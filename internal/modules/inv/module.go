// Package inv — modul inventory Go: 114 endpoint padanan modules/inv
// NestJS (prefix inventory.*). Wiring satu pintu, dipanggil internal/app.
// Keputusan ratifikasi modul inv: ck_inv_saldo_on_hand → 409 INV-010
// seragam; race 23505 → 409 pesan pre-check verbatim; kode kemasan =
// unik global sesuai DB.
package inv

import (
	"github.com/labstack/echo/v4"

	"nexierp/internal/modules/inv/handler"
	"nexierp/internal/modules/inv/types"
)

// Register — pasang SEMUA route modul inv di bawah group /api.
func Register(api *echo.Group, d types.Deps) {
	handler.DaftarkanDashboard(api, d)
	handler.DaftarkanLaporan(api, d)
	handler.DaftarkanMasterA(api, d)     // produk, produk-induk, kategori, unit, konversi, kemasan
	handler.DaftarkanMasterB(api, d)     // gudang, lokasi, lot, jenis-operasi, atribut+nilai
	handler.DaftarkanGerakan(api, d)     // gerakan stok (konfirmasi/batal/reservasi)
	handler.DaftarkanOperasiLain(api, d) // mutasi(+dari-gr), penyesuaian, picking, jadwal-hitung
	handler.DaftarkanStok(api, d)        // saldo/recompute/atp + pengaturan
}
