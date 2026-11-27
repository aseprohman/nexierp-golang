// Package types — kontrak view & konstanta fitur RBAC modul core
// (padanan @nexierp/schemas core/{users,roles,rbac,iam,audit}.ts + types/
// {rbac-types,overview-types}.ts NestJS). Bentuk JSON camelCase BEKU.
package types

// DefaultDemoPassword — password demo user baru (port mock api.ts:335,
// wajib diganti di login pertama; KEPUTUSAN RATIFIKASI Go: disimpan sebagai
// argon2id — auth.HashPassword — bukan plaintext).
const DefaultDemoPassword = "nexgea123"

// RoleBrief — pasangan {code, role} role yang dipegang user.
type RoleBrief struct {
	Code string `json:"code"`
	Role string `json:"role"`
}

// UserView — view user TANPA password_hash (userViewSchema; MULTI-ROLE).
type UserView struct {
	ID                  int64       `json:"id"`
	Username            string      `json:"username"`
	Name                string      `json:"name"`
	Email               string      `json:"email"`
	Roles               []RoleBrief `json:"roles"`
	Department          string      `json:"department"`
	IsActive            bool        `json:"isActive"`
	PasswordChangedAt   *string     `json:"passwordChangedAt"`
	MustChangePassword  bool        `json:"mustChangePassword"`
	FailedLoginAttempts int32       `json:"failedLoginAttempts"`
	LockedUntil         *string     `json:"lockedUntil"`
	MfaEnabled          bool        `json:"mfaEnabled"`
	LastLoginAt         *string     `json:"lastLoginAt"`
	CreatedAt           string      `json:"createdAt"`
}

// UserRoleAssignmentView — penugasan role (userRoleAssignmentSchema).
type UserRoleAssignmentView struct {
	UserID     int64  `json:"userId"`
	RoleCode   string `json:"roleCode"`
	AssignedBy string `json:"assignedBy"`
	AssignedAt string `json:"assignedAt"`
}

// UserOverrideView — override per-user PER SET permission: DEKLARASI di
// types/iam.go (dipakai bersama fitur iam user-overrides).

// SessionView — baris core_sessions (sessionRowSchema).
type SessionView struct {
	ID        int64   `json:"id"`
	UserID    int64   `json:"userId"`
	UserName  string  `json:"userName"`
	DeviceKey *string `json:"deviceKey"`
	LoginAt   string  `json:"loginAt"`
	ExpiresAt string  `json:"expiresAt"`
	LogoutAt  *string `json:"logoutAt"`
	RevokedAt *string `json:"revokedAt"`
	IPAddress string  `json:"ipAddress"`
	UserAgent string  `json:"userAgent"`
	Device    string  `json:"device"`
	IsValid   bool    `json:"isValid"`
}

// MfaView — baris core_user_mfa (mfaSchema); nil = belum daftar.
type MfaView struct {
	UserID            int64   `json:"userId"`
	UserName          string  `json:"userName"`
	Method            string  `json:"method"`
	ConfirmedAt       *string `json:"confirmedAt"`
	Enabled           bool    `json:"enabled"`
	LastUsedAt        *string `json:"lastUsedAt"`
	RecoveryCodesLeft int32   `json:"recoveryCodesLeft"`
}

// UserDetail — detail berelasi satu user (userDetailSchema).
type UserDetail struct {
	User                 UserView                 `json:"user"`
	ExtraRoles           []UserRoleAssignmentView `json:"extraRoles"`
	EffectivePermissions []string                 `json:"effectivePermissions"`
	RolePermissions      []string                 `json:"rolePermissions"`
	Overrides            []UserOverrideView       `json:"overrides"`
	Sessions             []SessionView            `json:"sessions"`
	Mfa                  *MfaView                 `json:"mfa"`
}

// RoleView — view role + jumlah member (roleViewSchema).
type RoleView struct {
	ID          int64   `json:"id"`
	Code        string  `json:"code"`
	Role        string  `json:"role"`
	Description *string `json:"description"`
	IsSystem    bool    `json:"isSystem"`
	MemberCount int64   `json:"memberCount"`
	CreatedAt   string  `json:"createdAt"`
	UpdatedAt   string  `json:"updatedAt"`
}

// ModuleRegistryView — view registry modul (moduleRegistryViewSchema).
type ModuleRegistryView struct {
	ID         int64   `json:"id"`
	Key        string  `json:"key"`
	Name       string  `json:"name"`
	Tagline    string  `json:"tagline"`
	Tone       string  `json:"tone"`
	IsCore     bool    `json:"isCore"`
	Enabled    bool    `json:"enabled"`
	EnabledAt  string  `json:"enabledAt"`
	DisabledAt *string `json:"disabledAt"`
	DisabledBy *string `json:"disabledBy"`
}

// ModuleEnabledResult — hasil enable/disable (moduleEnabledResultSchema).
type ModuleEnabledResult struct {
	Changed bool   `json:"changed"`
	Key     string `json:"key"`
	Enabled bool   `json:"enabled"`
}

// OverviewStats — statistik overview + registry IAM v2 (overviewStatsV2Schema:
// systemOverviewStatsSchema + routes + permissions; KEPUTUSAN: "permissions"
// = count SET aktif, routes = count core_routes).
type OverviewStats struct {
	TotalUsers      int64 `json:"totalUsers"`
	ActiveUsers     int64 `json:"activeUsers"`
	LockedUsers     int64 `json:"lockedUsers"`
	MfaUsers        int64 `json:"mfaUsers"`
	ActiveSessions  int64 `json:"activeSessions"`
	FailedLogins24h int64 `json:"failedLogins24h"`
	Roles           int64 `json:"roles"`
	Routes          int64 `json:"routes"`
	Permissions     int64 `json:"permissions"`
	AuditToday      int64 `json:"auditToday"`
}

// AuditTrailEntry — baris audit trail: DEKLARASI di types/security.go
// (dipakai bersama fitur security audit-trail).

// ModuleKeyRank — urutan kanonik moduleKeySchema.enumValues (rank sort list
// modul; key di luar daftar = 99).
var ModuleKeyRank = map[string]int{
	"inventory":       0,
	"accounting":      1,
	"sales":           2,
	"finance":         3,
	"hr":              4,
	"crm":             5,
	"whatsapp-crm":    6,
	"book":            7,
	"pos":             8,
	"purchasing":      9,
	"asset":           10,
	"ess":             11,
	"fnb":             12,
	"system":          13,
	"payment-gateway": 14,
	"shipment":        15,
	"ecom":            16,
	"wf":              17,
	"ai-llm":          18,
}
