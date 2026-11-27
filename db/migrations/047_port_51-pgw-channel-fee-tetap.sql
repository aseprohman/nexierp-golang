-- +goose Up
-- Porting 1:1 dari ddl/51-pgw-channel-fee-tetap.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 51-pgw-channel-fee-tetap.sql — FEE CAMPURAN (PERSEN + TETAP) +
-- BACKFILL KATALOG (evolusi ddl/49-pgw-fee-channel.sql)
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : keputusan pemilik 2026-11-11 — "biaya layanan TIDAK diinput bebas;
--            dihitung otomatis berdasarkan ketentuan vendor (tarif per channel)";
--            formula final: fee = round(jumlah × fee_persen) + fee_nominal
--            (rupiah penuh, Math.round) — preset gabungan credit_card
--            {2%, 2000} TIDAK terwakili di XOR-strict patch 49.
-- Pemilik  : PGW (penganam milik PGW — preseden ddl/40/41/46/49).
-- Isi      : (1) enum_jenis_fee_pgw + nilai 'CAMPURAN' (persen + nominal tetap
--            sekaligus); (2) ganti ck_pgw_channel_fee — XOR 3 cabang patch 49
--            menjadi 4 cabang (TANPA|PERSEN|NOMINAL|CAMPURAN); (3) COMMENT
--            kolom diperbarui (formula fee final + NULL = tanpa komponen);
--            (4) BACKFILL DATA (idempoten) 17 kode katalog KATALOG_CHANNEL_PGW
--            (MIDTRANS 11 + DOKU 6) dari preset DEFAULT tarif vendor — HANYA
--            baris yang masih TANPA (fee_jenis='TANPA' + kedua kolom NULL):
--            hormati ketentuan manual admin/vendor yang sudah diisi; baris
--            legacy di luar katalog (va/ewallet/bank_transfer generik MIDTRANS)
--            sengaja TIDAK disentuh (tetap TANPA — tidak pernah ditagih).
--            TANPA ALTER tipe kolom — fee_persen tetap rasio numeric(18,6)
--            (konvensi "0.007 = 0,7%", pola rasio patch 49).
-- Aliran   : PGW bentuk intent (termasukBiayaLayanan=true) → fee dihitung
--            server dari kolom channel ini → gross = jumlah + fee disimpan di
--            pgw_transaksi.jumlah → snapshot fee_vendor (patch 49 §3) + rincian
--            jsonb detail_vendor.biayaLayanan {basisProduk, feePersen,
--            feeNominalTetap, feeNominal, total}.
-- Idempoten: aman dijalankan berulang (ADD VALUE IF NOT EXISTS + guard
--            constraint drop/add + UPDATE guard TANPA). Jalankan 2×.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/51-pgw-channel-fee-tetap.sql
--            (jalankan 2× = idempoten; ALTER TYPE ADD VALUE autocommit — patch
--            ini sengaja TANPA BEGIN/COMMIT pembungkus, pola ddl/50)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- §1 ENUM — nilai 'CAMPURAN' (persen + nominal tetap sekaligus)
--    Autocommit (psql tanpa transaksi pembungkus) — nilai baru dipakai
--    constraint/backfill di §2/§4 yang berjalan statement terpisah.
-- -----------------------------------------------------------------------------
ALTER TYPE enum_jenis_fee_pgw ADD VALUE IF NOT EXISTS 'CAMPURAN';

-- -----------------------------------------------------------------------------
-- §2 CONSTRAINT — ganti XOR-strict 3 cabang (patch 49) dengan 4 cabang
--    TANPA : tanpa ketentuan fee — kedua kolom NULL (NULL = tanpa biaya).
--    PERSEN : fee_persen wajib (rasio 0..1), fee_nominal NULL.
--    NOMINAL : fee_nominal wajib (uang), fee_persen NULL.
--    CAMPURAN : keduanya wajib >= 0 (fee = round(jumlah × fee_persen) + fee_nominal).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_pgw_channel_fee') THEN
    ALTER TABLE pgw_channel DROP CONSTRAINT ck_pgw_channel_fee;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_pgw_channel_fee') THEN
    ALTER TABLE pgw_channel ADD CONSTRAINT ck_pgw_channel_fee CHECK (
      (fee_jenis = 'TANPA'     AND fee_persen IS NULL AND fee_nominal IS NULL) OR
      (fee_jenis = 'PERSEN'    AND fee_persen  IS NOT NULL AND fee_persen >= 0 AND fee_nominal IS NULL) OR
      (fee_jenis = 'NOMINAL'   AND fee_nominal IS NOT NULL AND fee_nominal >= 0 AND fee_persen IS NULL) OR
      (fee_jenis = 'CAMPURAN'  AND fee_persen  IS NOT NULL AND fee_nominal IS NOT NULL
                               AND fee_persen >= 0 AND fee_nominal >= 0)
    );
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §3 COMMENT kolom — formula fee final (keputusan pemilik 2026-11-11)
-- -----------------------------------------------------------------------------
COMMENT ON COLUMN pgw_channel.fee_jenis IS
  'ketentuan fee vendor channel: TANPA|PERSEN|NOMINAL|CAMPURAN (patch 49 + evolusi 51 — fee = round(jumlah × fee_persen) + fee_nominal, rupiah penuh; NULL berarti tanpa komponen itu)';
COMMENT ON COLUMN pgw_channel.fee_persen IS
  'rasio fee persen (0..1; 0.007 = 0,7% — pola rasio 18,6) untuk PERSEN/CAMPURAN; komponen fee = round(jumlah × fee_persen) rupiah penuh; NULL = tanpa komponen persen';
COMMENT ON COLUMN pgw_channel.fee_nominal IS
  'fee nominal tetap (uang 18,4) untuk NOMINAL/CAMPURAN; ditambahkan persis (tanpa pembulatan) setelah komponen persen; NULL = tanpa komponen tetap';

-- -----------------------------------------------------------------------------
-- §4 BACKFILL DATA — preset DEFAULT tarif vendor per kode katalog
--    (KATALOG_CHANNEL_PGW packages/schemas/src/pgw/tipe.ts; keputusan pemilik
--    2026-11-11: konstanta ini = preset playground — tarif riil dapat berbeda
--    per merchant & diatur di dashboard vendor, admin PGW bebas menimpa).
--    Guard: HANYA baris hidup yang masih TANPA penuh → idempoten & tidak pernah
--    menimpa ketentuan yang sudah diisi admin/vendor.
--    Persen disimpan RASIO (2% → 0.02; 0,7% → 0.007) sesuai konvensi kolom.
-- -----------------------------------------------------------------------------
WITH tarif(kode_vendor, kode_channel, persen, tetap) AS (VALUES
  -- MIDTRANS (11 kode katalog)
  ('MIDTRANS', 'credit_card', 0.02,  2000::numeric),
  ('MIDTRANS', 'gopay',       0.02,  0::numeric),
  ('MIDTRANS', 'shopeepay',   0.02,  0::numeric),
  ('MIDTRANS', 'qris',        0.007, 0::numeric),
  ('MIDTRANS', 'bca_va',      0,     4000::numeric),
  ('MIDTRANS', 'bni_va',      0,     4000::numeric),
  ('MIDTRANS', 'bri_va',      0,     4000::numeric),
  ('MIDTRANS', 'permata_va',  0,     4000::numeric),
  ('MIDTRANS', 'echannel',    0,     4000::numeric),
  ('MIDTRANS', 'cstore',      0,     5000::numeric),
  ('MIDTRANS', 'akulaku',     0.03,  0::numeric),
  -- DOKU (6 kode katalog)
  ('DOKU', 'virtual_account', 0,     4000::numeric),
  ('DOKU', 'qris',            0.007, 0::numeric),
  ('DOKU', 'ewallet',         0.015, 0::numeric),
  ('DOKU', 'credit_card',     0.02,  2000::numeric),
  ('DOKU', 'o2o',             0,     5000::numeric),
  ('DOKU', 'paylater',        0.03,  0::numeric)
)
UPDATE pgw_channel c
SET fee_jenis = CASE
      WHEN x.persen > 0 AND x.tetap > 0 THEN 'CAMPURAN'::enum_jenis_fee_pgw
      WHEN x.persen > 0                 THEN 'PERSEN'::enum_jenis_fee_pgw
      WHEN x.tetap > 0                  THEN 'NOMINAL'::enum_jenis_fee_pgw
      ELSE 'TANPA'::enum_jenis_fee_pgw
    END,
    fee_persen  = CASE WHEN x.persen > 0 THEN x.persen END,
    fee_nominal = CASE WHEN x.tetap > 0 THEN x.tetap END,
    updated_at  = now()
FROM tarif x, pgw_konfigurasi_vendor k
WHERE k.id = c.id_pgw_konfigurasi_vendor
  AND k.kode_vendor = x.kode_vendor
  AND c.kode_channel = x.kode_channel
  AND c.deleted_at IS NULL
  AND c.fee_jenis = 'TANPA'
  AND c.fee_persen IS NULL
  AND c.fee_nominal IS NULL;

-- -----------------------------------------------------------------------------
-- §5 VERIFIKASI (komentar introspeksi)
-- -----------------------------------------------------------------------------
-- SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
--   WHERE t.typname = 'enum_jenis_fee_pgw' ORDER BY enumsortorder;  -- TANPA,PERSEN,NOMINAL,CAMPURAN
-- SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname = 'ck_pgw_channel_fee';                           -- 4 cabang
-- SELECT kode_vendor, kode_channel, fee_jenis, fee_persen, fee_nominal
--   FROM pgw_channel WHERE deleted_at IS NULL AND fee_jenis <> 'TANPA'
--   ORDER BY 1, 2;                                                  -- baris katalog terisi
-- SELECT kode_vendor, kode_channel FROM pgw_channel
--   WHERE deleted_at IS NULL AND kode_channel IN ('va','ewallet','bank_transfer')
--   AND fee_jenis <> 'TANPA';                                       -- 0 baris (legacy tetap TANPA)

-- PATCH 51-pgw-channel-fee-tetap.sql selesai.
