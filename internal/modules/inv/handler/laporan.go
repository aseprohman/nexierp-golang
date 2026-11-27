// handler/laporan.go — permukaan HTTP fitur LAPORAN PERSEDIAAN (8 endpoint
// GET, READ-ONLY) — padanan LaporanController NestJS. Prefix
// /inventory/laporan → permission inventory.laporan; guard per group.
// Envelope: endpoint page (kartu-stok, lapisan-biaya, kpi, traceability) →
// { data, meta } ATAS (tanpa bungkus {data}); list polos → { data }.
// Validasi query zod-ekuivalen (pesan verbatim schemas: kpiQuerySchema,
// traceabilityQuerySchema).
package handler

import (
	"strconv"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanLaporan — pasang 8 route laporan di group /inventory/laporan.
func DaftarkanLaporan(api *echo.Group, d types.Deps) {
	h := &laporanHandler{svc: service.NewLaporanService(d.DB, d.ModCfg)}
	g := api.Group("/inventory/laporan", d.AuthGuard, d.RbacGuard)
	g.GET("/kartu-stok", h.kartuStok)
	g.GET("/expiring", h.expiring)
	g.GET("/nilai", h.nilai)
	g.GET("/backlog", h.backlog)
	g.GET("/reorder", h.reorder)
	g.GET("/lapisan-biaya", h.lapisanBiaya)
	g.GET("/kpi", h.kpi)
	g.GET("/traceability", h.traceability)
}

// laporanHandler — dependensi handler laporan.
type laporanHandler struct {
	svc *service.LaporanService
}

// page — kirim page { data, meta } ATAS (padanan return buildPage langsung).
func page(c echo.Context, p any) error {
	return c.JSON(200, p)
}

// fi — field issue singkat (laporan).
func fi(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

// kartuStok — GET /kartu-stok (idProduk + rentang WAJIB) → page.
func (h *laporanHandler) kartuStok(c echo.Context) error {
	pr, err := errkontrak.ParsePageRequest(c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.svc.KartuStok(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return page(c, out)
}

// expiring — GET /expiring?idGudang= → { data }; id invalid → diabaikan.
func (h *laporanHandler) expiring(c echo.Context) error {
	idGudang := angkaQueryOpsionalInteger(c.QueryParam("idGudang"))
	data, err := h.svc.Expiring(c.Request().Context(), idGudang)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// nilai — GET /nilai?kelompok= → { data }; kelompok invalid → kategori.
func (h *laporanHandler) nilai(c echo.Context) error {
	data, err := h.svc.Nilai(c.Request().Context(), c.QueryParam("kelompok"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// backlog — GET /backlog → { data }.
func (h *laporanHandler) backlog(c echo.Context) error {
	data, err := h.svc.Backlog(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// reorder — GET /reorder → { data }.
func (h *laporanHandler) reorder(c echo.Context) error {
	data, err := h.svc.Reorder(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// lapisanBiaya — GET /lapisan-biaya (idInvProduk WAJIB — dua pesan) → page.
func (h *laporanHandler) lapisanBiaya(c echo.Context) error {
	pr, err := errkontrak.ParsePageRequest(c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.svc.LapisanBiaya(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return page(c, out)
}

// kpi — GET /kpi (periode wajib; zod kpiQuerySchema) → page 4 baris fixed.
func (h *laporanHandler) kpi(c echo.Context) error {
	// Layer zod-ekuivalen kpiQuerySchema (controller): field wajib + refine
	// tanggalSampai > tanggalDari (string compare) — gagal → 400 VAL-400.
	q := c.Request().URL.Query()
	issues := validasiKPIQueryZod(q)
	if len(issues) > 0 {
		return errkontrak.Map(c, errkontrak.Validation(issues))
	}
	pr, err := errkontrak.ParsePageRequest(q)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.svc.KPI(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return page(c, out)
}

// traceability — GET /traceability (minimal satu id; zod
// traceabilityQuerySchema; lot menang atas produk) → page.
func (h *laporanHandler) traceability(c echo.Context) error {
	q := c.Request().URL.Query()

	// Koersi id numerik sebelum zod (controller): ""/absen → undefined.
	idProduk, idLot, issues := validasiTraceIDZod(q)
	if len(issues) > 0 {
		return errkontrak.Map(c, errkontrak.Validation(issues))
	}
	pr, err := errkontrak.ParsePageRequest(q)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	out, err := h.svc.Traceability(c.Request().Context(), pr, idProduk, idLot)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return page(c, out)
}

// ---------------------------------------------------------------------
// Validasi zod-ekuivalen (pesan persis packages/schemas inv/schemas.ts)
// ---------------------------------------------------------------------

// validasiKPIQueryZod — kpiQuerySchema = { tanggalDari: z.string().min(1),
// tanggalSampai: z.string().min(1) } + refine(sampai > dari, "Tanggal
// sampai harus setelah tanggal dari." path tanggalSampai). Urutan issues
// zod: field object dulu (tanggalDari → tanggalSampai), refine hanya bila
// base valid.
func validasiKPIQueryZod(q map[string][]string) []errkontrak.FieldIssue {
	var issues []errkontrak.FieldIssue

	// tanggalSchema = z.string().min(1) — wajib (undefined → "Required";
	// "" → pesan min verbatim zod 3.25).
	dari, adaDari := q["tanggalDari"]
	sampai, adaSampai := q["tanggalSampai"]
	if !adaDari || len(dari) == 0 {
		issues = append(issues, fi("tanggalDari", "Required"))
	} else if dari[0] == "" {
		issues = append(issues, fi("tanggalDari", "Too small: expected string to have >=1 characters"))
	}
	if !adaSampai || len(sampai) == 0 {
		issues = append(issues, fi("tanggalSampai", "Required"))
	} else if sampai[0] == "" {
		issues = append(issues, fi("tanggalSampai", "Too small: expected string to have >=1 characters"))
	}

	// Refine hanya jalan bila base parse sukses (semantik zod).
	if len(issues) == 0 && sampai[0] <= dari[0] {
		issues = append(issues, fi("tanggalSampai", "Tanggal sampai harus setelah tanggal dari."))
	}
	return issues
}

// validasiTraceIDZod — koersi + traceabilityQuerySchema: idRefSchema =
// z.number().int().positive("Pilih salah satu opsi.") (nullish); tanggal
// tanggalSchema.nullish(). Refine minimal satu id → "Pilih minimal satu
// filter: produk atau lot." path idInvProduk. Return (idProduk, idLot, issues).
func validasiTraceIDZod(q map[string][]string) (*int64, *int64, []errkontrak.FieldIssue) {
	var issues []errkontrak.FieldIssue

	idProduk := idRefQuery(q, "idInvProduk", &issues)
	idLot := idRefQuery(q, "idInvLotSerial", &issues)

	// tanggalDari/tanggalSampai nullish — string().min(1) bila ada.
	for _, key := range []string{"tanggalDari", "tanggalSampai"} {
		if vals, ada := q[key]; ada && len(vals) > 0 && vals[0] == "" {
			issues = append(issues, fi(key, "Too small: expected string to have >=1 characters"))
		}
	}

	// Refine hanya bila field valid (semantik zod).
	if len(issues) == 0 && idProduk == nil && idLot == nil {
		issues = append(issues, fi("idInvProduk", "Pilih minimal satu filter: produk atau lot."))
	}
	return idProduk, idLot, issues
}

// idRefQuery — satu idRefSchema nullish: absen/"" → nil; NaN → "Invalid
// input: expected number, received nan"; pecahan → "Invalid input:
// expected int, received number"; < 1 → "Pilih salah satu opsi."
func idRefQuery(q map[string][]string, field string, issues *[]errkontrak.FieldIssue) *int64 {
	raw := angkaQueryOpsional(field, q, issues) // *float64 (NaN → issue)
	if raw == nil {
		return nil
	}
	f := *raw
	if f != float64(int64(f)) {
		*issues = append(*issues, fi(field, "Invalid input: expected int, received number"))
		return nil
	}
	if int64(f) < 1 {
		*issues = append(*issues, fi(field, "Pilih salah satu opsi."))
		return nil
	}
	n := int64(f)
	return &n
}

// angkaQueryOpsional — query string → *float64 semantik Number(): absen/"" →
// nil (nullish OK); bukan angka → issue "Invalid input: expected number,
// received nan" (NaN terdeteksi sebelum zod karena koersi controller).
func angkaQueryOpsional(field string, q map[string][]string, issues *[]errkontrak.FieldIssue) *float64 {
	vals, ada := q[field]
	if !ada || len(vals) == 0 || vals[0] == "" {
		return nil
	}
	f, err := strconv.ParseFloat(vals[0], 64)
	if err != nil {
		*issues = append(*issues, fi(field, "Invalid input: expected number, received nan"))
		return nil
	}
	return &f
}
