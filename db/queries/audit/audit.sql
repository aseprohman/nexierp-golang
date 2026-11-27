-- Audit trail pusat — padanan AuditRepository NestJS (kernel audit).
-- Nilai insert DIBANGUN di service; repo hanya menulis/baca.

-- name: ScanModuleIdKeys :many
-- Full-scan core_modules — VERBATIM dari service lama: semua baris diambil,
-- filter per-key dilakukan pemanggil (service) di memori.
SELECT id, key
FROM core_modules;

-- name: InsertEntry :one
-- Insert SATU baris core_audit_trail, kembalikan id baris baru.
-- Batch banyak entri = loop panggilan ini dalam executor (tx) yang sama.
INSERT INTO core_audit_trail (
  at, id_core_users, actor_name, id_core_modules, entity_type, entity_id,
  action, before_value, after_value, severity, ip_address, user_agent, request_id
) VALUES (
  $1, $2, $3, $4, $5, $6,
  $7, $8, $9, $10, $11, $12, $13
)
RETURNING id;
