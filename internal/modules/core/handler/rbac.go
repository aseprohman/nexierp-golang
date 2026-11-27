// Handler RBAC fitur modul core — TIPIS: parse (zod padanan) → service →
// envelope `{data, meta?}` (port VERBATIM controllers/rbac/{users,roles,
// modules,overview}.controller.ts NestJS; penegakan permission ROUTE-CENTRIC
// via guard AuthGuard + RbacGuard per group — TANPA @RequirePermission).
//
// GET   /system/users                    — halaman user + filter q/role
// GET   /system/users/:id                — detail berelasi (UserDetail)
// POST  /system/users                    — buat user (multi-role) 201
// PATCH /system/users/:id/active         — aktif/nonaktif (+cabut sesi)
// POST  /system/users/:id/password-reset — reset password (tampil sekali)
// POST  /system/users/:id/unlock         — buka kunci
// PUT   /system/users/:id/roles          — REPLACE junction multi-role
// GET   /system/roles                    — daftar role + memberCount
// GET   /system/roles/public             — ringkas dropdown (identik list)
// POST  /system/roles                    — buat role 201
// PATCH /system/roles/:id                — update role (kode immutable)
// GET   /system/roles/:id/permissions    — DISTINCT code via grant SET
// GET   /system/roles/:id/permission-sets — id SET yang di-grant
// PUT   /system/roles/:id/permissions    — REPLACE grant BY SET id
// GET   /system/roles/:id/menus/ids      — id menu milik role (sort asc)
// GET   /system/modules                  — registry modul (rank enum)
// POST  /system/modules/:key/enable      — aktifkan modul
// POST  /system/modules/:key/disable     — nonaktifkan (is_core → 409)
// GET   /system/health                   — {status:"ok"}
// GET   /system/overview                 — 8 agregat paralel
// GET   /system/overview/audit           — N audit terbaru (clamp 1..100)
package handler

import (
	"encoding/json"
	"io"
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

// DaftarkanRbac — pasang seluruh route RBAC (guard di tiap group; route
// statis `/system/roles/public` didaftarkan SEBELUM `:id` — statis menang).
func DaftarkanRbac(api *echo.Group, d types.Deps) {
	h := &rbacHandlers{
		users:    service.NewUsersService(d),
		roles:    service.NewRolesService(d),
		modules:  service.NewModulesService(d),
		overview: service.NewOverviewService(d),
	}
	guard := []echo.MiddlewareFunc{d.AuthGuard, d.RbacGuard}

	users := api.Group("/system/users", guard...)
	users.GET("", h.usersList)
	users.POST("", h.userCreate)
	users.GET("/:id", h.userDetail)
	users.PATCH("/:id/active", h.userSetActive)
	users.POST("/:id/password-reset", h.userResetPassword)
	users.POST("/:id/unlock", h.userUnlock)
	users.PUT("/:id/roles", h.userAssignRoles)

	roles := api.Group("/system/roles", guard...)
	roles.GET("", h.rolesList)
	roles.GET("/public", h.rolesListPublic) // statis — sebelum :id
	roles.POST("", h.roleCreate)
	roles.PATCH("/:id", h.roleUpdate)
	roles.GET("/:id/permissions", h.rolePermissions)
	roles.GET("/:id/permission-sets", h.rolePermissionSets)
	roles.PUT("/:id/permissions", h.roleReplacePermissions)
	roles.GET("/:id/menus/ids", h.roleMenuIds)

	modules := api.Group("/system/modules", guard...)
	modules.GET("", h.modulesList)
	modules.POST("/:key/enable", h.moduleEnable)
	modules.POST("/:key/disable", h.moduleDisable)

	health := api.Group("/system/health", guard...)
	health.GET("", h.healthCheck)

	overview := api.Group("/system/overview", guard...)
	overview.GET("", h.overviewStats)
	overview.GET("/audit", h.overviewRecentAudit)
}

// rbacHandlers — dependensi fitur RBAC (method BERNAMA — nama runtime
// stabil untuk permission code cmd/scanroute).
type rbacHandlers struct {
	users    *service.UsersService
	roles    *service.RolesService
	modules  *service.ModulesService
	overview *service.OverviewService
}

/* ================================================================
// Users
// ================================================================ */

// usersList — GET "" — halaman user (multi-role per user): {data, meta}.
func (h *rbacHandlers) usersList(c echo.Context) error {
	pr, err := errkontrak.ParsePageRequest(c.QueryParams())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	// Whitelist sort users (USERS_SORT_COLUMNS) — di luar → 400.
	if err := shared.SortUnknown(pr, []string{"username", "name", "created_at", "updated_at"}); err != nil {
		return errkontrak.Map(c, err)
	}
	page, err := h.users.List(c.Request().Context(), pr)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return c.JSON(http.StatusOK, page)
}

// userDetail — GET "/:id" — detail berelasi: {data: UserDetail}.
func (h *rbacHandlers) userDetail(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	detail, err := h.users.Detail(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, detail)
}

// userCreate — POST "" — buat user: {data: UserView} 201.
func (h *rbacHandlers) userCreate(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	in, issues := validasiCreateUser(m)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	view, err := h.users.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// userSetActive — PATCH "/:id/active" — {data: {ok: true}}.
func (h *rbacHandlers) userSetActive(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	issues := []errkontrak.FieldIssue{}
	isActive, ada := rbacBool(m, "isActive", true, &issues)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.users.SetActive(c.Request().Context(), id, isActive && ada, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

// userResetPassword — POST "/:id/password-reset" — password sementara
// TAMPIL SEKALI: {data: {temporaryPassword}}.
func (h *rbacHandlers) userResetPassword(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	issues := []errkontrak.FieldIssue{}
	pwd, provided := rbacOptionalString(m, "temporaryPassword", 8, "", &issues)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	password, err := h.users.ResetPassword(c.Request().Context(), id, pwd, provided, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"temporaryPassword": password})
}

// userUnlock — POST "/:id/unlock" — {data: {ok: true}}.
func (h *rbacHandlers) userUnlock(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	if err := h.users.Unlock(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"ok": true})
}

// userAssignRoles — PUT "/:id/roles" — REPLACE junction: {data: {roles}}.
func (h *rbacHandlers) userAssignRoles(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	issues := []errkontrak.FieldIssue{}
	roleIds := rbacIds(m, "roleIds", "Minimal satu role", &issues)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	roles, err := h.users.AssignRoles(c.Request().Context(), id, roleIds, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"roles": roles})
}

/* ================================================================
// Roles
// ================================================================ */

// rolesList — GET "" — semua role + jumlah member: {data: RoleView[]}.
func (h *rbacHandlers) rolesList(c echo.Context) error {
	data, err := h.roles.List(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// rolesListPublic — GET "/public" — ringkas dropdown (identik list).
func (h *rbacHandlers) rolesListPublic(c echo.Context) error {
	return h.rolesList(c)
}

// roleCreate — POST "" — {data: RoleView} 201.
func (h *rbacHandlers) roleCreate(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	in, issues := validasiCreateRole(m)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	view, err := h.roles.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.Created(c, view)
}

// roleUpdate — PATCH "/:id" — {data: RoleView}; kode immutable.
func (h *rbacHandlers) roleUpdate(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	in, issues := validasiUpdateRole(m, c.Param("id"))
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	view, err := h.roles.Update(c.Request().Context(), in.ID, service.RoleUpdateInput{
		Role:           in.Role,
		Description:    in.Description,
		HasDescription: in.HasDescription,
	}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, view)
}

// rolePermissions — GET "/:id/permissions" — DISTINCT code: {data: string[]}.
func (h *rbacHandlers) rolePermissions(c echo.Context) error {
	data, err := h.roles.GetPermissions(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// rolePermissionSets — GET "/:id/permission-sets" — {data: number[]}.
func (h *rbacHandlers) rolePermissionSets(c echo.Context) error {
	data, err := h.roles.GetPermissionSetIDs(c.Request().Context(), c.Param("id"))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// roleReplacePermissions — PUT "/:id/permissions" — {data: {granted}}.
func (h *rbacHandlers) roleReplacePermissions(c echo.Context) error {
	m, ok := rbacDecodeBody(c)
	if !ok {
		return rbacBadBody(c)
	}
	issues := []errkontrak.FieldIssue{}
	permissionIds := rbacIds(m, "permissionIds", "", &issues)
	if len(issues) > 0 {
		return rbacIssues400(c, issues)
	}
	granted, err := h.roles.ReplacePermissions(c.Request().Context(), c.Param("id"), service.ReplacePermissionsInput{PermissionIds: permissionIds}, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, map[string]any{"granted": granted})
}

// roleMenuIds — GET "/:id/menus/ids" — {data: number[]} (sort asc).
func (h *rbacHandlers) roleMenuIds(c echo.Context) error {
	id, err := shared.ParseIDParam(c.Param("id"), "id")
	if err != nil {
		return errkontrak.Map(c, err)
	}
	data, err := h.roles.MenuIDs(c.Request().Context(), id)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

/* ================================================================
// Modules + health
// ================================================================ */

// modulesList — GET "" — registry modul: {data: ModuleRegistryView[]}.
func (h *rbacHandlers) modulesList(c echo.Context) error {
	data, err := h.modules.List(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// moduleEnable — POST "/:key/enable" — {data: {changed, key, enabled}}.
func (h *rbacHandlers) moduleEnable(c echo.Context) error {
	return h.moduleSetEnabled(c, true)
}

// moduleDisable — POST "/:key/disable" — is_core ditolak 409.
func (h *rbacHandlers) moduleDisable(c echo.Context) error {
	return h.moduleSetEnabled(c, false)
}

func (h *rbacHandlers) moduleSetEnabled(c echo.Context, enabled bool) error {
	data, err := h.modules.SetEnabled(c.Request().Context(), c.Param("key"), enabled, shared.ActorOf(c.Request()))
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// healthCheck — GET "/system/health" — {data: {status: "ok"}}.
func (h *rbacHandlers) healthCheck(c echo.Context) error {
	return errkontrak.OK(c, map[string]any{"status": "ok"})
}

/* ================================================================
// Overview
// ================================================================ */

// overviewStats — GET "" — {data: OverviewStats} (8 agregat paralel).
func (h *rbacHandlers) overviewStats(c echo.Context) error {
	data, err := h.overview.Stats(c.Request().Context())
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

// overviewRecentAudit — GET "/audit" — limit clamp 1..100 default 8
// TANPA 400 (query tidak valid → fallback 8).
func (h *rbacHandlers) overviewRecentAudit(c echo.Context) error {
	raw := strings.TrimSpace(c.QueryParam("limit"))
	limit := 8
	if raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}
	data, err := h.overview.RecentAudit(c.Request().Context(), limit)
	if err != nil {
		return errkontrak.Map(c, err)
	}
	return errkontrak.OK(c, data)
}

/* ================================================================
// Validasi body — pesan & urutan issue zod v3 (padanan
// packages/schemas core/{users,roles}.ts — TANPA .trim())
// ================================================================ */

var (
	reUsername    = regexp.MustCompile(`^[a-z0-9_.-]+$`)
	reKodeRole    = regexp.MustCompile(`^[a-z0-9_-]+$`)
	msgUsernameRe = "Username: huruf kecil, angka, titik, underscore, dash"
	msgKodeRoleRe = "Kode role: huruf kecil, angka, dash/underscore"
	msgFullName   = "Nama lengkap wajib diisi"
	msgDepartment = "Departemen wajib diisi"
	msgSatuRole   = "Minimal satu role"
	msgNamaRole   = "Nama role wajib diisi"
)

/* ----------------------------------------------------------------
// Helper lokal fitur RBAC — decode body + pesan & urutan issue zod v3
// (VERBATIM default message zod 3.25 yang dipakai packages/schemas).
// Sengaja ber-prefix `rbac` — tidak meminjam helper fitur lain agar
// perubahan milik fitur lain tidak menggeser kontrak RBAC.
// ---------------------------------------------------------------- */

// Pesan default zod v3 (verbatim locales/en.js).
const (
	rbacMsgRequired = "Required"
	rbacMsgEmail    = "Invalid email"
)

func rbacMsgMinString(n int) string {
	return "String must contain at least " + strconv.Itoa(n) + " character(s)"
}

func rbacMsgMaxString(n int) string {
	return "String must contain at most " + strconv.Itoa(n) + " character(s)"
}

func rbacMsgGreaterThan(n int64) string {
	return "Number must be greater than " + strconv.FormatInt(n, 10)
}

func rbacMsgExpected(expected, received string) string {
	return "Expected " + expected + ", received " + received
}

// rbacNamaTipe — getParsedType zod untuk nilai JSON apa pun.
func rbacNamaTipe(v any) string {
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

// rbacReEmail — regex email default zod v3 (verbatim emailRegexps.z.EmailURL).
var rbacReEmail = regexp.MustCompile(`^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$`)

// rbacDecodeBody — baca body request → map JSON; ok=false bila rusak.
// Body kosong = objek kosong (field opsional tetap lolos — zod).
func rbacDecodeBody(c echo.Context) (map[string]any, bool) {
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

// rbacBadBody — 400 VAL-400 detail "Body tidak valid" (JSON rusak).
func rbacBadBody(c echo.Context) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid",
		[]errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}})
}

// rbacIssues400 — padanan parseWith gagal: 400 VAL-400 detail "Data tidak
// valid." + issues (problem+json ditulis langsung, bukan error mentah echo).
func rbacIssues400(c echo.Context, issues []errkontrak.FieldIssue) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
}

// rbacString — z.string() (opsional bila !wajib; null → invalid_type):
// (nilai, ada=nilai string valid?). TANPA trim — skema RBAC tak memakai itu.
func rbacString(m map[string]any, key string, wajib bool, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada {
		if !wajib {
			return "", false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgRequired})
		return "", false
	}
	if v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgExpected("string", "null")})
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgExpected("string", rbacNamaTipe(v))})
		return "", false
	}
	return s, true
}

// rbacOptionalString — z.string().min(min).optional(): (nilai, eksplisit?).
func rbacOptionalString(m map[string]any, key string, min int, pesanMin string, issues *[]errkontrak.FieldIssue) (string, bool) {
	s, ada := rbacString(m, key, false, issues)
	if !ada {
		return "", false
	}
	if len([]rune(s)) < min {
		pesan := pesanMin
		if pesan == "" {
			pesan = rbacMsgMinString(min)
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	return s, true
}

// rbacBool — z.boolean() (wajib) / .optional() bila !wajib: (nilai, eksplisit?).
func rbacBool(m map[string]any, key string, wajib bool, issues *[]errkontrak.FieldIssue) (bool, bool) {
	v, ada := m[key]
	if !ada {
		if !wajib {
			return false, false
		}
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgRequired})
		return false, false
	}
	b, ok := v.(bool)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgExpected("boolean", rbacNamaTipe(v))})
		return false, ada
	}
	return b, ada
}

// rbacIds — z.array(z.number().int().positive()).min(1, pesanMin):
// elemen bermasalah → issue path `key.i`; min length dicek SETELAH elemen
// (urutan zod; pesanMin kosong = pesan default zod).
func rbacIds(m map[string]any, key string, pesanMin string, issues *[]errkontrak.FieldIssue) []int64 {
	v, ada := m[key]
	if !ada {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgRequired})
		return nil
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: rbacMsgExpected("array", rbacNamaTipe(v))})
		return nil
	}
	out := make([]int64, 0, len(arr))
	for i, el := range arr {
		path := key + "." + strconv.Itoa(i)
		f, okF := el.(float64)
		if !okF {
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: rbacMsgExpected("number", rbacNamaTipe(el))})
			continue
		}
		if f != float64(int64(f)) { // .int()
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: rbacMsgExpected("integer", "float")})
		}
		if f <= 0 { // .positive() → too_small inclusive:false
			*issues = append(*issues, errkontrak.FieldIssue{Field: path, Message: rbacMsgGreaterThan(0)})
		}
		out = append(out, int64(f))
	}
	if len(arr) < 1 && pesanMin != "" {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: pesanMin})
	}
	return out
}

// rbacIDFromRaw — Number(raw) semantik z.number().int().positive() untuk id
// PATCH role (schema id dari path — BUKAN parseIdParam): NaN → "nan",
// pecahan → "float", ≤ 0 → "Number must be greater than 0".
func rbacIDFromRaw(raw string, issues *[]errkontrak.FieldIssue) int64 {
	raw = strings.TrimSpace(raw)
	f := 0.0
	if raw != "" {
		parsed, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "id", Message: rbacMsgExpected("number", "nan")})
			return 0
		}
		f = parsed
	}
	if f != f { // NaN
		*issues = append(*issues, errkontrak.FieldIssue{Field: "id", Message: rbacMsgExpected("number", "nan")})
		return 0
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "id", Message: rbacMsgExpected("integer", "float")})
	}
	if f <= 0 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "id", Message: rbacMsgGreaterThan(0)})
	}
	return int64(f)
}

// validasiCreateUser — createUserSchema (urutan key schema: username,
// email, fullName, department, roleIds, isActive default true).
func validasiCreateUser(m map[string]any) (service.CreateUserInput, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	in := service.CreateUserInput{IsActive: true}

	if s, ada := rbacString(m, "username", true, &issues); ada {
		if len([]rune(s)) < 3 {
			issues = append(issues, errkontrak.FieldIssue{Field: "username", Message: rbacMsgMinString(3)})
		}
		if len([]rune(s)) > 64 {
			issues = append(issues, errkontrak.FieldIssue{Field: "username", Message: rbacMsgMaxString(64)})
		}
		if !reUsername.MatchString(s) {
			issues = append(issues, errkontrak.FieldIssue{Field: "username", Message: msgUsernameRe})
		}
		in.Username = s
	}

	if s, ada := rbacString(m, "email", false, &issues); ada {
		if !rbacReEmail.MatchString(s) {
			issues = append(issues, errkontrak.FieldIssue{Field: "email", Message: rbacMsgEmail})
		}
		in.Email = s
	}

	if s, ada := rbacString(m, "fullName", true, &issues); ada {
		if len([]rune(s)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "fullName", Message: msgFullName})
		}
		in.FullName = s
	}

	if s, ada := rbacString(m, "department", true, &issues); ada {
		if len([]rune(s)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "department", Message: msgDepartment})
		}
		in.Department = s
	}

	in.RoleIds = rbacIds(m, "roleIds", msgSatuRole, &issues)

	if b, ada := rbacBool(m, "isActive", false, &issues); ada {
		in.IsActive = b
	}
	return in, issues
}

// validasiCreateRole — createRoleSchema (code/role/description).
func validasiCreateRole(m map[string]any) (service.RoleCreateInput, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	var in service.RoleCreateInput

	if s, ada := rbacString(m, "code", true, &issues); ada {
		if len([]rune(s)) < 2 {
			issues = append(issues, errkontrak.FieldIssue{Field: "code", Message: rbacMsgMinString(2)})
		}
		if len([]rune(s)) > 32 {
			issues = append(issues, errkontrak.FieldIssue{Field: "code", Message: rbacMsgMaxString(32)})
		}
		if !reKodeRole.MatchString(s) {
			issues = append(issues, errkontrak.FieldIssue{Field: "code", Message: msgKodeRoleRe})
		}
		in.Code = s
	}

	if s, ada := rbacString(m, "role", true, &issues); ada {
		if len([]rune(s)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "role", Message: msgNamaRole})
		}
		in.Role = s
	}

	if s, ada := rbacString(m, "description", false, &issues); ada {
		if len([]rune(s)) > 500 {
			issues = append(issues, errkontrak.FieldIssue{Field: "description", Message: rbacMsgMaxString(500)})
		}
		d := s
		in.Description = &d
	}
	return in, issues
}

// roleUpdateIn — hasil parse PATCH role (id dari path via schema).
type roleUpdateIn struct {
	ID             int64
	Role           *string
	Description    *string
	HasDescription bool
}

// validasiUpdateRole — updateRoleSchema {id, role?, description? nullish}:
// id = Number(path) divalidasi zod (bukan parseIdParam); urutan key schema:
// id → role → description.
func validasiUpdateRole(m map[string]any, idRaw string) (roleUpdateIn, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	in := roleUpdateIn{ID: rbacIDFromRaw(idRaw, &issues)}

	if s, ada := rbacString(m, "role", false, &issues); ada {
		if len([]rune(s)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "role", Message: rbacMsgMinString(1)})
		}
		in.Role = &s
	}

	if v, ada := m["description"]; ada {
		if v == nil { // null eksplisit — nullable
			in.HasDescription = true
		} else if s, ok := v.(string); ok {
			if len([]rune(s)) > 500 {
				issues = append(issues, errkontrak.FieldIssue{Field: "description", Message: rbacMsgMaxString(500)})
			}
			in.Description = &s
			in.HasDescription = true
		} else {
			issues = append(issues, errkontrak.FieldIssue{Field: "description", Message: rbacMsgExpected("string", rbacNamaTipe(v))})
		}
	}
	return in, issues
}
