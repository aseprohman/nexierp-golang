-- WILAYAH + WILAYAH ADMIN modul core — padanan WilayahRepository +
-- WilayahAdminRepository NestJS (lookup referensi wilayah Indonesia 4 level
-- MASTER core_provinsi → core_kota → core_kecamatan → core_kelurahan,
-- ddl/42-core-wilayah). Disiplin: soft-delete deleted_at IS NULL di SEMUA
-- query; nama induk LEFT JOIN coalesce ''; sort via whitelist kolom
-- kanonik (sort_col '' = default urutan level itu — nama ASC); search ILIKE
-- %q% nama. Race uq_*_kode_hidup (23505) dilempar mentah — dipetakan service.

-- ===========================================================================
-- LOOKUP (READ-ONLY) — provinsi
-- ===========================================================================

-- name: ListProvinsi :many
-- List provinsi hidup — filter search nama; default urut nama (sort_col '').
SELECT id, kode, nama, version
FROM core_provinsi
WHERE deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL OR nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN nama END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN nama
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN nama
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountProvinsi :one
-- Total provinsi hidup (kriteria sama dengan ListProvinsi).
SELECT count(*)::int AS total
FROM core_provinsi
WHERE deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL OR nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatProvinsiByID :many
-- Satu provinsi hidup — kosong = tidak ditemukan / ter-soft-delete.
SELECT id, kode, nama, version
FROM core_provinsi
WHERE deleted_at IS NULL AND id = sqlc.arg('id')::bigint
LIMIT 1;

-- ===========================================================================
-- LOOKUP — kota/kabupaten (wajib konteks provinsi; LEFT JOIN nama provinsi)
-- ===========================================================================

-- name: ListKota :many
-- List kota hidup satu provinsi — filter jenis opsional + search nama.
SELECT ck.id, ck.kode, ck.nama, ck.jenis, ck.id_core_provinsi,
       coalesce(cp.nama, '') AS provinsi_nama, ck.version
FROM core_kota ck
LEFT JOIN core_provinsi cp ON cp.id = ck.id_core_provinsi
WHERE ck.deleted_at IS NULL
  AND ck.id_core_provinsi = sqlc.arg('id_provinsi')::bigint
  AND (sqlc.narg('jenis')::text IS NULL OR ck.jenis = sqlc.narg('jenis'))
  AND (sqlc.narg('search')::text IS NULL OR ck.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN ck.nama END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN ck.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN ck.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN ck.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN ck.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKota :one
-- Total kota hidup satu provinsi (kriteria sama dengan ListKota).
SELECT count(*)::int AS total
FROM core_kota ck
LEFT JOIN core_provinsi cp ON cp.id = ck.id_core_provinsi
WHERE ck.deleted_at IS NULL
  AND ck.id_core_provinsi = sqlc.arg('id_provinsi')::bigint
  AND (sqlc.narg('jenis')::text IS NULL OR ck.jenis = sqlc.narg('jenis'))
  AND (sqlc.narg('search')::text IS NULL OR ck.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatKotaByID :many
-- Satu kota hidup + nama provinsi — kosong = tidak ditemukan.
SELECT ck.id, ck.kode, ck.nama, ck.jenis, ck.id_core_provinsi,
       coalesce(cp.nama, '') AS provinsi_nama, ck.version
FROM core_kota ck
LEFT JOIN core_provinsi cp ON cp.id = ck.id_core_provinsi
WHERE ck.deleted_at IS NULL AND ck.id = sqlc.arg('id')::bigint
LIMIT 1;

-- ===========================================================================
-- LOOKUP — kecamatan (wajib konteks kota; LEFT JOIN nama kota)
-- ===========================================================================

-- name: ListKecamatan :many
-- List kecamatan hidup satu kota — search nama.
SELECT ck.id, ck.kode, ck.nama, ck.id_core_kota,
       coalesce(cj.nama, '') AS kota_nama, ck.version
FROM core_kecamatan ck
LEFT JOIN core_kota cj ON cj.id = ck.id_core_kota
WHERE ck.deleted_at IS NULL
  AND ck.id_core_kota = sqlc.arg('id_kota')::bigint
  AND (sqlc.narg('search')::text IS NULL OR ck.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN ck.nama END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN ck.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN ck.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN ck.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN ck.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN ck.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKecamatan :one
-- Total kecamatan hidup satu kota (kriteria sama dengan ListKecamatan).
SELECT count(*)::int AS total
FROM core_kecamatan ck
LEFT JOIN core_kota cj ON cj.id = ck.id_core_kota
WHERE ck.deleted_at IS NULL
  AND ck.id_core_kota = sqlc.arg('id_kota')::bigint
  AND (sqlc.narg('search')::text IS NULL OR ck.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatKecamatanByID :many
-- Satu kecamatan hidup + nama kota — kosong = tidak ditemukan.
SELECT ck.id, ck.kode, ck.nama, ck.id_core_kota,
       coalesce(cj.nama, '') AS kota_nama, ck.version
FROM core_kecamatan ck
LEFT JOIN core_kota cj ON cj.id = ck.id_core_kota
WHERE ck.deleted_at IS NULL AND ck.id = sqlc.arg('id')::bigint
LIMIT 1;

-- ===========================================================================
-- LOOKUP — kelurahan/desa (wajib konteks kecamatan; kode pos opsional persis)
-- ===========================================================================

-- name: ListKelurahan :many
-- List kelurahan hidup satu kecamatan — filter kodePos PERSIS + search nama.
SELECT cl.id, cl.kode, cl.nama, cl.kode_pos, cl.id_core_kecamatan,
       coalesce(cc.nama, '') AS kecamatan_nama, cl.version
FROM core_kelurahan cl
LEFT JOIN core_kecamatan cc ON cc.id = cl.id_core_kecamatan
WHERE cl.deleted_at IS NULL
  AND cl.id_core_kecamatan = sqlc.arg('id_kecamatan')::bigint
  AND (sqlc.narg('kode_pos')::text IS NULL OR cl.kode_pos = sqlc.narg('kode_pos'))
  AND (sqlc.narg('search')::text IS NULL OR cl.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN cl.nama END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN cl.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN cl.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN cl.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN cl.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKelurahan :one
-- Total kelurahan hidup satu kecamatan (kriteria sama dengan ListKelurahan).
SELECT count(*)::int AS total
FROM core_kelurahan cl
LEFT JOIN core_kecamatan cc ON cc.id = cl.id_core_kecamatan
WHERE cl.deleted_at IS NULL
  AND cl.id_core_kecamatan = sqlc.arg('id_kecamatan')::bigint
  AND (sqlc.narg('kode_pos')::text IS NULL OR cl.kode_pos = sqlc.narg('kode_pos'))
  AND (sqlc.narg('search')::text IS NULL OR cl.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatKelurahanLengkap :many
-- Satu kelurahan hidup + RANTAI LENGKAP (kecamatan/kota/provinsi — nama &
-- kode, coalesce '') — bahan alamat member & payload ongkir SHP (M55).
SELECT cl.id, cl.kode, cl.nama, cl.kode_pos, cl.id_core_kecamatan,
       coalesce(cc.nama, '') AS kecamatan_nama, cl.version,
       coalesce(cc.kode, '') AS kode_kecamatan,
       coalesce(cj.nama, '') AS kota_nama,
       coalesce(cj.kode, '') AS kode_kota,
       coalesce(cp.nama, '') AS provinsi_nama,
       coalesce(cp.kode, '') AS kode_provinsi
FROM core_kelurahan cl
LEFT JOIN core_kecamatan cc ON cc.id = cl.id_core_kecamatan
LEFT JOIN core_kota cj ON cj.id = cc.id_core_kota
LEFT JOIN core_provinsi cp ON cp.id = cj.id_core_provinsi
WHERE cl.deleted_at IS NULL AND cl.id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: ListKodePos :many
-- Daftar kelurahan ber-kode pos PERSIS (paged ringkas) + nama kecamatan.
SELECT cl.id, cl.kode, cl.nama, cl.kode_pos, cl.id_core_kecamatan,
       coalesce(cc.nama, '') AS kecamatan_nama, cl.version
FROM core_kelurahan cl
LEFT JOIN core_kecamatan cc ON cc.id = cl.id_core_kecamatan
WHERE cl.deleted_at IS NULL
  AND cl.kode_pos = sqlc.arg('kode_pos')::text
  AND (sqlc.narg('search')::text IS NULL OR cl.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN cl.nama END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN cl.nama
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN cl.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN cl.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN cl.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN cl.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKodePos :one
-- Total kelurahan ber-kode pos PERSIS (kriteria sama dengan ListKodePos).
SELECT count(*)::int AS total
FROM core_kelurahan cl
LEFT JOIN core_kecamatan cc ON cc.id = cl.id_core_kecamatan
WHERE cl.deleted_at IS NULL
  AND cl.kode_pos = sqlc.arg('kode_pos')::text
  AND (sqlc.narg('search')::text IS NULL OR cl.nama ILIKE '%' || sqlc.narg('search') || '%');

-- ===========================================================================
-- ADMIN — assert baris hidup (404 WLY-005 diputuskan repository/service)
-- ===========================================================================

-- name: AssertProvinsiAda :many
-- Baris provinsi hidup penuh — kosong = 404 WLY-005.
SELECT * FROM core_provinsi
WHERE deleted_at IS NULL AND id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: AssertKotaAda :many
-- Baris kota hidup penuh — kosong = 404 WLY-005.
SELECT * FROM core_kota
WHERE deleted_at IS NULL AND id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: AssertKecamatanAda :many
-- Baris kecamatan hidup penuh — kosong = 404 WLY-005.
SELECT * FROM core_kecamatan
WHERE deleted_at IS NULL AND id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: AssertKelurahanAda :many
-- Baris kelurahan hidup penuh — kosong = 404 WLY-005.
SELECT * FROM core_kelurahan
WHERE deleted_at IS NULL AND id = sqlc.arg('id')::bigint
LIMIT 1;

-- ===========================================================================
-- ADMIN — pre-check kode hidup duplikat (409 WLY-004 diputuskan service)
-- ===========================================================================

-- name: CariKodeHidupProvinsi :many
-- Provinsi hidup ber-kode sama — kosong = kode bebas (race → 23505).
SELECT id FROM core_provinsi
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- name: CariKodeHidupKota :many
-- Kota hidup ber-kode sama — kosong = kode bebas.
SELECT id FROM core_kota
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- name: CariKodeHidupKecamatan :many
-- Kecamatan hidup ber-kode sama — kosong = kode bebas.
SELECT id FROM core_kecamatan
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- name: CariKodeHidupKelurahan :many
-- Kelurahan hidup ber-kode sama — kosong = kode bebas.
SELECT id FROM core_kelurahan
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- ===========================================================================
-- ADMIN — hitung child hidup (guard ubah kode WLY-001 & hapus WLY-003)
-- ===========================================================================

-- name: HitungKotaHidup :one
-- Jumlah kota hidup satu provinsi.
SELECT count(*)::int AS total FROM core_kota
WHERE id_core_provinsi = sqlc.arg('id_provinsi')::bigint AND deleted_at IS NULL;

-- name: HitungKecamatanHidup :one
-- Jumlah kecamatan hidup satu kota.
SELECT count(*)::int AS total FROM core_kecamatan
WHERE id_core_kota = sqlc.arg('id_kota')::bigint AND deleted_at IS NULL;

-- name: HitungKelurahanHidup :one
-- Jumlah kelurahan hidup satu kecamatan.
SELECT count(*)::int AS total FROM core_kelurahan
WHERE id_core_kecamatan = sqlc.arg('id_kecamatan')::bigint AND deleted_at IS NULL;

-- ===========================================================================
-- ADMIN — CRUD provinsi
-- ===========================================================================

-- name: InsertProvinsi :one
-- Insert provinsi (version 1 eksplisit; entity_id default gen_random_uuid());
-- race uq_core_provinsi_kode_hidup (23505) mentah.
INSERT INTO core_provinsi (kode, nama, version)
VALUES (sqlc.arg('kode'), sqlc.arg('nama'), sqlc.arg('version'))
RETURNING *;

-- name: UpdateProvinsi :many
-- Update provinsi hidup + optimistic lock (version server di WHERE);
-- kosong = versi bentrok (race — 409 WLY-002 diputuskan service).
UPDATE core_provinsi SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteProvinsi :many
-- Soft delete provinsi (deleted_at + version bump + updatedAt) dengan
-- optimistic lock; kosong = versi bentrok.
UPDATE core_provinsi SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  version = version + 1,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING id;

-- ===========================================================================
-- ADMIN — CRUD kota
-- ===========================================================================

-- name: InsertKota :one
-- Insert kota/kabupaten — race uq_core_kota_kode_hidup (23505) mentah.
INSERT INTO core_kota (kode, nama, jenis, id_core_provinsi, version)
VALUES (sqlc.arg('kode'), sqlc.arg('nama'), sqlc.arg('jenis'),
        sqlc.arg('id_core_provinsi')::bigint, sqlc.arg('version'))
RETURNING *;

-- name: UpdateKota :many
-- Update kota hidup + optimistic lock; kosong = versi bentrok.
UPDATE core_kota SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  jenis = sqlc.arg('jenis'),
  id_core_provinsi = sqlc.arg('id_core_provinsi')::bigint,
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteKota :many
-- Soft delete kota dengan optimistic lock; kosong = versi bentrok.
UPDATE core_kota SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  version = version + 1,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING id;

-- ===========================================================================
-- ADMIN — CRUD kecamatan
-- ===========================================================================

-- name: InsertKecamatan :one
-- Insert kecamatan — race uq_core_kecamatan_kode_hidup (23505) mentah.
INSERT INTO core_kecamatan (kode, nama, id_core_kota, version)
VALUES (sqlc.arg('kode'), sqlc.arg('nama'), sqlc.arg('id_core_kota')::bigint, sqlc.arg('version'))
RETURNING *;

-- name: UpdateKecamatan :many
-- Update kecamatan hidup + optimistic lock; kosong = versi bentrok.
UPDATE core_kecamatan SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  id_core_kota = sqlc.arg('id_core_kota')::bigint,
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteKecamatan :many
-- Soft delete kecamatan dengan optimistic lock; kosong = versi bentrok.
UPDATE core_kecamatan SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  version = version + 1,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING id;

-- ===========================================================================
-- ADMIN — CRUD kelurahan/desa
-- ===========================================================================

-- name: InsertKelurahan :one
-- Insert kelurahan (kode_pos nullable — NULL = belum tercantum); race
-- uq_core_kelurahan_kode_hidup (23505) mentah.
INSERT INTO core_kelurahan (kode, nama, kode_pos, id_core_kecamatan, version)
VALUES (sqlc.arg('kode'), sqlc.arg('nama'), sqlc.narg('kode_pos'),
        sqlc.arg('id_core_kecamatan')::bigint, sqlc.arg('version'))
RETURNING *;

-- name: UpdateKelurahan :many
-- Update kelurahan hidup + optimistic lock (kode_pos nullable — NULL =
-- hapus kode pos); kosong = versi bentrok.
UPDATE core_kelurahan SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  kode_pos = sqlc.narg('kode_pos'),
  id_core_kecamatan = sqlc.arg('id_core_kecamatan')::bigint,
  version = sqlc.arg('version'),
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING *;

-- name: SoftDeleteKelurahan :many
-- Soft delete kelurahan (level daun — TANPA child-check) dengan optimistic
-- lock; kosong = versi bentrok.
UPDATE core_kelurahan SET
  deleted_at = sqlc.arg('deleted_at')::timestamptz,
  version = version + 1,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND version = sqlc.arg('versi_server')
  AND deleted_at IS NULL
RETURNING id;
