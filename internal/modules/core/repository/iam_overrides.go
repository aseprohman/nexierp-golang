// repository/iam_overrides.go — SATU-SATUNYA pengguna area sqlc
// USER-OVERRIDES (`core_user_permissions` granularitas PER SET — padanan
// UserOverridesRepository NestJS). Alias `granted_by` = LEFT JOIN core_users
// pemberi (persis alias drizzle). Invalidasi compiler = urusan service.
package repository

import (
	"context"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// OverridesRepo — wrapper sqlc area user-overrides.
type OverridesRepo struct{}

// NewOverridesRepo membuat repository user-overrides.
func NewOverridesRepo() *OverridesRepo { return &OverridesRepo{} }

// kolomSortOverrides — whitelist sort list override (persis drizzlePageBounds).
var kolomSortOverrides = map[string]string{
	"id":         "core_user_permissions.id",
	"granted_at": "core_user_permissions.granted_at",
	"created_at": "core_user_permissions.created_at",
}

// kolomJoinOverrides — kolom flat hasil JOIN (persis overrideJoinColumns).
const kolomJoinOverrides = `core_user_permissions.id, core_user_permissions.id_core_users,
       core_users.name, core_user_permissions.id_core_permissions,
       core_permissions.name, core_user_permissions.granted,
       granted_by_user_overrides.name, core_user_permissions.granted_at,
       core_user_permissions.expires_at`

// fromJoinOverrides — FROM + alias pemberi (persis alias granted_by_user_overrides).
const fromJoinOverrides = `FROM core_user_permissions
       JOIN core_users ON core_users.id = core_user_permissions.id_core_users
       JOIN core_permissions ON core_permissions.id = core_user_permissions.id_core_permissions
       LEFT JOIN core_users granted_by_user_overrides ON granted_by_user_overrides.id = core_user_permissions.id_core_users_granted_by`

// List — daftar override milik SATU user — paginated + filter opsional
// `search` (ILIKE nama SET). Default `granted_at DESC, id DESC` (terbaru dulu).
func (r *OverridesRepo) List(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, userID int64, search *string) ([]types.UserOverrideView, int, error) {
	if err := shared.SortUnknown(pr, keysOf(kolomSortOverrides)); err != nil {
		return nil, 0, err
	}

	where := " WHERE core_user_permissions.id_core_users = $1 AND core_user_permissions.deleted_at IS NULL"
	args := []any{userID}
	if search != nil && *search != "" {
		where += " AND core_permissions.name ILIKE $" + strconv.Itoa(len(args)+1)
		args = append(args, "%"+*search+"%")
	}

	var total int
	if err := exec.QueryRow(ctx,
		"SELECT count(*) "+fromJoinOverrides+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	orderBy := orderClause(pr, kolomSortOverrides, "core_user_permissions.granted_at DESC, core_user_permissions.id DESC")
	sql := "SELECT " + kolomJoinOverrides + " " + fromJoinOverrides + where +
		" ORDER BY " + orderBy +
		" LIMIT $" + strconv.Itoa(len(args)+1) + " OFFSET $" + strconv.Itoa(len(args)+2)
	args = append(args, pr.Limit, pr.Offset)

	rows, err := exec.Query(ctx, sql, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []types.UserOverrideView{}
	for rows.Next() {
		var row gen.FindOverrideJoinRowRow
		if err := rows.Scan(&row.ID, &row.UserID, &row.UserName, &row.PermissionID,
			&row.PermissionName, &row.Granted, &row.GrantedByName,
			&row.GrantedAt, &row.ExpiresAt); err != nil {
			return nil, 0, err
		}
		out = append(out, OverrideToView(row))
	}
	return out, total, rows.Err()
}

// FindJoinRow — baca ulang SATU baris override hidup berbentuk flat JOIN
// (setelah upsert dijamin ada) — sumber view. Null bila absen.
func (r *OverridesRepo) FindJoinRow(ctx context.Context, exec DBTX, userID, permissionID int64) (*gen.FindOverrideJoinRowRow, error) {
	row, err := gen.New(exec).FindOverrideJoinRow(ctx, gen.FindOverrideJoinRowParams{
		IDCoreUsers:       userID,
		IDCorePermissions: permissionID,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindUserById — user target by id (404 oleh service); null bila absen.
func (r *OverridesRepo) FindUserById(ctx context.Context, exec DBTX, userID int64) (bool, error) {
	_, err := gen.New(exec).FindUserById(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindPermissionById — SET permission by id ({id, name} — entityId audit).
func (r *OverridesRepo) FindPermissionById(ctx context.Context, exec DBTX, permissionID int64) (*gen.FindPermissionNameByIdRow, error) {
	row, err := gen.New(exec).FindPermissionNameById(ctx, permissionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindLiveById — override HIDUP by id baris (baris PENUH); null bila absen.
func (r *OverridesRepo) FindLiveById(ctx context.Context, exec DBTX, id int64) (*gen.CoreUserPermission, error) {
	row, err := gen.New(exec).FindLiveOverrideById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// OverrideUpsert — nilai upsert (dibangun service; updated_at = baris ke-7).
type OverrideUpsert struct {
	IDCoreUsers          int64
	IDCorePermissions    int64
	Granted              bool
	IDCoreUsersGrantedBy int64
	GrantedAt            pgtype.Timestamptz
	ExpiresAt            pgtype.Timestamptz
	UpdatedAt            pgtype.Timestamptz
}

// Upsert — INSERT ... ON CONFLICT (user, permission) WHERE deleted_at IS NULL
// DO UPDATE (baris soft-delete tidak disentuh) — persis target+targetWhere.
func (r *OverridesRepo) Upsert(ctx context.Context, exec DBTX, v OverrideUpsert) error {
	return gen.New(exec).UpsertOverride(ctx, gen.UpsertOverrideParams{
		IDCoreUsers:          v.IDCoreUsers,
		IDCorePermissions:    v.IDCorePermissions,
		Granted:              v.Granted,
		IDCoreUsersGrantedBy: v.IDCoreUsersGrantedBy,
		GrantedAt:            v.GrantedAt,
		ExpiresAt:            v.ExpiresAt,
		Column7:              v.UpdatedAt,
	})
}

// SoftDeleteById — SOFT DELETE override by id (deleted_at + updated_at).
func (r *OverridesRepo) SoftDeleteById(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt pgtype.Timestamptz) error {
	return gen.New(exec).SoftDeleteOverrideById(ctx, gen.SoftDeleteOverrideByIdParams{
		ID:        id,
		DeletedAt: deletedAt,
		UpdatedAt: updatedAt,
	})
}
