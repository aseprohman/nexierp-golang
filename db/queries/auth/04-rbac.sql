-- Query auth: roles & menus untuk view sesi login + /auth/me, cek role
-- ecom_member (login nonaktif), role id by kode + junction (register).
-- Port VERBATIM muatRolesUser / muatMenusUser / punyaRoleKode /
-- cariRoleIdByKode / assignRoleUser.

-- name: MuatRolesUser :many
SELECT r.code, r.role, r.description
FROM core_users_roles ur
JOIN core_roles r ON r.id = ur.id_core_roles
WHERE ur.id_core_users = $1
ORDER BY r.code ASC;

-- name: MuatMenusUser :many
SELECT DISTINCT m.id, m.text, m.url_path, m."order", m.parent, m.icon, m.external_href
FROM core_menus m
JOIN core_roles_menus rm ON rm.id_core_menus = m.id
JOIN core_users_roles ur ON ur.id_core_roles = rm.id_core_roles
WHERE ur.id_core_users = $1
ORDER BY m."order" ASC, m.id ASC;

-- name: PunyaRoleKode :one
SELECT EXISTS (
  SELECT 1
  FROM core_users_roles ur
  JOIN core_roles r ON r.id = ur.id_core_roles
  WHERE ur.id_core_users = $1 AND r.code = $2
) AS ada;

-- name: CariRoleIdByKode :one
SELECT id
FROM core_roles
WHERE code = $1
LIMIT 1;

-- name: AssignRoleUser :exec
INSERT INTO core_users_roles (id_core_users, id_core_roles, id_core_users_assigned_by)
VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;
