// handler/gerakan.go — permukaan HTTP murni fitur GERAKAN STOK modul inv
// (padanan controllers/operasi/gerakan.controller.ts NestJS — 7 endpoint):
//
//	GET  /inventory/operasi/gerakan                 — Page<GerakanStokView>
//	POST /inventory/operasi/gerakan                 — buat (nomor server)
//	GET  /inventory/operasi/gerakan/:id             — detail
//	POST /inventory/operasi/gerakan/:id/konfirmasi  — sebagian/selesai (1 tx)
//	POST /inventory/operasi/gerakan/:id/batal       — alasan wajib (STD-06)
//	POST /inventory/operasi/gerakan/:id/reservasi   — reservasi picking D-29
//	POST /inventory/operasi/gerakan/:id/batal-reservasi
//
// Alur: bind → validasi zod-ekuivalen (pesan VERBATIM schemas packages,
// helper mb* masterb.go) → delegasi service → pemetaan error errkontrak
// (problem+json): DomainError kode INV-xxx; race 23505 → 409 CONF-409
// verbatim (kernel errkontrak.Map); sisanya 500 SYS-000.
package handler

import (
	"math"
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanGerakan — pasang 7 route gerakan di group /api (koordinator
// memanggil dari DaftarkanOperasi).
func DaftarkanGerakan(api *echo.Group, d types.Deps) {
	svc := service.NewGerakanService(d.DB, d.Audit, d.Outbox, d.Numbering, d.ModCfg)
	h := &gerakanHandler{svc: svc}

	g := api.Group("/inventory/operasi/gerakan", d.AuthGuard, d.RbacGuard)
	g.GET("", h.list)
	g.POST("", h.buat)
	g.GET("/:id", h.ambil)
	g.POST("/:id/konfirmasi", h.konfirmasi)
	g.POST("/:id/batal", h.batal)
	g.POST("/:id/reservasi", h.reservasi)
	g.POST("/:id/batal-reservasi", h.batalReservasi)
}

// gerakanHandler — dependensi handler gerakan.
type gerakanHandler struct {
	svc *service.GerakanService
}

// konteksMutasi — padanan mutationCtx(user, req): aktor dari JWT
// (auth.From), IP & UA dari request (fallback "-" / "unknown").
func konteksMutasi(c echo.Context) service.MutationContext {
	var aktor *rbac.AuthenticatedUser
	if u := auth.From(c); u != nil {
		aktor = &rbac.AuthenticatedUser{ID: u.ID, Username: u.Username, SessionID: u.SessionID}
	}
	return service.MutationContext{
		Actor:     aktor,
		IPAddress: mbIPOf(c.Request()),
		UserAgent: mbUAOf(c.Request()),
	}
}

// =====================================================================
// Endpoint
// =====================================================================

// list — GET "" — halaman gerakan (filter jenis/status/idProduk/idGudang +
// search nomor): envelope {data, meta} ATAS (padanan return Page langsung).
func (h *gerakanHandler) list(c echo.Context) error {
	pr, err := mbPageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svc.List(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// buat — POST "" — buat gerakan manual (nomor via penomoran): 201 {data}.
func (h *gerakanHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := gkValidasiCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, konteksMutasi(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusCreated, map[string]any{"data": view})
}

// ambil — GET "/:id" — detail gerakan: {data}.
func (h *gerakanHandler) ambil(c echo.Context) error {
	view, err := h.svc.Get(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// konfirmasi — POST "/:id/konfirmasi" — parsial (SEBAGIAN) atau tuntas
// (SELESAI): satu UoW saldo+audit+outbox. 200 {data}.
func (h *gerakanHandler) konfirmasi(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := gkValidasiKonfirmasi(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Konfirmasi(c.Request().Context(), c.Param("id"), in, konteksMutasi(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// batal — POST "/:id/batal" — alasan wajib (STD-06): 200 {data}.
func (h *gerakanHandler) batal(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	alasan, issues := gkValidasiBatal(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Batal(c.Request().Context(), c.Param("id"), alasan, konteksMutasi(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// reservasi — POST "/:id/reservasi" — cukup saldo efektif → TERRESERVASI.
func (h *gerakanHandler) reservasi(c echo.Context) error {
	view, err := h.svc.Reservasi(c.Request().Context(), c.Param("id"), konteksMutasi(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// batalReservasi — POST "/:id/batal-reservasi" — reservasi dilepas.
func (h *gerakanHandler) batalReservasi(c echo.Context) error {
	view, err := h.svc.BatalReservasi(c.Request().Context(), c.Param("id"), konteksMutasi(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// =====================================================================
// Validasi body — zod-ekuivalen (pesan VERBATIM gerakanCreateSchema /
// gerakanKonfirmasiSchema / gerakanBatalSchema packages/schemas)
// =====================================================================

// gkOpsiJenis — opsi z.enum(JENIS_GERAKAN) urut deklarasi tipe.ts (persis).
var gkOpsiJenis = []string{
	"PENERIMAAN", "PENGIRIMAN", "TRANSFER_INTERNAL", "PRODUKSI", "SCRAP", "PENYESUAIAN",
}

// gkOpsiStatusAwal — opsi z.enum(["DRAFT","TERJADWAL","MENUNGGU_STOK"]).
var gkOpsiStatusAwal = []string{"DRAFT", "TERJADWAL", "MENUNGGU_STOK"}

// gkValidasiCreate — gerakanCreateSchema (+refine sumber ≠ tujuan).
func gkValidasiCreate(m map[string]any) (service.BuatGerakanInput, []errkontrak.FieldIssue) {
	var in service.BuatGerakanInput
	issues := []errkontrak.FieldIssue{}

	// jenis: z.enum(JENIS_GERAKAN) — wajib.
	in.Jenis, _ = mbZodEnum(m, "jenis", gkOpsiJenis, false, &issues)

	// idInvProduk / idInvUnitUkur / idLokasiSumber / idLokasiTujuan:
	// idRefSchema wajib.
	in.IDInvProduk = mbZodIDWajib(m, "idInvProduk", &issues)
	in.IDInvUnitUkur = mbZodIDWajib(m, "idInvUnitUkur", &issues)
	in.IDLokasiSumber = mbZodIDWajib(m, "idLokasiSumber", &issues)
	in.IDLokasiTujuan = mbZodIDWajib(m, "idLokasiTujuan", &issues)

	// idInvLotSerial: idRefSchema.nullish().
	if lot, _ := mbZodID(m, "idInvLotSerial", &issues); lot != nil {
		in.IDInvLotSerial = lot
	}

	// qtyDiminta: qtySchema.positive("Qty diminta harus > 0.")
	if q, _ := mbZodInt(m, "qtyDiminta", 1, math.MaxInt64,
		"Qty harus bilangan bulat", "Qty diminta harus > 0.", "", true, &issues); q != nil {
		in.QtyDiminta = *q
	}

	// tanggalJadwal: tanggalSchema.nullish() (string min 1).
	if t, _ := mbZodStringPtr(m, "tanggalJadwal", 1, math.MaxInt, true, &issues); t != nil {
		in.TanggalJadwal = t
	}

	// jenisSumber: z.string().trim().max(50).default("MANUAL").
	if js, ada := mbZodString(m, "jenisSumber", 0, 50, nil, "", "", false, false, &issues); ada {
		in.JenisSumber = js
	} else {
		in.JenisSumber = "MANUAL"
	}

	// entityIdSumber: z.string().trim().max(255).nullish().
	if e, _ := mbZodStringPtr(m, "entityIdSumber", 0, 255, true, &issues); e != nil {
		in.EntityIDSumber = e
	}

	// status: z.enum([...]).default("TERJADWAL").
	if st, ada := mbZodEnum(m, "status", gkOpsiStatusAwal, true, &issues); ada {
		in.Status = st
	} else {
		in.Status = "TERJADWAL"
	}

	// .refine: sumber ≠ tujuan — hanya bila validasi dasar lolos (zod).
	if len(issues) == 0 && in.IDLokasiSumber == in.IDLokasiTujuan {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "idLokasiTujuan",
			Message: "Lokasi sumber dan tujuan harus berbeda (INV-BR03).",
		})
	}
	return in, issues
}

// gkValidasiKonfirmasi — gerakanKonfirmasiSchema.
func gkValidasiKonfirmasi(m map[string]any) (service.KonfirmasiInput, []errkontrak.FieldIssue) {
	var in service.KonfirmasiInput
	issues := []errkontrak.FieldIssue{}

	// qtySelesai: qtySchema.positive("Qty selesai harus > 0.")
	//   .max(999_999_999, "Qty selesai melebihi qty diminta.")
	if q, _ := mbZodInt(m, "qtySelesai", 1, 999_999_999,
		"Qty harus bilangan bulat", "Qty selesai harus > 0.", "Qty selesai melebihi qty diminta.", true, &issues); q != nil {
		in.QtySelesai = *q
	}

	// idInvLotSerial: idRefSchema.nullish().
	if lot, _ := mbZodID(m, "idInvLotSerial", &issues); lot != nil {
		in.IDInvLotSerial = lot
	}

	// nilaiPersatuan: moneySchema.nullish() — min 0 / max 999_999_999_999
	// (pesan default zod).
	if n, _ := mbZodNumNullish(m, "nilaiPersatuan", 0, 999_999_999_999, "", "", &issues); n != nil {
		in.NilaiPersatuan = n
	}

	return in, issues
}

// gkValidasiBatal — gerakanBatalSchema: alasan trim min 3 (pesan kustom)
// max 300, wajib → alasan (string ter-trim).
func gkValidasiBatal(m map[string]any) (string, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	alasan, _ := mbZodString(m, "alasan", 3, 300, nil, "",
		"Alasan pembatalan wajib (min. 3 karakter).", true, false, &issues)
	return alasan, issues
}
