-- =============================================================================
-- PATCH DDL 76-sls-pricelist-aturan-sederhana.sql — SLS: `sls_pricelist_
-- aturan` sederhana (harga dan/atau diskon, tanpa target kategori)
-- =============================================================================
-- Domain   : NEXIERP · Modul SALES (SLS) — pricelist aturan [LINE] F02,
--            SLS-BR06. Bentuk live DIUBAH PEMILIK LANGSUNG di DB; patch ini
--            MEMFORMALKAN transformasi bentuk `ddl/28-sls.sql` → bentuk live
--            (live DB = acuan).ddl/28-sls.sql TIDAK disentuh (historis).
-- Kartu    :
--   sls_pricelist_aturan | [LINE] | SLS | perubahan:
--     - DROP kolom `jenis_target` (enum_jenis_target_aturan_sls) — target
--       kategori DIHAPUS; target kini hanya SEMUA/PRODUK dari kekosongan
--       `id_inv_produk` (NULL = semua produk; terisi = khusus produk itu).
--       Tipe enum_jenis_target_aturan_sls DIPERTAHANKAN — masih dipakai
--       `sls_promosi_aturan.jenis_target` (fitur promosi milik sendiri).
--     - DROP kolom `id_inv_kategori_produk` (+ FK fk_sls_pricelist_aturan_
--       kategori otomatis) + DROP INDEX uq_sls_pricelist_aturan_kategori.
--     - DROP kolom `jenis_aturan` (enum_jenis_aturan_harga_sls) — harga dan
--       diskon BOLEH berbarengan pada satu baris (xor lama dihapus); baris
--       tanpa keduanya = TIDAK VALID (SLS-BR06) — ditegakkan app (zod
--       refine + service), DB tidak men-CHECK. Tipe enum_jenis_aturan_
--       harga_sls di-DROP (terbukti tanpa pemakai pg_attribute).
--     - RENAME kolom `harga_tetap` → `harga` numeric(18,4) NULL.
--     - ADD kolom `min_qty_diskon` integer NOT NULL DEFAULT 1 — ambang qty
--       khusus diskon: harga berlaku utk qty ≥ min_qty, diskon berlaku utk
--       qty ≥ min_qty_diskon.
--     - DROP CHECK ck_sls_pricelist_aturan_target & ck_sls_pricelist_aturan_
--       nilai (pemegang semantik lama); ck_min_qty & ck_diskon bertahan.
--     - Index/index uq bentuk live: uq_sls_pricelist_aturan_produk
--       (pricelist, produk, min_qty) partial produk NOT NULL + hidup;
--       ix_sls_pricelist_aturan_pricelist partial hidup — dinyatakan ulang
--       IF NOT EXISTS agar patch aman dari baseline mana pun.
--   Kemenangan aturan (SLS-BR06, dipakai resolusi harga): tingkat pricelist
--   (PELANGGAN→GRUP→UMUM), lalu target PRODUK di atas SEMUA, lalu ambang
--   terbesar yang terpenuhi (min_qty utk harga / min_qty_diskon utk diskon),
--   lalu prioritas, tie-break id terkecil. Harga kosong pada baris pemenang
--   → fallback harga jual produk; diskon pemenang tetap dipakai.
-- Idempoten: DROP IF EXISTS / ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT
--            EXISTS / DO-block guard rename & drop tipe.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/76-sls-pricelist-aturan-sederhana.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Konsistensi bentuk lama → live (urutan: index → constraint → kolom)
-- -----------------------------------------------------------------------------

-- 1a. Index uq target KATEGORI dihapus (semantik kategori pensiun).
DROP INDEX IF EXISTS uq_sls_pricelist_aturan_kategori;

-- 1b. CHECK pemegang semantik lama dihapus lebih dulu (menahan kolom lama).
ALTER TABLE sls_pricelist_aturan
  DROP CONSTRAINT IF EXISTS ck_sls_pricelist_aturan_nilai;
ALTER TABLE sls_pricelist_aturan
  DROP CONSTRAINT IF EXISTS ck_sls_pricelist_aturan_target;

-- 1c. Kolom target/kategori + jenis aturan lama dihapus. FK fk_sls_pricelist_
--     _aturan_kategori ikut ter-drop bersama kolomnya (otomatis PostgreSQL).
ALTER TABLE sls_pricelist_aturan
  DROP COLUMN IF EXISTS jenis_target,
  DROP COLUMN IF EXISTS jenis_aturan,
  DROP COLUMN IF EXISTS id_inv_kategori_produk;

-- 1d. RENAME harga_tetap → harga — HANYA bila kolom lama ada & baru belum
--     (live DB pemilik sudah rename → langkah ini no-op).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sls_pricelist_aturan'
      AND column_name = 'harga_tetap'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sls_pricelist_aturan'
      AND column_name = 'harga'
  ) THEN
    ALTER TABLE sls_pricelist_aturan
      RENAME COLUMN harga_tetap TO harga;
  END IF;
END $$;

-- 1e. Kolom ambang qty diskon — NOT NULL DEFAULT 1 (baris lama aman: diskon
--     lama berlaku sejak min_qty; default 1 = semantik "sejak qty pertama"
--     utk data warisan yang sudah terlanjur hidup).
ALTER TABLE sls_pricelist_aturan
  ADD COLUMN IF NOT EXISTS min_qty_diskon integer NOT NULL DEFAULT 1;

-- -----------------------------------------------------------------------------
-- §2 Index bentuk live — dinyatakan ulang IF NOT EXISTS (baseline 28 sudah
--    punya bentuk identik; patch tidak mengubah definisi, hanya memastikan).
-- -----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_pricelist_aturan_produk
  ON sls_pricelist_aturan (id_sls_pricelist, id_inv_produk, min_qty)
  WHERE id_inv_produk IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pricelist_aturan_pricelist
  ON sls_pricelist_aturan (id_sls_pricelist) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- §3 DROP tipe enum_jenis_aturan_harga_sls — HANYA bila tipe ada DAN terbukti
--    tanpa pemakai kolom (pg_attribute kosong). enum_jenis_target_aturan_sls
--    TIDAK disentuh (dipakai sls_promosi_aturan.jenis_target).
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_oid oid;
BEGIN
  SELECT t.oid INTO v_oid
  FROM pg_type t
  WHERE t.typname = 'enum_jenis_aturan_harga_sls';

  IF v_oid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.atttypid = v_oid
        AND a.attisdropped = false
    ) THEN
      RAISE NOTICE 'PATCH 76: enum_jenis_aturan_harga_sls masih dipakai kolom — tipe TIDAK di-drop';
    ELSE
      DROP TYPE enum_jenis_aturan_harga_sls;
    END IF;
  END IF;
END $$;

COMMIT;
