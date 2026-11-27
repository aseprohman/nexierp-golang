// Handler TENANTS — permukaan HTTP murni fitur tenant modul core (padanan
// SystemTenantsController NestJS): bind body/query → validasi zod-parity
// (pesan & urutan issue PERSIS skema) → delegasi service → bentuk respons
// dan problem+json PERSIS NestJS. Tanpa query SQL, tanpa aturan bisnis.
// Permission ROUTE-CENTRIC: tanpa cek permission di sini — guard group
// mencocokkan (method, path) → system.tenants.<action> di core_routes.
//
// Route `context` dideklarasikan SEBELUM route `:id` agar tidak tertelan
// param dinamis (ParseIDParam menolak "context" sebagai angka).
package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/service"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// DaftarkanTenants — pasang 20 route tenant di group /system/tenants
// (guard auth + RBAC route-centric, PERSIS @UseGuards controller NestJS).
func DaftarkanTenants(api *echo.Group, d types.Deps) {
	h := &TenantsHandler{svc: service.NewTenantsService(d)}
	g := api.Group("/system/tenants", d.AuthGuard, d.RbacGuard)
	g.GET("/context", h.konteks)                              // GET /system/tenants/context
	g.GET("", h.daftar)                                       // GET /system/tenants
	g.POST("", h.buat)                                        // POST /system/tenants (201)
	g.GET("/:id", h.ambil)                                    // GET /system/tenants/:id
	g.PATCH("/:id", h.ubah)                                   // PATCH /system/tenants/:id
	g.POST("/:id/suspend", h.suspend)                         // POST /system/tenants/:id/suspend
	g.POST("/:id/reactivate", h.reaktivasi)                   // POST /system/tenants/:id/reactivate
	g.POST("/:id/close", h.tutup)                             // POST /system/tenants/:id/close
	g.PUT("/:id/tier", h.setTier)                             // PUT /system/tenants/:id/tier
	g.GET("/:id/modules", h.listModules)                      // GET /system/tenants/:id/modules
	g.PUT("/:id/modules", h.setModules)                       // PUT /system/tenants/:id/modules
	g.GET("/:id/features", h.listFeatures)                    // GET /system/tenants/:id/features
	g.PUT("/:id/features", h.setFeatures)                     // PUT /system/tenants/:id/features
	g.GET("/:id/settings", h.listSettings)                    // GET /system/tenants/:id/settings
	g.PUT("/:id/settings", h.setSettings)                     // PUT /system/tenants/:id/settings
	g.GET("/:id/events", h.listEvents)                        // GET /system/tenants/:id/events
	g.GET("/:id/members", h.listMembers)                      // GET /system/tenants/:id/members
	g.POST("/:id/members", h.addMember)                       // POST /system/tenants/:id/members (201)
	g.PUT("/:id/members/:userId/default", h.setMemberDefault) // PUT .../members/:userId/default
	g.DELETE("/:id/members/:userId", h.removeMember)          // DELETE .../members/:userId
}

// TenantsHandler — dependensi handler tenants.
type TenantsHandler struct {
	svc *service.TenantsService
}

/* ==================================================================
// Helper permukaan HTTP — decode body + pesan & urutan issue zod v3
// (VERBATIM default message zod 3.25 yang dipakai packages/schemas)
// ================================================================== */

// Pesan default zod v3 (verbatim locales/en.js).
const (
	msgRequired = "Required"
	msgEmail    = "Invalid email"
)

func msgMinString(n int) string {
	return "String must contain at least " + strconv.Itoa(n) + " character(s)"
}
func msgMaxString(n int) string {
	return "String must contain at most " + strconv.Itoa(n) + " character(s)"
}
func msgMinNumber(n int64) string {
	return "Number must be greater than or equal to " + strconv.FormatInt(n, 10)
}
func msgMaxNumber(n int64) string {
	return "Number must be less than or equal to " + strconv.FormatInt(n, 10)
}
func msgGreaterThan(n int64) string {
	return "Number must be greater than " + strconv.FormatInt(n, 10)
}
func msgMinArray(n int) string {
	return "Array must contain at least " + strconv.Itoa(n) + " element(s)"
}
func msgMaxArray(n int) string {
	return "Array must contain at most " + strconv.Itoa(n) + " element(s)"
}
func msgBukan(expected, received string) string {
	return "Expected " + expected + ", received " + received
}
func msgEnumNilai(options []string, received string) string {
	return "Invalid enum value. Expected " + strings.Join(quoted(options), " | ") + ", received '" + received + "'"
}

func quoted(xs []string) []string {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		out = append(out, "'"+x+"'")
	}
	return out
}

// namaTipeJSON — getParsedType zod utk nilai JSON apa pun.
func namaTipeJSON(v any) string {
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

// reEmail — regex email default zod v3 (verbatim emailRegexps.z.EmailURL).
var reEmail = regexp.MustCompile(`^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$`)

// reKodeTenant — regex tenantCreateSchema kode (verbatim).
var reKodeTenant = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)

// decodeBody — baca body request → map JSON; ok=false bila rusak (padanan
// safeParse gagal struktur → detail "Body tidak valid").
func decodeBody(c echo.Context) (map[string]any, bool) {
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

// badBody — 400 VAL-400 detail "Body tidak valid" (+ issues bila ada).
func badBody(c echo.Context, issues []errkontrak.FieldIssue) error {
	if issues == nil {
		issues = []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}}
	}
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid", issues)
}

// gagalValidasi — padanan parseWith gagal: 400 VAL-400 detail "Data tidak valid."
// (problem+json ditulis langsung — bukan return error mentah ke echo).
func gagalValidasi(c echo.Context, issues []errkontrak.FieldIssue) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
}

// strField — ambil field string mentah: (nilai, ada issue?).
func strField(m map[string]any, key string) (string, *errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgRequired}
	}
	if v == nil {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgBukan("string", "null")}
	}
	s, ok := v.(string)
	if !ok {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgBukan("string", namaTipeJSON(v))}
	}
	return s, nil
}

// numField — ambil field number mentah: (nilai, ada issue?).
func numField(m map[string]any, key string) (float64, *errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada {
		return 0, &errkontrak.FieldIssue{Field: key, Message: msgRequired}
	}
	if v == nil {
		return 0, &errkontrak.FieldIssue{Field: key, Message: msgBukan("number", "null")}
	}
	f, ok := v.(float64)
	if !ok {
		return 0, &errkontrak.FieldIssue{Field: key, Message: msgBukan("number", namaTipeJSON(v))}
	}
	return f, nil
}

// zodString — z.string().trim().min(min).max(max) [email] [regex custom]:
// checks dieksekusi berurutan seperti urutan deklarasi; nilai kembali TER-TRIM.
// pesanMin/pesanRegex kosong = pesan default zod. wajib=false =
// .optional()/.nullish(): absen ATAU null → lolos tanpa nilai (ada=false).
func zodString(m map[string]any, key string, min, max int, email bool, re *regexp.Regexp, pesanRegex, pesanMin string, wajib bool, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		if !wajib {
			return "", false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgRequired})
		return "", false
	}
	if v == nil {
		if !wajib { // nullish — null diterima
			return "", false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgBukan("string", "null")})
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgBukan("string", namaTipeJSON(v))})
		return "", false
	}
	s = strings.TrimSpace(s) // z.string().trim() — transform pertama
	if len([]rune(s)) < min {
		pesan := pesanMin
		if pesan == "" {
			pesan = msgMinString(min)
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgMaxString(max)})
	}
	if email && !reEmail.MatchString(s) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgEmail})
	}
	if re != nil && !re.MatchString(s) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesanRegex})
	}
	return s, true
}

// zodInt32Nullish — z.number().int().min(0).nullish(): (nilai, eksplisit?, nil
// = absen/null). Out-of-range int32 → issue number invalid (kolom DB int).
func zodInt32Nullish(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*int32, bool) {
	v, ada := m[key]
	if !ada || v == nil { // undefined/null → nil (nullish)
		return nil, ada
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgBukan("number", namaTipeJSON(v))})
		return nil, true
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgBukan("integer", "float")})
	}
	if f < 0 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgMinNumber(0)})
	}
	if f < -2147483648 || f > 2147483647 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgMaxNumber(2147483647)})
	}
	n := int32(f)
	return &n, true
}

// zodEnum — z.enum(options): nilai bukan-string ATAU di luar anggota →
// invalid_enum_value (persis ZodEnum — tidak pernah invalid_type).
// optional=true = .optional()/.default(): absen → lolos tanpa nilai.
func zodEnum(m map[string]any, key string, options []string, optional bool, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		if optional {
			return "", false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgRequired})
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgEnumNilai(options, zodReceived(v))})
		return "", false
	}
	for _, o := range options {
		if s == o {
			return s, true
		}
	}
	*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgEnumNilai(options, s)})
	return "", false
}

// zodReceived — tampilan `received` gaya template JS utk pesan enum.
func zodReceived(v any) string {
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

// zodPositiveInt64 — z.number().int().positive() utk elemen array id:
// issue path "key.index" (padanan path zod ber-index).
func zodPositiveInt64(arr []any, key string, issues *[]errkontrak.FieldIssue) []int64 {
	out := make([]int64, 0, len(arr))
	for i, v := range arr {
		path := key + "." + strconv.Itoa(i)
		f, ok := v.(float64)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: msgBukan("number", namaTipeJSON(v))})
			continue
		}
		if f != float64(int64(f)) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: msgBukan("integer", "float")})
		}
		if f <= 0 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: msgGreaterThan(0)})
		}
		out = append(out, int64(f))
	}
	return out
}

/* ==================================================================
// Endpoint
// ================================================================== */

// konteks — GET /system/tenants/context — keanggotaan aktif user JWT
// (switcher FE): default paling atas, sisanya by kode.
func (h *TenantsHandler) konteks(c echo.Context) error {
	u := auth.From(c)
	userID := int64(0)
	if u != nil {
		userID = u.ID
	}
	rows, err := h.svc.Context(c.Request().Context(), userID)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"rows": rows})
}

// daftar — GET /system/tenants — envelope {rows, total} (BUKAN Page).
func (h *TenantsHandler) daftar(c echo.Context) error {
	q, issues := parseListQuery(c.QueryParams())
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	out, err := h.svc.List(c.Request().Context(), q)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, out)
}

// coerceNumber — padanan z.coerce.number(): Number(v) JS — "" dan whitespace
// saja → 0; selain itu ParseFloat (gagal = NaN).
func coerceNumber(raw string) (float64, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return 0, true
	}
	f, err := strconv.ParseFloat(trimmed, 64)
	if err != nil {
		return 0, false
	}
	return f, true
}

// parseListQuery — tenantListQuerySchema (z.coerce page/limit default 1/20,
// search trim max120, status/tier enum).
func parseListQuery(qs map[string][]string) (types.TenantListQuery, []errkontrak.FieldIssue) {
	var q types.TenantListQuery
	issues := []errkontrak.FieldIssue{}

	get := func(key string) (string, bool) {
		vs, ada := qs[key]
		if !ada || len(vs) == 0 {
			return "", false
		}
		return vs[0], true
	}

	// page: z.coerce.number().int().min(1).default(1)
	if raw, ada := get("page"); ada {
		if f, ok := coerceNumber(raw); !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: "page", Message: msgBukan("number", "nan")})
		} else {
			if f != float64(int64(f)) {
				issues = append(issues, errkontrak.FieldIssue{Field: "page", Message: msgBukan("integer", "float")})
			}
			if f < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "page", Message: msgMinNumber(1)})
			}
			q.Page = int64(f)
		}
	} else {
		q.Page = 1
	}

	// limit: z.coerce.number().int().min(1).max(200).default(20)
	if raw, ada := get("limit"); ada {
		if f, ok := coerceNumber(raw); !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: "limit", Message: msgBukan("number", "nan")})
		} else {
			if f != float64(int64(f)) {
				issues = append(issues, errkontrak.FieldIssue{Field: "limit", Message: msgBukan("integer", "float")})
			}
			if f < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "limit", Message: msgMinNumber(1)})
			}
			if f > 200 {
				issues = append(issues, errkontrak.FieldIssue{Field: "limit", Message: msgMaxNumber(200)})
			}
			q.Limit = int64(f)
		}
	} else {
		q.Limit = 20
	}

	// search: z.string().trim().max(120).optional() — kosong hasil trim =
	// tanpa filter (padanan `if (term)` repo NestJS).
	if raw, ada := get("search"); ada {
		s := strings.TrimSpace(raw)
		if len([]rune(s)) > 120 {
			issues = append(issues, errkontrak.FieldIssue{Field: "search", Message: msgMaxString(120)})
		}
		if s != "" {
			q.Search = &s
		}
	}

	// status: z.enum(STATUS_TENANT).optional()
	if raw, ada := get("status"); ada {
		valid := false
		for _, o := range types.StatusTenantValid {
			if raw == o {
				valid = true
				break
			}
		}
		if !valid {
			issues = append(issues, errkontrak.FieldIssue{Field: "status", Message: msgEnumNilai(types.StatusTenantValid, raw)})
		} else {
			q.Status = raw
		}
	}

	// tier: z.enum(PAKET_TIER).optional()
	if raw, ada := get("tier"); ada {
		valid := false
		for _, o := range types.PaketTierValid {
			if raw == o {
				valid = true
				break
			}
		}
		if !valid {
			issues = append(issues, errkontrak.FieldIssue{Field: "tier", Message: msgEnumNilai(types.PaketTierValid, raw)})
		} else {
			q.Tier = raw
		}
	}

	return q, issues
}

// buat — POST /system/tenants — provisio tenant baru (201, envelope {data}).
func (h *TenantsHandler) buat(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiCreate(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	view, err := h.svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// validasiCreate — tenantCreateSchema (pesan kustom kode/nama VERBATIM,
// paketTier default PS2, kuota/kontak nullish).
func validasiCreate(m map[string]any) (types.TenantCreateInput, []errkontrak.FieldIssue) {
	var in types.TenantCreateInput
	issues := []errkontrak.FieldIssue{}

	// kode: trim min3 pesan kustom, max50, regex pesan kustom.
	kode, _ := zodString(m, "kode", 3, 50, false, reKodeTenant,
		"Kode tenant hanya huruf kecil, angka, titik, garis — tanpa spasi.",
		"Kode tenant minimal 3 karakter.", true, &issues)
	in.Kode = kode

	// nama: trim min2 pesan kustom, max100.
	nama, _ := zodString(m, "nama", 2, 100, false, nil, "", "Nama tenant minimal 2 karakter.", true, &issues)
	in.Nama = nama

	// paketTier: z.enum(PAKET_TIER).default("PS2") — absen → default PS2.
	if tier, terisi := zodEnum(m, "paketTier", types.PaketTierValid, true, &issues); terisi {
		in.PaketTier = tier
	} else {
		in.PaketTier = types.TierPS2 // default
	}

	if v, ada := zodInt32Nullish(m, "maxUsers", &issues); ada {
		in.MaxUsers = v
	}
	if v, ada := zodInt32Nullish(m, "maxLokasi", &issues); ada {
		in.MaxLokasi = v
	}

	// kontakEmail: z.string().trim().email().max(150).nullish() — null → nil.
	if v, ada := zodString(m, "kontakEmail", 0, 150, true, nil, "", "", false, &issues); ada {
		s := v
		in.KontakEmail = &s
	}

	// kontakTelepon: z.string().trim().max(50).nullish() — null → nil.
	if v, ada := zodString(m, "kontakTelepon", 0, 50, false, nil, "", "", false, &issues); ada {
		s := v
		in.KontakTelepon = &s
	}

	return in, issues
}

// ambil — GET /system/tenants/:id — detail tenant (envelope {data}).
func (h *TenantsHandler) ambil(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.svc.Get(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// ubah — PATCH /system/tenants/:id — patch umum; `version` WAJIB di body
// (zod tanpa .optional); If-Match menang bila dikirim; 412 bila stale.
func (h *TenantsHandler) ubah(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiUpdate(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	ifMatch, err := shared.IfMatchVersion(c.Request())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	// ifMatchVersion(req) ?? dto.version — If-Match menang bila ada.
	expected := ifMatch
	if expected == nil {
		expected = &in.Version
	}
	view, err := h.svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()), expected)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// validasiUpdate — tenantUpdateSchema = createSchema.partial().omit(paketTier)
// .extend({paketTier optional}) + version WAJIB (z.number().int().min(1)).
func validasiUpdate(m map[string]any) (types.TenantUpdateInput, []errkontrak.FieldIssue) {
	var in types.TenantUpdateInput
	issues := []errkontrak.FieldIssue{}

	// kode/nama: partial string — absen lolos; eksplisit null → invalid_type.
	if v, ada := m["kode"]; ada {
		if v == nil {
			issues = append(issues, errkontrak.FieldIssue{Field: "kode", Message: msgBukan("string", "null")})
		} else if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if len([]rune(s)) < 3 {
				issues = append(issues, errkontrak.FieldIssue{Field: "kode", Message: "Kode tenant minimal 3 karakter."})
			}
			if len([]rune(s)) > 50 {
				issues = append(issues, errkontrak.FieldIssue{Field: "kode", Message: msgMaxString(50)})
			}
			if !reKodeTenant.MatchString(s) {
				issues = append(issues, errkontrak.FieldIssue{Field: "kode", Message: "Kode tenant hanya huruf kecil, angka, titik, garis — tanpa spasi."})
			}
			in.Kode = &s
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "kode", Message: msgBukan("string", namaTipeJSON(v))})
		}
	}

	if v, ada := m["nama"]; ada {
		if v == nil {
			issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: msgBukan("string", "null")})
		} else if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if len([]rune(s)) < 2 {
				issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: "Nama tenant minimal 2 karakter."})
			}
			if len([]rune(s)) > 100 {
				issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: msgMaxString(100)})
			}
			in.Nama = &s
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: msgBukan("string", namaTipeJSON(v))})
		}
	}

	if _, terisi := zodEnum(m, "paketTier", types.PaketTierValid, true, &issues); terisi {
		// nilai enum valid terjamin — ambil ulang string mentah.
		in.PaketTier, _ = m["paketTier"].(string)
	}

	if v, ada := zodInt32Nullish(m, "maxUsers", &issues); ada {
		in.MaxUsers, in.MaxUsersAda = v, true
	}
	if v, ada := zodInt32Nullish(m, "maxLokasi", &issues); ada {
		in.MaxLokasi, in.MaxLokasiAda = v, true
	}

	if v, ada := m["kontakEmail"]; ada {
		if v == nil {
			in.KontakEmail, in.KontakEmailAda = nil, true
		} else if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if !reEmail.MatchString(s) {
				issues = append(issues, errkontrak.FieldIssue{Field: "kontakEmail", Message: msgEmail})
			}
			if len([]rune(s)) > 150 {
				issues = append(issues, errkontrak.FieldIssue{Field: "kontakEmail", Message: msgMaxString(150)})
			}
			in.KontakEmail, in.KontakEmailAda = &s, true
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "kontakEmail", Message: msgBukan("string", namaTipeJSON(v))})
			in.KontakEmailAda = true
		}
	}

	if v, ada := m["kontakTelepon"]; ada {
		if v == nil {
			in.KontakTelepon, in.KontakTeleponAda = nil, true
		} else if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if len([]rune(s)) > 50 {
				issues = append(issues, errkontrak.FieldIssue{Field: "kontakTelepon", Message: msgMaxString(50)})
			}
			in.KontakTelepon, in.KontakTeleponAda = &s, true
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "kontakTelepon", Message: msgBukan("string", namaTipeJSON(v))})
			in.KontakTeleponAda = true
		}
	}

	// version: z.number().int().min(1) — WAJIB (tanpa .optional()).
	if f, iss := numField(m, "version"); iss != nil {
		issues = append(issues, *iss)
	} else {
		if f != float64(int64(f)) {
			issues = append(issues, errkontrak.FieldIssue{Field: "version", Message: msgBukan("integer", "float")})
		}
		if f < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "version", Message: msgMinNumber(1)})
		}
		in.Version = int64(f)
	}

	return in, issues
}

// aksi — gerbang suspend/reactivate/close: parse param + body + delegasi
// (padanan aksi() privat controller NestJS).
func (h *TenantsHandler) aksi(c echo.Context, aksi string) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiAksi(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	view, err := h.svc.SetAksi(c.Request().Context(), id, aksi, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// validasiAksi — tenantAksiSchema: alasan string trim max300 nullish.
func validasiAksi(m map[string]any) (types.TenantAksiInput, []errkontrak.FieldIssue) {
	var in types.TenantAksiInput
	issues := []errkontrak.FieldIssue{}
	v, ada := m["alasan"]
	if ada {
		if v == nil {
			in.Alasan = nil
		} else if s, ok := v.(string); ok {
			s = strings.TrimSpace(s)
			if len([]rune(s)) > 300 {
				issues = append(issues, errkontrak.FieldIssue{Field: "alasan", Message: msgMaxString(300)})
			}
			in.Alasan = &s
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "alasan", Message: msgBukan("string", namaTipeJSON(v))})
		}
	}
	return in, issues
}

func (h *TenantsHandler) suspend(c echo.Context) error    { return h.aksi(c, "suspend") }    // TenantLifecycleAction "suspend"
func (h *TenantsHandler) reaktivasi(c echo.Context) error { return h.aksi(c, "reactivate") } // "reactivate"
func (h *TenantsHandler) tutup(c echo.Context) error      { return h.aksi(c, "close") }      // "close"

// setTier — PUT /system/tenants/:id/tier — `{ paketTier, version? }`;
// If-Match fallback dto.version; event SET_TIER; audit warning.
func (h *TenantsHandler) setTier(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiTierSet(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	ifMatch, err := shared.IfMatchVersion(c.Request())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	// ifMatchVersion(req) ?? dto.version — keduanya boleh nihil (tanpa cek).
	expected := ifMatch
	if expected == nil {
		expected = in.Version
	}
	view, err := h.svc.SetTier(c.Request().Context(), id, in.PaketTier, shared.ActorOf(c.Request()), expected)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// validasiTierSet — tenantTierSetSchema.
func validasiTierSet(m map[string]any) (types.TenantTierSetInput, []errkontrak.FieldIssue) {
	var in types.TenantTierSetInput
	issues := []errkontrak.FieldIssue{}
	if tier, terisi := zodEnum(m, "paketTier", types.PaketTierValid, false, &issues); terisi {
		in.PaketTier = tier
	}
	if v, ada := m["version"]; ada { // optional — absen lolos; null → invalid_type
		f, ok := v.(float64)
		if !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: "version", Message: msgBukan("number", namaTipeJSON(v))})
		} else {
			if f != float64(int64(f)) {
				issues = append(issues, errkontrak.FieldIssue{Field: "version", Message: msgBukan("integer", "float")})
			}
			if f < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "version", Message: msgMinNumber(1)})
			}
			n := int64(f)
			in.Version = &n
		}
	}
	return in, issues
}

// listModules — GET /:id/modules — `{ idModules: [...] }` hanya aktif ORDER id.
func (h *TenantsHandler) listModules(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	rows, err := h.svc.ListModules(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	ids := make([]int64, 0, len(rows))
	for _, r := range rows {
		if r.Aktif {
			ids = append(ids, r.ID)
		}
	}
	return c.JSON(http.StatusOK, map[string]any{"idModules": ids})
}

// setModules — PUT /:id/modules — REPLACE set aktif; respons {rows:[...]}.
func (h *TenantsHandler) setModules(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiSetID(m, "idModules", 200)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	rows, err := h.svc.SetModules(c.Request().Context(), id, types.TenantModuleSetInput{IDModules: in}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"rows": rows})
}

// listFeatures — GET /:id/features — `{ idFeatures: [...] }` hanya aktif.
func (h *TenantsHandler) listFeatures(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	rows, err := h.svc.ListFeatures(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	ids := make([]int64, 0, len(rows))
	for _, r := range rows {
		if r.Aktif {
			ids = append(ids, r.ID)
		}
	}
	return c.JSON(http.StatusOK, map[string]any{"idFeatures": ids})
}

// setFeatures — PUT /:id/features — REPLACE set aktif; respons {rows:[...]}.
func (h *TenantsHandler) setFeatures(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiSetID(m, "idFeatures", 500)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	rows, err := h.svc.SetFeatures(c.Request().Context(), id, types.TenantFeatureSetInput{IDFeatures: in}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"rows": rows})
}

// validasiSetID — tenantModuleSetSchema / tenantFeatureSetSchema:
// array number int positive (tanpa min panjang — array kosong sah), max200/max500.
func validasiSetID(m map[string]any, key string, max int) ([]int64, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	v, ada := m[key]
	if !ada {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgRequired})
		return nil, issues
	}
	arr, ok := v.([]any)
	if !ok {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgBukan("array", namaTipeJSON(v))})
		return nil, issues
	}
	if len(arr) > max {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgMaxArray(max)})
	}
	out := zodPositiveInt64(arr, key, &issues)
	return out, issues
}

// listSettings — GET /:id/settings?kategori — array flat urut kategori,kunci.
func (h *TenantsHandler) listSettings(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	q, issues := parseSettingsQuery(c.QueryParams())
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	rows, err := h.svc.ListSettings(c.Request().Context(), id, q.Kategori)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, rows)
}

// parseSettingsQuery — tenantSettingsQuerySchema: kategori trim min1 max100 optional.
func parseSettingsQuery(qs map[string][]string) (types.TenantSettingsQuery, []errkontrak.FieldIssue) {
	var q types.TenantSettingsQuery
	issues := []errkontrak.FieldIssue{}
	vs, ada := qs["kategori"]
	if ada && len(vs) > 0 {
		s := strings.TrimSpace(vs[0])
		if len([]rune(s)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "kategori", Message: msgMinString(1)})
		}
		if len([]rune(s)) > 100 {
			issues = append(issues, errkontrak.FieldIssue{Field: "kategori", Message: msgMaxString(100)})
		}
		q.Kategori = &s
	}
	return q, issues
}

// setSettings — PUT /:id/settings — REPLACE satu kategori; respons {rows}.
func (h *TenantsHandler) setSettings(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiSettingsSet(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	rows, err := h.svc.SetSettings(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"rows": rows})
}

// validasiSettingsSet — tenantSettingsSetSchema: kategori trim min1 max100;
// entri array min1 pesan kustom "Minimal satu entri setting." max100;
// item {kunci trim min1 max100, nilai unknown}.
func validasiSettingsSet(m map[string]any) (types.TenantSettingsSetInput, []errkontrak.FieldIssue) {
	var in types.TenantSettingsSetInput
	issues := []errkontrak.FieldIssue{}

	kategori, _ := zodString(m, "kategori", 1, 100, false, nil, "", "", true, &issues)
	in.Kategori = kategori

	v, ada := m["entri"]
	if !ada {
		issues = append(issues, errkontrak.FieldIssue{Field: "entri", Message: msgRequired})
		return in, issues
	}
	arr, ok := v.([]any)
	if !ok {
		issues = append(issues, errkontrak.FieldIssue{Field: "entri", Message: msgBukan("array", namaTipeJSON(v))})
		return in, issues
	}
	if len(arr) < 1 {
		issues = append(issues, errkontrak.FieldIssue{Field: "entri", Message: "Minimal satu entri setting."})
	}
	if len(arr) > 100 {
		issues = append(issues, errkontrak.FieldIssue{Field: "entri", Message: msgMaxArray(100)})
	}
	for i, item := range arr {
		path := "entri." + strconv.Itoa(i)
		obj, ok := item.(map[string]any)
		if !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: path, Message: msgBukan("object", namaTipeJSON(item))})
			continue
		}
		// kunci: z.string().trim().min(1).max(100)
		kv, kAda := obj["kunci"]
		if !kAda {
			issues = append(issues, errkontrak.FieldIssue{Field: path + ".kunci", Message: msgRequired})
		} else if s, ok := kv.(string); ok {
			s = strings.TrimSpace(s)
			if len([]rune(s)) < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: path + ".kunci", Message: msgMinString(1)})
			}
			if len([]rune(s)) > 100 {
				issues = append(issues, errkontrak.FieldIssue{Field: path + ".kunci", Message: msgMaxString(100)})
			}
			in.Entri = append(in.Entri, types.TenantSettingEntri{Kunci: s, Nilai: obj["nilai"]})
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: path + ".kunci", Message: msgBukan("string", namaTipeJSON(kv))})
		}
	}
	return in, issues
}

// listEvents — GET /:id/events — array TenantEventView ORDER id DESC.
func (h *TenantsHandler) listEvents(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	rows, err := h.svc.ListEvents(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, rows)
}

// listMembers — GET /:id/members — array anggota aktif.
func (h *TenantsHandler) listMembers(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	rows, err := h.svc.ListMembers(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, rows)
}

// addMember — POST /:id/members — tambah/reaktivasi anggota (201, {data}).
func (h *TenantsHandler) addMember(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiMembersAdd(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	view, err := h.svc.AddMember(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// validasiMembersAdd — tenantMembersAddSchema: idCoreUsers int positive;
// isDefault boolean default false.
func validasiMembersAdd(m map[string]any) (types.TenantMembersAddInput, []errkontrak.FieldIssue) {
	var in types.TenantMembersAddInput
	issues := []errkontrak.FieldIssue{}

	if f, iss := numField(m, "idCoreUsers"); iss != nil {
		issues = append(issues, *iss)
	} else {
		if f != float64(int64(f)) {
			issues = append(issues, errkontrak.FieldIssue{Field: "idCoreUsers", Message: msgBukan("integer", "float")})
		}
		if f <= 0 {
			issues = append(issues, errkontrak.FieldIssue{Field: "idCoreUsers", Message: msgGreaterThan(0)})
		}
		in.IDCoreUsers = int64(f)
	}

	if v, ada := m["isDefault"]; ada {
		b, ok := v.(bool)
		if !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: "isDefault", Message: msgBukan("boolean", namaTipeJSON(v))})
		} else {
			in.IsDefault = b
		}
	} // absen → default false

	return in, issues
}

// setMemberDefault — PUT /:id/members/:userId/default — {data: member}.
func (h *TenantsHandler) setMemberDefault(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	userID, err := shared.ParseIDParam(c.Param("userId"), "userId")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	view, err := h.svc.SetMemberDefault(c.Request().Context(), id, userID, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// removeMember — DELETE /:id/members/:userId — cabut SOFT; {data:{ok:true}}.
func (h *TenantsHandler) removeMember(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	userID, err := shared.ParseIDParam(c.Param("userId"), "userId")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.svc.RemoveMember(c.Request().Context(), id, userID, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}
