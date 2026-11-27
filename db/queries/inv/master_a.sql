-- Query fitur MASTER-A modul inv — port VERBATIM repositories/master/
-- {produk,produk-induk,kategori,unit,unit-konversi,kemasan}.repository.ts
-- NestJS (drizzle) ke sqlc. Kolom EKSPLISIT (tanpa SELECT *); money
-- numeric(18,4)/faktor numeric(18,6) dipilih ::text (mapper Number() di
-- wrapper); urutan ORDER BY dinamis = CASE whitelist sort + fallback
-- (padanan drizzlePageBounds). Semua query hidup (deleted_at IS NULL)
-- KECUALI yang sengaja global sesuai sumber (cari SKU/kode unik global).

/* ================================================================== */
/* PRODUK — inv_produk (+ saldo readmodel, junction atribut varian)    */
/* ================================================================== */

-- name: ListProduk :many
-- Daftar produk hidup — filter status/tipe/idKategori + search SKU/nama
-- (ILIKE); saldo_on_hand subquery inv_saldo_stok (VERBATIM list()).
SELECT
  p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_kategori_produk,
  p.id_inv_unit_ukur, p.id_inv_produk_induk, p.kunci_kombinasi,
  p.adalah_induk_varian, p.jejak_stok, p.barcode,
  p.harga_jual AS harga_jual, p.harga_biaya AS harga_biaya,
  p.stok_minimum, p.stok_maksimum, p.reorder_aktif, p.berat_gram,
  p.volume_cm3, p.keterangan, p.status, p.version, p.created_at, p.updated_at,
  COALESCE((
    SELECT SUM(s.qty_on_hand)::int FROM inv_saldo_stok s
    WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
  ), 0) AS saldo_on_hand
FROM inv_produk p
WHERE p.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR p.status::text = sqlc.narg('status'))
  AND (sqlc.narg('tipe')::text IS NULL OR p.tipe::text = sqlc.narg('tipe'))
  AND (sqlc.narg('id_kategori')::bigint IS NULL OR p.id_inv_kategori_produk = sqlc.narg('id_kategori'))
  AND (sqlc.narg('search')::text IS NULL OR p.kode_produk ILIKE '%' || sqlc.narg('search') || '%' OR p.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'kode_produk' AND NOT sqlc.arg('sort_desc')::boolean THEN p.kode_produk END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'kode_produk' AND sqlc.arg('sort_desc')::boolean     THEN p.kode_produk END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND NOT sqlc.arg('sort_desc')::boolean THEN p.nama        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND sqlc.arg('sort_desc')::boolean     THEN p.nama        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN p.created_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND sqlc.arg('sort_desc')::boolean     THEN p.created_at  END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN p.updated_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND sqlc.arg('sort_desc')::boolean     THEN p.updated_at  END DESC,
  p.kode_produk ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountProduk :one
SELECT count(*)::int AS total
FROM inv_produk p
WHERE p.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR p.status::text = sqlc.narg('status'))
  AND (sqlc.narg('tipe')::text IS NULL OR p.tipe::text = sqlc.narg('tipe'))
  AND (sqlc.narg('id_kategori')::bigint IS NULL OR p.id_inv_kategori_produk = sqlc.narg('id_kategori'))
  AND (sqlc.narg('search')::text IS NULL OR p.kode_produk ILIKE '%' || sqlc.narg('search') || '%' OR p.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatProdukHidup :one
-- Detail/assertHidup — baris penuh produk hidup (null di wrapper → 404 INV-018).
SELECT
  p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_kategori_produk,
  p.id_inv_unit_ukur, p.id_inv_produk_induk, p.kunci_kombinasi,
  p.adalah_induk_varian, p.jejak_stok, p.barcode,
  p.harga_jual AS harga_jual, p.harga_biaya AS harga_biaya,
  p.stok_minimum, p.stok_maksimum, p.reorder_aktif, p.berat_gram,
  p.volume_cm3, p.keterangan, p.status, p.version, p.created_at, p.updated_at
FROM inv_produk p
WHERE p.id = sqlc.arg('id') AND p.deleted_at IS NULL;

-- name: CariIndukVarianHidup :one
-- Induk varian hidup (penanda induk aktif, bukan varian) — cariIndukVarian.
SELECT
  p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_kategori_produk,
  p.id_inv_unit_ukur, p.id_inv_produk_induk, p.kunci_kombinasi,
  p.adalah_induk_varian, p.jejak_stok, p.barcode,
  p.harga_jual AS harga_jual, p.harga_biaya AS harga_biaya,
  p.stok_minimum, p.stok_maksimum, p.reorder_aktif, p.berat_gram,
  p.volume_cm3, p.keterangan, p.status, p.version, p.created_at, p.updated_at
FROM inv_produk p
WHERE p.id = sqlc.arg('id') AND p.deleted_at IS NULL
  AND p.adalah_induk_varian = TRUE AND p.id_inv_produk_induk IS NULL;

-- name: ListProdukLookup :many
-- Lookup ringkas picker (M36) — hanya AKTIF, INNER JOIN unit (kodeUnit);
-- barcode eksak MENANG atas search; limit sudah di-clamp wrapper (1..200).
SELECT
  p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_produk_induk,
  p.id_inv_unit_ukur, unit_ref.kode AS kode_unit,
  p.harga_jual AS harga_jual,
  COALESCE((
    SELECT SUM(s.qty_on_hand)::int FROM inv_saldo_stok s
    WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
  ), 0) AS saldo_on_hand
FROM inv_produk p
INNER JOIN inv_unit_ukur unit_ref ON unit_ref.id = p.id_inv_unit_ukur
WHERE p.deleted_at IS NULL AND p.status = 'AKTIF'
  AND CASE WHEN sqlc.narg('barcode')::text IS NOT NULL THEN p.barcode = sqlc.narg('barcode') ELSE TRUE END
  AND CASE WHEN sqlc.narg('search')::text IS NULL THEN TRUE ELSE
    (p.kode_produk ILIKE '%' || sqlc.narg('search') || '%'
     OR p.nama ILIKE '%' || sqlc.narg('search') || '%'
     OR p.barcode ILIKE '%' || sqlc.narg('search') || '%')
  END
  AND (sqlc.narg('id_kategori')::bigint IS NULL OR p.id_inv_kategori_produk = sqlc.narg('id_kategori'))
ORDER BY p.kode_produk ASC
LIMIT sqlc.arg('limit');

-- name: CariSkuDipakai :one
-- assertSkuBebas — SKU unik GLOBAL (unique DB uq_inv_produk_kode; TANPA
-- filter deleted_at — numbering tak pernah dipakai ulang, K-10).
SELECT p.id FROM inv_produk p WHERE p.kode_produk = sqlc.arg('sku') LIMIT 1;

-- name: CariBarcodeProdukHidup :one
-- assertBarcodeBebas — barcode unik di antara baris hidup (partial unique).
SELECT p.id FROM inv_produk p
WHERE p.barcode = sqlc.arg('barcode') AND p.deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR p.id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: ListKonfigurasiIndukRingkas :many
-- Konfigurasi atribut induk utk validasi entry varian (wajib + kode D-19);
-- TANPA ORDER BY — persis listKonfigurasiInduk produk.repository.
SELECT
  k.id_inv_atribut, a.kode AS kode_atribut, k.wajib
FROM inv_produk_varian_konfig k
INNER JOIN inv_atribut a ON a.id = k.id_inv_atribut
WHERE k.id_inv_produk = sqlc.arg('id_induk') AND k.deleted_at IS NULL;

-- name: ListNilaiAtributHidup :many
-- Nilai atribut hidup by ids (validasi pasangan atribut/nilai).
SELECT n.id, n.id_inv_atribut, n.nilai
FROM inv_nilai_atribut n
WHERE n.id = ANY(sqlc.arg('ids')::bigint[]) AND n.deleted_at IS NULL;

-- name: CariVarianKombinasiHidup :one
-- Varian hidup dengan kunci kombinasi sama per induk — INV-016.
SELECT p.id FROM inv_produk p
WHERE p.id_inv_produk_induk = sqlc.arg('id_induk')
  AND p.kunci_kombinasi = sqlc.arg('kunci') AND p.deleted_at IS NULL
LIMIT 1;

-- name: InsertProduk :one
-- Insert produk baru → baris lengkap (entityId/kunci/harga warisan di service).
INSERT INTO inv_produk (
  entity_id, kode_produk, nama, tipe, id_inv_kategori_produk, id_inv_unit_ukur,
  id_inv_produk_induk, kunci_kombinasi, jejak_stok, barcode, harga_jual,
  harga_biaya, stok_minimum, stok_maksimum, reorder_aktif, adalah_induk_varian,
  berat_gram, volume_cm3, keterangan, status
) VALUES (
  sqlc.arg('entity_id'), sqlc.arg('kode_produk'), sqlc.arg('nama'), sqlc.arg('tipe'),
  sqlc.arg('id_inv_kategori_produk'), sqlc.arg('id_inv_unit_ukur'),
  sqlc.arg('id_inv_produk_induk'), sqlc.arg('kunci_kombinasi'), sqlc.arg('jejak_stok'),
  sqlc.arg('barcode'), sqlc.arg('harga_jual'), sqlc.arg('harga_biaya'),
  sqlc.arg('stok_minimum'), sqlc.arg('stok_maksimum'), sqlc.arg('reorder_aktif'),
  sqlc.arg('adalah_induk_varian'), sqlc.arg('berat_gram'), sqlc.arg('volume_cm3'),
  sqlc.arg('keterangan'), sqlc.arg('status')
)
RETURNING
  id, kode_produk, nama, tipe, id_inv_kategori_produk,
  id_inv_unit_ukur, id_inv_produk_induk, kunci_kombinasi,
  adalah_induk_varian, jejak_stok, barcode,
  harga_jual AS harga_jual, harga_biaya AS harga_biaya,
  stok_minimum, stok_maksimum, reorder_aktif, berat_gram,
  volume_cm3, keterangan, status, version, created_at, updated_at;

-- name: InsertVarian :one
-- Insert varian → ringkas {id, kodeProduk} (returning verbatim sumber).
INSERT INTO inv_produk (
  entity_id, kode_produk, nama, tipe, id_inv_kategori_produk, id_inv_unit_ukur,
  id_inv_produk_induk, kunci_kombinasi, jejak_stok, barcode, harga_jual,
  harga_biaya, stok_minimum, stok_maksimum, reorder_aktif, adalah_induk_varian,
  berat_gram, volume_cm3, keterangan, status
) VALUES (
  sqlc.arg('entity_id'), sqlc.arg('kode_produk'), sqlc.arg('nama'), sqlc.arg('tipe'),
  sqlc.arg('id_inv_kategori_produk'), sqlc.arg('id_inv_unit_ukur'),
  sqlc.arg('id_inv_produk_induk'), sqlc.arg('kunci_kombinasi'), sqlc.arg('jejak_stok'),
  sqlc.arg('barcode'), sqlc.arg('harga_jual'), sqlc.arg('harga_biaya'),
  sqlc.arg('stok_minimum'), sqlc.arg('stok_maksimum'), sqlc.arg('reorder_aktif'),
  sqlc.arg('adalah_induk_varian'), sqlc.arg('berat_gram'), sqlc.arg('volume_cm3'),
  sqlc.arg('keterangan'), sqlc.arg('status')
)
RETURNING id, kode_produk;

-- name: UpdateProdukVersiHidup :one
-- Optimistic locking atomik STD-07 — WHERE id + hidup + version; 0 baris →
-- 409 INV-017 di service.
UPDATE inv_produk SET
  nama = sqlc.arg('nama'),
  tipe = sqlc.arg('tipe'),
  id_inv_kategori_produk = sqlc.arg('id_inv_kategori_produk'),
  id_inv_unit_ukur = sqlc.arg('id_inv_unit_ukur'),
  jejak_stok = sqlc.arg('jejak_stok'),
  barcode = sqlc.arg('barcode'),
  harga_jual = sqlc.arg('harga_jual'),
  harga_biaya = sqlc.arg('harga_biaya'),
  stok_minimum = sqlc.arg('stok_minimum'),
  stok_maksimum = sqlc.arg('stok_maksimum'),
  reorder_aktif = sqlc.arg('reorder_aktif'),
  adalah_induk_varian = sqlc.arg('adalah_induk_varian'),
  berat_gram = sqlc.arg('berat_gram'),
  volume_cm3 = sqlc.arg('volume_cm3'),
  keterangan = sqlc.arg('keterangan'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING
  id, kode_produk, nama, tipe, id_inv_kategori_produk,
  id_inv_unit_ukur, id_inv_produk_induk, kunci_kombinasi,
  adalah_induk_varian, jejak_stok, barcode,
  harga_jual AS harga_jual, harga_biaya AS harga_biaya,
  stok_minimum, stok_maksimum, reorder_aktif, berat_gram,
  volume_cm3, keterangan, status, version, created_at, updated_at;

-- name: UpdateIndukVersiHidup :one
-- Update induk (update() fitur produk-induk) — WHERE id + hidup + version.
UPDATE inv_produk SET
  nama = sqlc.arg('nama'),
  keterangan = sqlc.arg('keterangan'),
  id_inv_kategori_produk = sqlc.arg('id_inv_kategori_produk'),
  id_inv_unit_ukur = sqlc.arg('id_inv_unit_ukur'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING
  id, kode_produk, nama, tipe, id_inv_kategori_produk,
  id_inv_unit_ukur, id_inv_produk_induk, kunci_kombinasi,
  adalah_induk_varian, jejak_stok, barcode,
  harga_jual AS harga_jual, harga_biaya AS harga_biaya,
  stok_minimum, stok_maksimum, reorder_aktif, berat_gram,
  volume_cm3, keterangan, status, version, created_at, updated_at;

-- name: UpdateProdukVersiTanpaHidup :one
-- Langkah bump version REPLACE konfigurasi induk — VERBATIM sumber: WHERE
-- id + version SAJA (TANPA filter hidup).
UPDATE inv_produk SET version = sqlc.arg('version_baru'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND version = sqlc.arg('versi_harap')
RETURNING
  id, kode_produk, nama, tipe, id_inv_kategori_produk,
  id_inv_unit_ukur, id_inv_produk_induk, kunci_kombinasi,
  adalah_induk_varian, jejak_stok, barcode,
  harga_jual AS harga_jual, harga_biaya AS harga_biaya,
  stok_minimum, stok_maksimum, reorder_aktif, berat_gram,
  volume_cm3, keterangan, status, version, created_at, updated_at;

-- name: SoftDeleteProdukHidup :exec
-- Hapus lunak produk hidup (fitur produk — set di service).
UPDATE inv_produk SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;

-- name: SoftDeleteIndukHidup :exec
-- Hapus lunak induk hidup — set (deletedAt/updatedAt/adalahIndukVarian=false).
UPDATE inv_produk SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at'),
  adalah_induk_varian = sqlc.arg('adalah_induk_varian')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;

-- name: InsertProdukAtribut :exec
-- Junction varian ↔ nilai atribut (junction murni D-20 — idempoten).
INSERT INTO inv_produk_atribut (id_inv_produk, id_inv_nilai_atribut)
VALUES (sqlc.arg('id_inv_produk'), sqlc.arg('id_inv_nilai_atribut'))
ON CONFLICT DO NOTHING;

-- name: JumlahSaldoOnHandProduk :one
-- Agregat saldo hidup produk dari readmodel inv_saldo_stok (BACA).
SELECT COALESCE(SUM(s.qty_on_hand), 0)::int AS n
FROM inv_saldo_stok s
WHERE s.id_inv_produk = sqlc.arg('id_produk') AND s.deleted_at IS NULL;

-- name: HitungVarianHidupProduk :one
-- Jumlah varian hidup satu induk — guard D-21/D-39.
SELECT count(*)::int AS n FROM inv_produk p
WHERE p.id_inv_produk_induk = sqlc.arg('id_induk') AND p.deleted_at IS NULL;

-- name: HitungVarianMapInduk :many
-- Jumlah varian hidup per induk (groupBy) — list/get/update/remove induk.
SELECT p.id_inv_produk_induk AS id_induk, count(*)::int AS n
FROM inv_produk p
WHERE p.id_inv_produk_induk = ANY(sqlc.arg('ids')::bigint[]) AND p.deleted_at IS NULL
GROUP BY p.id_inv_produk_induk;

-- name: HitungGerakanHidupProduk :one
-- Guard hapus INV-002 — jumlah gerakan stok hidup produk.
SELECT count(*)::int AS n FROM inv_gerakan_stok g
WHERE g.id_inv_produk = sqlc.arg('id_produk') AND g.deleted_at IS NULL;

-- name: HitungLotHidupProduk :one
-- Guard hapus INV-002 — jumlah lot/serial hidup produk.
SELECT count(*)::int AS n FROM inv_lot_serial l
WHERE l.id_inv_produk = sqlc.arg('id_produk') AND l.deleted_at IS NULL;

-- name: MuatAtributProduk :many
-- Pasangan nilai atribut per produk (varian) — katalog produk.
SELECT
  pa.id_inv_produk, a.kode AS kode_atribut, a.nama AS nama_atribut, n.nilai
FROM inv_produk_atribut pa
INNER JOIN inv_nilai_atribut n ON n.id = pa.id_inv_nilai_atribut
INNER JOIN inv_atribut a ON a.id = n.id_inv_atribut
WHERE pa.id_inv_produk = ANY(sqlc.arg('ids')::bigint[])
  AND pa.deleted_at IS NULL AND n.deleted_at IS NULL;

-- name: MuatPetaKategoriHidup :many
-- Peta referensi kategori (nama by id) — input mapper view produk/induk.
SELECT k.id, k.nama FROM inv_kategori_produk k WHERE k.deleted_at IS NULL;

-- name: MuatPetaUnitHidup :many
-- Peta referensi unit ukur (kode by id) — input mapper view produk/induk.
SELECT u.id, u.kode FROM inv_unit_ukur u WHERE u.deleted_at IS NULL;

-- name: MuatPetaIndukHidup :many
-- Peta referensi induk varian (kode by id).
SELECT p.id, p.kode_produk FROM inv_produk p
WHERE p.adalah_induk_varian = TRUE AND p.deleted_at IS NULL;

/* ================================================================== */
/* PRODUK INDUK — inv_produk_varian_konfig (LINE REPLACE)              */
/* ================================================================== */

-- name: ListProdukInduk :many
-- Daftar induk (produk template) — paginated + search kode/nama.
SELECT
  p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_kategori_produk,
  p.id_inv_unit_ukur, p.id_inv_produk_induk, p.kunci_kombinasi,
  p.adalah_induk_varian, p.jejak_stok, p.barcode,
  p.harga_jual AS harga_jual, p.harga_biaya AS harga_biaya,
  p.stok_minimum, p.stok_maksimum, p.reorder_aktif, p.berat_gram,
  p.volume_cm3, p.keterangan, p.status, p.version, p.created_at, p.updated_at
FROM inv_produk p
WHERE p.adalah_induk_varian = TRUE AND p.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL OR p.kode_produk ILIKE '%' || sqlc.narg('search') || '%' OR p.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'       AND NOT sqlc.arg('sort_desc')::boolean THEN p.kode_produk END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'       AND sqlc.arg('sort_desc')::boolean     THEN p.kode_produk END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'       AND NOT sqlc.arg('sort_desc')::boolean THEN p.nama        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'       AND sqlc.arg('sort_desc')::boolean     THEN p.nama        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN p.created_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at' AND sqlc.arg('sort_desc')::boolean     THEN p.created_at  END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN p.updated_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at' AND sqlc.arg('sort_desc')::boolean     THEN p.updated_at  END DESC,
  p.kode_produk ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountProdukInduk :one
SELECT count(*)::int AS total
FROM inv_produk p
WHERE p.adalah_induk_varian = TRUE AND p.deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL OR p.kode_produk ILIKE '%' || sqlc.narg('search') || '%' OR p.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: ListAtributHidupByIds :many
-- Atribut hidup by ids — validasi REPLACE konfigurasi (absen = 404).
SELECT a.id FROM inv_atribut a
WHERE a.id = ANY(sqlc.arg('ids')::bigint[]) AND a.deleted_at IS NULL;

-- name: ListIdKonfigHidup :many
-- Id baris konfigurasi hidup satu induk — hitungan lama utk audit REPLACE.
SELECT k.id FROM inv_produk_varian_konfig k
WHERE k.id_inv_produk = sqlc.arg('id_induk') AND k.deleted_at IS NULL;

-- name: MuatKonfigurasiAtributInduk :many
-- Konfigurasi atribut induk (LINE hidup) — kodeAtribut disertakan, urut urutan.
SELECT
  k.id_inv_produk, k.id_inv_atribut, a.kode AS kode_atribut,
  a.nama AS nama_atribut, k.wajib, k.urutan
FROM inv_produk_varian_konfig k
INNER JOIN inv_atribut a ON a.id = k.id_inv_atribut
WHERE k.id_inv_produk = ANY(sqlc.arg('ids')::bigint[]) AND k.deleted_at IS NULL
ORDER BY k.urutan ASC;

-- name: InsertKonfigAtribut :exec
-- Sisip baris konfigurasi atribut induk (LINE — nilai item di service).
INSERT INTO inv_produk_varian_konfig (
  entity_id, id_inv_produk, id_inv_atribut, wajib, urutan
) VALUES (
  sqlc.arg('entity_id'), sqlc.arg('id_inv_produk'), sqlc.arg('id_inv_atribut'),
  sqlc.arg('wajib'), sqlc.arg('urutan')
);

-- name: SoftDeleteKonfigHidupByProduk :exec
-- Hapus lunak seluruh baris konfigurasi hidup satu induk (langkah REPLACE).
UPDATE inv_produk_varian_konfig SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id_inv_produk = sqlc.arg('id_induk') AND deleted_at IS NULL;

/* ================================================================== */
/* KATEGORI — inv_kategori_produk                                      */
/* ================================================================== */

-- name: ListKategori :many
-- Daftar kategori hidup + nama induk (self-join) + punya_mutasi (EXISTS
-- produk × gerakan — VERBATIM pilihKategoriColumns).
SELECT
  k.id, k.id_kategori_induk, induk.nama AS nama_induk, k.nama,
  k.metode_valuasi, k.sistem_valuasi, k.kebijakan_pelacakan,
  k.kebijakan_kedaluwarsa, k.status, k.version, k.created_at, k.updated_at,
  EXISTS (
    SELECT 1 FROM inv_produk p
    JOIN inv_gerakan_stok g ON g.id_inv_produk = p.id
    WHERE p.id_inv_kategori_produk = k.id
      AND p.deleted_at IS NULL AND g.deleted_at IS NULL
  ) AS punya_mutasi
FROM inv_kategori_produk k
LEFT JOIN inv_kategori_produk induk ON induk.id = k.id_kategori_induk
WHERE k.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR k.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR k.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND NOT sqlc.arg('sort_desc')::boolean THEN k.nama        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND sqlc.arg('sort_desc')::boolean     THEN k.nama        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN k.created_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND sqlc.arg('sort_desc')::boolean     THEN k.created_at  END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN k.updated_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND sqlc.arg('sort_desc')::boolean     THEN k.updated_at  END DESC,
  k.nama ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKategori :one
SELECT count(*)::int AS total
FROM inv_kategori_produk k
WHERE k.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR k.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR k.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatKategoriDetail :one
-- Detail kategori (join induk + punya-mutasi) — null bila absen.
SELECT
  k.id, k.id_kategori_induk, induk.nama AS nama_induk, k.nama,
  k.metode_valuasi, k.sistem_valuasi, k.kebijakan_pelacakan,
  k.kebijakan_kedaluwarsa, k.status, k.version, k.created_at, k.updated_at,
  EXISTS (
    SELECT 1 FROM inv_produk p
    JOIN inv_gerakan_stok g ON g.id_inv_produk = p.id
    WHERE p.id_inv_kategori_produk = k.id
      AND p.deleted_at IS NULL AND g.deleted_at IS NULL
  ) AS punya_mutasi
FROM inv_kategori_produk k
LEFT JOIN inv_kategori_produk induk ON induk.id = k.id_kategori_induk
WHERE k.id = sqlc.arg('id') AND k.deleted_at IS NULL;

-- name: MuatKategoriHidup :one
-- assertAda — baris penuh kategori hidup (404 INV-018 di wrapper).
SELECT
  k.id, k.id_kategori_induk, k.nama, k.metode_valuasi, k.sistem_valuasi,
  k.kebijakan_pelacakan, k.kebijakan_kedaluwarsa, k.status, k.version,
  k.created_at, k.updated_at
FROM inv_kategori_produk k
WHERE k.id = sqlc.arg('id') AND k.deleted_at IS NULL;

-- name: CariDupeNamaKategori :one
-- Nama dipakai kategori hidup lain? (partial unique hidup).
SELECT k.id FROM inv_kategori_produk k
WHERE k.nama = sqlc.arg('nama') AND k.deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR k.id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: AdaMutasiKategori :one
-- Punya mutasi gerakan? (via produk kategori ini — count VERBATIM adaMutasi).
SELECT count(*)::int AS n
FROM inv_gerakan_stok g
INNER JOIN inv_produk p ON p.id = g.id_inv_produk
WHERE p.id_inv_kategori_produk = sqlc.arg('id')
  AND g.deleted_at IS NULL AND p.deleted_at IS NULL;

-- name: HitungAnakKategori :one
SELECT count(*)::int AS n FROM inv_kategori_produk k
WHERE k.id_kategori_induk = sqlc.arg('id') AND k.deleted_at IS NULL;

-- name: HitungProdukKategori :one
SELECT count(*)::int AS n FROM inv_produk p
WHERE p.id_inv_kategori_produk = sqlc.arg('id') AND p.deleted_at IS NULL;

-- name: InsertKategori :one
INSERT INTO inv_kategori_produk (
  entity_id, nama, id_kategori_induk, metode_valuasi, sistem_valuasi,
  kebijakan_pelacakan, kebijakan_kedaluwarsa, status
) VALUES (
  sqlc.arg('entity_id'), sqlc.arg('nama'), sqlc.arg('id_kategori_induk'),
  sqlc.arg('metode_valuasi'), sqlc.arg('sistem_valuasi'),
  sqlc.arg('kebijakan_pelacakan'), sqlc.arg('kebijakan_kedaluwarsa'), sqlc.arg('status')
)
RETURNING
  id, id_kategori_induk, nama, metode_valuasi, sistem_valuasi,
  kebijakan_pelacakan, kebijakan_kedaluwarsa, status, version,
  created_at, updated_at;

-- name: UpdateKategoriVersiHidup :one
-- Optimistic locking STD-07 — WHERE id + hidup + version (409 INV-017).
UPDATE inv_kategori_produk SET
  nama = sqlc.arg('nama'),
  id_kategori_induk = sqlc.arg('id_kategori_induk'),
  metode_valuasi = sqlc.arg('metode_valuasi'),
  sistem_valuasi = sqlc.arg('sistem_valuasi'),
  kebijakan_pelacakan = sqlc.arg('kebijakan_pelacakan'),
  kebijakan_kedaluwarsa = sqlc.arg('kebijakan_kedaluwarsa'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING
  id, id_kategori_induk, nama, metode_valuasi, sistem_valuasi,
  kebijakan_pelacakan, kebijakan_kedaluwarsa, status, version,
  created_at, updated_at;

-- name: SoftDeleteKategori :exec
UPDATE inv_kategori_produk SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;

/* ================================================================== */
/* UNIT UKUR — inv_unit_ukur                                           */
/* ================================================================== */

-- name: ListUnit :many
SELECT
  u.id, u.kode, u.nama, u.kategori_uom, u.status, u.version,
  u.created_at, u.updated_at
FROM inv_unit_ukur u
WHERE u.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR u.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR u.kode ILIKE '%' || sqlc.narg('search') || '%' OR u.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'        AND NOT sqlc.arg('sort_desc')::boolean THEN u.kode        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'        AND sqlc.arg('sort_desc')::boolean     THEN u.kode        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND NOT sqlc.arg('sort_desc')::boolean THEN u.nama        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'nama'        AND sqlc.arg('sort_desc')::boolean     THEN u.nama        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN u.created_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND sqlc.arg('sort_desc')::boolean     THEN u.created_at  END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN u.updated_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND sqlc.arg('sort_desc')::boolean     THEN u.updated_at  END DESC,
  u.kode ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountUnit :one
SELECT count(*)::int AS total
FROM inv_unit_ukur u
WHERE u.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR u.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR u.kode ILIKE '%' || sqlc.narg('search') || '%' OR u.nama ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatUnitHidup :one
-- Unit hidup by id (assertAda / assertUnit konversi — label 404 di wrapper).
SELECT
  u.id, u.kode, u.nama, u.kategori_uom, u.status, u.version,
  u.created_at, u.updated_at
FROM inv_unit_ukur u
WHERE u.id = sqlc.arg('id') AND u.deleted_at IS NULL;

-- name: CariDupeKodeUnit :one
-- Kode unik GLOBAL (uq_inv_unit_ukur_kode TANPA deleted — verbatim sumber).
SELECT u.id FROM inv_unit_ukur u
WHERE u.kode = sqlc.arg('kode')
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR u.id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: HitungProdukUnit :one
SELECT count(*)::int AS n FROM inv_produk p
WHERE p.id_inv_unit_ukur = sqlc.arg('id') AND p.deleted_at IS NULL;

-- name: HitungGerakanUnit :one
SELECT count(*)::int AS n FROM inv_gerakan_stok g
WHERE g.id_inv_unit_ukur = sqlc.arg('id') AND g.deleted_at IS NULL;

-- name: HitungKonversiUnit :one
-- Konversi hidup yang menyentuh unit (dari ATAU ke — INV-002).
SELECT count(*)::int AS n FROM inv_unit_konversi c
WHERE c.deleted_at IS NULL AND (c.id_unit_dari = sqlc.arg('id') OR c.id_unit_ke = sqlc.arg('id'));

-- name: InsertUnit :one
INSERT INTO inv_unit_ukur (entity_id, kode, nama, kategori_uom, status)
VALUES (sqlc.arg('entity_id'), sqlc.arg('kode'), sqlc.arg('nama'),
        sqlc.arg('kategori_uom'), sqlc.arg('status'))
RETURNING
  id, kode, nama, kategori_uom, status, version,
  created_at, updated_at;

-- name: UpdateUnitVersiHidup :one
UPDATE inv_unit_ukur SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  kategori_uom = sqlc.arg('kategori_uom'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING
  id, kode, nama, kategori_uom, status, version,
  created_at, updated_at;

-- name: SoftDeleteUnit :exec
UPDATE inv_unit_ukur SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;

/* ================================================================== */
/* UNIT KONVERSI — inv_unit_konversi (patch 05)                        */
/* ================================================================== */

-- name: ListKonversi :many
SELECT
  c.id, c.id_unit_dari, dari.kode AS kode_unit_dari, dari.nama AS nama_unit_dari,
  c.id_unit_ke, ke.kode AS kode_unit_ke, ke.nama AS nama_unit_ke,
  c.faktor::text AS faktor, c.status, c.version, c.created_at, c.updated_at
FROM inv_unit_konversi c
INNER JOIN inv_unit_ukur dari ON dari.id = c.id_unit_dari
INNER JOIN inv_unit_ukur ke ON ke.id = c.id_unit_ke
WHERE c.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR c.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR
       dari.kode ILIKE '%' || sqlc.narg('search') || '%' OR dari.nama ILIKE '%' || sqlc.narg('search') || '%' OR
       ke.kode ILIKE '%' || sqlc.narg('search') || '%' OR ke.nama ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'dari'        AND NOT sqlc.arg('sort_desc')::boolean THEN dari.kode       END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'dari'        AND sqlc.arg('sort_desc')::boolean     THEN dari.kode       END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'ke'          AND NOT sqlc.arg('sort_desc')::boolean THEN ke.kode         END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'ke'          AND sqlc.arg('sort_desc')::boolean     THEN ke.kode         END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN c.created_at    END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND sqlc.arg('sort_desc')::boolean     THEN c.created_at    END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN c.updated_at    END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND sqlc.arg('sort_desc')::boolean     THEN c.updated_at    END DESC,
  dari.kode ASC, ke.kode ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKonversi :one
SELECT count(*)::int AS total
FROM inv_unit_konversi c
WHERE c.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR c.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR
       c.id_unit_dari IN (SELECT u.id FROM inv_unit_ukur u WHERE u.kode ILIKE '%' || sqlc.narg('search') || '%' OR u.nama ILIKE '%' || sqlc.narg('search') || '%') OR
       c.id_unit_ke IN (SELECT u.id FROM inv_unit_ukur u WHERE u.kode ILIKE '%' || sqlc.narg('search') || '%' OR u.nama ILIKE '%' || sqlc.narg('search') || '%'));

-- name: MuatKonversiRow :one
-- Konversi hidup by id + kedua unit ter-join — null bila absen.
SELECT
  c.id, c.id_unit_dari, dari.kode AS kode_unit_dari, dari.nama AS nama_unit_dari,
  c.id_unit_ke, ke.kode AS kode_unit_ke, ke.nama AS nama_unit_ke,
  c.faktor::text AS faktor, c.status, c.version, c.created_at, c.updated_at
FROM inv_unit_konversi c
INNER JOIN inv_unit_ukur dari ON dari.id = c.id_unit_dari
INNER JOIN inv_unit_ukur ke ON ke.id = c.id_unit_ke
WHERE c.id = sqlc.arg('id') AND c.deleted_at IS NULL;

-- name: CariPasanganTerpakai :one
-- Pasangan (dari→ke maupun balik ke→dari) sudah dipakai konversi hidup lain?
SELECT c.id FROM inv_unit_konversi c
WHERE c.deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR c.id <> sqlc.narg('kecuali_id'))
  AND ((c.id_unit_dari = sqlc.arg('id_dari') AND c.id_unit_ke = sqlc.arg('id_ke'))
       OR (c.id_unit_dari = sqlc.arg('id_ke') AND c.id_unit_ke = sqlc.arg('id_dari')))
LIMIT 1;

-- name: InsertKonversi :one
INSERT INTO inv_unit_konversi (entity_id, id_unit_dari, id_unit_ke, faktor, status)
VALUES (sqlc.arg('entity_id'), sqlc.arg('id_unit_dari'), sqlc.arg('id_unit_ke'),
        sqlc.arg('faktor'), sqlc.arg('status'))
RETURNING
  id, id_unit_dari, id_unit_ke, faktor::text AS faktor, status,
  version, created_at, updated_at;

-- name: UpdateKonversiVersiHidup :one
UPDATE inv_unit_konversi SET
  id_unit_dari = sqlc.arg('id_unit_dari'),
  id_unit_ke = sqlc.arg('id_unit_ke'),
  faktor = sqlc.arg('faktor'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING
  id, id_unit_dari, id_unit_ke, faktor::text AS faktor, status,
  version, created_at, updated_at;

-- name: SoftDeleteKonversi :exec
UPDATE inv_unit_konversi SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;

/* ================================================================== */
/* KEMASAN — inv_kemasan (patch 04)                                    */
/* ================================================================== */

-- name: ListKemasan :many
SELECT
  km.id, km.id_inv_produk, p.kode_produk AS kode_produk, p.nama AS nama_produk,
  km.kode, km.nama, km.barcode, km.id_inv_unit_ukur, u.kode AS kode_unit,
  km.qty_isi, km.status, km.version, km.created_at, km.updated_at
FROM inv_kemasan km
INNER JOIN inv_produk p ON p.id = km.id_inv_produk
INNER JOIN inv_unit_ukur u ON u.id = km.id_inv_unit_ukur
WHERE km.deleted_at IS NULL
  AND (sqlc.narg('id_produk')::bigint IS NULL OR km.id_inv_produk = sqlc.narg('id_produk'))
  AND (sqlc.narg('status')::text IS NULL OR km.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR
       km.kode ILIKE '%' || sqlc.narg('search') || '%' OR
       km.nama ILIKE '%' || sqlc.narg('search') || '%' OR
       km.barcode ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'        AND NOT sqlc.arg('sort_desc')::boolean THEN km.kode        END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'kode'        AND sqlc.arg('sort_desc')::boolean     THEN km.kode        END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN km.created_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'created_at'  AND sqlc.arg('sort_desc')::boolean     THEN km.created_at  END DESC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND NOT sqlc.arg('sort_desc')::boolean THEN km.updated_at  END ASC,
  CASE WHEN sqlc.arg('sort_field')::text = 'updated_at'  AND sqlc.arg('sort_desc')::boolean     THEN km.updated_at  END DESC,
  km.kode ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountKemasan :one
SELECT count(*)::int AS total
FROM inv_kemasan km
WHERE km.deleted_at IS NULL
  AND (sqlc.narg('id_produk')::bigint IS NULL OR km.id_inv_produk = sqlc.narg('id_produk'))
  AND (sqlc.narg('status')::text IS NULL OR km.status::text = sqlc.narg('status'))
  AND (sqlc.narg('search')::text IS NULL OR
       km.kode ILIKE '%' || sqlc.narg('search') || '%' OR
       km.nama ILIKE '%' || sqlc.narg('search') || '%' OR
       km.barcode ILIKE '%' || sqlc.narg('search') || '%');

-- name: MuatKemasanViewHidup :one
-- Detail kemasan (join referensi) — null bila tidak ada / terhapus.
SELECT
  km.id, km.id_inv_produk, p.kode_produk AS kode_produk, p.nama AS nama_produk,
  km.kode, km.nama, km.barcode, km.id_inv_unit_ukur, u.kode AS kode_unit,
  km.qty_isi, km.status, km.version, km.created_at, km.updated_at
FROM inv_kemasan km
INNER JOIN inv_produk p ON p.id = km.id_inv_produk
INNER JOIN inv_unit_ukur u ON u.id = km.id_inv_unit_ukur
WHERE km.id = sqlc.arg('id') AND km.deleted_at IS NULL;

-- name: CariBarcodeKemasanView :one
-- Lookup barcode scanner F15 — kemasan hidup + produk hidup + saldo produk.
SELECT
  km.id, km.id_inv_produk, p.kode_produk AS kode_produk, p.nama AS nama_produk,
  km.kode, km.nama, km.barcode, km.id_inv_unit_ukur, u.kode AS kode_unit,
  km.qty_isi, km.status, km.version, km.created_at, km.updated_at,
  p.tipe AS tipe_produk, p.id_inv_produk_induk AS id_induk_produk,
  p.id_inv_unit_ukur AS id_unit_produk, u.kode AS kode_unit_produk,
  p.harga_jual AS harga_jual,
  (
    SELECT COALESCE(SUM(s.qty_on_hand), 0)::int
    FROM inv_saldo_stok s WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
  ) AS saldo_on_hand
FROM inv_kemasan km
INNER JOIN inv_produk p ON p.id = km.id_inv_produk
INNER JOIN inv_unit_ukur u ON u.id = km.id_inv_unit_ukur
WHERE km.barcode = sqlc.arg('barcode') AND km.deleted_at IS NULL AND p.deleted_at IS NULL
LIMIT 1;

-- name: MuatKemasanHidup :one
-- assertKemasan — baris penuh kemasan hidup (404 INV-018 di wrapper).
SELECT
  km.id, km.id_inv_produk, km.kode, km.nama, km.barcode, km.id_inv_unit_ukur,
  km.qty_isi, km.status, km.version, km.created_at, km.updated_at
FROM inv_kemasan km
WHERE km.id = sqlc.arg('id') AND km.deleted_at IS NULL;

-- name: CariProdukHidupAda :one
-- assertProdukAda — referensi produk wajib hidup.
SELECT p.id FROM inv_produk p
WHERE p.id = sqlc.arg('id') AND p.deleted_at IS NULL;

-- name: CariDupeKodeKemasan :one
-- Kode kemasan unik GLOBAL (uq_inv_kemasan_kode TANPA deleted — ratifikasi
-- keputusan DB: pre-check meratakan inkonsistensi Nest).
SELECT km.id FROM inv_kemasan km
WHERE km.kode = sqlc.arg('kode')
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR km.id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: CariDupeBarcodeKemasan :one
-- Barcode unik di antara baris hidup (uq_inv_kemasan_barcode partial).
SELECT km.id FROM inv_kemasan km
WHERE km.barcode = sqlc.arg('barcode') AND km.deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR km.id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: InsertKemasan :one
INSERT INTO inv_kemasan (
  entity_id, id_inv_produk, kode, nama, barcode, id_inv_unit_ukur, qty_isi, status
) VALUES (
  sqlc.arg('entity_id'), sqlc.arg('id_inv_produk'), sqlc.arg('kode'), sqlc.arg('nama'),
  sqlc.arg('barcode'), sqlc.arg('id_inv_unit_ukur'), sqlc.arg('qty_isi'), sqlc.arg('status')
)
RETURNING
  id, id_inv_produk, kode, nama, barcode, id_inv_unit_ukur,
  qty_isi, status, version, created_at, updated_at;

-- name: UpdateKemasanVersiHidup :one
-- Optimistic locking STD-07 — returning ringkas {id} verbatim sumber
-- (null = kalah balapan → 409 INV-017 di service).
UPDATE inv_kemasan SET
  id_inv_produk = sqlc.arg('id_inv_produk'),
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  barcode = sqlc.arg('barcode'),
  id_inv_unit_ukur = sqlc.arg('id_inv_unit_ukur'),
  qty_isi = sqlc.arg('qty_isi'),
  status = sqlc.arg('status'),
  version = sqlc.arg('version_baru'),
  updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL AND version = sqlc.arg('versi_harap')
RETURNING id;

-- name: SoftDeleteKemasan :exec
UPDATE inv_kemasan SET deleted_at = sqlc.arg('deleted_at'), updated_at = sqlc.arg('updated_at')
WHERE id = sqlc.arg('id') AND deleted_at IS NULL;
