-- +goose Up
-- Porting 1:1 dari ddl/53-inv-mutasi-data-scope.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 53-inv-mutasi-data-scope.sql — Seed data-scope mutasi barang (INV)
-- Domain   : INV — adopsi dimensi data-scope 'storages' pada modul dokumen
--            MUTASI BARANG (inv_mutasi_dokumen sumber/tujuan → inv_lokasi_stok
--            .id_inv_gudang). Semantik "party semantics": dokumen terlihat /
--            boleh disusun bila minimal SATU endpoint (sumber ATAU tujuan)
--            berada di gudang whitelist aktor — transfer keluar/masuk gudang
--            aktor tetap terlihat agar stok gudangnya rekonsiliasi
--            (blueprint analisa-modul-inv-v2 §3.3 / A-05: cakupan gudang per
--            penugasan). Pemetaan kode: core/rbac/data-scope.service.ts
--            SCOPE_COLUMN_MAP ['storages'] = invGudang.id; wrapper keputusan
--            filterStoragesIds; pemakai apps/api/src/modules/inv/operasi/
--            mutasi.service.ts (baca di luar cakupan → 404; susun → 409
--            INV-021 LOKASI_TIDAK_DIIZINKAN).
-- Sumber   : keputusan cakupan blueprint inv §3.3 — role luas (Manager
--            Inventory) melihat semua gudang; role lapangan (Supervisor
--            Gudang) subset gudang pusat. Assignment level USER (menimpa
--            union role) adalah aksi runtime admin via /core/data-scope —
--            TIDAK di-seed di sini (aktor targetnya kontekstual per env).
-- Tanggal  : 2026-11-11
-- Prasyarat: tabel core_scope_definitions/assignments/values live (ddl/50
--            trio); definisi 'storages' modul 'inventory' sudah terdaftar
--            (live: id 1, target inv_gudang.id); core_roles berisi 'Manager
--            Inventory' & 'Supervisor Gudang'; inv_gudang berisi baris kode
--            GUDANG-UTAMA & TOKO. VERIFIKASI live 2026-11-11: definisi
--            'storages' aktif; assignment role Manager Inventory sudah ada
--            (id 16, nilai 15/16/17) — seed ini idempoten di atasnya.
-- Isi      : §1 self-heal definisi 'storages' INI SAJA (registry struktural
--            wajib sinkron kode — pola seed-pos-core.sql §3);
--            §2 pastikan assignment role 'Manager Inventory' (whitelist SEMUA
--            gudang yang ada — paritas cakupan penuh manajer);
--            §3 assignment role 'Supervisor Gudang' (SUBSET gudang TOKO saja —
--            keputusan pemilik 2026-11-11 via /core/data-scope; GUDANG-UTAMA
--            & GU_BKS di luar cakupannya);
--            nilai whitelist dijamin lengkap per kode gudang (lookup nama,
--            tanpa id hardcode).
-- Makna    : RBAC (permission route) menentukan AKSI fitur mutasi; data-scope
--            (trio core_scope_*) menentukan BARIS mana yang terlihat dalam
--            fitur itu — keduanya berlaku bersama. Tanpa assignment = lihat
--            semua (fail-open, paritas perilaku lama); assignment TANPA nilai
--            = tidak melihat apa pun (DENY_ALL); nilai milik USER menimpa
--            union ROLE-nya (evaluator data-scope.service.ts).
-- Idempoten: INSERT ... SELECT + NOT EXISTS per (definisi, role) dan per
--            (assignment, value) — aman dijalankan 2× (run-2 no-op). Guard
--            nilai TANPA filter deleted_at: unique core_scope_values_pair_uq
--            NULLS NOT DISTINCT menahan pair lintas status soft-delete, jadi
--            guard-nya harus menghitung baris terhapus lunak juga.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Self-heal definisi 'storages' milik modul 'inventory' INI SAJA (re-run):
--    registry struktural wajib sinkron dengan kode — SCOPE_COLUMN_MAP
--    ['storages'] = invGudang.id ('inv_gudang'.'id'); salah target = aturan
--    di-skip guard (fail-open) / predicate salah tabel. Label/description
--    tidak disentuh; version dinaikkan agar If-Match klien lama tidak menimpa
--    basis basi.
-- -----------------------------------------------------------------------------
UPDATE core_scope_definitions d
SET target_table = 'inv_gudang',
    target_field = 'id',
    operator     = 'in',
    is_active    = true,
    deleted_at   = NULL,
    version      = d.version + 1,
    updated_at   = now()
FROM core_modules m
WHERE d.id_core_modules = m.id
  AND m.key = 'inventory'
  AND d.scope_key = 'storages'
  AND (d.target_table IS DISTINCT FROM 'inv_gudang'
       OR d.target_field IS DISTINCT FROM 'id'
       OR d.operator IS DISTINCT FROM 'in'
       OR d.deleted_at IS NOT NULL
       OR d.is_active = false);

-- -----------------------------------------------------------------------------
-- §2 Assignment role 'Manager Inventory' → whitelist SEMUA gudang (lookup
--    definisi by (modul, scope_key) + role by nama — tanpa id hardcode).
--    Role cakupan luas TETAP diberi whitelist penuh (bukan tanpa assignment —
--    itu kelas berbeda; di sini manajer memang diikat ke gudang yang ada).
--    Nilainya dilengkapi di §2b per kode gudang.
-- -----------------------------------------------------------------------------
INSERT INTO core_scope_assignments
  (id_core_scope_definitions, id_core_roles, is_active, note)
SELECT d.id, r.id, true,
       'Manager Inventory — whitelist semua gudang terdaftar (cakupan penuh)'
FROM core_scope_definitions d
JOIN core_modules m ON m.id = d.id_core_modules
JOIN core_roles r ON r.role = 'Manager Inventory'
WHERE m.key = 'inventory'
  AND d.scope_key = 'storages'
  AND d.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM core_scope_assignments a
    WHERE a.id_core_scope_definitions = d.id
      AND a.id_core_roles = r.id
      AND a.deleted_at IS NULL
  );

-- §2b Whitelist nilai Manager Inventory = semua gudang hidup (per (assignment,
--     value); guard tanpa deleted_at — lihat header Idempoten).
INSERT INTO core_scope_values (id_core_scope_assignments, value)
SELECT a.id, g.id::text
FROM core_scope_assignments a
JOIN core_scope_definitions d ON d.id = a.id_core_scope_definitions
JOIN core_modules m ON m.id = d.id_core_modules
JOIN core_roles r ON r.id = a.id_core_roles
JOIN inv_gudang g ON g.deleted_at IS NULL
WHERE m.key = 'inventory'
  AND d.scope_key = 'storages'
  AND r.role = 'Manager Inventory'
  AND a.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM core_scope_values v
    WHERE v.id_core_scope_assignments = a.id
      AND v.value = g.id::text
  );

-- -----------------------------------------------------------------------------
-- §3 Assignment role 'Supervisor Gudang' → SUBSET gudang TOKO saja (baseline
--    selaras keputusan pemilik via /core/data-scope 2026-11-11; nilai lain
--    yang dihapus UI tidak dihidupkan kembali oleh seed ini karena guard
--    NOT EXISTS-nya menghitung baris hidup). Dokumen mutasi yang TIDAK
--    menyentuh TOKO tidak terlihat role ini (list disembunyikan, detail by
--    id → 404 — paritas "tidak ada data").
-- -----------------------------------------------------------------------------
INSERT INTO core_scope_assignments
  (id_core_scope_definitions, id_core_roles, is_active, note)
SELECT d.id, r.id, true,
       'Supervisor Gudang — subset gudang TOKO; utama & GU_BKS di luar cakupan'
FROM core_scope_definitions d
JOIN core_modules m ON m.id = d.id_core_modules
JOIN core_roles r ON r.role = 'Supervisor Gudang'
WHERE m.key = 'inventory'
  AND d.scope_key = 'storages'
  AND d.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM core_scope_assignments a
    WHERE a.id_core_scope_definitions = d.id
      AND a.id_core_roles = r.id
      AND a.deleted_at IS NULL
  );

-- §3b Whitelist nilai Supervisor Gudang = gudang TOKO by KODE (lookup nama —
--     nilai yang disimpan tetap id gudang ::text, flavor evaluasi numerik).
INSERT INTO core_scope_values (id_core_scope_assignments, value)
SELECT a.id, g.id::text
FROM core_scope_assignments a
JOIN core_scope_definitions d ON d.id = a.id_core_scope_definitions
JOIN core_modules m ON m.id = d.id_core_modules
JOIN core_roles r ON r.id = a.id_core_roles
JOIN inv_gudang g ON g.kode = 'TOKO'
WHERE m.key = 'inventory'
  AND d.scope_key = 'storages'
  AND r.role = 'Supervisor Gudang'
  AND a.deleted_at IS NULL
  AND g.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM core_scope_values v
    WHERE v.id_core_scope_assignments = a.id
      AND v.value = g.id::text
  );

COMMIT;

-- ddl/53-inv-mutasi-data-scope.sql selesai.
