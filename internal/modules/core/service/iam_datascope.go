// service/iam_datascope.go — manajemen data scope dinamis (ddl/50, padanan
// IamDatascopeService NestJS): katalog `core_scope_definitions`, pemberian
// whitelist `core_scope_assignments` (role/user XOR), himpunan nilai
// `core_scope_values` (REPLACE bulk satu tx). Trio + `version` (definitions
// & assignments) untuk optimistic locking If-Match (412 SYS-412). Evaluasi
// scope TIDAK di sini — evaluator generik core/rbac.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// ====================================================================
// DEFINISI (katalog dimensi scope)
// ====================================================================

// ListDefinitions — katalog definisi aktif + ringkasan jumlah assignment.
func (s *IamDatascopeService) ListDefinitions(ctx context.Context) ([]types.ScopeDefinitionSummary, error) {
	rows, err := s.repo.ListDefinitions(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	counts, err := s.repo.CountAssignmentsByDefinition(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	countByID := map[int64]int{}
	for _, c := range counts {
		countByID[c.ID] = int(c.Count)
	}
	out := make([]types.ScopeDefinitionSummary, 0, len(rows))
	for _, r := range rows {
		v := repository.DefinitionToView(r)
		out = append(out, types.ScopeDefinitionSummary{
			ScopeDefinitionView: v,
			AssignmentCount:     countByID[r.ID],
		})
	}
	return out, nil
}

// ScopeDefinitionCreateInput — body POST definitions
// (scopeDefinitionCreateSchema; module_id opsional → default 'system').
type ScopeDefinitionCreateInput struct {
	ModuleID    *int64
	ScopeKey    string
	Label       string
	Description *string
	TargetTable string
	TargetField string
}

// CreateDefinition — buat definisi katalog; duplikat (modul, scope_key)
// hidup → 409 SYS-409; operator v1 = 'in'.
func (s *IamDatascopeService) CreateDefinition(ctx context.Context, in ScopeDefinitionCreateInput, actor audit.Actor) (*types.ScopeDefinitionView, error) {
	moduleID := in.ModuleID
	if moduleID == nil {
		id, err := s.resolveModuleIdByKey(ctx, "system")
		if err != nil {
			return nil, err
		}
		moduleID = id
	}
	var view *types.ScopeDefinitionView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.ensureModuleExists(ctx, tx, *moduleID); err != nil {
			return err
		}
		dup, err := s.repo.FindDefinitionDuplicate(ctx, tx, *moduleID, in.ScopeKey)
		if err != nil {
			return err
		}
		if dup {
			return errkontrak.Conflict(fmt.Sprintf("scope_key '%s' sudah terdaftar di modul id %d.", in.ScopeKey, *moduleID), "SYS-409")
		}

		inserted, err := s.repo.InsertDefinition(ctx, tx, repository.BuildInsertDefinitionParams(*moduleID, in.ScopeKey, in.Label, in.Description, in.TargetTable, in.TargetField))
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_definition",
			EntityID:   fmt.Sprintf("%d", inserted.ID),
			Action:     "create",
			AfterValue: audit.Snapshot{
				"module_id": inserted.IDCoreModules,
				"scope_key": inserted.ScopeKey,
				"label":     inserted.Label,
				"target":    fmt.Sprintf("%s.%s", inserted.TargetTable, inserted.TargetField),
			},
		}, Actor: actor}}); err != nil {
			return err
		}
		v := repository.DefinitionToView(*inserted)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// FieldOpt — field opsional PATCH yang membedakan "absen" vs "null".
type FieldOpt struct {
	Present bool
	Null    bool
	Str     string
	Bool    bool
	Int     int64
}

// ScopeDefinitionUpdateInput — body PATCH definitions
// (scopeDefinitionUpdateSchema; semua opsional).
type ScopeDefinitionUpdateInput struct {
	Label       FieldOpt
	ScopeKey    FieldOpt
	ModuleID    FieldOpt
	TargetTable FieldOpt
	TargetField FieldOpt
	Description FieldOpt
	IsActive    FieldOpt
}

// UpdateDefinition — ubah definisi (label/description/is_active/registry);
// If-Match `version` (412 SYS-412 bila stale); version naik 1 tiap edit.
func (s *IamDatascopeService) UpdateDefinition(ctx context.Context, id int64, in ScopeDefinitionUpdateInput, actor audit.Actor, expectedVersion *int64) (*types.ScopeDefinitionView, error) {
	var view *types.ScopeDefinitionView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindDefinitionById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Definisi scope id %d tidak ditemukan.", id), "SYS-404")
		}
		if err := iamEnsureVersion(row.Version, expectedVersion); err != nil {
			return err
		}

		// Registry pindahan (module/scope_key) — guard unique pasangan hidup.
		nextModuleID := row.IDCoreModules
		nextScopeKey := row.ScopeKey
		if in.ModuleID.Present && !in.ModuleID.Null {
			nextModuleID = in.ModuleID.Int
		}
		if in.ScopeKey.Present && !in.ScopeKey.Null {
			nextScopeKey = in.ScopeKey.Str
		}
		if nextModuleID != row.IDCoreModules || nextScopeKey != row.ScopeKey {
			if err := s.ensureModuleExists(ctx, tx, nextModuleID); err != nil {
				return err
			}
			dupID, err := s.repo.FindDefinitionDuplicateId(ctx, tx, nextModuleID, nextScopeKey)
			if err != nil {
				return err
			}
			if dupID != nil && *dupID != id {
				return errkontrak.Conflict(fmt.Sprintf("scope_key '%s' sudah terdaftar di modul id %d.", nextScopeKey, nextModuleID), "SYS-409")
			}
		}

		patch := repository.DefinitionPatch{
			Version:   row.Version + 1,
			UpdatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
		}
		if in.Label.Present {
			patch.Label = &in.Label.Str
		}
		if in.Description.Present {
			patch.Description = &in.Description.Str
		}
		if in.IsActive.Present {
			patch.IsActive = &in.IsActive.Bool
		}
		if in.ScopeKey.Present {
			patch.ScopeKey = &in.ScopeKey.Str
		}
		if in.ModuleID.Present {
			patch.ModuleID = &in.ModuleID.Int
		}
		if in.TargetTable.Present {
			patch.TargetTable = &in.TargetTable.Str
		}
		if in.TargetField.Present {
			patch.TargetField = &in.TargetField.Str
		}

		updated, err := s.repo.UpdateDefinitionById(ctx, tx, id, patch)
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_definition",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "update",
			BeforeValue: audit.Snapshot{
				"label":       row.Label,
				"scope_key":   row.ScopeKey,
				"target":      fmt.Sprintf("%s.%s", row.TargetTable, row.TargetField),
				"description": row.Description,
				"is_active":   row.IsActive,
				"version":     row.Version,
			},
			AfterValue: audit.Snapshot{
				"label":       updated.Label,
				"scope_key":   updated.ScopeKey,
				"target":      fmt.Sprintf("%s.%s", updated.TargetTable, updated.TargetField),
				"description": updated.Description,
				"is_active":   updated.IsActive,
				"version":     updated.Version,
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}
		v := repository.DefinitionToView(*updated)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// DeleteDefinition — SOFT delete definisi; ditolak 409 bila masih ada
// assignment hidup (kelola pemberiannya dulu).
func (s *IamDatascopeService) DeleteDefinition(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindDefinitionById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Definisi scope id %d tidak ditemukan.", id), "SYS-404")
		}

		activeCount, err := s.repo.CountAssignmentsLiveByDefinition(ctx, tx, id)
		if err != nil {
			return err
		}
		if activeCount > 0 {
			return errkontrak.Conflict(fmt.Sprintf("Definisi masih dipakai %d pemberian — hapus pemberiannya lebih dulu.", activeCount), "SYS-409")
		}

		now := pgtype.Timestamptz{Time: time.Now(), Valid: true}
		if err := s.repo.SoftDeleteDefinitionById(ctx, tx, id, now, now, row.Version+1); err != nil {
			return err
		}

		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_definition",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "delete",
			BeforeValue: audit.Snapshot{
				"scope_key": row.ScopeKey,
				"target":    fmt.Sprintf("%s.%s", row.TargetTable, row.TargetField),
				"version":   row.Version,
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}})
		return err
	})
}

// ====================================================================
// ASSIGNMENT (pemberian whitelist ke role/user)
// ====================================================================

// ListAssignments — daftar assignment satu definisi + value_count
// (definisi wajib ada).
func (s *IamDatascopeService) ListAssignments(ctx context.Context, definitionID int64) ([]types.ScopeAssignmentView, error) {
	ok, err := s.repo.FindDefinitionIdById(ctx, s.db.Pool, definitionID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errkontrak.NotFound(fmt.Sprintf("Definisi scope id %d tidak ditemukan.", definitionID), "SYS-404")
	}

	rows, err := s.repo.ListAssignmentsByDefinition(ctx, s.db.Pool, definitionID)
	if err != nil {
		return nil, err
	}

	// Nilai whitelist per assignment (untuk seeding dialog Kelola Nilai UI).
	valueRows, err := s.repo.ListAllScopeValues(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	valuesByID := map[int64][]string{}
	for _, v := range valueRows {
		valuesByID[v.ID] = append(valuesByID[v.ID], v.Value)
	}

	out := make([]types.ScopeAssignmentView, 0, len(rows))
	for _, r := range rows {
		vals := valuesByID[r.ID]
		if vals == nil {
			vals = []string{}
		}
		out = append(out, assignmentToView(r.ID, r.IDCoreScopeDefinitions, r.IDCoreRoles, r.IDCoreUsers,
			repository.PgTextPtr(r.RoleName), repository.PgTextPtr(r.Username),
			r.IsActive, r.Note, len(vals), r.Version, vals))
	}
	return out, nil
}

// ScopeAssignmentUpsertInput — body POST assignments
// (scopeAssignmentUpsertSchema; XOR role_id/user_id divalidasi handler).
type ScopeAssignmentUpsertInput struct {
	DefinitionID int64
	RoleID       *int64
	UserID       *int64
	Note         *string
}

// CreateAssignment — buat pemberian whitelist (role ATAU user); duplikat
// pasangan hidup → 409 SYS-409.
func (s *IamDatascopeService) CreateAssignment(ctx context.Context, in ScopeAssignmentUpsertInput, actor audit.Actor) (*types.ScopeAssignmentView, error) {
	var view *types.ScopeAssignmentView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.ensureDefinitionExists(ctx, tx, in.DefinitionID); err != nil {
			return err
		}
		if in.RoleID != nil {
			if err := s.ensureRoleExists(ctx, tx, *in.RoleID); err != nil {
				return err
			}
		}
		if in.UserID != nil {
			if err := s.ensureUserExists(ctx, tx, *in.UserID); err != nil {
				return err
			}
		}

		dup, err := s.repo.FindAssignmentDuplicate(ctx, tx, in.DefinitionID, in.RoleID, in.UserID)
		if err != nil {
			return err
		}
		if dup {
			subject := fmt.Sprintf("user id %d", *in.UserID)
			if in.RoleID != nil {
				subject = fmt.Sprintf("role id %d", *in.RoleID)
			}
			return errkontrak.Conflict(fmt.Sprintf("Assignment untuk definisi id %d dan %s sudah ada.", in.DefinitionID, subject), "SYS-409")
		}

		inserted, err := s.repo.InsertAssignment(ctx, tx, repository.BuildInsertAssignmentParams(in.DefinitionID, in.RoleID, in.UserID, in.Note))
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_assignment",
			EntityID:   fmt.Sprintf("%d", inserted.ID),
			Action:     "create",
			AfterValue: audit.Snapshot{
				"definition_id": inserted.IDCoreScopeDefinitions,
				"role_id":       repository.Int8Ptr(inserted.IDCoreRoles),
				"user_id":       repository.Int8Ptr(inserted.IDCoreUsers),
				"is_active":     inserted.IsActive,
			},
		}, Actor: actor}}); err != nil {
			return err
		}

		v := assignmentToView(inserted.ID, inserted.IDCoreScopeDefinitions, inserted.IDCoreRoles, inserted.IDCoreUsers,
			nil, nil, inserted.IsActive, inserted.Note, 0, inserted.Version, []string{})
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// ScopeAssignmentUpdateInput — body PATCH assignments (semua opsional).
type ScopeAssignmentUpdateInput struct {
	IsActive FieldOpt
	Note     FieldOpt
}

// UpdateAssignment — ubah assignment (is_active/note); If-Match `version`.
func (s *IamDatascopeService) UpdateAssignment(ctx context.Context, id int64, in ScopeAssignmentUpdateInput, actor audit.Actor, expectedVersion *int64) (*types.ScopeAssignmentView, error) {
	var view *types.ScopeAssignmentView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindAssignmentById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Assignment id %d tidak ditemukan.", id), "SYS-404")
		}
		if err := iamEnsureVersion(row.Version, expectedVersion); err != nil {
			return err
		}

		patch := repository.AssignmentPatch{
			Version:   row.Version + 1,
			UpdatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
		}
		if in.IsActive.Present {
			patch.IsActive = &in.IsActive.Bool
		}
		if in.Note.Present {
			patch.Note = &in.Note.Str
		}

		updated, err := s.repo.UpdateAssignmentById(ctx, tx, id, patch)
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_assignment",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "update",
			BeforeValue: audit.Snapshot{
				"is_active": row.IsActive,
				"note":      row.Note,
				"version":   row.Version,
			},
			AfterValue: audit.Snapshot{
				"is_active": updated.IsActive,
				"note":      updated.Note,
				"version":   updated.Version,
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}

		values, err := s.repo.ListValuesOfAssignment(ctx, tx, id)
		if err != nil {
			return err
		}
		count, err := s.repo.CountValues(ctx, tx, id)
		if err != nil {
			return err
		}
		if values == nil {
			values = []string{}
		}
		v := assignmentToView(updated.ID, updated.IDCoreScopeDefinitions, updated.IDCoreRoles, updated.IDCoreUsers,
			nil, nil, updated.IsActive, updated.Note, count, updated.Version, values)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// DeleteAssignment — SOFT delete assignment (deleted_at = now); nilai anak
// tidak dihapus fisik (jejak tersisa).
func (s *IamDatascopeService) DeleteAssignment(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindAssignmentById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Assignment id %d tidak ditemukan.", id), "SYS-404")
		}

		now := pgtype.Timestamptz{Time: time.Now(), Valid: true}
		if err := s.repo.SoftDeleteAssignmentById(ctx, tx, id, now, now, row.Version+1); err != nil {
			return err
		}

		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_datascope_assignment",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "delete",
			BeforeValue: audit.Snapshot{
				"definition_id": row.IDCoreScopeDefinitions,
				"role_id":       repository.Int8Ptr(row.IDCoreRoles),
				"user_id":       repository.Int8Ptr(row.IDCoreUsers),
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}})
		return err
	})
}

// ScopeValuesSetInput — body PUT assignments/:id/values (scopeValuesSetSchema).
type ScopeValuesSetInput struct {
	AssignmentID int64
	Values       []string
}

// ScopeValuesSetResult — hasil REPLACE himpunan nilai.
type ScopeValuesSetResult struct {
	AssignmentID int64    `json:"assignment_id"`
	Values       []string `json:"values"`
}

// SetValues — REPLACE himpunan nilai whitelist satu assignment (SATU tx):
// hapus FISIK yang tak ada di payload + sisip yang baru (idempoten by
// unique pair). assignment_id body wajib sama dengan path.
func (s *IamDatascopeService) SetValues(ctx context.Context, id int64, in ScopeValuesSetInput, actor audit.Actor) (*ScopeValuesSetResult, error) {
	if in.AssignmentID != id {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
			Field:   "assignment_id",
			Message: fmt.Sprintf("assignment_id body (%d) harus sama dengan id di path (%d).", in.AssignmentID, id),
		}})
	}
	values := iamDedupeStr(in.Values)
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindAssignmentById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Assignment id %d tidak ditemukan.", id), "SYS-404")
		}

		before, err := s.repo.ListValuesBefore(ctx, tx, id)
		if err != nil {
			return err
		}

		// Bulk replace: hapus fisik yang tak ada di payload…
		if len(before) > 0 {
			keep := map[string]bool{}
			for _, v := range values {
				keep[v] = true
			}
			toDelete := []string{}
			for _, v := range before {
				if !keep[v] {
					toDelete = append(toDelete, v)
				}
			}
			if len(toDelete) > 0 {
				if err := s.repo.DeleteValues(ctx, tx, id, toDelete); err != nil {
					return err
				}
			}
		}
		// …lalu sisip yang belum ada (ON CONFLICT DO NOTHING — unique pair).
		if len(values) > 0 {
			if err := s.repo.InsertValues(ctx, tx, id, values); err != nil {
				return err
			}
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:   "system",
			EntityType:  "iam_datascope_values",
			EntityID:    fmt.Sprintf("%d", id),
			Action:      "set_values",
			BeforeValue: audit.Snapshot{"values": strSliceToAny(before)},
			AfterValue:  audit.Snapshot{"values": strSliceToAny(values)},
			Severity:    audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &ScopeValuesSetResult{AssignmentID: id, Values: values}, nil
}

// ====================================================================
// OPSI NILAI GENERIK
// ====================================================================

// ListOptions — baris tabel rujukan definisi (paging/search server, TANPA
// sort). Tabel tak ter-registry → 404 pesan verbatim SCOPE_TABLE_REGISTRIES.
func (s *IamDatascopeService) ListOptions(ctx context.Context, definitionID int64, pr *errkontrak.PageRequest, search *string) (*types.ScopeOptionsResult, error) {
	definition, err := s.repo.FindDefinitionTarget(ctx, s.db.Pool, definitionID)
	if err != nil {
		return nil, err
	}
	if definition == nil {
		return nil, errkontrak.NotFound(fmt.Sprintf("Definisi scope id %d tidak ditemukan.", definitionID), "SYS-404")
	}

	result, err := s.repo.ListOptions(ctx, s.db.Pool, definition.TargetTable, definition.TargetField, pr, search)
	if err != nil {
		return nil, err
	}
	if result == nil {
		return nil, errkontrak.NotFound(fmt.Sprintf("Tabel opsi untuk '%s.%s' belum ter-registry di mirror drizzle — daftarkan schema modulnya di SCOPE_TABLE_REGISTRIES.", definition.TargetTable, definition.TargetField), "SYS-404")
	}
	return result, nil
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// iamEnsureVersion — 412 SYS-412 bila If-Match diberikan dan version tidak cocok.
func iamEnsureVersion(current int64, expected *int64) error {
	if expected != nil && *expected != current {
		return &errkontrak.DomainError{
			Code:   "SYS-412",
			Status: 412,
			Detail: fmt.Sprintf("Resource sudah diubah pihak lain — If-Match (%d) ≠ version terkini (%d).", *expected, current),
		}
	}
	return nil
}

// resolveModuleIdByKey — id modul by key (default 'system' definisi baru).
func (s *IamDatascopeService) resolveModuleIdByKey(ctx context.Context, key string) (*int64, error) {
	id, err := s.repo.FindModuleIdByKey(ctx, s.db.Pool, key)
	if err != nil {
		return nil, err
	}
	if id == nil {
		return nil, errkontrak.NotFound(fmt.Sprintf("Modul '%s' tidak ditemukan.", key), "SYS-404")
	}
	return id, nil
}

// ensureModuleExists — 404 `Modul id ${id} tidak ditemukan.`
func (s *IamDatascopeService) ensureModuleExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindModuleIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("Modul id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// ensureDefinitionExists — 404 `Definisi scope id ${id} tidak ditemukan.`
func (s *IamDatascopeService) ensureDefinitionExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindDefinitionIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("Definisi scope id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// ensureRoleExists — 404 `Role id ${id} tidak ditemukan.`
func (s *IamDatascopeService) ensureRoleExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindRoleIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// ensureUserExists — 404 `User id ${id} tidak ditemukan.`
func (s *IamDatascopeService) ensureUserExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindUserIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("User id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// definitionToView — baris definisi → view (scopeDefinitionViewSchema).

// assignmentToView — rakit view assignment (bentuk persis sumber — dipakai
// list, create, update; create mengirim values kosong & roleName/username null).
func assignmentToView(id, definitionID int64, roleID, userID pgtype.Int8,
	roleName, username *string, isActive bool, note string,
	valueCount int, version int64, values []string) types.ScopeAssignmentView {
	return types.ScopeAssignmentView{
		ID:           id,
		DefinitionID: definitionID,
		RoleID:       repository.Int8Ptr(roleID),
		UserID:       repository.Int8Ptr(userID),
		RoleName:     roleName,
		Username:     username,
		IsActive:     isActive,
		Note:         note,
		ValueCount:   valueCount,
		Version:      version,
		Values:       values,
	}
}

// genInsertDefinitionValues — rakit nilai insert definisi.

// genInsertAssignmentValues — rakit nilai insert assignment.

// iamDedupeStr — padanan [...new Set(values)] (urut kemunculan pertama).
func iamDedupeStr(values []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values))
	for _, v := range values {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// strSliceToAny — []string → []any (snapshot jsonb).
func strSliceToAny(vs []string) []any {
	out := make([]any, len(vs))
	for i, v := range vs {
		out[i] = v
	}
	return out
}
