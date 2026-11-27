// jadwal.go — aturan MURNI jadwal hitung (padanan domain/jadwal-rules.ts
// VERBATIM — gelombang 1 refactor domain inv, fungsi batasJatuhTempo).
//
// Batas jatuh tempo — tanggal kemunculan terdekat (≤ sekarang) sesuai
// frekuensi; jadwal due bila terakhir_dibuat_pada < batas:
//   - HARIAN   : awal hari ini;
//   - MINGGUAN : hari dow = hariEksekusi (0=Minggu..6=Sabtu) pada minggu berjalan;
//   - BULANAN  : tanggal hariEksekusi bulan berjalan (mundur 1 bulan bila belum tercapai);
//   - TRIWULAN : seperti BULANAN + minimal jeda 3 bulan dari terakhir generate.
//
// Semantik waktu: JS setHours(0,0,0,0) = awal hari di TIMEZONE LOKAL proses
// (server) — Go pakai time.Date(...,0,0,0,0, sekarang.Location()). Nomor hari
// JS Date.getDay() (0=Minggu..6=Sabtu) identik penomoran time.Weekday Go.
package domain

import "time"

// BatasJatuhTempo — tanggal kemunculan terdekat (≤ sekarang) untuk satu
// frekuensi hitung; murni & deterministik (unit-testable).
func BatasJatuhTempo(frekuensi string, hariEksekusi int, sekarang time.Time) time.Time {
	batas := time.Date(sekarang.Year(), sekarang.Month(), sekarang.Day(), 0, 0, 0, 0, sekarang.Location())
	if frekuensi == "HARIAN" {
		return batas
	}
	if frekuensi == "MINGGUAN" {
		dow := int(batas.Weekday()) // 0=Minggu..6=Sabtu — identik getDay() JS
		selisih := (dow - hariEksekusi + 7) % 7
		return batas.AddDate(0, 0, -selisih)
	}
	// BULANAN / TRIWULAN — hariEksekusi = tanggal 1..28 bulan berjalan.
	h := hariEksekusi
	if h < 1 {
		h = 1
	}
	if h > 28 {
		h = 28
	}
	batas = time.Date(sekarang.Year(), sekarang.Month(), h, 0, 0, 0, 0, sekarang.Location())
	if batas.After(sekarang) {
		batas = batas.AddDate(0, -1, 0)
	}
	if frekuensi == "TRIWULAN" {
		// Minimal jeda 3 bulan: mundurkan batas 2 bulan lagi bila terakhir
		// belum cukup tua (dibandingkan oleh pemanggil lewat terakhir_dibuat_pada).
		batas = batas.AddDate(0, -2, 0)
	}
	return batas
}
