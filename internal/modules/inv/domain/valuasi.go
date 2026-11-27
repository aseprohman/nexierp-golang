// Package domain — fungsi MURNI domain modul inv (tanpa import DB/framework)
// sehingga unit-testable.
//
// valuasi.go — valuasi persediaan (padanan domain/valuasi.ts VERBATIM —
// patch 04, D-27/D-28, P0 #1).
//
// Metode valuasi diambil dari kategori produk (`inv_kategori_produk.metode_valuasi`):
//   - STANDAR : perilaku lama tetap (harga_biaya / nilai dari payload) — tidak diubah;
//   - AVCO    : rata-rata bergerak — inbound SELESAI menggeser rata-rata dan
//     MENULIS BALIK `inv_produk.harga_biaya` (D-28); outbound SELESAI
//     memakai harga_biaya terkini; TIDAK memakai tabel lapisan;
//   - FIFO    : inbound SELESAI melahirkan lapisan `inv_lapisan_biaya`; outbound
//     SELESAI mengonsumsi lapisan tertua dulu (FEFO biaya); lapisan
//     kurang (data lama sebelum patch) → fallback harga_biaya — TIDAK
//     menggagalkan konfirmasi, cukup dicatat audit.
//
// Semua fungsi murni & deterministik — pembulatan 4 desimal (numeric(18,4)).
package domain

import "math"

// LapisanFifo — satu lapisan biaya FIFO tersedia (sisa = qty_masuk − qty_terpakai).
type LapisanFifo struct {
	ID int64
	// Sisa — qty yang masih bisa dikonsumsi (> 0).
	Sisa float64
	// Biaya — biaya persatuan lapisan.
	Biaya float64
}

// PemakaianLapisan — satu pemakaian lapisan saat konsumsi keluar.
type PemakaianLapisan struct {
	ID    int64
	Qty   float64
	Biaya float64
}

// HasilKonsumsiFifo — hasil konsumsi FIFO utk satu gerakan keluar.
type HasilKonsumsiFifo struct {
	// Pemakaian — lapisan yang terpakai (urut lama → baru).
	Pemakaian []PemakaianLapisan
	// QtyTerlayani — total qty yang ditutup lapisan.
	QtyTerlayani float64
	// FallbackQty — qty yang tidak tertutup lapisan (data lama) → fallback harga_biaya.
	FallbackQty float64
}

// Putus4 — pembulatan uang/nilai 4 desimal (numeric(18,4)).
// Paritas JS `Math.round(n * 10_000) / 10_000` — Math.round(x) = floor(x+0.5),
// bukan math.Round Go (half away-from-zero) agar -0.00005 dst identik.
func Putus4(n float64) float64 {
	return math.Floor(n*10_000+0.5) / 10_000
}

// HitungRataRataBergerak — rata-rata bergerak AVCO (D-27/D-28):
//
//	avgBaru = ((saldoQty × avgLama) + (qtyMasuk × biayaMasuk)) / (saldoQty + qtyMasuk)
//
// avgLama = harga_biaya produk (?? biayaMasuk bila belum pernah ada).
func HitungRataRataBergerak(saldoQty, avgLama, qtyMasuk, biayaMasuk float64) float64 {
	totalQty := saldoQty + qtyMasuk
	if totalQty <= 0 {
		return Putus4(biayaMasuk)
	}
	if saldoQty <= 0 {
		return Putus4(biayaMasuk)
	}
	totalNilai := saldoQty*avgLama + qtyMasuk*biayaMasuk
	return Putus4(totalNilai / totalQty)
}

// KonsumsiLapisanFifo — konsumsi lapisan FIFO tertua dulu (D-27) — input
// HARUS sudah terurut (tanggal_masuk, id) ASC; sisa tidak cukup → sisanya
// jatuh ke fallback (dilaporkan, bukan error — data lama pra-patch tidak
// punya lapisan).
func KonsumsiLapisanFifo(lapisan []LapisanFifo, qtyKeluar float64) HasilKonsumsiFifo {
	pemakaian := []PemakaianLapisan{}
	sisa := qtyKeluar
	for _, l := range lapisan {
		if sisa <= 0 {
			break
		}
		ambil := math.Min(l.Sisa, sisa)
		if ambil <= 0 {
			continue
		}
		pemakaian = append(pemakaian, PemakaianLapisan{ID: l.ID, Qty: ambil, Biaya: l.Biaya})
		sisa -= ambil
	}
	qtyTerlayani := qtyKeluar - math.Max(0, sisa)
	return HasilKonsumsiFifo{
		Pemakaian:    pemakaian,
		QtyTerlayani: qtyTerlayani,
		FallbackQty:  math.Max(0, sisa),
	}
}

// NilaiPersatuanFifo — nilai persatuan hasil konsumsi FIFO =
// Σ(qty lapisan × biaya) + fallback dibagi total qty selesai. Fallback
// memakai harga_biaya terkini produk.
func NilaiPersatuanFifo(hasil HasilKonsumsiFifo, qtySelesai, fallbackBiaya float64) float64 {
	if qtySelesai <= 0 {
		return 0
	}
	nilaiLapisan := 0.0
	for _, p := range hasil.Pemakaian {
		nilaiLapisan += p.Qty * p.Biaya
	}
	total := nilaiLapisan + hasil.FallbackQty*fallbackBiaya
	return Putus4(total / qtySelesai)
}
