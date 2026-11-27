// handler/lot.go — endpoint HTTP fitur LOT/SERIAL modul inv (padanan
// LotController NestJS — daftar/detail/buat manual, 3 endpoint
// /inventory/master/lot). Validasi body = zod-parity lotSerialCreateSchema
// (refine kedaluwarsa > prodiksi lexicographic verbatim).
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// daftarkanLot — pasang 3 route lot.
func daftarkanLot(api *echo.Group, d types.Deps) {
	h := &LotHandler{svc: service.NewLotService(d)}
	g := api.Group("/inventory/master/lot", d.AuthGuard, d.RbacGuard)
	g.GET("", h.daftar)    // GET /inventory/master/lot
	g.POST("", h.buat)     // POST /inventory/master/lot (201)
	g.GET("/:id", h.ambil) // GET /inventory/master/lot/:id
}

// LotHandler — dependensi handler lot.
type LotHandler struct {
	svc *service.LotService
}

// daftar — GET /inventory/master/lot — halaman lot.
func (h *LotHandler) daftar(c echo.Context) error {
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

// buat — POST /inventory/master/lot — buat lot manual (201 {data}).
func (h *LotHandler) buat(c echo.Context) error {
	m, ok := mbDecodeBody(c)
	if !ok {
		return mbBadBody(c, nil)
	}
	in, issues := mbLotCreate(m)
	if len(issues) > 0 {
		return mbGagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, mbActor(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// ambil — GET /inventory/master/lot/:id — {data} (saldo dari readmodel).
func (h *LotHandler) ambil(c echo.Context) error {
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

/* -------------------------------------------------------------- */
/* Validasi zod-parity lotSerialCreateSchema                       */
/* -------------------------------------------------------------- */

// mbLotCreate — pesan & urutan issue persis skema + refine kedaluwarsa >
// prodiksi (perbandingan STRING verbatim JS; hanya bila keduanya terisi).
func mbLotCreate(m map[string]any) (service.LotCreateInput, []errkontrak.FieldIssue) {
	var in service.LotCreateInput
	issues := []errkontrak.FieldIssue{}

	in.IDInvProduk = mbZodIDWajib(m, "idInvProduk", &issues)

	kode, _ := mbZodString(m, "kode", 1, 100, nil, "", "Kode lot/serial wajib.", true, false, &issues)
	in.Kode = kode

	if v, ada := mbZodString(m, "barcode", 0, 50, nil, "", "", false, true, &issues); ada {
		s := v
		in.Barcode = &s
	}
	// tanggalProdiksi/Kedaluwarsa: z.string().min(1) — TANPA trim (verbatim).
	if v, ada := m["tanggalProdiksi"]; ada && v != nil {
		if s, isStr := v.(string); isStr {
			if len([]rune(s)) < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "tanggalProdiksi", Message: mbMsgMinString(1)})
			}
			t := s
			in.TanggalProdiksi = &t
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "tanggalProdiksi", Message: mbMsgBukan("string", mbNamaTipeJSON(v))})
		}
	}
	if v, ada := m["tanggalKedaluwarsa"]; ada && v != nil {
		if s, isStr := v.(string); isStr {
			if len([]rune(s)) < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "tanggalKedaluwarsa", Message: mbMsgMinString(1)})
			}
			t := s
			in.TanggalKedaluwarsa = &t
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "tanggalKedaluwarsa", Message: mbMsgBukan("string", mbNamaTipeJSON(v))})
		}
	}
	// refine: !kedaluwarsa || !prodiksi || kedaluwarsa > prodiksi — setelah
	// field checks (urutan issue zod).
	if in.TanggalKedaluwarsa != nil && in.TanggalProdiksi != nil &&
		*in.TanggalKedaluwarsa <= *in.TanggalProdiksi && len(issues) == 0 {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "tanggalKedaluwarsa",
			Message: "Tanggal kedaluwarsa harus setelah tanggal produksi.",
		})
	}
	return in, issues
}
