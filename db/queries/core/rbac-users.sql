-- Query RBAC fitur USERS modul core — port VERBATIM
-- repositories/rbac/users.repository.ts NestJS (list terpagi + filter
-- q/filter[role], detail berelasi, guard baris, tulis user/junction/sesi/
-- riwayat password). Kolom eksplisit generasi baru (tanpa kolom legacy).
--
-- ListUsers/CountUsers param: $1 q kosong-check, $2 pola ILIKE "%q%",
-- $3 kode role filter[role], $4 field sort (whitelist), $5 desc?,
-- $6 limit, $7 offset. ORDER BY CASE hanya cabang sort terpilih yang
-- bernilai (baris lain NULL konsisten = no-op) — padanan orderBy
-- drizzlePageBounds + fallback username ASC.

-- name: ListUsers :many
SELECT id, username, name, email, department, is_active, password_changed_at,
       must_change_password, failed_login_attempts, locked_until, mfa_enabled,
       last_login_at, created_at
FROM core_users
WHERE ($1::text = '' OR username ILIKE $2 OR name ILIKE $2 OR email ILIKE $2)
  AND ($3::text = '' OR EXISTS (
        SELECT 1 FROM core_users_roles ur
        JOIN core_roles r ON r.id = ur.id_core_roles
        WHERE ur.id_core_users = core_users.id AND r.code = $3
      ))
ORDER BY
  CASE WHEN $4::text = 'username'   AND NOT $5::boolean THEN username   END ASC,
  CASE WHEN $4::text = 'username'   AND $5::boolean     THEN username   END DESC,
  CASE WHEN $4::text = 'name'       AND NOT $5::boolean THEN name       END ASC,
  CASE WHEN $4::text = 'name'       AND $5::boolean     THEN name       END DESC,
  CASE WHEN $4::text = 'created_at' AND NOT $5::boolean THEN created_at END ASC,
  CASE WHEN $4::text = 'created_at' AND $5::boolean     THEN created_at END DESC,
  CASE WHEN $4::text = 'updated_at' AND NOT $5::boolean THEN updated_at END ASC,
  CASE WHEN $4::text = 'updated_at' AND $5::boolean     THEN updated_at END DESC
LIMIT $6
OFFSET $7;

-- name: CountUsers :one
SELECT count(*) AS total
FROM core_users
WHERE ($1::text = '' OR username ILIKE $2 OR name ILIKE $2 OR email ILIKE $2)
  AND ($3::text = '' OR EXISTS (
        SELECT 1 FROM core_users_roles ur
        JOIN core_roles r ON r.id = ur.id_core_roles
        WHERE ur.id_core_users = core_users.id AND r.code = $3
      ));

-- name: LoadRolesOfUsers :many
SELECT ur.id_core_users, r.id, r.code, r.role
FROM core_users_roles ur
JOIN core_roles r ON r.id = ur.id_core_roles
WHERE ur.id_core_users = ANY(sqlc.arg('user_ids')::bigint[])
ORDER BY r.code ASC;

-- name: MuatUserByID :one
SELECT id, username, name, email, department, is_active, password_changed_at,
       must_change_password, failed_login_attempts, locked_until, mfa_enabled,
       last_login_at, created_at
FROM core_users
WHERE id = $1
LIMIT 1;

-- name: ListAllRolesLite :many
SELECT id, code, role
FROM core_roles;

-- name: ListAllUsernames :many
SELECT id, username
FROM core_users;

-- name: ListAssignmentsOfUser :many
SELECT id_core_users, id_core_roles, id_core_users_assigned_by, assigned_at
FROM core_users_roles
WHERE id_core_users = $1;

-- name: ListOverridesOfUser :many
SELECT up.id, up.id_core_users, u.name AS user_name,
       up.id_core_permissions, p.name AS permission_name, up.granted,
       gu.name AS granted_by_name, up.granted_at, up.expires_at
FROM core_user_permissions up
JOIN core_users u ON u.id = up.id_core_users
JOIN core_permissions p ON p.id = up.id_core_permissions
LEFT JOIN core_users gu ON gu.id = up.id_core_users_granted_by
WHERE up.id_core_users = $1 AND up.deleted_at IS NULL
ORDER BY up.granted_at DESC;

-- name: ListSessionsOfUser :many
SELECT id, id_core_users, user_name, device_key, login_at, expires_at,
       logout_at, revoked_at, ip_address, user_agent, device, is_valid
FROM core_sessions
WHERE id_core_users = $1;

-- name: MuatMfaByUser :many
SELECT id_core_users, user_name, method, confirmed_at, enabled,
       last_used_at, recovery_codes_left
FROM core_user_mfa
WHERE id_core_users = $1
LIMIT 1;

-- name: ListRolePermissionNames :many
SELECT DISTINCT p.name
FROM core_users_roles ur
JOIN core_role_permissions rp ON rp.id_core_roles = ur.id_core_roles
JOIN core_permissions p ON p.id = rp.id_core_permissions
WHERE ur.id_core_users = $1 AND p.status = 'active'
ORDER BY p.name ASC;

-- name: CariIDByUsername :one
SELECT id
FROM core_users
WHERE username = $1
LIMIT 1;

-- name: ListRolesByIds :many
SELECT id, code, role
FROM core_roles
WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- name: ListRoleCodesOfUser :many
SELECT r.code
FROM core_users_roles ur
JOIN core_roles r ON r.id = ur.id_core_roles
WHERE ur.id_core_users = $1;

-- name: InsertUser :one
INSERT INTO core_users
  (username, email, name, department, password_hash, is_active,
   password_changed_at, must_change_password)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING id, username, name, email, department, is_active,
          password_changed_at, must_change_password, failed_login_attempts,
          locked_until, mfa_enabled, last_login_at, created_at;

-- name: UpdateUserIsActive :exec
UPDATE core_users
SET is_active = $2
WHERE id = $1;

-- name: UpdateUserResetPassword :exec
UPDATE core_users
SET password_hash = $2, must_change_password = true,
    password_changed_at = NULL, failed_login_attempts = 0, locked_until = NULL
WHERE id = $1;

-- name: UpdateUserUnlock :exec
UPDATE core_users
SET failed_login_attempts = 0, locked_until = NULL
WHERE id = $1;

-- name: InsertUserRole :exec
INSERT INTO core_users_roles (id_core_users, id_core_roles, id_core_users_assigned_by)
VALUES ($1, $2, $3);

-- name: InsertUserRoleIfAbsent :exec
INSERT INTO core_users_roles (id_core_users, id_core_roles, id_core_users_assigned_by)
VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;

-- name: DeleteUserRolesByUser :exec
DELETE FROM core_users_roles
WHERE id_core_users = $1;

-- name: CabutSesiAktif :exec
UPDATE core_sessions
SET is_valid = false, revoked_at = $2
WHERE id_core_users = $1 AND is_valid = true AND revoked_at IS NULL;

-- name: InsertPasswordHistory :exec
INSERT INTO core_password_history (id_core_users, user_name, set_at, masked_hash)
VALUES ($1, $2, $3, $4);
