// repository/gudang.go — SATU-SATUNYA pengguna pgx+sqlc fitur GUDANG modul
// inv (padanan GudangRepository NestJS; tabel inv_gudang + read
// inv_lokasi_stok guard hapus INV-002 + rantai wilayah CORE 4 level, ddl/48
// 3NF tanpa salinan nama — kondisi hidup di ON-join). Mapping baris → view
// (kontrak JSON = packages/schemas inv/views.ts GudangView) di sini.
// Executor (pool | tx) diteruskan pemanggil; keputusan cakupan 'storages'
// diterjemahkan service lewat CakupanStorages.
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository/gen"
)

// GudangRow — baris inv_gudang (pgtype telah dikonversi; dipakai service).
type GudangRow struct {
	ID              int64
	EntityID        string
	Kode            string
	Nama            string
	KodeSatuan      *string
	Alamat          *string
	Status          string
	Version         int32
	CreatedAt       time.Time
	UpdatedAt       time.Time
	DeletedAt       *time.Time
	IDCoreKelurahan *int64
	Latitude        *float64
	Longitude       *float64
}

// GudangRantaiRow — baris gudang + rantai wilayah hasil LEFT JOIN master
// CORE (semua nullable — baris tetap selamat saat master wilayah
// lunak-dihapus; nama rantai null → view wilayah null).
type GudangRantaiRow struct {
	GudangRow
	IDCoreKecamatan *int64
	IDCoreKota      *int64
	IDCoreProvinsi  *int64
	KelurahanNama   *string
	KecamatanNama   *string
	KotaNama        *string
	ProvinsiNama    *string
	KodePos         *string
}

// GudangWilayahView — rantai wilayah CORE (kunci cermin gudangWilayahViewSchema).
type GudangWilayahView struct {
	IDKelurahan   int64   `json:"idKelurahan"`
	IDKecamatan   int64   `json:"idKecamatan"`
	IDKota        int64   `json:"idKota"`
	IDProvinsi    int64   `json:"idProvinsi"`
	KelurahanNama string  `json:"kelurahanNama"`
	KecamatanNama string  `json:"kecamatanNama"`
	KotaNama      string  `json:"kotaNama"`
	ProvinsiNama  string  `json:"provinsiNama"`
	KodePos       *string `json:"kodePos"`
}

// GudangView — kontrak respons gudang (kunci cermin gudangViewSchema).
type GudangView struct {
	ID              int64              `json:"id"`
	Kode            string             `json:"kode"`
	Nama            string             `json:"nama"`
	KodeSatuan      *string            `json:"kodeSatuan"`
	Alamat          *string            `json:"alamat"`
	IDCoreKelurahan *int64             `json:"idCoreKelurahan"`
	Wilayah         *GudangWilayahView `json:"wilayah"`
	Latitude        *float64           `json:"latitude"`
	Longitude       *float64           `json:"longitude"`
	Status          string             `json:"status"`
	Version         int32              `json:"version"`
	CreatedAt       string             `json:"createdAt"`
	UpdatedAt       string             `json:"updatedAt"`
}

// Whitelist sort gudang (persis peta kolom drizzlePageBounds repo sumber —
// hanya 4 alias ini; "created_at" TIDAK dikenal di fitur ini).
var whitelistSortGudang = []string{"kode", "nama", "createdAt", "updatedAt"}

var kanonikSortGudang = map[string]string{
	"kode":      "kode",
	"nama":      "nama",
	"createdAt": "created_at",
	"updatedAt": "updated_at",
}

// GudangRepository — pembungkus gen.Querier fitur gudang (tanpa state;
// executor diteruskan per method).
type GudangRepository struct{}

// NewGudangRepository — konstruksi repo gudang.
func NewGudangRepository() *GudangRepository { return &GudangRepository{} }

// fromGudangRantai — konversi pgtype → baris polos.
func fromGudangRantai(r gen.ListGudangRantaiRow) GudangRantaiRow {
	return GudangRantaiRow{
		GudangRow: GudangRow{
			ID:              r.ID,
			EntityID:        mbUUIDString(r.EntityID),
			Kode:            r.Kode,
			Nama:            r.Nama,
			KodeSatuan:      mbTxt(r.KodeSatuan),
			Alamat:          mbTxt(r.Alamat),
			Status:          string(r.Status),
			Version:         r.Version,
			CreatedAt:       r.CreatedAt.Time,
			UpdatedAt:       r.UpdatedAt.Time,
			DeletedAt:       mbTimePtr(r.DeletedAt),
			IDCoreKelurahan: mbInt8(r.IDCoreKelurahan),
			Latitude:        mbNum(r.Latitude),
			Longitude:       mbNum(r.Longitude),
		},
		IDCoreKecamatan: mbInt8(r.IDCoreKecamatan),
		IDCoreKota:      mbInt8(r.IDCoreKota),
		IDCoreProvinsi:  mbInt8(r.IDCoreProvinsi),
		KelurahanNama:   mbTxt(r.KelurahanNama),
		KecamatanNama:   mbTxt(r.KecamatanNama),
		KotaNama:        mbTxt(r.KotaNama),
		ProvinsiNama:    mbTxt(r.ProvinsiNama),
		KodePos:         mbTxt(r.KodePos),
	}
}

// GudangToView — padanan toGudangView (numeric PG → number; nama rantai
// null → view wilayah null).
func GudangToView(row GudangRantaiRow) GudangView {
	lengkap := row.IDCoreKelurahan != nil &&
		row.KelurahanNama != nil &&
		row.KecamatanNama != nil &&
		row.KotaNama != nil &&
		row.ProvinsiNama != nil
	var wilayah *GudangWilayahView
	if lengkap {
		wilayah = &GudangWilayahView{
			IDKelurahan:   *row.IDCoreKelurahan,
			IDKecamatan:   *row.IDCoreKecamatan,
			IDKota:        *row.IDCoreKota,
			IDProvinsi:    *row.IDCoreProvinsi,
			KelurahanNama: *row.KelurahanNama,
			KecamatanNama: *row.KecamatanNama,
			KotaNama:      *row.KotaNama,
			ProvinsiNama:  *row.ProvinsiNama,
			KodePos:       row.KodePos,
		}
	}
	return GudangView{
		ID:              row.ID,
		Kode:            row.Kode,
		Nama:            row.Nama,
		KodeSatuan:      row.KodeSatuan,
		Alamat:          row.Alamat,
		IDCoreKelurahan: row.IDCoreKelurahan,
		Wilayah:         wilayah,
		Latitude:        row.Latitude,
		Longitude:       row.Longitude,
		Status:          row.Status,
		Version:         row.Version,
		CreatedAt:       mbIso(pgtypeTz(row.CreatedAt)),
		UpdatedAt:       mbIso(pgtypeTz(row.UpdatedAt)),
	}
}

// pgtypeTz — time.Time polos → pgtype.Timestamptz (util mapper view).
func pgtypeTz(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

// mbUUIDString — pgtype.UUID → string uuid standar.
func mbUUIDString(u pgtype.UUID) string {
	if !u.Valid {
		return ""
	}
	return fmtUUID(u.Bytes)
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// ListGudang — halaman gudang paged rantai wilayah — filter status/search;
// cakupan 'storages' aktor (nil = SEMUA; DENY_ALL → halaman kosong —
// verbatim buildPage([], 0); DAFTAR → id IN whitelist). Sort whitelist 4
// alias, default kode ASC.
func (r *GudangRepository) ListGudang(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest, cakupan *CakupanStorages) (errkontrak.Page[GudangView], error) {
	if err := mbSortCek(pr, whitelistSortGudang); err != nil {
		return errkontrak.Page[GudangView]{}, err
	}
	if cakupan != nil && cakupan.Deny {
		return errkontrak.BuildPage([]GudangView{}, 0, pr), nil
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortGudang)
	var ids []int64
	if cakupan != nil {
		ids = cakupan.IDs
	}
	params := gen.ListGudangRantaiParams{
		Status:   mbTxtNil(filterVal(pr, "status")),
		Search:   mbTxtNil(filterVal(pr, "search")),
		Ids:      ids,
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   pageOffset(pr),
		Limit:    pageLimit(pr),
	}
	rows, err := gen.New(exec).ListGudangRantai(ctx, params)
	if err != nil {
		return errkontrak.Page[GudangView]{}, err
	}
	total, err := gen.New(exec).CountGudang(ctx, gen.CountGudangParams{
		Status: params.Status,
		Search: params.Search,
		Ids:    params.Ids,
	})
	if err != nil {
		return errkontrak.Page[GudangView]{}, err
	}
	views := make([]GudangView, 0, len(rows))
	for _, row := range rows {
		views = append(views, GudangToView(fromGudangRantai(row)))
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// RantaiByID — baris rantai satu gudang — nil bila absen.
func (r *GudangRepository) RantaiByID(ctx context.Context, exec gen.DBTX, id int64) (*GudangRantaiRow, error) {
	row, err := gen.New(exec).GudangRantaiByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromGudangRantai(listRowDariRantai(row))
	return &out, nil
}

// listRowDariRantai — samakan tipe baris rantai-by-id dengan baris list
// (kolom identik — sqlc memisahkan tipe per query).
func listRowDariRantai(r gen.GudangRantaiByIDRow) gen.ListGudangRantaiRow {
	return gen.ListGudangRantaiRow{
		ID: r.ID, EntityID: r.EntityID, Kode: r.Kode, Nama: r.Nama,
		KodeSatuan: r.KodeSatuan, Alamat: r.Alamat, Status: r.Status,
		Version: r.Version, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		DeletedAt: r.DeletedAt, IDCoreKelurahan: r.IDCoreKelurahan,
		Latitude: r.Latitude, Longitude: r.Longitude,
		IDCoreKecamatan: r.IDCoreKecamatan, IDCoreKota: r.IDCoreKota,
		IDCoreProvinsi: r.IDCoreProvinsi, KelurahanNama: r.KelurahanNama,
		KecamatanNama: r.KecamatanNama, KotaNama: r.KotaNama,
		ProvinsiNama: r.ProvinsiNama, KodePos: r.KodePos,
	}
}

// AssertAda — gudang by id + rantai wilayah — 404 INV-018 bila absen/
// lunak-dihapus (padanan assertAda yang melempar DomainError).
func (r *GudangRepository) AssertAda(ctx context.Context, exec gen.DBTX, id int64) (GudangRantaiRow, error) {
	row, err := r.RantaiByID(ctx, exec, id)
	if err != nil {
		return GudangRantaiRow{}, err
	}
	if row == nil || row.DeletedAt != nil {
		return GudangRantaiRow{}, errkontrak.NotFound(
			"Gudang id "+strconvI64(id)+" tidak ditemukan.",
			domain.KodeInvTidakDitemukan,
		)
	}
	return *row, nil
}

// CariDupeKode — kode gudang sudah dipakai (uq GLOBAL — TANPA filter
// deleted, verbatim sumber)? — nil bila bebas.
func (r *GudangRepository) CariDupeKode(ctx context.Context, exec gen.DBTX, kode string) (*int64, error) {
	id, err := gen.New(exec).GudangDupeKode(ctx, kode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// CariKelurahanHidup — kelurahan CORE hidup by id (SOFT-DELETE-AWARE) —
// nil bila absen/lunak-dihapus.
func (r *GudangRepository) CariKelurahanHidup(ctx context.Context, exec gen.DBTX, idKelurahan int64) (*int64, error) {
	id, err := gen.New(exec).KelurahanHidup(ctx, idKelurahan)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// HitungLokasi — jumlah lokasi stok hidup dalam gudang (guard hapus INV-002).
func (r *GudangRepository) HitungLokasi(ctx context.Context, exec gen.DBTX, id int64) (int32, error) {
	return gen.New(exec).CountLokasiGudang(ctx, id)
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// GudangBaru — nilai insert inv_gudang (koordinat sudah float; entity_id
// dibangun service).
type GudangBaru struct {
	EntityID        string
	Kode            string
	Nama            string
	KodeSatuan      *string
	Alamat          *string
	IDCoreKelurahan *int64
	Latitude        *float64
	Longitude       *float64
	Status          string
}

// InsertGudang — insert gudang baru → baris polos (23505 race DITITIPKAN
// mentah — dipetakan 409 pesan pre-check oleh service).
func (r *GudangRepository) InsertGudang(ctx context.Context, exec gen.DBTX, v GudangBaru) (GudangRow, error) {
	row, err := gen.New(exec).InsertGudang(ctx, gen.InsertGudangParams{
		EntityID:        mbUUID(v.EntityID),
		Kode:            v.Kode,
		Nama:            v.Nama,
		KodeSatuan:      mbTxtNil(v.KodeSatuan),
		Alamat:          mbTxtNil(v.Alamat),
		IDCoreKelurahan: mbInt8Nil(v.IDCoreKelurahan),
		Latitude:        mbNumNil(v.Latitude),
		Longitude:       mbNumNil(v.Longitude),
		Status:          gen.EnumStatusAktif(v.Status),
	})
	if err != nil {
		return GudangRow{}, err
	}
	return gudangRowDariGen(row), nil
}

// GudangUbahSet — set update gudang hasil merge service (version+1 di sana).
type GudangUbahSet struct {
	Nama            string
	KodeSatuan      *string
	Alamat          *string
	IDCoreKelurahan *int64
	Latitude        *float64
	Longitude       *float64
	Status          string
	Version         int32
	UpdatedAt       time.Time
}

// UpdateGudangHidup — update gudang hidup — predicate id + hidup + version
// (optimistic locking atomik STD-07); nil bila kalah balapan (0 baris) →
// 409 INV-017 di service.
func (r *GudangRepository) UpdateGudangHidup(ctx context.Context, exec gen.DBTX, id int64, versiHarap int32, set GudangUbahSet) (*GudangRow, error) {
	row, err := gen.New(exec).UpdateGudangHidup(ctx, gen.UpdateGudangHidupParams{
		Nama:            set.Nama,
		KodeSatuan:      mbTxtNil(set.KodeSatuan),
		Alamat:          mbTxtNil(set.Alamat),
		IDCoreKelurahan: mbInt8Nil(set.IDCoreKelurahan),
		Latitude:        mbNumNil(set.Latitude),
		Longitude:       mbNumNil(set.Longitude),
		Status:          gen.EnumStatusAktif(set.Status),
		Version:         set.Version,
		UpdatedAt:       mbTz(set.UpdatedAt),
		ID:              id,
		VersiHarap:      versiHarap,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := gudangRowDariGen(row)
	return &out, nil
}

// HapusLunakGudang — soft delete (set deletedAt/updatedAt — TANPA bump
// version, verbatim sumber).
func (r *GudangRepository) HapusLunakGudang(ctx context.Context, exec gen.DBTX, id int64, saat time.Time) error {
	return gen.New(exec).HapusLunakGudang(ctx, gen.HapusLunakGudangParams{
		DeletedAt: mbTz(saat),
		UpdatedAt: mbTz(saat),
		ID:        id,
	})
}

// gudangRowDariGen — konversi baris RETURNING (tanpa join) → baris polos.
func gudangRowDariGen(r gen.InvGudang) GudangRow {
	return GudangRow{
		ID:              r.ID,
		EntityID:        mbUUIDString(r.EntityID),
		Kode:            r.Kode,
		Nama:            r.Nama,
		KodeSatuan:      mbTxt(r.KodeSatuan),
		Alamat:          mbTxt(r.Alamat),
		Status:          string(r.Status),
		Version:         r.Version,
		CreatedAt:       r.CreatedAt.Time,
		UpdatedAt:       r.UpdatedAt.Time,
		DeletedAt:       mbTimePtr(r.DeletedAt),
		IDCoreKelurahan: mbInt8(r.IDCoreKelurahan),
		Latitude:        mbNum(r.Latitude),
		Longitude:       mbNum(r.Longitude),
	}
}
