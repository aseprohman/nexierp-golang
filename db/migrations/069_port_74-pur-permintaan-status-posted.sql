-- +goose Up
-- Porting 1:1 dari ddl/74-pur-permintaan-status-posted.sql (urutan & isi sama, tanpa perubahan)

-- =====================================================================
-- 74-pur-permintaan-status-posted.sql — alur PR tanpa tahap keputusan:
-- DRAFT → ajukan → POSTED (langsung); DIBATALKAN dari DRAFT/POSTED;
-- TERKONVERSI tetap di sisi PO. DIAJUKAN/DISETUJUI/DITOLAK ditarik dari
-- kosakata aplikasi (zod + mirror Drizzle).
--
-- Kartu klasifikasi (arsitektur-database):
--   tabel   : pur_permintaan [TRANSAKSI] — pemilik modul `purchasing`
--   perubahan: enum_status_permintaan_pur ADD VALUE 'POSTED' (idempoten).
--   catatan : nilai lama (DIAJUKAN/DISETUJUI/DITOLAK) DIBIARKAN di tipe
--             DB (Postgres tidak mendukung REMOVE VALUE) — aplikasi tidak
--             pernah menulisnya lagi (zod membatasi kosakata); tabel
--             pur_permintaan KOSONG saat patch (pengosongan transaksi
--             2026-11-21) → tidak ada migrasi data.
--   kolom   : alasan_penolakan + ck_pur_permintaan_tolak DIBIARKAN
--             (harmless — status DITOLAK tak lagi terjangkau).
-- =====================================================================

BEGIN;

ALTER TYPE enum_status_permintaan_pur ADD VALUE IF NOT EXISTS 'POSTED';

COMMIT;