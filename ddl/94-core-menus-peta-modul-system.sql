-- =============================================================================
-- PATCH DDL 94-core-menus-peta-modul-system.sql — CORE: peta modul menu System
-- =============================================================================
-- Domain   : NEXIERP · Modul CORE — registry `core_menus` (halaman
--            /core/menus + halaman gate modul + form parent-combo).
--            15 baris menu milik modul System & Authorization (3 header grup
--            "Utama" / "Akses & Otorisasi" / "Keamanan & Audit" + 12 menu
--            halaman /core/*) masih `id_core_modules IS NULL` — warisan data
--            pra-migrasi TANPA file seed sumber di repo.
--            Akibatnya (bukti audit 2026-11-25): `moduleParentScope` form
--            menu hanya mengenal 3 anak (Data Scope/Cluster/Kosakata) —
--            combo Parent & tree kiri halaman /core/menus TIDAK memuat
--            hierarki valid saat modul System dipilih; halaman gate juga
--            tidak bisa memetakan menu→modul System.
-- Migrasi  : UPDATE (bukan INSERT) — data yang sudah ada diberi pemilik.
--            Pemetaan by `url_path` (bukan id hardcode — aman lintas env);
--            header grup mengikuti anak-anaknya (pola kanonik modul lain:
--            header & seluruh anak ber-modul — nol NULL di 13 modul lain).
-- Bedah    : §1 anak halaman (12 url_path /core/*) → modul `system`;
--            §2 header grup = parent dari anak-anak §1 yang masih NULL.
-- Idempoten: guard `AND id_core_modules IS NULL` — lari kedua = UPDATE 0.
-- Catatan  : 5 header yatim tanpa anak (id 614/615/616/617/625 — sisa seed
--            lama, bukan menu core) TIDAK disentuh — temuan terpisah P3.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/94-core-menus-peta-modul-system.sql
--            (jalankan 2× — lari kedua = UPDATE 0). Tidak dieksekusi oleh
--            sesi audit — koordinator meng-apply setelah review.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 ANAK HALAMAN — 12 menu /core/* yang masih tanpa modul → `system`
-- -----------------------------------------------------------------------------

UPDATE core_menus
SET id_core_modules = (SELECT id FROM core_modules WHERE key = 'system')
WHERE url_path IN (
      '/core',                    -- Overview (header Utama)
      '/core/environment',        -- Environment
      '/core/users',              -- Pengguna
      '/core/roles',              -- Peran & Izin Global
      '/core/module-permissions', -- Izin & Otorisasi
      '/core/registry',           -- Registry Endpoint
      '/core/menus',              -- Menu Navigasi
      '/core/modules',            -- Manajemen Modul
      '/core/tenants',            -- Tenant
      '/core/security',           -- Sesi & Autentikasi
      '/core/audit-trail',        -- Audit Trail
      '/core/media'               -- Media Library
      )
  AND id_core_modules IS NULL;

-- -----------------------------------------------------------------------------
-- §2 HEADER GRUP — parent dari anak-anak §1 yang masih NULL → `system`
--    ("Utama", "Akses & Otorisasi", "Keamanan & Audit")
-- -----------------------------------------------------------------------------

UPDATE core_menus
SET id_core_modules = (SELECT id FROM core_modules WHERE key = 'system')
WHERE id IN (
      SELECT DISTINCT parent
      FROM core_menus
      WHERE url_path IN (
            '/core', '/core/environment', '/core/users', '/core/roles',
            '/core/module-permissions', '/core/registry', '/core/menus',
            '/core/modules', '/core/tenants', '/core/security',
            '/core/audit-trail', '/core/media'
            )
        AND parent IS NOT NULL
      )
  AND parent IS NULL
  AND id_core_modules IS NULL;

COMMIT;

-- -----------------------------------------------------------------------------
-- §3 VERIFIKASI (jalankan manual setelah patch — ekspektasi di komentar)
-- -----------------------------------------------------------------------------
-- SELECT count(*) FROM core_menus
--  WHERE url_path LIKE '/core%' AND id_core_modules IS NULL;          -- 0
-- SELECT count(*) FROM core_menus m
--  WHERE m.id_core_modules = (SELECT id FROM core_modules WHERE key='system'); -- 18 (3 header + 15 menu)
-- SELECT m.text, count(c.id) AS anak
--  FROM core_menus m LEFT JOIN core_menus c ON c.parent = m.id
--  WHERE m.id_core_modules = (SELECT id FROM core_modules WHERE key='system')
--    AND m.parent IS NULL GROUP BY m.text ORDER BY m.text;
--   → Keamanan & Audit 3 · Utama 2 · Akses & Otorisasi 10
