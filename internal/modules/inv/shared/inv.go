// Package shared — helper umum modul inv (L2): util waktu/numeric/param
// di-port dari shared/inv.views.ts NestJS. Kontrak pesan error VERBATIM.
// ParseIDParam ada di views.go (fitur master-A — bentuk sama persis core
// shared; di sini TIDAK diduplikasi).
package shared

import (
	"time"

	"nexierp/internal/core/errkontrak"
)

// ISO — time → string ISO-8601 UTC ala Date.toISOString() JS: 3 digit
// milidetik + akhiran Z (mis. 2026-11-27T09:00:00.000Z).
func ISO(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}

// RentangTanggal — batas tanggal string (yyyy-mm-dd) → awal/akhir hari
// (inclusive) waktu LOKAL (padanan `new Date("${dari}T00:00:00")` /
// `${sampai}T23:59:59.999`). Salah format → 400 VAL-400 field tanggalDari
// "Format tanggal tidak valid (yyyy-mm-dd)." — TERMASUK tanggalSampai
// invalid (laporan field tanggalDari — verbatim inv.views.ts).
func RentangTanggal(dari, sampai string) (time.Time, time.Time, error) {
	a, errA := time.ParseInLocation("2006-01-02", dari, time.Local)
	s, errS := time.ParseInLocation("2006-01-02", sampai, time.Local)
	if errA != nil || errS != nil {
		return time.Time{}, time.Time{}, errkontrak.Validation([]errkontrak.FieldIssue{
			{Field: "tanggalDari", Message: "Format tanggal tidak valid (yyyy-mm-dd)."},
		})
	}
	awal := time.Date(a.Year(), a.Month(), a.Day(), 0, 0, 0, 0, time.Local)
	akhir := time.Date(s.Year(), s.Month(), s.Day(), 23, 59, 59, int(999*time.Millisecond), time.Local)
	return awal, akhir, nil
}
