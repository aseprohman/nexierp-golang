-- +goose Up
-- Porting 1:1 dari ddl/36-ecom.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 36-ecom.sql — Modul ECOM (E-COMMERCE / TOKO ONLINE)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-ecom-v2.md (blueprint v2 ter-audit — kartu entitas
--            §4.1, peta status §4.2, fitur F01–F11, BR01–BR11, IN-01…IN-06,
--            CFG-ECOM-01…11) + docs/audit-analisa-ecom-v2.md (P2-1/P2-2/P3 diterapkan)
--            + docs/peta-modul.md (§4 kepemilikan; §5 M14/M15/M22/M23/M24/M34/M35/M50–M53).
-- Kartu    : docs/arsitektur-database-ecom.md (7 tabel §2 + keputusan §1–§5;
--            gerbang arsitektur-database)
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, core_files, fungsi set_updated_at,
--            enum core_module_key) + INV 02 (inv_produk) + SLS 28 (sls_pelanggan,
--            sls_pesanan_penjualan) — semua tabel live.
-- Isi      : 7 tabel ecom_* — 2 MASTER (katalog_online, kupon) + 3 TRANSAKSI
--            (keranjang [session-like, hold kedaluwarsa], pesanan_web, review)
--            + 2 LINE (keranjang_item, pesanan_web_item) + 9 enum enum_*_ecom
--            + trigger set_updated_at 7 tabel.
-- Integrasi: FK keluar baca-saja HANYA ke tabel live — id_inv_produk (RESTRICT
--            NOT NULL), id_sls_pelanggan (RESTRICT nullable — tamu), 
--            id_sls_pesanan_penjualan (so_ref, SET NULL nullable — SO dibuat
--            BELAKANGAN oleh M14), id_core_users_* (SET NULL — aktor
--            verifikasi/batal/moderasi), id_core_files (RESTRICT nullable —
--            gambar utama katalog). DILARANG FK ke rsv_* (M34/M35) dan pgw_*
--            (M50–M53) — tabel belum ada; gateway_ref varchar menampung
--            payment_ref M15/M50. Cache stok M22/M23 = kolom qty_tersedia_cache.
-- Kasus    : KASUS KHUSUS REGISTRY — key 'ecom' TIDAK ADA di enum core_module_key
-- KHUSUS     maupun baris core_modules. Patch diawali ALTER TYPE ADD VALUE IF NOT
--            EXISTS 'ecom'; aturan PG: nilai enum baru TIDAK BOLEH dipakai dalam
--            transaksi yang sama saat ditambahkan ("unsafe use of new value") →
--            TIDAK ADA INSERT yang memakai 'ecom' di patch ini (tanpa INSERT
--            core_modules, tanpa INSERT/JOIN core_sequences m.key='ecom'). Guard
--            berupa DO RAISE NOTICE (bukan EXCEPTION) yang mengarahkan penanaman
--            registry + sequences via podman/seed-ecom-core.sql (fase berikutnya).
--            Rencana penomoran (kartu §4.2, TIDAK dieksekusi di sini):
--            web_order WO-{yyyy}, kupon KPN-{yyyy} (opsional — kode manual sah).
-- Idempoten: aman dijalankan berulang & dry-run BEGIN..ROLLBACK — enum DO-block
--            duplicate_object (fail-loud bila kosakata menyimpang), ALTER TYPE
--            ADD VALUE IF NOT EXISTS (no-op run kedua), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit, CREATE INDEX IF NOT EXISTS, trigger
--            DO-block DROP+CREATE, tanpa INSERT data. Perbandingan registry memakai
--            key::text (cast enum→text tidak melalui fungsi input enum — aman).
-- Catatan  : LINE tanpa entity_id/version (pola hr/sls baris); uang numeric(18,4),
--            persen kupon numeric(18,6), qty integer, waktu kejadian timestamptz,
--            periode kupon date, varchar bucket 50/100/150/200/300 (tanpa text).
--            Seed data bisnis tidak ada — katalog/kupon dibuat Pengelola lewat UI.
-- =============================================================================

-- =============================================================================
-- §0 — KASUS KHUSUS REGISTRY 'ecom' (WAJIB statement pertama; aturan PG:
--      nilai enum baru tidak boleh dipakai dalam transaksi yang sama → hanya
--      ALTER TYPE + NOTICE, TANPA INSERT yang memakai 'ecom')
-- =============================================================================

ALTER TYPE core_module_key ADD VALUE IF NOT EXISTS 'ecom';

-- Fail-soft (NOTICE, bukan EXCEPTION): bila row registry belum ada, penanaman
-- registry + core_sequences ditunda ke podman/seed-ecom-core.sql (fase berikutnya)
-- SETELAH patch ini commit — nilai enum baru memang tidak boleh dipakai di sini.
-- +goose StatementBegin
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key::text = 'ecom') THEN
    RAISE NOTICE 'PATCH 36-ecom: registry core_modules key=''ecom'' belum ada — '
      'row registry + core_sequences (web_order WO-{yyyy}, kupon KPN-{yyyy}) ditanam '
      'via podman/seed-ecom-core.sql (fase berikutnya). Nilai enum baru tidak boleh '
      'dipakai dalam transaksi yang sama saat ALTER TYPE ADD VALUE (aturan PG), '
      'sehingga patch ini sengaja tidak melakukan INSERT apa pun yang memakai ''ecom''.';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §1 — ENUM (kosakata persis analisa §4.1/§4.2 + turunan teknis eksplisit;
--      fail-loud bila sudah ada dengan kosakata menyimpang)
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_sumber_harga_ecom AS ENUM ('MANUAL','PRICELIST');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_harga_ecom')
     IS DISTINCT FROM ARRAY['MANUAL','PRICELIST']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_sumber_harga_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_katalog_ecom AS ENUM ('DRAFT','PUBLIK','TERSEMBUNYI','DIHENTIKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_katalog_ecom')
     IS DISTINCT FROM ARRAY['DRAFT','PUBLIK','TERSEMBUNYI','DIHENTIKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_katalog_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_kupon_ecom AS ENUM ('PERSEN','NOMINAL','GRATIS_ONGKIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_kupon_ecom')
     IS DISTINCT FROM ARRAY['PERSEN','NOMINAL','GRATIS_ONGKIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_jenis_kupon_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_kupon_ecom AS ENUM
    ('DRAFT','AKTIF','NONAKTIF','HABIS_KUOTA','KADALUARSA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kupon_ecom')
     IS DISTINCT FROM ARRAY['DRAFT','AKTIF','NONAKTIF','HABIS_KUOTA','KADALUARSA']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_kupon_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_keranjang_ecom AS ENUM ('AKTIF','DIPESAN','DIBATALKAN','KADALUARSA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_keranjang_ecom')
     IS DISTINCT FROM ARRAY['AKTIF','DIPESAN','DIBATALKAN','KADALUARSA']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_keranjang_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- Peta §4.2 analisa (hasil P2-1 audit): batal hanya sebelum diproses; refund dari
-- DIBAYAR/DIPROSES; DIKIRIM → REFUND hanya setelah alur retur (INV/ACC) selesai
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pesanan_web_ecom AS ENUM
    ('MENUNGGU_PEMBAYARAN','DIBAYAR','DIPROSES','DIKIRIM','SELESAI','DIBATALKAN','REFUND');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pesanan_web_ecom')
     IS DISTINCT FROM ARRAY['MENUNGGU_PEMBAYARAN','DIBAYAR','DIPROSES','DIKIRIM','SELESAI','DIBATALKAN','REFUND']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_pesanan_web_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- §4.2 analisa: status_bayar sisi entitas BELUM_BAYAR -> TERBAYAR (M15) -> REFUNDED
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_bayar_ecom AS ENUM ('BELUM_BAYAR','TERBAYAR','REFUNDED');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_bayar_ecom')
     IS DISTINCT FROM ARRAY['BELUM_BAYAR','TERBAYAR','REFUNDED']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_bayar_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- F07: konversi M14 — MENUNGGU (belum dipicu) / ANTREAN_REVIEW (M14 gagal —
-- antrian review manual CS/Manajer, CFG-SLS-12) / TERBENTUK (so_ref terisi)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_konversi_ecom AS ENUM ('MENUNGGU','ANTREAN_REVIEW','TERBENTUK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_konversi_ecom')
     IS DISTINCT FROM ARRAY['MENUNGGU','ANTREAN_REVIEW','TERBENTUK']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_konversi_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- F10: moderasi review — tampil setelah moderasi (tayang/sembunyikan + alasan)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_review_ecom AS ENUM ('MENUNGGU_MODERASI','TAYANG','TERSEMBUNYI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_review_ecom')
     IS DISTINCT FROM ARRAY['MENUNGGU_MODERASI','TAYANG','TERSEMBUNYI']::text[] THEN
    RAISE EXCEPTION 'PATCH 36-ecom: enum_status_review_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 — TABEL (urutan dependensi FK dalam modul; FK keluar ke tabel live)
-- =============================================================================

-- 2.1 ecom_katalog_online — [MASTER] — tampilan jualan satu produk INV di web
--     (isi, harga web CFG-ECOM-06, tampilan stok CFG-ECOM-04, cache M22/M23)
CREATE TABLE IF NOT EXISTS ecom_katalog_online (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk          bigint NOT NULL,           -- live INV (RESTRICT — baca-saja, ECOM-BR06)
  slug                   varchar(200) NOT NULL,     -- unique partial HIDUP (URL publik)
  judul                  varchar(200) NOT NULL,
  deskripsi              varchar(300),
  sumber_harga           enum_sumber_harga_ecom NOT NULL DEFAULT 'MANUAL',  -- CFG-ECOM-06
  harga_web              numeric(18,4),             -- NULL sah bila sumber PRICELIST (render via M36/IN-06)
  media                  jsonb,                     -- array media tampilan (jsonb — kartu §1.5; gambar utama = id_core_files)
  id_core_files          bigint,                    -- gambar utama (live CORE, RESTRICT nullable)
  varian                 jsonb,                     -- [{ref_varian,label}] display web (kartu §1.5)
  batas_tampil_stok      integer,                   -- CFG-ECOM-04 (NULL = ikut default kebijakan)
  qty_tersedia_cache     integer,                   -- cache M22/M23; NULL = belum pernah tarik (gagal → "habis", aman)
  cache_diperbarui_at    timestamptz,               -- staleness ≤ 5 menit (F02)
  perlu_ditinjau         boolean NOT NULL DEFAULT false,  -- F01: master produk berubah → penandaan
  status                 enum_status_katalog_ecom NOT NULL DEFAULT 'DRAFT',
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_ecom_katalog_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_katalog_harga CHECK (harga_web IS NULL OR harga_web >= 0),
  CONSTRAINT ck_ecom_katalog_batas_stok
    CHECK (batas_tampil_stok IS NULL OR batas_tampil_stok >= 0),
  CONSTRAINT fk_ecom_katalog_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_katalog_file FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_katalog_slug_hidup
  ON ecom_katalog_online (slug) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_produk ON ecom_katalog_online (id_inv_produk);
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_storefront
  ON ecom_katalog_online (status) WHERE status = 'PUBLIK' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_perlu_ditinjau
  ON ecom_katalog_online (perlu_ditinjau) WHERE perlu_ditinjau AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_file
  ON ecom_katalog_online (id_core_files) WHERE id_core_files IS NOT NULL;

-- 2.2 ecom_kupon — [MASTER] — voucher diskon (persen/nominal/gratis ongkir);
--     kode GLOBAL tanpa deleted_at — tidak dipakai ulang antar kampanye (ECOM-BR01)
CREATE TABLE IF NOT EXISTS ecom_kupon (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- UNIQUE GLOBAL (K-10 / ECOM-BR01)
  nama                   varchar(100) NOT NULL,
  jenis                  enum_jenis_kupon_ecom NOT NULL,
  persen                 numeric(18,6),             -- wajib bila PERSEN (rasio — bucket 18,6)
  nilai                  numeric(18,4),             -- wajib bila NOMINAL (uang)
  syarat_minimum         numeric(18,4) NOT NULL DEFAULT 0 CHECK (syarat_minimum >= 0),  -- 0 = tanpa minimum (CFG-ECOM-07)
  periode_mulai          date,
  periode_berakhir       date,
  kuota_total            integer,                   -- NULL = tanpa batas; 0 = kuota habis
  kuota_per_pelanggan    integer NOT NULL DEFAULT 1 CHECK (kuota_per_pelanggan >= 1),
  kuota_terpakai         integer NOT NULL DEFAULT 0 CHECK (kuota_terpakai >= 0),  -- decrement atomik (F04/STD-07)
  status                 enum_status_kupon_ecom NOT NULL DEFAULT 'DRAFT',
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_ecom_kupon_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ecom_kupon_kode UNIQUE (kode),      -- GLOBAL tanpa deleted_at
  CONSTRAINT ck_ecom_kupon_nilai
    CHECK ((persen IS NULL OR persen >= 0) AND (nilai IS NULL OR nilai >= 0)),
  CONSTRAINT ck_ecom_kupon_jenis_nilai
    CHECK ((jenis <> 'PERSEN' OR persen IS NOT NULL)
       AND (jenis <> 'NOMINAL' OR nilai IS NOT NULL)),
  CONSTRAINT ck_ecom_kupon_periode
    CHECK (periode_mulai IS NULL OR periode_berakhir IS NULL
           OR periode_berakhir >= periode_mulai),
  CONSTRAINT ck_ecom_kupon_kuota
    CHECK (kuota_total IS NULL OR kuota_total >= 0)
);
CREATE INDEX IF NOT EXISTS ix_ecom_kupon_aktif
  ON ecom_kupon (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_kupon_berakhir
  ON ecom_kupon (periode_berakhir) WHERE periode_berakhir IS NOT NULL;

-- 2.3 ecom_keranjang — [TRANSAKSI SESSION-LIKE] — wadah item sebelum checkout;
--     hold_berakhir_at = kedaluwarsa_hold analisa (CFG-ECOM-10; NULL = tanpa hold);
--     satu keranjang AKTIF per sesi tamu / per pelanggan; KADALUARSA = terminal
CREATE TABLE IF NOT EXISTS ecom_keranjang (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  sesi_ref               varchar(150),              -- token sesi pembeli tamu (CFG-ECOM-01)
  id_sls_pelanggan       bigint,                    -- pembeli akun (live SLS, RESTRICT nullable; NULL = tamu)
  id_ecom_kupon          bigint,                    -- kupon terpakai di keranjang (SET NULL)
  subtotal               numeric(18,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),   -- cache server-side (ECOM-BR05)
  diskon_kupon           numeric(18,4) NOT NULL DEFAULT 0 CHECK (diskon_kupon >= 0),
  hold_berakhir_at       timestamptz,               -- kedaluwarsa_hold (CFG-ECOM-10); NULL = tanpa hold
  status                 enum_status_keranjang_ecom NOT NULL DEFAULT 'AKTIF',
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_ecom_keranjang_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_keranjang_pemilik
    CHECK (sesi_ref IS NOT NULL OR id_sls_pelanggan IS NOT NULL),
  CONSTRAINT fk_ecom_keranjang_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_keranjang_kupon FOREIGN KEY (id_ecom_kupon)
    REFERENCES ecom_kupon (id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_keranjang_sesi_aktif
  ON ecom_keranjang (sesi_ref)
  WHERE status = 'AKTIF' AND sesi_ref IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_keranjang_pelanggan_aktif
  ON ecom_keranjang (id_sls_pelanggan)
  WHERE status = 'AKTIF' AND id_sls_pelanggan IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_keranjang_sweeper
  ON ecom_keranjang (hold_berakhir_at)
  WHERE status = 'AKTIF' AND hold_berakhir_at IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_keranjang_pelanggan
  ON ecom_keranjang (id_sls_pelanggan) WHERE id_sls_pelanggan IS NOT NULL;

-- 2.4 ecom_keranjang_item — [LINE of keranjang] — baris (katalog_ref, qty) analisa
--     §4.1; harga_satuan hanya cache masuk keranjang — recompute checkout (ECOM-BR05)
CREATE TABLE IF NOT EXISTS ecom_keranjang_item (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ecom_keranjang      bigint NOT NULL,
  id_ecom_katalog_online bigint NOT NULL,           -- RESTRICT — item non-publik ditolak (ECOM-BR06)
  qty                    integer NOT NULL CHECK (qty > 0),
  harga_satuan           numeric(18,4) NOT NULL CHECK (harga_satuan >= 0),  -- cache harga (bukan sumber kebenaran)
  subtotal               numeric(18,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_ecom_keranjang_item_keranjang FOREIGN KEY (id_ecom_keranjang)
    REFERENCES ecom_keranjang (id) ON DELETE CASCADE,
  CONSTRAINT fk_ecom_keranjang_item_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT
);
-- uq partial HIDUP (pola hr — qty diubah in-place, tanpa baris ganda)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_keranjang_item_hidup
  ON ecom_keranjang_item (id_ecom_keranjang, id_ecom_katalog_online)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_keranjang_item_katalog
  ON ecom_keranjang_item (id_ecom_katalog_online);

-- 2.5 ecom_pesanan_web — [TRANSAKSI] — transaksi web pembeli: status bayar (M15/M50),
--     konversi SO belakangan (M14 — so_ref SET NULL), status pemenuhan balik (M24);
--     nomor doc_name rencana 'web_order' WO-{yyyy} (seed fase berikutnya — STD-08)
CREATE TABLE IF NOT EXISTS ecom_pesanan_web (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,   -- UNIQUE GLOBAL (WO-{yyyy}; numbering pasca-seed)
  id_ecom_keranjang           bigint,                  -- asal keranjang (SET NULL — ephemeral)
  id_sls_pelanggan            bigint,                  -- NULL = tamu; terisi setelah master terbentuk (CFG-ECOM-11/M14)
  id_ecom_kupon               bigint,                  -- kupon dipakai (SET NULL — snapshot diskon tetap)
  nama_pembeli                varchar(100) NOT NULL,   -- snapshot identitas (tamu/akun)
  email                       varchar(150),
  telepon                     varchar(50),
  alamat_kirim                varchar(300) NOT NULL,   -- F05 alamat lengkap (pola sls_pelanggan.alamat_kirim)
  nilai_subtotal              numeric(18,4) NOT NULL DEFAULT 0 CHECK (nilai_subtotal >= 0),
  diskon_kupon                numeric(18,4) NOT NULL DEFAULT 0 CHECK (diskon_kupon >= 0),
  ongkir                      numeric(18,4) NOT NULL DEFAULT 0 CHECK (ongkir >= 0),   -- CFG-ECOM-05
  nilai_total                 numeric(18,4) NOT NULL DEFAULT 0 CHECK (nilai_total >= 0),  -- item − diskon + ongkir (ECOM-BR05)
  metode_bayar                varchar(100),            -- snapshot label metode (payload M15/M50)
  gateway_ref                 varchar(150),            -- payment_ref M15 / intent_ref M50 (tanpa FK ke pgw_* — tabel belum ada)
  waktu_bayar                 timestamptz,
  kedaluwarsa_bayar_at        timestamptz,             -- CFG-ECOM-10: MENUNGGU_PEMBAYARAN lewat ini → DIBATALKAN
  status_bayar                enum_status_bayar_ecom NOT NULL DEFAULT 'BELUM_BAYAR',
  id_core_users_verifikasi    bigint,                  -- verifikasi transfer manual (ECOM-BR08; SET NULL)
  status_konversi             enum_status_konversi_ecom NOT NULL DEFAULT 'MENUNGGU',  -- M14 / antrian review F07
  id_sls_pesanan_penjualan    bigint,                  -- so_ref — SO dibuat BELAKANGAN oleh M14 (SET NULL)
  nilai_refund                numeric(18,4),           -- uang dieksekusi ACC (M15 jenis REFUND — A-05)
  status                      enum_status_pesanan_web_ecom NOT NULL DEFAULT 'MENUNGGU_PEMBAYARAN',
  id_core_users_batal         bigint,                  -- aktor batal/refund (SoD ECOM-BR10; SET NULL)
  alasan_batal                varchar(300),            -- wajib bila DIBATALKAN/REFUND (ECOM-BR04 — ck di bawah)
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ecom_pesanan_web_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ecom_pesanan_web_nomor UNIQUE (nomor),
  CONSTRAINT ck_ecom_pesanan_web_batal
    CHECK (status NOT IN ('DIBATALKAN','REFUND') OR alasan_batal IS NOT NULL),
  CONSTRAINT ck_ecom_pesanan_web_refund
    CHECK (nilai_refund IS NULL OR (nilai_refund >= 0 AND nilai_refund <= nilai_total)),
  CONSTRAINT fk_ecom_pesanan_web_keranjang FOREIGN KEY (id_ecom_keranjang)
    REFERENCES ecom_keranjang (id) ON DELETE SET NULL,
  CONSTRAINT fk_ecom_pesanan_web_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_pesanan_web_kupon FOREIGN KEY (id_ecom_kupon)
    REFERENCES ecom_kupon (id) ON DELETE SET NULL,
  CONSTRAINT fk_ecom_pesanan_web_so FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE SET NULL,
  CONSTRAINT fk_ecom_pesanan_web_verifikasi FOREIGN KEY (id_core_users_verifikasi)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_ecom_pesanan_web_batal FOREIGN KEY (id_core_users_batal)
    REFERENCES core_users (id) ON DELETE SET NULL
);
-- Idempoten M15/M50 per payment_ref: dua pesanan tidak boleh membagi ref
-- (retry charge menimpa kolom di baris yang sama — A-04)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_pesanan_web_gateway_ref
  ON ecom_pesanan_web (gateway_ref)
  WHERE gateway_ref IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_pelanggan
  ON ecom_pesanan_web (id_sls_pelanggan) WHERE id_sls_pelanggan IS NOT NULL;
-- Antrian CS: pembayaran tertunda + sweeper kedaluwarsa (F06)
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_menunggu_bayar
  ON ecom_pesanan_web (kedaluwarsa_bayar_at)
  WHERE status = 'MENUNGGU_PEMBAYARAN' AND deleted_at IS NULL;
-- Pemicu M14: pesanan DIBAYAR yang SO-nya belum terbentuk
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_antrian_konversi
  ON ecom_pesanan_web (id_sls_pelanggan)
  WHERE status = 'DIBAYAR' AND status_konversi <> 'TERBENTUK' AND deleted_at IS NULL;
-- Antrian review manual (M14 gagal → CS/Manajer, F07)
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_antrean_review
  ON ecom_pesanan_web (status_konversi)
  WHERE status_konversi = 'ANTREAN_REVIEW' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_so
  ON ecom_pesanan_web (id_sls_pesanan_penjualan) WHERE id_sls_pesanan_penjualan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_kupon
  ON ecom_pesanan_web (id_ecom_kupon) WHERE id_ecom_kupon IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_keranjang
  ON ecom_pesanan_web (id_ecom_keranjang) WHERE id_ecom_keranjang IS NOT NULL;

-- 2.6 ecom_pesanan_web_item — [LINE of pesanan] — baris beku saat checkout
--     (katalog_ref, qty, harga) analisa §4.1; snapshot judul + harga deal (ECOM-BR05)
CREATE TABLE IF NOT EXISTS ecom_pesanan_web_item (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ecom_pesanan_web    bigint NOT NULL,
  id_ecom_katalog_online bigint NOT NULL,           -- RESTRICT (katalog tidak pernah hard-delete — STD-02)
  judul                  varchar(200) NOT NULL,     -- snapshot judul katalog (beku)
  qty                    integer NOT NULL CHECK (qty > 0),
  harga_satuan           numeric(18,4) NOT NULL CHECK (harga_satuan >= 0),  -- snapshot harga deal saat checkout
  subtotal               numeric(18,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_ecom_pesanan_item_pesanan FOREIGN KEY (id_ecom_pesanan_web)
    REFERENCES ecom_pesanan_web (id) ON DELETE CASCADE,
  CONSTRAINT fk_ecom_pesanan_item_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT
);
-- uq partial HIDUP (pola hr — checkout menggabungkan baris, tanpa baris ganda)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_pesanan_item_hidup
  ON ecom_pesanan_web_item (id_ecom_pesanan_web, id_ecom_katalog_online)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_item_katalog
  ON ecom_pesanan_web_item (id_ecom_katalog_online);

-- 2.7 ecom_review — [TRANSAKSI] — ulasan produk pembeli + moderasi (F10);
--     wajib merujuk pesanan web yang memuat item (bukti riwayat pembelian);
--     disembunyikan tetap tersimpan (STD-02); review milik penulisnya (ECOM-BR03)
CREATE TABLE IF NOT EXISTS ecom_review (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ecom_katalog_online bigint NOT NULL,           -- RESTRICT
  id_ecom_pesanan_web    bigint NOT NULL,           -- RESTRICT — bukti riwayat pembelian (F10)
  id_sls_pelanggan       bigint,                    -- penulis (nullable — tamu pasca master terbentuk)
  penulis_nama           varchar(100) NOT NULL,     -- snapshot display (beku)
  rating                 smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  isi                    varchar(300),
  balasan                varchar(300),              -- Pengelola membalas (F10)
  status                 enum_status_review_ecom NOT NULL DEFAULT 'MENUNGGU_MODERASI',
  alasan_moderasi        varchar(300),              -- wajib bila TERSEMBUNYI (ECOM-BR04 — ck di bawah)
  id_core_users_moderator bigint,                   -- Pengelola yang memoderasi (SET NULL)
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_ecom_review_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_review_moderasi
    CHECK (status <> 'TERSEMBUNYI' OR alasan_moderasi IS NOT NULL),
  CONSTRAINT fk_ecom_review_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_review_pesanan FOREIGN KEY (id_ecom_pesanan_web)
    REFERENCES ecom_pesanan_web (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_review_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_review_moderator FOREIGN KEY (id_core_users_moderator)
    REFERENCES core_users (id) ON DELETE SET NULL
);
-- uq partial HIDUP — satu review per pembelian per item katalog (F10)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_review_hidup
  ON ecom_review (id_ecom_pesanan_web, id_ecom_katalog_online)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_review_storefront
  ON ecom_review (id_ecom_katalog_online)
  WHERE status = 'TAYANG' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_review_antrian_moderasi
  ON ecom_review (status) WHERE status = 'MENUNGGU_MODERASI' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_review_pelanggan
  ON ecom_review (id_sls_pelanggan) WHERE id_sls_pelanggan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_review_pesanan
  ON ecom_review (id_ecom_pesanan_web);

-- =============================================================================
-- §3 — TRIGGER updated_at (7 tabel ecom_* — satu blok DO; set_updated_at() milik
--      baseline CORE 01-core, TIDAK dibuat ulang di sini)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'ecom_katalog_online','ecom_kupon','ecom_keranjang','ecom_keranjang_item',
    'ecom_pesanan_web','ecom_pesanan_web_item','ecom_review'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §4 — VERIFIKASI (komentar introspeksi — jalankan manual setelah apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 4.1 Daftar tabel ecom_* (harap 7):
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name LIKE 'ecom\_%' ESCAPE '\'
-- ORDER BY table_name;
-- SELECT count(*) AS jumlah_tabel_ecom FROM (
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' AND table_name LIKE 'ecom\_%' ESCAPE '\'
-- ) t;
--
-- -- 4.2 Jumlah enum ecom (harap 9):
-- SELECT count(*) AS jumlah_enum_ecom
-- FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE t.typtype = 'e' AND t.typname LIKE 'enum\_%\_ecom' ESCAPE '\'
--   AND n.nspname = 'public';
--
-- -- 4.3 Trigger set_updated_at pada tabel ecom (harap 7):
-- SELECT count(*) AS jumlah_trigger_ecom
-- FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
-- WHERE NOT t.tgisinternal AND c.relname LIKE 'ecom\_%' ESCAPE '\'
--   AND t.tgname LIKE '%_updated_at';
--
-- -- 4.4 Nilai enum registry (harap memuat 'ecom' SETELAH patch di-apply untuk
-- --     sungguhan — pada dry-run BEGIN..ROLLBACK nilai ini ikut dibatalkan):
-- SELECT enum_range(NULL::core_module_key)::text;
--
-- -- 4.5 Registry & sequences (harap KOSONG sampai seed-ecom-core.sql fase
-- --     berikutnya — patch ini sengaja tidak INSERT memakai 'ecom'):
-- SELECT * FROM core_modules WHERE key::text = 'ecom';
--
-- PATCH 36-ecom.sql selesai.
