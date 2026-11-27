-- +goose Up
-- Porting 1:1 dari ddl/80-ecom-kategori-thumbnail.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 80-ecom-kategori-thumbnail.sql — ECOM: thumbnail kategori
-- storefront (kolom `id_core_files` FK core_files, RESTRICT nullable)
-- =============================================================================
-- Domain   : NEXIERP · Modul ECOM — kategori storefront [MASTER]. Kolom baru
--            `id_core_files` = thumbnail tampil tile kategori (beranda,
--            filter katalog, dsb.); NULL = tanpa thumbnail — UI fallback
--            inisial. Reuse pola media ddl/36 (`ecom_katalog_online.
--            id_core_files` RESTRICT nullable — fk_ecom_katalog_file).
--            TANPA index baru (tidak ada reverse-lookup by file).
-- Kartu    :
--   ecom_kategori | [MASTER] | ecom | +kolom id_core_files (FK core_files, RESTRICT) — thumbnail storefront
-- Idempoten: ADD COLUMN IF NOT EXISTS + DO-block guard pg_constraint — lari
--            kedua = no-op (kolom & FK sudah ada, semua langkah lewati).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/80-ecom-kategori-thumbnail.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom thumbnail — nullable; NULL = tanpa thumbnail (UI fallback inisial).
-- -----------------------------------------------------------------------------

ALTER TABLE ecom_kategori ADD COLUMN IF NOT EXISTS id_core_files bigint;

COMMENT ON COLUMN ecom_kategori.id_core_files IS 'Thumbnail storefront kategori — referensi core_files; NULL = tanpa thumbnail (UI fallback inisial)';

-- -----------------------------------------------------------------------------
-- §2 FK fk_ecom_kategori_core_files — RESTRICT live CORE (pola media
--    fk_ecom_katalog_file ddl/36; guard pg_constraint pola ddl/67).
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_kategori_core_files') THEN
    ALTER TABLE ecom_kategori
      ADD CONSTRAINT fk_ecom_kategori_core_files FOREIGN KEY (id_core_files)
      REFERENCES core_files (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


COMMENT ON CONSTRAINT fk_ecom_kategori_core_files ON ecom_kategori IS 'thumbnail RESTRICT live CORE — file terpakai kategori tidak boleh terhapus (pola fk_ecom_katalog_file ddl/36)';

COMMIT;