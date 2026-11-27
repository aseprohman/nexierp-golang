// repository/iam_features.go — SATU-SATUNYA pengguna area sqlc FEATURES
// (fitur per modul `core_modules_features` — padanan FeaturesRepository
// NestJS). Siklus aktif fitur: aktor + cap waktu dibangun service.
package repository

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// FeaturesRepo — wrapper sqlc area features.
type FeaturesRepo struct{}

// NewFeaturesRepo membuat repository features.
func NewFeaturesRepo() *FeaturesRepo { return &FeaturesRepo{} }

// ListJoined — seluruh fitur + key modul (urut key modul lalu folder).
func (r *FeaturesRepo) ListJoined(ctx context.Context, exec DBTX) ([]gen.ListFeaturesJoinedRow, error) {
	return gen.New(exec).ListFeaturesJoined(ctx)
}

// FindJoinedById — fitur by id + key modul (baris join PENUH); null bila absen.
func (r *FeaturesRepo) FindJoinedById(ctx context.Context, exec DBTX, id int64) (*gen.FindFeatureJoinedByIdRow, error) {
	row, err := gen.New(exec).FindFeatureJoinedById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FeaturePatch — set UPDATE siklus aktif (dibangun service): branch activate
// men-set aktor+active_until & membersihkan deactivated_from, dst.
type FeaturePatch struct {
	IsActive               bool
	IDCoreUsersActivated   pgtype.Int8
	ActiveUntil            pgtype.Timestamptz
	IDCoreUsersDeactivated pgtype.Int8
	DeactivatedFrom        pgtype.Timestamptz
	UpdatedAt              pgtype.Timestamptz
}

// UpdateById — update fitur by id → baris terbaru.
func (r *FeaturesRepo) UpdateById(ctx context.Context, exec DBTX, id int64, p FeaturePatch) (*gen.CoreModulesFeature, error) {
	row, err := gen.New(exec).UpdateFeatureById(ctx, gen.UpdateFeatureByIdParams{
		ID:                     id,
		IsActive:               p.IsActive,
		IDCoreUsersActivated:   p.IDCoreUsersActivated,
		ActiveUntil:            p.ActiveUntil,
		IDCoreUsersDeactivated: p.IDCoreUsersDeactivated,
		DeactivatedFrom:        p.DeactivatedFrom,
		UpdatedAt:              p.UpdatedAt,
	})
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FeatureToView — baris fitur + moduleKey → ModuleFeatureView
// (moduleFeatureViewSchema; is_system NULL → false).
func FeatureToView(id int64, moduleKey string, featuresFolder string, isActive bool, isSystem pgtype.Bool) types.ModuleFeatureView {
	return types.ModuleFeatureView{
		ID:             id,
		ModuleKey:      moduleKey,
		FeaturesFolder: featuresFolder,
		IsActive:       isActive,
		IsSystem:       isSystem.Valid && isSystem.Bool,
	}
}
