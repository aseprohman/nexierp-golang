-- DASHBOARD INVENTORY (INV-F14) — padanan DashboardRepository NestJS
-- (repositories/dashboard/dashboard.repository.ts), agregat skalar + tren
-- harian di-salin VERBATIM semantiknya. Kolom EKSPLISIT (schema.sql mengandung
-- kolom porting yang tak ada live). Soft-delete mengikuti sumber (produk,
-- saldo, header, stok, penyesuaian, lot). Enum di-CAST ::text agar hasil
-- sqlc berupa string.

-- name: HitungSku :one
-- Total SKU hidup + yang berstatus AKTIF.
SELECT count(*)::int AS total,
       (count(*) FILTER (WHERE inv_produk.status = 'AKTIF'))::int AS aktif
FROM inv_produk
WHERE deleted_at IS NULL;

-- name: MuatTotalNilaiPersediaan :one
-- Total nilai persediaan (READMODEL saldo) — dipakai dashboard ringkasan
-- DAN penyebut KPI laporan (satu sumber).
SELECT COALESCE(SUM(inv_saldo_stok.nilai_persediaan), 0)::numeric AS total
FROM inv_saldo_stok
WHERE deleted_at IS NULL;

-- name: HitungGerakanSejak :one
-- Gerakan dibuat sejak `awal_hari` (00:00 lokal hari ini — dihitung service).
SELECT count(*)::int AS n
FROM inv_gerakan_header
WHERE deleted_at IS NULL
  AND created_at >= sqlc.arg('awal_hari')::timestamptz;

-- name: HitungGerakanTerbuka :one
-- Gerakan terbuka — status bukan SELESAI/BATAL.
SELECT count(*)::int AS n
FROM inv_gerakan_header
WHERE deleted_at IS NULL
  AND status NOT IN ('SELESAI', 'BATAL');

-- name: HitungPenyesuaianMenunggu :one
-- Penyesuaian stok menunggu persetujuan (SoD approval).
SELECT count(*)::int AS n
FROM inv_penyesuaian_stok
WHERE deleted_at IS NULL
  AND status = 'MENUNGGU_PERSETUJUAN';

-- name: HitungLotKedaluwarsaBersaldo :one
-- Lot kedaluwarsa (tanggal < now()) yang MASIH menahan saldo (belum
-- dimusnahkan) — EXISTS inv_saldo_stok verbatim.
SELECT count(*)::int AS n
FROM inv_lot_serial
WHERE deleted_at IS NULL
  AND tanggal_kedaluwarsa < now()
  AND EXISTS (
    SELECT 1 FROM inv_saldo_stok s
    WHERE s.id_inv_lot_serial = inv_lot_serial.id
      AND s.qty_on_hand > 0
      AND s.deleted_at IS NULL
  );

-- name: ListProdukBawahMinimum :many
-- Agregat saldo efektif per produk (on-hand − dipesan vs stok_minimum) —
-- sumber hitungBawahMinimum (domain).
SELECT inv_produk.id,
       inv_produk.stok_minimum AS minimum,
       inv_produk.reorder_aktif,
       COALESCE(SUM(inv_saldo_stok.qty_on_hand), 0)::int AS on_hand,
       COALESCE(SUM(inv_saldo_stok.qty_dipesan), 0)::int AS dipesan
FROM inv_produk
LEFT JOIN inv_saldo_stok
  ON inv_saldo_stok.id_inv_produk = inv_produk.id
 AND inv_saldo_stok.deleted_at IS NULL
WHERE inv_produk.deleted_at IS NULL
  AND inv_produk.stok_minimum > 0
GROUP BY inv_produk.id, inv_produk.stok_minimum, inv_produk.reorder_aktif;

-- name: ListTrenHarian :many
-- Tren gerakan SELESAI per hari — masuk (PENERIMAAN) vs keluar
-- (PENGIRIMAN/SCRAP/PRODUKSI); awal = 00:00 hari pertama (dihitung
-- service); batas atas = now() saat query (verbatim).
SELECT to_char(inv_gerakan_stok.tanggal_selesai::date, 'YYYY-MM-DD') AS tanggal,
       (count(*) FILTER (WHERE inv_gerakan_header.jenis = 'PENERIMAAN'))::int AS masuk,
       (count(*) FILTER (WHERE inv_gerakan_header.jenis IN ('PENGIRIMAN', 'SCRAP', 'PRODUKSI')))::int AS keluar,
       COALESCE(SUM(COALESCE(inv_gerakan_stok.nilai_persatuan, 0) * inv_gerakan_stok.qty_selesai)
         FILTER (WHERE inv_gerakan_header.jenis = 'PENERIMAAN'), 0)::numeric AS nilai_masuk,
       COALESCE(SUM(COALESCE(inv_gerakan_stok.nilai_persatuan, 0) * inv_gerakan_stok.qty_selesai)
         FILTER (WHERE inv_gerakan_header.jenis IN ('PENGIRIMAN', 'SCRAP', 'PRODUKSI')), 0)::numeric AS nilai_keluar
FROM inv_gerakan_stok
INNER JOIN inv_gerakan_header
  ON inv_gerakan_header.id = inv_gerakan_stok.id_inv_gerakan_header
WHERE inv_gerakan_stok.deleted_at IS NULL
  AND inv_gerakan_header.status = 'SELESAI'
  AND inv_gerakan_stok.tanggal_selesai >= sqlc.arg('awal')::timestamptz
  AND inv_gerakan_stok.tanggal_selesai <= sqlc.arg('sekarang')::timestamptz
GROUP BY inv_gerakan_stok.tanggal_selesai::date
ORDER BY inv_gerakan_stok.tanggal_selesai::date;
