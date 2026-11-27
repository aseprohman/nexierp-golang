-- =============================================================================
-- PATCH DDL 02-inventory.sql — Modul INVENTORY
-- Domain   : OdooLikeERP (single tenant, konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-inv-v2.md (kosakata status = PERSIS §4.1/§4.2)
-- Kartu    : docs/arsitektur-database-core-inv.md
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum (kosakata persis blueprint INV v2)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_tipe_produk AS ENUM ('BARANG', 'JASA', 'BAHAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_pelacakan AS ENUM ('TANPA', 'LOT', 'SERIAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_metode_valuasi AS ENUM ('STANDAR', 'AVCO', 'FIFO');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_sistem_valuasi AS ENUM ('PERPETUAL', 'PERIODIK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_lokasi AS ENUM ('INTERNAL', 'VENDOR', 'CUSTOMER', 'PRODUKSI', 'SCRAP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_gerakan AS ENUM
    ('PENERIMAAN', 'PENGIRIMAN', 'TRANSFER_INTERNAL', 'PRODUKSI', 'SCRAP', 'PENYESUAIAN');
  -- Catatan D-14: nilai RETUR menunggu keputusan kontrak retur (P1 audit) —
  -- tambah belakangan via ALTER TYPE enum_jenis_gerakan ADD VALUE 'RETUR_...' setelah kontrak dikunci.
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_gerakan AS ENUM
    ('DRAFT', 'MENUNGGU_STOK', 'TERJADWAL', 'SEBAGIAN', 'SELESAI', 'BATAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_lot_serial AS ENUM ('AKTIF', 'KEDALUWARSA', 'HABIS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_penyesuaian AS ENUM ('PENYESUAIAN', 'CYCLE_COUNT', 'SCRAP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_penyesuaian AS ENUM
    ('DRAFT', 'MENUNGGU_PERSETUJUAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_landed AS ENUM ('DITERIMA', 'DIALOKASIKAN', 'DITUNDA', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_dasar_alokasi AS ENUM ('NILAI', 'QTY', 'BERAT', 'VOLUME');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- inv_kategori_produk — kebijakan stok & valuasi per kategori [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_kategori_produk (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                   varchar(100) NOT NULL,
  id_kategori_induk      bigint,
  metode_valuasi         enum_metode_valuasi NOT NULL DEFAULT 'STANDAR',   -- CFG-INV-06
  sistem_valuasi         enum_sistem_valuasi NOT NULL DEFAULT 'PERPETUAL', -- CFG-INV-07
  kebijakan_pelacakan    enum_pelacakan NOT NULL DEFAULT 'TANPA',          -- CFG-INV-01
  kebijakan_kedaluwarsa  boolean NOT NULL DEFAULT false,                   -- CFG-INV-02
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_inv_kategori_produk_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_inv_kategori_produk_induk FOREIGN KEY (id_kategori_induk)
    REFERENCES inv_kategori_produk (id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_kategori_produk_nama
  ON inv_kategori_produk (nama) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_kategori_produk_induk
  ON inv_kategori_produk (id_kategori_induk);

-- -----------------------------------------------------------------------------
-- inv_unit_ukur — satuan hitung & konversi [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_unit_ukur (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  kode           varchar(50) NOT NULL,               -- PCS, KG, GR, ML, L
  nama           varchar(100) NOT NULL,
  kategori_uom   varchar(50) NOT NULL DEFAULT 'UNIT', -- konversi hanya dalam kategori sama
  rasio_ke_dasar numeric(18,6) NOT NULL DEFAULT 1,    -- 1 unit ini = rasio x unit dasar kategori
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_inv_unit_ukur_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_unit_ukur_kode UNIQUE (kode),
  CONSTRAINT ck_inv_unit_ukur_rasio CHECK (rasio_ke_dasar > 0)
);

-- -----------------------------------------------------------------------------
-- inv_produk — kartu induk barang/bahan/jasa [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_produk (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_produk            varchar(50) NOT NULL,        -- SKU; tak pernah dipakai ulang
  nama                   varchar(100) NOT NULL,
  tipe                   enum_tipe_produk NOT NULL DEFAULT 'BARANG',
  id_inv_kategori_produk bigint NOT NULL,
  id_inv_unit_ukur       bigint NOT NULL,             -- unit dasar
  jejak_stok             boolean NOT NULL DEFAULT true,  -- jasa = false (tanpa gerakan)
  barcode                varchar(50),
  harga_jual             numeric(18,4),               -- dasar; harga kanal hidup di pricelist SLS
  harga_biaya            numeric(18,4),               -- biaya standar/dasar valuasi
  stok_minimum           int NOT NULL DEFAULT 0,      -- kebijakan reorder di kartu produk (A-03 v2)
  stok_maksimum          int,
  reorder_aktif          boolean NOT NULL DEFAULT false, -- terpicu -> M27 ke PUR
  berat_gram             int,                         -- NULL menunggu keputusan Q-02 (D-15)
  volume_cm3             int,                         -- NULL menunggu keputusan Q-02 (D-15)
  keterangan             text,                        -- prosa bebas (K-08)
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_inv_produk_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_produk_kode UNIQUE (kode_produk),
  CONSTRAINT ck_inv_produk_maks CHECK (stok_maksimum IS NULL OR stok_maksimum > stok_minimum),
  CONSTRAINT ck_inv_produk_berat CHECK (berat_gram IS NULL OR berat_gram >= 0),
  CONSTRAINT ck_inv_produk_volume CHECK (volume_cm3 IS NULL OR volume_cm3 >= 0),
  CONSTRAINT fk_inv_produk_kategori FOREIGN KEY (id_inv_kategori_produk)
    REFERENCES inv_kategori_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_produk_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_produk_barcode
  ON inv_produk (barcode) WHERE deleted_at IS NULL AND barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_inv_produk_kategori ON inv_produk (id_inv_kategori_produk);
CREATE INDEX IF NOT EXISTS ix_inv_produk_reorder
  ON inv_produk (reorder_aktif) WHERE deleted_at IS NULL AND reorder_aktif IS TRUE;

-- -----------------------------------------------------------------------------
-- inv_gudang — gudang/cabang fisik [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_gudang (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,
  nama        varchar(100) NOT NULL,
  kode_satuan varchar(50),                          -- transitional multi-cabang PS3 (D-13)
  alamat      varchar(300),
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     int NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_inv_gudang_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_gudang_kode UNIQUE (kode)
);

-- -----------------------------------------------------------------------------
-- inv_lokasi_stok — node perhitungan stok [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_lokasi_stok (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  kode             varchar(50) NOT NULL,
  nama             varchar(100) NOT NULL,
  jenis            enum_jenis_lokasi NOT NULL DEFAULT 'INTERNAL',
  id_inv_gudang    bigint,                           -- NULL = lokasi virtual (VENDOR/CUSTOMER/...)
  id_lokasi_induk  bigint,                           -- hierarki rak/bin
  status           enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version          int NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_inv_lokasi_stok_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_lokasi_stok_kode UNIQUE (kode),
  CONSTRAINT ck_inv_lokasi_internal_punya_gudang
    CHECK (jenis <> 'INTERNAL' OR id_inv_gudang IS NOT NULL),
  CONSTRAINT fk_inv_lokasi_stok_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_lokasi_stok_induk FOREIGN KEY (id_lokasi_induk)
    REFERENCES inv_lokasi_stok (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_lokasi_stok_gudang ON inv_lokasi_stok (id_inv_gudang);
CREATE INDEX IF NOT EXISTS ix_inv_lokasi_stok_induk ON inv_lokasi_stok (id_lokasi_induk);

-- -----------------------------------------------------------------------------
-- inv_lot_serial — identitas lot/serial [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_lot_serial (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk        bigint NOT NULL,
  kode                 varchar(100) NOT NULL,        -- nomor lot/serial
  tanggal_prodiksi     timestamptz,
  tanggal_kedaluwarsa  timestamptz,
  status               enum_status_lot_serial NOT NULL DEFAULT 'AKTIF',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_inv_lot_serial_entity_id UNIQUE (entity_id),
  -- identitas fisik tidak pernah dipakai ulang -> unique global (tanpa partial)
  CONSTRAINT uq_inv_lot_serial_produk_kode UNIQUE (id_inv_produk, kode),
  CONSTRAINT ck_inv_lot_serial_tanggal
    CHECK (tanggal_kedaluwarsa IS NULL OR tanggal_prodiksi IS NULL
           OR tanggal_kedaluwarsa > tanggal_prodiksi),
  CONSTRAINT fk_inv_lot_serial_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_lot_serial_fefo
  ON inv_lot_serial (id_inv_produk, tanggal_kedaluwarsa);  -- FEFO (CFG-INV-02)

-- -----------------------------------------------------------------------------
-- inv_gerakan_stok — satu-satunya jalur perubahan saldo [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_gerakan_stok (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_dokumen        varchar(150) NOT NULL,        -- nomor picking via core_penomoran (D-07)
  jenis                enum_jenis_gerakan NOT NULL,
  status               enum_status_gerakan NOT NULL DEFAULT 'DRAFT',
  id_inv_produk        bigint NOT NULL,
  id_inv_lot_serial    bigint,
  id_inv_unit_ukur     bigint NOT NULL,
  qty_diminta          int NOT NULL,
  qty_selesai          int NOT NULL DEFAULT 0,
  id_lokasi_sumber     bigint NOT NULL,
  id_lokasi_tujuan     bigint NOT NULL,
  nilai_persatuan      numeric(18,4),                -- snapshot valuasi saat SELESAI (M16)
  tanggal_jadwal       timestamptz NOT NULL DEFAULT now(),
  tanggal_selesai      timestamptz,
  jenis_sumber         varchar(50) NOT NULL DEFAULT 'MANUAL',   -- SO/PO/ADJ/LANDED/MANUAL
  entity_id_sumber     varchar(255),                 -- jejak polimorfik, tanpa FK (D-11)
  id_core_users        bigint,                       -- pelaksana; NULL = [sistem]
  alasan               varchar(300),                 -- wajib saat BATAL (STD-06, dicek app)
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_inv_gerakan_stok_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_gerakan_qty_diminta CHECK (qty_diminta > 0),
  CONSTRAINT ck_inv_gerakan_qty_selesai CHECK (qty_selesai >= 0 AND qty_selesai <= qty_diminta),
  CONSTRAINT ck_inv_gerakan_lokasi_beda CHECK (id_lokasi_sumber <> id_lokasi_tujuan),  -- INV-BR03
  CONSTRAINT ck_inv_gerakan_selesai_saat_status
    CHECK (status <> 'SELESAI' OR tanggal_selesai IS NOT NULL),
  CONSTRAINT fk_inv_gerakan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_gerakan_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_sumber FOREIGN KEY (id_lokasi_sumber)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_tujuan FOREIGN KEY (id_lokasi_tujuan)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_pelaksana FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

-- idempotensi retry kontrak (M01/M09/M11/M28): satu gerakan per sumber per dokumen
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_gerakan_idempoten
  ON inv_gerakan_stok (nomor_dokumen, id_inv_produk, jenis_sumber, entity_id_sumber)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_dokumen ON inv_gerakan_stok (nomor_dokumen);
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_produk_status
  ON inv_gerakan_stok (id_inv_produk, status);
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_tujuan_status
  ON inv_gerakan_stok (id_lokasi_tujuan, status);
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_sumber_ref
  ON inv_gerakan_stok (jenis_sumber, entity_id_sumber);
-- daftar kerja panas: gerakan yang belum tuntas
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_terbuka
  ON inv_gerakan_stok (status, tanggal_jadwal)
  WHERE status NOT IN ('SELESAI', 'BATAL') AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- inv_penyesuaian_stok — dokumen penyesuaian/cycle count/scrap [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_penyesuaian_stok (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                    varchar(50) NOT NULL,       -- penomoran ADJ (STD-08, anti-race)
  jenis                   enum_jenis_penyesuaian NOT NULL DEFAULT 'PENYESUAIAN',
  status                  enum_status_penyesuaian NOT NULL DEFAULT 'DRAFT',
  id_inv_gudang           bigint NOT NULL,
  tanggal_dokumen         timestamptz NOT NULL DEFAULT now(),
  id_core_users_penyusun  bigint,
  id_core_users_penyetuju bigint,                     -- SoD: penyusun != penyetuju (dicek app)
  alasan                  varchar(300),               -- wajib saat penyesuaian/tolak (app)
  version                 int NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_inv_penyesuaian_stok_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_penyesuaian_stok_kode UNIQUE (kode),  -- numbering: global, tanpa partial
  CONSTRAINT fk_inv_penyesuaian_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_penyesuaian_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_penyesuaian_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_penyesuaian_status
  ON inv_penyesuaian_stok (status, tanggal_dokumen);

-- -----------------------------------------------------------------------------
-- inv_penyesuaian_stok_items — baris penyesuaian [LINE]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_penyesuaian_stok_items (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_penyesuaian_stok bigint NOT NULL,
  id_inv_produk           bigint NOT NULL,
  id_inv_lot_serial       bigint,
  id_inv_lokasi_stok      bigint NOT NULL,
  id_inv_unit_ukur        bigint NOT NULL,
  qty_sistem              int NOT NULL DEFAULT 0,
  qty_hitung              int NOT NULL DEFAULT 0,
  qty_selisih             int NOT NULL DEFAULT 0,     -- dihitung app saat simpan
  biaya_satuan            numeric(18,4),              -- snapshot biaya
  nama_produk             varchar(100) NOT NULL,      -- snapshot beku saat dokumen hidup
  version                 int NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_inv_penyesuaian_items_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_penyesuaian_items_qty
    CHECK (qty_sistem >= 0 AND qty_hitung >= 0),
  CONSTRAINT fk_inv_penyesuaian_items_header FOREIGN KEY (id_inv_penyesuaian_stok)
    REFERENCES inv_penyesuaian_stok (id) ON DELETE CASCADE,
  CONSTRAINT fk_inv_penyesuaian_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_penyesuaian_items_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_penyesuaian_items_lokasi FOREIGN KEY (id_inv_lokasi_stok)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_penyesuaian_items_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_penyesuaian_items_header
  ON inv_penyesuaian_stok_items (id_inv_penyesuaian_stok);

-- -----------------------------------------------------------------------------
-- inv_biaya_pembelian_landed — biaya tambahan pembelian (M28 dari PUR) [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_biaya_pembelian_landed (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  kode            varchar(50) NOT NULL,               -- penomoran LC
  nomor_po_ref    varchar(150) NOT NULL,              -- dari payload M28 (tanpa FK lintas modul)
  dasar_alokasi   enum_dasar_alokasi NOT NULL DEFAULT 'NILAI',  -- CFG-INV-11
  total_biaya     numeric(18,4) NOT NULL,
  tanggal_dokumen timestamptz NOT NULL DEFAULT now(),
  status          enum_status_landed NOT NULL DEFAULT 'DITERIMA',
  catatan         text,                               -- prosa bebas
  version         int NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_inv_landed_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_landed_kode UNIQUE (kode),
  CONSTRAINT ck_inv_landed_total CHECK (total_biaya > 0)
);

CREATE INDEX IF NOT EXISTS ix_inv_landed_po ON inv_biaya_pembelian_landed (nomor_po_ref);

-- -----------------------------------------------------------------------------
-- inv_biaya_pembelian_landed_items — baris alokasi ke gerakan [LINE]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_biaya_pembelian_landed_items (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_biaya_pembelian_landed bigint NOT NULL,
  id_inv_gerakan_stok         bigint NOT NULL,        -- gerakan penerimaan target alokasi
  bobot                       numeric(18,6) NOT NULL, -- hasil hitung dasar alokasi
  nilai_alokasi               numeric(18,4) NOT NULL DEFAULT 0,
  version                     int NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_inv_landed_items_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_landed_items_bobot CHECK (bobot >= 0),
  CONSTRAINT fk_inv_landed_items_header FOREIGN KEY (id_inv_biaya_pembelian_landed)
    REFERENCES inv_biaya_pembelian_landed (id) ON DELETE CASCADE,
  CONSTRAINT fk_inv_landed_items_gerakan FOREIGN KEY (id_inv_gerakan_stok)
    REFERENCES inv_gerakan_stok (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_landed_items_header
  ON inv_biaya_pembelian_landed_items (id_inv_biaya_pembelian_landed);

-- -----------------------------------------------------------------------------
-- inv_saldo_stok — saldo baca [READMODEL] (D-09)
-- Sumber kebenaran : inv_gerakan_stok berstatus SELESAI
-- Jalur recompute  : event saat gerakan SELESAI + sweep harian; boleh truncate & rebuild
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_saldo_stok (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_lokasi_stok bigint NOT NULL,
  id_inv_produk     bigint NOT NULL,
  id_inv_lot_serial bigint,
  qty_on_hand       int NOT NULL DEFAULT 0,
  qty_dipesan       int NOT NULL DEFAULT 0,           -- TERJADWAL keluar (reservasi ATP)
  qty_tersedia      int NOT NULL DEFAULT 0,           -- on_hand - dipesan (dihitung recompute)
  nilai_persediaan  numeric(18,4) NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,                      -- NULL; baris dibangun ulang sweep
  CONSTRAINT uq_inv_saldo_stok_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_saldo_on_hand CHECK (qty_on_hand >= 0),
  CONSTRAINT fk_inv_saldo_lokasi FOREIGN KEY (id_inv_lokasi_stok)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_saldo_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_saldo_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE RESTRICT
);

-- tanpa version: baris READMODEL dihitung ulang (D-12)
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_saldo_tanpa_lot
  ON inv_saldo_stok (id_inv_lokasi_stok, id_inv_produk)
  WHERE id_inv_lot_serial IS NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_saldo_dengan_lot
  ON inv_saldo_stok (id_inv_lokasi_stok, id_inv_produk, id_inv_lot_serial)
  WHERE id_inv_lot_serial IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_saldo_produk ON inv_saldo_stok (id_inv_produk);

-- -----------------------------------------------------------------------------
-- Trigger updated_at — semua tabel INV (D-04)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inv_kategori_produk','inv_unit_ukur','inv_produk','inv_gudang','inv_lokasi_stok',
    'inv_lot_serial','inv_gerakan_stok','inv_penyesuaian_stok','inv_penyesuaian_stok_items',
    'inv_biaya_pembelian_landed','inv_biaya_pembelian_landed_items','inv_saldo_stok'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- PATCH 02-inventory.sql selesai.
