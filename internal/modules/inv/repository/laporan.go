// Package repository — SATU-SATUNYA pengguna pgx+sqlc modul inv.
// laporan.go — fitur LAPORAN PERSEDIAAN (INV-F14 + patch 04): kartu stok,
// expiring FEFO, lapisan biaya FIFO, KPI §2.3, traceability, nilai
// persediaan, backlog, reorder — padanan LaporanRepository NestJS. Row →
// struct murni domain di sini; mapper view + saldo berjalan ada di domain.
// Helper konversi pgtype dipakai dari helpers.go (waktu/i8Nilai/i8Ptr/txtPtr/
// pgtypeTzPtr).
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository/gen"
	"nexierp/internal/modules/inv/types"
)

// LaporanRepository — baca non-transaksi (service meneruskan executor).
type LaporanRepository struct{}

// NewLaporanRepository membuat repository laporan.
func NewLaporanRepository() *LaporanRepository { return &LaporanRepository{} }

// ---------------------------------------------------------------------
// Kartu stok — mutasi periode / total / saldo awal / kode lot
// ---------------------------------------------------------------------

// ListMutasiKartuStok — baris mutasi kartu stok satu halaman (gerakan
// SELESAI hidup yang menyentuh lokasi produk tsb pada rentang
// tanggal_selesai; sort/limit diputuskan service).
func (r *LaporanRepository) ListMutasiKartuStok(
	ctx context.Context,
	exec DBTX,
	idProduk int64,
	idLokasi *int64,
	awal, akhir time.Time,
	sortCol string,
	sortDesc bool,
	limit, offset int32,
) ([]domain.BarisKartuStok, error) {
	rows, err := gen.New(exec).ListMutasiKartuStok(ctx, gen.ListMutasiKartuStokParams{
		IDProduk: idProduk,
		IDLokasi: lpI8Nil(idLokasi),
		Awal:     lpWaktu(awal),
		Akhir:    lpWaktu(akhir),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   offset,
		Limit:    limit,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.BarisKartuStok, 0, len(rows))
	for _, row := range rows {
		out = append(out, domain.BarisKartuStok{
			TanggalSelesai:    lpTzPtr(row.TanggalSelesai),
			TanggalJadwal:     row.TanggalJadwal.Time,
			NomorDokumen:      row.NomorDokumen,
			Jenis:             row.Jenis,
			IDInvLotSerial:    lpI8Ptr(row.IDInvLotSerial),
			QtySelesai:        int64(row.QtySelesai),
			NilaiPersatuan:    Angka(row.NilaiPersatuan),
			IDLokasiTujuan:    row.IDLokasiTujuan,
			JenisSumberLokasi: row.JenisSumberLokasi,
			JenisTujuanLokasi: row.JenisTujuanLokasi,
		})
	}
	return out, nil
}

// HitungMutasiKartuStok — total baris mutasi kartu stok (filter sama).
func (r *LaporanRepository) HitungMutasiKartuStok(
	ctx context.Context,
	exec DBTX,
	idProduk int64,
	idLokasi *int64,
	awal, akhir time.Time,
) (int64, error) {
	n, err := gen.New(exec).HitungMutasiKartuStok(ctx, gen.HitungMutasiKartuStokParams{
		IDProduk: idProduk,
		IDLokasi: lpI8Nil(idLokasi),
		Awal:     lpWaktu(awal),
		Akhir:    lpWaktu(akhir),
	})
	return int64(n), err
}

// MuatSaldoAwalKartuStok — Σ gerakan SELESAI `<=` tanggalDari (inklusif).
func (r *LaporanRepository) MuatSaldoAwalKartuStok(ctx context.Context, exec DBTX, idProduk int64, idLokasi *int64, awal time.Time) (int64, error) {
	n, err := gen.New(exec).MuatSaldoAwalKartuStok(ctx, gen.MuatSaldoAwalKartuStokParams{
		IDProduk: idProduk,
		IDLokasi: lpI8Nil(idLokasi),
		Awal:     lpWaktu(awal),
	})
	return int64(n), err
}

// ListKodeLot — map id → kode lot (pra-muat utk mapper kartu stok).
func (r *LaporanRepository) ListKodeLot(ctx context.Context, exec DBTX, lotIDs []int64) (map[int64]string, error) {
	if len(lotIDs) == 0 {
		return map[int64]string{}, nil
	}
	rows, err := gen.New(exec).ListKodeLot(ctx, lotIDs)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string, len(rows))
	for _, row := range rows {
		out[row.ID] = row.Kode
	}
	return out, nil
}

// ---------------------------------------------------------------------
// Expiring (FEFO)
// ---------------------------------------------------------------------

// ListLotExpiring — lot kedaluwarsa ≤ batas (CFG-INV-12), filter gudang.
func (r *LaporanRepository) ListLotExpiring(ctx context.Context, exec DBTX, batas time.Time, idGudang *int64) ([]domain.LotExpiring, error) {
	rows, err := gen.New(exec).ListLotExpiring(ctx, gen.ListLotExpiringParams{
		Batas:    lpWaktu(batas),
		IDGudang: lpI8Nil(idGudang),
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.LotExpiring, 0, len(rows))
	for _, row := range rows {
		out = append(out, domain.LotExpiring{
			ID:                 row.ID,
			Kode:               row.Kode,
			TanggalKedaluwarsa: lpTzPtr(row.TanggalKedaluwarsa),
			Status:             row.Status,
			IDInvProduk:        row.IDInvProduk,
			KodeProduk:         row.KodeProduk,
			NamaProduk:         row.NamaProduk,
			QtyOnHand:          int64(row.QtyOnHand),
			NilaiPersediaan:    Angka0(row.NilaiPersediaan),
		})
	}
	return out, nil
}

// ---------------------------------------------------------------------
// Lapisan biaya FIFO (patch 04 — D-27)
// ---------------------------------------------------------------------

// lapisanRow — baris lapisan biaya hasil konversi pgtype (view dirakit
// service — bentuk 1:1 kolom query).
type lapisanRow struct {
	ID                int64
	IDInvProduk       int64
	KodeProduk        string
	KodeLot           *string
	NomorDokumenMasuk string
	TanggalMasuk      time.Time
	QtyMasuk          int64
	QtyTerpakai       int64
	BiayaPersatuan    float64
}

// ListLapisanBiaya — lapisan biaya sisa satu halaman + total (urut tertua).
func (r *LaporanRepository) ListLapisanBiaya(
	ctx context.Context,
	exec DBTX,
	idProduk int64,
	sortCol string,
	sortDesc bool,
	limit, offset int32,
) ([]lapisanRow, int64, error) {
	rows, err := gen.New(exec).ListLapisanBiaya(ctx, gen.ListLapisanBiayaParams{
		IDProduk: idProduk,
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   offset,
		Limit:    limit,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).HitungLapisanBiaya(ctx, idProduk)
	if err != nil {
		return nil, 0, err
	}
	out := make([]lapisanRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, lapisanRow{
			ID:                row.ID,
			IDInvProduk:       row.IDInvProduk,
			KodeProduk:        row.KodeProduk,
			KodeLot:           lpTxtPtr(row.KodeLot),
			NomorDokumenMasuk: row.NomorDokumenMasuk,
			TanggalMasuk:      row.TanggalMasuk.Time,
			QtyMasuk:          int64(row.QtyMasuk),
			QtyTerpakai:       int64(row.QtyTerpakai),
			BiayaPersatuan:    Angka0(row.BiayaPersatuan),
		})
	}
	return out, int64(total), nil
}

// ---------------------------------------------------------------------
// KPI §2.3 (patch 04) — empat agregat terpisah
// ---------------------------------------------------------------------

// MuatTotalNilaiPersediaan — penyebut KPI = Σ nilai persediaan READMODEL
// (query yang sama dengan dashboard — satu sumber).
func (r *LaporanRepository) MuatTotalNilaiPersediaan(ctx context.Context, exec DBTX) (float64, error) {
	n, err := gen.New(exec).MuatTotalNilaiPersediaan(ctx)
	if err != nil {
		return 0, err
	}
	return Angka0(n), nil
}

// MuatSelisihPenyesuaianDisetujui — Σ|qty_selisih × biaya_satuan| DISETUJUI.
func (r *LaporanRepository) MuatSelisihPenyesuaianDisetujui(ctx context.Context, exec DBTX, awal, akhir time.Time) (float64, error) {
	n, err := gen.New(exec).MuatSelisihPenyesuaianDisetujui(ctx, gen.MuatSelisihPenyesuaianDisetujuiParams{
		Awal:  lpWaktu(awal),
		Akhir: lpWaktu(akhir),
	})
	if err != nil {
		return 0, err
	}
	return Angka0(n), nil
}

// KetepatanRow — agregat ketepatan (total vs tepat) KPI penerimaan/pengiriman.
type KetepatanRow struct {
	Total int64
	Tepat int64
}

// MuatKetepatanPenerimaan — RCV SELESAI, selesai ≤ jadwal+1 hari.
func (r *LaporanRepository) MuatKetepatanPenerimaan(ctx context.Context, exec DBTX, awal, akhir time.Time) (KetepatanRow, error) {
	row, err := gen.New(exec).MuatKetepatanPenerimaan(ctx, gen.MuatKetepatanPenerimaanParams{
		Awal:  lpWaktu(awal),
		Akhir: lpWaktu(akhir),
	})
	if err != nil {
		return KetepatanRow{}, err
	}
	return KetepatanRow{Total: int64(row.Total), Tepat: int64(row.Tepat)}, nil
}

// MuatKetepatanPengiriman — DLV SELESAI pada hari jadwalnya (::date).
func (r *LaporanRepository) MuatKetepatanPengiriman(ctx context.Context, exec DBTX, awal, akhir time.Time) (KetepatanRow, error) {
	row, err := gen.New(exec).MuatKetepatanPengiriman(ctx, gen.MuatKetepatanPengirimanParams{
		Awal:  lpWaktu(awal),
		Akhir: lpWaktu(akhir),
	})
	if err != nil {
		return KetepatanRow{}, err
	}
	return KetepatanRow{Total: int64(row.Total), Tepat: int64(row.Tepat)}, nil
}

// ---------------------------------------------------------------------
// Traceability (patch 04)
// ---------------------------------------------------------------------

// TraceabilityFilter — filter traceability (lot menang atas produk —
// diputuskan service); rentang opsional (narg — wajib KEDUANYA).
type TraceabilityFilter struct {
	IDProduk *int64
	IDLot    *int64
	Awal     *time.Time
	Akhir    *time.Time
}

// ListTraceability — baris traceability satu halaman.
func (r *LaporanRepository) ListTraceability(ctx context.Context, exec DBTX, f TraceabilityFilter, sortCol string, sortDesc bool, limit, offset int32) ([]domain.BarisTraceability, error) {
	rows, err := gen.New(exec).ListTraceability(ctx, gen.ListTraceabilityParams{
		IDProduk: lpI8Nil(f.IDProduk),
		IDLot:    lpI8Nil(f.IDLot),
		Awal:     lpTzNarg(f.Awal),
		Akhir:    lpTzNarg(f.Akhir),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   offset,
		Limit:    limit,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.BarisTraceability, 0, len(rows))
	for _, row := range rows {
		out = append(out, domain.BarisTraceability{
			TanggalSelesai:    lpTzPtr(row.TanggalSelesai),
			TanggalJadwal:     row.TanggalJadwal.Time,
			NomorDokumen:      row.NomorDokumen,
			Jenis:             row.Jenis,
			JenisSumber:       row.JenisSumber,
			QtySelesai:        int64(row.QtySelesai),
			NilaiPersatuan:    Angka(row.NilaiPersatuan),
			EntityIDSumber:    lpTxtPtr(row.EntityIDSumber),
			JenisSumberLokasi: row.JenisSumberLokasi,
			JenisTujuanLokasi: row.JenisTujuanLokasi,
			KodeSumber:        row.KodeSumber,
			NamaSumber:        row.NamaSumber,
			KodeTujuan:        row.KodeTujuan,
			NamaTujuan:        row.NamaTujuan,
			KodeLot:           lpTxtPtr(row.KodeLot),
		})
	}
	return out, nil
}

// HitungTraceability — total baris traceability (filter sama).
func (r *LaporanRepository) HitungTraceability(ctx context.Context, exec DBTX, f TraceabilityFilter) (int64, error) {
	n, err := gen.New(exec).HitungTraceability(ctx, gen.HitungTraceabilityParams{
		IDProduk: lpI8Nil(f.IDProduk),
		IDLot:    lpI8Nil(f.IDLot),
		Awal:     lpTzNarg(f.Awal),
		Akhir:    lpTzNarg(f.Akhir),
	})
	return int64(n), err
}

// ---------------------------------------------------------------------
// Nilai persediaan / backlog / reorder
// ---------------------------------------------------------------------

// NilaiKelompokRow — baris agregat nilai persediaan (kelompok + angka
// terkonversi; prefix khusus utk hindari kolisi NilaiRow master-A).
type NilaiKelompokRow struct {
	Kelompok   string
	JumlahSku  int64
	TotalQty   int64
	TotalNilai float64
}

// AgregatNilaiPerGudang — nilai persediaan per GUDANG (urut nilai terbesar).
func (r *LaporanRepository) AgregatNilaiPerGudang(ctx context.Context, exec DBTX) ([]NilaiKelompokRow, error) {
	rows, err := gen.New(exec).AgregatNilaiPerGudang(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]NilaiKelompokRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, NilaiKelompokRow{
			Kelompok:   row.Kelompok,
			JumlahSku:  int64(row.JumlahSku),
			TotalQty:   int64(row.TotalQty),
			TotalNilai: Angka0(row.TotalNilai),
		})
	}
	return out, nil
}

// AgregatNilaiPerKategori — nilai persediaan per KATEGORI produk.
func (r *LaporanRepository) AgregatNilaiPerKategori(ctx context.Context, exec DBTX) ([]NilaiKelompokRow, error) {
	rows, err := gen.New(exec).AgregatNilaiPerKategori(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]NilaiKelompokRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, NilaiKelompokRow{
			Kelompok:   row.Kelompok,
			JumlahSku:  int64(row.JumlahSku),
			TotalQty:   int64(row.TotalQty),
			TotalNilai: Angka0(row.TotalNilai),
		})
	}
	return out, nil
}

// AgregatBacklog — gerakan terbuka per jenis×status.
func (r *LaporanRepository) AgregatBacklog(ctx context.Context, exec DBTX) ([]types.BacklogRowView, error) {
	rows, err := gen.New(exec).AgregatBacklog(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]types.BacklogRowView, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.BacklogRowView{
			Jenis:    row.Jenis,
			Status:   row.Status,
			Jumlah:   int64(row.Jumlah),
			TotalQty: int64(row.TotalQty),
		})
	}
	return out, nil
}

// ReorderRow — baris reorder (saldo efektif & qty saran dihitung service via domain).
type ReorderRow struct {
	IDInvProduk  int64
	KodeProduk   string
	NamaProduk   string
	StokMinimum  int64
	StokMaksimum *int64
	ReorderAktif bool
	OnHand       int64
	Dipesan      int64
}

// ListReorder — produk reorder_aktif dengan stok_minimum > 0 (urut kode).
func (r *LaporanRepository) ListReorder(ctx context.Context, exec DBTX) ([]ReorderRow, error) {
	rows, err := gen.New(exec).ListReorder(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]ReorderRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, ReorderRow{
			IDInvProduk:  row.ID,
			KodeProduk:   row.KodeProduk,
			NamaProduk:   row.Nama,
			StokMinimum:  int64(row.StokMinimum),
			StokMaksimum: lpI4Ptr(row.StokMaksimum),
			ReorderAktif: row.ReorderAktif,
			OnHand:       int64(row.OnHand),
			Dipesan:      int64(row.Dipesan),
		})
	}
	return out, nil
}

// lpTzPtr — pgtype.Timestamptz → *time.Time (NULL → nil).
func lpTzPtr(v pgtype.Timestamptz) *time.Time {
	if !v.Valid {
		return nil
	}
	t := v.Time
	return &t
}

// lpTzNarg — *time.Time → pgtype.Timestamptz (NULL bila nil — rentang opsional).
func lpTzNarg(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

// lpI8Nil — *int64 → pgtype.Int8 (nil = NULL).
func lpI8Nil(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// lpI8Ptr — pgtype.Int8 → *int64 (NULL → nil).
func lpI8Ptr(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	n := v.Int64
	return &n
}

// lpI4Ptr — pgtype.Int4 → *int64 (NULL → nil; stok_maksimum integer).
func lpI4Ptr(v pgtype.Int4) *int64 {
	if !v.Valid {
		return nil
	}
	n := int64(v.Int32)
	return &n
}

// lpTxtPtr — pgtype.Text → *string (NULL → nil).
func lpTxtPtr(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	s := v.String
	return &s
}
