-- +goose Up
-- Porting 1:1 dari ddl/60-purchasing-usulan-aset-hapus.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 60-purchasing-usulan-aset-hapus.sql — Pembasmian fitur Usulan Aset
-- Domain   : PURCHASING — hapus fitur usulan aset pembelian (F9/M17):
--            tabel `pur_usulan_aset` (3 baris, diarsip), 5 route RBAC
--            `purchasing.usulan-aset.*`, menu "Usulan Aset", kolom FK
--            `ast_aset.id_pur_usulan_aset` (jejak registrasi aset M17).
-- Sumber   : keputusan pemilik 2026-11-12 (refactor-delete-mode; audit
--            dampak: 0 konsumen outbox M17 — modul AST backend belum ada,
--            0 baris ast_aset ber-usulan, Dexie/test kosong).
-- Tanggal  : 2026-11-12
-- Prasyarat: arsip `arsip-hapus-purchasing-usulan-aset-20261112.tgz`
--            (data + skema + snapshot 15 file kode).
-- Isi      : §1 lepas FK + kolom jejak di ast_aset; §2 DROP pur_usulan_aset;
--            §3 enum yatim; §4 basmi RBAC (route/SET/junction/menu).
-- Makna    : alur pengajuan pembelian-aset berhenti di purchasing —
--            pencatatan aset tetast berlaku via modul AST tanpa jejak usulan.
-- Idempoten: IF EXISTS / DO-guard di semua statement.
-- Catatan  : replay urutan ddl 39→60 aman (drop SETELAH pembuatnya 39);
--            CFG-PUR-11 dibersihkan di lapisan kode (param registry dihapus
--            §4e dari core_module_configs).
-- =============================================================================

BEGIN;

-- =============================================================================
-- §1 AST — lepas jejak usulan di tabel aset (kolom NULL semuanya — terbukti)
-- =============================================================================
ALTER TABLE ast_aset
  DROP CONSTRAINT IF EXISTS fk_ast_aset_usulan_pembelian;
ALTER TABLE ast_aset
  DROP COLUMN IF EXISTS id_pur_usulan_aset;
DROP INDEX IF EXISTS ix_ast_aset_usulan;

-- =============================================================================
-- §2 DROP tabel usulan aset
-- =============================================================================
DROP TABLE IF EXISTS pur_usulan_aset;

-- =============================================================================
-- §3 enum yatim milik tabel terhapus
-- =============================================================================
DROP TYPE IF EXISTS pur_keadaan_usulan_aset;
DROP TYPE IF EXISTS pur_status_usulan_aset;

COMMIT;

-- =============================================================================
-- §4 RBAC — route/SET/junction/menu fitur (di luar tx; idempoten)
-- =============================================================================
-- 4a) junction SET↔route untuk route usulan
DELETE FROM core_permissions_routes pr
USING core_routes r
WHERE pr.id_core_routes = r.id AND r.uri_pattern LIKE '/purchasing/usulan-aset%';

-- 4b) route usulan
DELETE FROM core_routes WHERE uri_pattern LIKE '/purchasing/usulan-aset%';

-- 4c) junction role↔SET usulan
DELETE FROM core_role_permissions rp
USING core_permissions p
WHERE rp.id_core_permissions = p.id AND p.name LIKE 'purchasing.usulan-aset%';

-- 4d) SET usulan (junction role sudah dibersihkan di 4c)
DELETE FROM core_permissions WHERE name LIKE 'purchasing.usulan-aset%';

-- 4e) CFG-PUR-11 — param registry pemicu usulan (milik fitur)
DELETE FROM core_module_configs
WHERE param_key = 'CFG-PUR-11'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'purchasing');

-- 4f) menu "Usulan Aset" — junction role↔menu dulu, lalu menunya
DELETE FROM core_roles_menus rm
USING core_menus c
WHERE rm.id_core_menus = c.id
  AND c.url_path = '/purchasing/usulan-aset'
  AND c.id_core_modules = (SELECT id FROM core_modules WHERE key = 'purchasing');
DELETE FROM core_menus
WHERE url_path = '/purchasing/usulan-aset'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'purchasing');

-- =============================================================================
-- VERIFIKASI (harus 0)
-- =============================================================================
SELECT 'cek 1 tabel usulan' AS cek, count(*) FROM pg_class
WHERE relname = 'pur_usulan_aset' AND relkind = 'r';
SELECT 'cek 2 kolom jejak ast' AS cek, count(*) FROM pg_attribute a
JOIN pg_class t ON t.oid = a.attrelid
WHERE t.relname = 'ast_aset' AND a.attname = 'id_pur_usulan_aset' AND a.attisdropped = false;
SELECT 'cek 3 enum yatim' AS cek, count(*) FROM pg_type
WHERE typname IN ('pur_keadaan_usulan_aset','pur_status_usulan_aset');
SELECT 'cek 4 route usulan' AS cek, count(*) FROM core_routes WHERE uri_pattern LIKE '/purchasing/usulan-aset%';
SELECT 'cek 5 SET usulan' AS cek, count(*) FROM core_permissions WHERE name LIKE 'purchasing.usulan-aset%';
SELECT 'cek 6 menu usulan' AS cek, count(*) FROM core_menus WHERE url_path = '/purchasing/usulan-aset';
SELECT 'cek 7 CFG-PUR-11' AS cek, count(*) FROM core_module_configs WHERE param_key = 'CFG-PUR-11';

-- ddl/60-purchasing-usulan-aset-hapus.sql selesai.
