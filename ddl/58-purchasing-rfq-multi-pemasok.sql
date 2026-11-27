-- =============================================================================
-- PATCH DDL 58-purchasing-rfq-multi-pemasok.sql — RFQ multi-pemasok (REVISI
--            desain keputusan pemilik 2026-11-12)
-- Domain   : PUR — revisi fitur RFQ (ddl/57): 1 RFQ TIDAK lagi dikunci 1
--            pemasok. Header kini pemasok-agnostik (deskripsi kebutuhan);
--            undangan per pemasok hidup di tabel child BARU
--            `pur_rfq_penerima` (satu baris per pemasok yang diundang, dengan
--            status + jejak kirim + RESPO pemasok masing-masing) — dasar
--            PERBANDINGAN penawaran antar pemasok (nilai_penawaran +
--            catatan_respon per penerima).
-- Sumber   : keputusan pemilik 2026-11-12 (revisi atas ddl/57 yang
--            single-pemasok). Kartu lolos gerbang arsitektur-database:
--            `pur_rfq_penerima` = [LINE] penerima undangan (child ber-atribut
--            status per baris — bukan junction murni).
-- Tanggal  : 2026-11-12
-- Prasyarat: ddl/57 terpasang; VERIFIKASI live: header 1 baris (uji user) +
--            item 1 + kirim 0 → MIGRASI SELAMAT-DATA §3 wajib.
-- Isi      : §1 ENUM enum_status_penerima_rfq_pur (DIUNDANG/TERKIRIM/RESPON);
--            §2 tabel pur_rfq_penerima + unique partial + index + trigger;
--            §3 migrasi selamat-data — baris penerima dari header lama
--            (id_pur_pemasok → penerima; status/terkirim/respon dipindah);
--            §4 ALTER kirim ADD id_rfq_penerima (nullable — baris lama 0);
--            §5 ALTER header DROP kolom pemasok-agnostik lama.
-- Makna    : header menggambarkan KEBUTUHAN (item + deadline); penerima
--            menggambarkan SIAPA yang diundang & apa balasannya. Kirim per
--            penerima (log ber-kanal); respon per penerima memicu status
--            RESPON + nilai_penawaran utk tabel perbandingan.
-- Idempoten: guard pg_type/pg_constraint + ADD COLUMN IF NOT EXISTS +
--            migrasi data guard NOT EXISTS — aman 2× (run-2 no-op).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Enum status penerima undangan.
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_penerima_rfq_pur AS ENUM
    ('DIUNDANG', 'TERKIRIM', 'RESPON');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- §2 Tabel penerima undangan [LINE].
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pur_rfq_penerima (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  id_permintaan_penawaran  bigint NOT NULL,
  id_pur_pemasok           bigint NOT NULL,
  status                   enum_status_penerima_rfq_pur NOT NULL DEFAULT 'DIUNDANG',
  terkirim_pada            timestamptz,
  tanggal_respon           date,
  catatan_respon           varchar(300),
  -- Penawaran balik pemasok (opsional, manual) — bahan perbandingan harga.
  nilai_penawaran          numeric(18, 4),
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_pur_rfq_penerima_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_rfq_penerima_header FOREIGN KEY (id_permintaan_penawaran)
    REFERENCES pur_permintaan_penawaran (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_rfq_penerima_pemasok FOREIGN KEY (id_pur_pemasok)
    REFERENCES pur_pemasok (id) ON UPDATE CASCADE ON DELETE RESTRICT
);
-- Satu undangan hidup per (RFQ, pemasok) — partial unique (baris hidup saja;
-- undang ulang sah setelah soft delete). NULL DISTINCT membuat UNIQUE berkolom
-- deleted_at tidak menegakkan apa pun — partial index yang benar.
CREATE UNIQUE INDEX IF NOT EXISTS uq_pur_rfq_penerima_pasangan
  ON pur_rfq_penerima (id_permintaan_penawaran, id_pur_pemasok)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_rfq_penerima_header
  ON pur_rfq_penerima (id_permintaan_penawaran);
CREATE INDEX IF NOT EXISTS ix_pur_rfq_penerima_pemasok
  ON pur_rfq_penerima (id_pur_pemasok);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pur_rfq_penerima_updated_at') THEN
    CREATE TRIGGER trg_pur_rfq_penerima_updated_at BEFORE UPDATE ON pur_rfq_penerima
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §3 Migrasi selamat-data — header lama ber-pemasok → baris penerima.
--    Status penerima mengikuti kondisi header: TERKIRIM bila sudah ada
--    terkirim_pada (menyesuaikan kolom status enum lama), else DIUNDANG.
--    Respon header (jika terisi) dipindah ke penerima.
--    GUARD: hanya bila kolom id_pur_pemasok MASIH ada (sebelum §5) —
--    re-run setelah §5 = no-op (idempoten).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'pur_permintaan_penawaran' AND column_name = 'id_pur_pemasok'
  ) THEN
    INSERT INTO pur_rfq_penerima
      (entity_id, id_permintaan_penawaran, id_pur_pemasok, status,
       terkirim_pada, tanggal_respon, catatan_respon, created_at, updated_at)
    SELECT gen_random_uuid(),
           h.id,
           h.id_pur_pemasok,
           CASE WHEN h.status = 'DRAFT' THEN 'DIUNDANG'::enum_status_penerima_rfq_pur
                ELSE 'TERKIRIM'::enum_status_penerima_rfq_pur END,
           h.terkirim_pada,
           h.tanggal_respon,
           h.catatan_respon,
           h.created_at,
           now()
    FROM pur_permintaan_penawaran h
    WHERE h.id_pur_pemasok IS NOT NULL
      AND h.deleted_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM pur_rfq_penerima p
        WHERE p.id_permintaan_penawaran = h.id
          AND p.id_pur_pemasok = h.id_pur_pemasok
          AND p.deleted_at IS NULL
      );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §4 Log kirim menunjuk penerima (nullable — baris lama NULL tetap sah).
-- -----------------------------------------------------------------------------
ALTER TABLE pur_permintaan_penawaran_kirim
  ADD COLUMN IF NOT EXISTS id_rfq_penerima bigint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_pur_rfq_kirim_penerima'
      AND conrelid = 'pur_permintaan_penawaran_kirim'::regclass
  ) THEN
    ALTER TABLE pur_permintaan_penawaran_kirim
      ADD CONSTRAINT fk_pur_rfq_kirim_penerima
      FOREIGN KEY (id_rfq_penerima)
      REFERENCES pur_rfq_penerima (id)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_pur_rfq_kirim_penerima
  ON pur_permintaan_penawaran_kirim (id_rfq_penerima);

-- -----------------------------------------------------------------------------
-- §5 Header — kolom pemasok & respon pindah ke penerima.
-- -----------------------------------------------------------------------------
ALTER TABLE pur_permintaan_penawaran
  DROP COLUMN IF EXISTS id_pur_pemasok,
  DROP COLUMN IF EXISTS tanggal_respon,
  DROP COLUMN IF EXISTS catatan_respon;

-- Index pemasok header tidak lagi relevan.
DROP INDEX IF EXISTS ix_pur_rfq_pemasok;

COMMIT;

-- ddl/58-purchasing-rfq-multi-pemasok.sql selesai.
