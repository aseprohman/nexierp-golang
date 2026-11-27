package rbac

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"time"

	"nexierp/internal/core/rbac/repository"
	"nexierp/internal/core/rbac/repository/gen"
)

// permissionLoader — permukaan repository yang dipakai compiler (dipisah
// jadi interface agar merge/TTL cache teruji pure tanpa DB).
type permissionLoader interface {
	RoleRouteCodes(ctx context.Context, userID int64) ([]string, error)
	UserRouteOverrides(ctx context.Context, userID int64) ([]gen.UserRouteOverridesRow, error)
}

// UserPermissionCacheTTL — TTL cache in-memory permission per user,
// invalid via InvalidateUser/InvalidateAll (padanan NestJS 60 dtk).
const UserPermissionCacheTTL = 60 * time.Second

// InvalidationHook — listener invalidasi cache; dipanggil setiap
// InvalidateUser/InvalidateAll (all=true = seluruh cache dibuang). Dipasang
// jembatan realtime (wiring lain) untuk menerjemahkannya menjadi event
// socket `rbac.changed` — callback, bukan inject service, agar compiler
// tidak membuat siklus modul auth → rbac → realtime.
type InvalidationHook func(userIDs []int64, all bool)

// userCacheEntry — entri cache permission efektif per user.
type userCacheEntry struct {
	set      []string
	cachedAt time.Time
}

// Compiler — kompiler permission efektif RBAC v2.1 SET-based, SATU SUMBER
// CODE = core_routes.permission_code.
//
// Permission efektif SATU USER (dua query persis NestJS):
//  1. UNION code route via SEMUA role user (SET 'active', modul enabled —
//     SET tanpa modul tetap dihitung);
//  2. override per-user PER SET core_user_permissions (baris hidup, belum
//     kedaluwarsa): granted=true menambah code, granted=false (deny)
//     menghapus code — deny diterapkan SETELAH grant (DENY MENANG).
//
// Hasil di-cache in-memory per user dengan TTL 60 detik dan invalidasi
// eksplisit InvalidateUser/InvalidateAll; output tetap []string code dari
// core_routes.
type Compiler struct {
	repo permissionLoader
	log  *slog.Logger

	mu        sync.Mutex
	cache     map[int64]userCacheEntry
	listeners []InvalidationHook
}

// NewCompiler membuat compiler di atas executor (pool).
func NewCompiler(exec repository.Executor, log *slog.Logger) *Compiler {
	if log == nil {
		log = slog.Default()
	}
	return &Compiler{
		repo:  repository.New(exec),
		log:   log,
		cache: map[int64]userCacheEntry{},
	}
}

// OnInvalidate — pasang listener invalidasi cache (dipanggil jembatan
// realtime saat init); menerima daftar user yang cache permission-nya baru
// dibuang. Aman dipasang tanpa/banyak listener.
func (c *Compiler) OnInvalidate(fn InvalidationHook) {
	c.mu.Lock()
	c.listeners = append(c.listeners, fn)
	c.mu.Unlock()
}

// PermissionSet — permission efektif SATU USER (multi-role union + override
// per-user), cache in-memory TTL 60 detik. Hasil di-sort leksikografis.
// Slice hasil milik compiler — jangan dimutasi.
func (c *Compiler) PermissionSet(ctx context.Context, userID int64) ([]string, error) {
	c.mu.Lock()
	hit, ok := c.cache[userID]
	c.mu.Unlock()
	if ok && time.Since(hit.cachedAt) < UserPermissionCacheTTL {
		return hit.set, nil
	}
	set, err := c.compute(ctx, userID)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	c.cache[userID] = userCacheEntry{set: set, cachedAt: time.Now()}
	c.mu.Unlock()
	return set, nil
}

// Has — cek satu permission code untuk user (dipakai PermissionsGuard).
func (c *Compiler) Has(ctx context.Context, userID int64, code string) (bool, error) {
	set, err := c.PermissionSet(ctx, userID)
	if err != nil {
		return false, err
	}
	// Set ter-sort leksikografis — pencarian biner.
	i := sort.SearchStrings(set, code)
	return i < len(set) && set[i] == code, nil
}

// InvalidateUser — buang cache satu user (dipanggil modul system setelah
// mutasi override). Listener realtime menerjemahkannya menjadi event
// `rbac.changed` → klien memuat ulang `/auth/me`.
func (c *Compiler) InvalidateUser(userID int64) {
	c.mu.Lock()
	delete(c.cache, userID)
	listeners := c.cloneListeners()
	c.mu.Unlock()
	c.notify([]int64{userID}, false, listeners)
}

// InvalidateAll — buang SEMUA cache (setelah mutasi role/permission/modul/
// route). Hanya user yang permission-nya sempat ter-cache yang diberi tahu.
func (c *Compiler) InvalidateAll() {
	c.mu.Lock()
	userIDs := make([]int64, 0, len(c.cache))
	for id := range c.cache {
		userIDs = append(userIDs, id)
	}
	c.cache = map[int64]userCacheEntry{}
	listeners := c.cloneListeners()
	c.mu.Unlock()
	c.notify(userIDs, true, listeners)
}

// notify — panggil semua listener invalidasi (aman tanpa listener); di luar
// mutex agar listener tidak pernah deadlock terhadap compiler.
func (c *Compiler) notify(userIDs []int64, all bool, listeners []InvalidationHook) {
	if len(listeners) == 0 {
		return
	}
	for _, fn := range listeners {
		if fn != nil {
			fn(userIDs, all)
		}
	}
}

func (c *Compiler) cloneListeners() []InvalidationHook {
	out := make([]InvalidationHook, len(c.listeners))
	copy(out, c.listeners)
	return out
}

// compute — union multi-role + override per-user, tanpa cache (internal).
func (c *Compiler) compute(ctx context.Context, userID int64) ([]string, error) {
	roleCodes, err := c.repo.RoleRouteCodes(ctx, userID)
	if err != nil {
		return nil, err
	}
	overrides, err := c.repo.UserRouteOverrides(ctx, userID)
	if err != nil {
		return nil, err
	}
	o := make([]userOverride, len(overrides))
	for i, row := range overrides {
		o[i] = userOverride{granted: row.Granted, code: row.Code}
	}
	return mergePermissionSet(roleCodes, o), nil
}

// userOverride — satu baris override per-user PER SET permission.
type userOverride struct {
	granted bool
	code    string
}

// mergePermissionSet — MURNI: grant dulu, deny terakhir — deny menang atas
// grant (aturan §D2 NestJS); hasil sort leksikografis.
func mergePermissionSet(roleCodes []string, overrides []userOverride) []string {
	set := make(map[string]struct{}, len(roleCodes))
	for _, code := range roleCodes {
		set[code] = struct{}{}
	}
	for _, o := range overrides {
		if o.granted {
			set[o.code] = struct{}{}
		}
	}
	for _, o := range overrides {
		if !o.granted {
			delete(set, o.code)
		}
	}
	out := make([]string, 0, len(set))
	for code := range set {
		out = append(out, code)
	}
	sort.Strings(out)
	return out
}
