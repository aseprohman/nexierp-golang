-- Query fitur MASTER-B modul INVENTORY — padanan repositories/master/*
-- NestJS (gudang, lokasi, lot, jenis-operasi, atribut+nilai; gelombang 3
-- refactor: query verbatim dari service gelombang 2). Tabel: inv_gudang,
-- inv_lokasi_stok, inv_lot_serial (+inv_produk), inv_jenis_operasi
-- (+inv_gerakan_header guard hapus), inv_atribut, inv_nilai_atribut
-- (+inv_produk_atribut guard hapus), inv_saldo_stok (saldo lot & lokasi),
-- rantai wilayah CORE (core_kelurahan→core_kecamatan→core_kota→core_provinsi
-- — ddl/48, 3NF tanpa salinan nama).
-- Disiplin: soft-delete `deleted_at IS NULL` di SEMUA query BACA/mutasi baris;
-- dua pengecualian VERBATIM sumber: cek dup kode gudang/lokasi/atribut TANPA
-- filter deleted (global), cek dup kode lot per produk TANPA filter deleted,
-- resolver kode lokasi default jenis operasi TANPA filter deleted; kondisi
-- hidup rantai wilayah di ON-join (bukan WHERE) agar baris gudang selamat.
-- Semua kolom EKSPLISIT; executor (pool | tx) diteruskan wrapper repository.

-- ===========================================================================
-- GUDANG — padanan gudang.repository.ts
-- ===========================================================================

-- name: ListGudangRantai :many
-- Halaman gudang + rantai wilayah (4 LEFT JOIN, kondisi hidup di ON — baris
-- tetap selamat saat master wilayah lunak-dihapus, nama → NULL). Filter
-- status/search; cakupan 'storages' aktor lewat ids (bigint[] NULL = tanpa
-- predicate — SEMUA; DENY_ALL ditangani service, halaman kosong). sort_col
-- whitelist kanonik ('' = kode ASC).
SELECT g.id, g.entity_id, g.kode, g.nama, g.kode_satuan, g.alamat,
       g.status, g.version, g.created_at, g.updated_at, g.deleted_at,
       g.id_core_kelurahan, g.latitude, g.longitude,
       kec.id AS id_core_kecamatan,
       kota.id AS id_core_kota,
       prov.id AS id_core_provinsi,
       kel.nama AS kelurahan_nama,
       kec.nama AS kecamatan_nama,
       kota.nama AS kota_nama,
       prov.nama AS provinsi_nama,
       kel.kode_pos AS kode_pos
FROM inv_gudang g
LEFT JOIN core_kelurahan kel
       ON kel.id = g.id_core_kelurahan AND kel.deleted_at IS NULL
LEFT JOIN core_kecamatan kec
       ON kec.id = kel.id_core_kecamatan AND kec.deleted_at IS NULL
LEFT JOIN core_kota kota
       ON kota.id = kec.id_core_kota AND kota.deleted_at IS NULL
LEFT JOIN core_provinsi prov
       ON prov.id = kota.id_core_provinsi AND prov.deleted_at IS NULL
WHERE g.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR g.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('search')::text IS NULL
       OR g.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR g.nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (sqlc.narg('ids')::bigint[] IS NULL OR g.id = ANY(sqlc.narg('ids')::bigint[]))
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN g.kode END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN g.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN g.nama
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN g.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN g.nama
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN g.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN g.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN g.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN g.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountGudang :one
-- Total baris ListGudangRantai (WHERE identik pada inv_gudang — tanpa join,
-- persis hitungan sumber).
SELECT count(*)::int AS total
FROM inv_gudang g
WHERE g.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR g.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('search')::text IS NULL
       OR g.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR g.nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (sqlc.narg('ids')::bigint[] IS NULL OR g.id = ANY(sqlc.narg('ids')::bigint[]));

-- name: GudangRantaiByID :one
-- Satu gudang + rantai wilayah (post-mutasi read & assertAda) — kosong =
-- absen. kondisi hidup rantai tetap di ON-join.
SELECT g.id, g.entity_id, g.kode, g.nama, g.kode_satuan, g.alamat,
       g.status, g.version, g.created_at, g.updated_at, g.deleted_at,
       g.id_core_kelurahan, g.latitude, g.longitude,
       kec.id AS id_core_kecamatan,
       kota.id AS id_core_kota,
       prov.id AS id_core_provinsi,
       kel.nama AS kelurahan_nama,
       kec.nama AS kecamatan_nama,
       kota.nama AS kota_nama,
       prov.nama AS provinsi_nama,
       kel.kode_pos AS kode_pos
FROM inv_gudang g
LEFT JOIN core_kelurahan kel
       ON kel.id = g.id_core_kelurahan AND kel.deleted_at IS NULL
LEFT JOIN core_kecamatan kec
       ON kec.id = kel.id_core_kecamatan AND kec.deleted_at IS NULL
LEFT JOIN core_kota kota
       ON kota.id = kec.id_core_kota AND kota.deleted_at IS NULL
LEFT JOIN core_provinsi prov
       ON prov.id = kota.id_core_provinsi AND prov.deleted_at IS NULL
WHERE g.id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: GudangDupeKode :one
-- Kode gudang sudah dipakai (uq global)? — TANPA filter deleted (verbatim
-- sumber); 23505 race dipetakan 409 pesan sama.
SELECT g.id
FROM inv_gudang g
WHERE g.kode = sqlc.arg('kode')::text
LIMIT 1;

-- name: KelurahanHidup :one
-- Kelurahan CORE hidup by id (SOFT-DELETE-AWARE — FK RESTRICT hanya hard
-- delete); kosong = absen/lunak-dihapus → 400 pesan verbatim.
SELECT k.id
FROM core_kelurahan k
WHERE k.id = sqlc.arg('id')::bigint AND k.deleted_at IS NULL
LIMIT 1;

-- name: CountLokasiGudang :one
-- Jumlah lokasi stok hidup dalam gudang (guard hapus INV-002).
SELECT count(*)::int AS n
FROM inv_lokasi_stok l
WHERE l.id_inv_gudang = sqlc.arg('id')::bigint AND l.deleted_at IS NULL;

-- name: InsertGudang :one
-- Insert gudang baru (entityId di-generate app) → baris lengkap.
INSERT INTO inv_gudang
  (entity_id, kode, nama, kode_satuan, alamat, id_core_kelurahan, latitude, longitude, status)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('kode')::text, sqlc.arg('nama')::text,
   sqlc.narg('kode_satuan')::text, sqlc.narg('alamat')::text,
   sqlc.narg('id_core_kelurahan')::bigint, sqlc.narg('latitude')::numeric,
   sqlc.narg('longitude')::numeric, sqlc.arg('status')::enum_status_aktif)
RETURNING
  id, entity_id, kode, nama, kode_satuan, alamat, status, version,
  created_at, updated_at, deleted_at, id_core_kelurahan, latitude, longitude;

-- name: UpdateGudangHidup :one
-- Update gudang hidup — predicate id + hidup + version (optimistic locking
-- atomik STD-07; 0 baris → 409 INV-017 di service). Set lengkap hasil merge
-- service (version+1 dihitung di sana).
UPDATE inv_gudang
SET nama = sqlc.arg('nama')::text,
    kode_satuan = sqlc.narg('kode_satuan')::text,
    alamat = sqlc.narg('alamat')::text,
    id_core_kelurahan = sqlc.narg('id_core_kelurahan')::bigint,
    latitude = sqlc.narg('latitude')::numeric,
    longitude = sqlc.narg('longitude')::numeric,
    status = sqlc.arg('status')::enum_status_aktif,
    version = sqlc.arg('version')::int,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
  AND version = sqlc.arg('versi_harap')::int
RETURNING
  id, entity_id, kode, nama, kode_satuan, alamat, status, version,
  created_at, updated_at, deleted_at, id_core_kelurahan, latitude, longitude;

-- name: HapusLunakGudang :exec
-- Soft delete — TANPA bump version (verbatim sumber; set dibangun service).
UPDATE inv_gudang
SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- ===========================================================================
-- LOKASI STOK — padanan lokasi.repository.ts
-- ===========================================================================

-- name: ListLokasi :many
-- Halaman lokasi + nama gudang induk + nama lokasi induk (LEFT JOIN tanpa
-- kondisi hidup — verbatim sumber). Cakupan 'storages' HANYA menyentuh lokasi
-- INTERNAL: scope_deny → jenis <> 'INTERNAL' (virtual selalu tampil); DAFTAR
-- → OR(jenis <> 'INTERNAL', id_inv_gudang IN ids); SEMUA → ids NULL tanpa
-- predicate. sort_col whitelist kanonik ('' = kode ASC).
SELECT l.id, l.entity_id, l.kode, l.nama, l.jenis, l.id_inv_gudang,
       l.id_lokasi_induk, l.status, l.version, l.created_at, l.updated_at,
       l.deleted_at,
       gr.nama AS nama_gudang,
       ir.nama AS nama_induk
FROM inv_lokasi_stok l
LEFT JOIN inv_gudang gr ON gr.id = l.id_inv_gudang
LEFT JOIN inv_lokasi_stok ir ON ir.id = l.id_lokasi_induk
WHERE l.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR l.jenis::text = sqlc.narg('jenis')::text)
  AND (sqlc.narg('id_gudang')::bigint IS NULL OR l.id_inv_gudang = sqlc.narg('id_gudang')::bigint)
  AND (sqlc.narg('search')::text IS NULL
       OR l.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR l.nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (
    (sqlc.arg('scope_deny')::boolean AND l.jenis::text <> 'INTERNAL')
    OR (
      NOT sqlc.arg('scope_deny')::boolean
      AND (
        sqlc.narg('scope_ids')::bigint[] IS NULL
        OR l.jenis::text <> 'INTERNAL'
        OR l.id_inv_gudang = ANY(sqlc.narg('scope_ids')::bigint[])
      )
    )
  )
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN l.kode END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN l.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN l.nama
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN l.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN l.nama
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN l.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN l.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN l.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN l.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountLokasi :one
-- Total baris ListLokasi (WHERE identik pada inv_lokasi_stok — tanpa join).
SELECT count(*)::int AS total
FROM inv_lokasi_stok l
WHERE l.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR l.jenis::text = sqlc.narg('jenis')::text)
  AND (sqlc.narg('id_gudang')::bigint IS NULL OR l.id_inv_gudang = sqlc.narg('id_gudang')::bigint)
  AND (sqlc.narg('search')::text IS NULL
       OR l.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR l.nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (
    (sqlc.arg('scope_deny')::boolean AND l.jenis::text <> 'INTERNAL')
    OR (
      NOT sqlc.arg('scope_deny')::boolean
      AND (
        sqlc.narg('scope_ids')::bigint[] IS NULL
        OR l.jenis::text <> 'INTERNAL'
        OR l.id_inv_gudang = ANY(sqlc.narg('scope_ids')::bigint[])
      )
    )
  );

-- name: LokasiDetail :one
-- Detail lokasi hidup + nama gudang + nama induk (muatDetail) — kosong =
-- absen/lunak-dihapus.
SELECT l.id, l.entity_id, l.kode, l.nama, l.jenis, l.id_inv_gudang,
       l.id_lokasi_induk, l.status, l.version, l.created_at, l.updated_at,
       l.deleted_at,
       gr.nama AS nama_gudang,
       ir.nama AS nama_induk
FROM inv_lokasi_stok l
LEFT JOIN inv_gudang gr ON gr.id = l.id_inv_gudang
LEFT JOIN inv_lokasi_stok ir ON ir.id = l.id_lokasi_induk
WHERE l.id = sqlc.arg('id')::bigint AND l.deleted_at IS NULL
LIMIT 1;

-- name: LokasiHidupByID :one
-- Lokasi hidup by id tanpa join (muatById — pre-check update/remove).
SELECT l.id, l.entity_id, l.kode, l.nama, l.jenis, l.id_inv_gudang,
       l.id_lokasi_induk, l.status, l.version, l.created_at, l.updated_at,
       l.deleted_at
FROM inv_lokasi_stok l
WHERE l.id = sqlc.arg('id')::bigint AND l.deleted_at IS NULL
LIMIT 1;

-- name: LokasiDupeKode :one
-- Kode lokasi sudah dipakai (uq global)? — TANPA filter deleted (verbatim
-- sumber); 23505 race dipetakan 409 pesan sama.
SELECT l.id
FROM inv_lokasi_stok l
WHERE l.kode = sqlc.arg('kode')::text
LIMIT 1;

-- name: SaldoLokasi :one
-- Total saldo on-hand lokasi (guard hapus INV-014 — COALESCE SUM, hidup).
SELECT COALESCE(SUM(s.qty_on_hand), 0)::int AS n
FROM inv_saldo_stok s
WHERE s.id_inv_lokasi_stok = sqlc.arg('id')::bigint AND s.deleted_at IS NULL;

-- name: InsertLokasi :one
-- Insert lokasi baru → baris lengkap.
INSERT INTO inv_lokasi_stok
  (entity_id, kode, nama, jenis, id_inv_gudang, id_lokasi_induk, status)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('kode')::text, sqlc.arg('nama')::text,
   sqlc.arg('jenis')::enum_jenis_lokasi, sqlc.narg('id_inv_gudang')::bigint,
   sqlc.narg('id_lokasi_induk')::bigint, sqlc.arg('status')::enum_status_aktif)
RETURNING
  id, entity_id, kode, nama, jenis, id_inv_gudang, id_lokasi_induk, status,
  version, created_at, updated_at, deleted_at;

-- name: UpdateLokasiHidup :one
-- Update lokasi hidup — predicate id + hidup + version (STD-07; 0 baris →
-- 409 INV-017 di service). Set lengkap hasil merge service.
UPDATE inv_lokasi_stok
SET nama = sqlc.arg('nama')::text,
    jenis = sqlc.arg('jenis')::enum_jenis_lokasi,
    id_inv_gudang = sqlc.narg('id_inv_gudang')::bigint,
    id_lokasi_induk = sqlc.narg('id_lokasi_induk')::bigint,
    status = sqlc.arg('status')::enum_status_aktif,
    version = sqlc.arg('version')::int,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
  AND version = sqlc.arg('versi_harap')::int
RETURNING
  id, entity_id, kode, nama, jenis, id_inv_gudang, id_lokasi_induk, status,
  version, created_at, updated_at, deleted_at;

-- name: HapusLunakLokasi :exec
-- Soft delete — TANPA bump version (verbatim sumber).
UPDATE inv_lokasi_stok
SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- ===========================================================================
-- LOT/SERIAL — padanan lot.repository.ts
-- ===========================================================================

-- name: ListLot :many
-- Halaman lot + produk (INNER JOIN) + saldo on-hand readmodel (subquery SUM
-- inv_saldo_stok hidup — FEFO index di DDL). Filter status/idProduk/search
-- (kode lot ILIKE ATAU sku produk). sort_col whitelist kanonik
-- ('' = kode ASC; 'kedaluwarsa' = tanggal_kedaluwarsa).
SELECT l.id, l.entity_id, l.id_inv_produk, l.kode, l.tanggal_prodiksi,
       l.tanggal_kedaluwarsa, l.status, l.version, l.created_at, l.updated_at,
       l.deleted_at, l.barcode,
       p.kode_produk AS kode_produk,
       p.nama AS nama_produk,
       COALESCE((
         SELECT SUM(s.qty_on_hand)::int FROM inv_saldo_stok s
         WHERE s.id_inv_lot_serial = l.id AND s.deleted_at IS NULL
       ), 0) AS saldo_on_hand
FROM inv_lot_serial l
INNER JOIN inv_produk p ON p.id = l.id_inv_produk
WHERE l.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR l.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('id_produk')::bigint IS NULL OR l.id_inv_produk = sqlc.narg('id_produk')::bigint)
  AND (sqlc.narg('search')::text IS NULL
       OR l.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR p.kode_produk ILIKE '%' || sqlc.narg('search')::text || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN l.kode END ASC,
  -- varchar group
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN l.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN l.kode
  END DESC NULLS FIRST,
  -- timestamptz group
  CASE
    WHEN sqlc.arg('sort_col') = 'kedaluwarsa' AND NOT sqlc.arg('sort_desc')::boolean THEN l.tanggal_kedaluwarsa
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN l.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN l.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kedaluwarsa' AND sqlc.arg('sort_desc')::boolean THEN l.tanggal_kedaluwarsa
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN l.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN l.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountLot :one
-- Total baris ListLot (INNER JOIN produk ikut hitungan — verbatim sumber).
SELECT count(*)::int AS total
FROM inv_lot_serial l
INNER JOIN inv_produk p ON p.id = l.id_inv_produk
WHERE l.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR l.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('id_produk')::bigint IS NULL OR l.id_inv_produk = sqlc.narg('id_produk')::bigint)
  AND (sqlc.narg('search')::text IS NULL
       OR l.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR p.kode_produk ILIKE '%' || sqlc.narg('search')::text || '%');

-- name: LotDetail :one
-- Detail lot hidup + produk + saldo readmodel — kosong = absen/terhapus.
SELECT l.id, l.entity_id, l.id_inv_produk, l.kode, l.tanggal_prodiksi,
       l.tanggal_kedaluwarsa, l.status, l.version, l.created_at, l.updated_at,
       l.deleted_at, l.barcode,
       p.kode_produk AS kode_produk,
       p.nama AS nama_produk,
       COALESCE((
         SELECT SUM(s.qty_on_hand)::int FROM inv_saldo_stok s
         WHERE s.id_inv_lot_serial = l.id AND s.deleted_at IS NULL
       ), 0) AS saldo_on_hand
FROM inv_lot_serial l
INNER JOIN inv_produk p ON p.id = l.id_inv_produk
WHERE l.id = sqlc.arg('id')::bigint AND l.deleted_at IS NULL
LIMIT 1;

-- name: ProdukHidup :one
-- Produk hidup by id (id/kode/nama utk guard & audit) — kosong = absen.
SELECT p.id, p.kode_produk, p.nama
FROM inv_produk p
WHERE p.id = sqlc.arg('id')::bigint AND p.deleted_at IS NULL
LIMIT 1;

-- name: LotDupeKode :one
-- Kode lot sudah ada untuk produk (uq per produk)? — TANPA filter deleted
-- (verbatim sumber); 23505 race dipetakan 409 pesan sama.
SELECT l.id
FROM inv_lot_serial l
WHERE l.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND l.kode = sqlc.arg('kode')::text
LIMIT 1;

-- name: LotDupeBarcode :one
-- Barcode dipakai lot HIDUP lain (uq_inv_lot_serial_barcode — partial hidup,
-- verbatim sumber); kosong = bebas.
SELECT l.id
FROM inv_lot_serial l
WHERE l.barcode = sqlc.arg('barcode')::text AND l.deleted_at IS NULL
LIMIT 1;

-- name: InsertLot :one
-- Insert lot baru (status default DB AKTIF) → baris lengkap.
INSERT INTO inv_lot_serial
  (entity_id, id_inv_produk, kode, barcode, tanggal_prodiksi, tanggal_kedaluwarsa)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('id_inv_produk')::bigint,
   sqlc.arg('kode')::text, sqlc.narg('barcode')::text,
   sqlc.narg('tanggal_prodiksi')::timestamptz,
   sqlc.narg('tanggal_kedaluwarsa')::timestamptz)
RETURNING
  id, entity_id, id_inv_produk, kode, tanggal_prodiksi, tanggal_kedaluwarsa,
  status, version, created_at, updated_at, deleted_at, barcode;

-- ===========================================================================
-- JENIS OPERASI — padanan jenis-operasi.repository.ts
-- ===========================================================================

-- name: ListJenisOperasi :many
-- Halaman jenis operasi + kode lokasi default (2 LEFT JOIN alias
-- jo_sumber/jo_tujuan — tanpa kondisi hidup, verbatim sumber). Filter
-- jenisGerakan/status/search (kode ILIKE ATAU nama ILIKE). sort_col whitelist
-- kanonik ('' = kode ASC).
SELECT j.id, j.entity_id, j.kode, j.nama, j.jenis_gerakan, j.prefix,
       j.jumlah_langkah, j.nama_langkah_1, j.nama_langkah_2, j.nama_langkah_3,
       j.id_lokasi_sumber_default, j.id_lokasi_tujuan_default, j.status,
       j.version, j.created_at, j.updated_at, j.deleted_at,
       src.kode AS kode_sumber,
       dst.kode AS kode_tujuan
FROM inv_jenis_operasi j
LEFT JOIN inv_lokasi_stok src ON src.id = j.id_lokasi_sumber_default
LEFT JOIN inv_lokasi_stok dst ON dst.id = j.id_lokasi_tujuan_default
WHERE j.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR j.jenis_gerakan::text = sqlc.narg('jenis')::text)
  AND (sqlc.narg('status')::text IS NULL OR j.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('search')::text IS NULL
       OR j.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR j.nama ILIKE '%' || sqlc.narg('search')::text || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN j.kode END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN j.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN j.nama
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN j.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN j.nama
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN j.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN j.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountJenisOperasi :one
-- Total baris ListJenisOperasi (WHERE identik pada inv_jenis_operasi).
SELECT count(*)::int AS total
FROM inv_jenis_operasi j
WHERE j.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR j.jenis_gerakan::text = sqlc.narg('jenis')::text)
  AND (sqlc.narg('status')::text IS NULL OR j.status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('search')::text IS NULL
       OR j.kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR j.nama ILIKE '%' || sqlc.narg('search')::text || '%');

-- name: JenisOperasiDetail :one
-- Detail jenis operasi hidup + kode lokasi default — kosong = absen/terhapus.
SELECT j.id, j.entity_id, j.kode, j.nama, j.jenis_gerakan, j.prefix,
       j.jumlah_langkah, j.nama_langkah_1, j.nama_langkah_2, j.nama_langkah_3,
       j.id_lokasi_sumber_default, j.id_lokasi_tujuan_default, j.status,
       j.version, j.created_at, j.updated_at, j.deleted_at,
       src.kode AS kode_sumber,
       dst.kode AS kode_tujuan
FROM inv_jenis_operasi j
LEFT JOIN inv_lokasi_stok src ON src.id = j.id_lokasi_sumber_default
LEFT JOIN inv_lokasi_stok dst ON dst.id = j.id_lokasi_tujuan_default
WHERE j.id = sqlc.arg('id')::bigint AND j.deleted_at IS NULL
LIMIT 1;

-- name: JenisOperasiHidupByID :one
-- Jenis operasi hidup by id tanpa join (assertAda) — kosong = tidak ada.
SELECT j.id, j.entity_id, j.kode, j.nama, j.jenis_gerakan, j.prefix,
       j.jumlah_langkah, j.nama_langkah_1, j.nama_langkah_2, j.nama_langkah_3,
       j.id_lokasi_sumber_default, j.id_lokasi_tujuan_default, j.status,
       j.version, j.created_at, j.updated_at, j.deleted_at
FROM inv_jenis_operasi j
WHERE j.id = sqlc.arg('id')::bigint AND j.deleted_at IS NULL
LIMIT 1;

-- name: JenisOperasiDupeKode :one
-- Kode sudah dipakai jenis operasi HIDUP lain (dengan filter deleted —
-- verbatim sumber; kecuali_id NULL = cek semua); kosong = bebas.
SELECT j.id
FROM inv_jenis_operasi j
WHERE j.kode = sqlc.arg('kode')::text
  AND j.deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR j.id <> sqlc.narg('kecuali_id')::bigint)
LIMIT 1;

-- name: CountGerakanPakai :one
-- Jumlah gerakan hidup pemakai kode jenis operasi ini (guard hapus INV-002).
SELECT count(*)::int AS n
FROM inv_gerakan_header gh
WHERE gh.kode_jenis_operasi = sqlc.arg('kode')::text AND gh.deleted_at IS NULL;

-- name: KodeLokasiDefault :many
-- Resolver kode lokasi default BATCH inArray — TANPA filter deleted
-- (verbatim sumber); tanpa baris cocok → kode null di mapper.
SELECT l.id, l.kode
FROM inv_lokasi_stok l
WHERE l.id = ANY(sqlc.arg('ids')::bigint[]);

-- name: InsertJenisOperasi :one
-- Insert jenis operasi baru → baris lengkap.
INSERT INTO inv_jenis_operasi
  (entity_id, kode, nama, jenis_gerakan, prefix, jumlah_langkah,
   nama_langkah_1, nama_langkah_2, nama_langkah_3,
   id_lokasi_sumber_default, id_lokasi_tujuan_default, status)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('kode')::text, sqlc.arg('nama')::text,
   sqlc.arg('jenis_gerakan')::enum_jenis_gerakan, sqlc.arg('prefix')::text,
   sqlc.arg('jumlah_langkah')::int, sqlc.arg('nama_langkah_1')::text,
   sqlc.narg('nama_langkah_2')::text, sqlc.narg('nama_langkah_3')::text,
   sqlc.narg('id_lokasi_sumber_default')::bigint,
   sqlc.narg('id_lokasi_tujuan_default')::bigint,
   sqlc.arg('status')::enum_status_aktif)
RETURNING
  id, entity_id, kode, nama, jenis_gerakan, prefix, jumlah_langkah,
  nama_langkah_1, nama_langkah_2, nama_langkah_3, id_lokasi_sumber_default,
  id_lokasi_tujuan_default, status, version, created_at, updated_at, deleted_at;

-- name: UpdateJenisOperasiHidup :one
-- Update jenis operasi hidup — predicate id + hidup + version (STD-07; 0
-- baris → 409 INV-017 di service). Set lengkap hasil merge service.
UPDATE inv_jenis_operasi
SET kode = sqlc.arg('kode')::text,
    nama = sqlc.arg('nama')::text,
    jenis_gerakan = sqlc.arg('jenis_gerakan')::enum_jenis_gerakan,
    prefix = sqlc.arg('prefix')::text,
    jumlah_langkah = sqlc.arg('jumlah_langkah')::int,
    nama_langkah_1 = sqlc.arg('nama_langkah_1')::text,
    nama_langkah_2 = sqlc.narg('nama_langkah_2')::text,
    nama_langkah_3 = sqlc.narg('nama_langkah_3')::text,
    id_lokasi_sumber_default = sqlc.narg('id_lokasi_sumber_default')::bigint,
    id_lokasi_tujuan_default = sqlc.narg('id_lokasi_tujuan_default')::bigint,
    status = sqlc.arg('status')::enum_status_aktif,
    version = sqlc.arg('version')::int,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
  AND version = sqlc.arg('versi_harap')::int
RETURNING
  id, entity_id, kode, nama, jenis_gerakan, prefix, jumlah_langkah,
  nama_langkah_1, nama_langkah_2, nama_langkah_3, id_lokasi_sumber_default,
  id_lokasi_tujuan_default, status, version, created_at, updated_at, deleted_at;

-- name: HapusLunakJenisOperasi :exec
-- Soft delete — TANPA bump version (verbatim sumber).
UPDATE inv_jenis_operasi
SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- ===========================================================================
-- ATRIBUT + NILAI ATRIBUT — padanan atribut.repository.ts
-- ===========================================================================

-- name: ListAtribut :many
-- Halaman atribut varian (hidup) — tanpa filter (verbatim sumber). sort_col
-- whitelist kanonik ('' = kode ASC).
SELECT a.id, a.entity_id, a.kode, a.nama, a.tipe_input, a.status, a.version,
       a.created_at, a.updated_at, a.deleted_at
FROM inv_atribut a
WHERE a.deleted_at IS NULL
ORDER BY
  CASE WHEN sqlc.arg('sort_col') = '' THEN a.kode END ASC,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN a.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND NOT sqlc.arg('sort_desc')::boolean THEN a.nama
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'kode' AND sqlc.arg('sort_desc')::boolean THEN a.kode
    WHEN sqlc.arg('sort_col') = 'nama' AND sqlc.arg('sort_desc')::boolean THEN a.nama
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN a.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN a.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col') = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN a.created_at
    WHEN sqlc.arg('sort_col') = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN a.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountAtribut :one
-- Total atribut hidup (kriteria sama dengan ListAtribut).
SELECT count(*)::int AS total
FROM inv_atribut a
WHERE a.deleted_at IS NULL;

-- name: AtributHidupByID :one
-- Atribut hidup wajib ada (assertAtribut) — kosong = 404 INV-018.
SELECT a.id, a.entity_id, a.kode, a.nama, a.tipe_input, a.status, a.version,
       a.created_at, a.updated_at, a.deleted_at
FROM inv_atribut a
WHERE a.id = sqlc.arg('id')::bigint AND a.deleted_at IS NULL
LIMIT 1;

-- name: AtributDupeKode :one
-- Kode atribut sudah dipakai (uq GLOBAL — TANPA filter deleted, verbatim
-- sumber); 23505 race dipetakan 409 pesan sama.
SELECT a.id
FROM inv_atribut a
WHERE a.kode = sqlc.arg('kode')::text
LIMIT 1;

-- name: InsertAtribut :one
-- Insert atribut baru → baris lengkap.
INSERT INTO inv_atribut
  (entity_id, kode, nama, tipe_input, status)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('kode')::text, sqlc.arg('nama')::text,
   sqlc.arg('tipe_input')::enum_tipe_atribut, sqlc.arg('status')::enum_status_aktif)
RETURNING
  id, entity_id, kode, nama, tipe_input, status, version, created_at,
  updated_at, deleted_at;

-- name: UpdateAtributHidup :one
-- Update atribut hidup — predicate id + hidup + version (STD-07). Set
-- lengkap hasil merge service.
UPDATE inv_atribut
SET nama = sqlc.arg('nama')::text,
    tipe_input = sqlc.arg('tipe_input')::enum_tipe_atribut,
    status = sqlc.arg('status')::enum_status_aktif,
    version = sqlc.arg('version')::int,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
  AND version = sqlc.arg('versi_harap')::int
RETURNING
  id, entity_id, kode, nama, tipe_input, status, version, created_at,
  updated_at, deleted_at;

-- name: CountNilaiHidup :one
-- Jumlah nilai terkurasi hidup satu atribut (guard hapus atribut INV-002).
SELECT count(*)::int AS n
FROM inv_nilai_atribut n
WHERE n.id_inv_atribut = sqlc.arg('id')::bigint AND n.deleted_at IS NULL;

-- name: HapusLunakAtribut :exec
-- Soft delete atribut — TANPA bump version (verbatim sumber).
UPDATE inv_atribut
SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- name: ListNilaiByAtribut :many
-- Daftar nilai satu atribut hidup — urut urutan lalu nilai (BUKAN Page —
-- verbatim sumber).
SELECT n.id, n.entity_id, n.id_inv_atribut, n.nilai, n.urutan, n.status,
       n.version, n.created_at, n.updated_at, n.deleted_at
FROM inv_nilai_atribut n
WHERE n.id_inv_atribut = sqlc.arg('id')::bigint AND n.deleted_at IS NULL
ORDER BY n.urutan ASC, n.nilai ASC;

-- name: NilaiHidupByID :one
-- Nilai atribut hidup by id (findNilaiHidupById) — kosong = absen/terhapus.
SELECT n.id, n.entity_id, n.id_inv_atribut, n.nilai, n.urutan, n.status,
       n.version, n.created_at, n.updated_at, n.deleted_at
FROM inv_nilai_atribut n
WHERE n.id = sqlc.arg('id')::bigint AND n.deleted_at IS NULL
LIMIT 1;

-- name: NilaiDuplikat :one
-- Duplikat (atribut, nilai) di antara baris HIDUP (partial unique — verbatim
-- sumber); kosong = bebas.
SELECT n.id
FROM inv_nilai_atribut n
WHERE n.id_inv_atribut = sqlc.arg('id')::bigint
  AND n.nilai = sqlc.arg('nilai')::text
  AND n.deleted_at IS NULL
LIMIT 1;

-- name: CountPemakaianNilai :one
-- Jumlah pemakaian nilai oleh varian (junction inv_produk_atribut HIDUP —
-- guard hapus nilai INV-002).
SELECT count(*)::int AS n
FROM inv_produk_atribut pa
WHERE pa.id_inv_nilai_atribut = sqlc.arg('id')::bigint AND pa.deleted_at IS NULL;

-- name: InsertNilai :one
-- Insert nilai atribut baru → baris lengkap.
INSERT INTO inv_nilai_atribut
  (entity_id, id_inv_atribut, nilai, urutan, status)
VALUES
  (sqlc.arg('entity_id')::uuid, sqlc.arg('id_inv_atribut')::bigint,
   sqlc.arg('nilai')::text, sqlc.arg('urutan')::int,
   sqlc.arg('status')::enum_status_aktif)
RETURNING
  id, entity_id, id_inv_atribut, nilai, urutan, status, version, created_at,
  updated_at, deleted_at;

-- name: UpdateNilaiHidup :one
-- Update nilai atribut hidup — predicate id + hidup + version (STD-07).
UPDATE inv_nilai_atribut
SET nilai = sqlc.arg('nilai')::text,
    urutan = sqlc.arg('urutan')::int,
    status = sqlc.arg('status')::enum_status_aktif,
    version = sqlc.arg('version')::int,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
  AND version = sqlc.arg('versi_harap')::int
RETURNING
  id, entity_id, id_inv_atribut, nilai, urutan, status, version, created_at,
  updated_at, deleted_at;

-- name: HapusLunakNilai :exec
-- Soft delete nilai atribut — TANPA bump version (verbatim sumber).
UPDATE inv_nilai_atribut
SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
    updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;
