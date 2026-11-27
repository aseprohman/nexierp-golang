-- +goose Up
-- Porting 1:1 dari ddl/09-gerakan-header.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 09-gerakan-header.sql — inv_gerakan_stok pecah header-detail
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : docs/audit-gerakan-header-detail.md (audit + rekomendasi
--            disetujui 2026-11-05: kolom approval langsung dibuat,
--            nomor dokumen UNIQUE global, validasi satu-header-satu-jenis)
--            docs/arsitektur-database-core-inv.md §12 (D-48..D-52)
-- Pola     : header `inv_gerakan_header` [TRANSAKSI] + `inv_gerakan_stok`
--            menjadi [LINE] (baris item per barang). Kontrak wire
--            GerakanStokView TETAP flat (D-51) — FE & kontrak M01/M11/M28
--            tidak berubah; server find-or-create header per nomor.
-- Idempoten: aman dijalankan berulang (backfill guard EXISTS header)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) HEADER — inv_gerakan_header [TRANSAKSI]
-- Lokasi sumber/tujuan NULLABLE (D-48): NULL utk PENYESUAIAN (lokasi per baris
-- ADJ); utk jenis lain wajib terisi & beda (dicek app + CHECK parsial).
-- Kolom approval LANGSUNG ADA (keputusan user): penyusun/penyetuju.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_gerakan_header (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_dokumen            varchar(150) NOT NULL,   -- UNIQUE global (keputusan user)
  jenis                    enum_jenis_gerakan NOT NULL,
  status                   enum_status_gerakan NOT NULL DEFAULT 'DRAFT',
  langkah                  int NOT NULL DEFAULT 1,   -- D-25: eksekusi multi-langkah per dokumen
  total_langkah            int NOT NULL DEFAULT 1,
  reservasi                enum_status_reservasi NOT NULL DEFAULT 'TIDAK', -- D-29
  tanggal_jadwal           timestamptz NOT NULL DEFAULT now(),
  tanggal_selesai          timestamptz,              -- dokumen SELESAI penuh
  jenis_sumber             varchar(50) NOT NULL DEFAULT 'MANUAL', -- SO/PO/ADJ/LANDED/MUTASI/MANUAL
  entity_id_sumber         varchar(255),             -- kontrak dok-level (nullable)
  -- D-26 pindah header (patch 09): jejak jenis operasi per DOKUMEN (tanpa FK).
  kode_jenis_operasi       varchar(50),
  id_core_users            bigint,                   -- pelaksana
  id_core_users_penyusun   bigint,                   -- approval (kolom langsung ada)
  id_core_users_penyetuju  bigint,                   -- SoD: penyusun != penyetuju (app)
  alasan                   varchar(300),             -- wajib saat BATAL (STD-06)
  id_lokasi_sumber         bigint,                   -- NULL = PENYESUAIAN (D-48)
  id_lokasi_tujuan         bigint,                   -- NULL = PENYESUAIAN (D-48)
  version                  int NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_inv_gerakan_header_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_gerakan_header_nomor UNIQUE (nomor_dokumen), -- numbering global
  CONSTRAINT ck_inv_gerakan_header_langkah CHECK (langkah BETWEEN 1 AND total_langkah),
  CONSTRAINT ck_inv_gerakan_header_selesai_saat_status
    CHECK (status <> 'SELESAI' OR tanggal_selesai IS NOT NULL),
  CONSTRAINT ck_inv_gerakan_header_lokasi_beda
    CHECK (id_lokasi_sumber IS NULL OR id_lokasi_tujuan IS NULL
           OR id_lokasi_sumber <> id_lokasi_tujuan), -- INV-BR03 (pasangan sah cek app INV-003)
  CONSTRAINT fk_inv_gerakan_header_sumber FOREIGN KEY (id_lokasi_sumber)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_header_tujuan FOREIGN KEY (id_lokasi_tujuan)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_gerakan_header_pelaksana FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_gerakan_header_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_gerakan_header_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_gerakan_header_status
  ON inv_gerakan_header (status, tanggal_jadwal);
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_header_sumber
  ON inv_gerakan_header (id_lokasi_sumber);
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_header_tujuan
  ON inv_gerakan_header (id_lokasi_tujuan);

-- -----------------------------------------------------------------------------
-- 2) DETAIL — inv_gerakan_stok menjadi [LINE]: tambah FK header + override
--    lokasi nullable (D-48: PENYESUAIAN membawa lokasi per baris), kolom
--    dokumen DIBUANG (pindah header). tanggal_selesai & entity_id_sumber
--    TETAP per baris (D-50).
-- -----------------------------------------------------------------------------
ALTER TABLE inv_gerakan_stok ADD COLUMN IF NOT EXISTS id_inv_gerakan_header bigint;

-- Backfill header dari kelompok nomor (DISTINCT ON baris pertama; status
-- di-derive). Guard kolom nomor_dokumen: rerun pasca-DROP = skip bersih.
-- +goose StatementBegin
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'inv_gerakan_stok' AND column_name = 'nomor_dokumen'
  ) THEN
    INSERT INTO inv_gerakan_header (
      entity_id, nomor_dokumen, jenis, status, langkah, total_langkah, reservasi,
      tanggal_jadwal, tanggal_selesai, jenis_sumber, entity_id_sumber,
      kode_jenis_operasi,
      id_core_users, id_core_users_penyusun, id_core_users_penyetuju, alasan,
      id_lokasi_sumber, id_lokasi_tujuan, created_at, updated_at
    )
    SELECT
      gen_random_uuid(),
      f.nomor_dokumen,
      f.jenis,
      CASE
        WHEN f.n_batal = f.n_total THEN 'BATAL'
        WHEN f.n_selesai = f.n_total THEN 'SELESAI'
        WHEN f.n_selesai > 0 OR f.n_progress > 0 THEN 'SEBAGIAN'
        ELSE f.status_pertama
      END::enum_status_gerakan,
      f.langkah,
      f.total_langkah,
      f.reservasi,
      f.tanggal_jadwal,
      CASE WHEN f.n_selesai = f.n_total THEN f.tanggal_terakhir END,
      f.jenis_sumber,
      f.entity_id_sumber,
      f.kode_jenis_operasi,
      f.id_core_users,
      f.id_core_users,          -- penyusun = pelaksana baris pertama (historis)
      NULL,                     -- penyetuju: dokumen historis pra-approval
      f.alasan,
      CASE WHEN f.sumber_sama THEN f.id_lokasi_sumber END,
      CASE WHEN f.tujuan_sama THEN f.id_lokasi_tujuan END,
      f.created_at,
      f.updated_at
    FROM (
      SELECT DISTINCT ON (g.nomor_dokumen)
        g.nomor_dokumen,
        g.jenis,
        g.status AS status_pertama,
        g.langkah,
        g.total_langkah,
        g.reservasi,
        g.tanggal_jadwal,
        g.jenis_sumber,
        g.entity_id_sumber,
        g.kode_jenis_operasi,
        g.id_core_users,
        g.alasan,
        g.created_at,
        g.updated_at,
        (SELECT g2.tanggal_selesai FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL
            AND g2.tanggal_selesai IS NOT NULL
          ORDER BY g2.tanggal_selesai DESC LIMIT 1) AS tanggal_terakhir,
        (SELECT count(*) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL) AS n_total,
        (SELECT count(*) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL
            AND g2.status = 'SELESAI') AS n_selesai,
        (SELECT count(*) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL
            AND g2.status = 'BATAL') AS n_batal,
        (SELECT count(*) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL
            AND g2.qty_selesai > 0 AND g2.status <> 'SELESAI') AS n_progress,
        (SELECT count(DISTINCT g2.id_lokasi_sumber) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL) = 1 AS sumber_sama,
        (SELECT count(DISTINCT g2.id_lokasi_tujuan) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL) = 1 AS tujuan_sama,
        (SELECT min(g2.id_lokasi_sumber) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL) AS id_lokasi_sumber,
        (SELECT min(g2.id_lokasi_tujuan) FROM inv_gerakan_stok g2
          WHERE g2.nomor_dokumen = g.nomor_dokumen AND g2.deleted_at IS NULL) AS id_lokasi_tujuan
      FROM inv_gerakan_stok g
      WHERE g.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM inv_gerakan_header h WHERE h.nomor_dokumen = g.nomor_dokumen)
      ORDER BY g.nomor_dokumen, g.id
    ) f;

    -- Repoint detail + backfill override lokasi (hanya dokumen mixed —
    -- dokumen uniform: override NULL, lokasi diwarisi header).
    UPDATE inv_gerakan_stok g
    SET id_inv_gerakan_header = h.id,
        id_lokasi_sumber = CASE WHEN h.id_lokasi_sumber IS NULL THEN g.id_lokasi_sumber END,
        id_lokasi_tujuan = CASE WHEN h.id_lokasi_tujuan IS NULL THEN g.id_lokasi_tujuan END
    FROM inv_gerakan_header h
    WHERE g.nomor_dokumen = h.nomor_dokumen
      AND g.deleted_at IS NULL
      AND g.id_inv_gerakan_header IS NULL;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_gerakan_stok ALTER COLUMN id_inv_gerakan_header SET NOT NULL;
EXCEPTION WHEN others THEN NULL; END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_gerakan_stok ADD CONSTRAINT fk_inv_gerakan_header
    FOREIGN KEY (id_inv_gerakan_header) REFERENCES inv_gerakan_header (id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- Kunci idempotensi kontrak baru (nama lama gugur bersama kolom nomor).
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_gerakan_idempoten
  ON inv_gerakan_stok (id_inv_gerakan_header, id_inv_produk, entity_id_sumber)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_gerakan_stok_header
  ON inv_gerakan_stok (id_inv_gerakan_header);

-- Backfill kolom baru di header eksisting (CREATE IF NOT EXISTS melewati) —
-- D-26 direkonstruksi dari PREFIX nomor dokumen (= kode jenis operasi).
ALTER TABLE inv_gerakan_header ADD COLUMN IF NOT EXISTS kode_jenis_operasi varchar(50);
UPDATE inv_gerakan_header
SET kode_jenis_operasi = split_part(nomor_dokumen, '/', 1)
WHERE kode_jenis_operasi IS NULL;

-- 3) Buang kolom dokumen dari detail (index lama ikut gugur bersama kolom).
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS nomor_dokumen;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS jenis;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS status;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS langkah;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS total_langkah;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS reservasi;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS tanggal_jadwal;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS jenis_sumber;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS id_core_users;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS alasan;
ALTER TABLE inv_gerakan_stok DROP COLUMN IF EXISTS kode_jenis_operasi;