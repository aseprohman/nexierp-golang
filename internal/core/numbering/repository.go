// repository.go — SATU-SATUNYA pengguna sqlc untuk area numbering
// (padanan NumberingRepository NestJS — raw SQL VERBATIM dari service lama).
package numbering

import (
	"context"

	"nexierp/internal/core/numbering/repository/gen"
)

// DBTX — executor (pool | tx) agar alokasi nomor masuk transaksi bisnis
// pemanggil (nomor ikut commit/rollback bersama dokumennya).
type DBTX = gen.DBTX

// SequenceRow — satu baris hasil `UPDATE core_sequences … RETURNING`.
type SequenceRow struct {
	CurrentValue int64
	Prefix       string
	Padding      int
}

// Repository — wrapper sqlc area numbering.
type Repository struct{}

// NewRepository membuat repository (tanpa state — executor per panggilan).
func NewRepository() *Repository { return &Repository{} }

// IncrementSequence — UPDATE current_value+1 (VERBATIM). nil bila alokasi
// 0 baris (baris counter belum ada — service memutuskan seed + eksekusi ulang
// dalam STATEMENT BARU agar snapshot segar; CTE dilarang).
func (r *Repository) IncrementSequence(ctx context.Context, exec DBTX, moduleKey, docName string) (*SequenceRow, error) {
	rows, err := gen.New(exec).IncrementSequence(ctx, gen.IncrementSequenceParams{
		Key:     gen.CoreModuleKey(moduleKey),
		DocName: docName,
	})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	row := rows[0]
	return &SequenceRow{
		CurrentValue: row.CurrentValue,
		Prefix:       row.Prefix,
		Padding:      int(row.Padding),
	}, nil
}

// SeedSequence — seed baris counter (idempoten): INSERT-if-missing
// ON CONFLICT (id_core_modules, doc_name) DO NOTHING (VERBATIM).
func (r *Repository) SeedSequence(ctx context.Context, exec DBTX, moduleKey, docName, prefix string, padding int) error {
	return gen.New(exec).SeedSequence(ctx, gen.SeedSequenceParams{
		Key:     gen.CoreModuleKey(moduleKey),
		DocName: docName,
		Prefix:  prefix,
		Padding: int16(padding),
	})
}

// FindModuleIdByKey — natural key modul → id; nil bila tidak terdaftar.
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
