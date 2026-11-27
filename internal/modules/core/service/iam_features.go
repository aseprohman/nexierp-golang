// service/iam_features.go — fitur per modul (`core_modules_features`,
// padanan IamFeaturesService NestJS). PATCH /:id mengubah is_active +
// mencatat aktor siklus: aktifkan → id_core_users_activated + active_until;
// nonaktifkan → id_core_users_deactivated + deactivated_from. Status sama →
// no-op TANPA audit (idempoten).
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

// List — daftar fitur (view moduleFeatureViewSchema) + filter `module` /
// `moduleKey` (key) — penyaringan in-memory HASIL join, persis sumber.
func (s *IamFeaturesService) List(ctx context.Context, moduleFilter string) ([]types.ModuleFeatureView, error) {
	rows, err := s.repo.ListJoined(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	out := []types.ModuleFeatureView{}
	for _, r := range rows {
		if moduleFilter != "" && string(r.ModuleKey) != moduleFilter {
			continue
		}
		out = append(out, repository.FeatureToView(r.ID, string(r.ModuleKey), r.FeaturesFolder, r.IsActive, r.IsSystem))
	}
	return out, nil
}

// SetActive — aktifkan/nonaktifkan fitur (siklus aktif tercatat dengan
// aktor). Audit `iam_feature` severity warning; kolom yang tidak disentuh
// patch sumber dipertahankan nilainya.
func (s *IamFeaturesService) SetActive(ctx context.Context, id int64, isActive bool, actor audit.Actor) (*types.ModuleFeatureView, error) {
	var view *types.ModuleFeatureView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindJoinedById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Fitur id %d tidak ditemukan.", id), "SYS-404")
		}
		if row.IsActive == isActive {
			// Status sama → no-op tanpa audit (idempoten).
			v := repository.FeatureToView(row.ID, string(row.ModuleKey), row.FeaturesFolder, row.IsActive, row.IsSystem)
			view = &v
			return nil
		}

		now := pgtype.Timestamptz{Time: time.Now(), Valid: true}
		patch := repository.FeaturePatch{UpdatedAt: now}
		if isActive {
			patch.IsActive = true
			patch.IDCoreUsersActivated = repository.Int8Of(actor.IDCoreUsers)
			patch.ActiveUntil = now
			patch.DeactivatedFrom = pgtype.Timestamptz{} // dibersihkan
			// kolom yang tidak disentuh patch sumber → pertahankan.
			patch.IDCoreUsersDeactivated = row.IDCoreUsersDeactivated
		} else {
			patch.IsActive = false
			patch.IDCoreUsersDeactivated = repository.Int8Of(actor.IDCoreUsers)
			patch.DeactivatedFrom = now
			patch.IDCoreUsersActivated = row.IDCoreUsersActivated
			patch.ActiveUntil = row.ActiveUntil
		}

		updated, err := s.repo.UpdateById(ctx, tx, id, patch)
		if err != nil {
			return err
		}

		action := "deactivate"
		if isActive {
			action = "activate"
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_feature",
			EntityID:   fmt.Sprintf("%d", id),
			Action:     action,
			BeforeValue: audit.Snapshot{
				"is_active": row.IsActive,
			},
			AfterValue: audit.Snapshot{
				"is_active":       isActive,
				"module":          string(row.ModuleKey),
				"features_folder": updated.FeaturesFolder,
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}

		v := repository.FeatureToView(updated.ID, string(row.ModuleKey), updated.FeaturesFolder, updated.IsActive, updated.IsSystem)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}
