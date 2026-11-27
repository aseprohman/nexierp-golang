-- permissions.sql — compiler permission efektif RBAC v2.1 SET-based: DUA
-- query persis PermissionCompilerRepository NestJS (union role + override
-- per-user per SET); merge (deny menang) di service Go.

-- (1) UNION code route via SEMUA SET yang di-grant ke role user — hanya SET
-- 'active' dan modulnya enabled (SET tanpa modul tetap dihitung).
-- name: RoleRouteCodes :many
SELECT DISTINCT rt.permission_code AS code
FROM core_users_roles ur
JOIN core_role_permissions rp ON rp.id_core_roles = ur.id_core_roles
JOIN core_permissions p ON p.id = rp.id_core_permissions
JOIN core_permissions_routes pr ON pr.id_core_permissions = rp.id_core_permissions
JOIN core_routes rt ON rt.id = pr.id_core_routes
LEFT JOIN core_modules m ON m.id = p.id_core_modules
WHERE ur.id_core_users = sqlc.arg('user_id')
  AND p.status = 'active'
  AND (p.id_core_modules IS NULL OR m.enabled = true);

-- (2) Override per-user PER SET permission — dipancar ke code route via
-- junction core_permissions_routes; hanya baris hidup (soft-delete) yang
-- belum kedaluwarsa.
-- name: UserRouteOverrides :many
SELECT up.granted, rt.permission_code AS code
FROM core_user_permissions up
JOIN core_permissions p ON p.id = up.id_core_permissions
JOIN core_permissions_routes pr ON pr.id_core_permissions = p.id
JOIN core_routes rt ON rt.id = pr.id_core_routes
WHERE up.id_core_users = sqlc.arg('user_id')
  AND up.deleted_at IS NULL
  AND (up.expires_at IS NULL OR up.expires_at > now());
