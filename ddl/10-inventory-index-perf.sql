-- =============================================================================
-- PATCH DDL 10-inventory-index-perf.sql — 3 index perf master data inv
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : audit perf inv (disetujui user): subquery saldo per lot
--            (lot.service.ts) filter id_inv_lot_serial tanpa index;
--            EXISTS/count per baris di inv_gerakan_stok (kategori.service.ts,
--            produk.service.ts, unit.service.ts) hanya punya index header +
--            uq idempoten. Selaras drizzle schema/inv.ts (invSaldoStok,
--            invGerakanStok).
-- Pola     : 3 btree index sekunder non-unique, IF NOT EXISTS (idempoten).
--            Tabel dev kecil — CREATE INDEX biasa cukup (tanpa CONCURRENTLY).
-- Idempoten: aman dijalankan berulang (IF NOT EXISTS).
-- =============================================================================

-- 1) inv_saldo_stok — subquery scalar saldo per lot (lot.service.ts:55-58,94-97)
CREATE INDEX IF NOT EXISTS ix_inv_saldo_lot
  ON inv_saldo_stok (id_inv_lot_serial);

-- 2) inv_gerakan_stok — EXISTS per baris kategori/produk + count by produk
--    (kategori.service.ts:76-81,106-111; produk.service.ts:638-641)
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_stok_produk
  ON inv_gerakan_stok (id_inv_produk);

-- 3) inv_gerakan_stok — count referensi unit ukur (unit.service.ts:199-202)
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_stok_unit_ukur
  ON inv_gerakan_stok (id_inv_unit_ukur);
