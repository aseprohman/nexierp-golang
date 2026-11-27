package rbac

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	"nexierp/internal/core/rbac/repository/gen"
)

// fakeRouteLoader — loader route palsu (pure, tanpa DB).
type fakeRouteLoader struct {
	rows  []gen.ListRoutesRow
	err   error
	calls int
}

func (f *fakeRouteLoader) ListRoutes(ctx context.Context) ([]gen.ListRoutesRow, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.rows, nil
}

func route(method, uri, code string) gen.ListRoutesRow {
	return gen.ListRoutesRow{Method: gen.CoreHttpMethod(method), UriPattern: uri, PermissionCode: code}
}

func newTestRegistry(l routeLoader) *RouteRegistry {
	return &RouteRegistry{repo: l, log: slog.Default(), entries: map[string][]RouteEntry{}}
}

// TestResolveLazyLoad — resolve pertama memuat; resolve berikutnya tidak
// memuat ulang (cache memori).
func TestResolveLazyLoad(t *testing.T) {
	loader := &fakeRouteLoader{rows: []gen.ListRoutesRow{
		route("GET", "/system/users", "system.master.list"),
	}}
	reg := newTestRegistry(loader)
	ctx := context.Background()

	if _, ok := reg.Resolve(ctx, "get", "/system/users"); !ok {
		t.Fatal("resolve pertama harus menemukan route")
	}
	if loader.calls != 1 {
		t.Fatalf("resolve pertama harus memuat 1x, dapat %d", loader.calls)
	}
	if _, ok := reg.Resolve(ctx, "get", "/system/users"); !ok {
		t.Fatal("resolve kedua harus tetap menemukan route")
	}
	if loader.calls != 1 {
		t.Fatalf("resolve kedua tidak boleh memuat ulang, load = %d", loader.calls)
	}
	if reg.Size() != 1 {
		t.Errorf("size = %d, harap 1", reg.Size())
	}
}

// TestResolveFailClosedRetry — load gagal → resolve null (fail-closed);
// resolve BERIKUTNYA di-retry dan berhasil bila DB pulih.
func TestResolveFailClosedRetry(t *testing.T) {
	loader := &fakeRouteLoader{err: errors.New("db down")}
	reg := newTestRegistry(loader)
	ctx := context.Background()

	if _, ok := reg.Resolve(ctx, "get", "/system/users"); ok {
		t.Fatal("load gagal → resolve harus tidak ditemukan (fail-closed)")
	}
	if reg.Size() != 0 {
		t.Fatal("registry harus kosong setelah load gagal")
	}

	// DB pulih — resolve berikutnya harus memuat ulang (loaded=false).
	loader.err = nil
	loader.rows = []gen.ListRoutesRow{route("GET", "/system/users", "system.master.list")}
	if _, ok := reg.Resolve(ctx, "get", "/system/users"); !ok {
		t.Fatal("resolve setelah DB pulih harus berhasil (retry load)")
	}
}

// TestResolveInvalidate — Invalidate memaksa reload dari DB di resolve
// berikutnya (paritas reload setelah CRUD core_routes).
func TestResolveInvalidate(t *testing.T) {
	loader := &fakeRouteLoader{rows: []gen.ListRoutesRow{route("GET", "/a", "a.a.list")}}
	reg := newTestRegistry(loader)
	ctx := context.Background()

	if _, ok := reg.Resolve(ctx, "get", "/a"); !ok {
		t.Fatal("resolve awal gagal")
	}
	reg.Invalidate()
	loader.rows = []gen.ListRoutesRow{route("GET", "/a", "a.a.list"), route("GET", "/b", "b.b.list")}
	if _, ok := reg.Resolve(ctx, "get", "/b"); !ok {
		t.Fatal("setelah Invalidate route baru harus ter-resolve")
	}
	if loader.calls != 2 {
		t.Errorf("Invalidate harus memicu reload, load = %d", loader.calls)
	}
}

// TestResolvePrecedenceLiteralVsParam — pattern literal menang atas `:param`
// bila keduanya cocok (sort ascending jumlah segmen param per method).
func TestResolvePrecedenceLiteralVsParam(t *testing.T) {
	loader := &fakeRouteLoader{rows: []gen.ListRoutesRow{
		// Sengaja daftar TAK TERURUT — sort di doLoad yang menentukan.
		route("GET", "/inv/barang/:id", "inv.barang.detail"),
		route("GET", "/inv/barang/detail", "inv.barang.detailEksak"),
		route("GET", "/a/:b/:c", "abc.dua"),
		route("GET", "/a/x/:c", "abc.satu"),
	}}
	reg := newTestRegistry(loader)
	ctx := context.Background()

	if code, ok := reg.Resolve(ctx, "get", "/inv/barang/detail"); !ok || code != "inv.barang.detailEksak" {
		t.Errorf("literal harus menang atas :param; dapat %q (ok=%v)", code, ok)
	}
	if code, ok := reg.Resolve(ctx, "get", "/inv/barang/99"); !ok || code != "inv.barang.detail" {
		t.Errorf("path non-literal harus jatuh ke :param; dapat %q (ok=%v)", code, ok)
	}
	if code, ok := reg.Resolve(ctx, "get", "/a/x/9"); !ok || code != "abc.satu" {
		t.Errorf("lebih sedikit param harus dicoba lebih dulu; dapat %q (ok=%v)", code, ok)
	}
}

// TestResolveMatching — matching per segmen: panjang sama, `:x` menerima
// segmen non-kosong, trailing slash otomatis hilang, method lowercase.
func TestResolveMatching(t *testing.T) {
	loader := &fakeRouteLoader{rows: []gen.ListRoutesRow{
		route("GET", "/system/users/:id", "system.master.detail"),
		route("POST", "/auth/login", "auth.session.login"),
	}}
	reg := newTestRegistry(loader)
	ctx := context.Background()

	if _, ok := reg.Resolve(ctx, "GET", "/system/users/12"); !ok {
		t.Error("GET besar harus dicocokkan (method lowercase internal)")
	}
	// Trailing slash tidak MENAMBAH segmen (kosong dibuang) — tapi tetap
	// tidak cocok route 3-segmen :id; normalisasi trailing slash dilakukan
	// guard sebelum resolve (RequestPath).
	if _, ok := reg.Resolve(ctx, "get", "/system/users/"); ok {
		t.Error("2 segmen tidak boleh cocok route 3-segmen :id")
	}
	if _, ok := reg.Resolve(ctx, "get", "/system/users"); ok {
		t.Error("jumlah segmen beda (tanpa :id) tidak boleh cocok route :id")
	}
	if _, ok := reg.Resolve(ctx, "post", "/auth/login"); !ok {
		t.Error("POST /auth/login harus cocok")
	}
	if _, ok := reg.Resolve(ctx, "delete", "/auth/login"); ok {
		t.Error("method beda tidak boleh cocok (deny-by-default)")
	}
	if _, ok := reg.Resolve(ctx, "get", "/system/users/12/riwayat"); ok {
		t.Error("jumlah segmen lebih tidak boleh cocok")
	}
}
