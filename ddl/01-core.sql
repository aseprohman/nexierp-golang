-- =============================================================================
-- PATCH DDL 01-core.sql — Modul CORE (fondasi auth/RBAC/menu/audit/layanan)
-- Domain   : OdooLikeERP (single tenant, konfigurable, Profil Skala PS1/PS2/PS3)
-- Kartu    : docs/arsitektur-database-core-inv.md
-- Idempoten: aman dijalankan berulang (enum DO-block, IF NOT EXISTS, trigger DO-block)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Util: satu jalur refresh updated_at (K-04/D-04)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- Enum (K-07)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_modul AS ENUM ('AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_pengguna AS ENUM ('AKTIF', 'DINONAKTIFKAN', 'DITANGGUHKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_aktif AS ENUM ('AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_aksi_baku AS ENUM ('BACA', 'CREATE', 'TULIS', 'AJUKAN', 'SETUJUI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_penugasan AS ENUM ('AKTIF', 'BERAKHIR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_notifikasi AS ENUM ('TERKIRIM', 'DIBACA', 'DIARSIPKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_nilai_konfig AS ENUM ('TEKS', 'ANGKA', 'BOOLEAN', 'OPSI', 'JSON');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- core_modul — registry modul/fitur [CONFIG]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_modul (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(10) NOT NULL,
  nama        varchar(100) NOT NULL,
  deskripsi   varchar(200),
  status      enum_status_modul NOT NULL DEFAULT 'AKTIF',
  urutan      int NOT NULL DEFAULT 0,
  version     int NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_core_modul_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_modul_kode UNIQUE (kode)
);

-- -----------------------------------------------------------------------------
-- core_users — pengguna [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_users (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id     uuid NOT NULL DEFAULT gen_random_uuid(),
  username      varchar(50) NOT NULL,
  nama_lengkap  varchar(150) NOT NULL,
  email         varchar(150),
  no_telepon    varchar(50),
  foto_path     varchar(300),
  status        enum_status_pengguna NOT NULL DEFAULT 'AKTIF',
  version       int NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT uq_core_users_entity_id UNIQUE (entity_id),
  -- username tak pernah dipakai ulang (identitas login global)
  CONSTRAINT uq_core_users_username UNIQUE (username)
);

CREATE INDEX IF NOT EXISTS ix_core_users_status ON core_users (status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_users_email
  ON core_users (email) WHERE deleted_at IS NULL AND email IS NOT NULL;

-- -----------------------------------------------------------------------------
-- core_kredensial — hash argon2 + versi [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_kredensial (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users     bigint NOT NULL,
  hash_argon2       varchar(150) NOT NULL,          -- encoded PHC; plaintext tidak pernah disimpan
  versi_kredensial  int NOT NULL DEFAULT 1,         -- naik tiap ganti -> invalidate JWT lama
  version           int NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_core_kredensial_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_kredensial_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT
);

-- satu kredensial AKTIF per pengguna; kredensial lama = soft delete (riwayat selamat)
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_kredensial_aktif
  ON core_kredensial (id_core_users) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- core_sessions — sesi login [SESSION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_sessions (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users   bigint,
  token           varchar(300) NOT NULL,            -- token tersimpan dalam bentuk hash
  ip              varchar(50),
  user_agent      varchar(300),
  kadaluarsa_pada timestamptz NOT NULL,
  ditutup_pada    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_sessions_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_sessions_token UNIQUE (token),
  CONSTRAINT fk_core_sessions_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_core_sessions_users ON core_sessions (id_core_users, kadaluarsa_pada);

-- -----------------------------------------------------------------------------
-- core_password_resets — permintaan reset sandi [SESSION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_password_resets (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users   bigint NOT NULL,
  token           varchar(300) NOT NULL,
  kadaluarsa_pada timestamptz NOT NULL,
  dipakai_pada    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_password_resets_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_password_resets_token UNIQUE (token),
  CONSTRAINT fk_core_password_resets_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_core_password_resets_kadaluarsa
  ON core_password_resets (kadaluarsa_pada);

-- -----------------------------------------------------------------------------
-- core_roles — role [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_roles (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,
  nama        varchar(100) NOT NULL,
  deskripsi   varchar(200),
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     int NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_core_roles_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_roles_kode UNIQUE (kode)      -- immutable; rename = patch seed terurut
);

-- -----------------------------------------------------------------------------
-- core_grup_izin — permission = grup rute [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_grup_izin (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,
  nama        varchar(150) NOT NULL,
  deskripsi   varchar(200),
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     int NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_core_grup_izin_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_grup_izin_kode UNIQUE (kode)  -- nama grup immutable & unik
);

-- -----------------------------------------------------------------------------
-- core_routes — kode izin satu tempat [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_routes (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id          uuid NOT NULL DEFAULT gen_random_uuid(),
  kode               varchar(100) NOT NULL,          -- permission_code satu tempat
  path               varchar(300) NOT NULL,
  metode             varchar(50) NOT NULL DEFAULT 'GET',
  aksi               enum_aksi_baku NOT NULL,        -- 5 aksi baku model grup v2
  id_core_grup_izin  bigint NOT NULL,
  deskripsi          varchar(200),
  version            int NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CONSTRAINT uq_core_routes_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_routes_kode UNIQUE (kode),
  CONSTRAINT fk_core_routes_grup FOREIGN KEY (id_core_grup_izin)
    REFERENCES core_grup_izin (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_core_routes_grup ON core_routes (id_core_grup_izin);

-- -----------------------------------------------------------------------------
-- core_menus — menu dinamis per role [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_menus (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id     uuid NOT NULL DEFAULT gen_random_uuid(),
  kode          varchar(50) NOT NULL,
  label         varchar(100) NOT NULL,
  path          varchar(300),
  ikon          varchar(100),
  urutan        int NOT NULL DEFAULT 0,
  id_core_menus bigint,
  id_core_modul bigint NOT NULL,
  version       int NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT uq_core_menus_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_menus_kode UNIQUE (kode),
  CONSTRAINT fk_core_menus_parent FOREIGN KEY (id_core_menus)
    REFERENCES core_menus (id) ON DELETE SET NULL,
  CONSTRAINT fk_core_menus_modul FOREIGN KEY (id_core_modul)
    REFERENCES core_modul (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_core_menus_parent ON core_menus (id_core_menus);
CREATE INDEX IF NOT EXISTS ix_core_menus_modul ON core_menus (id_core_modul);

-- -----------------------------------------------------------------------------
-- Junctions (N:M murni) — trio audit menyeluruh (D-03)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_users_roles (
  id_core_users  bigint NOT NULL,
  id_core_roles  bigint NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT pk_core_users_roles PRIMARY KEY (id_core_users, id_core_roles),
  CONSTRAINT fk_core_users_roles_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_users_roles_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS core_roles_grup_izin (
  id_core_roles     bigint NOT NULL,
  id_core_grup_izin bigint NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT pk_core_roles_grup_izin PRIMARY KEY (id_core_roles, id_core_grup_izin),
  CONSTRAINT fk_core_roles_grup_izin_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_roles_grup_izin_grup FOREIGN KEY (id_core_grup_izin)
    REFERENCES core_grup_izin (id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS core_roles_menus (
  id_core_roles bigint NOT NULL,
  id_core_menus bigint NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT pk_core_roles_menus PRIMARY KEY (id_core_roles, id_core_menus),
  CONSTRAINT fk_core_roles_menus_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_roles_menus_menus FOREIGN KEY (id_core_menus)
    REFERENCES core_menus (id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- core_penugasan — penugasan & data-scope [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_penugasan (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users  bigint NOT NULL,
  id_core_roles  bigint NOT NULL,
  kode_satuan    varchar(50) NOT NULL,             -- transitional, lihat kartu D-13
  status         enum_status_penugasan NOT NULL DEFAULT 'AKTIF',
  mulai_pada     timestamptz NOT NULL DEFAULT now(),
  berakhir_pada  timestamptz,
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_core_penugasan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_penugasan_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_penugasan_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_penugasan_aktif
  ON core_penugasan (id_core_users, id_core_roles, kode_satuan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_penugasan_users ON core_penugasan (id_core_users);

-- -----------------------------------------------------------------------------
-- core_audit — audit trail [LOG/EVENT] append-only
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_audit (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  tabel_sumber      varchar(50) NOT NULL,
  entity_id_sumber  varchar(255) NOT NULL,           -- Tier B subjek audit (kode/id baris)
  aksi              varchar(100) NOT NULL,           -- create/update/approve/login_gagal/lockout/...
  id_core_users     bigint,                          -- NULL = aktor [sistem]
  payload           jsonb,                           -- snapshot perubahan/event; tidak difilter
  ip                varchar(50),
  user_agent        varchar(300),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),  -- beku di log
  deleted_at        timestamptz,                         -- selalu NULL
  CONSTRAINT uq_core_audit_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_audit_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_core_audit_subjek
  ON core_audit (tabel_sumber, entity_id_sumber, created_at);
CREATE INDEX IF NOT EXISTS ix_core_audit_aktor
  ON core_audit (id_core_users, created_at);

-- -----------------------------------------------------------------------------
-- core_penomoran — nomor dokumen anti-race [CONFIG]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_penomoran (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        varchar(255) NOT NULL,            -- Tier B komposit MODUL:JENIS:PERIODE
  id_core_modul    bigint NOT NULL,
  jenis_dokumen    varchar(50) NOT NULL,             -- GERAKAN, ADJ, LC, SO, PO, FAKTUR, SESI, ...
  periode          varchar(50) NOT NULL DEFAULT 'GLOBAL',
  format           varchar(100) NOT NULL,            -- mis. GR/{YYYY}/{MM}/{SEQ:5}
  nomor_berikutnya bigint NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_core_penomoran_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_penomoran_komposit UNIQUE (id_core_modul, jenis_dokumen, periode),
  CONSTRAINT fk_core_penomoran_modul FOREIGN KEY (id_core_modul)
    REFERENCES core_modul (id) ON DELETE RESTRICT
);
-- Tanpa kolom version: mutasi via atomic UPDATE nomor_berikutnya = nomor_berikutnya + 1
-- RETURNING (D-12); optimistic locking justru merusak throughput penomoran.

-- -----------------------------------------------------------------------------
-- core_konfigurasi — registry CFG (Profil Skala + parameter modul) [CONFIG]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_konfigurasi (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      varchar(255) NOT NULL,              -- Tier B komposit MODUL:KODE_CFG
  id_core_modul  bigint NOT NULL,
  kode_cfg       varchar(50) NOT NULL,               -- mis. CFG-INV-05
  nama           varchar(200) NOT NULL,
  pertanyaan     varchar(300),                       -- pertanyaan bisnis di UI konfigurasi
  opsi           jsonb,                              -- daftar pilihan untuk UI; tidak difilter
  jenis_nilai    enum_jenis_nilai_konfig NOT NULL DEFAULT 'TEKS',
  nilai_teks     varchar(300),                       -- nilai efektif; baca via service, tidak di-join
  terkunci       boolean NOT NULL DEFAULT false,     -- CFG kritis hanya diubah admin
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_core_konfigurasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_konfigurasi_komposit UNIQUE (id_core_modul, kode_cfg),
  CONSTRAINT fk_core_konfigurasi_modul FOREIGN KEY (id_core_modul)
    REFERENCES core_modul (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_core_konfigurasi_modul ON core_konfigurasi (id_core_modul);

-- -----------------------------------------------------------------------------
-- core_notifikasi — notifikasi lintas role [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_notifikasi (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users    bigint,                           -- penerima; NULL = broadcast
  id_core_roles    bigint,                           -- target role bila broadcast
  judul            varchar(200) NOT NULL,
  isi              text,                             -- prosa bebas (K-08)
  jenis            varchar(50) NOT NULL,             -- approval/status/peringatan_stok/...
  status           enum_status_notifikasi NOT NULL DEFAULT 'TERKIRIM',
  dibaca_pada      timestamptz,
  tabel_sumber     varchar(50),
  entity_id_sumber varchar(255),                     -- Tier B referensi sumber
  version          int NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_core_notifikasi_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_notifikasi_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_core_notifikasi_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_core_notifikasi_penerima
  ON core_notifikasi (id_core_users, status, created_at);
CREATE INDEX IF NOT EXISTS ix_core_notifikasi_roles
  ON core_notifikasi (id_core_roles, status, created_at);

-- -----------------------------------------------------------------------------
-- Trigger updated_at — satu blok untuk semua tabel CORE (D-04)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core_modul','core_users','core_kredensial','core_sessions','core_password_resets',
    'core_roles','core_grup_izin','core_routes','core_menus',
    'core_users_roles','core_roles_grup_izin','core_roles_menus',
    'core_penugasan','core_audit','core_penomoran','core_konfigurasi','core_notifikasi'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- PATCH 01-core.sql selesai.
