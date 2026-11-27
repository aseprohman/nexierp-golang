// repository/masterb_helpers.go — helper kecil lintas-fitur MASTER-B modul
// inv (prefix `mb` — pengaman kolisi nama dengan file fitur lain di package
// repository yang sama): konversi pgtype ↔ tipe Go polos, ISO-8601, token
// sort whitelist, dan terjemahan keputusan data-scope 'storages'.
package repository

import (
	"encoding/hex"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
)

// filterVal — nilai filter `?k=v` / `?filter[k]=v` (PageRequest.Filters);
// kosong → nil (filter dilewati — persis `req.filters["k"] || undefined`).
func filterVal(pr *errkontrak.PageRequest, key string) *string {
	if pr == nil {
		return nil
	}
	if v := pr.Filters[key]; v != "" {
		return &v
	}
	return nil
}

// filterNumVal — filter numerik dengan semantik Number(): gagal parse →
// error 500 generik (NestJS mengikat NaN ke query → PG error → 500; jalur
// ini praktis tidak pernah ditempuh pemakai normal).
func filterNumVal(pr *errkontrak.PageRequest, key string) (pgtype.Int8, error) {
	s := filterVal(pr, key)
	if s == nil {
		return pgtype.Int8{}, nil
	}
	f, err := strconv.ParseFloat(*s, 64)
	if err != nil || f != float64(int64(f)) {
		return pgtype.Int8{}, errkontrak.Internal("")
	}
	return pgtype.Int8{Int64: int64(f), Valid: true}, nil
}

// pageLimit — pr.Limit (≥1 dijamin parser; guard kecil) → int32.
func pageLimit(pr *errkontrak.PageRequest) int32 {
	if pr == nil || pr.Limit < 1 {
		return 20
	}
	return int32(pr.Limit)
}

// pageOffset — pr.Offset → int32.
func pageOffset(pr *errkontrak.PageRequest) int32 {
	if pr == nil {
		return 0
	}
	return int32(pr.Offset)
}

// strconvI64 — int64 → string (pesan error).
func strconvI64(v int64) string { return strconv.FormatInt(v, 10) }

// fmtUUID — [16]byte → string uuid standar ber-hubung.
func fmtUUID(b [16]byte) string {
	u := make([]byte, 36)
	hex.Encode(u[0:8], b[0:4])
	u[8] = '-'
	hex.Encode(u[9:13], b[4:6])
	u[13] = '-'
	hex.Encode(u[14:18], b[6:8])
	u[18] = '-'
	hex.Encode(u[19:23], b[8:10])
	u[23] = '-'
	hex.Encode(u[24:36], b[10:16])
	return string(u)
}

// CakupanStorages — keputusan cakupan data dimensi 'storages' milik modul
// inventory (padanan CakupanStorages repo NestJS — struktur identik
// DataScopeDecision evaluator core/rbac tanpa repo mengimpor evaluator):
// SEMUA = nil pointer (tanpa predicate); DENY_ALL = Deny; DAFTAR = IDs
// whitelist id gudang. Service yang menerjemahkan hasil evaluator.
type CakupanStorages struct {
	Deny bool    // DENY_ALL — tidak melihat apa pun
	IDs  []int64 // DAFTAR — whitelist id gudang (kolom target inv_gudang.id)
}

// CakupanDariDecision — terjemahan *rbac.Decision → *CakupanStorages
// (SEMUA → nil; DENY_ALL → Deny; DAFTAR → IDs).
func CakupanDariDecision(d *rbac.Decision) *CakupanStorages {
	if d == nil || d.Mode == rbac.ModeSemua {
		return nil
	}
	if d.Mode == rbac.ModeDenyAll {
		return &CakupanStorages{Deny: true}
	}
	return &CakupanStorages{IDs: d.IDs}
}

// mbIso — timestamptz NOT NULL → ISO-8601 toISOString() (UTC, 3 digit ms).
func mbIso(v pgtype.Timestamptz) string { return v.Time.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

// mbIsoPtr — timestamptz nullable → *string ISO (NULL → nil).
func mbIsoPtr(v pgtype.Timestamptz) *string {
	if !v.Valid {
		return nil
	}
	s := mbIso(v)
	return &s
}

// mbTimePtr — timestamptz nullable → *time.Time (NULL → nil).
func mbTimePtr(v pgtype.Timestamptz) *time.Time {
	if !v.Valid {
		return nil
	}
	t := v.Time
	return &t
}

// mbTxt — pgtype.Text → *string (NULL → nil).
func mbTxt(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	s := v.String
	return &s
}

// mbTxtNil — *string → pgtype.Text (nil = NULL).
func mbTxtNil(v *string) pgtype.Text {
	if v == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *v, Valid: true}
}

// mbTz — time.Time → pgtype.Timestamptz (NOT NULL).
func mbTz(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

// mbTzNil — *time.Time → pgtype.Timestamptz (nil = NULL).
func mbTzNil(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

// mbInt8 — pgtype.Int8 → *int64 (NULL → nil).
func mbInt8(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	x := v.Int64
	return &x
}

// mbInt8Nil — *int64 → pgtype.Int8 (nil = NULL).
func mbInt8Nil(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// mbNum — pgtype.Numeric → *float64 (NULL → nil; Number(...) mapper).
func mbNum(v pgtype.Numeric) *float64 {
	if !v.Valid {
		return nil
	}
	f, err := v.Float64Value()
	if err != nil || !f.Valid {
		return nil
	}
	x := f.Float64
	return &x
}

// mbNumNil — *float64 → pgtype.Numeric (nil = NULL; presisi via FormatFloat
// shortest — numeric(9,6) PG membulatkan sendiri).
func mbNumNil(v *float64) pgtype.Numeric {
	if v == nil {
		return pgtype.Numeric{}
	}
	var n pgtype.Numeric
	_ = n.ScanScientific(strconv.FormatFloat(*v, 'f', -1, 64))
	return n
}

// mbUUID — string uuid v4 → pgtype.UUID (parse hex tanpa tanda hubung).
func mbUUID(s string) pgtype.UUID {
	var u pgtype.UUID
	var b [16]byte
	hex := make([]byte, 0, 32)
	for i := 0; i < len(s) && len(hex) < 32; i++ {
		c := s[i]
		if c == '-' {
			continue
		}
		hex = append(hex, c)
	}
	if len(hex) != 32 {
		return u
	}
	for i := 0; i < 16; i++ {
		hi, err1 := strconv.ParseUint(string(hex[i*2]), 16, 8)
		lo, err2 := strconv.ParseUint(string(hex[i*2+1]), 16, 8)
		if err1 != nil || err2 != nil {
			return u
		}
		b[i] = byte(hi<<4 | lo)
	}
	return pgtype.UUID{Bytes: b, Valid: true}
}

// mbSort — ekstraksi kriteria sort PERTAMA hasil parse: (kolom kanonik,
// desc). pr.Sort kosong → ("", false) = urutan default query. Field sudah
// divalidasi whitelist lewat mbSortCek.
func mbSort(pr *errkontrak.PageRequest, kanonik map[string]string) (string, bool) {
	if pr == nil || len(pr.Sort) == 0 {
		return "", false
	}
	s := pr.Sort[0]
	return kanonik[s.Field], s.Desc
}

// mbSortCek — padanan drizzlePageBounds: field sort di luar whitelist →
// 400 VAL-400 pesan verbatim `Field sort tidak dikenal: ${field}.`
func mbSortCek(pr *errkontrak.PageRequest, allowed []string) error {
	if pr == nil {
		return nil
	}
	set := make(map[string]bool, len(allowed))
	for _, a := range allowed {
		set[a] = true
	}
	for _, s := range pr.Sort {
		if !set[s.Field] {
			return errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "sort", Message: "Field sort tidak dikenal: " + s.Field + "."},
			})
		}
	}
	return nil
}
