-- Query auth: core_sessions — INSERT sesi login, lookup validasi guard/
-- refresh, tutup sesi logout. logout_at/revoked_at selalu NULL saat login
-- (port insertSesi dengan nilai null literal), device tetap 'Browser'.

-- name: InsertSesi :one
INSERT INTO core_sessions
  (id_core_users, user_name, device_key, login_at, expires_at,
   logout_at, revoked_at, ip_address, user_agent, device, is_valid)
VALUES ($1, $2, $3, $4, $5, NULL, NULL, $6, $7, 'Browser', true)
RETURNING id;

-- name: GetSesiByID :one
SELECT id, id_core_users, user_name, login_at, expires_at, logout_at,
       revoked_at, is_valid
FROM core_sessions
WHERE id = $1
LIMIT 1;

-- name: TutupSesi :exec
UPDATE core_sessions
SET is_valid = false, logout_at = $2
WHERE id = $1;
