-- Modul core — SECURITY + AUDIT-TRAIL + ENVIRONMENT.
-- Port 1:1 repositories/security/*.ts NestJS (Drizzle → sqlc pgx/v5):
--   sessions.repository.ts, security-settings.repository.ts,
--   audit-trail.repository.ts, environment.repository.ts.
-- Semua query jalan lewat executor (pool | tx) gen.DBTX — revoke/mfa/
-- allowlist/environment ditulis DI DALAM tx bisnis yang sama dengan audit.
--
-- Sort whitelist (anti-injection ORDER BY): token '<field>:<asc|desc>'
-- dibangun repository dari peta kolom; token KOSONG ('') = baris default
-- (persis drizzlePageBounds: sort query di-whitelist, default port mock).
-- Tie-break id deterministik ditambahkan persis service NestJS.

-- =============================== SESI ===============================

-- name: PageSessions :many
-- SATU HALAMAN sesi (paging server): search satu kata kunci lintas kolom
-- (user_name/ip_address/user_agent/device); whitelist sort login_at,
-- user_name, expires_at, id; default login_at DESC (terbaru dulu) + tie-break
-- id DESC.
SELECT id, id_core_users, user_name, device_key, login_at, expires_at,
       logout_at, revoked_at, ip_address, user_agent, device, is_valid
FROM core_sessions
WHERE (sqlc.narg('search')::text IS NULL OR (
          user_name ILIKE '%' || sqlc.narg('search')::text || '%'
       OR ip_address ILIKE '%' || sqlc.narg('search')::text || '%'
       OR user_agent ILIKE '%' || sqlc.narg('search')::text || '%'
       OR device ILIKE '%' || sqlc.narg('search')::text || '%'))
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'login_at:asc' THEN login_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'login_at:desc' THEN login_at END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'user_name:asc' THEN user_name END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'user_name:desc' THEN user_name END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'expires_at:asc' THEN expires_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'expires_at:desc' THEN expires_at END DESC,
  CASE WHEN sqlc.arg('sort')::text = '' THEN login_at END DESC,
  id DESC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountSessions :one
-- Total baris sesi untuk filter PageSessions (envelope meta.total).
SELECT count(*)::bigint AS total
FROM core_sessions
WHERE (sqlc.narg('search')::text IS NULL OR (
          user_name ILIKE '%' || sqlc.narg('search')::text || '%'
       OR ip_address ILIKE '%' || sqlc.narg('search')::text || '%'
       OR user_agent ILIKE '%' || sqlc.narg('search')::text || '%'
       OR device ILIKE '%' || sqlc.narg('search')::text || '%'));

-- name: MuatSession :one
-- Satu sesi (id + is_valid) — guard 404 diputuskan service (muatSession).
SELECT id, is_valid
FROM core_sessions
WHERE id = $1
LIMIT 1;

-- name: RevokeSession :exec
-- Revoke sesi — is_valid=false + revoked_at (JwtAuthGuard menolak sesi mati
-- secara alami di request berikutnya); audit tetap di service (tx sama).
UPDATE core_sessions
SET is_valid = false, revoked_at = $2
WHERE id = $1;

-- ============================ LOG LOGIN ==============================

-- name: PageLoginAudit :many
-- SATU HALAMAN log login: filter opsional username (ILIKE username_tried)
-- dan success (eksak); search lintas username_tried/ip_address/user_agent;
-- whitelist sort attempted_at, username_tried, id; default attempted_at DESC
-- + tie-break id DESC.
SELECT id, id_core_users, username_tried, success, fail_reason, ip_address,
       user_agent, attempted_at
FROM core_login_audit
WHERE (sqlc.narg('username')::text IS NULL OR
       username_tried ILIKE '%' || sqlc.narg('username')::text || '%')
  AND (sqlc.narg('success')::bool IS NULL OR success = sqlc.narg('success')::bool)
  AND (sqlc.narg('search')::text IS NULL OR (
          username_tried ILIKE '%' || sqlc.narg('search')::text || '%'
       OR ip_address ILIKE '%' || sqlc.narg('search')::text || '%'
       OR user_agent ILIKE '%' || sqlc.narg('search')::text || '%'))
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'attempted_at:asc' THEN attempted_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'attempted_at:desc' THEN attempted_at END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'username_tried:asc' THEN username_tried END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'username_tried:desc' THEN username_tried END DESC,
  CASE WHEN sqlc.arg('sort')::text = '' THEN attempted_at END DESC,
  id DESC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountLoginAudit :one
-- Total baris log login untuk filter PageLoginAudit.
SELECT count(*)::bigint AS total
FROM core_login_audit
WHERE (sqlc.narg('username')::text IS NULL OR
       username_tried ILIKE '%' || sqlc.narg('username')::text || '%')
  AND (sqlc.narg('success')::bool IS NULL OR success = sqlc.narg('success')::bool)
  AND (sqlc.narg('search')::text IS NULL OR (
          username_tried ILIKE '%' || sqlc.narg('search')::text || '%'
       OR ip_address ILIKE '%' || sqlc.narg('search')::text || '%'
       OR user_agent ILIKE '%' || sqlc.narg('search')::text || '%'));

-- =============================== MFA ================================

-- name: PageMfa :many
-- SATU HALAMAN status MFA per PENGGUNA: LEFT JOIN core_users x core_user_mfa
-- sehingga pengguna tanpa baris MFA tetap tampil (kolom m.* NULL = belum
-- daftar); search lintas name/username/user_name MFA; whitelist sort
-- user_name (users.name), username, id; default users.id ASC (port mock).
SELECT u.id, u.name, u.username,
       m.id_core_users AS mfa_user_id, m.user_name AS mfa_user_name,
       m.method, m.confirmed_at, m.enabled, m.last_used_at,
       m.recovery_codes_left
FROM core_users u
LEFT JOIN core_user_mfa m ON m.id_core_users = u.id
WHERE (sqlc.narg('search')::text IS NULL OR (
          u.name ILIKE '%' || sqlc.narg('search')::text || '%'
       OR u.username ILIKE '%' || sqlc.narg('search')::text || '%'
       OR m.user_name ILIKE '%' || sqlc.narg('search')::text || '%'))
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'user_name:asc' THEN u.name END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'user_name:desc' THEN u.name END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'username:asc' THEN u.username END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'username:desc' THEN u.username END DESC,
  u.id ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountMfa :one
-- Total pengguna untuk filter PageMfa (JOIN dihitung persis service NestJS).
SELECT count(*)::bigint AS total
FROM core_users u
LEFT JOIN core_user_mfa m ON m.id_core_users = u.id
WHERE (sqlc.narg('search')::text IS NULL OR (
          u.name ILIKE '%' || sqlc.narg('search')::text || '%'
       OR u.username ILIKE '%' || sqlc.narg('search')::text || '%'
       OR m.user_name ILIKE '%' || sqlc.narg('search')::text || '%'));

-- name: MuatUserRingkas :one
-- User ringkas (id + nama + flag mfa_enabled) — null bila absen (404 service).
SELECT id, name, mfa_enabled
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: MuatMfaUser :one
-- Baris MFA satu pengguna (PK = FK) — null bila belum mendaftar.
SELECT id_core_users, user_name, method, confirmed_at, enabled, last_used_at,
       recovery_codes_left
FROM core_user_mfa
WHERE id_core_users = $1
LIMIT 1;

-- name: InsertMfa :exec
-- Insert baris MFA baru (belum ada) — nilai dibangun service (setMfaEnabled):
-- method totp, confirmed_at = now bila enable, recovery_codes_left 10/0.
INSERT INTO core_user_mfa (
  id_core_users, user_name, method, confirmed_at, enabled, recovery_codes_left
) VALUES ($1, $2, 'totp', $3, $4, $5);

-- name: UpdateMfa :exec
-- Update flag MFA (sudah ada) — confirmed_at dipertahankan bila pernah
-- dikonfirmasi (dihitung service).
UPDATE core_user_mfa
SET enabled = $2, confirmed_at = $3
WHERE id_core_users = $1;

-- name: UpdateUserMfaEnabled :exec
-- Sinkron flag core_users.mfa_enabled.
UPDATE core_users
SET mfa_enabled = $2
WHERE id = $1;

-- ========================= RIWAYAT PASSWORD =========================

-- name: PagePasswordHistory :many
-- SATU HALAMAN riwayat password: search di kolom user_name; whitelist sort
-- set_at, user_name, id; default set_at DESC (terbaru dulu) + tie-break id.
SELECT id, id_core_users, user_name, set_at, masked_hash
FROM core_password_history
WHERE (sqlc.narg('search')::text IS NULL OR
       user_name ILIKE '%' || sqlc.narg('search')::text || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'set_at:asc' THEN set_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'set_at:desc' THEN set_at END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'user_name:asc' THEN user_name END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'user_name:desc' THEN user_name END DESC,
  CASE WHEN sqlc.arg('sort')::text = '' THEN set_at END DESC,
  id DESC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountPasswordHistory :one
-- Total baris riwayat password untuk filter PagePasswordHistory.
SELECT count(*)::bigint AS total
FROM core_password_history
WHERE (sqlc.narg('search')::text IS NULL OR
       user_name ILIKE '%' || sqlc.narg('search')::text || '%');

-- ============================ IP ALLOWLIST ==========================

-- name: PageIpAllowlist :many
-- SATU HALAMAN aturan allowlist dengan JOIN core_roles untuk roleCode view;
-- search lintas target/cidr/note; whitelist sort target, cidr, created_at,
-- id; default id ASC (port mock).
SELECT r.id, r.id_core_roles, r.id_core_users, r.target, r.cidr, r.note,
       r.created_at, ro.code AS role_code
FROM core_ip_allowlist r
LEFT JOIN core_roles ro ON ro.id = r.id_core_roles
WHERE (sqlc.narg('search')::text IS NULL OR (
          r.target ILIKE '%' || sqlc.narg('search')::text || '%'
       OR r.cidr ILIKE '%' || sqlc.narg('search')::text || '%'
       OR r.note ILIKE '%' || sqlc.narg('search')::text || '%'))
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'target:asc' THEN r.target END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'target:desc' THEN r.target END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'cidr:asc' THEN r.cidr END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'cidr:desc' THEN r.cidr END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'created_at:asc' THEN r.created_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'created_at:desc' THEN r.created_at END DESC,
  r.id ASC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountIpAllowlist :one
-- Total aturan untuk filter PageIpAllowlist (JOIN dihitung persis service).
SELECT count(*)::bigint AS total
FROM core_ip_allowlist r
LEFT JOIN core_roles ro ON ro.id = r.id_core_roles
WHERE (sqlc.narg('search')::text IS NULL OR (
          r.target ILIKE '%' || sqlc.narg('search')::text || '%'
       OR r.cidr ILIKE '%' || sqlc.narg('search')::text || '%'
       OR r.note ILIKE '%' || sqlc.narg('search')::text || '%'));

-- name: MuatNamaUser :one
-- Nama user untuk label target `User: <nama>` — null bila absen (404 service).
SELECT name
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: MuatRoleByCode :one
-- Role by code untuk label target `Role: <label>` — null bila absen.
SELECT id, role
FROM core_roles
WHERE code = $1
LIMIT 1;

-- name: InsertIpAllowlist :exec
-- Insert aturan allowlist (FK tetap id numerik) — nilai dibangun service.
INSERT INTO core_ip_allowlist (id_core_roles, id_core_users, target, cidr, note)
VALUES ($1, $2, $3, $4, $5);

-- name: MuatIpAllowlist :one
-- Aturan allowlist (target + cidr untuk audit before) — null bila absen.
SELECT target, cidr
FROM core_ip_allowlist
WHERE id = $1
LIMIT 1;

-- name: DeleteIpAllowlist :exec
-- Hapus aturan allowlist by id (DELETE fisik — tanpa soft delete).
DELETE FROM core_ip_allowlist
WHERE id = $1;

-- ============================ AUDIT TRAIL ===========================

-- name: ListAuditActions :many
-- DAFTAR AKSI DISTINCT (sumber opsi dropdown filter) — 1 query ringan,
-- dibatasi 200, urut abjad.
SELECT DISTINCT action
FROM core_audit_trail
ORDER BY action ASC
LIMIT 200;

-- name: PageAuditTrail :many
-- SATU HALAMAN audit trail: filter module_key (natural key core_modules,
-- enum dibandingkan via ::text), severity, action (eksak), query teks bebas
-- (actor_name/entity_type/entity_id/action/modules.key::text), rentang
-- tanggal UTC date_from inklusif - date_to eksklusif awal hari berikutnya;
-- whitelist sort at, id, severity; default at DESC + tie-break id DESC.
SELECT t.id, t.at, t.id_core_users, t.actor_name, t.entity_type, t.entity_id,
       t.action, t.before_value, t.after_value, t.severity, t.ip_address,
       t.user_agent, t.request_id, m.key AS module_key
FROM core_audit_trail t
LEFT JOIN core_modules m ON m.id = t.id_core_modules
WHERE (sqlc.narg('module_key')::text IS NULL OR
       m.key::text = sqlc.narg('module_key')::text)
  AND (sqlc.narg('severity')::text IS NULL OR
       t.severity::text = sqlc.narg('severity')::text)
  AND (sqlc.narg('action')::text IS NULL OR t.action = sqlc.narg('action')::text)
  AND (sqlc.narg('query')::text IS NULL OR (
          t.actor_name ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_type ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_id ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.action ILIKE '%' || sqlc.narg('query')::text || '%'
       OR m.key::text ILIKE '%' || sqlc.narg('query')::text || '%'))
  AND (sqlc.narg('date_from')::timestamptz IS NULL OR
       t.at >= sqlc.narg('date_from')::timestamptz)
  AND (sqlc.narg('date_to')::timestamptz IS NULL OR
       t.at < sqlc.narg('date_to')::timestamptz)
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'at:asc' THEN t.at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'at:desc' THEN t.at END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'severity:asc' THEN t.severity END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'severity:desc' THEN t.severity END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'id:asc' THEN t.id END ASC,
  CASE WHEN sqlc.arg('sort')::text = '' THEN t.at END DESC,
  t.id DESC
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountAuditTrail :one
-- Total baris audit trail untuk filter PageAuditTrail.
SELECT count(*)::bigint AS total
FROM core_audit_trail t
LEFT JOIN core_modules m ON m.id = t.id_core_modules
WHERE (sqlc.narg('module_key')::text IS NULL OR
       m.key::text = sqlc.narg('module_key')::text)
  AND (sqlc.narg('severity')::text IS NULL OR
       t.severity::text = sqlc.narg('severity')::text)
  AND (sqlc.narg('action')::text IS NULL OR t.action = sqlc.narg('action')::text)
  AND (sqlc.narg('query')::text IS NULL OR (
          t.actor_name ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_type ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_id ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.action ILIKE '%' || sqlc.narg('query')::text || '%'
       OR m.key::text ILIKE '%' || sqlc.narg('query')::text || '%'))
  AND (sqlc.narg('date_from')::timestamptz IS NULL OR
       t.at >= sqlc.narg('date_from')::timestamptz)
  AND (sqlc.narg('date_to')::timestamptz IS NULL OR
       t.at < sqlc.narg('date_to')::timestamptz);

-- name: EksporAuditTrail :many
-- Seluruh baris cocok TANPA pagination (bahan ekspor CSV service) — urut
-- at DESC, id DESC, dibatasi LIMIT 50.000 (guard memori ekspor).
SELECT t.id, t.at, t.id_core_users, t.actor_name, t.entity_type, t.entity_id,
       t.action, t.before_value, t.after_value, t.severity, t.ip_address,
       t.user_agent, t.request_id, m.key AS module_key
FROM core_audit_trail t
LEFT JOIN core_modules m ON m.id = t.id_core_modules
WHERE (sqlc.narg('module_key')::text IS NULL OR
       m.key::text = sqlc.narg('module_key')::text)
  AND (sqlc.narg('severity')::text IS NULL OR
       t.severity::text = sqlc.narg('severity')::text)
  AND (sqlc.narg('action')::text IS NULL OR t.action = sqlc.narg('action')::text)
  AND (sqlc.narg('query')::text IS NULL OR (
          t.actor_name ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_type ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.entity_id ILIKE '%' || sqlc.narg('query')::text || '%'
       OR t.action ILIKE '%' || sqlc.narg('query')::text || '%'
       OR m.key::text ILIKE '%' || sqlc.narg('query')::text || '%'))
  AND (sqlc.narg('date_from')::timestamptz IS NULL OR
       t.at >= sqlc.narg('date_from')::timestamptz)
  AND (sqlc.narg('date_to')::timestamptz IS NULL OR
       t.at < sqlc.narg('date_to')::timestamptz)
ORDER BY t.at DESC, t.id DESC
LIMIT 50000;

-- ============================ ENVIRONMENT ===========================

-- name: ListKategori :many
-- Seluruh baris kategori konfigurasi (urut kanonik dilakukan service:
-- company, smtp, app, storage).
SELECT id, fields, created_at, updated_at
FROM core_app_settings;

-- name: MuatKategori :one
-- Satu kategori by natural key — null bila absen (404 diputuskan service).
SELECT id, fields, created_at, updated_at
FROM core_app_settings
WHERE id = $1
LIMIT 1;

-- name: MuatMeta :one
-- Satu baris meta by key (mis. "company_logo") — null bila absen.
SELECT id, value, created_at, updated_at
FROM core_meta
WHERE id = $1
LIMIT 1;

-- name: UpdateFieldsKategori :exec
-- Update kolom jsonb `fields` satu kategori — payload dibangun service
-- (merge hanya key dikenal; updated_at tidak disentuh — persis drizzle set).
UPDATE core_app_settings
SET fields = $2
WHERE id = $1;

-- name: UpsertMeta :exec
-- Upsert meta by PK natural key (onConflictDoUpdate kolom value saja —
-- key tidak berubah) — nilai dibangun service.
INSERT INTO core_meta (id, value)
VALUES ($1, $2)
ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;
