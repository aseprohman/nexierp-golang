-- +goose Up
-- Porting 1:1 dari ddl/03-inventory-varian.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 03-inventory-varian.sql — Pola Multi-Varian Produk (dukungan katalog ECOM)
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : docs/arsitektur-database-core-inv.md §7 (kartu + keputusan D-17..D-22)
-- Pola     : inv_produk_induk (template) + inv_produk (varian = SKU jual/stok, tetap
--            satu-satunya identitas yang dirujuk gerakan/saldo/lot/kanal)
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum (K-07)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_tipe_atribut AS ENUM ('PILIHAN', 'BEBAS');
  -- PILIHAN  : nilai terkurasi -> kombinasi nilai inilah pembentuk varian (warna/ukuran)
  -- BEBAS    : input bebas (engraving/catatan), tidak membentuk varian
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- inv_produk_induk — induk/template produk multi-varian [MASTER]
-- Varian nyata tetap inv_produk; induk mengelompokkan varian untuk katalog (ECOM)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_produk_induk (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                    varchar(50) NOT NULL,          -- kode induk, mis. TSHIRT-001
  nama                    varchar(100) NOT NULL,
  deskripsi               text,                          -- prosa bebas (K-08)
  id_inv_kategori_produk  bigint NOT NULL,               -- default kategori varian baru
  id_inv_unit_ukur        bigint NOT NULL,               -- default unit varian baru
  status                  enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                 int NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_inv_produk_induk_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_produk_induk_kode UNIQUE (kode),
  CONSTRAINT fk_inv_produk_induk_kategori FOREIGN KEY (id_inv_kategori_produk)
    REFERENCES inv_kategori_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_produk_induk_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_produk_induk_status
  ON inv_produk_induk (status) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- inv_atribut — definisi atribut varian [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_atribut (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,                 -- WARNA, UKURAN, MEMORI
  nama        varchar(100) NOT NULL,
  tipe_input  enum_tipe_atribut NOT NULL DEFAULT 'PILIHAN',
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     int NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_inv_atribut_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_atribut_kode UNIQUE (kode)
);

-- -----------------------------------------------------------------------------
-- inv_nilai_atribut — nilai terkurasi per atribut [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_nilai_atribut (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_atribut bigint NOT NULL,
  nilai          varchar(100) NOT NULL,              -- Merah, XL, 128GB
  urutan         int NOT NULL DEFAULT 0,             -- urutan tampil di katalog
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_inv_nilai_atribut_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_inv_nilai_atribut_atribut FOREIGN KEY (id_inv_atribut)
    REFERENCES inv_atribut (id) ON DELETE RESTRICT
);

-- satu nilai unik per atribut (bisa dipakai ulang setelah soft delete)
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_nilai_atribut_atribut_nilai
  ON inv_nilai_atribut (id_inv_atribut, nilai) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_nilai_atribut_atribut
  ON inv_nilai_atribut (id_inv_atribut, urutan);

-- -----------------------------------------------------------------------------
-- inv_produk_induk_atribut — baris konfigurasi varian per induk [LINE]
-- (punya kolom bisnis wajib/urutan -> LINE, bukan junction murni; lihat D-19)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_produk_induk_atribut (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk_induk     bigint NOT NULL,
  id_inv_atribut          bigint NOT NULL,
  wajib                   boolean NOT NULL DEFAULT true,  -- kombinasi wajib menyertakan nilai atribut ini
  urutan                  int NOT NULL DEFAULT 0,
  version                 int NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_inv_produk_induk_atribut_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_inv_produk_induk_atribut_induk FOREIGN KEY (id_inv_produk_induk)
    REFERENCES inv_produk_induk (id) ON DELETE CASCADE,
  CONSTRAINT fk_inv_produk_induk_atribut_atribut FOREIGN KEY (id_inv_atribut)
    REFERENCES inv_atribut (id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- inv_produk_atribut — pasangan varian <-> nilai atribut [JUNCTION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_produk_atribut (
  id_inv_produk        bigint NOT NULL,
  id_inv_nilai_atribut bigint NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT pk_inv_produk_atribut PRIMARY KEY (id_inv_produk, id_inv_nilai_atribut),
  CONSTRAINT fk_inv_produk_atribut_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE CASCADE,
  CONSTRAINT fk_inv_produk_atribut_nilai FOREIGN KEY (id_inv_nilai_atribut)
    REFERENCES inv_nilai_atribut (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_produk_atribut_nilai
  ON inv_produk_atribut (id_inv_nilai_atribut);

-- -----------------------------------------------------------------------------
-- ALTER inv_produk — produk kini bisa berperan varian (aditif, tanpa refactor rujukan)
-- -----------------------------------------------------------------------------
ALTER TABLE inv_produk ADD COLUMN IF NOT EXISTS id_inv_produk_induk bigint;
ALTER TABLE inv_produk ADD COLUMN IF NOT EXISTS kunci_kombinasi varchar(300);

COMMENT ON COLUMN inv_produk.id_inv_produk_induk IS
  'NULL = produk sederhana (tanpa varian); terisi = varian dari inv_produk_induk';
COMMENT ON COLUMN inv_produk.kunci_kombinasi IS
  'kombinasi kanonik nilai atribut, dibentuk app (sorted "atribut:nilai|...") — hanya untuk varian';

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_produk ADD CONSTRAINT fk_inv_produk_induk FOREIGN KEY (id_inv_produk_induk)
    REFERENCES inv_produk_induk (id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_produk ADD CONSTRAINT ck_inv_produk_kombinasi CHECK
    ((kunci_kombinasi IS NULL) OR (id_inv_produk_induk IS NOT NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- kombinasi unik per induk; produk sederhana (tanpa induk) tidak ikut
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_produk_kombinasi
  ON inv_produk (id_inv_produk_induk, kunci_kombinasi)
  WHERE id_inv_produk_induk IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_produk_induk ON inv_produk (id_inv_produk_induk);

-- -----------------------------------------------------------------------------
-- Trigger updated_at — tabel baru patch ini (D-04)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inv_produk_induk','inv_atribut','inv_nilai_atribut',
    'inv_produk_induk_atribut','inv_produk_atribut'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- PATCH 03-inventory-varian.sql selesai.
