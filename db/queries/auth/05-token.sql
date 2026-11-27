-- Query auth: core_auth_tokens (token aktivasi one-time, ddl/81) +
-- core_password_history (ganti password).
-- jenis selalu 'AKTIVASI' di area auth — hardcode literal agar param Go
-- tetap string; token_hash = SHA-256 hex dari token mentah.

-- name: InsertAuthToken :one
INSERT INTO core_auth_tokens (entity_id, id_core_users, jenis, token_hash, berlaku_hingga)
VALUES ($1, $2, 'AKTIVASI', $3, $4)
RETURNING id;

-- name: CariAuthTokenByHash :one
SELECT id, id_core_users, dipakai_at, berlaku_hingga
FROM core_auth_tokens
WHERE token_hash = $1 AND jenis = 'AKTIVASI' AND deleted_at IS NULL
LIMIT 1;

-- name: TandaiTokenDipakai :exec
UPDATE core_auth_tokens
SET dipakai_at = $1, updated_at = $1
WHERE id = $2;

-- name: CabutTokenAktivasiBelumPakai :exec
UPDATE core_auth_tokens
SET deleted_at = $1, updated_at = $1
WHERE id_core_users = $2 AND jenis = 'AKTIVASI'
  AND dipakai_at IS NULL AND deleted_at IS NULL;

-- name: HapusTokenKedaluwarsa :many
DELETE FROM core_auth_tokens
WHERE berlaku_hingga < $1
RETURNING id;

-- name: InsertPasswordHistory :exec
INSERT INTO core_password_history (id_core_users, user_name, set_at, masked_hash)
VALUES ($1, $2, $3, $4);
