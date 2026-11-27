// repository.go — SATU-SATUNYA pengguna sqlc untuk area outbox
// (padanan OutboxRepository NestJS). Keputusan dedupe/tangkap 23505
// uq_outbox_topic_key_pending TETAP DI SERVICE.
package outbox

import (
	"context"

	"nexierp/internal/core/outbox/repository/gen"
)

// Repository — wrapper sqlc area outbox.
type Repository struct{}

// NewRepository membuat repository (tanpa state — executor per panggilan).
func NewRepository() *Repository { return &Repository{} }

// FindPendingDeliveredIdByTopicKey — dedupe pre-check: id baris hidup
// (pending/delivered) dengan (topic, `_key` di payload) sama — TERMASUK uji
// keberadaan `_key`; nil bila belum ada.
func (r *Repository) FindPendingDeliveredIdByTopicKey(ctx context.Context, exec DBTX, topic, key string) (*int64, error) {
	rows, err := gen.New(exec).FindPendingDeliveredIdByTopicKey(ctx, gen.FindPendingDeliveredIdByTopicKeyParams{
		Topic: topic,
		Kunci: key,
	})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	id := rows[0]
	return &id, nil
}

// FindLiveIdByTopicKey — re-select baris hidup (pending/delivered) saat race
// 23505 — varian TANPA uji keberadaan `_key` (VERBATIM repo NestJS).
func (r *Repository) FindLiveIdByTopicKey(ctx context.Context, exec DBTX, topic, key string) (*int64, error) {
	rows, err := gen.New(exec).FindLiveIdByTopicKey(ctx, gen.FindLiveIdByTopicKeyParams{
		Topic: topic,
		Kunci: key,
	})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	id := rows[0]
	return &id, nil
}

// InsertEvent — insert event berstatus 'pending', attempts 0 (nilai dibangun
// service), kembalikan id.
func (r *Repository) InsertEvent(ctx context.Context, exec DBTX, topic string, payload []byte) (int64, error) {
	id, err := gen.New(exec).InsertEvent(ctx, gen.InsertEventParams{
		Topic:    topic,
		Payload:  payload,
		Status:   gen.CoreOutboxStatusPending,
		Attempts: 0,
	})
	if err != nil {
		return 0, err
	}
	return id, nil
}

// PollPending — SELECT ... FOR UPDATE SKIP LOCKED; executor (tx) dibuka
// SERVICE (db.Tx) lalu diteruskan ke sini.
func (r *Repository) PollPending(ctx context.Context, exec DBTX, limit int) ([]gen.CoreOutboxEvent, error) {
	return gen.New(exec).PollPending(ctx, int32(limit))
}

// PollPendingByTopics — varian poll berdasarkan topik; topics kosong → []
// (tanpa query — VERBATIM early-return repo NestJS).
func (r *Repository) PollPendingByTopics(ctx context.Context, exec DBTX, topics []string, limit int) ([]gen.CoreOutboxEvent, error) {
	if len(topics) == 0 {
		return nil, nil
	}
	return gen.New(exec).PollPendingByTopics(ctx, gen.PollPendingByTopicsParams{
		Topics: topics,
		Limit:  int32(limit),
	})
}

// TandaiDelivered — tandai event SELESAI diproses konsumen (delivered +
// processed_at); last_error/attempts tidak disentuh.
func (r *Repository) TandaiDelivered(ctx context.Context, exec DBTX, id int64) error {
	return gen.New(exec).TandaiDelivered(ctx, id)
}
