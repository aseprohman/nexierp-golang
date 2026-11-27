// Package types — kontrak wiring modul inv (padanan inv NestJS).
// CATATAN GUARD: mengimpor echo+database = kontrak wiring ter-ratifikasi
// (pola yang sama dengan modul core — pengecualian kind-murni terdokumentasi).
package types

import (
	"log/slog"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/core/numbering"
	"nexierp/internal/core/outbox"
	"nexierp/internal/core/pkcipher"
	"nexierp/internal/core/rbac"
)

// Deps — kebutuhan modul inv (di-wiring internal/app; L3 → L1 turun saja).
type Deps struct {
	DB        *database.DB
	Cfg       *config.Env
	Log       *slog.Logger
	Audit     *audit.Service
	Outbox    *outbox.Service
	Numbering *numbering.Service
	ModCfg    *moduleconfig.Service
	Scope     *rbac.Scope // data-scope 3-mode (dimensi 'storages' inv_gudang)
	Cipher    *pkcipher.Cipher

	// AuthGuard / RbacGuard — echo.MiddlewareFunc hasil wiring.
	AuthGuard echo.MiddlewareFunc
	RbacGuard echo.MiddlewareFunc
}
