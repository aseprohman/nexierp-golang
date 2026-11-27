-- ============================================================================
-- PATCH DDL 45-shp-kurir-layanan.sql — SHP katalog layanan per kurir vendor
-- (granularitas resmi API Biteship) + kosakata operasi log "KURIR"
-- ============================================================================
-- Domain   : OdooLikeERP · Modul SHP (prioritas vendor: BITESHIP)
-- Sumber   : API resmi Biteship GET /v1/couriers — respons `couriers[]`
--            PER PRODUK LAYANAN: courier_code, courier_service_code,
--            courier_service_name, tier, description, service_type,
--            shipping_type, shipment_duration_range/unit,
--            available_for_cash_on_delivery / _insurance /
--            _proof_of_delivery / _instant_waybill_id,
--            available_collection_method. (docs resmi biteship.com/en/docs,
--            terverifikasi 2026-11-08; plan Starter = 3 kurir ter-install.)
-- Desain   : aktivasi kurir di level PERUSAHAAN (shp_kurir_vendor.aktif —
--            menentukan parameter `couriers=` saat hitung tarif), katalog
--            LAYANAN anak [KATALOG] per produk (tabel ini) = detail resmi
--            yang di-upsert oleh sinkronisasi vendor; UI menampilkan
--            layanan per kurir tanpa parsing jsonb.
-- Tanggal  : 2026-11-09
-- Prasyarat: ddl/44-shp-refactor.sql (shp_kurir_vendor).
-- Isi      : CREATE TABLE shp_kurir_layanan [KATALOG] + unique/index +
--            trigger set_updated_at. Tanpa enum baru (jenis via varchar
--            kosakata SHP; flags boolean).
-- Idempoten: IF NOT EXISTS semua; trigger DO-block.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/45-shp-kurir-layanan.sql   (2×)
-- ============================================================================

-- [KATALOG] shp_kurir_layanan — satu baris per PRODUK LAYANAN vendor
-- (courier_service_code resmi), anak dari shp_kurir_vendor. Di-upsert
-- saat sinkronisasi katalog (bukan diedit user); trio audit seragam,
-- tanpa `version` (bukan dokumen user).
CREATE TABLE IF NOT EXISTS shp_kurir_layanan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_shp_kurir_vendor    bigint NOT NULL,
  kode_layanan           varchar(50) NOT NULL,   -- courier_service_code resmi (reg/best/ez/CARGO/…)
  nama_layanan           varchar(100) NOT NULL,  -- courier_service_name
  jenis_layanan          varchar(50),            -- normalisasi SHP: STANDARD/EKSPRES/INSTANT/KARGO/LAINNYA
  service_type_vendor    varchar(50),            -- service_type mentah vendor
  shipping_type          varchar(50),            -- parcel / freight (mentah vendor)
  tier                   varchar(50),            -- tier produk kurir resmi
  durasi_nilai           varchar(50),            -- shipment_duration_range ("2 - 3")
  durasi_satuan          varchar(50),            -- shipment_duration_unit (days/hours)
  tersedia_cod           boolean NOT NULL DEFAULT false,   -- available_for_cash_on_delivery
  tersedia_asuransi      boolean NOT NULL DEFAULT false,   -- available_for_insurance
  tersedia_pod           boolean NOT NULL DEFAULT false,   -- available_for_proof_of_delivery
  tersedia_instant       boolean NOT NULL DEFAULT false,   -- available_for_instant_waybill_id
  metode_ambil           varchar(50),            -- available_collection_method utama (PICKUP/DROP_OFF)
  deskripsi              varchar(300),           -- description resmi vendor
  meta                   jsonb,                  -- sisa field vendor (tanpa secret)
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_shp_kurir_layanan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_shp_kurir_layanan_kurir FOREIGN KEY (id_shp_kurir_vendor)
    REFERENCES shp_kurir_vendor (id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_shp_kurir_layanan_pasangan_hidup
  ON shp_kurir_layanan (id_shp_kurir_vendor, kode_layanan)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_shp_kurir_layanan_jenis
  ON shp_kurir_layanan (jenis_layanan)
  WHERE deleted_at IS NULL;

DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY['shp_kurir_layanan'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- VERIFIKASI manual: tabel ada + FK CASCADE + trigger; diisi oleh sinkron
-- katalog vendor (tanpa baris = belum pernah sinkron).
-- ============================================================================
-- ddl/45-shp-kurir-layanan.sql selesai.
