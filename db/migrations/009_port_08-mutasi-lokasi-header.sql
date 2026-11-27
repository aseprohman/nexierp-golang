-- +goose Up
-- Porting 1:1 dari ddl/08-mutasi-lokasi-header.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 08-mutasi-lokasi-header.sql — Lokasi sumber/tujuan pindah ke header
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : iterasi patch 07 — pola DO (delivery order): lokasi asal/tujuan
--            milik DOKUMEN (header), bukan per produk; item = produk+qty+lot.
--            Posting gerakan memakai lokasi header untuk semua item.
-- Kartu    : docs/arsitektur-database-core-inv.md §11.3 (D-47)
-- Idempoten: aman dijalankan berulang (backfill pakai DISTINCT pasangan)
-- =============================================================================

-- 1) Kolom lokasi di header.
ALTER TABLE inv_mutasi_dokumen ADD COLUMN IF NOT EXISTS id_lokasi_sumber bigint;
ALTER TABLE inv_mutasi_dokumen ADD COLUMN IF NOT EXISTS id_lokasi_tujuan bigint;

-- 2) Backfill dari item lama (dokumen patch 07: lokasi seragam per dokumen —
--    bila ada dokumen multi-lokasi, baris pertama yang dipakai sebagai header).
--    Guard kolom: rerun setelah kolom item di-drop = skip bersih.
-- +goose StatementBegin
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'inv_mutasi_items' AND column_name = 'id_lokasi_sumber'
  ) THEN
    UPDATE inv_mutasi_dokumen d
    SET id_lokasi_sumber = i.id_lokasi_sumber,
        id_lokasi_tujuan = i.id_lokasi_tujuan
    FROM (
      SELECT DISTINCT ON (id_inv_mutasi_dokumen)
        id_inv_mutasi_dokumen, id_lokasi_sumber, id_lokasi_tujuan
      FROM inv_mutasi_items
      WHERE deleted_at IS NULL
      ORDER BY id_inv_mutasi_dokumen, id
    ) i
    WHERE d.id = i.id_inv_mutasi_dokumen
      AND (d.id_lokasi_sumber IS NULL OR d.id_lokasi_tujuan IS NULL);
  END IF;
END $$;
-- +goose StatementEnd


-- 3) Integritas: NOT NULL + FK RESTRICT + CHECK sumber ≠ tujuan.
-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_mutasi_dokumen ALTER COLUMN id_lokasi_sumber SET NOT NULL;
EXCEPTION WHEN others THEN NULL; END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_mutasi_dokumen ALTER COLUMN id_lokasi_tujuan SET NOT NULL;
EXCEPTION WHEN others THEN NULL; END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT fk_inv_mutasi_sumber
    FOREIGN KEY (id_lokasi_sumber) REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT fk_inv_mutasi_tujuan
    FOREIGN KEY (id_lokasi_tujuan) REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT ck_inv_mutasi_lokasi_beda
    CHECK (id_lokasi_sumber <> id_lokasi_tujuan);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_inv_mutasi_dokumen_sumber
  ON inv_mutasi_dokumen (id_lokasi_sumber);
CREATE INDEX IF NOT EXISTS ix_inv_mutasi_dokumen_tujuan
  ON inv_mutasi_dokumen (id_lokasi_tujuan);

-- 4) Kolom lokasi di item DIBUANG (beserta FK & CHECK-nya ikut kolom).
ALTER TABLE inv_mutasi_items DROP COLUMN IF EXISTS id_lokasi_sumber;
ALTER TABLE inv_mutasi_items DROP COLUMN IF EXISTS id_lokasi_tujuan;