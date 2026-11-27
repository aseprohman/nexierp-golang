-- +goose Up
-- Porting 1:1 dari ddl/95-hapus-menu-module-permissions.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 95-hapus-menu-module-permissions.sql — CORE: hapus menu halaman
-- izin & otorisasi yang sudah tidak ada
-- =============================================================================
-- Domain   : NEXIERP · Modul CORE — registry `core_menus`.
--            Halaman FE `/core/module-permissions` sudah dihapus
--            (refactor-delete-mode 2026-11-08, docs/analisa-modul-core.md
--            A-11 — nav + komponen dihapus, backend endpoint /system/permissions
--            tetap), tetapi BARIS MENU-nya di core_menus luput: warisan data
--            pra-migrasi yang TIDAK punya file seed sumber di repo (terbukti
--            grep "module-permissions" di podman/ + seed BE = 0 hasil) —
--            keputusan pemilik 2026-11-25: hapus baris menu + junction-nya.
-- Migrasi  : DELETE anak-dahulu-induk (FK core_roles_menus → core_menus
--            RESTRICT — pola ddl/91/92). Permission SET & rute API
--            /system/permissions TIDAK disentuh (backend IAM masih hidup).
-- Bedah    : §1 DELETE junction role↔menu; §2 DELETE baris menu.
-- Idempoten: DELETE … WHERE url_path = '/core/module-permissions' — lari
--            kedua = DELETE 0.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/95-hapus-menu-module-permissions.sql
--            (jalankan 2× — lari kedua = no-op).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 JUNCTION role↔menu yang menunjuk menu tersebut (FK RESTRICT — hapus dulu)
-- -----------------------------------------------------------------------------

DELETE FROM core_roles_menus
WHERE id_core_menus IN (
  SELECT id FROM core_menus WHERE url_path = '/core/module-permissions'
);

-- -----------------------------------------------------------------------------
-- §2 BARIS MENU "Izin & Otorisasi" /core/module-permissions
-- -----------------------------------------------------------------------------

DELETE FROM core_menus
WHERE url_path = '/core/module-permissions';

COMMIT;

-- -----------------------------------------------------------------------------
-- §3 VERIFIKASI (jalankan manual setelah patch — ekspektasi di komentar)
-- -----------------------------------------------------------------------------
-- SELECT count(*) FROM core_menus WHERE url_path = '/core/module-permissions'; -- 0
-- SELECT count(*) FROM core_roles_menus rm
--  JOIN core_menus m ON m.id = rm.id_core_menus
--  WHERE m.url_path = '/core/module-permissions';                              -- 0
-- SELECT count(*) FROM core_menus c WHERE c.parent = 529;                      -- 9 (anak Akses & Otorisasi berkurang 1)
