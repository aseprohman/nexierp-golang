// handler/atribut.go — endpoint HTTP fitur ATRIBUT varian + NILAI ATRIBUT
// modul inv (padanan AtributController + NilaiAtributController NestJS —
// patch 03; 7 endpoint /inventory/master/atribut + 2 endpoint
// /inventory/master/atributnilai). Validasi body = zod-parity
// atributCreateSchema / nilaiAtributCreateSchema (+ .partial() update).
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// daftarkanAtribut — pasang 9 route atribut+nilai (nilai ter-ber-param id
// pakai path terpisah `atributnilai` — kontrak verbatim sumber).
func daftarkanAtribut(api *echo.Group, d types.Deps) {
	h := &AtributHandler{svc: service.NewAtributService(d)}
	g := api.Group("/inventory/master/atribut", d.AuthGuard, d.RbacGuard)
	g.GET("", h.daftar)                // GET /inventory/master/atribut
	g.POST("", h.buat)                 // POST /inventory/master/atribut (201)
	g.GET("/:id", h.ambil)             // GET /inventory/master/atribut/:id
	g.PATCH("/:id", h.ubah)            // PATCH /inventory/master/atribut/:id
	g.DELETE("/:id", h.hapus)          // DELETE /inventory/master/atribut/:id
	g.GET("/:id/nilai", h.daftarNilai) // GET /inventory/master/atribut/:id/nilai
	g.POST("/:id/nilai", h.buatNilai)  // POST /inventory/master/atribut/:id/nilai (201)
	gn := api.Group("/inventory/master/atributnilai", d.AuthGuard, d.RbacGuard)
	gn.PATCH("/:id", h.ubahNilai)   // PATCH /inventory/master/atributnilai/:id
	gn.DELETE("/:id", h.hapusNilai) // DELETE /inventory/master/atributnilai/:id
}

// AtributHandler — dependensi handler atribut+nilai.
type AtributHandler struct {
	svc *service.AtributService
}

// daftar — GET /inventory/master/atribut — halaman atribut varian.
func (h *AtributHandler) daftar(c echo.Context) error {
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

// buat — POST /inventory/master/atribut — 201 {data}.
func (h *AtributHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbAtributCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ambil — GET /inventory/master/atribut/:id — {data}.
func (h *AtributHandler) ambil(c echo.Context) error {
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

// ubah — PATCH /inventory/master/atribut/:id — version WAJIB di body.
func (h *AtributHandler) ubah(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbAtributUpdate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Update(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// hapus — DELETE /inventory/master/atribut/:id — {data:{ok:true}}.
func (h *AtributHandler) hapus(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.svc.Remove(c.Request().Context(), id, mbActor(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* ---------------- Nilai atribut ---------------- */

// daftarNilai — GET /inventory/master/atribut/:id/nilai — array urut
// urutan (BUKAN Page — kontrak verbatim).
func (h *AtributHandler) daftarNilai(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	rows, err := h.svc.ListNilai(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, rows)
}

// buatNilai — POST /inventory/master/atribut/:id/nilai — 201 {data}.
func (h *AtributHandler) buatNilai(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbNilaiCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.CreateNilai(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ubahNilai — PATCH /inventory/master/atributnilai/:id — {data}.
func (h *AtributHandler) ubahNilai(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbNilaiUpdate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.UpdateNilai(c.Request().Context(), id, in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// hapusNilai — DELETE /inventory/master/atributnilai/:id — {data:{ok:true}}.
func (h *AtributHandler) hapusNilai(c echo.Context) error {
	id, err := mbIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.svc.RemoveNilai(c.Request().Context(), id, mbActor(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

/* -------------------------------------------------------------- */
/* Validasi zod-parity                                             */
/* -------------------------------------------------------------- */

// mbAtributCreate — atributCreateSchema (urutan: kode, nama, tipeInput,
// status).
func mbAtributCreate(m map[string]any) (service.AtributCreateInput, []errkontrak.FieldIssue) {
	var in service.AtributCreateInput
	issues := []errkontrak.FieldIssue{}

	kode, _ := mbZodString(m, "kode", 1, 50, reKodeInv, "Kode: huruf/angka/. _ -", "Kode atribut wajib.", true, false, &issues)
	in.Kode = kode

	nama, _ := mbZodString(m, "nama", 1, 100, nil, "", "Nama atribut wajib.", true, false, &issues)
	in.Nama = nama

	if s, terisi := mbZodEnum(m, "tipeInput", enumTipeAtribut, true, &issues); terisi {
		in.TipeInput = s
	} else {
		in.TipeInput = "PILIHAN" // z.enum(TIPE_ATRIBUT).default("PILIHAN")
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	} else {
		in.Status = "AKTIF"
	}
	return in, issues
}

// mbAtributUpdate — atributUpdateSchema = create.partial() + version wajib.
func mbAtributUpdate(m map[string]any) (service.AtributUpdateInput, []errkontrak.FieldIssue) {
	var in service.AtributUpdateInput
	issues := []errkontrak.FieldIssue{}

	if v, ada := mbZodString(m, "nama", 1, 100, nil, "", "Nama atribut wajib.", false, false, &issues); ada {
		s := v
		in.Nama = &s
	}
	if s, terisi := mbZodEnum(m, "tipeInput", enumTipeAtribut, true, &issues); terisi {
		in.TipeInput = s
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	}
	in.Version = mbVersion(m, &issues)
	return in, issues
}

// mbNilaiCreate — nilaiAtributCreateSchema (urutan: idInvAtribut, nilai,
// urutan, status; idInvAtribut divalidasi tapi TIDAK dipakai service —
// verbatim sumber memakai param path).
func mbNilaiCreate(m map[string]any) (service.NilaiCreateInput, []errkontrak.FieldIssue) {
	var in service.NilaiCreateInput
	issues := []errkontrak.FieldIssue{}

	in.IDInvAtribut = mbZodIDWajib(m, "idInvAtribut", &issues)

	nilai, _ := mbZodString(m, "nilai", 1, 100, nil, "", "Nilai wajib.", true, false, &issues)
	in.Nilai = nilai

	if v, _ := mbZodInt(m, "urutan", 0, 1<<62-1, "Qty harus bilangan bulat", "", "", false, &issues); v != nil {
		in.Urutan = *v
	} else {
		in.Urutan = 0 // qtySchema.min(0).default(0)
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	} else {
		in.Status = "AKTIF"
	}
	return in, issues
}

// mbNilaiUpdate — nilaiAtributUpdateSchema = create.partial() + version
// wajib (idInvAtribut ikut .partial() — divalidasi, TIDAK dipakai).
func mbNilaiUpdate(m map[string]any) (service.NilaiUpdateInput, []errkontrak.FieldIssue) {
	var in service.NilaiUpdateInput
	issues := []errkontrak.FieldIssue{}

	mbZodID(m, "idInvAtribut", &issues)

	if v, ada := mbZodString(m, "nilai", 1, 100, nil, "", "Nilai wajib.", false, false, &issues); ada {
		s := v
		in.Nilai = &s
	}
	if v, ada := mbZodInt(m, "urutan", 0, 1<<62-1, "Qty harus bilangan bulat", "", "", false, &issues); ada {
		in.Urutan = v
	}
	if s, terisi := mbZodEnum(m, "status", enumStatusAktif, true, &issues); terisi {
		in.Status = s
	}
	in.Version = mbVersion(m, &issues)
	return in, issues
}
