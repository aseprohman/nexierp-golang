-- +goose Up
-- Porting 1:1 dari ddl/93-hr-checkin-qr.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 93-hr-checkin-qr.sql — HR: FONDASI CHECK-IN QR + LIVE LOCATION
--                       (master `hr_lokasi_kerja` + jejak QR/GPS di
--                       `hr_absensi` — BATCH A, modul HR)
-- =============================================================================
-- Domain   : NEXIERP · Modul HR (KEPEGAWAIAN) — fitur check-in absensi QR
--            + live location. Keputusan desain TERKUNCI:
--            (1) QR DINAMIS ber-rotasi ±60 detik ber-HMAC PER LOKASI KERJA —
--            STATELESS (TANPA tabel token): payload = lokasi + window index
--            + HMAC(secret_qr, payload); server validasi jendela ±60 dtk
--            tanpa state. `secret_qr` (32 byte hex) sumber HMAC per lokasi,
--            di-rotate oleh HR (mematikan token lama seketika).
--            (2) GPS PEGAWAI WAJIB saat check-in QR + validasi radius
--            haversine terhadap `hr_lokasi_kerja` (radius_meter) — dilakukan
--            di service (batch B); DB hanya menyimpan audit `jarak_meter`.
--            (3) `hr_lokasi_kerja` = MASTER pemilik modul hr (CRUD penuh
--            dibuat batch B/C — patch ini hanya DDL + mirror + zod + seed).
-- Migrasi  : Tabel baru KOSONG + kolom baru NULL — tanpa backfill. Baris
--            absensi lama tetap valid (id_hr_lokasi_kerja/jarak_meter NULL =
--            kanal non-QR). Nilai enum baru 'QR' TIDAK dipakai patch ini
--            (PG: ADD VALUE tak boleh diikuti pemakaian nilai dalam
--            transaksi sama — pemakai baru lahir dari kode batch B).
-- Bedah    : CREATE TABLE + enum baru; ALTER `hr_absensi` murni ADD COLUMN
--            nullable + FK RESTRICT (riwayat absensi menahan hapus lokasi);
--            ALTER TYPE ADD VALUE dengan guard pg_enum; CFG-HR-17 registry.
-- Idempoten: Guard `to_regclass`/`pg_type`/`pg_constraint`/`pg_enum` +
--            `ADD COLUMN IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS` +
--            trigger drop/create + COMMENT + INSERT-if-missing — lari kedua
--            = no-op.
-- Catatan  : Index partial ala konvensi repo (WHERE deleted_at IS NULL);
--            trigger `set_updated_at()` fungsi generik CORE (ddl/01); trio
--            audit + version + entity_id di seluruh baris (STD); unique
--            kode HIDUP (partial) — nonaktif/hapus lepas kode untuk reuse.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/93-hr-checkin-qr.sql
--            (jalankan 2× — lari kedua = no-op). TIDAK dijalankan otomatis
--            oleh sesi ini ke DB dev — diuji di DB test (nexierp_ddl93_test)
--            lalu dieksekusi koordinator setelah review.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 ENUM BARU + TABEL [MASTER] `hr_lokasi_kerja` — lokasi absensi QR
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'enum_status_lokasi_kerja_hr') THEN
    CREATE TYPE enum_status_lokasi_kerja_hr AS ENUM ('AKTIF', 'NONAKTIF');
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.hr_lokasi_kerja') IS NULL THEN
    CREATE TABLE hr_lokasi_kerja (
      id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      entity_id    uuid NOT NULL DEFAULT gen_random_uuid(),
      kode         varchar(50) NOT NULL,   -- KKR-xxx — unique HIDUP (partial)
      nama         varchar(100) NOT NULL,
      keterangan   varchar(300),
      latitude     numeric(9,6) NOT NULL,  -- pusat geofence (WGS84)
      longitude    numeric(9,6) NOT NULL,
      radius_meter integer NOT NULL DEFAULT 150,
      CONSTRAINT ck_hr_lokasi_kerja_radius CHECK (radius_meter > 0),
      secret_qr    varchar(64) NOT NULL,   -- 32 byte hex; sumber HMAC QR rotasi; di-rotate HR
      status       enum_status_lokasi_kerja_hr NOT NULL DEFAULT 'AKTIF',
      version      integer NOT NULL DEFAULT 1,
      created_at   timestamptz NOT NULL DEFAULT now(),
      updated_at   timestamptz NOT NULL DEFAULT now(),
      deleted_at   timestamptz,
      CONSTRAINT uq_hr_lokasi_kerja_entity_id UNIQUE (entity_id),
      CONSTRAINT ck_hr_lokasi_kerja_latitude CHECK (latitude BETWEEN -90 AND 90),
      CONSTRAINT ck_hr_lokasi_kerja_longitude CHECK (longitude BETWEEN -180 AND 180)
    );
  END IF;
END $$;
-- +goose StatementEnd


CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_lokasi_kerja_kode
  ON hr_lokasi_kerja (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_lokasi_kerja_aktif
  ON hr_lokasi_kerja (status)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- §2 TRIGGER set_updated_at — fungsi generik CORE (pola array/loop ddl/90 §3)
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'hr_lokasi_kerja'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §3 ALTER `hr_absensi` — jejak kanal QR: lokasi terpakai + jarak audit
-- -----------------------------------------------------------------------------

ALTER TABLE hr_absensi
  ADD COLUMN IF NOT EXISTS id_hr_lokasi_kerja bigint,
  ADD COLUMN IF NOT EXISTS jarak_meter numeric(10,2);

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_hr_absensi_lokasi'
      AND conrelid = 'hr_absensi'::regclass
  ) THEN
    ALTER TABLE hr_absensi
      ADD CONSTRAINT fk_hr_absensi_lokasi FOREIGN KEY (id_hr_lokasi_kerja)
        REFERENCES hr_lokasi_kerja (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_hr_absensi_lokasi
  ON hr_absensi (id_hr_lokasi_kerja)
  WHERE deleted_at IS NULL AND id_hr_lokasi_kerja IS NOT NULL;

COMMENT ON COLUMN hr_absensi.id_hr_lokasi_kerja IS
  'Lokasi kerja terpakai saat check-in QR (fk_hr_absensi_lokasi RESTRICT — riwayat absensi menahan hapus lokasi); NULL = kanal non-QR (SYSTRAY/KIOSK/MANUAL).';

COMMENT ON COLUMN hr_absensi.jarak_meter IS
  'Jarak pegawai→lokasi kerja (meter, haversine) saat check-in QR — audit validasi radius (service membandingkan radius_meter hr_lokasi_kerja); NULL = kanal non-QR.';

-- -----------------------------------------------------------------------------
-- §4 ALTER TYPE `enum_sumber_absensi_hr` — kanal baru 'QR' (guard pg_enum;
--    NILAI TIDAK dipakai dalam transaksi ini — konstrain PG ADD VALUE)
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'enum_sumber_absensi_hr')
     AND NOT EXISTS (
       SELECT 1 FROM pg_enum e
       JOIN pg_type t ON t.oid = e.enumtypid
       WHERE t.typname = 'enum_sumber_absensi_hr' AND e.enumlabel = 'QR'
     ) THEN
    ALTER TYPE enum_sumber_absensi_hr ADD VALUE 'QR';
  END IF;
END $$;
-- +goose StatementEnd


COMMENT ON TYPE enum_sumber_absensi_hr IS
  'Kanal check-in/out absensi HR: SYSTRAY | KIOSK | MANUAL | QR (check-in QR lokasi kerja — payload HMAC ber-rotasi ±60 dtk + GPS wajib valid radius haversine; ddl/93).';

-- -----------------------------------------------------------------------------
-- §5 CFG-HR-17 — radius default validasi QR (meter) — registry
--    core_module_configs modul `hr` (pola INSERT-if-missing seed-hr-core §1;
--    nilai existing TIDAK pernah ditimpa — konvensi CFG)
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.core_modules') IS NULL
     OR to_regclass('public.core_module_configs') IS NULL THEN
    RAISE EXCEPTION 'ddl/93: registry core belum ada — jalankan ddl/01-core lebih dulu';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'hr') THEN
    RAISE EXCEPTION 'ddl/93: registry core_modules key=''hr'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;
-- +goose StatementEnd


INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, 'CFG-HR-17', '150', 'number'::core_config_value_type,
       'Berapa radius default validasi check-in QR per lokasi kerja (meter)? (1-10000 — override per lokasi hr_lokasi_kerja.radius_meter; haversine GPS wajib)'
FROM core_modules m
WHERE m.key = 'hr'
  AND NOT EXISTS (
    SELECT 1 FROM core_module_configs c
    WHERE c.id_core_modules = m.id AND c.param_key = 'CFG-HR-17'
  );

-- -----------------------------------------------------------------------------
-- §6 COMMENT — kepemilikan modul hr
-- -----------------------------------------------------------------------------

COMMENT ON TABLE hr_lokasi_kerja IS
  'MASTER lokasi kerja absensi QR — PEMILIK MODUL HR (ddl/93, 2026-11-25): geofence (lat/lng/radius_meter) validasi GPS haversine + secret_qr sumber HMAC token QR stateless ber-rotasi ±60 dtk (TANPA tabel token); secret di-rotate HR — token lama mati seketika. CRUD penuh batch B/C.';

COMMENT ON COLUMN hr_lokasi_kerja.secret_qr IS
  'Secret HMAC QR lokasi — entropi acak 32 byte hex (64 char); payload token = lokasi+window+HMAC(secret,payload) divalidasi stateless jendela ±60 dtk; ROTATE oleh HR mematikan token lama seketika; JANGAN pernah diekspos ke FE (view tanpa kolom ini).';

COMMIT;

-- =============================================================================
-- §7 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Tabel  : SELECT to_regclass('public.hr_lokasi_kerja');              → NOT NULL
-- Kolom  : SELECT column_name, data_type FROM information_schema.columns
--          WHERE table_name='hr_lokasi_kerja' ORDER BY ordinal_position;
--          → id, entity_id, kode, nama, keterangan, latitude, longitude,
--            radius_meter, secret_qr, status, version, created_at,
--            updated_at, deleted_at (14)
-- Kolom  : SELECT column_name FROM information_schema.columns
--          WHERE table_name='hr_absensi'
--            AND column_name IN ('id_hr_lokasi_kerja','jarak_meter');
--          → 2 baris
-- FK     : SELECT conname, confdeltype FROM pg_constraint
--          WHERE conname='fk_hr_absensi_lokasi'
--            AND conrelid='hr_absensi'::regclass;
--          → fk_hr_absensi_lokasi (r=RESTRICT)
-- Enum   : SELECT enumlabel FROM pg_enum e
--          JOIN pg_type t ON t.oid=e.enumtypid
--          WHERE t.typname='enum_sumber_absensi_hr' ORDER BY enumsortorder;
--          → SYSTRAY, KIOSK, MANUAL, QR
--          SELECT count(*) FROM pg_type WHERE
--            typname='enum_status_lokasi_kerja_hr';                → 1
-- CK/UQ  : SELECT conname FROM pg_constraint
--          WHERE conrelid='hr_lokasi_kerja'::regclass ORDER BY conname;
--          → ck_hr_lokasi_kerja_latitude, ck_hr_lokasi_kerja_longitude,
--            ck_hr_lokasi_kerja_radius, hr_lokasi_kerja_pkey,
--            uq_hr_lokasi_kerja_entity_id (5)
-- Index  : SELECT indexname FROM pg_indexes
--          WHERE tablename='hr_lokasi_kerja' ORDER BY 1;
--          → ix_hr_lokasi_kerja_aktif, hr_lokasi_kerja_pkey,
--            uq_hr_lokasi_kerja_entity_id, uq_hr_lokasi_kerja_kode (4)
--          SELECT indexname FROM pg_indexes WHERE tablename='hr_absensi'
--            AND indexname='ix_hr_absensi_lokasi';                 → 1 baris
-- Trigger: SELECT tgname FROM pg_trigger
--          WHERE tgrelid='hr_lokasi_kerja'::regclass AND NOT tgisinternal;
--          → trg_hr_lokasi_kerja_updated_at
-- CFG    : SELECT c.param_key, c.param_value, c.value_type
--          FROM core_module_configs c JOIN core_modules m ON m.id=c.id_core_modules
--          WHERE m.key='hr' AND c.param_key='CFG-HR-17';
--          → CFG-HR-17 | 150 | number
-- Kosong : SELECT count(*) FROM hr_lokasi_kerja;                     → 0 (dev)
-- =============================================================================
