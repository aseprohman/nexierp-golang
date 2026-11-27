// repository.go — SATU-SATUNYA pengguna sqlc untuk area audit
// (padanan AuditRepository NestJS). Nilai insert DIBANGUN di service;
// repository hanya menulis/baca via executor (pool | tx) pertama.
package audit

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit/repository/gen"
)

// DBTX — executor (pool | tx) agar append masuk transaksi bisnis pemanggil.
type DBTX = gen.DBTX

// Repository — wrapper sqlc area audit.
type Repository struct{}

// NewRepository membuat repository (tanpa state — executor per panggilan).
func NewRepository() *Repository { return &Repository{} }

// ModuleKeyRow — satu baris full-scan core_modules (id + key).
type ModuleKeyRow struct {
	ID  int64
	Key string
}

// ScanModuleIdKeys — full-scan core_modules (VERBATIM scanModuleIdKeys:
// tanpa WHERE; filter per-key dilakukan service di memori).
func (r *Repository) ScanModuleIdKeys(ctx context.Context, exec DBTX) ([]ModuleKeyRow, error) {
	rows, err := gen.New(exec).ScanModuleIdKeys(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]ModuleKeyRow, len(rows))
	for i, row := range rows {
		out[i] = ModuleKeyRow{ID: row.ID, Key: string(row.Key)}
	}
	return out, nil
}

// InsertValues — satu baris insert core_audit_trail (dibangun service).
type InsertValues struct {
	At            time.Time
	IdCoreUsers   *int64
	ActorName     string
	IdCoreModules *int64
	EntityType    string
	EntityID      string
	Action        string
	BeforeValue   Snapshot // nil → NULL
	AfterValue    Snapshot // nil → NULL
	Severity      Severity
	IPAddress     string
	UserAgent     string
	RequestID     string
}

// InsertEntry — insert satu baris core_audit_trail, kembalikan id baris baru.
// Batch banyak entri = loop panggilan ini dalam executor (tx) yang sama.
func (r *Repository) InsertEntry(ctx context.Context, exec DBTX, v InsertValues) (int64, error) {
	before, err := marshalSnapshot(v.BeforeValue)
	if err != nil {
		return 0, err
	}
	after, err := marshalSnapshot(v.AfterValue)
	if err != nil {
		return 0, err
	}
	id, err := gen.New(exec).InsertEntry(ctx, gen.InsertEntryParams{
		At:            pgtype.Timestamptz{Time: v.At, Valid: true},
		IDCoreUsers:   int8Ptr(v.IdCoreUsers),
		ActorName:     v.ActorName,
		IDCoreModules: int8Ptr(v.IdCoreModules),
		EntityType:    v.EntityType,
		EntityID:      v.EntityID,
		Action:        v.Action,
		BeforeValue:   before,
		AfterValue:    after,
		Severity:      gen.CoreAuditSeverity(v.Severity),
		IpAddress:     v.IPAddress,
		UserAgent:     v.UserAgent,
		RequestID:     v.RequestID,
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// marshalSnapshot — jsonb Snapshot → bytes; nil → NULL (bytes nil).
func marshalSnapshot(s Snapshot) ([]byte, error) {
	if s == nil {
		return nil, nil
	}
	return json.Marshal(s)
}

// int8Ptr — *int64 → pgtype.Int8 (nil → NULL).
func int8Ptr(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}
