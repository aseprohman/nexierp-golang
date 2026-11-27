-- =========================================================================
-- PATCH 69 — wa_instance: kredensial koneksi Evolution via CONFIG ENV
-- =========================================================================
-- KEPUTUSAN PEMILIK (2026-11-18; live DB = acuan):
--  1. Kredensial koneksi Evolution TIDAK disimpan per-instance — SATU
--     deployment Evolution untuk semua instance; kredensial dibaca dari env
--     server: WA_EVOLUTION_BASE_URL + WA_EVOLUTION_APIKEY (getter
--     EnvService waEvolutionBaseUrl/waEvolutionApikey).
--  2. Kolom `wa_instance.environment`, `base_url`, `apikey`,
--     `webhook_token` SUDAH DI-DROP pemilik di live (terverifikasi
--     information_schema 2026-11-18) — patch ini menyelaraskan DDL historis
--     agar idempoten (lolos 2x). WA-BR08 (kredensial terenkripsi per
--     environment) OBSOLETE — diganti "kredensial via config env".
--  3. Webhook = token GLOBAL env WA_WEBHOOK_TOKEN; URL per instance =
--     ${WA_WEBHOOK_URL_PUBLIK}/wa/webhook/${WA_WEBHOOK_TOKEN}; instance
--     di-resolve dari payload vendor field `instance` (nama = wa_instance.nama).
--  4. `nama` baris = instanceName Evolution.
--  5. Tipe `enum_environment_wa` tinggal TANPA pemakai kolom → di-drop.
--     DO-block guarded: cek dulu pg_attribute tak ada kolom memakai; bila
--     masih dipakai → fail-soft (RAISE WARNING, DROP dilewati).
-- Struktur live yang tersisa (jangan disentuh): ck_wa_instance_ambang_positif,
-- fk_wa_instance_persona (SET NULL), uq entity_id, uq_wa_instance_nomor_hidup
-- (partial), uq_wa_instance_default_outbox_hidup (partial), ix_wa_instance_status
-- (partial), ix_wa_instance_persona (partial).
-- =========================================================================

ALTER TABLE wa_instance DROP COLUMN IF EXISTS environment;
ALTER TABLE wa_instance DROP COLUMN IF EXISTS base_url;
ALTER TABLE wa_instance DROP COLUMN IF EXISTS apikey;
ALTER TABLE wa_instance DROP COLUMN IF EXISTS webhook_token;

DO $$
DECLARE
  pemakai int;
BEGIN
  SELECT count(*) INTO pemakai
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_type t ON t.oid = a.atttypid
  WHERE t.typname = 'enum_environment_wa'
    AND n.nspname = current_schema()
    AND a.attnum > 0
    AND NOT a.attisdropped;

  IF pemakai > 0 THEN
    RAISE WARNING 'enum_environment_wa masih dipakai % kolom — DROP TYPE dilewati (fail-soft)', pemakai;
  ELSE
    DROP TYPE IF EXISTS enum_environment_wa;
  END IF;
END
$$;
