// Package audit — audit trail pusat append-only ke `core_audit_trail`
// (persis AuditService NestJS). Aktor (`id_core_users`) dibangun CALLER dari
// JWT — TIDAK PERNAH dari payload client; ditulis di DALAM transaksi bisnis
// yang sama (executor DBTX) sehingga audit ikut commit/rollback.
// `moduleKey` (natural key core_modules) di-resolve ke FK numerik
// `id_core_modules` di executor yang sama dengan entri.
package audit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"

	"nexierp/internal/core/database"
)

// Service — kernel audit.
type Service struct {
	db   *database.DB
	repo *Repository

	mu    sync.Mutex
	cache map[string]int64 // moduleKey → id_core_modules (ResolveModuleID, aman-race)
}

// New membuat service audit.
func New(db *database.DB) *Service {
	return &Service{db: db, repo: NewRepository(), cache: make(map[string]int64)}
}

// Append menulis BANYAK entri audit — semua dalam executor yang sama (bila
// caller memberi Tx, satu batch dalam transaksi itu). Nilai insert dibangun
// PERSIS service NestJS: at = now, actorName fallback "system", severity
// fallback "info", ip fallback "", ua fallback "server", request_id fallback
// "req-" + 12 karakter hex (6 byte acak).
func (s *Service) Append(ctx context.Context, exec DBTX, entries []AppendInput) (AppendResult, error) {
	if len(entries) == 0 {
		return AppendResult{IDs: []int64{}}, nil
	}

	// Resolve natural key modul → id SEKALI untuk seluruh batch (satu
	// full-scan, bukan per entri).
	need := make(map[string]bool, len(entries))
	moduleKeys := make([]string, 0)
	for _, e := range entries {
		if e.IdCoreModules != nil || e.ModuleKey == "" || need[e.ModuleKey] {
			continue
		}
		need[e.ModuleKey] = true
		moduleKeys = append(moduleKeys, e.ModuleKey)
	}
	moduleIDByKey := make(map[string]int64, len(moduleKeys))
	if len(moduleKeys) > 0 {
		rows, err := s.repo.ScanModuleIdKeys(ctx, exec)
		if err != nil {
			return AppendResult{}, fmt.Errorf("audit: scan core_modules: %w", err)
		}
		for _, row := range rows {
			if need[row.Key] {
				moduleIDByKey[row.Key] = row.ID
			}
		}
	}

	ids := make([]int64, 0, len(entries))
	for _, e := range entries {
		var idModules *int64
		if e.IdCoreModules != nil {
			idModules = e.IdCoreModules
		} else if e.ModuleKey != "" {
			if id, ok := moduleIDByKey[e.ModuleKey]; ok {
				idModules = &id
			}
		}

		actorName := e.Actor.ActorName
		if actorName == "" {
			actorName = "system"
		}
		severity := e.Severity
		if severity == "" {
			severity = SeverityInfo
		}
		userAgent := e.Actor.UserAgent
		if userAgent == "" {
			userAgent = "server"
		}
		requestID := e.Actor.RequestID
		if requestID == "" {
			requestID = "req-" + randomHex12()
		}

		id, err := s.repo.InsertEntry(ctx, exec, InsertValues{
			At:            time.Now(),
			IdCoreUsers:   e.Actor.IDCoreUsers,
			ActorName:     actorName,
			IdCoreModules: idModules,
			EntityType:    e.EntityType,
			EntityID:      e.EntityID,
			Action:        e.Action,
			BeforeValue:   e.BeforeValue,
			AfterValue:    e.AfterValue,
			Severity:      severity,
			IPAddress:     e.Actor.IPAddress, // fallback "" (persis ?? "")
			UserAgent:     userAgent,
			RequestID:     requestID,
		})
		if err != nil {
			return AppendResult{}, fmt.Errorf("audit: insert core_audit_trail: %w", err)
		}
		ids = append(ids, id)
	}
	return AppendResult{IDs: ids}, nil
}

// AppendOne — entri tunggal, gula di atas Append untuk satu baris.
func (s *Service) AppendOne(ctx context.Context, exec DBTX, e AppendInput) (int64, error) {
	res, err := s.Append(ctx, exec, []AppendInput{e})
	if err != nil {
		return 0, err
	}
	return res.IDs[0], nil
}

// ResolveModuleID — cek keberadaan modul by key (util kecil untuk caller yang
// butuh id sebelum membangun entri): full-scan core_modules PERSIS
// scanModuleIdKeys, filter per-key di memori; hasil positif di-cache
// in-memory (aman-race). nil bila modul tidak terdaftar.
func (s *Service) ResolveModuleID(ctx context.Context, exec DBTX, moduleKey string) (*int64, error) {
	s.mu.Lock()
	id, ok := s.cache[moduleKey]
	s.mu.Unlock()
	if ok {
		return &id, nil
	}
	rows, err := s.repo.ScanModuleIdKeys(ctx, exec)
	if err != nil {
		return nil, fmt.Errorf("audit: scan core_modules: %w", err)
	}
	for _, row := range rows {
		if row.Key == moduleKey {
			s.mu.Lock()
			s.cache[moduleKey] = row.ID
			s.mu.Unlock()
			return &row.ID, nil
		}
	}
	return nil, nil
}

// randomHex12 — padanan randomBytes(6).toString("hex"): 12 karakter hex.
func randomHex12() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand praktis tak pernah gagal; fallback waktu tetap cukup unik
		now := uint64(time.Now().UnixNano())
		for i := 0; i < 6; i++ {
			b[i] = byte(now >> (i * 8))
		}
	}
	return hex.EncodeToString(b[:])
}
