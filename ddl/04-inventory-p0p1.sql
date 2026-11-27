-- =============================================================================
-- PATCH DDL 04-inventory-p0p1.sql — Penutup gap P0/P1 audit fitur INV vs Odoo
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : docs/audit-fitur-inv-vs-odoo.md (P0 #1–5, P1 #6–11)
--            docs/analisa-modul-inv-v2.md (A-02 picking agregat, F08/F10)
-- Kartu    : docs/arsitektur-database-core-inv.md §8 (kartu klasifikasi baru)
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum baru
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_reservasi AS ENUM ('TIDAK', 'TERRESERVASI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_frekuensi_hitung AS ENUM ('HARIAN', 'MINGGUAN', 'BULANAN', 'TRIWULAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- inv_jenis_operasi — operation types (P1 #8 + P0 #3) [MASTER]
-- Formalkan prefix penomoran + jumlah langkah + lokasi default per jenis operasi.
-- Eksekusi multi-langkah (CFG-INV-03/04) hidup pada kolom langkah/total_langkah
-- inv_gerakan_stok — picking tetap agregat nomor_dokumen (D-07, tanpa tabel picking).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_jenis_operasi (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                     varchar(50) NOT NULL,          -- RCV, DLV, TRF, ADJ, SCR
  nama                     varchar(100) NOT NULL,
  jenis_gerakan            enum_jenis_gerakan NOT NULL,
  prefix                   varchar(20) NOT NULL,          -- prefix penomoran core_sequences
  jumlah_langkah           int NOT NULL DEFAULT 1,        -- 1/2/3 (CFG-INV-03/04 sebagai default baris baru)
  nama_langkah_1           varchar(100) NOT NULL DEFAULT 'Input',
  nama_langkah_2           varchar(100),
  nama_langkah_3           varchar(100),
  id_lokasi_sumber_default bigint,                        -- default untuk gerakan jenis ini
  id_lokasi_tujuan_default bigint,
  status                   enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                  int NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_inv_jenis_operasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_jenis_operasi_kode UNIQUE (kode),
  CONSTRAINT ck_inv_jenis_operasi_langkah CHECK (jumlah_langkah BETWEEN 1 AND 3),
  CONSTRAINT ck_inv_jenis_operasi_nama_langkah CHECK
    ((jumlah_langkah < 2 OR nama_langkah_2 IS NOT NULL) AND
     (jumlah_langkah < 3 OR nama_langkah_3 IS NOT NULL)),
  CONSTRAINT fk_inv_jenis_operasi_sumber FOREIGN KEY (id_lokasi_sumber_default)
    REFERENCES inv_lokasi_stok (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_jenis_operasi_tujuan FOREIGN KEY (id_lokasi_tujuan_default)
    REFERENCES inv_lokasi_stok (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_jenis_operasi_gerakan
  ON inv_jenis_operasi (jenis_gerakan) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- inv_lapisan_biaya — cost layer FIFO (P0 #1) [TRANSAKSI]
-- Lapisan biaya per produk (± lot) lahir dari penerimaan/penyesuaian-plus SELESAI;
-- konsumsi keluar mengambil lapisan tertua dulu (FIFO). AVCO tidak memakai tabel ini.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_lapisan_biaya (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id          uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk      bigint NOT NULL,
  id_inv_lot_serial  bigint,
  nomor_dokumen_masuk varchar(150) NOT NULL,            -- gerakan penerimaan pembentuk lapisan
  tanggal_masuk      timestamptz NOT NULL DEFAULT now(),
  qty_masuk          int NOT NULL,
  qty_terpakai       int NOT NULL DEFAULT 0,
  biaya_persatuan    numeric(18,4) NOT NULL,
  version            int NOT NULL DEFAULT 1,           -- mutasi via API? tidak — job/domain; dipertahankan K-05 default
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CONSTRAINT uq_inv_lapisan_biaya_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_lapisan_biaya_qty CHECK (qty_masuk > 0 AND qty_terpakai >= 0 AND qty_terpakai <= qty_masuk),
  CONSTRAINT ck_inv_lapisan_biaya_biaya CHECK (biaya_persatuan >= 0),
  CONSTRAINT fk_inv_lapisan_biaya_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_lapisan_biaya_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_lapisan_biaya_fefo
  ON inv_lapisan_biaya (id_inv_produk, tanggal_masuk, id)
  WHERE deleted_at IS NULL AND qty_terpakai < qty_masuk;
CREATE INDEX IF NOT EXISTS ix_inv_lapisan_biaya_dokumen
  ON inv_lapisan_biaya (nomor_dokumen_masuk);

-- -----------------------------------------------------------------------------
-- inv_kemasan — product packaging (P1 #10) [MASTER]
-- Kemasan jual per produk (mis. DUS-12 berisi 12) — barcode kemasan bisa dipindai
-- dan di-resolve menjadi produk × qty_isi pada operasi pindai (F15).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_kemasan (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk    bigint NOT NULL,
  kode             varchar(50) NOT NULL,                -- DUS-12, PALET-100
  nama             varchar(100) NOT NULL,
  barcode          varchar(50),
  id_inv_unit_ukur bigint NOT NULL,
  qty_isi          int NOT NULL,                        -- 1 kemasan = qty_isi unit
  status           enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version          int NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_inv_kemasan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_kemasan_kode UNIQUE (kode),
  CONSTRAINT ck_inv_kemasan_isi CHECK (qty_isi > 0),
  CONSTRAINT fk_inv_kemasan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_kemasan_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_kemasan_barcode
  ON inv_kemasan (barcode) WHERE deleted_at IS NULL AND barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_inv_kemasan_produk
  ON inv_kemasan (id_inv_produk) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- inv_jadwal_hitung — penjadwalan cycle count (P1 #7) [MASTER]
-- Jadwal count per gudang/lokasi; eksekusi = generate draft inv_penyesuaian_stok
-- jenis CYCLE_COUNT (count sheet: qty_sistem dari saldo, qty_hitung 0) manual atau
-- oleh penjadwal bila jatuh tempo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_jadwal_hitung (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                  varchar(50) NOT NULL,
  nama                  varchar(100) NOT NULL,
  id_inv_gudang         bigint NOT NULL,
  id_inv_lokasi_stok    bigint,                         -- NULL = semua lokasi gudang
  frekuensi             enum_frekuensi_hitung NOT NULL DEFAULT 'BULANAN',
  hari_eksekusi         int NOT NULL DEFAULT 1,         -- 0=Minggu..6=Sabtu utk MINGGUAN; 1..28 utk BULANAN
  aktif                 boolean NOT NULL DEFAULT true,
  terakhir_dibuat_pada  timestamptz,
  version               int NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  deleted_at            timestamptz,
  CONSTRAINT uq_inv_jadwal_hitung_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_jadwal_hitung_kode UNIQUE (kode),
  CONSTRAINT ck_inv_jadwal_hitung_hari CHECK (hari_eksekusi BETWEEN 0 AND 28),
  CONSTRAINT fk_inv_jadwal_hitung_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_jadwal_hitung_lokasi FOREIGN KEY (id_inv_lokasi_stok)
    REFERENCES inv_lokasi_stok (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_jadwal_hitung_aktif
  ON inv_jadwal_hitung (aktif, frekuensi) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- ALTER inv_gerakan_stok — kolom eksekusi multi-langkah + reservasi (P0 #3, P1 #11)
-- Aditif; data lama = langkah 1/1 (sudah selesai input), reservasi TIDAK.
-- -----------------------------------------------------------------------------
ALTER TABLE inv_gerakan_stok ADD COLUMN IF NOT EXISTS kode_jenis_operasi varchar(50);
ALTER TABLE inv_gerakan_stok ADD COLUMN IF NOT EXISTS langkah int NOT NULL DEFAULT 1;
ALTER TABLE inv_gerakan_stok ADD COLUMN IF NOT EXISTS total_langkah int NOT NULL DEFAULT 1;
ALTER TABLE inv_gerakan_stok ADD COLUMN IF NOT EXISTS reservasi enum_status_reservasi NOT NULL DEFAULT 'TIDAK';

COMMENT ON COLUMN inv_gerakan_stok.kode_jenis_operasi IS
  'kode inv_jenis_operasi (jejak; tidak FK agar jenis operasi bisa diarsip)';
COMMENT ON COLUMN inv_gerakan_stok.langkah IS
  'tahap eksekusi saat ini (1..total_langkah); konfirmasi stok hanya di langkah terakhir';
COMMENT ON COLUMN inv_gerakan_stok.reservasi IS
  'TERRESERVASI = stok dikunci untuk picking ini (qty_dipesan ikut menghitung)';

DO $$ BEGIN
  ALTER TABLE inv_gerakan_stok ADD CONSTRAINT ck_inv_gerakan_langkah CHECK
    (langkah >= 1 AND total_langkah >= 1 AND langkah <= total_langkah AND total_langkah <= 3);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS ix_inv_gerakan_picking_langkah
  ON inv_gerakan_stok (nomor_dokumen, langkah) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Trigger updated_at — tabel baru patch ini (D-04)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inv_jenis_operasi','inv_lapisan_biaya','inv_kemasan','inv_jadwal_hitung'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- PATCH 04-inventory-p0p1.sql selesai.
