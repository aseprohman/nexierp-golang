// mastera_unit.go + mastera_konversi.go — wrapper sqlc fitur UNIT UKUR
// (INV-F01 UOM K-05) & UNIT KONVERSI (patch 05) modul inv — padanan
// UnitRepository + UnitKonversiRepository NestJS: list/detail/guard/CRUD
// optimistic locking STD-07, guard hapus unit (produk/gerakan/konversi
// INV-002), pasangan dua arah D-34, mapper toUnitView/toKonversiView.
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

/* ================================================================== */
/* UNIT UKUR                                                           */
/* ================================================================== */

// UnitRow — baris mentah inv_unit_ukur.
type UnitRow struct {
	ID          int64
	Kode        string
	Nama        string
	KategoriUom string
	Status      string
	Version     int32
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// UnitBaru — nilai insert inv_unit_ukur.
type UnitBaru struct {
	EntityID    string
	Kode        string
	Nama        string
	KategoriUom string
	Status      string
}

// UnitUbahSet — nilai update inv_unit_ukur.
type UnitUbahSet struct {
	Kode        string
	Nama        string
	KategoriUom string
	Status      string
	Version     int32
	UpdatedAt   time.Time
}

// UnitRepository — wrapper sqlc fitur unit.
type UnitRepository struct{}

// NewUnit — konstruksi tanpa state.
func NewUnit() *UnitRepository { return &UnitRepository{} }

func unitDariValues(
	id int64, kode, nama string, kategoriUom string, status gen.EnumStatusAktif,
	version int32, createdAt, updatedAt pgtype.Timestamptz,
) UnitRow {
	return UnitRow{
		ID: id, Kode: kode, Nama: nama, KategoriUom: kategoriUom,
		Status: string(status), Version: version,
		CreatedAt: createdAt.Time, UpdatedAt: updatedAt.Time,
	}
}

func dariMuatUnitHidupRow(r gen.MuatUnitHidupRow) UnitRow {
	return unitDariValues(r.ID, r.Kode, r.Nama, r.KategoriUom, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
}

func dariInsertUnitRow(r gen.InsertUnitRow) UnitRow {
	return unitDariValues(r.ID, r.Kode, r.Nama, r.KategoriUom, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
}

func dariUpdateUnitRow(r gen.UpdateUnitVersiHidupRow) UnitRow {
	return unitDariValues(r.ID, r.Kode, r.Nama, r.KategoriUom, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
}

// ToUnitView — padanan toUnitView.
func ToUnitView(row UnitRow) types.UnitUkurView {
	return types.UnitUkurView{
		ID: row.ID, Kode: row.Kode, Nama: row.Nama, KategoriUom: row.KategoriUom,
		Status: row.Status, Version: row.Version,
		CreatedAt: maIsoWaktu(row.CreatedAt), UpdatedAt: maIsoWaktu(row.UpdatedAt),
	}
}

/* ------------------------------------------------------------------ */
/* Baca                                                                */
/* ------------------------------------------------------------------ */

// FilterUnit — filter list unit.
type FilterUnit struct {
	Status    string
	Search    string
	SortField string
	SortDesc  bool
	Limit     int32
	Offset    int32
}

// ListUnit — daftar unit hidup.
func (r *UnitRepository) ListUnit(ctx context.Context, exec DBTX, f FilterUnit) ([]types.UnitUkurView, int, error) {
	p := gen.ListUnitParams{
		Status:    maTeksNihil(maStrPtrNihil(f.Status)),
		Search:    maTeksNihil(maStrPtrNihil(f.Search)),
		SortField: f.SortField,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := gen.New(exec).ListUnit(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountUnit(ctx, gen.CountUnitParams{Status: p.Status, Search: p.Search})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.UnitUkurView, 0, len(rows))
	for _, r := range rows {
		out = append(out, ToUnitView(unitDariValues(r.ID, r.Kode, r.Nama, r.KategoriUom, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)))
	}
	return out, int(total), nil
}

/* ------------------------------------------------------------------ */
/* Guard baris                                                         */
/* ------------------------------------------------------------------ */

// AssertAda — unit hidup by id — 404 INV-018 (label 404 dinamis di sisi
// caller: "Unit"/"Unit asal"/"Unit tujuan" lewat AssertUnitDenganLabel).
func (r *UnitRepository) AssertAda(ctx context.Context, exec DBTX, id int64) (UnitRow, error) {
	return r.assertUnitDenganLabel(ctx, exec, id, "Unit")
}

// AssertUnitDenganLabel — assertUnit konversi (sisi asal/tujuan) — 404
// INV-018 dengan pesan `Unit ${sisi} id ${id} tidak ditemukan.`
func (r *UnitRepository) AssertUnitDenganLabel(ctx context.Context, exec DBTX, id int64, label string) (UnitRow, error) {
	return r.assertUnitDenganLabel(ctx, exec, id, label)
}

func (r *UnitRepository) assertUnitDenganLabel(ctx context.Context, exec DBTX, id int64, label string) (UnitRow, error) {
	rrow, err := gen.New(exec).MuatUnitHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return UnitRow{}, errkontrak.NotFound(
				label+" id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		return UnitRow{}, err
	}
	return dariMuatUnitHidupRow(rrow), nil
}

// CariDupeKode — kode dipakai baris lain? (UNIK GLOBAL TANPA deleted —
// verbatim cariDupeKode unit.repository NestJS).
func (r *UnitRepository) CariDupeKode(ctx context.Context, exec DBTX, kode string, kecualiID *int64) (bool, error) {
	_, err := gen.New(exec).CariDupeKodeUnit(ctx, gen.CariDupeKodeUnitParams{
		Kode:      kode,
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

// HitungProduk — jumlah produk hidup ber-unit ini (INV-002).
func (r *UnitRepository) HitungProduk(ctx context.Context, exec DBTX, id int64) (int, error) {
	n, err := gen.New(exec).HitungProdukUnit(ctx, id)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungGerakan — jumlah gerakan hidup ber-unit ini (INV-002).
func (r *UnitRepository) HitungGerakan(ctx context.Context, exec DBTX, id int64) (int, error) {
	n, err := gen.New(exec).HitungGerakanUnit(ctx, id)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// HitungKonversi — konversi hidup yang menyentuh unit (dari ATAU ke).
func (r *UnitRepository) HitungKonversi(ctx context.Context, exec DBTX, id int64) (int, error) {
	n, err := gen.New(exec).HitungKonversiUnit(ctx, id)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

/* ------------------------------------------------------------------ */
/* Tulis                                                               */
/* ------------------------------------------------------------------ */

// Insert — unit baru → UnitRow lengkap.
func (r *UnitRepository) Insert(ctx context.Context, exec DBTX, n UnitBaru) (UnitRow, error) {
	rrow, err := gen.New(exec).InsertUnit(ctx, gen.InsertUnitParams{
		EntityID:    maUuidNilai(n.EntityID),
		Kode:        n.Kode,
		Nama:        n.Nama,
		KategoriUom: n.KategoriUom,
		Status:      gen.EnumStatusAktif(n.Status),
	})
	if err != nil {
		return UnitRow{}, err
	}
	return dariInsertUnitRow(rrow), nil
}

// Update — unit hidup + predicate version (STD-07); nil bila kalah.
func (r *UnitRepository) Update(ctx context.Context, exec DBTX, id int64, versiHarap int32, s UnitUbahSet) (*UnitRow, error) {
	rrow, err := gen.New(exec).UpdateUnitVersiHidup(ctx, gen.UpdateUnitVersiHidupParams{
		Kode:        s.Kode,
		Nama:        s.Nama,
		KategoriUom: s.KategoriUom,
		Status:      gen.EnumStatusAktif(s.Status),
		VersionBaru: s.Version,
		UpdatedAt:   maWaktu(s.UpdatedAt),
		ID:          id,
		VersiHarap:  versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := dariUpdateUnitRow(rrow)
	return &row, nil
}

// HapusLunak — soft delete unit hidup.
func (r *UnitRepository) HapusLunak(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteUnit(ctx, gen.SoftDeleteUnitParams{
		DeletedAt: maWaktu(deletedAt), UpdatedAt: maWaktu(updatedAt), ID: id,
	})
}

/* ================================================================== */
/* UNIT KONVERSI (patch 05)                                            */
/* ================================================================== */

// KonversiRow — baris inv_unit_konversi + kedua unit (muatRow).
type KonversiRow struct {
	Konversi KonversiMurni
	Dari     UnitRow
	Ke       UnitRow
}

// KonversiMurni — kolom inv_unit_konversi.
type KonversiMurni struct {
	ID         int64
	IDUnitDari int64
	IDUnitKe   int64
	Faktor     string // teks numeric(18,6) — Number() di view
	Status     string
	Version    int32
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

// KonversiBaru — nilai insert inv_unit_konversi.
type KonversiBaru struct {
	EntityID   string
	IDUnitDari int64
	IDUnitKe   int64
	Faktor     string // toFixed(6) dari service
	Status     string
}

// KonversiUbahSet — nilai update inv_unit_konversi.
type KonversiUbahSet struct {
	IDUnitDari int64
	IDUnitKe   int64
	Faktor     string
	Status     string
	Version    int32
	UpdatedAt  time.Time
}

// UnitKonversiRepository — wrapper sqlc fitur konversi.
type UnitKonversiRepository struct{}

// NewUnitKonversi — konstruksi tanpa state.
func NewUnitKonversi() *UnitKonversiRepository { return &UnitKonversiRepository{} }

func konversiDariValues(
	id, idDari int64, kodeDari, namaDari string, idKe int64, kodeKe, namaKe string,
	faktor string, status gen.EnumStatusAktif, version int32,
	createdAt, updatedAt pgtype.Timestamptz,
) KonversiRow {
	return KonversiRow{
		Konversi: KonversiMurni{
			ID: id, IDUnitDari: idDari, IDUnitKe: idKe, Faktor: faktor,
			Status: string(status), Version: version,
			CreatedAt: createdAt.Time, UpdatedAt: updatedAt.Time,
		},
		Dari: unitDariValues(idDari, kodeDari, namaDari, "", "AKTIF", 0, createdAt, updatedAt),
		Ke:   unitDariValues(idKe, kodeKe, namaKe, "", "AKTIF", 0, createdAt, updatedAt),
	}
}

func dariListKonversiRow(r gen.ListKonversiRow) KonversiRow {
	return konversiDariValues(r.ID, r.IDUnitDari, r.KodeUnitDari, r.NamaUnitDari,
		r.IDUnitKe, r.KodeUnitKe, r.NamaUnitKe, r.Faktor, r.Status, r.Version,
		r.CreatedAt, r.UpdatedAt)
}

// ToKonversiView — padanan toKonversiView (faktor Number(text)).
func ToKonversiView(row KonversiRow) types.UnitKonversiView {
	return types.UnitKonversiView{
		ID:           row.Konversi.ID,
		IDUnitDari:   row.Konversi.IDUnitDari,
		KodeUnitDari: row.Dari.Kode,
		NamaUnitDari: row.Dari.Nama,
		IDUnitKe:     row.Konversi.IDUnitKe,
		KodeUnitKe:   row.Ke.Kode,
		NamaUnitKe:   row.Ke.Nama,
		Faktor:       maAngka(row.Konversi.Faktor),
		Status:       row.Konversi.Status,
		Version:      row.Konversi.Version,
		CreatedAt:    maIsoWaktu(row.Konversi.CreatedAt),
		UpdatedAt:    maIsoWaktu(row.Konversi.UpdatedAt),
	}
}

/* ------------------------------------------------------------------ */
/* Baca                                                                */
/* ------------------------------------------------------------------ */

// FilterKonversi — filter list konversi.
type FilterKonversi struct {
	Status    string
	Search    string
	SortField string
	SortDesc  bool
	Limit     int32
	Offset    int32
}

// ListKonversi — daftar konversi hidup + kedua unit.
func (r *UnitKonversiRepository) ListKonversi(ctx context.Context, exec DBTX, f FilterKonversi) ([]types.UnitKonversiView, int, error) {
	p := gen.ListKonversiParams{
		Status:    maTeksNihil(maStrPtrNihil(f.Status)),
		Search:    maTeksNihil(maStrPtrNihil(f.Search)),
		SortField: f.SortField,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := gen.New(exec).ListKonversi(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountKonversi(ctx, gen.CountKonversiParams{Status: p.Status, Search: p.Search})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.UnitKonversiView, 0, len(rows))
	for _, r := range rows {
		out = append(out, ToKonversiView(dariListKonversiRow(r)))
	}
	return out, int(total), nil
}

// MuatRow — konversi hidup by id + kedua unit — nil bila absen.
func (r *UnitKonversiRepository) MuatRow(ctx context.Context, exec DBTX, id int64) (*KonversiRow, error) {
	rrow, err := gen.New(exec).MuatKonversiRow(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	row := konversiDariValues(rrow.ID, rrow.IDUnitDari, rrow.KodeUnitDari, rrow.NamaUnitDari,
		rrow.IDUnitKe, rrow.KodeUnitKe, rrow.NamaUnitKe, rrow.Faktor, rrow.Status,
		rrow.Version, rrow.CreatedAt, rrow.UpdatedAt)
	return &row, nil
}

/* ------------------------------------------------------------------ */
/* Guard / Tulis                                                       */
/* ------------------------------------------------------------------ */

// CariPasanganTerpakai — pasangan (dari→ke maupun balik ke→dari) sudah
// dipakai konversi hidup lain? (kecualiID lompat diri — keputusan D-34 di
// service).
func (r *UnitKonversiRepository) CariPasanganTerpakai(ctx context.Context, exec DBTX, idDari, idKe int64, kecualiID *int64) (bool, error) {
	_, err := gen.New(exec).CariPasanganTerpakai(ctx, gen.CariPasanganTerpakaiParams{
		IDDari:    idDari,
		IDKe:      idKe,
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

// Insert — konversi baru → kolom murni (label unit di service dari
// assertUnit — persis toKonversiView(row, dari, ke) sumber).
func (r *UnitKonversiRepository) Insert(ctx context.Context, exec DBTX, n KonversiBaru) (KonversiMurni, error) {
	rrow, err := gen.New(exec).InsertKonversi(ctx, gen.InsertKonversiParams{
		EntityID:   maUuidNilai(n.EntityID),
		IDUnitDari: n.IDUnitDari,
		IDUnitKe:   n.IDUnitKe,
		Faktor:     maNumericDari(&n.Faktor),
		Status:     gen.EnumStatusAktif(n.Status),
	})
	if err != nil {
		return KonversiMurni{}, err
	}
	return KonversiMurni{
		ID: rrow.ID, IDUnitDari: rrow.IDUnitDari, IDUnitKe: rrow.IDUnitKe,
		Faktor: rrow.Faktor, Status: string(rrow.Status), Version: rrow.Version,
		CreatedAt: rrow.CreatedAt.Time, UpdatedAt: rrow.UpdatedAt.Time,
	}, nil
}

// Update — konversi hidup + predicate version (STD-07); nil bila kalah.
func (r *UnitKonversiRepository) Update(ctx context.Context, exec DBTX, id int64, versiHarap int32, s KonversiUbahSet) (*KonversiMurni, error) {
	rrow, err := gen.New(exec).UpdateKonversiVersiHidup(ctx, gen.UpdateKonversiVersiHidupParams{
		IDUnitDari:  s.IDUnitDari,
		IDUnitKe:    s.IDUnitKe,
		Faktor:      maNumericDari(&s.Faktor),
		Status:      gen.EnumStatusAktif(s.Status),
		VersionBaru: s.Version,
		UpdatedAt:   maWaktu(s.UpdatedAt),
		ID:          id,
		VersiHarap:  versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &KonversiMurni{
		ID: rrow.ID, IDUnitDari: rrow.IDUnitDari, IDUnitKe: rrow.IDUnitKe,
		Faktor: rrow.Faktor, Status: string(rrow.Status), Version: rrow.Version,
		CreatedAt: rrow.CreatedAt.Time, UpdatedAt: rrow.UpdatedAt.Time,
	}, nil
}

// HapusLunak — soft delete konversi hidup.
func (r *UnitKonversiRepository) HapusLunak(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteKonversi(ctx, gen.SoftDeleteKonversiParams{
		DeletedAt: maWaktu(deletedAt), UpdatedAt: maWaktu(updatedAt), ID: id,
	})
}
