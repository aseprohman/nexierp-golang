// mastera_endpoint.go — endpoint HTTP keenam fitur MASTER-A (padanan isi
// controllers/master/*.controller.ts NestJS): parse (zod-parity) → service
// → envelope {data} / {data, meta} / problem+json. DaftarkanMasterA tetap
// satu pintu (mastera.go).
package handler

import (
	"net/http"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/shared"
)

/* ================================================================== */
/* PRODUK                                                             */
/* ================================================================== */

// hProdukList — GET /inventory/master/produk — Page<ProdukView>.
func hProdukList(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page) // { data, meta }
	}
}

// hProdukCreate — POST — 201 ProdukView.
func hProdukCreate(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in, varian := maParseProdukBuat(m, &issues)
		if varian != nil {
			in.Varian = varian
		}
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

// hProdukLookup — GET /lookup — ProdukLookupView[] (default 20, maks 200).
func hProdukLookup(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		q := c.QueryParams()
		// limit: Number(limit); absen/kosong/NaN → undefined (default 20).
		var limit *float64
		if raw := maFirstQuery(q, "limit"); raw != "" {
			limit = maNumStr(raw)
		}
		// kategori: parseIdParam(kategori, "kategori") bila diisi.
		var idKategori *int64
		if raw := maFirstQuery(q, "kategori"); raw != "" {
			id, err := shared.ParseIDParam(raw, "kategori")
			if err != nil {
				return errkontrak.Map(c, err)
			}
			idKategori = &id
		}
		rows, err := svc.Lookup(c.Request().Context(), maFirstQuery(q, "search"), maFirstQuery(q, "barcode"), limit, idKategori)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, rows)
	}
}

// hProdukGet — GET /:id — ProdukView (404 INV-018).
func hProdukGet(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

// hProdukUpdate — PATCH /:id — versi wajib (409 INV-017).
func hProdukUpdate(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseProdukUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

// hProdukRemove — DELETE /:id — {ok:true} (409 INV-002).
func hProdukRemove(svc *service.ProdukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

/* ================================================================== */
/* PRODUK INDUK                                                       */
/* ================================================================== */

func hIndukList(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

func hIndukCreate(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseIndukBuat(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hIndukGet(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hIndukUpdate(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseIndukUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hIndukRemove(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

// hIndukReplaceAtribut — PUT /:id/atribut — REPLACE konfigurasi (satu UoW).
func hIndukReplaceAtribut(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseIndukAtributReplace(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.ReplaceAtribut(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

// hIndukGenerateVarian — POST /:id/varian — 201 {dibuat:[...]} (409 INV-016).
func hIndukGenerateVarian(svc *service.ProdukIndukService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseVarianGenerate(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		out, err := svc.GenerateVarian(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, out)
	}
}

/* ================================================================== */
/* KATEGORI                                                           */
/* ================================================================== */

func hKategoriList(svc *service.KategoriService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

func hKategoriCreate(svc *service.KategoriService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKategoriBuat(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hKategoriGet(svc *service.KategoriService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKategoriUpdate(svc *service.KategoriService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKategoriUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKategoriRemove(svc *service.KategoriService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

/* ================================================================== */
/* UNIT                                                               */
/* ================================================================== */

func hUnitList(svc *service.UnitService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

func hUnitCreate(svc *service.UnitService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseUnitBuat(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hUnitGet(svc *service.UnitService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hUnitUpdate(svc *service.UnitService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseUnitUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hUnitRemove(svc *service.UnitService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

/* ================================================================== */
/* UNIT KONVERSI                                                      */
/* ================================================================== */

func hKonversiList(svc *service.UnitKonversiService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

func hKonversiCreate(svc *service.UnitKonversiService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKonversiBuat(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hKonversiGet(svc *service.UnitKonversiService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKonversiUpdate(svc *service.UnitKonversiService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKonversiUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKonversiRemove(svc *service.UnitKonversiService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

/* ================================================================== */
/* KEMASAN                                                            */
/* ================================================================== */

func hKemasanList(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := maPageReq(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

// hKemasanLookup — GET /lookup — barcode WAJIB (400 pesan verbatim).
func hKemasanLookup(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		barcode := maFirstQuery(c.QueryParams(), "barcode")
		if barcode == "" || strings.TrimSpace(barcode) == "" {
			// DomainError.validation (400 VAL-400) — pesan verbatim.
			return errkontrak.Map(c, errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "barcode", Message: "Parameter barcode wajib."},
			}))
		}
		view, err := svc.Lookup(c.Request().Context(), strings.TrimSpace(barcode))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKemasanCreate(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKemasanBuat(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hKemasanGet(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKemasanUpdate(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		m, ok := maDecodeBody(c)
		if !ok {
			return maGagalBody(c)
		}
		issues := []errkontrak.FieldIssue{}
		in := maParseKemasanUbah(m, &issues)
		if len(issues) > 0 {
			return maGagalValidasi(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hKemasanRemove(svc *service.KemasanService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := maParseID(c)
		if err != nil {
			return errkontrak.Map(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return errkontrak.Map(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}
