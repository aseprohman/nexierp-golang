-- AGAMA modul core — padanan AgamaRepository NestJS (kosakata agama resmi,
-- ddl/72-core-agama): master core_agama — pola persis cluster minus junction
-- (list/paging, cari hidup, cari hidup by code, insert, patch ber-version,
-- soft delete TANPA bump). Sort whitelist kanonik (sort_col '' = default
-- urutan, id — uratan dropdown FE).

-- name: ListAgama :many
-- Daftar agama hidup — search code/nama (ILIKE), filter status. Default urut
-- urutan, id.
SELECT ag.*
FROM core_agama ag
WHERE ag.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR (ag.code ILIKE '%' || sqlc.narg('search') || '%'
           OR ag.nama ILIKE '%' || sqlc.narg('search') || '%'))
  AND (sqlc.narg('status')::text IS NULL OR ag.status::text = sqlc.narg('status'))
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN ag.urutan END ASC,
  CASE WHEN sqlc.arg('sort_col') = '' THEN ag.id END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'code' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.code
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.nama
    WHEN sqlc.arg('sort_col') = 'status' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.status::text
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'code' AND sqlc.arg('sort_desc')::boolean THEN ag.code
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN ag.nama
    WHEN sqlc.arg('sort_col') = 'status' AND sqlc.arg('sort_desc')::boolean THEN ag.status::text
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'urutan' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.urutan
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'urutan' AND sqlc.arg('sort_desc')::boolean THEN ag.urutan
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ag.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN ag.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN ag.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountAgama :one
-- Total agama hidup (kriteria sama dengan ListAgama).
SELECT count(*)::int AS total
FROM core_agama ag
WHERE ag.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR (ag.code ILIKE '%' || sqlc.narg('search') || '%'
           OR ag.nama ILIKE '%' || sqlc.narg('search') || '%'))
  AND (sqlc.narg('status')::text IS NULL OR ag.status::text = sqlc.narg('status'));

-- name: CariAgamaHidup :many
-- Baris agama hidup penuh — kosong = tidak ada / terhapus.
SELECT * FROM core_agama
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: CariAgamaHidupByKode :many
-- Id agama hidup lain berkode sama — pre-check dup code (409 di service).
SELECT id FROM core_agama
WHERE code = sqlc.arg('code') AND deleted_at IS NULL
LIMIT 1;

-- name: InsertAgama :one
-- Insert agama baru (version 1 eksplisit; entity_id default
-- gen_random_uuid()); race uq_core_agama_code_hidup (23505) mentah.
INSERT INTO core_agama (code, nama, urutan, status, version)
VALUES (sqlc.arg('code'), sqlc.arg('nama'), sqlc.arg('urutan'), sqlc.arg('status'), sqlc.arg('version'))
RETURNING *;

-- name: UpdateAgamaBerVersion :many
-- Patch ber-version (optimistic lock) — kosong = version berubah di antara
-- baca & tulis (race — 409 SYS-409 di service).
UPDATE core_agama SET
  code = sqlc.arg('code'),
  nama = sqlc.arg('nama'),
  urutan = sqlc.arg('urutan'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteAgama :exec
-- Soft delete agama (set deleted_at — JANGAN hard delete; TANPA version
-- bump). FK RESTRICT dari ppdb_pendaftaran/akd_siswa (23503) dilempar
-- mentah — dipetakan 409 SYS-409 di service.
UPDATE core_agama SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;
