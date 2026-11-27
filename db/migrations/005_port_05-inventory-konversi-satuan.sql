-- +goose Up
-- Porting 1:1 dari ddl/05-inventory-konversi-satuan.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 05-inventory-konversi-satuan.sql — Tabel konversi satuan (UOM)
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : permintaan refactor halaman /inventory/master/unit — field
--            `rasio_ke_dasar` inv_unit_ukur terbukti tidak pernah dikonsumsi
--            komputasi bisnis mana pun (write-only: CRUD unit + seed), jadi
--            konversi antar unit dipindah ke tabel [MASTER] sendiri.
-- Kartu    : docs/arsitektur-database-core-inv.md §9 (kartu klasifikasi baru)
-- Idempoten: aman dijalankan berulang
-- =============================================================================

-- -----------------------------------------------------------------------------
-- inv_unit_konversi — peta konversi antar unit dalam kategori UOM sama [MASTER]
-- Semantik: 1 unit_dari = faktor × unit_ke (contoh: 1 DUS = 12 PCS).
-- Satu baris per pasangan berarah; arah balik (PCS→DUS) = invers, tidak
-- diduplikasi (dicegah service). Kesamaan kategori_uom divalidasi service
-- (pola D-26 — kepatuhan kode app-side, tidak mungkin sebagai CHECK lintas
-- tabel).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_unit_konversi (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_unit_dari   bigint NOT NULL,                     -- unit asal
  id_unit_ke     bigint NOT NULL,                     -- unit tujuan
  faktor         numeric(18,6) NOT NULL,              -- 1 dari = faktor × ke
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_inv_unit_konversi_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_inv_unit_konversi_faktor CHECK (faktor > 0),
  CONSTRAINT ck_inv_unit_konversi_beda_unit CHECK (id_unit_dari <> id_unit_ke),
  CONSTRAINT fk_inv_unit_konversi_dari FOREIGN KEY (id_unit_dari)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT fk_inv_unit_konversi_ke FOREIGN KEY (id_unit_ke)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT
);

-- Pasangan partial-unique (pakai ulang setelah hapus lunak) — pola ddl/02.
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_unit_konversi_pasangan
  ON inv_unit_konversi (id_unit_dari, id_unit_ke) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_inv_unit_konversi_dari
  ON inv_unit_konversi (id_unit_dari) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_unit_konversi_ke
  ON inv_unit_konversi (id_unit_ke) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- inv_unit_ukur — DROP rasio_ke_dasar (digantikan inv_unit_konversi)
-- Kolom write-only: tidak dirujuk view/gerakan/saldo/laporan mana pun
-- (audit kode 2026-11-05). Data konversi lama pada kolom ini TIDAK dimigrasi
-- otomatis — konversi resmi diisi seed/master baru (rasio relatif ke "unit
-- dasar kategori" tidak setara pasangan antar unit eksplisit).
-- -----------------------------------------------------------------------------
ALTER TABLE inv_unit_ukur DROP CONSTRAINT IF EXISTS ck_inv_unit_ukur_rasio;
ALTER TABLE inv_unit_ukur DROP COLUMN IF EXISTS rasio_ke_dasar;