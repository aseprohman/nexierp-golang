// service/iam_permissions.go — katalog SET permission `core_permissions`
// + junction SET↔route (padanan IamPermissionsService NestJS). Nama unik
// per modul (duplikat → 409 SYS-409); DELETE menolak SET yang masih
// disandang role ATAU masih punya route (409); invalidasi registry tidak
// relevan di sini (junction dibaca compiler via SQL, bukan cache registry).
package service

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// CreatePermissionInput — body POST (createPermissionSchema; hadir = field
// dikirim). Description/modul/fitur opsional.
type CreatePermissionInput struct {
	Name           string
	Description    *string // nil = tidak dikirim → NULL
	ModuleKey      *string
	FeaturesFolder *string
}

// UpdatePermissionInput — body PATCH (updatePermissionSchema; null = bersihkan
// kolom): hadir-nya field dibedakan dari nilainya (Has* + *nilai).
type UpdatePermissionInput struct {
	HasName        bool
	Name           *string // null → HasName=true, Name=nil
	HasDescription bool
	Description    *string
	HasStatus      bool
	Status         string
	HasModuleKey   bool
	ModuleKey      *string // null → HasModuleKey=true, ModuleKey=nil
	HasFeatures    bool
	FeaturesFolder *string // null → HasFeatures=true, FeaturesFolder=nil
}

// List — halaman SET permission (filter module/status; default name asc).
func (s *IamPermissionsService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.PermissionView], error) {
	data, total, err := s.repo.List(ctx, s.db.Pool, pr)
	if err != nil {
		return errkontrak.Page[types.PermissionView]{}, err
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Create — tambah SET permission (nama unik per modul; moduleKey unknown →
// 404 SYS-404; featuresFolder divalidasi bila dibawa). SET baru TANPA route
// (diisi via PUT /:id/routes).
func (s *IamPermissionsService) Create(ctx context.Context, in CreatePermissionInput, actor audit.Actor) (*types.PermissionView, error) {
	var view *types.PermissionView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		ids, err := s.resolveModuleRefs(ctx, tx, in.ModuleKey, in.FeaturesFolder)
		if err != nil {
			return err
		}
		dupe, err := s.repo.FindDuplicateByName(ctx, tx, in.Name, ids.ModuleID)
		if err != nil {
			return err
		}
		if dupe {
			return errkontrak.Conflict(fmt.Sprintf("Nama SET '%s' sudah dipakai pada modul tsb.", in.Name), "SYS-409")
		}
		inserted, err := s.repo.Insert(ctx, tx, repository.InsertPermissionValues(
			in.Name, in.Description, ids.ModuleID, ids.FeatureID))
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_permission",
			EntityID:   fmt.Sprintf("%d", inserted.ID),
			Action:     "create",
			AfterValue: audit.Snapshot{"name": repository.PgTextPtr(inserted.Name)},
		},
			Actor: actor}}); err != nil {
			return err
		}
		v := repository.PermissionToView(inserted, in.ModuleKey, 0)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Update — ubah SET permission (name/description/status/module/feature;
// null = bersihkan; ganti moduleKey membuang fitur lama — persis sumber).
func (s *IamPermissionsService) Update(ctx context.Context, id int64, in UpdatePermissionInput, actor audit.Actor) (*types.PermissionView, error) {
	var view *types.PermissionView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("SET permission id %d tidak ditemukan.", id), "SYS-404")
		}

		patch := repository.PermissionPatch{UpdatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true}}
		if in.HasName {
			patch.Name = &pgtype.Text{String: iamDerefStr(in.Name), Valid: in.Name != nil}
		}
		if in.HasDescription {
			patch.Description = &pgtype.Text{String: iamDerefStr(in.Description), Valid: in.Description != nil}
		}
		if in.HasStatus {
			st := repository.StatusOf(in.Status)
			patch.Status = &st
		}

		// module/featuresFolder: ganti modul dan/atau fitur pemilik SET.
		if in.HasModuleKey {
			ids, err := s.resolveModuleRefs(ctx, tx, in.ModuleKey, nil)
			if err != nil {
				return err
			}
			patch.ModuleID = iamInt8Field(ids.ModuleID)
			patch.FeatureID = iamNullInt8() // ganti modul → fitur lama tidak relevan
		}
		if in.HasFeatures {
			var ownerModule *string
			var err error
			if in.HasModuleKey {
				ownerModule = in.ModuleKey
			} else if row.IDCoreModules.Valid {
				id := row.IDCoreModules.Int64
				ownerModule, err = s.repo.FindModuleKeyById(ctx, tx, &id)
				if err != nil {
					return err
				}
			}
			folder := in.FeaturesFolder
			ids, err := s.resolveModuleRefs(ctx, tx, ownerModule, folder)
			if err != nil {
				return err
			}
			if in.FeaturesFolder == nil {
				patch.FeatureID = iamNullInt8()
			} else {
				if ids.ModuleID == nil || ids.FeatureID == nil {
					return errkontrak.NotFound(fmt.Sprintf("Fitur '%s' tidak ditemukan pada modul.", iamDerefStr(in.FeaturesFolder)), "SYS-404")
				}
				patch.ModuleID = iamInt8Field(ids.ModuleID)
				patch.FeatureID = iamInt8Field(ids.FeatureID)
			}
		}

		updated, err := s.repo.Update(ctx, tx, id, patch)
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_permission",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "update",
			BeforeValue: audit.Snapshot{
				"name":   repository.PgTextPtr(row.Name),
				"status": string(row.Status),
			},
			AfterValue: audit.Snapshot{
				"name":   repository.PgTextPtr(updated.Name),
				"status": string(updated.Status),
			},
			Severity: audit.SeverityWarning,
		},
			Actor: actor}}); err != nil {
			return err
		}

		routeCount, err := s.repo.CountRoutesByPermission(ctx, tx, id)
		if err != nil {
			return err
		}
		var moduleKey *string
		if updated.IDCoreModules.Valid {
			moduleKey, err = s.repo.FindModuleKeyById(ctx, tx, &updated.IDCoreModules.Int64)
			if err != nil {
				return err
			}
		}
		v := repository.PermissionToView(updated, moduleKey, routeCount)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Remove — hapus SET permission fisik; 409 SYS-409 bila dipakai role atau
// masih punya route (pesan verbatim; nama null → fallback String(id)).
func (s *IamPermissionsService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("SET permission id %d tidak ditemukan.", id), "SYS-404")
		}

		roleUse, err := s.repo.FindRoleUse(ctx, tx, id)
		if err != nil {
			return err
		}
		if roleUse {
			return errkontrak.Conflict(fmt.Sprintf("SET '%s' masih disandang role — cabut dulu (PUT /system/roles/:id/permissions).", iamNamaAtauID(row.Name, id)), "SYS-409")
		}
		routeUse, err := s.repo.FindRouteUse(ctx, tx, id)
		if err != nil {
			return err
		}
		if routeUse {
			return errkontrak.Conflict(fmt.Sprintf("SET '%s' masih terhubung route — lepas dulu (PUT /system/permissions/:id/routes).", iamNamaAtauID(row.Name, id)), "SYS-409")
		}

		if err := s.repo.DeleteById(ctx, tx, id); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_permission",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     "delete",
			BeforeValue: audit.Snapshot{
				"name":   repository.PgTextPtr(row.Name),
				"status": string(row.Status),
			},
			Severity: audit.SeverityWarning,
		},
			Actor: actor}})
		return err
	})
}

// AssignRoutesInput — body PUT /:id/routes (assignRoutesSchema).
type AssignRoutesInput struct {
	RouteIds []int64
}

// AssignRoutesResult — hasil REPLACE junction.
type AssignRoutesResult struct {
	RouteIds []int64 `json:"routeIds"`
}

// AssignRoutes — REPLACE junction SET↔route (dedupe; route wajib ada →
// 404 `Route tidak ditemukan: ${missing}.`; array kosong = lepas semua).
func (s *IamPermissionsService) AssignRoutes(ctx context.Context, id int64, in AssignRoutesInput, actor audit.Actor) (*AssignRoutesResult, error) {
	var result *AssignRoutesResult
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		perm, err := s.repo.FindById(ctx, tx, id)
		if err != nil {
			return err
		}
		if perm == nil {
			return errkontrak.NotFound(fmt.Sprintf("SET permission id %d tidak ditemukan.", id), "SYS-404")
		}

		before, err := s.repo.ListRouteIds(ctx, tx, id)
		if err != nil {
			return err
		}

		uniqueIds := iamDedupeInt64(in.RouteIds)
		if len(uniqueIds) > 0 {
			found, err := s.repo.FindExistingRouteIds(ctx, tx, uniqueIds)
			if err != nil {
				return err
			}
			if len(found) != len(uniqueIds) {
				foundSet := map[int64]bool{}
				for _, f := range found {
					foundSet[f] = true
				}
				missing := []int64{}
				for _, rid := range uniqueIds {
					if !foundSet[rid] {
						missing = append(missing, rid)
					}
				}
				return errkontrak.NotFound(fmt.Sprintf("Route tidak ditemukan: %s.", iamJoinInt64(missing)), "SYS-404")
			}
		}

		// REPLACE: hapus junction lama, tulis yang baru (unik pair — idempoten).
		if err := s.repo.DeleteRoutesByPermission(ctx, tx, id); err != nil {
			return err
		}
		for _, rid := range uniqueIds {
			if err := s.repo.InsertPermissionRoute(ctx, tx, rid, id); err != nil {
				return err
			}
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_permission",
			EntityID:   iamNamaAtauID(perm.Name, id),
			Action:     "assign_routes",
			BeforeValue: audit.Snapshot{
				"route_ids": iamInt64sToAny(before),
			},
			AfterValue: audit.Snapshot{
				"route_ids": iamInt64sToAny(uniqueIds),
			},
			Severity: audit.SeverityWarning,
		},
			Actor: actor}}); err != nil {
			return err
		}
		result = &AssignRoutesResult{RouteIds: uniqueIds}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// FindRouteIds — id route ter-junction ke SET (sorted numeric asc);
// 404 SYS-404 bila SET tidak ada / sudah terhapus.
func (s *IamPermissionsService) FindRouteIds(ctx context.Context, id int64) ([]int64, error) {
	ok, err := s.repo.FindIdById(ctx, s.db.Pool, id)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errkontrak.NotFound(fmt.Sprintf("SET permission id %d tidak ditemukan.", id), "SYS-404")
	}
	rows, err := s.repo.ListRouteIds(ctx, s.db.Pool, id)
	if err != nil {
		return nil, err
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i] < rows[j] })
	return rows, nil
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// moduleRefs — hasil resolve moduleKey/featuresFolder → FK.
type moduleRefs struct {
	ModuleID  *int64
	FeatureID *int64
}

// resolveModuleRefs — padanan resolveModuleRefs: null bila tidak dibawa;
// featuresFolder tanpa moduleKey → 400; fitur/modul tak dikenal → 404.
func (s *IamPermissionsService) resolveModuleRefs(ctx context.Context, exec repository.DBTX, moduleKey, featuresFolder *string) (moduleRefs, error) {
	var out moduleRefs
	if moduleKey != nil {
		id, err := s.repo.FindModuleIdByKey(ctx, exec, *moduleKey)
		if err != nil {
			return out, err
		}
		if id == nil {
			return out, errkontrak.NotFound(fmt.Sprintf("Modul '%s' tidak ditemukan.", *moduleKey), "SYS-404")
		}
		out.ModuleID = id
	}
	if featuresFolder != nil && *featuresFolder != "" {
		if out.ModuleID == nil {
			return out, errkontrak.Validation([]errkontrak.FieldIssue{{
				Field:   "featuresFolder",
				Message: "featuresFolder wajib disertai moduleKey.",
			}})
		}
		feat, err := s.repo.FindFeatureIdByModuleAndFolder(ctx, exec, *out.ModuleID, *featuresFolder)
		if err != nil {
			return out, err
		}
		if feat == nil {
			return out, errkontrak.NotFound(fmt.Sprintf("Fitur '%s' tidak ditemukan pada modul.", *featuresFolder), "SYS-404")
		}
		out.FeatureID = feat
	}
	return out, nil
}

// int8Field — *int64 → *pgtype.Int8 (nilai patch update).
func iamInt8Field(v *int64) *pgtype.Int8 {
	x := repository.Int8Of(v)
	return &x
}

// nullInt8 — pointer ke pgtype.Int8 NULL (SET NULL patch).
func iamNullInt8() *pgtype.Int8 {
	x := pgtype.Int8{}
	return &x
}

func iamDerefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// namaAtauID — `${row.name ?? id}` (nama NULL → String(id)).
func iamNamaAtauID(name pgtype.Text, id int64) string {
	if name.Valid && name.String != "" {
		return name.String
	}
	return fmt.Sprintf("%d", id)
}

// dedupeInt64 — padanan [...new Set(ids)]: urut kemunculan pertama dipertahankan.
func iamDedupeInt64(ids []int64) []int64 {
	seen := map[int64]bool{}
	out := make([]int64, 0, len(ids))
	for _, v := range ids {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// joinInt64 — padanan `${missing.join(", ")}`.
func iamJoinInt64(ids []int64) string {
	out := ""
	for i, v := range ids {
		if i > 0 {
			out += ", "
		}
		out += fmt.Sprintf("%d", v)
	}
	return out
}

// int64sToAny — []int64 → []any (snapshot jsonb).
func iamInt64sToAny(ids []int64) []any {
	out := make([]any, len(ids))
	for i, v := range ids {
		out[i] = v
	}
	return out
}
