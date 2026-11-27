// mastera_kategori.go — SATU-SATUNYA pengguna sqlc fitur KATEGORI PRODUK
// modul inv (padanan KategoriRepository NestJS — master kebijakan stok &
// valuasi INV-F01): list/detail join induk + penanda punya-mutasi (EXISTS),
// guard baris, CRUD + optimistic locking STD-07, soft delete. Mapper
// toKategoriView di sini — bentuk JSON = types.KategoriProdukView.
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

// KategoriRow — baris mentah inv_kategori_produk.
type KategoriRow struct {
	ID                   int64
	IDKategoriInduk      *int64
	Nama                 string
	MetodeValuasi        string
	SistemValuasi        string
	KebijakanPelacakan   string
	KebijakanKedaluwarsa bool
	Status               string
	Version              int32
	CreatedAt            time.Time
	UpdatedAt            time.Time
}

// KategoriBaru — nilai insert inv_kategori_produk.
type KategoriBaru struct {
	EntityID             string
	Nama                 string
	IDKategoriInduk      *int64
	MetodeValuasi        string
	SistemValuasi        string
	KebijakanPelacakan   string
	KebijakanKedaluwarsa bool
	Status               string
}

// KategoriUbahSet — nilai update inv_kategori_produk (set dibangun service).
type KategoriUbahSet struct {
	Nama                 string
	IDKategoriInduk      *int64
	MetodeValuasi        string
	SistemValuasi        string
	KebijakanPelacakan   string
	KebijakanKedaluwarsa bool
	Status               string
	Version              int32
	UpdatedAt            time.Time
}

// KategoriRepository — wrapper sqlc fitur kategori.
type KategoriRepository struct{}

// NewKategori — konstruksi tanpa state.
func NewKategori() *KategoriRepository { return &KategoriRepository{} }

/* ------------------------------------------------------------------ */
/* Konversi baris + mapper view                                        */
/* ------------------------------------------------------------------ */

func kategoriDariValues(
	id int64, idInduk pgtype.Int8, nama string,
	metode gen.EnumMetodeValuasi, sistem gen.EnumSistemValuasi,
	pelacakan gen.EnumPelacakan, kedaluwarsa bool, status gen.EnumStatusAktif,
	version int32, createdAt, updatedAt pgtype.Timestamptz,
) KategoriRow {
	return KategoriRow{
		ID:                   id,
		IDKategoriInduk:      maI8Ptr(idInduk),
		Nama:                 nama,
		MetodeValuasi:        string(metode),
		SistemValuasi:        string(sistem),
		KebijakanPelacakan:   string(pelacakan),
		KebijakanKedaluwarsa: kedaluwarsa,
		Status:               string(status),
		Version:              version,
		CreatedAt:            createdAt.Time,
		UpdatedAt:            updatedAt.Time,
	}
}

func dariMuatKategoriHidupRow(r gen.MuatKategoriHidupRow) KategoriRow {
	return kategoriDariValues(r.ID, r.IDKategoriInduk, r.Nama, r.MetodeValuasi,
		r.SistemValuasi, r.KebijakanPelacakan, r.KebijakanKedaluwarsa, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt)
}

func dariInsertKategoriRow(r gen.InsertKategoriRow) KategoriRow {
	return kategoriDariValues(r.ID, r.IDKategoriInduk, r.Nama, r.MetodeValuasi,
		r.SistemValuasi, r.KebijakanPelacakan, r.KebijakanKedaluwarsa, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt)
}

func dariUpdateKategoriRow(r gen.UpdateKategoriVersiHidupRow) KategoriRow {
	return kategoriDariValues(r.ID, r.IDKategoriInduk, r.Nama, r.MetodeValuasi,
		r.SistemValuasi, r.KebijakanPelacakan, r.KebijakanKedaluwarsa, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt)
}

// ToKategoriView — padanan toKategoriView (kunci cermin views.ts).
func ToKategoriView(row KategoriRow, namaInduk *string, punyaMutasi bool) types.KategoriProdukView {
	return types.KategoriProdukView{
		ID:                   row.ID,
		IDKategoriInduk:      row.IDKategoriInduk,
		NamaInduk:            namaInduk,
		Nama:                 row.Nama,
		MetodeValuasi:        row.MetodeValuasi,
		SistemValuasi:        row.SistemValuasi,
		KebijakanPelacakan:   row.KebijakanPelacakan,
		KebijakanKedaluwarsa: row.KebijakanKedaluwarsa,
		Status:               row.Status,
		PunyaMutasi:          punyaMutasi,
		Version:              row.Version,
		CreatedAt:            maIsoWaktu(row.CreatedAt),
		UpdatedAt:            maIsoWaktu(row.UpdatedAt),
	}
}

func viewDariListKategoriRow(r gen.ListKategoriRow) types.KategoriProdukView {
	row := kategoriDariValues(r.ID, r.IDKategoriInduk, r.Nama, r.MetodeValuasi,
		r.SistemValuasi, r.KebijakanPelacakan, r.KebijakanKedaluwarsa, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt)
	return ToKategoriView(row, maTxtPtr(r.NamaInduk), r.PunyaMutasi)
}

func viewDariMuatKategoriDetailRow(r gen.MuatKategoriDetailRow) types.KategoriProdukView {
	row := kategoriDariValues(r.ID, r.IDKategoriInduk, r.Nama, r.MetodeValuasi,
		r.SistemValuasi, r.KebijakanPelacakan, r.KebijakanKedaluwarsa, r.Status,
		r.Version, r.CreatedAt, r.UpdatedAt)
	return ToKategoriView(row, maTxtPtr(r.NamaInduk), r.PunyaMutasi)
}

/* ------------------------------------------------------------------ */
/* Baca                                                                */
/* ------------------------------------------------------------------ */

// FilterKategori — filter list kategori.
type FilterKategori struct {
	Status    string
	Search    string
	SortField string
	SortDesc  bool
	Limit     int32
	Offset    int32
}

// ListKategori — daftar kategori hidup + nama induk + punya-mutasi.
func (r *KategoriRepository) ListKategori(ctx context.Context, exec DBTX, f FilterKategori) ([]types.KategoriProdukView, int, error) {
	p := gen.ListKategoriParams{
		Status:    maTeksNihil(maStrPtrNihil(f.Status)),
		Search:    maTeksNihil(maStrPtrNihil(f.Search)),
		SortField: f.SortField,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := gen.New(exec).ListKategori(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountKategori(ctx, gen.CountKategoriParams{Status: p.Status, Search: p.Search})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.KategoriProdukView, 0, len(rows))
	for _, r := range rows {
		out = append(out, viewDariListKategoriRow(r))
	}
	return out, int(total), nil
}

// MuatDetail — detail kategori (join induk + punya-mutasi) — nil bila absen.
func (r *KategoriRepository) MuatDetail(ctx context.Context, exec DBTX, id int64) (*types.KategoriProdukView, error) {
	rrow, err := gen.New(exec).MuatKategoriDetail(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	v := viewDariMuatKategoriDetailRow(rrow)
	return &v, nil
}

/* ------------------------------------------------------------------ */
/* Guard baris (fail berkode — dipakai service sebelum mutasi)         */
/* ------------------------------------------------------------------ */

// AssertAda — kategori hidup by id — 404 INV-018 bila tidak ada.
func (r *KategoriRepository) AssertAda(ctx context.Context, exec DBTX, id int64) (KategoriRow, error) {
	rrow, err := gen.New(exec).MuatKategoriHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return KategoriRow{}, errkontrak.NotFound(
				"Kategori id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		return KategoriRow{}, err
	}
	return dariMuatKategoriHidupRow(rrow), nil
}

// CariDupeNama — nama dipakai kategori hidup lain? (partial unique hidup).
func (r *KategoriRepository) CariDupeNama(ctx context.Context, exec DBTX, nama string, kecualiID *int64) (bool, error) {
	_, err := gen.New(exec).CariDupeNamaKategori(ctx, gen.CariDupeNamaKategoriParams{
		Nama:      nama,
		KecualiID: maI8Nilai(kecualiID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// AdaMutasi — punya mutasi gerakan? (via produk kategori ini).
func (r *KategoriRepository) AdaMutasi(ctx context.Context, exec DBTX, id int64) (bool, error) {
	n, err := gen.New(exec).AdaMutasiKategori(ctx, id)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// HitungAnak — jumlah kategori anak hidup (guard hapus INV-002).
func (r *KategoriRepository) HitungAnak(ctx context.Context, exec DBTX, id int64) (int, error) {
	n, err := gen.New(exec).HitungAnakKategori(ctx, pgtype.Int8{Int64: id, Valid: true})
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungProduk — jumlah produk hidup dalam kategori (guard hapus INV-002).
func (r *KategoriRepository) HitungProduk(ctx context.Context, exec DBTX, id int64) (int, error) {
	n, err := gen.New(exec).HitungProdukKategori(ctx, id)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

/* ------------------------------------------------------------------ */
/* Tulis                                                               */
/* ------------------------------------------------------------------ */

// Insert — kategori baru → KategoriRow lengkap.
func (r *KategoriRepository) Insert(ctx context.Context, exec DBTX, n KategoriBaru) (KategoriRow, error) {
	rrow, err := gen.New(exec).InsertKategori(ctx, gen.InsertKategoriParams{
		EntityID:             maUuidNilai(n.EntityID),
		Nama:                 n.Nama,
		IDKategoriInduk:      maI8Nilai(n.IDKategoriInduk),
		MetodeValuasi:        gen.EnumMetodeValuasi(n.MetodeValuasi),
		SistemValuasi:        gen.EnumSistemValuasi(n.SistemValuasi),
		KebijakanPelacakan:   gen.EnumPelacakan(n.KebijakanPelacakan),
		KebijakanKedaluwarsa: n.KebijakanKedaluwarsa,
		Status:               gen.EnumStatusAktif(n.Status),
	})
	if err != nil {
		return KategoriRow{}, err
	}
	return dariInsertKategoriRow(rrow), nil
}

// Update — kategori hidup + predicate version (STD-07); nil bila kalah.
func (r *KategoriRepository) Update(ctx context.Context, exec DBTX, id int64, versiHarap int32, s KategoriUbahSet) (*KategoriRow, error) {
	rrow, err := gen.New(exec).UpdateKategoriVersiHidup(ctx, gen.UpdateKategoriVersiHidupParams{
		Nama:                 s.Nama,
		IDKategoriInduk:      maI8Nilai(s.IDKategoriInduk),
		MetodeValuasi:        gen.EnumMetodeValuasi(s.MetodeValuasi),
		SistemValuasi:        gen.EnumSistemValuasi(s.SistemValuasi),
		KebijakanPelacakan:   gen.EnumPelacakan(s.KebijakanPelacakan),
		KebijakanKedaluwarsa: s.KebijakanKedaluwarsa,
		Status:               gen.EnumStatusAktif(s.Status),
		VersionBaru:          s.Version,
		UpdatedAt:            maWaktu(s.UpdatedAt),
		ID:                   id,
		VersiHarap:           versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := dariUpdateKategoriRow(rrow)
	return &row, nil
}

// HapusLunak — soft delete kategori hidup.
func (r *KategoriRepository) HapusLunak(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteKategori(ctx, gen.SoftDeleteKategoriParams{
		DeletedAt: maWaktu(deletedAt), UpdatedAt: maWaktu(updatedAt), ID: id,
	})
}
