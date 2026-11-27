-- ============================================================================
-- PATCH DDL 42-core-wilayah.sql — CORE referensi wilayah Indonesia (4 level)
-- ============================================================================
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/arsitektur-database-core-wilayah.md (kartu klasifikasi)
--            + kebutuhan alamat member ECOM & payload ongkir SHP (M55 —
--            granularitas kecamatan + kode pos presisi vendor).
-- Tanggal  : 2026-11-08
-- Prasyarat: baseline CORE 01-core (fungsi set_updated_at).
-- Isi      : 4 tabel MASTER core_* — core_provinsi (38) / core_kota (514,
--            KOTA|KABUPATEN) / core_kecamatan (7.285) / core_kelurahan
--            (83.762, kode_pos) — FK RESTRICT berjenjang + unique kode hidup
--            + index nama/kode_pos/FK. TANPA enum (jenis kota via CHECK).
-- Sumber data (seed di luar patch): kode wilayah = fityannugroho/idn-area-data
--            v4.0.1 (ODbL — basis Kepmendagri 300.2.2-2L38/2025); kode pos =
--            mrayhanfadil/kodepos-id (nomor.net, Kepmendagri 100.1.1-6117/2022).
--            Atribusi ODbL di header seed apps/api/src/core/database/seed/
--            core-wilayah/ (pnpm seed:wilayah).
-- Integrasi: pemilik CORE (master lintas modul — pola core_pemasok);
--            konsumen baca-saja: ECOM (alamat member), SHP (M55 ongkir).
--            Pemetaan area_id vendor (Biteship IDNP..) sengaja menyusul —
--            kandidat tabel pemetaan milik SHP, bukan di sini.
-- Idempoten: aman dijalankan berulang — CREATE TABLE/INDEX IF NOT EXISTS,
--            FK/check bernama eksplisit, trigger DO-block DROP+CREATE.
-- Catatan  : trio audit semua tabel + version (K-04/K-05); kode Kemendagri
--            leading-zero terjaga (varchar, bukan numeric); tanpa hard-delete
--            (kode daerah nonaktif = deleted_at, bukan hapus — K-10).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/42-core-wilayah.sql   (jalankan 2×)
-- ============================================================================

-- §1 TABEL MASTER — urutan dependensi FK

-- [MASTER] Provinsi — kode Kemendagri 2 digit (leading zero terjaga).
CREATE TABLE IF NOT EXISTS core_provinsi (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,             -- 11, 96, … (2 digit, leading zero)
  nama                 varchar(100) NOT NULL,            -- "Aceh", "Papua Barat Daya"
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_core_provinsi_entity_id UNIQUE (entity_id)
);

-- [MASTER] Kabupaten/Kota — kode 4 digit (2 prov + 2 kab); jenis kota vs kab.
CREATE TABLE IF NOT EXISTS core_kota (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,             -- 1101, 9271, …
  nama                 varchar(100) NOT NULL,            -- tanpa prefix "Kabupaten "/"Kota "
  jenis                varchar(50) NOT NULL,             -- KOTA | KABUPATEN (ck di bawah)
  id_core_provinsi     bigint NOT NULL,
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_core_kota_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_kota_provinsi FOREIGN KEY (id_core_provinsi)
    REFERENCES core_provinsi (id) ON DELETE RESTRICT,
  CONSTRAINT ck_core_kota_jenis CHECK (jenis IN ('KOTA','KABUPATEN'))
);

-- [MASTER] Kecamatan — kode 6 digit (4 kota + 2 kec).
CREATE TABLE IF NOT EXISTS core_kecamatan (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,             -- 110101, 967110, …
  nama                 varchar(100) NOT NULL,
  id_core_kota         bigint NOT NULL,
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_core_kecamatan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_kecamatan_kota FOREIGN KEY (id_core_kota)
    REFERENCES core_kota (id) ON DELETE RESTRICT
);

-- [MASTER] Kelurahan/Desa — kode 10 digit + kode pos (Pos Indonesia).
CREATE TABLE IF NOT EXISTS core_kelurahan (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                 varchar(50) NOT NULL,             -- 1101012001, …
  nama                 varchar(100) NOT NULL,
  kode_pos             varchar(50),                      -- 5 digit; NULL = belum tercantum (0,29% — Papua pemekaran)
  id_core_kecamatan    bigint NOT NULL,
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_core_kelurahan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_kelurahan_kecamatan FOREIGN KEY (id_core_kecamatan)
    REFERENCES core_kecamatan (id) ON DELETE RESTRICT
);

-- §2 UNIQUE KODE HIDUP + INDEX (K-10: partial "hidup"; nama/kode_pos = query panas)

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_provinsi_kode_hidup
  ON core_provinsi (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_provinsi_nama
  ON core_provinsi (nama) WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_kota_kode_hidup
  ON core_kota (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kota_provinsi
  ON core_kota (id_core_provinsi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kota_nama
  ON core_kota (nama) WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_kecamatan_kode_hidup
  ON core_kecamatan (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kecamatan_kota
  ON core_kecamatan (id_core_kota) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kecamatan_nama
  ON core_kecamatan (nama) WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_kelurahan_kode_hidup
  ON core_kelurahan (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kelurahan_kecamatan
  ON core_kelurahan (id_core_kecamatan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_kelurahan_kode_pos
  ON core_kelurahan (kode_pos) WHERE deleted_at IS NULL AND kode_pos IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_core_kelurahan_nama
  ON core_kelurahan (nama) WHERE deleted_at IS NULL;

-- §3 TRIGGER updated_at — fungsi set_updated_at milik baseline 01-core
DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'core_provinsi', 'core_kota', 'core_kecamatan', 'core_kelurahan'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- §4 SEED — di luar patch (referensi master besar)
-- Data 38/514/7.285/83.762 baris diisi via runner CSV idempoten:
--   apps/api/src/core/database/seed/core-wilayah/ → `pnpm seed:wilayah`
-- (COPY/INSERT batch dalam SATU transaksi, kunci idempoten = kode hidup +
--  entity_id deterministik; verifikator = jumlah baris, parent integrity,
--  coverage kode_pos, run-2 no-op).

-- §5 VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT count(*) FROM pg_tables WHERE schemaname='public'
--     AND tablename IN ('core_provinsi','core_kota','core_kecamatan','core_kelurahan');  -- 4
--   SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'trg_core_%updated_at'
--     AND NOT tgisinternal;  -- += 4 (total repo bertambah 4)
--   -- Setelah seed: per level 38/514/7.285/83.762; coverage kode_pos ±99,7%.
-- ============================================================================
-- ddl/42-core-wilayah.sql selesai.
