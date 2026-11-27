// repository/lokasi.go — SATU-SATUNYA pengguna pgx+sqlc fitur LOKASI STOK
// modul inv (padanan LokasiRepository NestJS — node perhitungan stok; tabel
// inv_lokasi_stok + join inv_gudang/inv_lokasi_stok alias + read
// inv_saldo_stok guard hapus INV-014 COALESCE SUM). Mapping baris → view
// (kontrak JSON = packages/schemas inv/views.ts LokasiStokView) di sini.
// DATA-SCOPE 'storages' hanya menyentuh lokasi INTERNAL; predikat lokasi
// virtual SELALU tampil dibangun di query (scope_deny/scope_ids).
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
)

// LokasiRow — baris inv_lokasi_stok (pgtype telah dikonversi).
type LokasiRow struct {
	ID            int64
	EntityID      string
	Kode          string
	Nama          string
	Jenis         string
	IDInvGudang   *int64
	IDLokasiInduk *int64
	Status        string
	Version       int32
	CreatedAt     time.Time
	UpdatedAt     time.Time
	DeletedAt     *time.Time
}

// LokasiDenganNama — baris lokasi + nama gudang induk + nama lokasi induk
// (hasil muatDetail).
type LokasiDenganNama struct {
	Lokasi     LokasiRow
	NamaGudang *string
	NamaInduk  *string
}

// LokasiStokView — kontrak respons lokasi (kunci cermin lokasiStokViewSchema).
type LokasiStokView struct {
	ID            int64   `json:"id"`
	Kode          string  `json:"kode"`
	Nama          string  `json:"nama"`
	Jenis         string  `json:"jenis"`
	IDInvGudang   *int64  `json:"idInvGudang"`
	NamaGudang    *string `json:"namaGudang"`
	IDLokasiInduk *int64  `json:"idLokasiInduk"`
	NamaInduk     *string `json:"namaInduk"`
	Status        string  `json:"status"`
	Version       int32   `json:"version"`
	CreatedAt     string  `json:"createdAt"`
	UpdatedAt     string  `json:"updatedAt"`
}

// Whitelist sort lokasi (persis peta kolom drizzlePageBounds repo sumber).
var whitelistSortLokasi = []string{"kode", "nama", "createdAt", "updatedAt"}

var kanonikSortLokasi = map[string]string{
	"kode":      "kode",
	"nama":      "nama",
	"createdAt": "created_at",
	"updatedAt": "updated_at",
}

// LokasiRepository — pembungkus gen.Querier fitur lokasi.
type LokasiRepository struct{}

// NewLokasiRepository — konstruksi repo lokasi.
func NewLokasiRepository() *LokasiRepository { return &LokasiRepository{} }

// fromLokasiRowGen — konversi baris RETURNING/tanpa-join → baris polos.
func fromLokasiRowGen(r gen.InvLokasiStok) LokasiRow {
	return LokasiRow{
		ID:            r.ID,
		EntityID:      mbUUIDString(r.EntityID),
		Kode:          r.Kode,
		Nama:          r.Nama,
		Jenis:         string(r.Jenis),
		IDInvGudang:   mbInt8(r.IDInvGudang),
		IDLokasiInduk: mbInt8(r.IDLokasiInduk),
		Status:        string(r.Status),
		Version:       r.Version,
		CreatedAt:     r.CreatedAt.Time,
		UpdatedAt:     r.UpdatedAt.Time,
		DeletedAt:     mbTimePtr(r.DeletedAt),
	}
}

// LokasiToView — padanan toLokasiView.
func LokasiToView(row LokasiRow, namaGudang, namaInduk *string) LokasiStokView {
	return LokasiStokView{
		ID:            row.ID,
		Kode:          row.Kode,
		Nama:          row.Nama,
		Jenis:         row.Jenis,
		IDInvGudang:   row.IDInvGudang,
		NamaGudang:    namaGudang,
		IDLokasiInduk: row.IDLokasiInduk,
		NamaInduk:     namaInduk,
		Status:        row.Status,
		Version:       row.Version,
		CreatedAt:     mbIso(pgtypeTz(row.CreatedAt)),
		UpdatedAt:     mbIso(pgtypeTz(row.UpdatedAt)),
	}
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// filterLokasi — susun params filter+cakupan bersama List & Count.
func filterLokasi(pr *errkontrak.PageRequest, cakupan *CakupanStorages) (gen.ListLokasiParams, error) {
	idGudang, err := filterNumVal(pr, "idGudang")
	if err != nil {
		return gen.ListLokasiParams{}, err
	}
	var deny bool
	var ids []int64
	if cakupan != nil {
		deny = cakupan.Deny
		ids = cakupan.IDs
	}
	return gen.ListLokasiParams{
		Jenis:     mbTxtNil(filterVal(pr, "jenis")),
		IDGudang:  idGudang,
		Search:    mbTxtNil(filterVal(pr, "search")),
		ScopeDeny: deny,
		ScopeIds:  ids,
	}, nil
}

// ListLokasi — halaman lokasi paged + nama gudang/induk — filter jenis/
// idGudang/search; cakupan 'storages' (nil = SEMUA; DENY_ALL → hanya
// virtual; DAFTAR → OR(virtual, gudang IN whitelist)). Sort whitelist 4
// alias, default kode ASC.
func (r *LokasiRepository) ListLokasi(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest, cakupan *CakupanStorages) (errkontrak.Page[LokasiStokView], error) {
	if err := mbSortCek(pr, whitelistSortLokasi); err != nil {
		return errkontrak.Page[LokasiStokView]{}, err
	}
	base, err := filterLokasi(pr, cakupan)
	if err != nil {
		return errkontrak.Page[LokasiStokView]{}, err
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortLokasi)
	base.SortCol, base.SortDesc, base.Offset, base.Limit = sortCol, sortDesc, pageOffset(pr), pageLimit(pr)
	rows, err := gen.New(exec).ListLokasi(ctx, base)
	if err != nil {
		return errkontrak.Page[LokasiStokView]{}, err
	}
	total, err := gen.New(exec).CountLokasi(ctx, gen.CountLokasiParams{
		Jenis:     base.Jenis,
		IDGudang:  base.IDGudang,
		Search:    base.Search,
		ScopeDeny: base.ScopeDeny,
		ScopeIds:  base.ScopeIds,
	})
	if err != nil {
		return errkontrak.Page[LokasiStokView]{}, err
	}
	views := make([]LokasiStokView, 0, len(rows))
	for _, row := range rows {
		views = append(views, LokasiToView(fromLokasiRowGen(rowToLokasi(row)), mbTxt(row.NamaGudang), mbTxt(row.NamaInduk)))
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// rowToLokasi — potong kolom lokasi dari baris join (12 kolom pertama).
func rowToLokasi(r gen.ListLokasiRow) gen.InvLokasiStok {
	return gen.InvLokasiStok{
		ID: r.ID, EntityID: r.EntityID, Kode: r.Kode, Nama: r.Nama,
		Jenis: r.Jenis, IDInvGudang: r.IDInvGudang, IDLokasiInduk: r.IDLokasiInduk,
		Status: r.Status, Version: r.Version, CreatedAt: r.CreatedAt,
		UpdatedAt: r.UpdatedAt, DeletedAt: r.DeletedAt,
	}
}

// MuatDetail — detail lokasi hidup + nama gudang/induk — nil bila absen/
// lunak-dihapus.
func (r *LokasiRepository) MuatDetail(ctx context.Context, exec gen.DBTX, id int64) (*LokasiDenganNama, error) {
	row, err := gen.New(exec).LokasiDetail(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &LokasiDenganNama{
		Lokasi:     fromLokasiRowGen(rowToLokasiDetail(row)),
		NamaGudang: mbTxt(row.NamaGudang),
		NamaInduk:  mbTxt(row.NamaInduk),
	}, nil
}

// rowToLokasiDetail — potong kolom lokasi dari baris detail.
func rowToLokasiDetail(r gen.LokasiDetailRow) gen.InvLokasiStok {
	return gen.InvLokasiStok{
		ID: r.ID, EntityID: r.EntityID, Kode: r.Kode, Nama: r.Nama,
		Jenis: r.Jenis, IDInvGudang: r.IDInvGudang, IDLokasiInduk: r.IDLokasiInduk,
		Status: r.Status, Version: r.Version, CreatedAt: r.CreatedAt,
		UpdatedAt: r.UpdatedAt, DeletedAt: r.DeletedAt,
	}
}

/* -------------------------------------------------------------- */
/* Guard baris & hitungan                                          */
/* -------------------------------------------------------------- */

// MuatByID — lokasi hidup by id tanpa join — nil bila absen/terhapus.
func (r *LokasiRepository) MuatByID(ctx context.Context, exec gen.DBTX, id int64) (*LokasiRow, error) {
	row, err := gen.New(exec).LokasiHidupByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromLokasiRowGen(row)
	return &out, nil
}

// CariDupeKode — kode lokasi sudah dipakai (uq GLOBAL — TANPA filter
// deleted, verbatim sumber)? — nil bila bebas.
func (r *LokasiRepository) CariDupeKode(ctx context.Context, exec gen.DBTX, kode string) (*int64, error) {
	id, err := gen.New(exec).LokasiDupeKode(ctx, kode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// HitungSaldo — total saldo on-hand lokasi (guard hapus INV-014 — saldo ≠ 0
// ditolak; COALESCE SUM atas baris hidup).
func (r *LokasiRepository) HitungSaldo(ctx context.Context, exec gen.DBTX, id int64) (int32, error) {
	return gen.New(exec).SaldoLokasi(ctx, id)
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// LokasiBaru — nilai insert inv_lokasi_stok (dibangun service).
type LokasiBaru struct {
	EntityID      string
	Kode          string
	Nama          string
	Jenis         string
	IDInvGudang   *int64
	IDLokasiInduk *int64
	Status        string
}

// InsertLokasi — insert lokasi baru → baris polos (23505 race DITITIPKAN
// mentah — dipetakan 409 pesan pre-check oleh service).
func (r *LokasiRepository) InsertLokasi(ctx context.Context, exec gen.DBTX, v LokasiBaru) (LokasiRow, error) {
	row, err := gen.New(exec).InsertLokasi(ctx, gen.InsertLokasiParams{
		EntityID:      mbUUID(v.EntityID),
		Kode:          v.Kode,
		Nama:          v.Nama,
		Jenis:         gen.EnumJenisLokasi(v.Jenis),
		IDInvGudang:   mbInt8Nil(v.IDInvGudang),
		IDLokasiInduk: mbInt8Nil(v.IDLokasiInduk),
		Status:        gen.EnumStatusAktif(v.Status),
	})
	if err != nil {
		return LokasiRow{}, err
	}
	return fromLokasiRowGen(row), nil
}

// LokasiUbahSet — set update lokasi hasil merge service.
type LokasiUbahSet struct {
	Nama          string
	Jenis         string
	IDInvGudang   *int64
	IDLokasiInduk *int64
	Status        string
	Version       int32
	UpdatedAt     time.Time
}

// UpdateLokasiHidup — update lokasi hidup — predicate id + hidup + version
// (STD-07); nil bila kalah balapan → 409 INV-017 di service.
func (r *LokasiRepository) UpdateLokasiHidup(ctx context.Context, exec gen.DBTX, id int64, versiHarap int32, set LokasiUbahSet) (*LokasiRow, error) {
	row, err := gen.New(exec).UpdateLokasiHidup(ctx, gen.UpdateLokasiHidupParams{
		Nama:          set.Nama,
		Jenis:         gen.EnumJenisLokasi(set.Jenis),
		IDInvGudang:   mbInt8Nil(set.IDInvGudang),
		IDLokasiInduk: mbInt8Nil(set.IDLokasiInduk),
		Status:        gen.EnumStatusAktif(set.Status),
		Version:       set.Version,
		UpdatedAt:     mbTz(set.UpdatedAt),
		ID:            id,
		VersiHarap:    versiHarap,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromLokasiRowGen(row)
	return &out, nil
}

// HapusLunakLokasi — soft delete (TANPA bump version, verbatim sumber).
func (r *LokasiRepository) HapusLunakLokasi(ctx context.Context, exec gen.DBTX, id int64, saat time.Time) error {
	return gen.New(exec).HapusLunakLokasi(ctx, gen.HapusLunakLokasiParams{
		DeletedAt: mbTz(saat),
		UpdatedAt: mbTz(saat),
		ID:        id,
	})
}
