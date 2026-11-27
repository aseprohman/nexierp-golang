-- datascope.sql — evaluator data-scope tiga tabel dinamis (padanan
-- DataScopeRepository NestJS):
--   core_scope_definitions (katalog) → core_scope_assignments (pemberian
--   whitelist ke ROLE/USER) → core_scope_values (himpunan nilai).

-- Definisi aktif untuk scope_key (opsional persempit per modul) — daftar id
-- definisi; kosong = dimensi belum terdaftar (service memutuskan fail-open).
-- name: ScopeDefinitionIDs :many
SELECT id
FROM core_scope_definitions
WHERE scope_key = sqlc.arg('scope_key')
  AND is_active = true
  AND deleted_at IS NULL
  AND (sqlc.narg('module_id')::bigint IS NULL
       OR id_core_modules = sqlc.narg('module_id'));

-- Id semua role milik user (union assignment role).
-- name: UserRoleIDs :many
SELECT id_core_roles
FROM core_users_roles
WHERE id_core_users = sqlc.arg('user_id');

-- Baris assignment aktif milik user ATAU role-nya untuk definisi def_ids —
-- LEFT JOIN values agar assignment dengan 0 nilai tetap terdeteksi (baris
-- value NULL = deny-all, bukan fallback ke role). role_ids kosong (`{}`) =
-- hanya pencocokan user.
-- name: ScopeAssignmentValueRows :many
SELECT a.id_core_users AS user_id, v.value
FROM core_scope_assignments a
JOIN core_scope_definitions d ON d.id = a.id_core_scope_definitions
LEFT JOIN core_scope_values v ON v.id_core_scope_assignments = a.id
WHERE a.id_core_scope_definitions = ANY(sqlc.arg('def_ids')::bigint[])
  AND a.is_active = true
  AND a.deleted_at IS NULL
  AND (
    a.id_core_users = sqlc.arg('user_id')::bigint
    OR (a.id_core_roles IS NOT NULL
        AND a.id_core_roles = ANY(sqlc.arg('role_ids')::bigint[]))
  );
