-- +goose Up
-- Porting 1:1 dari ddl/68-wa-grup-simulator.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 68-wa-grup-simulator.sql — WA CRM: grup chat + pesan multimedia
-- Domain   : OdooLikeERP (single tenant konfigurable)
-- Sumber   : keputusan pemilik 2026-11-17 — widget operator chat WA harus
--            mendukung GRUP CHAT dan LAMPIRAN multimedia (gambar/audio/video/
--            dokumen office). Kartu dasar: docs/arsitektur-database-wa.md
--            (ddl/66-wa.sql) — patch ini ADDITIVE, tidak mengubah tabel/kolom
--            lama kecuali menambah.
-- Tanggal  : 2026-11-17
-- Prasyarat: ddl/66-wa.sql SUDAH terpasang (14 tabel wa_* + 15 enum).
--            PERINGATAN fail-loud: setelah patch ini, re-run ddl/66-wa.sql
--            sengaja MENYIMPANG guard (kosakata enum_jenis_pesan_wa diperluas)
--            — urutan benar 66 → 68, jangan diulang terbalik. LIVE DB = acuan.
-- Isi      : (a) enum_jenis_pesan_wa + AUDIO, VIDEO (lampiran multimedia);
--            (b) enum_jenis_kontak_wa PERSONAL/GRUP + kolom wa_kontak.jenis
--                (grup = kontak ber-JID @g.us, nama_profil = nama grup);
--            (c) wa_pesan.pengirim_nama (anggota grup — pushName; NULL utk
--                chat pribadi/keluar), wa_pesan.nama_file/ukuran_file/
--                mime_type (metadata lampiran kartu dokumen widget).
-- Idempoten: ADD VALUE IF NOT EXISTS (PG16), CREATE TYPE DO-block fail-loud,
--            ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--             -v ON_ERROR_STOP=1 < ddl/68-wa-grup-simulator.sql  (jalankan 2×)
-- =============================================================================

-- =============================================================================
-- §1 ENUM — perluasan & baru
-- =============================================================================

-- (a) Jenis pesan + multimedia (urutan final live DB: TEKS,GAMBAR,DOKUMEN,
--     UNKNOWN,AUDIO,VIDEO — ADD VALUE selalu append di akhir).
ALTER TYPE enum_jenis_pesan_wa ADD VALUE IF NOT EXISTS 'AUDIO';
ALTER TYPE enum_jenis_pesan_wa ADD VALUE IF NOT EXISTS 'VIDEO';

-- (b) Jenis kontak — chat pribadi atau grup (grup chat widget operator).
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_kontak_wa AS ENUM ('PERSONAL','GRUP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_kontak_wa')
     IS DISTINCT FROM ARRAY['PERSONAL','GRUP']::text[] THEN
    RAISE EXCEPTION 'PATCH 68-wa: enum_jenis_kontak_wa kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 KOLOM — tambahan additive
-- =============================================================================

-- wa_kontak.jenis — PERSONAL (default semua baris lama) | GRUP (JID '@g.us').
ALTER TABLE wa_kontak
  ADD COLUMN IF NOT EXISTS jenis enum_jenis_kontak_wa NOT NULL DEFAULT 'PERSONAL';
CREATE INDEX IF NOT EXISTS ix_wa_kontak_jenis
  ON wa_kontak (jenis) WHERE deleted_at IS NULL;

-- wa_pesan.pengirim_nama — anggota grup yang mengirim (pushName/participant);
-- NULL untuk chat pribadi dan pesan keluar.
ALTER TABLE wa_pesan
  ADD COLUMN IF NOT EXISTS pengirim_nama varchar(100);

-- Metadata lampiran widget (kartu dokumen/gambar/audio): nama asli file,
-- ukuran byte, mime — sumber = core_files saat agen melampirkan / payload
-- webhook vendor. Semua nullable (pesan teks tanpa lampiran).
ALTER TABLE wa_pesan ADD COLUMN IF NOT EXISTS nama_file varchar(255);
ALTER TABLE wa_pesan ADD COLUMN IF NOT EXISTS ukuran_file bigint;
ALTER TABLE wa_pesan ADD COLUMN IF NOT EXISTS mime_type varchar(100);

COMMENT ON COLUMN wa_kontak.jenis IS
  'Jenis kontak — PERSONAL chat pribadi, GRUP grup chat (nomor_wa = JID @g.us) — patch 68.';
COMMENT ON COLUMN wa_pesan.pengirim_nama IS
  'Nama pengirim dalam grup chat (pushName/participant) — NULL di chat pribadi & pesan keluar — patch 68.';
COMMENT ON COLUMN wa_pesan.nama_file IS
  'Nama asli lampiran (gambar/audio/video/dokumen) untuk kartu media widget — patch 68.';
COMMENT ON COLUMN wa_pesan.ukuran_file IS
  'Ukuran lampiran dalam byte — metadata widget, patch 68.';
COMMENT ON COLUMN wa_pesan.mime_type IS
  'MIME type lampiran — menentukan jenis pesan (image/* GAMBAR, audio/* AUDIO, video/* VIDEO, sisanya DOKUMEN) — patch 68.';

-- Trigger trg_wa_kontak_updated_at / trg_wa_pesan_updated_at sudah ada
-- (ddl/66 §4) — BEFORE UPDATE menangani kolom baru otomatis.

-- =============================================================================
-- §3 VERIFIKASI (introspeksi manual SETELAH apply)
-- =============================================================================
-- Enum jenis pesan : SELECT enumlabel FROM pg_enum e JOIN pg_type t ON
--                    t.oid=e.enumtypid WHERE t.typname='enum_jenis_pesan_wa'
--                    ORDER BY enumsortorder; → 6 baris (…,AUDIO,VIDEO)
-- Enum jenis kontak: SELECT enumlabel FROM pg_enum e JOIN pg_type t ON
--                    t.oid=e.enumtypid WHERE t.typname='enum_jenis_kontak_wa'
--                    → PERSONAL,GRUP
-- Kolom            : SELECT column_name FROM information_schema.columns
--                    WHERE table_name='wa_pesan' AND column_name IN
--                    ('pengirim_nama','nama_file','ukuran_file','mime_type'); → 4
--                    … AND table_name='wa_kontak' AND column_name='jenis'; → 1
-- =============================================================================
