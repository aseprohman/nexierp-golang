-- iam.sql — query IAM modul core (padanan repositories/iam/*.ts NestJS):
-- ROUTES (registry core_routes), PERMISSIONS (SET + junction), MENUS
-- (+ junction core_roles_menus), FEATURES, USER-OVERRIDES, DATASCOPE
-- (definitions/assignments/values). List ber-pagination + sort dinamis
-- (routes/permissions/user-overrides) + opsi nilai generik datascope
-- DITULIS LANGSUNG di repository (ORDER BY identifier whitelist statis —
-- sqlc tidak mendukung ORDER BY dinamis; nilai filter tetap parameter $n).

-- ====================================================================
-- ROUTES — registry `core_routes`
-- ====================================================================

-- Peta "METHOD /uri" → permission code (tanpa paging).
-- name: ListAllForMap :many
SELECT method, uri_pattern, permission_code
FROM core_routes;

-- Route by id (baris PENUH) — null bila tidak ada (service → 404).
-- name: FindRouteById :one
SELECT * FROM core_routes WHERE id = $1;

-- ====================================================================
-- PERMISSIONS — SET `core_permissions` + junction `core_permissions_routes`
-- ====================================================================

-- SET permission by id (baris PENUH — audit before/after) — null bila absen.
-- name: FindPermissionById :one
SELECT * FROM core_permissions WHERE id = $1;

-- Id SET by id (guard junction GET /:id/routes) — null bila tidak ada.
-- name: FindPermissionIdById :one
SELECT id FROM core_permissions WHERE id = $1;

-- Duplikat nama SET pada modul (unique per (name, modul)) — modul null
-- dibandingkan baris TANPA modul (IS NULL), persis drizzle isNull.
-- name: FindPermissionDuplicateByName :one
SELECT id FROM core_permissions
WHERE name = $1
  AND ((sqlc.arg('module_id')::bigint IS NOT NULL AND id_core_modules = sqlc.arg('module_id'))
       OR (sqlc.arg('module_id')::bigint IS NULL AND id_core_modules IS NULL))
LIMIT 1;

-- moduleKey by id modul (null → null; modul absen → null).
-- name: FindModuleKeyById :one
SELECT key FROM core_modules WHERE id = $1;

-- Id modul by key (resolveModuleRefs) — null bila absen; perbandingan text
-- agar key di luar enum → 0 baris (404), bukan error kast enum.
-- name: FindModuleIdByKey :one
SELECT id FROM core_modules WHERE key::text = sqlc.arg('module_key')::text LIMIT 1;

-- Id modul by id (ensureModuleExists) — null bila absen.
-- name: FindModuleIdById :one
SELECT id FROM core_modules WHERE id = $1;

-- Id fitur (modul + featuresFolder) — null bila absen.
-- name: FindFeatureIdByModuleAndFolder :one
SELECT id FROM core_modules_features
WHERE id_core_modules = $1 AND features_folder = $2
LIMIT 1;

-- SET masih disandang role? (junction core_role_permissions — DELETE guard).
-- name: FindPermissionRoleUse :one
SELECT id FROM core_role_permissions
WHERE id_core_permissions = $1
LIMIT 1;

-- SET masih terhubung route? (junction core_permissions_routes — DELETE guard).
-- name: FindPermissionRouteUse :one
SELECT id FROM core_permissions_routes
WHERE id_core_permissions = $1
LIMIT 1;

-- Id route ter-junction ke SET (centangan awal panel junction FE).
-- name: ListRouteIdsByPermission :many
SELECT id_core_routes FROM core_permissions_routes
WHERE id_core_permissions = $1;

-- Route id yang ada di antara kandidat (validasi assignRoutes) — verbatim.
-- name: FindExistingRouteIds :many
SELECT id FROM core_routes WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- Jumlah route pada SET (junction) — count persis sumber.
-- name: CountRoutesByPermission :one
SELECT count(*)::int AS route_count FROM core_permissions_routes
WHERE id_core_permissions = $1;

-- Insert SET permission → baris lengkap (audit + view oleh service).
-- name: InsertPermission :one
INSERT INTO core_permissions
  (name, description, id_core_modules, id_core_modules_features, is_system)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- Update SET permission — set parsial via flag (persis drizzle .set(patch)):
-- flag false = kolom tidak disentuh; nilai null = bersihkan kolom.
-- name: UpdatePermission :one
UPDATE core_permissions SET
  name = CASE WHEN sqlc.arg('set_name')::bool THEN sqlc.arg('name') ELSE name END,
  description = CASE WHEN sqlc.arg('set_description')::bool THEN sqlc.arg('description') ELSE description END,
  status = CASE WHEN sqlc.arg('set_status')::bool THEN sqlc.arg('status') ELSE status END,
  id_core_modules = CASE WHEN sqlc.arg('set_module')::bool THEN sqlc.arg('module_id') ELSE id_core_modules END,
  id_core_modules_features = CASE WHEN sqlc.arg('set_feature')::bool THEN sqlc.arg('feature_id') ELSE id_core_modules_features END,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- Hapus SET permission fisik by id (guard role/route oleh service).
-- name: DeletePermissionById :execrows
DELETE FROM core_permissions WHERE id = $1;

-- REPLACE junction SET↔route tahap 1 — hapus seluruh baris milik SET.
-- name: DeleteRoutesByPermission :exec
DELETE FROM core_permissions_routes WHERE id_core_permissions = $1;

-- REPLACE tahap 2 — sisip pasangan (unik pair, idempoten DO NOTHING).
-- name: InsertPermissionRoute :exec
INSERT INTO core_permissions_routes (id_core_routes, id_core_permissions)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;

-- ====================================================================
-- MENUS — `core_menus` + junction `core_roles_menus`
-- ====================================================================

-- Daftar menu FLAT — urut parent, order, id (persis asc(parent),asc(order),asc(id);
-- PG ASC default NULLS LAST). Filter modul opsional (JOIN core_modules.key).
-- name: ListMenusFlat :many
SELECT m.id, m.text, m.url_path, m.parent, m."order", m.class, m.icon, m.external_href, m.created_at, m.updated_at, m.id_core_modules FROM core_menus m
LEFT JOIN core_modules mo ON mo.id = m.id_core_modules
WHERE (sqlc.narg('module_key')::core_module_key IS NULL OR mo.key = sqlc.narg('module_key'))
ORDER BY m.parent ASC, m."order" ASC, m.id ASC;

-- Menu by id (baris PENUH — audit beforeValue) — null bila tidak ada.
-- name: FindMenuById :one
SELECT id, text, url_path, parent, "order", class, icon, external_href, created_at, updated_at, id_core_modules FROM core_menus WHERE id = $1;

-- Id menu by id (ensureMenuExists) — null bila tidak ada.
-- name: FindMenuIdById :one
SELECT id FROM core_menus WHERE id = $1;

-- Peta parent seluruh menu (tabel kecil) — input anti-siklus murni.
-- name: ListParentPairs :many
SELECT id, parent FROM core_menus;

-- Id menu milik SATU role (junction core_roles_menus) — pemakai IAM
-- (assign_roles); RBAC pakai salinannya sendiri (hindari nama bentrok).
-- name: IamListMenuIdsByRole :many
SELECT id_core_menus FROM core_roles_menus WHERE id_core_roles = $1;

-- Role by id ({id, code} — entityId audit assign_roles) — null bila absen.
-- name: FindRoleById :one
SELECT id, code FROM core_roles WHERE id = $1;

-- Id role by id (ensure role ada) — null bila tidak ada.
-- name: FindRoleIdById :one
SELECT id FROM core_roles WHERE id = $1;

-- Menu id yang ada di antara kandidat (validasi menuIds assign) — verbatim.
-- name: FindExistingMenuIds :many
SELECT id FROM core_menus WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- Junction role↔menu masih memegang menu ini? (DELETE guard RESTRICT).
-- name: FindMenuRoleUse :one
SELECT id FROM core_roles_menus WHERE id_core_menus = $1
LIMIT 1;

-- Insert menu → baris lengkap (audit + view oleh service).
-- name: InsertMenu :one
INSERT INTO core_menus
  (text, url_path, parent, "order", class, icon, external_href, id_core_modules)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING id, text, url_path, parent, "order", class, icon, external_href, created_at, updated_at, id_core_modules;

-- Update menu — set parsial via flag (persis drizzle .set(patch)).
-- name: UpdateMenu :one
UPDATE core_menus SET
  text = CASE WHEN sqlc.arg('set_text')::bool THEN sqlc.arg('text') ELSE text END,
  url_path = CASE WHEN sqlc.arg('set_url_path')::bool THEN sqlc.arg('url_path') ELSE url_path END,
  parent = CASE WHEN sqlc.arg('set_parent')::bool THEN sqlc.arg('parent') ELSE parent END,
  "order" = CASE WHEN sqlc.arg('set_order')::bool THEN sqlc.arg('order_index') ELSE "order" END,
  class = CASE WHEN sqlc.arg('set_class')::bool THEN sqlc.arg('class') ELSE class END,
  icon = CASE WHEN sqlc.arg('set_icon')::bool THEN sqlc.arg('icon') ELSE icon END,
  external_href = CASE WHEN sqlc.arg('set_external_href')::bool THEN sqlc.arg('external_href') ELSE external_href END,
  id_core_modules = CASE WHEN sqlc.arg('set_module')::bool THEN sqlc.arg('module_id') ELSE id_core_modules END,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING id, text, url_path, parent, "order", class, icon, external_href, created_at, updated_at, id_core_modules;

-- Hapus menu fisik by id — child ikut (FK parent CASCADE).
-- name: DeleteMenuById :execrows
DELETE FROM core_menus WHERE id = $1;

-- REPLACE junction role↔menu tahap 1 — hapus seluruh baris milik role.
-- name: DeleteMenusByRole :exec
DELETE FROM core_roles_menus WHERE id_core_roles = $1;

-- REPLACE tahap 2 — sisip pasangan (unik pair, idempoten DO NOTHING).
-- name: InsertRoleMenu :exec
INSERT INTO core_roles_menus (id_core_roles, id_core_menus)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;

-- ====================================================================
-- FEATURES — `core_modules_features`
-- ====================================================================

-- Seluruh fitur + key modul — urut key modul lalu folder fitur.
-- name: ListFeaturesJoined :many
SELECT f.id, f.id_core_modules, f.features_folder, f.is_system, f.is_active,
       f.id_core_users_activated, f.active_until, f.id_core_users_deactivated,
       f.deactivated_from, f.created_at, f.updated_at, m.key AS module_key
FROM core_modules_features f
JOIN core_modules m ON m.id = f.id_core_modules
ORDER BY m.key ASC, f.features_folder ASC;

-- Fitur by id + key modul (baris join PENUH) — null bila tidak ada.
-- name: FindFeatureJoinedById :one
SELECT f.id, f.id_core_modules, f.features_folder, f.is_system, f.is_active,
       f.id_core_users_activated, f.active_until, f.id_core_users_deactivated,
       f.deactivated_from, f.created_at, f.updated_at, m.key AS module_key
FROM core_modules_features f
JOIN core_modules m ON m.id = f.id_core_modules
WHERE f.id = $1;

-- Update fitur by id — set siklus aktif penuh (dibangun service: branch
-- activate men-set aktor+active_until; branch deactivate aktor+deactivated_from).
-- name: UpdateFeatureById :one
UPDATE core_modules_features SET
  is_active = $2,
  id_core_users_activated = $3,
  active_until = $4,
  id_core_users_deactivated = $5,
  deactivated_from = $6,
  updated_at = $7
WHERE id = $1
RETURNING *;

-- ====================================================================
-- USER-OVERRIDES — `core_user_permissions` (granularitas PER SET)
-- ====================================================================

-- Baca ulang SATU baris override hidup berbentuk flat JOIN (setelah upsert
-- dijamin ada) — sumber view UserOverrideView. Null bila absen.
-- name: FindOverrideJoinRow :one
SELECT up.id, up.id_core_users AS user_id, u.name AS user_name,
       up.id_core_permissions AS permission_id, p.name AS permission_name,
       up.granted, gb.name AS granted_by_name,
       up.granted_at, up.expires_at
FROM core_user_permissions up
JOIN core_users u ON u.id = up.id_core_users
JOIN core_permissions p ON p.id = up.id_core_permissions
LEFT JOIN core_users gb ON gb.id = up.id_core_users_granted_by
WHERE up.id_core_users = $1 AND up.id_core_permissions = $2
  AND up.deleted_at IS NULL
LIMIT 1;

-- User target by id (404 oleh service) — null bila absen.
-- name: FindUserById :one
SELECT id FROM core_users WHERE id = $1;

-- SET permission by id ({id, name} — entityId audit) — null bila absen.
-- name: FindPermissionNameById :one
SELECT id, name FROM core_permissions WHERE id = $1;

-- Override HIDUP by id baris (baris PENUH — guard soft-delete + audit).
-- name: FindLiveOverrideById :one
SELECT * FROM core_user_permissions
WHERE id = $1 AND deleted_at IS NULL;

-- Upsert override — pasangan unik (user, permission) baris hidup: baris
-- lama di-UPDATE (ON CONFLICT ... WHERE deleted_at IS NULL — baris
-- soft-delete tidak disentuh), persis drizzle target+targetWhere.
-- name: UpsertOverride :exec
INSERT INTO core_user_permissions
  (id_core_users, id_core_permissions, granted, id_core_users_granted_by,
   granted_at, expires_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (id_core_users, id_core_permissions) WHERE deleted_at IS NULL
DO UPDATE SET
  granted = $3::bool,
  expires_at = $6::timestamptz,
  id_core_users_granted_by = $4::bigint,
  granted_at = $5::timestamptz,
  updated_at = $7::timestamptz;

-- SOFT DELETE override by id (deleted_at + updated_at — set dibangun service).
-- name: SoftDeleteOverrideById :exec
UPDATE core_user_permissions
SET deleted_at = $2, updated_at = $3
WHERE id = $1;

-- ====================================================================
-- DATASCOPE — `core_scope_definitions` / `_assignments` / `_values`
-- ====================================================================

-- Baris definisi aktif (tanpa soft-delete) — urut modul lalu scope_key.
-- name: ListScopeDefinitions :many
SELECT * FROM core_scope_definitions
WHERE deleted_at IS NULL
ORDER BY id_core_modules ASC, scope_key ASC;

-- Ringkasan jumlah assignment hidup per definisi (groupBy).
-- name: CountAssignmentsByDefinition :many
SELECT id_core_scope_definitions AS id, count(*)::int AS count
FROM core_scope_assignments
WHERE deleted_at IS NULL
GROUP BY id_core_scope_definitions;

-- Definisi hidup by id (baris PENUH — audit & version If-Match).
-- name: FindScopeDefinitionById :one
SELECT * FROM core_scope_definitions
WHERE id = $1 AND deleted_at IS NULL;

-- (target_table, target_field) definisi hidup — input opsi nilai generik.
-- name: FindScopeDefinitionTarget :one
SELECT target_table, target_field FROM core_scope_definitions
WHERE id = $1 AND deleted_at IS NULL;

-- Duplikat (modul, scope_key) hidup — guard create & pindahan registry.
-- name: FindScopeDefinitionDuplicate :one
SELECT id FROM core_scope_definitions
WHERE id_core_modules = $1 AND scope_key = $2 AND deleted_at IS NULL
LIMIT 1;

-- Id definisi hidup by id (ensureDefinitionExists) — null bila absen.
-- name: FindScopeDefinitionIdById :one
SELECT id FROM core_scope_definitions
WHERE id = $1 AND deleted_at IS NULL;

-- Insert definisi katalog (operator 'in' dibangun service) → baris.
-- name: InsertScopeDefinition :one
INSERT INTO core_scope_definitions
  (id_core_modules, scope_key, label, description, target_table,
   target_field, operator)
VALUES ($1, $2, $3, $4, $5, $6, 'in')
RETURNING *;

-- Update definisi — set parsial via flag; version & updated_at dibangun service.
-- name: UpdateScopeDefinitionById :one
UPDATE core_scope_definitions SET
  label = CASE WHEN sqlc.arg('set_label')::bool THEN sqlc.arg('label') ELSE label END,
  description = CASE WHEN sqlc.arg('set_description')::bool THEN sqlc.arg('description') ELSE description END,
  is_active = CASE WHEN sqlc.arg('set_is_active')::bool THEN sqlc.arg('is_active') ELSE is_active END,
  scope_key = CASE WHEN sqlc.arg('set_scope_key')::bool THEN sqlc.arg('scope_key') ELSE scope_key END,
  id_core_modules = CASE WHEN sqlc.arg('set_module')::bool THEN sqlc.arg('module_id') ELSE id_core_modules END,
  target_table = CASE WHEN sqlc.arg('set_target_table')::bool THEN sqlc.arg('target_table') ELSE target_table END,
  target_field = CASE WHEN sqlc.arg('set_target_field')::bool THEN sqlc.arg('target_field') ELSE target_field END,
  version = sqlc.arg('version')::bigint,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- SOFT delete definisi (deleted_at + updatedAt + version — set dari service).
-- name: SoftDeleteScopeDefinitionById :exec
UPDATE core_scope_definitions
SET deleted_at = $2, updated_at = $3, version = $4
WHERE id = $1;

-- Jumlah assignment HIDUP satu definisi (guard DELETE — 409 oleh service).
-- name: CountAssignmentsLiveByDefinition :one
SELECT count(*)::int AS count FROM core_scope_assignments
WHERE id_core_scope_definitions = $1 AND deleted_at IS NULL;

-- Assignment hidup satu definisi + nama subject (LEFT JOIN) — urut id.
-- name: ListAssignmentsByDefinition :many
SELECT a.id, a.id_core_scope_definitions, a.id_core_roles, a.id_core_users,
       a.is_active, a.note, a.version, a.created_at, a.updated_at,
       r.code AS role_name, u.username AS username
FROM core_scope_assignments a
LEFT JOIN core_roles r ON r.id = a.id_core_roles
LEFT JOIN core_users u ON u.id = a.id_core_users
WHERE a.id_core_scope_definitions = $1 AND a.deleted_at IS NULL
ORDER BY a.id ASC;

-- Seluruh nilai whitelist hidup (urut id PK tabel values) — pengelompokan
-- per assignment di service; kolom pertama = id ASSIGNMENT (alias persis sumber).
-- name: ListAllScopeValues :many
SELECT id_core_scope_assignments AS id, value
FROM core_scope_values
WHERE deleted_at IS NULL
ORDER BY core_scope_values.id ASC;

-- Assignment hidup by id (baris PENUH — audit & version).
-- name: FindScopeAssignmentById :one
SELECT * FROM core_scope_assignments
WHERE id = $1 AND deleted_at IS NULL;

-- Duplikat pasangan hidup (definisi + role XOR user) — role null → bandingkan
-- user (persis ternary sumber); kunci idempoten unique pair partial ddl/50.
-- name: FindAssignmentDuplicate :one
SELECT id FROM core_scope_assignments
WHERE id_core_scope_definitions = $1
  AND deleted_at IS NULL
  AND ((sqlc.arg('role_id')::bigint IS NOT NULL AND id_core_roles = sqlc.arg('role_id'))
       OR (sqlc.arg('role_id')::bigint IS NULL AND id_core_users = sqlc.arg('user_id')))
LIMIT 1;

-- Insert assignment (role ATAU user — XOR divalidasi schema) → baris.
-- name: InsertScopeAssignment :one
INSERT INTO core_scope_assignments
  (id_core_scope_definitions, id_core_roles, id_core_users, note)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- Update assignment — set parsial via flag; version & updated_at di service.
-- name: UpdateScopeAssignmentById :one
UPDATE core_scope_assignments SET
  is_active = CASE WHEN sqlc.arg('set_is_active')::bool THEN sqlc.arg('is_active') ELSE is_active END,
  note = CASE WHEN sqlc.arg('set_note')::bool THEN sqlc.arg('note') ELSE note END,
  version = sqlc.arg('version')::bigint,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- SOFT delete assignment (deleted_at + updatedAt + version — set service).
-- name: SoftDeleteScopeAssignmentById :exec
UPDATE core_scope_assignments
SET deleted_at = $2, updated_at = $3, version = $4
WHERE id = $1;

-- Whitelist nilai satu assignment hidup (urut id PK — view & seeding UI).
-- name: ListScopeValuesOfAssignment :many
SELECT value FROM core_scope_values
WHERE id_core_scope_assignments = $1 AND deleted_at IS NULL
ORDER BY id ASC;

-- Jumlah nilai hidup satu assignment (count persis sumber).
-- name: CountScopeValues :one
SELECT count(*)::int AS count FROM core_scope_values
WHERE id_core_scope_assignments = $1 AND deleted_at IS NULL;

-- Nilai hidup sebelum REPLACE (urut NILAI — snapshot audit `set_values`).
-- name: ListScopeValuesBefore :many
SELECT value FROM core_scope_values
WHERE id_core_scope_assignments = $1 AND deleted_at IS NULL
ORDER BY value ASC;

-- Bulk replace tahap 1 — hapus FISIK nilai yang tak ada di payload.
-- name: DeleteScopeValues :exec
DELETE FROM core_scope_values
WHERE id_core_scope_assignments = sqlc.arg('assignment_id')::bigint
  AND value = ANY(sqlc.arg('values')::varchar[]);

-- Bulk replace tahap 2 — sisip satu nilai (ON CONFLICT DO NOTHING — unique
-- pair NULLS NOT DISTINCT; dipanggil loop oleh repository dalam tx yang sama).
-- name: InsertScopeValue :exec
INSERT INTO core_scope_values (id_core_scope_assignments, value)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;
