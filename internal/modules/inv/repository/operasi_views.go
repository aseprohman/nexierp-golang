// operasi_views.go — kontrak JSON fitur OPERASI-LAIN modul inv (dokumen
// mutasi barang, penyesuaian stok, picking, jadwal hitung): kunci CERMIN
// respons packages/schemas/src/inv/views.ts NestJS (guard G8). Waktu ISO
// 8601 string, numeric PG → number, nullable sesuai DDL (pointer TANPA
// omitempty = null tetap terkirim); `token` pk-cipher optional (omitempty —
// ditempel service).
package repository

import (
	"strconv"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/inv/repository/gen"
	"nexierp/internal/modules/inv/types"
)

// opNumeric — float64 → pgtype.Numeric (untuk kolom numeric(18,4)/numeric —
// presisi via format eksponensial penuh).
func opNumeric(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.ScanScientific(strconv.FormatFloat(f, 'e', -1, 64))
	return n
}

// opNumericN — *float64 → pgtype.Numeric (nil = NULL).
func opNumericN(f *float64) pgtype.Numeric {
	if f == nil {
		return pgtype.Numeric{}
	}
	return opNumeric(*f)
}

// opIsoPtr — timestamptz nullable → *string ISO-8601 (NULL → nil).
func opIsoPtr(t pgtype.Timestamptz) *string {
	if !t.Valid {
		return nil
	}
	s := maIso(t)
	return &s
}

// opNullEnumStr — NullEnumJenisPenyesuaian hasil sqlc (enum nullable) → *string.
func opNullEnumStr(n gen.NullEnumJenisPenyesuaian) *string {
	if !n.Valid {
		return nil
	}
	s := string(n.EnumJenisPenyesuaian)
	return &s
}

/* ------------------------------------------------------------------ */
/* MUTASI — dokumen mutasi barang (patch 07/D-45 + dari GR patch 59)    */
/* ------------------------------------------------------------------ */

// MutasiItemView — padanan mutasiItemViewSchema.
type MutasiItemView struct {
	ID                 int64    `json:"id"`
	IDInvMutasiDokumen int64    `json:"idInvMutasiDokumen"`
	IDInvProduk        int64    `json:"idInvProduk"`
	KodeProduk         string   `json:"kodeProduk"`
	NamaProduk         string   `json:"namaProduk"`
	IDInvLotSerial     *int64   `json:"idInvLotSerial"`
	KodeLot            *string  `json:"kodeLot"`
	IDInvUnitUkur      int64    `json:"idInvUnitUkur"`
	KodeUnit           string   `json:"kodeUnit"`
	QtyDiminta         int      `json:"qtyDiminta"`
	HargaSatuanPo      *float64 `json:"hargaSatuanPo"` // patch 59 — NULL = manual
	Version            int32    `json:"version"`
	CreatedAt          string   `json:"createdAt"`
	UpdatedAt          string   `json:"updatedAt"`
}

// MutasiDokumenView — padanan mutasiDokumenViewSchema (header + items).
type MutasiDokumenView struct {
	ID                     int64            `json:"id"`
	Token                  string           `json:"token,omitempty"` // PK tersamar pk-cipher
	Kode                   string           `json:"kode"`
	Jenis                  string           `json:"jenis"`
	Status                 string           `json:"status"`
	IDLokasiSumber         int64            `json:"idLokasiSumber"`
	NamaLokasiSumber       string           `json:"namaLokasiSumber"`
	IDLokasiTujuan         int64            `json:"idLokasiTujuan"`
	NamaLokasiTujuan       string           `json:"namaLokasiTujuan"`
	TanggalDokumen         string           `json:"tanggalDokumen"`
	NamaPenyusun           *string          `json:"namaPenyusun"`
	NamaPenyetuju          *string          `json:"namaPenyetuju"`
	Alasan                 *string          `json:"alasan"`
	Items                  []MutasiItemView `json:"items"`
	JumlahGerakanDiposting int              `json:"jumlahGerakanDiposting"`
	IDPurPenerimaan        *int64           `json:"idPurPenerimaan"` // patch 59 — NULL = manual
	NomorGr                *string          `json:"nomorGr"`
	NomorPo                *string          `json:"nomorPo"`
	Version                int32            `json:"version"`
	CreatedAt              string           `json:"createdAt"`
	UpdatedAt              string           `json:"updatedAt"`
}

// GrEligibleView — padanan grEligibleViewSchema (patch 59 — daftar GR PUR
// eligible generate mutasi penerimaan).
type GrEligibleView struct {
	IDPurPenerimaan int64   `json:"idPurPenerimaan"`
	NomorGr         string  `json:"nomorGr"`
	NomorPo         string  `json:"nomorPo"`
	NamaPemasok     string  `json:"namaPemasok"`
	KodeGudang      *string `json:"kodeGudang"`
	TanggalTerima   *string `json:"tanggalTerima"`
	TotalQty        int     `json:"totalQty"`
	JumlahBaris     int     `json:"jumlahBaris"`
}

/* ------------------------------------------------------------------ */
/* PENYESUAIAN — dokumen penyesuaian/cycle count/scrap                  */
/* ------------------------------------------------------------------ */

// PenyesuaianItemView — padanan penyesuaianItemViewSchema.
type PenyesuaianItemView struct {
	ID              int64    `json:"id"`
	IDInvProduk     int64    `json:"idInvProduk"`
	KodeProduk      string   `json:"kodeProduk"`
	NamaProduk      string   `json:"namaProduk"`
	IDInvLotSerial  *int64   `json:"idInvLotSerial"`
	KodeLot         *string  `json:"kodeLot"`
	IDInvLokasiStok int64    `json:"idInvLokasiStok"`
	KodeLokasi      string   `json:"kodeLokasi"`
	IDInvUnitUkur   int64    `json:"idInvUnitUkur"`
	KodeUnit        string   `json:"kodeUnit"`
	IDInvKemasan    *int64   `json:"idInvKemasan"`
	KodeKemasan     *string  `json:"kodeKemasan"`
	IsiPerKemasan   *int     `json:"isiPerKemasan"`
	QtySistem       int      `json:"qtySistem"`
	QtyHitung       int      `json:"qtyHitung"`
	QtySelisih      int      `json:"qtySelisih"`
	BiayaSatuan     *float64 `json:"biayaSatuan"`
	NilaiSelisih    float64  `json:"nilaiSelisih"`
}

// PenyesuaianView — padanan penyesuaianViewSchema.
type PenyesuaianView struct {
	ID                int64                 `json:"id"`
	Token             string                `json:"token,omitempty"`
	Kode              string                `json:"kode"`
	Jenis             string                `json:"jenis"`
	Status            string                `json:"status"`
	IDInvGudang       int64                 `json:"idInvGudang"`
	KodeGudang        string                `json:"kodeGudang"`
	NamaGudang        string                `json:"namaGudang"`
	TanggalDokumen    string                `json:"tanggalDokumen"`
	NamaPenyusun      *string               `json:"namaPenyusun"`
	NamaPenyetuju     *string               `json:"namaPenyetuju"`
	Alasan            *string               `json:"alasan"`
	AlasanKeputusan   *string               `json:"alasanKeputusan"`
	Items             []PenyesuaianItemView `json:"items"`
	TotalNilaiSelisih float64               `json:"totalNilaiSelisih"`
	Version           int32                 `json:"version"`
	CreatedAt         string                `json:"createdAt"`
	UpdatedAt         string                `json:"updatedAt"`
}

/* ------------------------------------------------------------------ */
/* PICKING — agregat kerja per nomor_dokumen (D-07/D-25)                */
/* ------------------------------------------------------------------ */

// PickingLangkahView — padanan pickingLangkahViewSchema.
type PickingLangkahView struct {
	NomorDokumen       string  `json:"nomorDokumen"`
	KodeJenisOperasi   *string `json:"kodeJenisOperasi"`
	NamaJenisOperasi   *string `json:"namaJenisOperasi"`
	Jenis              string  `json:"jenis"`
	Langkah            int     `json:"langkah"`
	TotalLangkah       int     `json:"totalLangkah"`
	NamaLangkahAktif   string  `json:"namaLangkahAktif"`
	NamaLangkahBerikut *string `json:"namaLangkahBerikut"` // null = langkah akhir
	StatusAgregat      string  `json:"statusAgregat"`
	JumlahBaris        int     `json:"jumlahBaris"`
	QtyDiminta         int     `json:"qtyDiminta"`
	QtySelesai         int     `json:"qtySelesai"`
	TanggalJadwal      string  `json:"tanggalJadwal"`
	Reservasi          string  `json:"reservasi"`
}

// AgregatPicking — baris agregat mentah (CTE agg / AgregatNomorTerbuka) —
// input mapper ToViewPicking; dipakai list (rawSQL) & majukan (sqlc).
type AgregatPicking struct {
	NomorDokumen     string
	Jenis            string
	KodeJenisOperasi *string
	Langkah          int
	TotalLangkah     int
	StatusDominan    string
	JumlahBaris      int
	QtyDiminta       int
	QtySelesai       int
	TanggalJadwal    string // ISO
	Reservasi        bool
}

// JenisOperasiLabel — nilai peta muatJenisOperasi (label langkah aktif D-26).
type JenisOperasiLabel struct {
	Nama    string
	Langkah []string
}

// GerakanStokView — padanan gerakanStokViewSchema (dipakai picking get —
// delegasi view gerakan; muatView FLAT D-51 + enrichment baris ADJ).
type GerakanStokView struct {
	ID               int64    `json:"id"`
	NomorDokumen     string   `json:"nomorDokumen"`
	Jenis            string   `json:"jenis"`
	Status           string   `json:"status"`
	Langkah          int      `json:"langkah"`
	TotalLangkah     int      `json:"totalLangkah"`
	Reservasi        string   `json:"reservasi"`
	IDInvProduk      int64    `json:"idInvProduk"`
	KodeProduk       string   `json:"kodeProduk"`
	NamaProduk       string   `json:"namaProduk"`
	IDInvLotSerial   *int64   `json:"idInvLotSerial"`
	KodeLot          *string  `json:"kodeLot"`
	IDInvUnitUkur    int64    `json:"idInvUnitUkur"`
	KodeUnit         string   `json:"kodeUnit"`
	QtyDiminta       int      `json:"qtyDiminta"`
	QtySelesai       int      `json:"qtySelesai"`
	IDLokasiSumber   int64    `json:"idLokasiSumber"` // efektif (baris ?? header D-48)
	KodeLokasiSumber string   `json:"kodeLokasiSumber"`
	NamaLokasiSumber string   `json:"namaLokasiSumber"`
	IDLokasiTujuan   int64    `json:"idLokasiTujuan"`
	KodeLokasiTujuan string   `json:"kodeLokasiTujuan"`
	NamaLokasiTujuan string   `json:"namaLokasiTujuan"`
	NilaiPersatuan   *float64 `json:"nilaiPersatuan"`
	TanggalJadwal    string   `json:"tanggalJadwal"`
	TanggalSelesai   *string  `json:"tanggalSelesai"`
	JenisSumber      string   `json:"jenisSumber"`
	EntityIDSumber   *string  `json:"entityIdSumber"`
	Alasan           *string  `json:"alasan"`
	JenisPenyesuaian *string  `json:"jenisPenyesuaian"`
	QtySistem        *int     `json:"qtySistem"`
	QtyHitung        *int     `json:"qtyHitung"`
	QtySelisih       *int     `json:"qtySelisih"`
	Version          int32    `json:"version"`
	CreatedAt        string   `json:"createdAt"`
	UpdatedAt        string   `json:"updatedAt"`
}

/* ------------------------------------------------------------------ */
/* JADWAL HITUNG — cycle count terjadwal (patch 04)                     */
/* ------------------------------------------------------------------ */

// JadwalHitungView — padanan jadwalHitungViewSchema.
type JadwalHitungView struct {
	ID                 int64   `json:"id"`
	Kode               string  `json:"kode"`
	Nama               string  `json:"nama"`
	IDInvGudang        int64   `json:"idInvGudang"`
	KodeGudang         string  `json:"kodeGudang"`
	IDInvLokasiStok    *int64  `json:"idInvLokasiStok"`
	KodeLokasi         *string `json:"kodeLokasi"`
	Frekuensi          string  `json:"frekuensi"`
	HariEksekusi       int     `json:"hariEksekusi"`
	Aktif              bool    `json:"aktif"`
	TerakhirDibuatPada *string `json:"terakhirDibuatPada"`
	Version            int32   `json:"version"`
	CreatedAt          string  `json:"createdAt"`
	UpdatedAt          string  `json:"updatedAt"`
}

/* ------------------------------------------------------------------ */
/* PENYESUAIAN — resolver barcode terpadu (D-37)                        */
/* ------------------------------------------------------------------ */

// BarcodeLotView — padanan objek lot pada barcodeResolveViewSchema.
type BarcodeLotView struct {
	ID          int64  `json:"id"`
	Kode        string `json:"kode"`
	Status      string `json:"status"`
	SaldoOnHand int    `json:"saldoOnHand"`
}

// BarcodeKemasanView — padanan objek kemasan pada barcodeResolveViewSchema.
type BarcodeKemasanView struct {
	ID            int64  `json:"id"`
	Kode          string `json:"kode"`
	Nama          string `json:"nama"`
	QtyIsi        int    `json:"qtyIsi"` // 1 kemasan = qtyIsi unit dasar produk
	IDInvUnitUkur int64  `json:"idInvUnitUkur"`
	KodeUnit      string `json:"kodeUnit"`
}

// BarcodeResolveView — padanan barcodeResolveViewSchema (produk memakai
// types.ProdukLookupView milik modul — kontrak sama persis).
type BarcodeResolveView struct {
	Sumber  string                 `json:"sumber"` // PRODUK / LOT / KEMASAN
	Barcode string                 `json:"barcode"`
	Label   string                 `json:"label"`
	Produk  types.ProdukLookupView `json:"produk"`
	Lot     *BarcodeLotView        `json:"lot"`     // terisi bila sumber LOT
	Kemasan *BarcodeKemasanView    `json:"kemasan"` // terisi bila sumber KEMASAN
}
