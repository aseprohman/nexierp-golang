-- Query core_mail_log (ddl/81 — [LOG/EVENT] append-only, pemilik core/mailer).
-- Hanya INSERT + SELECT riwayat — TANPA update/delete (aturan LOG/EVENT).

-- INSERT baris jejak kirim (sukses maupun gagal/nonaktif) — tiap panggilan
-- Kirim = SATU baris. created_at/updated_at default now().
-- name: InsertMailLog :one
INSERT INTO core_mail_log (
  entity_id, id_core_users, penerima, penerima_nama, subjek, jenis,
  status, pesan_error, provider_message_id
) VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9
)
RETURNING *;

-- Riwayat kirim terbaru per alamat penerima (observabilitas/dev).
-- name: ListMailLogByPenerima :many
SELECT *
FROM core_mail_log
WHERE penerima = $1
ORDER BY created_at DESC
LIMIT $2;
