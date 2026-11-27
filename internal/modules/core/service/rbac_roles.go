// Service Peran (Sheet "Peran & Izin Global") fitur RBAC modul core — port
// VERBATIM services/rbac/roles.service.ts NestJS ke MODEL RBAC v2.1
// SET-based: role menyandang SET permission lewat junction
// core_role_permissions (unik pair); PUT permissions menggantikan SELURUH
// grant (REPLACE) lalu Compiler.InvalidateAll() SETELAH commit. Sumber
// permission code = core_routes.permission_code (DISTINCT via junction).
package service

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// RolesService — orkestrasi fitur roles.
type RolesService struct {
	db       *database.DB
	audit    *audit.Service
	compiler *rbac.Compiler
	repo     *repository.RolesRepo
}

// NewRolesService membangun service roles dari deps modul.
func NewRolesService(d types.Deps) *RolesService {
	return &RolesService{db: d.DB, audit: d.Audit, compiler: d.Compiler, repo: repository.NewRolesRepo()}
}

// RoleCreateInput — nilai create role (hasil validasi handler; schema v2:
// code/role/description).
type RoleCreateInput struct {
	Code        string
	Role        string
	Description *string // absent → "" (persis `input.description ?? ""`)
}

// RoleUpdateInput — nilai PATCH role: label (`role`) & description; kode
// role TIDAK bisa diubah (natural key tetap).
type RoleUpdateInput struct {
	Role           *string
	Description    *string
	HasDescription bool // false = field absen (undefined); true + nil = null eksplisit
}

// List — daftar role + memberCount (anggota dari junction core_users_roles).
func (s *RolesService) List(ctx context.Context) ([]types.RoleView, error) {
	return s.repo.List(ctx, s.db.Pool)
}

// Create — buat role (port createRole; schema v2): kode unik (409 SYS-409,
// pre-check + tangkap 23505 → 409 pesan sama), is_system=false. Role baru
// TANPA permission (diisi via PUT /:id/permissions).
func (s *RolesService) Create(ctx context.Context, in RoleCreateInput, actor audit.Actor) (types.RoleView, error) {
	var view types.RoleView
	desc := ""
	if in.Description != nil {
		desc = *in.Description
	}
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if _, ada, err := s.repo.IDByCode(ctx, tx, in.Code); err != nil {
			return err
		} else if ada {
			return errkontrak.Conflict(fmt.Sprintf("Kode role '%s' sudah dipakai.", in.Code), "SYS-409")
		}
		row, err := s.repo.Insert(ctx, tx, in.Code, in.Role, &desc)
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode role '%s' sudah dipakai.", in.Code), "SYS-409")
			}
			return err
		}
		view = row
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "role",
				EntityID:   row.Code,
				Action:     "create",
				AfterValue: audit.Snapshot{"role": row.Role},
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return types.RoleView{}, err
	}
	return view, nil
}

// Update — PATCH role (port updateRole): label (`role`) & description;
// kode immutable. updated_at SELALU di-set (persis NestJS yang menyertakan
// updatedAt walau body kosong). Perubahan label/deskripsi bukan bagian set
// permission — cache user TIDAK dibuang.
func (s *RolesService) Update(ctx context.Context, id int64, in RoleUpdateInput, actor audit.Actor) (types.RoleView, error) {
	now := time.Now()
	var updated repository.MuatRoleByIDRow

	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		role, ok, err := s.repo.MuatByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if !ok {
			return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", id), "SYS-404")
		}

		// Drizzle membangun set parsial — Go: statement kondisional dengan
		// updatedAt yang sama; bila tidak ada field → touch updated_at saja.
		last := role
		if in.Role != nil {
			row, ok, err := s.repo.UpdateLabel(ctx, tx, id, *in.Role, now)
			if err != nil {
				return err
			}
			if !ok {
				return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", id), "SYS-404")
			}
			last = muatFromLabelRow(row)
		}
		if in.HasDescription {
			row, ok, err := s.repo.UpdateDescription(ctx, tx, id, in.Description, now)
			if err != nil {
				return err
			}
			if !ok {
				return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", id), "SYS-404")
			}
			last = muatFromDescRow(row)
		}
		if in.Role == nil && !in.HasDescription {
			row, ok, err := s.repo.TouchRole(ctx, tx, id, now)
			if err != nil {
				return err
			}
			if !ok {
				return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", id), "SYS-404")
			}
			last = muatFromTouchRow(row)
		}
		updated = last

		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "role",
				EntityID:   updated.Code,
				Action:     "update",
				BeforeValue: audit.Snapshot{
					"role":        role.Role,
					"description": descriptionOrNull(role.Description),
				},
				AfterValue: audit.Snapshot{
					"role":        updated.Role,
					"description": descriptionOrNull(updated.Description),
				},
				Severity: audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return types.RoleView{}, err
	}
	// roleToView(updated) — memberCount default 0 (persis NestJS PATCH).
	return roleViewFromMuat(updated, 0), nil
}

// GetPermissions — permission milik role (GET /:id/permissions): DISTINCT
// core_routes.permission_code via grant SET (urut code).
func (s *RolesService) GetPermissions(ctx context.Context, ref string) ([]string, error) {
	roleID, err := s.resolveRoleID(ctx, ref)
	if err != nil {
		return nil, err
	}
	codes, err := s.repo.PermissionCodesOfRole(ctx, s.db.Pool, roleID)
	if err != nil {
		return nil, err
	}
	if codes == nil {
		codes = []string{}
	}
	return codes, nil
}

// GetPermissionSetIDs — id SET permission yang di-grant role (junction,
// urut id) — state checked editor frontend.
func (s *RolesService) GetPermissionSetIDs(ctx context.Context, ref string) ([]int64, error) {
	roleID, err := s.resolveRoleID(ctx, ref)
	if err != nil {
		return nil, err
	}
	ids, err := s.repo.PermissionSetIDsOfRole(ctx, s.db.Pool, roleID)
	if err != nil {
		return nil, err
	}
	if ids == nil {
		ids = []int64{}
	}
	return ids, nil
}

// ReplacePermissionsInput — body PUT /:id/permissions.
type ReplacePermissionsInput struct {
	PermissionIds []int64
}

// ReplacePermissions — REPLACE SET permission role (port
// replacePermissions): dedupe, validasi id SET (404 PRE-CHECK tanpa
// menulis), target di-sort by (name ?? String(id)) localeCompare, hapus +
// tulis grant, audit before/after kode — lalu Compiler.InvalidateAll()
// SETELAH commit (set efektif SELURUH user berpotensi berubah).
func (s *RolesService) ReplacePermissions(ctx context.Context, ref string, in ReplacePermissionsInput, actor audit.Actor) ([]string, error) {
	roleID, err := s.resolveRoleID(ctx, ref)
	if err != nil {
		return nil, err
	}
	uniqueIds := dedupeIds(in.PermissionIds)

	var granted []string
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		before, err := s.repo.CodesOfRoleGrants(ctx, tx, roleID)
		if err != nil {
			return err
		}

		// Pre-check target TANPA menulis (verbatim: query bila ada ids).
		targets, err := s.repo.PermissionTargetsByIds(ctx, tx, uniqueIds)
		if err != nil {
			return err
		}
		if len(targets) != len(uniqueIds) {
			found := make(map[int64]bool, len(targets))
			for _, t := range targets {
				found[t.ID] = true
			}
			missing := make([]string, 0)
			for _, pid := range uniqueIds {
				if !found[pid] {
					missing = append(missing, fmt.Sprintf("%d", pid))
				}
			}
			return errkontrak.NotFound(fmt.Sprintf("SET permission tidak ditemukan: %s.", strings.Join(missing, ", ")), "SYS-404")
		}
		// Urut target by (name ?? String(id)) localeCompare.
		byID := make(map[int64]repository.ListPermissionTargetsByIdsRow, len(targets))
		for _, t := range targets {
			byID[t.ID] = t
		}
		ordered := make([]repository.ListPermissionTargetsByIdsRow, 0, len(uniqueIds))
		for _, pid := range uniqueIds {
			ordered = append(ordered, byID[pid])
		}
		sort.SliceStable(ordered, func(i, j int) bool {
			return sortKeyOf(ordered[i]) < sortKeyOf(ordered[j])
		})

		// REPLACE: hapus grant lama role, tulis yang baru (unik pair
		// idempoten).
		if err := s.repo.DeleteGrantsByRole(ctx, tx, roleID); err != nil {
			return err
		}
		for _, t := range ordered {
			if err := s.repo.InsertGrant(ctx, tx, roleID, t.ID); err != nil {
				return err
			}
		}

		after, err := s.repo.CodesOfRoleGrants(ctx, tx, roleID)
		if err != nil {
			return err
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "role_permission",
				EntityID:    fmt.Sprintf("%d", roleID),
				Action:      "replace",
				BeforeValue: audit.Snapshot{"permissions": before},
				AfterValue:  audit.Snapshot{"permissions": after},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		granted = after
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Presedensi v2: buang cache SELURUH user SETELAH commit.
	s.compiler.InvalidateAll()
	if granted == nil {
		granted = []string{}
	}
	return granted, nil
}

// MenuIDs — id menu milik role (port iam findMenuIdsByRole): role wajib
// ada (404 SYS-404 `Role id ${id} tidak ditemukan.`), junction baca + sort
// asc numerik.
func (s *RolesService) MenuIDs(ctx context.Context, roleID int64) ([]int64, error) {
	if _, ada, err := s.repo.RoleIDByID(ctx, s.db.Pool, roleID); err != nil {
		return nil, err
	} else if !ada {
		return nil, errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", roleID), "SYS-404")
	}
	ids, err := s.repo.MenuIDsByRole(ctx, s.db.Pool, roleID)
	if err != nil {
		return nil, err
	}
	if ids == nil {
		ids = []int64{}
	}
	return ids, nil
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// resolveRoleID — resolve param id/kode → id role (404 SYS-404 verbatim).
func (s *RolesService) resolveRoleID(ctx context.Context, ref string) (int64, error) {
	id, ada, err := s.repo.RoleIDByRef(ctx, s.db.Pool, ref)
	if err != nil {
		return 0, err
	}
	if !ada {
		return 0, errkontrak.NotFound(fmt.Sprintf("Role '%s' tidak ditemukan.", ref), "SYS-404")
	}
	return id, nil
}

// sortKeyOf — kunci sort target REPLACE: (name ?? String(id)).
func sortKeyOf(t repository.ListPermissionTargetsByIdsRow) string {
	if t.Name.Valid {
		return t.Name.String
	}
	return fmt.Sprintf("%d", t.ID)
}

// descriptionOrNull — pgtype.Text → string atau nil (audit before/after).
func descriptionOrNull(t pgtype.Text) any {
	if t.Valid {
		return t.String
	}
	return nil
}

// muatFrom*Row — satukan tiga tipe RETURNING update role ke bentuk muat.
func muatFromLabelRow(r repository.UpdateRoleLabelRow) repository.MuatRoleByIDRow {
	return repository.MuatRoleByIDRow{ID: r.ID, Code: r.Code, Role: r.Role, Description: r.Description, IsSystem: r.IsSystem, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt}
}

func muatFromDescRow(r repository.UpdateRoleDescriptionRow) repository.MuatRoleByIDRow {
	return repository.MuatRoleByIDRow{ID: r.ID, Code: r.Code, Role: r.Role, Description: r.Description, IsSystem: r.IsSystem, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt}
}

func muatFromTouchRow(r repository.TouchRoleRow) repository.MuatRoleByIDRow {
	return repository.MuatRoleByIDRow{ID: r.ID, Code: r.Code, Role: r.Role, Description: r.Description, IsSystem: r.IsSystem, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt}
}

// roleViewFromMuat — baris role → RoleView (memberCount eksplisit).
func roleViewFromMuat(r repository.MuatRoleByIDRow, memberCount int64) types.RoleView {
	return types.RoleView{
		ID:          r.ID,
		Code:        r.Code,
		Role:        r.Role,
		Description: repository.PgTextPtr(r.Description),
		IsSystem:    r.IsSystem,
		MemberCount: memberCount,
		CreatedAt:   isoReq(r.CreatedAt),
		UpdatedAt:   isoReq(r.UpdatedAt),
	}
}
