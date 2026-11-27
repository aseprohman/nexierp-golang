// agama.go — fitur AGAMA modul core — padanan AgamaRepository NestJS
// (kosakata agama resmi, ddl/72-core-agama): master core_agama — pola persis
// cluster minus junction (list/paging, cari hidup, cari hidup by code,
// insert, patch ber-version, soft delete TANPA bump).
package repository

import (
	"context"
	"time"

	"nexierp/internal/core/audit"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// AgamaRepository — master core_agama.
type AgamaRepository struct{}

// NewAgamaRepository membuat repository agama.
func NewAgamaRepository() *AgamaRepository { return &AgamaRepository{} }

// AgamaListQuery — kriteria list agama (service yang memutuskan).
type AgamaListQuery struct {
	Search   *string // SUDAH di-trim service
	Status   *string
	SortCol  string
	SortDesc bool
	Limit    int32
	Offset   int32
}

// AgamaToView — mapper baris core_agama → view (waktu ISO-8601).
func AgamaToView(row gen.CoreAgama) types.CoreAgamaView {
	return types.CoreAgamaView{
		ID:        row.ID,
		EntityID:  row.EntityID.String(),
		Code:      row.Code,
		Nama:      row.Nama,
		Urutan:    row.Urutan,
		Status:    string(row.Status),
		Version:   row.Version,
		CreatedAt: isoZ(row.CreatedAt.Time),
		UpdatedAt: isoZ(row.UpdatedAt.Time),
	}
}

// SnapshotAgama — ringkasan agama utk audit before/after (verbatim
// snapshotAgama NestJS).
func SnapshotAgama(row gen.CoreAgama) audit.Snapshot {
	return audit.Snapshot{
		"code":    row.Code,
		"nama":    row.Nama,
		"urutan":  row.Urutan,
		"status":  string(row.Status),
		"version": row.Version,
	}
}

// ListAgama — halaman agama hidup + total.
func (r *AgamaRepository) ListAgama(ctx context.Context, exec gen.DBTX, q AgamaListQuery) ([]types.CoreAgamaView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListAgama(ctx, gen.ListAgamaParams{
		Search:   teksNihil(q.Search),
		Status:   teksNihil(q.Status),
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountAgama(ctx, gen.CountAgamaParams{
		Search: teksNihil(q.Search),
		Status: teksNihil(q.Status),
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.CoreAgamaView, 0, len(rows))
	for _, row := range rows {
		out = append(out, AgamaToView(row))
	}
	return out, total, nil
}

// CariAgamaHidup — baris hidup by id — nil bila tidak ada / terhapus.
func (r *AgamaRepository) CariAgamaHidup(ctx context.Context, exec gen.DBTX, id int64) (*gen.CoreAgama, error) {
	rows, err := gen.New(exec).CariAgamaHidup(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// CariHidupByKode — id agama hidup lain berkode sama (pre-check dup code).
func (r *AgamaRepository) CariHidupByKode(ctx context.Context, exec gen.DBTX, code string) (*int64, error) {
	rows, err := gen.New(exec).CariAgamaHidupByKode(ctx, code)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// InsertAgama — insert agama baru (version 1; race 23505 mentah).
func (r *AgamaRepository) InsertAgama(ctx context.Context, exec gen.DBTX, code, nama string, urutan int32, status string) (gen.CoreAgama, error) {
	return gen.New(exec).InsertAgama(ctx, gen.InsertAgamaParams{
		Code:    code,
		Nama:    nama,
		Urutan:  urutan,
		Status:  gen.EnumStatusAktif(status),
		Version: 1,
	})
}

// AgamaUbahSet — nilai kolom dibangun service.
type AgamaUbahSet struct {
	ID          int64
	VersiServer int32
	Code        string
	Nama        string
	Urutan      int32
	Status      string
	Version     int32
	UpdatedAt   time.Time
}

// UpdateBerVersion — patch ber-version; nil = race version.
func (r *AgamaRepository) UpdateBerVersion(ctx context.Context, exec gen.DBTX, s AgamaUbahSet) (*gen.CoreAgama, error) {
	rows, err := gen.New(exec).UpdateAgamaBerVersion(ctx, gen.UpdateAgamaBerVersionParams{
		Code:        s.Code,
		Nama:        s.Nama,
		Urutan:      s.Urutan,
		Status:      gen.EnumStatusAktif(s.Status),
		Version:     s.Version,
		UpdatedAt:   waktu(s.UpdatedAt),
		ID:          s.ID,
		VersiServer: s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDelete — set deleted_at saja (JANGAN hard delete; TANPA version bump).
// FK RESTRICT (23503) dari ppdb_pendaftaran/akd_siswa dilempar mentah.
func (r *AgamaRepository) SoftDelete(ctx context.Context, exec gen.DBTX, id int64, now time.Time) error {
	return gen.New(exec).SoftDeleteAgama(ctx, gen.SoftDeleteAgamaParams{
		DeletedAt: waktu(now),
		UpdatedAt: waktu(now),
		ID:        id,
	})
}
