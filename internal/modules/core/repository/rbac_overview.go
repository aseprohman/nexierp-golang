// Fitur OVERVIEW modul core — agregat hitung atas core_users, core_user_mfa,
// core_sessions, core_login_audit, core_roles, core_routes, core_permissions,
// core_audit_trail + N audit terbaru (port VERBATIM
// repositories/rbac/overview.repository.ts NestJS; 8 agregat dijalankan
// PARALEL persis Promise.all; mapper toAuditTrailView dari repo
// security/audit-trail).
package repository

import (
	"context"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// OverviewRepo — pembungkus query sqlc fitur overview.
type OverviewRepo struct{}

// NewOverviewRepo membuat repo (tanpa state — executor per panggilan).
func NewOverviewRepo() *OverviewRepo { return &OverviewRepo{} }

// Stats — statistik kesehatan akses (8 agregat paralel persis Promise.all):
// total/aktif/terkunci, MFA aktif, sesi valid, login gagal 24 jam rolling,
// jumlah role, jumlah route, SET permission aktif, audit sejak midnight
// LOKAL server.
func (r *OverviewRepo) Stats(ctx context.Context, exec gen.DBTX, now, dayStart time.Time) (types.OverviewStats, error) {
	nowArg := pgtype.Timestamptz{Time: now, Valid: true}

	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		firstErr error
		userAgg  gen.OverviewUserAggRow
		mfaN     int64
		sesiN    int64
		gagalN   int64
		roleN    int64
		routeN   int64
		permN    int64
		auditN   int64
	)
	fatal := func(err error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
	}
	run := func(fn func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(); err != nil {
				fatal(err)
			}
		}()
	}

	q := gen.New(exec)
	run(func() error { // users total/aktif/locked
		row, err := q.OverviewUserAgg(ctx, nowArg)
		userAgg = row
		return err
	})
	run(func() error { // MFA aktif
		v, err := q.CountMfaEnabled(ctx)
		mfaN = v
		return err
	})
	run(func() error { // sesi valid belum kadaluarsa & belum di-revoke
		v, err := q.CountActiveSessions(ctx, nowArg)
		sesiN = v
		return err
	})
	run(func() error { // login gagal 24 jam rolling
		v, err := q.CountFailedLogins24h(ctx, pgtype.Timestamptz{Time: now.Add(-24 * time.Hour), Valid: true})
		gagalN = v
		return err
	})
	run(func() error {
		v, err := q.CountRoles(ctx)
		roleN = v
		return err
	})
	run(func() error {
		v, err := q.CountRoutes(ctx)
		routeN = v
		return err
	})
	run(func() error { // "permissions" = jumlah SET aktif
		v, err := q.CountPermissionsActive(ctx)
		permN = v
		return err
	})
	run(func() error { // audit sejak awal hari (midnight lokal server)
		v, err := q.CountAuditSince(ctx, pgtype.Timestamptz{Time: dayStart, Valid: true})
		auditN = v
		return err
	})
	wg.Wait()
	if firstErr != nil {
		return types.OverviewStats{}, firstErr
	}

	return types.OverviewStats{
		TotalUsers:      userAgg.Total,
		ActiveUsers:     userAgg.Active,
		LockedUsers:     userAgg.Locked,
		MfaUsers:        mfaN,
		ActiveSessions:  sesiN,
		FailedLogins24h: gagalN,
		Roles:           roleN,
		Routes:          routeN,
		Permissions:     permN,
		AuditToday:      auditN,
	}, nil
}

// RecentAudit — N audit trail terbaru (at DESC, id DESC); moduleKey di-
// resolve dari FK (LEFT JOIN core_modules) dan dipetakan toAuditTrailView.
// Limit di-clamp caller (1..100).
func (r *OverviewRepo) RecentAudit(ctx context.Context, exec gen.DBTX, limit int32) ([]types.AuditTrailEntry, error) {
	rows, err := gen.New(exec).RecentAudit(ctx, limit)
	if err != nil {
		return nil, err
	}
	out := make([]types.AuditTrailEntry, len(rows))
	for i, row := range rows {
		var moduleKey *string
		if row.ModuleKey.Valid {
			k := string(row.ModuleKey.CoreModuleKey)
			moduleKey = &k
		}
		var actorUserID *int64
		if row.IDCoreUsers.Valid {
			id := row.IDCoreUsers.Int64
			actorUserID = &id
		}
		var before, after any
		if len(row.BeforeValue) > 0 {
			before = jsonValue(row.BeforeValue)
		}
		if len(row.AfterValue) > 0 {
			after = jsonValue(row.AfterValue)
		}
		out[i] = types.AuditTrailEntry{
			ID:          row.ID,
			At:          IsoRequired(row.At),
			ActorUserID: actorUserID,
			ActorName:   row.ActorName,
			ModuleKey:   moduleKey,
			EntityType:  row.EntityType,
			EntityID:    row.EntityID,
			Action:      row.Action,
			BeforeValue: before,
			AfterValue:  after,
			Severity:    string(row.Severity),
			IPAddress:   row.IpAddress,
			UserAgent:   row.UserAgent,
			RequestID:   row.RequestID,
		}
	}
	return out, nil
}
