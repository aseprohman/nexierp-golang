package rbac

import (
	"context"
	"errors"
	"log/slog"
	"reflect"
	"sort"
	"testing"
	"time"

	"nexierp/internal/core/rbac/repository/gen"
)

// fakePermLoader — loader permission palsu (pure, tanpa DB).
type fakePermLoader struct {
	roleCodes []string
	overrides []gen.UserRouteOverridesRow
	errRole   error
	callsRole int
}

func (f *fakePermLoader) RoleRouteCodes(ctx context.Context, userID int64) ([]string, error) {
	f.callsRole++
	if f.errRole != nil {
		return nil, f.errRole
	}
	return f.roleCodes, nil
}

func (f *fakePermLoader) UserRouteOverrides(ctx context.Context, userID int64) ([]gen.UserRouteOverridesRow, error) {
	return f.overrides, nil
}

func newTestCompiler(l permissionLoader) *Compiler {
	return &Compiler{repo: l, log: slog.Default(), cache: map[int64]userCacheEntry{}}
}

func override(granted bool, code string) gen.UserRouteOverridesRow {
	return gen.UserRouteOverridesRow{Granted: granted, Code: code}
}

// TestMergeDenyMenang — deny diterapkan SETELAH grant: deny menang atas
// grant berapa pun urutannya (aturan §D2).
func TestMergeDenyMenang(t *testing.T) {
	role := []string{"system.user.list", "system.user.delete", "pos.order.list"}
	// deny dan grant code yang SAMA — deny harus menang walau deny lebih dulu.
	overrides := []userOverride{
		{granted: false, code: "system.user.delete"},
		{granted: true, code: "system.user.delete"},
		{granted: true, code: "pos.order.export"},
	}
	got := mergePermissionSet(role, overrides)
	want := []string{"pos.order.export", "pos.order.list", "system.user.list"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("merge = %v, harap %v", got, want)
	}
}

// TestMergeUrutanHasilLeksikografis — hasil ter-sort leksikografis.
func TestMergeUrutanHasilLeksikografis(t *testing.T) {
	got := mergePermissionSet([]string{"zz.top", "aa.bottom"}, nil)
	if !sort.StringsAreSorted(got) {
		t.Errorf("hasil harus ter-sort, dapat %v", got)
	}
	if !reflect.DeepEqual(got, []string{"aa.bottom", "zz.top"}) {
		t.Errorf("merge = %v, harap [aa.bottom zz.top]", got)
	}
}

// TestCompilerTTLCache — cache in-memory TTL 60 dtk: hit tidak menyentuh
// DB; kedaluwarsa memuat ulang; InvalidateUser memaksa muat ulang.
func TestCompilerTTLCache(t *testing.T) {
	loader := &fakePermLoader{roleCodes: []string{"a.b.c"}}
	comp := newTestCompiler(loader)
	ctx := context.Background()

	set1, err := comp.PermissionSet(ctx, 7)
	if err != nil {
		t.Fatalf("PermissionSet error: %v", err)
	}
	set2, err := comp.PermissionSet(ctx, 7)
	if err != nil {
		t.Fatalf("PermissionSet error: %v", err)
	}
	if loader.callsRole != 1 {
		t.Fatalf("hit cache tidak boleh menyentuh DB, panggilan = %d", loader.callsRole)
	}
	if len(set1) != 1 || set1[0] != "a.b.c" || len(set2) != 1 {
		t.Fatalf("isi set salah: %v / %v", set1, set2)
	}

	// Setelah TTL lewat → muat ulang.
	comp.mu.Lock()
	entri := comp.cache[7]
	entri.cachedAt = time.Now().Add(-UserPermissionCacheTTL - time.Second)
	comp.cache[7] = entri
	comp.mu.Unlock()
	if _, err = comp.PermissionSet(ctx, 7); err != nil {
		t.Fatalf("PermissionSet error: %v", err)
	}
	if loader.callsRole != 2 {
		t.Errorf("cache kedaluwarsa harus memuat ulang, panggilan = %d", loader.callsRole)
	}

	// InvalidateUser → muat ulang walau masih segar.
	comp.InvalidateUser(7)
	if _, err = comp.PermissionSet(ctx, 7); err != nil {
		t.Fatalf("PermissionSet error: %v", err)
	}
	if loader.callsRole != 3 {
		t.Errorf("InvalidateUser harus memaksa muat ulang, panggilan = %d", loader.callsRole)
	}
}

// TestCompilerTTLCachePerUser — cache terpisah per user.
func TestCompilerTTLCachePerUser(t *testing.T) {
	loader := &fakePermLoader{roleCodes: []string{"x.y.z"}}
	comp := newTestCompiler(loader)
	ctx := context.Background()
	if _, err := comp.PermissionSet(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := comp.PermissionSet(ctx, 2); err != nil {
		t.Fatal(err)
	}
	if loader.callsRole != 2 {
		t.Errorf("user beda harus memuat terpisah, panggilan = %d", loader.callsRole)
	}
}

// TestCompilerInvalidateAll — buang seluruh cache + listener diberi tahu
// dengan daftar user ter-cache dan all=true.
func TestCompilerInvalidateAll(t *testing.T) {
	loader := &fakePermLoader{roleCodes: []string{"a.b.c"}}
	comp := newTestCompiler(loader)
	ctx := context.Background()
	for _, id := range []int64{1, 2, 3} {
		if _, err := comp.PermissionSet(ctx, id); err != nil {
			t.Fatal(err)
		}
	}

	var (
		hookIDs []int64
		hookAll bool
	)
	comp.OnInvalidate(func(userIDs []int64, all bool) {
		hookIDs = append(hookIDs, userIDs...)
		hookAll = all
	})
	comp.InvalidateAll()
	if loader.callsRole != 3 {
		t.Fatalf("panggilan awal = %d, harap 3", loader.callsRole)
	}
	if _, err := comp.PermissionSet(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if loader.callsRole != 4 {
		t.Errorf("setelah InvalidateAll semua cache harus kosong, panggilan = %d", loader.callsRole)
	}
	if !hookAll {
		t.Error("hook InvalidateAll harus all=true")
	}
	if len(hookIDs) != 3 {
		t.Errorf("hook harus menerima 3 user ter-cache, dapat %v", hookIDs)
	}
}

// TestCompilerHasDenyMenang — deny override menghapus code dari set: Has
// false untuk code yang di-deny meski di-grant role.
func TestCompilerHasDenyMenang(t *testing.T) {
	loader := &fakePermLoader{
		roleCodes: []string{"a.b.c", "a.b.delete"},
		overrides: []gen.UserRouteOverridesRow{
			override(false, "a.b.delete"),
		},
	}
	comp := newTestCompiler(loader)
	ctx := context.Background()

	if has, err := comp.Has(ctx, 5, "a.b.c"); err != nil || !has {
		t.Errorf("Has a.b.c = %v (err %v), harap true", has, err)
	}
	if has, _ := comp.Has(ctx, 5, "a.b.delete"); has {
		t.Error("deny per-user harus menghapus code (Has false)")
	}
	if has, _ := comp.Has(ctx, 5, "tidak.ada.code"); has {
		t.Error("code di luar set harus false")
	}
}

// TestCompilerErrorDiteruskan — gagal query role → error ke pemanggil (guard
// memetakan 500), cache tidak terisi.
func TestCompilerErrorDiteruskan(t *testing.T) {
	loader := &fakePermLoader{errRole: errors.New("db down")}
	comp := newTestCompiler(loader)
	ctx := context.Background()
	if _, err := comp.PermissionSet(ctx, 1); err == nil {
		t.Fatal("error harus diteruskan")
	}
	if len(comp.cache) != 0 {
		t.Error("cache tidak boleh terisi saat gagal")
	}
}
