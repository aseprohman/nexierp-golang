// Package types — view respons fitur MASTER-A modul inv (padanan
// packages/schemas/src/inv/views.ts — KUNCI CERMIN zod, camelCase):
// kategoriProdukViewSchema, unitUkurViewSchema, unitKonversiViewSchema,
// produkIndukViewSchema, produkViewSchema, produkLookupViewSchema,
// kemasanViewSchema + kemasanLookupViewSchema (types/kemasan-types.ts).
package types

// KategoriProdukView — padanan kategoriProdukViewSchema.
type KategoriProdukView struct {
	ID                   int64   `json:"id"`
	IDKategoriInduk      *int64  `json:"idKategoriInduk"`
	NamaInduk            *string `json:"namaInduk"`
	Nama                 string  `json:"nama"`
	MetodeValuasi        string  `json:"metodeValuasi"`
	SistemValuasi        string  `json:"sistemValuasi"`
	KebijakanPelacakan   string  `json:"kebijakanPelacakan"`
	KebijakanKedaluwarsa bool    `json:"kebijakanKedaluwarsa"`
	Status               string  `json:"status"`
	PunyaMutasi          bool    `json:"punyaMutasi"`
	Version              int32   `json:"version"`
	CreatedAt            string  `json:"createdAt"`
	UpdatedAt            string  `json:"updatedAt"`
}

// UnitUkurView — padanan unitUkurViewSchema.
type UnitUkurView struct {
	ID          int64  `json:"id"`
	Kode        string `json:"kode"`
	Nama        string `json:"nama"`
	KategoriUom string `json:"kategoriUom"`
	Status      string `json:"status"`
	Version     int32  `json:"version"`
	CreatedAt   string `json:"createdAt"`
	UpdatedAt   string `json:"updatedAt"`
}

// UnitKonversiView — padanan unitKonversiViewSchema (faktor numeric → number).
type UnitKonversiView struct {
	ID           int64   `json:"id"`
	IDUnitDari   int64   `json:"idUnitDari"`
	KodeUnitDari string  `json:"kodeUnitDari"`
	NamaUnitDari string  `json:"namaUnitDari"`
	IDUnitKe     int64   `json:"idUnitKe"`
	KodeUnitKe   string  `json:"kodeUnitKe"`
	NamaUnitKe   string  `json:"namaUnitKe"`
	Faktor       float64 `json:"faktor"`
	Status       string  `json:"status"`
	Version      int32   `json:"version"`
	CreatedAt    string  `json:"createdAt"`
	UpdatedAt    string  `json:"updatedAt"`
}

// IndukAtributView — baris atribut[] pada produkIndukViewSchema.
type IndukAtributView struct {
	IDInvAtribut int64  `json:"idInvAtribut"`
	KodeAtribut  string `json:"kodeAtribut"`
	NamaAtribut  string `json:"namaAtribut"`
	Wajib        bool   `json:"wajib"`
	Urutan       int32  `json:"urutan"`
}

// ProdukIndukView — padanan produkIndukViewSchema (harga money = nullable
// number; deskripsi hidup di kolom keterangan produk — patch 06).
type ProdukIndukView struct {
	ID                  int64              `json:"id"`
	Kode                string             `json:"kode"`
	Nama                string             `json:"nama"`
	Deskripsi           *string            `json:"deskripsi"`
	IDInvKategoriProduk int64              `json:"idInvKategoriProduk"`
	NamaKategori        string             `json:"namaKategori"`
	IDInvUnitUkur       int64              `json:"idInvUnitUkur"`
	KodeUnit            string             `json:"kodeUnit"`
	HargaJual           *float64           `json:"hargaJual"`
	HargaBiaya          *float64           `json:"hargaBiaya"`
	StokMinimum         int32              `json:"stokMinimum"`
	Status              string             `json:"status"`
	JumlahVarian        int                `json:"jumlahVarian"`
	Atribut             []IndukAtributView `json:"atribut"`
	Version             int32              `json:"version"`
	CreatedAt           string             `json:"createdAt"`
	UpdatedAt           string             `json:"updatedAt"`
}

// ProdukAtributView — pasangan nilai atribut varian (atribut[] produkView).
type ProdukAtributView struct {
	KodeAtribut string `json:"kodeAtribut"`
	NamaAtribut string `json:"namaAtribut"`
	Nilai       string `json:"nilai"`
}

// ProdukView — padanan produkViewSchema.
type ProdukView struct {
	ID                  int64               `json:"id"`
	KodeProduk          string              `json:"kodeProduk"`
	Nama                string              `json:"nama"`
	Tipe                string              `json:"tipe"`
	IDInvKategoriProduk int64               `json:"idInvKategoriProduk"`
	NamaKategori        string              `json:"namaKategori"`
	IDInvUnitUkur       int64               `json:"idInvUnitUkur"`
	KodeUnit            string              `json:"kodeUnit"`
	IDInvProdukInduk    *int64              `json:"idInvProdukInduk"`
	KodeInduk           *string             `json:"kodeInduk"`
	KunciKombinasi      *string             `json:"kunciKombinasi"`
	Atribut             []ProdukAtributView `json:"atribut"`
	JejakStok           bool                `json:"jejakStok"`
	Barcode             *string             `json:"barcode"`
	HargaJual           *float64            `json:"hargaJual"`
	HargaBiaya          *float64            `json:"hargaBiaya"`
	StokMinimum         int32               `json:"stokMinimum"`
	StokMaksimum        *int32              `json:"stokMaksimum"`
	ReorderAktif        bool                `json:"reorderAktif"`
	AdalahIndukVarian   bool                `json:"adalahIndukVarian"`
	BeratGram           *int32              `json:"beratGram"`
	VolumeCm3           *int32              `json:"volumeCm3"`
	Keterangan          *string             `json:"keterangan"`
	Status              string              `json:"status"`
	SaldoOnHand         int                 `json:"saldoOnHand"`
	Version             int32               `json:"version"`
	CreatedAt           string              `json:"createdAt"`
	UpdatedAt           string              `json:"updatedAt"`
}

// ProdukLookupView — padanan produkLookupViewSchema (picker ringkas M36).
type ProdukLookupView struct {
	ID               int64    `json:"id"`
	KodeProduk       string   `json:"kodeProduk"`
	Nama             string   `json:"nama"`
	Tipe             string   `json:"tipe"`
	IDInvProdukInduk *int64   `json:"idInvProdukInduk"`
	IDInvUnitUkur    int64    `json:"idInvUnitUkur"`
	KodeUnit         string   `json:"kodeUnit"`
	HargaJual        *float64 `json:"hargaJual"`
	SaldoOnHand      int      `json:"saldoOnHand"`
}

// KemasanView — padanan kemasanViewSchema.
type KemasanView struct {
	ID            int64   `json:"id"`
	IDInvProduk   int64   `json:"idInvProduk"`
	KodeProduk    string  `json:"kodeProduk"`
	NamaProduk    string  `json:"namaProduk"`
	Kode          string  `json:"kode"`
	Nama          string  `json:"nama"`
	Barcode       *string `json:"barcode"`
	IDInvUnitUkur int64   `json:"idInvUnitUkur"`
	KodeUnit      string  `json:"kodeUnit"`
	QtyIsi        int32   `json:"qtyIsi"`
	Status        string  `json:"status"`
	Version       int32   `json:"version"`
	CreatedAt     string  `json:"createdAt"`
	UpdatedAt     string  `json:"updatedAt"`
}

// KemasanLookupView — padanan kemasanLookupViewSchema (types/kemasan-types.ts):
// { kemasan, produk ringkas, qtyIsi }.
type KemasanLookupView struct {
	Kemasan KemasanView      `json:"kemasan"`
	Produk  ProdukLookupView `json:"produk"`
	QtyIsi  int32            `json:"qtyIsi"`
}
