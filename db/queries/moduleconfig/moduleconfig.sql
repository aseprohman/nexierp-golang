-- ModuleConfig — padanan ModuleConfigRepository NestJS (tabel
-- core_module_configs; upsert by natural key + optimistic locking version).

-- name: FindRowByKey :many
-- Baris config by natural key (moduleId sudah FK numerik); kosong bila
-- belum ada.
SELECT id, id_core_modules, param_key, param_value, value_type, description,
       version, updated_by, created_at, updated_at
FROM core_module_configs
WHERE id_core_modules = $1
  AND param_key = $2
LIMIT 1;

-- name: InsertIgnoreConflict :many
-- Insert baris baru — kosong (DO NOTHING) bila natural key
-- (id_core_modules, param_key) sudah diperebutkan penulis lain.
INSERT INTO core_module_configs (id_core_modules, param_key, param_value, value_type, updated_by)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (id_core_modules, param_key) DO NOTHING
RETURNING id;

-- name: UpdateConditional :many
-- Update kondisional (optimistic locking) dalam SATU statement:
-- version = version + 1 + catat actor & updated_at. Bila expected_version
-- NULL → tanpa syarat versi (last-write-wins); bila diisi → hanya saat
-- version cocok. Kosong bila tidak mengenai baris (stale / baris lenyap).
UPDATE core_module_configs
SET param_value = $3,
    value_type = $4,
    version = version + 1,
    updated_by = $5,
    updated_at = now()
WHERE id_core_modules = $1
  AND param_key = $2
  AND version = coalesce(sqlc.narg('expected_version'), version)
RETURNING version;

-- name: DeleteHard :many
-- Hard delete satu baris param (override outlet dibatalkan — G-22);
-- kosong bila baris tidak ada (idempoten).
DELETE FROM core_module_configs
WHERE id_core_modules = $1
  AND param_key = $2
RETURNING id;

-- name: FindModuleIdByKey :many
-- FK numerik modul by natural key core_modules.key; kosong bila modul tidak
-- terdaftar (penilaian error ada di service).
SELECT id
FROM core_modules
WHERE key = $1
LIMIT 1;
