// security_sessions.go — service SESI & LOG LOGIN (padanan
// services/security/sessions.service.ts): port fetchSessions, revokeSession,
// fetchLoginAudit. Service = orkestrasi: validasi urutan → SATU pgx tx
// (revoke: update + audit in-tx) → repo (baca non-transaksi untuk paging).
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// SessionsService — kernel fitur sesi & log login.
type SessionsService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.SessionsRepository
}

// NewSessionsService membuat service sesi.
func NewSessionsService(db *database.DB, auditSvc *audit.Service) *SessionsService {
	return &SessionsService{db: db, audit: auditSvc, repo: repository.NewSessionsRepository()}
}

// PageSessions — SATU HALAMAN sesi (paging server): `search` satu kata
// kunci lintas kolom (user, IP, user agent, device); sort di-whitelist,
// default login_at DESC + tie-break id deterministik (di repo).
func (s *SessionsService) PageSessions(ctx context.Context, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.SessionRow], error) {
	return s.repo.PageSessions(ctx, s.db.Pool, pr, search)
}

// RevokeSession — sesi tidak ada → 404 SYS-404; sisanya: update
// is_valid=false + revoked_at + audit `revoke` warning dalam SATU
// transaksi (JwtAuthGuard menolak sesi mati secara alami di request
// berikutnya — validasi server-side per request).
func (s *SessionsService) RevokeSession(ctx context.Context, sessionID int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.MuatSession(ctx, tx, sessionID)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Sesi %d tidak ditemukan.", sessionID), "SYS-404")
		}
		if err := s.repo.RevokeSession(ctx, tx, sessionID, time.Now()); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "session",
				EntityID:    fmt.Sprintf("%d", sessionID),
				Action:      "revoke",
				BeforeValue: audit.Snapshot{"is_valid": row.IsValid},
				AfterValue:  audit.Snapshot{"is_valid": false},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// PageLoginAudit — SATU HALAMAN log login: filter opsional `username` dan
// `success`, `search` lintas kolom (username/IP/user agent); default urut
// attempted_at DESC + tie-break id.
func (s *SessionsService) PageLoginAudit(ctx context.Context, pr *errkontrak.PageRequest, username string, success *bool, search string) (errkontrak.Page[types.LoginAuditEntry], error) {
	return s.repo.PageLoginAudit(ctx, s.db.Pool, pr, username, success, search)
}
