-- Query auth: core_users — login/refresh/me/guard/register/ganti password.
-- Port VERBATIM AuthRepository NestJS (cariUserByUsername, cariUserById,
-- insertUser, kunciGagalLogin, resetLoginSukses, updatePassword,
-- aktifkanUser, cariAktifUserById, cariKaryawanTerlink, cariSecurityMeta).

-- name: GetUserByUsername :one
SELECT id, username, password_hash, name, email, department, is_active,
       failed_login_attempts, locked_until, must_change_password
FROM core_users
WHERE username = $1
LIMIT 1;

-- name: GetUserByID :one
SELECT id, username, password_hash, name, email, department, is_active,
       failed_login_attempts, locked_until, must_change_password
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: GetUserAktifByID :one
SELECT is_active
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: InsertUser :one
INSERT INTO core_users (username, email, name, password_hash, is_active, must_change_password)
VALUES ($1, $2, $3, $4, $5, false)
ON CONFLICT (username) DO NOTHING
RETURNING id, username, name, email, is_active;

-- name: UpdateLoginGagal :exec
UPDATE core_users
SET failed_login_attempts = $1, locked_until = $2
WHERE id = $3;

-- name: UpdateLoginSukses :exec
UPDATE core_users
SET failed_login_attempts = 0, locked_until = NULL, last_login_at = $2,
    password_hash = COALESCE(sqlc.narg('upgraded_hash'), password_hash)
WHERE id = $1;

-- name: UpdatePassword :exec
UPDATE core_users
SET password_hash = $1, password_changed_at = $2, must_change_password = $3
WHERE id = $4;

-- name: AktifkanUser :exec
UPDATE core_users
SET is_active = true, failed_login_attempts = 0, locked_until = NULL, updated_at = $2
WHERE id = $1;

-- name: CariKaryawanTerlink :one
SELECT id
FROM hr_karyawan
WHERE id_core_users = $1 AND deleted_at IS NULL
LIMIT 1;

-- name: CariSecurityMeta :one
SELECT value
FROM core_meta
WHERE id = 'security'
LIMIT 1;
