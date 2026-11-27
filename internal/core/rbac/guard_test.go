package rbac

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/rbac/repository/gen"
)

// setupGuard — guard dengan registry + compiler pure (tanpa DB); provider
// sesi palsu mengenal user 7.
func setupGuard(routes []gen.ListRoutesRow, roleCodes []string) (*PermissionsGuard, echo.MiddlewareFunc) {
	reg := newTestRegistry(&fakeRouteLoader{rows: routes})
	comp := newTestCompiler(&fakePermLoader{roleCodes: roleCodes})
	g := &PermissionsGuard{Reg: reg, Compiler: comp, UserProvider: func(c echo.Context) (int64, string, int64, bool) {
		return 7, "andi", 55, true
	}}
	return g, g.Middleware()
}

// jalankan — jalankan middleware atas request path+method; kembalikan
// (nextTerpanggil, status, body).
func jalankan(t *testing.T, mw echo.MiddlewareFunc, method, target string) (bool, int, string) {
	t.Helper()
	e := echo.New()
	req := httptest.NewRequest(method, target, nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	nextTerpanggil := false
	err := mw(func(c echo.Context) error {
		nextTerpanggil = true
		return c.NoContent(http.StatusOK)
	})(c)
	if err != nil {
		// Echo menyimpan status di response recorder via c.JSON di WriteProblem.
		return nextTerpanggil, rec.Code, rec.Body.String()
	}
	return nextTerpanggil, rec.Code, rec.Body.String()
}

var routeDemo = []gen.ListRoutesRow{
	route("GET", "/system/users", "system.master.list"),
	route("GET", "/system/users/:id", "system.master.detail"),
}

// TestGuardUrutanKeputusan — alur lengkap (a)–(e) persis PermissionsGuard.
func TestGuardUrutanKeputusan(t *testing.T) {
	_, mw := setupGuard(routeDemo, []string{"system.master.list"})

	// (a) publik → lolos tanpa sesi (provider tidak dipanggil).
	next, status, _ := jalankan(t, mw, http.MethodGet, "/health")
	if !next || status != http.StatusOK {
		t.Errorf("(a) /health harus lolos; next=%v status=%d", next, status)
	}

	// (b) tanpa sesi → 401 AUTH-401 pesan persis.
	g2 := &PermissionsGuard{Reg: newTestRegistry(&fakeRouteLoader{rows: routeDemo}),
		Compiler: newTestCompiler(&fakePermLoader{}), UserProvider: func(c echo.Context) (int64, string, int64, bool) {
			return 0, "", 0, false
		}}
	next, status, body := jalankan(t, g2.Middleware(), http.MethodGet, "/system/users")
	if next || status != http.StatusUnauthorized || !strings.Contains(body, "AUTH-401") ||
		!strings.Contains(body, "Sesi tidak ditemukan — login terlebih dahulu.") {
		t.Errorf("(b) harus 401 AUTH-401; next=%v status=%d body=%s", next, status, body)
	}

	// (d) endpoint tidak terdaftar → 403 deny-by-default, pesan persis.
	_, mw3 := setupGuard(routeDemo, []string{"system.master.list"})
	next, status, body = jalankan(t, mw3, http.MethodGet, "/tidak/terdaftar")
	if next || status != http.StatusForbidden || !strings.Contains(body, "FORB-403") ||
		!strings.Contains(body, "endpoint tidak terdaftar dalam core_routes (deny-by-default)") {
		t.Errorf("(d) harus 403 deny-by-default; next=%v status=%d body=%s", next, status, body)
	}

	// (e) terdaftar tapi permission tidak ada → 403 pesan persis.
	_, mw4 := setupGuard(routeDemo, []string{"lain.modul.list"})
	next, status, body = jalankan(t, mw4, http.MethodGet, "/system/users")
	if next || status != http.StatusForbidden || !strings.Contains(body, `permission 'system.master.list' diperlukan`) {
		t.Errorf("(e) harus 403 permission diperlukan; next=%v status=%d body=%s", next, status, body)
	}

	// Lolos: terdaftar + permission ada.
	_, mw5 := setupGuard(routeDemo, []string{"system.master.list"})
	next, status, _ = jalankan(t, mw5, http.MethodGet, "/system/users")
	if !next || status != http.StatusOK {
		t.Errorf("harus lolos; next=%v status=%d", next, status)
	}
}

// TestGuardNormalisasiPath — prefix /api dan trailing slash dibuang sebelum
// matching (paritas resolveRequestPath NestJS).
func TestGuardNormalisasiPath(t *testing.T) {
	_, mw := setupGuard(routeDemo, []string{"system.master.list"})

	next, status, _ := jalankan(t, mw, http.MethodGet, "/api/system/users")
	if !next || status != http.StatusOK {
		t.Errorf("prefix /api harus dibuang; next=%v status=%d", next, status)
	}
	next, status, _ = jalankan(t, mw, http.MethodGet, "/api/system/users/")
	if !next || status != http.StatusOK {
		t.Errorf("trailing slash harus dibuang; next=%v status=%d", next, status)
	}
	next, status, _ = jalankan(t, mw, http.MethodGet, "/api")
	if next {
		t.Error("/api ternormalisasi jadi '/' — bukan allowlist, harus ditolak")
	}
}

// TestGuardParamCocokSatuSegmen — route `:id` menerima segmen non-kosong.
func TestGuardParamCocokSatuSegmen(t *testing.T) {
	_, mw := setupGuard(routeDemo, []string{"system.master.detail"})
	next, status, _ := jalankan(t, mw, http.MethodGet, "/system/users/42")
	if !next || status != http.StatusOK {
		t.Errorf("/:id harus cocok /system/users/42; next=%v status=%d", next, status)
	}
}

// TestRequestPath — normalisasi persis resolveRequestPath.
func TestRequestPath(t *testing.T) {
	e := echo.New()
	kasus := []struct{ target, want string }{
		{"/system/users", "/system/users"},
		{"/api/system/users", "/system/users"},
		{"/system/users/", "/system/users"},
		{"/", "/"},
		{"/api", "/"},
		{"/api/", "/"},
	}
	for _, k := range kasus {
		req := httptest.NewRequest(http.MethodGet, k.target, nil)
		c := e.NewContext(req, httptest.NewRecorder())
		if got := RequestPath(c); got != k.want {
			t.Errorf("RequestPath(%q) = %q, harap %q", k.target, got, k.want)
		}
	}
}

// TestGuardGagalCompiler500 — compiler gagal (DB down) → 500 via
// errkontrak.Map (SYS-000, detail generik).
func TestGuardGagalCompiler500(t *testing.T) {
	reg := newTestRegistry(&fakeRouteLoader{rows: routeDemo})
	comp := newTestCompiler(&fakePermLoader{errRole: context.DeadlineExceeded})
	g := &PermissionsGuard{Reg: reg, Compiler: comp, UserProvider: func(c echo.Context) (int64, string, int64, bool) {
		return 7, "andi", 55, true
	}}
	_, status, body := jalankan(t, g.Middleware(), http.MethodGet, "/system/users")
	if status != http.StatusInternalServerError || !strings.Contains(body, "SYS-000") {
		t.Errorf("gagal compiler harus 500 SYS-000; status=%d body=%s", status, body)
	}
}

// TestGuardRegistryFailClosed — registry gagal muat → endpoint terdaftar
// pun ditolak deny-by-default (fail-closed), lalu pulih saat retry.
func TestGuardRegistryFailClosed(t *testing.T) {
	loader := &fakeRouteLoader{err: context.DeadlineExceeded}
	reg := newTestRegistry(loader)
	comp := newTestCompiler(&fakePermLoader{roleCodes: []string{"system.master.list"}})
	g := &PermissionsGuard{Reg: reg, Compiler: comp, UserProvider: func(c echo.Context) (int64, string, int64, bool) {
		return 7, "andi", 55, true
	}}
	_, status, body := jalankan(t, g.Middleware(), http.MethodGet, "/system/users")
	if status != http.StatusForbidden || !strings.Contains(body, "deny-by-default") {
		t.Errorf("registry gagal harus deny-by-default; status=%d body=%s", status, body)
	}

	// DB pulih → resolve berikutnya memuat ulang dan request lolos.
	loader.err = nil
	loader.rows = routeDemo
	next, status, _ := jalankan(t, g.Middleware(), http.MethodGet, "/system/users")
	if !next || status != http.StatusOK {
		t.Errorf("setelah DB pulih harus lolos; next=%v status=%d", next, status)
	}
}

// TestGuardTanpaUserProvider — provider nil = salah pasang wiring → 401
// (fail-closed), bukan panic.
func TestGuardTanpaUserProvider(t *testing.T) {
	g := &PermissionsGuard{Reg: newTestRegistry(&fakeRouteLoader{rows: routeDemo}),
		Compiler: newTestCompiler(&fakePermLoader{})}
	next, status, body := jalankan(t, g.Middleware(), http.MethodGet, "/system/users")
	if next || status != http.StatusUnauthorized || !strings.Contains(body, "AUTH-401") {
		t.Errorf("tanpa UserProvider harus 401; next=%v status=%d body=%s", next, status, body)
	}
}
