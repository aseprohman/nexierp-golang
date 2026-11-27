-- +goose Up
-- Porting 1:1 dari ddl/59-purchasing-rfq-hapus-gudang.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 59-purchasing-rfq-hapus-gudang.sql — RFQ tanpa gudang penerimaan
-- Domain   : PUR — koreksi keputusan pemilik 2026-11-12: dokumen permintaan
--            penawaran (RFQ) TIDAK menentukan gudang penerimaan; gudang
--            diputuskan belakangan di PO/penerimaan.
-- Sumber   : keputusan pemilik; gerbang arsitektur-database — kolom eksklusif
--            fitur (ddl/57), pembaca lain = 0 (audit 2026-11-12).
-- Isi      : DROP COLUMN id_inv_gudang (nullable; FK ikut ter-drop) dari
--            header pur_permintaan_penawaran.
-- Idempoten: DROP COLUMN IF EXISTS — aman 2×.
-- =============================================================================

BEGIN;
ALTER TABLE pur_permintaan_penawaran
  DROP COLUMN IF EXISTS id_inv_gudang;
COMMIT;

-- ddl/59-purchasing-rfq-hapus-gudang.sql selesai.
