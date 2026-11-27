package domain

import (
	"testing"
	"time"
)

// Unit test murni BatasJatuhTempo — 4 frekuensi (padanan jadwal-rules.spec
// sumber; basis waktu tetap agar deterministik).
//
// Basis: Rabu 15 Okt 2025 14:30 lokal (dow = 3 — 0=Minggu).
var basis = time.Date(2025, 10, 15, 14, 30, 0, 0, time.Local)

func harian(t *testing.T) {
	t.Helper()
	b := BatasJatuhTempo("HARIAN", 1, basis)
	awalHari := time.Date(2025, 10, 15, 0, 0, 0, 0, time.Local)
	if !b.Equal(awalHari) {
		t.Fatalf("HARIAN: harap %v, dapat %v", awalHari, b)
	}
}

func mingguan(t *testing.T) {
	t.Helper()
	// hariEksekusi 1 (Senin) pada minggu berjalan → Senin 13 Okt 2025.
	b := BatasJatuhTempo("MINGGUAN", 1, basis)
	harap := time.Date(2025, 10, 13, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("MINGGUAN(1): harap %v, dapat %v", harap, b)
	}
	// hariEksekusi 3 (Rabu = hari ini) → awal hari ini (selisih 0).
	b = BatasJatuhTempo("MINGGUAN", 3, basis)
	harap = time.Date(2025, 10, 15, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("MINGGUAN(3): harap %v, dapat %v", harap, b)
	}
	// hariEksekusi 0 (Minggu) → Minggu 12 Okt 2025.
	b = BatasJatuhTempo("MINGGUAN", 0, basis)
	harap = time.Date(2025, 10, 12, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("MINGGUAN(0): harap %v, dapat %v", harap, b)
	}
}

func bulanan(t *testing.T) {
	t.Helper()
	// Tanggal 15 = hari ini → batas awal hari ini (tidak mundur bulan).
	b := BatasJatuhTempo("BULANAN", 15, basis)
	harap := time.Date(2025, 10, 15, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("BULANAN(15): harap %v, dapat %v", harap, b)
	}
	// Tanggal 20 > hari ini (15) → mundur 1 bulan: 20 Sep 2025.
	b = BatasJatuhTempo("BULANAN", 20, basis)
	harap = time.Date(2025, 9, 20, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("BULANAN(20): harap %v, dapat %v", harap, b)
	}
	// hariEksekusi di luar 1..28 di-clamp (31 → 28) — 28 Sep 2025.
	b = BatasJatuhTempo("BULANAN", 31, basis)
	harap = time.Date(2025, 9, 28, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("BULANAN(31): harap %v, dapat %v", harap, b)
	}
}

func triwulan(t *testing.T) {
	t.Helper()
	// Seperti BULANAN + mundur 2 bulan lagi: 15 Okt → 15 Agu 2025 (hari ini
	// sudah ≥ tanggal eksekusi — tanpa mundur 1 bulan, lalu −2 bulan).
	b := BatasJatuhTempo("TRIWULAN", 15, basis)
	harap := time.Date(2025, 8, 15, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("TRIWULAN(15): harap %v, dapat %v", harap, b)
	}
	// Tanggal 20 > hari ini → mundur 1 bulan (20 Sep) lalu 2 bulan (20 Jul).
	b = BatasJatuhTempo("TRIWULAN", 20, basis)
	harap = time.Date(2025, 7, 20, 0, 0, 0, 0, time.Local)
	if !b.Equal(harap) {
		t.Fatalf("TRIWULAN(20): harap %v, dapat %v", harap, b)
	}
}

func TestBatasJatuhTempo(t *testing.T) {
	t.Run("HARIAN", harian)
	t.Run("MINGGUAN", mingguan)
	t.Run("BULANAN", bulanan)
	t.Run("TRIWULAN", triwulan)
}
