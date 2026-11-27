// Package types — view types fitur IAM (kontrak JSON PERSIS zod
// @nexierp/schemas: core/routes.ts routeViewSchema, core/iam.ts
// permissionView/menu/moduleFeatureView + scope*, core/rbac.ts
// userOverrideViewSchema). Field camelCase mengikuti zod; scope
// snake_case mengikuti zodnya (scopeDefinitionViewSchema dll.).
package types

// RouteView — baris registry core_routes (routeViewSchema; updatedAt
// nullable, createdAt wajib — kolom NOT NULL).
type RouteView struct {
	ID             int64   `json:"id"`
	Method         string  `json:"method"`
	URIPattern     string  `json:"uriPattern"`
	PermissionCode string  `json:"permissionCode"`
	CreatedAt      string  `json:"createdAt"`
	UpdatedAt      *string `json:"updatedAt"`
}

// PermissionView — satu SET permission (permissionViewSchema). name fallback
// `set#<id>` dilakukan repository (kolom legacy nullable).
type PermissionView struct {
	ID          int64   `json:"id"`
	Name        string  `json:"name"`
	Description *string `json:"description"`
	ModuleKey   *string `json:"moduleKey"`
	Status      string  `json:"status"`
	IsSystem    bool    `json:"isSystem"`
	RouteCount  int     `json:"routeCount"`
	CreatedAt   string  `json:"createdAt"`
}

// Menu — baris menu (menuSchema; kolom `class` tidak dipublikasikan).
type Menu struct {
	ID            int64   `json:"id"`
	Text          string  `json:"text"`
	URLPath       *string `json:"urlPath"`
	Order         *int32  `json:"order"`
	Parent        *int64  `json:"parent"`
	Icon          *string `json:"icon"`
	ExternalHref  *string `json:"externalHref"`
	IDCoreModules *int64  `json:"idCoreModules"`
}

// MenuTreeNode — node menu tree (menuTreeNodeSchema; parent map in-memory).
type MenuTreeNode struct {
	ID            int64          `json:"id"`
	Text          string         `json:"text"`
	URLPath       *string        `json:"urlPath"`
	Order         *int32         `json:"order"`
	Icon          *string        `json:"icon"`
	ExternalHref  *string        `json:"externalHref"`
	IDCoreModules *int64         `json:"idCoreModules"`
	Children      []MenuTreeNode `json:"children"`
}

// ModuleFeatureView — fitur per modul (moduleFeatureViewSchema).
type ModuleFeatureView struct {
	ID             int64  `json:"id"`
	ModuleKey      string `json:"moduleKey"`
	FeaturesFolder string `json:"featuresFolder"`
	IsActive       bool   `json:"isActive"`
	IsSystem       bool   `json:"isSystem"`
}

// UserOverrideView — override per-user PER SET (userOverrideViewSchema);
// moduleKey = segmen pertama permissionName.
type UserOverrideView struct {
	ID             int64   `json:"id"`
	UserID         int64   `json:"userId"`
	UserName       string  `json:"userName"`
	PermissionID   int64   `json:"permissionId"`
	PermissionName string  `json:"permissionName"`
	ModuleKey      string  `json:"moduleKey"`
	Granted        bool    `json:"granted"`
	GrantedByName  *string `json:"grantedByName"`
	GrantedAt      string  `json:"grantedAt"`
	ExpiresAt      *string `json:"expiresAt"`
}

// ScopeDefinitionView — definisi dimensi scope (scopeDefinitionViewSchema —
// field snake_case persis zod).
type ScopeDefinitionView struct {
	ID          int64  `json:"id"`
	ModuleID    int64  `json:"module_id"`
	ScopeKey    string `json:"scope_key"`
	Label       string `json:"label"`
	Description string `json:"description"`
	TargetTable string `json:"target_table"`
	TargetField string `json:"target_field"`
	Operator    string `json:"operator"`
	IsActive    bool   `json:"is_active"`
	Version     int64  `json:"version"`
	CreatedAt   string `json:"created_at"`
}

// ScopeDefinitionSummary — view + ringkasan jumlah assignment (field
// tambahan `assignmentCount` — camelCase persis zod extend).
type ScopeDefinitionSummary struct {
	ScopeDefinitionView
	AssignmentCount int `json:"assignmentCount"`
}

// ScopeAssignmentView — pemberian scope + ringkasan nilai
// (scopeAssignmentViewSchema — snake_case persis zod).
type ScopeAssignmentView struct {
	ID           int64    `json:"id"`
	DefinitionID int64    `json:"definition_id"`
	RoleID       *int64   `json:"role_id"`
	UserID       *int64   `json:"user_id"`
	RoleName     *string  `json:"role_name"`
	Username     *string  `json:"username"`
	IsActive     bool     `json:"is_active"`
	Note         string   `json:"note"`
	ValueCount   int      `json:"value_count"`
	Version      int64    `json:"version"`
	Values       []string `json:"values"`
}

// ScopeOptionColumn — metadata kolom tampilan opsi (scopeOptionColumnSchema).
type ScopeOptionColumn struct {
	Key   string `json:"key"`
	Label string `json:"label"`
}

// ScopeOptionRow — baris opsi dinamis (scopeOptionRowSchema: record string →
// string|number|null); `value` = PK sebagai teks.
type ScopeOptionRow = map[string]any

// ScopeOptionsResult — hasil GET /system/datascope/definitions/:id/options
// (bentuk persis controller: { data, columns, meta }).
type ScopeOptionsResult struct {
	Data    []ScopeOptionRow    `json:"data"`
	Columns []ScopeOptionColumn `json:"columns"`
	Meta    struct {
		Page       int `json:"page"`
		Limit      int `json:"limit"`
		Total      int `json:"total"`
		TotalPages int `json:"totalPages"`
	} `json:"meta"`
}
