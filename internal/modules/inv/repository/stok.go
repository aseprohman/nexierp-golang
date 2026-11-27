// repository/stok.go — SATU-SATUNYA pengguna pgx+sqlc fitur STOK modul inv
// (padanan repositories/stok/saldo.repository.ts NestJS): READMODEL
// `inv_saldo_stok` (baca — dibangun recompute; soft-delete aman) + agregat
// ATP per produk. Query/alias/mapper dipegang di sini; service memegang
// validasi filter, transaksi recompute, dan baca CFG-INV-13 (mode ATP) yang
// diteruskan ke PetakanAtp. Fungsi recompute TIDAK di file ini — milik fitur
// GERAKAN (repository eksport RecomputeSaldoStok; satu-satunya jalur
// TRUNCATE sah di modul INV).
package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
)

// ---------------------------------------------------------------------
// Tipe baris & view (kontrak JSON = packages/schemas inv/views.ts)
// ---------------------------------------------------------------------

// SaldoListFilter — filter daftar saldo (parsed service dari PageRequest).
type SaldoListFilter struct {
	IDLokasi     pgtype.Int8
	IDProduk     pgtype.Int8
	IDGudang     pgtype.Int8 // target kolom: lokasi_saldo_ref.id_inv_gudang
	OnlyBelowMin bool
	Search       pgtype.Text
}

// SaldoStokView — baris saldo (kunci cermin saldoStokViewSchema). Numeric
// PG → number (nilai_persediaan ::float8 = padanan mapper Number(...)).
type SaldoStokView struct {
	ID                 int64   `json:"id"`
	IDInvLokasiStok    int64   `json:"idInvLokasiStok"`
	KodeLokasi         string  `json:"kodeLokasi"`
	NamaLokasi         string  `json:"namaLokasi"`
	KodeGudang         *string `json:"kodeGudang"`
	IDInvProduk        int64   `json:"idInvProduk"`
	KodeProduk         string  `json:"kodeProduk"`
	NamaProduk         string  `json:"namaProduk"`
	IDInvLotSerial     *int64  `json:"idInvLotSerial"`
	KodeLot            *string `json:"kodeLot"`
	TanggalKedaluwarsa *string `json:"tanggalKedaluwarsa"`
	QtyOnHand          int32   `json:"qtyOnHand"`
	QtyDipesan         int32   `json:"qtyDipesan"`
	QtyTersedia        int32   `json:"qtyTersedia"`
	NilaiPersediaan    float64 `json:"nilaiPersediaan"`
	UpdatedAt          string  `json:"updatedAt"`
}

// AtpItemView — jawaban ATP per produk (kunci cermin atpItemViewSchema;
// INV-BR14: tidak pernah melebihi fisik − terjadwal kecuali selaluTersedia).
type AtpItemView struct {
	IDInvProduk    int64  `json:"idInvProduk"`
	KodeProduk     string `json:"kodeProduk"`
	NamaProduk     string `json:"namaProduk"`
	QtyOnHand      int32  `json:"qtyOnHand"`
	QtyDipesan     int32  `json:"qtyDipesan"`
	QtyTersedia    int32  `json:"qtyTersedia"`
	SelaluTersedia bool   `json:"selaluTersedia"`
}

// SaldoRecomputeView — hasil rebuild READMODEL (saldoRecomputeViewSchema).
type SaldoRecomputeView struct {
	BarisDibangun int64 `json:"barisDibangun"`
	DurasiMs      int64 `json:"durasiMs"`
}

// ModeAtp — mode jawaban ATP sesuai CFG-INV-13.
type ModeAtp = string

// ---------------------------------------------------------------------
// Sort whitelist (persis peta kolom drizzlePageBounds repo sumber — alias
// camelCase FE ikut dikenal; createdAt = saldo.created_at sumber).
// ---------------------------------------------------------------------

var whitelistSortSaldo = []string{
	"kode_produk", "kode_lokasi", "qty_on_hand", "qtyOnHand",
	"updated_at", "createdAt", "updatedAt",
}

var kanonikSortSaldo = map[string]string{
	"kode_produk": "kode_produk",
	"kode_lokasi": "kode_lokasi",
	"qty_on_hand": "qty_on_hand",
	"qtyOnHand":   "qtyOnHand",
	"updated_at":  "updated_at",
	"createdAt":   "createdAt",
	"updatedAt":   "updatedAt",
}

// ---------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------

// SaldoRepository — pembungkus gen.Querier fitur saldo (tanpa state;
// executor diteruskan per method).
type SaldoRepository struct{}

// NewSaldoRepository — konstruksi repo saldo.
func NewSaldoRepository() *SaldoRepository { return &SaldoRepository{} }

// saldoFilter — terjemahan PageRequest → SaldoListFilter (persis
// SaldoService.list: filter truthy → dipakai; onlyBelowMin === "true";
// search || undefined). Filter numerik dengan semantik Number() lewat
// filterNumVal (garbage → 500 generik, persis jalur NaN sumber).
func saldoFilter(pr *errkontrak.PageRequest) (SaldoListFilter, error) {
	f := SaldoListFilter{OnlyBelowMin: pr.Filters["onlyBelowMin"] == "true"}
	if s := filterVal(pr, "search"); s != nil {
		f.Search = pgtype.Text{String: *s, Valid: true}
	}
	var err error
	if f.IDLokasi, err = filterNumVal(pr, "idLokasi"); err != nil {
		return f, err
	}
	if f.IDProduk, err = filterNumVal(pr, "idProduk"); err != nil {
		return f, err
	}
	if f.IDGudang, err = filterNumVal(pr, "idGudang"); err != nil {
		return f, err
	}
	return f, nil
}

// PageSaldoStok — SATU HALAMAN saldo (filter + search + whitelist sort;
// default kode_produk ASC — persis fallback asc(produkRef.kodeProduk)).
func (r *SaldoRepository) PageSaldoStok(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest) (errkontrak.Page[SaldoStokView], error) {
	if err := mbSortCek(pr, whitelistSortSaldo); err != nil {
		return errkontrak.Page[SaldoStokView]{}, err
	}
	f, err := saldoFilter(pr)
	if err != nil {
		return errkontrak.Page[SaldoStokView]{}, err
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortSaldo)

	rows, err := gen.New(exec).PageSaldoStok(ctx, gen.PageSaldoStokParams{
		IDLokasi:     f.IDLokasi,
		IDProduk:     f.IDProduk,
		IDGudang:     f.IDGudang,
		OnlyBelowMin: f.OnlyBelowMin,
		Search:       f.Search,
		SortCol:      sortCol,
		SortDesc:     sortDesc,
		Limit:        pageLimit(pr),
		Offset:       pageOffset(pr),
	})
	if err != nil {
		return errkontrak.Page[SaldoStokView]{}, err
	}
	total, err := gen.New(exec).CountSaldoStok(ctx, gen.CountSaldoStokParams{
		IDLokasi:     f.IDLokasi,
		IDProduk:     f.IDProduk,
		IDGudang:     f.IDGudang,
		OnlyBelowMin: f.OnlyBelowMin,
		Search:       f.Search,
	})
	if err != nil {
		return errkontrak.Page[SaldoStokView]{}, err
	}
	data := make([]SaldoStokView, len(rows))
	for i, row := range rows {
		data[i] = toSaldoView(row)
	}
	return errkontrak.BuildPage(data, int(total), pr), nil
}

// toSaldoView — mapper baris sqlc → SaldoStokView (pgtype → tipe polos).
func toSaldoView(r gen.PageSaldoStokRow) SaldoStokView {
	return SaldoStokView{
		ID:                 r.ID,
		IDInvLokasiStok:    r.IDInvLokasiStok,
		KodeLokasi:         r.KodeLokasi,
		NamaLokasi:         r.NamaLokasi,
		KodeGudang:         mbTxt(r.KodeGudang),
		IDInvProduk:        r.IDInvProduk,
		KodeProduk:         r.KodeProduk,
		NamaProduk:         r.NamaProduk,
		IDInvLotSerial:     mbInt8(r.IDInvLotSerial),
		KodeLot:            mbTxt(r.KodeLot),
		TanggalKedaluwarsa: mbIsoPtr(r.TanggalKedaluwarsa),
		QtyOnHand:          r.QtyOnHand,
		QtyDipesan:         r.QtyDipesan,
		QtyTersedia:        r.QtyTersedia,
		NilaiPersediaan:    r.NilaiPersediaan,
		UpdatedAt:          mbIso(r.UpdatedAt),
	}
}

// ListSaldoAtp — baris agregat ATP per produk (on-hand/dipesan/tersedia dari
// READMODEL); mode CFG-INV-13 dibaca service lalu PetakanAtp memetakan.
func (r *SaldoRepository) ListSaldoAtp(ctx context.Context, exec gen.DBTX, produkIds []int64) ([]gen.ListSaldoAtpRow, error) {
	return gen.New(exec).ListSaldoAtp(ctx, produkIds)
}

// PetakanAtp — agregat ATP → AtpItemView — VERBATIM petakanAtp sumber:
//
//	ON_HAND          → qty on-hand fisik;
//	ATP_KETAT        → on_hand − keluar terjadwal (qty_tersedia);
//	ATP_KETAT_BUFFER → ATP ketat + buffer (stok_minimum produk).
//
// Produk jejakStok=false (jasa) → selaluTersedia=true dan TANPA clamp
// Math.min (INV-BR14 — tidak pernah melebihi fisik − terjadwal utk produk
// berjejak stok).
func PetakanAtp(rows []gen.ListSaldoAtpRow, mode ModeAtp) []AtpItemView {
	out := make([]AtpItemView, len(rows))
	for i, r := range rows {
		// Jasa / produk tanpa jejak stok → selalu tersedia (konfigurasi katalog).
		selaluTersedia := !r.JejakStok
		qtyTersedia := r.Tersedia
		if mode == "ON_HAND" {
			qtyTersedia = r.OnHand
		}
		if mode == "ATP_KETAT_BUFFER" {
			qtyTersedia = r.Tersedia + r.StokMinimum
		}
		if !selaluTersedia && qtyTersedia > r.OnHand {
			qtyTersedia = r.OnHand // Math.min(qtyTersedia, r.onHand)
		}
		out[i] = AtpItemView{
			IDInvProduk:    r.ID,
			KodeProduk:     r.KodeProduk,
			NamaProduk:     r.Nama,
			QtyOnHand:      r.OnHand,
			QtyDipesan:     r.Dipesan,
			QtyTersedia:    qtyTersedia,
			SelaluTersedia: selaluTersedia,
		}
	}
	return out
}
