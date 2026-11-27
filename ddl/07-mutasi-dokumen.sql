-- =============================================================================
-- PATCH DDL 07-mutasi-dokumen.sql — Mutasi barang berbasis dokumen header+item
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : keputusan iterasi 2026-11-05 — mutasi barang mengikuti pola
--            penyesuaian stok (header `inv_penyesuaian_stok` + items [LINE]):
--            transaksi berdasarkan DOKUMEN header + list item, siap approval
--            (MENUNGGU_PERSETUJUAN → DISETUJUI/DITOLAK, SoD penyusun≠penyetuju).
--            Posting = menulis baris `inv_gerakan_stok` per item saat DISETUJUI
--            (jenis_sumber 'MUTASI', entity_id_sumber {dokumen}:{item} —
--            idempoten via uq_inv_gerakan_idempoten); alur gerakan lama dan
--            kontrak M01/M11/M28 TIDAK berubah (patch aditif).
-- Kartu    : docs/arsitektur-database-core-inv.md §11 (D-45)
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum status dokumen mutasi (lifecycle mengikuti penyesuaian).
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_mutasi AS ENUM
    ('DRAFT', 'MENUNGGU_PERSETUJUAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN', 'SELESAI');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- inv_mutasi_dokumen — dokumen mutasi barang (MASUK/KELUAR/TRANSFER) [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_mutasi_dokumen (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                     varchar(50) NOT NULL,     -- penomoran MUT (STD-08, anti-race)
  jenis                    enum_jenis_gerakan NOT NULL,
  status                   enum_status_mutasi NOT NULL DEFAULT 'DRAFT',
  tanggal_dokumen          timestamptz NOT NULL DEFAULT now(),
  -- LOKASI PEMBAWAAN DI HEADER (D-47): seluruh item bergerak dari sumber yang
  -- sama ke tujuan yang sama; kustom per baris tidak ada di pola dokumen ini.
  id_lokasi_sumber         bigint NOT NULL,
  id_lokasi_tujuan         bigint NOT NULL,
  id_core_users_penyusun   bigint,
  id_core_users_penyetuju  bigint,                   -- SoD: penyusun != penyetuju (dicek app)
  alasan                   varchar(300),             -- wajib saat tolak/batal (dicek app)
  version                  int NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_inv_mutasi_dokumen_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_inv_mutasi_dokumen_kode UNIQUE (kode),  -- numbering: global, tanpa partial
  CONSTRAINT ck_inv_mutasi_header_lokasi_beda CHECK (id_lokasi_sumber <> id_lokasi_tujuan),
  CONSTRAINT fk_inv_mutasi_header_sumber FOREIGN KEY (id_lokasi_sumber)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_mutasi_header_tujuan FOREIGN KEY (id_lokasi_tujuan)
    REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_mutasi_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_mutasi_penyetuju FOREIGN KEY (id_core_users_penyetuju)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_inv_mutasi_dokumen_status
  ON inv_mutasi_dokumen (status, tanggal_dokumen);

-- -----------------------------------------------------------------------------
-- inv_mutasi_items — baris item mutasi [LINE]
-- Lokasi sumber ≠ tujuan ditegakkan utk TRANSFER (app); MASUK/KELUAR memakai
-- lokasi virtual sumber/tujuan sesuai semantik gerakan (ck hanya per baris
-- transfer — CHECK generik tidak tahu jenis header, kepatuhan app-side D-26).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_mutasi_items (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_mutasi_dokumen  bigint NOT NULL,
  id_inv_produk          bigint NOT NULL,
  id_inv_lot_serial      bigint,
  id_inv_unit_ukur       bigint NOT NULL,
  qty_diminta            int NOT NULL,
  nama_produk            varchar(100) NOT NULL,   -- snapshot beku saat dokumen hidup
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_inv_mutasi_items_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_mutasi_items_qty CHECK (qty_diminta > 0),
  CONSTRAINT fk_inv_mutasi_items_header FOREIGN KEY (id_inv_mutasi_dokumen)
    REFERENCES inv_mutasi_dokumen (id) ON DELETE CASCADE,
  CONSTRAINT fk_inv_mutasi_items_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_mutasi_items_lot FOREIGN KEY (id_inv_lot_serial)
    REFERENCES inv_lot_serial (id) ON DELETE SET NULL,
  CONSTRAINT fk_inv_mutasi_items_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_inv_mutasi_items_header
  ON inv_mutasi_items (id_inv_mutasi_dokumen);
CREATE INDEX IF NOT EXISTS ix_inv_mutasi_items_produk
  ON inv_mutasi_items (id_inv_produk);

-- -----------------------------------------------------------------------------
-- MIGRASI (DB yang menerapkan versi awal patch ini): lokasi pindah ke header.
-- Idempoten — DB segar (bentuk final) langsung skip via to_regclass-check
-- kolom item.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'inv_mutasi_items' AND column_name = 'id_lokasi_sumber'
  ) THEN
    ALTER TABLE inv_mutasi_dokumen ADD COLUMN IF NOT EXISTS id_lokasi_sumber bigint;
    ALTER TABLE inv_mutasi_dokumen ADD COLUMN IF NOT EXISTS id_lokasi_tujuan bigint;

    -- Backfill dari item pertama tiap dokumen; dokumen tanpa item → pasangan virtual.
    UPDATE inv_mutasi_dokumen d
    SET id_lokasi_sumber = COALESCE(i.src, v.ven),
        id_lokasi_tujuan = COALESCE(i.tgt, v.wh)
    FROM (
      SELECT (SELECT id FROM inv_lokasi_stok WHERE kode = 'VEN-VIRTUAL' AND deleted_at IS NULL) AS ven,
             (SELECT id FROM inv_lokasi_stok WHERE kode = 'WH1-STOK' AND deleted_at IS NULL) AS wh
    ) v
    LEFT JOIN (
      SELECT id_inv_mutasi_dokumen, min(id_lokasi_sumber) AS src, min(id_lokasi_tujuan) AS tgt
      FROM inv_mutasi_items GROUP BY id_inv_mutasi_dokumen
    ) i ON i.id_inv_mutasi_dokumen = d.id
    WHERE d.id_lokasi_sumber IS NULL OR d.id_lokasi_tujuan IS NULL;

    -- Baris tanpa pasangan lokasi valid (virtual tak terpasang) → buang; dokumen
    -- kosong bukan transaksi sah.
    DELETE FROM inv_mutasi_dokumen
    WHERE id_lokasi_sumber IS NULL OR id_lokasi_tujuan IS NULL OR id_lokasi_sumber = id_lokasi_tujuan;

    ALTER TABLE inv_mutasi_dokumen ALTER COLUMN id_lokasi_sumber SET NOT NULL;
    ALTER TABLE inv_mutasi_dokumen ALTER COLUMN id_lokasi_tujuan SET NOT NULL;

    ALTER TABLE inv_mutasi_dokumen DROP CONSTRAINT IF EXISTS ck_inv_mutasi_header_lokasi_beda;
    BEGIN
      ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT ck_inv_mutasi_header_lokasi_beda
        CHECK (id_lokasi_sumber <> id_lokasi_tujuan);
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT fk_inv_mutasi_header_sumber
        FOREIGN KEY (id_lokasi_sumber) REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER TABLE inv_mutasi_dokumen ADD CONSTRAINT fk_inv_mutasi_header_tujuan
        FOREIGN KEY (id_lokasi_tujuan) REFERENCES inv_lokasi_stok (id) ON DELETE RESTRICT;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;

    ALTER TABLE inv_mutasi_items DROP COLUMN IF EXISTS id_lokasi_sumber;
    ALTER TABLE inv_mutasi_items DROP COLUMN IF EXISTS id_lokasi_tujuan;
  END IF;
END $$;
