// Package outbox — transactional outbox (persis OutboxService NestJS):
// event integrasi ditulis di transaksi bisnis yang sama (outbox pattern);
// poll worker memakai FOR UPDATE SKIP LOCKED dalam transaksi sendiri agar
// aman dipanggil bersamaan dari banyak worker (lock lepas saat commit).
package outbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/database"
	"nexierp/internal/core/outbox/repository/gen"
)

// DBTX — executor (pool | tx) agar enqueue masuk transaksi bisnis pemanggil.
type DBTX = gen.DBTX

// EventRow — baris event outbox hasil poll (cermin kolom core_outbox_events).
type EventRow struct {
	ID          int64
	Topic       string
	Payload     map[string]any
	Status      string
	AvailableAt time.Time
	Attempts    int
	LastError   *string
	CreatedAt   time.Time
	ProcessedAt *time.Time
	UpdatedAt   time.Time
}

// EventInput — masukan event baru. `Key` (bila diberikan) disimpan di payload
// `_key` — dasar dedupe G-29; kombinasi (topic, key) yang masih
// pending/delivered tidak di-emit ulang.
type EventInput struct {
	Topic   string
	Key     *string
	Payload map[string]any
}

// constraintUniqueTopicKeyPending — unique parsial (ddl/26-outbox-idempoten):
// maks satu baris hidup per (topic, key). Baris 'failed' tidak diliput.
const constraintUniqueTopicKeyPending = "uq_outbox_topic_key_pending"

// Service — kernel outbox.
type Service struct {
	db   *database.DB
	repo *Repository
}

// New membuat service outbox.
func New(db *database.DB) *Service {
	return &Service{db: db, repo: NewRepository()}
}

// Enqueue menulis event status 'pending', attempts 0, available_at default
// kolom — idempoten G-29 lapis app: bila `key` diberikan dan sudah ada baris
// hidup (pending/delivered) dengan (topic, key) sama — mis. retry sesi
// DITAHAN — insert di-skip dan id baris lama dikembalikan (dedupe). Jaminan
// keras ada di DB (unique parsial); pelanggaran oleh race antar-transaksi
// ditangkap di bawah dan tetap mengembalikan id baris lama.
func (s *Service) Enqueue(ctx context.Context, exec DBTX, in EventInput) (int64, error) {
	payload := in.Payload
	if in.Key != nil {
		// merge payload["_key"] — persis `{ ...payload, _key: key }` NestJS
		// (payload asli caller tidak dimutasi).
		merged := make(map[string]any, len(in.Payload)+1)
		for k, v := range in.Payload {
			merged[k] = v
		}
		merged["_key"] = *in.Key
		payload = merged
	}

	if in.Key != nil {
		dup, err := s.repo.FindPendingDeliveredIdByTopicKey(ctx, exec, in.Topic, *in.Key)
		if err != nil {
			return 0, fmt.Errorf("outbox: dedupe pre-check: %w", err)
		}
		if dup != nil {
			return *dup, nil
		}
	}

	raw, err := json.Marshal(payload)
	if err != nil {
		return 0, fmt.Errorf("outbox: marshal payload: %w", err)
	}
	id, err := s.repo.InsertEvent(ctx, exec, in.Topic, raw)
	if err != nil {
		// Race dedupe: tx lain menginsert (topic, key) sama di antara
		// pre-check dan insert — kembalikan id baris lama, bukan error.
		if in.Key != nil && isUniqueViolationOnConstraint(err, constraintUniqueTopicKeyPending) {
			dup, ferr := s.repo.FindLiveIdByTopicKey(ctx, exec, in.Topic, *in.Key)
			if ferr == nil && dup != nil {
				return *dup, nil
			}
		}
		return 0, fmt.Errorf("outbox: insert event: %w", err)
	}
	return id, nil
}

// PollPending mengambil event pending yang sudah jatuh tempo
// (available_at <= now), urut created_at, MAKS `limit` — FOR UPDATE SKIP
// LOCKED di dalam transaksi sendiri supaya aman dipanggil bersamaan dari
// banyak worker. Lock lepas saat commit; pemroses menandai via
// TandaiDelivered di tx-nya sendiri.
func (s *Service) PollPending(ctx context.Context, limit int) ([]EventRow, error) {
	var rows []EventRow
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		r, err := s.repo.PollPending(ctx, tx, limit)
		if err != nil {
			return err
		}
		rows, err = toEventRows(r)
		return err
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// PollPendingByTopics — poll BERDASARKAN TOPIK (read-only; pemroses menandai
// via TandaiDelivered). Topics kosong → []. Sama dengan PollPending + filter
// topic = ANY(...); FOR UPDATE SKIP LOCKED dalam transaksi sendiri.
func (s *Service) PollPendingByTopics(ctx context.Context, topics []string, limit int) ([]EventRow, error) {
	var rows []EventRow
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		r, err := s.repo.PollPendingByTopics(ctx, tx, topics, limit)
		if err != nil {
			return err
		}
		rows, err = toEventRows(r)
		return err
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// TandaiDelivered menandai event id SELESAI diproses konsumen (status
// delivered) — read-side; tx sendiri.
func (s *Service) TandaiDelivered(ctx context.Context, id int64) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		return s.repo.TandaiDelivered(ctx, tx, id)
	})
}

// toEventRows memetakan baris sqlc (CoreOutboxEvent) → EventRow (payload
// jsonb di-parse; angka menjadi float64 persis semantik JSON).
func toEventRows(rows []gen.CoreOutboxEvent) ([]EventRow, error) {
	out := make([]EventRow, len(rows))
	for i, row := range rows {
		payload, err := unmarshalPayload(row.ID, row.Payload)
		if err != nil {
			return nil, err
		}
		out[i] = EventRow{
			ID:          row.ID,
			Topic:       row.Topic,
			Payload:     payload,
			Status:      string(row.Status),
			AvailableAt: row.AvailableAt.Time,
			Attempts:    int(row.Attempts),
			LastError:   textPtr(row.LastError),
			CreatedAt:   row.CreatedAt.Time,
			ProcessedAt: timestamptzPtr(row.ProcessedAt),
			UpdatedAt:   row.UpdatedAt.Time,
		}
	}
	return out, nil
}

// unmarshalPayload — jsonb payload → map; kosong → map kosong.
func unmarshalPayload(id int64, raw []byte) (map[string]any, error) {
	payload := map[string]any{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &payload); err != nil {
			return nil, fmt.Errorf("outbox: unmarshal payload event %d: %w", id, err)
		}
	}
	return payload, nil
}

// isUniqueViolationOnConstraint — 23505 pada constraint tertentu.
func isUniqueViolationOnConstraint(err error, constraint string) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "23505" && pe.ConstraintName == constraint
	}
	return false
}

// textPtr — pgtype.Text → *string (invalid → nil).
func textPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

// timestamptzPtr — pgtype.Timestamptz → *time.Time (invalid → nil).
func timestamptzPtr(t pgtype.Timestamptz) *time.Time {
	if !t.Valid {
		return nil
	}
	tm := t.Time
	return &tm
}
