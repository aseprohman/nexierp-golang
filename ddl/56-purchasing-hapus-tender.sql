-- =============================================================================
-- PATCH DDL 56-purchasing-hapus-tender.sql — Hapus fitur tender RFQ (F17/PUR-BR27)
-- Domain   : PUR — pembasmian total fitur TENDER penawaran RFQ alternatif
--            (refactor-delete-mode; keputusan pemilik 2026-11-12). Fitur ini
--            TIDAK punya tabel sendiri — terimplementasi sebagai 2 kolom
--            EKSKLUSIF di tabel [TRANSAKSI] shared `pur_pesanan` (ddl/33 §F17)
--            + 1 baris konfigurasi CFG-PUR-19 + 3 endpoint + helper + FE.
-- Sumber   : keputusan pemilik hapus fitur tender sampai akar. Gerbang
--            arsitektur-database: `pur_pesanan` adalah tabel shared (fitur
--            PO utama, revisi, kunci, dropship, kesepakatan) — TIDAK boleh
--            di-drop; kolom milik F17 SAJA boleh dikerutkan setelah grep
--            pembaca lain = 0 (audit 2026-11-12: konsumen lintas-modul
--            fungsional 0 — satu-satunya sebutan lain adalah prosa catatan
--            pelanggan di seed SLS, bukan pembaca kolom).
-- Tanggal  : 2026-11-12
-- Prasyarat: ddl/33 terpasang (2 kolom ada); kode aplikasi pemakai kolom
--            SUDAH dibersihkan di commit yang sama (pesanan/laporan/FE/seed).
-- Isi      : §1 DROP COLUMN kelompok_penawaran + tender_pemenang (data 3 PO
--            seed demo TND-2026-11 ikut hilang — konsekuensi sah penghapusan;
--            PO-nya tetap hidup); §2 DELETE baris konfigurasi CFG-PUR-19
--            (param modul purchasing — description menyebut F17).
-- Makna    : F17/PUR-BR27 (satu kelompok satu pemenang, kalah tender →
--            DIBATALKAN KALAH_TENDER) tidak lagi ada; kode error PUR-018
--            TENDER_PEMENANG_ADA dipensiunkan bersama commit kode.
-- Idempoten: DROP COLUMN IF EXISTS + DELETE WHERE param_key — aman 2×
--            (run-2 no-op).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom eksklusif fitur tender di pur_pesanan.
-- -----------------------------------------------------------------------------
ALTER TABLE pur_pesanan
  DROP COLUMN IF EXISTS kelompok_penawaran,
  DROP COLUMN IF EXISTS tender_pemenang;

-- -----------------------------------------------------------------------------
-- §2 Konfigurasi mode tender (NONAKTIF/OPSIONAL/WAJIB) — param milik F17.
-- -----------------------------------------------------------------------------
DELETE FROM core_module_configs
WHERE id_core_modules = (SELECT id FROM core_modules WHERE key = 'purchasing')
  AND param_key = 'CFG-PUR-19';

COMMIT;

-- ddl/56-purchasing-hapus-tender.sql selesai.
