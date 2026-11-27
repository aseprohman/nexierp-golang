-- =============================================================================
-- PATCH DDL 78-pur-pesanan-item-sederhana.sql — PUR: `pur_pesanan_item`
-- sederhana (DROP `deskripsi` + `jenis_baris` + tipe `pur_jenis_baris`)
-- =============================================================================
-- Domain   : NEXIERP · Modul PURCHASING (PUR) — baris PO [LINE]. Bentuk live
--            DIUBAH PEMILIK LANGSUNG di DB (acuan per 2026-11-22); patch ini
--            MEMFORMALKAN transformasi bentuk `ddl/33-purchasing-fitur-
--            lanjutan.sql` → bentuk live. ddl/33 TIDAK disentuh (historis).
--            Tabel pur_pesanan_item KOSONG (0 baris) saat perubahan → tidak
--            ada migrasi data.
-- Kartu    :
--   pur_pesanan_item | [LINE] | PUR | perubahan:
--     - DROP kolom `deskripsi` varchar(300) NOT NULL — snapshot deskripsi
--       baris pensiun; label baris kini DITURUNKAN saat baca: repository PO
--       ber-join inv_produk (kode + nama produk) — tidak ada salinan teks
--       di baris transaksi.
--     - DROP kolom `jenis_baris` pur_jenis_baris NOT NULL DEFAULT 'BARANG'
--       (revisi-3 pensiun) — jenis baris PO kini DITURUNKAN dari
--       `inv_produk.tipe` (enum_tipe_produk = BARANG|JASA|BAHAN):
--       baris produk tipe ≠ 'JASA' (BARANG|BAHAN — barang fisik) masuk
--       jadwal penerimaan M03 (`pur.po.jadwal`); tipe = 'JASA' masuk
--       faktur jasa M08 (`pur.po.jasa`) — penurunan dieksekusi service
--       PUR saat setujui (emisi outbox), bukan kolom tersimpan.
--   tipe    : `pur_jenis_baris` DROPPED — terbukti tanpa pemakai kolom
--             lain (pg_attribute; hanya pur_pesanan_item.jenis_baris).
-- Idempoten: DROP COLUMN IF EXISTS / DO-block guard drop tipe (hanya bila
--            ada DAN tanpa pemakai kolom).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom hapusan — live DB pemilik sudah drop (langkah ini no-op di live;
--    baseline ddl/33 yang masih memegang kolom dibersihkan di sini).
-- -----------------------------------------------------------------------------

ALTER TABLE pur_pesanan_item
  DROP COLUMN IF EXISTS deskripsi,
  DROP COLUMN IF EXISTS jenis_baris;

-- -----------------------------------------------------------------------------
-- §2 DROP tipe pur_jenis_baris — HANYA bila tipe ada DAN terbukti tanpa
--    pemakai kolom (pg_attribute kosong).
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_oid oid;
BEGIN
  SELECT t.oid INTO v_oid
  FROM pg_type t
  WHERE t.typname = 'pur_jenis_baris';

  IF v_oid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.atttypid = v_oid
        AND a.attisdropped = false
    ) THEN
      RAISE NOTICE 'PATCH 78: pur_jenis_baris masih dipakai kolom — tipe TIDAK di-drop';
    ELSE
      DROP TYPE pur_jenis_baris;
    END IF;
  END IF;
END $$;

COMMIT;
