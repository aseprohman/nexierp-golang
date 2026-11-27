// Package types — tipe fitur SECURITY + AUDIT-TRAIL + ENVIRONMENT modul
// core (padanan types/security-types.ts + view schemas @nexierp/schemas:
// security.ts, audit.ts, environment.ts, sessions.ts). Bentuk JSON
// camelCase PERSIS kontrak NestJS; timestamp = ISO-8601 toISOString().
package types

import (
	"encoding/json"
	"fmt"
	"time"
)

// ---------------------------------------------------------------------
// Util waktu — padanan shared/views.ts iso/isoRequired (toISOString).
// ---------------------------------------------------------------------

// Iso — toISOString(): UTC, 3 digit milidetik, akhiran Z (padanan
// shared/views.ts isoRequired).
func Iso(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

// ---------------------------------------------------------------------
// Sesi & log login (sessions.ts)
// ---------------------------------------------------------------------

// SessionRow — view baris core_sessions (sessionRowSchema).
type SessionRow struct {
	ID        int64   `json:"id"`
	UserID    *int64  `json:"userId"`
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

// LoginAuditEntry — view jejak percobaan login (core_login_audit).
type LoginAuditEntry struct {
	ID            int64   `json:"id"`
	UserID        *int64  `json:"userId"`
	UsernameTried string  `json:"usernameTried"`
	Success       bool    `json:"success"`
	FailReason    *string `json:"failReason"`
	IPAddress     string  `json:"ipAddress"`
	UserAgent     string  `json:"userAgent"`
	AttemptedAt   string  `json:"attemptedAt"`
}

// ---------------------------------------------------------------------
// MFA & riwayat password (security.ts)
// ---------------------------------------------------------------------

// UserMfa — view baris core_user_mfa (mfaSchema).
type UserMfa struct {
	UserID            int64   `json:"userId"`
	UserName          string  `json:"userName"`
	Method            string  `json:"method"`
	ConfirmedAt       *string `json:"confirmedAt"`
	Enabled           bool    `json:"enabled"`
	LastUsedAt        *string `json:"lastUsedAt"`
	RecoveryCodesLeft int     `json:"recoveryCodesLeft"`
}

// UserMfaStatus — baris tabel status MFA per pengguna (LEFT JOIN
// core_users x core_user_mfa): Mfa nil = pengguna belum mendaftar TOTP.
type UserMfaStatus struct {
	UserID   int64    `json:"userId"`
	UserName string   `json:"userName"`
	Username string   `json:"username"`
	Mfa      *UserMfa `json:"mfa"`
}

// PasswordHistoryEntry — view riwayat ganti password (hash dimasker).
type PasswordHistoryEntry struct {
	ID         int64  `json:"id"`
	UserID     int64  `json:"userId"`
	UserName   string `json:"userName"`
	SetAt      string `json:"setAt"`
	MaskedHash string `json:"maskedHash"`
}

// IpAllowlistRule — view aturan allowlist IP (roleCode dari JOIN core_roles).
type IpAllowlistRule struct {
	ID        int64   `json:"id"`
	RoleCode  *string `json:"roleCode"`
	UserID    *int64  `json:"userId"`
	Target    string  `json:"target"`
	Cidr      string  `json:"cidr"`
	Note      *string `json:"note"`
	CreatedAt string  `json:"createdAt"`
}

// CreateIpAllowlistRuleInput — request tambah aturan allowlist
// (createIpAllowlistRuleSchema): minimal satu target role/user (refine =
// CHECK DDL core_ip_allowlist_target_required). nil = null/absen.
type CreateIpAllowlistRuleInput struct {
	RoleCode *string
	UserID   *int64
	Cidr     string
	Note     *string
}

// SetMfaInput — request aktif/nonaktifkan MFA user (setMfaSchema).
type SetMfaInput struct {
	UserID  int64
	Enabled bool
}

// ---------------------------------------------------------------------
// Audit trail (audit.ts + security-types.ts)
// ---------------------------------------------------------------------

// AuditTrailEntry — view audit trail pusat (core_audit_trail JOIN
// core_modules; moduleKey dari JOIN, null bila modul sudah hilang).
type AuditTrailEntry struct {
	ID          int64   `json:"id"`
	At          string  `json:"at"`
	ActorUserID *int64  `json:"actorUserId"`
	ActorName   string  `json:"actorName"`
	ModuleKey   *string `json:"moduleKey"`
	EntityType  string  `json:"entityType"`
	EntityID    string  `json:"entityId"`
	Action      string  `json:"action"`
	BeforeValue any     `json:"beforeValue"`
	AfterValue  any     `json:"afterValue"`
	Severity    string  `json:"severity"`
	IPAddress   string  `json:"ipAddress"`
	UserAgent   string  `json:"userAgent"`
	RequestID   string  `json:"requestId"`
}

// AuditTrailFilter — filter hasil parse auditTrailFilterSchema (tanpa
// page/limit); nil = param tidak dikirim (undefined di zod). Query boleh
// string kosong ("" lolos z.string()).
type AuditTrailFilter struct {
	ModuleKey *string
	Severity  *string
	Action    *string
	Query     *string
	DateFrom  *string
	DateTo    *string
}

// CSVHeaders — header CSV ekspor (CSV_HEADERS security-types.ts; kolom flat
// baris core_audit_trail + before/after JSON).
var CSVHeaders = []string{
	"id",
	"at",
	"actor_user_id",
	"actor_name",
	"module_key",
	"entity_type",
	"entity_id",
	"action",
	"severity",
	"before_value",
	"after_value",
	"ip_address",
	"user_agent",
	"request_id",
}

// ---------------------------------------------------------------------
// Environment (environment.ts + security-types.ts)
// ---------------------------------------------------------------------

// EnvCategoryData — data satu kategori environment (baris core_app_settings).
// Fields = payload jsonb apa adanya (field rusak lolos — jangan buang data).
type EnvCategoryData struct {
	Category string          `json:"category"`
	Fields   json.RawMessage `json:"fields"`
}

// CompanyLogo — logo perusahaan (core_meta.id="company_logo").
// LogoDataUrl any → pas-through nilai jsonb (?? null → JSON null).
type CompanyLogo struct {
	LogoName    string `json:"logoName"`
	LogoDataUrl any    `json:"logoDataUrl"`
}

// EnvironmentConfig — konfigurasi environment utuh halaman Pengaturan.
type EnvironmentConfig struct {
	Categories []EnvCategoryData `json:"categories"`
	Logo       CompanyLogo       `json:"logo"`
}

// SaveEnvironmentCategoryInput — request simpan satu kategori
// (saveEnvironmentCategorySchema): key → nilai baru (string|boolean).
type SaveEnvironmentCategoryInput struct {
	Category string
	Values   map[string]any
}

// SmtpTestResult — hasil uji koneksi SMTP (smtpTestSchema); kegagalan
// koneksi BUKAN error server (HTTP 200).
type SmtpTestResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// ---------------------------------------------------------------------
// Konstanta fitur security (security-types.ts)
// ---------------------------------------------------------------------

// EnvCategoryOrder — urutan kategori saat pembacaan (ENV_CATEGORY_ORDER).
var EnvCategoryOrder = []string{"company", "smtp", "app", "storage"}

// CompanyLogoMetaKey — meta key logo (core_meta.id).
const CompanyLogoMetaKey = "company_logo"

// ModuleKeyValues — nilai moduleKeySchema (enum 19 — validasi filter
// audit trail; BUKAN enum DB 34 nilai).
var ModuleKeyValues = []string{
	"inventory",
	"accounting",
	"sales",
	"finance",
	"hr",
	"crm",
	"whatsapp-crm",
	"book",
	"pos",
	"purchasing",
	"asset",
	"ess",
	"fnb",
	"system",
	"payment-gateway",
	"shipment",
	"ecom",
	"wf",
	"ai-llm",
}

// SeverityValues — nilai auditSeveritySchema.
var SeverityValues = []string{"info", "warning", "critical"}

// CategoryValues — nilai envCategorySchema.
var CategoryValues = []string{"company", "smtp", "app", "storage"}

// PesanEnum — pesan default zod v3 invalid_enum_value (verbatim joinValues:
// nilai string dikutip 'x', dipisah " | "):
// `Invalid enum value. Expected 'a' | 'b', received 'x'`.
func PesanEnum(options []string, received string) string {
	msg := "Invalid enum value. Expected "
	for i, o := range options {
		if i > 0 {
			msg += " | "
		}
		msg += fmt.Sprintf("'%s'", o)
	}
	return msg + fmt.Sprintf(", received '%s'", received)
}
