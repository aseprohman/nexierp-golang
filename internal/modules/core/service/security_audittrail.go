// security_audittrail.go — service AUDIT TRAIL pusat (padanan
// services/security/audit-trail.service.ts): port fetchAuditTrail +
// exportAuditTrail. Baca non-transaksi; aksi ekspor TETAP tercatat sebagai
// baris `export` di trail (R11) dalam tx terpisah. Konversi CSV memakai
// generator shared (RFC 4180 — padanan shared/csv.ts).
package service

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// AuditTrailService — kernel fitur audit trail pusat.
type AuditTrailService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.AuditTrailRepository
}

// NewAuditTrailService membuat service audit trail.
func NewAuditTrailService(db *database.DB, auditSvc *audit.Service) *AuditTrailService {
	return &AuditTrailService{db: db, audit: auditSvc, repo: repository.NewAuditTrailRepository()}
}

// PageAuditTrail — SATU HALAMAN audit trail: urutan default at DESC,
// id DESC; sort query dibatasi whitelist kolom waktu/id/severity. Batas
// tanggal dikonversi ke instan UTC: dateFrom inklusif mulai awal hari,
// dateTo eksklusif awal hari berikutnya (persis service NestJS).
func (s *AuditTrailService) PageAuditTrail(ctx context.Context, filter types.AuditTrailFilter, pr *errkontrak.PageRequest) (errkontrak.Page[types.AuditTrailEntry], error) {
	from, to, err := batasTanggal(filter)
	if err != nil {
		return errkontrak.Page[types.AuditTrailEntry]{}, err
	}
	return s.repo.PageAuditTrail(ctx, s.db.Pool, filter, pr, from, to)
}

// ListActions — opsi dropdown aksi: distinct ringan (maks 200).
func (s *AuditTrailService) ListActions(ctx context.Context) ([]string, error) {
	return s.repo.ListActions(ctx, s.db.Pool)
}

// ExportCsv — TANPA pagination (seluruh baris cocok, urut at DESC, id
// DESC, LIMIT 50.000). Aksi ekspor tercatat di trail dalam tx terpisah
// (afterValue: filter, rows, format csv). Return csv + nama attachment.
func (s *AuditTrailService) ExportCsv(ctx context.Context, filter types.AuditTrailFilter, actor audit.Actor) (string, string, error) {
	from, to, err := batasTanggal(filter)
	if err != nil {
		return "", "", err
	}
	views, err := s.repo.EksporAuditTrail(ctx, s.db.Pool, filter, from, to)
	if err != nil {
		return "", "", err
	}

	rows := make([][]any, len(views))
	for i, v := range views {
		rows[i] = []any{
			v.ID,
			v.At,
			v.ActorUserID,
			v.ActorName,
			v.ModuleKey,
			v.EntityType,
			v.EntityID,
			v.Action,
			v.Severity,
			v.BeforeValue,
			v.AfterValue,
			v.IPAddress,
			v.UserAgent,
			v.RequestID,
		}
	}
	csv := shared.ToCSV(types.CSVHeaders, rows)

	// Aksi ekspor tercatat di trail — tx TERPISAH dari pembacaan baris.
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		_, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "audit_trail",
				EntityID:   "*",
				Action:     "export",
				AfterValue: audit.Snapshot{
					"filter": filterJSON(filter),
					"rows":   len(views),
					"format": "csv",
				},
				Severity: audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
	if err != nil {
		return "", "", err
	}

	return csv, shared.CSVAttachmentFilename("audit-trail", time.Now()), nil
}

// batasTanggal — dateFrom/dateTo (YYYY-MM-DD) → instan UTC: from = awal
// hari (inklusif, >=), to = awal hari berikutnya (eksklusif, <).
func batasTanggal(filter types.AuditTrailFilter) (*time.Time, *time.Time, error) {
	parse := func(raw *string) (*time.Time, error) {
		if raw == nil {
			return nil, nil
		}
		t, err := time.Parse("2006-01-02", (*raw)[:10])
		if err != nil {
			// Format lolos regex zod tapi bukan tanggal sah (mis. 2026-13-99)
			// → kegagalan internal, persis Instant invalid di sisi NestJS.
			return nil, errkontrak.Internal("Terjadi kesalahan internal pada server.", "SYS-001")
		}
		return &t, nil
	}
	from, err := parse(filter.DateFrom)
	if err != nil {
		return nil, nil, err
	}
	to, err := parse(filter.DateTo)
	if err != nil {
		return nil, nil, err
	}
	if to != nil {
		next := to.UTC().AddDate(0, 0, 1)
		to = &next
	}
	return from, to, nil
}

// filterJSON — JSON.stringify(filter) dengan urutan key deklarasi schema
// (moduleKey, severity, action, query, dateFrom, dateTo); field undefined
// dihilangkan, query "" tetap ikut (persis zod + JSON.stringify).
func filterJSON(f types.AuditTrailFilter) string {
	var b strings.Builder
	b.WriteString("{")
	first := true
	write := func(key string, val *string) {
		if val == nil {
			return
		}
		if !first {
			b.WriteString(",")
		}
		first = false
		k, _ := json.Marshal(key)
		v, _ := json.Marshal(*val)
		b.Write(k)
		b.WriteString(":")
		b.Write(v)
	}
	write("moduleKey", f.ModuleKey)
	write("severity", f.Severity)
	write("action", f.Action)
	write("query", f.Query)
	write("dateFrom", f.DateFrom)
	write("dateTo", f.DateTo)
	b.WriteString("}")
	return b.String()
}
