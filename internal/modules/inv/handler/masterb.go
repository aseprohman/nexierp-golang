// Handler MASTER-B — SATU PINTU pendaftaran route fitur gudang, lokasi,
// lot, jenis-operasi, atribut+atributnilai modul inv (padanan controllers/
// master/{gudang,lokasi,lot,jenis-operasi,atribut}.controller.ts NestJS —
// total 27 endpoint). Permukaan HTTP murni: bind body/query → validasi
// zod-parity (pesan & urutan issue PERSIS packages/schemas/src/inv/
// schemas.ts) → delegasi service → bentuk respons & problem+json PERSIS
// NestJS. Tanpa SQL, tanpa aturan bisnis.
//
// Permission ROUTE-CENTRIC: tanpa cek permission di sini — guard group
// mencocokkan (method, path) → inventory.master.<fitur>.<action> di
// core_routes (PERSIS @UseGuards controller NestJS).
//
// Data-scope dimensi 'storages' dievaluasi DI SERVICE (gudang & lokasi
// saja); handler hanya meneruskan id user JWT. Helper paket handler
// ber-prefix `mb` — pengaman kolisi nama dengan file fitur lain (master-A,
// dashboard, operasi, stok) di package handler yang sama.
package handler

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/types"
)

// DaftarkanMasterB — pasang SEMUA route MASTER-B modul inv (dipanggil
// module.go sebelah DaftarkanMaster milik master-A):
//
//	/inventory/master/gudang          — CRUD (5)
//	/inventory/master/lokasi          — CRUD (5)
//	/inventory/master/lot             — list/create/detail (3)
//	/inventory/master/jenis-operasi   — CRUD (5)
//	/inventory/master/atribut         — CRUD + list/create nilai (7)
//	/inventory/master/atributnilai    — update/delete nilai (2)
func DaftarkanMasterB(api *echo.Group, d types.Deps) {
	daftarkanGudang(api, d)
	daftarkanLokasi(api, d)
	daftarkanLot(api, d)
	daftarkanJenisOperasi(api, d)
	daftarkanAtribut(api, d)
}

/* ==================================================================
// Helper permukaan HTTP bersama MASTER-B — decode body + pesan & urutan
// issue zod v3 (VERBATIM default message zod yang dipakai packages/schemas)
// ================================================================== */

// mbUserID — id user JWT utk evaluasi data-scope (0 = tak dikenal → SEMUA).
func mbUserID(c echo.Context) int64 {
	u := auth.From(c)
	if u == nil {
		return 0
	}
	return u.ID
}

// mbActor — aktor audit WAJIB dari JWT (padanan mutationCtx NestJS):
// idCoreUsers/actorName dari user login; ip/ua dari request.
func mbActor(req *http.Request) audit.Actor {
	u := auth.FromReq(req)
	idCoreUsers := (*int64)(nil)
	name := "system"
	if u != nil {
		id := u.ID
		idCoreUsers = &id
		name = u.Username
	}
	return audit.Actor{
		IDCoreUsers: idCoreUsers,
		ActorName:   name,
		IPAddress:   mbIPOf(req),
		UserAgent:   mbUAOf(req),
	}
}

func mbIPOf(req *http.Request) string {
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

func mbUAOf(req *http.Request) string {
	if ua := req.Header.Get("User-Agent"); ua != "" {
		return ua
	}
	return "unknown"
}

// Pesan default zod v3 (verbatim locales/en.js) + pesan kustom skema.
const (
	mbMsgRequired = "Required"
)

func mbMsgMinString(n int) string {
	return "String must contain at least " + strconv.Itoa(n) + " character(s)"
}
func mbMsgMaxString(n int) string {
	return "String must contain at most " + strconv.Itoa(n) + " character(s)"
}
func mbMsgMinNumber(n int64) string {
	return "Number must be greater than or equal to " + strconv.FormatInt(n, 10)
}
func mbMsgMaxNumber(n int64) string {
	return "Number must be less than or equal to " + strconv.FormatInt(n, 10)
}
func mbMsgGreaterThan(n int64) string {
	return "Number must be greater than " + strconv.FormatInt(n, 10)
}
func mbMsgBukan(expected, received string) string {
	return "Expected " + expected + ", received " + received
}
func mbMsgEnumNilai(options []string, received string) string {
	return "Invalid enum value. Expected " + strings.Join(mbQuoted(options), " | ") + ", received '" + received + "'"
}

func mbQuoted(xs []string) []string {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		out = append(out, "'"+x+"'")
	}
	return out
}

// mbNamaTipeJSON — getParsedType zod utk nilai JSON apa pun.
func mbNamaTipeJSON(v any) string {
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

// mbZodReceived — tampilan `received` gaya template JS utk pesan enum.
func mbZodReceived(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	default:
		return "[object Object]"
	}
}

// reKodeInv — regex kode master inv (verbatim: /^[A-Za-z0-9_.-]+$/).
var reKodeInv = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// Kosakata enum skema inv (persis ddl + tipe.ts).
var (
	enumStatusAktif  = []string{"AKTIF", "NONAKTIF"}
	enumJenisLokasi  = []string{"INTERNAL", "VENDOR", "CUSTOMER", "PRODUKSI", "SCRAP"}
	enumJenisGerakan = []string{"PENERIMAAN", "PENGIRIMAN", "TRANSFER_INTERNAL", "PRODUKSI", "SCRAP", "PENYESUAIAN"}
	enumTipeAtribut  = []string{"PILIHAN", "BEBAS"}
	enumStatusLot    = []string{"AKTIF", "KEDALUWARSA", "HABIS"}
)

// mbDecodeBody — baca body request → map JSON; ok=false bila rusak (padanan
// safeParse gagal struktur → detail "Body tidak valid").
func mbDecodeBody(c echo.Context) (map[string]any, bool) {
	body, err := io.ReadAll(c.Request().Body)
	if err != nil {
		return nil, false
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		// body kosong = objek kosong → issue "Required" per field (zod).
		return map[string]any{}, true
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, false
	}
	return m, true
}

// mbBadBody — 400 VAL-400 detail "Body tidak valid" (+ issues bila ada).
func mbBadBody(c echo.Context, issues []errkontrak.FieldIssue) error {
	if issues == nil {
		issues = []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}}
	}
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid", issues)
}

// mbGagalValidasi — padanan parseWith gagal: 400 VAL-400 detail
// "Data tidak valid." (problem+json ditulis langsung — bukan error mentah).
func mbGagalValidasi(c echo.Context, issues []errkontrak.FieldIssue) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
}

// mbZodString — z.string().trim().min(min).max(max) [regex]: checks
// dieksekusi berurutan seperti urutan deklarasi; nilai kembali TER-TRIM.
// pesanMin/pesanRegex kosong = pesan default zod.
//   - wajib=true: absen → Required; null → invalid_type.
//   - wajib=false + nullish=true (.nullish() dari create schema, ikut
//     .partial()): absen ATAU null → lolos tanpa nilai (ada=false).
//   - wajib=false + nullish=false (.optional() saja dari .partial()):
//     absen → lolos; null → invalid_type (persis zod .optional()).
func mbZodString(m map[string]any, key string, min, max int, re *regexp.Regexp, pesanRegex, pesanMin string, wajib, nullish bool, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		if wajib {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgRequired})
			return "", false
		}
		return "", false
	}
	if v == nil {
		if wajib || !nullish { // wajib | .optional() — null ditolak
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("string", "null")})
			return "", false
		}
		return "", false // nullish — null diterima
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("string", mbNamaTipeJSON(v))})
		return "", false
	}
	s = strings.TrimSpace(s) // z.string().trim() — transform pertama
	if len([]rune(s)) < min {
		pesan := pesanMin
		if pesan == "" {
			pesan = mbMsgMinString(min)
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgMaxString(max)})
	}
	if re != nil && !re.MatchString(s) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesanRegex})
	}
	return s, true
}

// mbZodStringPtr — z.string().trim().max(max).nullish() → *string:
// absen → (nil,false); null eksplisit nullish → (nil,TRUE — 3-state);
// terisi → pointer. Bila nullish=false, null → issue invalid_type di
// mbZodString.
func mbZodStringPtr(m map[string]any, key string, min, max int, nullish bool, issues *[]errkontrak.FieldIssue) (*string, bool) {
	if v, ada := m[key]; ada && v == nil {
		if nullish {
			return nil, true
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("string", "null")})
		return nil, false
	}
	v, ada := mbZodString(m, key, min, max, nil, "", "", false, nullish, issues)
	if !ada {
		return nil, false
	}
	s := v
	return &s, true
}

// mbZodID — idRefSchema.nullish() utk picker: absen → (nil, false); null →
// (nil, TRUE — nullish 3-state: eksplisit dikirim); else
// z.number().int().positive("Pilih salah satu opsi.").
func mbZodID(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*int64, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false
	}
	if v == nil { // null eksplisit — sah (nullish), bedakan dari absen
		return nil, true
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", mbNamaTipeJSON(v))})
		return nil, true
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("integer", "float")})
	}
	if f <= 0 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: "Pilih salah satu opsi."})
	}
	n := int64(f)
	return &n, true
}

// mbZodIDWajib — idRefSchema (tanpa nullish): absen → Required.
func mbZodIDWajib(m map[string]any, key string, issues *[]errkontrak.FieldIssue) int64 {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgRequired})
		return 0
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", mbNamaTipeJSON(v))})
		return 0
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("integer", "float")})
	}
	if f <= 0 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: "Pilih salah satu opsi."})
	}
	return int64(f)
}

// mbZodNumNullish — z.number().min(min,pesanMin).max(max,pesanMax).nullish()
// (latitude/longitude — float sah, pesan kustom verbatim). absen → (nil,
// false); null eksplisit → (nil, TRUE — 3-state: eksplisit dikirim).
func mbZodNumNullish(m map[string]any, key string, min, max float64, pesanMin, pesanMax string, issues *[]errkontrak.FieldIssue) (*float64, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false
	}
	if v == nil {
		return nil, true
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", mbNamaTipeJSON(v))})
		return nil, true
	}
	if f < min {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesanMin})
	}
	if f > max {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesanMax})
	}
	return &f, true
}

// mbZodInt — z.number().int(pesanInt).min(min,pesanMin).max(max,pesanMax)
// [.default(def)]: wajib=false = optional/default (absen → def).
// pesanInt kosong = pesan default zod (mengikuti konvensi repo:
// "Expected integer, received float" → mbMsgBukan).
func mbZodInt(m map[string]any, key string, min, max int64, pesanInt, pesanMin, pesanMax string, wajib bool, issues *[]errkontrak.FieldIssue) (*int64, bool) {
	v, ada := m[key]
	if !ada {
		if !wajib {
			return nil, false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgRequired})
		return nil, false
	}
	if v == nil {
		if !wajib { // optional — null → invalid_type (bukan absen)
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", "null")})
			return nil, true
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", "null")})
		return nil, true
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgBukan("number", mbNamaTipeJSON(v))})
		return nil, true
	}
	if f != float64(int64(f)) {
		pesan := pesanInt
		if pesan == "" {
			pesan = mbMsgBukan("integer", "float")
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	if f < float64(min) {
		pesan := pesanMin
		if pesan == "" {
			pesan = mbMsgMinNumber(min)
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	if f > float64(max) {
		pesan := pesanMax
		if pesan == "" {
			pesan = mbMsgMaxNumber(max)
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	n := int64(f)
	return &n, true
}

// mbZodEnum — z.enum(options)[.optional()/.default()]: nilai bukan-string
// ATAU di luar anggota → invalid_enum_value (persis ZodEnum — tidak pernah
// invalid_type). optional=true = .optional()/.default(): absen → lolos
// tanpa nilai; null tetap invalid (received 'null').
func mbZodEnum(m map[string]any, key string, options []string, optional bool, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		if optional {
			return "", false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgRequired})
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgEnumNilai(options, mbZodReceived(v))})
		return "", false
	}
	for _, o := range options {
		if s == o {
			return s, true
		}
	}
	*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: mbMsgEnumNilai(options, s)})
	return "", false
}

// mbVersion — version WAJIB di body patch: z.number().int().min(1).
func mbVersion(m map[string]any, issues *[]errkontrak.FieldIssue) int64 {
	v, _ := mbZodInt(m, "version", 1, 1<<62-1, "", "", "", true, issues)
	if v == nil {
		return 0
	}
	return *v
}

// mbPageReq — parse query pagination seragam (default 1/20, clamp 200,
// sort/filter) — padanan PageRequest.fromQuery; gagal → *DomainError
// VAL-400 (dipetakan errkontrak.Map oleh pemanggil).
func mbPageReq(c echo.Context) (*errkontrak.PageRequest, error) {
	return errkontrak.ParsePageRequest(c.QueryParams())
}

// mbIDParam — padanan parseIdParam: bukan int ≥1 → *DomainError VAL-400
// field dengan pesan verbatim.
func mbIDParam(raw, field string) (int64, error) {
	n, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || n < 1 {
		return 0, errkontrak.Validation([]errkontrak.FieldIssue{
			{Field: field, Message: "Harus bilangan bulat >= 1 (diterima: " + raw + ")."},
		})
	}
	return n, nil
}
