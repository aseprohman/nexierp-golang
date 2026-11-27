// repository helpers kecil lintas-fitur modul core: konversi nilai kolom
// pgtype + pesan 404 lookup.
package repository

import (
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// teksNihil — *string → pgtype.Text (nil = NULL).
func teksNihil(v *string) pgtype.Text {
	if v == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *v, Valid: true}
}

// waktu — time.Time → pgtype.Timestamptz (persis nilai now server).
func waktu(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

// teksNilai — pgtype.Text → *string (NULL → nil).
func teksNilai(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	out := v.String
	return &out
}

// notFoundLookup — pesan 404 lookup baca (tanpa suffix WLY — padanan
// WilayahRepository NestJS: `Provinsi id 42 tidak ditemukan.` NOTF-404).
func notFoundLookup(label string, id int64) string {
	return fmt.Sprintf("%s id %d tidak ditemukan.", label, id)
}
