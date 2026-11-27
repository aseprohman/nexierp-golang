-- =============================================================================
-- PATCH DDL 85-wa-kampanye-status.sql — WA: kampanye DUA MODE — komposer
-- beberapa STATUS WA terjadwal (selain broadcast lama)
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — keputusan pemilik 2026-11-23: kampanye
--            dipakai untuk pembuatan beberapa STATUS WA (story) dengan
--            jadwal posting per-kampanye (kolom `jadwal` wa_kampanye yang
--            sudah ada), bukan hanya broadcast ke penerima.
-- Isi      : (1) enum + kolom `wa_kampanye.tipe` = BROADCAST|STATUS
--            (default BROADCAST — baris lama tetap broadcast);
--            (2) `wa_kampanye.id_wa_template` jadi NULLABLE — mode STATUS
--            tidak ber-template (konten ada di tiap wa_status anak);
--            integritas tetap dijaga CHECK: BROADCAST wajib template;
--            (3) `wa_status.id_wa_kampanye` FK RESTRICT — 1 kampanye → N
--            status anak; NULL = status mandiri (form status biasa);
--            (4) index hidup anak per kampanye (sweep + progres FE).
-- Jadwal   : tetap di `wa_kampanye.jadwal` (per-kampanye) — sweep memposting
--            anak DRAFT BERURUTAN satu per siklus (gap antar story otomatis
--            dari interval worker CFG-WA-11 + syarat anak sebelumnya final).
-- Kartu    :
--   wa_kampanye | [TRANSAKSI] | wa | +kolom tipe (enum) + id_wa_template
--   nullable + CK tipe/template — mirror Drizzle waKampanye
--   wa_status   | [TRANSAKSI] | wa | +kolom id_wa_kampanye (FK RESTRICT,
--   nullable) — mirror Drizzle waStatus
-- Idempoten: DO-block guard (pg_type/pg_constraint/IF NOT EXISTS) — lari
--            kedua = no-op.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/85-wa-kampanye-status.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Tipe kampanye — enum baru + kolom (default BROADCAST = baris lama).
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  CREATE TYPE enum_tipe_kampanye_wa AS ENUM ('BROADCAST', 'STATUS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE wa_kampanye ADD COLUMN IF NOT EXISTS tipe enum_tipe_kampanye_wa NOT NULL DEFAULT 'BROADCAST';

COMMENT ON COLUMN wa_kampanye.tipe IS 'Mode kampanye: BROADCAST = kirim pesan ke segmen penerima (alur lama); STATUS = komposer beberapa wa_status story terjadwal';

-- -----------------------------------------------------------------------------
-- §2 Template opsional — mode STATUS tidak ber-template; CHECK menegakkan
--    BROADCAST wajib template (integritas di DB, bukan hanya app).
-- -----------------------------------------------------------------------------

ALTER TABLE wa_kampanye ALTER COLUMN id_wa_template DROP NOT NULL;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_wa_kampanye_tipe_template') THEN
    ALTER TABLE wa_kampanye
      ADD CONSTRAINT ck_wa_kampanye_tipe_template CHECK (
        (tipe = 'BROADCAST' AND id_wa_template IS NOT NULL) OR (tipe = 'STATUS')
      );
  END IF;
END $$;

COMMENT ON CONSTRAINT ck_wa_kampanye_tipe_template ON wa_kampanye IS 'BROADCAST wajib id_wa_template; STATUS tanpa template (konten per wa_status anak)';

-- -----------------------------------------------------------------------------
-- §3 Link anak — wa_status.id_wa_kampanye (RESTRICT: kampanye punya anak
--    hidup tidak boleh terhapus) + index hidup.
-- -----------------------------------------------------------------------------

ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS id_wa_kampanye bigint;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wa_status_kampanye') THEN
    ALTER TABLE wa_status
      ADD CONSTRAINT fk_wa_status_kampanye FOREIGN KEY (id_wa_kampanye)
      REFERENCES wa_kampanye (id) ON DELETE RESTRICT;
  END IF;
END $$;

COMMENT ON COLUMN wa_status.id_wa_kampanye IS 'Kampanye induk (mode STATUS) — 1 kampanye → N status story terjadwal; NULL = status mandiri';

CREATE INDEX IF NOT EXISTS ix_wa_status_kampanye_hidup
  ON wa_status (id_wa_kampanye) WHERE deleted_at IS NULL;

COMMIT;
