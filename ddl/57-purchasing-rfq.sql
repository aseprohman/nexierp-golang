-- =============================================================================
-- PATCH DDL 57-purchasing-rfq.sql — Fitur Request Quotation (RFQ) PURCHASING
-- Domain   : PUR — dokumen PERMINTAAN PENAWARAN (request quotation) per
--            pemasok: header + item + log pengiriman (pola header-detail,
--            arsitektur-database). RFQ dikirim ke pemasok via EMAIL (SMTP
--            core_app_settings — kirim nyata) atau WA (outbox pur.rfq.kirim.wa
--            — gateway WA-CRM integrator menyusul, pola M54), bisa diekspor
--            XLS dari FE. Respons pemasok dicatat manual (tanggal_respon/
--            catatan_respon) — kelanjutan harga jadi PO lewat alur PO
--            eksisting (pemilihan baris harga PUR-BR06).
-- Sumber   : keputusan pemilik 2026-11-12 (fitur-modul-fullcycle Fase 2;
--            kartu lolos gerbang arsitektur-database). Konteks: fitur tender
--            multi-pemasok F17 DIHAPUS ddl/56 — RFQ ini SATU pemasok per
--            dokumen; perbandingan antar pemasok = beberapa RFQ.
-- Tanggal  : 2026-11-12
-- Prasyarat: pur_pemasok (ddl/55 rename), inv_produk/inv_unit_ukur/inv_gudang
--            (INV), core_users, enum pola `enum_*_pur` live.
-- Isi      : §1 3 enum (status RFQ, kanal kirim, status kirim);
--            §2 tabel header [TRANSAKSI] pur_permintaan_penawaran;
--            §3 tabel LINE pur_permintaan_penawaran_item;
--            §4 tabel LOG/EVENT pur_permintaan_penawaran_kirim;
--            §5 trigger set_updated_at (pola repo);
--            §6 penomoran core_sequences doc_name 'purchase_rfq' RFQ-{yyyy}.
-- Makna    : HEADER pur_permintaan_penawaran | kode numbering unik global +
--            enum lifecycle + version + trio; LINE snapshot nama_produk
--            (harga TIDAK di-RFQ-kan di baris — penawaran balik pemasok
--            dicatat via respon/PO); LOG append-only trio lengkap.
-- Idempoten: CREATE TABLE IF NOT EXISTS + guard pg_type/pg_constraint +
--            ON CONFLICT sequence — aman 2× (run-2 no-op).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Enum.
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_rfq_pur AS ENUM
    ('DRAFT', 'TERKIRIM', 'DITUTUP', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_kanal_kirim_pur AS ENUM ('EMAIL', 'WA');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_kirim_pur AS ENUM ('BERHASIL', 'GAGAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- §2 Header [TRANSAKSI].
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pur_permintaan_penawaran (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  kode             varchar(50) NOT NULL,          -- numbering RFQ-{yyyy} (unique global)
  id_pur_pemasok   bigint NOT NULL,               -- target tunggal per dokumen
  id_inv_gudang    bigint,                        -- gudang tujuan barang (opsional)
  tanggal          date NOT NULL,
  butuh_pada       date,                          -- deadline kebutuhan barang
  status           enum_status_rfq_pur NOT NULL DEFAULT 'DRAFT',
  terkirim_pada    timestamptz,                   -- kirim pertama BERHASIL
  tanggal_respon   date,                          -- balasan pemasok (manual)
  catatan_respon   varchar(300),
  alasan_penutupan varchar(300),                  -- wajib bila DIBATALKAN (app)
  catatan          varchar(300),
  id_core_users_penyusun bigint REFERENCES core_users (id) ON DELETE SET NULL,
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_pur_rfq_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_rfq_kode UNIQUE (kode),
  CONSTRAINT fk_pur_rfq_pemasok FOREIGN KEY (id_pur_pemasok)
    REFERENCES pur_pemasok (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_pur_rfq_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_pur_rfq_batal
    CHECK (status <> 'DIBATALKAN' OR alasan_penutupan IS NOT NULL),
  CONSTRAINT ck_pur_rfq_respon
    CHECK (catatan_respon IS NULL OR tanggal_respon IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_status ON pur_permintaan_penawaran (status, tanggal);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_pemasok ON pur_permintaan_penawaran (id_pur_pemasok);

-- -----------------------------------------------------------------------------
-- §3 LINE.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pur_permintaan_penawaran_item (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  id_permintaan_penawaran   bigint NOT NULL,
  id_inv_produk             bigint NOT NULL,
  id_inv_unit_ukur          bigint NOT NULL,
  qty                       integer NOT NULL,
  catatan                   varchar(200),        -- catatan baris utk pemasok
  nama_produk               varchar(100) NOT NULL, -- snapshot beku
  version                   integer NOT NULL DEFAULT 1,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_pur_rfq_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_rfq_item_header FOREIGN KEY (id_permintaan_penawaran)
    REFERENCES pur_permintaan_penawaran (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_rfq_item_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_pur_rfq_item_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_pur_rfq_item_qty CHECK (qty > 0)
);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_item_header ON pur_permintaan_penawaran_item (id_permintaan_penawaran);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_item_produk ON pur_permintaan_penawaran_item (id_inv_produk);

-- -----------------------------------------------------------------------------
-- §4 LOG/EVENT pengiriman — append-only (tidak ada UPDATE/DELETE bisnis).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pur_permintaan_penawaran_kirim (
  id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  id_permintaan_penawaran   bigint NOT NULL,
  kanal                     enum_kanal_kirim_pur NOT NULL,
  tujuan                    varchar(150) NOT NULL, -- email/no-WA pemasok (snapshot)
  status                    enum_status_kirim_pur NOT NULL,
  detail                    varchar(300),          -- message-id / ringkasan error
  id_core_users             bigint REFERENCES core_users (id) ON DELETE SET NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  deleted_at                timestamptz,
  CONSTRAINT uq_pur_rfq_kirim_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_rfq_kirim_header FOREIGN KEY (id_permintaan_penawaran)
    REFERENCES pur_permintaan_penawaran (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_kirim_header
  ON pur_permintaan_penawaran_kirim (id_permintaan_penawaran, created_at);

-- -----------------------------------------------------------------------------
-- §5 Trigger set_updated_at (pola repo ddl/25).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pur_rfq_updated_at') THEN
    CREATE TRIGGER trg_pur_rfq_updated_at BEFORE UPDATE ON pur_permintaan_penawaran
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pur_rfq_item_updated_at') THEN
    CREATE TRIGGER trg_pur_rfq_item_updated_at BEFORE UPDATE ON pur_permintaan_penawaran_item
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pur_rfq_kirim_updated_at') THEN
    CREATE TRIGGER trg_pur_rfq_kirim_updated_at BEFORE UPDATE ON pur_permintaan_penawaran_kirim
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §6 Penomoran RFQ-{yyyy} (pola purchase_order PO-{yyyy}).
-- -----------------------------------------------------------------------------
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, 'purchase_rfq', 'RFQ-{yyyy}', 0, 4
FROM core_modules m
WHERE m.key = 'purchasing'
ON CONFLICT DO NOTHING;

COMMIT;

-- ddl/57-purchasing-rfq.sql selesai.
