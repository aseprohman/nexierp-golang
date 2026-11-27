-- +goose Up
-- Porting 1:1 dari ddl/55-core-cluster.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 55-core-cluster.sql — CORE: Cluster Modul & Fitur (master + junction)
-- Domain   : OdooLikeERP · Proyek: SISPANDU (cluster aplikasi akademik)
-- Sumber   : kebutuhan pengelompokan modul per lini bisnis (cluster SEKOLAH
--            ISLAM TERPADU / UMKM) — spec DDL DIKUNCI (brief 2026-11-10),
--            patch hanya mengikuti.
-- Kartu    : docs/arsitektur-database-core-cluster.md (D-01..D-07).
-- Tanggal  : 2026-11-10
-- Prasyarat: baseline CORE 01-core (core_modules, core_modules_features,
--            fungsi set_updated_at) + enum global enum_status_aktif (AKTIF/
--            NONAKTIF — SUDAH ADA, dipakai ulang; TANPA enum baru).
-- Isi      : 1 MASTER `core_cluster` + 2 JUNCTION murni
--            `core_cluster_modules` (cluster ↔ modul) dan
--            `core_cluster_features` (baris cluster_modules ↔ feature).
--            Trigger updated_at satu blok untuk 3 tabel (pola 01-core D-04).
-- Idempoten: aman dijalankan berulang — CREATE TABLE IF NOT EXISTS, FK &
--            constraint bernama eksplisit, CREATE INDEX IF NOT EXISTS,
--            trigger DO-block DROP TRIGGER IF EXISTS + CREATE TRIGGER.
-- Catatan  : unassign junction = soft delete (deleted_at) lalu boleh re-assign
--            → pair-unik PARTIAL `WHERE deleted_at IS NULL` (kartu D-02);
--            FK junction CASCADE karena junction murni (kartu D-03);
--            entity_id Tier A hanya di MASTER (kartu D-05); version hanya di
--            core_cluster yang dimutasi API PATCH (kartu D-06).
-- =============================================================================

-- =============================================================================
-- §1 TABEL MASTER — core_cluster (pengelompokan modul per lini bisnis)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core_cluster (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  code        varchar(50) NOT NULL,
  nama        varchar(100) NOT NULL,
  deskripsi   varchar(200),
  icon        varchar(50),
  tone        varchar(100),
  urutan      integer NOT NULL DEFAULT 0,
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_core_cluster_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_core_cluster_code CHECK (length(btrim(code)) > 0),
  CONSTRAINT ck_core_cluster_nama  CHECK (length(btrim(nama)) > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_cluster_code_hidup ON core_cluster (code) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_cluster_status ON core_cluster (status) WHERE deleted_at IS NULL;

-- =============================================================================
-- §2 TABEL JUNCTION — core_cluster_modules (cluster ↔ modul, murni pasangan)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core_cluster_modules (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_cluster  bigint NOT NULL,
  id_core_modules  bigint NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT fk_core_cluster_modules_cluster FOREIGN KEY (id_core_cluster) REFERENCES core_cluster (id) ON DELETE CASCADE,
  CONSTRAINT fk_core_cluster_modules_modul   FOREIGN KEY (id_core_modules)   REFERENCES core_modules (id)   ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_cluster_modules_pair_hidup ON core_cluster_modules (id_core_cluster, id_core_modules) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_cluster_modules_cluster ON core_cluster_modules (id_core_cluster);
CREATE INDEX IF NOT EXISTS ix_core_cluster_modules_modul   ON core_cluster_modules (id_core_modules);

-- =============================================================================
-- §3 TABEL JUNCTION — core_cluster_features (baris cluster_modules ↔ feature)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core_cluster_features (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_cluster_modules  bigint NOT NULL,
  id_core_modules_features bigint NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT fk_core_cluster_features_cm  FOREIGN KEY (id_core_cluster_modules)  REFERENCES core_cluster_modules (id)  ON DELETE CASCADE,
  CONSTRAINT fk_core_cluster_features_cmf FOREIGN KEY (id_core_modules_features) REFERENCES core_modules_features (id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_cluster_features_pair_hidup ON core_cluster_features (id_core_cluster_modules, id_core_modules_features) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_cluster_features_cm  ON core_cluster_features (id_core_cluster_modules);
CREATE INDEX IF NOT EXISTS ix_core_cluster_features_cmf ON core_cluster_features (id_core_modules_features);

-- =============================================================================
-- §4 TRIGGER updated_at — satu blok untuk 3 tabel (pola 01-core.sql D-04)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core_cluster','core_cluster_modules','core_cluster_features'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- Penerapan (DB dev = container nexierp-postgres, arahan pemilik 2026-11-10;
-- pgdb BUKAN DB live):
--   podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--     -v ON_ERROR_STOP=1 < ddl/55-core-cluster.sql
--   (jalankan 2× — run-2 harus sukses tanpa error = bukti idempoten)
--
-- VERIFIKASI:
--   \d core_cluster                       -- 3 tabel + 3 trigger trg_*_updated_at
--   SELECT count(*) FROM pg_class WHERE relname IN
--     ('core_cluster','core_cluster_modules','core_cluster_features');  -- 3
--   SELECT count(*) FROM pg_indexes WHERE tablename LIKE 'core_cluster%'; -- 6
--   SELECT count(*) FROM pg_trigger WHERE tgrelid::regclass::text LIKE 'core_cluster%'
--     AND NOT tgisinternal;                                             -- 3
--   Seed menyusul: podman/seed-core-cluster.sql + podman/seed-menus-cluster.sql
-- =============================================================================

-- ddl/55-core-cluster.sql selesai.
