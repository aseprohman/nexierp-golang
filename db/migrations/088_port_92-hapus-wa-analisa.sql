-- +goose Up
-- Porting 1:1 dari ddl/92-hapus-wa-analisa.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 92-hapus-wa-analisa.sql — WA: HAPUS FITUR ANALISA KONTAK (WA-F12)
-- =============================================================================
-- Domain   : NEXIERP · Modul WA (WHATSAPP CRM) — tabel [LOG/EVENT]
--            `wa_analisa_kontak` (ddl/66-wa.sql) + enum `enum_sentimen_wa` +
--            jejak registry (route /wa/analisa*, SET permission `wa.analisa` +
--            junction permission↔route, menu "Analisa Kontak" + junction
--            role↔menu, module-config CFG-WA-08 jadwal analisa).
--            Keputusan pemilik 2026-11-25: **FITUR DIHAPUS TOTAL** — tidak
--            pernah dipakai (0 baris, 0 audit trail). **WA-F11 LEDGER
--            `wa_llm_pemakaian` TETAP HIDUP** — chatbot terus menulis ledger
--            (LlmPemakaianRepository) dan KPI dashboard terus membacanya
--            (DashboardRepository); jangan sentuh tabel itu. Kode FE/BE/
--            schemas/seed/menu sudah dihapus bersamaan di repo (arsip lengkap:
--            `arsip-hapus-wa-analisa-20261125.tgz` di root repo — berisi dump
--            schema `ddl-wa-analisa-kontak.sql` + data CSV
--            `data-wa-analisa-kontak.csv` (0 baris) + semua file terhapus
--            sebelum dihapus).
-- Migrasi  : TANPA migrasi data — tabel berisi 0 baris di seluruh environment
--            (dev diverifikasi 2026-11-25); riwayat analisa tidak ada yang
--            perlu dipertahankan. Registry dihapus §3 agar seed & RBAC tidak
--            lagi menampilkan fitur mati.
-- Bedah    : DROP tabel langsung (tanpa anak) → enum dengan guard introspeksi
--            pg_attribute/information_schema (hanya drop bila TIDAK ada kolom
--            lain yang memakai; bila masih ada → RAISE WARNING, enum dibiarkan
--            hidup) → bersih registry anak-dahulu-induk (junction → entitas).
-- Idempoten: DROP TABLE IF EXISTS + guard pg_type + DELETE … WHERE EXISTS —
--            lari kedua = no-op.
-- Catatan  : (a) SET permission `wa.analisa` unik milik fitur ini (deskripsi
--              "WA-F11/F12 analisa+ledger") — DIHAPUS beserta grant
--              role-nya; route pakai permission_code spesifik
--              (`wa.analisa.pemakaian|picu|riwayatkontak`) yang hanya
--              ter-junction ke SET itu, jadi ikut terhapus aman.
--            (b) CFG-WA-08 (jadwal analisa, `core_module_configs` modul
--              `whatsapp-crm`) dihapus — konsumen (AnalisaKontakJob,
--              PengaturanService) sudah dihapus di repo.
--            (c) Job BullMQ repeatable `nexierp.wa:analisa-kontak` di Redis
--              dibersihkan terpisah oleh sesi refactor (bukan domain DB).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/92-hapus-wa-analisa.sql
--            (jalankan 2× — lari kedua = no-op). TIDAK dijalankan otomatis oleh
--            sesi refactor — koordinator mengeksekusi setelah review.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 DROP TABEL — ledger riwayat analisa kontak berversi (WA-F12)
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS wa_analisa_kontak;

-- -----------------------------------------------------------------------------
-- §2 DROP ENUM — hanya bila tak ada kolom lain yang memakai (guard dinamis)
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type t WHERE t.typname = 'enum_sentimen_wa') THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE udt_name = 'enum_sentimen_wa'
    ) THEN
      RAISE WARNING 'enum_sentimen_wa MASIH dipakai kolom lain — tidak di-drop';
    ELSE
      DROP TYPE enum_sentimen_wa;
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §3 BERSIH REGISTRY — junction dulu → entitas (pembelajaran ddl/91: DB
--    berdata gagal bila junction tidak dihapus sebelum induknya — FK RESTRICT)
-- -----------------------------------------------------------------------------

-- (1) Junction permission↔route milik SET `wa.analisa` (FK
--     core_permissions_routes → core_permissions & core_routes = RESTRICT —
--     WAJIB dihapus sebelum keduanya).
DELETE FROM core_permissions_routes
WHERE id_core_routes IN (
  SELECT id FROM core_routes WHERE uri_pattern LIKE '/wa/analisa%'
);

-- (2) Junction role↔menu milik menu Analisa Kontak (FK core_roles_menus →
--     core_menus = RESTRICT — hapus sebelum baris menu-nya).
DELETE FROM core_roles_menus
WHERE id_core_menus IN (
  SELECT id FROM core_menus WHERE url_path = '/wa/analisa'
);

-- (3) Grant role atas SET `wa.analisa` (admin/wa_supervisor/wa_agen).
DELETE FROM core_role_permissions
WHERE id_core_permissions IN (
  SELECT id FROM core_permissions WHERE name = 'wa.analisa'
);

-- (4) Grant pengguna langsung atas SET `wa.analisa` (defensif — dev saat ini 0).
DELETE FROM core_user_permissions
WHERE id_core_permissions IN (
  SELECT id FROM core_permissions WHERE name = 'wa.analisa'
);

-- (5) Route izin fitur analisa.
DELETE FROM core_routes
WHERE uri_pattern LIKE '/wa/analisa%';

-- (6) SET permission `wa.analisa` (modul whatsapp-crm — guard per modul).
DELETE FROM core_permissions
WHERE name = 'wa.analisa'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'whatsapp-crm');

-- (7) Menu "Analisa Kontak" /wa/analisa.
DELETE FROM core_menus
WHERE url_path = '/wa/analisa';

-- (8) Module-config CFG-WA-08 (jadwal analisa) milik modul whatsapp-crm.
DELETE FROM core_module_configs
WHERE param_key = 'CFG-WA-08'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'whatsapp-crm');

-- (9) Baris fitur `analisa` di core_modules_features (defensif — dev saat ini
--     tidak ada; permission/route me-refer via FK RESTRICT/SET NULL sudah
--     bersih di atas).
DELETE FROM core_modules_features
WHERE features_folder = 'analisa'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'whatsapp-crm');

COMMIT;

-- -----------------------------------------------------------------------------
-- §4 VERIFIKASI (jalankan manual setelah patch — semua harus kosong/NULL)
-- -----------------------------------------------------------------------------
-- SELECT to_regclass('public.wa_analisa_kontak');                 -- NULL
-- SELECT count(*) FROM pg_type WHERE typname = 'enum_sentimen_wa';-- 0
-- SELECT count(*) FROM core_routes
--   WHERE uri_pattern LIKE '/wa/analisa%';                        -- 0
-- SELECT count(*) FROM core_menus WHERE url_path = '/wa/analisa'; -- 0
-- SELECT count(*) FROM core_permissions WHERE name = 'wa.analisa';-- 0
-- SELECT count(*) FROM core_module_configs c
--   JOIN core_modules m ON m.id = c.id_core_modules
--   WHERE m.key = 'whatsapp-crm' AND c.param_key = 'CFG-WA-08';   -- 0
-- SELECT count(*) FROM core_modules_features f
--   JOIN core_modules m ON m.id = f.id_core_modules
--   WHERE m.key = 'whatsapp-crm' AND f.features_folder = 'analisa'; -- 0
-- LEDGER F11 TETAP HIDUP:
-- SELECT to_regclass('public.wa_llm_pemakaian');                  -- bukan NULL
-- SELECT count(*) FROM wa_llm_pemakaian;                          -- tetap ada barisnya (dev: 29)
