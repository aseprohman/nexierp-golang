-- Query registry core_files (ddl/01c + ddl/44) — pemilik core/storage.
-- Baris HIDUP = deleted_at IS NULL (soft delete; object MinIO tak dihapus).

-- INSERT baris registry file (SELALU dalam tx upload dari service).
-- name: InsertFile :one
INSERT INTO core_files (
  entity_id, bucket, object_key, original_name, mime_type, size_bytes,
  checksum_sha256, scope, id_core_users, id_core_modules, id_core_media_categories
) VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
)
RETURNING *;

-- Daftar file HIDUP (paginasi manual, terbaru dulu) + nama pengunggah.
-- Filter opsional: scope, search (ILIKE nama), pemilik modul, kategori
-- (id_kategori = 0 → sentinel "tanpa kategori" — FK kategori NULL).
-- name: ListFiles :many
SELECT f.*, u.name AS uploader_name
FROM core_files f
LEFT JOIN core_users u ON u.id = f.id_core_users
WHERE f.deleted_at IS NULL
  AND (sqlc.narg('scope')::text IS NULL OR f.scope = sqlc.narg('scope'))
  AND (sqlc.narg('search')::text IS NULL OR f.original_name ILIKE '%' || sqlc.narg('search') || '%')
  AND (sqlc.narg('id_core_modules')::bigint IS NULL OR f.id_core_modules = sqlc.narg('id_core_modules'))
  AND (
    sqlc.narg('id_kategori')::bigint IS NULL
    OR (sqlc.narg('id_kategori')::bigint = 0 AND f.id_core_media_categories IS NULL)
    OR (sqlc.narg('id_kategori')::bigint > 0 AND f.id_core_media_categories = sqlc.narg('id_kategori'))
  )
ORDER BY f.created_at DESC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- Total baris HIDUP untuk filter ListFiles (paginasi).
-- name: CountFiles :one
SELECT count(*)::bigint AS total
FROM core_files f
WHERE f.deleted_at IS NULL
  AND (sqlc.narg('scope')::text IS NULL OR f.scope = sqlc.narg('scope'))
  AND (sqlc.narg('search')::text IS NULL OR f.original_name ILIKE '%' || sqlc.narg('search') || '%')
  AND (sqlc.narg('id_core_modules')::bigint IS NULL OR f.id_core_modules = sqlc.narg('id_core_modules'))
  AND (
    sqlc.narg('id_kategori')::bigint IS NULL
    OR (sqlc.narg('id_kategori')::bigint = 0 AND f.id_core_media_categories IS NULL)
    OR (sqlc.narg('id_kategori')::bigint > 0 AND f.id_core_media_categories = sqlc.narg('id_kategori'))
  );

-- View registry HIDUP by id numerik + nama pengunggah.
-- name: GetFileViewByID :one
SELECT f.*, u.name AS uploader_name
FROM core_files f
LEFT JOIN core_users u ON u.id = f.id_core_users
WHERE f.id = $1 AND f.deleted_at IS NULL
LIMIT 1;

-- View registry HIDUP by entity_id (uuid) + nama pengunggah.
-- name: GetFileViewByEntityID :one
SELECT f.*, u.name AS uploader_name
FROM core_files f
LEFT JOIN core_users u ON u.id = f.id_core_users
WHERE f.entity_id = $1 AND f.deleted_at IS NULL
LIMIT 1;

-- Baris mentah registry HIDUP by id (untuk sign/stream — object key).
-- name: GetFileRawByID :one
SELECT * FROM core_files
WHERE id = $1 AND deleted_at IS NULL
LIMIT 1;

-- Baris mentah registry HIDUP by entity_id (uuid).
-- name: GetFileRawByEntityID :one
SELECT * FROM core_files
WHERE entity_id = $1 AND deleted_at IS NULL
LIMIT 1;

-- Baris mentah registry HIDUP + kunci baris (FOR UPDATE — hapus).
-- name: GetFileRawForUpdateByID :one
SELECT * FROM core_files
WHERE id = $1 AND deleted_at IS NULL
LIMIT 1
FOR UPDATE;

-- Baris mentah registry HIDUP + kunci baris (FOR UPDATE) by entity_id.
-- name: GetFileRawForUpdateByEntityID :one
SELECT * FROM core_files
WHERE entity_id = $1 AND deleted_at IS NULL
LIMIT 1
FOR UPDATE;

-- SOFT DELETE (ddl/44) — deleted_at=now(), version+1; kembalikan version baru.
-- name: SoftDeleteFile :one
UPDATE core_files
SET deleted_at = now(), version = $2, updated_at = now()
WHERE id = $1
RETURNING version;

-- Lookup FK pemilik modul (ddl/44) — id core_modules ada?
-- name: ModuleIDExists :one
SELECT id FROM core_modules
WHERE id = $1
LIMIT 1;
