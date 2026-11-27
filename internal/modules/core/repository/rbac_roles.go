// Fitur ROLES modul core — SATU-SATUNYA pengguna pgx+sqlc untuk tabel
// core_roles, core_role_permissions, core_permissions, core_permissions_routes,
// core_routes, core_users_roles, core_roles_menus (port VERBATIM
// repositories/rbac/roles.repository.ts + potongan iam/menus.repository.ts).
// Row→View di sini; guard 404/409 tetap di service.
package repository

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// Alias tipe baris sqlc untuk service (guard lapisan — lihat rbac_users.go).
type (
	MuatRoleByIDRow               = gen.MuatRoleByIDRow
	ListPermissionTargetsByIdsRow = gen.ListPermissionTargetsByIdsRow
	UpdateRoleLabelRow            = gen.UpdateRoleLabelRow
	UpdateRoleDescriptionRow      = gen.UpdateRoleDescriptionRow
	TouchRoleRow                  = gen.TouchRoleRow
)

// RolesRepo — pembungkus query sqlc fitur roles.
type RolesRepo struct{}

// NewRolesRepo membuat repo (tanpa state — executor per panggilan).
func NewRolesRepo() *RolesRepo { return &RolesRepo{} }

// roleViewOf — mapper baris core_roles → RoleView (roleToView).
func roleViewOf(id int64, code, role string, description pgtype.Text, isSystem bool,
	createdAt, updatedAt pgtype.Timestamptz, memberCount int64) types.RoleView {
	return types.RoleView{
		ID:          id,
		Code:        code,
		Role:        role,
		Description: PgTextPtr(description),
		IsSystem:    isSystem,
		MemberCount: memberCount,
		CreatedAt:   IsoRequired(createdAt),
		UpdatedAt:   IsoRequired(updatedAt),
	}
}

// List — daftar role + memberCount (anggota dihitung dari junction
// core_users_roles; MULTI-ROLE — tanpa kolom role primer), urut id ASC.
func (r *RolesRepo) List(ctx context.Context, exec gen.DBTX) ([]types.RoleView, error) {
	q := gen.New(exec)
	roleRows, err := q.ListRoles(ctx)
	if err != nil {
		return nil, err
	}
	counts, err := q.CountRoleMembers(ctx)
	if err != nil {
		return nil, err
	}
	members := make(map[int64]int64, len(counts))
	for _, c := range counts {
		members[c.IDCoreRoles] = c.Total
	}
	out := make([]types.RoleView, len(roleRows))
	for i, row := range roleRows {
		out[i] = roleViewOf(row.ID, row.Code, row.Role, row.Description, row.IsSystem,
			row.CreatedAt, row.UpdatedAt, members[row.ID])
	}
	return out, nil
}

// IDByCode — role id by kode unik (dupe-check create; false = bebas).
func (r *RolesRepo) IDByCode(ctx context.Context, exec gen.DBTX, code string) (int64, bool, error) {
	id, err := gen.New(exec).CariIDByCode(ctx, code)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, err
	}
	return id, true, nil
}

// RoleIDByRef — resolve param id/kode → id role (verbatim resolveRoleId:
// angka bulat positif dicari by id, selain itu by kode; false = tidak ada).
func (r *RolesRepo) RoleIDByRef(ctx context.Context, exec gen.DBTX, idOrCode string) (int64, bool, error) {
	q := gen.New(exec)
	asNumber, err := strconv.ParseInt(strings.TrimSpace(idOrCode), 10, 64)
	if err == nil && asNumber > 0 {
		id, err := q.CariRoleIDByID(ctx, asNumber)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return 0, false, nil
			}
			return 0, false, err
		}
		return id, true, nil
	}
	id, err := q.CariRoleIDByCode(ctx, idOrCode)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, err
	}
	return id, true, nil
}

// MuatByID — role by id (false = tidak ada).
func (r *RolesRepo) MuatByID(ctx context.Context, exec gen.DBTX, id int64) (gen.MuatRoleByIDRow, bool, error) {
	row, err := gen.New(exec).MuatRoleByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.MuatRoleByIDRow{}, false, nil
		}
		return gen.MuatRoleByIDRow{}, false, err
	}
	return row, true, nil
}

// RoleIDByID — role id by id (findRoleIdById; false = tidak ada).
func (r *RolesRepo) RoleIDByID(ctx context.Context, exec gen.DBTX, id int64) (int64, bool, error) {
	roleID, err := gen.New(exec).CariRoleIDByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, err
	}
	return roleID, true, nil
}

// Insert — role baru (is_system=false dibangun service) → RoleView.
func (r *RolesRepo) Insert(ctx context.Context, exec gen.DBTX, code, role string, description *string) (types.RoleView, error) {
	row, err := gen.New(exec).InsertRole(ctx, gen.InsertRoleParams{
		Code:        code,
		Role:        role,
		Description: TextPtrOf(description),
		IsSystem:    false,
	})
	if err != nil {
		return types.RoleView{}, err
	}
	return roleViewOf(row.ID, row.Code, row.Role, row.Description, row.IsSystem,
		row.CreatedAt, row.UpdatedAt, 0), nil
}

// UpdateLabel — PATCH role: label (`role`) + updated_at dibangun service.
func (r *RolesRepo) UpdateLabel(ctx context.Context, exec gen.DBTX, id int64, role string, updatedAt time.Time) (gen.UpdateRoleLabelRow, bool, error) {
	row, err := gen.New(exec).UpdateRoleLabel(ctx, gen.UpdateRoleLabelParams{
		ID:        id,
		Role:      role,
		UpdatedAt: pgtype.Timestamptz{Time: updatedAt, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.UpdateRoleLabelRow{}, false, nil
		}
		return gen.UpdateRoleLabelRow{}, false, err
	}
	return row, true, nil
}

// UpdateDescription — PATCH role: description (NULL eksplisit bila body
// mengirim null) + updated_at dibangun service.
func (r *RolesRepo) UpdateDescription(ctx context.Context, exec gen.DBTX, id int64, description *string, updatedAt time.Time) (gen.UpdateRoleDescriptionRow, bool, error) {
	row, err := gen.New(exec).UpdateRoleDescription(ctx, gen.UpdateRoleDescriptionParams{
		ID:          id,
		Description: TextPtrOf(description),
		UpdatedAt:   pgtype.Timestamptz{Time: updatedAt, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.UpdateRoleDescriptionRow{}, false, nil
		}
		return gen.UpdateRoleDescriptionRow{}, false, err
	}
	return row, true, nil
}

// TouchRole — PATCH role tanpa field: hanya updated_at (persis NestJS yang
// selalu menyertakan updatedAt dalam set).
func (r *RolesRepo) TouchRole(ctx context.Context, exec gen.DBTX, id int64, updatedAt time.Time) (gen.TouchRoleRow, bool, error) {
	row, err := gen.New(exec).TouchRole(ctx, gen.TouchRoleParams{
		ID:        id,
		UpdatedAt: pgtype.Timestamptz{Time: updatedAt, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.TouchRoleRow{}, false, nil
		}
		return gen.TouchRoleRow{}, false, err
	}
	return row, true, nil
}

// PermissionCodesOfRole — DISTINCT permission_code via grant SET
// (role_permissions → permissions_routes → routes), urut code ASC.
func (r *RolesRepo) PermissionCodesOfRole(ctx context.Context, exec gen.DBTX, roleId int64) ([]string, error) {
	return gen.New(exec).ListPermissionCodesOfRole(ctx, roleId)
}

// PermissionSetIDsOfRole — id SET yang di-grant (junction, urut id ASC).
func (r *RolesRepo) PermissionSetIDsOfRole(ctx context.Context, exec gen.DBTX, roleId int64) ([]int64, error) {
	return gen.New(exec).ListPermissionSetIDsOfRole(ctx, roleId)
}

// CodesOfRoleGrants — DISTINCT code dari grant SET saat ini (TANPA order
// SQL — di-sort di sini leksikografis, persis `.sort()` JS), dipakai audit
// before/after REPLACE dan respons {granted}.
func (r *RolesRepo) CodesOfRoleGrants(ctx context.Context, exec gen.DBTX, roleId int64) ([]string, error) {
	codes, err := gen.New(exec).CodesOfRoleGrants(ctx, roleId)
	if err != nil {
		return nil, err
	}
	sort.Strings(codes)
	return codes, nil
}

// PermissionTargetsByIds — SET target REPLACE {id, name} (name legacy
// nullable; kosong bila ids kosong — verbatim).
func (r *RolesRepo) PermissionTargetsByIds(ctx context.Context, exec gen.DBTX, ids []int64) ([]gen.ListPermissionTargetsByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.ListPermissionTargetsByIdsRow{}, nil
	}
	return gen.New(exec).ListPermissionTargetsByIds(ctx, ids)
}

// DeleteGrantsByRole — hapus SELURUH grant role (semantik REPLACE).
func (r *RolesRepo) DeleteGrantsByRole(ctx context.Context, exec gen.DBTX, roleId int64) error {
	return gen.New(exec).DeleteGrantsByRole(ctx, roleId)
}

// InsertGrant — sisip grant (unik pair) ON CONFLICT DO NOTHING (idempoten).
func (r *RolesRepo) InsertGrant(ctx context.Context, exec gen.DBTX, idCoreRoles, idCorePermissions int64) error {
	return gen.New(exec).InsertRoleGrant(ctx, gen.InsertRoleGrantParams{
		IDCoreRoles:       idCoreRoles,
		IDCorePermissions: idCorePermissions,
	})
}

// MenuIDsByRole — id menu junction core_roles_menus milik role.
func (r *RolesRepo) MenuIDsByRole(ctx context.Context, exec gen.DBTX, roleId int64) ([]int64, error) {
	ids, err := gen.New(exec).ListMenuIdsByRole(ctx, roleId)
	if err != nil {
		return nil, err
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] }) // port .sort((a,b) => a-b)
	return ids, nil
}
