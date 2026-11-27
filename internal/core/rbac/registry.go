package rbac

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"sync"

	"nexierp/internal/core/rbac/repository"
	"nexierp/internal/core/rbac/repository/gen"
)

// routeLoader — permukaan repository yang dipakai registry (dipisah jadi
// interface agar semantik lazy/fail-closed teruji pure tanpa DB).
type routeLoader interface {
	ListRoutes(ctx context.Context) ([]gen.ListRoutesRow, error)
}

// RouteEntry — satu entri route hasil parse core_routes (padanan
// RouteRegistryEntry NestJS).
type RouteEntry struct {
	// Method verb HTTP lowercase.
	Method string
	// URIPattern — pola URI apa adanya dari DB; segmen `:param` adalah
	// parameter.
	URIPattern string
	// PermissionCode — `{modul}.{fitur}.{action}`.
	PermissionCode string
	// Segmen URIPattern — elemen berawalan ":" adalah parameter.
	Segments []string
}

// RouteRegistry — memori cache tabel `core_routes` (method, uri_pattern,
// permission_code) untuk guard RBAC route-centric.
//
//   - load lazy saat resolve pertama; guard load in-flight mencegah
//     double-load paralel (panggilan paralel berbagi satu query);
//   - kegagalan load DB → registry kosong + loaded=false (FAIL-CLOSED:
//     semua resolve tidak ditemukan) → di-retry resolve berikutnya;
//   - Invalidate() memaksa reload dari DB pada resolve berikutnya.
type RouteRegistry struct {
	repo routeLoader
	log  *slog.Logger

	mu      sync.Mutex
	entries map[string][]RouteEntry
	loaded  bool
	loading *loadHandle
}

// loadHandle — penanda load in-flight (channel ditutup saat load selesai).
type loadHandle struct{ done chan struct{} }

// errLoadGagal — hasil load paralel yang gagal (pemanggil memutuskan
// fail-closed: resolve → tidak ditemukan).
var errLoadGagal = errors.New("rbac: muat core_routes gagal")

// NewRouteRegistry membuat registry di atas executor (pool) — padanan
// RouteRegistryService NestJS.
func NewRouteRegistry(exec repository.Executor, log *slog.Logger) *RouteRegistry {
	if log == nil {
		log = slog.Default()
	}
	return &RouteRegistry{
		repo:    repository.New(exec),
		log:     log,
		entries: map[string][]RouteEntry{},
	}
}

// Invalidate — paksa reload dari DB (load ulang di resolve berikutnya;
// dipanggil setelah CRUD core_routes).
func (r *RouteRegistry) Invalidate() {
	r.mu.Lock()
	r.loaded = false
	r.mu.Unlock()
}

// Size — jumlah route ter-load per seluruh method (observabilitas/test).
func (r *RouteRegistry) Size() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	total := 0
	for _, list := range r.entries {
		total += len(list)
	}
	return total
}

// Resolve — request → permission_code. ok=false = endpoint TIDAK terdaftar
// (guard wajib menolak — deny-by-default).
//
// method verb HTTP (case-insensitive); path TANPA prefix global `/api` dan
// tanpa query string (mis. `/system/users/123`); trailing slash diabaikan.
func (r *RouteRegistry) Resolve(ctx context.Context, method, path string) (string, bool) {
	entry, ok := r.ResolveEntry(ctx, method, path)
	if !ok {
		return "", false
	}
	return entry.PermissionCode, true
}

// ResolveEntry — request → ENTRI route utuh (method, uri_pattern,
// permission_code). ok=false = endpoint TIDAK terdaftar (deny-by-default).
func (r *RouteRegistry) ResolveEntry(ctx context.Context, method, path string) (RouteEntry, bool) {
	if err := r.ensureLoaded(ctx); err != nil {
		return RouteEntry{}, false
	}
	r.mu.Lock()
	list := r.entries[strings.ToLower(method)]
	r.mu.Unlock()
	pathSegments := SplitSegments(path)
	for _, entry := range list {
		if MatchSegments(entry.Segments, pathSegments) {
			return entry, true
		}
	}
	return RouteEntry{}, false
}

// ensureLoaded — lazy load pertama (dan retry bila load sebelumnya gagal —
// DB belum siap); load paralel berbagi satu query. Gagal lagi → registry
// tetap kosong.
func (r *RouteRegistry) ensureLoaded(ctx context.Context) error {
	r.mu.Lock()
	if r.loaded {
		r.mu.Unlock()
		return nil
	}
	if r.loading != nil {
		// Load berjalan — ikuti hasilnya (in-flight guard).
		ch := r.loading
		r.mu.Unlock()
		select {
		case <-ch.done:
		case <-ctx.Done():
			return ctx.Err()
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.loaded {
			return nil
		}
		return errLoadGagal
	}
	ch := &loadHandle{done: make(chan struct{})}
	r.loading = ch
	r.mu.Unlock()

	err := r.doLoad(ctx)

	r.mu.Lock()
	r.loading = nil
	if err == nil {
		r.loaded = true
	}
	r.mu.Unlock()
	close(ch.done)
	return err
}

// doLoad — query DB → isi map. Gagal = registry kosong + log (fail-closed).
func (r *RouteRegistry) doLoad(ctx context.Context) error {
	rows, err := r.repo.ListRoutes(ctx)
	if err != nil {
		r.mu.Lock()
		r.entries = map[string][]RouteEntry{}
		r.loaded = false
		r.mu.Unlock()
		r.log.Error("RouteRegistry gagal memuat core_routes — registry KOSONG (deny-by-default)",
			"error", err.Error())
		return err
	}

	next := make(map[string][]RouteEntry)
	for _, row := range rows {
		method := strings.ToLower(string(row.Method))
		entry := RouteEntry{
			Method:         method,
			URIPattern:     row.UriPattern,
			PermissionCode: row.PermissionCode,
			Segments:       SplitSegments(row.UriPattern),
		}
		next[method] = append(next[method], entry)
	}
	// Deterministik: route dengan LEBIH SEDIKIT segmen param dicoba lebih
	// dulu — pattern literal menang atas `:param` bila keduanya cocok.
	for _, list := range next {
		sort.SliceStable(list, func(i, j int) bool {
			return countParamSegments(list[i].Segments) < countParamSegments(list[j].Segments)
		})
	}
	r.mu.Lock()
	r.entries = next
	r.mu.Unlock()
	return nil
}
