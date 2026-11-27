-- Transactional outbox — padanan OutboxRepository NestJS (kernel outbox).
-- Keputusan dedupe/tangkap 23505 TETAP DI SERVICE.

-- name: FindPendingDeliveredIdByTopicKey :many
-- Dedupe pre-check — id baris hidup (pending/delivered) dengan
-- (topic, `_key` di payload) sama; kosong bila belum ada.
-- jsonb_exists(payload,'_key') = operator `payload ? '_key'` (bentuk fungsi
-- agar aman diparse sqlc; semantik Postgres identik).
SELECT id
FROM core_outbox_events
WHERE topic = @topic
  AND jsonb_exists(payload, '_key')
  AND payload->>'_key' = @kunci::text
  AND status IN ('pending', 'delivered')
LIMIT 1;

-- name: FindLiveIdByTopicKey :many
-- Re-select baris hidup (pending/delivered) saat race 23505 — varian TANPA
-- uji keberadaan `_key` (VERBATIM dari repo NestJS).
SELECT id
FROM core_outbox_events
WHERE topic = @topic
  AND payload->>'_key' = @kunci::text
  AND status IN ('pending', 'delivered')
LIMIT 1;

-- name: InsertEvent :one
-- Insert event berstatus 'pending' (nilai dibangun service), kembalikan id.
INSERT INTO core_outbox_events (topic, payload, status, attempts)
VALUES ($1, $2, $3, $4)
RETURNING id;

-- name: PollPending :many
-- Ambil event pending yang sudah jatuh tempo (available_at <= now), urut
-- created_at, MAKS `limit` — FOR UPDATE SKIP LOCKED agar aman dipanggil
-- bersamaan dari banyak worker. Lock lepas saat tx commit.
SELECT id, topic, payload, status, available_at, attempts, last_error,
       created_at, processed_at, updated_at
FROM core_outbox_events
WHERE status = 'pending'
  AND available_at <= now()
ORDER BY created_at ASC
FOR UPDATE SKIP LOCKED
LIMIT $1;

-- name: PollPendingByTopics :many
-- Varian poll BERDASARKAN TOPIK — sama dengan PollPending + filter
-- topic = ANY(...). Topics kosong dicek di repository (return []).
SELECT id, topic, payload, status, available_at, attempts, last_error,
       created_at, processed_at, updated_at
FROM core_outbox_events
WHERE status = 'pending'
  AND topic = ANY(@topics::text[])
  AND available_at <= now()
ORDER BY created_at ASC
FOR UPDATE SKIP LOCKED
LIMIT $1;

-- name: TandaiDelivered :exec
-- Tandai event SELESAI diproses konsumen (delivered + processed_at) —
-- read-side saja; last_error/attempts tidak disentuh.
UPDATE core_outbox_events
SET status = 'delivered',
    processed_at = now(),
    updated_at = now()
WHERE id = $1;
