-- Query fitur STOK modul INVENTORY — padanan repositories/stok/*
-- NestJS (saldo.repository.ts): READMODEL `inv_saldo_stok` (baca — dibangun
-- recompute; soft-delete aman) + agregat ATP per produk. Join 4 alias PERSIS
-- sumber: lokasi_saldo_ref, gudang_saldo_ref, produk_saldo_ref, lot_saldo_ref.
-- Fungsi recompute TIDAK di file ini — milik fitur GERAKAN (repository
-- eksport RecomputeSaldoStok; satu-satunya jalur TRUNCATE sah di modul INV).
--
-- Disiplin: kolom EKSPLISIT (tanpa SELECT *); filter deleted_at IS NULL hanya
-- di inv_saldo_stok (persis where sumber — alias join master di-baca apa
-- adanya); `nilai_persediaan::float8` = padanan mapper Number(...) (numeric
-- PG → number). sort_col whitelist kanonik ('' = kode_produk ASC — persis
-- fallback asc(produkRef.kodeProduk)); TANPA tie-break id (persis sumber).

-- name: PageSaldoStok :many
-- SATU HALAMAN saldo stok: filter idLokasi/idProduk/idGudang (narg bigint),
-- only_below_min (`(qty_on_hand - qty_dipesan) < stok_minimum produk AND
-- stok_minimum > 0` — VERBATIM), search (ILIKE kode_produk/nama produk).
SELECT saldo.id,
       saldo.id_inv_lokasi_stok,
       saldo.id_inv_produk,
       saldo.id_inv_lot_serial,
       saldo.qty_on_hand,
       saldo.qty_dipesan,
       saldo.qty_tersedia,
       saldo.nilai_persediaan::float8 AS nilai_persediaan,
       saldo.updated_at,
       lokasi_saldo_ref.kode         AS kode_lokasi,
       lokasi_saldo_ref.nama         AS nama_lokasi,
       gudang_saldo_ref.kode         AS kode_gudang,
       produk_saldo_ref.kode_produk  AS kode_produk,
       produk_saldo_ref.nama         AS nama_produk,
       lot_saldo_ref.kode            AS kode_lot,
       lot_saldo_ref.tanggal_kedaluwarsa AS tanggal_kedaluwarsa
FROM inv_saldo_stok saldo
INNER JOIN inv_lokasi_stok lokasi_saldo_ref
        ON lokasi_saldo_ref.id = saldo.id_inv_lokasi_stok
LEFT JOIN inv_gudang gudang_saldo_ref
        ON gudang_saldo_ref.id = lokasi_saldo_ref.id_inv_gudang
INNER JOIN inv_produk produk_saldo_ref
        ON produk_saldo_ref.id = saldo.id_inv_produk
LEFT JOIN inv_lot_serial lot_saldo_ref
        ON lot_saldo_ref.id = saldo.id_inv_lot_serial
WHERE saldo.deleted_at IS NULL
  AND (sqlc.narg('id_lokasi')::bigint IS NULL
       OR saldo.id_inv_lokasi_stok = sqlc.narg('id_lokasi'))
  AND (sqlc.narg('id_produk')::bigint IS NULL
       OR saldo.id_inv_produk = sqlc.narg('id_produk'))
  AND (sqlc.narg('id_gudang')::bigint IS NULL
       OR lokasi_saldo_ref.id_inv_gudang = sqlc.narg('id_gudang'))
  AND (sqlc.arg('only_below_min')::boolean = FALSE
       OR ((saldo.qty_on_hand - saldo.qty_dipesan) < produk_saldo_ref.stok_minimum
           AND produk_saldo_ref.stok_minimum > 0))
  AND (sqlc.narg('search')::text IS NULL
       OR produk_saldo_ref.kode_produk ILIKE '%' || sqlc.narg('search')::text || '%'
       OR produk_saldo_ref.nama ILIKE '%' || sqlc.narg('search')::text || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN produk_saldo_ref.kode_produk END ASC,
  -- grup teks (kode) — CASE per tipe kolom (varchar/int/timestamptz tak
  -- boleh campur dalam satu CASE; grup non-match konstan NULL = tanpa efek)
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode_produk' AND NOT sqlc.arg('sort_desc')::boolean THEN produk_saldo_ref.kode_produk
    WHEN sqlc.arg('sort_col')::text = 'kode_lokasi' AND NOT sqlc.arg('sort_desc')::boolean THEN lokasi_saldo_ref.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode_produk' AND sqlc.arg('sort_desc')::boolean THEN produk_saldo_ref.kode_produk
    WHEN sqlc.arg('sort_col')::text = 'kode_lokasi' AND sqlc.arg('sort_desc')::boolean THEN lokasi_saldo_ref.kode
  END DESC NULLS FIRST,
  -- grup angka (qty — alias camelCase FE ikut dikenal, sortable header On-Hand)
  CASE
    WHEN sqlc.arg('sort_col')::text = 'qty_on_hand' AND NOT sqlc.arg('sort_desc')::boolean THEN saldo.qty_on_hand
    WHEN sqlc.arg('sort_col')::text = 'qtyOnHand'   AND NOT sqlc.arg('sort_desc')::boolean THEN saldo.qty_on_hand
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'qty_on_hand' AND sqlc.arg('sort_desc')::boolean THEN saldo.qty_on_hand
    WHEN sqlc.arg('sort_col')::text = 'qtyOnHand'   AND sqlc.arg('sort_desc')::boolean THEN saldo.qty_on_hand
  END DESC NULLS FIRST,
  -- grup waktu (created/updated)
  CASE
    WHEN sqlc.arg('sort_col')::text = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN saldo.updated_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt'  AND NOT sqlc.arg('sort_desc')::boolean THEN saldo.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt'  AND NOT sqlc.arg('sort_desc')::boolean THEN saldo.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN saldo.updated_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt'  AND sqlc.arg('sort_desc')::boolean THEN saldo.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt'  AND sqlc.arg('sort_desc')::boolean THEN saldo.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountSaldoStok :one
-- Total baris filter PageSaldoStok — join PERSIS hitungan sumber (lokasi +
-- produk + lot; TANPA gudang — kode_gudang hanya display di baris).
SELECT count(*)::int AS total
FROM inv_saldo_stok saldo
INNER JOIN inv_lokasi_stok lokasi_saldo_ref
        ON lokasi_saldo_ref.id = saldo.id_inv_lokasi_stok
INNER JOIN inv_produk produk_saldo_ref
        ON produk_saldo_ref.id = saldo.id_inv_produk
LEFT JOIN inv_lot_serial lot_saldo_ref
        ON lot_saldo_ref.id = saldo.id_inv_lot_serial
WHERE saldo.deleted_at IS NULL
  AND (sqlc.narg('id_lokasi')::bigint IS NULL
       OR saldo.id_inv_lokasi_stok = sqlc.narg('id_lokasi'))
  AND (sqlc.narg('id_produk')::bigint IS NULL
       OR saldo.id_inv_produk = sqlc.narg('id_produk'))
  AND (sqlc.narg('id_gudang')::bigint IS NULL
       OR lokasi_saldo_ref.id_inv_gudang = sqlc.narg('id_gudang'))
  AND (sqlc.arg('only_below_min')::boolean = FALSE
       OR ((saldo.qty_on_hand - saldo.qty_dipesan) < produk_saldo_ref.stok_minimum
           AND produk_saldo_ref.stok_minimum > 0))
  AND (sqlc.narg('search')::text IS NULL
       OR produk_saldo_ref.kode_produk ILIKE '%' || sqlc.narg('search')::text || '%'
       OR produk_saldo_ref.nama ILIKE '%' || sqlc.narg('search')::text || '%');

-- name: ListSaldoAtp :many
-- Agregat saldo per produk (on-hand/dipesan/tersedia dari READMODEL, hanya
-- baris hidup) — sumber petakanAtp; mode CFG-INV-13 dibaca service.
-- GROUP BY 5 kolom + ORDER kode_produk ASC (persis sumber).
SELECT produk.id,
       produk.kode_produk,
       produk.nama,
       produk.jejak_stok,
       produk.stok_minimum,
       COALESCE(SUM(saldo.qty_on_hand), 0)::int  AS on_hand,
       COALESCE(SUM(saldo.qty_dipesan), 0)::int  AS dipesan,
       COALESCE(SUM(saldo.qty_tersedia), 0)::int AS tersedia
FROM inv_produk produk
LEFT JOIN inv_saldo_stok saldo
       ON saldo.id_inv_produk = produk.id AND saldo.deleted_at IS NULL
WHERE produk.id = ANY(sqlc.arg('produk_ids')::bigint[])
  AND produk.deleted_at IS NULL
GROUP BY produk.id, produk.kode_produk, produk.nama, produk.jejak_stok,
         produk.stok_minimum
ORDER BY produk.kode_produk ASC;
