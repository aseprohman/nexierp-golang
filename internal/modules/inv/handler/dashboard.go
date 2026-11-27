// handler/dashboard.go — permukaan HTTP fitur DASHBOARD INVENTORY (6
// endpoint GET, READ-ONLY) — padanan DashboardController NestJS. Semua
// endpoint ber-prefix /inventory/dashboard → permission inventory.dashboard;
// guard d.AuthGuard + d.RbacGuard per group. Envelope: list non-page →
// { data }; parsing query kecil (hari, kelompok, idGudang) mengikuti
// controller NestJS (invalid → diabaikan/di-fallback, TANPA 400 kecuali
// ditentukan).
package handler

import (
	"strconv"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanDashboard — pasang 6 route dashboard di group /inventory/dashboard.
func DaftarkanDashboard(api *echo.Group, d types.Deps) {
	h := &dashboardHandler{svc: service.NewDashboardService(d.DB, d.ModCfg)}
	g := api.Group("/inventory/dashboard", d.AuthGuard, d.RbacGuard)
	g.GET("/ringkasan", h.ringkasan)
	g.GET("/tren", h.tren)
	g.GET("/nilai", h.nilai)
	g.GET("/backlog", h.backlog)
	g.GET("/reorder", h.reorder)
	g.GET("/expiring", h.expiring)
}

// dashboardHandler — dependensi handler dashboard.
type dashboardHandler struct {
	svc *service.DashboardService
}

// ringkasan — GET /ringkasan → { data: DashboardRingkasanView }.
func (h *dashboardHandler) ringkasan(c echo.Context) error {
	view, err := h.svc.Ringkasan(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// tren — GET /tren?hari=14 → { data: DashboardTrenRowView[] }; clamp 1..90
// default 14 TANPA 400 (verbatim).
func (h *dashboardHandler) tren(c echo.Context) error {
	data, err := h.svc.Tren(c.Request().Context(), c.QueryParam("hari"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// nilai — GET /nilai?kelompok=kategori|gudang → { data }; kelompok invalid
// → kategori diam-diam (verbatim).
func (h *dashboardHandler) nilai(c echo.Context) error {
	data, err := h.svc.Nilai(c.Request().Context(), c.QueryParam("kelompok"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// backlog — GET /backlog → { data: BacklogRowView[] }.
func (h *dashboardHandler) backlog(c echo.Context) error {
	data, err := h.svc.Backlog(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// reorder — GET /reorder → { data: ReorderRowView[] }.
func (h *dashboardHandler) reorder(c echo.Context) error {
	data, err := h.svc.Reorder(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// expiring — GET /expiring?idGudang= → { data: ExpiringRowView[] }; id
// invalid → diabaikan (Number.isInteger guard verbatim).
func (h *dashboardHandler) expiring(c echo.Context) error {
	idGudang := angkaQueryOpsionalInteger(c.QueryParam("idGudang"))
	data, err := h.svc.Expiring(c.Request().Context(), idGudang)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// angkaQueryOpsionalInteger — padanan
// `idGudang != null && idGudang !== "" ? Number(id) : undefined` +
// `Number.isInteger(id) ? id : undefined`: kosong → nil; bukan integer →
// diabaikan (nil); integer (termasuk ≤ 0) diteruskan apa adanya.
func angkaQueryOpsionalInteger(raw string) *int64 {
	if raw == "" {
		return nil
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || f != float64(int64(f)) {
		return nil
	}
	n := int64(f)
	return &n
}
