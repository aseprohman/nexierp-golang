-- +goose Up
-- Porting 1:1 dari ddl/48-inv-gudang-wilayah.sql (urutan & isi sama, tanpa perubahan)

-- ============================================================================
-- PATCH DDL 48-inv-gudang-wilayah.sql — INV gudang referensi wilayah CORE
-- (kelurahan + koordinat) agar biaya shipment dari gudang akurat
-- ============================================================================
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : kartu arsitektur fitur-modul-fullcycle (update fitur gudang
--            2026-11-10) + gerbang arsitektur-database.
-- Tanggal  : 2026-11-10
-- Prasyarat: ddl/02-inventory.sql (inv_gudang) + ddl/42-core-wilayah.sql
--            (core_kelurahan ter-seed — FK menunjuk baris hidup).
-- Isi      : ALTER inv_gudang — tambah 3 kolom NULL (transisi baris lama):
--            (1) id_core_kelurahan FK RESTRICT — referensi wilayah DAUN;
--            rantai provinsi→kota→kecamatan & kode pos TIDAK disalin (3NF:
--            derivable via FK join — satu fakta satu tempat; sumber kebenaran
--            tetap core_*; perbaikan master wilayah tidak perlu sinkron ulang).
--            (2) latitude/longitude numeric(9,6) — syarat kurir instant SHP
--            (wajib koordinat). Plus index FK.
-- Integrasi: pemilik kolom INV (inv_gudang [MASTER]); konsumen baca: SHP
--            (kalkulasi live mengambil origin dari gudang — idCoreKelurahan
--            diresolusi server via rantai CORE, pola resolusiWilayah).
-- Idempoten: ALTER ADD COLUMN IF NOT EXISTS + FK named eksplisit (DO-block)
--            + CREATE INDEX IF NOT EXISTS — aman dijalankan berulang.
-- Catatan  : trio audit inv_gudang + trigger trg_inv_gudang_updated_at sudah
--            ada (baseline 02) — tidak diubah. NULL = wilayah belum diisi;
--            penetapan gudang sebagai origin SHP menuntut kelurahan + kode
--            pos terisi (validasi di titik pakai, bukan di master).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/48-inv-gudang-wilayah.sql (jalankan 2×)
-- ============================================================================

-- §1 KOLOM REFERENSI WILAYAH + KOORDINAT
ALTER TABLE inv_gudang
  ADD COLUMN IF NOT EXISTS id_core_kelurahan bigint,
  ADD COLUMN IF NOT EXISTS latitude  numeric(9,6),
  ADD COLUMN IF NOT EXISTS longitude numeric(9,6);

-- §2 FK RESTRICT — kelurahan master tidak boleh hilang selama dirujuk
--    (hard-delete diblokir DB; penonaktifan = deleted_at, divalidasi service).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_inv_gudang_kelurahan'
      AND conrelid = 'inv_gudang'::regclass
  ) THEN
    ALTER TABLE inv_gudang
      ADD CONSTRAINT fk_inv_gudang_kelurahan
      FOREIGN KEY (id_core_kelurahan)
      REFERENCES core_kelurahan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- §3 INDEX FK (join rantai wilayah di view/origin resolution)
CREATE INDEX IF NOT EXISTS ix_inv_gudang_kelurahan
  ON inv_gudang (id_core_kelurahan);

-- §4 VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT count(*) FROM information_schema.columns
--     WHERE table_name='inv_gudang'
--       AND column_name IN ('id_core_kelurahan','latitude','longitude');  -- 3
--   SELECT count(*) FROM pg_constraint
--     WHERE conname='fk_inv_gudang_kelurahan';                            -- 1
--   SELECT count(*) FROM pg_indexes
--     WHERE tablename='inv_gudang'
--       AND indexname='ix_inv_gudang_kelurahan';                          -- 1
-- ============================================================================
-- ddl/48-inv-gudang-wilayah.sql selesai.
