// handler/lokasi.go — endpoint HTTP fitur LOKASI STOK modul inv (padanan
// LokasiController NestJS — CRUD /inventory/master/lokasi, 5 endpoint;
// baca/ubah/hapus ter-scope dimensi 'storages' via gudang induk di service).
// Validasi body = zod-parity lokasiStokCreateSchema (refine INTERNAL wajib
// gudang verbatim) / lokasiStokUpdateSchema.
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// daftarkanLokasi — pasang 5 route lokasi.
func daftarkanLokasi(api *echo.Group, d types.Deps) {
	h := &LokasiHandler{svc: service.NewLokasiService(d)}
	g := api.Group("/inventory/master/lokasi", d.AuthGuard, d.RbacGuard)
	g.GET("", h.daftar)       // GET /inventory/master/lokasi
	g.POST("", h.buat)        // POST /inventory/master/lokasi (201)
	g.GET("/:id", h.ambil)    // GET /inventory/master/lokasi/:id
	g.PATCH("/:id", h.ubah)   // PATCH /inventory/master/lokasi/:id
	g.DELETE("/:id", h.hapus) // DELETE /inventory/master/lokasi/:id
}

// LokasiHandler — dependensi handler lokasi.
type LokasiHandler struct {
	svc *service.LokasiService
}

// daftar — GET /inventory/master/lokasi — halaman lokasi (ter-scope).
func (h *LokasiHandler) daftar(c echo.Context) error {
	pr, err := mbPageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svc.List(c.Request().Context(), pr, mbUserID(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// buat — POST /inventory/master/lokasi — 201 {data}.
func (h *LokasiHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbLokasiCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ambil — GET /inventory/master/lokasi/:id — {data} (404 di luar cakupan).
func (h *LokasiHandler) ambil(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.svc.Get(c.Request().Context(), id, mbUserID(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// ubah — PATCH /inventory/master/lokasi/:id — version WAJIB di body.
func (h *LokasiHandler) ubah(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbLokasiUpdate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Update(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// hapus — DELETE /inventory/master/lokasi/:id — {data:{ok:true}}.
func (h *LokasiHandler) hapus(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.svc.Remove(c.Request().Context(), id, mbActor(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* -------------------------------------------------------------- */
/* Validasi zod-parity lokasiStokCreateSchema                      */
/* -------------------------------------------------------------- */

// mbLokasiCreate — pesan & urutan issue persis skema + refine INTERNAL
// wajib gudang (pesan "Lokasi INTERNAL wajib punya gudang induk." path
// idInvGudang — verbatim).
func mbLokasiCreate(m map[string]any) (service.LokasiCreateInput, []errkontrak.FieldIssue) {
	var in service.LokasiCreateInput
	issues := []errkontrak.FieldIssue{}

	kode, _ := mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode lokasi wajib.", true, false, &issues)
	in.Kode = kode

	nama, _ := mbZodString(m, "nama", 1, 100, nil, "", "Nama lokasi wajib.", true, false, &issues)
	in.Nama = nama

	if s, terisi := mbZodEnum(m, "jenis", enumJenisLokasi, true, &issues); terisi {
		in.Jenis = s
	} else {
		in.Jenis = "INTERNAL" // z.enum(JENIS_LOKASI).default("INTERNAL")
	}
	if v, _ := mbZodID(m, "idInvGudang", &issues); v != nil {
		in.IDInvGudang = v
	}
	if v, _ := mbZodID(m, "idLokasiInduk", &issues); v != nil {
		in.IDLokasiInduk = v
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	} else {
		in.Status = "AKTIF"
	}
	// refine: jenis !== "INTERNAL" || idInvGudang != null — berjalan SETELAH
	// semua field checks lolos (urutan issue zod).
	if in.Jenis == "INTERNAL" && in.IDInvGudang == nil && len(issues) == 0 {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "idInvGudang",
			Message: "Lokasi INTERNAL wajib punya gudang induk.",
		})
	}
	return in, issues
}

// mbLokasiUpdate — lokasiStokUpdateSchema = base.partial() + version wajib
// (TANPA refine — quirk zod .partial(); guard INV-003 hidup di service).
func mbLokasiUpdate(m map[string]any) (service.LokasiUpdateInput, []errkontrak.FieldIssue) {
	var in service.LokasiUpdateInput
	issues := []errkontrak.FieldIssue{}

	if v, ada := mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode lokasi wajib.", false, false, &issues); ada {
		// kode divalidasi tapi tidak dipakai (quirk verbatim service).
		_ = v
	}
	if v, ada := mbZodString(m, "nama", 1, 100, nil, "", "Nama lokasi wajib.", false, false, &issues); ada {
		s := v
		in.Nama = &s
	}
	if s, terisi := mbZodEnum(m, "jenis", enumJenisLokasi, true, &issues); terisi {
		in.Jenis = s
	}
	if v, ada := mbZodID(m, "idInvGudang", &issues); ada {
		in.IDInvGudang, in.IDInvGudangAda = v, true
	}
	if v, ada := mbZodID(m, "idLokasiInduk", &issues); ada {
		in.IDLokasiInduk, in.IDLokasiIndukAda = v, true
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	}
	in.Version = mbVersion(m, &issues)
	return in, issues
}
