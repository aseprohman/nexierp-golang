// handler/jenis_operasi.go — endpoint HTTP fitur JENIS OPERASI modul inv
// (padanan JenisOperasiController NestJS — patch 04 P1 #8; CRUD
// /inventory/master/jenis-operasi, 5 endpoint). Validasi body = zod-parity
// jenisOperasiCreateSchema (CHECK langkah 1..3 + 2 refine verbatim) /
// jenisOperasiUpdateSchema (TANPA refine — quirk .partial()).
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// daftarkanJenisOperasi — pasang 5 route jenis operasi.
func daftarkanJenisOperasi(api *echo.Group, d types.Deps) {
	h := &JenisOperasiHandler{svc: service.NewJenisOperasiService(d)}
	g := api.Group("/inventory/master/jenis-operasi", d.AuthGuard, d.RbacGuard)
	g.GET("", h.daftar)       // GET /inventory/master/jenis-operasi
	g.POST("", h.buat)        // POST /inventory/master/jenis-operasi (201)
	g.GET("/:id", h.ambil)    // GET /inventory/master/jenis-operasi/:id
	g.PATCH("/:id", h.ubah)   // PATCH /inventory/master/jenis-operasi/:id
	g.DELETE("/:id", h.hapus) // DELETE /inventory/master/jenis-operasi/:id
}

// JenisOperasiHandler — dependensi handler jenis operasi.
type JenisOperasiHandler struct {
	svc *service.JenisOperasiService
}

// daftar — GET /inventory/master/jenis-operasi — halaman jenis operasi.
func (h *JenisOperasiHandler) daftar(c echo.Context) error {
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

// buat — POST /inventory/master/jenis-operasi — 201 {data}.
func (h *JenisOperasiHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbJenisOperasiCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ambil — GET /inventory/master/jenis-operasi/:id — {data}.
func (h *JenisOperasiHandler) ambil(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.svc.Get(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// ubah — PATCH /inventory/master/jenis-operasi/:id — version WAJIB di body.
func (h *JenisOperasiHandler) ubah(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbJenisOperasiUpdate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Update(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// hapus — DELETE /inventory/master/jenis-operasi/:id — {data:{ok:true}}.
func (h *JenisOperasiHandler) hapus(c echo.Context) error {
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
/* Validasi zod-parity jenisOperasiCreateSchema                    */
/* -------------------------------------------------------------- */

// mbJenisOperasiBase — field dasar create (pesan & urutan verbatim).
func mbJenisOperasiBase(m map[string]any, issues *[]errkontrak.FieldIssue) (
	kode, nama, jenisGerakan, prefix string,
	jumlahLangkah int64,
	namaLangkah1 string,
	namaLangkah2, namaLangkah3 *string,
	idLokasiSumberDefault, idLokasiTujuanDefault *int64,
	status string,
) {
	kode, _ = mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode jenis operasi wajib.", true, false, issues)
	nama, _ = mbZodString(m, "nama", 1, 100, nil, "", "Nama jenis operasi wajib.", true, false, issues)
	jenisGerakan, _ = mbZodEnum(m, "jenisGerakan", enumJenisGerakan, false, issues)
	prefix, _ = mbZodString(m, "prefix", 1, 20, nil, "", "Prefix penomoran wajib.", true, false, issues)
	if v, _ := mbZodInt(m, "jumlahLangkah", 1, 3, "Qty harus bilangan bulat", "Minimal 1 langkah.", "Maksimal 3 langkah.", false, issues); v != nil {
		jumlahLangkah = *v
	} else {
		jumlahLangkah = 1 // z.number().int()...default(1)
	}
	// namaLangkah1: .default("Input") — absen → "Input"; null/"" → issue.
	var nl1Ada bool
	namaLangkah1, nl1Ada = mbZodString(m, "namaLangkah1", 1, 100, nil, "", "", false, false, issues)
	if _, keyAda := m["namaLangkah1"]; !keyAda && !nl1Ada {
		namaLangkah1 = "Input"
	}
	namaLangkah2, _ = mbZodStringPtr(m, "namaLangkah2", 0, 100, true, issues)
	namaLangkah3, _ = mbZodStringPtr(m, "namaLangkah3", 0, 100, true, issues)
	idLokasiSumberDefault, _ = mbZodID(m, "idLokasiSumberDefault", issues)
	idLokasiTujuanDefault, _ = mbZodID(m, "idLokasiTujuanDefault", issues)
	status, _ = mbZodEnum(m, "status", enumStatusAktif, true, issues)
	if status == "" {
		status = "AKTIF"
	}
	return
}

// mbJenisOperasiCreate — create-schema + 2 refine verbatim (berjalan
// SETELAH semua field checks lolos — urutan issue zod).
func mbJenisOperasiCreate(m map[string]any) (service.JenisOperasiCreateInput, []errkontrak.FieldIssue) {
	var in service.JenisOperasiCreateInput
	issues := []errkontrak.FieldIssue{}

	kode, nama, jenisGerakan, prefix, jumlahLangkah, namaLangkah1, namaLangkah2, namaLangkah3, idSumber, idTujuan, status :=
		mbJenisOperasiBase(m, &issues)

	in.Kode = kode
	in.Nama = nama
	in.JenisGerakan = jenisGerakan
	in.Prefix = prefix
	in.JumlahLangkah = jumlahLangkah
	in.NamaLangkah1 = namaLangkah1
	in.NamaLangkah2 = namaLangkah2
	in.NamaLangkah3 = namaLangkah3
	in.IDLokasiSumberDefault = idSumber
	in.IDLokasiTujuanDefault = idTujuan
	in.Status = status

	if len(issues) == 0 {
		// refine 1: jumlahLangkah ≥ 2 → namaLangkah2 terisi non-kosong.
		if in.JumlahLangkah >= 2 && (in.NamaLangkah2 == nil || len([]rune(*in.NamaLangkah2)) == 0) {
			issues = append(issues, errkontrak.FieldIssue{
				Field:   "namaLangkah2",
				Message: "Nama langkah 2 wajib bila jumlah langkah ≥ 2.",
			})
		}
		// refine 2: jumlahLangkah = 3 → namaLangkah3 terisi non-kosong.
		if in.JumlahLangkah >= 3 && (in.NamaLangkah3 == nil || len([]rune(*in.NamaLangkah3)) == 0) {
			issues = append(issues, errkontrak.FieldIssue{
				Field:   "namaLangkah3",
				Message: "Nama langkah 3 wajib bila jumlah langkah = 3.",
			})
		}
	}
	return in, issues
}

// mbJenisOperasiUpdate — jenisOperasiUpdateSchema = base.partial() + version
// wajib (TANPA refine langkah — quirk zod .partial(), verbatim sumber).
func mbJenisOperasiUpdate(m map[string]any) (service.JenisOperasiUpdateInput, []errkontrak.FieldIssue) {
	var in service.JenisOperasiUpdateInput
	issues := []errkontrak.FieldIssue{}

	// partial: semua field opsional; string null → invalid_type.
	if v, ada := mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode jenis operasi wajib.", false, false, &issues); ada {
		s := v
		in.Kode = &s
	}
	if v, ada := mbZodString(m, "nama", 1, 100, nil, "", "Nama jenis operasi wajib.", false, false, &issues); ada {
		s := v
		in.Nama = &s
	}
	if s, terisi := mbZodEnum(m, "jenisGerakan", enumJenisGerakan, true, &issues); terisi {
		in.JenisGerakan = s
	}
	if v, ada := mbZodString(m, "prefix", 1, 20, nil, "", "Prefix penomoran wajib.", false, false, &issues); ada {
		s := v
		in.Prefix = &s
	}
	if v, ada := mbZodInt(m, "jumlahLangkah", 1, 3, "Qty harus bilangan bulat", "Minimal 1 langkah.", "Maksimal 3 langkah.", false, &issues); ada {
		in.JumlahLangkah = v
	}
	if v, ada := mbZodString(m, "namaLangkah1", 1, 100, nil, "", "", false, false, &issues); ada {
		s := v
		in.NamaLangkah1 = &s
	}
	if v, ada := mbZodStringPtr(m, "namaLangkah2", 0, 100, true, &issues); ada {
		in.NamaLangkah2, in.NamaLangkah2Ada = v, true
	}
	if v, ada := mbZodStringPtr(m, "namaLangkah3", 0, 100, true, &issues); ada {
		in.NamaLangkah3, in.NamaLangkah3Ada = v, true
	}
	if v, ada := mbZodID(m, "idLokasiSumberDefault", &issues); ada {
		in.IDLokasiSumberDefault, in.IDLokasiSumberDefaultAda = v, true
	}
	if v, ada := mbZodID(m, "idLokasiTujuanDefault", &issues); ada {
		in.IDLokasiTujuanDefault, in.IDLokasiTujuanDefaultAda = v, true
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	}
	in.Version = mbVersion(m, &issues)
	return in, issues
}
