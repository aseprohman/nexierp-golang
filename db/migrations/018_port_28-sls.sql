-- +goose Up
-- Porting 1:1 dari ddl/28-sls.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 28-sls.sql — Modul SALES (SLS) (rekonstruksi baru)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-sls-v4.md (kanonik — alur penawaran/SO/pemenuhan/
--            faktur/retur; keputusan K-10 kode pelanggan tak dipakai ulang, A-06
--            kode_termin transitional, F02 pricelist tanpa overlap, F15 margin,
--            SLS-BR06 algoritma harga, SLS-BR07 jasa, SLS-BR09/13 faktur & DP,
--            SLS-BR11 idempotensi web, SLS-BR14 retur wajib faktur) +
--            docs/audit-analisa-sls-v4.md. Kepemilikan mengikuti peta-modul §4.
-- Kartu    : docs/arsitektur-database-sls.md (PP-01…PP-25; pola reserved-FK
--            PP-03 seperti pos_pesanan.id_sls_pelanggan).
-- Status   : TERPASANG — dieksekusi di DB dev nexierp-postgres (db nexierp) 2026-11-06
--            (persetujuan pemilik bisnis; dry-run transaksional BEGIN→ROLLBACK lulus).
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at, registry
--            core_modules key='sales', core_sequences, core_module_configs,
--            core_outbox_events) + INV 02-inventory (inv_produk,
--            inv_kategori_produk, inv_unit_ukur, inv_gudang — FK sungguhan ke
--            id bigint) + patch 23-pos (pos_pesanan & pos_kartu_poin sudah
--            membawa kolom reserved id_sls_pelanggan — FK disetor §5).
-- Isi      : 17 tabel — 3 MASTER (grup_pelanggan, pelanggan, pricelist) +
--            1 LINE master (pricelist_aturan) + 4 TRANSAKSI (penawaran,
--            pesanan_penjualan, amendment_pesanan, retur_penjualan) +
--            3 LINE transaksi (penawaran_items, pesanan_items, retur_items)
--            + 1 LOG/EVENT append-only (pemenuhan_event)
--            + 5 ENGINE PROMOSI (promosi, promosi_kanal [JUNCTION],
--            promosi_aturan [LINE], voucher [TRANSAKSI], promosi_pemakaian
--            [LOG append-only]) + 20 enum enum_*_sls + 2 FK setoran ke tabel
--            POS live.
-- Integrasi: outbox topics M01 (SO terkonfirmasi → INV), M07 (pemicu faktur &
--            uang muka → ACC), M24 (status SO → ECOM), M39 (gerakan retur →
--            INV), M40 (nota kredit retur → ACC) — payload->_key idempoten
--            (uq_outbox_topic_key_pending, patch 26); pemenuhan fisik tetap
--            milik INV via M02 (picking, event masuk sls_pemenuhan_event);
--            cek limit M25 = query baca-saja ke ACC (tanpa tabel).
--            ACC = kontrak tanpa FK (invoice_ref varchar); nilai diskon
--            promosi mengalir ke SO via sls_promosi_pemakaian (ledger
--            append-only) — program kosong-kanal = semua kanal.
-- Mirror   : apps/api/src/core/database/schema/sls.ts (1:1 — TERPASANG;
--            dokumen; kosakata enum diverifikasi fail-loud §1).
-- Idempoten: aman dijalankan berulang (CREATE IF NOT EXISTS, enum DO-block
--            fail-loud, FK guard pg_constraint, seed ON CONFLICT DO NOTHING,
--            trigger DO-block DROP+CREATE).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) ENUM — 20 kosakata PERSIS mirror sls.ts (K-07); bila tipe sudah ada,
--    verifikasi kosakata persis — fail-loud bila menyimpang (pola 25-purchasing).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pelanggan_sls AS ENUM ('PROSPEK','AKTIF','NONAKTIF','DIBLOKIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_pelanggan_sls')
     IS DISTINCT FROM ARRAY['PROSPEK','AKTIF','NONAKTIF','DIBLOKIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_pelanggan_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_penawaran_sls AS ENUM
    ('DRAFT','TERKIRIM','DITERIMA','KADALUARSA','TERKONVERSI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_penawaran_sls')
     IS DISTINCT FROM ARRAY['DRAFT','TERKIRIM','DITERIMA','KADALUARSA','TERKONVERSI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_penawaran_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_so_sls AS ENUM
    ('DRAFT','MENUNGGU_APPROVAL','TERKONFIRMASI','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_so_sls')
     IS DISTINCT FROM ARRAY['DRAFT','MENUNGGU_APPROVAL','TERKONFIRMASI','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_so_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_persetujuan_sls AS ENUM ('DIAJUKAN','DISETUJUI','DITOLAK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_persetujuan_sls')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_persetujuan_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pemenuhan_sls AS ENUM
    ('BELUM_DIJADWALKAN','DALAM_PROSES','TERKIRIM_PARSIAL','TERKIRIM_PENUH','DITUTUP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_pemenuhan_sls')
     IS DISTINCT FROM ARRAY['BELUM_DIJADWALKAN','DALAM_PROSES','TERKIRIM_PARSIAL','TERKIRIM_PENUH','DITUTUP']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_pemenuhan_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_faktur_sls AS ENUM ('BELUM_DIFAKTUR','FAKTUR_PARSIAL','FAKTUR_PENUH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_faktur_sls')
     IS DISTINCT FROM ARRAY['BELUM_DIFAKTUR','FAKTUR_PARSIAL','FAKTUR_PENUH']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_faktur_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_baris_sls AS ENUM ('BARANG','JASA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_jenis_baris_sls')
     IS DISTINCT FROM ARRAY['BARANG','JASA']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_jenis_baris_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kanal_so_sls AS ENUM ('MANUAL','WEB','POS','RSV');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_kanal_so_sls')
     IS DISTINCT FROM ARRAY['MANUAL','WEB','POS','RSV']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_kanal_so_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_sumber_so_sls AS ENUM ('MANUAL','PENAWARAN','WEB');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_jenis_sumber_so_sls')
     IS DISTINCT FROM ARRAY['MANUAL','PENAWARAN','WEB']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_jenis_sumber_so_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pricelist_sls AS ENUM ('DRAFT','AKTIF','NONAKTIF','KADALUARSA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_pricelist_sls')
     IS DISTINCT FROM ARRAY['DRAFT','AKTIF','NONAKTIF','KADALUARSA']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_pricelist_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_basis_pricelist_sls AS ENUM ('UMUM','GRUP','PELANGGAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_basis_pricelist_sls')
     IS DISTINCT FROM ARRAY['UMUM','GRUP','PELANGGAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_basis_pricelist_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_target_aturan_sls AS ENUM ('SEMUA','KATEGORI','PRODUK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_jenis_target_aturan_sls')
     IS DISTINCT FROM ARRAY['SEMUA','KATEGORI','PRODUK']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_jenis_target_aturan_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_aturan_harga_sls AS ENUM ('HARGA_TETAP','DISKON_PERSEN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_jenis_aturan_harga_sls')
     IS DISTINCT FROM ARRAY['HARGA_TETAP','DISKON_PERSEN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_jenis_aturan_harga_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_retur_sls AS ENUM
    ('DIAJUKAN','DISETUJUI','DITOLAK','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_retur_sls')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_retur_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_arah_pemenuhan_sls AS ENUM ('KIRIM','KEMBALI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_arah_pemenuhan_sls')
     IS DISTINCT FROM ARRAY['KIRIM','KEMBALI']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_arah_pemenuhan_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_promosi_sls AS ENUM ('PROMO','KUPON','VOUCHER','BUNDLE');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_jenis_promosi_sls')
     IS DISTINCT FROM ARRAY['PROMO','KUPON','VOUCHER','BUNDLE']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_jenis_promosi_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_promosi_sls AS ENUM ('DRAFT','AKTIF','NONAKTIF','BERAKHIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_promosi_sls')
     IS DISTINCT FROM ARRAY['DRAFT','AKTIF','NONAKTIF','BERAKHIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_promosi_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_promosi_peran_sls AS ENUM ('SYARAT','HADIAH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_promosi_peran_sls')
     IS DISTINCT FROM ARRAY['SYARAT','HADIAH']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_promosi_peran_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_promosi_jenis_hadiah_sls AS ENUM
    ('DISKON_PERSEN','DISKON_NOMINAL','PRODUK_GRATIS','NILAI_VOUCHER');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_promosi_jenis_hadiah_sls')
     IS DISTINCT FROM ARRAY['DISKON_PERSEN','DISKON_NOMINAL','PRODUK_GRATIS','NILAI_VOUCHER']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_promosi_jenis_hadiah_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_voucher_sls AS ENUM ('AKTIF','DIPAKAI','KADALUARSA','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_voucher_sls')
     IS DISTINCT FROM ARRAY['AKTIF','DIPAKAI','KADALUARSA','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 28-sls: enum_status_voucher_sls kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 2) MASTER modul SLS — grup pelanggan, pelanggan, pricelist (+ LINE aturan)
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist; -- dipakai EXCLUDE overlap periode pricelist (F02)

-- [MASTER] sls_grup_pelanggan — segmentasi pelanggan untuk basis pricelist GRUP
--   (PP-02) dan pelaporan; kode reusable setelah soft-delete (uq partial).
CREATE TABLE IF NOT EXISTS sls_grup_pelanggan (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,           -- kode grup, reusable pasca soft-delete
  nama        varchar(100) NOT NULL,
  keterangan  varchar(200),
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_sls_grup_pelanggan_entity_id UNIQUE (entity_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_grup_pelanggan_kode
  ON sls_grup_pelanggan (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_grup_pelanggan_nama
  ON sls_grup_pelanggan (nama) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_grup_pelanggan IS
  '[MASTER] grup pelanggan (PP-02) — segmen untuk pricelist basis GRUP'
  ' (enum_basis_pricelist_sls) dan pelaporan penjualan.';

-- [MASTER] sls_pelanggan — mitra pelanggan (dipakai lintas modul: SO SLS,
--   setoran POS PP-03, kartu poin POS). Kode PLG GLOBAL tanpa filter
--   deleted_at — numbering core_sequences 'sales_customer' (K-10: kode tak
--   pernah dipakai ulang). kode_termin transitional A-06 tanpa FK (pola PUR).
CREATE TABLE IF NOT EXISTS sls_pelanggan (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                varchar(50) NOT NULL,   -- numbering PLG-{yyyy} — unique GLOBAL (K-10)
  nama                varchar(200) NOT NULL,
  id_sls_grup_pelanggan bigint,                -- segmen opsional (pricelist GRUP)
  telepon             varchar(50),
  email               varchar(150),
  alamat_tagih        varchar(300),            -- dasar faktur ACC (kontrak tanpa FK)
  alamat_kirim        varchar(300),            -- default alamat kirim SO/pemenuhan
  kode_termin         varchar(50),             -- transitional A-06 — tanpa FK sampai termin pemilik ACC live
  limit_kredit        numeric(18,4) NOT NULL DEFAULT 0, -- dipakai CFG-SLS-09 (IZINKAN_PERINGATAN/BLOKIR_KONFIRMASI)
  id_sls_pricelist    bigint,                  -- pricelist pribadi — FK oleh ALTER §5 (circular dgn sls_pricelist)
  status              enum_status_pelanggan_sls NOT NULL DEFAULT 'PROSPEK',
  alasan_blokir       varchar(300),            -- terisi bila DIBLOKIR (limit kredit / keputusan)
  catatan             varchar(200),
  version             integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_sls_pelanggan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_pelanggan_kode UNIQUE (kode), -- GLOBAL tanpa deleted_at (K-10)
  CONSTRAINT fk_sls_pelanggan_grup FOREIGN KEY (id_sls_grup_pelanggan)
    REFERENCES sls_grup_pelanggan (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_sls_pelanggan_nama
  ON sls_pelanggan (nama) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pelanggan_grup
  ON sls_pelanggan (id_sls_grup_pelanggan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pelanggan_status
  ON sls_pelanggan (status) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_pelanggan IS
  '[MASTER] pelanggan (PP-01/PP-02) — dirujuk SO SLS, setoran FK pos_pesanan &'
  ' pos_kartu_poin (PP-03); kode PLG global tak dipakai ulang (K-10).';
COMMENT ON COLUMN sls_pelanggan.kode_termin IS
  'transitional A-06 — rujukan termin pembayaran tanpa FK; FK oleh patch pemilik termin (pola PUR).';

-- [MASTER] sls_pricelist — daftar harga berperiode per segmen (F02): UMUM /
--   GRUP / PELANGGAN; dua pricelist AKTIF segmen+periode identik DILARANG
--   (EXCLUDE gist §bawah); dalam satu pricelist urutan kemenangan aturan
--   ditentukan min_qty & prioritas (SLS-BR06/Odoo).
CREATE TABLE IF NOT EXISTS sls_pricelist (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL, -- kode pricelist, reusable pasca soft-delete
  nama                   varchar(100) NOT NULL,
  mata_uang              varchar(3) NOT NULL DEFAULT 'IDR',
  periode_mulai          date NOT NULL,
  periode_selesai        date NOT NULL,
  basis                  enum_basis_pricelist_sls NOT NULL DEFAULT 'UMUM',
  id_sls_pelanggan       bigint,               -- wajib bila basis='PELANGGAN' (ck_basis)
  id_sls_grup_pelanggan  bigint,               -- wajib bila basis='GRUP' (ck_basis)
  prioritas              integer NOT NULL DEFAULT 0, -- pemutus bila dua pricelist segmen berbeda bersinggungan
  status                 enum_status_pricelist_sls NOT NULL DEFAULT 'DRAFT',
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_sls_pricelist_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_pricelist_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_pricelist_grup FOREIGN KEY (id_sls_grup_pelanggan)
    REFERENCES sls_grup_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_pricelist_periode
    CHECK (periode_selesai >= periode_mulai),
  CONSTRAINT ck_sls_pricelist_basis CHECK (
    (basis = 'PELANGGAN' AND id_sls_pelanggan IS NOT NULL AND id_sls_grup_pelanggan IS NULL)
    OR (basis = 'GRUP' AND id_sls_grup_pelanggan IS NOT NULL AND id_sls_pelanggan IS NULL)
    OR (basis = 'UMUM' AND id_sls_pelanggan IS NULL AND id_sls_grup_pelanggan IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_pricelist_kode
  ON sls_pricelist (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pricelist_status
  ON sls_pricelist (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pricelist_periode
  ON sls_pricelist (periode_mulai, periode_selesai) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_pricelist IS
  '[MASTER] pricelist penjualan (PP-04, F02) — berperiode per segmen UMUM/GRUP/'
  'PELANGGAN; overlap periode pricelist AKTIF segmen sama ditegakkan DB (EXCLUDE gist).';

-- Dua pricelist AKTIF segmen (pelanggan/grup/umum) + periode identik dilarang
-- (F02) — DB-side; sengaja tidak diekspresikan di mirror Drizzle (constraint
-- eksklusif PG). COALESCE menyetarakan NULL segmen utk pembanding gist.
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ex_sls_pricelist_overlap') THEN
    ALTER TABLE sls_pricelist ADD CONSTRAINT ex_sls_pricelist_overlap
      EXCLUDE USING gist (
        daterange(periode_mulai, periode_selesai, '[]') WITH &&,
        COALESCE(id_sls_pelanggan, 0)      WITH =,
        COALESCE(id_sls_grup_pelanggan, 0) WITH =
      ) WHERE (status = 'AKTIF' AND deleted_at IS NULL);
  END IF;
END $$;
-- +goose StatementEnd


-- [LINE] sls_pricelist_aturan — aturan harga per target SEMUA/KATEGORI/PRODUK;
--   HARGA_TETAP xor DISKON_PERSEN (SLS-BR06); kemenangan baris: min_qty terbesar
--   yang terpenuhi lalu prioritas (SLS-BR06/Odoo).
CREATE TABLE IF NOT EXISTS sls_pricelist_aturan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_pricelist       bigint NOT NULL,
  jenis_target           enum_jenis_target_aturan_sls NOT NULL DEFAULT 'SEMUA',
  id_inv_produk          bigint,               -- wajib bila jenis_target='PRODUK' (ck_target)
  id_inv_kategori_produk bigint,               -- wajib bila jenis_target='KATEGORI' (ck_target)
  min_qty                integer NOT NULL DEFAULT 1,
  jenis_aturan           enum_jenis_aturan_harga_sls NOT NULL DEFAULT 'HARGA_TETAP',
  harga_tetap            numeric(18,4),        -- wajib bila HARGA_TETAP (ck_nilai)
  diskon_persen          numeric(5,2),         -- wajib bila DISKON_PERSEN (ck_nilai)
  prioritas              integer NOT NULL DEFAULT 0,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_sls_pricelist_aturan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_pricelist_aturan_pricelist FOREIGN KEY (id_sls_pricelist)
    REFERENCES sls_pricelist (id) ON DELETE CASCADE,
  CONSTRAINT fk_sls_pricelist_aturan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_pricelist_aturan_kategori FOREIGN KEY (id_inv_kategori_produk)
    REFERENCES inv_kategori_produk (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_pricelist_aturan_min_qty CHECK (min_qty >= 1),
  CONSTRAINT ck_sls_pricelist_aturan_target CHECK (
    (jenis_target = 'PRODUK' AND id_inv_produk IS NOT NULL AND id_inv_kategori_produk IS NULL)
    OR (jenis_target = 'KATEGORI' AND id_inv_kategori_produk IS NOT NULL AND id_inv_produk IS NULL)
    OR (jenis_target = 'SEMUA' AND id_inv_produk IS NULL AND id_inv_kategori_produk IS NULL)
  ),
  CONSTRAINT ck_sls_pricelist_aturan_diskon
    CHECK (diskon_persen IS NULL OR (diskon_persen >= 0 AND diskon_persen <= 100)),
  CONSTRAINT ck_sls_pricelist_aturan_nilai CHECK (
    (jenis_aturan = 'HARGA_TETAP' AND harga_tetap IS NOT NULL AND diskon_persen IS NULL)
    OR (jenis_aturan = 'DISKON_PERSEN' AND diskon_persen IS NOT NULL AND harga_tetap IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_pricelist_aturan_produk
  ON sls_pricelist_aturan (id_sls_pricelist, id_inv_produk, min_qty)
  WHERE id_inv_produk IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_pricelist_aturan_kategori
  ON sls_pricelist_aturan (id_sls_pricelist, id_inv_kategori_produk, min_qty)
  WHERE id_inv_kategori_produk IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pricelist_aturan_pricelist
  ON sls_pricelist_aturan (id_sls_pricelist) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 3) TRANSAKSI modul SLS — penawaran (+ items), pesanan (+ items), amendment,
--    retur (+ items)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] sls_penawaran — penawaran harga (KUO, F03); lifecycle DRAFT→
--   TERKIRIM→DITERIMA→TERKONVERSI (tanggal_konversi) / KADALUARSA (oleh
--   penjadwal via kadaluarsa_at) / DIBATALKAN wajib alasan; konversi ke SO
--   satu-satu (uq_sls_so_penawaran di sls_pesanan_penjualan); jejak pengirim
--   via core_audit_trail (STD-01).
CREATE TABLE IF NOT EXISTS sls_penawaran (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor             varchar(150) NOT NULL,     -- numbering QT-{yyyy} (core_sequences 'quotation' — legacy kontinu) — unique global
  tanggal           date NOT NULL DEFAULT CURRENT_DATE,
  berlaku_hingga    date NOT NULL,             -- dasar penjadwal KADALUARSA (ck_berlaku)
  id_sls_pelanggan  bigint NOT NULL,
  id_core_users_staf bigint,                   -- sales pemilik penawaran (SET NULL bila user terhapus)
  id_sls_pricelist  bigint,                    -- pricelist acuan saat terbit (SLS-BR06)
  status            enum_status_penawaran_sls NOT NULL DEFAULT 'DRAFT',
  nilai_subtotal    numeric(18,4) NOT NULL DEFAULT 0,
  nilai_diskon      numeric(18,4) NOT NULL DEFAULT 0,
  nilai_pajak       numeric(18,4) NOT NULL DEFAULT 0,
  nilai_total       numeric(18,4) NOT NULL DEFAULT 0,
  catatan           varchar(200),
  tanggal_konversi  date,                      -- terisi saat TERKONVERSI → SO
  kadaluarsa_at     timestamptz,               -- ditandai penjadwal antrian (ix_berlaku_hingga)
  alasan_batal      varchar(300),              -- wajib bila DIBATALKAN (ck_batal)
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_sls_penawaran_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_penawaran_nomor UNIQUE (nomor),
  CONSTRAINT fk_sls_penawaran_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_penawaran_staf FOREIGN KEY (id_core_users_staf)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_sls_penawaran_pricelist FOREIGN KEY (id_sls_pricelist)
    REFERENCES sls_pricelist (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_penawaran_berlaku CHECK (berlaku_hingga >= tanggal),
  CONSTRAINT ck_sls_penawaran_batal
    CHECK (status <> 'DIBATALKAN' OR alasan_batal IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_sls_penawaran_pelanggan
  ON sls_penawaran (id_sls_pelanggan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_penawaran_status
  ON sls_penawaran (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_penawaran_berlaku_hingga
  ON sls_penawaran (berlaku_hingga) WHERE status IN ('DRAFT','TERKIRIM'); -- antrian penjadwal KADALUARSA
CREATE INDEX IF NOT EXISTS ix_sls_penawaran_staf
  ON sls_penawaran (id_core_users_staf) WHERE deleted_at IS NULL;

-- [LINE] sls_penawaran_items — snapshot produk/satuan/harga saat terbit (beku);
--   harga_dasar = snapshot cost utk margin (F15); pajak_persen snapshot skema
--   pajak CFG-PLT-04 (pajak tidak dihitung SLS — A-02).
CREATE TABLE IF NOT EXISTS sls_penawaran_items (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_penawaran bigint NOT NULL,
  id_inv_produk    bigint NOT NULL,
  kode_produk      varchar(50) NOT NULL,      -- snapshot master INV
  nama_produk      varchar(200) NOT NULL,     -- snapshot master INV
  id_inv_unit_ukur bigint NOT NULL,
  satuan           varchar(50) NOT NULL,      -- snapshot nama satuan
  qty              integer NOT NULL,
  harga_satuan     numeric(18,4) NOT NULL,    -- hasil pemilihan pricelist (SLS-BR06)
  harga_dasar      numeric(18,4) NOT NULL DEFAULT 0, -- snapshot cost — margin F15
  diskon_persen    numeric(5,2) NOT NULL DEFAULT 0,
  pajak_persen     numeric(5,2) NOT NULL DEFAULT 0,  -- snapshot skema pajak CFG-PLT-04
  nilai_baris      numeric(18,4) NOT NULL DEFAULT 0,
  catatan          varchar(200),
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_sls_penawaran_items_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_penawaran_items_penawaran FOREIGN KEY (id_sls_penawaran)
    REFERENCES sls_penawaran (id) ON DELETE CASCADE,
  CONSTRAINT fk_sls_penawaran_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_penawaran_items_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_penawaran_items_qty CHECK (qty > 0),
  CONSTRAINT ck_sls_penawaran_items_diskon
    CHECK (diskon_persen >= 0 AND diskon_persen <= 100),
  CONSTRAINT ck_sls_penawaran_items_pajak
    CHECK (pajak_persen >= 0 AND pajak_persen <= 100)
);

CREATE INDEX IF NOT EXISTS ix_sls_penawaran_items_penawaran
  ON sls_penawaran_items (id_sls_penawaran) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_penawaran_items_produk
  ON sls_penawaran_items (id_inv_produk) WHERE deleted_at IS NULL;

-- [TRANSAKSI] sls_pesanan_penjualan — Sales Order inti (F04/F06, PP-05): satu
--   dimensi lifecycle (status) + tiga trek pelengkap terpisah (status_
--   persetujuan CFG-SLS-02/03, status_pemenuhan dari M02, status_faktur dari
--   kontrak balik M07). Idempotensi order web M14 via uq_sls_so_sumber
--   (SLS-BR11); satu SO maksimal per penawaran (uq_sls_so_penawaran);
--   nilai_terfaktur & nilai_uang_muka denormalisasi hasil kontrak balik M07
--   (SLS-BR09/BR13 — faktur DP tidak menutup dasar). Aktor transisi via
--   core_audit_trail (STD-01).
CREATE TABLE IF NOT EXISTS sls_pesanan_penjualan (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                    varchar(150) NOT NULL, -- numbering SO-{yyyy} (core_sequences 'order' — legacy kontinu counter) — unique global
  tanggal                  date NOT NULL DEFAULT CURRENT_DATE,
  tanggal_kirim_diharapkan date,                 -- komitmen kirim (Odoo commitment date)
  id_sls_pelanggan         bigint NOT NULL,
  id_core_users_staf       bigint,               -- sales pemilik SO
  id_sls_penawaran         bigint,               -- sumber konversi KUO — FK oleh ALTER §5 (urutan seksi)
  kanal                    enum_kanal_so_sls NOT NULL DEFAULT 'MANUAL',
  jenis_sumber             enum_jenis_sumber_so_sls NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber         varchar(255),         -- web_order_id — idempotensi M14 (uq_sls_so_sumber, SLS-BR11)
  id_inv_gudang            bigint,               -- gudang kirim; NULL sah utk SO baris JASA saja (SLS-BR07)
  id_sls_pricelist         bigint,               -- pricelist acuan harga (SLS-BR06)
  status                   enum_status_so_sls NOT NULL DEFAULT 'DRAFT',
  status_persetujuan       enum_status_persetujuan_sls, -- terisi bila CFG-SLS-02 ≠ TANPA_APPROVAL
  level_persetujuan        integer NOT NULL DEFAULT 0,  -- level rantai saat ini (CFG-SLS-03)
  alasan_penolakan         varchar(300),         -- wajib bila DITOLAK (ck_tolak)
  status_pemenuhan         enum_status_pemenuhan_sls NOT NULL DEFAULT 'BELUM_DIJADWALKAN', -- dari M02
  status_faktur            enum_status_faktur_sls NOT NULL DEFAULT 'BELUM_DIFAKTUR',       -- dari kontrak balik M07
  nilai_subtotal           numeric(18,4) NOT NULL DEFAULT 0,
  nilai_diskon             numeric(18,4) NOT NULL DEFAULT 0,
  nilai_pajak              numeric(18,4) NOT NULL DEFAULT 0,
  nilai_total              numeric(18,4) NOT NULL DEFAULT 0,
  nilai_terfaktur          numeric(18,4) NOT NULL DEFAULT 0, -- denormalisasi — recompute dari M07 (SLS-BR09/BR13)
  nilai_uang_muka          numeric(18,4) NOT NULL DEFAULT 0, -- denormalisasi — faktur DP tak menutup dasar (SLS-BR13)
  alasan_batal             varchar(300),         -- wajib bila DIBATALKAN (ck_batal)
  terkonfirmasi_at         timestamptz,          -- jejak DRAFT→TERKONFIRMASI (M01 terkirim)
  ditutup_at               timestamptz,          -- jejak SELESAI (pemenuhan+faktur tuntas)
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_sls_pesanan_penjualan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_pesanan_penjualan_nomor UNIQUE (nomor),
  CONSTRAINT fk_sls_pesanan_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_pesanan_staf FOREIGN KEY (id_core_users_staf)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_sls_pesanan_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_pesanan_pricelist FOREIGN KEY (id_sls_pricelist)
    REFERENCES sls_pricelist (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_pesanan_penjualan_tolak
    CHECK (status_persetujuan <> 'DITOLAK' OR alasan_penolakan IS NOT NULL),
  CONSTRAINT ck_sls_pesanan_penjualan_batal
    CHECK (status <> 'DIBATALKAN' OR alasan_batal IS NOT NULL),
  CONSTRAINT ck_sls_pesanan_penjualan_dp
    CHECK (nilai_uang_muka >= 0 AND nilai_uang_muka <= nilai_total) -- SLS-BR13: DP tak melebihi nilai SO
);

-- Idempotensi order web M14: satu web_order_id hanya boleh menghasilkan satu SO
-- (SLS-BR11); baris failed retry aman — duplikat ditolak DB.
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_so_sumber
  ON sls_pesanan_penjualan (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL;
-- Satu SO maksimal per penawaran (konversi KUO satu-satu).
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_so_penawaran
  ON sls_pesanan_penjualan (id_sls_penawaran)
  WHERE id_sls_penawaran IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_pelanggan
  ON sls_pesanan_penjualan (id_sls_pelanggan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_staf
  ON sls_pesanan_penjualan (id_core_users_staf) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_status
  ON sls_pesanan_penjualan (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_antrian_approval
  ON sls_pesanan_penjualan (status_persetujuan, level_persetujuan)
  WHERE status = 'MENUNGGU_APPROVAL' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_antrian_faktur
  ON sls_pesanan_penjualan (status_faktur)
  WHERE status = 'TERKONFIRMASI' AND status_faktur <> 'FAKTUR_PENUH' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_kanal
  ON sls_pesanan_penjualan (kanal) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_tanggal
  ON sls_pesanan_penjualan (tanggal) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_pesanan_penjualan IS
  '[TRANSAKSI inti] Sales Order (PP-05) — status lifecycle + trek persetujuan/'
  'pemenuhan/faktur terpisah; sumber outbox M01/M07/M24; idempoten M14 & konversi'
  ' KUO via uq partial; gudang NULL hanya utk SO JASA (SLS-BR07).';
COMMENT ON COLUMN sls_pesanan_penjualan.entity_id_sumber IS
  'web_order_id sumber order web — unik per jenis_sumber (uq_sls_so_sumber, M14/SLS-BR11).';

-- [LINE] sls_pesanan_items — baris SO; snapshot harga/deskripsi/satuan (beku);
--   qty_terkirim = akumulasi event picking M02 arah KIRIM; qty_diretur =
--   akumulasi picking balik M02 arah KEMBALI (≤ qty_terkirim — SLS-BR14);
--   qty terkirim EFEKTIF = qty_terkirim − qty_diretur (derived, tidak
--   disimpan); qty_terfaktur = akumulasi kontrak balik M07 (≤ dasar CFG-
--   SLS-07 dijaga app layer — SLS-BR09); baris JASA tak pernah terkirim/
--   diretur (SLS-BR07) dan tak mengikat gudang.
CREATE TABLE IF NOT EXISTS sls_pesanan_items (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_pesanan_penjualan bigint NOT NULL,
  id_inv_produk           bigint NOT NULL,
  jenis_baris             enum_jenis_baris_sls NOT NULL DEFAULT 'BARANG',
  kode_produk             varchar(50) NOT NULL, -- snapshot master INV
  nama_produk             varchar(200) NOT NULL, -- snapshot master INV
  id_inv_unit_ukur        bigint NOT NULL,
  satuan                  varchar(50) NOT NULL, -- snapshot nama satuan
  qty_dipesan             integer NOT NULL,
  qty_terkirim            integer NOT NULL DEFAULT 0, -- akumulasi M02 (denormalisasi)
  qty_diretur             integer NOT NULL DEFAULT 0, -- ≤ qty_terkirim (ck_retur_le, SLS-BR14)
  qty_terfaktur           integer NOT NULL DEFAULT 0, -- akumulasi M07 (denormalisasi)
  harga_dasar             numeric(18,4) NOT NULL DEFAULT 0, -- snapshot cost — margin F15
  harga_satuan            numeric(18,4) NOT NULL,
  diskon_persen           numeric(5,2) NOT NULL DEFAULT 0,
  pajak_persen            numeric(5,2) NOT NULL DEFAULT 0, -- snapshot skema pajak CFG-PLT-04
  nilai_baris             numeric(18,4) NOT NULL DEFAULT 0,
  catatan                 varchar(200),
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_sls_pesanan_items_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_pesanan_items_pesanan FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE CASCADE,
  CONSTRAINT fk_sls_pesanan_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_pesanan_items_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_pesanan_items_qty CHECK (qty_dipesan > 0),
  CONSTRAINT ck_sls_pesanan_items_akumulasi CHECK (
    qty_terkirim >= 0 AND qty_diretur >= 0 AND qty_terfaktur >= 0
  ),
  CONSTRAINT ck_sls_pesanan_items_retur_le
    CHECK (qty_diretur <= qty_terkirim), -- SLS-BR14
  CONSTRAINT ck_sls_pesanan_items_jasa
    CHECK (jenis_baris <> 'JASA' OR (qty_terkirim = 0 AND qty_diretur = 0)), -- SLS-BR07
  CONSTRAINT ck_sls_pesanan_items_diskon
    CHECK (diskon_persen >= 0 AND diskon_persen <= 100),
  CONSTRAINT ck_sls_pesanan_items_pajak
    CHECK (pajak_persen >= 0 AND pajak_persen <= 100)
);

CREATE INDEX IF NOT EXISTS ix_sls_pesanan_items_pesanan
  ON sls_pesanan_items (id_sls_pesanan_penjualan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_items_produk
  ON sls_pesanan_items (id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_pesanan_items_jasa
  ON sls_pesanan_items (jenis_baris) WHERE jenis_baris = 'JASA';

-- [TRANSAKSI kecil] sls_amendment_pesanan — usulan perubahan SO pasca-
--   TERKONFIRMASI (M24): payload jsonb = snapshot proposal perubahan, dibaca
--   utuh (tidak di-join/difilter); DITOLAK wajib alasan; pengaju ≠ pemutus
--   (SoD — dua kolom aktor terpisah).
CREATE TABLE IF NOT EXISTS sls_amendment_pesanan (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_pesanan_penjualan bigint NOT NULL,
  id_core_users_pengaju    bigint,
  alasan                   varchar(300) NOT NULL,
  payload                  jsonb NOT NULL DEFAULT '{}', -- snapshot proposal — dibaca utuh, tidak di-join
  status                   enum_status_persetujuan_sls NOT NULL DEFAULT 'DIAJUKAN',
  id_core_users_pemutus    bigint,
  alasan_keputusan         varchar(300),         -- wajib bila DITOLAK (ck_tolak)
  diputuskan_at            timestamptz,
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_sls_amendment_pesanan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_amendment_pesanan_pesanan FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_amendment_pesanan_pengaju FOREIGN KEY (id_core_users_pengaju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_sls_amendment_pesanan_pemutus FOREIGN KEY (id_core_users_pemutus)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_sls_amendment_pesanan_tolak
    CHECK (status <> 'DITOLAK' OR alasan_keputusan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_sls_amendment_pesanan_pesanan
  ON sls_amendment_pesanan (id_sls_pesanan_penjualan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_amendment_pesanan_status
  ON sls_amendment_pesanan (status) WHERE status = 'DIAJUKAN'; -- antrian approval M24

-- [TRANSAKSI] sls_retur_penjualan — retur penjualan (RTJ): usulan atas baris
--   qty_terkirim − qty_diretur; entity_id = retur_id idempotensi M39/M40.
--   DISETUJUI wajib sudah memicu M39 (pemicu_gerakan_at); M40 (nota kredit)
--   hanya boleh terkirim dgn invoice_ref faktur POSTED di ACC (SLS-BR14);
--   status inti SO tidak berubah ("SO SELESAI tetap SELESAI").
CREATE TABLE IF NOT EXISTS sls_retur_penjualan (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(), -- retur_id — idempotensi M39/M40
  nomor                    varchar(150) NOT NULL, -- numbering RT-{yyyy} (core_sequences 'return' — legacy kontinu counter) — unique global
  id_sls_pesanan_penjualan bigint NOT NULL,
  id_core_users_pengaju    bigint,
  id_core_users_disetujui  bigint,
  disetujui_at             timestamptz,
  alasan                   varchar(300) NOT NULL, -- cacat/rusak/kelebihan kirim/batal sebagian
  invoice_ref              varchar(150),          -- nomor faktur POSTED ACC — syarat M40 (ck_kredit, SLS-BR14)
  status                   enum_status_retur_sls NOT NULL DEFAULT 'DIAJUKAN',
  alasan_keputusan         varchar(300),          -- wajib bila DITOLAK (ck_tolak)
  pemicu_gerakan_at        timestamptz,           -- M39 (gerakan masuk INV) terkirim
  pemicu_kredit_at         timestamptz,           -- M40 (nota kredit) terkirim — wajib invoice_ref (ck_kredit)
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_sls_retur_penjualan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_retur_penjualan_nomor UNIQUE (nomor),
  CONSTRAINT fk_sls_retur_pesanan FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_retur_pengaju FOREIGN KEY (id_core_users_pengaju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_sls_retur_disetujui FOREIGN KEY (id_core_users_disetujui)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_sls_retur_penjualan_tolak
    CHECK (status <> 'DITOLAK' OR alasan_keputusan IS NOT NULL),
  CONSTRAINT ck_sls_retur_penjualan_kredit
    CHECK (pemicu_kredit_at IS NULL OR invoice_ref IS NOT NULL), -- SLS-BR14
  CONSTRAINT ck_sls_retur_penjualan_gerakan
    CHECK (status NOT IN ('DISETUJUI','SELESAI') OR pemicu_gerakan_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_sls_retur_pesanan
  ON sls_retur_penjualan (id_sls_pesanan_penjualan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_retur_status
  ON sls_retur_penjualan (status) WHERE status = 'DIAJUKAN'; -- antrian approval retur

-- [LINE] sls_retur_items — baris retur per baris SO asal; qty > 0; satu baris
--   SO maksimal satu baris retur per dokumen (uq pasangan partial); mutasi
--   qty_diretur baris SO terjadi saat picking balik divalidasi INV (M02 arah
--   KEMBALI), bukan saat retur dibuat/disetujui (SLS-BR14).
CREATE TABLE IF NOT EXISTS sls_retur_items (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_retur_penjualan bigint NOT NULL,
  id_sls_pesanan_items bigint NOT NULL,          -- baris SO asal
  id_inv_produk        bigint NOT NULL,
  qty_retur            integer NOT NULL,
  nama_produk          varchar(200) NOT NULL,    -- snapshot baris SO saat retur dibuat
  alasan               varchar(300),
  version              integer NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_sls_retur_items_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_retur_items_retur FOREIGN KEY (id_sls_retur_penjualan)
    REFERENCES sls_retur_penjualan (id) ON DELETE CASCADE,
  CONSTRAINT fk_sls_retur_items_pesanan_item FOREIGN KEY (id_sls_pesanan_items)
    REFERENCES sls_pesanan_items (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_retur_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_retur_items_qty CHECK (qty_retur > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_retur_items_pasangan
  ON sls_retur_items (id_sls_retur_penjualan, id_sls_pesanan_items)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_retur_items_produk
  ON sls_retur_items (id_inv_produk) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4) LOG/EVENT — sls_pemenuhan_event append-only (M02 dari INV)
-- -----------------------------------------------------------------------------
-- [LOG/EVENT] sls_pemenuhan_event — jejak event picking INV per SO (M02),
--   append-only: picking_ref unique GLOBAL = idempotensi per picking_id (event
--   retry/duplikat INV ditolak DB); arah KIRIM/KEMBALI (picking balik utk
--   retur M39); qty_detail jsonb = snapshot qty per baris, dibaca utuh.
--   updated_at BEKU (tanpa trigger), deleted_at selalu NULL, tanpa version.
CREATE TABLE IF NOT EXISTS sls_pemenuhan_event (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  picking_ref              varchar(150) NOT NULL, -- picking_id INV — unique GLOBAL (idempotensi M02)
  id_sls_pesanan_penjualan bigint NOT NULL,
  arah                     enum_arah_pemenuhan_sls NOT NULL DEFAULT 'KIRIM',
  status_picking           varchar(50) NOT NULL,  -- kosakata sisi INV (pemilik INV)
  qty_detail               jsonb NOT NULL DEFAULT '{}', -- snapshot qty per baris — payload event, tidak di-join
  diterima_at              timestamptz NOT NULL DEFAULT now(),
  catatan                  varchar(200),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(), -- beku (append-only — tanpa trigger)
  deleted_at               timestamptz,            -- selalu NULL (append-only)
  CONSTRAINT uq_sls_pemenuhan_event_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_pemenuhan_event_picking_ref UNIQUE (picking_ref),
  CONSTRAINT fk_sls_pemenuhan_event_pesanan FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_sls_pemenuhan_event_pesanan
  ON sls_pemenuhan_event (id_sls_pesanan_penjualan, diterima_at);

COMMENT ON TABLE sls_pemenuhan_event IS
  '[LOG/EVENT append-only] pemenuhan fisik SO via M02 (PP-07) — per picking_id;'
  ' updated_at beku & deleted_at selalu NULL; agregasi qty_terkirim baris SO.';
COMMENT ON COLUMN sls_pemenuhan_event.qty_detail IS
  'snapshot qty per baris (payload event M02) — dibaca utuh, tidak di-join/difilter.';

-- -----------------------------------------------------------------------------
-- 4b) ENGINE PROMOSI — program, kanal, aturan syarat/hadiah, voucher,
--     pemakaian (PP-19…PP-24; keputusan 2026-11-06 menimpa A-08 analisa v4;
--     adaptasi POS/ECOM junction = tahap selanjutnya, T-07)
-- -----------------------------------------------------------------------------
-- [MASTER berlifecycle] sls_promosi — program promosi (PP-19): PROMO/KUPON/
--   VOUCHER/BUNDLE; eligibility kanal via sls_promosi_kanal (kosong = semua
--   kanal); syarat/hadiah via sls_promosi_aturan; pemakaian tercatat di
--   ledger sls_promosi_pemakaian. Kode manual, reusable pasca soft-delete
--   (uq partial).
CREATE TABLE IF NOT EXISTS sls_promosi (
  id                            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                     uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                          varchar(50) NOT NULL,  -- kode manual — reusable pasca soft-delete (uq partial)
  nama                          varchar(100) NOT NULL,
  jenis                         enum_jenis_promosi_sls NOT NULL DEFAULT 'PROMO',
  periode_mulai                 date NOT NULL DEFAULT CURRENT_DATE,
  periode_selesai               date NOT NULL,
  syarat_min_belanja            numeric(18,4),          -- NULL = tanpa syarat nominal
  syarat_min_qty                integer,                -- NULL = tanpa syarat qty
  batas_pemakaian_per_pelanggan integer,                -- NULL = tanpa batas per pelanggan
  batas_total                   integer,                -- NULL = tanpa batas total
  prioritas                     integer NOT NULL DEFAULT 0, -- urutan penilaian program sekaligus (PP-24)
  eksklusif                     boolean NOT NULL DEFAULT false, -- bila terpilih: program lain berhenti (app layer + CFG-SLS-13)
  status                        enum_status_promosi_sls NOT NULL DEFAULT 'DRAFT',
  keterangan                    varchar(200),
  version                       integer NOT NULL DEFAULT 1,
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),
  deleted_at                    timestamptz,
  CONSTRAINT uq_sls_promosi_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_sls_promosi_periode CHECK (periode_selesai >= periode_mulai),
  CONSTRAINT ck_sls_promosi_batas CHECK (
    (batas_pemakaian_per_pelanggan IS NULL OR batas_pemakaian_per_pelanggan >= 1)
    AND (batas_total IS NULL OR batas_total >= 1)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_promosi_kode
  ON sls_promosi (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_status
  ON sls_promosi (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_periode
  ON sls_promosi (periode_mulai, periode_selesai) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_promosi IS
  '[MASTER berlifecycle] program promosi (PP-19) — PROMO/KUPON/VOUCHER/BUNDLE;'
  ' eligibility kanal via sls_promosi_kanal (kosong = semua kanal); syarat/'
  'hadiah via sls_promosi_aturan; pemakaian via ledger sls_promosi_pemakaian.';

-- [JUNCTION murni] sls_promosi_kanal — eligibility kanal program (PP-21):
--   TANPA entity_id & TANPA version (precedent core_users_roles); baris tidak
--   ada = SEMUA kanal (pola POS PP-13); junction lintas-modul ke POS/ECOM =
--   tahap selanjutnya (T-07).
CREATE TABLE IF NOT EXISTS sls_promosi_kanal (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_sls_promosi bigint NOT NULL,
  kanal          enum_kanal_so_sls NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_sls_promosi_kanal_pasangan UNIQUE (id_sls_promosi, kanal),
  CONSTRAINT fk_sls_promosi_kanal_promosi FOREIGN KEY (id_sls_promosi)
    REFERENCES sls_promosi (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_sls_promosi_kanal_promosi
  ON sls_promosi_kanal (id_sls_promosi) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_promosi_kanal IS
  '[JUNCTION murni] eligibility kanal program (PP-21) — kosong = SEMUA kanal'
  ' (pola POS PP-13); junction lintas-modul ke POS/ECOM = tahap selanjutnya (T-07).';

-- [LINE] sls_promosi_aturan — aturan syarat/hadiah per program (PP-22); satu
--   baris = satu peran (SYARAT atau HADIAH — ck_peran); target SEMUA/
--   KATEGORI/PRODUK reuse enum aturan pricelist (K-07); hadiah PRODUK_GRATIS
--   wajib target produk (produk gratis = id_inv_produk baris ini).
CREATE TABLE IF NOT EXISTS sls_promosi_aturan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_promosi         bigint NOT NULL,
  peran                  enum_promosi_peran_sls NOT NULL DEFAULT 'SYARAT',
  jenis_target           enum_jenis_target_aturan_sls NOT NULL DEFAULT 'SEMUA', -- reuse enum aturan pricelist (K-07)
  id_inv_produk          bigint,               -- wajib bila jenis_target='PRODUK' (ck_target)
  id_inv_kategori_produk bigint,               -- wajib bila jenis_target='KATEGORI' (ck_target)
  min_qty                integer,              -- SYARAT — ambang qty target
  min_nilai              numeric(18,4),        -- SYARAT — ambang nilai belanja target
  jenis_hadiah           enum_promosi_jenis_hadiah_sls, -- HADIAH — wajib bila peran='HADIAH' (ck_peran)
  nilai_persen           numeric(5,2),         -- HADIAH DISKON_PERSEN
  nilai_nominal          numeric(18,4),        -- HADIAH DISKON_NOMINAL / NILAI_VOUCHER
  qty_gratis             integer,              -- HADIAH PRODUK_GRATIS (produk = id_inv_produk baris ini)
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_sls_promosi_aturan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_promosi_aturan_promosi FOREIGN KEY (id_sls_promosi)
    REFERENCES sls_promosi (id) ON DELETE CASCADE,
  CONSTRAINT fk_sls_promosi_aturan_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_promosi_aturan_kategori FOREIGN KEY (id_inv_kategori_produk)
    REFERENCES inv_kategori_produk (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_promosi_aturan_target CHECK (
    (jenis_target = 'PRODUK' AND id_inv_produk IS NOT NULL AND id_inv_kategori_produk IS NULL)
    OR (jenis_target = 'KATEGORI' AND id_inv_kategori_produk IS NOT NULL AND id_inv_produk IS NULL)
    OR (jenis_target = 'SEMUA' AND id_inv_produk IS NULL AND id_inv_kategori_produk IS NULL)
  ),
  CONSTRAINT ck_sls_promosi_aturan_peran CHECK (
    (peran = 'SYARAT' AND jenis_hadiah IS NULL AND nilai_persen IS NULL
      AND nilai_nominal IS NULL AND qty_gratis IS NULL)
    OR (peran = 'HADIAH' AND jenis_hadiah IS NOT NULL AND (
      (jenis_hadiah = 'DISKON_PERSEN'    AND nilai_persen  IS NOT NULL
        AND nilai_nominal IS NULL AND qty_gratis IS NULL)
      OR (jenis_hadiah = 'DISKON_NOMINAL' AND nilai_nominal IS NOT NULL
        AND nilai_persen IS NULL AND qty_gratis IS NULL)
      OR (jenis_hadiah = 'PRODUK_GRATIS'  AND qty_gratis IS NOT NULL AND qty_gratis >= 1
        AND id_inv_produk IS NOT NULL AND nilai_persen IS NULL AND nilai_nominal IS NULL)
      OR (jenis_hadiah = 'NILAI_VOUCHER'  AND nilai_nominal IS NOT NULL
        AND nilai_persen IS NULL AND qty_gratis IS NULL)
    ))
  ),
  CONSTRAINT ck_sls_promosi_aturan_min CHECK (
    (min_qty IS NULL OR min_qty >= 1) AND (min_nilai IS NULL OR min_nilai >= 0)
  ),
  CONSTRAINT ck_sls_promosi_aturan_persen
    CHECK (nilai_persen IS NULL OR (nilai_persen >= 0 AND nilai_persen <= 100))
);

-- Satu program tak boleh punya dua baris aturan sama (target + peran + ambang)
-- — COALESCE menyetarakan NULL min_qty utk pembanding unik (pola uq pricelist_
-- aturan, K-07).
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_promosi_aturan_produk
  ON sls_promosi_aturan (id_sls_promosi, peran, id_inv_produk, COALESCE(min_qty, 0))
  WHERE id_inv_produk IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_promosi_aturan_kategori
  ON sls_promosi_aturan (id_sls_promosi, peran, id_inv_kategori_produk, COALESCE(min_qty, 0))
  WHERE id_inv_kategori_produk IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_aturan_promosi
  ON sls_promosi_aturan (id_sls_promosi) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_promosi_aturan IS
  '[LINE] aturan syarat/hadiah per program (PP-22) — satu baris satu peran'
  ' (SYARAT atau HADIAH); hadiah PRODUK_GRATIS wajib target produk (produk'
  ' gratis = id_inv_produk baris ini); jenis_target reuse enum pricelist (K-07).';

-- [TRANSAKSI] sls_voucher — instrumen kode promosi (PP-23): kode unik GLOBAL
--   tak dipakai ulang (K-10) — dibuat generator app/seed, bukan core_sequences;
--   personal bila id_sls_pelanggan terisi, publik bila NULL; nilai_persen/
--   nilai_nominal NULL = ikut hadiah program asal (ck_nilai: maks satu terisi).
CREATE TABLE IF NOT EXISTS sls_voucher (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,  -- kode unik GLOBAL tak dipakai ulang (K-10) — generator app/seed, bukan core_sequences
  id_sls_promosi       bigint NOT NULL,       -- program asal (KUPON/VOUCHER/BUNDLE)
  id_sls_pelanggan     bigint,                -- NULL = voucher publik; terisi = personal
  status               enum_status_voucher_sls NOT NULL DEFAULT 'AKTIF',
  masa_berlaku_mulai   date NOT NULL DEFAULT CURRENT_DATE,
  masa_berlaku_selesai date NOT NULL,
  batas_pakai          integer NOT NULL DEFAULT 1,
  nilai_persen         numeric(5,2),          -- NULL = ikut hadiah program
  nilai_nominal        numeric(18,4),         -- NULL = ikut hadiah program
  version              integer NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_sls_voucher_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_voucher_kode UNIQUE (kode), -- GLOBAL tanpa deleted_at (K-10)
  CONSTRAINT fk_sls_voucher_promosi FOREIGN KEY (id_sls_promosi)
    REFERENCES sls_promosi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_voucher_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON DELETE RESTRICT,
  CONSTRAINT ck_sls_voucher_periode CHECK (masa_berlaku_selesai >= masa_berlaku_mulai),
  CONSTRAINT ck_sls_voucher_batas CHECK (batas_pakai >= 1),
  CONSTRAINT ck_sls_voucher_persen
    CHECK (nilai_persen IS NULL OR (nilai_persen >= 0 AND nilai_persen <= 100)),
  CONSTRAINT ck_sls_voucher_nilai
    CHECK (nilai_persen IS NULL OR nilai_nominal IS NULL) -- maks satu terisi
);

CREATE INDEX IF NOT EXISTS ix_sls_voucher_promosi
  ON sls_voucher (id_sls_promosi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_voucher_status
  ON sls_voucher (status) WHERE status = 'AKTIF';
CREATE INDEX IF NOT EXISTS ix_sls_voucher_pelanggan
  ON sls_voucher (id_sls_pelanggan) WHERE id_sls_pelanggan IS NOT NULL;

COMMENT ON TABLE sls_voucher IS
  '[TRANSAKSI] instrumen kode promosi (PP-23) — kode unik GLOBAL tak dipakai'
  ' ulang (K-10, generator app/seed); personal bila id_sls_pelanggan terisi,'
  ' publik bila NULL; nilai sendiri opsional — NULL mengikuti hadiah program.';
COMMENT ON COLUMN sls_voucher.kode IS
  'kode voucher unik GLOBAL dan tak pernah dipakai ulang (K-10) — dibuat'
  ' generator app/seed, bukan core_sequences.';

-- [LOG/EVENT] sls_promosi_pemakaian — ledger pemakaian promosi per SO,
--   append-only (pola sls_pemenuhan_event/PP-15): nilai hadiah snapshot beku
--   saat pemakaian; detail jsonb = snapshot baris kena — dibaca utuh, tidak
--   di-join; TANPA version, updated_at beku (tanpa trigger), deleted_at
--   selalu NULL; satu program sekali per SO (uq pasangan — idempoten).
CREATE TABLE IF NOT EXISTS sls_promosi_pemakaian (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_promosi           bigint NOT NULL,
  id_sls_voucher           bigint,                  -- NULL utk PROMO otomatis tanpa kode
  id_sls_pesanan_penjualan bigint NOT NULL,
  kanal                    enum_kanal_so_sls NOT NULL DEFAULT 'MANUAL',
  jenis_hadiah             enum_promosi_jenis_hadiah_sls NOT NULL,
  nilai_persen             numeric(5,2),            -- snapshot beku saat pemakaian
  nilai_nominal            numeric(18,4),           -- snapshot beku saat pemakaian
  detail                   jsonb NOT NULL DEFAULT '{}', -- snapshot baris kena — dibaca utuh, tidak di-join (pola qty_detail)
  diterima_at              timestamptz NOT NULL DEFAULT now(),
  catatan                  varchar(200),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(), -- beku (append-only — tanpa trigger)
  deleted_at               timestamptz,             -- selalu NULL (append-only)
  CONSTRAINT uq_sls_promosi_pemakaian_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_sls_promosi_pemakaian_pasangan UNIQUE (id_sls_promosi, id_sls_pesanan_penjualan), -- satu program sekali per SO (idempoten)
  CONSTRAINT fk_sls_promosi_pemakaian_promosi FOREIGN KEY (id_sls_promosi)
    REFERENCES sls_promosi (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_promosi_pemakaian_voucher FOREIGN KEY (id_sls_voucher)
    REFERENCES sls_voucher (id) ON DELETE RESTRICT,
  CONSTRAINT fk_sls_promosi_pemakaian_pesanan FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_sls_promosi_pemakaian_promosi
  ON sls_promosi_pemakaian (id_sls_promosi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_pemakaian_voucher
  ON sls_promosi_pemakaian (id_sls_voucher) WHERE id_sls_voucher IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_sls_promosi_pemakaian_pesanan
  ON sls_promosi_pemakaian (id_sls_pesanan_penjualan) WHERE deleted_at IS NULL;

COMMENT ON TABLE sls_promosi_pemakaian IS
  '[LOG append-only] ledger pemakaian promosi per SO (PP-24) — nilai hadiah'
  ' snapshot beku; sumber rekonsiliasi nilai_diskon SO; updated_at beku &'
  ' deleted_at selalu NULL; satu program sekali per SO (idempoten).';
COMMENT ON COLUMN sls_promosi_pemakaian.detail IS
  'snapshot baris SO kena promosi (payload pemakaian) — dibaca utuh, tidak di-join/difilter.';

-- -----------------------------------------------------------------------------
-- 5) FK LINTAS — setoran ke tabel POS live (PP-03) + FK sesama SLS yang
--    sengaja ditunda §2–3 (circular / urutan seksi); semua dibungkus guard
--    pg_constraint (pola 25-purchasing).
-- -----------------------------------------------------------------------------
-- 5a) Setoran FK reserved kolom POS → master pelanggan SLS (PP-03/D-11).
--     NOT VALID: data live POS membawa id_sls_pelanggan seed lama (mis. 990002)
--     yang belum berpasangan dengan sls_pelanggan baru — constraint berlaku
--     untuk BARIS BARU; VALIDATE CONSTRAINT dijalankan seed-realistik/migrasi
--     setelah master pelanggan SLS diisi dan rujukan POS direkonsiliasi.
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_pesanan_sls_pelanggan') THEN
    ALTER TABLE pos_pesanan ADD CONSTRAINT fk_pos_pesanan_sls_pelanggan
      FOREIGN KEY (id_sls_pelanggan) REFERENCES sls_pelanggan (id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_kartu_poin_sls_pelanggan') THEN
    ALTER TABLE pos_kartu_poin ADD CONSTRAINT fk_pos_kartu_poin_sls_pelanggan
      FOREIGN KEY (id_sls_pelanggan) REFERENCES sls_pelanggan (id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


-- 5b) FK sesama SLS yang ditunda: sls_pelanggan.id_sls_pricelist ↔
--     sls_pricelist.id_sls_pelanggan (circular); sls_pesanan_penjualan.
--     id_sls_penawaran (tabel sumber dibuat lebih awal dari pemilik rujukan).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_pelanggan_pricelist') THEN
    ALTER TABLE sls_pelanggan ADD CONSTRAINT fk_sls_pelanggan_pricelist
      FOREIGN KEY (id_sls_pricelist) REFERENCES sls_pricelist (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_pesanan_penawaran') THEN
    ALTER TABLE sls_pesanan_penjualan ADD CONSTRAINT fk_sls_pesanan_penawaran
      FOREIGN KEY (id_sls_penawaran) REFERENCES sls_penawaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 6) TRIGGER set_updated_at — 15 tabel mutable; sls_pemenuhan_event &
--    sls_promosi_pemakaian sengaja TANPA trigger (updated_at beku —
--    append-only, pola fnb_event_log).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'sls_grup_pelanggan','sls_pelanggan',
    'sls_pricelist','sls_pricelist_aturan',
    'sls_penawaran','sls_penawaran_items',
    'sls_pesanan_penjualan','sls_pesanan_items',
    'sls_amendment_pesanan',
    'sls_retur_penjualan','sls_retur_items',
    'sls_promosi','sls_promosi_kanal',
    'sls_promosi_aturan','sls_voucher'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 7) SEKSI INTEGRASI CORE — registry modul, penomoran, konfigurasi CFG-SLS
-- -----------------------------------------------------------------------------
-- Guard fail-loud: registry modul wajib ada sebelum seed penomoran/konfigurasi.
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'sales') THEN
    RAISE EXCEPTION 'PATCH 28-sls: registry core_modules key=''sales'' absen — baseline CORE wajib dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- core_sequences (penomoran anti-race STD-08) — 4 dokumen SLS. doc_name
-- quotation/order/return MENGENOP baris legacy era-mockup yang sudah hidup di
-- live (QT counter 105, SO counter 212, RT counter 502) agar penomoran LANJUT
-- — bukan restart dari 0 (STD-08; risiko tabrakan nomor dgn dokumen lama);
-- baris existing tidak disentuh (DO NOTHING). 'customer' = baru (master
-- pelanggan belum pernah bernomor). invoice/delivery/e_faktur = wilayah
-- ACC/INV — tidak disentuh patch ini. Master pelanggan/pricelist di-seed oleh
-- seed-realistik (bukan patch ini); [TRANSAKSI] mengalir dari alur.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, 0, v.padding
FROM core_modules m
CROSS JOIN (VALUES
  ('customer',  'PLG-{yyyy}', 5),
  ('quotation', 'QT-{yyyy}',  5),
  ('order',     'SO-{yyyy}',  5),
  ('return',    'RT-{yyyy}',  5)
) AS v(doc_name, prefix, padding)
WHERE m.key = 'sales'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- core_module_configs CFG-SLS-01..13 — pertanyaan bisnis + opsi persis tabel
-- CFG docs/analisa-modul-sls-v4.md §5.2 (F12); nilai default skala PS1;
-- insert-if-missing (nilai suntingan user TIDAK ditimpa). Value type mengikuti
-- enum core_config_value_type. Nilai diubah saat aktivasi Profil Skala.
INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-SLS-01', 'SATU_LANGKAH', 'string',
   'Apakah penjualan wajib melewati kuotasi dulu? SATU_LANGKAH / DUA_LANGKAH_WAJIB / CAMPURAN'),
  ('CFG-SLS-02', 'TANPA_APPROVAL', 'string',
   'Apakah SO di atas nominal tertentu wajib disetujui? TANPA_APPROVAL / SATU_LEVEL / BERJENJANG'),
  ('CFG-SLS-03', '0', 'number',
   'Ambang nominal persetujuan per level (CFG-SLS-02); 0 = nonaktif'),
  ('CFG-SLS-04', '5', 'number',
   'Batas diskon khusus per baris (%) sebelum wajib persetujuan Manajer (SLS-BR04)'),
  ('CFG-SLS-05', 'TUNGGU_PENUH', 'string',
   'Bila stok kurang saat konfirmasi: BACKORDER_PARSIAL / TUNGGU_PENUH / TOLAK_KELEBIHAN'),
  ('CFG-SLS-06', 'MANUAL', 'string',
   'Kapan faktur pelanggan dibuat? MANUAL / OTOMATIS_TERKIRIM_PENUH / OTOMATIS_TERKIRIM / HIBRIDA (jasa saat konfirmasi — SLS-BR09)'),
  ('CFG-SLS-07', 'TERKIRIM', 'string',
   'Faktur atas dasar kuantitas apa? DIPESAN / TERKIRIM (baris JASA selalu DIPESAN — SLS-BR09)'),
  ('CFG-SLS-08', 'NONAKTIF', 'string',
   'Dasar pemakaian limit kredit: NONAKTIF / SALDO_AR / OPEN_SO_FAKTUR / KOMBINASI'),
  ('CFG-SLS-09', 'IZINKAN_PERINGATAN', 'string',
   'Saat limit kredit terlampaui: BLOKIR_KONFIRMASI / IZINKAN_DG_APPROVAL / IZINKAN_PERINGATAN'),
  ('CFG-SLS-10', 'HARGA_PRODUK', 'string',
   'Harga bila pelanggan tanpa pricelist: HARGA_PRODUK / WAJIB_PILIH_PRICELIST / TOLAK'),
  ('CFG-SLS-11', 'MANAJER', 'string',
   'Bolehkah SO terkonfirmasi dibatalkan, oleh siapa? TIDAK / MANAJER / STAF (SLS-BR12)'),
  ('CFG-SLS-12', 'SELALU_REVIEW_MANUAL', 'string',
   'Approval pesanan web M14: IKUT_AMBANG_NORMAL / SELALU_OTOMATIS / SELALU_REVIEW_MANUAL'),
  ('CFG-SLS-13', 'IKUT_FLAG_EKSKLUSIF', 'string',
   'Bila beberapa program promosi memenuhi syarat sekaligus: TERBAIK_SAJA / SEMUA_TERAPAN / IKUT_FLAG_EKSKLUSIF (urutan prioritas + flag eksklusif per program — PP-24)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'sales'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

-- PATCH 28-sls.sql selesai.
