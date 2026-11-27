-- =============================================================================
-- PATCH DDL 88-acc-faktur-pindah.sql — PEMINDAHAN KEPEMILIKAN FITUR FAKTUR
--                       ACC → SLS/PUR + PENGHAPUSAN KOMITMEN PO
-- =============================================================================
-- Domain   : NEXIERP · Keputusan pemilik 2026-11-24 — fitur faktur keluar dari
--            modul ACC mengikuti konteks bisnisnya:
--            · Faktur Pelanggan  → modul SALES (SLS)   — acc_faktur_pelanggan*   → sls_faktur_pelanggan*
--            · Faktur Pemasok    → modul PURCHASING    — acc_faktur_pemasok*     → pur_faktur_pembelian*
--              (rename konteks: "faktur pembelian" di PUR)
--            · Komitmen PO       → DIHAPUS (halaman+endpoint+tabel; konsumen event
--              PUR belum pernah ada; penulis tunggal = seed)
--            · acc_faktur_cicilan (shared dua fitur, CK tepat-satu) di-SPLIT
--              mengikuti pemilik barisnya: sls_faktur_cicilan / pur_faktur_cicilan
-- Kartu    : docs/arsitektur-database-acc.md (catatan pindah) + kartu sls/pur
--            menyusul di MIGRASI-BACKEND.md; gerbang arsitektur-database.
-- Tanggal  : 2026-11-24
-- Metode   : ALTER TABLE RENAME (data & id & entity_id DIPERTAHANKAN — tidak
--            ada INSERT-SELECT untuk induk/items); cicilan dipecah INSERT-
--            SELECT per sisi CK tepat-satu lalu DROP induknya.
-- Re-point : 10 FK penunjuk di tabel yang TETAP di ACC/POS — kolom ikut
--            di-rename ke pemilik baru (konvensi id_<tabel_tunggal>):
--            acc_nota_kredit, acc_pembayaran_alokasi, acc_entri_jurnal,
--            acc_event_log, acc_bukti_potong, acc_faktur_pajak (→ sls),
--            pos_pesanan.id_acc_faktur (→ sls, tetap NOT VALID semula).
-- Termin   : kolom id_acc_termin di kedua tabel faktur TETAP bernama demikian
--            (menunjuk acc_termin_pembayaran milik ACC yang tidak pindah —
--            nama kolom masih benar; FK lintas modul baca pola sah).
-- Outbox   : topik acc.faktur.so.status / acc.faktur.pos.status ikut pindah
--            milik service (di-rename kode-side ke sls.faktur.*) — 0 konsumen
--            saat ini (aman; bukan bagian DDL).
-- Idempoten: semua langkah ter-guard to_regclass/pg_constraint (kali-2 no-op).
-- Verifikasi (§8) wajib dijalankan SETELAH apply.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 RENAME TABEL INDUK + ITEMS (data, id, entity_id, index isi ikut)
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF to_regclass('public.acc_faktur_pelanggan') IS NOT NULL
     AND to_regclass('public.sls_faktur_pelanggan') IS NULL THEN
    ALTER TABLE acc_faktur_pelanggan RENAME TO sls_faktur_pelanggan;
  END IF;
  IF to_regclass('public.acc_faktur_pelanggan_items') IS NOT NULL
     AND to_regclass('public.sls_faktur_pelanggan_items') IS NULL THEN
    ALTER TABLE acc_faktur_pelanggan_items RENAME TO sls_faktur_pelanggan_items;
  END IF;
  IF to_regclass('public.acc_faktur_pemasok') IS NOT NULL
     AND to_regclass('public.pur_faktur_pembelian') IS NULL THEN
    ALTER TABLE acc_faktur_pemasok RENAME TO pur_faktur_pembelian;
  END IF;
  IF to_regclass('public.acc_faktur_pemasok_items') IS NOT NULL
     AND to_regclass('public.pur_faktur_pembelian_items') IS NULL THEN
    ALTER TABLE acc_faktur_pemasok_items RENAME TO pur_faktur_pembelian_items;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §2 RENAME KOLOM FK INTERNAL ITEMS (FK ikut mengikuti kolom otomatis)
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='sls_faktur_pelanggan_items' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE sls_faktur_pelanggan_items
      RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='pur_faktur_pembelian_items' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE pur_faktur_pembelian_items
      RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §3 RE-POINT FK PENUNJUK DI TABEL YANG TETAP — drop FK → rename kolom →
--    add FK bernama baru (konvensi penamaan pemilik baru)
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fktplg') THEN
    ALTER TABLE acc_entri_jurnal DROP CONSTRAINT fk_acc_entri_fktplg;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fktpms') THEN
    ALTER TABLE acc_entri_jurnal DROP CONSTRAINT fk_acc_entri_fktpms;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_entri_jurnal' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE acc_entri_jurnal RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_entri_jurnal' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE acc_entri_jurnal RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fkt_sls') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_fkt_sls
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fkt_pur') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_fkt_pur
      FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES pur_faktur_pembelian(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fktplg') THEN
    ALTER TABLE acc_event_log DROP CONSTRAINT fk_acc_event_fktplg;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fktpms') THEN
    ALTER TABLE acc_event_log DROP CONSTRAINT fk_acc_event_fktpms;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_event_log' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE acc_event_log RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_event_log' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE acc_event_log RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fkt_sls') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_fkt_sls
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fkt_pur') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_fkt_pur
      FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES pur_faktur_pembelian(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fktplg') THEN
    ALTER TABLE acc_pembayaran_alokasi DROP CONSTRAINT fk_acc_alok_fktplg;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fktpms') THEN
    ALTER TABLE acc_pembayaran_alokasi DROP CONSTRAINT fk_acc_alok_fktpms;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_pembayaran_alokasi' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE acc_pembayaran_alokasi RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_pembayaran_alokasi' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE acc_pembayaran_alokasi RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fkt_sls') THEN
    ALTER TABLE acc_pembayaran_alokasi ADD CONSTRAINT fk_acc_alok_fkt_sls
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fkt_pur') THEN
    ALTER TABLE acc_pembayaran_alokasi ADD CONSTRAINT fk_acc_alok_fkt_pur
      FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES pur_faktur_pembelian(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_faktur_pelanggan') THEN
    ALTER TABLE acc_nota_kredit DROP CONSTRAINT fk_acc_nota_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_faktur_pemasok') THEN
    ALTER TABLE acc_nota_kredit DROP CONSTRAINT fk_acc_nota_faktur_pemasok;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_nota_kredit' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE acc_nota_kredit RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_nota_kredit' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE acc_nota_kredit RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_fkt_sls') THEN
    ALTER TABLE acc_nota_kredit ADD CONSTRAINT fk_acc_nota_fkt_sls
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_fkt_pur') THEN
    ALTER TABLE acc_nota_kredit ADD CONSTRAINT fk_acc_nota_fkt_pur
      FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES pur_faktur_pembelian(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_faktur_pemasok') THEN
    ALTER TABLE acc_bukti_potong DROP CONSTRAINT fk_acc_bupot_faktur_pemasok;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_bukti_potong' AND column_name='id_acc_faktur_pemasok') THEN
    ALTER TABLE acc_bukti_potong RENAME COLUMN id_acc_faktur_pemasok TO id_pur_faktur_pembelian;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_fkt_pur') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_fkt_pur
      FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES pur_faktur_pembelian(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_faktur_pelanggan') THEN
    ALTER TABLE acc_faktur_pajak DROP CONSTRAINT fk_acc_fpajak_faktur_pelanggan;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='acc_faktur_pajak' AND column_name='id_acc_faktur_pelanggan') THEN
    ALTER TABLE acc_faktur_pajak RENAME COLUMN id_acc_faktur_pelanggan TO id_sls_faktur_pelanggan;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_fkt_sls') THEN
    ALTER TABLE acc_faktur_pajak ADD CONSTRAINT fk_acc_fpajak_fkt_sls
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

DO $$ BEGIN
  -- POS M38: semantik diperpetukan (RESTRICT NOT VALID) dengan pemilik baru.
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_pesanan_acc_faktur') THEN
    ALTER TABLE pos_pesanan DROP CONSTRAINT fk_pos_pesanan_acc_faktur;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name='pos_pesanan' AND column_name='id_acc_faktur') THEN
    ALTER TABLE pos_pesanan RENAME COLUMN id_acc_faktur TO id_sls_faktur_pelanggan;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_pesanan_sls_faktur') THEN
    ALTER TABLE pos_pesanan ADD CONSTRAINT fk_pos_pesanan_sls_faktur
      FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES sls_faktur_pelanggan(id)
      ON UPDATE CASCADE ON DELETE RESTRICT NOT VALID;
  END IF;
  COMMENT ON COLUMN pos_pesanan.id_sls_faktur_pelanggan IS
    'Faktur pelanggan SLS terkait (M38 — pindah kepemilikan dari ACC, ddl/88); diisi via outbox status faktur';
END $$;

-- -----------------------------------------------------------------------------
-- §4 RENAME CONSTRAINT/INDEX/TRIGGER pada tabel hasil rename (kepemilikan nama)
-- -----------------------------------------------------------------------------

DO $$ DECLARE v_r text; BEGIN
  FOREACH v_r IN ARRAY ARRAY[
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT acc_faktur_pelanggan_pkey TO sls_faktur_pelanggan_pkey',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT fk_acc_fktplg_pelanggan TO fk_sls_fktplg_pelanggan',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT fk_acc_fktplg_penyusun TO fk_sls_fktplg_penyusun',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT fk_acc_fktplg_pesanan_penjualan TO fk_sls_fktplg_pesanan_penjualan',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT fk_acc_fktplg_termin TO fk_sls_fktplg_termin',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT uq_acc_fktplg_entity_id TO uq_sls_fktplg_entity_id',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT uq_acc_fktplg_nomor TO uq_sls_fktplg_nomor',
    'ALTER TABLE sls_faktur_pelanggan RENAME CONSTRAINT uq_acc_fktplg_idempoten TO uq_sls_fktplg_idempoten',
    'ALTER INDEX ix_acc_fktplg_aging RENAME TO ix_sls_fktplg_aging',
    'ALTER INDEX ix_acc_fktplg_draft RENAME TO ix_sls_fktplg_draft',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT acc_faktur_pelanggan_items_pkey TO sls_faktur_pelanggan_items_pkey',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT fk_acc_fktplg_items_faktur TO fk_sls_fktplg_items_faktur',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT fk_acc_fktplg_items_pajak TO fk_sls_fktplg_items_pajak',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT fk_acc_fktplg_items_produk TO fk_sls_fktplg_items_produk',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT acc_faktur_pelanggan_items_qty_check TO sls_faktur_pelanggan_items_qty_check',
    'ALTER TABLE sls_faktur_pelanggan_items RENAME CONSTRAINT uq_acc_fktplg_items_entity_id TO uq_sls_fktplg_items_entity_id',
    'ALTER INDEX ix_acc_fktplg_items_faktur RENAME TO ix_sls_fktplg_items_faktur',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT acc_faktur_pemasok_pkey TO pur_faktur_pembelian_pkey',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT fk_acc_fktpms_pemasok TO fk_pur_fktpms_pemasok',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT fk_acc_fktpms_penyusun TO fk_pur_fktpms_penyusun',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT fk_acc_fktpms_po TO fk_pur_fktpms_po',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT fk_acc_fktpms_termin TO fk_pur_fktpms_termin',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT uq_acc_fktpms_entity_id TO uq_pur_fktpms_entity_id',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT uq_acc_fktpms_nomor TO uq_pur_fktpms_nomor',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT uq_acc_fktpms_bill_pemasok TO uq_pur_fktpms_bill_pemasok',
    'ALTER TABLE pur_faktur_pembelian RENAME CONSTRAINT uq_acc_fktpms_idempoten TO uq_pur_fktpms_idempoten',
    'ALTER INDEX ix_acc_fktpms_aging RENAME TO ix_pur_fktpms_aging',
    'ALTER INDEX ix_acc_fktpms_draft RENAME TO ix_pur_fktpms_draft',
    'ALTER INDEX ix_acc_fktpms_po RENAME TO ix_pur_fktpms_po',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT acc_faktur_pemasok_items_pkey TO pur_faktur_pembelian_items_pkey',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT fk_acc_fktpms_items_faktur TO fk_pur_fktpms_items_faktur',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT fk_acc_fktpms_items_pajak TO fk_pur_fktpms_items_pajak',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT fk_acc_fktpms_items_produk TO fk_pur_fktpms_items_produk',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT acc_faktur_pemasok_items_qty_check TO pur_faktur_pembelian_items_qty_check',
    'ALTER TABLE pur_faktur_pembelian_items RENAME CONSTRAINT uq_acc_fktpms_items_entity_id TO uq_pur_fktpms_items_entity_id',
    'ALTER INDEX ix_acc_fktpms_items_faktur RENAME TO ix_pur_fktpms_items_faktur'
  ] LOOP
    BEGIN
      EXECUTE v_r;
    EXCEPTION WHEN OTHERS THEN
      NULL; -- idempoten: sudah direname / nama lama tak ada (state diverifikasi §8)
    END;
  END LOOP;
END $$;

DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'trg_acc_faktur_pelanggan_updated_at|trg_sls_faktur_pelanggan_updated_at|sls_faktur_pelanggan',
    'trg_acc_faktur_pelanggan_items_updated_at|trg_sls_faktur_pelanggan_items_updated_at|sls_faktur_pelanggan_items',
    'trg_acc_faktur_pemasok_updated_at|trg_pur_faktur_pembelian_updated_at|pur_faktur_pembelian',
    'trg_acc_faktur_pemasok_items_updated_at|trg_pur_faktur_pembelian_items_updated_at|pur_faktur_pembelian_items'
  ] LOOP
    DECLARE
      v_lama text := split_part(v_t, '|', 1);
      v_baru text := split_part(v_t, '|', 2);
      v_tabel text := split_part(v_t, '|', 3);
    BEGIN
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_lama, v_tabel);
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_baru, v_tabel);
      EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I
                      FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_baru, v_tabel);
    END;
  END LOOP;
END $$;

-- Sequence identity ikut tabel; rapikan nama (guard idempoten).
DO $$ DECLARE v_s text; BEGIN
  FOREACH v_s IN ARRAY ARRAY[
    'acc_faktur_pelanggan_id_seq|sls_faktur_pelanggan_id_seq',
    'acc_faktur_pelanggan_items_id_seq|sls_faktur_pelanggan_items_id_seq',
    'acc_faktur_pemasok_id_seq|pur_faktur_pembelian_id_seq',
    'acc_faktur_pemasok_items_id_seq|pur_faktur_pembelian_items_id_seq'
  ] LOOP
    DECLARE
      v_lama text := split_part(v_s, '|', 1);
      v_baru text := split_part(v_s, '|', 2);
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_sequences WHERE sequencename = v_lama)
         AND NOT EXISTS (SELECT 1 FROM pg_sequences WHERE sequencename = v_baru) THEN
        EXECUTE format('ALTER SEQUENCE %I RENAME TO %I', v_lama, v_baru);
      END IF;
    END;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- §5 SPLIT acc_faktur_cicilan → sls_faktur_cicilan + pur_faktur_cicilan
--    (CK tepat-satu menjamin tiap baris tepat satu sisi; data ikut sisi itu)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sls_faktur_cicilan (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_sls_faktur_pelanggan bigint NOT NULL,
  urutan                  integer NOT NULL DEFAULT 1,
  tanggal_jatuh_tempo     date NOT NULL,
  nilai_cicilan           numeric(18,4) NOT NULL,
  sisa_cicilan            numeric(18,4) NOT NULL DEFAULT 0,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_sls_fktcic_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_sls_fktcic_faktur FOREIGN KEY (id_sls_faktur_pelanggan)
    REFERENCES sls_faktur_pelanggan (id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT ck_sls_fktcic_nilai CHECK (nilai_cicilan > 0),
  CONSTRAINT ck_sls_fktcic_sisa CHECK (sisa_cicilan >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sls_fktcic_faktur_urutan
  ON sls_faktur_cicilan (id_sls_faktur_pelanggan, urutan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_sls_fktcic_jatuh_tempo
  ON sls_faktur_cicilan (tanggal_jatuh_tempo)
  WHERE deleted_at IS NULL AND sisa_cicilan > 0;

CREATE TABLE IF NOT EXISTS pur_faktur_cicilan (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_faktur_pembelian bigint NOT NULL,
  urutan                  integer NOT NULL DEFAULT 1,
  tanggal_jatuh_tempo     date NOT NULL,
  nilai_cicilan           numeric(18,4) NOT NULL,
  sisa_cicilan            numeric(18,4) NOT NULL DEFAULT 0,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_pur_fktcic_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_fktcic_faktur FOREIGN KEY (id_pur_faktur_pembelian)
    REFERENCES pur_faktur_pembelian (id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT ck_pur_fktcic_nilai CHECK (nilai_cicilan > 0),
  CONSTRAINT ck_pur_fktcic_sisa CHECK (sisa_cicilan >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_pur_fktcic_faktur_urutan
  ON pur_faktur_cicilan (id_pur_faktur_pembelian, urutan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_fktcic_jatuh_tempo
  ON pur_faktur_cicilan (tanggal_jatuh_tempo)
  WHERE deleted_at IS NULL AND sisa_cicilan > 0;

DO $$ BEGIN
  IF to_regclass('public.acc_faktur_cicilan') IS NOT NULL THEN
    INSERT INTO sls_faktur_cicilan (entity_id, id_sls_faktur_pelanggan, urutan,
                                    tanggal_jatuh_tempo, nilai_cicilan, sisa_cicilan,
                                    version, created_at, updated_at, deleted_at)
    SELECT entity_id, id_acc_faktur_pelanggan, urutan, tanggal_jatuh_tempo,
           nilai_cicilan, sisa_cicilan, version, created_at, updated_at, deleted_at
    FROM acc_faktur_cicilan
    WHERE id_acc_faktur_pelanggan IS NOT NULL
    ON CONFLICT (entity_id) DO NOTHING;

    INSERT INTO pur_faktur_cicilan (entity_id, id_pur_faktur_pembelian, urutan,
                                    tanggal_jatuh_tempo, nilai_cicilan, sisa_cicilan,
                                    version, created_at, updated_at, deleted_at)
    SELECT entity_id, id_acc_faktur_pemasok, urutan, tanggal_jatuh_tempo,
           nilai_cicilan, sisa_cicilan, version, created_at, updated_at, deleted_at
    FROM acc_faktur_cicilan
    WHERE id_acc_faktur_pemasok IS NOT NULL
    ON CONFLICT (entity_id) DO NOTHING;

    PERFORM setval(pg_get_serial_sequence('sls_faktur_cicilan', 'id'),
                   COALESCE((SELECT MAX(id) FROM sls_faktur_cicilan), 1));
    PERFORM setval(pg_get_serial_sequence('pur_faktur_cicilan', 'id'),
                   COALESCE((SELECT MAX(id) FROM pur_faktur_cicilan), 1));

    DROP TABLE acc_faktur_cicilan;
    RAISE NOTICE 'PATCH 88: acc_faktur_cicilan di-split & di-drop';
  ELSE
    RAISE NOTICE 'PATCH 88: acc_faktur_cicilan tidak ada — split dilewati';
  END IF;
END $$;

-- Trigger updated_at dua tabel cicilan baru (fungsi generik CORE).
DO $$ BEGIN
  EXECUTE 'DROP TRIGGER IF EXISTS trg_sls_faktur_cicilan_updated_at ON sls_faktur_cicilan';
  EXECUTE 'CREATE TRIGGER trg_sls_faktur_cicilan_updated_at BEFORE UPDATE ON sls_faktur_cicilan
           FOR EACH ROW EXECUTE FUNCTION set_updated_at()';
  EXECUTE 'DROP TRIGGER IF EXISTS trg_pur_faktur_cicilan_updated_at ON pur_faktur_cicilan';
  EXECUTE 'CREATE TRIGGER trg_pur_faktur_cicilan_updated_at BEFORE UPDATE ON pur_faktur_cicilan
           FOR EACH ROW EXECUTE FUNCTION set_updated_at()';
END $$;

-- -----------------------------------------------------------------------------
-- §6 DROP acc_komitmen_po — fitur dihapus (0 FK masuk; penulis tunggal = seed;
--    konsumen event PUR M05 tidak pernah ada). Data 1 baris seed ikut hilang
--    (arsip tarball + seed lama = undo).
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS acc_komitmen_po;

-- -----------------------------------------------------------------------------
-- §6b PINDAH core_sequences penomoran faktur ke modul pemilik baru
--     (invoice_sales → sales/SLS; invoice_purchase → purchasing/PUR)
-- -----------------------------------------------------------------------------

DO $$ BEGIN
  UPDATE core_sequences s
  SET id_core_modules = (SELECT id FROM core_modules WHERE key = 'sales')
  WHERE s.doc_name = 'invoice_sales'
    AND s.id_core_modules = (SELECT id FROM core_modules WHERE key = 'accounting')
    AND EXISTS (SELECT 1 FROM core_modules WHERE key = 'sales');
  UPDATE core_sequences s
  SET id_core_modules = (SELECT id FROM core_modules WHERE key = 'purchasing')
  WHERE s.doc_name = 'invoice_purchase'
    AND s.id_core_modules = (SELECT id FROM core_modules WHERE key = 'accounting')
    AND EXISTS (SELECT 1 FROM core_modules WHERE key = 'purchasing');
END $$;

-- -----------------------------------------------------------------------------
-- §7 COMMENT — kepemilikan baru
-- -----------------------------------------------------------------------------

COMMENT ON TABLE sls_faktur_pelanggan IS
  'TRANSAKSI faktur penjualan (AR) — PEMILIK MODUL SLS (pindah dari ACC 2026-11-24, ddl/88); posting → jurnal ACC via bridge ACC; nomor unik global + idempoten key.';
COMMENT ON TABLE sls_faktur_pelanggan_items IS
  'LINE item faktur penjualan SLS — snapshot produk/pajak saat transaksi.';
COMMENT ON TABLE sls_faktur_cicilan IS
  'LINE jadwal cicilan faktur penjualan SLS (pindah dari acc_faktur_cicilan — split ddl/88).';
COMMENT ON TABLE pur_faktur_pembelian IS
  'TRANSAKSI faktur pembelian (AP, 3-way match) — PEMILIK MODUL PURCHASING (pindah dari ACC "faktur pemasok" 2026-11-24, ddl/88).';
COMMENT ON TABLE pur_faktur_pembelian_items IS
  'LINE item faktur pembelian PUR — snapshot produk/pajak saat transaksi.';
COMMENT ON TABLE pur_faktur_cicilan IS
  'LINE jadwal cicilan faktur pembelian PUR (pindah dari acc_faktur_cicilan — split ddl/88).';

COMMIT;

-- =============================================================================
-- §8 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Apply      : podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/88-acc-faktur-pindah.sql  (2× — identik)
-- Tabel baru : SELECT to_regclass('public.sls_faktur_pelanggan'),
--                     to_regclass('public.sls_faktur_pelanggan_items'),
--                     to_regclass('public.sls_faktur_cicilan'),
--                     to_regclass('public.pur_faktur_pembelian'),
--                     to_regclass('public.pur_faktur_pembelian_items'),
--                     to_regclass('public.pur_faktur_cicilan');   → semua NOT NULL
-- Tabel hilang: SELECT to_regclass('public.acc_faktur_pelanggan') IS NULL
--              AND to_regclass('public.acc_faktur_pemasok') IS NULL
--              AND to_regclass('public.acc_faktur_cicilan') IS NULL
--              AND to_regclass('public.acc_komitmen_po') IS NULL;          → true
-- Data utuh  : SELECT (SELECT count(*) FROM sls_faktur_pelanggan) +
--                     (SELECT count(*) FROM pur_faktur_pembelian);        → 6 (3+3)
-- Re-point   : SELECT conrelid::regclass, conname FROM pg_constraint
--              WHERE confrelid IN ('sls_faktur_pelanggan'::regclass,
--                                  'pur_faktur_pembelian'::regclass)
--              ORDER BY 1;  → nota/alokasi/jurnal/event_log/bupot/fpajak/
--                             pos_pesanan/items/cicilan (12 FK penunjuk)
-- Komitmen   : SELECT to_regclass('public.acc_komitmen_po');               → NULL
-- =============================================================================
