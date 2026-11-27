// operasi_penyesuaian.go — repository fitur PENYESUAIAN STOK modul inv
// (padanan repositories/operasi/penyesuaian.repository.ts NestJS): dokumen
// `inv_penyesuaian_stok` + items (CRUD + REPLACE satu UoW), posting
// `inv_gerakan_header`/`inv_gerakan_stok` (konvensi lokasi ADJ-VIRTUAL),
// lapisan FIFO `inv_lapisan_biaya` (D-27 — SELECT … FOR UPDATE), master
// gudang/produk/kemasan/lokasi/lot/unit + resolver barcode terpadu (D-37).
// Nilai INSERT/UPDATE dibangun SERVICE (otoritas konversi kemasan ddl/54 di
// service); mapper view (kunci cermin views.ts) di sini.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository/gen"
	"nexierp/internal/modules/inv/types"
)

// PenyesuaianRepository — SATU-SATUNYA pengguna query inv operasi fitur
// penyesuaian.
type PenyesuaianRepository struct{}

// NewPenyesuaianRepository membuat repository penyesuaian.
func NewPenyesuaianRepository() *PenyesuaianRepository { return &PenyesuaianRepository{} }

// PenyesuaianListFilter — kriteria list (parsed service dari PageRequest).
type PenyesuaianListFilter struct {
	Status   *string
	Jenis    *string
	Search   *string
	SortCol  string // whitelist: kode|tanggal_dokumen|created_at|createdAt|updatedAt
	SortDesc bool
	Limit    int32
	Offset   int32
}

// KodeReferensi — cache kode produk/lot/lokasi/unit/kemasan hasil muatItems
// (bahan mapper view — padanan kode*Cache instance repo NestJS, di-Join di
// satu struct agar mapper murni).
type KodeReferensi struct {
	Produk  map[int64]string
	Lot     map[int64]string
	Lokasi  map[int64]string
	Unit    map[int64]string
	Kemasan map[int64]string
}

// MuatKodeReferensi — isi peta kode referensi utk sekumpulan item (query
// per jenis referensi — verbatim muatItems NestJS).
func (r *PenyesuaianRepository) MuatKodeReferensi(ctx context.Context, exec DBTX, items []gen.InvPenyesuaianStokItem) (*KodeReferensi, error) {
	g := gen.New(exec)
	ref := &KodeReferensi{
		Produk:  map[int64]string{},
		Lot:     map[int64]string{},
		Lokasi:  map[int64]string{},
		Unit:    map[int64]string{},
		Kemasan: map[int64]string{},
	}
	produkIDs := []int64{}
	lotIDs := []int64{}
	lokasiIDs := []int64{}
	unitIDs := []int64{}
	kemasanIDs := []int64{}
	for _, it := range items {
		produkIDs = appendUnikI64(produkIDs, it.IDInvProduk)
		if it.IDInvLotSerial.Valid {
			lotIDs = appendUnikI64(lotIDs, it.IDInvLotSerial.Int64)
		}
		lokasiIDs = appendUnikI64(lokasiIDs, it.IDInvLokasiStok)
		unitIDs = appendUnikI64(unitIDs, it.IDInvUnitUkur)
		if it.IDInvKemasan.Valid {
			kemasanIDs = appendUnikI64(kemasanIDs, it.IDInvKemasan.Int64)
		}
	}
	if len(produkIDs) > 0 {
		rows, err := g.KodeProdukByIds(ctx, produkIDs)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			ref.Produk[row.ID] = row.KodeProduk
		}
	}
	if len(lotIDs) > 0 {
		rows, err := g.KodeLotByIds(ctx, lotIDs)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			ref.Lot[row.ID] = row.Kode
		}
	}
	if len(lokasiIDs) > 0 {
		rows, err := g.KodeLokasiByIds(ctx, lokasiIDs)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			ref.Lokasi[row.ID] = row.Kode
		}
	}
	if len(unitIDs) > 0 {
		rows, err := g.KodeUnitByIds(ctx, unitIDs)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			ref.Unit[row.ID] = row.Kode
		}
	}
	if len(kemasanIDs) > 0 {
		rows, err := g.KodeKemasanByIds(ctx, kemasanIDs)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			ref.Kemasan[row.ID] = row.Kode
		}
	}
	return ref, nil
}

// appendUnikI64 — dedupe sederhana (set kecil — jumlah baris dokumen).
func appendUnikI64(s []int64, v int64) []int64 {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}

/* ------------------------------------------------------------------ */
/* Mapper header + items → PenyesuaianView (kunci cermin views.ts)      */
/* ------------------------------------------------------------------ */

// PenyesuaianToView — mapper header+items+ref → PenyesuaianView.
func PenyesuaianToView(
	id int64, kode, jenis, status string, idGudang int64,
	kodeGudang, namaGudang, tanggalDokumen string,
	namaPenyusun, namaPenyetuju, alasan *string,
	items []gen.InvPenyesuaianStokItem, ref *KodeReferensi,
	version int32, createdAt, updatedAt string,
) PenyesuaianView {
	views := make([]PenyesuaianItemView, 0, len(items))
	totalNilai := 0.0
	for _, i := range items {
		biaya := maAngkaPtr(i.BiayaSatuan)
		biayaF := 0.0
		if biaya != nil {
			biayaF = *biaya
		}
		var kodeLot *string
		var kodeKemasan *string
		if i.IDInvLotSerial.Valid {
			if k, ada := ref.Lot[i.IDInvLotSerial.Int64]; ada {
				kodeLot = &k
			}
		}
		if i.IDInvKemasan.Valid {
			if k, ada := ref.Kemasan[i.IDInvKemasan.Int64]; ada {
				kodeKemasan = &k
			}
		}
		views = append(views, PenyesuaianItemView{
			ID:              i.ID,
			IDInvProduk:     i.IDInvProduk,
			KodeProduk:      ref.Produk[i.IDInvProduk],
			NamaProduk:      i.NamaProduk,
			IDInvLotSerial:  maI8Ptr(i.IDInvLotSerial),
			KodeLot:         kodeLot,
			IDInvLokasiStok: i.IDInvLokasiStok,
			KodeLokasi:      ref.Lokasi[i.IDInvLokasiStok],
			IDInvUnitUkur:   i.IDInvUnitUkur,
			KodeUnit:        ref.Unit[i.IDInvUnitUkur],
			IDInvKemasan:    maI8Ptr(i.IDInvKemasan),
			KodeKemasan:     kodeKemasan,
			IsiPerKemasan:   i4Int(maI4Ptr(i.IsiPerKemasan)),
			QtySistem:       int(i.QtySistem),
			QtyHitung:       int(i.QtyHitung),
			QtySelisih:      int(i.QtySelisih),
			BiayaSatuan:     biaya,
			NilaiSelisih:    float64(i.QtySelisih) * biayaF,
		})
		totalNilai += float64(i.QtySelisih) * biayaF
	}
	// Gap kontrak: kolom alasan_keputusan tidak ada di DDL — jejak keputusan
	// (tolak/batal) menempati kolom `alasan` yang sama.
	var alasanKeputusan *string
	if status == "DITOLAK" || status == "DIBATALKAN" {
		alasanKeputusan = alasan
	}
	return PenyesuaianView{
		ID:                id,
		Kode:              kode,
		Jenis:             jenis,
		Status:            status,
		IDInvGudang:       idGudang,
		KodeGudang:        kodeGudang,
		NamaGudang:        namaGudang,
		TanggalDokumen:    tanggalDokumen,
		NamaPenyusun:      namaPenyusun,
		NamaPenyetuju:     namaPenyetuju,
		Alasan:            alasan,
		AlasanKeputusan:   alasanKeputusan,
		Items:             views,
		TotalNilaiSelisih: totalNilai,
		Version:           version,
		CreatedAt:         createdAt,
		UpdatedAt:         updatedAt,
	}
}

// i4Int — *int32 → *int (JSON number int).
func i4Int(v *int32) *int {
	if v == nil {
		return nil
	}
	n := int(*v)
	return &n
}

/* ------------------------------------------------------------------ */
/* Baca — list / detail                                                 */
/* ------------------------------------------------------------------ */

// ListPenyesuaian — halaman penyesuaian (filter status/jenis/search) —
// header + items (kelompok kecil) + kode gudang & nama penyusun/penyetuju.
func (r *PenyesuaianRepository) ListPenyesuaian(ctx context.Context, exec DBTX, f PenyesuaianListFilter) ([]PenyesuaianView, int, error) {
	g := gen.New(exec)
	p := gen.ListPenyesuaianParams{
		Status:   maTeksNihil(f.Status),
		Jenis:    maTeksNihil(f.Jenis),
		Search:   maTeksNihil(f.Search),
		SortCol:  f.SortCol,
		SortDesc: f.SortDesc,
		Limit:    f.Limit,
		Offset:   f.Offset,
	}
	rows, err := g.ListPenyesuaian(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountPenyesuaian(ctx, gen.CountPenyesuaianParams{Status: p.Status, Jenis: p.Jenis, Search: p.Search})
	if err != nil {
		return nil, 0, err
	}
	headerIDs := make([]int64, 0, len(rows))
	for _, row := range rows {
		headerIDs = append(headerIDs, row.ID)
	}
	items, ref, err := r.muatItemsDanRef(ctx, exec, headerIDs)
	if err != nil {
		return nil, 0, err
	}
	out := make([]PenyesuaianView, 0, len(rows))
	for _, row := range rows {
		out = append(out, PenyesuaianToView(
			row.ID, row.Kode, string(row.Jenis), string(row.Status), row.IDInvGudang,
			row.KodeGudang, row.NamaGudang, maIso(row.TanggalDokumen),
			maTxtPtr(row.NamaPenyusun), maTxtPtr(row.NamaPenyetuju), maTxtPtr(row.Alasan),
			items[row.ID], ref, row.Version, maIso(row.CreatedAt), maIso(row.UpdatedAt),
		))
	}
	return out, int(total), nil
}

// muatItemsDanRef — items per header + kode referensi (verbatim muatItems).
func (r *PenyesuaianRepository) muatItemsDanRef(ctx context.Context, exec DBTX, headerIDs []int64) (map[int64][]gen.InvPenyesuaianStokItem, *KodeReferensi, error) {
	perHeader := map[int64][]gen.InvPenyesuaianStokItem{}
	if len(headerIDs) == 0 {
		return perHeader, &KodeReferensi{Produk: map[int64]string{}, Lot: map[int64]string{}, Lokasi: map[int64]string{}, Unit: map[int64]string{}, Kemasan: map[int64]string{}}, nil
	}
	rows, err := gen.New(exec).PenyesuaianItemsHidupByHeader(ctx, headerIDs)
	if err != nil {
		return nil, nil, err
	}
	for _, it := range rows {
		perHeader[it.IDInvPenyesuaianStok] = append(perHeader[it.IDInvPenyesuaianStok], it)
	}
	ref, err := r.MuatKodeReferensi(ctx, exec, rows)
	if err != nil {
		return nil, nil, err
	}
	return perHeader, ref, nil
}

// MuatSatu — muat SATU penyesuaian lewat executor tertentu — WAJIB tx pada
// jalur mutasi (baris baru belum terlihat dari pool sebelum commit); 404
// INV-018 bila absen/terhapus (pesan verbatim).
func (r *PenyesuaianRepository) MuatSatu(ctx context.Context, exec DBTX, id int64) (PenyesuaianView, error) {
	rows, err := gen.New(exec).PenyesuaianDenganRefById(ctx, id)
	if err != nil {
		return PenyesuaianView{}, err
	}
	if len(rows) == 0 {
		return PenyesuaianView{}, errkontrak.NotFound(
			"Penyesuaian id "+strconvI64(id)+" tidak ditemukan.",
			domain.KodeInvTidakDitemukan,
		)
	}
	row := rows[0]
	items, ref, err := r.muatItemsDanRef(ctx, exec, []int64{id})
	if err != nil {
		return PenyesuaianView{}, err
	}
	return PenyesuaianToView(
		row.ID, row.Kode, string(row.Jenis), string(row.Status), row.IDInvGudang,
		row.KodeGudang, row.NamaGudang, maIso(row.TanggalDokumen),
		maTxtPtr(row.NamaPenyusun), maTxtPtr(row.NamaPenyetuju), maTxtPtr(row.Alasan),
		items[id], ref, row.Version, maIso(row.CreatedAt), maIso(row.UpdatedAt),
	), nil
}

// PenyesuaianHidupById — header hidup wajib ada — fail 404 INV (verbatim
// assertPenyesuaianById).
func (r *PenyesuaianRepository) PenyesuaianHidupById(ctx context.Context, exec DBTX, id int64) (gen.InvPenyesuaianStok, error) {
	row, err := gen.New(exec).PenyesuaianHidupById(ctx, id)
	if err != nil {
		return gen.InvPenyesuaianStok{}, err
	}
	return row, nil
}

// ItemsHidupByHeader — items hidup satu header (urut id) — bahan posting.
func (r *PenyesuaianRepository) ItemsHidupByHeader(ctx context.Context, exec DBTX, idHeader int64) ([]gen.InvPenyesuaianStokItem, error) {
	return gen.New(exec).PenyesuaianItemsHidupByHeader(ctx, []int64{idHeader})
}

/* ------------------------------------------------------------------ */
/* Master pendukung sisipItems                                          */
/* ------------------------------------------------------------------ */

// GudangHidupById — validasi create draft; nil bila absen/terhapus.
func (r *PenyesuaianRepository) GudangHidupById(ctx context.Context, exec DBTX, id int64) (*gen.InvGudang, error) {
	rows, err := gen.New(exec).GudangHidupById(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// ProdukDenganUnitHidupByIds — id/nama/unit dasar (snapshot & validasi kemasan).
func (r *PenyesuaianRepository) ProdukDenganUnitHidupByIds(ctx context.Context, exec DBTX, ids []int64) ([]gen.ProdukDenganUnitHidupByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.ProdukDenganUnitHidupByIdsRow{}, nil
	}
	return gen.New(exec).ProdukDenganUnitHidupByIds(ctx, ids)
}

// KemasanHidupByIds — master kemasan pemilik faktor konversi (ddl/54).
func (r *PenyesuaianRepository) KemasanHidupByIds(ctx context.Context, exec DBTX, ids []int64) ([]gen.KemasanHidupByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.KemasanHidupByIdsRow{}, nil
	}
	return gen.New(exec).KemasanHidupByIds(ctx, ids)
}

/* ------------------------------------------------------------------ */
/* Tulis — dokumen / items                                              */
/* ------------------------------------------------------------------ */

// InsertPenyesuaian — insert penyesuaian DRAFT (nilai dibangun service).
func (r *PenyesuaianRepository) InsertPenyesuaian(ctx context.Context, exec DBTX, p gen.InsertPenyesuaianParams) (gen.InvPenyesuaianStok, error) {
	return gen.New(exec).InsertPenyesuaian(ctx, p)
}

// UpdateDraft — ubah draft (jenis/tanggal/alasan/version).
func (r *PenyesuaianRepository) UpdateDraft(ctx context.Context, exec DBTX, p gen.UpdatePenyesuaianDraftParams) error {
	return gen.New(exec).UpdatePenyesuaianDraft(ctx, p)
}

// UpdateStatus — transisi status (penyetuju/alasan NULL = tidak disentuh —
// COALESCE keep; ajukan MENUNGGU/DISETUJUI-auto & keputusan & batal).
func (r *PenyesuaianRepository) UpdateStatus(ctx context.Context, exec DBTX, p gen.UpdatePenyesuaianStatusParams) error {
	return gen.New(exec).UpdatePenyesuaianStatus(ctx, p)
}

// SoftDeleteItemsHidupByHeader — langkah REPLACE draft.
func (r *PenyesuaianRepository) SoftDeleteItemsHidupByHeader(ctx context.Context, exec DBTX, idHeader int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeletePenyesuaianItemsByHeader(ctx, gen.SoftDeletePenyesuaianItemsByHeaderParams{
		DeletedAt: maWaktu(deletedAt),
		UpdatedAt: maWaktu(updatedAt),
		IDHeader:  idHeader,
	})
}

// InsertItem — sisip SATU baris item (otoritas konversi kemasan di service).
func (r *PenyesuaianRepository) InsertItem(ctx context.Context, exec DBTX, p gen.InsertPenyesuaianItemParams) error {
	return gen.New(exec).InsertPenyesuaianItem(ctx, p)
}

/* ------------------------------------------------------------------ */
/* Posting gerakan PENYESUAIAN + lapisan FIFO (D-27)                    */
/* ------------------------------------------------------------------ */

// LokasiHidupByKode — konvensi ADJ-VIRTUAL (kode dikirim pemanggil); nil
// bila tidak ada.
func (r *PenyesuaianRepository) LokasiHidupByKode(ctx context.Context, exec DBTX, kode string) (*gen.InvLokasiStok, error) {
	rows, err := gen.New(exec).LokasiHidupByKode(ctx, kode)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// RefValuasiProduk — metode kategori + fallback harga_biaya (hanya kategori
// FIFO diproses catatLapisanFifo); nil bila produk tidak ada.
func (r *PenyesuaianRepository) RefValuasiProduk(ctx context.Context, exec DBTX, idProduk int64) (*string, *float64, error) {
	rows, err := gen.New(exec).RefValuasiProduk(ctx, idProduk)
	if err != nil || len(rows) == 0 {
		return nil, nil, err
	}
	metode := string(rows[0].MetodeValuasi)
	return &metode, maAngkaPtr(rows[0].HargaBiaya), nil
}

// InsertLapisanBiaya — penyesuaian-plus melahirkan lapisan (nomor ADJ).
func (r *PenyesuaianRepository) InsertLapisanBiaya(ctx context.Context, exec DBTX, p gen.InsertLapisanBiayaParams) error {
	return gen.New(exec).InsertLapisanBiaya(ctx, p)
}

// LapisanFifoTerbuka — lapisan terbuka produk/lot TERLAMA dulu —
// SELECT … FOR UPDATE (konsumsi tertua D-27).
func (r *PenyesuaianRepository) LapisanFifoTerbuka(ctx context.Context, exec DBTX, idProduk int64, idLot *int64) ([]gen.InvLapisanBiaya, error) {
	return gen.New(exec).LapisanFifoTerbuka(ctx, gen.LapisanFifoTerbukaParams{
		IDProduk: idProduk,
		AdaLot:   idLot != nil,
		IDLot:    maI8Nilai(idLot).Int64,
	})
}

// TambahQtyTerpakaiLapisan — konsumsi lapisan FIFO (+version).
func (r *PenyesuaianRepository) TambahQtyTerpakaiLapisan(ctx context.Context, exec DBTX, idLapisan int64, qty int, at time.Time) error {
	return gen.New(exec).TambahQtyTerpakaiLapisan(ctx, gen.TambahQtyTerpakaiLapisanParams{
		Qty:       int32(qty),
		UpdatedAt: maWaktu(at),
		ID:        idLapisan,
	})
}

// SetNilaiPersatuanGerakan — nilai gerakan minus = rata-rata tertimbang
// lapisan (dihitung service, D-27).
func (r *PenyesuaianRepository) SetNilaiPersatuanGerakan(ctx context.Context, exec DBTX, idGerakan int64, nilai float64) error {
	return gen.New(exec).SetNilaiPersatuanGerakan(ctx, gen.SetNilaiPersatuanGerakanParams{
		Nilai: opNumeric(nilai),
		ID:    idGerakan,
	})
}

/* ------------------------------------------------------------------ */
/* Resolver barcode terpadu (D-37) — mode entri scanner                 */
/* ------------------------------------------------------------------ */

// toProdukLookup — baris barcode lookup → types.ProdukLookupView (harga
// numeric → number; mapper verbatim toProdukLookup).
func toProdukLookup(id int64, kodeProduk, nama, tipe string, idInduk pgtype.Int8, idUnit int64, kodeUnit string, hargaJual pgtype.Numeric, saldo int32) types.ProdukLookupView {
	return types.ProdukLookupView{
		ID:               id,
		KodeProduk:       kodeProduk,
		Nama:             nama,
		Tipe:             tipe,
		IDInvProdukInduk: maI8Ptr(idInduk),
		IDInvUnitUkur:    idUnit,
		KodeUnit:         kodeUnit,
		HargaJual:        maAngkaPtr(hargaJual),
		SaldoOnHand:      int(saldo),
	}
}

// ProdukByBarcode — resolve barcode → PRODUK (kartu induk; hidup); nil
// bila tidak cocok.
func (r *PenyesuaianRepository) ProdukByBarcode(ctx context.Context, exec DBTX, kode string) (*types.ProdukLookupView, error) {
	rows, err := gen.New(exec).ProdukByBarcode(ctx, maTeksNihil(&kode))
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	row := rows[0]
	v := toProdukLookup(row.ID, row.KodeProduk, row.Nama, string(row.Tipe), row.IDInvProdukInduk, row.IDInvUnitUkur, row.KodeUnit, row.HargaJual, row.SaldoOnHand)
	return &v, nil
}

// LotByBarcode — resolve barcode → LOT/serial (+ saldo lot hidup); nil
// bila tidak cocok.
func (r *PenyesuaianRepository) LotByBarcode(ctx context.Context, exec DBTX, kode string) (*types.ProdukLookupView, *BarcodeLotView, error) {
	rows, err := gen.New(exec).LotByBarcode(ctx, maTeksNihil(&kode))
	if err != nil || len(rows) == 0 {
		return nil, nil, err
	}
	row := rows[0]
	produk := toProdukLookup(row.ID, row.KodeProduk, row.Nama, string(row.Tipe), row.IDInvProdukInduk, row.IDInvUnitUkur, row.KodeUnit, row.HargaJual, row.SaldoOnHand)
	lot := &BarcodeLotView{
		ID:          row.LotID,
		Kode:        row.LotKode,
		Status:      string(row.LotStatus),
		SaldoOnHand: int(row.LotSaldo),
	}
	return &produk, lot, nil
}

// KemasanByBarcode — resolve barcode → KEMASAN (unit isi = unit dasar
// produk, ddl/54); nil bila tidak cocok.
func (r *PenyesuaianRepository) KemasanByBarcode(ctx context.Context, exec DBTX, kode string) (*types.ProdukLookupView, *BarcodeKemasanView, error) {
	rows, err := gen.New(exec).KemasanByBarcode(ctx, maTeksNihil(&kode))
	if err != nil || len(rows) == 0 {
		return nil, nil, err
	}
	row := rows[0]
	produk := toProdukLookup(row.ID, row.KodeProduk, row.Nama, string(row.Tipe), row.IDInvProdukInduk, row.IDInvUnitUkur, row.KodeUnit, row.HargaJual, row.SaldoOnHand)
	kemasan := &BarcodeKemasanView{
		ID:            row.KemasanID,
		Kode:          row.KemasanKode,
		Nama:          row.KemasanNama,
		QtyIsi:        int(row.KemasanIsi),
		IDInvUnitUkur: row.IDInvUnitUkur,
		KodeUnit:      row.KodeUnit,
	}
	return &produk, kemasan, nil
}
