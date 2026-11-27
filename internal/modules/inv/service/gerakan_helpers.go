// service/gerakan_helpers.go — helper murni fitur GERAKAN (prefiks gk —
// kolisi-aman di package service yang diisi fitur lain paralel). Konversi
// pgtype ↔ tipe Go polos ada di repository (tipe wrapper) — service bebas
// gen sqlc/pgtype (guard lapisan).
package service

import (
	"fmt"
	"strconv"
	"time"

	"nexierp/internal/core/errkontrak"
)

// parseIdGerakan — padanan Number(idRaw) JS: gagal parse (NaN) → 500 (PG
// error jalur Nest); pecah/≤0 → 404 (query tanpa hasil). Return (id, tampil,
// err) — tampil = String(Number) JS utk pesan 404 numerik.
func parseIdGerakan(raw string) (int64, string, error) {
	f, err := strconv.ParseFloat(trimSpasi(raw), 64)
	if err != nil {
		if trimSpasi(raw) == "" {
			// Number("") = 0 → 404.
			return 0, "0", errkontrak.NotFound("Gerakan id 0 tidak ditemukan.", invErrTidakDitemukan)
		}
		return 0, "", errkontrak.Internal("")
	}
	tampil := strconv.FormatFloat(f, 'f', -1, 64)
	if f != float64(int64(f)) || f < 1 {
		return 0, tampil, errkontrak.NotFound(
			fmt.Sprintf("Gerakan id %s tidak ditemukan.", tampil),
			invErrTidakDitemukan,
		)
	}
	return int64(f), tampil, nil
}

// trimSpasi — JS Number memotong whitespace pinggir.
func trimSpasi(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n' || s[0] == '\r') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t' || s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}

// gkWaktuAtauSekarang — input.tanggalJadwal ? new Date(str) : new Date();
// string rusak (Invalid Date) → 500 (jalur Nest: insert gagal).
func gkWaktuAtauSekarang(raw *string) (time.Time, error) {
	if raw == nil || *raw == "" {
		return time.Now(), nil
	}
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04", "2006-01-02"} {
		if t, err := time.Parse(layout, *raw); err == nil {
			return t, nil
		}
	}
	return time.Time{}, errkontrak.Internal("")
}

// gkToFixed4 — padanan Number.prototype.toFixed(4).
func gkToFixed4(v float64) string {
	return strconv.FormatFloat(v, 'f', 4, 64)
}

// gkPertamaToFixed4 — rantai `??` (payload → fallback1 → fallback2): kandidat
// non-nil pertama → toFixed(4); semua nil → nil (kolom NULL).
func gkPertamaToFixed4(kandidat ...*float64) *string {
	for _, k := range kandidat {
		if k != nil {
			v := gkToFixed4(*k)
			return &v
		}
	}
	return nil
}

// gkClonePayload — salin map payload event (base tidak dibagi antar topic).
func gkClonePayload(src map[string]any) map[string]any {
	out := make(map[string]any, len(src)+1)
	for k, v := range src {
		out[k] = v
	}
	return out
}
