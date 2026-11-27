-- routes.sql — registry route RBAC: seluruh baris `core_routes` dimuat ke
-- memori RouteRegistry (lazy load, fail-closed saat gagal).

-- name: ListRoutes :many
SELECT method, uri_pattern, permission_code
FROM core_routes;
