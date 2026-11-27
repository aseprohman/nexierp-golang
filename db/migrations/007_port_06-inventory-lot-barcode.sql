-- +goose Up
-- Porting 1:1 dari ddl/06-inventory-lot-barcode.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 06-inventory-lot-barcode.sql — Penghubung barcode produk ↔ lot/serial
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : fitur-modul-fullcycle Fase 2 — entry produk: barcode autocomplete
--            lot/serial + deteksi varian per kategori
-- Kartu    : docs/arsitektur-database-core-inv.md §10 (klasifikasi + D-36..D-38)
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- inv_lot_serial — kolom barcode (patch aditif; K-08: varchar bucket 50)
-- Lot/serial kini punya identitas barcode sendiri — dipindai pada entry produk
-- (autocomplete) & operasi gudang; resolver terpadu produk/kemasan/lot.
-- -----------------------------------------------------------------------------
ALTER TABLE inv_lot_serial ADD COLUMN IF NOT EXISTS barcode varchar(50);

COMMENT ON COLUMN inv_lot_serial.barcode IS
  'barcode lot/serial (opsional) — resolver barcode terpadu bersama produk & kemasan;'
  'unik di antara lot hidup (partial unique, boleh dipakai ulang setelah soft delete)';

-- Unique reusable (K-10): barcode lot boleh dipakai ulang setelah soft delete.
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_lot_serial_barcode
  ON inv_lot_serial (barcode) WHERE deleted_at IS NULL AND barcode IS NOT NULL;

-- Pencarian prefix utk autocomplete resolver (scan/type-ahead).
CREATE INDEX IF NOT EXISTS ix_inv_lot_serial_barcode
  ON inv_lot_serial (barcode) WHERE deleted_at IS NULL AND barcode IS NOT NULL;

-- PATCH 06-inventory-lot-barcode.sql selesai.
