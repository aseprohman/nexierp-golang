-- +goose Up
-- Porting 1:1 dari ddl/65-ecom-portal-v4.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 65-ecom-portal-v4.sql — ECOM portal v4: AUTH MEMBER = CORE_USERS +
-- NORMALISASI MEDIA (LINE katalog) + ALAMAT → WILAYAH CORE
-- Domain   : OdooLikeERP (single tenant konfigurable)
-- Sumber   : keputusan pemilik (kartu beku 2026-11-17 — eksekusi persis) di
--            atas audit fakta live: semua tabel ecom 0 baris; core_users
--            username varchar(42) CHECK lowercase UNIQUE / email varchar(93);
--            wilayah CORE terpasang & terisi (ddl/42; mirror core.ts:1172+).
-- Kartu    : keputusan D-16…D-20 (lanjutan D-01…D-15 kartu
--            docs/arsitektur-database-ecom.md §6):
--   D-16 — Auth member = user pertama non-staf: `ecom_member.id_core_users`
--          bigint 1:1 (UNIQUE) FK→core_users ON UPDATE CASCADE ON DELETE
--          RESTRICT; kolom auth mandiri member DIHAPUS (sandi_hash,
--          gagal_login, terkunci_hingga — padanan core_users.password_hash /
--          failed_login_attempts / locked_until). core_users di-WIDEN agar
--          email (login member) muat: username 42→150, name 42→100,
--          email 93→150; department DROP NOT NULL (user portal non-staf).
--   D-17 — Sesi member = core_sessions + JWT core (tanpa ganda): DROP TABLE
--          ecom_member_sesi (token_hash/device_ref/berlaku_hingga/dicabut_at
--          tidak punya padanan bisnis yang dipakai).
--   D-18 — ecom_member_token TETAP ada: token lupa sandi (F09) tanpa padanan
--          di CORE — tidak ada perubahan DDL (komentar eksisting tidak
--          menyebut sesi lama, jadi tanpa koreksi komentar).
--   D-19 — Alamat member → master wilayah CORE (pemilik CORE; lookup
--          /system/wilayah; rantai hierarki divalidasi aplikasi): 4 kolom
--          varchar free-text provinsi/kota/kecamatan/kelurahan DIGANTI 4 FK
--          RESTRICT → core_provinsi/kota/kecamatan/kelurahan (ddl/42;
--          preseden FK wilayah: ddl/48-inv-gudang-wilayah). Komentar lama
--          provinsi ("master shp_wilayah … D-06") USANG — hilang bersama
--          kolom, diganti komentar FK baru.
--   D-20 — Media katalog dinormalisasi: `ecom_katalog_online.media jsonb`
--          DIHAPUS → tabel LINE baru `ecom_katalog_media` (urutan + jenis
--          GAMBAR|VIDEO + alt, trio audit tanpa entity_id/version);
--          `id_core_files` TETAP sebagai cover denormalisasi gambar utama —
--          jalur sinkron app: nilai = id_core_files baris
--          ecom_katalog_media dengan urutan terkecil.
-- Isi      : §1 widen core_users; §2 ALTER ecom_member (+id_core_users, drop
--            3 kolom auth); §3 DROP TABLE ecom_member_sesi; §4 (tanpa DDL —
--            token tetap, D-18); §5 ALTER ecom_member_alamat (4 varchar →
--            4 FK wilayah + index); §6 DROP media + komentar id_core_files;
--            §7 enum enum_jenis_media_ecom + tabel ecom_katalog_media +
--            trigger updated_at; §8 verifikasi (komentar introspeksi).
-- Idempoten: ALTER TYPE/DROP NOT NULL/DROP COLUMN IF EXISTS/ADD COLUMN IF NOT
--            EXISTS no-op saat ulang; ADD CONSTRAINT di-guard pg_constraint
--            (pola 48); enum fail-loud idiom 36 (pg_type + ::text[]);
--            trigger DROP IF EXISTS + CREATE (pola 36 §3). Satu tx per
--            bagian (BEGIN/COMMIT — preseden 40/43/44/52).
-- Catatan  : semua tabel ecom KOSONG saat patch → ADD COLUMN NOT NULL tanpa
--            default aman. packages/schemas/src/ecom SENGAJA belum dibuat
--            (modul BE ecom menyusul). Seed registry menyusul batch seed.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/65-ecom-portal-v4.sql   (jalankan 2×)
-- =============================================================================

-- =============================================================================
-- §1 — WIDEN core_users (D-16; email member sebagai username, CHECK lowercase
--      & UNIQUE username TIDAK tersentuh ALTER TYPE)
-- =============================================================================
BEGIN;
ALTER TABLE core_users ALTER COLUMN username TYPE varchar(150);
ALTER TABLE core_users ALTER COLUMN name TYPE varchar(100);
ALTER TABLE core_users ALTER COLUMN email TYPE varchar(150);
ALTER TABLE core_users ALTER COLUMN department DROP NOT NULL;
COMMIT;

-- =============================================================================
-- §2 — ecom_member: +id_core_users (1:1 ke core_users), drop kolom auth
--      mandiri (D-16) + koreksi komentar
-- =============================================================================
BEGIN;
ALTER TABLE ecom_member ADD COLUMN IF NOT EXISTS id_core_users bigint;

-- FK — guard pg_constraint (ADD CONSTRAINT tanpa IF NOT EXISTS; pola 48)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ecom_member_core_users'
      AND conrelid = 'ecom_member'::regclass
  ) THEN
    ALTER TABLE ecom_member
      ADD CONSTRAINT fk_ecom_member_core_users
      FOREIGN KEY (id_core_users)
      REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- UNIQUE 1:1 (satu core_users maksimal satu akun member; NULL = belum
-- terhubung — banyak NULL sah)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_ecom_member_core_users'
      AND conrelid = 'ecom_member'::regclass
  ) THEN
    ALTER TABLE ecom_member
      ADD CONSTRAINT uq_ecom_member_core_users UNIQUE (id_core_users);
  END IF;
END $$;
-- +goose StatementEnd


-- Kolom auth mandiri dihapus (padanan hidup di core_users — D-16)
ALTER TABLE ecom_member
  DROP COLUMN IF EXISTS sandi_hash,
  DROP COLUMN IF EXISTS gagal_login,
  DROP COLUMN IF EXISTS terkunci_hingga;

COMMENT ON COLUMN ecom_member.id_core_users IS 'auth member = user pertama non-staf di core_users (1:1 — uq_ecom_member_core_users; email member = username); NULL = akun belum terhubung (D-16)';
COMMENT ON COLUMN ecom_member.email IS 'identitas/kontak member; unik di antara baris hidup (boleh dipakai ulang pasca soft-delete — bukan numbering); LOGIN via core_users.username = email ini (D-16)';
COMMIT;

-- =============================================================================
-- §3 — DROP TABLE ecom_member_sesi (D-17: sesi = core_sessions + JWT core)
-- =============================================================================
BEGIN;
DROP TABLE IF EXISTS ecom_member_sesi;
COMMIT;

-- =============================================================================
-- §4 — ecom_member_token TETAP (D-18): token lupa sandi F09 tanpa padanan
--      core — tanpa perubahan DDL; komentar eksisting tidak menyebut sesi
--      lama, jadi tanpa koreksi komentar. (Bagian sengaja kosong.)
-- =============================================================================

-- =============================================================================
-- §5 — ecom_member_alamat: 4 varchar free-text → 4 FK wilayah CORE (D-19;
--      pemilik CORE, lookup /system/wilayah, hierarki divalidasi aplikasi;
--      preseden ddl/48-inv-gudang-wilayah)
-- =============================================================================
BEGIN;
ALTER TABLE ecom_member_alamat
  DROP COLUMN IF EXISTS provinsi,
  DROP COLUMN IF EXISTS kota,
  DROP COLUMN IF EXISTS kecamatan,
  DROP COLUMN IF EXISTS kelurahan;

ALTER TABLE ecom_member_alamat
  ADD COLUMN IF NOT EXISTS id_core_provinsi  bigint NOT NULL,
  ADD COLUMN IF NOT EXISTS id_core_kota      bigint NOT NULL,
  ADD COLUMN IF NOT EXISTS id_core_kecamatan bigint NOT NULL,
  ADD COLUMN IF NOT EXISTS id_core_kelurahan bigint NOT NULL;

-- 4 FK RESTRICT — master wilayah tidak boleh hilang selama dirujuk
-- (hard-delete diblokir DB; penonaktifan = deleted_at, divalidasi service)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ecom_member_alamat_core_provinsi'
      AND conrelid = 'ecom_member_alamat'::regclass
  ) THEN
    ALTER TABLE ecom_member_alamat
      ADD CONSTRAINT fk_ecom_member_alamat_core_provinsi
      FOREIGN KEY (id_core_provinsi)
      REFERENCES core_provinsi (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ecom_member_alamat_core_kota'
      AND conrelid = 'ecom_member_alamat'::regclass
  ) THEN
    ALTER TABLE ecom_member_alamat
      ADD CONSTRAINT fk_ecom_member_alamat_core_kota
      FOREIGN KEY (id_core_kota)
      REFERENCES core_kota (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ecom_member_alamat_core_kecamatan'
      AND conrelid = 'ecom_member_alamat'::regclass
  ) THEN
    ALTER TABLE ecom_member_alamat
      ADD CONSTRAINT fk_ecom_member_alamat_core_kecamatan
      FOREIGN KEY (id_core_kecamatan)
      REFERENCES core_kecamatan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ecom_member_alamat_core_kelurahan'
      AND conrelid = 'ecom_member_alamat'::regclass
  ) THEN
    ALTER TABLE ecom_member_alamat
      ADD CONSTRAINT fk_ecom_member_alamat_core_kelurahan
      FOREIGN KEY (id_core_kelurahan)
      REFERENCES core_kelurahan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- 4 INDEX FK (join rantai wilayah saat snapshot alamat_kirim checkout)
CREATE INDEX IF NOT EXISTS ix_ecom_member_alamat_core_provinsi
  ON ecom_member_alamat (id_core_provinsi);
CREATE INDEX IF NOT EXISTS ix_ecom_member_alamat_core_kota
  ON ecom_member_alamat (id_core_kota);
CREATE INDEX IF NOT EXISTS ix_ecom_member_alamat_core_kecamatan
  ON ecom_member_alamat (id_core_kecamatan);
CREATE INDEX IF NOT EXISTS ix_ecom_member_alamat_core_kelurahan
  ON ecom_member_alamat (id_core_kelurahan);

COMMENT ON COLUMN ecom_member_alamat.id_core_provinsi IS 'master wilayah pemilik CORE (ddl/42) — lookup /system/wilayah; rantai provinsi→kota→kecamatan→kelurahan divalidasi aplikasi (D-19; komentar lama shp_wilayah/D-06 USANG)';
COMMENT ON COLUMN ecom_member_alamat.id_core_kota IS 'master wilayah pemilik CORE (ddl/42) — hierarki ke provinsi divalidasi aplikasi (D-19)';
COMMENT ON COLUMN ecom_member_alamat.id_core_kecamatan IS 'master wilayah pemilik CORE (ddl/42) — hierarki ke kota divalidasi aplikasi (D-19)';
COMMENT ON COLUMN ecom_member_alamat.id_core_kelurahan IS 'master wilayah pemilik CORE (ddl/42) — hierarki ke kecamatan divalidasi aplikasi; kode_pos bila NULL ikut core_kelurahan.kode_pos (D-19)';
COMMIT;

-- =============================================================================
-- §6 — ecom_katalog_online: DROP media jsonb; id_core_files TETAP sebagai
--      cover denormalisasi + komentar jalur sinkron (D-20)
-- =============================================================================
BEGIN;
ALTER TABLE ecom_katalog_online DROP COLUMN IF EXISTS media;

COMMENT ON COLUMN ecom_katalog_online.id_core_files IS 'cover denormalisasi gambar utama (RESTRICT fk_ecom_katalog_file) — jalur sinkron app: nilai = id_core_files baris ecom_katalog_media urutan terkecil; diperbarui app saat media katalog berubah (D-20)';
COMMIT;

-- =============================================================================
-- §7 — TABEL BARU ecom_katalog_media (LINE anak katalog — D-20): tanpa
--      entity_id/version; trio audit + trigger updated_at pola 36 §3
-- =============================================================================
BEGIN;

-- enum fail-loud idiom 36 (duplikat dengan kosakata sama = no-op; menyimpang
-- = EXCEPTION)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_media_ecom AS ENUM ('GAMBAR', 'VIDEO');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_media_ecom')
     IS DISTINCT FROM ARRAY['GAMBAR', 'VIDEO']::text[] THEN
    RAISE EXCEPTION 'PATCH 65-ecom-portal-v4: enum_jenis_media_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


CREATE TABLE IF NOT EXISTS ecom_katalog_media (
  id                     bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  id_ecom_katalog_online bigint NOT NULL,
  id_core_files          bigint NOT NULL,
  jenis                  enum_jenis_media_ecom NOT NULL DEFAULT 'GAMBAR',
  urutan                 integer NOT NULL DEFAULT 0,
  alt                    varchar(300),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_ecom_katalog_media_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_katalog_media_file FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON DELETE RESTRICT
);

COMMENT ON TABLE ecom_katalog_media IS '[LINE of katalog_online] daftar media tampilan katalog (D-20 — normalisasi mantan kolom media jsonb); gambar utama = urutan terkecil (cover denormalisasi ecom_katalog_online.id_core_files)';
COMMENT ON COLUMN ecom_katalog_media.id_core_files IS 'berkas penyimpanan platform — pemilik CORE (fk_ecom_katalog_media_file RESTRICT)';
COMMENT ON COLUMN ecom_katalog_media.jenis IS 'GAMBAR|VIDEO (enum_jenis_media_ecom — D-20)';
COMMENT ON COLUMN ecom_katalog_media.urutan IS 'urutan tampil dalam katalog; 0 = default; urutan terkecil = gambar utama (sinkron cover id_core_files)';
COMMENT ON COLUMN ecom_katalog_media.alt IS 'teks alternatif aksesibilitas/SEO (bucket 300)';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_katalog_media_hidup
  ON ecom_katalog_media (id_ecom_katalog_online, id_core_files)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_media_urutan
  ON ecom_katalog_media (id_ecom_katalog_online, urutan)
  WHERE deleted_at IS NULL;

-- Trigger updated_at — pola 36 §3 (set_updated_at() milik baseline CORE
-- 01-core, TIDAK dibuat ulang di sini)
-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY['ecom_katalog_media'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd

COMMIT;

-- =============================================================================
-- §8 — VERIFIKASI (komentar introspeksi — jalankan manual SETELAH apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 8.1 core_users (widen D-16):
-- \d+ core_users
--   username varchar(150), name varchar(100), email varchar(150),
--   department nullable; CHECK lowercase + UNIQUE username tetap ada.
-- SELECT character_maximum_length, is_nullable FROM information_schema.columns
--   WHERE table_name='core_users'
--     AND column_name IN ('username','name','email','department')
--   ORDER BY column_name;   -- 150/100/150 + department YES
--
-- -- 8.2 ecom_member (D-16):
-- \d+ ecom_member
--   +id_core_users bigint; tanpa sandi_hash/gagal_login/terkunci_hingga;
--   FK fk_ecom_member_core_users (2 actions: UPDATE cascade / DELETE restrict);
--   UNIQUE uq_ecom_member_core_users; CHECK gagal_login hilang.
-- SELECT count(*) FROM pg_constraint
--   WHERE conrelid='ecom_member'::regclass
--     AND conname IN ('fk_ecom_member_core_users','uq_ecom_member_core_users');  -- 2
-- SELECT count(*) FROM information_schema.columns
--   WHERE table_name='ecom_member'
--     AND column_name IN ('sandi_hash','gagal_login','terkunci_hingga');         -- 0
--
-- -- 8.3 ecom_member_sesi hilang (D-17):
-- SELECT to_regclass('ecom_member_sesi');   -- NULL
--
-- -- 8.4 ecom_member_token tetap (D-18):
-- SELECT to_regclass('ecom_member_token');  -- ecom_member_token
--
-- -- 8.5 ecom_member_alamat (D-19):
-- \d+ ecom_member_alamat
--   tanpa provinsi/kota/kecamatan/kelurahan varchar; +4 bigint NOT NULL;
--   4 FK RESTRICT + 4 index ix_*; komentar provinsi lama hilang.
-- SELECT count(*) FROM pg_constraint
--   WHERE conrelid='ecom_member_alamat'::regclass
--     AND conname LIKE 'fk_ecom_member_alamat_core_%';                           -- 4
-- SELECT count(*) FROM pg_indexes
--   WHERE tablename='ecom_member_alamat'
--     AND indexname LIKE 'ix_ecom_member_alamat_core_%';                         -- 4
--
-- -- 8.6 ecom_katalog_online (D-20):
-- SELECT count(*) FROM information_schema.columns
--   WHERE table_name='ecom_katalog_online' AND column_name='media';              -- 0
--
-- -- 8.7 enum + tabel + trigger baru (D-20):
-- \dT enum_jenis_media_ecom   -- GAMBAR, VIDEO
-- \d+ ecom_katalog_media      -- 9 kolom, 2 FK RESTRICT, uq_hidup + ix_urutan,
--                             -- trigger trg_ecom_katalog_media_updated_at
-- SELECT count(*) FROM pg_trigger
--   WHERE tgrelid='ecom_katalog_media'::regclass AND NOT tgisinternal;           -- 1
--
-- -- 8.8 Rekap FK/index baru patch ini:
-- SELECT conname FROM pg_constraint
--   WHERE conname IN ('fk_ecom_member_core_users','uq_ecom_member_core_users',
--     'fk_ecom_member_alamat_core_provinsi','fk_ecom_member_alamat_core_kota',
--     'fk_ecom_member_alamat_core_kecamatan','fk_ecom_member_alamat_core_kelurahan',
--     'fk_ecom_katalog_media_katalog','fk_ecom_katalog_media_file')
--   ORDER BY conname;   -- 8 baris
-- =============================================================================
-- ddl/65-ecom-portal-v4.sql selesai.
