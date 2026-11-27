-- +goose Up
-- Porting 1:1 dari ddl/77-sls-promosi-aturan-sederhana.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 77-sls-promosi-aturan-sederhana.sql — SLS: `sls_promosi_aturan`
-- sederhana (1 baris = syarat + hadiah — "beli X → dapat Y")
-- =============================================================================
-- Domain   : NEXIERP · Modul SALES (SLS) — engine promosi aturan [LINE]
--            (PP-22, F16). Bentuk live DIUBAH PEMILIK LANGSUNG di DB — kolom
--            `peran` sudah di-drop di live TANPA merge data (bentuk antara:
--            3 baris SYARAT jenis_hadiah NULL + 3 baris HADIAH); patch ini
--            MEMFORMALKAN transformasi bentuk `ddl/28-sls.sql` (peran
--            SYARAT/HADIAH) DAN bentuk antara live → bentuk final.
--            ddl/28-sls.sql TIDAK disentuh (historis).
-- Kartu    :
--   sls_promosi_aturan | [LINE] | SLS | perubahan:
--     - SEMANTIK BARU — satu baris = paket mandiri "beli X → dapat Y":
--       syarat OPSIONAL (target + ambang min_qty/min_nilai) + hadiah WAJIB
--       berada di SATU baris; baris-baris INDEPENDEN (program = kumpulan
--       paket aturan).
--     - DROP peran SYARAT/HADIAH: kolom `peran`, CHECK
--       ck_sls_promosi_aturan_peran, index uq lama yang memuat peran, dan
--       tipe enum_promosi_peran_sls — pembagian peran dihapus; baris tanpa
--       hadiah tidak lagi sah.
--     - Target SEMUA/KATEGORI/PRODUK DIPERTAHANKAN (ck_target & enum
--       enum_jenis_target_aturan_sls tidak disentuh) — kini menyatakan
--       target SYARAT ("beli apa").
--     - ADD kolom `id_inv_produk_gratis` bigint → inv_produk(id) RESTRICT —
--       produk gratis utk hadiah PRODUK_GRATIS ("dapat apa"); TERPISAH dari
--       `id_inv_produk` yang kini = target syarat ("beli apa").
--     - `jenis_hadiah` SET NOT NULL — semua baris tersisa pasti berhadiah.
--     - ADD CHECK ck_sls_promosi_aturan_baris (xor ketat per jenis hadiah;
--       PRODUK_GRATIS wajib qty_gratis ≥ 1 + id_inv_produk_gratis);
--       ck_target / ck_min / ck_persen lama BERTAHAN — ambang syarat
--       min_qty/min_nilai OPSIONAL (NULL = menyala tanpa syarat).
--     - Index bentuk live baru (tanpa peran, + jenis_hadiah):
--       uq_sls_promosi_aturan_produk & uq_sls_promosi_aturan_kategori
--       dinyatakan ulang IF NOT EXISTS; ix_sls_promosi_aturan_promosi
--       dipertahankan bentuk sama (tidak memuat peran).
--   Migrasi data (§4 — SATU DO-block, dijaga kolom `peran` ATAU sisa baris
--   bentuk lama `jenis_hadiah IS NULL`; marker peran dipakai lewat padanan
--   ck_peran lama: SYARAT ⟺ jenis_hadiah NULL, HADIAH ⟺ jenis_hadiah NOT
--   NULL — bekerja di bentuk lama maupun bentuk antara live yang kolom
--   peran-nya sudah hilang):
--     4a. Produk target hadiah PRODUK_GRATIS pindah ke id_inv_produk_gratis
--         (SEBELUM id_inv_produk ditimpa merge — urutan KETAT).
--     4b. Baris SYARAT PERTAMA tiap program (MIN(id), hidup) disalin ke
--         SEMUA baris HADIAH program yang sama (overwrite jenis_target,
--         id_inv_produk, id_inv_kategori_produk, min_qty, min_nilai);
--         program tanpa SYARAT → baris HADIAH tak tersentuh (ambang tetap
--         NULL = menyala tanpa syarat).
--     4c. DELETE baris SYARAT (fisik — sudah ter-merge; LINE, precedent
--         REPLACE).
--     4d. jenis_hadiah SET NOT NULL.
-- Idempoten: DROP IF EXISTS / ADD COLUMN IF NOT EXISTS / DO-block guard
--            (kolom peran, conname ck_baris, tipe enum) / CREATE INDEX IF
--            NOT EXISTS — lari ke-2 = no-op penuh.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/77-sls-promosi-aturan-sederhana.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 DROP index lama yang memuat kolom peran (ekspresi uq menyertakan `peran`
--    — wajib hilang sebelum kolomnya di-drop di §7).
-- -----------------------------------------------------------------------------

-- 1a. Uq target KATEGORI bentuk lama (id_sls_promosi, peran, kategori, min_qty).
DROP INDEX IF EXISTS uq_sls_promosi_aturan_kategori;

-- 1b. Uq target PRODUK bentuk lama (id_sls_promosi, peran, produk, min_qty).
DROP INDEX IF EXISTS uq_sls_promosi_aturan_produk;

-- ix_sls_promosi_aturan_promosi TIDAK disentuh (tidak memuat peran).

-- -----------------------------------------------------------------------------
-- §2 DROP CHECK semantik lama (SYARAT xor HADIAH) — pemegang kolom peran.
-- -----------------------------------------------------------------------------

ALTER TABLE sls_promosi_aturan
  DROP CONSTRAINT IF EXISTS ck_sls_promosi_aturan_peran;

-- -----------------------------------------------------------------------------
-- §3 ADD kolom produk gratis — FK inline, idempoten.
-- -----------------------------------------------------------------------------

-- Produk gratis utk hadiah PRODUK_GRATIS ("dapat apa") — TERPISAH dari
-- id_inv_produk yang kini = target syarat ("beli apa").
ALTER TABLE sls_promosi_aturan
  ADD COLUMN IF NOT EXISTS id_inv_produk_gratis bigint
  REFERENCES inv_produk(id) ON DELETE RESTRICT;

-- -----------------------------------------------------------------------------
-- §4 MIGRASI DATA — SATU DO-block, dijaga keberadaan bentuk lama: kolom
--    `peran` masih ada ATAU masih ada baris SYARAT bentuk lama (jenis_hadiah
--    NULL — live pemilik sudah drop kolom peran tanpa merge). Syarat/HADIAH
--    ditandai via jenis_hadiah NULL / NOT NULL — padanan eksak ck_peran lama.
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'sls_promosi_aturan'
      AND column_name = 'peran'
  ) OR EXISTS (
    SELECT 1 FROM sls_promosi_aturan WHERE jenis_hadiah IS NULL
  ) THEN

    -- 4a. Produk target hadiah PRODUK_GRATIS disimpan dulu ke kolom baru —
    --     SEBELUM id_inv_produk ditimpa merge syarat (urutan KETAT).
    UPDATE sls_promosi_aturan
      SET id_inv_produk_gratis = id_inv_produk
      WHERE jenis_hadiah = 'PRODUK_GRATIS' AND id_inv_produk IS NOT NULL;

    -- 4b. Merge syarat: baris SYARAT PERTAMA tiap program (MIN(id), hidup)
    --     disalin ke SEMUA baris HADIAH program yang sama — overwrite
    --     jenis_target, id_inv_produk, id_inv_kategori_produk, min_qty,
    --     min_nilai. Program tanpa SYARAT → baris HADIAH tak tersentuh.
    UPDATE sls_promosi_aturan AS h
      SET jenis_target         = s.jenis_target,
          id_inv_produk        = s.id_inv_produk,
          id_inv_kategori_produk = s.id_inv_kategori_produk,
          min_qty              = s.min_qty,
          min_nilai            = s.min_nilai
      FROM sls_promosi_aturan AS s
      WHERE h.id_sls_promosi = s.id_sls_promosi
        AND h.jenis_hadiah IS NOT NULL
        AND s.id = (
          SELECT MIN(l.id) FROM sls_promosi_aturan AS l
          WHERE l.id_sls_promosi = h.id_sls_promosi
            AND l.jenis_hadiah IS NULL
            AND l.deleted_at IS NULL
        );

    -- 4c. DELETE baris SYARAT — fisik (sudah ter-merge; LINE, precedent
    --     REPLACE).
    DELETE FROM sls_promosi_aturan WHERE jenis_hadiah IS NULL;

    -- 4d. Semua baris tersisa pasti berhadiah → hadiah jadi WAJIB.
    ALTER TABLE sls_promosi_aturan
      ALTER COLUMN jenis_hadiah SET NOT NULL;

  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §5 ADD CHECK bentuk baris baru — DO-block guard conname (bentuk ddl/76):
--    hanya ADD bila ck_sls_promosi_aturan_baris belum ada. Syarat ambang
--    min_qty/min_nilai OPSIONAL — dicover ck_sls_promosi_aturan_min lama.
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ck_sls_promosi_aturan_baris'
      AND conrelid = 'sls_promosi_aturan'::regclass
  ) THEN
    ALTER TABLE sls_promosi_aturan ADD CONSTRAINT ck_sls_promosi_aturan_baris CHECK (
      (jenis_hadiah IS NOT NULL AND (
        (jenis_hadiah = 'DISKON_PERSEN'   AND nilai_persen IS NOT NULL
          AND nilai_nominal IS NULL AND qty_gratis IS NULL)
        OR (jenis_hadiah = 'DISKON_NOMINAL' AND nilai_nominal IS NOT NULL
          AND nilai_persen IS NULL AND qty_gratis IS NULL)
        OR (jenis_hadiah = 'PRODUK_GRATIS' AND qty_gratis IS NOT NULL AND qty_gratis >= 1
          AND id_inv_produk_gratis IS NOT NULL AND nilai_persen IS NULL AND nilai_nominal IS NULL)
        OR (jenis_hadiah = 'NILAI_VOUCHER' AND nilai_nominal IS NOT NULL
          AND nilai_persen IS NULL AND qty_gratis IS NULL)
      ))
    );
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §6 Index bentuk live baru — dinyatakan ulang IF NOT EXISTS (pembanding uq
--    kini tanpa peran, + jenis_hadiah; COALESCE menyetarakan NULL min_qty,
--    pola uq pricelist_aturan K-07).
-- -----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_promosi_aturan_produk
  ON sls_promosi_aturan (id_sls_promosi, id_inv_produk, COALESCE(min_qty, 0), jenis_hadiah)
  WHERE id_inv_produk IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_promosi_aturan_kategori
  ON sls_promosi_aturan (id_sls_promosi, id_inv_kategori_produk, COALESCE(min_qty, 0), jenis_hadiah)
  WHERE id_inv_kategori_produk IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_aturan_promosi
  ON sls_promosi_aturan (id_sls_promosi) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- §7 DROP kolom peran — peran SYARAT/HADIAH pensiun (semantik §4 sudah merge).
-- -----------------------------------------------------------------------------

ALTER TABLE sls_promosi_aturan
  DROP COLUMN IF EXISTS peran;

-- -----------------------------------------------------------------------------
-- §8 DROP tipe enum_promosi_peran_sls — HANYA bila tipe ada DAN terbukti
--    tanpa pemakai kolom (pg_attribute kosong); bila masih dipakai → NOTICE,
--    tipe dibiarkan. enum_jenis_target_aturan_sls TIDAK disentuh (masih
--    dipakai sls_promosi_aturan.jenis_target).
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
DECLARE
  v_oid oid;
BEGIN
  SELECT t.oid INTO v_oid
  FROM pg_type t
  WHERE t.typname = 'enum_promosi_peran_sls';

  IF v_oid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.atttypid = v_oid
        AND a.attisdropped = false
    ) THEN
      RAISE NOTICE 'PATCH 77: enum_promosi_peran_sls masih dipakai kolom — tipe TIDAK di-drop';
    ELSE
      DROP TYPE enum_promosi_peran_sls;
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;