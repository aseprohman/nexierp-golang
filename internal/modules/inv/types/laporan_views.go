// Package types — view respons fitur LAPORAN (kontrak JSON persis zod
// @nexierp/schemas inv/views.ts: kartuStokRowViewSchema, expiringRowViewSchema,
// nilaiPersediaanRowViewSchema, backlogRowViewSchema, reorderRowViewSchema,
// lapisanBiayaViewSchema, kpiRowViewSchema, traceabilityRowViewSchema).
// Semua uang = JSON number; qty int; nullable sesuai DDL.
package types

// KartuStokRowView — satu baris kartu stok (kartuStokRowViewSchema).
type KartuStokRowView struct {
	Tanggal       string  `json:"tanggal"`
	NomorDokumen  string  `json:"nomorDokumen"`
	Jenis         string  `json:"jenis"`
	KodeLot       *string `json:"kodeLot"`
	QtyMasuk      int64   `json:"qtyMasuk"`
	QtyKeluar     int64   `json:"qtyKeluar"`
	Nilai         float64 `json:"nilai"`
	SaldoBerjalan int64   `json:"saldoBerjalan"`
}

// ExpiringRowView — lot mendekati/lewat kedaluwarsa (expiringRowViewSchema).
type ExpiringRowView struct {
	IDInvLotSerial     int64   `json:"idInvLotSerial"`
	KodeLot            string  `json:"kodeLot"`
	IDInvProduk        int64   `json:"idInvProduk"`
	KodeProduk         string  `json:"kodeProduk"`
	NamaProduk         string  `json:"namaProduk"`
	TanggalKedaluwarsa string  `json:"tanggalKedaluwarsa"`
	Status             string  `json:"status"`
	QtyOnHand          int64   `json:"qtyOnHand"`
	NilaiPersediaan    float64 `json:"nilaiPersediaan"`
	HariTersisa        int64   `json:"hariTersisa"`
}

// NilaiPersediaanRowView — nilai persediaan per kategori/gudang.
type NilaiPersediaanRowView struct {
	Kelompok      string  `json:"kelompok"`
	JenisKelompok string  `json:"jenisKelompok"` // KATEGORI | GUDANG
	JumlahSku     int64   `json:"jumlahSku"`
	TotalQty      int64   `json:"totalQty"`
	TotalNilai    float64 `json:"totalNilai"`
}

// BacklogRowView — backlog picking gerakan terbuka per jenis×status.
type BacklogRowView struct {
	Jenis    string `json:"jenis"`
	Status   string `json:"status"`
	Jumlah   int64  `json:"jumlah"`
	TotalQty int64  `json:"totalQty"`
}

// ReorderRowView — daftar reorder (qtySaran = maks − efektif).
type ReorderRowView struct {
	IDInvProduk  int64   `json:"idInvProduk"`
	KodeProduk   string  `json:"kodeProduk"`
	NamaProduk   string  `json:"namaProduk"`
	StokMinimum  int64   `json:"stokMinimum"`
	StokMaksimum *int64  `json:"stokMaksimum"`
	SaldoEfektif int64   `json:"saldoEfektif"`
	QtySaran     int64   `json:"qtySaran"`
	NamaGudang   *string `json:"namaGudang"`
	ReorderAktif bool    `json:"reorderAktif"`
}

// LapisanBiayaView — lapisan biaya FIFO sisa (lapisanBiayaViewSchema).
type LapisanBiayaView struct {
	ID                int64   `json:"id"`
	IDInvProduk       int64   `json:"idInvProduk"`
	KodeProduk        string  `json:"kodeProduk"`
	KodeLot           *string `json:"kodeLot"`
	NomorDokumenMasuk string  `json:"nomorDokumenMasuk"`
	TanggalMasuk      string  `json:"tanggalMasuk"`
	QtyMasuk          int64   `json:"qtyMasuk"`
	QtyTerpakai       int64   `json:"qtyTerpakai"`
	QtySisa           int64   `json:"qtySisa"`
	BiayaPersatuan    float64 `json:"biayaPersatuan"`
}

// KpiRowView — baris KPI §2.3 (kpiRowViewSchema) — semua angka JSON number.
type KpiRowView struct {
	Kpi      string  `json:"kpi"`
	Label    string  `json:"label"`
	Nilai    float64 `json:"nilai"`
	Satuan   string  `json:"satuan"`
	Target   string  `json:"target"`
	Jumlah   float64 `json:"jumlah"`
	Penyebut float64 `json:"penyebut"`
}

// TraceabilityRowView — jejak produk/lot (traceabilityRowViewSchema);
// nilaiPersatuan number|null.
type TraceabilityRowView struct {
	Arah            string   `json:"arah"`
	NomorDokumen    string   `json:"nomorDokumen"`
	Jenis           string   `json:"jenis"`
	Tanggal         string   `json:"tanggal"`
	KodeLot         *string  `json:"kodeLot"`
	Qty             int64    `json:"qty"`
	NilaiPersatuan  *float64 `json:"nilaiPersatuan"`
	KodeLokasiLawan string   `json:"kodeLokasiLawan"`
	NamaLokasiLawan string   `json:"namaLokasiLawan"`
	JenisSumber     string   `json:"jenisSumber"`
	EntityIDSumber  *string  `json:"entityIdSumber"`
}
