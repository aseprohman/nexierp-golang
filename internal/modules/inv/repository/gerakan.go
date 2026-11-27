// repository/gerakan.go — SATU-SATUNYA pengguna sqlc+rawSQL fitur GERAKAN
// STOK modul inv (padanan repositories/operasi/gerakan.repository.ts +
// repositories/stok/recompute-saldo.repository.ts NestJS). Mapping BARIS →
// VIEW (GerakanStokView flat D-51) dan baris → tipe wrapper domain-friendly
// ikut repo — service TIDAK mengimpor gen sqlc (guard lapisan). Semua method
// menerima executor `gen.DBTX` (pool | tx) — service meneruskan tx transaksi
// bisnis yang sama (konfirmasi/batal/reservasi: repo + audit + outbox +
// recompute SATU tx). rawSQL saldo on-hand/dipesan, kandidat lot FEFO, dan
// recompute saldo VERBATIM dari sumber (tanpa konversi query-builder).
// Helper kecil memakai prefiks `gk` (pengaman kolisi package repository
// yang diisi fitur lain paralel); helper bersama reuse helpers.go /
// masterb_helpers.go / operasi_views.go.
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
)

// ErrSaldoOnHandNegatif — pelanggaran CHECK `ck_inv_saldo_on_hand` (23514)
// saat recompute inv_saldo_stok. KEPUTUSAN RATIFIKASI modul inv: dari alur
// GERAKAN dipetakan 409 INV-010 (bukan 500); dari alur PENYESUAIAN pemakai
// lain memetakan pesan panjang verbatim masing-masing (sentinel bersama).
var ErrSaldoOnHandNegatif = errors.New("inventory: saldo on-hand negatif (ck_inv_saldo_on_hand) saat recompute")

// Kontrak VIEW GerakanStokView (flat D-51) SATU SUMBER di operasi_views.go
// (dipakai bersama fitur picking/mutasi/penyesuaian — kunci JSON cermin
// packages/schemas inv/views.ts, guard G8). File ini memakai tipe tersebut.

// KandidatLotFefo — kandidat lot FEFO (D-31): {id, status} urut
// tanggal_kedaluwarsa ASC NULLS LAST, id ASC.
type KandidatLotFefo struct {
	ID     int64
	Status string
}

/* ------------------------------------------------------------------ */
/* Tipe wrapper (baris → domain-friendly; service bebas gen)            */
/* ------------------------------------------------------------------ */

// BarisHeaderGerakan — kolom header yang dipakai guard/mutasi service.
type BarisHeaderGerakan struct {
	ID               int64
	NomorDokumen     string
	Jenis            string
	Status           string
	Langkah          int32
	TotalLangkah     int32
	Reservasi        string
	KodeJenisOperasi *string
	IDLokasiSumber   *int64 // NULL = PENYESUAIAN (D-48)
	IDLokasiTujuan   *int64
	Version          int32
}

// BarisGerakan — pasangan detail + header hasil MuatBaris (muatRowLengkap).
type BarisGerakan struct {
	ID             int64
	IDInvProduk    int64
	IDInvLotSerial *int64
	IDInvUnitUkur  int64
	QtyDiminta     int32
	QtySelesai     int32
	IDLokasiSumber int64 // override baris (D-48); 0 = warisi header
	IDLokasiTujuan int64
	NilaiPersatuan *float64
	Version        int32
	Header         BarisHeaderGerakan
}

// HeaderGerakanBaru — nilai insert header create manual (query bersama
// operasi.sql: langkah/total default 1/1, entity_id_sumber NULL,
// tanggal_selesai NULL, penyusun = pelaksana).
type HeaderGerakanBaru struct {
	EntityID      string
	Nomor         string
	Jenis         string
	Status        string
	TanggalJadwal time.Time
	JenisSumber   string
	IDKetat       *int64 // pelaksana & penyusun (id > 0, selain itu NULL)
	Sumber        int64
	Tujuan        int64
}

// HeaderBackorderBaru — nilai insert header BACKORDER (CFG-INV-05).
type HeaderBackorderBaru struct {
	EntityID         string
	Nomor            string
	Jenis            string
	Status           string
	Langkah          int32
	TotalLangkah     int32
	TanggalJadwal    time.Time
	JenisSumber      string
	EntityIDSumber   string // nomor dokumen asal
	KodeJenisOperasi *string
	IDKetat          *int64
	Sumber           *int64 // warisi header asal (bisa NULL utk ADJ)
	Tujuan           *int64
}

// DetailGerakanBaru — nilai insert baris detail (override lokasi NULL —
// D-48 lokasi hidup di header).
type DetailGerakanBaru struct {
	EntityID       string
	IDHeader       int64
	IDProduk       int64
	IDLot          *int64
	IDUnit         int64
	QtyDiminta     int32
	QtySelesai     int32
	EntityIDSumber *string
}

// HeaderGerakanRow — hasil insert header (kolom yang dipakai service).
type HeaderGerakanRow struct {
	ID           int64
	NomorDokumen string
	Jenis        string
	Status       string
}

// DetailGerakanRow — hasil insert/update detail (kolom yang dipakai service).
type DetailGerakanRow struct {
	ID             int64
	IDInvProduk    int64
	IDInvLotSerial *int64
	IDInvUnitUkur  int64
	QtyDiminta     int32
	QtySelesai     int32
	IDLokasiSumber int64 // 0 = NULL (warisi header)
	IDLokasiTujuan int64
	NilaiPersatuan *float64
	EntityIDSumber *string
	Version        int32
}

// DetailKonfirmasiUbah — set update baris saat konfirmasi (tanggal selesai
// NULL bila belum tuntas).
type DetailKonfirmasiUbah struct {
	ID             int64
	QtySelesai     int32
	IDLot          *int64
	NilaiSatuan    *string // toFixed(4) atau NULL
	TanggalSelesai *time.Time
	Version        int32
	UpdatedAt      time.Time
}

// HeaderHidupUbah — set parsial update header hidup (batal / reservasi):
// kolom NULL tidak diubah (padanan set parsial Drizzle via COALESCE narg).
type HeaderHidupUbah struct {
	ID        int64
	Status    string
	Alasan    *string
	Reservasi *string
	Version   int32
	UpdatedAt time.Time
}

// HeaderStatusUbah — derive status D-49 (tanggal selesai hanya saat
// SELESAI penuh).
type HeaderStatusUbah struct {
	ID             int64
	Status         string
	TanggalSelesai *time.Time
	UpdatedAt      time.Time
}

// LapisanBiayaBaru — insert lapisan FIFO inbound (qty_terpakai 0 via query
// bersama operasi.sql).
type LapisanBiayaBaru struct {
	EntityID          string
	IDProduk          int64
	IDLot             *int64
	NomorDokumenMasuk string
	TanggalMasuk      time.Time
	QtyMasuk          int32
	BiayaPersatuan    string // toFixed(4)
}

// LapisanFifoRow — baris lapisan FIFO utk konsumsi (D-27).
type LapisanFifoRow struct {
	ID             int64
	QtyMasuk       int32
	QtyTerpakai    int32
	BiayaPersatuan float64
}

// ProdukGerakanRow — kolom produk yang dipakai service gerakan.
type ProdukGerakanRow struct {
	ID           int64
	KodeProduk   string
	JejakStok    bool
	ReorderAktif bool
	StokMinimum  int32
	StokMaksimum *int64
}

// ProdukValuasiRow — kolom valuasi produk (kategori + harga_biaya).
type ProdukValuasiRow struct {
	KategoriID int64
	HargaBiaya *float64
}

// KategoriValuasiRow — kebijakan pelacakan + metode valuasi kategori.
type KategoriValuasiRow struct {
	Pelacakan     string
	MetodeValuasi string
}

// LokasiGerakanRow — lokasi (id/kode/jenis).
type LokasiGerakanRow struct {
	ID    int64
	Kode  string
	Jenis string
}

// LotGerakanRow — kolom lot yang dipakai konfirmasi.
type LotGerakanRow struct {
	Kode   string
	Status string
}

// AggProgresHeader — {total, selesai, adaProgres} (D-49).
type AggProgresHeader struct {
	Total      int32
	Selesai    int32
	AdaProgres int32
}

// SaldoAggProduk — agregat readmodel {onHand, dipesan}.
type SaldoAggProduk struct {
	OnHand  int32
	Dipesan int32
}

// =====================================================================
// Repository
// =====================================================================

// GerakanRepository — wrapper sqlc+rawSQL area gerakan (tanpa state).
type GerakanRepository struct{}

// NewGerakanRepository membuat repository gerakan.
func NewGerakanRepository() *GerakanRepository { return &GerakanRepository{} }

// whitelistSortGerakan — drizzlePageBounds gerakan (verbatim): dua alias
// camelCase FE menunjuk kolom yang sama.
var whitelistSortGerakan = []string{
	"nomor_dokumen", "nomorDokumen",
	"tanggal_jadwal",
	"created_at", "createdAt",
	"updatedAt",
}

// kanonikSortGerakan — field sort → token kolom kanonik query (CASE).
var kanonikSortGerakan = map[string]string{
	"nomor_dokumen":  "nomor_dokumen",
	"nomorDokumen":   "nomor_dokumen",
	"tanggal_jadwal": "tanggal_jadwal",
	"created_at":     "created_at",
	"createdAt":      "created_at",
	"updatedAt":      "updated_at",
}

// gkSortToken — token sort pertama `kanonik:asc|desc` (” = default query).
func gkSortToken(pr *errkontrak.PageRequest) string {
	kolom, desc := mbSort(pr, kanonikSortGerakan)
	if kolom == "" {
		return ""
	}
	if desc {
		return kolom + ":desc"
	}
	return kolom + ":asc"
}

// List — daftar gerakan: halaman id (filter jenis/status/produk/gudang +
// search nomor) lalu muatView (persis alur repo NestJS).
func (r *GerakanRepository) List(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest) (errkontrak.Page[GerakanStokView], error) {
	if err := mbSortCek(pr, whitelistSortGerakan); err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	}
	params := gen.ListGerakanIdsParams{
		Jenis:    maTeksNihil(filterVal(pr, "jenis")),
		Status:   maTeksNihil(filterVal(pr, "status")),
		IDProduk: pgtype.Int8{},
		IDGudang: pgtype.Int8{},
		Search:   maTeksNihil(filterVal(pr, "search")),
		Sort:     gkSortToken(pr),
		Limit:    pageLimit(pr),
		Offset:   pageOffset(pr),
	}
	if v, err := filterNumVal(pr, "idProduk"); err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	} else {
		params.IDProduk = v
	}
	if v, err := filterNumVal(pr, "idGudang"); err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	} else {
		params.IDGudang = v
	}
	q := gen.New(exec)
	ids, err := q.ListGerakanIds(ctx, params)
	if err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	}
	total, err := q.CountGerakan(ctx, gen.CountGerakanParams{
		Jenis:    params.Jenis,
		Status:   params.Status,
		IDProduk: params.IDProduk,
		IDGudang: params.IDGudang,
		Search:   params.Search,
	})
	if err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	}
	views, err := r.MuatView(ctx, exec, ids)
	if err != nil {
		return errkontrak.Page[GerakanStokView]{}, err
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// MuatView — view FLAT utk sekumpulan id (join header + master + lokasi
// efektif D-48 + enrichment ADJ; ORDER id ASC; baris absen tidak ikut).
func (r *GerakanRepository) MuatView(ctx context.Context, exec gen.DBTX, ids []int64) ([]GerakanStokView, error) {
	out := []GerakanStokView{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := gen.New(exec).GerakanStokViewByIds(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, rw := range rows {
		out = append(out, gkPetaView(rw))
	}
	return out, nil
}

// MuatViewSatu — view satu id; nil bila absen (404 INV-018 di service).
func (r *GerakanRepository) MuatViewSatu(ctx context.Context, exec gen.DBTX, id int64) (*GerakanStokView, error) {
	rows, err := gen.New(exec).GerakanStokViewByIds(ctx, []int64{id})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	v := gkPetaView(rows[0])
	return &v, nil
}

// gkPetaView — baris GerakanStokViewByIds → view flat D-51 (mapper angka/iso
// verbatim inv.views.ts: angka() → number|null, iso/isoRequired → ISO-8601).
func gkPetaView(rw gen.GerakanStokViewByIdsRow) GerakanStokView {
	v := GerakanStokView{
		ID:               rw.ID,
		NomorDokumen:     rw.NomorDokumen,
		Jenis:            string(rw.JenisHeader),
		Status:           string(rw.StatusHeader),
		Langkah:          int(rw.Langkah),
		TotalLangkah:     int(rw.TotalLangkah),
		Reservasi:        string(rw.Reservasi),
		IDInvProduk:      rw.IDInvProduk,
		KodeProduk:       rw.KodeProduk,
		NamaProduk:       rw.NamaProduk,
		IDInvLotSerial:   maI8Ptr(rw.IDInvLotSerial),
		KodeLot:          maTxtPtr(rw.KodeLot),
		IDInvUnitUkur:    rw.IDInvUnitUkur,
		KodeUnit:         rw.KodeUnit,
		QtyDiminta:       int(rw.QtyDiminta),
		QtySelesai:       int(rw.QtySelesai),
		IDLokasiSumber:   int64(rw.IDLokasiSumberEfektif),
		KodeLokasiSumber: rw.KodeSumber,
		NamaLokasiSumber: rw.NamaSumber,
		IDLokasiTujuan:   int64(rw.IDLokasiTujuanEfektif),
		KodeLokasiTujuan: rw.KodeTujuan,
		NamaLokasiTujuan: rw.NamaTujuan,
		NilaiPersatuan:   maAngkaPtr(rw.NilaiPersatuan),
		TanggalJadwal:    maIso(rw.TanggalJadwal),
		TanggalSelesai:   opIsoPtr(rw.TanggalSelesai),
		JenisSumber:      rw.JenisSumber,
		EntityIDSumber:   maTxtPtr(rw.EntityIDSumber),
		Alasan:           maTxtPtr(rw.Alasan),
		JenisPenyesuaian: opNullEnumStr(rw.JenisPenyesuaian),
		QtySistem:        i4Int(maI4Ptr(rw.QtySistem)),
		QtyHitung:        i4Int(maI4Ptr(rw.QtyHitung)),
		QtySelisih:       i4Int(maI4Ptr(rw.QtySelisih)),
		Version:          rw.Version,
		CreatedAt:        maIso(rw.CreatedAt),
		UpdatedAt:        maIso(rw.UpdatedAt),
	}
	return v
}

// =====================================================================
// Guard baris & master pendukung
// =====================================================================

// MuatBaris — pasangan detail+header (muatRowLengkap); nil bila absen (404
// INV-018 diputuskan service).
func (r *GerakanRepository) MuatBaris(ctx context.Context, exec gen.DBTX, id int64) (*BarisGerakan, error) {
	row, err := gen.New(exec).MuatGerakanBaris(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	b := &BarisGerakan{
		ID:             row.ID,
		IDInvProduk:    row.IDInvProduk,
		IDInvLotSerial: maI8Ptr(row.IDInvLotSerial),
		IDInvUnitUkur:  row.IDInvUnitUkur,
		QtyDiminta:     row.QtyDiminta,
		QtySelesai:     row.QtySelesai,
		IDLokasiSumber: maAnyI8Val(row.IDLokasiSumber),
		IDLokasiTujuan: maAnyI8Val(row.IDLokasiTujuan),
		NilaiPersatuan: maAngkaPtr(row.NilaiPersatuan),
		Version:        row.Version,
		Header: BarisHeaderGerakan{
			ID:               row.HID,
			NomorDokumen:     row.HNomorDokumen,
			Jenis:            row.HJenis,
			Status:           row.HStatus,
			Langkah:          row.HLangkah,
			TotalLangkah:     row.HTotalLangkah,
			Reservasi:        row.HReservasi,
			KodeJenisOperasi: maTxtPtr(row.HKodeJenisOperasi),
			IDLokasiSumber:   maAnyI8(row.HIDLokasiSumber),
			IDLokasiTujuan:   maAnyI8(row.HIDLokasiTujuan),
			Version:          row.HVersion,
		},
	}
	return b, nil
}

// MuatProduk — produk hidup penuh by id (assertProduk & reorder M27); nil
// bila absen.
func (r *GerakanRepository) MuatProduk(ctx context.Context, exec gen.DBTX, id int64) (*ProdukGerakanRow, error) {
	row, err := gen.New(exec).MuatProdukHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &ProdukGerakanRow{
		ID:           row.ID,
		KodeProduk:   row.KodeProduk,
		JejakStok:    row.JejakStok,
		ReorderAktif: row.ReorderAktif,
		StokMinimum:  row.StokMinimum,
		StokMaksimum: gkI4PtrI64(row.StokMaksimum),
	}, nil
}

// MuatProdukValuasi — kolom valuasi produk (kategori + harga_biaya) hidup;
// nil bila absen.
func (r *GerakanRepository) MuatProdukValuasi(ctx context.Context, exec gen.DBTX, idProduk int64) (*ProdukValuasiRow, error) {
	row, err := gen.New(exec).MuatProdukValuasi(ctx, idProduk)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &ProdukValuasiRow{
		KategoriID: row.KategoriID,
		HargaBiaya: maAngkaPtr(row.HargaBiaya),
	}, nil
}

// UpdateProdukHargaBiaya — tulis balik harga_biaya produk hidup (AVCO D-28);
// hargaBiaya string toFixed(4) dari service.
func (r *GerakanRepository) UpdateProdukHargaBiaya(ctx context.Context, exec gen.DBTX, id int64, hargaBiaya string, updatedAt time.Time) error {
	return gen.New(exec).UpdateProdukHargaBiaya(ctx, gen.UpdateProdukHargaBiayaParams{
		HargaBiaya: gkNum(hargaBiaya),
		UpdatedAt:  maWaktu(updatedAt),
		ID:         id,
	})
}

// MuatKategoriValuasi — kebijakan pelacakan + metode valuasi kategori hidup;
// nil bila absen.
func (r *GerakanRepository) MuatKategoriValuasi(ctx context.Context, exec gen.DBTX, idKategori int64) (*KategoriValuasiRow, error) {
	row, err := gen.New(exec).MuatKategoriValuasi(ctx, idKategori)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &KategoriValuasiRow{
		Pelacakan:     row.Pelacakan,
		MetodeValuasi: row.MetodeValuasi,
	}, nil
}

// MuatLokasiStok — lokasi (id/kode/jenis) hidup by sekumpulan id.
func (r *GerakanRepository) MuatLokasiStok(ctx context.Context, exec gen.DBTX, ids []int64) ([]LokasiGerakanRow, error) {
	if len(ids) == 0 {
		return []LokasiGerakanRow{}, nil
	}
	rows, err := gen.New(exec).MuatLokasiStok(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]LokasiGerakanRow, 0, len(rows))
	for _, rw := range rows {
		out = append(out, LokasiGerakanRow{ID: rw.ID, Kode: rw.Kode, Jenis: rw.Jenis})
	}
	return out, nil
}

// MuatJenisLokasi — jenis lokasi TANPA filter deleted (verbatim PENYESUAIAN).
func (r *GerakanRepository) MuatJenisLokasi(ctx context.Context, exec gen.DBTX, ids []int64) ([]LokasiGerakanRow, error) {
	if len(ids) == 0 {
		return []LokasiGerakanRow{}, nil
	}
	rows, err := gen.New(exec).MuatJenisLokasi(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]LokasiGerakanRow, 0, len(rows))
	for _, rw := range rows {
		out = append(out, LokasiGerakanRow{ID: rw.ID, Jenis: rw.Jenis})
	}
	return out, nil
}

// MuatGudangIdLokasi — gudang pemilik lokasi; nil bila lokasi absen/NULL.
func (r *GerakanRepository) MuatGudangIdLokasi(ctx context.Context, exec gen.DBTX, idLokasi int64) (*int64, error) {
	v, err := gen.New(exec).MuatGudangIdLokasi(ctx, idLokasi)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return maI8Ptr(v), nil
}

// MuatLot — lot hidup by id; nil bila absen (404 INV-018 di service).
func (r *GerakanRepository) MuatLot(ctx context.Context, exec gen.DBTX, lotID int64) (*LotGerakanRow, error) {
	row, err := gen.New(exec).MuatLotById(ctx, lotID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &LotGerakanRow{Kode: row.Kode, Status: row.Status}, nil
}

// CariSerialTerpakai — serial terpakai gerakan keluar lain (INV-009); nil =
// aman.
func (r *GerakanRepository) CariSerialTerpakai(ctx context.Context, exec gen.DBTX, lotID, kecualiDetailID int64) (*int64, error) {
	id, err := gen.New(exec).CariSerialTerpakai(ctx, gen.CariSerialTerpakaiParams{
		LotID:           lotID,
		JenisKeluar:     []string{"PENGIRIMAN", "TRANSFER_INTERNAL", "SCRAP", "PRODUKSI"},
		KecualiDetailID: kecualiDetailID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &id, nil
}

// =====================================================================
// Saldo & FEFO — rawSQL VERBATIM (tanpa konversi query-builder)
// =====================================================================

// sqlSaldoOnHand — Σ gerakan SELESAI sisi internal (masuk di tujuan, keluar
// di sumber; lokasi efektif D-48) utk (produk, lot ±) pada satu lokasi —
// tanpa menyentuh READMODEL (konsisten recompute).
const sqlSaldoOnHand = `
      SELECT COALESCE(SUM(CASE
        WHEN COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan) = $1 THEN g.qty_selesai
        WHEN COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber) = $1 THEN -g.qty_selesai
        ELSE 0 END), 0)::int AS on_hand
      FROM inv_gerakan_stok g
      JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
      JOIN inv_lokasi_stok lt ON lt.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)
      JOIN inv_lokasi_stok ls ON ls.id = COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)
      WHERE g.id_inv_produk = $2
        AND h.status = 'SELESAI' AND g.deleted_at IS NULL AND h.deleted_at IS NULL
        AND (lt.jenis = 'INTERNAL' OR ls.jenis = 'INTERNAL')
        AND (g.id_inv_lot_serial IS NOT DISTINCT FROM $3)
`

// SaldoCukup — on-hand Σ SELESAI ± INTERNAL ≥ butuhQty? (INV-010).
func (r *GerakanRepository) SaldoCukup(ctx context.Context, exec gen.DBTX, idLokasi, idProduk int64, idLot *int64, butuhQty int64) (bool, error) {
	var onHand int32
	if err := exec.QueryRow(ctx, sqlSaldoOnHand, idLokasi, idProduk, idLot).Scan(&onHand); err != nil {
		return false, err
	}
	return int64(onHand) >= butuhQty, nil
}

// CariKandidatLotFefo — kandidat lot FEFO (D-31): join READMODEL saldo per
// lot di lokasi sumber, qty_on_hand > 0, ORDER tanggal_kedaluwarsa ASC NULLS
// LAST, id ASC. Penyaringan CFG-INV-02 BLOKIR dilakukan service.
func (r *GerakanRepository) CariKandidatLotFefo(ctx context.Context, exec gen.DBTX, idLokasiSumber, idProduk int64) ([]KandidatLotFefo, error) {
	rows, err := exec.Query(ctx, `
      SELECT lot.id::int AS id, lot.status::text AS status
      FROM inv_lot_serial lot
      JOIN inv_saldo_stok s ON s.id_inv_lot_serial = lot.id AND s.deleted_at IS NULL
      WHERE lot.id_inv_produk = $1
        AND lot.deleted_at IS NULL
        AND lot.status <> 'HABIS'
        AND s.qty_on_hand > 0
        AND s.id_inv_lokasi_stok = $2
      ORDER BY lot.tanggal_kedaluwarsa ASC NULLS LAST, lot.id ASC
	`, idProduk, idLokasiSumber)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []KandidatLotFefo{}
	for rows.Next() {
		var k KandidatLotFefo
		var id int32
		if err := rows.Scan(&id, &k.Status); err != nil {
			return nil, err
		}
		k.ID = int64(id)
		out = append(out, k)
	}
	return out, rows.Err()
}

// SaldoOnHandInternal — saldo on-hand produk pada SATU lokasi internal
// (semantik persis CTE `masuk` recompute, termasuk filter lokasi hidup).
func (r *GerakanRepository) SaldoOnHandInternal(ctx context.Context, exec gen.DBTX, idLokasi, idProduk int64) (int64, error) {
	var n int32
	err := exec.QueryRow(ctx, `
      SELECT COALESCE(SUM(g.qty_selesai), 0)::int AS n
      FROM inv_gerakan_stok g
      JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
      JOIN inv_lokasi_stok lt ON lt.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)
      WHERE COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan) = $1
        AND g.id_inv_produk = $2
        AND h.status = 'SELESAI' AND g.deleted_at IS NULL AND h.deleted_at IS NULL
        AND lt.deleted_at IS NULL
        AND lt.jenis = 'INTERNAL'
	`, idLokasi, idProduk).Scan(&n)
	if err != nil {
		return 0, err
	}
	return int64(n), nil
}

// SaldoEfektifReservasi — on-hand − dipesan DOKUMEN LAIN (D-29): dipesan =
// dokumen keluar/pindah terbuka TERJADWAL/SEBAGIAN ATAU TERRESERVASI pada
// (lokasi sumber, produk, lot), header ≠ dokumen ini.
func (r *GerakanRepository) SaldoEfektifReservasi(ctx context.Context, exec gen.DBTX, idLokasi, idProduk int64, idLot *int64, kecualiHeaderID int64) (int64, error) {
	var onHand int32
	if err := exec.QueryRow(ctx, sqlSaldoOnHand, idLokasi, idProduk, idLot).Scan(&onHand); err != nil {
		return 0, err
	}
	var dipesan int32
	err := exec.QueryRow(ctx, `
      SELECT COALESCE(SUM(g.qty_diminta - g.qty_selesai), 0)::int AS n
      FROM inv_gerakan_stok g
      JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
      WHERE COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber) = $1
        AND g.id_inv_produk = $2
        AND g.deleted_at IS NULL AND h.deleted_at IS NULL
        AND h.id <> $3
        AND h.jenis IN ('PENGIRIMAN', 'TRANSFER_INTERNAL', 'SCRAP', 'PRODUKSI')
        AND (h.status IN ('TERJADWAL', 'SEBAGIAN') OR h.reservasi = 'TERRESERVASI')
        AND (g.id_inv_lot_serial IS NOT DISTINCT FROM $4)
	`, idLokasi, idProduk, kecualiHeaderID, idLot).Scan(&dipesan)
	if err != nil {
		return 0, err
	}
	return int64(onHand) - int64(dipesan), nil
}

// =====================================================================
// Tulis — header / detail / lapisan FIFO
// =====================================================================

// InsertHeaderCreate — header gerakan create manual (query bersama
// operasi.sql; nilai dibangun service).
func (r *GerakanRepository) InsertHeaderCreate(ctx context.Context, exec gen.DBTX, p HeaderGerakanBaru) (HeaderGerakanRow, error) {
	row, err := gen.New(exec).InsertGerakanHeader(ctx, gen.InsertGerakanHeaderParams{
		EntityID:            gkUUID(p.EntityID),
		NomorDokumen:        p.Nomor,
		Jenis:               gen.EnumJenisGerakan(p.Jenis),
		Status:              gen.EnumStatusGerakan(p.Status),
		TanggalJadwal:       maWaktu(p.TanggalJadwal),
		TanggalSelesai:      pgtype.Timestamptz{},
		JenisSumber:         p.JenisSumber,
		IDCoreUsers:         maI8Nilai(p.IDKetat),
		IDCoreUsersPenyusun: maI8Nilai(p.IDKetat),
		IDLokasiSumber:      pgtype.Int8{Int64: p.Sumber, Valid: true},
		IDLokasiTujuan:      pgtype.Int8{Int64: p.Tujuan, Valid: true},
	})
	if err != nil {
		return HeaderGerakanRow{}, err
	}
	return HeaderGerakanRow{
		ID:           row.ID,
		NomorDokumen: row.NomorDokumen,
		Jenis:        string(row.Jenis),
		Status:       string(row.Status),
	}, nil
}

// InsertHeaderBackorder — header dokumen BACKORDER (CFG-INV-05).
func (r *GerakanRepository) InsertHeaderBackorder(ctx context.Context, exec gen.DBTX, p HeaderBackorderBaru) (HeaderGerakanRow, error) {
	row, err := gen.New(exec).InsertGerakanHeaderBackorder(ctx, gen.InsertGerakanHeaderBackorderParams{
		EntityID:            gkUUID(p.EntityID),
		NomorDokumen:        p.Nomor,
		Jenis:               gen.EnumJenisGerakan(p.Jenis),
		Status:              gen.EnumStatusGerakan(p.Status),
		Langkah:             p.Langkah,
		TotalLangkah:        p.TotalLangkah,
		TanggalJadwal:       maWaktu(p.TanggalJadwal),
		JenisSumber:         p.JenisSumber,
		EntityIDSumber:      p.EntityIDSumber,
		KodeJenisOperasi:    maTeksNihil(p.KodeJenisOperasi),
		IDCoreUsers:         maI8Nilai(p.IDKetat),
		IDCoreUsersPenyusun: pgtype.Int8{},
		IDLokasiSumber:      maI8Nilai(p.Sumber),
		IDLokasiTujuan:      maI8Nilai(p.Tujuan),
	})
	if err != nil {
		return HeaderGerakanRow{}, err
	}
	return HeaderGerakanRow{
		ID:           row.ID,
		NomorDokumen: row.NomorDokumen,
		Jenis:        row.Jenis,
		Status:       row.Status,
	}, nil
}

// InsertDetail — baris detail gerakan (override lokasi NULL — D-48).
func (r *GerakanRepository) InsertDetail(ctx context.Context, exec gen.DBTX, p DetailGerakanBaru) (DetailGerakanRow, error) {
	row, err := gen.New(exec).InsertGerakanDetail(ctx, gen.InsertGerakanDetailParams{
		EntityID:           gkUUID(p.EntityID),
		IDInvGerakanHeader: p.IDHeader,
		IDInvProduk:        p.IDProduk,
		IDInvLotSerial:     maI8Nilai(p.IDLot),
		IDInvUnitUkur:      p.IDUnit,
		QtyDiminta:         p.QtyDiminta,
		QtySelesai:         p.QtySelesai,
		IDLokasiSumber:     pgtype.Int8{},
		IDLokasiTujuan:     pgtype.Int8{},
		EntityIDSumber:     maTeksNihil(p.EntityIDSumber),
	})
	if err != nil {
		return DetailGerakanRow{}, err
	}
	return gkPetaDetail(row), nil
}

// UpdateDetailKonfirmasi — qty/lot/nilai/tanggal_selesai + version+1; nil
// bila baris absen.
func (r *GerakanRepository) UpdateDetailKonfirmasi(ctx context.Context, exec gen.DBTX, p DetailKonfirmasiUbah) (*DetailGerakanRow, error) {
	row, err := gen.New(exec).UpdateGerakanDetailKonfirmasi(ctx, gen.UpdateGerakanDetailKonfirmasiParams{
		QtySelesai:     p.QtySelesai,
		IDInvLotSerial: maI8Nilai(p.IDLot),
		NilaiPersatuan: gkNumNihilStr(p.NilaiSatuan),
		TanggalSelesai: maWaktuNihil(p.TanggalSelesai),
		Version:        p.Version,
		UpdatedAt:      maWaktu(p.UpdatedAt),
		ID:             p.ID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	d := gkPetaDetail(gen.InsertGerakanDetailRow(row))
	return &d, nil
}

// UpdateHeaderHidup — status/alasan/reservasi + version (set parsial via
// narg — kolom NULL tidak diubah).
func (r *GerakanRepository) UpdateHeaderHidup(ctx context.Context, exec gen.DBTX, p HeaderHidupUbah) error {
	return gen.New(exec).UpdateGerakanHeaderHidup(ctx, gen.UpdateGerakanHeaderHidupParams{
		Status:    gen.EnumStatusGerakan(p.Status),
		Alasan:    maTeksNihil(p.Alasan),
		Reservasi: gkReservasiNihil(p.Reservasi),
		Version:   p.Version,
		UpdatedAt: maWaktu(p.UpdatedAt),
		ID:        p.ID,
	})
}

// UpdateHeaderStatus — derive status D-49 (where id saja — verbatim).
func (r *GerakanRepository) UpdateHeaderStatus(ctx context.Context, exec gen.DBTX, p HeaderStatusUbah) error {
	return gen.New(exec).UpdateGerakanHeaderStatus(ctx, gen.UpdateGerakanHeaderStatusParams{
		Status:         gen.EnumStatusGerakan(p.Status),
		TanggalSelesai: maWaktuNihil(p.TanggalSelesai),
		UpdatedAt:      maWaktu(p.UpdatedAt),
		ID:             p.ID,
	})
}

// InsertLapisanBiaya — lapisan FIFO inbound (qty_terpakai 0 — query bersama
// operasi.sql).
func (r *GerakanRepository) InsertLapisanBiaya(ctx context.Context, exec gen.DBTX, p LapisanBiayaBaru) error {
	var biaya pgtype.Numeric
	_ = biaya.ScanScientific(p.BiayaPersatuan)
	return gen.New(exec).InsertLapisanBiaya(ctx, gen.InsertLapisanBiayaParams{
		EntityID:          gkUUID(p.EntityID),
		IDInvProduk:       p.IDProduk,
		IDInvLotSerial:    maI8Nilai(p.IDLot),
		NomorDokumenMasuk: p.NomorDokumenMasuk,
		TanggalMasuk:      maWaktu(p.TanggalMasuk),
		QtyMasuk:          p.QtyMasuk,
		BiayaPersatuan:    biaya,
	})
}

// ListLapisanFifoKunci — lapisan FIFO belum habis FOR UPDATE, tertua dulu
// (tanggal_masuk, id); lot dicocokkan IS NOT DISTINCT FROM.
func (r *GerakanRepository) ListLapisanFifoKunci(ctx context.Context, exec gen.DBTX, idProduk int64, lotID *int64) ([]LapisanFifoRow, error) {
	rows, err := gen.New(exec).ListLapisanFifoKunci(ctx, gen.ListLapisanFifoKunciParams{
		IDInvProduk:    idProduk,
		IDInvLotSerial: maI8Nilai(lotID),
	})
	if err != nil {
		return nil, err
	}
	out := make([]LapisanFifoRow, 0, len(rows))
	for _, rw := range rows {
		out = append(out, LapisanFifoRow{
			ID:             rw.ID,
			QtyMasuk:       rw.QtyMasuk,
			QtyTerpakai:    rw.QtyTerpakai,
			BiayaPersatuan: gkNumFloat(rw.BiayaPersatuan),
		})
	}
	return out, nil
}

// TambahQtyTerpakaiLapisan — konsumsi lapisan FIFO (query bersama
// operasi.sql — qty_terpakai += qty, version +1).
func (r *GerakanRepository) TambahQtyTerpakaiLapisan(ctx context.Context, exec gen.DBTX, id int64, qty int32, sekarang time.Time) error {
	return gen.New(exec).TambahQtyTerpakaiLapisan(ctx, gen.TambahQtyTerpakaiLapisanParams{
		Qty:       qty,
		UpdatedAt: maWaktu(sekarang),
		ID:        id,
	})
}

// =====================================================================
// Agregat progres & reorder (M27)
// =====================================================================

// MuatAggProgresHeader — {total, selesai, adaProgres} (D-49, agg FILTER).
func (r *GerakanRepository) MuatAggProgresHeader(ctx context.Context, exec gen.DBTX, idHeader int64) (*AggProgresHeader, error) {
	row, err := gen.New(exec).MuatAggProgresHeader(ctx, idHeader)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &AggProgresHeader{Total: row.Total, Selesai: row.Selesai, AdaProgres: row.AdaProgres}, nil
}

// MuatSaldoAggProduk — agregat readmodel {onHand, dipesan} satu produk.
func (r *GerakanRepository) MuatSaldoAggProduk(ctx context.Context, exec gen.DBTX, idProduk int64) (*SaldoAggProduk, error) {
	row, err := gen.New(exec).MuatSaldoAggProduk(ctx, idProduk)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &SaldoAggProduk{OnHand: row.OnHand, Dipesan: row.Dipesan}, nil
}

// HitungOutboxReorderHariIni — idempoten per produk-periode (M27).
func (r *GerakanRepository) HitungOutboxReorderHariIni(ctx context.Context, exec gen.DBTX, idProduk int64) (int32, error) {
	return gen.New(exec).HitungOutboxReorderHariIni(ctx, strconvI64(idProduk))
}

// =====================================================================
// RecomputeSaldoStok — SATU-SATUNYA tempat recompute modul INV (EKSPOR;
// dipakai fitur inv lain & modul fnb/pos/kernel seed lewat sini). rawSQL
// VERBATIM repositories/stok/recompute-saldo.repository.ts — dua statement
// (TRUNCATE + INSERT..SELECT transaksional), aman dalam Tx pemanggil.
// =====================================================================

// sqlRecomputeTruncate — 1) kosongkan readmodel (satu-satunya TRUNCATE yang
// sah di modul INV).
const sqlRecomputeTruncate = `TRUNCATE TABLE inv_saldo_stok`

// sqlRecomputeInsert — 2) rebuild dari gerakan SELESAI (hanya baris hidup)
// ke lokasi INTERNAL; qty_dipesan = reservasi ATP (TERJADWAL/SEBAGIAN, patch
// 04 D-29: TERRESERVASI ikut); qty_tersedia = on_hand − dipesan; nilai
// persediaan = snapshot valuasi sisi masuk − keluar; baris agregat qty 0
// tidak dibangun (HAVING SUM<>0); CHECK ck_inv_saldo_on_hand menegakkan
// saldo >= 0 — gerakan minus melebihi saldo gagal keras di sini (INV-BR03).
const sqlRecomputeInsert = `
      INSERT INTO inv_saldo_stok (
        entity_id, id_inv_lokasi_stok, id_inv_produk, id_inv_lot_serial,
        qty_on_hand, qty_dipesan, qty_tersedia, nilai_persediaan,
        created_at, updated_at
      )
      WITH gerakan_selesai AS (
        SELECT COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber) AS id_lokasi_sumber,
               COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan) AS id_lokasi_tujuan,
               g.id_inv_produk, g.id_inv_lot_serial, g.qty_selesai,
               COALESCE(g.nilai_persatuan, 0) AS nilai_sat
        FROM inv_gerakan_stok g
        JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
        WHERE h.status = 'SELESAI' AND g.deleted_at IS NULL AND h.deleted_at IS NULL
      ),
      gerakan_terbuka AS (
        SELECT COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber) AS id_lokasi_sumber,
               g.id_inv_produk, g.id_inv_lot_serial,
               (g.qty_diminta - g.qty_selesai) AS qty_dipesan
        FROM inv_gerakan_stok g
        JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
        WHERE g.deleted_at IS NULL AND h.deleted_at IS NULL
          AND h.jenis IN ('PENGIRIMAN', 'TRANSFER_INTERNAL', 'SCRAP', 'PRODUKSI')
          AND (
            h.status IN ('TERJADWAL', 'SEBAGIAN')
            -- Patch 04 (D-29): reservasi picking mengunci stok — TERRESERVASI
            -- ikut dipesan (ATP konsisten: tersedia = on_hand − dipesan).
            OR h.reservasi = 'TERRESERVASI'
          )
      ),
      masuk AS (
        SELECT g.id_lokasi_tujuan AS lokasi, g.id_inv_produk, g.id_inv_lot_serial,
               g.qty_selesai AS qty, g.qty_selesai * g.nilai_sat AS nilai
        FROM gerakan_selesai g
        JOIN inv_lokasi_stok l ON l.id = g.id_lokasi_tujuan
        WHERE l.deleted_at IS NULL AND l.jenis = 'INTERNAL'
      ),
      keluar AS (
        SELECT g.id_lokasi_sumber AS lokasi, g.id_inv_produk, g.id_inv_lot_serial,
               -g.qty_selesai AS qty, -g.qty_selesai * g.nilai_sat AS nilai
        FROM gerakan_selesai g
        JOIN inv_lokasi_stok l ON l.id = g.id_lokasi_sumber
        WHERE l.deleted_at IS NULL AND l.jenis = 'INTERNAL'
      ),
      mutasi AS (
        SELECT lokasi, id_inv_produk, id_inv_lot_serial, qty, nilai FROM masuk
        UNION ALL
        SELECT lokasi, id_inv_produk, id_inv_lot_serial, qty, nilai FROM keluar
      ),
      saldo AS (
        SELECT lokasi, id_inv_produk, id_inv_lot_serial,
               SUM(qty) AS on_hand, SUM(nilai) AS nilai
        FROM mutasi
        GROUP BY 1, 2, 3
        HAVING SUM(qty) <> 0
      ),
      reservasi AS (
        SELECT t.id_lokasi_sumber AS lokasi, t.id_inv_produk, t.id_inv_lot_serial,
               SUM(t.qty_dipesan) AS dipesan
        FROM gerakan_terbuka t
        JOIN inv_lokasi_stok l ON l.id = t.id_lokasi_sumber
        WHERE l.deleted_at IS NULL AND l.jenis = 'INTERNAL'
        GROUP BY 1, 2, 3
      )
      SELECT
        gen_random_uuid(),
        s.lokasi,
        s.id_inv_produk,
        s.id_inv_lot_serial,
        s.on_hand,
        COALESCE(r.dipesan, 0),
        s.on_hand - COALESCE(r.dipesan, 0),
        s.nilai,
        now(),
        now()
      FROM saldo s
      LEFT JOIN reservasi r
        ON r.lokasi = s.lokasi
       AND r.id_inv_produk = s.id_inv_produk
       AND r.id_inv_lot_serial IS NOT DISTINCT FROM s.id_inv_lot_serial
`

// RecomputeSaldoStok — recompute penuh inv_saldo_stok dari gerakan SELESAI;
// return jumlah baris dibangun (rowCount INSERT..SELECT). Pelanggaran CHECK
// ck_inv_saldo_on_hand (23514) → ErrSaldoOnHandNegatif (pemetaan 409 di
// service pemanggil — keputusan ratifikasi modul inv).
func RecomputeSaldoStok(ctx context.Context, exec gen.DBTX) (int64, error) {
	// 1) Kosongkan readmodel — TRUNCATE tanpa rowCount.
	if _, err := exec.Exec(ctx, sqlRecomputeTruncate); err != nil {
		return 0, err
	}
	// 2) Rebuild — rowCount = baris saldo dibangun.
	tag, err := exec.Exec(ctx, sqlRecomputeInsert)
	if err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "23514" && pe.ConstraintName == "ck_inv_saldo_on_hand" {
			return 0, ErrSaldoOnHandNegatif
		}
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// =====================================================================
// Helper `gk` kecil (kolisi-aman dengan file fitur lain package ini)
// =====================================================================

// gkNum — string desimal (toFixed(4) service) → pgtype.Numeric.
func gkNum(s string) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.ScanScientific(s)
	return n
}

// gkNumNihilStr — *string → pgtype.Numeric (nil = NULL).
func gkNumNihilStr(v *string) pgtype.Numeric {
	if v == nil {
		return pgtype.Numeric{}
	}
	return gkNum(*v)
}

// gkNumFloat — pgtype.Numeric → float64 (NULL → 0; mapper angka0).
func gkNumFloat(v pgtype.Numeric) float64 {
	if p := maAngkaPtr(v); p != nil {
		return *p
	}
	return 0
}

// gkUUID — string uuid v4 → pgtype.UUID (reuse maUuidNilai).
func gkUUID(s string) pgtype.UUID { return maUuidNilai(s) }

// gkI4PtrI64 — pgtype.Int4 → *int64 (NULL → nil; stok_maksimum).
func gkI4PtrI64(v pgtype.Int4) *int64 {
	if !v.Valid {
		return nil
	}
	x := int64(v.Int32)
	return &x
}

// gkReservasiNihil — *string enum reservasi → NullEnumStatusReservasi.
func gkReservasiNihil(v *string) gen.NullEnumStatusReservasi {
	if v == nil {
		return gen.NullEnumStatusReservasi{}
	}
	return gen.NullEnumStatusReservasi{EnumStatusReservasi: gen.EnumStatusReservasi(*v), Valid: true}
}

// maWaktuNihil — *time.Time → pgtype.Timestamptz (nil = NULL).
func maWaktuNihil(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return maWaktu(*t)
}

// gkPetaDetail — baris detail gen → tipe wrapper DetailGerakanRow.
func gkPetaDetail(row gen.InsertGerakanDetailRow) DetailGerakanRow {
	// inv_gerakan_stok.id_lokasi_* NOT NULL di skema hidup — service memakai
	// nilai ini langsung (fallback header ?? hanya jaga bila DDL nullable).
	return DetailGerakanRow{
		ID:             row.ID,
		IDInvProduk:    row.IDInvProduk,
		IDInvLotSerial: maI8Ptr(row.IDInvLotSerial),
		IDInvUnitUkur:  row.IDInvUnitUkur,
		QtyDiminta:     row.QtyDiminta,
		QtySelesai:     row.QtySelesai,
		IDLokasiSumber: maAnyI8Val(row.IDLokasiSumber),
		IDLokasiTujuan: maAnyI8Val(row.IDLokasiTujuan),
		NilaiPersatuan: maAngkaPtr(row.NilaiPersatuan),
		EntityIDSumber: maTxtPtr(row.EntityIDSumber),
		Version:        row.Version,
	}
}
