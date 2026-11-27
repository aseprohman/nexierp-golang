// Package auth — kernel autentikasi Go, porting persis dari
// apps/api/src/core/auth NestJS: 8 route (login/register/aktivasi/kirim-ulang/
// refresh/logout/me/change-password), guard JWT + sesi server-side, cookie
// dua ruang origin, token aktivasi one-time, sweep core_auth_tokens.
package auth

import "time"

// ---------------------------------------------------------------------
// Klaim & user konteks
// ---------------------------------------------------------------------

// Claims — payload access/refresh token HS256 (padanan AccessTokenPayload).
type Claims struct {
	Sub      int64  `json:"sub"`
	Username string `json:"username"`
	SID      int64  `json:"sid"`
	JTI      string `json:"jti,omitempty"` // hanya pada refresh token
	Exp      int64  `json:"exp"`
	Iat      int64  `json:"iat"`
}

// User — req.user hasil guard (dari JWT + validasi sesi server-side).
type User struct {
	ID        int64
	Username  string
	SessionID int64
}

// ---------------------------------------------------------------------
// Parameter keamanan (core_meta id 'security')
// ---------------------------------------------------------------------

// SecuritySettings — baris core_meta 'security' (default = mockup types.ts).
type SecuritySettings struct {
	MaxFailedAttempts int
	LockoutMinutes    int
	SessionTtlHours   int
}

// DefaultSecuritySettings — DEFAULT_SECURITY_SETTINGS mockup.
var DefaultSecuritySettings = SecuritySettings{
	MaxFailedAttempts: 5,
	LockoutMinutes:    60,
	SessionTtlHours:   12,
}

// ---------------------------------------------------------------------
// Input body (padanan skema zod)
// ---------------------------------------------------------------------

// LoginInput — loginBodySchema {username min1, password min1}.
type LoginInput struct {
	Username string
	Password string
}

// RegisterInput — registerSchema packages/schemas (D-16 + ddl/81).
type RegisterInput struct {
	Email   string // sudah di-trim
	Nama    string // sudah di-trim
	Telepon string // opsional — kosong bila tidak diisi
	Sandi   string
}

// AktivasiInput — aktivasiBodySchema {token min10 max200}.
type AktivasiInput struct {
	Token string
}

// KirimUlangInput — kirimUlangAktivasiBodySchema {email trim email max150}.
type KirimUlangInput struct {
	Email string
}

// ChangePasswordInput — changePasswordBodySchema {currentPassword min1, newPassword min6}.
type ChangePasswordInput struct {
	CurrentPassword string
	NewPassword     string
}

// ---------------------------------------------------------------------
// View respons
// ---------------------------------------------------------------------

// SessionUserRoleInfo — hasil JOIN core_users_roles → core_roles.
type SessionUserRoleInfo struct {
	Code        string  `json:"code"`
	Role        string  `json:"role"`
	Description *string `json:"description"`
}

// SessionUserView — blok user di view sesi.
type SessionUserView struct {
	ID       int64                 `json:"id"`
	Username string                `json:"username"`
	FullName string                `json:"fullName"` // = core_users.name
	Roles    []SessionUserRoleInfo `json:"roles"`
}

// SessionView — view sesi hasil login/refresh.
type SessionView struct {
	SessionID     int64           `json:"sessionId"`
	User          SessionUserView `json:"user"`
	PermissionSet []string        `json:"permissionSet"` // sorted leksikografis
	LoginAt       string          `json:"loginAt"`       // ISO 8601 (3 digit ms)
	ExpiresAt     string          `json:"expiresAt"`
}

// TokenPairResult — pasangan token + view sesi (login & refresh).
type TokenPairResult struct {
	AccessToken  string       `json:"accessToken"`
	RefreshToken string       `json:"refreshToken"`
	TokenType    string       `json:"tokenType"` // selalu "Bearer"
	ExpiresIn    int          `json:"expiresIn"` // detik umur access token
	Session      *SessionView `json:"session"`
}

// MenuItemView — menu /auth/me DATAR, urut kolom `order` (id tie-break);
// parent disertakan agar client bisa menyusun tree.
type MenuItemView struct {
	ID           int64   `json:"id"`
	Text         string  `json:"text"`
	UrlPath      *string `json:"urlPath"`
	Order        *int32  `json:"order"`
	Parent       *int64  `json:"parent"`
	Icon         *string `json:"icon"`
	ExternalHref *string `json:"externalHref"`
}

// MeView — view GET /auth/me (kontrak zod meViewSchema + idHrKaryawan).
type MeView struct {
	ID          int64                 `json:"id"`
	Username    string                `json:"username"`
	FullName    string                `json:"fullName"`
	Department  string                `json:"department"` // NULL → ""
	Email       string                `json:"email"`
	Roles       []SessionUserRoleInfo `json:"roles"`
	Permissions []string              `json:"permissions"`
	Menus       []MenuItemView        `json:"menus"`
	// IDHrKaryawan — hr_karyawan ter-link ke user; null bila tak ber-link.
	IDHrKaryawan *int64 `json:"idHrKaryawan"`
}

// RegisterResultView — respons POST /auth/register (akun NONAKTIF dulu).
type RegisterResultView struct {
	Email  string `json:"email"`
	Status string `json:"status"` // "MENUNGGU_AKTIVASI"
}

// ---------------------------------------------------------------------
// Email aktivasi (dependency injection — TIDAK mengimpor mailer)
// ---------------------------------------------------------------------

// MailAktivasiPayload — payload kiriman ke KirimAktivasi yang di-wiring
// cmd/api dari mailer. Keagalan kirim TIDAK membalikkan registrasi.
type MailAktivasiPayload struct {
	Kepada      string // email user (tujuan SMTP)
	NamaTujuan  string // nama tampil
	IDCoreUsers int64  // pemilik akun (jejak core_mail_log)
	Token       string // token mentah — hanya hidup di email
	Tautan      string // <ECOM_PORTAL_URL>/aktivasi?token=…
}

// isoOf — toISOString() JS: 3 digit milidetik + offset Z.
func isoOf(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}
