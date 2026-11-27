-- Query RBAC fitur MODULES REGISTRY modul core — port VERBATIM
-- repositories/rbac/modules-registry.repository.ts NestJS (list berelasi
-- disabledBy di-JOIN dari core_users + muat by key + update status).

-- name: ListModules :many
SELECT m.id, m.key, m.name, m.tagline, m.tone, m.is_core, m.enabled,
       m.enabled_at, m.disabled_at, u.name AS disabler_name
FROM core_modules m
LEFT JOIN core_users u ON u.id = m.id_core_users;

-- name: MuatModuleByKey :one
SELECT id, key, name, tagline, tone, is_core, enabled, enabled_at,
       disabled_at, id_core_users
FROM core_modules
WHERE key = sqlc.arg('key')::core_module_key
LIMIT 1;

-- name: UpdateModuleStatus :exec
UPDATE core_modules
SET enabled = $2, enabled_at = $3, disabled_at = $4, id_core_users = $5
WHERE id = $1;
