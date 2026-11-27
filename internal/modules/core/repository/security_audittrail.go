// security_audittrail.go — SATU-SATUNYA pengguna sqlc fitur AUDIT TRAIL
// pusat modul core (padanan repositories/security/audit-trail.repository.ts;
// tabel core_audit_trail JOIN core_modules). Konversi CSV + pencatatan aksi
// ekspor tetap di service — di sini hanya query + mapper.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// AuditTrailRepository — wrapper sqlc area audit trail.
type AuditTrailRepository struct{}

// NewAuditTrailRepository membuat repository (tanpa state).
func NewAuditTrailRepository() *AuditTrailRepository { return &AuditTrailRepository{} }

// filterArgs — terjemahan filter modul → param sqlc (enum dibandingkan
// via ::text; tanggal sudah timestamptz dari service).
type filterArgs struct {
	ModuleKey, Severity, Action, Query pgtype.Text
	DateFrom, DateTo                   pgtype.Timestamptz
}

// trailFilter — konversi filter view → argumen query sqlc.
func trailFilter(f types.AuditTrailFilter, dateFrom, dateTo *time.Time) filterArgs {
	return filterArgs{
		ModuleKey: textOrNilPtr(f.ModuleKey),
		Severity:  textOrNilPtr(f.Severity),
		Action:    textOrNilPtr(f.Action),
		Query:     textOrNilPtr(f.Query),
		DateFrom:  tzPtr(dateFrom),
		DateTo:    tzPtr(dateTo),
	}
}

// ListActions — DAFTAR AKSI DISTINCT (sumber opsi dropdown filter) — 1
// query ringan, dibatasi 200, urut abjad.
func (r *AuditTrailRepository) ListActions(ctx context.Context, exec DBTX) ([]string, error) {
	actions, err := gen.New(exec).ListAuditActions(ctx)
	if err != nil {
		return nil, err
	}
	if actions == nil {
		actions = []string{}
	}
	return actions, nil
}

// PageAuditTrail — SATU HALAMAN audit trail: default at DESC + tie-break
// id DESC; whitelist sort at, id, severity.
func (r *AuditTrailRepository) PageAuditTrail(ctx context.Context, exec DBTX, f types.AuditTrailFilter, pr *errkontrak.PageRequest, dateFrom, dateTo *time.Time) (errkontrak.Page[types.AuditTrailEntry], error) {
	if err := shared.SortUnknown(pr, whitelistAuditTrail); err != nil {
		return errkontrak.Page[types.AuditTrailEntry]{}, err
	}
	base := trailFilter(f, dateFrom, dateTo)
	params := gen.PageAuditTrailParams{
		ModuleKey: base.ModuleKey,
		Severity:  base.Severity,
		Action:    base.Action,
		Query:     base.Query,
		DateFrom:  base.DateFrom,
		DateTo:    base.DateTo,
		Sort:      sortToken(pr),
		Limit:     int32(pr.Limit),
		Offset:    int32(pr.Offset),
	}
	rows, err := gen.New(exec).PageAuditTrail(ctx, params)
	if err != nil {
		return errkontrak.Page[types.AuditTrailEntry]{}, err
	}
	countParams := gen.CountAuditTrailParams{
		ModuleKey: base.ModuleKey,
		Severity:  base.Severity,
		Action:    base.Action,
		Query:     base.Query,
		DateFrom:  base.DateFrom,
		DateTo:    base.DateTo,
	}
	total, err := gen.New(exec).CountAuditTrail(ctx, countParams)
	if err != nil {
		return errkontrak.Page[types.AuditTrailEntry]{}, err
	}
	views := make([]types.AuditTrailEntry, len(rows))
	for i, row := range rows {
		views[i] = auditView(row.ID, row.At, row.IDCoreUsers, row.ActorName,
			row.EntityType, row.EntityID, row.Action, row.BeforeValue,
			row.AfterValue, string(row.Severity), row.IpAddress, row.UserAgent,
			row.RequestID, row.ModuleKey)
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// EksporAuditTrail — seluruh baris cocok TANPA pagination (bahan ekspor
// CSV service) — urut at DESC, id DESC, dibatasi LIMIT 50.000.
func (r *AuditTrailRepository) EksporAuditTrail(ctx context.Context, exec DBTX, f types.AuditTrailFilter, dateFrom, dateTo *time.Time) ([]types.AuditTrailEntry, error) {
	base := trailFilter(f, dateFrom, dateTo)
	params := gen.EksporAuditTrailParams{
		ModuleKey: base.ModuleKey,
		Severity:  base.Severity,
		Action:    base.Action,
		Query:     base.Query,
		DateFrom:  base.DateFrom,
		DateTo:    base.DateTo,
	}
	rows, err := gen.New(exec).EksporAuditTrail(ctx, params)
	if err != nil {
		return nil, err
	}
	views := make([]types.AuditTrailEntry, len(rows))
	for i, row := range rows {
		views[i] = auditView(row.ID, row.At, row.IDCoreUsers, row.ActorName,
			row.EntityType, row.EntityID, row.Action, row.BeforeValue,
			row.AfterValue, string(row.Severity), row.IpAddress, row.UserAgent,
			row.RequestID, row.ModuleKey)
	}
	return views, nil
}

// auditView — mapper baris mentah → AuditTrailEntry (moduleKey dari JOIN).
func auditView(
	id int64,
	at pgtype.Timestamptz,
	idCoreUsers pgtype.Int8,
	actorName, entityType, entityID, action string,
	beforeValue, afterValue []byte,
	severity, ipAddress, userAgent, requestID string,
	moduleKey gen.NullCoreModuleKey,
) types.AuditTrailEntry {
	return types.AuditTrailEntry{
		ID:          id,
		At:          isoTZ(at),
		ActorUserID: int8Ptr(idCoreUsers),
		ActorName:   actorName,
		ModuleKey:   enumPtr(string(moduleKey.CoreModuleKey), moduleKey.Valid),
		EntityType:  entityType,
		EntityID:    entityID,
		Action:      action,
		BeforeValue: jsonValue(beforeValue),
		AfterValue:  jsonValue(afterValue),
		Severity:    severity,
		IPAddress:   ipAddress,
		UserAgent:   userAgent,
		RequestID:   requestID,
	}
}
