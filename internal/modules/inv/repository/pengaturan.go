// repository/pengaturan.go — SATU-SATUNYA pengguna pgx+sqlc fitur
// PENGATURAN modul inv (padanan repositories/pengaturan/pengaturan.repository.ts
// NestJS): baca version/updatedAt baris registry `core_module_configs` per
// param CFG-INV (pemilik registry: CORE, natural key modul inventory).
// Pertanyaan bisnis & opsi label (DEFINISI_PARAM/OPSI_KOSAKATA) TIDAK di
// sini — milik service/pengaturan.go (padanan types/pengaturan-types.ts);
// tulis nilai param via moduleconfig.Service (serialisasi + version + 409
// VAL-409) dan audit trail tetap di service (INV-BR06).
package repository

import (
	"context"
	"time"

	"nexierp/internal/modules/inv/repository/gen"
)

// ParamConfigRow — version/updatedAt registry satu param CFG (input mapper
// view service); nol-time = param belum pernah diset.
type ParamConfigRow struct {
	Version   int64
	UpdatedAt time.Time
	Found     bool
}

// OpsiLabel — satu opsi pilihan: nilai + label ramah UI.
type OpsiLabel struct {
	Nilai string `json:"nilai"`
	Label string `json:"label"`
}

// CfgInvParamView — satu param CFG untuk UI pengaturan (kunci cermin
// cfgInvParamViewSchema; nilai bebas — string/number/object/null).
type CfgInvParamView struct {
	ParamKey   string      `json:"paramKey"`
	Pertanyaan string      `json:"pertanyaan"`
	Nilai      any         `json:"nilai"`
	Opsi       []OpsiLabel `json:"opsi"`
	ValueType  string      `json:"valueType"`
	Version    int64       `json:"version"`
	UpdatedAt  string      `json:"updatedAt"`
}

// CfgInvView — kontrak respons GET/PUT /inventory/pengaturan.
type CfgInvView struct {
	Params []CfgInvParamView `json:"params"`
}

// PengaturanRepository — pembungkus gen.Querier fitur pengaturan (tanpa
// state; executor diteruskan per method).
type PengaturanRepository struct{}

// NewPengaturanRepository — konstruksi repo pengaturan.
func NewPengaturanRepository() *PengaturanRepository { return &PengaturanRepository{} }

// MuatVersiParam — version + updatedAt baris `core_module_configs` satu
// param CFG-INV; found=false bila param belum pernah diset (service
// fallback epoch + version 0).
//
// QUIRK VERBATIM sumber (sengaja dipertahankan): filter HANYA param_key
// TANPA filter modul + LIMIT 1 tanpa ORDER BY — baris param_key sama milik
// modul lain bisa ikut terpilih.
func (r *PengaturanRepository) MuatVersiParam(ctx context.Context, exec gen.DBTX, paramKey string) (ParamConfigRow, error) {
	rows, err := gen.New(exec).MuatVersiParam(ctx, paramKey)
	if err != nil {
		return ParamConfigRow{}, err
	}
	if len(rows) == 0 {
		return ParamConfigRow{Found: false}, nil
	}
	return ParamConfigRow{
		Version:   rows[0].Version,
		UpdatedAt: rows[0].UpdatedAt.Time,
		Found:     true,
	}, nil
}
