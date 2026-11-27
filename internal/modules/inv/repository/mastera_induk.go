// mastera_induk.go — wrapper sqlc fitur PRODUK INDUK modul inv (padanan
// ProdukIndukRepository NestJS — patch 06 hierarki mandiri D-42): induk =
// baris inv_produk sendiri; list paginated + jumlah varian, guard induk,
// REPLACE konfigurasi atribut LINE inv_produk_varian_konfig (soft delete
// lama + sisip baru satu UoW), bump version TANPA filter hidup (verbatim),
// generate varian + junction nilai, muat konfigurasi/kategori/unit.
package repository

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
	"nexierp/internal/modules/inv/types"
)

// KonfigurasiAtributInduk — baris konfigurasi atribut induk (LINE hidup).
type KonfigurasiAtributInduk struct {
	IDInvAtribut int64
	KodeAtribut  string
	NamaAtribut  string
	Wajib        bool
	Urutan       int32
}

// KonfigBaru — satu baris insert inv_produk_varian_konfig (service isi).
type KonfigBaru struct {
	EntityID     string
	IDInvProduk  int64
	IDInvAtribut int64
	Wajib        bool
	Urutan       int32
}

// IndukUbahSet — nilai update induk (set dibangun service).
type IndukUbahSet struct {
	Nama                string
	Keterangan          *string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	Status              string
	Version             int32
	UpdatedAt           time.Time
}

// ProdukIndukRepository — wrapper sqlc fitur produk-induk.
type ProdukIndukRepository struct{}

// NewProdukInduk — konstruksi tanpa state.
func NewProdukInduk() *ProdukIndukRepository { return &ProdukIndukRepository{} }

/* ------------------------------------------------------------------ */
/* Konversi baris gen → ProdukRow + mapper view                        */
/* ------------------------------------------------------------------ */

func dariListIndukRow(r gen.ListProdukIndukRow) ProdukRow {
	return ProdukRow{
		ID:                  r.ID,
		KodeProduk:          r.KodeProduk,
		Nama:                r.Nama,
		Tipe:                string(r.Tipe),
		IDInvKategoriProduk: r.IDInvKategoriProduk,
		IDInvUnitUkur:       r.IDInvUnitUkur,
		IDInvProdukInduk:    maI8Ptr(r.IDInvProdukInduk),
		KunciKombinasi:      maTxtPtr(r.KunciKombinasi),
		AdalahIndukVarian:   r.AdalahIndukVarian,
		JejakStok:           r.JejakStok,
		Barcode:             maTxtPtr(r.Barcode),
		HargaJual:           maNumericTeksis(r.HargaJual),
		HargaBiaya:          maNumericTeksis(r.HargaBiaya),
		StokMinimum:         r.StokMinimum,
		StokMaksimum:        maI4Ptr(r.StokMaksimum),
		ReorderAktif:        r.ReorderAktif,
		BeratGram:           maI4Ptr(r.BeratGram),
		VolumeCm3:           maI4Ptr(r.VolumeCm3),
		Keterangan:          maTxtPtr(r.Keterangan),
		Status:              string(r.Status),
		Version:             r.Version,
		CreatedAt:           r.CreatedAt.Time,
		UpdatedAt:           r.UpdatedAt.Time,
	}
}

// ProdukIndukToView — padanan produkIndukToView (kunci cermin views.ts).
func ProdukIndukToView(row ProdukRow, jumlahVarian int, atribut []KonfigurasiAtributInduk, kategori, unit map[int64]string) types.ProdukIndukView {
	list := make([]types.IndukAtributView, 0, len(atribut))
	for _, a := range atribut {
		list = append(list, types.IndukAtributView{
			IDInvAtribut: a.IDInvAtribut, KodeAtribut: a.KodeAtribut,
			NamaAtribut: a.NamaAtribut, Wajib: a.Wajib, Urutan: a.Urutan,
		})
	}
	return types.ProdukIndukView{
		ID:   row.ID,
		Kode: row.KodeProduk,
		Nama: row.Nama,
		// deskripsi induk hidup di kolom keterangan produk (patch 06).
		Deskripsi:           row.Keterangan,
		IDInvKategoriProduk: row.IDInvKategoriProduk,
		NamaKategori:        kategori[row.IDInvKategoriProduk],
		IDInvUnitUkur:       row.IDInvUnitUkur,
		KodeUnit:            unit[row.IDInvUnitUkur],
		HargaJual:           maAngkaStrPtr(row.HargaJual),
		HargaBiaya:          maAngkaStrPtr(row.HargaBiaya),
		StokMinimum:         row.StokMinimum,
		Status:              row.Status,
		JumlahVarian:        jumlahVarian,
		Atribut:             list,
		Version:             row.Version,
		CreatedAt:           maIsoWaktu(row.CreatedAt),
		UpdatedAt:           maIsoWaktu(row.UpdatedAt),
	}
}

/* ------------------------------------------------------------------ */
/* Baca — list / detail                                                */
/* ------------------------------------------------------------------ */

// FilterInduk — filter list induk.
type FilterInduk struct {
	Search    string
	SortField string
	SortDesc  bool
	Limit     int32
	Offset    int32
}

// ListProdukInduk — daftar induk hidup + jumlah varian + konfigurasi.
func (r *ProdukIndukRepository) ListProdukInduk(ctx context.Context, exec DBTX, f FilterInduk) ([]types.ProdukIndukView, int, error) {
	p := gen.ListProdukIndukParams{
		Search:    maTeksNihil(maStrPtrNihil(f.Search)),
		SortField: f.SortField,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := gen.New(exec).ListProdukInduk(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountProdukInduk(ctx, p.Search)
	if err != nil {
		return nil, 0, err
	}
	ids := make([]int64, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	varianMap, atributMap, kategori, unit, err := r.muatPelengkap(ctx, exec, ids)
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.ProdukIndukView, 0, len(rows))
	for _, r := range rows {
		row := dariListIndukRow(r)
		out = append(out, ProdukIndukToView(row, varianMap[row.ID], atributMap[row.ID], kategori, unit))
	}
	return out, int(total), nil
}

// GetProdukInduk — detail induk — 404 INV-018 bila bukan induk hidup.
func (r *ProdukIndukRepository) GetProdukInduk(ctx context.Context, exec DBTX, id int64) (types.ProdukIndukView, error) {
	row, err := r.AssertInduk(ctx, exec, id)
	if err != nil {
		return types.ProdukIndukView{}, err
	}
	varianMap, atributMap, kategori, unit, err := r.muatPelengkap(ctx, exec, []int64{id})
	if err != nil {
		return types.ProdukIndukView{}, err
	}
	return ProdukIndukToView(row, varianMap[id], atributMap[id], kategori, unit), nil
}

// muatPelengkap — varianMap + atributMap + kategori + unit (Promise.all).
func (r *ProdukIndukRepository) muatPelengkap(ctx context.Context, exec DBTX, ids []int64) (map[int64]int, map[int64][]KonfigurasiAtributInduk, map[int64]string, map[int64]string, error) {
	varianMap, err := r.HitungVarianMap(ctx, exec, ids)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	atributMap, err := r.MuatKonfigurasiAtribut(ctx, exec, ids)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	kategori, unit, err := MuatPetaKategoriUnit(ctx, exec)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return varianMap, atributMap, kategori, unit, nil
}

/* ------------------------------------------------------------------ */
/* Guard baris (fail berkode)                                          */
/* ------------------------------------------------------------------ */

// AssertInduk — induk wajib: baris produk hidup, penanda induk aktif,
// bukan varian — 404 INV-018 verbatim.
func (r *ProdukIndukRepository) AssertInduk(ctx context.Context, exec DBTX, id int64) (ProdukRow, error) {
	rrow, err := gen.New(exec).MuatProdukHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ProdukRow{}, errkontrak.NotFound(
				"Produk induk id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		return ProdukRow{}, err
	}
	row := dariProdukRow(rrow)
	if !row.AdalahIndukVarian || row.IDInvProdukInduk != nil {
		return ProdukRow{}, errkontrak.NotFound(
			"Produk induk id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
	}
	return row, nil
}

// AssertKodeIndukBebas — kode induk unik global — 409 verbatim.
func (r *ProdukIndukRepository) AssertKodeIndukBebas(ctx context.Context, exec DBTX, kode string) error {
	dupe, err := gen.New(exec).CariSkuDipakai(ctx, kode)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	_ = dupe
	return errkontrak.Conflict("Kode induk '" + kode + "' sudah dipakai.")
}

// AssertSkuVarianBebas — SKU varian unik global — 409 verbatim (INV-016).
func (r *ProdukIndukRepository) AssertSkuVarianBebas(ctx context.Context, exec DBTX, sku string) error {
	dupe, err := gen.New(exec).CariSkuDipakai(ctx, sku)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	_ = dupe
	return errkontrak.Conflict("SKU varian '" + sku + "' sudah dipakai (INV-016).")
}

/* ------------------------------------------------------------------ */
/* Agregat varian & konfigurasi atribut induk (LINE)                   */
/* ------------------------------------------------------------------ */

// HitungVarianMap — jumlah varian hidup per induk (groupBy).
func (r *ProdukIndukRepository) HitungVarianMap(ctx context.Context, exec DBTX, ids []int64) (map[int64]int, error) {
	mapOut := map[int64]int{}
	if len(ids) == 0 {
		return mapOut, nil
	}
	rows, err := gen.New(exec).HitungVarianMapInduk(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		if r.IDInduk.Valid {
			mapOut[r.IDInduk.Int64] = int(r.N)
		}
	}
	return mapOut, nil
}

// HitungVarianHidup — jumlah varian hidup satu induk (guard D-21/D-39).
func (r *ProdukIndukRepository) HitungVarianHidup(ctx context.Context, exec DBTX, idInduk int64) (int, error) {
	n, err := gen.New(exec).HitungVarianHidupProduk(ctx, pgtype.Int8{Int64: idInduk, Valid: true})
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// MuatKonfigurasiAtribut — konfigurasi atribut induk (LINE hidup, urut
// urutan) per idInduk.
func (r *ProdukIndukRepository) MuatKonfigurasiAtribut(ctx context.Context, exec DBTX, ids []int64) (map[int64][]KonfigurasiAtributInduk, error) {
	mapOut := map[int64][]KonfigurasiAtributInduk{}
	if len(ids) == 0 {
		return mapOut, nil
	}
	rows, err := gen.New(exec).MuatKonfigurasiAtributInduk(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		mapOut[r.IDInvProduk] = append(mapOut[r.IDInvProduk], KonfigurasiAtributInduk{
			IDInvAtribut: r.IDInvAtribut, KodeAtribut: r.KodeAtribut,
			NamaAtribut: r.NamaAtribut, Wajib: r.Wajib, Urutan: r.Urutan,
		})
	}
	return mapOut, nil
}

// MuatPetaKategoriUnit — peta nama kategori & kode unit (dipakai fitur
// induk; fitur produk memakai MuatReferensi produk repository).
func MuatPetaKategoriUnit(ctx context.Context, exec DBTX) (map[int64]string, map[int64]string, error) {
	kategoriRows, err := gen.New(exec).MuatPetaKategoriHidup(ctx)
	if err != nil {
		return nil, nil, err
	}
	unitRows, err := gen.New(exec).MuatPetaUnitHidup(ctx)
	if err != nil {
		return nil, nil, err
	}
	kategori := make(map[int64]string, len(kategoriRows))
	for _, r := range kategoriRows {
		kategori[r.ID] = r.Nama
	}
	unit := make(map[int64]string, len(unitRows))
	for _, r := range unitRows {
		unit[r.ID] = r.Kode
	}
	return kategori, unit, nil
}

/* ------------------------------------------------------------------ */
/* Validasi REPLACE konfigurasi & generate varian                      */
/* ------------------------------------------------------------------ */

// ListAtributHidupByIds — atribut hidup by ids (absen = 404 di service).
func (r *ProdukIndukRepository) ListAtributHidupByIds(ctx context.Context, exec DBTX, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return []int64{}, nil
	}
	rows, err := gen.New(exec).ListAtributHidupByIds(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, len(rows))
	out = append(out, rows...)
	return out, nil
}

// ListIdKonfigHidup — id baris konfigurasi hidup satu induk (audit REPLACE).
func (r *ProdukIndukRepository) ListIdKonfigHidup(ctx context.Context, exec DBTX, idInduk int64) ([]int64, error) {
	rows, err := gen.New(exec).ListIdKonfigHidup(ctx, idInduk)
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, len(rows))
	out = append(out, rows...)
	return out, nil
}

// ListNilaiAtributHidup — nilai atribut hidup by ids (kombinasi varian).
func (r *ProdukIndukRepository) ListNilaiAtributHidup(ctx context.Context, exec DBTX, ids []int64) ([]NilaiAtributHidup, error) {
	if len(ids) == 0 {
		return []NilaiAtributHidup{}, nil
	}
	rows, err := gen.New(exec).ListNilaiAtributHidup(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]NilaiAtributHidup, 0, len(rows))
	for _, r := range rows {
		out = append(out, NilaiAtributHidup{ID: r.ID, IDInvAtribut: r.IDInvAtribut, Nilai: r.Nilai})
	}
	return out, nil
}

// CariVarianKombinasi — varian hidup dengan kunci kombinasi sama per induk.
func (r *ProdukIndukRepository) CariVarianKombinasi(ctx context.Context, exec DBTX, idInduk int64, kunci string) (bool, error) {
	_, err := gen.New(exec).CariVarianKombinasiHidup(ctx, gen.CariVarianKombinasiHidupParams{
		IDInduk: pgtype.Int8{Int64: idInduk, Valid: true},
		Kunci:   pgtype.Text{String: kunci, Valid: true},
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

/* ------------------------------------------------------------------ */
/* Tulis — produk / konfigurasi LINE / junction varian                 */
/* ------------------------------------------------------------------ */

// InsertProduk — insert baris produk (induk maupun varian).
func (r *ProdukIndukRepository) InsertProduk(ctx context.Context, exec DBTX, n ProdukBaru) (ProdukRow, error) {
	rrow, err := gen.New(exec).InsertProduk(ctx, produkBaruParams(n))
	if err != nil {
		return ProdukRow{}, err
	}
	return dariInsertProdukRow(rrow), nil
}

// InsertVarian — insert varian → ringkas {id, kodeProduk} (verbatim).
func (r *ProdukIndukRepository) InsertVarian(ctx context.Context, exec DBTX, n ProdukBaru) (int64, string, error) {
	v, err := gen.New(exec).InsertVarian(ctx, varianParams(n))
	if err != nil {
		return 0, "", err
	}
	return v.ID, v.KodeProduk, nil
}

// varianParams — konversi ProdukBaru → gen.InsertVarianParams (kolom sama,
// struct gen terpisah — hasil returning ringkas {id, kode_produk}).
func varianParams(n ProdukBaru) gen.InsertVarianParams {
	return gen.InsertVarianParams{
		EntityID:            maUuidNilai(n.EntityID),
		KodeProduk:          n.KodeProduk,
		Nama:                n.Nama,
		Tipe:                gen.EnumTipeProduk(n.Tipe),
		IDInvKategoriProduk: n.IDInvKategoriProduk,
		IDInvUnitUkur:       n.IDInvUnitUkur,
		IDInvProdukInduk:    maI8Nilai(n.IDInvProdukInduk),
		KunciKombinasi:      maTeksNihil(n.KunciKombinasi),
		JejakStok:           n.JejakStok,
		Barcode:             maTeksNihil(n.Barcode),
		HargaJual:           maNumericDari(n.HargaJual),
		HargaBiaya:          maNumericDari(n.HargaBiaya),
		StokMinimum:         n.StokMinimum,
		StokMaksimum:        maI4Nilai(n.StokMaksimum),
		ReorderAktif:        n.ReorderAktif,
		AdalahIndukVarian:   n.AdalahIndukVarian,
		BeratGram:           maI4Nilai(n.BeratGram),
		VolumeCm3:           maI4Nilai(n.VolumeCm3),
		Keterangan:          maTeksNihil(n.Keterangan),
		Status:              gen.EnumStatusAktif(n.Status),
	}
}

// produkBaruParams — konversi ProdukBaru → gen params (dipakai bareng
// produk repository — kolom insert identik).
func produkBaruParams(n ProdukBaru) gen.InsertProdukParams {
	return gen.InsertProdukParams{
		EntityID:            maUuidNilai(n.EntityID),
		KodeProduk:          n.KodeProduk,
		Nama:                n.Nama,
		Tipe:                gen.EnumTipeProduk(n.Tipe),
		IDInvKategoriProduk: n.IDInvKategoriProduk,
		IDInvUnitUkur:       n.IDInvUnitUkur,
		IDInvProdukInduk:    maI8Nilai(n.IDInvProdukInduk),
		KunciKombinasi:      maTeksNihil(n.KunciKombinasi),
		JejakStok:           n.JejakStok,
		Barcode:             maTeksNihil(n.Barcode),
		HargaJual:           maNumericDari(n.HargaJual),
		HargaBiaya:          maNumericDari(n.HargaBiaya),
		StokMinimum:         n.StokMinimum,
		StokMaksimum:        maI4Nilai(n.StokMaksimum),
		ReorderAktif:        n.ReorderAktif,
		AdalahIndukVarian:   n.AdalahIndukVarian,
		BeratGram:           maI4Nilai(n.BeratGram),
		VolumeCm3:           maI4Nilai(n.VolumeCm3),
		Keterangan:          maTeksNihil(n.Keterangan),
		Status:              gen.EnumStatusAktif(n.Status),
	}
}

// UpdateIndukVersiHidup — WHERE id + hidup + version (STD-07); nil bila
// kalah balapan.
func (r *ProdukIndukRepository) UpdateIndukVersiHidup(ctx context.Context, exec DBTX, id int64, s IndukUbahSet, versiHarap int32) (*ProdukRow, error) {
	rrow, err := gen.New(exec).UpdateIndukVersiHidup(ctx, gen.UpdateIndukVersiHidupParams{
		Nama:                s.Nama,
		Keterangan:          maTeksNihil(s.Keterangan),
		IDInvKategoriProduk: s.IDInvKategoriProduk,
		IDInvUnitUkur:       s.IDInvUnitUkur,
		Status:              gen.EnumStatusAktif(s.Status),
		VersionBaru:         s.Version,
		UpdatedAt:           maWaktu(s.UpdatedAt),
		ID:                  id,
		VersiHarap:          versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := dariUpdateIndukRow(rrow)
	return &row, nil
}

// UpdateProdukVersiTanpaHidup — bump version REPLACE konfigurasi — VERBATIM
// sumber: WHERE id + version SAJA (TANPA filter hidup; returning baris
// penuh). Nil bila 0 baris.
func (r *ProdukIndukRepository) UpdateProdukVersiTanpaHidup(ctx context.Context, exec DBTX, id int64, versionBaru, versiHarap int32, updatedAt time.Time) (*ProdukRow, error) {
	row, err := gen.New(exec).UpdateProdukVersiTanpaHidup(ctx, gen.UpdateProdukVersiTanpaHidupParams{
		VersionBaru: versionBaru,
		UpdatedAt:   maWaktu(updatedAt),
		ID:          id,
		VersiHarap:  versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	out := produkDariValues(
		row.ID, row.KodeProduk, row.Nama, row.Tipe, row.IDInvKategoriProduk, row.IDInvUnitUkur,
		row.IDInvProdukInduk, row.KunciKombinasi, row.AdalahIndukVarian, row.JejakStok,
		row.Barcode, row.HargaJual, row.HargaBiaya, row.StokMinimum, row.StokMaksimum,
		row.ReorderAktif, row.BeratGram, row.VolumeCm3, row.Keterangan, row.Status,
		row.Version, row.CreatedAt, row.UpdatedAt,
	)
	return &out, nil
}

// SoftDeleteIndukHidup — hapus lunak induk hidup (+adalahIndukVarian=false).
func (r *ProdukIndukRepository) SoftDeleteIndukHidup(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteIndukHidup(ctx, gen.SoftDeleteIndukHidupParams{
		DeletedAt:         maWaktu(deletedAt),
		UpdatedAt:         maWaktu(updatedAt),
		AdalahIndukVarian: false,
		ID:                id,
	})
}

// SoftDeleteKonfigHidupByProduk — hapus lunak konfigurasi hidup satu induk.
func (r *ProdukIndukRepository) SoftDeleteKonfigHidupByProduk(ctx context.Context, exec DBTX, idInduk int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteKonfigHidupByProduk(ctx, gen.SoftDeleteKonfigHidupByProdukParams{
		DeletedAt: maWaktu(deletedAt),
		UpdatedAt: maWaktu(updatedAt),
		IDInduk:   idInduk,
	})
}

// InsertKonfigBanyak — sisip baris konfigurasi atribut induk (LINE).
func (r *ProdukIndukRepository) InsertKonfigBanyak(ctx context.Context, exec DBTX, nilai []KonfigBaru) error {
	for _, n := range nilai {
		if err := gen.New(exec).InsertKonfigAtribut(ctx, gen.InsertKonfigAtributParams{
			EntityID:     maUuidNilai(n.EntityID),
			IDInvProduk:  n.IDInvProduk,
			IDInvAtribut: n.IDInvAtribut,
			Wajib:        n.Wajib,
			Urutan:       n.Urutan,
		}); err != nil {
			return err
		}
	}
	return nil
}

// InsertAtributVarian — junction varian ↔ nilai atribut (idempoten).
func (r *ProdukIndukRepository) InsertAtributVarian(ctx context.Context, exec DBTX, pasangan []ProdukAtributBaru) error {
	for _, p := range pasangan {
		if err := gen.New(exec).InsertProdukAtribut(ctx, gen.InsertProdukAtributParams{
			IDInvProduk:       p.IDInvProduk,
			IDInvNilaiAtribut: p.IDInvNilaiAtribut,
		}); err != nil {
			return err
		}
	}
	return nil
}
