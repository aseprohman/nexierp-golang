-- =============================================================================
-- ddl/32-purchasing-harga-bertingkat.sql — REVISI-3 harga pemasok (2026-11-07)
-- =============================================================================
-- Harga bertingkat per qty untuk satu pemasok (tier `qty_minimal` multi-baris,
-- ala Odoo `product.supplierinfo.min_qty`) — keputusan pemilik 2026-11-07.
--
-- KARTU ARSITEKTUR (arsitektur-database):
--   core_pemasok_harga | [LINE] (atribut master CORE `core_pemasok`) |
--   pemilik: CORE, dikelola fitur PUR-F01 | PK `id bigint IDENTITY` +
--   `entity_id uuid` Tier A (unique global) | FK: pemasok CASCADE,
--   produk/unit RESTRICT | kunci produksi: EXCLUDE gist
--   `ex_core_pemasok_harga_overlap` (pemasok + produk + tier qty_minimal +
--   daterange periode) WHERE deleted_at IS NULL — duplikat tier sama pada
--   periode tumpang-tindih ditolak; tier berbeda sah berdampingan |
--   snapshot: harga/diskon/mata_uang beku per baris kontrak (PO menyalin
--   harga ke barisnya) | seed: mengalir dari seed master pemasok (tanpa
--   seed baru; constraint lebih longgar = data live tetap valid).
--
-- PERUBAHAN: constraint `ex_core_pemasok_harga_overlap` diperluas dengan
-- `qty_minimal WITH =`. Sebelumnya satu harga per pemasok+produk-periode;
-- kini tier qty berbeda (mis. qty_minimal 1 → 10rb, qty_minimal 10 → 9rb)
-- sah dalam satu periode. Seleksi tier tetap PUR-BR06 via `pilihHargaKontrak`
-- (sudah tier-aware: WHERE qty >= qty_minimal, ORDER urutan_prioritas → harga).
--
-- Idempoten: guard mendeteksi bentuk constraint (kolom qty_minimal di conkey);
-- bentuk lama di-drop lalu dibentuk ulang, bentuk baru dilewati. Aman re-run.
-- Instal segar: ddl/25-purchasing.sql (§2, blok EXCLUDE revisi-3) sudah
-- membentuk constraint tier — patch ini no-op di sana.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist; -- opclass gist int4 utk qty_minimal

DO $$
DECLARE
  v_tier_sudah boolean;
BEGIN
  -- Bentuk baru = constraint berisi kolom qty_minimal; bentuk lama = drop.
  SELECT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
    WHERE c.conname = 'ex_core_pemasok_harga_overlap'
      AND c.conrelid = 'core_pemasok_harga'::regclass
      AND a.attname = 'qty_minimal'
  ) INTO v_tier_sudah;

  IF v_tier_sudah THEN
    RAISE NOTICE 'ex_core_pemasok_harga_overlap sudah bentuk tier (qty_minimal) — lewati.';
    RETURN;
  END IF;

  ALTER TABLE core_pemasok_harga
    DROP CONSTRAINT IF EXISTS ex_core_pemasok_harga_overlap;

  ALTER TABLE core_pemasok_harga ADD CONSTRAINT ex_core_pemasok_harga_overlap
    EXCLUDE USING gist (
      id_core_pemasok WITH =,
      id_inv_produk   WITH =,
      qty_minimal     WITH =,
      daterange(tanggal_mulai, COALESCE(tanggal_selesai, 'infinity'::date), '[)') WITH &&
    ) WHERE (deleted_at IS NULL);

  RAISE NOTICE 'ex_core_pemasok_harga_overlap diganti bentuk tier: pemasok+produk+qty_minimal+periode.';
END $$;
