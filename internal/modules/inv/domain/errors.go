// Package domain — aturan MURNI modul inv. errors.go — pemetaan pesan &
// kode error domain MASTER-B (padanan domain/errors.ts + KODE_ERROR_INV
// packages/schemas/src/inv/tipe.ts): 404 paritas "tidak ada data" untuk
// baris di luar cakupan data-scope 'storages' (pesan SAMA dengan 404 biasa
// — keberadaan tidak pernah bocor) dan kosakata kode INV-xxx berkode
// problem+json.
package domain

import "fmt"

import "nexierp/internal/core/errkontrak"

// Kosakata kode error modul INV (problem+json `code`) — mirror verbatim
// KODE_ERROR_INV tipe.ts; hanya yang terpakai fitur aktif yang diberi
// konstanta ter-ekspor (sisanya tinggal ditambah pemakainya).
const (
	// KodeInvHapusDiblokir — INV-002.
	KodeInvHapusDiblokir = "INV-002"
	// KodeInvGerakanTidakSah — INV-003 (lokasi INTERNAL wajib gudang).
	KodeInvGerakanTidakSah = "INV-003"
	// KodeInvSaldoTidakCukup — INV-010.
	KodeInvSaldoTidakCukup = "INV-010"
	// KodeInvLokasiMasihBerisi — INV-014.
	KodeInvLokasiMasihBerisi = "INV-014"
	// KodeInvBarcodeTidakCocok — INV-015.
	KodeInvBarcodeTidakCocok = "INV-015"
	// KodeInvVersiBentrok — INV-017 (optimistic locking).
	KodeInvVersiBentrok = "INV-017"
	// KodeInvTidakDitemukan — INV-018.
	KodeInvTidakDitemukan = "INV-018"
	// KodeInvLokasiTidakDiizinkan — INV-021 (pindah gudang luar whitelist).
	KodeInvLokasiTidakDiizinkan = "INV-021"
)

// ErrGudangTersembunyi — 404 paritas "tidak ada data": gudang di luar
// cakupan scope aktor (pesan identik 404 biasa — padanan errGudangTersembunyi).
func ErrGudangTersembunyi(id int64) *errkontrak.DomainError {
	return errkontrak.NotFound(
		fmt.Sprintf("Gudang id %d tidak ditemukan.", id),
		KodeInvTidakDitemukan,
	)
}

// ErrLokasiTersembunyi — 404 paritas "tidak ada data": lokasi di luar
// cakupan scope aktor (padanan errLokasiTersembunyi).
func ErrLokasiTersembunyi(id int64) *errkontrak.DomainError {
	return errkontrak.NotFound(
		fmt.Sprintf("Lokasi id %d tidak ditemukan.", id),
		KodeInvTidakDitemukan,
	)
}

// ErrDokumenTersembunyi — 404 paritas "tidak ada data": dokumen mutasi di
// luar cakupan scope aktor (padanan errDokumenTersembunyi — dipakai fitur
// operasi/mutasi; didefinisikan di sini satu pintu bersama saudaranya).
func ErrDokumenTersembunyi(id int64) *errkontrak.DomainError {
	return errkontrak.NotFound(
		fmt.Sprintf("Dokumen mutasi id %d tidak ditemukan.", id),
		KodeInvTidakDitemukan,
	)
}

// KoordinatPasang — syarat koordinat lengkap: keduanya terisi ATAU keduanya
// kosong (kurir instant SHP membaca pasangan lat/lng — separuh terisi tidak
// berguna). Issue field = sisi yang terisi (padanan koordinatPasang
// gudang.service.ts); murni — unit-testable.
func KoordinatPasang(issues *[]errkontrak.FieldIssue, latitude, longitude *float64) {
	adaLat := latitude != nil
	adaLng := longitude != nil
	if adaLat != adaLng {
		field := "longitude"
		if adaLat {
			field = "latitude"
		}
		*issues = append(*issues, errkontrak.FieldIssue{
			Field:   field,
			Message: "Koordinat harus diisi berpasangan (latitude & longitude).",
		})
	}
}
