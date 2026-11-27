// security_util.go — helper bersama repository SECURITY modul core:
// konversi pgtype → tipe view, decode jsonb, dan pembangun token sort
// whitelist (padanan drizzlePageBounds).
package repository

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/types"
)

// Whitelist sort tiap daftar (persis peta kolom drizzlePageBounds service
// NestJS) — field di luar daftar → 400 VAL-400 via shared.SortUnknown.
var (
	whitelistSessions    = []string{"login_at", "user_name", "expires_at", "id"}
	whitelistLoginAudit  = []string{"attempted_at", "username_tried", "id"}
	whitelistPasswordHis = []string{"set_at", "user_name", "id"}
	whitelistMfa         = []string{"user_name", "username", "id"}
	whitelistIpAllowlist = []string{"target", "cidr", "created_at", "id"}
	whitelistAuditTrail  = []string{"at", "id", "severity"}
)

// isNoRows — pgx.ErrNoRows (baris absen → nil diputuskan service).
func isNoRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }

// pgtypeBool — bool → pgtype.Bool (narg success).
func pgtypeBool(b bool) pgtype.Bool { return pgtype.Bool{Bool: b, Valid: true} }

// pgtypeTz — time.Time → pgtype.Timestamptz (NOT NULL).
func pgtypeTz(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

// textVal — pgtype.Text nullable → string (NULL → "").
func textVal(v pgtype.Text) string { return v.String }

// enumPtr — enum nullable → *string (NULL → nil).
func enumPtr(s string, valid bool) *string {
	if !valid {
		return nil
	}
	return &s
}

// sortToken — token '<field>:<dir>' dari kriteria sort PERTAMA hasil parse
// (persis drizzlePageBounds: satu kriteria sort per query — field sudah
// divalidasi whitelist lewat shared.SortUnknown oleh pemanggil). Token
// kosong = pakai urutan default query.
func sortToken(pr *errkontrak.PageRequest) string {
	if pr == nil || len(pr.Sort) == 0 {
		return ""
	}
	s := pr.Sort[0]
	dir := "asc"
	if s.Desc {
		dir = "desc"
	}
	return s.Field + ":" + dir
}

// textOrNil — string filter opsional: kosong → NULL (narg).
func textOrNil(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

// int8Ptr — pgtype.Int8 → *int64 (NULL → nil).
func int8Ptr(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	x := v.Int64
	return &x
}

// textPtr — pgtype.Text → *string (NULL → nil).
func textPtr(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	s := v.String
	return &s
}

// isoTZ — timestamptz NOT NULL → ISO toISOString().
func isoTZ(v pgtype.Timestamptz) string { return types.Iso(v.Time) }

// isoTZPtr — timestamptz nullable → *string (NULL → nil).
func isoTZPtr(v pgtype.Timestamptz) *string {
	if !v.Valid {
		return nil
	}
	s := types.Iso(v.Time)
	return &s
}

// jsonValue — byte jsonb → nilai apa adanya (object/array/string/number/
// bool); payload rusak diteruskan sebagai string — jangan buang data.
func jsonValue(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return string(b)
	}
	return v
}
