// Package handler — endpoint HTTP fitur IAM modul core (padankan
// controllers/iam/*.ts NestJS; 30 endpoint). TIPIS: parse + validasi body
// (pesan zod PERSIS skema @nexierp/schemas — termasuk DS-*-40x) → Service →
// bentuk respons `{data}` / `{data, meta}`. Penegakan permission =
// ROUTE-CENTRIC: guard pasangan (AuthGuard + RbacGuard) per group.
package handler

import (
	"encoding/json"
	"fmt"
	"io"
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

// DaftarkanIam — pasang SEMUA route IAM di bawah group /api (kontrak kawat
// verbatim NestJS; path statis didaftarkan SEBELUM ":id").
func DaftarkanIam(api *echo.Group, d types.Deps) {
	deps := service.Deps{DB: d.DB, Audit: d.Audit, Registry: d.Registry, Compiler: d.Compiler}
	routesSvc := service.NewIamRoutesService(deps)
	permsSvc := service.NewIamPermissionsService(deps)
	menusSvc := service.NewIamMenusService(deps)
	featuresSvc := service.NewIamFeaturesService(deps)
	overridesSvc := service.NewIamUserOverridesService(deps)
	datascopeSvc := service.NewIamDatascopeService(deps)

	// Padankan @UseGuards(JwtAuthGuard, PermissionsGuard) per controller.
	m := make([]echo.MiddlewareFunc, 0, 2)
	if d.AuthGuard != nil {
		m = append(m, d.AuthGuard)
	}
	if d.RbacGuard != nil {
		m = append(m, d.RbacGuard)
	}

	// ---- /system/routes (IamRoutesController) ----
	g := api.Group("/system/routes", m...)
	g.GET("", hRoutesList(routesSvc))
	g.GET("/map", hRoutesMap(routesSvc))
	g.POST("/reload", hRoutesReload(routesSvc))
	g.GET("/:id", hRoutesGet(routesSvc))

	// ---- /system/permissions (IamPermissionsController) ----
	g = api.Group("/system/permissions", m...)
	g.GET("", hPermissionsList(permsSvc))
	g.POST("", hPermissionsCreate(permsSvc))
	g.PATCH("/:id", hPermissionsUpdate(permsSvc))
	g.DELETE("/:id", hPermissionsRemove(permsSvc))
	g.PUT("/:id/routes", hPermissionsAssignRoutes(permsSvc))
	g.GET("/:id/routes", hPermissionsFindRoutes(permsSvc))

	// ---- /system/menus (IamMenusController) ----
	g = api.Group("/system/menus", m...)
	g.GET("", hMenusList(menusSvc))
	g.POST("", hMenusCreate(menusSvc))
	g.PATCH("/:id", hMenusUpdate(menusSvc))
	g.DELETE("/:id", hMenusRemove(menusSvc))
	g.PUT("/:id/roles", hMenusAssignRoles(menusSvc))

	// ---- /system/features (IamFeaturesController — @Controller("system")) ----
	g = api.Group("/system/features", m...)
	g.GET("", hFeaturesList(featuresSvc))
	g.PATCH("/:id", hFeaturesSetActive(featuresSvc))

	// ---- /system/user-overrides (IamUserOverridesController) ----
	g = api.Group("/system/user-overrides", m...)
	g.GET("", hOverridesList(overridesSvc))
	g.POST("", hOverridesCreate(overridesSvc))
	g.DELETE("/:id", hOverridesRemove(overridesSvc))

	// ---- /system/datascope (IamDatascopeController) ----
	g = api.Group("/system/datascope", m...)
	g.GET("/definitions", hScopeListDefinitions(datascopeSvc))
	g.POST("/definitions", hScopeCreateDefinition(datascopeSvc))
	g.PATCH("/definitions/:id", hScopeUpdateDefinition(datascopeSvc))
	g.DELETE("/definitions/:id", hScopeDeleteDefinition(datascopeSvc))
	g.GET("/definitions/:id/assignments", hScopeListAssignments(datascopeSvc))
	g.GET("/definitions/:id/options", hScopeListOptions(datascopeSvc))
	g.POST("/assignments", hScopeCreateAssignment(datascopeSvc))
	g.PATCH("/assignments/:id", hScopeUpdateAssignment(datascopeSvc))
	g.DELETE("/assignments/:id", hScopeDeleteAssignment(datascopeSvc))
	g.PUT("/assignments/:id/values", hScopeSetValues(datascopeSvc))
}

// ---------------------------------------------------------------------
// Helper bentuk respons & body (padankan parseWith + parseIdParam + ctx)
// ---------------------------------------------------------------------

// hErr — pemetaan error service → problem+json (satu pintu).
func hErr(c echo.Context, err error) error { return errkontrak.Map(c, err) }

// iamBody — decode JSON body → map; ok=false bila rusak (400 "Body tidak
// valid", padankan parseBody).
func iamBody(c echo.Context) (map[string]any, bool) {
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

// iamBadBody — 400 VAL-400 "Body tidak valid" + issues (padankan parseBody).
func iamBadBody(c echo.Context, issues []errkontrak.FieldIssue) error {
	if len(issues) == 0 {
		issues = []errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}}
	}
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid", issues)
}

// iamInvalid — gagal validasi zod → DomainError.validation (detail default
// "Data tidak valid.").
func iamInvalid(issues []errkontrak.FieldIssue) error {
	return errkontrak.Validation(issues)
}

// iamTypeName — nama tipe zod untuk nilai JSON apa pun (parsedType).
func iamTypeName(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		if math.IsNaN(t) {
			return "nan"
		}
		if math.IsInf(t, 0) {
			return "infinity"
		}
		if t == math.Trunc(t) {
			return "int"
		}
		return "float"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "unknown"
	}
}

// iamExpect — issue invalid_type `Expected X, received Y` (default zod).
func iamExpect(field, expected string, v any) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{
		Field:   field,
		Message: fmt.Sprintf("Expected %s, received %s", expected, iamTypeName(v)),
	}
}

// iamRequired — issue field wajib absen (default zod "Required").
func iamRequired(field string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: "Required"}
}

// iamNum — angka dari nilai JSON (int check terpisah).
func iamNum(v any) (float64, bool) {
	n, ok := v.(float64)
	return n, ok
}

// iamIsInt — bilangan bulat (zod .int(): parsedType float → invalid).
func iamIsInt(n float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && n == math.Trunc(n)
}

// iamOptStr — field string opsional (z.string().optional()): hadir non-null
// wajib string; null TIDAK diizinkan untuk optional tanpa nullable.
// Kembalikan (nilai, hadir, ok).
func iamOptStr(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (string, bool, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return "", false, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, iamExpect(key, "string", v))
		return "", true, false
	}
	return s, true, true
}

// iamOptStrNull — field string opsional+nullable (null = bersihkan kolom).
func iamOptStrNull(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*string, bool, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false, true
	}
	if v == nil {
		return nil, true, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, iamExpect(key, "string", v))
		return nil, true, false
	}
	return &s, true, true
}

// iamOptIntNull — field number opsional+nullable (int ≥ 1; null = bersihkan).
func iamOptIntNull(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*int64, bool, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false, true
	}
	if v == nil {
		return nil, true, true
	}
	n, ok := iamNum(v)
	if !ok {
		*issues = append(*issues, iamExpect(key, "number", v))
		return nil, true, false
	}
	if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(v))})
		return nil, true, false
	}
	if n < 1 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: "Number must be greater than 0"})
		return nil, true, false
	}
	x := int64(n)
	return &x, true, true
}

// iamOptIntNullPlain — field number opsional+nullable TANPA positive
// (z.number().int().nullable().optional() — kolom `order` menu).
func iamOptIntNullPlain(m map[string]any, key string, issues *[]errkontrak.FieldIssue) (*int32, bool, bool) {
	v, ada := m[key]
	if !ada {
		return nil, false, true
	}
	if v == nil {
		return nil, true, true
	}
	n, ok := iamNum(v)
	if !ok {
		*issues = append(*issues, iamExpect(key, "number", v))
		return nil, true, false
	}
	if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(v))})
		return nil, true, false
	}
	x := int32(n)
	return &x, true, true
}

// iamArrayInts — array number int ≥1 wajib (assignRoutes/menuIds).
func iamArrayInts(m map[string]any, key string, issues *[]errkontrak.FieldIssue) ([]int64, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		*issues = append(*issues, iamRequired(key))
		return nil, false
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, iamExpect(key, "array", v))
		return nil, false
	}
	out := make([]int64, 0, len(arr))
	okAll := true
	for _, item := range arr {
		n, isNum := iamNum(item)
		if !isNum {
			*issues = append(*issues, iamExpect(key, "number", item))
			okAll = false
			continue
		}
		if !iamIsInt(n) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(item))})
			okAll = false
			continue
		}
		if n < 1 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: "Number must be greater than 0"})
			okAll = false
			continue
		}
		out = append(out, int64(n))
	}
	return out, okAll
}

// iamStrReqMinMax — string wajib dengan batas panjang (pesa default zod).
func iamStrReqMinMax(m map[string]any, key string, min, max int, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		*issues = append(*issues, iamRequired(key))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, iamExpect(key, "string", v))
		return "", false
	}
	if len([]rune(s)) < min {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("String must contain at least %d character(s)", min)})
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("String must contain at most %d character(s)", max)})
	}
	return s, true
}

// iamOptStrMinMax — string opsional dengan batas panjang (null → invalid
// karena optional tanpa nullable).
func iamOptStrMinMax(m map[string]any, key string, max int, issues *[]errkontrak.FieldIssue) (string, bool, bool) {
	v, ada := m[key]
	if !ada || v == nil {
		return "", false, true
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, iamExpect(key, "string", v))
		return "", true, false
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: fmt.Sprintf("String must contain at most %d character(s)", max)})
	}
	return s, true, true
}

// ---------------------------------------------------------------------
// /system/routes
// ---------------------------------------------------------------------

func hRoutesList(svc *service.IamRoutesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := errkontrak.ParsePageRequest(c.QueryParams())
		if err != nil {
			return hErr(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return hErr(c, err)
		}
		return c.JSON(http.StatusOK, page) // { data, meta }
	}
}

func hRoutesMap(svc *service.IamRoutesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, err := svc.Map(c.Request().Context())
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, m)
	}
}

func hRoutesReload(svc *service.IamRoutesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		return errkontrak.OK(c, svc.Reload()) // { total } — TANPA audit
	}
}

func hRoutesGet(svc *service.IamRoutesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		view, err := svc.Get(c.Request().Context(), id)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

// ---------------------------------------------------------------------
// /system/permissions
// ---------------------------------------------------------------------

func hPermissionsList(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		pr, err := errkontrak.ParsePageRequest(c.QueryParams())
		if err != nil {
			return hErr(c, err)
		}
		page, err := svc.List(c.Request().Context(), pr)
		if err != nil {
			return hErr(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

// parseCreatePermission — createPermissionSchema: {name 1..150 wajib,
// description?, moduleKey?, featuresFolder?}.
func parseCreatePermission(m map[string]any, issues *[]errkontrak.FieldIssue) service.CreatePermissionInput {
	var in service.CreatePermissionInput
	in.Name, _ = iamStrReqMinMax(m, "name", 1, 150, issues)
	if s, ada, ok := iamOptStr(m, "description", issues); ada && ok {
		in.Description = &s
	}
	if s, ada, ok := iamOptStr(m, "moduleKey", issues); ada && ok {
		in.ModuleKey = &s
	}
	if s, ada, ok := iamOptStr(m, "featuresFolder", issues); ada && ok {
		in.FeaturesFolder = &s
	}
	return in
}

func hPermissionsCreate(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseCreatePermission(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

// parseUpdatePermission — updatePermissionSchema (semua opsional; null =
// bersihkan; status enum active|disabled).
func parseUpdatePermission(m map[string]any, issues *[]errkontrak.FieldIssue) service.UpdatePermissionInput {
	var in service.UpdatePermissionInput
	if v, ada := m["name"]; ada {
		in.HasName = true
		if v == nil {
			in.Name = nil
		} else if s, ok := v.(string); !ok {
			*issues = append(*issues, iamExpect("name", "string", v))
		} else {
			if len([]rune(s)) < 1 {
				*issues = append(*issues, errkontrak.FieldIssue{Field: "name", Message: "String must contain at least 1 character(s)"})
			}
			if len([]rune(s)) > 150 {
				*issues = append(*issues, errkontrak.FieldIssue{Field: "name", Message: "String must contain at most 150 character(s)"})
			}
			in.Name = &s
		}
	}
	if v, ada := m["description"]; ada {
		in.HasDescription = true
		if v == nil {
			in.Description = nil
		} else if s, ok := v.(string); !ok {
			*issues = append(*issues, iamExpect("description", "string", v))
		} else {
			in.Description = &s
		}
	}
	if v, ada := m["status"]; ada {
		in.HasStatus = true
		s, ok := v.(string)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "status", Message: fmt.Sprintf("Expected 'active' | 'disabled', received %s", iamEnumValue(v))})
		} else if s != "active" && s != "disabled" {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "status", Message: fmt.Sprintf("Invalid enum value. Expected 'active' | 'disabled', received '%s'", s)})
		} else {
			in.Status = s
		}
	}
	if v, ada := m["moduleKey"]; ada {
		in.HasModuleKey = true
		if v == nil {
			in.ModuleKey = nil
		} else if s, ok := v.(string); !ok {
			*issues = append(*issues, iamExpect("moduleKey", "string", v))
		} else {
			in.ModuleKey = &s
		}
	}
	if v, ada := m["featuresFolder"]; ada {
		in.HasFeatures = true
		if v == nil {
			in.FeaturesFolder = nil
		} else if s, ok := v.(string); !ok {
			*issues = append(*issues, iamExpect("featuresFolder", "string", v))
		} else {
			in.FeaturesFolder = &s
		}
	}
	return in
}

// iamEnumValue — bentuk ringkas nilai untuk pesan enum.
func iamEnumValue(v any) string {
	if s, ok := v.(string); ok {
		return "'" + s + "'"
	}
	return iamTypeName(v)
}

func hPermissionsUpdate(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseUpdatePermission(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hPermissionsRemove(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

func hPermissionsAssignRoutes(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := service.AssignRoutesInput{}
		in.RouteIds, _ = iamArrayInts(m, "routeIds", &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		res, err := svc.AssignRoutes(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, res)
	}
}

func hPermissionsFindRoutes(svc *service.IamPermissionsService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		ids, err := svc.FindRouteIds(c.Request().Context(), id)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, ids)
	}
}

// ---------------------------------------------------------------------
// /system/menus
// ---------------------------------------------------------------------

func hMenusList(svc *service.IamMenusService) echo.HandlerFunc {
	return func(c echo.Context) error {
		tree := c.QueryParam("tree") == "1"
		moduleKeyRaw := strings.TrimSpace(c.QueryParam("module"))
		var moduleKey *string
		if moduleKeyRaw != "" {
			moduleKey = &moduleKeyRaw
		}
		if tree {
			data, err := svc.ListTree(c.Request().Context(), moduleKey)
			if err != nil {
				return hErr(c, err)
			}
			return errkontrak.OK(c, data)
		}
		data, err := svc.ListFlat(c.Request().Context(), moduleKey)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, data)
	}
}

// parseMenu — createMenuSchema / updateMenuSchema (untukUpdate = semua
// field opsional; POST wajibkan text).
func parseMenu(m map[string]any, forUpdate bool, issues *[]errkontrak.FieldIssue) service.MenuInput {
	var in service.MenuInput
	if forUpdate {
		if v, ada := m["text"]; ada {
			in.HasText = true
			s, ok := v.(string)
			if !ok {
				*issues = append(*issues, iamExpect("text", "string", v))
			} else {
				if len([]rune(s)) < 1 {
					*issues = append(*issues, errkontrak.FieldIssue{Field: "text", Message: "String must contain at least 1 character(s)"})
				}
				if len([]rune(s)) > 100 {
					*issues = append(*issues, errkontrak.FieldIssue{Field: "text", Message: "String must contain at most 100 character(s)"})
				}
				in.Text = s
			}
		}
	} else {
		in.HasText = true
		in.Text, _ = iamStrReqMinMax(m, "text", 1, 100, issues)
	}
	if s, ada, ok := iamOptStrMinMax(m, "urlPath", 255, issues); ada {
		in.HasURLPath = ok
		if ok {
			in.URLPath = &s
		}
	}
	// urlPath menerima null (nullable) — tangani eksplisit di atas tidak;
	// periksa kembali bentuk null.
	if v, ada := m["urlPath"]; ada && v == nil {
		in.HasURLPath = true
		in.URLPath = nil
	}
	if p, ada, ok := iamOptIntNull(m, "parent", issues); ada {
		in.HasParent = ok
		if ok {
			in.Parent = p
		}
	}
	if v, ada := m["parent"]; ada && v == nil {
		in.HasParent = true
		in.Parent = nil
	}
	if o, ada, ok := iamOptIntNullPlain(m, "order", issues); ada {
		in.HasOrder = ok
		if ok {
			in.Order = o
		}
	}
	if v, ada := m["order"]; ada && v == nil {
		in.HasOrder = true
		in.Order = nil
	}
	if s, ada, ok := iamOptStrMinMax(m, "cssClass", 30, issues); ada {
		in.HasCssClass = ok
		if ok {
			in.CssClass = &s
		}
	}
	if v, ada := m["cssClass"]; ada && v == nil {
		in.HasCssClass = true
		in.CssClass = nil
	}
	if s, ada, ok := iamOptStrMinMax(m, "icon", 50, issues); ada {
		in.HasIcon = ok
		if ok {
			in.Icon = &s
		}
	}
	if v, ada := m["icon"]; ada && v == nil {
		in.HasIcon = true
		in.Icon = nil
	}
	if s, ada, ok := iamOptStrMinMax(m, "externalHref", 255, issues); ada {
		in.HasExtHref = ok
		if ok {
			in.ExternalHref = &s
		}
	}
	if v, ada := m["externalHref"]; ada && v == nil {
		in.HasExtHref = true
		in.ExternalHref = nil
	}
	if p, ada, ok := iamOptIntNull(m, "idCoreModules", issues); ada {
		in.HasModuleID = ok
		if ok {
			in.IDCoreModules = p
		}
	}
	if v, ada := m["idCoreModules"]; ada && v == nil {
		in.HasModuleID = true
		in.IDCoreModules = nil
	}
	return in
}

func hMenusCreate(svc *service.IamMenusService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseMenu(m, false, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

func hMenusUpdate(svc *service.IamMenusService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseMenu(m, true, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.Update(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hMenusRemove(svc *service.IamMenusService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

func hMenusAssignRoles(svc *service.IamMenusService) echo.HandlerFunc {
	return func(c echo.Context) error {
		roleId, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := service.AssignMenusInput{RoleID: roleId}
		// roleId body wajib sama dengan path (400 bila beda) — validasi
		// bentuk body persis assignMenusSchema dulu.
		if v, ada := m["roleId"]; !ada || v == nil {
			issues = append(issues, iamRequired("roleId"))
		} else {
			n, isNum := iamNum(v)
			if !isNum {
				issues = append(issues, iamExpect("roleId", "number", v))
			} else if !iamIsInt(n) {
				issues = append(issues, errkontrak.FieldIssue{Field: "roleId", Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(v))})
			} else if n < 1 {
				issues = append(issues, errkontrak.FieldIssue{Field: "roleId", Message: "Number must be greater than 0"})
			} else {
				in.RoleID = int64(n)
			}
		}
		in.MenuIds, _ = iamArrayInts(m, "menuIds", &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		res, err := svc.AssignMenusToRole(c.Request().Context(), roleId, in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, res)
	}
}

// ---------------------------------------------------------------------
// /system/features
// ---------------------------------------------------------------------

func hFeaturesList(svc *service.IamFeaturesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		module := c.QueryParam("module")
		if module == "" {
			module = c.QueryParam("moduleKey")
		}
		data, err := svc.List(c.Request().Context(), module)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, data)
	}
}

func hFeaturesSetActive(svc *service.IamFeaturesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		v, ada := m["isActive"]
		if !ada || v == nil {
			issues = append(issues, iamRequired("isActive"))
		}
		b, isBool := v.(bool)
		if ada && v != nil && !isBool {
			issues = append(issues, iamExpect("isActive", "boolean", v))
		}
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.SetActive(c.Request().Context(), id, b, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

// ---------------------------------------------------------------------
// /system/user-overrides
// ---------------------------------------------------------------------

// parseUserIdQuery — query `userId` WAJIB (bilangan bulat ≥ 1; kosong/
// bukan angka → 400 VAL-400, pola error existing modul iam).
func parseUserIdQuery(raw string) (int64, []errkontrak.FieldIssue) {
	if raw == "" {
		return 0, []errkontrak.FieldIssue{{
			Field: "userId", Message: "Query `userId` wajib diisi.",
		}}
	}
	n, err := strconv.ParseFloat(raw, 64)
	if err != nil || !iamIsInt(n) || n < 1 {
		return 0, []errkontrak.FieldIssue{{
			Field:   "userId",
			Message: fmt.Sprintf("Harus bilangan bulat >= 1 (diterima: %s).", raw),
		}}
	}
	return int64(n), nil
}

func hOverridesList(svc *service.IamUserOverridesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		userId, issues := parseUserIdQuery(c.QueryParam("userId"))
		if len(issues) > 0 {
			return hErr(c, iamInvalid(issues))
		}
		pr, err := errkontrak.ParsePageRequest(c.QueryParams())
		if err != nil {
			return hErr(c, err)
		}
		var search *string
		if s := strings.TrimSpace(c.QueryParam("search")); s != "" {
			search = &s
		}
		page, err := svc.List(c.Request().Context(), pr, userId, search)
		if err != nil {
			return hErr(c, err)
		}
		return c.JSON(http.StatusOK, page)
	}
}

// iamDatetimeOffset — zod .datetime({offset: true}): ISO 8601 ber-offset.
var iamDatetimeOffset = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$`)

// parseOverrideBuat — userOverrideBuatSchema (pesan kustom userId/
// permissionId verbatim).
func parseOverrideBuat(m map[string]any, issues *[]errkontrak.FieldIssue) service.OverrideBuat {
	var in service.OverrideBuat
	// userId: z.number().int().min(1, "User wajib dipilih.")
	if v, ada := m["userId"]; !ada || v == nil {
		*issues = append(*issues, iamRequired("userId"))
	} else if n, ok := iamNum(v); !ok {
		*issues = append(*issues, iamExpect("userId", "number", v))
	} else if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "userId", Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(v))})
	} else if n < 1 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "userId", Message: "User wajib dipilih."})
	} else {
		in.UserID = int64(n)
	}
	// permissionId: z.number().int().min(1, "Permission wajib dipilih.")
	if v, ada := m["permissionId"]; !ada || v == nil {
		*issues = append(*issues, iamRequired("permissionId"))
	} else if n, ok := iamNum(v); !ok {
		*issues = append(*issues, iamExpect("permissionId", "number", v))
	} else if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "permissionId", Message: fmt.Sprintf("Expected integer, received %s", iamTypeName(v))})
	} else if n < 1 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "permissionId", Message: "Permission wajib dipilih."})
	} else {
		in.PermissionID = int64(n)
	}
	// granted: boolean wajib.
	if v, ada := m["granted"]; !ada || v == nil {
		*issues = append(*issues, iamRequired("granted"))
	} else if b, ok := v.(bool); !ok {
		*issues = append(*issues, iamExpect("granted", "boolean", v))
	} else {
		in.Granted = b
	}
	// expiresAt: .datetime({offset:true}).nullish() — absen/null = permanen.
	if v, ada := m["expiresAt"]; ada && v != nil {
		s, ok := v.(string)
		if !ok {
			*issues = append(*issues, iamExpect("expiresAt", "string", v))
		} else if !iamDatetimeOffset.MatchString(s) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "expiresAt", Message: "Invalid datetime"})
		} else {
			in.ExpiresAt = &s
		}
	}
	return in
}

func hOverridesCreate(svc *service.IamUserOverridesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseOverrideBuat(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.Create(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view) // 200 (ApiZodOk — bukan 201)
	}
}

func hOverridesRemove(svc *service.IamUserOverridesService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		if err := svc.Remove(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

// ---------------------------------------------------------------------
// /system/datascope
// ---------------------------------------------------------------------

// kebabCase — KEBAB_RE zod: huruf kecil di depan, segmen [a-z0-9] dipisah
// tanda hubung.
var kebabCase = regexp.MustCompile(`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`)

// hScopeListDefinitions — katalog dimensi + ringkasan jumlah assignment.
func hScopeListDefinitions(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		data, err := svc.ListDefinitions(c.Request().Context())
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, data)
	}
}

// parseScopeDefCreate — scopeDefinitionCreateSchema (pesan DS-*-40x verbatim).
func parseScopeDefCreate(m map[string]any, issues *[]errkontrak.FieldIssue) service.ScopeDefinitionCreateInput {
	var in service.ScopeDefinitionCreateInput
	// module_id?: number int positive (opsional; default 'system' di service).
	if v, ada := m["module_id"]; ada && v != nil {
		n, ok := iamNum(v)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus angka."})
		} else if !iamIsInt(n) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus bilangan bulat."})
		} else if n < 1 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus >= 1."})
		} else {
			x := int64(n)
			in.ModuleID = &x
		}
	}
	// scope_key: wajib; kebab-case; maks 50.
	if v, ada := m["scope_key"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "scope_key", Message: "DS-KEY-401: scope_key wajib diisi."})
	} else if s, ok := v.(string); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "scope_key", Message: "DS-KEY-401: scope_key wajib diisi."})
	} else {
		if !kebabCase.MatchString(s) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "scope_key", Message: "DS-KEY-402: scope_key harus kebab-case ([a-z0-9], pisah tanda hubung), mis. 'storages'."})
		}
		if len([]rune(s)) > 50 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "scope_key", Message: "DS-KEY-403: scope_key maksimal 50 karakter."})
		}
		in.ScopeKey = s
	}
	// label: wajib; 3..100.
	if v, ada := m["label"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "label", Message: "DS-LABEL-401: label wajib diisi."})
	} else if s, ok := v.(string); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "label", Message: "DS-LABEL-401: label wajib diisi."})
	} else {
		if len([]rune(s)) < 3 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "label", Message: "DS-LABEL-402: label minimal 3 karakter."})
		}
		if len([]rune(s)) > 100 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "label", Message: "DS-LABEL-403: label maksimal 100 karakter."})
		}
		in.Label = s
	}
	// description?: teks maks 300.
	if v, ada := m["description"]; ada && v != nil {
		s, ok := v.(string)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "description", Message: "DS-DESC-401: description harus teks."})
		} else {
			if len([]rune(s)) > 300 {
				*issues = append(*issues, errkontrak.FieldIssue{Field: "description", Message: "DS-DESC-402: description maksimal 300 karakter."})
			}
			in.Description = &s
		}
	}
	// target_table / target_field: wajib (registry).
	if v, ada := m["target_table"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "target_table", Message: "DS-TABLE-401: target_table wajib diisi (registry)."})
	} else if s, ok := v.(string); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "target_table", Message: "DS-TABLE-401: target_table wajib diisi (registry)."})
	} else {
		if len([]rune(s)) > 100 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "target_table", Message: "DS-TABLE-402: target_table maksimal 100 karakter."})
		}
		in.TargetTable = s
	}
	if v, ada := m["target_field"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "target_field", Message: "DS-FIELD-401: target_field wajib diisi (registry)."})
	} else if s, ok := v.(string); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "target_field", Message: "DS-FIELD-401: target_field wajib diisi (registry)."})
	} else {
		if len([]rune(s)) > 100 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "target_field", Message: "DS-FIELD-402: target_field maksimal 100 karakter."})
		}
		in.TargetField = s
	}
	return in
}

func hScopeCreateDefinition(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseScopeDefCreate(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.CreateDefinition(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

// parseScopeDefUpdate — scopeDefinitionUpdateSchema (semua opsional,
// non-null; pesan DS-*-40x verbatim "harus teks").
func parseScopeDefUpdate(m map[string]any, issues *[]errkontrak.FieldIssue) service.ScopeDefinitionUpdateInput {
	var in service.ScopeDefinitionUpdateInput
	optStr := func(key, msgType string, max int, msgMax string, opt *service.FieldOpt) {
		if v, ada := m[key]; ada && v != nil {
			s, ok := v.(string)
			if !ok {
				*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgType})
				return
			}
			if max > 0 && len([]rune(s)) > max {
				*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgMax})
			}
			opt.Present = true
			opt.Str = s
		} else if ada && v == nil {
			// optional tanpa nullable → null invalid_type.
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgType})
		}
	}
	optStr("label", "DS-LABEL-401: label harus teks.", 100, "DS-LABEL-403: label maksimal 100 karakter.", &in.Label)
	// label min 3 — check khusus (zod .min(3) DS-LABEL-402).
	if in.Label.Present && len([]rune(in.Label.Str)) < 3 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "label", Message: "DS-LABEL-402: label minimal 3 karakter."})
	}
	optStr("scope_key", "DS-KEY-401: scope_key harus teks.", 50, "DS-KEY-402: scope_key maksimal 50 karakter.", &in.ScopeKey)
	optStr("target_table", "DS-TABLE-401: target_table harus teks.", 100, "DS-TABLE-402: target_table maksimal 100 karakter.", &in.TargetTable)
	optStr("target_field", "DS-FIELD-401: target_field harus teks.", 100, "DS-FIELD-402: target_field maksimal 100 karakter.", &in.TargetField)
	optStr("description", "DS-DESC-401: description harus teks.", 300, "DS-DESC-402: description maksimal 300 karakter.", &in.Description)
	// module_id?: number int positive.
	if v, ada := m["module_id"]; ada && v != nil {
		n, ok := iamNum(v)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus angka."})
		} else if !iamIsInt(n) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus bilangan bulat."})
		} else if n < 1 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-402: module_id harus positif."})
		} else {
			in.ModuleID.Present = true
			in.ModuleID.Int = int64(n)
		}
	} else if ada && v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "module_id", Message: "DS-MODULE-401: module_id harus angka."})
	}
	// is_active?: boolean.
	if v, ada := m["is_active"]; ada && v != nil {
		b, ok := v.(bool)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "is_active", Message: "DS-ACTIVE-401: is_active harus boolean."})
		} else {
			in.IsActive.Present = true
			in.IsActive.Bool = b
		}
	} else if ada && v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "is_active", Message: "DS-ACTIVE-401: is_active harus boolean."})
	}
	return in
}

func hScopeUpdateDefinition(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseScopeDefUpdate(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		expectedVersion, err := shared.IfMatchVersion(c.Request())
		if err != nil {
			return hErr(c, err)
		}
		view, err := svc.UpdateDefinition(c.Request().Context(), id, in, shared.ActorOf(c.Request()), expectedVersion)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hScopeDeleteDefinition(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		if err := svc.DeleteDefinition(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

func hScopeListAssignments(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		data, err := svc.ListAssignments(c.Request().Context(), id)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, data)
	}
}

func hScopeListOptions(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		pr, err := errkontrak.ParsePageRequest(c.QueryParams())
		if err != nil {
			return hErr(c, err)
		}
		var search *string
		if s := strings.TrimSpace(c.QueryParam("search")); s != "" {
			search = &s
		}
		result, err := svc.ListOptions(c.Request().Context(), id, pr, search)
		if err != nil {
			return hErr(c, err)
		}
		return c.JSON(http.StatusOK, result) // { data, columns, meta }
	}
}

// parseScopeAsgUpsert — scopeAssignmentUpsertSchema (XOR subjek superRefine
// → issue path role_id DS-SUBJECT-401).
func parseScopeAsgUpsert(m map[string]any, issues *[]errkontrak.FieldIssue) service.ScopeAssignmentUpsertInput {
	var in service.ScopeAssignmentUpsertInput
	// definition_id: wajib.
	if v, ada := m["definition_id"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "definition_id", Message: "DS-DEF-401: definition_id harus angka."})
	} else if n, ok := iamNum(v); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "definition_id", Message: "DS-DEF-401: definition_id harus angka."})
	} else if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "definition_id", Message: "DS-DEF-401: definition_id harus bilangan bulat."})
	} else if n < 1 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "definition_id", Message: "DS-DEF-402: definition_id harus >= 1."})
	} else {
		in.DefinitionID = int64(n)
	}
	// role_id / user_id: nullable optional — null TIDAK dihitung subjek.
	optSubject := func(key, msgAngka, msgBulat, msgPositif string) *int64 {
		v, ada := m[key]
		if !ada {
			return nil
		}
		if v == nil {
			return nil
		}
		n, ok := iamNum(v)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgAngka})
			return nil
		}
		if !iamIsInt(n) {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgBulat})
			return nil
		}
		if n < 1 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: key, Message: msgPositif})
			return nil
		}
		x := int64(n)
		return &x
	}
	in.RoleID = optSubject("role_id", "DS-ROLE-401: role_id harus angka.", "DS-ROLE-401: role_id harus bilangan bulat.", "DS-ROLE-402: role_id harus >= 1.")
	in.UserID = optSubject("user_id", "DS-USER-401: user_id harus angka.", "DS-USER-401: user_id harus bilangan bulat.", "DS-USER-402: user_id harus >= 1.")
	// note?: teks maks 200.
	if v, ada := m["note"]; ada && v != nil {
		s, ok := v.(string)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "note", Message: "DS-NOTE-401: note harus teks."})
		} else {
			if len([]rune(s)) > 200 {
				*issues = append(*issues, errkontrak.FieldIssue{Field: "note", Message: "DS-NOTE-402: note maksimal 200 karakter."})
			}
			in.Note = &s
		}
	}
	// XOR — (role_id == null) === (user_id == null) → issue path role_id.
	if (in.RoleID == nil) == (in.UserID == nil) {
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   "role_id",
			Message: "DS-SUBJECT-401: tepat satu subjek wajib — role_id ATAU user_id.",
		})
	}
	return in
}

func hScopeCreateAssignment(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseScopeAsgUpsert(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		view, err := svc.CreateAssignment(c.Request().Context(), in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.Created(c, view)
	}
}

// parseScopeAsgUpdate — scopeAssignmentUpdateSchema (is_active/note opsional).
func parseScopeAsgUpdate(m map[string]any, issues *[]errkontrak.FieldIssue) service.ScopeAssignmentUpdateInput {
	var in service.ScopeAssignmentUpdateInput
	if v, ada := m["is_active"]; ada && v != nil {
		b, ok := v.(bool)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "is_active", Message: "DS-ACTIVE-401: is_active harus boolean."})
		} else {
			in.IsActive.Present = true
			in.IsActive.Bool = b
		}
	} else if ada && v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "is_active", Message: "DS-ACTIVE-401: is_active harus boolean."})
	}
	if v, ada := m["note"]; ada && v != nil {
		s, ok := v.(string)
		if !ok {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "note", Message: "DS-NOTE-401: note harus teks."})
		} else {
			if len([]rune(s)) > 200 {
				*issues = append(*issues, errkontrak.FieldIssue{Field: "note", Message: "DS-NOTE-402: note maksimal 200 karakter."})
			}
			in.Note.Present = true
			in.Note.Str = s
		}
	} else if ada && v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "note", Message: "DS-NOTE-401: note harus teks."})
	}
	return in
}

func hScopeUpdateAssignment(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseScopeAsgUpdate(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		expectedVersion, err := shared.IfMatchVersion(c.Request())
		if err != nil {
			return hErr(c, err)
		}
		view, err := svc.UpdateAssignment(c.Request().Context(), id, in, shared.ActorOf(c.Request()), expectedVersion)
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, view)
	}
}

func hScopeDeleteAssignment(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		if err := svc.DeleteAssignment(c.Request().Context(), id, shared.ActorOf(c.Request())); err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, map[string]any{"ok": true})
	}
}

// parseScopeValuesSet — scopeValuesSetSchema (maks 500 nilai; teks 1..50).
func parseScopeValuesSet(m map[string]any, issues *[]errkontrak.FieldIssue) service.ScopeValuesSetInput {
	var in service.ScopeValuesSetInput
	// assignment_id: wajib.
	if v, ada := m["assignment_id"]; !ada || v == nil {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "assignment_id", Message: "DS-ASG-401: assignment_id harus angka."})
	} else if n, ok := iamNum(v); !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "assignment_id", Message: "DS-ASG-401: assignment_id harus angka."})
	} else if !iamIsInt(n) {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "assignment_id", Message: "DS-ASG-401: assignment_id harus bilangan bulat."})
	} else if n < 1 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "assignment_id", Message: "DS-ASG-402: assignment_id harus >= 1."})
	} else {
		in.AssignmentID = int64(n)
	}
	// values: array teks wajib, maks 500 item.
	v, ada := m["values"]
	if !ada || v == nil {
		*issues = append(*issues, iamRequired("values"))
		return in
	}
	arr, ok := v.([]any)
	if !ok {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "values", Message: "DS-VAL-404: values harus array teks."})
		return in
	}
	if len(arr) > 500 {
		*issues = append(*issues, errkontrak.FieldIssue{Field: "values", Message: "DS-VAL-405: maksimal 500 nilai per assignment."})
	}
	in.Values = make([]string, 0, len(arr))
	for _, item := range arr {
		s, isStr := item.(string)
		if !isStr {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "values", Message: "DS-VAL-401: tiap nilai harus teks (id baris target)."})
			continue
		}
		if len(s) < 1 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "values", Message: "DS-VAL-402: nilai tidak boleh kosong."})
			continue
		}
		if len(s) > 50 {
			*issues = append(*issues, errkontrak.FieldIssue{Field: "values", Message: "DS-VAL-403: nilai maksimal 50 karakter."})
			continue
		}
		in.Values = append(in.Values, s)
	}
	return in
}

func hScopeSetValues(svc *service.IamDatascopeService) echo.HandlerFunc {
	return func(c echo.Context) error {
		id, err := shared.ParseIDParam(c.Param("id"), "id")
		if err != nil {
			return hErr(c, err)
		}
		m, ok := iamBody(c)
		if !ok {
			return iamBadBody(c, nil)
		}
		issues := []errkontrak.FieldIssue{}
		in := parseScopeValuesSet(m, &issues)
		if len(issues) > 0 {
			return iamBadBody(c, issues)
		}
		res, err := svc.SetValues(c.Request().Context(), id, in, shared.ActorOf(c.Request()))
		if err != nil {
			return hErr(c, err)
		}
		return errkontrak.OK(c, res)
	}
}
