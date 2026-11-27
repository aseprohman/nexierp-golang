-- LAPORAN PERSEDIAAN (INV-F14 + patch 04) — padanan LaporanRepository
-- NestJS (repositories/laporan/laporan.repository.ts): kartu stok, expiring
-- (FEFO), lapisan biaya FIFO, KPI §2.3, traceability, nilai persediaan,
-- backlog, reorder. Semantik where/urutan DI-SALIN VERBATIM (termasuk
-- quirk: kartu stok default urut TANPA tiebreak; saldo awal `<=` awal
-- inklusif; RCV `+ INTERVAL '1 day'` vs DLV `::date` asimetri). Kolom
-- EKSPLISIT (schema.sql mengandung kolom porting yang tak ada live).

-- ===========================================================================
-- KARTU STOK — mutasi periode / total / saldo awal / kode lot
-- ===========================================================================

-- name: ListMutasiKartuStok :many
-- Baris mutasi kartu stok satu halaman (JOIN header + dua lokasi) — gerakan
-- SELESAI hidup yang menyentuh lokasi dengan produk tsb (sumber ATAU tujuan)
-- pada rentang tanggal_selesai. Whitelist sort: tanggal | nomor; tanpa sort
-- → tanggal_selesai ASC TANPA tiebreak (verbatim drizzle).
SELECT inv_gerakan_stok.tanggal_selesai,
       inv_gerakan_header.tanggal_jadwal,
       inv_gerakan_header.nomor_dokumen,
       inv_gerakan_header.jenis::text AS jenis,
       inv_gerakan_stok.id_inv_lot_serial,
       inv_gerakan_stok.qty_selesai,
       inv_gerakan_stok.nilai_persatuan,
       inv_gerakan_stok.id_lokasi_tujuan,
       sumber.jenis::text AS jenis_sumber_lokasi,
       kartu_tujuan.jenis::text AS jenis_tujuan_lokasi
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
INNER JOIN inv_lokasi_stok sumber
  ON sumber.id = COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber)
INNER JOIN inv_lokasi_stok kartu_tujuan
  ON kartu_tujuan.id = COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan)
WHERE inv_gerakan_stok.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_stok.tanggal_selesai >= sqlc.arg('awal')::timestamptz
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('akhir')::timestamptz
  AND (sqlc.narg('id_lokasi')::bigint IS NULL
    OR COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber) = sqlc.narg('id_lokasi')::bigint
    OR COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan) = sqlc.narg('id_lokasi')::bigint)
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_stok.tanggal_selesai END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'nomor' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_header.nomor_dokumen END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal' AND sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_stok.tanggal_selesai END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = 'nomor' AND sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_header.nomor_dokumen END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN inv_gerakan_stok.tanggal_selesai END ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: HitungMutasiKartuStok :one
-- Total baris mutasi kartu stok pada filter yang sama.
SELECT count(*)::int AS total
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
INNER JOIN inv_lokasi_stok sumber
  ON sumber.id = COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber)
INNER JOIN inv_lokasi_stok kartu_tujuan
  ON kartu_tujuan.id = COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan)
WHERE inv_gerakan_stok.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_stok.tanggal_selesai >= sqlc.arg('awal')::timestamptz
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('akhir')::timestamptz
  AND (sqlc.narg('id_lokasi')::bigint IS NULL
    OR COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber) = sqlc.narg('id_lokasi')::bigint
    OR COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan) = sqlc.narg('id_lokasi')::bigint);

-- name: MuatSaldoAwalKartuStok :one
-- Saldo awal periode = Σ gerakan SELESAI sebelum/sama tanggalDari (`<=`
-- inklusif — verbatim): masuk di tujuan internal, keluar di sumber internal.
SELECT COALESCE(SUM(CASE
  WHEN kartu_tujuan.jenis = 'INTERNAL' THEN inv_gerakan_stok.qty_selesai
  WHEN sumber.jenis = 'INTERNAL' THEN -inv_gerakan_stok.qty_selesai
  ELSE 0 END), 0)::int AS saldo
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
INNER JOIN inv_lokasi_stok sumber
  ON sumber.id = COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber)
INNER JOIN inv_lokasi_stok kartu_tujuan
  ON kartu_tujuan.id = COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan)
WHERE inv_gerakan_stok.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('awal')::timestamptz
  AND (sqlc.narg('id_lokasi')::bigint IS NULL
    OR COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber) = sqlc.narg('id_lokasi')::bigint
    OR COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan) = sqlc.narg('id_lokasi')::bigint);

-- name: ListKodeLot :many
-- Kode lot by id set (pra-muat utk mapper kartu stok sinkron).
SELECT inv_lot_serial.id, inv_lot_serial.kode
FROM inv_lot_serial
WHERE inv_lot_serial.id = ANY(sqlc.arg('lot_ids')::bigint[]);

-- ===========================================================================
-- EXPIRING (FEFO) — ≤ CFG-INV-12 hari
-- ===========================================================================

-- name: ListLotExpiring :many
-- Lot mendekati/lewat kedaluwarsa — batas = sekarang + ambang hari
-- CFG-INV-12 (dihitung service); filter gudang; qty & nilai dari READMODEL
-- saldo. GROUP BY ikut gudang (verbatim — lot multi-gudang terpisah baris).
SELECT inv_lot_serial.id,
       inv_lot_serial.kode,
       inv_lot_serial.tanggal_kedaluwarsa,
       inv_lot_serial.status::text AS status,
       inv_lot_serial.id_inv_produk,
       inv_produk.kode_produk,
       inv_produk.nama AS nama_produk,
       COALESCE(SUM(inv_saldo_stok.qty_on_hand), 0)::int AS qty_on_hand,
       COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0)::numeric AS nilai_persediaan,
       inv_gudang.kode AS kode_gudang
FROM inv_lot_serial
INNER JOIN inv_produk ON inv_produk.id = inv_lot_serial.id_inv_produk
LEFT JOIN inv_saldo_stok
  ON inv_saldo_stok.id_inv_lot_serial = inv_lot_serial.id
 AND inv_saldo_stok.deleted_at IS NULL
LEFT JOIN inv_lokasi_stok ON inv_lokasi_stok.id = inv_saldo_stok.id_inv_lokasi_stok
LEFT JOIN inv_gudang ON inv_gudang.id = inv_lokasi_stok.id_inv_gudang
WHERE inv_lot_serial.deleted_at IS NULL
  AND inv_produk.deleted_at IS NULL
  AND inv_lot_serial.tanggal_kedaluwarsa <= sqlc.arg('batas')::timestamptz
  AND (sqlc.narg('id_gudang')::bigint IS NULL
    OR inv_lokasi_stok.id_inv_gudang = sqlc.narg('id_gudang')::bigint)
GROUP BY inv_lot_serial.id, inv_lot_serial.kode, inv_lot_serial.tanggal_kedaluwarsa,
         inv_lot_serial.status, inv_produk.kode_produk, inv_produk.nama, inv_gudang.kode
ORDER BY inv_lot_serial.tanggal_kedaluwarsa ASC;

-- ===========================================================================
-- LAPISAN BIAYA FIFO (patch 04 — D-27)
-- ===========================================================================

-- name: ListLapisanBiaya :many
-- Lapisan biaya FIFO sisa per produk (qty_terpakai < qty_masuk), urut
-- tertua dulu. Whitelist sort: tanggal_masuk | tanggalMasuk | id; tanpa
-- sort → tanggal_masuk ASC, id ASC (verbatim).
SELECT inv_lapisan_biaya.id,
       inv_lapisan_biaya.id_inv_produk,
       inv_produk.kode_produk,
       inv_lot_serial.kode AS kode_lot,
       inv_lapisan_biaya.nomor_dokumen_masuk,
       inv_lapisan_biaya.tanggal_masuk,
       inv_lapisan_biaya.qty_masuk,
       inv_lapisan_biaya.qty_terpakai,
       inv_lapisan_biaya.biaya_persatuan
FROM inv_lapisan_biaya
INNER JOIN inv_produk ON inv_produk.id = inv_lapisan_biaya.id_inv_produk
LEFT JOIN inv_lot_serial ON inv_lot_serial.id = inv_lapisan_biaya.id_inv_lot_serial
WHERE inv_lapisan_biaya.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND inv_lapisan_biaya.deleted_at IS NULL
  AND inv_lapisan_biaya.qty_terpakai < inv_lapisan_biaya.qty_masuk
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal_masuk' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_lapisan_biaya.tanggal_masuk END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'id' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_lapisan_biaya.id END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal_masuk' AND sqlc.arg('sort_desc')::boolean
    THEN inv_lapisan_biaya.tanggal_masuk END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = 'id' AND sqlc.arg('sort_desc')::boolean
    THEN inv_lapisan_biaya.id END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN inv_lapisan_biaya.tanggal_masuk END ASC,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN inv_lapisan_biaya.id END ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: HitungLapisanBiaya :one
-- Total lapisan biaya sisa pada filter yang sama.
SELECT count(*)::int AS total
FROM inv_lapisan_biaya
WHERE inv_lapisan_biaya.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND inv_lapisan_biaya.deleted_at IS NULL
  AND inv_lapisan_biaya.qty_terpakai < inv_lapisan_biaya.qty_masuk;

-- ===========================================================================
-- KPI §2.3 (patch 04) — empat agregat terpisah
-- ===========================================================================

-- name: MuatSelisihPenyesuaianDisetujui :one
-- Pembilang penyesuaian DISETUJUI — Σ|qty_selisih × biaya_satuan| pada
-- periode (dipakai AKURASI_STOK & PENYESUAIAN_TAK_TERJELASKAN).
SELECT COALESCE(SUM(ABS(inv_penyesuaian_stok_items.qty_selisih
      * COALESCE(inv_penyesuaian_stok_items.biaya_satuan, 0))), 0)::numeric AS selisih_nilai
FROM inv_penyesuaian_stok_items
INNER JOIN inv_penyesuaian_stok
  ON inv_penyesuaian_stok.id = inv_penyesuaian_stok_items.id_inv_penyesuaian_stok
WHERE inv_penyesuaian_stok.status = 'DISETUJUI'
  AND inv_penyesuaian_stok.deleted_at IS NULL
  AND inv_penyesuaian_stok_items.deleted_at IS NULL
  AND inv_penyesuaian_stok.tanggal_dokumen >= sqlc.arg('awal')::timestamptz
  AND inv_penyesuaian_stok.tanggal_dokumen <= sqlc.arg('akhir')::timestamptz;

-- name: MuatKetepatanPenerimaan :one
-- Ketepatan penerimaan — RCV SELESAI, selesai ≤ jadwal+1 hari (timestamp +
-- INTERVAL) vs total periode — asimetri vs DLV ::date adalah verbatim.
SELECT (count(*))::int AS total,
       (count(*) FILTER (WHERE inv_gerakan_stok.tanggal_selesai
           <= inv_gerakan_header.tanggal_jadwal + INTERVAL '1 day'))::int AS tepat
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
WHERE inv_gerakan_header.jenis = 'PENERIMAAN'
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_stok.tanggal_selesai >= sqlc.arg('awal')::timestamptz
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('akhir')::timestamptz;

-- name: MuatKetepatanPengiriman :one
-- Ketepatan pengiriman — DLV SELESAI pada hari jadwalnya (::date vs ::date)
-- vs total periode.
SELECT (count(*))::int AS total,
       (count(*) FILTER (WHERE inv_gerakan_stok.tanggal_selesai::date
           <= inv_gerakan_header.tanggal_jadwal::date))::int AS tepat
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
WHERE inv_gerakan_header.jenis = 'PENGIRIMAN'
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_stok.tanggal_selesai >= sqlc.arg('awal')::timestamptz
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('akhir')::timestamptz;

-- ===========================================================================
-- TRACEABILITY (patch 04)
-- ===========================================================================

-- name: ListTraceability :many
-- Page traceability — jejak naik-turun produk/lot (alias sumber/tujuan
-- lokasi; LEFT JOIN lot). Lot menang atas produk. Rentang opsional (wajib
-- KEDUANYA bila ada — narg). Whitelist sort: tanggal | nomor; tanpa sort →
-- tanggal_selesai ASC, id ASC (verbatim).
SELECT inv_gerakan_stok.tanggal_selesai,
       inv_gerakan_header.tanggal_jadwal,
       inv_gerakan_header.nomor_dokumen,
       inv_gerakan_header.jenis::text AS jenis,
       inv_gerakan_header.jenis_sumber,
       inv_gerakan_stok.qty_selesai,
       inv_gerakan_stok.nilai_persatuan,
       inv_gerakan_stok.entity_id_sumber,
       trc_sumber.jenis::text AS jenis_sumber_lokasi,
       trc_tujuan_ref.jenis::text AS jenis_tujuan_lokasi,
       trc_sumber.kode AS kode_sumber,
       trc_sumber.nama AS nama_sumber,
       trc_tujuan_ref.kode AS kode_tujuan,
       trc_tujuan_ref.nama AS nama_tujuan,
       inv_lot_serial.kode AS kode_lot
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
INNER JOIN inv_lokasi_stok trc_sumber
  ON trc_sumber.id = COALESCE(inv_gerakan_stok.id_lokasi_sumber, inv_gerakan_header.id_lokasi_sumber)
INNER JOIN inv_lokasi_stok trc_tujuan_ref
  ON trc_tujuan_ref.id = COALESCE(inv_gerakan_stok.id_lokasi_tujuan, inv_gerakan_header.id_lokasi_tujuan)
LEFT JOIN inv_lot_serial ON inv_lot_serial.id = inv_gerakan_stok.id_inv_lot_serial
WHERE inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND ((sqlc.narg('id_lot')::bigint IS NOT NULL
        AND inv_gerakan_stok.id_inv_lot_serial = sqlc.narg('id_lot')::bigint)
    OR (sqlc.narg('id_lot')::bigint IS NULL
        AND inv_gerakan_stok.id_inv_produk = sqlc.narg('id_produk')::bigint))
  AND (sqlc.narg('awal')::timestamptz IS NULL
    OR inv_gerakan_stok.tanggal_selesai >= sqlc.narg('awal')::timestamptz)
  AND (sqlc.narg('akhir')::timestamptz IS NULL
    OR inv_gerakan_stok.tanggal_selesai <= sqlc.narg('akhir')::timestamptz)
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_stok.tanggal_selesai END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'nomor' AND NOT sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_header.nomor_dokumen END ASC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = 'tanggal' AND sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_stok.tanggal_selesai END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = 'nomor' AND sqlc.arg('sort_desc')::boolean
    THEN inv_gerakan_header.nomor_dokumen END DESC NULLS FIRST,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN inv_gerakan_stok.tanggal_selesai END ASC,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN inv_gerakan_stok.id END ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: HitungTraceability :one
-- Total baris traceability pada filter yang sama (JOIN header saja — verbatim).
SELECT count(*)::int AS total
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
WHERE inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.deleted_at IS NULL
  AND ((sqlc.narg('id_lot')::bigint IS NOT NULL
        AND inv_gerakan_stok.id_inv_lot_serial = sqlc.narg('id_lot')::bigint)
    OR (sqlc.narg('id_lot')::bigint IS NULL
        AND inv_gerakan_stok.id_inv_produk = sqlc.narg('id_produk')::bigint))
  AND (sqlc.narg('awal')::timestamptz IS NULL
    OR inv_gerakan_stok.tanggal_selesai >= sqlc.narg('awal')::timestamptz)
  AND (sqlc.narg('akhir')::timestamptz IS NULL
    OR inv_gerakan_stok.tanggal_selesai <= sqlc.narg('akhir')::timestamptz);

-- ===========================================================================
-- NILAI PERSEDIAAN / BACKLOG / REORDER
-- ===========================================================================

-- name: AgregatNilaiPerGudang :many
-- Nilai persediaan per GUDANG (query kelompok) — urut nilai terbesar.
SELECT COALESCE(inv_gudang.nama, '(Tanpa Gudang)') AS kelompok,
       (count(DISTINCT inv_saldo_stok.id_inv_produk))::int AS jumlah_sku,
       COALESCE(SUM(inv_saldo_stok.qty_on_hand), 0)::int AS total_qty,
       COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0)::numeric AS total_nilai
FROM inv_saldo_stok
INNER JOIN inv_lokasi_stok ON inv_lokasi_stok.id = inv_saldo_stok.id_inv_lokasi_stok
LEFT JOIN inv_gudang ON inv_gudang.id = inv_lokasi_stok.id_inv_gudang
WHERE inv_saldo_stok.deleted_at IS NULL
  AND inv_lokasi_stok.deleted_at IS NULL
GROUP BY COALESCE(inv_gudang.nama, '(Tanpa Gudang)')
ORDER BY COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0) DESC;

-- name: AgregatNilaiPerKategori :many
-- Nilai persediaan per KATEGORI produk (query kelompok) — urut nilai terbesar.
SELECT inv_kategori_produk.nama AS kelompok,
       (count(DISTINCT inv_saldo_stok.id_inv_produk))::int AS jumlah_sku,
       COALESCE(SUM(inv_saldo_stok.qty_on_hand), 0)::int AS total_qty,
       COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0)::numeric AS total_nilai
FROM inv_saldo_stok
INNER JOIN inv_produk ON inv_produk.id = inv_saldo_stok.id_inv_produk
INNER JOIN inv_kategori_produk ON inv_kategori_produk.id = inv_produk.id_inv_kategori_produk
WHERE inv_saldo_stok.deleted_at IS NULL
  AND inv_produk.deleted_at IS NULL
  AND inv_kategori_produk.deleted_at IS NULL
GROUP BY inv_kategori_produk.nama
ORDER BY COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0) DESC;

-- name: AgregatBacklog :many
-- Backlog picking — gerakan terbuka (bukan SELESAI/BATAL) per jenis×status.
SELECT inv_gerakan_header.jenis::text AS jenis,
       inv_gerakan_header.status::text AS status,
       (count(*))::int AS jumlah,
       COALESCE(SUM(inv_gerakan_stok.qty_diminta - inv_gerakan_stok.qty_selesai), 0)::int AS total_qty
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
WHERE inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_header.status NOT IN ('SELESAI', 'BATAL')
GROUP BY inv_gerakan_header.jenis, inv_gerakan_header.status
ORDER BY inv_gerakan_header.jenis ASC, inv_gerakan_header.status ASC;

-- name: ListReorder :many
-- Daftar reorder — produk reorder_aktif dengan saldo efektif < minimum
-- (filter efektif diputuskan domain/service — verbatim loop).
SELECT inv_produk.id,
       inv_produk.kode_produk,
       inv_produk.nama,
       inv_produk.stok_minimum,
       inv_produk.stok_maksimum,
       inv_produk.reorder_aktif,
       COALESCE(SUM(inv_saldo_stok.qty_on_hand), 0)::int AS on_hand,
       COALESCE(SUM(inv_saldo_stok.qty_dipesan), 0)::int AS dipesan
FROM inv_produk
LEFT JOIN inv_saldo_stok
  ON inv_saldo_stok.id_inv_produk = inv_produk.id
 AND inv_saldo_stok.deleted_at IS NULL
WHERE inv_produk.deleted_at IS NULL
  AND inv_produk.reorder_aktif = true
  AND inv_produk.stok_minimum > 0
GROUP BY inv_produk.id
ORDER BY inv_produk.kode_produk ASC;
