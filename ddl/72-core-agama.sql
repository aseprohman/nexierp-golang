-- =============================================================================
-- PATCH DDL 72-core-agama.sql — CORE: master `core_agama` + FK agama ke
-- calon siswa (ppdb_pendaftaran) & siswa (akd_siswa)
-- =============================================================================
-- Domain   : NEXIERP · Cluster Aplikasi Akademik (audit satuan-pendidikan
--            ppdb/akd/tgs/psn 2026-11-18).
-- Sumber   : permintaan pemilik — "buat tabel core_agama, update tabel
--            calon siswa & siswa, tambahkan fk id_core_agama, refactor
--            FE+BE". Kartu klasifikasi mengikuti skill arsitektur-database
--            (Fase 2): [MASTER] generik lintas modul → milik CORE.
-- Kartu    :
--   core_agama        | [MASTER] | CORE | PK identity, entity_id Tier A,
--     code varchar(50) unique-hidup (ISLAM, KRISTEN_PROTESTAN, …), nama
--     varchar(100), urutan int (uratan dropdown), status enum_status_aktif
--     (dipinjam CORE — tanpa enum baru), version (dimutasi via API CRUD),
--     trio audit. Tanpa jsonb/snapshot. Seed: 7 agama resmi Indonesia,
--     idempoten by code (podman/seed-core-agama.sql).
--   ppdb_pendaftaran  +id_core_agama bigint NULL FK RESTRICT + ix hidup
--     (NULL = kanal publik / data lama sebelum field ada; zod create
--     entri luring mewajibkan pilihan, portal publik opsional).
--   akd_siswa         +id_core_agama bigint NULL FK RESTRICT + ix hidup
--     (NULL = baris migrasi pra-field; form biodata FE menyediakan select).
-- Idempoten: CREATE TABLE IF NOT EXISTS; kolom via DO-block cek
--            information_schema; constraint FK bernama eksplisit via
--            DO-block cek pg_constraint; index CREATE INDEX IF NOT EXISTS;
--            trigger DO-block DROP IF EXISTS + CREATE.
-- Prasyarat: baseline CORE (enum_status_aktif, fungsi set_updated_at) +
--            tabel ppdb_pendaftaran (48) & akd_siswa (49) + patch 64
--            (akd_siswa sudah di-ALTER tempat_lahir/kelurahan).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/72-core-agama.sql   (jalankan 2×)
-- =============================================================================

-- =============================================================================
-- §1 TABEL MASTER — core_agama (kosakata agama resmi, lintas modul)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core_agama (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  code        varchar(50) NOT NULL,   -- ISLAM / KRISTEN_PROTESTAN / …
  nama        varchar(100) NOT NULL,  -- "Islam", "Kristen Protestan", …
  urutan      integer NOT NULL DEFAULT 0,   -- uratan dropdown FE
  status      enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_core_agama_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_core_agama_code CHECK (length(btrim(code)) > 0),
  CONSTRAINT ck_core_agama_nama  CHECK (length(btrim(nama)) > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_agama_code_hidup
  ON core_agama (code) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_agama_status
  ON core_agama (status) WHERE deleted_at IS NULL;

-- =============================================================================
-- §2 FK AGAMA — kolom + constraint + index (pola DO-block ddl/64)
-- =============================================================================

-- 2a. ppdb_pendaftaran (calon siswa) — kolom
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'ppdb_pendaftaran' AND column_name = 'id_core_agama'
  ) THEN
    ALTER TABLE ppdb_pendaftaran ADD COLUMN id_core_agama bigint;
  END IF;
END
$$;

-- 2b. constraint + index (dikunci terpisah agar idempoten penuh)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_ppdb_pendaftaran_agama'
      AND conrelid = 'ppdb_pendaftaran'::regclass
  ) THEN
    ALTER TABLE ppdb_pendaftaran
      ADD CONSTRAINT fk_ppdb_pendaftaran_agama FOREIGN KEY (id_core_agama)
        REFERENCES core_agama (id) ON DELETE RESTRICT;
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS ix_ppdb_pendaftaran_agama_hidup
  ON ppdb_pendaftaran (id_core_agama) WHERE deleted_at IS NULL;

-- 2c. akd_siswa (siswa) — kolom
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'akd_siswa' AND column_name = 'id_core_agama'
  ) THEN
    ALTER TABLE akd_siswa ADD COLUMN id_core_agama bigint;
  END IF;
END
$$;

-- 2d. constraint + index
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_akd_siswa_agama'
      AND conrelid = 'akd_siswa'::regclass
  ) THEN
    ALTER TABLE akd_siswa
      ADD CONSTRAINT fk_akd_siswa_agama FOREIGN KEY (id_core_agama)
        REFERENCES core_agama (id) ON DELETE RESTRICT;
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS ix_akd_siswa_agama_hidup
  ON akd_siswa (id_core_agama) WHERE deleted_at IS NULL;

-- =============================================================================
-- §3 TRIGGER updated_at — core_agama (pola 55-core-cluster D-04; ppdb/akd
--     sudah punya trigger dari patch asalnya — tidak disentuh)
-- =============================================================================

DO $$
BEGIN
  EXECUTE format('DROP TRIGGER IF EXISTS trg_core_agama_updated_at ON %I;', 'core_agama');
  EXECUTE format('CREATE TRIGGER trg_core_agama_updated_at BEFORE UPDATE ON %I
                  FOR EACH ROW EXECUTE FUNCTION set_updated_at();', 'core_agama');
END $$;

-- =============================================================================
-- VERIFIKASI (introspeksi manual SETELAH apply — BUKAN bagian eksekusi):
--   SELECT count(*) FROM pg_class WHERE relname='core_agama';            -- 1
--   SELECT count(*) FROM pg_indexes WHERE tablename='core_agama';        -- 3
--   SELECT conname FROM pg_constraint WHERE conrelid='ppdb_pendaftaran'::regclass
--     AND conname LIKE '%agama';                                         -- fk_ppdb_pendaftaran_agama
--   SELECT conname FROM pg_constraint WHERE conrelid='akd_siswa'::regclass
--     AND conname LIKE '%agama';                                         -- fk_akd_siswa_agama
--   Seed menyusul: podman/seed-core-agama.sql (7 agama, idempoten by code).
-- =============================================================================

-- ddl/72-core-agama.sql selesai.
