// Package health — padanan health.controller NestJS: GET /api/health publik,
// respons {"status":"ok"} TANPA envelope (pengecualian konvensi).
// Penambahan cek pg/redis (readiness) menyusul tanpa mengubah bentuk.
package health

import (
	"net/http"

	"github.com/labstack/echo/v4"
)

// check — handler liveness. Fungsi BERI-NAMA (bukan closure) agar nama
// handler terbaca di echo Routes() (`nexierp/internal/health.check`) —
// cmd/scanroute memakainya sebagai segmen action permission code
// `health.health.check` (paritas rev.6 NestJS: HealthController.check
// flat di src/health).
func check(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]string{"status": "ok"})
}

// Register memasang /health pada group (prefix /api dari wiring cmd/api).
func Register(g *echo.Group) {
	g.GET("/health", check)
}
