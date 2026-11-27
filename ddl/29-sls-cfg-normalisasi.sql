-- PATCH 29-sls-cfg-normalisasi.sql — normalisasi nilai seed CFG-SLS-09/12
-- ke kosakata opsi resmi (deskripsi DDL 28 & analisa v4 §5.2):
--   CFG-SLS-09 'PERINGATAN'        → 'IZINKAN_PERINGATAN'
--   CFG-SLS-12 'REVIEW_MANUAL'     → 'SELALU_REVIEW_MANUAL'
-- Inkonsistensi data seed (param_value ≠ kosakata opsi) membuat
-- SlsKonfigurasiService fail-loud SLS-026 pada nilai default. Normalisasi
-- HANYA menyentuh nilai legacy persis — suntingan user lain tidak disentuh.
-- Idempoten; jalankan berulang aman.
UPDATE core_module_configs c
SET param_value = 'IZINKAN_PERINGATAN'
FROM core_modules m
WHERE m.id = c.id_core_modules AND m.key = 'sales'
  AND c.param_key = 'CFG-SLS-09' AND c.param_value = 'PERINGATAN';

UPDATE core_module_configs c
SET param_value = 'SELALU_REVIEW_MANUAL'
FROM core_modules m
WHERE m.id = c.id_core_modules AND m.key = 'sales'
  AND c.param_key = 'CFG-SLS-12' AND c.param_value = 'REVIEW_MANUAL';
