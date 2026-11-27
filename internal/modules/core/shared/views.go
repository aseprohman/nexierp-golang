// Package shared — helper lintas-fitur modul core (L2): pesan & semantik
// VERBATIM NestJS (shared/views.ts, shared/csv.ts, pagination bounds).
package shared

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
)

// ParseIDParam — padanan parseIdParam: bukan int ≥1 → 400 VAL-400 field
// dengan pesan verbatim `Harus bilangan bulat >= 1 (diterima: ${raw}).`
func ParseIDParam(raw, field string) (int64, error) {
	n, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || n < 1 {
		return 0, errkontrak.Validation([]errkontrak.FieldIssue{
			{Field: field, Message: fmt.Sprintf("Harus bilangan bulat >= 1 (diterima: %s).", raw)},
		})
	}
	return n, nil
}

// IfMatchVersion — padanan ifMatchVersion: header opsional; terima `42`
// maupun `"42"`; invalid → 400 VAL-400 field If-Match pesan verbatim.
// Kosong/absen → nil, nil (tanpa cek version).
func IfMatchVersion(req *http.Request) (*int64, error) {
	raw := strings.TrimSpace(req.Header.Get("If-Match"))
	if raw == "" {
		return nil, nil
	}
	raw = strings.Trim(raw, `"`)
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{
			{Field: "If-Match", Message: `Header If-Match harus berisi nomor version (mis. "42").`},
		})
	}
	return &n, nil
}

// ActorOf — aktor audit WAJIB dari JWT (padanan mutationActor):
// idCoreUsers/actorName dari user login; ip/ua dari request.
func ActorOf(req *http.Request) audit.Actor {
	u := auth.FromReq(req)
	idCoreUsers := (*int64)(nil)
	name := "system"
	if u != nil {
		id := u.ID
		idCoreUsers = &id
		name = u.Username
	}
	return audit.Actor{
		IDCoreUsers: idCoreUsers,
		ActorName:   name,
		IPAddress:   ipOf(req),
		UserAgent:   uaOf(req),
	}
}

func ipOf(req *http.Request) string {
	if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			xff = xff[:i]
		}
		if xff = strings.TrimSpace(xff); xff != "" {
			return xff
		}
	}
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		host = req.RemoteAddr
	}
	if host != "" {
		return host
	}
	return "-"
}

func uaOf(req *http.Request) string {
	if ua := req.Header.Get("User-Agent"); ua != "" {
		return ua
	}
	return "unknown"
}

// SortUnknown — padanan drizzlePageBounds: field sort di luar whitelist
// → 400 VAL-400 pesan verbatim `Field sort tidak dikenal: ${field}.`
func SortUnknown(pr *errkontrak.PageRequest, allowed []string) error {
	if pr == nil {
		return nil
	}
	set := map[string]bool{}
	for _, a := range allowed {
		set[a] = true
	}
	for _, s := range pr.Sort {
		if !set[s.Field] {
			return errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "sort", Message: fmt.Sprintf("Field sort tidak dikenal: %s.", s.Field)},
			})
		}
	}
	return nil
}

// CSVCell — escape RFC 4180 persis shared/csv.ts: null → ""; object → JSON;
// mengandung [";\n\r,] → dibungkus kutip + kutip internal digandakan.
func CSVCell(v any) string {
	if v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return quoteCSV(t)
	case map[string]any, []any:
		b, _ := json.Marshal(t)
		return quoteCSV(string(b))
	default:
		return quoteCSV(fmt.Sprintf("%v", t))
	}
}

func quoteCSV(s string) string {
	if strings.ContainsAny(s, "\";\n\r,") {
		return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
	}
	return s
}

// ToCSV — kolom dipisah KOMA (persis shared/csv.ts toCsv; baris dipisah
// CRLF, dokumen berakhir CRLF).
func ToCSV(headers []string, rows [][]any) string {
	var b strings.Builder
	writeRow := func(cells []string) {
		b.WriteString(strings.Join(cells, ","))
		b.WriteString("\r\n")
	}
	h := make([]string, len(headers))
	for i, x := range headers {
		h[i] = quoteCSV(x)
	}
	writeRow(h)
	for _, r := range rows {
		c := make([]string, len(r))
		for i, x := range r {
			c[i] = CSVCell(x)
		}
		writeRow(c)
	}
	return b.String()
}

// CSVAttachmentFilename — padanan csvAttachmentFilename:
// attachment; filename="audit-trail-YYYY-MM-DD-HH-MM-SS.csv"
func CSVAttachmentFilename(prefix string, now time.Time) string {
	stamp := now.UTC().Format("2006-01-02T15:04:05")
	stamp = strings.NewReplacer(":", "-", "T", "-").Replace(stamp)
	return fmt.Sprintf(`attachment; filename="%s-%s.csv"`, prefix, stamp)
}
