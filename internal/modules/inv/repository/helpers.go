// helpers.go — konversi pgtype → tipe Go polos + mapper maWaktu/maAngka modul
// inv (padanan inv.views.ts: maIso/isoRequired/maAngka + helper repository
// wrapper). Semua repository MASTER-A menerima executor gen.DBTX
// (pool pgx | pgx.Tx) sebagai parameter pertama — service meneruskan tx
// transaksi bisnis yang sama atau pool untuk baca non-tx.
package repository

import (
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/repository/gen"
)

// DBTX — executor (pool | tx) ala kontrak audit.
type DBTX = gen.DBTX

/* ------------------------------------------------------------------ */
/* Waktu — ISO-8601 (padanan maIso/isoRequired: toISOString)             */
/* ------------------------------------------------------------------ */

// maIso — timestamptz wajib → ISO-8601.
func maIso(t pgtype.Timestamptz) string { return t.Time.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

// maIsoWaktu — time.Time → ISO-8601 (payload input handler).
func maIsoWaktu(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

// maWaktu — time.Time → pgtype.Timestamptz.
func maWaktu(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

/* ------------------------------------------------------------------ */
/* Teks / maAngka kecil                                                  */
/* ------------------------------------------------------------------ */

// maTeksNihil — *string → pgtype.Text (nil = NULL).
func maTeksNihil(v *string) pgtype.Text {
	if v == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *v, Valid: true}
}

// maTxtPtr — pgtype.Text → *string.
func maTxtPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

// maI4Ptr — pgtype.Int4 → *int32.
func maI4Ptr(i pgtype.Int4) *int32 {
	if !i.Valid {
		return nil
	}
	v := i.Int32
	return &v
}

// maI8Ptr — pgtype.Int8 → *int64.
func maI8Ptr(i pgtype.Int8) *int64 {
	if !i.Valid {
		return nil
	}
	v := i.Int64
	return &v
}

// maI8Nilai — *int64 → pgtype.Int8 (nil = NULL).
func maI8Nilai(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// maI4Nilai — *int32 → pgtype.Int4 (nil = NULL).
func maI4Nilai(v *int32) pgtype.Int4 {
	if v == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *v, Valid: true}
}

// maUuidNilai — string UUID v4 → pgtype.UUID.
func maUuidNilai(s string) pgtype.UUID {
	var u pgtype.UUID
	_ = u.Scan(s)
	return u
}

// maStrPtrNihil — string kosong → nil (param opsional teks).
func maStrPtrNihil(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

/* ------------------------------------------------------------------ */
/* Money/rasio — numeric PG (padanan maAngka: numeric → number)          */
/* ------------------------------------------------------------------ */

// maNumericTeksis — pgtype.Numeric → *string teks desimal (drizzle numeric
// keluar string; nilai warisan harga induk diteruskan apa adanya).
func maNumericTeksis(n pgtype.Numeric) *string {
	if !n.Valid {
		return nil
	}
	v, err := n.Value()
	if err != nil {
		return nil
	}
	s, _ := v.(string)
	return &s
}

// maAngkaPtr — padanan maAngka(value) tipe.ts: numeric → *float64 (Number).
func maAngkaPtr(n pgtype.Numeric) *float64 {
	s := maNumericTeksis(n)
	if s == nil {
		return nil
	}
	f, err := strconv.ParseFloat(*s, 64)
	if err != nil {
		return nil
	}
	return &f
}

// maAngka — padanan angka0: numeric NOT NULL (::text) → float64.
func maAngka(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

// maNumericDari — *string toFixed(...) → pgtype.Numeric (NULL bila nil).
func maNumericDari(s *string) pgtype.Numeric {
	if s == nil {
		return pgtype.Numeric{}
	}
	var n pgtype.Numeric
	if err := n.ScanScientific(*s); err != nil {
		return pgtype.Numeric{}
	}
	return n
}

// maAsInt — hasil subquery COALESCE(...::int) yang sqlc scan sebagai any.
func maAsInt(v any) int {
	switch t := v.(type) {
	case int32:
		return int(t)
	case int64:
		return int(t)
	case int:
		return t
	}
	return 0
}

/* ------------------------------------------------------------------ */
/* Sort whitelist (padanan drizzlePageBounds)                          */
/* ------------------------------------------------------------------ */

// maPilihSort — ambil SortKey PERTAMA yang terdaftar whitelist (urutan
// deklarasi drizzle dipertahankan); fallback (field, asc) bila tak cocok.
func MaPilihSort(pr *errkontrak.PageRequest, whitelist map[string]string, fallbackField string) (string, bool) {
	for _, k := range pr.Sort {
		if label, ada := whitelist[k.Field]; ada {
			return label, k.Desc
		}
	}
	return fallbackField, false
}

// maI8Val — pgtype.Int8 → int64 (NULL → 0; konvensi view gerakan "0 = warisi header").
func maI8Val(n pgtype.Int8) int64 {
	if !n.Valid {
		return 0
	}
	return n.Int64
}

// maAnyI8 — hasil kolom nullable (CASE…NULL, interface{}) → *int64.
func maAnyI8(v any) *int64 {
	switch x := v.(type) {
	case int64:
		return &x
	case pgtype.Int8:
		return maI8Ptr(x)
	case []byte:
		n, err := strconv.ParseInt(string(x), 10, 64)
		if err != nil {
			return nil
		}
		return &n
	case string:
		n, err := strconv.ParseInt(x, 10, 64)
		if err != nil {
			return nil
		}
		return &n
	}
	return nil
}

// maAnyI8Val — maAnyI8 dengan konvensi 0 = NULL.
func maAnyI8Val(v any) int64 {
	if p := maAnyI8(v); p != nil {
		return *p
	}
	return 0
}
