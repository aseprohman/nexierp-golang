-- =============================================================================
-- PATCH DDL 45-hapus-core-user-duties.sql — Pembasmian fitur duty-SoD legacy
-- Domain   : CORE — hapus `core_user_duties` (18 baris) + `core_sod_rules`
--            (11 baris) — fitur duty-SoD TIDAK PERNAH aktif: tanpa endpoint
--            CRUD (0 rute di core_routes), tanpa FK masuk, tanpa konsumen
--            lintas modul. Mekanisme penggantinya = data-scope
--            `core_scope_definitions` + `core_scope_assignments` (live).
-- Sumber   : keputusan pemilik 2026-11-11 (refactor-delete-mode; audit
--            refactor-modul-audit Fase 1 — 0 konsumen lintas-modul).
-- Tanggal  : 2026-11-11
-- Prasyarat: kode BE/FE konsumen duty sudah dibersihkan (users.service,
--            overview.service, sod-conflicts, users-page, schemas/core/sod).
--            Arsip pra-hapus: arsip-hapus-core-user-duties-20261111.tgz
--            (data + skema + snapshot 9 file kode).
-- Isi      : §1 drop tabel duty; §2 drop tabel rules; §3 drop enum yatim.
-- Makna    : konflik SoD berbasis duty tidak lagi ada — pengganti Otorisasi
--            konteks = data-scope per user (core_scope_*).
-- Idempoten: DROP TABLE/TYPE IF EXISTS — aman dijalankan berulang.
-- Catatan  : ddl/41-pgw-tanpa-refund.sql §7e memuat DELETE core_user_duties
--            historis — replay berurutan 39→45 tetap aman (drop terjadi
--            SETELAH 41). Kolom core_user_permissions.id_core_users_duties
--            tidak pernah ada (verifikasi pg_attribute).
-- =============================================================================

-- §1 duty per user
DROP TABLE IF EXISTS core_user_duties;

-- §2 pasangan duty terlarang
DROP TABLE IF EXISTS core_sod_rules;

-- §3 enum yatim milik core_sod_rules.enforcement (drop berulang = no-op)
DROP TYPE IF EXISTS core_sod_enforcement;

-- =============================================================================
-- VERIFIKASI (harus 0)
-- =============================================================================
SELECT 'cek 1 tabel duty' AS cek, count(*) FROM pg_class
WHERE relname IN ('core_user_duties','core_sod_rules') AND relkind = 'r';
SELECT 'cek 2 enum yatim' AS cek, count(*) FROM pg_type
WHERE typname = 'core_sod_enforcement';

-- ddl/45-hapus-core-user-duties.sql selesai.
