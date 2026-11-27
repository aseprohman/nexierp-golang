// Service Overview (Sheet "Overview") fitur RBAC modul core — port VERBATIM
// services/rbac/overview.service.ts NestJS: statistik kesehatan akses
// (+ registry IAM v2: routes & permissions) dan N audit trail terbaru
// (read-only sederhana; audit-trail penuh milik modul security).
package service

import (
	"context"
	"time"

	"nexierp/internal/core/database"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// OverviewService — delegasi baca non-transaksi.
type OverviewService struct {
	db   *database.DB
	repo *repository.OverviewRepo
}

// NewOverviewService membangun service overview dari deps modul.
func NewOverviewService(d types.Deps) *OverviewService {
	return &OverviewService{db: d.DB, repo: repository.NewOverviewRepo()}
}

// Stats — statistik kesehatan akses (port fetchOverviewStats): 8 agregat
// paralel; audit hari ini sejak midnight LOKAL server (setHours(0,0,0,0)).
func (s *OverviewService) Stats(ctx context.Context) (types.OverviewStats, error) {
	now := time.Now()
	y, m, d := now.Date()
	dayStart := time.Date(y, m, d, 0, 0, 0, 0, now.Location())
	return s.repo.Stats(ctx, s.db.Pool, now, dayStart)
}

// RecentAudit — N audit trail terbaru (port fetchRecentAudit); limit
// di-clamp 1..100 (persis Math.min(Math.max(limit, 1), 100)).
func (s *OverviewService) RecentAudit(ctx context.Context, limit int) ([]types.AuditTrailEntry, error) {
	if limit < 1 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}
	rows, err := s.repo.RecentAudit(ctx, s.db.Pool, int32(limit))
	if err != nil {
		return nil, err
	}
	if rows == nil {
		rows = []types.AuditTrailEntry{}
	}
	return rows, nil
}
