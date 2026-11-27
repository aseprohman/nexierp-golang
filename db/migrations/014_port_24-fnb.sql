-- +goose Up
-- Porting 1:1 dari ddl/24-fnb.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 24-fnb.sql — FNB fase fondasi: master + produksi dapur + KDS (v3)
-- Domain   : OdooLikeERP · Modul FNB — blueprint final
--            docs/analisa-modul-fnb-v3.md (fase fondasi + produksi + KDS;
--            keputusan pemilik 2026-11-06: dine-in/katalog/tagihan ditangguhkan,
--            KDS masuk fase ini sebagai antrian produksi, reservasi tetap RSV)
-- Kartu    : basis docs/arsitektur-database-fnb.md revisi-2 (FF-01…FF-13 tetap
--            sah utk meja/menu/resep/event log) + entitas BARU `fnb_produksi`
--            trio (kartu fisik produksi menyusul di gerbang yang sama)
-- Pola     : 3 [MASTER] (fnb_resep, fnb_menu, fnb_meja) + 6 [LINE]
--            (resep_bahan, menu_varian, menu_komponen, menu_jadwal_harga,
--            produksi_baris, produksi_bahan) + 1 [TRANSAKSI] (fnb_produksi)
--            + 1 [LOG/EVENT] append-only (fnb_event_log)
-- Integras : FK hanya ke tabel HIDUP pgdb/nexierp — core_users (aktor),
--            inv_produk / inv_unit_ukur (baca master — IN-01),
--            inv_lokasi_stok (gudang dapur sumber konsumsi — IN-02).
--            Tanpa FK ke pos_* (dine-in dorman; FF-08 tetap berlaku).
-- Idempoten: aman dijalankan berulang (DROP IF EXISTS guard data, enum
--            DO-block + ADD VALUE IF NOT EXISTS, IF NOT EXISTS, seed
--            ON CONFLICT DO NOTHING, trigger DO-block DROP+CREATE).
-- Migrasi  : menggantikan skema fnb era revisi-2 (8 tabel, terverifikasi
--            KOSONG 2026-11-06) — fail-loud bila ada baris (arsip dulu:
--            arsip-hapus-fnb-20261106.tgz / arsip-db-hapus-pos-fnb-*.sql).
-- Prasyarat: ddl/01-core.sql (set_updated_at, core_users, core_modules,
--            core_sequences, core_module_configs, enum_status_aktif)
--            + patch INV (inv_produk, inv_unit_ukur, inv_lokasi_stok).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) TRANSISI SKEMA LAMA — drop 8 tabel fnb era revisi-2 (wajib kosong)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE
  v_t text;
  v_n bigint;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'fnb_event_log', 'fnb_menu_komponen', 'fnb_menu_varian', 'fnb_menu_jadwal_harga',
    'fnb_resep_bahan', 'fnb_menu', 'fnb_resep', 'fnb_meja'
  ] LOOP
    IF to_regclass(format('public.%I', v_t)) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM %I', v_t) INTO v_n;
      IF v_n > 0 THEN
        RAISE EXCEPTION 'PATCH 24-fnb: tabel % masih berisi % baris — arsip data dulu sebelum migrasi v3', v_t, v_n;
      END IF;
    END IF;
  END LOOP;
END $$;
-- +goose StatementEnd


DROP TABLE IF EXISTS fnb_event_log CASCADE;
DROP TABLE IF EXISTS fnb_menu_komponen CASCADE;
DROP TABLE IF EXISTS fnb_menu_varian CASCADE;
DROP TABLE IF EXISTS fnb_menu_jadwal_harga CASCADE;
DROP TABLE IF EXISTS fnb_resep_bahan CASCADE;
DROP TABLE IF EXISTS fnb_menu CASCADE;
DROP TABLE IF EXISTS fnb_resep CASCADE;
DROP TABLE IF EXISTS fnb_meja CASCADE;
DROP TABLE IF EXISTS fnb_produksi CASCADE;
DROP TABLE IF EXISTS fnb_produksi_baris CASCADE;
DROP TABLE IF EXISTS fnb_produksi_bahan CASCADE;

-- -----------------------------------------------------------------------------
-- 1) ENUM — kosakata PERSIS blueprint v3 §4.1/4.2 (K-07)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_meja_fnb AS ENUM ('KOSONG', 'TERKUNCI', 'TERISI', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_menu_fnb AS ENUM ('DRAF', 'PUBLIK', 'HABIS_86', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_tipe_menu_fnb AS ENUM ('TUNGGAL', 'PAKET');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_varian_fnb AS ENUM ('VARIAN', 'MODIFIER');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_grup_course_fnb AS ENUM ('PEMBUKA', 'UTAMA', 'PENUTUP', 'LAINNYA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- enum_subjek_fnb era revisi-2 masih ada di DB live tanpa 'PRODUKSI' — tambah
-- value (idempoten). 'PESANAN_DINEIN' dipertahankan sebagai value dorman untuk
-- jejak dine-in (FF-06) — dipakai kembali bersama kontrak M29/M30.
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_subjek_fnb AS ENUM ('MEJA', 'MENU', 'RESEP', 'PESANAN_DINEIN', 'PRODUKSI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd

ALTER TYPE enum_subjek_fnb ADD VALUE IF NOT EXISTS 'PRODUKSI';

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_fnb_status_produksi AS ENUM ('DRAF', 'DIJALANKAN', 'SELESAI', 'BATAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_fnb_status_antrian AS ENUM ('DIPESAN', 'DIMASAK', 'SELESAI', 'BATAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_fnb_titik_konsumsi AS ENUM ('SAAT_DIJALANKAN', 'SAAT_KNOCK', 'SAAT_SELESAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- enum_status_aktif (AKTIF/NONAKTIF) dipinjam dari global 01-core untuk
-- fnb_resep.status — TIDAK dibuat ulang di sini (FF-11).

-- -----------------------------------------------------------------------------
-- 2) MASTER — fnb_resep (+ LINE bahan), fnb_menu (+ 3 LINE), fnb_meja
-- -----------------------------------------------------------------------------

-- [MASTER] fnb_resep — BOM satu level + yield; dasar kebutuhan produksi & food cost (FF-03).
CREATE TABLE IF NOT EXISTS fnb_resep (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_resep       varchar(50) NOT NULL,                -- numbering RSP-, unique global (K-10)
  yield_porsi      numeric(18, 6) NOT NULL DEFAULT 1,
  kategori_stasiun varchar(50) NOT NULL DEFAULT 'UTAMA', -- grill/bar/cold — kategori, bukan master (Q-01 v2)
  status           enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  catatan          varchar(300),
  version          int NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_fnb_resep_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fnb_resep_kode UNIQUE (kode_resep),
  CONSTRAINT ck_fnb_resep_yield CHECK (yield_porsi > 0)
);

-- [LINE] fnb_resep_bahan — bahan tidak disalin dari INV (A-05 v3; M36 baca master).
CREATE TABLE IF NOT EXISTS fnb_resep_bahan (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_resep     bigint NOT NULL,
  id_inv_produk    bigint NOT NULL,                     -- bahan (master INV)
  id_inv_unit_ukur bigint NOT NULL,                     -- UOM terkecil
  qty_per_porsi    int NOT NULL,
  catatan          varchar(300),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_fnb_resep_bahan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_resep_bahan_resep FOREIGN KEY (id_fnb_resep)
    REFERENCES fnb_resep (id) ON DELETE CASCADE,
  CONSTRAINT fk_fnb_resep_bahan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_resep_bahan_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_fnb_resep_bahan_qty CHECK (qty_per_porsi > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_resep_bahan_pasangan
  ON fnb_resep_bahan (id_fnb_resep, id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_resep_bahan_produk
  ON fnb_resep_bahan (id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_resep_stasiun
  ON fnb_resep (kategori_stasiun) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] fnb_menu — item jualan; lifecycle DRAF/PUBLIK/HABIS_86/NONAKTIF;
-- binding menu↔resep satu tempat di sisi menu (FF-03); sumber kebutuhan produksi.
CREATE TABLE IF NOT EXISTS fnb_menu (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_menu         varchar(50) NOT NULL,               -- numbering MNU-, unique global (K-10)
  nama              varchar(100) NOT NULL,
  kategori_menu     varchar(100) NOT NULL,              -- label, bukan master (FF-02 v2)
  harga_dasar       numeric(18, 4) NOT NULL,            -- milik FNB (bukan pricelist modul lain)
  tipe_menu         enum_tipe_menu_fnb NOT NULL DEFAULT 'TUNGGAL',
  grup_course       enum_grup_course_fnb NOT NULL DEFAULT 'LAINNYA', -- fase penyajian (FF-05 v2)
  target_masak_menit int,                               -- CFG-FNB-09 per menu; NULL = ikut mode global
  id_inv_produk     bigint,                             -- kemasan siap-jual (A-05 v3)
  id_fnb_resep      bigint,                             -- resep sumber (1:1 — FF-03)
  publik_mulai      timestamptz,                        -- jadwal publikasi (pasangan — CK)
  publik_selesai    timestamptz,
  status            enum_status_menu_fnb NOT NULL DEFAULT 'DRAF',
  version           int NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_fnb_menu_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fnb_menu_kode UNIQUE (kode_menu),
  CONSTRAINT fk_fnb_menu_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_menu_resep FOREIGN KEY (id_fnb_resep)
    REFERENCES fnb_resep (id) ON DELETE RESTRICT,
  -- FF-04 v2: TUNGGAL wajib tepat satu sumber; PAKET (kit) wajib tanpa keduanya
  CONSTRAINT ck_fnb_menu_sumber CHECK (
    (tipe_menu = 'TUNGGAL'
      AND ((id_inv_produk IS NOT NULL)::int + (id_fnb_resep IS NOT NULL)::int) = 1)
    OR (tipe_menu = 'PAKET' AND id_inv_produk IS NULL AND id_fnb_resep IS NULL)
  ),
  CONSTRAINT ck_fnb_menu_jadwal_publik CHECK (
    (publik_mulai IS NULL) = (publik_selesai IS NULL)
    AND (publik_mulai IS NULL OR publik_mulai < publik_selesai)
  ),
  CONSTRAINT ck_fnb_menu_harga CHECK (harga_dasar >= 0),
  CONSTRAINT ck_fnb_menu_target CHECK (target_masak_menit IS NULL OR target_masak_menit > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_menu_resep
  ON fnb_menu (id_fnb_resep) WHERE id_fnb_resep IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_publik
  ON fnb_menu (status) WHERE status = 'PUBLIK' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_86
  ON fnb_menu (status) WHERE status = 'HABIS_86' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_kategori
  ON fnb_menu (kategori_menu) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_produk
  ON fnb_menu (id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_resep
  ON fnb_menu (id_fnb_resep) WHERE deleted_at IS NULL;

-- [LINE] fnb_menu_varian — varian/modifier; delta >= 0 (FF-09 v2).
CREATE TABLE IF NOT EXISTS fnb_menu_varian (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id    uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_menu  bigint NOT NULL,
  jenis        enum_jenis_varian_fnb NOT NULL DEFAULT 'MODIFIER',
  nama         varchar(100) NOT NULL,
  delta_harga  numeric(18, 4) NOT NULL DEFAULT 0,
  urutan       int NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  CONSTRAINT uq_fnb_menu_varian_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_menu_varian_menu FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE CASCADE,
  CONSTRAINT ck_fnb_menu_varian_delta CHECK (delta_harga >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_menu_varian_nama
  ON fnb_menu_varian (id_fnb_menu, nama) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_varian_menu
  ON fnb_menu_varian (id_fnb_menu) WHERE deleted_at IS NULL;

-- [LINE] fnb_menu_komponen — kit paket/kombo (v3 F07); propagasi 86 induk↔komponen.
CREATE TABLE IF NOT EXISTS fnb_menu_komponen (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_menu          bigint NOT NULL,                  -- induk PAKET
  id_fnb_menu_komponen bigint NOT NULL,                  -- komponen (menu hidup — RESTRICT)
  qty                  int NOT NULL DEFAULT 1,
  urutan               int NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_fnb_menu_komponen_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_menu_komponen_induk FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE CASCADE,
  CONSTRAINT fk_fnb_menu_komponen_menu FOREIGN KEY (id_fnb_menu_komponen)
    REFERENCES fnb_menu (id) ON DELETE RESTRICT,
  CONSTRAINT ck_fnb_menu_komponen_induk CHECK (id_fnb_menu <> id_fnb_menu_komponen),
  CONSTRAINT ck_fnb_menu_komponen_qty CHECK (qty > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_menu_komponen_pasangan
  ON fnb_menu_komponen (id_fnb_menu, id_fnb_menu_komponen) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_menu_komponen_balik
  ON fnb_menu_komponen (id_fnb_menu_komponen) WHERE deleted_at IS NULL;

-- [LINE] fnb_menu_jadwal_harga — CFG-FNB-07; wrap tengah malam sah (FF-10 v2).
CREATE TABLE IF NOT EXISTS fnb_menu_jadwal_harga (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_menu bigint NOT NULL,
  label       varchar(100),
  harga       numeric(18, 4) NOT NULL,
  jam_mulai   time NOT NULL,
  jam_selesai time NOT NULL,
  hari_aktif  varchar(50),                              -- NULL = semua hari; format divalidasi app
  prioritas   int NOT NULL DEFAULT 0,                   -- overlap → tertinggi menang (app)
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_fnb_menu_jadwal_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_menu_jadwal_menu FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE CASCADE,
  CONSTRAINT ck_fnb_menu_jadwal_harga CHECK (harga >= 0),
  CONSTRAINT ck_fnb_menu_jadwal_jam CHECK (jam_mulai <> jam_selesai)
);

CREATE INDEX IF NOT EXISTS ix_fnb_menu_jadwal_menu
  ON fnb_menu_jadwal_harga (id_fnb_menu) WHERE deleted_at IS NULL;

-- [MASTER] fnb_meja — unit lantai + denah pada kartu meja (FF-01 v2); transisi
-- TERKUNCI/TERISI dorman (hidup bersama check-in M13 / pesanan dine-in — v3 F01).
CREATE TABLE IF NOT EXISTS fnb_meja (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_meja         varchar(50) NOT NULL,               -- numbering MJA-, unique global (K-10)
  nama              varchar(100) NOT NULL,
  lantai            varchar(50),
  area              varchar(100),
  bentuk            varchar(50),                        -- klasifikasi visual bebas (FF-02 v2)
  posisi_x          int,                                -- denah floor plan
  posisi_y          int,
  kapasitas_orang   int NOT NULL DEFAULT 2,             -- panduan M33/F11, bukan blokir
  status            enum_status_meja_fnb NOT NULL DEFAULT 'KOSONG',
  id_fnb_meja_induk bigint,                             -- gabung (BR11 v2); pisah = NULL
  id_rsv_reservasi  bigint,                             -- RESERVED (PP-03) — FK oleh patch RSV
  alasan            varchar(300),                       -- wajib bila NONAKTIF (STD-06/BR04 v3)
  catatan           varchar(300),
  version           int NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_fnb_meja_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fnb_meja_kode UNIQUE (kode_meja),
  CONSTRAINT fk_fnb_meja_induk FOREIGN KEY (id_fnb_meja_induk)
    REFERENCES fnb_meja (id) ON DELETE RESTRICT,
  CONSTRAINT ck_fnb_meja_induk CHECK (id_fnb_meja_induk IS NULL OR id_fnb_meja_induk <> id),
  CONSTRAINT ck_fnb_meja_nonaktif CHECK (status <> 'NONAKTIF' OR alasan IS NOT NULL),
  CONSTRAINT ck_fnb_meja_kapasitas CHECK (kapasitas_orang > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_meja_reservasi
  ON fnb_meja (id_rsv_reservasi) WHERE id_rsv_reservasi IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_meja_lantai_status
  ON fnb_meja (lantai, status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_meja_induk
  ON fnb_meja (id_fnb_meja_induk) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 3) TRANSAKSI — fnb_produksi (header) + baris antrian KDS + bahan konsumsi
-- -----------------------------------------------------------------------------

-- [TRANSAKSI] fnb_produksi — dokumen produksi dapur (v3 F04): resep × qty →
-- konsumsi ke INV pada titik CFG (BR07 idempoten), waste (BR08), approval
-- batal terjalankan/waste ambang (BR03, SoD); koreksi via dokumen pembalik (BR11).
CREATE TABLE IF NOT EXISTS fnb_produksi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_produksi          varchar(50) NOT NULL,          -- numbering PRD-, unique global (K-10)
  id_fnb_menu            bigint NOT NULL,
  id_fnb_menu_varian     bigint,                        -- target varian (opsional)
  id_inv_lokasi_stok     bigint NOT NULL,               -- gudang dapur sumber pengambilan (IN-02)
  id_core_users          bigint,                        -- pelaku (NULL = sistem)
  id_core_users_approval bigint,                        -- approver BR03 (SoD pengaju ≠ penyetuju)
  approval_at            timestamptz,
  qty_porsi_direncanakan int NOT NULL,
  qty_porsi_aktual       int,                           -- wajib saat SELESAI (CK)
  titik_konsumsi         enum_fnb_titik_konsumsi NOT NULL DEFAULT 'SAAT_KNOCK', -- snapshot CFG-FNB-01 saat dokumen disusun (BR05)
  status                 enum_fnb_status_produksi NOT NULL DEFAULT 'DRAF',
  alasan                 varchar(300),                  -- wajib bila BATAL (STD-06)
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fnb_produksi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fnb_produksi_kode UNIQUE (kode_produksi),
  CONSTRAINT fk_fnb_produksi_menu FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_varian FOREIGN KEY (id_fnb_menu_varian)
    REFERENCES fnb_menu_varian (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_lokasi FOREIGN KEY (id_inv_lokasi_stok)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_fnb_produksi_approver FOREIGN KEY (id_core_users_approval)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_fnb_produksi_qty_rencana CHECK (qty_porsi_direncanakan > 0),
  CONSTRAINT ck_fnb_produksi_qty_aktual CHECK (qty_porsi_aktual IS NULL OR qty_porsi_aktual >= 0),
  CONSTRAINT ck_fnb_produksi_batal CHECK (status <> 'BATAL' OR alasan IS NOT NULL),
  CONSTRAINT ck_fnb_produksi_selesai CHECK (status <> 'SELESAI' OR qty_porsi_aktual IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_fnb_produksi_status
  ON fnb_produksi (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_produksi_menu
  ON fnb_produksi (id_fnb_menu) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_produksi_lokasi
  ON fnb_produksi (id_inv_lokasi_stok) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_produksi_users
  ON fnb_produksi (id_core_users) WHERE deleted_at IS NULL;

-- [LINE] fnb_produksi_baris — antrian KDS per menu/komponen × stasiun (v3 F09);
-- knock hanya staf stasiunnya (BR12); version utk knock bersamaan (STD-07).
CREATE TABLE IF NOT EXISTS fnb_produksi_baris (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_produksi   bigint NOT NULL,
  id_fnb_menu       bigint NOT NULL,                    -- menu/komponen yang dikerjakan
  id_fnb_resep      bigint,                             -- NULL = menu kemasan tanpa resep
  kategori_stasiun  varchar(50) NOT NULL,               -- snapshot resep saat dokumen disusun
  qty_porsi         int NOT NULL,
  target_masak_menit int,                               -- snapshot menu (CFG-FNB-09)
  status            enum_fnb_status_antrian NOT NULL DEFAULT 'DIPESAN',
  dimulai_at        timestamptz,
  selesai_at        timestamptz,
  id_core_users_mulai   bigint,                         -- staf stasiun (BR12)
  id_core_users_selesai bigint,
  version           int NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_fnb_produksi_baris_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_produksi_baris_header FOREIGN KEY (id_fnb_produksi)
    REFERENCES fnb_produksi (id) ON DELETE CASCADE,
  CONSTRAINT fk_fnb_produksi_baris_menu FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_baris_resep FOREIGN KEY (id_fnb_resep)
    REFERENCES fnb_resep (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_baris_mulai FOREIGN KEY (id_core_users_mulai)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_fnb_produksi_baris_selesai FOREIGN KEY (id_core_users_selesai)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_fnb_produksi_baris_qty CHECK (qty_porsi > 0),
  CONSTRAINT ck_fnb_produksi_baris_dimasak
    CHECK (status NOT IN ('DIMASAK', 'SELESAI') OR dimulai_at IS NOT NULL),
  CONSTRAINT ck_fnb_produksi_baris_selesai
    CHECK (status <> 'SELESAI' OR selesai_at IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_produksi_baris_pasangan
  ON fnb_produksi_baris (id_fnb_produksi, id_fnb_menu, kategori_stasiun)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_kds_antrian
  ON fnb_produksi_baris (kategori_stasiun, status)
  WHERE status IN ('DIPESAN', 'DIMASAK') AND deleted_at IS NULL;

-- [LINE] fnb_produksi_bahan — kebutuhan (teoritis) & aktual/waste per bahan;
-- qty numeric(18,6) = hasil resep×qty÷yield (rasio — FF-11 v2); gerakan INV
-- ditulis pemilik INV (IN-02), baris ini adalah sumber & jejaknya di sisi FNB.
CREATE TABLE IF NOT EXISTS fnb_produksi_bahan (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_produksi  bigint NOT NULL,
  id_inv_produk    bigint NOT NULL,
  id_inv_unit_ukur bigint NOT NULL,
  qty_teoritis     numeric(18, 6) NOT NULL,             -- resep × qty ÷ yield
  qty_aktual       numeric(18, 6),                      -- terisi saat SELESAI
  qty_waste        numeric(18, 6),                      -- selisih yield/rusak (CFG-FNB-08)
  alasan_waste     varchar(300),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_fnb_produksi_bahan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_produksi_bahan_header FOREIGN KEY (id_fnb_produksi)
    REFERENCES fnb_produksi (id) ON DELETE CASCADE,
  CONSTRAINT fk_fnb_produksi_bahan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_produksi_bahan_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_fnb_bahan_teoritis CHECK (qty_teoritis >= 0),
  CONSTRAINT ck_fnb_bahan_aktual CHECK (qty_aktual IS NULL OR qty_aktual >= 0),
  CONSTRAINT ck_fnb_bahan_waste CHECK (qty_waste IS NULL OR qty_waste >= 0),
  CONSTRAINT ck_fnb_bahan_waste_alasan
    CHECK (qty_waste IS NULL OR qty_waste = 0 OR alasan_waste IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_produksi_bahan_pasangan
  ON fnb_produksi_bahan (id_fnb_produksi, id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_produksi_bahan_produk
  ON fnb_produksi_bahan (id_inv_produk) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4) LOG/EVENT — fnb_event_log append-only (STD-01/BR04; FF-06 v2 + subjek PRODUKSI)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fnb_event_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_fnb_meja     bigint,
  id_fnb_menu     bigint,
  id_fnb_resep    bigint,
  id_fnb_produksi bigint,
  id_core_users   bigint,                               -- NULL = aktor sistem/kontrak
  ref_pesanan     varchar(50),                          -- DORMAN — nomor struk dine-in (FF-06), tanpa FK
  subjek          enum_subjek_fnb NOT NULL,
  aksi            varchar(100) NOT NULL,                -- kode aksi/error: MEJA_TIDAK_KOSONG, SOD_DILANGGAR, …
  dari_status     varchar(50),
  ke_status       varchar(50),
  alasan          varchar(300),
  payload         jsonb,                                -- konteks kontrak; tak di-filter/di-join
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),   -- beku (append-only — tanpa trigger)
  deleted_at      timestamptz,                          -- selalu NULL (append-only)
  CONSTRAINT uq_fnb_event_log_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_event_meja FOREIGN KEY (id_fnb_meja)
    REFERENCES fnb_meja (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_event_menu FOREIGN KEY (id_fnb_menu)
    REFERENCES fnb_menu (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_event_resep FOREIGN KEY (id_fnb_resep)
    REFERENCES fnb_resep (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_event_produksi FOREIGN KEY (id_fnb_produksi)
    REFERENCES fnb_produksi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fnb_event_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  -- FF-06 v2 + subjek PRODUKSI (v3): tepat satu subjek FK; branch PESANAN_DINEIN
  -- dorman (menggantung ref_pesanan, tanpa FK — POS pemilik pesanan).
  CONSTRAINT ck_fnb_event_subjek CHECK (
    (
      ((id_fnb_meja IS NOT NULL)::int + (id_fnb_menu IS NOT NULL)::int
        + (id_fnb_resep IS NOT NULL)::int + (id_fnb_produksi IS NOT NULL)::int) = 1
      AND ref_pesanan IS NULL
      AND subjek <> 'PESANAN_DINEIN'
    )
    OR (
      subjek = 'PESANAN_DINEIN'
      AND ref_pesanan IS NOT NULL
      AND id_fnb_meja IS NULL AND id_fnb_menu IS NULL
      AND id_fnb_resep IS NULL AND id_fnb_produksi IS NULL
    )
  )
);

CREATE INDEX IF NOT EXISTS ix_fnb_event_meja
  ON fnb_event_log (id_fnb_meja, created_at) WHERE id_fnb_meja IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_event_menu
  ON fnb_event_log (id_fnb_menu, created_at) WHERE id_fnb_menu IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_event_resep
  ON fnb_event_log (id_fnb_resep, created_at) WHERE id_fnb_resep IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_event_produksi
  ON fnb_event_log (id_fnb_produksi, created_at) WHERE id_fnb_produksi IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_event_subjek_aksi
  ON fnb_event_log (subjek, aksi, created_at);

-- -----------------------------------------------------------------------------
-- 5) TRIGGER set_updated_at — 10 tabel mutable; fnb_event_log sengaja TANPA
--    trigger (updated_at beku — append-only, FF-13 v2).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'fnb_resep', 'fnb_resep_bahan', 'fnb_menu', 'fnb_menu_varian', 'fnb_menu_komponen',
    'fnb_menu_jadwal_harga', 'fnb_meja', 'fnb_produksi', 'fnb_produksi_baris', 'fnb_produksi_bahan'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 6) SEKSI INTEGRASI CORE — registry, penomoran, konfigurasi (insert-if-missing;
--    nilai existing TIDAK ditimpa — BR06)
-- -----------------------------------------------------------------------------

-- Registry modul (fail-loud bila enum core_module_key tak memuat 'fnb').
INSERT INTO core_modules (key, name, tagline, tone, is_core, enabled, enabled_at)
VALUES ('fnb', 'Food & Beverage',
        'Menu & resep, produksi dapur & KDS, ketersediaan menu, laporan food cost',
        'from-amber-400 to-red-500', false, true, now())
ON CONFLICT (key) DO UPDATE
SET enabled = true, disabled_at = NULL
WHERE core_modules.enabled = false;

-- Penomoran STD-08: MEJA/MENU/RESEP/PRODUKSI (v3 Q-01: prefix PRD).
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, 0, 4
FROM core_modules m
CROSS JOIN (VALUES
  ('MEJA', 'MJA-'),
  ('MENU', 'MNU-'),
  ('RESEP', 'RSP-'),
  ('PRODUKSI', 'PRD-')
) AS v(doc_name, prefix)
WHERE m.key = 'fnb'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- CFG-FNB fase fondasi (v3 F06) — parameter dine-in (04/05/06/11) TIDAK diseed,
-- hidup bersama fiturnya. Value type mengikuti enum core_config_value_type.
INSERT INTO core_module_configs (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-FNB-01', 'SAAT_KNOCK', 'string',
   'Titik konsumsi bahan produksi: SAAT_DIJALANKAN / SAAT_KNOCK / SAAT_SELESAI (v3 fase produksi)'),
  ('CFG-FNB-02', 'TANDAI_86', 'string',
   'Reaksi kekurangan bahan: TANDAI_86 / LANJUT_PERINGATAN / BLOKIR'),
  ('CFG-FNB-03', 'OTOMATIS', 'string',
   'Pembukaan menu 86: OTOMATIS / MANUAL'),
  ('CFG-FNB-07', 'SATU_HARGA', 'string',
   'Harga menu: SATU_HARGA / JADWAL (rentang waktu)'),
  ('CFG-FNB-08', 'CATAT_WASTE', 'string',
   'Pencatatan waste yield/rusak: CATAT_WASTE / TANPA_CATAT'),
  ('CFG-FNB-09', 'PER_MENU', 'string',
   'Target waktu masak KDS: TANPA_TARGET / GLOBAL / PER_MENU'),
  ('CFG-FNB-10', 'PER_STASIUN', 'string',
   'Pembagian antrian KDS: SATU_ANTRIAN / PER_STASIUN (dari kategori_stasiun resep)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'fnb'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

-- Data-fix warisan era v2: CFG-FNB-01 kosakata dine-in (dorman) → kosakata
-- fase produksi v3. Hanya menyentuh nilai lama persis; nilai suntingan user
-- lain tidak diganggu.
UPDATE core_module_configs c
SET param_value = 'SAAT_KNOCK', updated_at = now()
FROM core_modules m
WHERE m.id = c.id_core_modules AND m.key = 'fnb'
  AND c.param_key = 'CFG-FNB-01'
  AND c.param_value IN ('SAAT_DISAJIKAN', 'SAAT_KONFIRMASI');

-- PATCH 24-fnb.sql selesai.
