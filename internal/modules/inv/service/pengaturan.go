// service/pengaturan.go — orkestrasi fitur PENGATURAN modul inv (padanan
// services/pengaturan/pengaturan.service.ts NestJS, INV-F03): parameter
// CFG-INV-01..13 (12 kunci, CFG_INV_PARAMS — tanpa CFG-INV-11) pada registry
// `core_module_configs` (pemilik: CORE, natural key modul inventory).
//
// Pertanyaan bisnis & opsi label (DEFINISI_PARAM/OPSI_KOSAKATA) milik file
// ini (padanan types/pengaturan-types.ts — sesuai tabel §5.2 F03 analisa
// modul INV v2; pertanyaan bisnis bukan milik paket schemas). Perubahan via
// PUT divalidasi dependensinya oleh validasi padanan cfgInvValuesSchema
// (superRefine, di handler) lalu disimpan per param via
// moduleconfig.Service.SetValue (serialisasi + version; expectedVersion TIDAK
// dikirim — 12 setValue independen TANPA tx, persis sumber) + audit trail
// satu entri dalam tx terpisah (INV-BR06).
package service

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/modules/inv/repository"
)

// ---------------------------------------------------------------------
// Kosakata CFG (padanan CFG_*_OPSI @nexierp/schemas inv/schemas.ts)
// ---------------------------------------------------------------------

// CfgPelacakanOpsi — CFG-INV-01.
var CfgPelacakanOpsi = []string{"NONAKTIF", "LOT_TERPILIH", "WAJIB_TERPILIH"}

// CfgKedaluwarsaOpsi — CFG-INV-02.
var CfgKedaluwarsaOpsi = []string{"NONAKTIF", "PERINGATAN", "BLOKIR"}

// CfgLangkahOpsi — CFG-INV-03/04.
var CfgLangkahOpsi = []string{"1", "2", "3"}

// CfgBackorderOpsi — CFG-INV-05.
var CfgBackorderOpsi = []string{"BACKORDER_OTOMATIS", "TANYA_OPERATOR", "TANPA_BACKORDER"}

// CfgApprovalOpsi — CFG-INV-08.
var CfgApprovalOpsi = []string{"TANPA_APPROVAL", "DI_ATAS_AMBANG", "SEMUA"}

// CfgReorderOpsi — CFG-INV-10.
var CfgReorderOpsi = []string{"MANUAL_HARIAN", "OTOMATIS"}

// CfgAtpOpsi — CFG-INV-13.
var CfgAtpOpsi = []string{"ON_HAND", "ATP_KETAT", "ATP_KETAT_BUFFER"}

// MetodeValuasiOpsi — kosakata enum_metode_valuasi (CFG-INV-06, tipe.ts).
var MetodeValuasiOpsi = []string{"STANDAR", "AVCO", "FIFO"}

// SistemValuasiOpsi — kosakata enum_sistem_valuasi (CFG-INV-07, tipe.ts).
var SistemValuasiOpsi = []string{"PERPETUAL", "PERIODIK"}

// CFGInvParams — kunci param CFG-INV (persis CFG_INV_PARAMS tipe.ts —
// registry core_module_configs, modul `inventory`; 12 kunci).
var CFGInvParams = [...]string{
	"CFG-INV-01", "CFG-INV-02", "CFG-INV-03", "CFG-INV-04", "CFG-INV-05",
	"CFG-INV-06", "CFG-INV-07", "CFG-INV-08", "CFG-INV-09", "CFG-INV-10",
	"CFG-INV-12", "CFG-INV-13",
}

// DefinisiParam — pertanyaan bisnis + opsi + valueType per param
// (§5.2 F03 — sumber UI; padanan DEFINISI_PARAM pengaturan-types.ts).
var DefinisiParam = map[string]struct {
	Pertanyaan string
	Opsi       []repository.OpsiLabel
	ValueType  string // "string" | "number" | "boolean" | "json"
}{
	"CFG-INV-01": {
		Pertanyaan: "Apakah produk wajib dilacak per lot/serial?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "NONAKTIF", Label: "Nonaktif"},
			{Nilai: "LOT_TERPILIH", Label: "Lot untuk kategori terpilih"},
			{Nilai: "WAJIB_TERPILIH", Label: "Lot+serial wajib kategori terpilih"},
		},
		ValueType: "string",
	},
	"CFG-INV-02": {
		Pertanyaan: "Apakah kedaluwarsa & FEFO diberlakukan?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "NONAKTIF", Label: "Nonaktif"},
			{Nilai: "PERINGATAN", Label: "Aktif dengan peringatan"},
			{Nilai: "BLOKIR", Label: "Aktif + blokir keluar lot kedaluwarsa"},
		},
		ValueType: "string",
	},
	"CFG-INV-03": {
		Pertanyaan: "Berapa langkah alur penerimaan?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "1", Label: "1 langkah (langsung stok)"},
			{Nilai: "2", Label: "2 langkah (input → cek → stok)"},
			{Nilai: "3", Label: "3 langkah (input → cek → simpan → stok)"},
		},
		ValueType: "string",
	},
	"CFG-INV-04": {
		Pertanyaan: "Berapa langkah alur pengiriman?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "1", Label: "1 langkah (pick = kirim)"},
			{Nilai: "2", Label: "2 langkah (pick → kirim)"},
			{Nilai: "3", Label: "3 langkah (pick → pack → kirim)"},
		},
		ValueType: "string",
	},
	"CFG-INV-05": {
		Pertanyaan: "Apa yang dilakukan saat qty keluar kurang dari diminta?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "BACKORDER_OTOMATIS", Label: "Buat backorder otomatis"},
			{Nilai: "TANYA_OPERATOR", Label: "Tanya operator"},
			{Nilai: "TANPA_BACKORDER", Label: "Tanpa backorder (kurangi qty)"},
		},
		ValueType: "string",
	},
	"CFG-INV-06": {
		Pertanyaan: "Metode valuasi persediaan apa yang dipakai?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "STANDAR", Label: "Standar"},
			{Nilai: "AVCO", Label: "AVCO (rata-rata bergerak)"},
			{Nilai: "FIFO", Label: "FIFO"},
		},
		ValueType: "string",
	},
	"CFG-INV-07": {
		Pertanyaan: "Apakah valuasi perpetual atau periodik?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "PERPETUAL", Label: "Perpetual (jurnal per gerakan via M16)"},
			{Nilai: "PERIODIK", Label: "Periodik (penyesuaian berkala ke ACC)"},
		},
		ValueType: "string",
	},
	"CFG-INV-08": {
		Pertanyaan: "Apakah penyesuaian & scrap wajib persetujuan?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "TANPA_APPROVAL", Label: "Tanpa approval"},
			{Nilai: "DI_ATAS_AMBANG", Label: "Hanya di atas ambang"},
			{Nilai: "SEMUA", Label: "Semua wajib approval"},
		},
		ValueType: "string",
	},
	"CFG-INV-09": {
		Pertanyaan: "Berapa ambang (qty & nilai) penyesuaian sebelum wajib persetujuan?",
		Opsi:       nil,
		ValueType:  "json",
	},
	"CFG-INV-10": {
		Pertanyaan: "Kapan aturan reorder terpicu ke pembelian?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "MANUAL_HARIAN", Label: "Review manual harian"},
			{Nilai: "OTOMATIS", Label: "Otomatis saat stok < min"},
		},
		ValueType: "string",
	},
	"CFG-INV-12": {
		Pertanyaan: "Berapa hari sebelum kedaluwarsa sistem memberi peringatan FEFO?",
		Opsi:       nil,
		ValueType:  "number",
	},
	"CFG-INV-13": {
		Pertanyaan: "Bagaimana ketersediaan (ATP) dihitung untuk kanal online?",
		Opsi: []repository.OpsiLabel{
			{Nilai: "ON_HAND", Label: "Qty fisik on-hand"},
			{Nilai: "ATP_KETAT", Label: "On-hand − keluar terjadwal (ATP ketat)"},
			{Nilai: "ATP_KETAT_BUFFER", Label: "ATP ketat + buffer"},
		},
		ValueType: "string",
	},
}

// OpsiKosakata — peta opsi kosakata → CFG (padanan OPSI_KOSAKATA — untuk
// validasi silang di get — dokumentasi).
var OpsiKosakata = map[string][]string{
	"CFG-INV-01": CfgPelacakanOpsi,
	"CFG-INV-02": CfgKedaluwarsaOpsi,
	"CFG-INV-10": CfgReorderOpsi,
}

// ---------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------

// PengaturanService — kebutuhan fitur pengaturan (DB + audit + CFG + repo).
type PengaturanService struct {
	db    *database.DB
	audit *audit.Service
	cfg   *moduleconfig.Service
}

// NewPengaturanService — konstruksi service pengaturan.
func NewPengaturanService(db *database.DB, aud *audit.Service, cfg *moduleconfig.Service) *PengaturanService {
	return &PengaturanService{db: db, audit: aud, cfg: cfg}
}

// Get — baca 12 param CFG-INV + pertanyaan bisnis + opsi (CfgInvView).
// QUIRK verbatim: version/updatedAt dibaca MuatVersiParam — filter by
// param_key TANPA filter modul; param belum pernah diset → version 0 +
// updatedAt epoch 1970 (new Date(0).toISOString()).
func (s *PengaturanService) Get(ctx context.Context) (repository.CfgInvView, error) {
	const epoch1970 = "1970-01-01T00:00:00.000Z"
	params := make([]repository.CfgInvParamView, 0, len(CFGInvParams))
	for _, paramKey := range CFGInvParams {
		def := DefinisiParam[paramKey]
		nilai, err := s.cfg.GetValue(ctx, s.db.Pool, "inventory", paramKey)
		if err != nil {
			return repository.CfgInvView{}, err
		}
		row, err := repository.NewPengaturanRepository().MuatVersiParam(ctx, s.db.Pool, paramKey)
		if err != nil {
			return repository.CfgInvView{}, err
		}
		view := repository.CfgInvParamView{
			ParamKey:   paramKey,
			Pertanyaan: def.Pertanyaan,
			Nilai:      nilai, // nil → JSON null (nilai ?? null)
			Opsi:       def.Opsi,
			ValueType:  def.ValueType,
			Version:    0,
			UpdatedAt:  epoch1970,
		}
		if row.Found {
			view.Version = row.Version
			view.UpdatedAt = pengIso(row.UpdatedAt)
		}
		params = append(params, view)
	}
	return repository.CfgInvView{Params: params}, nil
}

// Put — simpan nilai CFG-INV (payload tervalidasi dependensi oleh schema —
// handler) + audit. Persis sumber: 12 SetValue INDEPENDEN di pool (TANPA tx,
// expectedVersion tidak dikirim — last-write-wins), lalu SATU entri audit
// ringkas seluruh params dalam tx TERPISAH, lalu get() ulang.
func (s *PengaturanService) Put(ctx context.Context, values map[string]any, actor audit.Actor) (repository.CfgInvView, error) {
	// Id user aktor (null = sistem) — persis `ctx.actor?.id && id > 0 ? id : null`.
	var actorID *int64
	if actor.IDCoreUsers != nil && *actor.IDCoreUsers > 0 {
		actorID = actor.IDCoreUsers
	}

	// Simpan per param — moduleconfig menangani serialisasi + version;
	// konflik optimistic locking → 409 VAL-409 pesan ModuleConfigService
	// verbatim (dari kernel moduleconfig).
	for _, paramKey := range CFGInvParams {
		if _, err := s.cfg.SetValue(ctx, s.db.Pool, "inventory", paramKey, values[paramKey], actorID, nil); err != nil {
			return repository.CfgInvView{}, err
		}
	}

	// Audit trail perubahan (INV-BR06) — satu entri ringkas seluruh params,
	// dalam transaksi TERPISAH dari setValue (persis sumber).
	if err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		_, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "core_module_configs",
				EntityID:   "CFG-INV",
				Action:     "update",
				AfterValue: audit.Snapshot(values),
				Severity:   audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	}); err != nil {
		return repository.CfgInvView{}, err
	}
	return s.Get(ctx)
}

// pengIso — time → ISO-8601 toISOString() (UTC, 3 digit ms; padanan
// isoRequired — duplikasi kecil karena mbIso privat di package repository).
func pengIso(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}
