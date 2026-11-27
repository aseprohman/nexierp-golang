// Package rbac — porting persis core/rbac NestJS: guard permission
// ROUTE-CENTRIC, registry route (cache core_routes), compiler permission
// efektif (union role + override per-user, TTL 60 dtk), dan evaluator
// data-scope tiga tabel dinamis.
//
// Paket ini TIDAK mengimpor paket auth — guard menerima user sesi dari
// field UserProvider yang diisi wiring cmd/api (dari auth), sehingga
// RBAC dan auth saling decouple.
package rbac

import "github.com/labstack/echo/v4"

// AuthenticatedUser — identitas aktor sesi (padanan AuthenticatedUser
// NestJS yang dipasang JwtAuthGuard di req.user). Kompatibel auth.User;
// hanya di rbac untuk keperluan internal guard.
type AuthenticatedUser struct {
	// ID — PK core_users (JWT claim `sub`).
	ID int64
	// Username — natural key core_users (JWT claim `username`).
	Username string
	// SessionID — PK core_sessions (JWT claim `sid`) — untuk revoke/logout.
	SessionID int64
}

// UserProvider — jembatan auth → rbac (decouple, tanpa import auth):
// ekstrak user sesi dari echo.Context. Wiring cmd/api mengisinya dari
// paket auth; ok=false = tidak ada sesi (guard memutuskan 401).
type UserProvider func(c echo.Context) (id int64, username string, sessionID int64, ok bool)
