// handler/security.go — permukaan HTTP fitur SECURITY + AUDIT-TRAIL +
// ENVIRONMENT modul core (padanan controllers/security/*.controller.ts).
// TIPIS: parse query/body (validasi padanan zod v3 — pesan & urutan issue
// PERSIS) → service → envelope respons. Penegakan permission = ROUTE-
// CENTRIC (JwtAuthGuard + PermissionsGuard via core_routes).
//
//	GET    /system/security/sessions            — halaman sesi, PAGINATED
//	POST   /system/security/sessions/:id/revoke — cabut sesi (200)
//	GET    /system/security/login-audit         — log login, PAGINATED
//	GET    /system/security/mfa                 — status MFA per user, PAGINATED
//	POST   /system/security/mfa                 — on/off MFA (200)
//	GET    /system/security/password-history    — riwayat password, PAGINATED
//	GET    /system/security/ip-allowlist        — allowlist, PAGINATED
//	POST   /system/security/ip-allowlist        — tambah aturan (201)
//	DELETE /system/security/ip-allowlist/:id    — hapus aturan (200)
//	GET    /system/audit-trail                  — halaman audit trail, PAGINATED
//	GET    /system/audit-trail/actions          — distinct aksi (maks 200)
//	GET    /system/audit-trail/export           — CSV attachment (maks 50.000)
//	GET    /system/environment                  — kategori + logo
//	POST   /system/environment                  — simpan satu kategori (200)
//	POST   /system/environment/logo             — update logo (200)
//	POST   /system/environment/smtp-test        — uji koneksi SMTP (200)
package handler

import (
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/service"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// securityHandler — dependensi handler security (service layer saja).
type securityHandler struct {
	svcSessions *service.SessionsService
	svcSettings *service.SettingsService
	svcTrail    *service.AuditTrailService
	svcEnv      *service.EnvironmentService
}

// DaftarkanSecurity — pasang 16 route security/audit-trail/environment
// (path & method PERSIS controller NestJS) dengan guard JWT + RBAC.
func DaftarkanSecurity(api *echo.Group, d types.Deps) {
	h := &securityHandler{
		svcSessions: service.NewSessionsService(d.DB, d.Audit),
		svcSettings: service.NewSettingsService(d.DB, d.Audit),
		svcTrail:    service.NewAuditTrailService(d.DB, d.Audit),
		svcEnv:      service.NewEnvironmentService(d.DB, d.Audit),
	}

	g := api.Group("", d.AuthGuard, d.RbacGuard)

	sec := g.Group("/system/security")
	sec.GET("/sessions", h.sessions)
	sec.POST("/sessions/:id/revoke", h.revokeSession)
	sec.GET("/login-audit", h.loginAudit)
	sec.GET("/mfa", h.mfa)
	sec.POST("/mfa", h.setMfa)
	sec.GET("/password-history", h.passwordHistory)
	sec.GET("/ip-allowlist", h.ipAllowlist)
	sec.POST("/ip-allowlist", h.addIpAllowlist)
	sec.DELETE("/ip-allowlist/:id", h.removeIpAllowlist)

	trail := g.Group("/system/audit-trail")
	trail.GET("", h.auditTrail)
	trail.GET("/actions", h.auditTrailActions)
	trail.GET("/export", h.auditTrailExport)

	env := g.Group("/system/environment")
	env.GET("", h.environment)
	env.POST("", h.saveEnvironmentCategory)
	env.POST("/logo", h.updateCompanyLogo)
	env.POST("/smtp-test", h.smtpTest)
}

// ---------------------------------------------------------------------
// Helper kecil — query, body, error
// ---------------------------------------------------------------------

// pageReq — parse query pagination seragam (konvensi §6).
func pageReq(c echo.Context) (*errkontrak.PageRequest, error) {
	return errkontrak.ParsePageRequest(c.Request().URL.Query())
}

// searchOf — filter `search` (kosong/absen = tanpa filter).
func searchOf(pr *errkontrak.PageRequest) string { return pr.Filters["search"] }

// Helper permukaan HTTP (decodeBody/badBody/msgRequired/namaTipeJSON/
// msgMinString/msgMaxString/msgBukan/gagalValidasi) DIAMBIL DARI
// handler/tenants.go satu package — tidak dideklarasikan dobel di sini.

// issues-spesifik security di bawah memakai konstanta & fungsi bersama itu.

func okTrue(c echo.Context, status int) error {
	return c.JSON(status, map[string]any{"data": map[string]any{"ok": true}})
}

// isIntJS — Number.isInteger (float JSON; NaN/Inf tak mungkin dari JSON).
func isIntJS(n float64) bool { return n == math.Trunc(n) }

// zStr — field string wajib: ada issue? (Required / Expected string).
func zStr(m map[string]any, key string) (string, *errkontrak.FieldIssue) {
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

// zStrNullableOpt — z.string().min(min).max(max).nullable().optional():
// absent/null → nil (valid); ada → string dengan cek panjang.
func zStrNullableOpt(m map[string]any, key string, min, max int) (*string, []errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, nil
	}
	s, ok := v.(string)
	if !ok {
		return nil, []errkontrak.FieldIssue{{Field: key, Message: msgBukan("string", namaTipeJSON(v))}}
	}
	var issues []errkontrak.FieldIssue
	if len([]rune(s)) < min {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgMinString(min)})
	}
	if max > 0 && len([]rune(s)) > max {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgMaxString(max)})
	}
	if len(issues) > 0 {
		return nil, issues
	}
	return &s, nil
}

// zNumNullableOpt — z.number().int().positive().nullable().optional().
func zNumNullableOpt(m map[string]any, key string) (*int64, []errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada || v == nil {
		return nil, nil
	}
	n, ok := v.(float64)
	if !ok {
		return nil, []errkontrak.FieldIssue{{Field: key, Message: msgBukan("number", namaTipeJSON(v))}}
	}
	if !isIntJS(n) {
		return nil, []errkontrak.FieldIssue{{Field: key, Message: msgBukan("integer", "float")}}
	}
	if n < 1 {
		return nil, []errkontrak.FieldIssue{{Field: key, Message: "Number must be greater than 0"}}
	}
	x := int64(n)
	return &x, nil
}

// coerceID — padanan parseWith(revokeSessionSchema/numericIdSchema, …):
// Number(raw) → int ≥ 1. "abc" → nan; "" → 0; "5.5" → float; 0 → positive.
func coerceID(raw, field string) (int64, *errkontrak.FieldIssue) {
	s := strings.TrimSpace(raw)
	n := 0.0 // JS Number("") = 0
	if s != "" {
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return 0, &errkontrak.FieldIssue{Field: field, Message: msgBukan("number", "nan")}
		}
		n = f
	}
	if !isIntJS(n) {
		return 0, &errkontrak.FieldIssue{Field: field, Message: msgBukan("integer", "float")}
	}
	if n < 1 {
		return 0, &errkontrak.FieldIssue{Field: field, Message: "Number must be greater than 0"}
	}
	return int64(n), nil
}

func inList(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------
// Sesi
// ---------------------------------------------------------------------

func (h *securityHandler) sessions(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svcSessions.PageSessions(c.Request().Context(), pr, searchOf(pr))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *securityHandler) revokeSession(c echo.Context) error {
	sessionID, iss := coerceID(c.Param("id"), "sessionId")
	if iss != nil {
		return gagalValidasi(c, []errkontrak.FieldIssue{*iss})
	}
	if err := h.svcSessions.RevokeSession(c.Request().Context(), sessionID, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusOK)
}

// ---------------------------------------------------------------------
// Log login
// ---------------------------------------------------------------------

func (h *securityHandler) loginAudit(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	username := pr.Filters["username"]
	var success *bool
	if v, ada := pr.Filters["success"]; ada && v != "" {
		b := v == "true"
		success = &b
	}
	page, err := h.svcSessions.PageLoginAudit(c.Request().Context(), pr, username, success, searchOf(pr))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// ---------------------------------------------------------------------
// MFA
// ---------------------------------------------------------------------

func (h *securityHandler) mfa(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svcSettings.PageMfaStatus(c.Request().Context(), pr, searchOf(pr))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// validasiSetMfa — setMfaSchema {userId int positive, enabled boolean}.
func validasiSetMfa(m map[string]any) (types.SetMfaInput, []errkontrak.FieldIssue) {
	var in types.SetMfaInput
	var issues []errkontrak.FieldIssue
	if v, iss := zNumNullableOpt(m, "userId"); iss != nil {
		issues = append(issues, iss...)
	} else if v == nil {
		// nullable optional di helper; schema aslinya WAJIB — bedakan.
		if _, ada := m["userId"]; !ada {
			issues = append(issues, errkontrak.FieldIssue{Field: "userId", Message: msgRequired})
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "userId", Message: msgBukan("number", "null")})
		}
	} else {
		in.UserID = *v
	}
	v, ada := m["enabled"]
	if !ada {
		issues = append(issues, errkontrak.FieldIssue{Field: "enabled", Message: msgRequired})
	} else if b, ok := v.(bool); !ok {
		issues = append(issues, errkontrak.FieldIssue{Field: "enabled", Message: msgBukan("boolean", namaTipeJSON(v))})
	} else {
		in.Enabled = b
	}
	return in, issues
}

func (h *securityHandler) setMfa(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiSetMfa(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	if err := h.svcSettings.SetMfaEnabled(c.Request().Context(), in.UserID, in.Enabled, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusOK)
}

// ---------------------------------------------------------------------
// Riwayat password
// ---------------------------------------------------------------------

func (h *securityHandler) passwordHistory(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svcSettings.PagePasswordHistory(c.Request().Context(), pr, searchOf(pr))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// ---------------------------------------------------------------------
// IP allowlist
// ---------------------------------------------------------------------

func (h *securityHandler) ipAllowlist(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.svcSettings.PageIpAllowlist(c.Request().Context(), pr, searchOf(pr))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

var reCIDR = regexp.MustCompile(`^\d{1,3}(\.\d{1,3}){3}(\/(3[0-2]|[12]?\d))?$`)

// validasiCreateIpAllowlist — createIpAllowlistRuleSchema: minimal satu
// target (refine = CHECK DDL); CIDR IPv4 verbatim; note maks 200.
func validasiCreateIpAllowlist(m map[string]any) (types.CreateIpAllowlistRuleInput, []errkontrak.FieldIssue) {
	var in types.CreateIpAllowlistRuleInput
	var issues []errkontrak.FieldIssue

	roleCode, iss := zStrNullableOpt(m, "roleCode", 1, 0)
	if iss != nil {
		issues = append(issues, iss...)
	} else {
		in.RoleCode = roleCode
	}
	userID, iss := zNumNullableOpt(m, "userId")
	if iss != nil {
		issues = append(issues, iss...)
	} else {
		in.UserID = userID
	}
	cidr, ziss := zStr(m, "cidr")
	if ziss != nil {
		issues = append(issues, *ziss)
	} else if !reCIDR.MatchString(cidr) {
		issues = append(issues, errkontrak.FieldIssue{Field: "cidr", Message: "Format CIDR IPv4, mis. 10.10.4.0/24"})
	} else {
		in.Cidr = cidr
	}
	note, iss := zStrNullableOpt(m, "note", 0, 200)
	if iss != nil {
		issues = append(issues, iss...)
	} else {
		in.Note = note
	}

	// Refine zod hanya dijalankan bila parse field sukses (issues kosong).
	if len(issues) == 0 && in.RoleCode == nil && in.UserID == nil {
		issues = append(issues, errkontrak.FieldIssue{Field: "(root)", Message: "Aturan allowlist wajib menyasar role atau user"})
	}
	return in, issues
}

func (h *securityHandler) addIpAllowlist(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiCreateIpAllowlist(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	if err := h.svcSettings.AddIpAllowlistRule(c.Request().Context(), in, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusCreated)
}

func (h *securityHandler) removeIpAllowlist(c echo.Context) error {
	id, iss := coerceID(c.Param("id"), "id")
	if iss != nil {
		return gagalValidasi(c, []errkontrak.FieldIssue{*iss})
	}
	if err := h.svcSettings.RemoveIpAllowlistRule(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusOK)
}

// ---------------------------------------------------------------------
// Audit trail
// ---------------------------------------------------------------------

var reTanggal = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}`)

// parseFilterAuditTrail — auditTrailFilterSchema terhadap query string;
// urutan issue = urutan deklarasi field schema; key tidak dikirim = skip.
func parseFilterAuditTrail(c echo.Context) (types.AuditTrailFilter, []errkontrak.FieldIssue) {
	q := c.Request().URL.Query()
	var f types.AuditTrailFilter
	var issues []errkontrak.FieldIssue
	get := func(k string) (string, bool) {
		vs, ada := q[k]
		if !ada || len(vs) == 0 {
			return "", false
		}
		return vs[0], true
	}
	if v, ada := get("moduleKey"); ada {
		if !inList(types.ModuleKeyValues, v) {
			issues = append(issues, errkontrak.FieldIssue{Field: "moduleKey", Message: types.PesanEnum(types.ModuleKeyValues, v)})
		} else {
			f.ModuleKey = &v
		}
	}
	if v, ada := get("severity"); ada {
		if !inList(types.SeverityValues, v) {
			issues = append(issues, errkontrak.FieldIssue{Field: "severity", Message: types.PesanEnum(types.SeverityValues, v)})
		} else {
			f.Severity = &v
		}
	}
	if v, ada := get("action"); ada {
		if len([]rune(v)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "action", Message: msgMinString(1)})
		} else {
			f.Action = &v
		}
	}
	if v, ada := get("query"); ada {
		f.Query = &v
	}
	if v, ada := get("dateFrom"); ada {
		if !reTanggal.MatchString(v) {
			issues = append(issues, errkontrak.FieldIssue{Field: "dateFrom", Message: "Gunakan tanggal ISO (YYYY-MM-DD)"})
		} else {
			f.DateFrom = &v
		}
	}
	if v, ada := get("dateTo"); ada {
		if !reTanggal.MatchString(v) {
			issues = append(issues, errkontrak.FieldIssue{Field: "dateTo", Message: "Gunakan tanggal ISO (YYYY-MM-DD)"})
		} else {
			f.DateTo = &v
		}
	}
	return f, issues
}

func (h *securityHandler) auditTrail(c echo.Context) error {
	pr, err := pageReq(c)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	filter, issues := parseFilterAuditTrail(c)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	page, err := h.svcTrail.PageAuditTrail(c.Request().Context(), filter, pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

func (h *securityHandler) auditTrailActions(c echo.Context) error {
	actions, err := h.svcTrail.ListActions(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"data": actions})
}

func (h *securityHandler) auditTrailExport(c echo.Context) error {
	filter, issues := parseFilterAuditTrail(c)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	csv, disposition, err := h.svcTrail.ExportCsv(c.Request().Context(), filter, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	c.Response().Header().Set(echo.HeaderContentType, "text/csv; charset=utf-8")
	c.Response().Header().Set(echo.HeaderContentDisposition, disposition)
	return c.Blob(http.StatusOK, "text/csv; charset=utf-8", []byte(csv))
}

// ---------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------

func (h *securityHandler) environment(c echo.Context) error {
	data, err := h.svcEnv.GetEnvironment(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"data": data})
}

// validasiSaveCategory — saveEnvironmentCategorySchema {category enum,
// values record<string, string|boolean>}.
func validasiSaveCategory(m map[string]any) (types.SaveEnvironmentCategoryInput, []errkontrak.FieldIssue) {
	var in types.SaveEnvironmentCategoryInput
	var issues []errkontrak.FieldIssue
	category, iss := zStr(m, "category")
	if iss != nil {
		issues = append(issues, *iss)
	} else if !inList(types.CategoryValues, category) {
		issues = append(issues, errkontrak.FieldIssue{Field: "category", Message: types.PesanEnum(types.CategoryValues, category)})
	} else {
		in.Category = category
	}
	rv, ada := m["values"]
	if !ada {
		issues = append(issues, errkontrak.FieldIssue{Field: "values", Message: msgRequired})
	} else if obj, ok := rv.(map[string]any); !ok {
		issues = append(issues, errkontrak.FieldIssue{Field: "values", Message: msgBukan("object", namaTipeJSON(rv))})
	} else {
		values := make(map[string]any, len(obj))
		for k, v := range obj {
			switch t := v.(type) {
			case string:
				values[k] = t
			case bool:
				values[k] = t
			default:
				// union(string, boolean) gagal → "Invalid input".
				issues = append(issues, errkontrak.FieldIssue{Field: "values." + k, Message: "Invalid input"})
			}
		}
		in.Values = values
	}
	if in.Values == nil {
		in.Values = map[string]any{}
	}
	return in, issues
}

func (h *securityHandler) saveEnvironmentCategory(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	in, issues := validasiSaveCategory(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	if err := h.svcEnv.SaveEnvironmentCategory(c.Request().Context(), in, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusOK)
}

// validasiCompanyLogo — companyLogoSchema {logoName string,
// logoDataUrl string|null} (logoDataUrl WAJIB ada, boleh null).
func validasiCompanyLogo(m map[string]any) (types.CompanyLogo, []errkontrak.FieldIssue) {
	var in types.CompanyLogo
	var issues []errkontrak.FieldIssue
	name, iss := zStr(m, "logoName")
	if iss != nil {
		issues = append(issues, *iss)
	} else {
		in.LogoName = name
	}
	v, ada := m["logoDataUrl"]
	if !ada {
		issues = append(issues, errkontrak.FieldIssue{Field: "logoDataUrl", Message: msgRequired})
	} else if v == nil {
		in.LogoDataUrl = nil
	} else if s, ok := v.(string); ok {
		in.LogoDataUrl = s
	} else {
		issues = append(issues, errkontrak.FieldIssue{Field: "logoDataUrl", Message: msgBukan("string", namaTipeJSON(v))})
	}
	return in, issues
}

func (h *securityHandler) updateCompanyLogo(c echo.Context) error {
	m, ok := decodeBody(c)
	if !ok {
		return badBody(c, nil)
	}
	logo, issues := validasiCompanyLogo(m)
	if len(issues) > 0 {
		return gagalValidasi(c, issues)
	}
	if err := h.svcEnv.UpdateCompanyLogo(c.Request().Context(), logo, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return okTrue(c, http.StatusOK)
}

func (h *securityHandler) smtpTest(c echo.Context) error {
	result, err := h.svcEnv.TestSmtp(c.Request().Context(), shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, map[string]any{"data": result})
}
