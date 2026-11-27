-- +goose Up
-- Porting 1:1 dari ddl/06-induk-jadi-produk.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 06-induk-jadi-produk.sql — Induk varian menjadi baris inv_produk
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : keputusan iterasi varian 2026-11-05 — relasi induk produk
--            diubah dari tabel template terpisah (inv_produk_induk) menjadi
--            HIERARKI MANDIRI di tabel master produk: FK
--            inv_produk.id_inv_produk_induk kini menunjuk inv_produk(id).
--            Induk = produk penuh (harga, stok min, berat hidup di induk)
--            sehingga varian mewarisi semua field induk sebagai default
--            (kustomisasi per varian di form produk).
-- Kartu    : docs/arsitektur-database-core-inv.md §10 (D-42..D-44)
-- Idempoten: aman dijalankan berulang (migrasi data pakai EXISTS)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- inv_produk_varian_konfig — konfigurasi atribut varian per produk induk [LINE]
-- Pengganti inv_produk_induk_atribut; parent kini baris inv_produk.
-- LINE (punya kolom bisnis wajib/urutan — warisan D-19), bukan junction murni.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inv_produk_varian_konfig (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk  bigint NOT NULL,                   -- produk INDUK (baris inv_produk)
  id_inv_atribut bigint NOT NULL,
  wajib          boolean NOT NULL DEFAULT true,     -- kombinasi wajib menyertakan nilai ini
  urutan         int NOT NULL DEFAULT 0,
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_inv_produk_varian_konfig_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pvk_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pvk_atribut FOREIGN KEY (id_inv_atribut)
    REFERENCES inv_atribut (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_produk_varian_konfig_pasangan
  ON inv_produk_varian_konfig (id_inv_produk, id_inv_atribut) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_inv_produk_varian_konfig_atribut
  ON inv_produk_varian_konfig (id_inv_atribut) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- MIGRASI DATA — induk → baris inv_produk (idempoten via EXISTS + guard
-- to_regclass: rerun setelah tabel lama di-drop = skip bersih).
-- Mapping: kode→kode_produk, nama→nama, deskripsi→keterangan, kategori/unit
-- tetap; tipe BARANG, jejak_stok true, stok_minimum 0 (default produk).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
BEGIN
  IF to_regclass('public.inv_produk_induk') IS NOT NULL THEN
    INSERT INTO inv_produk (
      entity_id, kode_produk, nama, tipe, id_inv_kategori_produk, id_inv_unit_ukur,
      jejak_stok, keterangan, status, created_at, updated_at
    )
    SELECT
      gen_random_uuid(),
      i.kode,
      i.nama,
      'BARANG',
      i.id_inv_kategori_produk,
      i.id_inv_unit_ukur,
      true,
      i.deskripsi,
      i.status,
      i.created_at,
      i.updated_at
    FROM inv_produk_induk i
    WHERE NOT EXISTS (
      SELECT 1 FROM inv_produk p WHERE p.kode_produk = i.kode AND p.deleted_at IS NULL
    );

    -- Repoint varian lama ke parent baris inv_produk (LEPAS FK lama dulu).
    ALTER TABLE inv_produk DROP CONSTRAINT IF EXISTS fk_inv_produk_induk;

    UPDATE inv_produk v
    SET id_inv_produk_induk = p.id,
        updated_at = now()
    FROM inv_produk_induk i
    JOIN inv_produk p ON p.kode_produk = i.kode AND p.deleted_at IS NULL
    WHERE v.id_inv_produk_induk = i.id;

    -- Migrasi baris konfigurasi atribut induk → konfig varian per produk induk.
    INSERT INTO inv_produk_varian_konfig (
      entity_id, id_inv_produk, id_inv_atribut, wajib, urutan, created_at, updated_at
    )
    SELECT
      gen_random_uuid(),
      p.id,
      a.id_inv_atribut,
      a.wajib,
      a.urutan,
      a.created_at,
      a.updated_at
    FROM inv_produk_induk_atribut a
    JOIN inv_produk_induk i ON i.id = a.id_inv_produk_induk
    JOIN inv_produk p ON p.kode_produk = i.kode AND p.deleted_at IS NULL
    WHERE NOT EXISTS (
      SELECT 1 FROM inv_produk_varian_konfig k
      WHERE k.id_inv_produk = p.id
        AND k.id_inv_atribut = a.id_inv_atribut
        AND k.deleted_at IS NULL
    );
  END IF;
END $$;
-- +goose StatementEnd


-- Self-FK hierarki (nama constraint dipertahankan — konvensi kolom sama).
-- DIKEMUKAKAN tanpa syarat: DB segar (tanpa tabel lama) tetap butuh FK ini.
-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE inv_produk ADD CONSTRAINT fk_inv_produk_induk FOREIGN KEY (id_inv_produk_induk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- Penanda induk varian eksplisit — produk sederhana vs produk induk (template)
-- tidak lagi dibedakan oleh tabel; dibedakan oleh flag ini (Odoo-parity
-- "template punya varian"). Induk yang baru dibuat (belum konfigurasi) tetap
-- terlihat di daftar template.
-- -----------------------------------------------------------------------------
ALTER TABLE inv_produk ADD COLUMN IF NOT EXISTS adalah_induk_varian
  boolean NOT NULL DEFAULT false;

-- Backfill: baris yang punya konfigurasi varian hidup = induk.
UPDATE inv_produk p
SET adalah_induk_varian = true
WHERE p.deleted_at IS NULL
  AND p.adalah_induk_varian = false
  AND EXISTS (
    SELECT 1 FROM inv_produk_varian_konfig k
    WHERE k.id_inv_produk = p.id AND k.deleted_at IS NULL
  );

CREATE INDEX IF NOT EXISTS ix_inv_produk_induk_varian
  ON inv_produk (adalah_induk_varian) WHERE deleted_at IS NULL AND adalah_induk_varian;

-- -----------------------------------------------------------------------------
-- DROP tabel template lama (data sudah termigrasi penuh di atas).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS inv_produk_induk_atribut;
DROP TABLE IF EXISTS inv_produk_induk;