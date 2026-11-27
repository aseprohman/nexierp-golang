-- Query RBAC fitur ROLES modul core — port VERBATIM
-- repositories/rbac/roles.repository.ts + potongan iam/menus.repository.ts
-- (findRoleIdById + listMenuIdsByRole) NestJS. Grant role = id SET
-- (core_role_permissions); sumber code = core_routes.permission_code via
-- junction core_permissions_routes.

-- name: ListRoles :many
SELECT id, code, role, description, is_system, created_at, updated_at
FROM core_roles
ORDER BY id ASC;

-- name: CountRoleMembers :many
SELECT id_core_roles, count(*) AS total
FROM core_users_roles
GROUP BY id_core_roles;

-- name: CariIDByCode :one
SELECT id
FROM core_roles
WHERE code = $1
LIMIT 1;

-- name: CariRoleIDByID :one
SELECT id
FROM core_roles
WHERE id = $1
LIMIT 1;

-- name: CariRoleIDByCode :one
SELECT id
FROM core_roles
WHERE code = $1
LIMIT 1;

-- name: MuatRoleByID :one
SELECT id, code, role, description, is_system, created_at, updated_at
FROM core_roles
WHERE id = $1
LIMIT 1;

-- name: InsertRole :one
INSERT INTO core_roles (code, role, description, is_system)
VALUES ($1, $2, $3, $4)
RETURNING id, code, role, description, is_system, created_at, updated_at;

-- name: UpdateRoleLabel :one
UPDATE core_roles
SET role = $2, updated_at = $3
WHERE id = $1
RETURNING id, code, role, description, is_system, created_at, updated_at;

-- name: UpdateRoleDescription :one
UPDATE core_roles
SET description = $2, updated_at = $3
WHERE id = $1
RETURNING id, code, role, description, is_system, created_at, updated_at;

-- name: TouchRole :one
UPDATE core_roles
SET updated_at = $2
WHERE id = $1
RETURNING id, code, role, description, is_system, created_at, updated_at;

-- name: ListPermissionCodesOfRole :many
SELECT DISTINCT rt.permission_code
FROM core_role_permissions rp
JOIN core_permissions_routes pr ON pr.id_core_permissions = rp.id_core_permissions
JOIN core_routes rt ON rt.id = pr.id_core_routes
WHERE rp.id_core_roles = $1
ORDER BY rt.permission_code ASC;

-- name: ListPermissionSetIDsOfRole :many
SELECT id_core_permissions
FROM core_role_permissions
WHERE id_core_roles = $1
ORDER BY id_core_permissions ASC;

-- name: CodesOfRoleGrants :many
SELECT DISTINCT rt.permission_code
FROM core_role_permissions rp
JOIN core_permissions_routes pr ON pr.id_core_permissions = rp.id_core_permissions
JOIN core_routes rt ON rt.id = pr.id_core_routes
WHERE rp.id_core_roles = $1;

-- name: ListPermissionTargetsByIds :many
SELECT id, name
FROM core_permissions
WHERE id = ANY(@ids::bigint[]);

-- name: DeleteGrantsByRole :exec
DELETE FROM core_role_permissions
WHERE id_core_roles = $1;

-- name: InsertRoleGrant :exec
INSERT INTO core_role_permissions (id_core_roles, id_core_permissions)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;

-- name: ListMenuIdsByRole :many
SELECT id_core_menus
FROM core_roles_menus
WHERE id_core_roles = $1;
