-- ============================================================================ 
-- PATCH DDL 41-shp.sql — Modul SHP (SHIPMENT — LAYANAN PENGIRIMAN & ONGKOS KIRIM)
-- ============================================================================
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-shp.md (keputusan pemilik 2026-11-07 inline §9:
--            Q-01 kode SHP, Q-03 tier Biteship Starter, Q-05 relasi fisik
--            sesuai rekomendasi)
--            + docs/arsitektur-database-shp.md (kartu klasifikasi).
-- Kartu    : docs/arsitektur-database-shp.md (gerbang arsitektur-database).
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at,
--            core_modules, core_sequences, core_module_configs, enum
--            core_module_key, enum_status_aktif) + master inv_gudang (02),
--            core_pemasok (25), sls_pelanggan (28).
-- Isi      : 7 tabel shp_* — 2 MASTER (konfigurasi vendor, lokasi asal) +
--            2 TRANSAKSI (kalkulasi SHK, order SHO) + 1 LINE (opsi tarif) +
--            2 LOG/EVENT append-only (log api, log webhook) + 11 enum
--            enum_*_shp + trigger updated_at.
-- Integrasi: FK keluar baca-saja — inv_gudang / core_pemasok / sls_pelanggan
--            (master RESTRICT). SHP tidak pernah menulis tabel modul lain —
--            keluaran via core_outbox_events (kontrak M55/M56/M57). Penomoran
--            via core_sequences — ditanam podman/seed-shp-core.sql SETELAH
--            patch commit (lihat §0/§5).
-- Idempoten: aman dijalankan berulang — ALTER TYPE ... ADD VALUE IF NOT
--            EXISTS (statement top-level, pola 36-ecom), enum DO-block
--            duplicate_object (fail-loud bila kosakata menyimpang), CREATE
--            TABLE IF NOT EXISTS, FK/check bernama eksplisit, CREATE INDEX
--            IF NOT EXISTS, trigger DO-block DROP+CREATE.
-- Catatan  : uang numeric(18,4); koordinat numeric(9,6); teks bucket varchar
--            50/100/150/200/300 tanpa text (entity_id_sumber varchar(255) =
--            pengecualian Tier B terkunci, pola PP-03 pgw); jsonb hanya
--            payload yang tidak difilter/di-join (kredensial blob terenkripsi
--            AES-256-GCM app-side — SHP-BR01 write-only/masking; payload
--            webhook beku; ringkasan API tanpa secret). LOG/EVENT append-only
--            (updated_at beku, deleted_at selalu NULL, tanpa version); LINE
--            tanpa entity_id/version; dedupe_key webhook UNIQUE GLOBAL
--            (idempoten tidak pernah dipakai ulang). Seed master preset =
--            podman/seed-shp-core.sql — di luar patch DDL ini.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/41-shp.sql   (jalankan 2× = idempoten)
-- ============================================================================

-- §0 REGISTRY KEY MODUL — pola 36-ecom (nilai enum BARU pada core_module_key)
-- ALTER TYPE dijalankan sebagai STATEMENT TOP-LEVEL pertama — bukan di dalam
-- DO block / transaksi eksplisit (aturan PG: nilai enum baru tidak boleh
-- dipakai pada transaksi yang sama saat ditambahkan — "unsafe use of new
-- value"). Patch ini TANPA INSERT apa pun yang memakai 'shipment'; baris
-- registry core_modules + core_sequences (SHK/SHO) + default CFG-SHP ditanam
-- via podman/seed-shp-core.sql SETELAH patch commit.
ALTER TYPE core_module_key ADD VALUE IF NOT EXISTS 'shipment';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key::text = 'shipment') THEN
    RAISE NOTICE 'PATCH 41-shp: registry core_modules key=''shipment'' belum ada — '
      'row registry + core_sequences (kalkulasi SHK-{yyyyMM}, order SHO-{yyyyMM}) '
      '+ default CFG-SHP-01..06 ditanam via podman/seed-shp-core.sql SETELAH patch '
      'commit. Nilai enum baru tidak boleh dipakai dalam transaksi yang sama saat '
      'ALTER TYPE ADD VALUE (aturan PG), sehingga patch ini sengaja tidak '
      'melakukan INSERT apa pun yang memakai ''shipment''.';
  END IF;
END $$;

-- ============================================================================
-- §1 ENUM — 11 tipe baru (fail-loud bila kosakata menyimpang dari mirror)
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE enum_environment_shp AS ENUM ('SANDBOX','PRODUKSI','SIMULASI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_environment_shp')
     IS DISTINCT FROM ARRAY['SANDBOX','PRODUKSI','SIMULASI']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_environment_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_konfigurasi_shp AS ENUM ('DRAFT','DIUJI','AKTIF','DINONAKTIFKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_konfigurasi_shp')
     IS DISTINCT FROM ARRAY['DRAFT','DIUJI','AKTIF','DINONAKTIFKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_status_konfigurasi_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_hasil_uji_shp AS ENUM ('LULUS','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_uji_shp')
     IS DISTINCT FROM ARRAY['LULUS','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_hasil_uji_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_sumber_kalkulasi_shp AS ENUM ('PUR_INBOUND','SLS_OUTBOUND','ECOM_OUTBOUND');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_kalkulasi_shp')
     IS DISTINCT FROM ARRAY['PUR_INBOUND','SLS_OUTBOUND','ECOM_OUTBOUND']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_sumber_kalkulasi_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_kalkulasi_shp AS ENUM ('DIPROSES','SELESAI','GAGAL','KEDALUWARSA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kalkulasi_shp')
     IS DISTINCT FROM ARRAY['DIPROSES','SELESAI','GAGAL','KEDALUWARSA']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_status_kalkulasi_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_layanan_shp AS ENUM ('STANDARD','EKSPRES','INSTANT','KARGO','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_layanan_shp')
     IS DISTINCT FROM ARRAY['STANDARD','EKSPRES','INSTANT','KARGO','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_jenis_layanan_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_metode_ambil_shp AS ENUM ('PICKUP','DROP_OFF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_metode_ambil_shp')
     IS DISTINCT FROM ARRAY['PICKUP','DROP_OFF']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_metode_ambil_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_order_shp AS ENUM
    ('DIBENTUK','DIJADWALKAN','DIKURIR','DALAM_PERJALANAN','DITAHAN',
     'TERKIRIM','DIKEMBALIKAN','DIBATALKAN','GAGAL_KURIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_order_shp')
     IS DISTINCT FROM ARRAY['DIBENTUK','DIJADWALKAN','DIKURIR','DALAM_PERJALANAN','DITAHAN',
        'TERKIRIM','DIKEMBALIKAN','DIBATALKAN','GAGAL_KURIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_status_order_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_event_webhook_shp AS ENUM ('ORDER_STATUS','ORDER_PRICE','ORDER_WAYBILL_ID');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_event_webhook_shp')
     IS DISTINCT FROM ARRAY['ORDER_STATUS','ORDER_PRICE','ORDER_WAYBILL_ID']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_event_webhook_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_hasil_verifikasi_shp AS ENUM ('VALID','DUPLIKAT','TAK_DIKENAL','INVALID');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_verifikasi_shp')
     IS DISTINCT FROM ARRAY['VALID','DUPLIKAT','TAK_DIKENAL','INVALID']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_hasil_verifikasi_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_hasil_panggilan_shp AS ENUM ('BERHASIL','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_panggilan_shp')
     IS DISTINCT FROM ARRAY['BERHASIL','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 41-shp: enum_hasil_panggilan_shp kosakata menyimpang dari mirror';
  END IF;
END $$;

-- ============================================================================
-- §2 TABEL MASTER — urutan dependensi FK
-- ============================================================================

-- [MASTER] Konfigurasi vendor kirim per (vendor, environment, versi kredensial).
-- Kredensial = blob terenkripsi AES-256-GCM app-side (api_key Biteship
-- write-only/masking — SHP-BR01); satu AKTIF per pasangan (SHP-BR02).
CREATE TABLE IF NOT EXISTS shp_konfigurasi_vendor (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor          varchar(50) NOT NULL,             -- BITESHIP / SIMULATOR / … (nilai konsep, bukan FK)
  environment          enum_environment_shp NOT NULL,    -- konfigurasi hanya SANDBOX|PRODUKSI (ck di bawah — SHP-BR03)
  base_url             varchar(300) NOT NULL,            -- https://api.biteship.com / internal://simulator
  kredensial           jsonb NOT NULL DEFAULT '{}'::jsonb, -- blob terenkripsi; tidak pernah difilter/join (SHP-BR01)
  kredensial_versi     int NOT NULL DEFAULT 1,           -- rotasi: ubah isi → status DRAFT + versi +1
  webhook_url          varchar(300),                     -- informasi endpoint callback yang didaftarkan di dashboard vendor
  status               enum_status_konfigurasi_shp NOT NULL DEFAULT 'DRAFT',
  uji_terakhir_at      timestamptz,                      -- F03: hasil uji koneksi terakhir (probe referensi dummy)
  uji_terakhir_hasil   enum_hasil_uji_shp,               -- LULUS/GAGAL; kode detail (OK_AUTH/AUTH_SALAH/…) di pesan
  uji_terakhir_pesan   varchar(300),
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_shp_konfigurasi_vendor_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_shp_konfigurasi_vendor_environment CHECK
    (environment IN ('SANDBOX','PRODUKSI'))              -- SHP-BR03: SIMULASI bukan environment konfigurasi
);

-- [MASTER] Lokasi asal kirim tersimpan (F10 — Should); mengikat master gudang
-- INV / pemasok CORE baca-saja RESTRICT; referensi outlet POS menyusul bersama
-- konsumen POS/FNB (Could — A-03 analisa).
CREATE TABLE IF NOT EXISTS shp_lokasi_asal (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                 varchar(100) NOT NULL,            -- "Gudang Pusat", "Gudang Surabaya", …
  jenis_sumber         varchar(50) NOT NULL,             -- GUDANG / PASOK / ALAMAT (nilai konsep)
  id_inv_gudang        bigint REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  id_core_pemasok      bigint REFERENCES core_pemasok (id) ON DELETE RESTRICT,
  alamat               varchar(300) NOT NULL,            -- alamat satu baris
  kunci_area_vendor    varchar(100),                     -- area id Biteship level kecamatan+kode pos (maps F05)
  kode_pos             varchar(50),
  latitude             numeric(9,6),                     -- kurir instant wajib koordinat
  longitude            numeric(9,6),
  metode_ambil_default enum_metode_ambil_shp NOT NULL DEFAULT 'PICKUP',
  status               enum_status_aktif NOT NULL DEFAULT 'AKTIF', -- pinjam CORE (01-core)
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_shp_lokasi_asal_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_shp_lokasi_asal_sumber CHECK
    (jenis_sumber IN ('GUDANG','PASOK','ALAMAT'))
);

-- ============================================================================
-- §3 TABEL TRANSAKSI + LINE + LOG/EVENT — urutan dependensi FK
-- ============================================================================

-- [TRANSAKSI] Kalkulasi ongkir dari modul konsumen (kontrak M55) bernomor
-- SHK-{yyyyMM}####. Idempoten reuse per (sumber, ref_permintaan, kunci_input)
-- — SHP-BR07. Environment + versi konfigurasi dibekukan saat dibentuk (SHP-BR02).
CREATE TABLE IF NOT EXISTS shp_kalkulasi (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                     varchar(150) NOT NULL,   -- SHK-{yyyyMM}#### via core_sequences (unique global, STD-08)
  sumber                    enum_sumber_kalkulasi_shp NOT NULL, -- PUR_INBOUND / SLS_OUTBOUND / ECOM_OUTBOUND (M55)
  ref_permintaan            varchar(150) NOT NULL,   -- referensi permintaan modul konsumen
  entity_id_sumber          varchar(255) NOT NULL,   -- Tier B: kunci bisnis dokumen sumber lintas modul (pola PP-03 pgw)
  kunci_input               varchar(100) NOT NULL,   -- hash kanonik input kalkulasi (idempotensi reuse — SHP-BR07)
  -- snapshot asal (beku saat dibentuk; alamat bebas sah)
  asal_tipe                 varchar(50) NOT NULL,    -- GUDANG / PASOK / ALAMAT / LOKASI
  asal_nama                 varchar(100) NOT NULL,
  asal_telepon              varchar(50) NOT NULL,
  asal_alamat               varchar(300) NOT NULL,
  asal_area_id              varchar(100),            -- kunci area vendor (maps F05)
  asal_kode_pos             varchar(50),
  asal_latitude             numeric(9,6),
  asal_longitude            numeric(9,6),
  -- snapshot tujuan
  tujuan_tipe               varchar(50) NOT NULL,    -- PELANGGAN / GUDANG / ALAMAT
  tujuan_nama               varchar(100) NOT NULL,
  tujuan_telepon            varchar(50) NOT NULL,
  tujuan_alamat             varchar(300) NOT NULL,
  tujuan_area_id            varchar(100),
  tujuan_kode_pos           varchar(50),
  tujuan_latitude           numeric(9,6),
  tujuan_longitude          numeric(9,6),
  -- master asal/tujuan baca-saja (nullable — alamat bebas sah)
  id_asal_inv_gudang        bigint REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  id_asal_core_pemasok      bigint REFERENCES core_pemasok (id) ON DELETE RESTRICT,
  id_tujuan_inv_gudang      bigint REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  id_tujuan_sls_pelanggan   bigint REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  rincian_barang            jsonb NOT NULL DEFAULT '[]'::jsonb, -- snapshot beku items M55 {nama,qty,nilai,berat_gram,dimensi?,kategori?}
  kurir_diminta             varchar(100),            -- daftar kode kurir dipisah koma; NULL = default CFG-SHP-03
  nilai_asuransi            numeric(18,4),           -- nilai barang yang diasuransikan (NULL = tanpa asuransi)
  cod_nilai                 numeric(18,4),           -- COD maks IDR 15 jt (NULL = tanpa COD)
  id_shp_konfigurasi_vendor bigint NOT NULL,
  environment               enum_environment_shp NOT NULL, -- beku saat dibentuk (SHP-BR02) — SIMULASI/SANDBOX/PRODUKSI
  konfigurasi_versi         int NOT NULL,
  status                    enum_status_kalkulasi_shp NOT NULL DEFAULT 'DIPROSES',
  masa_berlaku_hingga       timestamptz,             -- reuse sah sampai sini (CFG-SHP-02 — SHP-BR07)
  kode_hasil                varchar(50),             -- berkode: SHP-0xx / kode hasil vendor ternormalisasi
  pesan_gagal               varchar(300),
  version                   int NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_shp_kalkulasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_shp_kalkulasi_nomor UNIQUE (nomor),
  CONSTRAINT fk_shp_kalkulasi_konfigurasi FOREIGN KEY (id_shp_konfigurasi_vendor)
    REFERENCES shp_konfigurasi_vendor (id) ON DELETE RESTRICT,
  CONSTRAINT ck_shp_kalkulasi_sumber_asal CHECK (asal_tipe IN ('GUDANG','PASOK','ALAMAT','LOKASI')),
  CONSTRAINT ck_shp_kalkulasi_sumber_tujuan CHECK (tujuan_tipe IN ('PELANGGAN','GUDANG','ALAMAT'))
);

-- [LINE] Opsi tarif ternormalisasi hasil kalkulasi (SHP-BR08) — snapshot beku;
-- LINE murni: tanpa entity_id/version, mati bersama header (CASCADE).
CREATE TABLE IF NOT EXISTS shp_kalkulasi_opsi (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_shp_kalkulasi     bigint NOT NULL,
  kode_kurir           varchar(50) NOT NULL,            -- jne / sicepat / jnt / … (kode resmi vendor)
  nama_kurir           varchar(100) NOT NULL,
  kode_layanan         varchar(50) NOT NULL,            -- reg / best / ez / …
  nama_layanan         varchar(100) NOT NULL,
  deskripsi            varchar(300),
  jenis_layanan        enum_jenis_layanan_shp NOT NULL DEFAULT 'LAINNYA',
  mata_uang            varchar(50) NOT NULL DEFAULT 'IDR',
  biaya_kirim          numeric(18,4) NOT NULL,
  biaya_diskon         numeric(18,4) NOT NULL DEFAULT 0,
  biaya_surcharge      numeric(18,4) NOT NULL DEFAULT 0,
  biaya_asuransi       numeric(18,4) NOT NULL DEFAULT 0,
  biaya_cod            numeric(18,4) NOT NULL DEFAULT 0,
  harga_final          numeric(18,4) NOT NULL,          -- harga final resmi vendor (response `price`) — data sumber, bukan turunan
  durasi_nilai         varchar(50),                     -- rentang string resmi vendor (mis. "2 - 3")
  durasi_satuan        varchar(50),                     -- days / hours
  metode_ambil         enum_metode_ambil_shp,
  tersedia_asuransi    boolean NOT NULL DEFAULT false,
  tersedia_cod         boolean NOT NULL DEFAULT false,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT fk_shp_kalkulasi_opsi_kalkulasi FOREIGN KEY (id_shp_kalkulasi)
    REFERENCES shp_kalkulasi (id) ON DELETE CASCADE,
  CONSTRAINT uq_shp_kalkulasi_opsi_kurir UNIQUE (id_shp_kalkulasi, kode_kurir, kode_layanan),
  CONSTRAINT ck_shp_kalkulasi_opsi_biaya CHECK
    (biaya_kirim >= 0 AND biaya_diskon >= 0 AND biaya_surcharge >= 0
     AND biaya_asuransi >= 0 AND biaya_cod >= 0 AND harga_final >= 0)
);

-- [TRANSAKSI] Booking kurir pada vendor eksternal (Should) bernomor
-- SHO-{yyyyMM}####. Opsi terpilih tercatat di sini (menghindari FK melingkar
-- header kalkulasi↔LINE). Status peta monoton vendor → SHP (SHP-BR12).
CREATE TABLE IF NOT EXISTS shp_order (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                     varchar(150) NOT NULL,   -- SHO-{yyyyMM}#### via core_sequences (unique global, STD-08)
  sumber                    enum_sumber_kalkulasi_shp NOT NULL, -- bawaan dari kalkulasi
  ref_permintaan            varchar(150) NOT NULL,
  entity_id_sumber          varchar(255) NOT NULL,   -- Tier B (pola PP-03 pgw)
  -- snapshot kontak asal/tujuan (beku — order dibentuk dari opsi sah, SHP-BR10)
  asal_nama                 varchar(100) NOT NULL,
  asal_telepon              varchar(50) NOT NULL,
  asal_alamat               varchar(300) NOT NULL,
  asal_area_id              varchar(100),
  asal_kode_pos             varchar(50),
  asal_latitude             numeric(9,6),
  asal_longitude            numeric(9,6),
  tujuan_nama               varchar(100) NOT NULL,
  tujuan_telepon            varchar(50) NOT NULL,
  tujuan_alamat             varchar(300) NOT NULL,
  tujuan_area_id            varchar(100),
  tujuan_kode_pos           varchar(50),
  tujuan_latitude           numeric(9,6),
  tujuan_longitude          numeric(9,6),
  catatan_order             varchar(300),
  referensi_persetujuan     varchar(150),            -- approval modul asal di atas ambang CFG-SHP-04 (SHP-BR10)
  referensi_vendor          varchar(150),            -- id order di vendor (Biteship)
  waybill                   varchar(150),
  tracking_id               varchar(150),
  tracking_link             varchar(300),
  biaya_estimasi            numeric(18,4) NOT NULL,  -- dari harga_final opsi terpilih
  biaya_aktual              numeric(18,4),           -- harga final webhook order.price (SHP-BR14)
  mata_uang                 varchar(50) NOT NULL DEFAULT 'IDR',
  id_shp_kalkulasi          bigint NOT NULL,
  id_shp_kalkulasi_opsi     bigint NOT NULL,
  id_shp_konfigurasi_vendor bigint NOT NULL,
  id_shp_lokasi_asal        bigint,                  -- lokasi asal tersimpan bila dipakai
  environment               enum_environment_shp NOT NULL, -- beku saat dibentuk (SHP-BR02)
  status                    enum_status_order_shp NOT NULL DEFAULT 'DIBENTUK',
  alasan_batal              varchar(300),            -- alasan resmi vendor (SHP-BR13)
  waktu_selesai             timestamptz,             -- saat TERKIRIM
  waktu_batal               timestamptz,
  waktu_terakhir_status     timestamptz,             -- basis sweep polling CFG-SHP-05
  version                   int NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_shp_order_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_shp_order_nomor UNIQUE (nomor),
  CONSTRAINT fk_shp_order_kalkulasi FOREIGN KEY (id_shp_kalkulasi)
    REFERENCES shp_kalkulasi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_shp_order_opsi FOREIGN KEY (id_shp_kalkulasi_opsi)
    REFERENCES shp_kalkulasi_opsi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_shp_order_konfigurasi FOREIGN KEY (id_shp_konfigurasi_vendor)
    REFERENCES shp_konfigurasi_vendor (id) ON DELETE RESTRICT,
  CONSTRAINT fk_shp_order_lokasi_asal FOREIGN KEY (id_shp_lokasi_asal)
    REFERENCES shp_lokasi_asal (id) ON DELETE RESTRICT,
  CONSTRAINT ck_shp_order_biaya CHECK
    (biaya_estimasi >= 0 AND (biaya_aktual IS NULL OR biaya_aktual >= 0))
);

-- [LOG/EVENT] Jejak append-only setiap panggilan API vendor — tanpa secret
-- (SHP-BR04); log selamat dari induk (FK SET NULL).
CREATE TABLE IF NOT EXISTS shp_log_api (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  id_shp_kalkulasi          bigint,                  -- SET NULL: log selamat
  id_shp_order              bigint,
  id_shp_konfigurasi_vendor bigint,
  operasi                   varchar(50) NOT NULL,    -- UJI_KONEKSI / AREA / RATES / ORDER / DETAIL_ORDER / BATAL / TRACKING / SIMULASI
  environment               enum_environment_shp NOT NULL, -- audit terpisah sandbox/produksi/simulasi
  metode                    varchar(50),
  url                       varchar(300),
  status_http               int,
  hasil                     enum_hasil_panggilan_shp NOT NULL, -- BERHASIL / GAGAL
  kode_hasil                varchar(50),             -- OK_AUTH / AUTH_SALAH / SHP-0xx / kode vendor ternormalisasi
  latensi_ms                int,
  permintaan_ringkas        jsonb,                   -- payload tersaring tanpa secret (SHP-BR04)
  respons_ringkas           jsonb,                   -- potongan respons tanpa secret
  pesan                     varchar(300),
  waktu                     timestamptz NOT NULL DEFAULT now(),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(), -- beku (append-only)
  deleted_at                timestamptz,             -- selalu NULL (append-only)
  CONSTRAINT uq_shp_log_api_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_shp_log_api_kalkulasi FOREIGN KEY (id_shp_kalkulasi)
    REFERENCES shp_kalkulasi (id) ON DELETE SET NULL,
  CONSTRAINT fk_shp_log_api_order FOREIGN KEY (id_shp_order)
    REFERENCES shp_order (id) ON DELETE SET NULL,
  CONSTRAINT fk_shp_log_api_konfigurasi FOREIGN KEY (id_shp_konfigurasi_vendor)
    REFERENCES shp_konfigurasi_vendor (id) ON DELETE SET NULL
);

-- [LOG/EVENT] Jejak append-only webhook vendor — dedupe_key UNIQUE GLOBAL
-- (idempoten tidak pernah dipakai ulang — SHP-BR11); payload beku apa adanya.
CREATE TABLE IF NOT EXISTS shp_log_webhook (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor               varchar(50) NOT NULL,
  event                     enum_event_webhook_shp NOT NULL, -- ORDER_STATUS / ORDER_PRICE / ORDER_WAYBILL_ID
  referensi_order_vendor    varchar(150),
  id_shp_order              bigint,                  -- SET NULL: log selamat
  environment               enum_environment_shp NOT NULL,
  dedupe_key                varchar(255) NOT NULL,   -- UNIQUE GLOBAL — idempoten (SHP-BR11)
  hasil                     enum_hasil_verifikasi_shp NOT NULL, -- VALID / DUPLIKAT / TAK_DIKENAL / INVALID
  payload_raw               jsonb NOT NULL,          -- payload vendor beku apa adanya
  header_ringkas            jsonb,                   -- header tersaring tanpa secret
  waktu                     timestamptz NOT NULL DEFAULT now(),
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(), -- beku (append-only)
  deleted_at                timestamptz,             -- selalu NULL (append-only)
  CONSTRAINT uq_shp_log_webhook_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_shp_log_webhook_dedupe UNIQUE (dedupe_key),
  CONSTRAINT fk_shp_log_webhook_order FOREIGN KEY (id_shp_order)
    REFERENCES shp_order (id) ON DELETE SET NULL
);

-- Partial unique/index "hidup" (K-10) — dibuat terpisah agar IF NOT EXISTS.
-- Satu konfigurasi AKTIF per (vendor, environment) — SHP-BR02.
CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_konfigurasi_vendor_aktif_hidup
  ON shp_konfigurasi_vendor (kode_vendor, environment)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_konfigurasi_vendor_versi_hidup
  ON shp_konfigurasi_vendor (kode_vendor, environment, kredensial_versi)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_konfigurasi_vendor_pasangan
  ON shp_konfigurasi_vendor (kode_vendor, environment)
  WHERE deleted_at IS NULL;

-- Nama lokasi asal unik di antara baris hidup.
CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_lokasi_asal_nama_hidup
  ON shp_lokasi_asal (nama)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_lokasi_asal_gudang
  ON shp_lokasi_asal (id_inv_gudang)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_lokasi_asal_pemasok
  ON shp_lokasi_asal (id_core_pemasok)
  WHERE deleted_at IS NULL;

-- Idempotensi reuse kalkulasi — SHP-BR07 (satu hasil per permintaan+kunci input).
CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_kalkulasi_reuse_hidup
  ON shp_kalkulasi (sumber, ref_permintaan, kunci_input)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_sumber_ref
  ON shp_kalkulasi (sumber, ref_permintaan)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_sumber_status
  ON shp_kalkulasi (sumber, status)
  WHERE deleted_at IS NULL;

-- Sweep kedaluwarsa hasil kalkulasi (CFG-SHP-02).
CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_berlaku_hidup
  ON shp_kalkulasi (masa_berlaku_hingga)
  WHERE status = 'SELESAI' AND deleted_at IS NULL;

-- FK nullable partial kalkulasi (asal/tujuan master baca-saja).
CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_asal_gudang
  ON shp_kalkulasi (id_asal_inv_gudang) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_asal_pemasok
  ON shp_kalkulasi (id_asal_core_pemasok) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_tujuan_gudang
  ON shp_kalkulasi (id_tujuan_inv_gudang) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_shp_kalkulasi_tujuan_pelanggan
  ON shp_kalkulasi (id_tujuan_sls_pelanggan) WHERE deleted_at IS NULL;

-- Idempotensi bentuk order (STD-07): satu order aktif per opsi; retry setelah
-- terminal (DIBATALKAN/GAGAL_KURIR) dibolehkan.
CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_order_opsi_aktif_hidup
  ON shp_order (id_shp_kalkulasi_opsi)
  WHERE status NOT IN ('DIBATALKAN','GAGAL_KURIR') AND deleted_at IS NULL;

-- Idempotensi referensi vendor.
CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_order_referensi_vendor_hidup
  ON shp_order (id_shp_konfigurasi_vendor, referensi_vendor)
  WHERE referensi_vendor IS NOT NULL AND deleted_at IS NULL;

-- Sweep polling tracking (CFG-SHP-05) — hanya order belum terminal.
CREATE INDEX IF NOT EXISTS ix_shp_order_sweep
  ON shp_order (status, waktu_terakhir_status)
  WHERE status IN ('DIBENTUK','DIJADWALKAN','DIKURIR','DALAM_PERJALANAN','DITAHAN')
    AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_order_sumber_ref
  ON shp_order (sumber, ref_permintaan)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_order_lokasi_asal
  ON shp_order (id_shp_lokasi_asal)
  WHERE deleted_at IS NULL;

-- Index panas log API.
CREATE INDEX IF NOT EXISTS ix_shp_log_api_konfigurasi_waktu
  ON shp_log_api (id_shp_konfigurasi_vendor, waktu)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_log_api_operasi_waktu
  ON shp_log_api (operasi, waktu)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_log_api_kalkulasi
  ON shp_log_api (id_shp_kalkulasi) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_log_api_order
  ON shp_log_api (id_shp_order) WHERE deleted_at IS NULL;

-- Index panas log webhook.
CREATE INDEX IF NOT EXISTS ix_shp_log_webhook_order_waktu
  ON shp_log_webhook (id_shp_order, waktu)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_shp_log_webhook_vendor_event
  ON shp_log_webhook (kode_vendor, event, waktu)
  WHERE deleted_at IS NULL;

-- ============================================================================
-- §4 TRIGGER updated_at — fungsi set_updated_at milik baseline 01-core
-- (tidak pernah dibuat ulang di sini); satu trigger per tabel.
-- ============================================================================

DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'shp_konfigurasi_vendor', 'shp_lokasi_asal', 'shp_kalkulasi',
    'shp_kalkulasi_opsi', 'shp_order', 'shp_log_api', 'shp_log_webhook'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- ============================================================================
-- §5 SEED — DITANGANI DI LUAR PATCH (pola 36-ecom, nilai enum baru)
--
-- Podman/seed-shp-core.sql SETELAH patch commit (lihat §0):
--   1) registry core_modules key='shipment';
--   2) core_sequences module shipment — ('kalkulasi','SHK-{yyyyMM}',0,4),
--      ('order','SHO-{yyyyMM}',0,4) ON CONFLICT DO NOTHING (counter tidak
--      pernah diturunkan);
--   3) konfigurasi preset SIMULATOR (SANDBOX, internal://simulator, kredensial
--      {}, AKTIF) — guard WHERE NOT EXISTS by kunci hidup;
--   4) default CFG-SHP-01..06 di core_module_configs (ON CONFLICT DO NOTHING).
-- ============================================================================

-- ============================================================================
-- §6 VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi patch)
--
--   -- Dry-run: cat ddl/41-shp.sql | podman exec -i nexierp-postgres psql -U nexierp -d nexierp -v ON_ERROR_STOP=1
--   -- (ALTER TYPE ADD VALUE IF NOT EXISTS aman dijalankan berulang; dry-run
--   --  transaksional BEGIN→ROLLBACK juga aman karena 'shipment' tidak dirujuk
--   --  statement mana pun di patch ini.)
--   -- Uji idempoten: jalankan patch 2× — apply kedua harus sukses tanpa error.
--
--   SELECT count(*) FROM pg_tables  WHERE schemaname='public' AND tablename LIKE 'shp%';   -- harapan: 7
--   SELECT count(*) FROM pg_type    WHERE typtype='e' AND typname LIKE '%_shp';            -- harapan: 11
--   SELECT tgname FROM pg_trigger WHERE tgname LIKE 'trg_shp%updated_at' AND NOT tgisinternal; -- harapan: 7
--   SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid
--     WHERE t.typname='core_module_key' AND e.enumlabel='shipment';                        -- harapan: 1 baris
--   -- Setelah seed: SELECT doc_name, prefix FROM core_sequences cs
--   --   JOIN core_modules m ON m.id=cs.id_core_modules WHERE m.key::text='shipment';      -- harapan: SHK + SHO
-- ============================================================================
-- ddl/41-shp.sql selesai.
