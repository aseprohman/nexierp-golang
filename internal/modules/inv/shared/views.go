// Package shared — helper lintas-fitur MASTER-A modul inv (padanan
// inv.views.ts NestJS): ParseIDParam (pesan verbatim) + konteks mutasi
// (aktor WAJIB dari JWT — ip/ua dari request). Tanpa echo (net/http saja)
// sesuai guard batas lapisan.
package shared

import (
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/errkontrak"
)

// ParseIDParam — padanan parseIdParam: bukan int ≥ 1 → 400 VAL-400 field
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

// ipOf — IP asli request (fallback "-" persis ipOf Nest).
func ipOf(req *http.Request) string {
	ip := req.RemoteAddr
	if host, _, err := net.SplitHostPort(ip); err == nil {
		ip = host
	}
	if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	if ip != "" {
		return ip
	}
	return "-"
}

// userAgentOf — User-Agent asli request (fallback "unknown" persis Nest).
func userAgentOf(req *http.Request) string {
	if ua := req.Header.Get("User-Agent"); ua != "" {
		return ua
	}
	return "unknown"
}

// ActorOf — aktor audit WAJIB dari JWT (padanan mutationActor):
// idCoreUsers/actorName dari user login (fallback id 0/"system");
// ipAddress/userAgent dari request asli.
func ActorOf(req *http.Request) audit.Actor {
	u := auth.FromReq(req)
	var idCoreUsers *int64
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
		UserAgent:   userAgentOf(req),
	}
}
