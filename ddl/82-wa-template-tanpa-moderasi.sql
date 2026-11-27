-- =============================================================================
-- PATCH DDL 82-wa-template-tanpa-moderasi.sql — WA: template tanpa moderasi
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — template pesan (WA-F08).
-- Keputusan: pemilik 2026-11-23 — alur moderasi WA-BR03 DICABUT untuk
--            template: cukup DRAFT ↔ AKTIF, penyusun boleh memutus sendiri
--            (bisa langsung diaktifkan). KONSEKUENSI:
--            (1) constraint `ck_wa_template_sod` (disetujui ≠ disusun) di-DROP
--                — AKTIFKAN oleh penyusun sendiri sah;
--            (2) alur MENUNGGU_MODERASI keluar (endpoint /ajukan dihapus;
--                nilai enum biarkan — data lama & kompatibilitas);
--            (3) ck_wa_template_aktif_bersetuju TETAP (AKTIF wajib penyetuju:
--                user penyetuju ATAU penyetuju_sistem) — disetujui kini boleh
--                = disusun;
--            (4) WA-BR04 tetap: DRAFTKAN/NONAKTIFKAN wajib alasan.
--            KATALOG & KAMPANYE TIDAK tersentuh — moderasi WA-BR03 mereka
--            tetap berlaku.
-- Tambahan   (keputusan lanjutan pemilik 2026-11-23):
--            (5) template hidup NON-DRAFT → AKTIF SEMUA (default langsung
--                aktif; tanpa aksi lifecycle);
--            (6) enum_status_publikasi_wa + 'DIANTRIKAN' — publikasi status
--                WA lewat BACKGROUND JOB (poll DIANTRIKAN → vendor
--                status@broadcast; bukan kirim sinkron request handler).
-- Kartu    :
--   wa_template | [MASTER] | wa | -constraint ck_wa_template_sod; alur DRAFT↔AKTIF
--                 langsung (tanpa moderasi) | seed: template dibuat lewat UI
-- Idempoten: DO-block guard pg_constraint — lari kedua = no-op.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/82-wa-template-tanpa-moderasi.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Drop ck_wa_template_sod — SoD penyusun≠penyetuju tidak berlaku lagi utk
--    template (AKTIFKAN oleh penyusun sendiri sah — keputusan pemilik).
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_wa_template_sod') THEN
    ALTER TABLE wa_template DROP CONSTRAINT ck_wa_template_sod;
  END IF;
END $$;

COMMENT ON CONSTRAINT ck_wa_template_aktif_bersetuju ON wa_template IS
  'AKTIF wajib penyetuju (user ATAU penyetuju_sistem) — SoD dicabut 2026-11-23: disetujui boleh = disusun (template tanpa moderasi, keputusan pemilik)';

-- -----------------------------------------------------------------------------
-- §2 Template hidup → AKTIF SEMUA (default langsung aktif — tanpa lifecycle;
--    penyetuju_sistem=true bila belum ada penyetuju user — ck tetap terpenuhi)
-- -----------------------------------------------------------------------------
UPDATE wa_template SET
  status          = 'AKTIF',
  penyetuju_sistem = CASE WHEN id_core_users_disetujui IS NULL THEN true ELSE penyetuju_sistem END,
  version         = version + 1,
  updated_at      = now()
WHERE deleted_at IS NULL AND status <> 'AKTIF';

-- -----------------------------------------------------------------------------
-- §3 enum_status_publikasi_wa + 'DIANTRIKAN' — antrean publikasi background
--    job (ADD VALUE idempoten; PG menyimpan posisi di ekor — mirror Drizzle
--    union di-update sesuai urutan: DRAFT, DIANTRIKAN, TERKIRIM, GAGAL)
-- -----------------------------------------------------------------------------
ALTER TYPE enum_status_publikasi_wa ADD VALUE IF NOT EXISTS 'DIANTRIKAN' AFTER 'DRAFT';

COMMIT;

-- =============================================================================
-- §4 TAMBAHAN 2026-11-23 (keputusan pemilik — publikasi status via worker):
-- (a) enum_status_publikasi_wa + nilai 'DIANTRIKAN' (kirim = masuk antrean;
--     job StatusKirimJob memposting ke Evolution @status@broadcast);
--     ALTER TYPE di luar transaksi (praktik aman lintas versi PG);
-- (b) data lama: semua template DRAFT hidup → AKTIF + penyetuju_sistem
--     (template default langsung aktif; tanpa aksi lifecycle);
-- (c) seed CFG-WA-11 (interval job kirim status, ms; 0 = mati).
-- =============================================================================

ALTER TYPE enum_status_publikasi_wa ADD VALUE IF NOT EXISTS 'DIANTRIKAN' AFTER 'DRAFT';

UPDATE wa_template
SET status = 'AKTIF', penyetuju_sistem = true, alasan_moderasi = null, updated_at = now()
WHERE status = 'DRAFT' AND deleted_at IS NULL;

INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, 'CFG-WA-11', '15000', 'number',
  'Interval job kirim status WA (ms) — 0 = job mati (polling antrean DIANTRIKAN)'
FROM core_modules m
WHERE m.key = 'whatsapp-crm'
  AND NOT EXISTS (
    SELECT 1 FROM core_module_configs c
    WHERE c.id_core_modules = m.id AND c.param_key = 'CFG-WA-11');
