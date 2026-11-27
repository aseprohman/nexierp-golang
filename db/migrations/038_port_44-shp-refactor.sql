-- +goose Up
-- Porting 1:1 dari ddl/44-shp-refactor.sql (urutan & isi sama, tanpa perubahan)

-- ============================================================================
-- PATCH DDL 44-shp-refactor.sql — SHP refactor: hapus lokasi & kalkulasi
-- (persist), order pakai snapshot tarif live, tambah kurir vendor
-- ============================================================================
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : keputusan pemilik 2026-11-09 — halaman /shipment/lokasi dan
--            /shipment/kalkulasi dihapus beserta tabel yang diaksesnya
--            (refactor-delete-mode; arsip: arsip-hapus-shipment-lokasi-
--            kalkulasi-20261109.tgz). Arah baru: kalkulasi = LIVE di halaman
--            simulasi (tanpa persist), konfigurasi vendor + AKTIVASI KURIR
--            per vendor (fitur-modul-fullcycle).
-- Tanggal  : 2026-11-09
-- Prasyarat: ddl/41-shp.sql terpasang; data kalkulasi/lokasi/order seed
--            realistik di-arsip (hilang permanen setelah patch).
-- Isi      : (1) shp_order — lepas 3 FK/kolom ke kalkulasi/opsi/lokasi,
--            tambah snapshot tarif live (kode/nama kurir+layanan +
--            tarif_snapshot jsonb); (2) shp_log_api — lepas kolom
--            id_shp_kalkulasi; (3) DROP TABLE shp_kalkulasi_opsi,
--            shp_kalkulasi, shp_lokasi_asal; (4) TAMBAH tabel
--            shp_kurir_vendor [MASTER] — aktivasi kurir per konfigurasi
--            vendor; (5) trigger tabel baru.
-- Integrasi: order bentuk dari payload kalkulasi LIVE (halaman simulasi) —
--            snapshot tarif beku di shp_order; kontrak M55 (persist
--            kalkulasi) DITUNDA — diganti hitung-live respons sinkron;
--            M56/M57 tetap. Lookup wilayah (ddl/42) tetap dipakai payload.
-- Idempoten: ALTER ... IF EXISTS, DROP ... IF EXISTS, CREATE IF NOT EXISTS,
--            trigger DO-block DROP+CREATE.
-- Catatan  : uq/ix yang merujuk kolom dihapus wajib DIDROP DULU sebelum
--            kolomnya (Postgres drop column otomatis buang index-nya,
--            tetapi IF EXISTS eksplisit membuat patch tahan re-order).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/44-shp-refactor.sql   (2× = idempoten)
-- ============================================================================

-- §1 SHP_ORDER — lepas keterikatan kalkulasi/opsi/lokasi, pasang snapshot live
ALTER TABLE shp_order DROP CONSTRAINT IF EXISTS fk_shp_order_opsi;
ALTER TABLE shp_order DROP CONSTRAINT IF EXISTS fk_shp_order_kalkulasi;
ALTER TABLE shp_order DROP CONSTRAINT IF EXISTS fk_shp_order_lokasi_asal;
DROP INDEX IF EXISTS uq_shp_order_opsi_aktif_hidup;
DROP INDEX IF EXISTS ix_shp_order_lokasi_asal;

ALTER TABLE shp_order
  DROP COLUMN IF EXISTS id_shp_kalkulasi,
  DROP COLUMN IF EXISTS id_shp_kalkulasi_opsi,
  DROP COLUMN IF EXISTS id_shp_lokasi_asal;

-- Snapshot tarif live (beku saat order dibentuk — pengganti opsi persist).
ALTER TABLE shp_order ADD COLUMN IF NOT EXISTS kode_kurir  varchar(50);
ALTER TABLE shp_order ADD COLUMN IF NOT EXISTS nama_kurir  varchar(100);
ALTER TABLE shp_order ADD COLUMN IF NOT EXISTS kode_layanan varchar(50);
ALTER TABLE shp_order ADD COLUMN IF NOT EXISTS nama_layanan varchar(100);
ALTER TABLE shp_order ADD COLUMN IF NOT EXISTS tarif_snapshot jsonb; -- opsi tarif lengkap beku

COMMENT ON COLUMN shp_order.kode_kurir IS 'Snapshot kurir terpilih dari kalkulasi LIVE (tanpa tabel kalkulasi — ddl/44)';
COMMENT ON COLUMN shp_order.tarif_snapshot IS 'Opsi tarif lengkap beku (biaya/komponen/ETA) dari kalkulasi live';

-- §2 SHP_LOG_API — lepas kaitan kalkulasi (log order & konfigurasi tetap)
ALTER TABLE shp_log_api DROP CONSTRAINT IF EXISTS fk_shp_log_api_kalkulasi;
ALTER TABLE shp_log_api DROP COLUMN IF EXISTS id_shp_kalkulasi;
DROP INDEX IF EXISTS ix_shp_log_api_kalkulasi;

-- §3 DROP TABEL kalkulasi/opsi/lokasi (urutan anak → induk)
DROP TABLE IF EXISTS shp_kalkulasi_opsi;
DROP TABLE IF EXISTS shp_kalkulasi;
DROP TABLE IF EXISTS shp_lokasi_asal;

-- §4 SHP_KURIR_VENDOR [MASTER] — aktivasi kurir per konfigurasi vendor
--    (daftar kurir ter-install/tersedia dari API vendor — pola API sesuai
--    vendor via adapter; toggle aktif menentukan kurir yang dihitung live).
CREATE TABLE IF NOT EXISTS shp_kurir_vendor (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  id_shp_konfigurasi_vendor bigint NOT NULL,
  kode_kurir                varchar(50) NOT NULL,   -- kode resmi vendor (jne, sicepat, …)
  nama_kurir                varchar(100) NOT NULL,
  jenis_layanan             varchar(50),            -- STANDARD/EKSPRES/INSTANT/KARGO/LAINNYA (opsional)
  aktif                     boolean NOT NULL DEFAULT true,
  meta_vendor               jsonb,                  -- detail tambahan dari API vendor (tanpa secret)
  version                   int NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_shp_kurir_vendor_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_shp_kurir_vendor_konfigurasi FOREIGN KEY (id_shp_konfigurasi_vendor)
    REFERENCES shp_konfigurasi_vendor (id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_kurir_vendor_pasangan_hidup
  ON shp_kurir_vendor (id_shp_konfigurasi_vendor, kode_kurir)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_shp_kurir_vendor_aktif
  ON shp_kurir_vendor (id_shp_konfigurasi_vendor)
  WHERE aktif = true AND deleted_at IS NULL;

-- §5 TRIGGER updated_at — fungsi set_updated_at milik baseline 01-core
-- +goose StatementBegin
DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY['shp_kurir_vendor'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- §6 VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT tablename FROM pg_tables WHERE schemaname='public'
--     AND tablename IN ('shp_lokasi_asal','shp_kalkulasi','shp_kalkulasi_opsi','shp_kurir_vendor');
--   -- harapan: 1 baris (shp_kurir_vendor saja)
--   SELECT column_name FROM information_schema.columns
--     WHERE table_name='shp_order' AND column_name IN
--     ('id_shp_kalkulasi','id_shp_kalkulasi_opsi','id_shp_lokasi_asal','tarif_snapshot');
--   -- harapan: hanya tarif_snapshot
-- ============================================================================
-- ddl/44-shp-refactor.sql selesai.
