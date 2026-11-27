-- =============================================================================
-- PATCH DDL 90-pur-landed-alokasi-item.sql — PUR: ALOKASI BIAYA LANDED PER
--                       ITEM PO (tabel [LINE] pur_biaya_landed_item — BATCH 1)
-- =============================================================================
-- Domain   : NEXIERP · Modul PURCHASING — tabel baru [LINE]
--            `pur_biaya_landed_item`: alokasi biaya landed per
--            `pur_pesanan_item` (anak `pur_biaya_landed`, satu baris per item
--            PO penerima porsi biaya).
--            Keputusan desain TERKUNCI (kartu arsitektur lolos gerbang):
--            saat keputusan SETUJUI, sistem OTOMATIS membagi nilai biaya ke
--            SEMUA item PO terpilih sesuai `dasar_alokasi` header
--            (NILAI/QTY/BERAT/VOLUME) → status dokumen langsung TERALOKASIKAN
--            (enum status TIDAK berubah). TIDAK ada endpoint alokasi manual.
-- Bobot    : Bobot per item (dipakai batch 2 — eksekusi alokasi di service
--            keputusan): NILAI = harga × (1 − diskon_persen/100) × qty;
--            QTY = qty; BERAT = inv_produk.berat_gram × qty; VOLUME =
--            inv_produk.volume_cm3 × qty; NULL → 0; max(0,…). Helper murni
--            `hitungBobotAlokasi`/`bagiAlokasi` SATU SUMBER di packages/
--            schemas core (dinaikkan dari inv/tipe.ts — dipakai inv &
--            purchasing; patch 90 refactor 2026-11-25).
-- Migrasi  : Tabel baru KOSONG — tanpa backfill; baris lahir dari eksekusi
--            alokasi otomatis saat SETUJUI (batch 2). Dokumen landed
--            eksisting berstatus TERALOKASIKAN (pra-patch) tetap valid —
--            riwayat detail alokasinya tidak direkonstruksi.
-- Bedah    : CREATE TABLE saja — tanpa perubahan tabel/enum lama. FK header
--            CASCADE (baris alokasi ikut dokumen landed); FK
--            pur_pesanan_item RESTRICT (riwayat alokasi menahan hapus item).
-- Idempoten: Guard `to_regclass` sebelum CREATE TABLE + `CREATE INDEX IF NOT
--            EXISTS` + trigger drop/create + COMMENT — lari kedua = no-op.
-- Catatan  : Index partial ala konvensi repo (WHERE deleted_at IS NULL);
--            trigger `set_updated_at()` fungsi generik CORE (ddl/01);
--            trio audit + version + entity_id di seluruh baris (STD).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/90-pur-landed-alokasi-item.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 TABEL [LINE] — alokasi biaya landed per item PO
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF to_regclass('public.pur_biaya_landed_item') IS NULL THEN
    CREATE TABLE pur_biaya_landed_item (
      id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
      id_pur_biaya_landed   bigint NOT NULL,   -- FK CASCADE ke pur_biaya_landed(id)
      id_pur_pesanan_item   bigint NOT NULL,   -- FK RESTRICT ke pur_pesanan_item(id)
      bobot                 numeric(18,6) NOT NULL DEFAULT 0,
      nilai_alokasi         numeric(18,4) NOT NULL DEFAULT 0,
      version               integer NOT NULL DEFAULT 1,
      created_at            timestamptz NOT NULL DEFAULT now(),
      updated_at            timestamptz NOT NULL DEFAULT now(),
      deleted_at            timestamptz,
      CONSTRAINT uq_pur_landed_item_entity_id UNIQUE (entity_id),
      CONSTRAINT ck_pur_landed_item_bobot CHECK (bobot >= 0),
      CONSTRAINT fk_pur_landed_item_header FOREIGN KEY (id_pur_biaya_landed)
        REFERENCES pur_biaya_landed (id) ON DELETE CASCADE,
      CONSTRAINT fk_pur_landed_item_pesanan_item FOREIGN KEY (id_pur_pesanan_item)
        REFERENCES pur_pesanan_item (id) ON DELETE RESTRICT
    );
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §2 INDEX PARTIAL — sisi header & sisi item PO (pola konvensi repo)
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ix_pur_biaya_landed_item_header
  ON pur_biaya_landed_item (id_pur_biaya_landed) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_biaya_landed_item_pesanan_item
  ON pur_biaya_landed_item (id_pur_pesanan_item) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- §3 TRIGGER set_updated_at — fungsi generik CORE (pola array/loop ddl/25)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'pur_biaya_landed_item'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- §4 COMMENT — kepemilikan modul purchasing
-- -----------------------------------------------------------------------------

COMMENT ON TABLE pur_biaya_landed_item IS
  'LINE alokasi biaya landed per item PO — PEMILIK MODUL PURCHASING (ddl/90, 2026-11-25): lahir OTOMATIS saat keputusan SETUJUI — nilai biaya dibagi ke semua item PO terpilih sesuai dasar_alokasi header → dokumen langsung TERALOKASIKAN (tanpa endpoint alokasi manual).';

COMMENT ON COLUMN pur_biaya_landed_item.bobot IS
  'Bobot alokasi baris (batch 2): NILAI = harga×(1−diskon_persen/100)×qty; QTY = qty; BERAT = inv_produk.berat_gram×qty; VOLUME = inv_produk.volume_cm3×qty; NULL→0; max(0,…) — helper satu sumber packages/schemas core.';

COMMENT ON COLUMN pur_biaya_landed_item.nilai_alokasi IS
  'Porsi nilai biaya dibebankan ke baris ini — Σ(nilai_alokasi) baris hidup = pur_biaya_landed.nilai saat TERALOKASIKAN.';

COMMIT;

-- =============================================================================
-- §5 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Tabel  : SELECT to_regclass('public.pur_biaya_landed_item');        → NOT NULL
-- Kolom  : SELECT column_name, data_type FROM information_schema.columns
--          WHERE table_name='pur_biaya_landed_item' ORDER BY ordinal_position;
--          → id, entity_id, id_pur_biaya_landed, id_pur_pesanan_item, bobot,
--            nilai_alokasi, version, created_at, updated_at, deleted_at (10)
-- FK     : SELECT conname, confdeltype FROM pg_constraint
--          WHERE conrelid='pur_biaya_landed_item'::regclass AND contype='f'
--          ORDER BY conname;
--          → fk_pur_landed_item_header (c=CASCADE),
--            fk_pur_landed_item_pesanan_item (r=RESTRICT)
-- CK/UQ  : SELECT conname FROM pg_constraint
--          WHERE conrelid='pur_biaya_landed_item'::regclass
--          ORDER BY conname;
--          → ck_pur_landed_item_bobot, fk_…(2),
--            pur_biaya_landed_item_pkey, uq_pur_landed_item_entity_id (5)
-- Index  : SELECT indexname FROM pg_indexes
--          WHERE tablename='pur_biaya_landed_item' ORDER BY 1;
--          → ix_pur_biaya_landed_item_header,
--            ix_pur_biaya_landed_item_pesanan_item,
--            pur_biaya_landed_item_pkey, uq_pur_landed_item_entity_id (4)
-- Trigger: SELECT tgname FROM pg_trigger
--          WHERE tgrelid='pur_biaya_landed_item'::regclass AND NOT tgisinternal;
--          → trg_pur_biaya_landed_item_updated_at
-- Kosong : SELECT count(*) FROM pur_biaya_landed_item;                → 0
-- =============================================================================
