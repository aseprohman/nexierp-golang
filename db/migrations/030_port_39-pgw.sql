-- +goose Up
-- Porting 1:1 dari ddl/39-pgw.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 39-pgw.sql — Modul PGW (PAYMENT GATEWAY)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-pgw.md (blueprint teraudit; keputusan pemilik
--            2026-11-07 — M50–M54 incl. F13 kirim tautan bayar via outbox)
--            + docs/arsitektur-database-pgw.md (kartu klasifikasi).
-- Kartu    : docs/arsitektur-database-pgw.md (gerbang arsitektur-database).
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at,
--            core_modules key='payment-gateway' [live id 15], core_sequences,
--            enum_status_aktif) + master metode bayar 23-pos (core_metode_bayar).
-- Isi      : 9 tabel pgw_* — 2 MASTER (konfigurasi_vendor, channel)
--            + 3 TRANSAKSI (transaksi, refund, rekonsiliasi) + 1 LINE
--            (rekonsiliasi_baris) + 3 LOG/EVENT (log_webhook, log_api,
--            pengiriman_tautan) + 11 enum enum_*_pgw + trigger set_updated_at
--            9 tabel + ensure core_sequences module payment-gateway (2 baru).
-- Integrasi: FK keluar baca-saja — id_core_users (aktor refund/rekonsiliasi),
--            id_core_metode_bayar (pemetaan kanal, RESTRICT). PGW tidak pernah
--            menulis tabel modul lain — keluaran via core_outbox_events
--            (M51/M52/M54; dedupe payload->_key, index uq_outbox_topic_key_pending).
--            Penomoran via core_sequences: PGW-{yyyyMM}, PGWRF-{yyyyMM}.
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit, CREATE INDEX IF NOT EXISTS, trigger
--            DO-block DROP+CREATE, sequences ON CONFLICT DO NOTHING
--            (counter tidak pernah diturunkan).
-- Catatan  : uang numeric(18,4); teks bucket varchar 50/100/150/200/300 tanpa
--            text (entity_id_sumber varchar(255) = pengecualian Tier B terkunci);
--            jsonb hanya payload yang tidak difilter/di-join (kredensial
--            TERENKRIPSI app-side AES-256-GCM — tidak pernah plaintext, PGW-BR01);
--            kredensial environment hanya SANDBOX|PRODUKSI — SIMULASI adalah
--            environment transaksi adapter simulator (PGW-BR08);
--            LOG/EVENT append-only (updated_at beku, deleted_at selalu NULL,
--            tanpa version); LINE tanpa entity_id/version (pola tabel baris);
--            refund_key & dedupe_key UNIQUE GLOBAL (idempoten tidak pernah
--            dipakai ulang meski baris dihapus). Seed master preset = 
--            podman/seed-pgw-core.sql — di luar patch DDL ini.
-- =============================================================================

-- =============================================================================
-- §1 ENUM — 11 tipe baru (fail-loud bila kosakata menyimpang dari mirror)
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_environment_pgw AS ENUM ('SANDBOX','PRODUKSI','SIMULASI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_environment_pgw')
     IS DISTINCT FROM ARRAY['SANDBOX','PRODUKSI','SIMULASI']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_environment_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_konfigurasi_pgw AS ENUM ('DRAFT','DIUJI','AKTIF','DINONAKTIFKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_konfigurasi_pgw')
     IS DISTINCT FROM ARRAY['DRAFT','DIUJI','AKTIF','DINONAKTIFKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_status_konfigurasi_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_hasil_uji_pgw AS ENUM ('LULUS','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_uji_pgw')
     IS DISTINCT FROM ARRAY['LULUS','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_hasil_uji_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_transaksi_pgw AS ENUM
    ('DIBUAT','MENUNGGU_BAYAR','CHALLENGE','DIBAYAR','GAGAL','KADALUARSA','DIBATALKAN','REFUND_PENUH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_transaksi_pgw')
     IS DISTINCT FROM ARRAY['DIBUAT','MENUNGGU_BAYAR','CHALLENGE','DIBAYAR','GAGAL','KADALUARSA','DIBATALKAN','REFUND_PENUH']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_status_transaksi_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_refund_pgw AS ENUM
    ('DIAJUKAN','DISETUJUI','TERKIRIM_VENDOR','SELESAI','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_refund_pgw')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','TERKIRIM_VENDOR','SELESAI','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_status_refund_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_hasil_verifikasi_pgw AS ENUM ('VALID','INVALID','TAK_DIKENAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_verifikasi_pgw')
     IS DISTINCT FROM ARRAY['VALID','INVALID','TAK_DIKENAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_hasil_verifikasi_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_hasil_panggilan_pgw AS ENUM ('BERHASIL','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_panggilan_pgw')
     IS DISTINCT FROM ARRAY['BERHASIL','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_hasil_panggilan_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_rekonsiliasi_pgw AS ENUM ('DRAFT','SELESAI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_rekonsiliasi_pgw')
     IS DISTINCT FROM ARRAY['DRAFT','SELESAI']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_status_rekonsiliasi_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_selisih_rekonsiliasi_pgw AS ENUM
    ('COCOK','TANPA_LAPORAN','TANPA_TRANSAKSI','BEDA_NOMINAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_selisih_rekonsiliasi_pgw')
     IS DISTINCT FROM ARRAY['COCOK','TANPA_LAPORAN','TANPA_TRANSAKSI','BEDA_NOMINAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_jenis_selisih_rekonsiliasi_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kanal_pengiriman_pgw AS ENUM ('EMAIL','WHATSAPP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kanal_pengiriman_pgw')
     IS DISTINCT FROM ARRAY['EMAIL','WHATSAPP']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_kanal_pengiriman_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pengiriman_pgw AS ENUM ('DIANTREKAN','TERKIRIM','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pengiriman_pgw')
     IS DISTINCT FROM ARRAY['DIANTREKAN','TERKIRIM','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 39-pgw: enum_status_pengiriman_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 TABEL MASTER — urutan dependensi FK
-- =============================================================================

-- [MASTER] konfigurasi vendor per (kode_vendor, environment, versi kredensial).
-- kredensial = blob terenkripsi app-side (AES-256-GCM) — write-only (PGW-BR01).
CREATE TABLE IF NOT EXISTS pgw_konfigurasi_vendor (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor          varchar(50) NOT NULL,              -- MIDTRANS / DOKU / SIMULATOR / …
  environment          enum_environment_pgw NOT NULL,     -- konfigurasi hanya SANDBOX|PRODUKSI (ck di bawah)
  base_url             varchar(300) NOT NULL,             -- disimpan penuh: api.sandbox.midtrans.com / api-sandbox.doku.com / internal://simulator
  kredensial           jsonb NOT NULL DEFAULT '{}'::jsonb,-- blob terenkripsi (field dinamis per vendor) — tidak pernah difilter/join
  kredensial_versi    int NOT NULL DEFAULT 1,            -- rotasi: versi baru, satu AKTIF
  webhook_url          varchar(300),                      -- endpoint callback publik yang diumumkan ke dashboard vendor
  status               enum_status_konfigurasi_pgw NOT NULL DEFAULT 'DRAFT',
  uji_terakhir_at      timestamptz,                       -- hasil uji koneksi terakhir (F03)
  uji_terakhir_hasil   enum_hasil_uji_pgw,
  uji_terakhir_pesan   varchar(300),                      -- interpretasi berkode: AUTH_SALAH / BASE_URL_SALAH / JARINGAN
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_pgw_konfigurasi_vendor_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_pgw_konfigurasi_vendor_environment CHECK
    (environment IN ('SANDBOX','PRODUKSI'))              -- BR08: SIMULASI bukan environment konfigurasi
);

CREATE INDEX IF NOT EXISTS ix_pgw_konfigurasi_vendor_pasangan
  ON pgw_konfigurasi_vendor (kode_vendor, environment);

-- satu konfigurasi AKTIF per (vendor, environment) — PGW-BR09
CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_konfigurasi_vendor_aktif_hidup
  ON pgw_konfigurasi_vendor (kode_vendor, environment)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_konfigurasi_vendor_versi_hidup
  ON pgw_konfigurasi_vendor (kode_vendor, environment, kredensial_versi)
  WHERE deleted_at IS NULL;

-- [MASTER] channel pembayaran per konfigurasi; pemetaan ke master metode bayar CORE
-- (FK RESTRICT baca-saja — PGW tidak pernah membuat master metode bayar, PGW-BR06/PP-20).
CREATE TABLE IF NOT EXISTS pgw_channel (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pgw_konfigurasi_vendor bigint NOT NULL,
  id_core_metode_bayar      bigint NOT NULL,
  kode_channel              varchar(50) NOT NULL,   -- nilai asli vendor: gopay, bank_transfer, VIRTUAL_ACCOUNT_BCA, qris, …
  nama                      varchar(100) NOT NULL,
  konfig                    jsonb,                  -- setelan kecil per kanal (display, tidak difilter)
  status                    enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                   int NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_pgw_channel_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pgw_channel_konfigurasi FOREIGN KEY (id_pgw_konfigurasi_vendor)
    REFERENCES pgw_konfigurasi_vendor (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pgw_channel_metode_bayar FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_channel_kode_hidup
  ON pgw_channel (id_pgw_konfigurasi_vendor, kode_channel)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_channel_metode_bayar
  ON pgw_channel (id_core_metode_bayar)
  WHERE deleted_at IS NULL;

-- =============================================================================
-- §3 TABEL TRANSAKSI + LINE + LOG/EVENT — urutan dependensi FK
-- =============================================================================

-- [TRANSAKSI] transaksi pembayaran gateway — status ternormalisasi lintas vendor,
-- transisi monoton diegakkan app-side (PGW-BR03); idempotensi intent & referensi
-- vendor diegakkan DB (unique partial di bawah — PGW-BR04).
CREATE TABLE IF NOT EXISTS pgw_transaksi (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                     varchar(150) NOT NULL,   -- PGW-{yyyyMM}#### via core_sequences (unique global, STD-08)
  intent_ref                varchar(150) NOT NULL,   -- referensi intent dari modul peminta (M50/M53)
  jenis_sumber              varchar(50) NOT NULL,    -- ECOM_PESANAN_WEB / RSV_RESERVASI / SIMULATOR / …
  entity_id_sumber          varchar(255) NOT NULL,   -- Tier B: kunci bisnis dokumen sumber lintas modul (PP-03)
  jumlah                    numeric(18,4) NOT NULL,
  jumlah_terrefund          numeric(18,4) NOT NULL DEFAULT 0,
  mata_uang                 varchar(50) NOT NULL DEFAULT 'IDR',
  id_pgw_konfigurasi_vendor bigint NOT NULL,
  id_pgw_channel            bigint NOT NULL,
  id_core_metode_bayar      bigint NOT NULL,
  environment               enum_environment_pgw NOT NULL,  -- SANDBOX|PRODUKSI|SIMULASI (transaksi simulator = SIMULASI)
  referensi_vendor          varchar(150),            -- order_id / invoice_number dari vendor
  token_bayar               varchar(300),            -- token Snap / token_id Checkout
  url_bayar                 varchar(300),            -- redirect_url / payment.url — dibagikan ke pelanggan
  detail_vendor             jsonb,                   -- payload vendor display: va_number, qr_string, actions, dsb (tidak difilter)
  waktu_kadaluarsa          timestamptz,
  waktu_bayar               timestamptz,
  status                    enum_status_transaksi_pgw NOT NULL DEFAULT 'DIBUAT',
  version                   int NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_pgw_transaksi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pgw_transaksi_nomor UNIQUE (nomor),
  CONSTRAINT fk_pgw_transaksi_konfigurasi FOREIGN KEY (id_pgw_konfigurasi_vendor)
    REFERENCES pgw_konfigurasi_vendor (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pgw_transaksi_channel FOREIGN KEY (id_pgw_channel)
    REFERENCES pgw_channel (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pgw_transaksi_metode_bayar FOREIGN KEY (id_core_metode_bayar)
    REFERENCES core_metode_bayar (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pgw_transaksi_jumlah CHECK (jumlah > 0),
  CONSTRAINT ck_pgw_transaksi_refund CHECK
    (jumlah_terrefund >= 0 AND jumlah_terrefund <= jumlah)
);

-- idempotensi intent: satu transaksi AKTIF per (jenis_sumber, entity_id_sumber) — BR04
CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_transaksi_intent_aktif
  ON pgw_transaksi (jenis_sumber, entity_id_sumber)
  WHERE status IN ('DIBUAT','MENUNGGU_BAYAR','CHALLENGE') AND deleted_at IS NULL;

-- idempotensi vendor: referensi vendor unik per konfigurasi
CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_transaksi_ref_vendor
  ON pgw_transaksi (id_pgw_konfigurasi_vendor, referensi_vendor)
  WHERE referensi_vendor IS NOT NULL AND deleted_at IS NULL;

-- sweep polling/expire F08 (CFG-PGW-05)
CREATE INDEX IF NOT EXISTS ix_pgw_transaksi_sweep
  ON pgw_transaksi (status, waktu_kadaluarsa)
  WHERE status IN ('MENUNGGU_BAYAR','CHALLENGE') AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_transaksi_sumber
  ON pgw_transaksi (jenis_sumber, entity_id_sumber);

CREATE INDEX IF NOT EXISTS ix_pgw_transaksi_konfigurasi
  ON pgw_transaksi (id_pgw_konfigurasi_vendor)
  WHERE deleted_at IS NULL;

-- [TRANSAKSI] refund — pengaju RESTRICT / penyetuju SET NULL + penyetuju_sistem
-- (keputusan otomatis di bawah ambang CFG-PGW-02, blueprint F10/BR16);
-- refund_key UNIQUE GLOBAL — kunci idempoten vendor tidak pernah dipakai ulang.
CREATE TABLE IF NOT EXISTS pgw_refund (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                 varchar(150) NOT NULL,      -- PGWRF-{yyyyMM}#### via core_sequences
  id_pgw_transaksi      bigint NOT NULL,
  refund_key            varchar(100) NOT NULL,      -- idempoten ke vendor (BR04/BR13)
  jumlah                numeric(18,4) NOT NULL,
  alasan                varchar(300) NOT NULL,
  id_core_users_pengaju bigint NOT NULL,
  id_core_users_penyetuju bigint,                   -- NULL saat penyetuju_sistem
  penyetuju_sistem      boolean NOT NULL DEFAULT false,
  waktu_setuju          timestamptz,
  waktu_selesai         timestamptz,
  status                enum_status_refund_pgw NOT NULL DEFAULT 'DIAJUKAN',
  version               int NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  deleted_at            timestamptz,
  CONSTRAINT uq_pgw_refund_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pgw_refund_nomor UNIQUE (nomor),
  CONSTRAINT uq_pgw_refund_refund_key UNIQUE (refund_key),
  CONSTRAINT fk_pgw_refund_transaksi FOREIGN KEY (id_pgw_transaksi)
    REFERENCES pgw_transaksi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pgw_refund_pengaju FOREIGN KEY (id_core_users_pengaju)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pgw_refund_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pgw_refund_jumlah CHECK (jumlah > 0),
  CONSTRAINT ck_pgw_refund_penyetuju CHECK
    (penyetuju_sistem OR id_core_users_penyetuju IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pgw_refund_transaksi
  ON pgw_refund (id_pgw_transaksi)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_refund_status
  ON pgw_refund (status)
  WHERE deleted_at IS NULL;

-- [TRANSAKSI] rekonsiliasi mutasi gateway — header per (kode_vendor, periode) — F12
CREATE TABLE IF NOT EXISTS pgw_rekonsiliasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor            varchar(50) NOT NULL,
  periode                varchar(50) NOT NULL,     -- format YYYY-MM
  sumber_laporan         varchar(300),             -- nama file/impor laporan settlement dashboard vendor (Q-05)
  jumlah_cocok           int NOT NULL DEFAULT 0,
  jumlah_selisih         int NOT NULL DEFAULT 0,
  status                 enum_status_rekonsiliasi_pgw NOT NULL DEFAULT 'DRAFT',
  id_core_users_diproses bigint NOT NULL,          -- Staf Keuangan yang menjalankan
  waktu_selesai          timestamptz,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_pgw_rekonsiliasi_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pgw_rekonsiliasi_diproses FOREIGN KEY (id_core_users_diproses)
    REFERENCES core_users (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pgw_rekonsiliasi_periode_hidup
  ON pgw_rekonsiliasi (kode_vendor, periode)
  WHERE deleted_at IS NULL;

-- [LINE] baris rekonsiliasi — tanpa entity_id/version (pola tabel baris);
-- penjelasan wajib terisi sebelum periode SELESAI (BR15, diegakkan app-side).
CREATE TABLE IF NOT EXISTS pgw_rekonsiliasi_baris (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pgw_rekonsiliasi    bigint NOT NULL,
  jenis                  enum_jenis_selisih_rekonsiliasi_pgw NOT NULL,
  referensi_vendor       varchar(150),
  id_pgw_transaksi       bigint,
  id_pgw_refund          bigint,
  jumlah                 numeric(18,4) NOT NULL DEFAULT 0,
  penjelasan             varchar(300),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_pgw_rekonsiliasi_baris_header FOREIGN KEY (id_pgw_rekonsiliasi)
    REFERENCES pgw_rekonsiliasi (id) ON DELETE CASCADE,
  CONSTRAINT fk_pgw_rekonsiliasi_baris_transaksi FOREIGN KEY (id_pgw_transaksi)
    REFERENCES pgw_transaksi (id) ON DELETE SET NULL,
  CONSTRAINT fk_pgw_rekonsiliasi_baris_refund FOREIGN KEY (id_pgw_refund)
    REFERENCES pgw_refund (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pgw_rekonsiliasi_baris_header
  ON pgw_rekonsiliasi_baris (id_pgw_rekonsiliasi);

CREATE INDEX IF NOT EXISTS ix_pgw_rekonsiliasi_baris_jenis
  ON pgw_rekonsiliasi_baris (id_pgw_rekonsiliasi, jenis);

CREATE INDEX IF NOT EXISTS ix_pgw_rekonsiliasi_baris_transaksi
  ON pgw_rekonsiliasi_baris (id_pgw_transaksi)
  WHERE id_pgw_transaksi IS NOT NULL;

-- [LOG/EVENT] append-only notifikasi webhook vendor — raw payload WAJIB tersimpan
-- (prinsip beku skill payment-gateway); dedupe_key UNIQUE GLOBAL (BR04).
CREATE TABLE IF NOT EXISTS pgw_log_webhook (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor       varchar(50) NOT NULL,
  environment       enum_environment_pgw NOT NULL,
  id_pgw_transaksi  bigint,                       -- NULL bila transaksi tak dikenal — log tetap tersimpan
  dedupe_key        varchar(200) NOT NULL,        -- kunci kejadian vendor (idempotensi, tidak pernah reuse)
  payload_mentah    jsonb NOT NULL,               -- raw body apa adanya
  header_asli       jsonb,                        -- header asli (signature, client-id, dsb — tanpa secret)
  hasil_verifikasi  enum_hasil_verifikasi_pgw NOT NULL,
  dampak            varchar(300),                 -- ringkasan: transisi status / alasan diabaikan
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),  -- beku (append-only)
  deleted_at        timestamptz,                         -- selalu NULL (append-only)
  CONSTRAINT uq_pgw_log_webhook_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pgw_log_webhook_dedupe UNIQUE (dedupe_key),
  CONSTRAINT fk_pgw_log_webhook_transaksi FOREIGN KEY (id_pgw_transaksi)
    REFERENCES pgw_transaksi (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pgw_log_webhook_transaksi
  ON pgw_log_webhook (id_pgw_transaksi, created_at)
  WHERE id_pgw_transaksi IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_log_webhook_vendor
  ON pgw_log_webhook (kode_vendor, created_at);

-- [LOG/EVENT] append-only panggilan keluar ke vendor — tanpa secret di log (BR10).
CREATE TABLE IF NOT EXISTS pgw_log_api (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_vendor       varchar(50) NOT NULL,
  environment       enum_environment_pgw NOT NULL,
  operasi           varchar(50) NOT NULL,         -- CHARGE / STATUS / CANCEL / REFUND / UJI_KONEKSI
  id_pgw_transaksi  bigint,
  http_status       int,
  latensi_ms        int NOT NULL DEFAULT 0,
  hasil             enum_hasil_panggilan_pgw NOT NULL,
  hasil_ringkas     varchar(300),                 -- interpretasi berkode: AUTH_SALAH / BASE_URL_SALAH / JARINGAN / OK
  detail            jsonb,                        -- body error tersaring (tanpa kredensial)
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),  -- beku (append-only)
  deleted_at        timestamptz,                         -- selalu NULL (append-only)
  CONSTRAINT uq_pgw_log_api_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pgw_log_api_transaksi FOREIGN KEY (id_pgw_transaksi)
    REFERENCES pgw_transaksi (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pgw_log_api_transaksi
  ON pgw_log_api (id_pgw_transaksi, created_at)
  WHERE id_pgw_transaksi IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_log_api_vendor_operasi
  ON pgw_log_api (kode_vendor, operasi, created_at);

-- [LOG/EVENT] append-only kejadian pengiriman tautan bayar (F13/M54) — PGW tidak
-- pernah mengirim pesan langsung; pelaksana = layanan pesan via outbox (BR18).
CREATE TABLE IF NOT EXISTS pgw_pengiriman_tautan (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pgw_transaksi  bigint,
  kanal             enum_kanal_pengiriman_pgw NOT NULL,   -- EMAIL / WHATSAPP
  tujuan            varchar(150) NOT NULL,                -- alamat email / nomor WhatsApp
  percobaan         int NOT NULL DEFAULT 1,               -- idempoten: payment_ref+kanal+tujuan+percobaan
  status_kejadian   enum_status_pengiriman_pgw NOT NULL,  -- DIANTREKAN / TERKIRIM / GAGAL
  payload_ref       varchar(300),                         -- snapshot tautan/VA/QR saat dikirim
  catatan           varchar(300),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),  -- beku (append-only)
  deleted_at        timestamptz,                         -- selalu NULL (append-only)
  CONSTRAINT uq_pgw_pengiriman_tautan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pgw_pengiriman_tautan_transaksi FOREIGN KEY (id_pgw_transaksi)
    REFERENCES pgw_transaksi (id) ON DELETE SET NULL,
  CONSTRAINT ck_pgw_pengiriman_tautan_percobaan CHECK (percobaan >= 1)
);

CREATE INDEX IF NOT EXISTS ix_pgw_pengiriman_tautan_transaksi
  ON pgw_pengiriman_tautan (id_pgw_transaksi, created_at)
  WHERE id_pgw_transaksi IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pgw_pengiriman_tautan_kanal
  ON pgw_pengiriman_tautan (kanal, status_kejadian);

-- =============================================================================
-- §4 TRIGGER updated_at — fungsi set_updated_at milik baseline 01-core (tidak dibuat ulang)
-- =============================================================================

-- +goose StatementBegin
DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'pgw_konfigurasi_vendor', 'pgw_channel', 'pgw_transaksi', 'pgw_refund',
    'pgw_rekonsiliasi', 'pgw_rekonsiliasi_baris', 'pgw_log_webhook',
    'pgw_log_api', 'pgw_pengiriman_tautan'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §5 SEED PENOMORAN — guard registry + core_sequences module payment-gateway
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'payment-gateway') THEN
    RAISE EXCEPTION 'PATCH 39-pgw: registry core_modules key=''payment-gateway'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;
-- +goose StatementEnd


INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('transaksi', 'PGW-{yyyyMM}',   0, 4),
  ('refund',    'PGWRF-{yyyyMM}', 0, 4)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'payment-gateway'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- =============================================================================
-- §6 VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi patch)
-- =============================================================================
-- SELECT to_regclass('public.pgw_transaksi');
-- SELECT count(*) FROM pg_tables WHERE tablename LIKE 'pgw_%';            -- 9
-- SELECT count(*) FROM pg_type  WHERE typname  LIKE 'enum_%_pgw';         -- 11
-- SELECT count(*) FROM pg_trigger WHERE tgrelid::regclass::text LIKE 'pgw_%'
--        AND NOT tgisinternal;                                            -- 9
-- SELECT doc_name, prefix, current_value, padding FROM core_sequences s
--        JOIN core_modules m ON m.id = s.id_core_modules
--        WHERE m.key = 'payment-gateway';                                 -- 2 baris
-- Dry-run transaksional:  BEGIN; \i ddl/39-pgw.sql; ROLLBACK;
-- Uji idempoten: jalankan patch 2× — apply kedua harus sukses tanpa error.
