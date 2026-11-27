-- Query fitur TENANTS modul core — padanan TenantsRepository NestJS
-- (modules/core/repositories/tenants/tenants.repository.ts, ddl/22-core-tenants).
-- Tabel: core_tenants, core_users_tenants, core_tenant_modules,
-- core_tenant_features, core_tenant_settings, core_tenant_events + katalog
-- global core_modules / core_modules_features + identitas core_users.
-- Semua method menerima executor (pool | tx) — wrapper repository meneruskan
-- executor yang dipilih service (baca non-tx, mutasi dalam SATU tx bisnis).

-- ================================================================
-- Baca — daftar / detail / dup kode / konteks user
-- ================================================================

-- name: ListTenants :many
-- Daftar tenant paging (?page&limit&search&status&tier) — soft-delete aware
-- (deleted_at IS NULL); search menyasar kode + nama (ilike, tanpa escape —
-- persis Drizzle). Nilai kosong/nihil param = filter dilewati.
SELECT *
FROM core_tenants
WHERE deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (sqlc.narg('status')::text IS NULL OR status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('tier')::text IS NULL OR paket_tier::text = sqlc.narg('tier')::text)
ORDER BY id ASC
LIMIT sqlc.arg('limit')::int OFFSET sqlc.arg('offset')::int;

-- name: CountTenants :one
-- Total baris ListTenants (WHERE identik — pasangan paging).
SELECT count(*)::int AS total
FROM core_tenants
WHERE deleted_at IS NULL
  AND (sqlc.narg('search')::text IS NULL
       OR kode ILIKE '%' || sqlc.narg('search')::text || '%'
       OR nama ILIKE '%' || sqlc.narg('search')::text || '%')
  AND (sqlc.narg('status')::text IS NULL OR status::text = sqlc.narg('status')::text)
  AND (sqlc.narg('tier')::text IS NULL OR paket_tier::text = sqlc.narg('tier')::text);

-- name: GetTenantHidup :one
-- Tenant hidup wajib ada — tidak ada/terhapus → repository 404 SYS-404.
SELECT *
FROM core_tenants
WHERE id = $1 AND deleted_at IS NULL
LIMIT 1;

-- name: FindTenantKodeHidup :one
-- Tenant hidup by kode (cek duplikat provisio/patch) — absen = no rows.
SELECT id
FROM core_tenants
WHERE kode = $1 AND deleted_at IS NULL
LIMIT 1;

-- name: ListTenantContextUser :many
-- Tenant milik user SAAT INI (JWT) — keanggotaan aktif (dicabut_pada NULL)
-- bergabung tenant hidup (deleted_at NULL); default dulu, sisanya by kode.
SELECT t.id AS id_tenant, t.kode, t.nama, t.status, ut.is_default AS is_default
FROM core_users_tenants ut
JOIN core_tenants t ON t.id = ut.id_core_tenants
WHERE ut.id_core_users = $1
  AND t.deleted_at IS NULL
  AND ut.dicabut_pada IS NULL
ORDER BY ut.is_default DESC, t.kode ASC;

-- ================================================================
-- Tulis — tenant
-- ================================================================

-- name: InsertTenant :one
-- Insert tenant baru → baris lengkap (status PROVISI dibangun service).
INSERT INTO core_tenants
  (kode, nama, paket_tier, status, max_users, max_lokasi, kontak_email, kontak_telepon)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: UpdateTenantLengkap :one
-- Patch umum (kode/nama/kuota/kontak) — set LENGKAP hasil merge service
-- (field tak dikirim → nilai lama); version +1 dihitung service.
UPDATE core_tenants
SET kode = $1, nama = $2, paket_tier = $3, max_users = $4, max_lokasi = $5,
    kontak_email = $6, kontak_telepon = $7, version = $8, updated_at = now()
WHERE id = $9
RETURNING *;

-- name: UpdateTenantStatus :one
-- Transisi siklus hidup — status baru + version +1 (dihitung service).
UPDATE core_tenants
SET status = $2, version = $3, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: UpdateTenantTier :one
-- Ganti tier paket — paket_tier baru + version +1 (dihitung service).
UPDATE core_tenants
SET paket_tier = $2, version = $3, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: BumpVersionTenant :exec
-- Naikkan version +1 + updatedAt tenant (semua mutasi sub-resource).
UPDATE core_tenants
SET version = version + 1, updated_at = now()
WHERE id = $1;

-- ================================================================
-- Katalog global — snapshot PROVISIONING & validasi id REPLACE
-- ================================================================

-- name: ListSemuaModulId :many
-- Id SEMUA modul global (tanpa filter) — snapshot preset awal tenant.
SELECT id
FROM core_modules;

-- name: ListFiturGlobalAktifId :many
-- Id fitur global aktif (aktif + modulnya enabled) — snapshot preset awal.
SELECT f.id
FROM core_modules_features f
JOIN core_modules m ON m.id = f.id_core_modules
WHERE f.is_active = true AND m.enabled = true;

-- name: ListModulId :many
-- Id modul katalog by set id — validasi REPLACE setModules (absen = 404).
SELECT id
FROM core_modules
WHERE id = ANY($1::bigint[]);

-- name: ListFiturId :many
-- Id fitur katalog by set id — validasi REPLACE setFeatures (absen = 404).
SELECT id
FROM core_modules_features
WHERE id = ANY($1::bigint[]);

-- ================================================================
-- Junction modul tenant (core_tenant_modules)
-- ================================================================

-- name: InsertTenantModules :exec
-- Sisip modul aktif tenant — ON CONFLICT DO NOTHING (preset idempoten & REPLACE).
INSERT INTO core_tenant_modules (id_core_tenants, id_core_modules)
SELECT $1, id
FROM unnest($2::bigint[]) AS t(id)
ON CONFLICT DO NOTHING;

-- name: DeleteTenantModulesByTenant :exec
-- Hapus seluruh set modul tenant (langkah REPLACE semantik PUT).
DELETE FROM core_tenant_modules
WHERE id_core_tenants = $1;

-- name: ListIdModulAktif :many
-- Id modul aktif tenant (urut) — payload event SET_MODUL.
SELECT id_core_modules
FROM core_tenant_modules
WHERE id_core_tenants = $1
ORDER BY id_core_modules ASC;

-- name: ListRowsModulTenant :many
-- Baris modul registry + flag aktif tenant (aktif = ada baris junction),
-- seluruh katalog global ORDER id ASC.
SELECT m.id, m.key, m.name AS nama,
       (j.id_core_modules IS NOT NULL) AS aktif
FROM core_modules m
LEFT JOIN core_tenant_modules j
  ON j.id_core_modules = m.id AND j.id_core_tenants = $1
ORDER BY m.id ASC;

-- ================================================================
-- Junction fitur tenant (core_tenant_features)
-- ================================================================

-- name: InsertTenantFeatures :exec
-- Sisip fitur aktif tenant — ON CONFLICT DO NOTHING (preset idempoten & REPLACE).
INSERT INTO core_tenant_features (id_core_tenants, id_core_modules_features)
SELECT $1, id
FROM unnest($2::bigint[]) AS t(id)
ON CONFLICT DO NOTHING;

-- name: DeleteTenantFeaturesByTenant :exec
-- Hapus seluruh set fitur tenant (langkah REPLACE semantik PUT).
DELETE FROM core_tenant_features
WHERE id_core_tenants = $1;

-- name: ListIdFiturAktif :many
-- Id fitur aktif tenant (urut) — payload event SET_FITUR.
SELECT id_core_modules_features
FROM core_tenant_features
WHERE id_core_tenants = $1
ORDER BY id_core_modules_features ASC;

-- name: ListRowsFiturTenant :many
-- Baris fitur registry + flag aktif tenant; nama = label dari description
-- jsonb bila berbentuk object berkolom `label`, fallback features_folder.
SELECT f.id, m.key AS module_key, f.features_folder AS key,
       coalesce(
         CASE WHEN jsonb_typeof(f.description) = 'object'
              THEN f.description ->> 'label' END,
         f.features_folder
       ) AS nama,
       (j.id_core_modules_features IS NOT NULL) AS aktif
FROM core_modules_features f
JOIN core_modules m ON m.id = f.id_core_modules
LEFT JOIN core_tenant_features j
  ON j.id_core_modules_features = f.id AND j.id_core_tenants = $1
ORDER BY f.id ASC;

-- ================================================================
-- Settings tenant (core_tenant_settings)
-- ================================================================

-- name: ListRowsSettingsTenant :many
-- Baris setting tenant (opsional satu kategori) — hasil GET & PUT settings;
-- ORDER kategori, kunci.
SELECT kategori, kunci, nilai
FROM core_tenant_settings
WHERE id_core_tenants = $1
  AND (sqlc.narg('kategori')::text IS NULL OR kategori = sqlc.narg('kategori')::text)
ORDER BY kategori ASC, kunci ASC;

-- name: DeleteTenantSettingsKategori :exec
-- Hapus seluruh entri SATU kategori settings tenant (langkah REPLACE).
DELETE FROM core_tenant_settings
WHERE id_core_tenants = $1 AND kategori = $2;

-- name: InsertTenantSetting :exec
-- Sisip SATU entri settings (dedupe kunci & cast nilai di service — entri
-- terakhir menang); batch banyak entri = loop panggilan ini dalam executor
-- (tx) yang sama — pola baku audit.InsertEntry.
INSERT INTO core_tenant_settings (id_core_tenants, kategori, kunci, nilai)
VALUES ($1, $2, $3, $4);

-- name: ListKunciSettingsTenant :many
-- Kunci setting satu kategori (urut) — payload event SET_PENGATURAN.
SELECT kunci
FROM core_tenant_settings
WHERE id_core_tenants = $1 AND kategori = $2
ORDER BY kunci ASC;

-- ================================================================
-- Event tenant (core_tenant_events — append-only)
-- ================================================================

-- name: InsertTenantEvent :exec
-- Tulis satu baris event tenant (append-only) — tx sama dengan mutasi.
INSERT INTO core_tenant_events (id_core_tenants, aksi, payload, id_core_users)
VALUES ($1, $2, $3, $4);

-- name: ListRowsEventTenant :many
-- Riwayat event tenant — urut terbaru dulu (id DESC), JOIN aktor (u.name).
SELECT e.id, e.aksi, e.payload, u.name AS aktor, e.created_at
FROM core_tenant_events e
LEFT JOIN core_users u ON u.id = e.id_core_users
WHERE e.id_core_tenants = $1
ORDER BY e.id DESC;

-- ================================================================
-- Keanggotaan (core_users_tenants)
-- ================================================================

-- name: FindAnggotaTenant :one
-- Baris keanggotaan (tenant, user) apa pun statusnya — absen = no rows.
SELECT *
FROM core_users_tenants
WHERE id_core_tenants = $1 AND id_core_users = $2
LIMIT 1;

-- name: GetAnggotaAktif :one
-- Keanggotaan AKTIF (tenant, user) wajib ada — absen → repository 404 SYS-404.
SELECT *
FROM core_users_tenants
WHERE id_core_tenants = $1 AND id_core_users = $2 AND dicabut_pada IS NULL
LIMIT 1;

-- name: InsertTenantMember :one
-- Insert keanggotaan baru (reaktivasi lewat ReaktivasiAnggota).
INSERT INTO core_users_tenants (id_core_tenants, id_core_users, is_default)
VALUES ($1, $2, $3)
RETURNING *;

-- name: ReaktivasiAnggota :one
-- REAKTIVASI keanggotaan lama — dicabut_pada dikosongkan + isDefault payload.
UPDATE core_users_tenants
SET dicabut_pada = NULL, is_default = $2, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: SetDefaultAnggota :one
-- Set keanggotaan sebagai default user (default lain dikosongkan terpisah).
UPDATE core_users_tenants
SET is_default = true, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: CabutAnggota :exec
-- Cabut anggota SOFT — dicabut_pada = now + default dikosongkan.
UPDATE core_users_tenants
SET dicabut_pada = now(), is_default = false, updated_at = now()
WHERE id = $1;

-- name: CountAnggotaAktifLain :one
-- Jumlah anggota AKTIF lain (di luar satu user) — guard cabut anggota terakhir.
SELECT count(*)::int AS count
FROM core_users_tenants
WHERE id_core_tenants = $1
  AND dicabut_pada IS NULL
  AND id_core_users <> $2;

-- name: ClearDefaultLain :exec
-- Kosongkan default keanggotaan LAIN milik user (satu default per user).
UPDATE core_users_tenants
SET is_default = false
WHERE id_core_users = $1 AND is_default = true AND id <> $2;

-- name: ListRowsAnggotaAktif :many
-- Anggota aktif tenant (JOIN core_users) — default dulu, lalu alfabetis.
SELECT ut.id_core_users, u.username, u.name AS nama,
       ut.is_default, ut.dicabut_pada
FROM core_users_tenants ut
JOIN core_users u ON u.id = ut.id_core_users
WHERE ut.id_core_tenants = $1 AND ut.dicabut_pada IS NULL
ORDER BY ut.is_default DESC, u.username ASC;

-- name: GetUserIdentitas :one
-- Username + nama user by id (lengkapi baris keanggotaan; fallback id di service).
SELECT username, name
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: GetUserAda :one
-- User wajib ada — absen → repository 404 SYS-404 bila id tak dikenal.
SELECT id
FROM core_users
WHERE id = $1
LIMIT 1;
