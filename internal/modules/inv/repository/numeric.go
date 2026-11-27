package repository

import (
	"github.com/jackc/pgx/v5/pgtype"
)

// Pindahan dari shared (guard: pgx hanya di repository/).
// Angka — numeric PG → *float64 (JSON number; NULL/invalid → nil) — padanan
// angka() inv.views.ts: `Number(value)` sebelum respons.
func Angka(n pgtype.Numeric) *float64 {
	v, err := n.Float64Value()
	if err != nil || !v.Valid {
		return nil
	}
	f := v.Float64
	return &f
}

// Angka0 — numeric PG → float64 (fallback 0) — padanan angka0().
func Angka0(n pgtype.Numeric) float64 {
	v, err := n.Float64Value()
	if err != nil || !v.Valid {
		return 0
	}
	return v.Float64
}
