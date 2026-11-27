-- =============================================================================
-- PATCH DDL 49-pgw-fee-channel.sql — KETENTUAN FEE VENDOR PER CHANNEL (penganam PGW)
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : keputusan pemilik 2026-11-10 — "biaya layanan gateway otomatis sesuai
--            ketentuan vendor"; kartu ECOM docs/arsitektur-database-ecom.md §6 D-15;
--            blueprint ECOM docs/analisa-modul-ecom-v3.md A-13 + CFG-ECOM-12 DITIMPA.
-- Pemilik  : PGW (channel = milik PGW per peta-modul §4; patch ini PENGANAM milik
--            PGW — preseden ddl/40-pgw-refund-ck, 41-pgw-tanpa-refund, 46-pgw-*).
--            Patch 50-ecom-portal.sql TIDAK menyentuh pgw_*.
-- Isi      : (1) enum_jenis_fee_pgw; (2) pgw_channel + fee_jenis/fee_persen/fee_nominal
--            (ketentuan per vendor+channel+environment, XOR-strict); (3) pgw_transaksi
--            + fee_vendor (snapshot fee terhitung saat charge — ketentuan boleh berubah,
--            transaksi tidak bergeser; melayani ECOM M50/M52 dan RSV M53 sama rata).
-- Aliran   : ECOM checkout-options baca ketentuan via layanan PGW baca-saja in-process
--            (pola M36) → beku biaya_layanan di pesanan → M50 intent (jumlah sudah
--            termasuk fee) → PGW beku fee_vendor saat charge → M52 DIBAYAR; refund
--            tidak mengembalikan fee (vendor non-refundable).
-- Idempoten: aman dijalankan berulang (IF NOT EXISTS + guard pg_constraint).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/49-pgw-fee-channel.sql   (jalankan 2× = idempoten)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- §1 ENUM — jenis fee ketentuan channel (fail-loud pola 41-shp)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_jenis_fee_pgw AS ENUM ('TANPA', 'PERSEN', 'NOMINAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_fee_pgw')
     IS DISTINCT FROM ARRAY['TANPA', 'PERSEN', 'NOMINAL']::text[] THEN
    RAISE EXCEPTION 'enum_jenis_fee_pgw kosakata menyimpang dari mirror';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §2 pgw_channel — ketentuan fee per channel
--    QRIS vendor umumnya PERSEN; Virtual Account/e-wallet umumnya NOMINAL flat.
--    Admin PGW mengisi sesuai ketentuan merchant yang berlaku dari vendor.
-- -----------------------------------------------------------------------------
ALTER TABLE pgw_channel
  ADD COLUMN IF NOT EXISTS fee_jenis   enum_jenis_fee_pgw NOT NULL DEFAULT 'TANPA',
  ADD COLUMN IF NOT EXISTS fee_persen  numeric(18,6),
  ADD COLUMN IF NOT EXISTS fee_nominal numeric(18,4);

COMMENT ON COLUMN pgw_channel.fee_jenis   IS 'ketentuan fee vendor channel: TANPA|PERSEN|NOMINAL (keputusan pemilik 2026-11-10, D-15)';
COMMENT ON COLUMN pgw_channel.fee_persen  IS 'rasio fee ketika fee_jenis=PERSEN (0..1; 0.007 = 0,7% — pola rasio 18,6)';
COMMENT ON COLUMN pgw_channel.fee_nominal IS 'fee flat ketika fee_jenis=NOMINAL (uang 18,4)';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_pgw_channel_fee') THEN
    ALTER TABLE pgw_channel ADD CONSTRAINT ck_pgw_channel_fee CHECK (
      (fee_jenis = 'TANPA'   AND fee_persen IS NULL AND fee_nominal IS NULL) OR
      (fee_jenis = 'PERSEN'  AND fee_persen  IS NOT NULL AND fee_persen  >= 0 AND fee_nominal IS NULL) OR
      (fee_jenis = 'NOMINAL' AND fee_nominal IS NOT NULL AND fee_nominal >= 0 AND fee_persen  IS NULL)
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §3 pgw_transaksi — snapshot fee terhitung (beku saat charge)
-- -----------------------------------------------------------------------------
ALTER TABLE pgw_transaksi ADD COLUMN IF NOT EXISTS fee_vendor numeric(18,4);

COMMENT ON COLUMN pgw_transaksi.fee_vendor IS
  'fee channel terhitung dari ketentuan pgw_channel saat charge, dibekukan PGW (audit: ketentuan boleh berubah, transaksi tidak bergeser); NULL = transaksi tanpa fee';

-- -----------------------------------------------------------------------------
-- §4 VERIFIKASI (komentar introspeksi)
-- -----------------------------------------------------------------------------
-- SELECT count(*) FROM pg_type WHERE typname = 'enum_jenis_fee_pgw';          -- harap 1
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name='pgw_channel' AND column_name LIKE 'fee%' ORDER BY 1;    -- 3 baris
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name='pgw_transaksi' AND column_name='fee_vendor';            -- 1 baris
-- SELECT conname FROM pg_constraint WHERE conname='ck_pgw_channel_fee';       -- 1 baris

-- PATCH 49-pgw-fee-channel.sql selesai.
