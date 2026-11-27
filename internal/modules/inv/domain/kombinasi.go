// Package domain — fungsi MURNI domain fitur MASTER-A modul inv (padanan
// helper murni packages/schemas/src/inv/tipe.ts). Tanpa framework (echo/pgx/
// http) — unit-testable, dipakai service.
package domain

import (
	"sort"
	"strings"
)

// SusunKunciKombinasi — kunci kombinasi kanonik varian (D-19, padanan
// susunKunciKombinasi tipe.ts VERBATIM): pasangan [kodeAtribut, nilai]
// dinormalisasi (kode trim+UPPERCASE, nilai trim), diurut kode ASC lalu
// nilai (localeCompare ≈ urutan byte untuk ASCII), digabung `kode:nilai`
// dengan pemisah `|`. Contoh: `WARNA:Merah|UKURAN:XL`.
func SusunKunciKombinasi(pasangan [][2]string) string {
	norm := make([][2]string, len(pasangan))
	for i, p := range pasangan {
		norm[i] = [2]string{
			strings.ToUpper(strings.TrimSpace(p[0])),
			strings.TrimSpace(p[1]),
		}
	}
	sort.SliceStable(norm, func(i, j int) bool {
		if norm[i][0] != norm[j][0] {
			return norm[i][0] < norm[j][0] // localeCompare(kode)
		}
		return norm[i][1] < norm[j][1] // localeCompare(nilai)
	})
	parts := make([]string, len(norm))
	for i, p := range norm {
		parts[i] = p[0] + ":" + p[1]
	}
	return strings.Join(parts, "|")
}
