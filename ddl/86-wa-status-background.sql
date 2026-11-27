-- =============================================================================
-- PATCH DDL 86-wa-status-background.sql — WA: warna latar story teks
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — form status WA & komposer kampanye STATUS
--            menambah pengaturan `background color` story teks (vendor:
--            sendStatus type text WAJIB backgroundColor+font; hex #RRGGBB
--            divalidasi Baileys assertColor). NULL = default adapter
--            (#047857 emerald). Media (image/video) mengabaikan kolom ini.
-- Kartu    :
--   wa_status | [TRANSAKSI] | wa | +kolom background_color varchar(50)
--   nullable + CHECK format hex — mirror Drizzle waStatus
-- Idempoten: ADD COLUMN IF NOT EXISTS + DO-block guard pg_constraint.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/86-wa-status-background.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom — varchar(50) (bucket kode/label; isi #RRGGBB); NULL = default.
-- -----------------------------------------------------------------------------

ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS background_color varchar(50);

COMMENT ON COLUMN wa_status.background_color IS 'Warna latar story teks hex #RRGGBB (vendor assertColor); NULL = default adapter #047857 — diabaikan utk story media';

-- -----------------------------------------------------------------------------
-- §2 CHECK format hex — integritas di DB (mirror validasi zod #RRGGBB).
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_wa_status_background_hex') THEN
    ALTER TABLE wa_status
      ADD CONSTRAINT ck_wa_status_background_hex CHECK (
        background_color IS NULL OR background_color ~ '^#[0-9a-fA-F]{6}$'
      );
  END IF;
END $$;

COMMENT ON CONSTRAINT ck_wa_status_background_hex ON wa_status IS 'background_color wajib format #RRGGBB bila terisi (mirror regex zod)';

COMMIT;
