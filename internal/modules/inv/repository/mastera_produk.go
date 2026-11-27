// mastera_produk.go — SATU-SATUNYA pengguna sqlc fitur PRODUK modul inv
// (padanan ProdukRepository NestJS): list paginated + agregat saldo
// readmodel, lookup ringkas picker M36, guard SKU/barcode, insert/update
// optimistic locking STD-07, soft delete, junction inv_produk_atribut,
// validasi entry varian (konfigurasi/nilai). Mapper BARIS → VIEW
// (produkToView) di sini — kontrak bentuk JSON = types.ProdukView
// (cermin packages/schemas inv/views.ts).
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

// maStrconvI — int64 → teks (pesan 404).
func maStrconvI(id int64) string { return strconv.FormatInt(id, 10) }

// ProdukRow — baris mentah inv_produk (pgtype sudah dikonversi; harga
// numeric diteruskan SEBAGAI TEKS desimal — persis drizzle string, dipakai
// service utk warisan harga varian & perbandingan barcode).
type ProdukRow struct {
	ID                  int64
	KodeProduk          string
	Nama                string
	Tipe                string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	IDInvProdukInduk    *int64
	KunciKombinasi      *string
	AdalahIndukVarian   bool
	JejakStok           bool
	Barcode             *string
	HargaJual           *string
	HargaBiaya          *string
	StokMinimum         int32
	StokMaksimum        *int32
	ReorderAktif        bool
	BeratGram           *int32
	VolumeCm3           *int32
	Keterangan          *string
	Status              string
	Version             int32
	CreatedAt           time.Time
	UpdatedAt           time.Time
}

// PasanganAtributProduk — elemen atribut[] ProdukView.
type PasanganAtributProduk struct {
	KodeAtribut string
	NamaAtribut string
	Nilai       string
}

// ReferensiProduk — peta kategori/unit/induk (muat penuh per call).
type ReferensiProduk struct {
	Kategori map[int64]string
	Unit     map[int64]string
	Induk    map[int64]string
}

// ProdukBaru — nilai insert inv_produk (dibangun service).
type ProdukBaru struct {
	EntityID            string
	KodeProduk          string
	Nama                string
	Tipe                string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	IDInvProdukInduk    *int64
	KunciKombinasi      *string
	JejakStok           bool
	Barcode             *string
	HargaJual           *string
	HargaBiaya          *string
	StokMinimum         int32
	StokMaksimum        *int32
	ReorderAktif        bool
	AdalahIndukVarian   bool
	BeratGram           *int32
	VolumeCm3           *int32
	Keterangan          *string
	Status              string
}

// ProdukUbahSet — nilai update inv_produk (set penuh dibangun service;
// version_baru = row.version+1 di service).
type ProdukUbahSet struct {
	Nama                string
	Tipe                string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	JejakStok           bool
	Barcode             *string
	HargaJual           *string
	HargaBiaya          *string
	StokMinimum         int32
	StokMaksimum        *int32
	ReorderAktif        bool
	AdalahIndukVarian   bool
	BeratGram           *int32
	VolumeCm3           *int32
	Keterangan          *string
	Status              string
	Version             int32
	UpdatedAt           time.Time
}

// ProdukRepository — wrapper sqlc fitur produk.
type ProdukRepository struct{}

// NewProduk — konstruksi tanpa state (executor per method).
func NewProduk() *ProdukRepository { return &ProdukRepository{} }

/* ------------------------------------------------------------------ */
/* Konversi baris gen → ProdukRow                                      */
/* ------------------------------------------------------------------ */

func dariProdukRow(r gen.MuatProdukHidupRow) ProdukRow {
	return produkDariValues(
		r.ID, r.KodeProduk, r.Nama, r.Tipe, r.IDInvKategoriProduk, r.IDInvUnitUkur,
		r.IDInvProdukInduk, r.KunciKombinasi, r.AdalahIndukVarian, r.JejakStok,
		r.Barcode, r.HargaJual, r.HargaBiaya, r.StokMinimum, r.StokMaksimum,
		r.ReorderAktif, r.BeratGram, r.VolumeCm3, r.Keterangan, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt,
	)
}

// produkDariValues — konversi nilai kolom inv_produk → ProdukRow (dipakai
// bila bentuk kolom sama namun struct gen berbeda: MuatProdukHidupRow,
// InsertProdukRow, UpdateProdukVersiHidupRow, UpdateIndukVersiHidupRow).
func produkDariValues(
	id int64, kodeProduk, nama string, tipe gen.EnumTipeProduk,
	idKategori, idUnit int64,
	idInduk pgtype.Int8, kunci pgtype.Text, adalahInduk, jejak bool,
	barcode pgtype.Text, hargaJual, hargaBiaya pgtype.Numeric,
	stokMinimum int32, stokMaksimum pgtype.Int4, reorderAktif bool,
	beratGram, volumeCm3 pgtype.Int4,
	keterangan pgtype.Text, status gen.EnumStatusAktif,
	version int32, createdAt, updatedAt pgtype.Timestamptz,
) ProdukRow {
	return ProdukRow{
		ID:                  id,
		KodeProduk:          kodeProduk,
		Nama:                nama,
		Tipe:                string(tipe),
		IDInvKategoriProduk: idKategori,
		IDInvUnitUkur:       idUnit,
		IDInvProdukInduk:    maI8Ptr(idInduk),
		KunciKombinasi:      maTxtPtr(kunci),
		AdalahIndukVarian:   adalahInduk,
		JejakStok:           jejak,
		Barcode:             maTxtPtr(barcode),
		HargaJual:           maNumericTeksis(hargaJual),
		HargaBiaya:          maNumericTeksis(hargaBiaya),
		StokMinimum:         stokMinimum,
		StokMaksimum:        maI4Ptr(stokMaksimum),
		ReorderAktif:        reorderAktif,
		BeratGram:           maI4Ptr(beratGram),
		VolumeCm3:           maI4Ptr(volumeCm3),
		Keterangan:          maTxtPtr(keterangan),
		Status:              string(status),
		Version:             version,
		CreatedAt:           createdAt.Time,
		UpdatedAt:           updatedAt.Time,
	}
}

// dariInsertProdukRow — konversi hasil insert.
func dariInsertProdukRow(r gen.InsertProdukRow) ProdukRow {
	return produkDariValues(
		r.ID, r.KodeProduk, r.Nama, r.Tipe, r.IDInvKategoriProduk, r.IDInvUnitUkur,
		r.IDInvProdukInduk, r.KunciKombinasi, r.AdalahIndukVarian, r.JejakStok,
		r.Barcode, r.HargaJual, r.HargaBiaya, r.StokMinimum, r.StokMaksimum,
		r.ReorderAktif, r.BeratGram, r.VolumeCm3, r.Keterangan, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt,
	)
}

// dariUpdateProdukRow — konversi hasil update produk.
func dariUpdateProdukRow(r gen.UpdateProdukVersiHidupRow) ProdukRow {
	return produkDariValues(
		r.ID, r.KodeProduk, r.Nama, r.Tipe, r.IDInvKategoriProduk, r.IDInvUnitUkur,
		r.IDInvProdukInduk, r.KunciKombinasi, r.AdalahIndukVarian, r.JejakStok,
		r.Barcode, r.HargaJual, r.HargaBiaya, r.StokMinimum, r.StokMaksimum,
		r.ReorderAktif, r.BeratGram, r.VolumeCm3, r.Keterangan, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt,
	)
}

// dariUpdateIndukRow — konversi hasil update induk.
func dariUpdateIndukRow(r gen.UpdateIndukVersiHidupRow) ProdukRow {
	return produkDariValues(
		r.ID, r.KodeProduk, r.Nama, r.Tipe, r.IDInvKategoriProduk, r.IDInvUnitUkur,
		r.IDInvProdukInduk, r.KunciKombinasi, r.AdalahIndukVarian, r.JejakStok,
		r.Barcode, r.HargaJual, r.HargaBiaya, r.StokMinimum, r.StokMaksimum,
		r.ReorderAktif, r.BeratGram, r.VolumeCm3, r.Keterangan, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt,
	)
}

// ProdukToView — padanan produkToView (kunci cermin views.ts; maWaktu ISO).
func ProdukToView(row ProdukRow, saldoOnHand int, atribut []PasanganAtributProduk, kategori, unit, induk map[int64]string) types.ProdukView {
	kodeInduk := (*string)(nil)
	if row.IDInvProdukInduk != nil {
		if k, ada := induk[*row.IDInvProdukInduk]; ada {
			kodeInduk = &k
		}
	}
	if atribut == nil {
		atribut = []PasanganAtributProduk{}
	}
	return types.ProdukView{
		ID:                  row.ID,
		KodeProduk:          row.KodeProduk,
		Nama:                row.Nama,
		Tipe:                row.Tipe,
		IDInvKategoriProduk: row.IDInvKategoriProduk,
		NamaKategori:        kategori[row.IDInvKategoriProduk],
		IDInvUnitUkur:       row.IDInvUnitUkur,
		KodeUnit:            unit[row.IDInvUnitUkur],
		IDInvProdukInduk:    row.IDInvProdukInduk,
		KodeInduk:           kodeInduk,
		KunciKombinasi:      row.KunciKombinasi,
		Atribut:             produkAtributView(atribut),
		JejakStok:           row.JejakStok,
		Barcode:             row.Barcode,
		HargaJual:           maAngkaStrPtr(row.HargaJual),
		HargaBiaya:          maAngkaStrPtr(row.HargaBiaya),
		StokMinimum:         row.StokMinimum,
		StokMaksimum:        row.StokMaksimum,
		ReorderAktif:        row.ReorderAktif,
		AdalahIndukVarian:   row.AdalahIndukVarian,
		BeratGram:           row.BeratGram,
		VolumeCm3:           row.VolumeCm3,
		Keterangan:          row.Keterangan,
		Status:              row.Status,
		SaldoOnHand:         saldoOnHand,
		Version:             row.Version,
		CreatedAt:           maIsoWaktu(row.CreatedAt),
		UpdatedAt:           maIsoWaktu(row.UpdatedAt),
	}
}

func produkAtributView(list []PasanganAtributProduk) []types.ProdukAtributView {
	out := make([]types.ProdukAtributView, 0, len(list))
	for _, a := range list {
		out = append(out, types.ProdukAtributView{KodeAtribut: a.KodeAtribut, NamaAtribut: a.NamaAtribut, Nilai: a.Nilai})
	}
	return out
}

// angkaStrPtr — Number(teks numeric) untuk harga dari ProdukRow.
func maAngkaStrPtr(s *string) *float64 {
	if s == nil {
		return nil
	}
	f, err := strconv.ParseFloat(*s, 64)
	if err != nil {
		return nil
	}
	return &f
}

/* ------------------------------------------------------------------ */
/* Baca — list / detail / lookup picker                                */
/* ------------------------------------------------------------------ */

// FilterProduk — filter list produk (page/limit/offset di pemanggil).
type FilterProduk struct {
	Status     string
	Tipe       string
	IDKategori *int64
	Search     string
	SortField  string
	SortDesc   bool
	Limit      int32
	Offset     int32
}

func filterProdukParams(f FilterProduk) gen.ListProdukParams {
	return gen.ListProdukParams{
		Status:     maTeksNihil(maStrPtrNihil(f.Status)),
		Tipe:       maTeksNihil(maStrPtrNihil(f.Tipe)),
		IDKategori: maI8Nilai(f.IDKategori),
		Search:     maTeksNihil(maStrPtrNihil(f.Search)),
		SortField:  f.SortField,
		SortDesc:   f.SortDesc,
		Limit:      f.Limit,
		Offset:     f.Offset,
	}
}

// ListProduk — daftar produk hidup + saldo agregat (rows, total).
func (r *ProdukRepository) ListProduk(ctx context.Context, exec DBTX, f FilterProduk) ([]types.ProdukView, int, error) {
	p := filterProdukParams(f)
	rows, err := gen.New(exec).ListProduk(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountProduk(ctx, gen.CountProdukParams{
		Status:     p.Status,
		Tipe:       p.Tipe,
		IDKategori: p.IDKategori,
		Search:     p.Search,
	})
	if err != nil {
		return nil, 0, err
	}
	ids := make([]int64, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	atributMap, err := r.MuatAtribut(ctx, exec, ids)
	if err != nil {
		return nil, 0, err
	}
	ref, err := r.MuatReferensi(ctx, exec)
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.ProdukView, 0, len(rows))
	for _, r := range rows {
		row := ProdukRow{
			ID: r.ID, KodeProduk: r.KodeProduk, Nama: r.Nama, Tipe: string(r.Tipe),
			IDInvKategoriProduk: r.IDInvKategoriProduk, IDInvUnitUkur: r.IDInvUnitUkur,
			IDInvProdukInduk: maI8Ptr(r.IDInvProdukInduk), KunciKombinasi: maTxtPtr(r.KunciKombinasi),
			AdalahIndukVarian: r.AdalahIndukVarian, JejakStok: r.JejakStok,
			Barcode: maTxtPtr(r.Barcode), HargaJual: maNumericTeksis(r.HargaJual),
			HargaBiaya: maNumericTeksis(r.HargaBiaya), StokMinimum: r.StokMinimum,
			StokMaksimum: maI4Ptr(r.StokMaksimum), ReorderAktif: r.ReorderAktif,
			BeratGram: maI4Ptr(r.BeratGram), VolumeCm3: maI4Ptr(r.VolumeCm3),
			Keterangan: maTxtPtr(r.Keterangan), Status: string(r.Status),
			Version: r.Version, CreatedAt: r.CreatedAt.Time, UpdatedAt: r.UpdatedAt.Time,
		}
		out = append(out, ProdukToView(row, maAsInt(r.SaldoOnHand), atributMap[r.ID], ref.Kategori, ref.Unit, ref.Induk))
	}
	return out, int(total), nil
}

// GetProduk — detail produk hidup; 404 INV-018 bila tidak ada / terhapus.
func (r *ProdukRepository) GetProduk(ctx context.Context, exec DBTX, id int64) (types.ProdukView, error) {
	rrow, err := gen.New(exec).MuatProdukHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return types.ProdukView{}, errkontrak.NotFound(
				"Produk id "+maStrconvI(id)+" tidak ditemukan.", "INV-018")
		}
		return types.ProdukView{}, err
	}
	row := dariProdukRow(rrow)
	saldo, err := r.JumlahSaldoOnHand(ctx, exec, id)
	if err != nil {
		return types.ProdukView{}, err
	}
	atributMap, err := r.MuatAtribut(ctx, exec, []int64{id})
	if err != nil {
		return types.ProdukView{}, err
	}
	ref, err := r.MuatReferensi(ctx, exec)
	if err != nil {
		return types.ProdukView{}, err
	}
	return ProdukToView(row, saldo, atributMap[id], ref.Kategori, ref.Unit, ref.Induk), nil
}

// AssertHidup — produk hidup wajib ada — fail 404 INV-018 (update/remove).
func (r *ProdukRepository) AssertHidup(ctx context.Context, exec DBTX, id int64) (ProdukRow, error) {
	rrow, err := gen.New(exec).MuatProdukHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ProdukRow{}, errkontrak.NotFound(
				"Produk id "+maStrconvI(id)+" tidak ditemukan.", "INV-018")
		}
		return ProdukRow{}, err
	}
	return dariProdukRow(rrow), nil
}

// FindHidupById — produk hidup by id — nil bila absen (guard induk varian).
func (r *ProdukRepository) FindHidupById(ctx context.Context, exec DBTX, id int64) (*ProdukRow, error) {
	rrow, err := gen.New(exec).MuatProdukHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := dariProdukRow(rrow)
	return &row, nil
}

// LookupView — baris lookup ringkas (M36).
type LookupView struct {
	ID               int64
	KodeProduk       string
	Nama             string
	Tipe             string
	IDInvProdukInduk *int64
	IDInvUnitUkur    int64
	KodeUnit         string
	HargaJual        *float64
	SaldoOnHand      int
}

// Lookup — cari kode/nama/barcode, hanya AKTIF, INNER JOIN unit; barcode
// eksak menang atas search; limit sudah di-clamp service (1..200).
func (r *ProdukRepository) Lookup(ctx context.Context, exec DBTX, search, barcode string, limit int32, idKategori *int64) ([]types.ProdukLookupView, error) {
	rows, err := gen.New(exec).ListProdukLookup(ctx, gen.ListProdukLookupParams{
		Search:     maTeksNihil(maStrPtrNihil(search)),
		Barcode:    maTeksNihil(maStrPtrNihil(barcode)),
		IDKategori: maI8Nilai(idKategori),
		Limit:      limit,
	})
	if err != nil {
		return nil, err
	}
	out := make([]types.ProdukLookupView, 0, len(rows))
	for _, r := range rows {
		out = append(out, types.ProdukLookupView{
			ID:               r.ID,
			KodeProduk:       r.KodeProduk,
			Nama:             r.Nama,
			Tipe:             string(r.Tipe),
			IDInvProdukInduk: maI8Ptr(r.IDInvProdukInduk),
			IDInvUnitUkur:    r.IDInvUnitUkur,
			KodeUnit:         r.KodeUnit,
			HargaJual:        maAngkaPtr(r.HargaJual),
			SaldoOnHand:      maAsInt(r.SaldoOnHand),
		})
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Guard baris (fail berkode — dipakai service sebelum mutasi)         */
/* ------------------------------------------------------------------ */

// CariIndukVarian — induk varian hidup by id (penanda induk aktif, bukan
// varian) — nil bila absen.
func (r *ProdukRepository) CariIndukVarian(ctx context.Context, exec DBTX, id int64) (*ProdukRow, error) {
	rrow, err := gen.New(exec).CariIndukVarianHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := dariCariIndukRow(rrow)
	return &row, nil
}

// dariCariIndukRow — konversi CariIndukVarianHidupRow (bentuk sama,
// struct gen berbeda).
func dariCariIndukRow(r gen.CariIndukVarianHidupRow) ProdukRow {
	return produkDariValues(
		r.ID, r.KodeProduk, r.Nama, r.Tipe, r.IDInvKategoriProduk, r.IDInvUnitUkur,
		r.IDInvProdukInduk, r.KunciKombinasi, r.AdalahIndukVarian, r.JejakStok,
		r.Barcode, r.HargaJual, r.HargaBiaya, r.StokMinimum, r.StokMaksimum,
		r.ReorderAktif, r.BeratGram, r.VolumeCm3, r.Keterangan, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt,
	)
}

// AssertSkuBebas — SKU unik global (numbering, K-10) — 409 verbatim.
func (r *ProdukRepository) AssertSkuBebas(ctx context.Context, exec DBTX, sku string) error {
	dupe, err := gen.New(exec).CariSkuDipakai(ctx, sku)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	_ = dupe
	return errkontrak.Conflict("SKU '" + sku + "' sudah dipakai produk lain.")
}

// AssertBarcodeBebas — barcode unik di antara baris hidup (partial unique).
func (r *ProdukRepository) AssertBarcodeBebas(ctx context.Context, exec DBTX, barcode string, kecualiID *int64) error {
	_, err := gen.New(exec).CariBarcodeProdukHidup(ctx, gen.CariBarcodeProdukHidupParams{
		Barcode:   pgtype.Text{String: barcode, Valid: true},
		KecualiID: maI8Nilai(kecualiID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	return errkontrak.Conflict("Barcode '" + barcode + "' sudah dipakai produk lain.")
}

/* ------------------------------------------------------------------ */
/* Validasi entry varian (D-38/D-39) — konfigurasi induk & nilai       */
/* ------------------------------------------------------------------ */

// KonfigurasiIndukRingkas — baris konfigurasi (murni → domain).
type KonfigurasiIndukRingkas struct {
	IDInvAtribut int64
	KodeAtribut  string
	Wajib        bool
}

// ListKonfigurasiInduk — konfigurasi atribut induk (wajib + kode D-19);
// TANPA ORDER BY — persis sumber.
func (r *ProdukRepository) ListKonfigurasiInduk(ctx context.Context, exec DBTX, idInduk int64) ([]KonfigurasiIndukRingkas, error) {
	rows, err := gen.New(exec).ListKonfigurasiIndukRingkas(ctx, idInduk)
	if err != nil {
		return nil, err
	}
	out := make([]KonfigurasiIndukRingkas, 0, len(rows))
	for _, r := range rows {
		out = append(out, KonfigurasiIndukRingkas{IDInvAtribut: r.IDInvAtribut, KodeAtribut: r.KodeAtribut, Wajib: r.Wajib})
	}
	return out, nil
}

// NilaiAtributHidup — baris nilai atribut hidup (murni → domain).
type NilaiAtributHidup struct {
	ID           int64
	IDInvAtribut int64
	Nilai        string
}

// ListNilaiAtributHidup — nilai atribut hidup by ids.
func (r *ProdukRepository) ListNilaiAtributHidup(ctx context.Context, exec DBTX, ids []int64) ([]NilaiAtributHidup, error) {
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

// CariVarianKombinasi — varian hidup dengan kunci kombinasi sama per induk
// — nil bila bebas (INV-016).
func (r *ProdukRepository) CariVarianKombinasi(ctx context.Context, exec DBTX, idInduk int64, kunci string) (bool, error) {
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
/* Tulis — produk / junction atribut varian                            */
/* ------------------------------------------------------------------ */

// InsertProduk — insert produk baru → ProdukRow lengkap.
func (r *ProdukRepository) InsertProduk(ctx context.Context, exec DBTX, n ProdukBaru) (ProdukRow, error) {
	rrow, err := gen.New(exec).InsertProduk(ctx, gen.InsertProdukParams{
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
	})
	if err != nil {
		return ProdukRow{}, err
	}
	return dariInsertProdukRow(rrow), nil
}

// UpdateProdukVersiHidup — WHERE id + hidup + version (STD-07); nil bila
// kalah balapan (0 baris).
func (r *ProdukRepository) UpdateProdukVersiHidup(ctx context.Context, exec DBTX, id int64, s ProdukUbahSet, versiHarap int32) (*ProdukRow, error) {
	rrow, err := gen.New(exec).UpdateProdukVersiHidup(ctx, gen.UpdateProdukVersiHidupParams{
		Nama:                s.Nama,
		Tipe:                gen.EnumTipeProduk(s.Tipe),
		IDInvKategoriProduk: s.IDInvKategoriProduk,
		IDInvUnitUkur:       s.IDInvUnitUkur,
		JejakStok:           s.JejakStok,
		Barcode:             maTeksNihil(s.Barcode),
		HargaJual:           maNumericDari(s.HargaJual),
		HargaBiaya:          maNumericDari(s.HargaBiaya),
		StokMinimum:         s.StokMinimum,
		StokMaksimum:        maI4Nilai(s.StokMaksimum),
		ReorderAktif:        s.ReorderAktif,
		AdalahIndukVarian:   s.AdalahIndukVarian,
		BeratGram:           maI4Nilai(s.BeratGram),
		VolumeCm3:           maI4Nilai(s.VolumeCm3),
		Keterangan:          maTeksNihil(s.Keterangan),
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
	row := dariUpdateProdukRow(rrow)
	return &row, nil
}

// ProdukAtributBaru — pasangan junction varian ↔ nilai (D-20).
type ProdukAtributBaru struct {
	IDInvProduk       int64
	IDInvNilaiAtribut int64
}

// InsertAtributVarian — junction varian ↔ nilai atribut (idempoten).
func (r *ProdukRepository) InsertAtributVarian(ctx context.Context, exec DBTX, pasangan []ProdukAtributBaru) error {
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

// SoftDeleteProdukHidup — hapus lunak produk hidup.
func (r *ProdukRepository) SoftDeleteProdukHidup(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteProdukHidup(ctx, gen.SoftDeleteProdukHidupParams{
		DeletedAt: maWaktu(deletedAt), UpdatedAt: maWaktu(updatedAt), ID: id,
	})
}

/* ------------------------------------------------------------------ */
/* Agregat readmodel & guard referensi hapus (INV-002)                 */
/* ------------------------------------------------------------------ */

// JumlahSaldoOnHand — agregat saldo hidup produk (readmodel BACA).
func (r *ProdukRepository) JumlahSaldoOnHand(ctx context.Context, exec DBTX, idProduk int64) (int, error) {
	n, err := gen.New(exec).JumlahSaldoOnHandProduk(ctx, idProduk)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungVarianHidup — jumlah varian hidup satu induk (guard D-21).
func (r *ProdukRepository) HitungVarianHidup(ctx context.Context, exec DBTX, idInduk int64) (int, error) {
	n, err := gen.New(exec).HitungVarianHidupProduk(ctx, pgtype.Int8{Int64: idInduk, Valid: true})
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungGerakanHidup — guard hapus INV-002.
func (r *ProdukRepository) HitungGerakanHidup(ctx context.Context, exec DBTX, idProduk int64) (int, error) {
	n, err := gen.New(exec).HitungGerakanHidupProduk(ctx, idProduk)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungLotHidup — guard hapus INV-002.
func (r *ProdukRepository) HitungLotHidup(ctx context.Context, exec DBTX, idProduk int64) (int, error) {
	n, err := gen.New(exec).HitungLotHidupProduk(ctx, idProduk)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

/* ------------------------------------------------------------------ */
/* Referensi view — atribut varian & peta kategori/unit/induk          */
/* ------------------------------------------------------------------ */

// MuatAtribut — pasangan nilai atribut per produk (varian).
func (r *ProdukRepository) MuatAtribut(ctx context.Context, exec DBTX, ids []int64) (map[int64][]PasanganAtributProduk, error) {
	mapOut := map[int64][]PasanganAtributProduk{}
	if len(ids) == 0 {
		return mapOut, nil
	}
	rows, err := gen.New(exec).MuatAtributProduk(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		mapOut[r.IDInvProduk] = append(mapOut[r.IDInvProduk], PasanganAtributProduk{
			KodeAtribut: r.KodeAtribut, NamaAtribut: r.NamaAtribut, Nilai: r.Nilai,
		})
	}
	return mapOut, nil
}

// MuatReferensi — peta kategori/unit/induk (jarang berubah).
func (r *ProdukRepository) MuatReferensi(ctx context.Context, exec DBTX) (ReferensiProduk, error) {
	kategoriRows, err := gen.New(exec).MuatPetaKategoriHidup(ctx)
	if err != nil {
		return ReferensiProduk{}, err
	}
	unitRows, err := gen.New(exec).MuatPetaUnitHidup(ctx)
	if err != nil {
		return ReferensiProduk{}, err
	}
	indukRows, err := gen.New(exec).MuatPetaIndukHidup(ctx)
	if err != nil {
		return ReferensiProduk{}, err
	}
	ref := ReferensiProduk{
		Kategori: make(map[int64]string, len(kategoriRows)),
		Unit:     make(map[int64]string, len(unitRows)),
		Induk:    make(map[int64]string, len(indukRows)),
	}
	for _, r := range kategoriRows {
		ref.Kategori[r.ID] = r.Nama
	}
	for _, r := range unitRows {
		ref.Unit[r.ID] = r.Kode
	}
	for _, r := range indukRows {
		ref.Induk[r.ID] = r.KodeProduk
	}
	return ref, nil
}
