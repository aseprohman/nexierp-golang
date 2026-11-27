// service/laporan.go — fitur LAPORAN PERSEDIAAN (INV-F14 + patch 04): kartu
// stok, expiring FEFO, lapisan biaya FIFO, KPI §2.3, traceability, nilai
// persediaan, backlog, reorder — padanan LaporanService NestJS. Orkestrasi:
// validasi filter (400 VAL-400 pesan verbatim), baca CFG (CFG-INV-12 utk
// expiring), rakitan Page KPI (4 baris fixed, meta.total=4 TANPA slice),
// panggilan mapper domain (SusunBarisKartuStok, PetakanExpiring,
// PetakanTraceability). Semua baca non-transaksi (pool).
package service

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"time"

	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/shared"
	"nexierp/internal/modules/inv/types"
)

// LaporanService — orkestrasi baca laporan (executor pool).
type LaporanService struct {
	db     *database.DB
	modCfg *moduleconfig.Service
	repo   *repository.LaporanRepository
}

// NewLaporanService membuat service laporan.
func NewLaporanService(db *database.DB, modCfg *moduleconfig.Service) *LaporanService {
	return &LaporanService{db: db, modCfg: modCfg, repo: repository.NewLaporanRepository()}
}

// fi — field issue singkat.
func fi(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

// validasiSortLaporan — whitelist sort ala drizzlePageBounds: field di luar
// peta → 400 VAL-400 `Field sort tidak dikenal: X.`; tanpa sort → ("", false).
// Pemakaian multi-key (split koma di parser Go) divalidasi semua; yang
// dipakai ORDER BY = key pertama (NestJS single-sort).
func validasiSortLaporan(pr *errkontrak.PageRequest, allowed map[string]string) (string, bool, error) {
	if len(pr.Sort) == 0 {
		return "", false, nil
	}
	for _, k := range pr.Sort {
		if _, ada := allowed[k.Field]; !ada {
			return "", false, errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "sort", Message: fmt.Sprintf("Field sort tidak dikenal: %s.", k.Field)},
			})
		}
	}
	k := pr.Sort[0]
	return allowed[k.Field], k.Desc, nil
}

// filterAngka — filter numerik semantik Number() (padanan
// `Number(req.filters[k])`): kosong/absen → nil; gagal parse → 500 generik
// (NestJS mengikat NaN ke query → PG error → 500; jalur ini praktis tidak
// pernah ditempuh pemakai normal).
func filterAngka(pr *errkontrak.PageRequest, key string) (*int64, error) {
	raw := pr.Filters[key]
	if raw == "" {
		return nil, nil
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return nil, errkontrak.Internal("")
	}
	n := int64(f)
	return &n, nil
}

// ---------------------------------------------------------------------
// Kartu stok
// ---------------------------------------------------------------------

// whitelist sort kartu stok & traceability (drizzlePageBounds caller map).
var sortTanggalNomor = map[string]string{
	"tanggal": "tanggal",
	"nomor":   "nomor",
}

// KartuStok — kartu stok per produk (opsi lokasi) pada periode — mutasi
// gerakan SELESAI + saldo berjalan dari saldo awal periode (`<=` awal).
func (s *LaporanService) KartuStok(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.KartuStokRowView], error) {
	var out errkontrak.Page[types.KartuStokRowView]

	// WAJIB idProduk + tanggalDari + tanggalSampai — issue TUNGGAL field idProduk.
	rawProduk := pr.Filters["idProduk"]
	dari := pr.Filters["tanggalDari"]
	sampai := pr.Filters["tanggalSampai"]
	if rawProduk == "" || dari == "" || sampai == "" {
		return out, errkontrak.Validation([]errkontrak.FieldIssue{
			fi("idProduk", "Kartu stok wajib idProduk, tanggalDari, tanggalSampai."),
		})
	}
	idProduk, errAngka := filterAngka(pr, "idProduk")
	if errAngka != nil {
		return out, errAngka
	}
	idLokasi, errAngka := filterAngka(pr, "idLokasi")
	if errAngka != nil {
		return out, errAngka
	}

	awal, akhir, err := shared.RentangTanggal(dari, sampai)
	if err != nil {
		return out, err
	}

	sortCol, sortDesc, err := validasiSortLaporan(pr, sortTanggalNomor)
	if err != nil {
		return out, err
	}
	limit := int32(pr.Limit)
	offset := int32(pr.Offset)

	// Mutasi periode: gerakan SELESAI hidup yang menyentuh lokasi internal
	// dengan produk tsb (sumber ATAU tujuan) pada rentang tanggal_selesai.
	rows, err := s.repo.ListMutasiKartuStok(ctx, s.db.Pool, *idProduk, idLokasi, awal, akhir, sortCol, sortDesc, limit, offset)
	if err != nil {
		return out, err
	}
	total, err := s.repo.HitungMutasiKartuStok(ctx, s.db.Pool, *idProduk, idLokasi, awal, akhir)
	if err != nil {
		return out, err
	}

	// Saldo awal periode = Σ gerakan SELESAI `<=` tanggalDari (inklusif).
	saldoAwal, err := s.repo.MuatSaldoAwalKartuStok(ctx, s.db.Pool, *idProduk, idLokasi, awal)
	if err != nil {
		return out, err
	}

	// Pra-muat kode lot untuk baris halaman (dipakai sinkron di mapper).
	lotIDs := make([]int64, 0, len(rows))
	for _, r := range rows {
		if r.IDInvLotSerial != nil {
			lotIDs = append(lotIDs, *r.IDInvLotSerial)
		}
	}
	kodeLotByID, err := s.repo.ListKodeLot(ctx, s.db.Pool, lotIDs)
	if err != nil {
		return out, err
	}

	// Susun baris kartu + saldo berjalan (server-side) — mapper domain.
	data := domain.SusunBarisKartuStok(rows, kodeLotByID, saldoAwal, idLokasi)
	return errkontrak.BuildPage(data, int(total), pr), nil
}

// ---------------------------------------------------------------------
// Expiring (FEFO)
// ---------------------------------------------------------------------

// Expiring — lot mendekati/lewat kedaluwarsa — ≤ CFG-INV-12 hari dari
// sekarang (atau sudah lewat); filter gudang; qty & nilai dari READMODEL.
func (s *LaporanService) Expiring(ctx context.Context, idGudang *int64) ([]types.ExpiringRowView, error) {
	ambang, err := s.modCfg.GetNumber(ctx, s.db.Pool, "inventory", "CFG-INV-12", 0)
	if err != nil {
		return nil, err
	}
	// JS setDate(getDate() + ambang) — pecahan dipotong (ToIntegerOrInfinity).
	batas := time.Now().AddDate(0, 0, int(ambang))

	rows, err := s.repo.ListLotExpiring(ctx, s.db.Pool, batas, idGudang)
	if err != nil {
		return nil, err
	}
	return domain.PetakanExpiring(rows, time.Now()), nil
}

// ---------------------------------------------------------------------
// Lapisan biaya FIFO (patch 04 — D-27)
// ---------------------------------------------------------------------

// whitelist sort lapisan biaya (alias snake/camel satu kolom).
var sortLapisan = map[string]string{
	"tanggal_masuk": "tanggal_masuk",
	"tanggalMasuk":  "tanggal_masuk",
	"id":            "id",
}

// LapisanBiaya — lapisan biaya FIFO sisa per produk (qty_terpakai <
// qty_masuk), urut tertua dulu. idInvProduk WAJIB — dua pesan verbatim.
func (s *LaporanService) LapisanBiaya(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.LapisanBiayaView], error) {
	var out errkontrak.Page[types.LapisanBiayaView]
	raw := pr.Filters["idInvProduk"]
	if raw == "" {
		return out, errkontrak.Validation([]errkontrak.FieldIssue{
			fi("idInvProduk", "Wajib filter idInvProduk (lapisan biaya per produk)."),
		})
	}
	f, errNum := strconv.ParseFloat(raw, 64)
	if errNum != nil || f != float64(int64(f)) || int64(f) < 1 {
		return out, errkontrak.Validation([]errkontrak.FieldIssue{
			fi("idInvProduk", fmt.Sprintf("Id produk tidak valid (%s).", raw)),
		})
	}
	idProduk := int64(f)

	sortCol, sortDesc, err := validasiSortLaporan(pr, sortLapisan)
	if err != nil {
		return out, err
	}
	rows, total, err := s.repo.ListLapisanBiaya(ctx, s.db.Pool, idProduk, sortCol, sortDesc, int32(pr.Limit), int32(pr.Offset))
	if err != nil {
		return out, err
	}
	data := make([]types.LapisanBiayaView, 0, len(rows))
	for _, r := range rows {
		data = append(data, types.LapisanBiayaView{
			ID:                r.ID,
			IDInvProduk:       r.IDInvProduk,
			KodeProduk:        r.KodeProduk,
			KodeLot:           r.KodeLot,
			NomorDokumenMasuk: r.NomorDokumenMasuk,
			TanggalMasuk:      shared.ISO(r.TanggalMasuk),
			QtyMasuk:          r.QtyMasuk,
			QtyTerpakai:       r.QtyTerpakai,
			QtySisa:           r.QtyMasuk - r.QtyTerpakai,
			BiayaPersatuan:    r.BiayaPersatuan,
		})
	}
	return errkontrak.BuildPage(data, int(total), pr), nil
}

// ---------------------------------------------------------------------
// KPI §2.3 (patch 04)
// ---------------------------------------------------------------------

// KPI — Page<KpiRowView> 4 baris, semua angka dari query agregat (penyebut
// dihitung, bukan hardcode); meta.total = 4 FIXED TANPA slice page.
func (s *LaporanService) KPI(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.KpiRowView], error) {
	var out errkontrak.Page[types.KpiRowView]
	dari := pr.Filters["tanggalDari"]
	sampai := pr.Filters["tanggalSampai"]
	if dari == "" || sampai == "" {
		return out, errkontrak.Validation([]errkontrak.FieldIssue{
			fi("tanggalDari", "KPI wajib tanggalDari & tanggalSampai."),
		})
	}
	awal, akhir, err := shared.RentangTanggal(dari, sampai)
	if err != nil {
		return out, err
	}

	// --- Pembilang penyesuaian DISETUJUI (|selisih × biaya|) pada periode ---
	selisihNilai, err := s.repo.MuatSelisihPenyesuaianDisetujui(ctx, s.db.Pool, awal, akhir)
	if err != nil {
		return out, err
	}

	// --- Penyebut: nilai persediaan akhir (READMODEL saldo) ---
	totalNilaiPersediaan, err := s.repo.MuatTotalNilaiPersediaan(ctx, s.db.Pool)
	if err != nil {
		return out, err
	}

	// --- Ketepatan penerimaan (RCV SELESAI, selesai ≤ jadwal+1 hari) ---
	rcv, err := s.repo.MuatKetepatanPenerimaan(ctx, s.db.Pool, awal, akhir)
	if err != nil {
		return out, err
	}

	// --- Ketepatan pengiriman (DLV SELESAI pada hari jadwalnya) ---
	dlv, err := s.repo.MuatKetepatanPengiriman(ctx, s.db.Pool, awal, akhir)
	if err != nil {
		return out, err
	}

	persen := func(jumlah, penyebut float64) float64 {
		if penyebut > 0 {
			return math.Round(jumlah/penyebut*10000) / 100
		}
		return 0
	}
	akurasi := 0.0
	if totalNilaiPersediaan > 0 {
		akurasi = math.Round((1-selisihNilai/totalNilaiPersediaan)*10000) / 100
	}

	data := []types.KpiRowView{
		{
			Kpi:      "AKURASI_STOK",
			Label:    "Akurasi Stok",
			Nilai:    akurasi,
			Satuan:   "PERSEN",
			Target:   "≤ 99%",
			Jumlah:   selisihNilai,
			Penyebut: totalNilaiPersediaan,
		},
		{
			Kpi:      "KETEPATAN_PENERIMAAN",
			Label:    "Ketepatan Penerimaan",
			Nilai:    persen(float64(rcv.Tepat), float64(rcv.Total)),
			Satuan:   "PERSEN",
			Target:   "≥ 95%",
			Jumlah:   float64(rcv.Tepat),
			Penyebut: float64(rcv.Total),
		},
		{
			Kpi:      "KETEPATAN_PENGIRIMAN",
			Label:    "Ketepatan Pengiriman",
			Nilai:    persen(float64(dlv.Tepat), float64(dlv.Total)),
			Satuan:   "PERSEN",
			Target:   "≥ 95%",
			Jumlah:   float64(dlv.Tepat),
			Penyebut: float64(dlv.Total),
		},
		{
			Kpi:      "PENYESUAIAN_TAK_TERJELASKAN",
			Label:    "Penyesuaian Tak Terjelaskan",
			Nilai:    persen(selisihNilai, totalNilaiPersediaan),
			Satuan:   "PERSEN",
			Target:   "≤ 0,5%",
			Jumlah:   selisihNilai,
			Penyebut: totalNilaiPersediaan,
		},
	}
	// meta.total = panjang data (4) — page/limit tidak memotong baris KPI.
	return errkontrak.BuildPage(data, len(data), pr), nil
}

// ---------------------------------------------------------------------
// Traceability (patch 04)
// ---------------------------------------------------------------------

// Traceability — jejak naik-turun produk/lot pada rentang; minimal satu
// filter id (produk/lot); rentang wajib KEDUANYA (satu saja → diabaikan).
func (s *LaporanService) Traceability(ctx context.Context, pr *errkontrak.PageRequest, idProduk, idLot *int64) (errkontrak.Page[types.TraceabilityRowView], error) {
	var out errkontrak.Page[types.TraceabilityRowView]
	if idProduk == nil && idLot == nil {
		return out, errkontrak.Validation([]errkontrak.FieldIssue{
			fi("idInvProduk", "Pilih minimal satu filter: produk atau lot."),
		})
	}

	// Rentang opsional — dipakai HANYA bila keduanya ada (dari && sampai).
	var awal, akhir *time.Time
	dari := pr.Filters["tanggalDari"]
	sampai := pr.Filters["tanggalSampai"]
	if dari != "" && sampai != "" {
		a, ak, err := shared.RentangTanggal(dari, sampai)
		if err != nil {
			return out, err
		}
		awal, akhir = &a, &ak
	}

	sortCol, sortDesc, err := validasiSortLaporan(pr, sortTanggalNomor)
	if err != nil {
		return out, err
	}
	filter := repository.TraceabilityFilter{IDProduk: idProduk, IDLot: idLot, Awal: awal, Akhir: akhir}

	rows, err := s.repo.ListTraceability(ctx, s.db.Pool, filter, sortCol, sortDesc, int32(pr.Limit), int32(pr.Offset))
	if err != nil {
		return out, err
	}
	total, err := s.repo.HitungTraceability(ctx, s.db.Pool, filter)
	if err != nil {
		return out, err
	}
	return errkontrak.BuildPage(domain.PetakanTraceability(rows), int(total), pr), nil
}

// ---------------------------------------------------------------------
// Nilai persediaan / backlog / reorder
// ---------------------------------------------------------------------

// Nilai — nilai persediaan per KATEGORI (default) atau GUDANG; kelompok
// invalid → kategori diam-diam (verbatim).
func (s *LaporanService) Nilai(ctx context.Context, kelompokRaw string) ([]types.NilaiPersediaanRowView, error) {
	jenis := "KATEGORI"
	var rows []repository.NilaiKelompokRow
	var err error
	if kelompokRaw == "gudang" {
		jenis = "GUDANG"
		rows, err = s.repo.AgregatNilaiPerGudang(ctx, s.db.Pool)
	} else {
		rows, err = s.repo.AgregatNilaiPerKategori(ctx, s.db.Pool)
	}
	if err != nil {
		return nil, err
	}
	out := make([]types.NilaiPersediaanRowView, 0, len(rows))
	for _, r := range rows {
		out = append(out, types.NilaiPersediaanRowView{
			Kelompok:      r.Kelompok,
			JenisKelompok: jenis,
			JumlahSku:     r.JumlahSku,
			TotalQty:      r.TotalQty,
			TotalNilai:    r.TotalNilai,
		})
	}
	return out, nil
}

// Backlog — gerakan terbuka (bukan SELESAI/BATAL) per jenis×status.
func (s *LaporanService) Backlog(ctx context.Context) ([]types.BacklogRowView, error) {
	return s.repo.AgregatBacklog(ctx, s.db.Pool)
}

// Reorder — produk reorder_aktif dengan saldo efektif < minimum.
func (s *LaporanService) Reorder(ctx context.Context) ([]types.ReorderRowView, error) {
	rows, err := s.repo.ListReorder(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	out := make([]types.ReorderRowView, 0, len(rows))
	for _, r := range rows {
		saldoEfektif := r.OnHand - r.Dipesan
		// A-03: kebijakan reorder di kartu produk (agregat lintas gudang).
		if saldoEfektif >= r.StokMinimum {
			continue
		}
		out = append(out, types.ReorderRowView{
			IDInvProduk:  r.IDInvProduk,
			KodeProduk:   r.KodeProduk,
			NamaProduk:   r.NamaProduk,
			StokMinimum:  r.StokMinimum,
			StokMaksimum: r.StokMaksimum,
			SaldoEfektif: saldoEfektif,
			QtySaran:     domain.HitungQtySaranReorder(r.StokMinimum, r.StokMaksimum, saldoEfektif),
			NamaGudang:   nil,
			ReorderAktif: r.ReorderAktif,
		})
	}
	return out, nil
}
