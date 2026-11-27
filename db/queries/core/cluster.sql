-- CLUSTER modul core — padanan ClusterRepository NestJS (konfigurasi Cluster
-- Modul CORE, ddl/55-core-cluster): master core_cluster (list/paging dengan
-- jumlahModul correlated subquery hidup, cari hidup, insert, patch
-- ber-version, soft delete TANPA bump), junction core_cluster_modules
-- (N:M cluster ↔ modul registry) dan core_cluster_features (detail
-- cluster-modul ↔ fitur) — REPLACE set hidup semantik revive/insert/soft-
-- delete (pola pos outlet metode bayar) + katalog global core_modules /
-- core_modules_features (validasi id sync & opsi UI assign).
-- Sort whitelist kanonik (sort_col '' = default urutan, id).

-- ===========================================================================
-- MASTER core_cluster
-- ===========================================================================

-- name: ListCluster :many
-- Daftar cluster hidup — search code/nama (ILIKE), filter status; jumlahModul
-- = count assignment hidup per cluster (subquery terkorelasi). Default urut
-- urutan, id.
SELECT cc.*,
  (SELECT count(*)::int FROM core_cluster_modules ccm
   WHERE ccm.id_core_cluster = cc.id AND ccm.deleted_at IS NULL) AS jumlah_modul
FROM core_cluster cc
WHERE cc.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR (cc.code ILIKE '%' || sqlc.narg('search') || '%'
           OR cc.nama ILIKE '%' || sqlc.narg('search') || '%'))
  AND (sqlc.narg('status')::text IS NULL OR cc.status::text = sqlc.narg('status'))
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN cc.urutan END ASC,
  CASE WHEN sqlc.arg('sort_col') = '' THEN cc.id END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'code' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.code
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.nama
    WHEN sqlc.arg('sort_col') = 'status' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.status::text
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'code' AND sqlc.arg('sort_desc')::boolean THEN cc.code
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN cc.nama
    WHEN sqlc.arg('sort_col') = 'status' AND sqlc.arg('sort_desc')::boolean THEN cc.status::text
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'urutan' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.urutan
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'urutan' AND sqlc.arg('sort_desc')::boolean THEN cc.urutan
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cc.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN cc.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN cc.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountCluster :one
-- Total cluster hidup (kriteria sama dengan ListCluster).
SELECT count(*)::int AS total
FROM core_cluster cc
WHERE cc.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR (cc.code ILIKE '%' || sqlc.narg('search') || '%'
           OR cc.nama ILIKE '%' || sqlc.narg('search') || '%'))
  AND (sqlc.narg('status')::text IS NULL OR cc.status::text = sqlc.narg('status'));

-- name: CariClusterHidup :many
-- Baris cluster hidup penuh — kosong = tidak ada / terhapus.
SELECT * FROM core_cluster
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: CariClusterHidupByKode :many
-- Id cluster hidup lain berkode sama — pre-check dup code (409 di service).
SELECT id FROM core_cluster
WHERE code = sqlc.arg('code') AND deleted_at IS NULL
LIMIT 1;

-- name: JumlahModulCluster :one
-- Count assignment modul hidup satu cluster.
SELECT count(*)::int AS total FROM core_cluster_modules
WHERE id_core_cluster = sqlc.arg('id_cluster')::bigint AND deleted_at IS NULL;

-- name: InsertCluster :one
-- Insert cluster baru (version 1 eksplisit; entity_id default
-- gen_random_uuid()); race uq_core_cluster_code_hidup (23505) mentah.
INSERT INTO core_cluster (code, nama, deskripsi, icon, tone, urutan, status, version)
VALUES (sqlc.arg('code'), sqlc.arg('nama'), sqlc.narg('deskripsi'), sqlc.narg('icon'),
        sqlc.narg('tone'), sqlc.arg('urutan'), sqlc.arg('status'), sqlc.arg('version'))
RETURNING *;

-- name: UpdateClusterBerVersion :many
-- Patch ber-version (optimistic lock) — kosong = version berubah di antara
-- baca & tulis (race — 409 SYS-409 di service).
UPDATE core_cluster SET
  code = sqlc.arg('code'),
  nama = sqlc.arg('nama'),
  deskripsi = sqlc.narg('deskripsi'),
  icon = sqlc.narg('icon'),
  tone = sqlc.narg('tone'),
  urutan = sqlc.arg('urutan'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteCluster :exec
-- Soft delete cluster (set deleted_at — JANGAN hard delete; TANPA version
-- bump — kontrak endpoint terkunci).
UPDATE core_cluster SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- ===========================================================================
-- KATALOG global core_modules / core_modules_features
-- ===========================================================================

-- name: ModulOptionsModul :many
-- SEMUA modul registry (urut key — urutan enum core_module_key, persis
-- drizzle asc(key)).
SELECT id, key, name, tagline, enabled
FROM core_modules
ORDER BY key ASC;

-- name: ModulOptionsFitur :many
-- Fitur AKTIF per modul (core_modules_features is_active = true — tabel
-- tanpa deleted_at), urut id.
SELECT id_core_modules, id, features_folder, description
FROM core_modules_features
WHERE is_active = true
ORDER BY id ASC;

-- name: IdModulDikenal :many
-- Id modul registry yang dikenal dari set — validasi syncModul (400 di service).
SELECT id FROM core_modules
WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- name: BarisFiturByIds :many
-- Baris katalog fitur by id (+ id_core_modules pemiliknya) — validasi
-- syncFitur (400 di service).
SELECT id, id_core_modules FROM core_modules_features
WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- ===========================================================================
-- JUNCTION core_cluster_modules (cluster ↔ modul)
-- ===========================================================================

-- name: CariClusterModulHidup :many
-- Baris cluster-modul hidup by id — kosong = tidak ada (parent sync fitur).
SELECT * FROM core_cluster_modules
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: BacaClusterModulCluster :many
-- SEMUA baris junction cluster (hidup + mati) — bahan revive/insert/delete.
SELECT id, id_core_modules, deleted_at FROM core_cluster_modules
WHERE id_core_cluster = sqlc.arg('id_cluster')::bigint;

-- name: ReviveClusterModul :execrows
-- (1) Revive pasangan soft-deleted yang masuk lagi dalam set.
UPDATE core_cluster_modules SET
  deleted_at = NULL,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_core_cluster = sqlc.arg('id_cluster')::bigint
  AND id_core_modules = ANY(sqlc.arg('ids')::bigint[]);

-- name: InsertClusterModul :execrows
-- (2) Insert pasangan yang belum pernah ada (race pair unique hidup →
-- DO NOTHING, persis onConflictDoNothing).
INSERT INTO core_cluster_modules (id_core_cluster, id_core_modules)
SELECT sqlc.arg('id_cluster')::bigint, x
FROM unnest(sqlc.arg('ids')::bigint[]) AS t(x)
ON CONFLICT DO NOTHING;

-- name: SoftDeleteClusterModul :execrows
-- (3) Soft delete pasangan hidup yang hilang dari set.
UPDATE core_cluster_modules SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_core_cluster = sqlc.arg('id_cluster')::bigint
  AND id_core_modules = ANY(sqlc.arg('ids')::bigint[]);

-- name: IdsModulAktif :many
-- Id modul assignment hidup cluster (urut) — payload audit sync_modul.
SELECT id_core_modules AS id FROM core_cluster_modules
WHERE id_core_cluster = sqlc.arg('id_cluster')::bigint AND deleted_at IS NULL
ORDER BY id_core_modules ASC;

-- ===========================================================================
-- JUNCTION core_cluster_features (cluster-modul ↔ fitur)
-- ===========================================================================

-- name: BacaClusterFiturBaris :many
-- SEMUA baris fitur satu cluster-modul (hidup + mati) — bahan sync.
SELECT id, id_core_modules_features, deleted_at FROM core_cluster_features
WHERE id_core_cluster_modules = sqlc.arg('id_modul_cluster')::bigint;

-- name: ReviveClusterFitur :execrows
-- (1) Revive fitur soft-deleted yang masuk lagi dalam set.
UPDATE core_cluster_features SET
  deleted_at = NULL,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_core_cluster_modules = sqlc.arg('id_modul_cluster')::bigint
  AND id_core_modules_features = ANY(sqlc.arg('ids')::bigint[]);

-- name: InsertClusterFitur :execrows
-- (2) Insert fitur yang belum pernah ada (race pair unique hidup → DO NOTHING).
INSERT INTO core_cluster_features (id_core_cluster_modules, id_core_modules_features)
SELECT sqlc.arg('id_modul_cluster')::bigint, x
FROM unnest(sqlc.arg('ids')::bigint[]) AS t(x)
ON CONFLICT DO NOTHING;

-- name: SoftDeleteClusterFitur :execrows
-- (3) Soft delete fitur hidup yang hilang dari set.
UPDATE core_cluster_features SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_core_cluster_modules = sqlc.arg('id_modul_cluster')::bigint
  AND id_core_modules_features = ANY(sqlc.arg('ids')::bigint[]);

-- name: IdsFiturAktif :many
-- Id fitur hidup satu baris cluster-modul (urut) — hasil sync fitur.
SELECT id_core_modules_features AS id FROM core_cluster_features
WHERE id_core_cluster_modules = sqlc.arg('id_modul_cluster')::bigint AND deleted_at IS NULL
ORDER BY id_core_modules_features ASC;

-- ===========================================================================
-- VIEW detail — modul assignment hidup + fiturIds per assignment
-- ===========================================================================

-- name: RowsModulCluster :many
-- Baris modul assignment hidup cluster (join core_modules, urut key).
SELECT ccm.id, ccm.id_core_modules, m.key, m.name, m.tagline, m.enabled
FROM core_cluster_modules ccm
INNER JOIN core_modules m ON m.id = ccm.id_core_modules
WHERE ccm.id_core_cluster = sqlc.arg('id_cluster')::bigint AND ccm.deleted_at IS NULL
ORDER BY m.key ASC;

-- name: RowsFiturUntukModul :many
-- Fitur hidup untuk BANYAK baris cluster-modul sekaligus (urut id fitur) —
-- dipetakan per idModul di repository.
SELECT id_core_cluster_modules, id_core_modules_features
FROM core_cluster_features
WHERE id_core_cluster_modules = ANY(sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL
ORDER BY id_core_modules_features ASC;
