// repository.go — SATU-SATUNYA pengguna sqlc untuk tabel core_module_configs
// (padanan ModuleConfigRepository NestJS). Upsert by natural key
// (id_core_modules, param_key); insert ON CONFLICT DO NOTHING (baris baru
// version 0); update kondisional `version = expected` (optimistic locking)
// + version = version + 1; hapus override = HARD delete (tanpa deleted_at).
package moduleconfig

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/moduleconfig/repository/gen"
)

// DBTX — executor (pool | tx) agar config masuk transaksi bisnis pemanggil.
type DBTX = gen.DBTX

// ConfigRow — baris config yang dibutuhkan service (subset kolom).
type ConfigRow struct {
	ID         int64
	ParamValue string
	ValueType  string
	Version    int64
}

// Repository — wrapper sqlc area moduleconfig.
type Repository struct{}

// NewRepository membuat repository (tanpa state — executor per panggilan).
func NewRepository() *Repository { return &Repository{} }

// FindRowByKey — baris config by natural key (moduleId sudah FK numerik);
// found=false bila belum ada.
func (r *Repository) FindRowByKey(ctx context.Context, exec DBTX, moduleID int64, paramKey string) (ConfigRow, bool, error) {
	rows, err := gen.New(exec).FindRowByKey(ctx, gen.FindRowByKeyParams{
		IDCoreModules: moduleID,
		ParamKey:      paramKey,
	})
	if err != nil {
		return ConfigRow{}, false, err
	}
	if len(rows) == 0 {
		return ConfigRow{}, false, nil
	}
	row := rows[0]
	return ConfigRow{
		ID:         row.ID,
		ParamValue: row.ParamValue,
		ValueType:  string(row.ValueType),
		Version:    row.Version,
	}, true, nil
}

// InsertIgnoreConflict — insert baris baru; false bila natural key sudah
// diperebutkan penulis lain (ON CONFLICT DO NOTHING).
func (r *Repository) InsertIgnoreConflict(ctx context.Context, exec DBTX, moduleID int64, paramKey, raw, valueType string, actorID *int64) (bool, error) {
	rows, err := gen.New(exec).InsertIgnoreConflict(ctx, gen.InsertIgnoreConflictParams{
		IDCoreModules: moduleID,
		ParamKey:      paramKey,
		ParamValue:    raw,
		ValueType:     gen.CoreConfigValueType(valueType),
		UpdatedBy:     int8Ptr(actorID),
	})
	if err != nil {
		return false, err
	}
	return len(rows) > 0, nil
}

// UpdateConditional — update kondisional (optimistic locking) dalam SATU
// statement: version = version + 1 + catat actor & updated_at. expectedVersion
// nil → tanpa syarat versi (last-write-wins). Mengembalikan (version baru,
// kena/tidak).
func (r *Repository) UpdateConditional(ctx context.Context, exec DBTX, moduleID int64, paramKey, raw, valueType string, actorID, expectedVersion *int64) (int64, bool, error) {
	rows, err := gen.New(exec).UpdateConditional(ctx, gen.UpdateConditionalParams{
		IDCoreModules:   moduleID,
		ParamKey:        paramKey,
		ParamValue:      raw,
		ValueType:       gen.CoreConfigValueType(valueType),
		UpdatedBy:       int8Ptr(actorID),
		ExpectedVersion: int8Ptr(expectedVersion),
	})
	if err != nil {
		return 0, false, err
	}
	if len(rows) == 0 {
		return 0, false, nil
	}
	return rows[0], true, nil
}

// DeleteHard — hapus baris param (idempoten); true bila ada yang terhapus.
func (r *Repository) DeleteHard(ctx context.Context, exec DBTX, moduleID int64, paramKey string) (bool, error) {
	rows, err := gen.New(exec).DeleteHard(ctx, gen.DeleteHardParams{
		IDCoreModules: moduleID,
		ParamKey:      paramKey,
	})
	if err != nil {
		return false, err
	}
	return len(rows) > 0, nil
}

// FindModuleIdByKey — FK numerik modul by natural key; nil bila modul tidak
// terdaftar (penilaian error ada di service).
func (r *Repository) FindModuleIdByKey(ctx context.Context, exec DBTX, moduleKey string) (*int64, error) {
	rows, err := gen.New(exec).FindModuleIdByKey(ctx, gen.CoreModuleKey(moduleKey))
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	id := rows[0]
	return &id, nil
}

// int8Ptr — *int64 → pgtype.Int8 (nil → NULL).
func int8Ptr(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}
