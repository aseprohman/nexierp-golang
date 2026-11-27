// Fitur USERS modul core — SATU-SATUNYA pengguna pgx+sqlc untuk tabel
// core_users, core_users_roles, core_sessions, core_user_mfa,
// core_user_permissions, core_password_history (port VERBATIM
// repositories/rbac/users.repository.ts NestJS + mapper userToView/mfaToView
// dari rbac.views). Row→View di sini; guard 404/409 tetap di service.
//
// Semua method menerima executor gen.DBTX (pool | tx) — service meneruskan
// tx transaksi bisnis yang sama (audit + mutasi dalam SATU tx) atau pool
// untuk baca non-transaksi (padanan `Db | Tx` NestJS).
package repository

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// TextEmpty — pgtype.Text → string (NULL → ""; kolom legacy nullable).
func TextEmpty(t pgtype.Text) string {
	if t.Valid {
		return t.String
	}
	return ""
}

// Alias tipe baris/params sqlc yang dibutuhkan service — guard lapisan:
// service TIDAK mengimpor repository/gen langsung, hanya lewat paket ini.
type (
	MuatUserByIDRow          = gen.MuatUserByIDRow
	InsertUserRow            = gen.InsertUserRow
	InsertUserParams         = gen.InsertUserParams
	ListAllRolesLiteRow      = gen.ListAllRolesLiteRow
	ListRolesByIdsRow        = gen.ListRolesByIdsRow
	ListAssignmentsOfUserRow = gen.ListAssignmentsOfUserRow
	ListSessionsOfUserRow    = gen.ListSessionsOfUserRow
)

// UsersRepo — pembungkus query sqlc fitur users.
type UsersRepo struct{}

// UserRowToView — baris core_users (MuatUserByID) → UserView + roles.
func UserRowToView(row gen.MuatUserByIDRow, roles []types.RoleBrief) types.UserView {
	return userViewOf(row.ID, row.Username, row.Name, row.Email, row.Department,
		row.IsActive, row.PasswordChangedAt, row.MustChangePassword,
		row.FailedLoginAttempts, row.LockedUntil, row.LastLoginAt, row.CreatedAt,
		row.MfaEnabled, roles)
}

// UserInsertRowToView — baris RETURNING insert → UserView + roles.
func UserInsertRowToView(row gen.InsertUserRow, roles []types.RoleBrief) types.UserView {
	return userViewOf(row.ID, row.Username, row.Name, row.Email, row.Department,
		row.IsActive, row.PasswordChangedAt, row.MustChangePassword,
		row.FailedLoginAttempts, row.LockedUntil, row.LastLoginAt, row.CreatedAt,
		row.MfaEnabled, roles)
}

// NewUsersRepo membuat repo (tanpa state — executor per panggilan).
func NewUsersRepo() *UsersRepo { return &UsersRepo{} }

// UserFilter — filter list user (hasil parse PageRequest di handler/service):
// q ILIKE username/name/email OR + filter[role] EXISTS junction.
type UserFilter struct {
	Q        string
	RoleCode string
}

// ---------------------------------------------------------------------
// Mapper row → View
// ---------------------------------------------------------------------

// userViewOf — mapper baris user → UserView v2 MULTI-ROLE (userToView).
func userViewOf(id int64, username, name string, email, department pgtype.Text,
	isActive bool, passwordChangedAt pgtype.Timestamptz, mustChange bool,
	failed int32, lockedUntil, lastLoginAt, createdAt pgtype.Timestamptz,
	mfaEnabled bool, roles []types.RoleBrief) types.UserView {
	if roles == nil {
		roles = []types.RoleBrief{}
	}
	return types.UserView{
		ID:                  id,
		Username:            username,
		Name:                name,
		Email:               TextEmpty(email),
		Roles:               roles,
		Department:          TextEmpty(department), // NULL dirender kosong (ddl/65)
		IsActive:            isActive,
		PasswordChangedAt:   Iso(passwordChangedAt),
		MustChangePassword:  mustChange,
		FailedLoginAttempts: failed,
		LockedUntil:         Iso(lockedUntil),
		MfaEnabled:          mfaEnabled,
		LastLoginAt:         Iso(lastLoginAt),
		CreatedAt:           IsoRequired(createdAt),
	}
}

// ---------------------------------------------------------------------
// Baca — list terpagi
// ---------------------------------------------------------------------

// List — baris user satu halaman + roles junction per user (urut code),
// hasil dipetakan UserView. Default sort username ASC diterapkan caller
// (sortField/sortDesc dihitung service dari whitelist PageRequest).
func (r *UsersRepo) List(ctx context.Context, exec gen.DBTX, f UserFilter,
	sortField string, sortDesc bool, limit, offset int32) ([]types.UserView, error) {
	rows, err := gen.New(exec).ListUsers(ctx, gen.ListUsersParams{
		Column1:  f.Q,
		Username: "%" + f.Q + "%",
		Column3:  f.RoleCode,
		Column4:  sortField,
		Column5:  sortDesc,
		Limit:    limit,
		Offset:   offset,
	})
	if err != nil {
		return nil, err
	}
	ids := make([]int64, len(rows))
	for i, u := range rows {
		ids[i] = u.ID
	}
	rolesByUser, err := r.LoadRolesOfUsers(ctx, exec, ids)
	if err != nil {
		return nil, err
	}
	out := make([]types.UserView, len(rows))
	for i, u := range rows {
		out[i] = userViewOf(u.ID, u.Username, u.Name, u.Email, u.Department,
			u.IsActive, u.PasswordChangedAt, u.MustChangePassword,
			u.FailedLoginAttempts, u.LockedUntil, u.LastLoginAt, u.CreatedAt,
			u.MfaEnabled, rolesByUser[u.ID])
	}
	return out, nil
}

// Count — total user memenuhi filter list (pasangan List).
func (r *UsersRepo) Count(ctx context.Context, exec gen.DBTX, f UserFilter) (int64, error) {
	return gen.New(exec).CountUsers(ctx, gen.CountUsersParams{
		Column1:  f.Q,
		Username: "%" + f.Q + "%",
		Column3:  f.RoleCode,
	})
}

// LoadRolesOfUsers — role {code, role} per user (junction JOIN core_roles,
// urut code; kosong bila tidak ada user id).
func (r *UsersRepo) LoadRolesOfUsers(ctx context.Context, exec gen.DBTX, userIds []int64) (map[int64][]types.RoleBrief, error) {
	out := map[int64][]types.RoleBrief{}
	if len(userIds) == 0 {
		return out, nil
	}
	rows, err := gen.New(exec).LoadRolesOfUsers(ctx, userIds)
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		out[row.IDCoreUsers] = append(out[row.IDCoreUsers], types.RoleBrief{Code: row.Code, Role: row.Role})
	}
	return out, nil
}

// ---------------------------------------------------------------------
// Baca — detail berelasi satu user
// ---------------------------------------------------------------------

// MuatByID — user by id (false = tidak ada; service 404 SYS-404).
func (r *UsersRepo) MuatByID(ctx context.Context, exec gen.DBTX, id int64) (gen.MuatUserByIDRow, bool, error) {
	row, err := gen.New(exec).MuatUserByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.MuatUserByIDRow{}, false, nil
		}
		return gen.MuatUserByIDRow{}, false, err
	}
	return row, true, nil
}

// AllRolesLite — semua role (peta resolve assignment detail user).
func (r *UsersRepo) AllRolesLite(ctx context.Context, exec gen.DBTX) ([]gen.ListAllRolesLiteRow, error) {
	return gen.New(exec).ListAllRolesLite(ctx)
}

// AllUsernames — id→username (peta resolve assigned_by detail user).
func (r *UsersRepo) AllUsernames(ctx context.Context, exec gen.DBTX) (map[int64]string, error) {
	rows, err := gen.New(exec).ListAllUsernames(ctx)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string, len(rows))
	for _, row := range rows {
		out[row.ID] = row.Username
	}
	return out, nil
}

// AssignmentsOfUser — baris junction core_users_roles milik user.
func (r *UsersRepo) AssignmentsOfUser(ctx context.Context, exec gen.DBTX, userId int64) ([]gen.ListAssignmentsOfUserRow, error) {
	return gen.New(exec).ListAssignmentsOfUser(ctx, userId)
}

// OverridesOfUser — override per-user PER SET (baris hidup saja, terbaru
// dulu) dipetakan UserOverrideView (overrideToView; moduleKey = segmen
// pertama nama SET; nama legacy NULL → `set#<id>`).
func (r *UsersRepo) OverridesOfUser(ctx context.Context, exec gen.DBTX, userId int64) ([]types.UserOverrideView, error) {
	rows, err := gen.New(exec).ListOverridesOfUser(ctx, userId)
	if err != nil {
		return nil, err
	}
	out := make([]types.UserOverrideView, len(rows))
	for i, row := range rows {
		name := "set#" + strconv.FormatInt(row.IDCorePermissions, 10)
		if row.PermissionName.Valid {
			name = row.PermissionName.String
		}
		moduleKey := name
		if dot := strings.IndexByte(name, '.'); dot >= 0 {
			moduleKey = name[:dot]
		}
		out[i] = types.UserOverrideView{
			ID:             row.ID,
			UserID:         row.IDCoreUsers,
			UserName:       row.UserName,
			PermissionID:   row.IDCorePermissions,
			PermissionName: name,
			ModuleKey:      moduleKey,
			Granted:        row.Granted,
			GrantedByName:  PgTextPtr(row.GrantedByName),
			GrantedAt:      IsoRequired(row.GrantedAt),
			ExpiresAt:      Iso(row.ExpiresAt),
		}
	}
	return out, nil
}

// SessionsOfUser — sesi user (tanpa order SQL; service sort loginAt desc).
func (r *UsersRepo) SessionsOfUser(ctx context.Context, exec gen.DBTX, userId int64) ([]gen.ListSessionsOfUserRow, error) {
	return gen.New(exec).ListSessionsOfUser(ctx, pgtype.Int8{Int64: userId, Valid: true})
}

// MfaByUser — baris MFA user (nil bila belum ada; limit 1).
func (r *UsersRepo) MfaByUser(ctx context.Context, exec gen.DBTX, userId int64) (*types.MfaView, error) {
	rows, err := gen.New(exec).MuatMfaByUser(ctx, userId)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	row := rows[0]
	return &types.MfaView{
		UserID:            row.IDCoreUsers,
		UserName:          row.UserName,
		Method:            string(row.Method),
		ConfirmedAt:       Iso(row.ConfirmedAt),
		Enabled:           row.Enabled,
		LastUsedAt:        Iso(row.LastUsedAt),
		RecoveryCodesLeft: row.RecoveryCodesLeft,
	}, nil
}

// RolePermissionNames — nama SET yang dipegang user via junction role-nya,
// status aktif, urut name (name legacy nullable → "").
func (r *UsersRepo) RolePermissionNames(ctx context.Context, exec gen.DBTX, userId int64) ([]string, error) {
	rows, err := gen.New(exec).ListRolePermissionNames(ctx, userId)
	if err != nil {
		return nil, err
	}
	out := make([]string, len(rows))
	for i, n := range rows {
		out[i] = TextEmpty(n)
	}
	return out, nil
}

// ---------------------------------------------------------------------
// Guard baris (false → service melempar 404/409 berkode)
// ---------------------------------------------------------------------

// IDByUsername — dupe-check create (false = bebas dipakai).
func (r *UsersRepo) IDByUsername(ctx context.Context, exec gen.DBTX, username string) (int64, bool, error) {
	id, err := gen.New(exec).CariIDByUsername(ctx, username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, err
	}
	return id, true, nil
}

// RolesByIds — role {id, code, role} by ids (validasi roleIds).
func (r *UsersRepo) RolesByIds(ctx context.Context, exec gen.DBTX, ids []int64) ([]gen.ListRolesByIdsRow, error) {
	return gen.New(exec).ListRolesByIds(ctx, ids)
}

// RoleCodesOfUser — kode role yang sedang dipegang user (audit before).
func (r *UsersRepo) RoleCodesOfUser(ctx context.Context, exec gen.DBTX, userId int64) ([]string, error) {
	return gen.New(exec).ListRoleCodesOfUser(ctx, userId)
}

// ---------------------------------------------------------------------
// Tulis — user / junction role / sesi / riwayat password
// ---------------------------------------------------------------------

// Insert — user baru → baris lengkap (password_hash dibangun service).
func (r *UsersRepo) Insert(ctx context.Context, exec gen.DBTX, p gen.InsertUserParams) (gen.InsertUserRow, error) {
	return gen.New(exec).InsertUser(ctx, p)
}

// UpdateIsActive — set is_active by id (tanpa updated_at — persis drizzle).
func (r *UsersRepo) UpdateIsActive(ctx context.Context, exec gen.DBTX, id int64, isActive bool) error {
	return gen.New(exec).UpdateUserIsActive(ctx, gen.UpdateUserIsActiveParams{ID: id, IsActive: isActive})
}

// UpdateResetPassword — password baru + must_change_password, buka kunci,
// password_changed_at NULL (kolom set tetap — persis NestJS).
func (r *UsersRepo) UpdateResetPassword(ctx context.Context, exec gen.DBTX, id int64, passwordHash string) error {
	return gen.New(exec).UpdateUserResetPassword(ctx, gen.UpdateUserResetPasswordParams{ID: id, PasswordHash: passwordHash})
}

// UpdateUnlock — reset failed_login_attempts & locked_until.
func (r *UsersRepo) UpdateUnlock(ctx context.Context, exec gen.DBTX, id int64) error {
	return gen.New(exec).UpdateUserUnlock(ctx, id)
}

// InsertUserRole — sisip assignment; idempoten=true → ON CONFLICT DO
// NOTHING (verbatim create), false = insert polos (verbatim REPLACE).
func (r *UsersRepo) InsertUserRole(ctx context.Context, exec gen.DBTX, idCoreUsers, idCoreRoles, idCoreUsersAssignedBy int64, idempoten bool) error {
	p := gen.InsertUserRoleParams{IDCoreUsers: idCoreUsers, IDCoreRoles: idCoreRoles, IDCoreUsersAssignedBy: idCoreUsersAssignedBy}
	if idempoten {
		return gen.New(exec).InsertUserRoleIfAbsent(ctx, gen.InsertUserRoleIfAbsentParams(p))
	}
	return gen.New(exec).InsertUserRole(ctx, p)
}

// DeleteUserRolesByUser — hapus SELURUH assignment user (REPLACE).
func (r *UsersRepo) DeleteUserRolesByUser(ctx context.Context, exec gen.DBTX, userId int64) error {
	return gen.New(exec).DeleteUserRolesByUser(ctx, userId)
}

// CabutSesiAktif — is_valid=false + revoked_at untuk baris belum di-revoke.
func (r *UsersRepo) CabutSesiAktif(ctx context.Context, exec gen.DBTX, userId int64, revokedAt time.Time) error {
	return gen.New(exec).CabutSesiAktif(ctx, gen.CabutSesiAktifParams{
		IDCoreUsers: pgtype.Int8{Int64: userId, Valid: true},
		RevokedAt:   pgtype.Timestamptz{Time: revokedAt, Valid: true},
	})
}

// InsertPasswordHistory — baris riwayat (mask tampilan, bukan plaintext).
func (r *UsersRepo) InsertPasswordHistory(ctx context.Context, exec gen.DBTX, idCoreUsers int64, userName string, setAt time.Time, maskedHash string) error {
	return gen.New(exec).InsertPasswordHistory(ctx, gen.InsertPasswordHistoryParams{
		IDCoreUsers: idCoreUsers,
		UserName:    userName,
		SetAt:       pgtype.Timestamptz{Time: setAt, Valid: true},
		MaskedHash:  maskedHash,
	})
}
