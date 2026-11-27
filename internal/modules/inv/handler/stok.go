// handler/stok.go — permukaan HTTP fitur STOK + PENGATURAN modul inv
// (padanan controllers/stok/saldo.controller.ts + controllers/pengaturan/
// pengaturan.controller.ts NestJS). TIPIS: parse query/body (validasi
// padanan zod v3 — pesan & urutan issue PERSIS) → service → envelope.
// Penegakan permission = ROUTE-CENTRIC (JwtAuthGuard + PermissionsGuard via
// core_routes).
//
//	GET  /inventory/stok/saldo            — Page<SaldoStokView> (filter)
//	POST /inventory/stok/saldo/recompute  — full rebuild READMODEL (200)
//	GET  /inventory/stok/saldo/atp?produkIds=1,2,3 — AtpItemView[] (CFG-INV-13)
//	GET  /inventory/pengaturan            — CfgInvView (12 param + pertanyaan)
//	PUT  /inventory/pengaturan            — simpan cfgInvValuesSchema (200)
package handler

import (
	"encoding/json"
	"io"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/service"
	"nexierp/internal/modules/inv/types"
)

// stokHandler — dependensi handler stok+pengaturan (service layer saja).
type stokHandler struct {
	svcSaldo *service.SaldoService
	svcCfg   *service.PengaturanService
}

// DaftarkanStok — pasang 5 route stok/pengaturan (path & method PERSIS
// controller NestJS) dengan guard JWT + RBAC.
func DaftarkanStok(api *echo.Group, d types.Deps) {
	h := &stokHandler{
		svcSaldo: service.NewSaldoService(d.DB, d.ModCfg),
		svcCfg:   service.NewPengaturanService(d.DB, d.Audit, d.ModCfg),
	}

	g := api.Group("", d.AuthGuard, d.RbacGuard)

	saldo := g.Group("/inventory/stok/saldo")
	saldo.GET("", h.listSaldo)
	saldo.POST("/recompute", h.recomputeSaldo)
	saldo.GET("/atp", h.atp)

	peng := g.Group("/inventory/pengaturan")
	peng.GET("", h.pengaturanGet)
	peng.PUT("", h.pengaturanPut)
}

// ---------------------------------------------------------------------
// Handler saldo
// ---------------------------------------------------------------------

// listSaldo — GET /inventory/stok/saldo: Page envelope di level atas
// ({data, meta} — persis controller NestJS yang mengembalikan Page apa adanya).
func (h *stokHandler) listSaldo(c echo.Context) error {
	pr, err := errkontrak.ParsePageRequest(c.Request().URL.Query())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svcSaldo.PageSaldo(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// recomputeSaldo — POST /inventory/stok/saldo/recompute: 200 {data} — full
// rebuild READMODEL (tanpa body; konteks hanya info, tanpa audit bisnis).
func (h *stokHandler) recomputeSaldo(c echo.Context) error {
	view, err := h.svcSaldo.Recompute(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// atp — GET /inventory/stok/saldo/atp?produkIds=1,2,3: {data: AtpItemView[]}
// sesuai CFG-INV-13 — maks 200 produk (INV-BR14).
func (h *stokHandler) atp(c echo.Context) error {
	data, err := h.svcSaldo.Atp(c.Request().Context(), c.QueryParam("produkIds"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// ---------------------------------------------------------------------
// Handler pengaturan
// ---------------------------------------------------------------------

// pengaturanGet — GET /inventory/pengaturan: {data: CfgInvView}.
func (h *stokHandler) pengaturanGet(c echo.Context) error {
	view, err := h.svcCfg.Get(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// pengaturanPut — PUT /inventory/pengaturan: validasi padanan
// cfgInvValuesSchema (12 field + superRefine dependensi, pesan & urutan
// issue zod PERSIS) → simpan → {data: CfgInvView} get() ulang.
func (h *stokHandler) pengaturanPut(c echo.Context) error {
	m, ok := stokDecodeBody(c)
	if !ok {
		return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid",
			[]errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}})
	}
	values, issues := validasiCfgInvValues(m)
	if len(issues) > 0 {
		// Padanan parseWith gagal: 400 VAL-400 detail "Data tidak valid.".
		return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
	}
	view, err := h.svcCfg.Put(c.Request().Context(), values, stokActor(c))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

/* ==================================================================
// Validasi padanan cfgInvValuesSchema (zod v3) — 12 field + superRefine:
//
//	"CFG-INV-01" enum CfgPelacakanOpsi      "CFG-INV-08" enum CfgApprovalOpsi
//	"CFG-INV-02" enum CfgKedaluwarsaOpsi    "CFG-INV-09" {ambangQty?, ambangNilai?}
//	"CFG-INV-03" enum CfgLangkahOpsi        "CFG-INV-10" enum CfgReorderOpsi
//	"CFG-INV-04" enum CfgLangkahOpsi        "CFG-INV-12" qtySchema.min(0).max(365)
//	"CFG-INV-05" enum CfgBackorderOpsi      "CFG-INV-13" enum CfgAtpOpsi
//	"CFG-INV-06" enum METODE_VALUASI        (+ CFG-INV-07 enum SISTEM_VALUASI)
//
// superRefine (hanya bila base lolos — urutan issue zod PERSIS):
//	- CFG-INV-02 != NONAKTIF && CFG-INV-01 == NONAKTIF → issue CFG-INV-02
//	- CFG-INV-08 == DI_ATAS_AMBANG && kedua ambang null → issue CFG-INV-09
// ================================================================== */

// stokCfgKodeEnum — pasangan field enum (urutan validasi ditangani eksplisit
// di validasiCfgInvValues — urutan bentuk objek zod CFG-INV-01..13).
var stokCfgKodeEnum = map[string][]string{
	"CFG-INV-01": service.CfgPelacakanOpsi,
	"CFG-INV-02": service.CfgKedaluwarsaOpsi,
	"CFG-INV-03": service.CfgLangkahOpsi,
	"CFG-INV-04": service.CfgLangkahOpsi,
	"CFG-INV-05": service.CfgBackorderOpsi,
	"CFG-INV-06": service.MetodeValuasiOpsi,
	"CFG-INV-07": service.SistemValuasiOpsi,
	"CFG-INV-08": service.CfgApprovalOpsi,
	"CFG-INV-10": service.CfgReorderOpsi,
	"CFG-INV-13": service.CfgAtpOpsi,
}

// validasiCfgInvValues — hasil (nilai per param siap SetValue, issues).
// nil + issues bila gagal (base ATAU superRefine). Urutan issue = urutan
// definisi field dalam objek zod (01..13 — 09 sebelum 10, 12 sebelum 13).
func validasiCfgInvValues(m map[string]any) (map[string]any, []errkontrak.FieldIssue) {
	var issues []errkontrak.FieldIssue
	vals := make(map[string]any, 12)

	enum := func(key string) {
		if s, ok := stokEnumField(m, key, stokCfgKodeEnum[key], &issues); ok {
			vals[key] = s
		}
	}

	// Urut bentuk objek zod: 01..08.
	for _, key := range []string{"CFG-INV-01", "CFG-INV-02", "CFG-INV-03", "CFG-INV-04",
		"CFG-INV-05", "CFG-INV-06", "CFG-INV-07", "CFG-INV-08"} {
		enum(key)
	}

	// "CFG-INV-09": z.object({ambangQty: qtySchema.min(0).nullable(),
	//                         ambangNilai: moneySchema.nullable()})
	ambangQty, ambangNilai, ok09 := stokCfgInv09(m, &issues)
	if ok09 {
		vals["CFG-INV-09"] = map[string]any{"ambangQty": stokNumAny(ambangQty), "ambangNilai": stokNumAny(ambangNilai)}
	}

	// "CFG-INV-10".
	enum("CFG-INV-10")

	// "CFG-INV-12": qtySchema.min(0).max(365) — number int wajib.
	if n := stokAngkaField(m, "CFG-INV-12", "CFG-INV-12", false, true, "Qty harus bilangan bulat",
		stokFptr(0), stokFptr(365), &issues); n != nil {
		vals["CFG-INV-12"] = *n
	}

	// "CFG-INV-13".
	enum("CFG-INV-13")

	// Base parse gagal → superRefine TIDAK dijalankan (semantik zod).
	if len(issues) > 0 {
		return nil, issues
	}

	// superRefine — dependensi antar opsi (INV-BR06), pesan VERBATIM.
	v01, _ := vals["CFG-INV-01"].(string)
	v02, _ := vals["CFG-INV-02"].(string)
	if v02 != "NONAKTIF" && v01 == "NONAKTIF" {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "CFG-INV-02",
			Message: "Kedaluwarsa (CFG-INV-02) hanya relevan bila pelacakan lot aktif (CFG-INV-01).",
		})
	}
	v08, _ := vals["CFG-INV-08"].(string)
	if v08 == "DI_ATAS_AMBANG" && ambangQty == nil && ambangNilai == nil {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "CFG-INV-09",
			Message: "Ambang qty atau ambang nilai wajib diisi bila mode approval 'di atas ambang'.",
		})
	}
	if len(issues) > 0 {
		return nil, issues
	}
	return vals, nil
}

// stokCfgInv09 — field objek ambang approval: (ambangQty, ambangNilai,
// objek sah?). null → nil (nullable lolos); field nested path
// "CFG-INV-09.<nama>" (padanan path issue zod join ".").
func stokCfgInv09(m map[string]any, issues *[]errkontrak.FieldIssue) (*float64, *float64, bool) {
	v, ada := m["CFG-INV-09"]
	if !ada {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "CFG-INV-09", Message: "Required"})
		return nil, nil, false
	}
	sub, ok := v.(map[string]any)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   "CFG-INV-09",
			Message: "Expected object, received " + stokNamaTipe(v),
		})
		return nil, nil, false
	}
	ambangQty := stokAngkaField(sub, "ambangQty", "CFG-INV-09.ambangQty", true, true,
		"Qty harus bilangan bulat", stokFptr(0), nil, issues)
	ambangNilai := stokAngkaField(sub, "ambangNilai", "CFG-INV-09.ambangNilai", true, false, "",
		stokFptr(0), stokFptr(999999999999), issues)
	return ambangQty, ambangNilai, true
}

// stokEnumField — z.enum(opts): absent → "Required"; bukan string →
// `Expected <opsi>, received <tipe>` (expected = daftar opsi ter-quote);
// string di luar opsi → `Invalid enum value. Expected <opsi>, received 'X'`.
func stokEnumField(m map[string]any, key string, opts []string, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: "Required"})
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   key,
			Message: "Expected " + stokQuoted(opts) + ", received " + stokNamaTipe(v),
		})
		return "", false
	}
	for _, o := range opts {
		if o == s {
			return s, true
		}
	}
	*issues = append(*issues, errkontrak.FieldIssue{
		Field:   key,
		Message: "Invalid enum value. Expected " + stokQuoted(opts) + ", received '" + s + "'",
	})
	return "", false
}

// stokAngkaField — z.number() dengan rantai cek urut zod: type → (int?)
// → min → max → finite. nullable: null lolos (nil). key = kunci lookup di m;
// path = field issue (nested "INDUK.anak" — padanan path zod join ".").
func stokAngkaField(m map[string]any, key, path string, nullable, cekInt bool, msgInt string, min, max *float64, issues *[]errkontrak.FieldIssue) *float64 {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: "Required"})
		return nil
	}
	if nullable && v == nil {
		return nil
	}
	n, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   path,
			Message: "Expected number, received " + stokNamaTipe(v),
		})
		return nil
	}
	if cekInt && n != math.Trunc(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: msgInt})
	}
	if min != nil && n < *min {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   path,
			Message: "Number must be greater than or equal to " + stokNumTxt(*min),
		})
	}
	if max != nil && n > *max {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   path,
			Message: "Number must be less than or equal to " + stokNumTxt(*max),
		})
	}
	if math.IsNaN(n) || math.IsInf(n, 0) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: "Number must be finite"})
	}
	return &n
}

// ---------------------------------------------------------------------
// Helper permukaan HTTP — prefix `stok` (pengaman kolisi nama dengan file
// fitur lain di package handler yang sama).
// ---------------------------------------------------------------------

// stokDecodeBody — baca body request → map JSON; ok=false bila rusak (JSON
// rusak → 400 "Body tidak valid"; body kosong = objek kosong → issue
// "Required" per field — padanan zod parse {}).
func stokDecodeBody(c echo.Context) (map[string]any, bool) {
	body, err := io.ReadAll(c.Request().Body)
	if err != nil {
		return nil, false
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return map[string]any{}, true
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, false
	}
	return m, true
}

// stokNamaTipe — getParsedType zod utk nilai JSON apa pun (pesan invalid_type).
func stokNamaTipe(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		return "number"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "unknown"
	}
}

// stokQuoted — opsi enum ter-quote digabung " | " (padanan util.joinValues).
func stokQuoted(opts []string) string {
	q := make([]string, len(opts))
	for i, o := range opts {
		q[i] = "'" + o + "'"
	}
	return strings.Join(q, " | ")
}

// stokNumTxt — angka cek min/max utk pesan zod ("0", "365", "999999999999").
func stokNumTxt(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }

// stokFptr — sugar *float64 literal.
func stokFptr(f float64) *float64 { return &f }

// stokNumAny — *float64 → any (nil → null; view ambang JSON).
func stokNumAny(f *float64) any {
	if f == nil {
		return nil
	}
	return *f
}

// stokActor — aktor audit WAJIB dari JWT (padanan mutationCtx): id/name
// dari user login (fallback id 0/"system" — dilucuti >0 di service); ip/ua
// dari request (fallback "-" / "unknown").
func stokActor(c echo.Context) audit.Actor {
	var idc *int64
	name := "system"
	if u := auth.From(c); u != nil {
		id := u.ID
		idc = &id
		name = u.Username
	}
	return audit.Actor{
		IDCoreUsers: idc,
		ActorName:   name,
		IPAddress:   stokIPOf(c),
		UserAgent:   stokUAOf(c),
	}
}

// stokIPOf — IP asli request (X-Forwarded-For pertama, fallback RemoteAddr,
// fallback "-" persis ipOf NestJS).
func stokIPOf(c echo.Context) string {
	req := c.Request()
	if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			xff = xff[:i]
		}
		if xff = strings.TrimSpace(xff); xff != "" {
			return xff
		}
	}
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	if host != "" {
		return host
	}
	return "-"
}

// stokUAOf — User-Agent asli request (fallback "unknown" persis userAgentOf).
func stokUAOf(c echo.Context) string {
	if ua := c.Request().Header.Get("User-Agent"); ua != "" {
		return ua
	}
	return "unknown"
}
