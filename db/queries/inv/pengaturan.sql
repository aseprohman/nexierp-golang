-- Query fitur PENGATURAN modul INVENTORY — padanan
-- repositories/pengaturan/pengaturan.repository.ts NestJS (baca version +
-- updated_at baris registry `core_module_configs` per param CFG-INV).
--
-- QUIRK VERBATIM (dipertahankan sengaja): filter HANYA param_key TANPA
-- filter modul (pemilik registry: CORE, natural key modul inventory — baris
-- param_key sama milik modul lain bisa ikut terpilih, LIMIT 1 arbitrer);
-- nilainya di-fallback version 0 + updatedAt epoch (1970) oleh service.
-- Tulis nilai TIDAK lewat query ini — via moduleconfig.Service.SetValue
-- (serialisasi + version + 409 VAL-409); audit tetap di service (INV-BR06).

-- name: MuatVersiParam :many
-- version + updatedAt baris registry satu param CFG-INV — found=false bila
-- param belum pernah diset (service fallback epoch + version 0).
SELECT version, updated_at
FROM core_module_configs
WHERE param_key = sqlc.arg('param_key')::text
LIMIT 1;
