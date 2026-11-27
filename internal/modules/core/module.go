// Package core — modul core (system) Go: 130 endpoint padanan
// modules/core NestJS. Wiring satu pintu (Register) dipanggil dari
// internal/app. Kontrak kawat BEKU: path, izin (core_routes live),
// envelope, pesan error PERSIS NestJS. Keputusan ratifikasi modul core:
// password demo = argon2id saat create; race 23505 → 409 pesan verbatim.
package core

import (
	"github.com/labstack/echo/v4"

	"nexierp/internal/modules/core/handler"
	"nexierp/internal/modules/core/types"
)

// Register — pasang SEMUA route modul core di bawah group /api.
func Register(api *echo.Group, d types.Deps) {
	handler.DaftarkanIam(api, d)
	handler.DaftarkanRbac(api, d)
	handler.DaftarkanSecurity(api, d)
	handler.DaftarkanTenants(api, d)
	handler.DaftarkanFiles(api, d)
	handler.DaftarkanWilayah(api, d) // lookup + admin + cluster + agama
}
