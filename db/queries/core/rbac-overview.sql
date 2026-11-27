-- Query RBAC fitur OVERVIEW modul core — port VERBATIM
-- repositories/rbac/overview.repository.ts NestJS (8 agregat + N audit
-- terbaru; limit di-clamp caller 1..100).

-- name: OverviewUserAgg :one
SELECT count(*) AS total,
       count(*) FILTER (WHERE is_active) AS active,
       count(*) FILTER (WHERE locked_until > $1::timestamptz) AS locked
FROM core_users;

-- name: CountMfaEnabled :one
SELECT count(*) AS total
FROM core_user_mfa
WHERE enabled = true;

-- name: CountActiveSessions :one
SELECT count(*) AS total
FROM core_sessions
WHERE is_valid = true AND revoked_at IS NULL AND expires_at > $1::timestamptz;

-- name: CountFailedLogins24h :one
SELECT count(*) AS total
FROM core_login_audit
WHERE success = false AND attempted_at > $1::timestamptz;

-- name: CountRoles :one
SELECT count(*) AS total
FROM core_roles;

-- name: CountRoutes :one
SELECT count(*) AS total
FROM core_routes;

-- name: CountPermissionsActive :one
SELECT count(*) AS total
FROM core_permissions
WHERE status = 'active';

-- name: CountAuditSince :one
SELECT count(*) AS total
FROM core_audit_trail
WHERE at > $1::timestamptz;

-- name: RecentAudit :many
SELECT a.id, a.at, a.id_core_users, a.actor_name, m.key AS module_key,
       a.entity_type, a.entity_id, a.action, a.before_value, a.after_value,
       a.severity, a.ip_address, a.user_agent, a.request_id
FROM core_audit_trail a
LEFT JOIN core_modules m ON m.id = a.id_core_modules
ORDER BY a.at DESC, a.id DESC
LIMIT $1;
