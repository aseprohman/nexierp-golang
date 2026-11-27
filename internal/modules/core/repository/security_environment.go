// security_environment.go — SATU-SATUNYA pengguna sqlc fitur ENVIRONMENT
// modul core (padanan repositories/security/environment.repository.ts;
// tabel core_app_settings + core_meta). Kategori konfigurasi = baris
// core_app_settings (PK natural key enum core_env_category); logo =
// core_meta.id="company_logo" (upsert).
package repository

import (
	"context"
	"encoding/json"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// KategoriRow — satu baris kategori konfigurasi (payload jsonb apa adanya).
type KategoriRow struct {
	Category string
	Fields   json.RawMessage
}

// MetaRow — satu baris core_meta (value jsonb apa adanya).
type MetaRow struct {
	ID    string
	Value json.RawMessage
}

// EnvironmentRepository — wrapper sqlc area environment.
type EnvironmentRepository struct{}

// NewEnvironmentRepository membuat repository (tanpa state).
func NewEnvironmentRepository() *EnvironmentRepository { return &EnvironmentRepository{} }

// ListKategori — seluruh baris kategori konfigurasi (urut kanonik di
// service: company, smtp, app, storage).
func (r *EnvironmentRepository) ListKategori(ctx context.Context, exec DBTX) ([]types.EnvCategoryData, error) {
	rows, err := gen.New(exec).ListKategori(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]types.EnvCategoryData, len(rows))
	for i, row := range rows {
		out[i] = types.EnvCategoryData{
			Category: string(row.ID),
			Fields:   json.RawMessage(row.Fields),
		}
	}
	return out, nil
}

// MuatKategori — satu kategori by natural key; nil bila absen (404
// diputuskan service).
func (r *EnvironmentRepository) MuatKategori(ctx context.Context, exec DBTX, category string) (*KategoriRow, error) {
	row, err := gen.New(exec).MuatKategori(ctx, gen.CoreEnvCategory(category))
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &KategoriRow{Category: string(row.ID), Fields: json.RawMessage(row.Fields)}, nil
}

// MuatMeta — satu baris meta by key (mis. "company_logo"); nil bila absen.
func (r *EnvironmentRepository) MuatMeta(ctx context.Context, exec DBTX, id string) (*MetaRow, error) {
	row, err := gen.New(exec).MuatMeta(ctx, id)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &MetaRow{ID: row.ID, Value: json.RawMessage(row.Value)}, nil
}

// UpdateFieldsKategori — update kolom jsonb `fields` satu kategori
// (payload dibangun service; updated_at tidak disentuh — persis drizzle).
func (r *EnvironmentRepository) UpdateFieldsKategori(ctx context.Context, exec DBTX, category string, fields json.RawMessage) error {
	return gen.New(exec).UpdateFieldsKategori(ctx, gen.UpdateFieldsKategoriParams{
		ID:     gen.CoreEnvCategory(category),
		Fields: []byte(fields),
	})
}

// UpsertMeta — upsert meta by PK natural key (hanya kolom value yang
// berubah — key tidak berubah).
func (r *EnvironmentRepository) UpsertMeta(ctx context.Context, exec DBTX, id string, value json.RawMessage) error {
	return gen.New(exec).UpsertMeta(ctx, gen.UpsertMetaParams{
		ID:    id,
		Value: []byte(value),
	})
}
