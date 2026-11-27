// mastera_kemasan.go — SATU-SATUNYA pengguna sqlc fitur KEMASAN modul inv
// (padanan KemasanRepository NestJS — patch 04 P1 #10): kemasan jual per
// produk (DUS-12 berisi 12) — list paginated + filter, guard kode unik
// GLOBAL (sesuai DB — tanpa filter deleted_at) & barcode partial hidup,
// CRUD + optimistic locking STD-07, soft delete, lookup barcode scanner F15
// → {kemasan, produk ringkas, qtyIsi}. Mapper kemasanToView di sini —
// bentuk JSON = types.KemasanView.
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

// KemasanRow — baris mentah inv_kemasan.
type KemasanRow struct {
	ID            int64
	IDInvProduk   int64
	Kode          string
	Nama          string
	Barcode       *string
	IDInvUnitUkur int64
	QtyIsi        int32
	Status        string
	Version       int32
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// KemasanBaru — nilai insert inv_kemasan.
type KemasanBaru struct {
	EntityID      string
	IDInvProduk   int64
	Kode          string
	Nama          string
	Barcode       *string
	IDInvUnitUkur int64
	QtyIsi        int32
	Status        string
}

// KemasanUbahSet — nilai update inv_kemasan.
type KemasanUbahSet struct {
	IDInvProduk   int64
	Kode          string
	Nama          string
	Barcode       *string
	IDInvUnitUkur int64
	QtyIsi        int32
	Status        string
	Version       int32
	UpdatedAt     time.Time
}

// KemasanRepository — wrapper sqlc fitur kemasan.
type KemasanRepository struct{}

// NewKemasan — konstruksi tanpa state.
func NewKemasan() *KemasanRepository { return &KemasanRepository{} }

/* ------------------------------------------------------------------ */
/* Konversi baris + mapper view                                        */
/* ------------------------------------------------------------------ */

func kemasanDariValues(
	id, idProduk int64, kode, nama string, barcode pgtype.Text,
	idUnit int64, qtyIsi int32, status gen.EnumStatusAktif,
	version int32, createdAt, updatedAt pgtype.Timestamptz,
) KemasanRow {
	return KemasanRow{
		ID: id, IDInvProduk: idProduk, Kode: kode, Nama: nama,
		Barcode: maTxtPtr(barcode), IDInvUnitUkur: idUnit, QtyIsi: qtyIsi,
		Status: string(status), Version: version,
		CreatedAt: createdAt.Time, UpdatedAt: updatedAt.Time,
	}
}

func dariMuatKemasanHidupRow(r gen.MuatKemasanHidupRow) KemasanRow {
	return kemasanDariValues(r.ID, r.IDInvProduk, r.Kode, r.Nama, r.Barcode,
		r.IDInvUnitUkur, r.QtyIsi, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
}

func dariInsertKemasanRow(r gen.InsertKemasanRow) KemasanRow {
	return kemasanDariValues(r.ID, r.IDInvProduk, r.Kode, r.Nama, r.Barcode,
		r.IDInvUnitUkur, r.QtyIsi, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
}

// KemasanToView — padanan kemasanToView (join referensi kode/nama produk &
// kode unit).
func KemasanToView(row KemasanRow, kodeProduk, namaProduk, kodeUnit string) types.KemasanView {
	return types.KemasanView{
		ID:            row.ID,
		IDInvProduk:   row.IDInvProduk,
		KodeProduk:    kodeProduk,
		NamaProduk:    namaProduk,
		Kode:          row.Kode,
		Nama:          row.Nama,
		Barcode:       row.Barcode,
		IDInvUnitUkur: row.IDInvUnitUkur,
		KodeUnit:      kodeUnit,
		QtyIsi:        row.QtyIsi,
		Status:        row.Status,
		Version:       row.Version,
		CreatedAt:     maIsoWaktu(row.CreatedAt),
		UpdatedAt:     maIsoWaktu(row.UpdatedAt),
	}
}

func viewDariKemasanJoinRow(r gen.MuatKemasanViewHidupRow) types.KemasanView {
	row := kemasanDariValues(r.ID, r.IDInvProduk, r.Kode, r.Nama, r.Barcode,
		r.IDInvUnitUkur, r.QtyIsi, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
	return KemasanToView(row, r.KodeProduk, r.NamaProduk, r.KodeUnit)
}

/* ------------------------------------------------------------------ */
/* Baca — list / detail / lookup barcode                               */
/* ------------------------------------------------------------------ */

// FilterKemasan — filter list kemasan.
type FilterKemasan struct {
	IDProduk  *int64
	Status    string
	Search    string
	SortField string
	SortDesc  bool
	Limit     int32
	Offset    int32
}

// ListKemasan — daftar kemasan hidup + referensi produk/unit.
func (r *KemasanRepository) ListKemasan(ctx context.Context, exec DBTX, f FilterKemasan) ([]types.KemasanView, int, error) {
	p := gen.ListKemasanParams{
		IDProduk:  maI8Nilai(f.IDProduk),
		Status:    maTeksNihil(maStrPtrNihil(f.Status)),
		Search:    maTeksNihil(maStrPtrNihil(f.Search)),
		SortField: f.SortField,
		SortDesc:  f.SortDesc,
		Limit:     f.Limit,
		Offset:    f.Offset,
	}
	rows, err := gen.New(exec).ListKemasan(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountKemasan(ctx, gen.CountKemasanParams{
		IDProduk: p.IDProduk, Status: p.Status, Search: p.Search,
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.KemasanView, 0, len(rows))
	for _, r := range rows {
		out = append(out, viewDariListKemasanRow(r))
	}
	return out, int(total), nil
}

// viewDariListKemasanRow — konversi baris list (bentuk sama, struct berbeda).
func viewDariListKemasanRow(r gen.ListKemasanRow) types.KemasanView {
	row := kemasanDariValues(r.ID, r.IDInvProduk, r.Kode, r.Nama, r.Barcode,
		r.IDInvUnitUkur, r.QtyIsi, r.Status, r.Version, r.CreatedAt, r.UpdatedAt)
	return KemasanToView(row, r.KodeProduk, r.NamaProduk, r.KodeUnit)
}

// MuatViewHidupById — detail kemasan (join referensi) — nil bila absen.
func (r *KemasanRepository) MuatViewHidupById(ctx context.Context, exec DBTX, id int64) (*types.KemasanView, error) {
	rrow, err := gen.New(exec).MuatKemasanViewHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	v := viewDariKemasanJoinRow(rrow)
	return &v, nil
}

// MuatViewBaris — muat satu baris + referensi pasca-insert/update dalam tx
// (wajib ada — error mentah bila absen).
func (r *KemasanRepository) MuatViewBaris(ctx context.Context, exec DBTX, id int64) (types.KemasanView, error) {
	rrow, err := gen.New(exec).MuatKemasanViewHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return types.KemasanView{}, errkontrak.NotFound(
				"Kemasan id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		return types.KemasanView{}, err
	}
	return viewDariKemasanJoinRow(rrow), nil
}

// CariBarcodeView — lookup barcode scanner F15 — null bila barcode tak
// terdaftar (404 INV-015 dilempar service).
func (r *KemasanRepository) CariBarcodeView(ctx context.Context, exec DBTX, barcode string) (*types.KemasanLookupView, error) {
	rrow, err := gen.New(exec).CariBarcodeKemasanView(ctx, pgtype.Text{String: barcode, Valid: true})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	kemasan := kemasanDariValues(rrow.ID, rrow.IDInvProduk, rrow.Kode, rrow.Nama,
		rrow.Barcode, rrow.IDInvUnitUkur, rrow.QtyIsi, rrow.Status, rrow.Version,
		rrow.CreatedAt, rrow.UpdatedAt)
	produk := types.ProdukLookupView{
		ID:               rrow.IDInvProduk,
		KodeProduk:       rrow.KodeProduk,
		Nama:             rrow.NamaProduk,
		Tipe:             string(rrow.TipeProduk),
		IDInvProdukInduk: maI8Ptr(rrow.IDIndukProduk),
		IDInvUnitUkur:    rrow.IDUnitProduk,
		KodeUnit:         rrow.KodeUnitProduk,
		HargaJual:        maAngkaPtr(rrow.HargaJual),
		SaldoOnHand:      int(rrow.SaldoOnHand),
	}
	return &types.KemasanLookupView{
		Kemasan: KemasanToView(kemasan, rrow.KodeProduk, rrow.NamaProduk, rrow.KodeUnit),
		Produk:  produk,
		QtyIsi:  rrow.QtyIsi,
	}, nil
}

/* ------------------------------------------------------------------ */
/* Guard baris (fail berkode — dipakai service sebelum mutasi)         */
/* ------------------------------------------------------------------ */

// AssertKemasan — kemasan hidup wajib ada — fail 404 INV-018.
func (r *KemasanRepository) AssertKemasan(ctx context.Context, exec DBTX, id int64) (KemasanRow, error) {
	rrow, err := gen.New(exec).MuatKemasanHidup(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return KemasanRow{}, errkontrak.NotFound(
				"Kemasan id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		return KemasanRow{}, err
	}
	return dariMuatKemasanHidupRow(rrow), nil
}

// AssertProdukAda — produk referensi wajib hidup — fail 404 INV-018.
func (r *KemasanRepository) AssertProdukAda(ctx context.Context, exec DBTX, idProduk int64) error {
	_, err := gen.New(exec).CariProdukHidupAda(ctx, idProduk)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return errkontrak.NotFound(
				"Produk id "+strconv.FormatInt(idProduk, 10)+" tidak ditemukan.", "INV-018")
		}
		return err
	}
	return nil
}

// AssertKodeBebas — kode kemasan unik GLOBAL (uq_inv_kemasan_kode; TANPA
// filter deleted_at — ratifikasi keputusan DB).
func (r *KemasanRepository) AssertKodeBebas(ctx context.Context, exec DBTX, kode string, kecualiID *int64) error {
	_, err := gen.New(exec).CariDupeKodeKemasan(ctx, gen.CariDupeKodeKemasanParams{
		Kode:      kode,
		KecualiID: maI8Nilai(kecualiID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	return errkontrak.Conflict("Kode kemasan '" + kode + "' sudah dipakai.")
}

// AssertBarcodeBebas — barcode unik di antara baris hidup (partial).
func (r *KemasanRepository) AssertBarcodeBebas(ctx context.Context, exec DBTX, barcode string, kecualiID *int64) error {
	_, err := gen.New(exec).CariDupeBarcodeKemasan(ctx, gen.CariDupeBarcodeKemasanParams{
		Barcode:   pgtype.Text{String: barcode, Valid: true},
		KecualiID: maI8Nilai(kecualiID),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	return errkontrak.Conflict("Barcode '"+barcode+"' sudah dipakai kemasan lain.", "INV-015")
}

/* ------------------------------------------------------------------ */
/* Tulis — kemasan                                                     */
/* ------------------------------------------------------------------ */

// InsertKemasan — insert kemasan baru → KemasanRow lengkap.
func (r *KemasanRepository) InsertKemasan(ctx context.Context, exec DBTX, n KemasanBaru) (KemasanRow, error) {
	rrow, err := gen.New(exec).InsertKemasan(ctx, gen.InsertKemasanParams{
		EntityID:      maUuidNilai(n.EntityID),
		IDInvProduk:   n.IDInvProduk,
		Kode:          n.Kode,
		Nama:          n.Nama,
		Barcode:       maTeksNihil(n.Barcode),
		IDInvUnitUkur: n.IDInvUnitUkur,
		QtyIsi:        n.QtyIsi,
		Status:        gen.EnumStatusAktif(n.Status),
	})
	if err != nil {
		return KemasanRow{}, err
	}
	return dariInsertKemasanRow(rrow), nil
}

// UpdateSetVersiHidup — WHERE id + hidup + version (STD-07); returning
// ringkas {id} verbatim sumber — nil bila kalah balapan.
func (r *KemasanRepository) UpdateSetVersiHidup(ctx context.Context, exec DBTX, id int64, s KemasanUbahSet, versiHarap int32) (bool, error) {
	_, err := gen.New(exec).UpdateKemasanVersiHidup(ctx, gen.UpdateKemasanVersiHidupParams{
		IDInvProduk:   s.IDInvProduk,
		Kode:          s.Kode,
		Nama:          s.Nama,
		Barcode:       maTeksNihil(s.Barcode),
		IDInvUnitUkur: s.IDInvUnitUkur,
		QtyIsi:        s.QtyIsi,
		Status:        gen.EnumStatusAktif(s.Status),
		VersionBaru:   s.Version,
		UpdatedAt:     maWaktu(s.UpdatedAt),
		ID:            id,
		VersiHarap:    versiHarap,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// SoftDeleteHidupById — hapus lunak kemasan hidup.
func (r *KemasanRepository) SoftDeleteHidupById(ctx context.Context, exec DBTX, id int64, deletedAt, updatedAt time.Time) error {
	return gen.New(exec).SoftDeleteKemasan(ctx, gen.SoftDeleteKemasanParams{
		DeletedAt: maWaktu(deletedAt), UpdatedAt: maWaktu(updatedAt), ID: id,
	})
}
