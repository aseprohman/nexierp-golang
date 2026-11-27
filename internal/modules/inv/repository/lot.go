// repository/lot.go — SATU-SATUNYA pengguna pgx+sqlc fitur LOT/SERIAL modul
// inv (padanan LotRepository NestJS — INV-F07; tabel inv_lot_serial + INNER
// JOIN inv_produk + readmodel inv_saldo_stok subquery SUM per lot). Mapping
// baris → view (kontrak JSON = packages/schemas inv/views.ts
// LotSerialView) di sini. Guard dup: kode lot per produk TANPA filter
// deleted, barcode partial di antara lot HIDUP — verbatim sumber.
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
)

// LotRow — baris inv_lot_serial (pgtype telah dikonversi).
type LotRow struct {
	ID                 int64
	EntityID           string
	IDInvProduk        int64
	Kode               string
	TanggalProdiksi    *time.Time
	TanggalKedaluwarsa *time.Time
	Status             string
	Version            int32
	CreatedAt          time.Time
	UpdatedAt          time.Time
	DeletedAt          *time.Time
	Barcode            *string
}

// LotDenganProduk — baris lot + produk ter-join + saldo readmodel.
type LotDenganProduk struct {
	Lot         LotRow
	KodeProduk  string
	NamaProduk  string
	SaldoOnHand int32
}

// LotSerialView — kontrak respons lot (kunci cermin lotSerialViewSchema).
type LotSerialView struct {
	ID                 int64   `json:"id"`
	IDInvProduk        int64   `json:"idInvProduk"`
	KodeProduk         string  `json:"kodeProduk"`
	NamaProduk         string  `json:"namaProduk"`
	Kode               string  `json:"kode"`
	Barcode            *string `json:"barcode"`
	TanggalProdiksi    *string `json:"tanggalProdiksi"`
	TanggalKedaluwarsa *string `json:"tanggalKedaluwarsa"`
	Status             string  `json:"status"`
	SaldoOnHand        int32   `json:"saldoOnHand"`
	Version            int32   `json:"version"`
	CreatedAt          string  `json:"createdAt"`
	UpdatedAt          string  `json:"updatedAt"`
}

// Whitelist sort lot (persis peta kolom drizzlePageBounds repo sumber —
// termasuk alias ganda created_at/createdAt dan 'kedaluwarsa').
var whitelistSortLot = []string{"kode", "kedaluwarsa", "created_at", "createdAt", "updatedAt"}

var kanonikSortLot = map[string]string{
	"kode":        "kode",
	"kedaluwarsa": "kedaluwarsa",
	"created_at":  "created_at",
	"createdAt":   "created_at",
	"updatedAt":   "updated_at",
}

// LotRepository — pembungkus gen.Querier fitur lot.
type LotRepository struct{}

// NewLotRepository — konstruksi repo lot.
func NewLotRepository() *LotRepository { return &LotRepository{} }

// LotToView — padanan toLotView.
func LotToView(row LotRow, kodeProduk, namaProduk string, saldoOnHand int32) LotSerialView {
	return LotSerialView{
		ID:                 row.ID,
		IDInvProduk:        row.IDInvProduk,
		KodeProduk:         kodeProduk,
		NamaProduk:         namaProduk,
		Kode:               row.Kode,
		Barcode:            row.Barcode,
		TanggalProdiksi:    mbIsoPtr(pgtypeTzPtr(row.TanggalProdiksi)),
		TanggalKedaluwarsa: mbIsoPtr(pgtypeTzPtr(row.TanggalKedaluwarsa)),
		Status:             row.Status,
		SaldoOnHand:        saldoOnHand,
		Version:            row.Version,
		CreatedAt:          mbIso(pgtypeTz(row.CreatedAt)),
		UpdatedAt:          mbIso(pgtypeTz(row.UpdatedAt)),
	}
}

// pgtypeTzPtr — *time.Time → pgtype.Timestamptz (nil = NULL).
func pgtypeTzPtr(t *time.Time) pgtype.Timestamptz { return mbTzNil(t) }

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// ListLot — halaman lot + produk + saldo readmodel — filter status/
// idProduk/search (kode lot ILIKE ATAU sku produk). Sort whitelist alias
// sumber, default kode ASC.
func (r *LotRepository) ListLot(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest) (errkontrak.Page[LotSerialView], error) {
	if err := mbSortCek(pr, whitelistSortLot); err != nil {
		return errkontrak.Page[LotSerialView]{}, err
	}
	idProduk, err := filterNumVal(pr, "idProduk")
	if err != nil {
		return errkontrak.Page[LotSerialView]{}, err
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortLot)
	params := gen.ListLotParams{
		Status:   mbTxtNil(filterVal(pr, "status")),
		IDProduk: idProduk,
		Search:   mbTxtNil(filterVal(pr, "search")),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   pageOffset(pr),
		Limit:    pageLimit(pr),
	}
	rows, err := gen.New(exec).ListLot(ctx, params)
	if err != nil {
		return errkontrak.Page[LotSerialView]{}, err
	}
	total, err := gen.New(exec).CountLot(ctx, gen.CountLotParams{
		Status:   params.Status,
		IDProduk: params.IDProduk,
		Search:   params.Search,
	})
	if err != nil {
		return errkontrak.Page[LotSerialView]{}, err
	}
	views := make([]LotSerialView, 0, len(rows))
	for _, row := range rows {
		views = append(views, LotToView(lotRowDariList(row), row.KodeProduk, row.NamaProduk, mbIntAny(row.SaldoOnHand)))
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// lotRowDariList — potong kolom lot dari baris join list.
func lotRowDariList(r gen.ListLotRow) LotRow {
	return potongLot(r.ID, r.EntityID, r.IDInvProduk, r.Kode, r.TanggalProdiksi,
		r.TanggalKedaluwarsa, r.Status, r.Version, r.CreatedAt, r.UpdatedAt,
		r.DeletedAt, r.Barcode)
}

// potongLot — susun LotRow dari kolom mentah (dipakai list & detail).
func potongLot(
	id int64, entityID pgtype.UUID, idInvProduk int64, kode string,
	tanggalProdiksi, tanggalKedaluwarsa pgtype.Timestamptz,
	status gen.EnumStatusLotSerial,
	version int32, createdAt, updatedAt, deletedAt pgtype.Timestamptz,
	barcode pgtype.Text,
) LotRow {
	return LotRow{
		ID:                 id,
		EntityID:           mbUUIDString(entityID),
		IDInvProduk:        idInvProduk,
		Kode:               kode,
		TanggalProdiksi:    mbTimePtr(tanggalProdiksi),
		TanggalKedaluwarsa: mbTimePtr(tanggalKedaluwarsa),
		Status:             string(status),
		Version:            version,
		CreatedAt:          createdAt.Time,
		UpdatedAt:          updatedAt.Time,
		DeletedAt:          mbTimePtr(deletedAt),
		Barcode:            mbTxt(barcode),
	}
}

// mbIntAny — hasil subquery COALESCE(SUM(...)::int) yang tak ter-infer sqlc
// (interface{}) → int32 (pgx mengembalikan int32 untuk int4).
func mbIntAny(v any) int32 {
	switch n := v.(type) {
	case int32:
		return n
	case int64:
		return int32(n)
	case int16:
		return int32(n)
	case int:
		return int32(n)
	case float64:
		return int32(n)
	}
	return 0
}

// MuatDetail — detail lot hidup + produk + saldo — nil bila absen/terhapus.
func (r *LotRepository) MuatDetail(ctx context.Context, exec gen.DBTX, id int64) (*LotDenganProduk, error) {
	row, err := gen.New(exec).LotDetail(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	lot := potongLot(row.ID, row.EntityID, row.IDInvProduk, row.Kode,
		row.TanggalProdiksi, row.TanggalKedaluwarsa, row.Status, row.Version,
		row.CreatedAt, row.UpdatedAt, row.DeletedAt, row.Barcode)
	return &LotDenganProduk{
		Lot:         lot,
		KodeProduk:  row.KodeProduk,
		NamaProduk:  row.NamaProduk,
		SaldoOnHand: mbIntAny(row.SaldoOnHand),
	}, nil
}

/* -------------------------------------------------------------- */
/* Guard baris                                                     */
/* -------------------------------------------------------------- */

// ProdukHidup — produk hidup by id (id/kode/nama utk guard & audit) — nil
// bila absen.
type ProdukRingkas struct {
	ID         int64
	KodeProduk string
	Nama       string
}

// MuatProduk — produk hidup by id — nil bila absen/lunak-dihapus.
func (r *LotRepository) MuatProduk(ctx context.Context, exec gen.DBTX, id int64) (*ProdukRingkas, error) {
	row, err := gen.New(exec).ProdukHidup(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &ProdukRingkas{ID: row.ID, KodeProduk: row.KodeProduk, Nama: row.Nama}, nil
}

// CariDupeKode — kode lot sudah ada untuk produk (uq per produk — TANPA
// filter deleted, verbatim sumber)? — nil bila bebas.
func (r *LotRepository) CariDupeKode(ctx context.Context, exec gen.DBTX, idProduk int64, kode string) (*int64, error) {
	id, err := gen.New(exec).LotDupeKode(ctx, gen.LotDupeKodeParams{IDProduk: idProduk, Kode: kode})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// CariDupeBarcode — barcode dipakai lot HIDUP lain (partial hidup, verbatim
// sumber)? — nil bila bebas.
func (r *LotRepository) CariDupeBarcode(ctx context.Context, exec gen.DBTX, barcode string) (*int64, error) {
	id, err := gen.New(exec).LotDupeBarcode(ctx, barcode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// LotBaru — nilai insert inv_lot_serial (tanggal sudah time; status default
// DB AKTIF — verbatim sumber tidak mengirim status).
type LotBaru struct {
	EntityID           string
	IDInvProduk        int64
	Kode               string
	Barcode            *string
	TanggalProdiksi    *time.Time
	TanggalKedaluwarsa *time.Time
}

// InsertLot — insert lot baru → baris polos (23505 race DITITIPKAN mentah —
// dipetakan 409 pesan pre-check oleh service).
func (r *LotRepository) InsertLot(ctx context.Context, exec gen.DBTX, v LotBaru) (LotRow, error) {
	row, err := gen.New(exec).InsertLot(ctx, gen.InsertLotParams{
		EntityID:           mbUUID(v.EntityID),
		IDInvProduk:        v.IDInvProduk,
		Kode:               v.Kode,
		Barcode:            mbTxtNil(v.Barcode),
		TanggalProdiksi:    mbTzNil(v.TanggalProdiksi),
		TanggalKedaluwarsa: mbTzNil(v.TanggalKedaluwarsa),
	})
	if err != nil {
		return LotRow{}, err
	}
	return fromLotGen(row), nil
}

// fromLotGen — konversi baris RETURNING → baris polos.
func fromLotGen(r gen.InvLotSerial) LotRow {
	return LotRow{
		ID:                 r.ID,
		EntityID:           mbUUIDString(r.EntityID),
		IDInvProduk:        r.IDInvProduk,
		Kode:               r.Kode,
		TanggalProdiksi:    mbTimePtr(r.TanggalProdiksi),
		TanggalKedaluwarsa: mbTimePtr(r.TanggalKedaluwarsa),
		Status:             string(r.Status),
		Version:            r.Version,
		CreatedAt:          r.CreatedAt.Time,
		UpdatedAt:          r.UpdatedAt.Time,
		DeletedAt:          mbTimePtr(r.DeletedAt),
		Barcode:            mbTxt(r.Barcode),
	}
}
