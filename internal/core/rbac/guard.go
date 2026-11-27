package rbac

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
)

// PermissionsGuard — guard permission RBAC v2 route-centric (padanan
// PermissionsGuard NestJS). Struct agar wiring cmd/api dapat mengisi field
// UserProvider dari paket auth (rbac tidak mengimpor auth).
type PermissionsGuard struct {
	// UserProvider — sumber user sesi (wiring cmd/api mengisinya dari
	// auth); ok=false = tidak ada sesi → 401.
	UserProvider UserProvider

	// Reg — registry route (resolve method+path → permission code).
	Reg *RouteRegistry
	// Compiler — compiler permission efektif per user.
	Compiler *Compiler
}

// Guard — pintu satu-baris: middleware permission dari registry + compiler.
// Tanpa UserProvider (PermissionsGuard.UserProvider kosong) semua request
// non-publik 401 — fail-closed; wiring sesungguhnya memakai
// PermissionsGuard dengan UserProvider terisi.
func Guard(reg *RouteRegistry, comp *Compiler) echo.MiddlewareFunc {
	return (&PermissionsGuard{Reg: reg, Compiler: comp}).Middleware()
}

// Middleware — echo middleware (padanan canActivate). Alur keputusan per
// request (path sudah dinormalisasi — buang query, buang prefix global
// `/api`, buang trailing slash):
//
//	(a) PUBLIC_ALLOWLIST eksak → lolos tanpa sesi;
//	(b) selain itu WAJIB user sesi → tidak ada = 401 AUTH-401;
//	(c) override @RequirePermission — TIDAK ADA pemakai di repo ini; dilewati;
//	(d) resolve(method, path) gagal = endpoint TIDAK terdaftar core_routes →
//	    403 deny-by-default;
//	(e) permission code tidak ada di set efektif user → 403.
func (g *PermissionsGuard) Middleware() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			path := RequestPath(c)

			// (a) Allowlist publik — eksak + pola ber-parameter.
			if IsPublicPath(path) {
				return next(c)
			}

			// (b) Sesi wajib — UserProvider dipasang wiring di depan guard.
			if g.UserProvider == nil {
				return errkontrak.WriteProblem(c, http.StatusUnauthorized, errkontrak.CodeAuth401,
					"Sesi tidak ditemukan — login terlebih dahulu.", nil)
			}
			id, username, sessionID, ok := g.UserProvider(c)
			if !ok {
				return errkontrak.WriteProblem(c, http.StatusUnauthorized, errkontrak.CodeAuth401,
					"Sesi tidak ditemukan — login terlebih dahulu.", nil)
			}
			user := AuthenticatedUser{ID: id, Username: username, SessionID: sessionID}

			// (c) Override ekspresif @RequirePermission — 0 pemakai di repo
			// ini (semua route route-centric); dilewati persis spek.

			// (d) Route-centric — endpoint tidak terdaftar = tolak
			// (deny-by-default). Registry gagal muat = fail-closed di sini.
			code, terdaftar := g.Reg.Resolve(c.Request().Context(), strings.ToLower(c.Request().Method), path)
			if !terdaftar {
				return errkontrak.WriteProblem(c, http.StatusForbidden, errkontrak.CodeForb403,
					"endpoint tidak terdaftar dalam core_routes (deny-by-default)", nil)
			}

			// (e) Permission code route harus ada di set efektif user.
			has, err := g.Compiler.Has(c.Request().Context(), user.ID, code)
			if err != nil {
				return errkontrak.Map(c, err)
			}
			if !has {
				return errkontrak.WriteProblem(c, http.StatusForbidden, errkontrak.CodeForb403,
					fmt.Sprintf("permission '%s' diperlukan", code), nil)
			}
			return next(c)
		}
	}
}

// RequestPath — normalisasi path request (padanan resolveRequestPath
// NestJS): buang query string, buang prefix global `/api`, buang trailing
// slash — hasil selalu `"/..."` atau `"/"`.
func RequestPath(c echo.Context) string {
	path := c.Request().URL.Path
	if path == "" {
		path = "/"
	}
	if path == "/api" {
		path = "/"
	} else if strings.HasPrefix(path, "/api/") {
		path = path[len("/api"):] // "/api/system/users" → "/system/users"
	}
	if len(path) > 1 {
		path = strings.TrimRight(path, "/") // trailing slash diabaikan
	}
	if path == "" {
		return "/"
	}
	return path
}
