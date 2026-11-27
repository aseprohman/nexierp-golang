// Package types — tipe lintas-fitur modul core: Deps wiring + kontrak.
// CATATAN GUARD: file ini sengaja mengimpor echo + database (kontrak wiring
// modul, diratifikasi rencana G2-G3) — 2 temuan MERAH heuristik kind-murni
// adalah pengecualian kontrak terdokumentasi di Log pelacak, bukan pelanggaran
// lapisan bisnis.
package types

import (
	"log/slog"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/rbac"
	"nexierp/internal/core/storage"
)

// Deps — kebutuhan modul core (di-wiring internal/app; L3 → L1 turun saja).
type Deps struct {
	DB       *database.DB
	Cfg      *config.Env
	Log      *slog.Logger
	Audit    *audit.Service
	Compiler *rbac.Compiler
	Registry *rbac.RouteRegistry
	Media    *storage.MediaLibraryService
	Store    *storage.Service

	// AuthGuard — JWT + validasi core_sessions (hasil wiring auth.Guard).
	AuthGuard echo.MiddlewareFunc
	// RbacGuard — PermissionsGuard route-centric (rbac.PermissionsGuard.Middleware()).
	RbacGuard echo.MiddlewareFunc
}
