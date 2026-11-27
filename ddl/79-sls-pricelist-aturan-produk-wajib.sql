-- =============================================================================
-- PATCH DDL 79-sls-pricelist-aturan-produk-wajib.sql — SLS: aturan pricelist
-- WAJIB spesifik per produk (target SEMUA DIHAPUS — keputusan pemilik)
-- =============================================================================
-- Domain   : NEXIERP · Modul SALES (SLS) — pricelist aturan [LINE] F02,
--            SLS-BR06. Lanjutan ddl/76: aturan harga kini WAJIB terikat SATU
--            produk (`id_inv_produk NOT NULL`); target SEMUA
--            (`id_inv_produk IS NULL`) TIDAK VALID lagi di bentuk baru dan
--            DIHAPUS dari data. Basis header pricelist (UMUM/GRUP/PELANGGAN)
--            TETAP; fitur promosi (`sls_promosi_*`) TIDAK disentuh.
-- Kartu    :
--   sls_pricelist_aturan | [LINE] | SLS | perubahan:
--     - DELETE baris ber-`id_inv_produk IS NULL` (target SEMUA — baris
--       demo/uji bentuk ddl/76, termasuk milik seed lama & baris uji
--       PRL-SMOKE-76): bentuk lama tak valid di aturan baru; RAISE NOTICE
--       jumlah baris terhapus. Seed SLS v6 mengisi ulang baris miliknya
--       (semua aturan seed kini memakai produk INV nyata).
--     - ALTER COLUMN `id_inv_produk` SET NOT NULL (guard DO-block
--       information_schema — dilakukan sekali; DELETE §1a menjamin tidak ada
--       baris NULL tersisa). FK fk_sls_pricelist_aturan_produk RESTRICT
--       TETAP (ikutan kolom, tidak diubah).
--     - REBUILD INDEX uq_sls_pricelist_aturan_produk →
--       (id_sls_pricelist, id_inv_produk, min_qty) WHERE deleted_at IS NULL:
--       kondisi partial `id_inv_produk IS NOT NULL` tidak diperlukan lagi
--       (kolom NOT NULL). DROP lama → CREATE baru dgn IF EXISTS/IF NOT EXISTS.
--   Resolusi harga (SLS-BR06) ikut menyederhana: peringkat PRODUK > SEMUA
--   GUGUR — pemenang harga/diskon di antara baris produk itu = ambang
--   terbesar terpenuhi (min_qty utk harga / min_qty_diskon utk diskon) →
--   prioritas tertinggi → id terkecil; kaskade tingkat pricelist header
--   (PELANGGAN → GRUP → UMUM) TETAP.
-- Idempoten: DELETE where-guard + DO-block guard NOT NULL + DROP IF EXISTS /
--            CREATE IF NOT EXISTS — lari kedua = no-op (NOTICE 0 baris).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/79-sls-pricelist-aturan-produk-wajib.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1a DELETE baris target SEMUA (id_inv_produk NULL) — bentuk lama tak valid;
--     termasuk baris demo seed lama & baris uji PRL-SMOKE-76 (diharapkan).
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_terhapus integer;
BEGIN
  DELETE FROM sls_pricelist_aturan WHERE id_inv_produk IS NULL;
  GET DIAGNOSTICS v_terhapus = ROW_COUNT;
  RAISE NOTICE 'PATCH 79: % baris sls_pricelist_aturan target SEMUA (id_inv_produk NULL) dihapus', v_terhapus;
END $$;

-- -----------------------------------------------------------------------------
-- §1b ALTER COLUMN id_inv_produk SET NOT NULL — sekali (guard is_nullable).
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sls_pricelist_aturan'
      AND column_name = 'id_inv_produk'
      AND is_nullable = 'YES'
  ) THEN
    ALTER TABLE sls_pricelist_aturan ALTER COLUMN id_inv_produk SET NOT NULL;
    RAISE NOTICE 'PATCH 79: sls_pricelist_aturan.id_inv_produk SET NOT NULL';
  ELSE
    RAISE NOTICE 'PATCH 79: id_inv_produk sudah NOT NULL — lewati';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §2 REBUILD index uq bentuk baru — partial deleted_at saja (kolom NOT NULL).
-- -----------------------------------------------------------------------------

DROP INDEX IF EXISTS uq_sls_pricelist_aturan_produk;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_pricelist_aturan_produk
  ON sls_pricelist_aturan (id_sls_pricelist, id_inv_produk, min_qty)
  WHERE deleted_at IS NULL;

COMMIT;
