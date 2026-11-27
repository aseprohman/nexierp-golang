-- +goose Up
-- Porting 1:1 dari ddl/23-pos.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 23-pos.sql — Modul POS (Point of Sale, Kasir Multi-Outlet)
-- Domain   : OdooLikeERP · Modul POS — blueprint final docs/analisa-modul-pos-v3.md
--            (F01–F20, BR01–BR19, M09/M10/M12/M29/M30/M36/M38; revisi Q-01:
--            loyalitas poin F19 + promo kasir F20 masuk scope)
-- Kartu    : docs/arsitektur-database-pos.md (PP-01…PP-19 + PP-20)
-- Idempoten: aman dijalankan berulang (enum DO-block, IF NOT EXISTS, trigger DO-block)
-- Prasyarat: ddl/01-core.sql (set_updated_at, core_users, enum_status_aktif)
--            + patch INV (inv_gudang, inv_produk, inv_lot_serial, inv_unit_ukur)
--
-- PP-20 (keputusan pemilik modul, 2026-11-06) — tabel master yang dipakai
--   LINTAS MODUL masuk modul CORE dengan nama tabel core_:
--   • core_metode_bayar [MASTER, pemilik CORE] — master metode bayar dirujuk
--     POS (pembayaran/kas sesi/refund), ACC (pemetaan akun jurnal per metode,
--     kolom reserved id_acc_*), dan RSV (deposit M21, masa depan).
--   • outlet TETAP milik POS (putusan pemilik bisnis: outlet ≠ gudang; master
--     `pos_outlet` mengikuti kartu 3.1).
--   Enum kosakata ikut naik: enum_jenis_metode_bayar_pos di-rename menjadi
--   enum_jenis_metode_bayar_core (tidak ada dependen di DB live saat patch).
--   Sisanya (16 tabel pos_*) murni internal modul POS.
--
-- Integrasi lintas modul (tanpa FK transaksional, D-11):
--   M09 stok  → tulis inv_gerakan_header/inv_gerakan_stok jenis_sumber='POS'
--               dari gudang pemetaan outlet (pos_outlet.id_inv_gudang) saat
--               tutup sesi/per pesanan (CFG-POS-05) — idempoten per sesi/struk.
--   M10 jurnal→ outbox core_outbox_events topic 'pos.sesi.ditutup' (payload
--               ringkasan per metode dari pos_sesi_kas + kas in/out + selisih).
--   M38 faktur→ outbox topic 'pos.pesanan.faktur' (butuh_faktur=true).
--   Referensi modul yang belum live (SLS/FNB/ACC) = kolom bigint reserved
--   TANPA FK — constraint FK ditambahkan patch modul pemilik (PP-03).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. Enum (kosakata PERSIS blueprint v3; enum_status_aktif dipinjam dari 01-core)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_sesi_pos AS ENUM ('DIBUKA', 'AKTIF', 'MENUNGGU_TUTUP', 'DITAHAN', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pesanan_pos AS ENUM ('DRAFT', 'DIBAYAR', 'SELESAI', 'BATAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_refund_pos AS ENUM ('TANPA_REFUND', 'REFUND_PARSIAL', 'REFUND_PENUH');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pengajuan_pos AS ENUM ('MENUNGGU_PERSETUJUAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_faktur_pos AS ENUM ('TANPA_FAKTUR', 'MENUNGGU_FAKTUR', 'FAKTUR_TERBIT', 'GAGAL_FAKTUR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kanal_pos AS ENUM ('RETAIL', 'DINE_IN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_dapur_baris AS ENUM ('DIPESAN', 'DIMASAK', 'DISAJIKAN', 'VOID', 'KENDUR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_bukti_refund AS ENUM ('STRUK_ASLI', 'ID_PESANAN', 'KETERANGAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_arah_mutasi_kas_pos AS ENUM ('MASUK', 'KELUAR');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_subjek_pos AS ENUM ('SESI', 'PESANAN', 'ITEM');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_promo_pos AS ENUM ('PERSEN_MIN_BELANJA', 'NOMINAL_MIN_BELANJA', 'GRATIS_PRODUK', 'HARGA_KHUSUS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_mutasi_poin_pos AS ENUM ('EARN', 'REDEEM', 'EXPIRE', 'ADJUST');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- enum metode bayar naik ke CORE (PP-20): rename type lama bila ada, else create.
-- +goose StatementBegin
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'enum_jenis_metode_bayar_core') THEN
    IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'enum_jenis_metode_bayar_pos') THEN
      ALTER TYPE enum_jenis_metode_bayar_pos RENAME TO enum_jenis_metode_bayar_core;
    ELSE
      CREATE TYPE enum_jenis_metode_bayar_core AS ENUM
        ('TUNAI', 'KARTU', 'QRIS', 'TRANSFER', 'LAINNYA', 'POIN');
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- 'POIN' = redeem loyalitas (F19/BR17) — jaminan idempoten bila type berasal
-- dari DB lama yang belum memuat nilai ini.
-- +goose StatementBegin
DO $$ BEGIN
  ALTER TYPE enum_jenis_metode_bayar_core ADD VALUE IF NOT EXISTS 'POIN';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- B. CORE — master metode bayar (tabel lintas modul, PP-20)
-- -----------------------------------------------------------------------------
-- [MASTER] core_metode_bayar — pemilik CORE; dirujuk POS/ACC/RSV.
-- Pemetaan akun jurnal per metode = domain ACC (kolom reserved id_acc_* —
-- FK menyusul patch ACC). Kode & nama unik partial: reusable setelah soft-delete.
CREATE TABLE IF NOT EXISTS core_metode_bayar (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,
  nama                 varchar(100) NOT NULL,
  jenis                enum_jenis_metode_bayar_core NOT NULL,
  butuh_referensi      boolean NOT NULL DEFAULT false,   -- wajib no. EDC/gateway
  id_acc_akun_kas      bigint,                           -- reserved: FK oleh patch ACC
  id_acc_akun_pendapatan bigint,                         -- reserved: FK oleh patch ACC
  urutan               int NOT NULL DEFAULT 0,           -- urutan tampil di layar kasir
  status               enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_core_metode_bayar_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_core_metode_bayar_urutan CHECK (urutan >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_metode_bayar_kode
  ON core_metode_bayar (kode) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_metode_bayar_nama
  ON core_metode_bayar (nama) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_metode_bayar_status
  ON core_metode_bayar (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

COMMENT ON TABLE core_metode_bayar IS
  '[MASTER] metode bayar (CORE, PP-20) — dirujuk pembayaran/kas/refund POS,'
  ' pemetaan akun jurnal ACC, deposit RSV; kosakata: TUNAI/KARTU/QRIS/TRANSFER/'
  'LAINNYA/POIN (POIN = redeem loyalitas F19).';
COMMENT ON COLUMN core_metode_bayar.id_acc_akun_kas IS
  'reserved — FK ke acc_akun_coa ditambahkan patch modul ACC (PP-03/D-11).';

-- -----------------------------------------------------------------------------
-- C. POS — master outlet & junction konfigurasi kasir
-- -----------------------------------------------------------------------------
-- [MASTER] pos_outlet — pemilik POS (putusan pemilik bisnis: outlet ≠ gudang);
-- memetakan tepat satu gudang stok INV sebagai sumber pemotongan M09 (PP-02).
CREATE TABLE IF NOT EXISTS pos_outlet (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,
  nama                 varchar(100) NOT NULL,
  no_telepon           varchar(50),
  alamat               varchar(300),
  kelompok_cabang      varchar(100),                    -- pengelompokan antar-outlet
  id_inv_gudang        bigint NOT NULL,                 -- pemetaan stok; gudang tetap milik INV
  status               enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_outlet_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pos_outlet_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_outlet_kode
  ON pos_outlet (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_outlet_status
  ON pos_outlet (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_outlet_gudang
  ON pos_outlet (id_inv_gudang);

COMMENT ON TABLE pos_outlet IS
  '[MASTER] outlet kasir (POS) — unit pemisahan sesi/katalog/metode bayar/'
  'laporan; memetakan tepat satu gudang stok INV (pemilik gudang tetap INV).';
COMMENT ON COLUMN pos_outlet.id_inv_gudang IS
  'pemetaan (bukan identitas) — sumber pemotongan stok M09; gudang ≠ outlet.';

-- [JUNCTION] pos_outlet_metode_bayar — metode bayar AKTIF per outlet (N:M
-- murni, PK komposit, tanpa kolom bisnis; PP-12). Metode = master CORE.
CREATE TABLE IF NOT EXISTS pos_outlet_metode_bayar (
  id_pos_outlet        bigint NOT NULL,
  id_core_metode_bayar bigint NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT pk_pos_outlet_metode_bayar PRIMARY KEY (id_pos_outlet, id_core_metode_bayar),
  CONSTRAINT fk_pos_outlet_metode_bayar_outlet FOREIGN KEY (id_pos_outlet)
    REFERENCES pos_outlet (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_outlet_metode_bayar_metode FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_pom_metode
  ON pos_outlet_metode_bayar (id_core_metode_bayar) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_outlet_metode_bayar IS
  '[JUNCTION] metode bayar aktif per outlet (PP-12) — kosong = semua metode'
  ' AKTIF tidak otomatis; keanggotaan eksplisit dikelola Supervisor (F03/F18).';

-- [JUNCTION] pos_outlet_produk — katalog kasir per outlet (F08/PP-13):
-- KOSONG = mode SEMUA (semua produk INV AKTIF sah dijual); ada baris = mode
-- WHITELIST (hanya produk terdaftar — gerbang BR11 ITEM_DI_LUAR_KATALOG).
-- Mutasi = insert / soft-delete / reaktivasi (deleted_at di-null-kan).
CREATE TABLE IF NOT EXISTS pos_outlet_produk (
  id_pos_outlet        bigint NOT NULL,
  id_inv_produk        bigint NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT pk_pos_outlet_produk PRIMARY KEY (id_pos_outlet, id_inv_produk),
  CONSTRAINT fk_pos_outlet_produk_outlet FOREIGN KEY (id_pos_outlet)
    REFERENCES pos_outlet (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_outlet_produk_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_pop_produk
  ON pos_outlet_produk (id_inv_produk) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_outlet_produk IS
  '[JUNCTION] katalog kasir per outlet (F08/PP-13) — kosong = SEMUA produk INV'
  ' AKTIF sah; ada baris = WHITELIST. Tanpa version (mutasi = insert/soft-delete).';

-- -----------------------------------------------------------------------------
-- D. POS — loyalitas poin (F19) & promo kasir (F20)
-- -----------------------------------------------------------------------------
-- [MASTER] pos_program_loyalitas — aturan earn/tukar poin; tepat SATU program
-- AKTIF ditegakkan DB (uq_pos_program_aktif — BR18, PP-14).
CREATE TABLE IF NOT EXISTS pos_program_loyalitas (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,
  nama                 varchar(100) NOT NULL,
  poin_per_nominal     numeric(18,6) NOT NULL DEFAULT 0, -- earn: poin per basis_nominal
  basis_nominal        numeric(18,4) NOT NULL DEFAULT 1000,
  nominal_per_poin     numeric(18,4) NOT NULL DEFAULT 100, -- tukar saat redeem
  min_poin_redeem      int NOT NULL DEFAULT 0,
  masa_berlaku_bulan   int,                              -- NULL = tak kedaluwarsa
  redeem_aktif         boolean NOT NULL DEFAULT true,
  status               enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_program_loyalitas_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_program_poin CHECK (poin_per_nominal >= 0),
  CONSTRAINT ck_pos_program_basis CHECK (basis_nominal > 0),
  CONSTRAINT ck_pos_program_tukar CHECK (nominal_per_poin > 0),
  CONSTRAINT ck_pos_program_min_redeem CHECK (min_poin_redeem >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_program_loyalitas_kode
  ON pos_program_loyalitas (kode) WHERE deleted_at IS NULL;
-- BR18: tepat SATU program AKTIF di satu waktu (partial unique ekspresi konstanta).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_program_aktif
  ON pos_program_loyalitas ((1)) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_program_status
  ON pos_program_loyalitas (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

COMMENT ON TABLE pos_program_loyalitas IS
  '[MASTER] program loyalitas poin (F19/PP-14) — aturan akumulasi & tukar;'
  ' saldo TIDAK disimpan di sini (hidup di pos_kartu_poin dari ledger).';

-- [MASTER] pos_promo — program promo kasir otomatis per outlet (F20/PP-15).
CREATE TABLE IF NOT EXISTS pos_promo (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,
  nama                 varchar(100) NOT NULL,
  jenis                enum_jenis_promo_pos NOT NULL,
  nilai_persen         numeric(18,6),                    -- wajib PERSEN_MIN_BELANJA
  nilai_nominal        numeric(18,4),                    -- wajib NOMINAL_MIN_BELANJA/GRATIS_PRODUK
  min_belanja          numeric(18,4),                    -- ambang struk; NULL = tanpa
  mulai_at             timestamptz NOT NULL DEFAULT now(),
  selesai_at           timestamptz,                      -- NULL = tanpa batas akhir
  jam_mulai            time,                             -- happy hour harian (pasangan)
  jam_selesai          time,
  prioritas            int NOT NULL DEFAULT 0,           -- tabrakan: prioritas tinggi menang (BR19)
  status               enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_promo_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_promo_nilai CHECK (
    (jenis = 'PERSEN_MIN_BELANJA' AND nilai_persen IS NOT NULL) OR
    (jenis IN ('NOMINAL_MIN_BELANJA', 'GRATIS_PRODUK') AND nilai_nominal IS NOT NULL) OR
    jenis = 'HARGA_KHUSUS'
  ),
  CONSTRAINT ck_pos_promo_jam CHECK ((jam_mulai IS NULL) = (jam_selesai IS NULL)),
  CONSTRAINT ck_pos_promo_periode CHECK (selesai_at IS NULL OR selesai_at >= mulai_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_promo_kode
  ON pos_promo (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_promo_aktif
  ON pos_promo (status, selesai_at) WHERE status = 'AKTIF' AND deleted_at IS NULL;

COMMENT ON TABLE pos_promo IS
  '[MASTER] promo kasir otomatis (F20/PP-15) — jenis/ambang/jendela waktu/'
  'prioritas; hasil penerapannya beku di pos_pesanan(.items), master tetap hidup.';

-- [JUNCTION] pos_promo_outlet — outlet pengikut promo; EKSPLISIT (tanpa trik
-- "kosong = semua" ala F08 — promo default-semua berisiko finansial, PP-15).
CREATE TABLE IF NOT EXISTS pos_promo_outlet (
  id_pos_promo         bigint NOT NULL,
  id_pos_outlet        bigint NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT pk_pos_promo_outlet PRIMARY KEY (id_pos_promo, id_pos_outlet),
  CONSTRAINT fk_pos_promo_outlet_promo FOREIGN KEY (id_pos_promo)
    REFERENCES pos_promo (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_promo_outlet_outlet FOREIGN KEY (id_pos_outlet)
    REFERENCES pos_outlet (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_ppo_outlet
  ON pos_promo_outlet (id_pos_outlet) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_promo_outlet IS
  '[JUNCTION] outlet pengikut promo (F20/PP-15) — promo hanya sah di outlet'
  ' terdaftar (BR19).';

-- [LINE] pos_promo_item — produk khusus promo (anak master): harga_khusus
-- bila HARGA_KHUSUS; qty_gratis bila GRATIS_PRODUK (PP-15).
CREATE TABLE IF NOT EXISTS pos_promo_item (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_promo         bigint NOT NULL,
  id_inv_produk        bigint NOT NULL,
  harga_khusus         numeric(18,4),
  qty_gratis           int,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_promo_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pos_promo_item_promo FOREIGN KEY (id_pos_promo)
    REFERENCES pos_promo (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_promo_item_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pos_promo_item_harga CHECK (harga_khusus IS NULL OR harga_khusus >= 0),
  CONSTRAINT ck_pos_promo_item_qty_gratis CHECK (qty_gratis IS NULL OR qty_gratis > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_promo_item_pair
  ON pos_promo_item (id_pos_promo, id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ppi_produk
  ON pos_promo_item (id_inv_produk) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_promo_item IS
  '[LINE] produk khusus promo (anak pos_promo, PP-15) — harga_khusus/'
  'qty_gratis sesuai jenis induknya.';

-- -----------------------------------------------------------------------------
-- E. POS — sesi kasir (TRANSAKSI + LINE + LOG)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pos_sesi — periode kerja satu kasir pada satu outlet (F01/BR15);
-- wadah pertanggungjawaban kas; muara M09 (stok) & M10 (jurnal).
CREATE TABLE IF NOT EXISTS pos_sesi (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_sesi           varchar(50) NOT NULL,             -- penomoran global SES/{MMyy} (A-08/K-10)
  id_pos_outlet        bigint NOT NULL,                  -- tepat satu outlet (BR15)
  id_core_users_kasir  bigint NOT NULL,                  -- satu sesi = satu kasir pemilik (A-10)
  id_core_users_penutup bigint,                           -- boleh supervisor atas nama (jejak via event log)
  status               enum_status_sesi_pos NOT NULL DEFAULT 'DIBUKA',
  waktu_buka           timestamptz NOT NULL DEFAULT now(),
  waktu_tutup          timestamptz,
  saldo_teoritis       numeric(18,4),                    -- beku saat tutup: awal ± kas in/out − tunai + refund
  hitungan_akhir       numeric(18,4),                    -- kas fisik terhitung
  selisih_kas          numeric(18,4),                    -- over/short; > toleransi CFG-POS-12 wajib approval
  alasan_selisih       varchar(300),                     -- wajib bila selisih ≠ 0 (CHECK)
  ringkasan_pajak      numeric(18,4),                    -- beku saat tutup — payload M10
  ringkasan_refund     numeric(18,4),                    -- beku saat tutup — payload M10
  alasan_ditahan       varchar(300),                     -- gagal M09/M10 (POS-BR09/10)
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_sesi_entity_id UNIQUE (entity_id),
  -- penomoran global: tidak pernah dipakai ulang (unique penuh, tanpa deleted_at)
  CONSTRAINT uq_pos_sesi_nomor UNIQUE (nomor_sesi),
  CONSTRAINT ck_pos_sesi_selisih_alasan CHECK (
    selisih_kas IS NULL OR selisih_kas = 0 OR alasan_selisih IS NOT NULL
  ),
  CONSTRAINT fk_pos_sesi_outlet FOREIGN KEY (id_pos_outlet)
    REFERENCES pos_outlet (id) ON DELETE RESTRICT,
  -- akuntabilitas finansial selamat → RESTRICT (bukan SET NULL)
  CONSTRAINT fk_pos_sesi_kasir FOREIGN KEY (id_core_users_kasir)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_sesi_penutup FOREIGN KEY (id_core_users_penutup)
    REFERENCES core_users (id) ON DELETE SET NULL
);

-- Gerbang CFG-POS-08 level kasir: satu sesi hidup per (outlet, kasir);
-- mode "satu per outlet" ditegakkan app (config-dependent).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_sesi_hidup
  ON pos_sesi (id_pos_outlet, id_core_users_kasir) WHERE status <> 'DITUTUP';
CREATE INDEX IF NOT EXISTS ix_pos_sesi_outlet_status
  ON pos_sesi (id_pos_outlet, status) WHERE status <> 'DITUTUP';
CREATE INDEX IF NOT EXISTS ix_pos_sesi_kasir
  ON pos_sesi (id_core_users_kasir, waktu_buka);

COMMENT ON TABLE pos_sesi IS
  '[TRANSAKSI] sesi kasir per outlet (F01) — DIBUKA→AKTIF→MENUNGGU_TUTUP→'
  'DITUTUP; cabang DITAHAN bila M09/M10 gagal; ringkasan beku saat tutup.';

-- [LINE] pos_sesi_kas — kas sesi per metode: saldo awal, ringkasan beku,
-- hitungan fisik, selisih — isi Z-report & payload M10 (kartu 3.6).
CREATE TABLE IF NOT EXISTS pos_sesi_kas (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_sesi          bigint NOT NULL,
  id_core_metode_bayar bigint NOT NULL,
  saldo_awal           numeric(18,4) NOT NULL DEFAULT 0,
  total_penjualan      numeric(18,4),                    -- beku saat tutup
  total_refund         numeric(18,4),                    -- beku saat tutup
  hitungan_akhir       numeric(18,4),                    -- hitungan fisik per metode
  selisih_kas          numeric(18,4),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_sesi_kas_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pos_sesi_kas_sesi FOREIGN KEY (id_pos_sesi)
    REFERENCES pos_sesi (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_sesi_kas_metode FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_sesi_kas_pair
  ON pos_sesi_kas (id_pos_sesi, id_core_metode_bayar) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_sesi_kas IS
  '[LINE] kas sesi per metode bayar (kartu 3.6) — baris Z-report; dibekukan'
  ' saat sesi ditutup; tanpa version (pola LINE).';

-- [LOG/EVENT append-only] pos_sesi_mutasi_kas — kas masuk/keluar ber-alasan
-- (F14/BR05): kejadian historis, tanpa UPDATE/DELETE dari app (PP-11).
CREATE TABLE IF NOT EXISTS pos_sesi_mutasi_kas (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_sesi          bigint NOT NULL,
  id_core_users        bigint,                           -- NULL = aktor sistem
  id_core_metode_bayar bigint,                            -- NULL = tunai murni
  arah                 enum_arah_mutasi_kas_pos NOT NULL,
  nilai                numeric(18,4) NOT NULL,
  alasan               varchar(300) NOT NULL,            -- BR05: wajib ber-alasan
  waktu_mutasi         timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(), -- beku (append-only)
  deleted_at           timestamptz,                          -- selalu NULL
  CONSTRAINT uq_pos_sesi_mutasi_kas_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_sesi_mutasi_kas_nilai CHECK (nilai > 0),
  CONSTRAINT fk_pos_sesi_mutasi_kas_sesi FOREIGN KEY (id_pos_sesi)
    REFERENCES pos_sesi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_sesi_mutasi_kas_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pos_sesi_mutasi_kas_metode FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_psmk_sesi
  ON pos_sesi_mutasi_kas (id_pos_sesi, waktu_mutasi);

COMMENT ON TABLE pos_sesi_mutasi_kas IS
  '[LOG/EVENT append-only] kas masuk/keluar sesi (F14/BR05) — komponen saldo'
  ' teoritis & baris terpisah dalam payload M10 (Q-03); tanpa UPDATE/DELETE app.';

-- -----------------------------------------------------------------------------
-- F. POS — pesanan kasir (TRANSAKSI + LINE + approval + LOG)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pos_pesanan — satu transaksi kasir (struk); outlet diwarisi
-- sesinya (BR15); anak: items, pembayaran, refund, event log.
CREATE TABLE IF NOT EXISTS pos_pesanan (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_struk          varchar(50),                      -- terisi saat DIBAYAR/reservasi offline (BR01/BR13)
  id_pos_sesi          bigint NOT NULL,
  id_sls_pelanggan     bigint,                           -- reserved: FK oleh patch SLS (PP-03)
  id_fnb_meja          bigint,                           -- reserved: FK oleh patch FNB (dine-in)
  kanal                enum_kanal_pos NOT NULL DEFAULT 'RETAIL',
  status               enum_status_pesanan_pos NOT NULL DEFAULT 'DRAFT',
  status_refund        enum_status_refund_pos NOT NULL DEFAULT 'TANPA_REFUND',
  referensi_retur      varchar(50),
  butuh_faktur         boolean NOT NULL DEFAULT false,   -- penandaan faktur (F15); terbit = ACC (M38)
  status_faktur        enum_status_faktur_pos NOT NULL DEFAULT 'TANPA_FAKTUR',
  referensi_faktur     varchar(50),                      -- nomor faktur balikan ACC
  id_acc_faktur        bigint,                           -- reserved: FK oleh patch ACC
  subtotal             numeric(18,4) NOT NULL DEFAULT 0, -- beku saat DIBAYAR (BR03)
  diskon               numeric(18,4) NOT NULL DEFAULT 0, -- Σ diskon baris (beku)
  service_charge       numeric(18,4) NOT NULL DEFAULT 0, -- dari FNB
  pajak                numeric(18,4) NOT NULL DEFAULT 0, -- skema CFG-PLT-04 (BR12)
  pembulatan           numeric(18,4) NOT NULL DEFAULT 0, -- CFG-POS-07, setelah pajak
  total                numeric(18,4) NOT NULL DEFAULT 0,
  total_refund         numeric(18,4) NOT NULL DEFAULT 0, -- gerbang BR08 REFUND_MELEBIHI_SISA
  diskon_struk_persen  numeric(18,6) NOT NULL DEFAULT 0, -- PP-19 (F04/CFG-POS-11)
  diskon_struk_nominal numeric(18,4) NOT NULL DEFAULT 0, -- PP-19
  id_core_users_penyetuju_struk bigint,                  -- approval inline Supervisor header (PP-19, SoD BR04)
  waktu_persetujuan_struk timestamptz,
  asal_offline         boolean NOT NULL DEFAULT false,   -- F11/PP-06
  konflik_offline      boolean NOT NULL DEFAULT false,   -- selisih harga saat resinkron → review Supervisor
  catatan_konflik      varchar(300),
  id_pos_promo         bigint,                           -- promo struk otomatis (F20) — hasil beku
  diskon_promo         numeric(18,4) NOT NULL DEFAULT 0,
  poin_diperoleh       int NOT NULL DEFAULT 0,           -- earn snapshot saat DIBAYAR (F19/PP-18) — payload M10
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_pesanan_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_pesanan_faktur_pelanggan CHECK (
    butuh_faktur = false OR id_sls_pelanggan IS NOT NULL
  ),
  CONSTRAINT ck_pos_pesanan_refund_sisa CHECK (
    total_refund >= 0 AND total_refund <= total
  ),
  CONSTRAINT fk_pos_pesanan_sesi FOREIGN KEY (id_pos_sesi)
    REFERENCES pos_sesi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_penyetuju_struk FOREIGN KEY (id_core_users_penyetuju_struk)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pos_pesanan_promo FOREIGN KEY (id_pos_promo)
    REFERENCES pos_promo (id) ON DELETE RESTRICT
);

-- nomor struk unik global tanpa reuse — partial tanpa filter deleted_at (K-10).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_pesanan_struk
  ON pos_pesanan (nomor_struk) WHERE nomor_struk IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_sesi
  ON pos_pesanan (id_pos_sesi);
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_draft
  ON pos_pesanan (id_pos_sesi, status) WHERE status = 'DRAFT' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_faktur
  ON pos_pesanan (status_faktur) WHERE status_faktur = 'MENUNGGU_FAKTUR' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_pelanggan
  ON pos_pesanan (id_sls_pelanggan);
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_promo
  ON pos_pesanan (id_pos_promo);

COMMENT ON TABLE pos_pesanan IS
  '[TRANSAKSI] struk kasir (F02/F07) — DRAFT→DIBAYAR→SELESAI; BATAL terminal;'
  ' refund via status_refund + pos_pesanan_refund; angka final beku saat DIBAYAR.';

-- [LINE] pos_pesanan_items — baris produk/menu; snapshot harga/nama beku saat
-- DIBAYAR; lot untuk produk terlacak (F16/BR14); status dapur dine-in via M30.
CREATE TABLE IF NOT EXISTS pos_pesanan_items (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_pesanan       bigint NOT NULL,
  id_inv_produk        bigint,                           -- wajib utk baris produk (BR11) — dicek app
  id_inv_lot_serial    bigint,                           -- wajib bila produk terlacak (BR14) — dicek app
  id_fnb_menu          bigint,                           -- reserved: FK oleh patch FNB (M12)
  id_fnb_menu_varian   bigint,                           -- reserved: FK oleh patch FNB (POS-1)
  id_inv_unit_ukur     bigint,                           -- snapshot unit jual — FK RESTRICT nullable
  id_core_users_penyetuju bigint,                        -- approval diskon/harga manual (F04, SoD BR04)
  nama_item            varchar(100) NOT NULL,            -- snapshot beku (pola LINE inv)
  qty                  int NOT NULL,
  harga_satuan         numeric(18,4) NOT NULL,           -- harga final server-side (BR03)
  diskon_persen        numeric(18,6) NOT NULL DEFAULT 0,
  diskon_nominal       numeric(18,4) NOT NULL DEFAULT 0,
  harga_manual         boolean NOT NULL DEFAULT false,
  catatan              varchar(300),                     -- modifier dapur (M29)
  status_dapur         enum_status_dapur_baris,          -- hanya dine-in — dikendalikan FNB (M30)
  id_pos_promo_item    bigint,                           -- baris hasil promo produk (F20)
  waktu_persetujuan    timestamptz,
  urutan               int NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_pesanan_items_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_pesanan_items_qty CHECK (qty > 0),
  CONSTRAINT ck_pos_pesanan_items_lot_produk CHECK (
    id_inv_lot_serial IS NULL OR id_inv_produk IS NOT NULL
  ),
  CONSTRAINT fk_pos_pesanan_items_pesanan FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_pesanan_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_items_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_items_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_items_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pos_pesanan_items_promo_item FOREIGN KEY (id_pos_promo_item)
    REFERENCES pos_promo_item (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_ppi_pesanan
  ON pos_pesanan_items (id_pos_pesanan);
CREATE INDEX IF NOT EXISTS ix_pos_pesanan_items_promo
  ON pos_pesanan_items (id_pos_promo_item);

COMMENT ON TABLE pos_pesanan_items IS
  '[LINE] baris struk (F02/F16) — harga/nama/unit/lot snapshot beku; stok TIDAK'
  ' disalin (hidup via M09); status_dapur hanya baris dine-in (M30).';

-- [READMODEL] pos_kartu_poin — saldo poin per pelanggan; sumber kebenaran =
-- ledger pos_mutasi_poin; recompute = sweep Σ(mutasi), dipelihara satu-UoW
-- dengan mutasinya (PP-17). id_sls_pelanggan reserved — FK oleh patch SLS.
CREATE TABLE IF NOT EXISTS pos_kartu_poin (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_pelanggan     bigint NOT NULL,                  -- reserved: FK oleh patch SLS
  saldo_poin           int NOT NULL DEFAULT 0,
  version              int NOT NULL DEFAULT 1,           -- optimistic locking (dimutasi API satu-UoW)
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_kartu_poin_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_kartu_poin_saldo CHECK (saldo_poin >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_kartu_poin_pelanggan
  ON pos_kartu_poin (id_sls_pelanggan) WHERE deleted_at IS NULL;

COMMENT ON TABLE pos_kartu_poin IS
  '[READMODEL] saldo poin per pelanggan (F19/PP-17) — agregat turunan ledger;'
  ' boleh di-rebuild penuh dari pos_mutasi_poin; dibaca lintas modul via M36'
  ' BACA-SAJA (SLS/ECOM) — kepemilikan tetap POS.';

-- [LINE] pos_pesanan_pembayaran — pembayaran per metode (multi-metode F03);
-- Σ(nilai − kembalian) = total saat DIBAYAR; immutable setelah struk terbit.
CREATE TABLE IF NOT EXISTS pos_pesanan_pembayaran (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_pesanan       bigint NOT NULL,
  id_core_metode_bayar bigint NOT NULL,
  nama_metode          varchar(100) NOT NULL,            -- snapshot (master boleh rename/nonaktif; struk beku)
  nilai                numeric(18,4) NOT NULL,
  kembalian            numeric(18,4) NOT NULL DEFAULT 0, -- tunai, dihitung sistem
  referensi            varchar(150),                     -- no. EDC/gateway bila butuh_referensi (CFG-POS-10)
  poin_dipakai         int,                              -- metode POIN (F19/BR17)
  id_pos_kartu_poin    bigint,                           -- kartu poin yang ditukar
  waktu_bayar          timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_pesanan_pembayaran_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_pesanan_pembayaran_nilai CHECK (nilai > 0),
  CONSTRAINT ck_pos_pesanan_pembayaran_kembalian CHECK (kembalian >= 0),
  CONSTRAINT ck_pos_pesanan_pembayaran_poin CHECK (poin_dipakai IS NULL OR poin_dipakai > 0),
  CONSTRAINT fk_pos_pesanan_pembayaran_pesanan FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE CASCADE,
  CONSTRAINT fk_pos_pesanan_pembayaran_metode FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_pembayaran_kartu_poin FOREIGN KEY (id_pos_kartu_poin)
    REFERENCES pos_kartu_poin (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_ppb_pesanan
  ON pos_pesanan_pembayaran (id_pos_pesanan);
CREATE INDEX IF NOT EXISTS ix_ppb_kartu_poin
  ON pos_pesanan_pembayaran (id_pos_kartu_poin);

COMMENT ON TABLE pos_pesanan_pembayaran IS
  '[LINE] pembayaran per metode (F03) — multi/split payment; redeem poin ='
  ' baris metode POIN (BR17); UPDATE diblokir app setelah struk terbit.';

-- [TRANSAKSI varian anak] pos_pesanan_refund — pengajuan & pembukuan refund
-- (F06): bukti per CFG-POS-04, ambang CFG-POS-03, approval SoD (BR04/BR08).
-- Tanpa numbering sendiri — identitas menggantung struk asli (PP-07).
CREATE TABLE IF NOT EXISTS pos_pesanan_refund (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_pesanan       bigint NOT NULL,                  -- struk asli (mendukung refund lintas sesi)
  id_pos_sesi          bigint NOT NULL,                  -- sesi tempat refund dilakukan
  id_core_metode_bayar bigint NOT NULL,                  -- metode pengembalian dana
  id_core_users_penyusun bigint,                         -- kasir pengaju
  id_core_users_penyetuju bigint,                        -- Supervisor (SoD: ≠ penyusun — app)
  status               enum_status_pengajuan_pos NOT NULL DEFAULT 'MENUNGGU_PERSETUJUAN',
  nilai                numeric(18,4) NOT NULL,
  jenis_bukti          enum_jenis_bukti_refund NOT NULL, -- sesuai CFG-POS-04
  referensi_bukti      varchar(150),
  path_bukti           varchar(300),                     -- lampiran media library
  alasan               varchar(300) NOT NULL,
  waktu_persetujuan    timestamptz,
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pos_pesanan_refund_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_pesanan_refund_nilai CHECK (nilai > 0),
  CONSTRAINT fk_pos_pesanan_refund_pesanan FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_refund_sesi FOREIGN KEY (id_pos_sesi)
    REFERENCES pos_sesi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_refund_metode FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_refund_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pos_pesanan_refund_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_ppr_pesanan
  ON pos_pesanan_refund (id_pos_pesanan);
CREATE INDEX IF NOT EXISTS ix_ppr_sesi
  ON pos_pesanan_refund (id_pos_sesi);
CREATE INDEX IF NOT EXISTS ix_ppr_menunggu
  ON pos_pesanan_refund (id_pos_sesi)
  WHERE status = 'MENUNGGU_PERSETUJUAN' AND deleted_at IS NULL;

COMMENT ON TABLE pos_pesanan_refund IS
  '[TRANSAKSI varian anak] refund ber-approval (F06/PP-07) — DISETUJUI → satu'
  ' UoW: header status_refund/total_refund + pos_sesi_kas.total_refund + ledger'
  ' ADJUST poin + event log.';

-- [LOG/EVENT append-only] pos_event_log — jejak setiap transisi & keputusan
-- (STD-01/BR05): buka/tutup sesi, batal/void, selisih kas, kas in/out, tahanan
-- M09/M10, faktur M38, keputusan dapur M30, review offline.
CREATE TABLE IF NOT EXISTS pos_event_log (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_sesi          bigint,                           -- tepat satu subjek (CHECK XOR)
  id_pos_pesanan       bigint,
  id_core_users        bigint,                           -- NULL = aktor sistem + keterangan kontrak
  subjek               enum_subjek_pos NOT NULL,
  aksi                 varchar(100) NOT NULL,            -- kode aksi/error (SESI_AKTIF_LAIN, LOT_WAJIB, ...)
  dari_status          varchar(50),
  ke_status            varchar(50),
  alasan               varchar(300),
  payload              jsonb,                            -- keputusan kontrak M09/M10/M30/M38 — tak di-filter/di-join
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(), -- beku (append-only)
  deleted_at           timestamptz,                          -- selalu NULL
  CONSTRAINT uq_pos_event_log_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_event_log_subjek CHECK (
    (id_pos_sesi IS NOT NULL) <> (id_pos_pesanan IS NOT NULL)
  ),
  CONSTRAINT fk_pos_event_log_sesi FOREIGN KEY (id_pos_sesi)
    REFERENCES pos_sesi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_event_log_pesanan FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_event_log_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pel_sesi
  ON pos_event_log (id_pos_sesi, created_at);
CREATE INDEX IF NOT EXISTS ix_pel_pesanan
  ON pos_event_log (id_pos_pesanan, created_at);
CREATE INDEX IF NOT EXISTS ix_pel_subjek_aksi
  ON pos_event_log (subjek, aksi, created_at);

COMMENT ON TABLE pos_event_log IS
  '[LOG/EVENT append-only] jejak transisi & keputusan (STD-01/BR05) —'
  ' aktor/waktu/alasan per subjek sesi/pesanan/item; payload kontrak di jsonb.';

-- [LOG/EVENT append-only] pos_mutasi_poin — ledger poin (F19/BR16): EARN saat
-- DIBAYAR; REDEEM via metode POIN; EXPIRE oleh job; ADJUST ber-alasan saat
-- refund (PP-18). Sumber kebenaran saldo kartu (recompute = Σ mutasi).
CREATE TABLE IF NOT EXISTS pos_mutasi_poin (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pos_kartu_poin    bigint NOT NULL,
  id_pos_pesanan       bigint,                           -- NULL bila expire/adjust non-struk
  id_core_users        bigint,                           -- NULL = aktor sistem (job EXPIRE)
  jenis                enum_jenis_mutasi_poin_pos NOT NULL,
  arah                 enum_arah_mutasi_kas_pos NOT NULL, -- MASUK/KELUAR (semantik universal, dipinjam)
  poin                 int NOT NULL,
  kedaluwarsa_at       timestamptz,                      -- wajib EARN ber-jadwal (masa berlaku program)
  alasan               varchar(300),                     -- wajib ADJUST (BR05) — CHECK
  waktu_mutasi         timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(), -- beku (append-only)
  deleted_at           timestamptz,                          -- selalu NULL
  CONSTRAINT uq_pos_mutasi_poin_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pos_mutasi_poin_poin CHECK (poin > 0),
  CONSTRAINT ck_pos_mutasi_poin_alasan CHECK (jenis <> 'ADJUST' OR alasan IS NOT NULL),
  CONSTRAINT fk_pos_mutasi_poin_kartu FOREIGN KEY (id_pos_kartu_poin)
    REFERENCES pos_kartu_poin (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_mutasi_poin_pesanan FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_mutasi_poin_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pmp_kartu
  ON pos_mutasi_poin (id_pos_kartu_poin, waktu_mutasi);
CREATE INDEX IF NOT EXISTS ix_pmp_pesanan
  ON pos_mutasi_poin (id_pos_pesanan);
CREATE INDEX IF NOT EXISTS ix_pmp_kedaluwarsa
  ON pos_mutasi_poin (kedaluwarsa_at)
  WHERE jenis = 'EARN' AND kedaluwarsa_at IS NOT NULL;

COMMENT ON TABLE pos_mutasi_poin IS
  '[LOG/EVENT append-only] ledger poin (F19/BR16/PP-17) — saldo kartu wajib ='
  ' Σ mutasi; tanpa UPDATE/DELETE app; sweep EXPIRE via ix_pmp_kedaluwarsa.';

-- -----------------------------------------------------------------------------
-- G. Trigger updated_at — ke-18 tabel (satu jalur refresh, D-04; fungsi di 01-core)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core_metode_bayar',
    'pos_outlet','pos_outlet_metode_bayar','pos_outlet_produk',
    'pos_program_loyalitas','pos_promo','pos_promo_outlet','pos_promo_item',
    'pos_sesi','pos_sesi_kas','pos_sesi_mutasi_kas',
    'pos_pesanan','pos_pesanan_items','pos_pesanan_pembayaran',
    'pos_kartu_poin','pos_pesanan_refund','pos_event_log','pos_mutasi_poin'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- PATCH 23-pos.sql selesai.
