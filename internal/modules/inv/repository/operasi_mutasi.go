// operasi_mutasi.go — repository fitur MUTASI BARANG modul inv (padanan
// repositories/operasi/mutasi.repository.ts NestJS): dokumen
// `inv_mutasi_dokumen` + `inv_mutasi_items` (CRUD + REPLACE items satu UoW),
// posting `inv_gerakan_header`/`inv_gerakan_stok` (idempoten
// uq_inv_gerakan_idempoten), mirror PUR read-only (`pur_penerimaan`,
// `pur_penerimaan_item`, `pur_pesanan`, `pur_pesanan_item`, `pur_pemasok` —
// BACA SAJA), lokasi/gudang/produk/unit/lot (master INV) + `core_users`.
// Nilai INSERT/UPDATE (kolom bisnis — status, version+1, snapshot nama
// produk, entityId) dibangun SERVICE. Pesan & kode error domain verbatim.
package repository

import (
	"context"
	"time"

	"nexierp/internal/modules/inv/repository/gen"
)

// MutasiRepository — SATU-SATUNYA pengguna query inv operasi fitur mutasi.
type MutasiRepository struct{}

// NewMutasiRepository membuat repository mutasi.
func NewMutasiRepository() *MutasiRepository { return &MutasiRepository{} }

// MutasiListFilter — kriteria list dokumen (disusun service dari
// PageRequest + keputusan cakupan 'storages' aktor).
type MutasiListFilter struct {
	Status   *string
	Jenis    []string // multi koma-terpisah sudah dipecah service (valid)
	Search   *string
	Cakupan  *CakupanStorages // nil = SEMUA (fail-open); Deny ditangani service
	SortCol  string           // whitelist: kode|tanggal|created_at|createdAt|updated_at|updatedAt
	SortDesc bool
	Limit    int32
	Offset   int32
}

/* ------------------------------------------------------------------ */
/* Mapper baris → view (dipakai repo & service)                         */
/* ------------------------------------------------------------------ */

// MutasiHeaderView — mapper header → view tanpa items (nama lokasi +
// jumlah posting diisi pemanggil).
func MutasiHeaderView(
	id int64, kode, jenis, status string,
	idSumber, idTujuan int64,
	tanggal, createdAt, updatedAt string,
	namaPenyusun, namaPenyetuju, alasan *string,
	version int32,
	idPurPenerimaan *int64, nomorGr, nomorPo *string,
) MutasiDokumenView {
	return MutasiDokumenView{
		ID:                     id,
		Kode:                   kode,
		Jenis:                  jenis,
		Status:                 status,
		IDLokasiSumber:         idSumber,
		NamaLokasiSumber:       "",
		IDLokasiTujuan:         idTujuan,
		NamaLokasiTujuan:       "",
		TanggalDokumen:         tanggal,
		NamaPenyusun:           namaPenyusun,
		NamaPenyetuju:          namaPenyetuju,
		Alasan:                 alasan,
		Items:                  []MutasiItemView{},
		JumlahGerakanDiposting: 0,
		IDPurPenerimaan:        idPurPenerimaan,
		NomorGr:                nomorGr,
		NomorPo:                nomorPo,
		Version:                version,
		CreatedAt:              createdAt,
		UpdatedAt:              updatedAt,
	}
}

/* ------------------------------------------------------------------ */
/* Baca — list / detail dokumen                                         */
/* ------------------------------------------------------------------ */

// ListDokumen — halaman dokumen mutasi (join endpoint sumber/tujuan PK +
// penyusun/penyetuju + jejak GR patch 59). Cakupan DAFTAR = sumber/tujuan
// IN ids gudang (party semantics); nil = SEMUA.
func (r *MutasiRepository) ListDokumen(ctx context.Context, exec DBTX, f MutasiListFilter) ([]MutasiDokumenView, int, error) {
	g := gen.New(exec)
	ids := []int64{}
	if f.Cakupan != nil {
		ids = f.Cakupan.IDs
	}
	Jenis := f.Jenis
	if Jenis == nil {
		Jenis = []string{}
	}
	p := gen.ListMutasiDokumenParams{
		Status:    maTeksNihil(f.Status),
		Jenis:     Jenis,
		Search:    maTeksNihil(f.Search),
		IdsGudang: ids,
		SortCol:   f.SortCol,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := g.ListMutasiDokumen(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountMutasiDokumen(ctx, gen.CountMutasiDokumenParams{
		Status:    p.Status,
		Jenis:     p.Jenis,
		Search:    p.Search,
		IdsGudang: p.IdsGudang,
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]MutasiDokumenView, 0, len(rows))
	for _, r := range rows {
		v := MutasiHeaderView(
			r.ID, r.Kode, string(r.Jenis), string(r.Status),
			r.IDLokasiSumber, r.IDLokasiTujuan,
			maIso(r.TanggalDokumen), maIso(r.CreatedAt), maIso(r.UpdatedAt),
			maTxtPtr(r.Penyusun), maTxtPtr(r.Penyetuju), maTxtPtr(r.Alasan),
			r.Version, maI8Ptr(r.IDPurPenerimaan), maTxtPtr(r.NomorGr), maTxtPtr(r.NomorPo),
		)
		v.NamaLokasiSumber = r.NamaSumber
		v.NamaLokasiTujuan = r.NamaTujuan
		out = append(out, v)
	}
	return out, int(total), nil
}

// HitungGerakanDipostingPerKode — jumlah gerakan terposting per dokumen
// (jenis_sumber MUTASI/GR-PO — patch 59).
func (r *MutasiRepository) HitungGerakanDipostingPerKode(ctx context.Context, exec DBTX, kodes []string) (map[string]int, error) {
	rows, err := gen.New(exec).HitungGerakanDipostingPerKode(ctx, kodes)
	if err != nil {
		return nil, err
	}
	out := make(map[string]int, len(rows))
	for _, row := range rows {
		out[row.Nomor] = int(row.N)
	}
	return out, nil
}

// MutasiDokumenDenganRef — detail dokumen + referensi join; nil bila absen.
func (r *MutasiRepository) MutasiDokumenDenganRef(ctx context.Context, exec DBTX, id int64) (*gen.MutasiDokumenDenganRefByIdRow, error) {
	rows, err := gen.New(exec).MutasiDokumenDenganRefById(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	return &rows[0], nil
}

// DokumenHidupById — header dokumen hidup wajib ada — fail 404 INV
// (pesan verbatim assertDokumenById).
func (r *MutasiRepository) DokumenHidupById(ctx context.Context, exec DBTX, id int64) (gen.InvMutasiDokuman, error) {
	row, err := gen.New(exec).MutasiDokumenHidupById(ctx, id)
	if err != nil {
		return gen.InvMutasiDokuman{}, err
	}
	return row, nil
}

// GudangLokasiPasangan — gudang dari pasangan lokasi (sumber, tujuan) —
// bahan keputusan cakupan "party semantics"; lokasi virtual → NULL.
func (r *MutasiRepository) GudangLokasiPasangan(ctx context.Context, exec DBTX, idSumber, idTujuan int64) ([]*int64, error) {
	rows, err := gen.New(exec).GudangLokasiPasangan(ctx, []int64{idSumber, idTujuan})
	if err != nil {
		return nil, err
	}
	out := make([]*int64, 0, len(rows))
	for _, gd := range rows {
		out = append(out, maI8Ptr(gd))
	}
	return out, nil
}

// ItemsHidupByDokumen — items hidup dokumen (urut id) — bahan posting.
func (r *MutasiRepository) ItemsHidupByDokumen(ctx context.Context, exec DBTX, idDokumen int64) ([]gen.InvMutasiItem, error) {
	return gen.New(exec).MutasiItemsHidupByDokumen(ctx, idDokumen)
}

// MutasiItemBaris — baris item view ber-join kode produk/lot/unit.
func (r *MutasiRepository) MutasiItemBaris(ctx context.Context, exec DBTX, idDokumen int64) ([]gen.MutasiItemBarisByDokumenRow, error) {
	return gen.New(exec).MutasiItemBarisByDokumen(ctx, idDokumen)
}

// HitungGerakanDipostingNomor — jumlah gerakan terposting SATU dokumen.
func (r *MutasiRepository) HitungGerakanDipostingNomor(ctx context.Context, exec DBTX, nomorDokumen string) (int, error) {
	n, err := gen.New(exec).HitungGerakanDipostingNomor(ctx, nomorDokumen)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HargaSatuanPoBaris — baris mentah harga PO per item mutasi (patch 59) —
// net/faktor dihitung service (SUMBER TUNGGAL view & posting).
func (r *MutasiRepository) HargaSatuanPoBaris(ctx context.Context, exec DBTX, itemIds []int64) ([]gen.HargaSatuanPoBarisRow, error) {
	if len(itemIds) == 0 {
		return []gen.HargaSatuanPoBarisRow{}, nil
	}
	return gen.New(exec).HargaSatuanPoBaris(ctx, itemIds)
}

/* ------------------------------------------------------------------ */
/* Generate dari GR PUR (patch 59) — mirror PUR baca-saja               */
/* ------------------------------------------------------------------ */

// ListGrEligible — daftar GR PUR eligible (DITERIMA, belum dimutasi,
// minimal 1 baris non-TOLAK).
func (r *MutasiRepository) ListGrEligible(ctx context.Context, exec DBTX) ([]GrEligibleView, error) {
	rows, err := gen.New(exec).ListGrEligible(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]GrEligibleView, 0, len(rows))
	for _, row := range rows {
		tanggal := (*string)(nil)
		if row.TanggalTerima.Valid {
			s := maIso(row.TanggalTerima)
			tanggal = &s
		}
		out = append(out, GrEligibleView{
			IDPurPenerimaan: row.IDPurPenerimaan,
			NomorGr:         row.NomorGr,
			NomorPo:         row.NomorPo,
			NamaPemasok:     row.NamaPemasok,
			KodeGudang:      maTxtPtr(row.KodeGudang),
			TanggalTerima:   tanggal,
			TotalQty:        int(row.TotalQty),
			JumlahBaris:     int(row.JumlahBaris),
		})
	}
	return out, nil
}

// GrDenganPoById — GR PUR by id + nomor PO + gudang PO; nil bila absen.
func (r *MutasiRepository) GrDenganPoById(ctx context.Context, exec DBTX, id int64) (*gen.GrDenganPoByIdRow, error) {
	rows, err := gen.New(exec).GrDenganPoById(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	return &rows[0], nil
}

// MutasiHidupByGrId — pre-check 1 GR = 1 mutasi hidup; nil bila bebas.
func (r *MutasiRepository) MutasiHidupByGrId(ctx context.Context, exec DBTX, idGr int64) (*gen.MutasiHidupByGrIdRow, error) {
	rows, err := gen.New(exec).MutasiHidupByGrId(ctx, idGr)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	return &rows[0], nil
}

// PenerimaanItemsHidup — seluruh baris GR hidup (filter non-TOLAK di service).
func (r *MutasiRepository) PenerimaanItemsHidup(ctx context.Context, exec DBTX, idGr int64) ([]gen.PurPenerimaanItem, error) {
	return gen.New(exec).PenerimaanItemsHidup(ctx, idGr)
}

// LokasiVendorPertama — sumber mutasi dari GR; nil bila tidak ada.
func (r *MutasiRepository) LokasiVendorPertama(ctx context.Context, exec DBTX) (*int64, error) {
	rows, err := gen.New(exec).LokasiVendorPertama(ctx)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	id := rows[0]
	return &id, nil
}

// LokasiHidupById — pilihan tujuan manual dariGr; nil bila absen.
func (r *MutasiRepository) LokasiHidupById(ctx context.Context, exec DBTX, id int64) (*int64, error) {
	rows, err := gen.New(exec).LokasiHidupById(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	idOut := rows[0]
	return &idOut, nil
}

// LokasiInternalPertamaGudang — tujuan default dariGr (gudang GR ?? PO).
func (r *MutasiRepository) LokasiInternalPertamaGudang(ctx context.Context, exec DBTX, idGudang int64) (*int64, error) {
	rows, err := gen.New(exec).LokasiInternalPertamaGudang(ctx, idGudang)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	id := rows[0]
	return &id, nil
}

// KodeGudangById — label pesan INV-021 dariGr; nil bila absen.
func (r *MutasiRepository) KodeGudangById(ctx context.Context, exec DBTX, id int64) (*string, error) {
	rows, err := gen.New(exec).KodeGudangById(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// PesananItemsByIds — baris PO item by set id (konversi PUR-BR16).
func (r *MutasiRepository) PesananItemsByIds(ctx context.Context, exec DBTX, ids []int64) ([]gen.PurPesananItem, error) {
	if len(ids) == 0 {
		return []gen.PurPesananItem{}, nil
	}
	return gen.New(exec).PesananItemsByIds(ctx, ids)
}

// ProdukRingkasHidupByIds — id/nama/unit dasar (validasi referensi dariGr).
func (r *MutasiRepository) ProdukRingkasHidupByIds(ctx context.Context, exec DBTX, ids []int64) ([]gen.ProdukRingkasHidupByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.ProdukRingkasHidupByIdsRow{}, nil
	}
	return gen.New(exec).ProdukRingkasHidupByIds(ctx, ids)
}

// FaktorKonversiPasangan — faktor konversi antar unit (PUR-BR16 dieksekusi
// INV); pasangan via array paralel (dari[i] → ke[i]).
func (r *MutasiRepository) FaktorKonversiPasangan(ctx context.Context, exec DBTX, dari, ke []int64) ([]gen.FaktorKonversiPasanganRow, error) {
	if len(dari) == 0 {
		return []gen.FaktorKonversiPasanganRow{}, nil
	}
	return gen.New(exec).FaktorKonversiPasangan(ctx, gen.FaktorKonversiPasanganParams{Dari: dari, Ke: ke})
}

// NamaProdukHidupByIds — snapshot nama + validasi referensi sisipItems.
func (r *MutasiRepository) NamaProdukHidupByIds(ctx context.Context, exec DBTX, ids []int64) ([]gen.NamaProdukHidupByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.NamaProdukHidupByIdsRow{}, nil
	}
	return gen.New(exec).NamaProdukHidupByIds(ctx, ids)
}

/* ------------------------------------------------------------------ */
/* Tulis — dokumen / items / posting gerakan                            */
/* ------------------------------------------------------------------ */

// InsertDokumen — insert dokumen (DRAFT; nilai dibangun service) → baris.
func (r *MutasiRepository) InsertDokumen(ctx context.Context, exec DBTX, p gen.InsertMutasiDokumenParams) (gen.InvMutasiDokuman, error) {
	return gen.New(exec).InsertMutasiDokumen(ctx, p)
}

// UpdateDraft — ubah DRAFT (jenis/lokasi/tanggal/alasan/version).
func (r *MutasiRepository) UpdateDraft(ctx context.Context, exec DBTX, p gen.UpdateMutasiDraftParams) (gen.InvMutasiDokuman, error) {
	return gen.New(exec).UpdateMutasiDraft(ctx, p)
}

// UpdateStatus — transisi status (ajukan MENUNGGU/DISETUJUI).
func (r *MutasiRepository) UpdateStatus(ctx context.Context, exec DBTX, p gen.UpdateMutasiStatusParams) (gen.InvMutasiDokuman, error) {
	return gen.New(exec).UpdateMutasiStatus(ctx, p)
}

// UpdateKeputusan — keputusan approval (SETUJUI/TOLAK + penyetuju + alasan).
func (r *MutasiRepository) UpdateKeputusan(ctx context.Context, exec DBTX, p gen.UpdateMutasiKeputusanParams) (gen.InvMutasiDokuman, error) {
	return gen.New(exec).UpdateMutasiKeputusan(ctx, p)
}

// UpdateBatal — batal draft/pengajuan (status DIBATALKAN + alasan).
func (r *MutasiRepository) UpdateBatal(ctx context.Context, exec DBTX, p gen.UpdateMutasiBatalParams) (gen.InvMutasiDokuman, error) {
	return gen.New(exec).UpdateMutasiBatal(ctx, p)
}

// SoftDeleteDokumen — hapus DRAFT lunak (header — jejak tetap ada).
func (r *MutasiRepository) SoftDeleteDokumen(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteMutasiDokumen(ctx, gen.SoftDeleteMutasiDokumenParams{
		DeletedAt: maWaktu(deletedAt),
		UpdatedAt: maWaktu(updatedAt),
		ID:        id,
	})
}

// SoftDeleteItemsHidupByDokumen — hapus lunak SEMUA items dokumen.
func (r *MutasiRepository) SoftDeleteItemsHidupByDokumen(ctx context.Context, exec DBTX, idDokumen int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteMutasiItemsByDokumen(ctx, gen.SoftDeleteMutasiItemsByDokumenParams{
		DeletedAt: maWaktu(deletedAt),
		UpdatedAt: maWaktu(updatedAt),
		IDDokumen: idDokumen,
	})
}

// InsertItem — sisip SATU item dokumen (snapshot nama dibangun service).
func (r *MutasiRepository) InsertItem(ctx context.Context, exec DBTX, p gen.InsertMutasiItemParams) error {
	return gen.New(exec).InsertMutasiItem(ctx, p)
}
