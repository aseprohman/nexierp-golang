// Package types — view respons fitur DASHBOARD (kontrak JSON persis zod
// @nexierp/schemas inv/views.ts: dashboardRingkasanViewSchema,
// dashboardTrenRowViewSchema). Konvensi: waktu ISO 8601 string, numeric PG →
// number (JSON number), qty int.
package types

// DashboardRingkasanView — KPI ringkasan inventory (dashboardRingkasanViewSchema).
type DashboardRingkasanView struct {
	TotalSku                    int64   `json:"totalSku"`
	SkuAktif                    int64   `json:"skuAktif"`
	SkuDiBawahMin               int64   `json:"skuDiBawahMin"`
	TotalNilaiPersediaan        float64 `json:"totalNilaiPersediaan"`
	GerakanHariIni              int64   `json:"gerakanHariIni"`
	GerakanTerbuka              int64   `json:"gerakanTerbuka"`
	PenyesuaianMenungguApproval int64   `json:"penyesuaianMenungguApproval"`
	LotKedaluwarsa              int64   `json:"lotKedaluwarsa"`
	ReorderTertunda             int64   `json:"reorderTertunda"`
}

// DashboardTrenRowView — tren gerakan harian (dashboardTrenRowViewSchema).
type DashboardTrenRowView struct {
	Tanggal     string  `json:"tanggal"`
	Masuk       int64   `json:"masuk"`
	Keluar      int64   `json:"keluar"`
	NilaiMasuk  float64 `json:"nilaiMasuk"`
	NilaiKeluar float64 `json:"nilaiKeluar"`
}
