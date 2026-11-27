// Package repository — SATU-SATUNYA pengguna sqlc area auth (padanan
// AuthRepository NestJS). Wrapper menerima executor apa pun (pool pgx |
// pgx.Tx — keduanya memenuhi gen.DBTX) saat konstruksi: service memakai
// pool di luar transaksi dan repository.New(tx) DI DALAM transaksi bisnis.
// Konversi pgtype → tipe Go polos dilakukan di sini (row→View).
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/auth/repository/gen"
)

// Repository — pembungkus gen.Querier dengan executor tetap.
type Repository struct {
	q *gen.Queries
}

// New — executor = *pgxpool.Pool | pgx.Tx.
func New(exec gen.DBTX) *Repository { return &Repository{q: gen.New(exec)} }

// ---------------------------------------------------------------------
// Baris hasil (konversi pgtype selesai di sini)
// ---------------------------------------------------------------------

// UserRow — baris core_users (kolom yang dipakai auth).
type UserRow struct {
	ID                  int64
	Username            string
	PasswordHash        string
	Name                string
	Email               string // NULL → ""
	Department          string // NULL → ""
	IsActive            bool
	FailedLoginAttempts int32
	LockedUntil         *time.Time
	MustChangePassword  bool
}

// SessionRow — baris core_sessions (validitas sesi ditentukan server).
type SessionRow struct {
	ID          int64
	IDCoreUsers int64
	UserName    string
	LoginAt     time.Time
	ExpiresAt   time.Time
	LogoutAt    *time.Time
	RevokedAt   *time.Time
	IsValid     bool
}

// AuthTokenRow — baris core_auth_tokens (lookup aktivasi).
type AuthTokenRow struct {
	ID            int64
	IDCoreUsers   int64
	DipakaiAt     *time.Time
	BerlakuHingga time.Time
}

// InsertUserRow — hasil INSERT user (RETURNING subset).
type InsertUserRow struct {
	ID       int64
	Username string
	Name     string
	Email    string
	IsActive bool
}

// RoleRow — roles user (JOIN junction, ORDER BY code).
type RoleRow struct {
	Code        string
	Role        string
	Description *string // NULL → nil
}

// MenuRow — menu user (DISTINCT, ORDER BY "order", id).
type MenuRow struct {
	ID           int64
	Text         string
	UrlPath      *string
	Order        *int32
	Parent       *int64
	Icon         *string
	ExternalHref *string
}

// LoginAuditParams — INSERT core_login_audit; FailReason "" = NULL
// (login sukses tanpa alasan gagal).
type LoginAuditParams struct {
	IDCoreUsers   *int64
	UsernameTried string
	Success       bool
	FailReason    string
	IpAddress     string
	UserAgent     string
	AttemptedAt   time.Time
}

// ---------------------------------------------------------------------
// Konversi pgtype → tipe polos
// ---------------------------------------------------------------------

func tsPtr(v pgtype.Timestamptz) *time.Time {
	if !v.Valid {
		return nil
	}
	t := v.Time
	return &t
}

func tsVal(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

func textVal(v pgtype.Text) string {
	if !v.Valid {
		return ""
	}
	return v.String
}

func textPtr(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	s := v.String
	return &s
}

func i8Ptr(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	n := v.Int64
	return &n
}

func i8Val(v int64) pgtype.Int8 { return pgtype.Int8{Int64: v, Valid: true} }

func i2Ptr(v pgtype.Int2) *int32 {
	if !v.Valid {
		return nil
	}
	n := int32(v.Int16)
	return &n
}

// uuidVal — string uuid → pgtype.UUID (entity_id core_auth_tokens).
func uuidVal(s string) pgtype.UUID {
	b, ok := parseUUID(s)
	if !ok {
		return pgtype.UUID{}
	}
	return pgtype.UUID{Bytes: b, Valid: true}
}

// parseUUID — hex 32 char (dengan/tanpa tanda hubung) → [16]byte.
func parseUUID(s string) ([16]byte, bool) {
	var out [16]byte
	clean := make([]byte, 0, 32)
	for i := 0; i < len(s) && len(clean) < 32; i++ {
		if s[i] != '-' {
			clean = append(clean, s[i])
		}
	}
	if len(clean) != 32 {
		return out, false
	}
	nibble := func(c byte) int {
		switch {
		case c >= '0' && c <= '9':
			return int(c - '0')
		case c >= 'a' && c <= 'f':
			return int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			return int(c-'A') + 10
		default:
			return -1
		}
	}
	for _, c := range clean {
		if nibble(c) < 0 {
			return out, false
		}
	}
	for i := 0; i < 16; i++ {
		out[i] = byte(nibble(clean[i*2])<<4 | nibble(clean[i*2+1]))
	}
	return out, true
}

// ---------------------------------------------------------------------
// core_users
// ---------------------------------------------------------------------

func userRowOf(r gen.GetUserByUsernameRow) *UserRow {
	return &UserRow{
		ID:                  r.ID,
		Username:            r.Username,
		PasswordHash:        r.PasswordHash,
		Name:                r.Name,
		Email:               textVal(r.Email),
		Department:          textVal(r.Department),
		IsActive:            r.IsActive,
		FailedLoginAttempts: r.FailedLoginAttempts,
		LockedUntil:         tsPtr(r.LockedUntil),
		MustChangePassword:  r.MustChangePassword,
	}
}

// GetUserByUsername — nil bila tak terdaftar.
func (r *Repository) GetUserByUsername(ctx context.Context, username string) (*UserRow, error) {
	row, err := r.q.GetUserByUsername(ctx, username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return userRowOf(row), nil
}

// GetUserByID — nil bila tidak ada (baris gen identik dgn by-username).
func (r *Repository) GetUserByID(ctx context.Context, id int64) (*UserRow, error) {
	row, err := r.q.GetUserByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return userRowOf(gen.GetUserByUsernameRow(row)), nil
}

// GetUserAktifByID — false bila tidak ada (dipakai guard → 401).
func (r *Repository) GetUserAktifByID(ctx context.Context, id int64) (bool, error) {
	aktif, err := r.q.GetUserAktifByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return aktif, nil
}

// InsertUser — nil = username sudah terdaftar (pre-check atau race).
func (r *Repository) InsertUser(ctx context.Context, username, email, nama, passwordHash string, aktif bool) (*InsertUserRow, error) {
	row, err := r.q.InsertUser(ctx, gen.InsertUserParams{
		Username:     username,
		Email:        pgtype.Text{String: email, Valid: true},
		Name:         nama,
		PasswordHash: passwordHash,
		IsActive:     aktif,
	})
	if err != nil {
		return nil, err
	}
	return &InsertUserRow{
		ID:       row.ID,
		Username: row.Username,
		Name:     row.Name,
		Email:    textVal(row.Email),
		IsActive: row.IsActive,
	}, nil
}

// UpdateLoginGagal — naikkan attempts + kunci bila ambang lolos.
func (r *Repository) UpdateLoginGagal(ctx context.Context, failed int32, lockedUntil *time.Time, id int64) error {
	p := gen.UpdateLoginGagalParams{
		FailedLoginAttempts: failed,
		LockedUntil:         pgtype.Timestamptz{},
		ID:                  id,
	}
	if lockedUntil != nil {
		p.LockedUntil = tsVal(*lockedUntil)
	}
	return r.q.UpdateLoginGagal(ctx, p)
}

// UpdateLoginSukses — reset attempts + unlock + last_login_at; hash
// upgrade ditulis sekalian (nil = tanpa upgrade — COALESCE).
func (r *Repository) UpdateLoginSukses(ctx context.Context, id int64, now time.Time, upgradedHash *string) error {
	p := gen.UpdateLoginSuksesParams{
		ID:           id,
		LastLoginAt:  tsVal(now),
		UpgradedHash: pgtype.Text{}, // NULL → COALESCE(password_hash)
	}
	if upgradedHash != nil {
		p.UpgradedHash = pgtype.Text{String: *upgradedHash, Valid: true}
	}
	return r.q.UpdateLoginSukses(ctx, p)
}

// UpdatePassword — hash baru + timestamp + reset must_change_password.
func (r *Repository) UpdatePassword(ctx context.Context, id int64, passwordHash string, changedAt time.Time, mustChange bool) error {
	return r.q.UpdatePassword(ctx, gen.UpdatePasswordParams{
		PasswordHash:       passwordHash,
		PasswordChangedAt:  tsVal(changedAt),
		MustChangePassword: mustChange,
		ID:                 id,
	})
}

// AktifkanUser — is_active=true + reset lockout + updated_at.
func (r *Repository) AktifkanUser(ctx context.Context, id int64, now time.Time) error {
	return r.q.AktifkanUser(ctx, gen.AktifkanUserParams{ID: id, UpdatedAt: tsVal(now)})
}

// CariKaryawanTerlink — id hr_karyawan ter-link; nil bila tak ber-link.
func (r *Repository) CariKaryawanTerlink(ctx context.Context, idCoreUsers int64) (*int64, error) {
	id, err := r.q.CariKaryawanTerlink(ctx, i8Val(idCoreUsers))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

// CariSecurityMeta — nilai jsonb baris 'security'; nil bila baris hilang.
func (r *Repository) CariSecurityMeta(ctx context.Context) ([]byte, error) {
	raw, err := r.q.CariSecurityMeta(ctx)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return raw, nil
}

// ---------------------------------------------------------------------
// core_sessions
// ---------------------------------------------------------------------

// InsertSesi — INSERT sesi login (device 'Browser', is_valid true,
// logout_at/revoked_at NULL) → id baris baru.
func (r *Repository) InsertSesi(ctx context.Context, idCoreUsers int64, userName, deviceKey string, loginAt, expiresAt time.Time, ipAddress, userAgent string) (int64, error) {
	return r.q.InsertSesi(ctx, gen.InsertSesiParams{
		IDCoreUsers: i8Val(idCoreUsers),
		UserName:    userName,
		DeviceKey:   pgtype.Text{String: deviceKey, Valid: true},
		LoginAt:     tsVal(loginAt),
		ExpiresAt:   tsVal(expiresAt),
		IpAddress:   ipAddress,
		UserAgent:   pgtype.Text{String: userAgent, Valid: true},
	})
}

// GetSesiByID — nil bila tidak ada.
func (r *Repository) GetSesiByID(ctx context.Context, id int64) (*SessionRow, error) {
	row, err := r.q.GetSesiByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &SessionRow{
		ID:          row.ID,
		IDCoreUsers: row.IDCoreUsers.Int64,
		UserName:    row.UserName,
		LoginAt:     row.LoginAt.Time,
		ExpiresAt:   row.ExpiresAt.Time,
		LogoutAt:    tsPtr(row.LogoutAt),
		RevokedAt:   tsPtr(row.RevokedAt),
		IsValid:     row.IsValid,
	}, nil
}

// TutupSesi — is_valid=false + logout_at (logout mandiri).
func (r *Repository) TutupSesi(ctx context.Context, id int64, logoutAt time.Time) error {
	return r.q.TutupSesi(ctx, gen.TutupSesiParams{ID: id, LogoutAt: tsVal(logoutAt)})
}

// ---------------------------------------------------------------------
// core_login_audit
// ---------------------------------------------------------------------

// InsertLoginAudit — catat percobaan login (sukses/gagal).
func (r *Repository) InsertLoginAudit(ctx context.Context, p LoginAuditParams) error {
	reason := gen.NullCoreLoginFailReason{Valid: p.FailReason != ""}
	if reason.Valid {
		reason.CoreLoginFailReason = gen.CoreLoginFailReason(p.FailReason)
	}
	return r.q.InsertLoginAudit(ctx, gen.InsertLoginAuditParams{
		IDCoreUsers:   i8Val(derefI8(p.IDCoreUsers)),
		UsernameTried: p.UsernameTried,
		Success:       p.Success,
		FailReason:    reason,
		IpAddress:     p.IpAddress,
		UserAgent:     p.UserAgent,
		AttemptedAt:   tsVal(p.AttemptedAt),
	})
}

func derefI8(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// ---------------------------------------------------------------------
// Roles & menus (view sesi/me + cek role register/login)
// ---------------------------------------------------------------------

// MuatRolesUser — JOIN junction → core_roles, ORDER BY code ASC.
func (r *Repository) MuatRolesUser(ctx context.Context, userID int64) ([]RoleRow, error) {
	rows, err := r.q.MuatRolesUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]RoleRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, RoleRow{
			Code:        row.Code,
			Role:        row.Role,
			Description: textPtr(row.Description),
		})
	}
	return out, nil
}

// MuatMenusUser — menu semua role user, DISTINCT, ORDER BY "order", id.
func (r *Repository) MuatMenusUser(ctx context.Context, userID int64) ([]MenuRow, error) {
	rows, err := r.q.MuatMenusUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]MenuRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, MenuRow{
			ID:           row.ID,
			Text:         row.Text,
			UrlPath:      textPtr(row.UrlPath),
			Order:        i2Ptr(row.Order),
			Parent:       i8Ptr(row.Parent),
			Icon:         textPtr(row.Icon),
			ExternalHref: textPtr(row.ExternalHref),
		})
	}
	return out, nil
}

// PunyaRoleKode — user memegang role ber-kode (mis. ecom_member)?
func (r *Repository) PunyaRoleKode(ctx context.Context, userID int64, kode string) (bool, error) {
	return r.q.PunyaRoleKode(ctx, gen.PunyaRoleKodeParams{IDCoreUsers: userID, Code: kode})
}

// CariRoleIdByKode — nil bila role belum di-seed.
func (r *Repository) CariRoleIdByKode(ctx context.Context, kode string) (*int64, error) {
	id, err := r.q.CariRoleIdByKode(ctx, kode)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

// AssignRoleUser — junction idempoten; assigner = user sendiri (register).
func (r *Repository) AssignRoleUser(ctx context.Context, idCoreUsers, idCoreRoles, idCoreUsersAssignedBy int64) error {
	return r.q.AssignRoleUser(ctx, gen.AssignRoleUserParams{
		IDCoreUsers:           idCoreUsers,
		IDCoreRoles:           idCoreRoles,
		IDCoreUsersAssignedBy: idCoreUsersAssignedBy,
	})
}

// ---------------------------------------------------------------------
// core_auth_tokens + core_password_history
// ---------------------------------------------------------------------

// InsertAuthToken — INSERT token (hash SHA-256; entity_id uuid acak) → id.
func (r *Repository) InsertAuthToken(ctx context.Context, entityID string, idCoreUsers int64, tokenHash string, berlakuHingga time.Time) (int64, error) {
	return r.q.InsertAuthToken(ctx, gen.InsertAuthTokenParams{
		EntityID:      uuidVal(entityID),
		IDCoreUsers:   idCoreUsers,
		TokenHash:     tokenHash,
		BerlakuHingga: tsVal(berlakuHingga),
	})
}

// CariAuthTokenByHash — token hidup by hash (jenis AKTIVASI, deleted_at
// NULL); nil bila tidak ada.
func (r *Repository) CariAuthTokenByHash(ctx context.Context, tokenHash string) (*AuthTokenRow, error) {
	row, err := r.q.CariAuthTokenByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &AuthTokenRow{
		ID:            row.ID,
		IDCoreUsers:   row.IDCoreUsers,
		DipakaiAt:     tsPtr(row.DipakaiAt),
		BerlakuHingga: row.BerlakuHingga.Time,
	}, nil
}

// TandaiTokenDipakai — one-time: dipakai_at + refresh updated_at.
func (r *Repository) TandaiTokenDipakai(ctx context.Context, now time.Time, id int64) error {
	return r.q.TandaiTokenDipakai(ctx, gen.TandaiTokenDipakaiParams{DipakaiAt: tsVal(now), ID: id})
}

// CabutTokenAktivasiBelumPakai — soft-delete token belum terpakai milik
// user (kirim-ulang — satu token aktif per user).
func (r *Repository) CabutTokenAktivasiBelumPakai(ctx context.Context, now time.Time, idCoreUsers int64) error {
	return r.q.CabutTokenAktivasiBelumPakai(ctx, gen.CabutTokenAktivasiBelumPakaiParams{DeletedAt: tsVal(now), IDCoreUsers: idCoreUsers})
}

// HapusTokenKedaluwarsa — hard delete token kedaluwarsa (sweep) → ids.
func (r *Repository) HapusTokenKedaluwarsa(ctx context.Context, sebelum time.Time) ([]int64, error) {
	return r.q.HapusTokenKedaluwarsa(ctx, tsVal(sebelum))
}

// InsertPasswordHistory — catat riwayat (masked = 4 char + 12 bullet).
func (r *Repository) InsertPasswordHistory(ctx context.Context, idCoreUsers int64, userName string, setAt time.Time, maskedHash string) error {
	return r.q.InsertPasswordHistory(ctx, gen.InsertPasswordHistoryParams{
		IDCoreUsers: idCoreUsers,
		UserName:    userName,
		SetAt:       tsVal(setAt),
		MaskedHash:  maskedHash,
	})
}
