-- =====================================================================
-- 73-pur-permintaan-item-satuan.sql — FK satuan pada item permintaan
-- pembelian (PR, F02 modul purchasing).
--
-- Kartu klasifikasi (arsitektur-database):
--   tabel   : pur_permintaan_item [LINE] — pemilik modul `purchasing`
--   kolom   : id_inv_unit_ukur bigint NULL → inv_unit_ukur(id) RESTRICT
--   justifikasi nullable : satuan permintaan = PREFERENSI peminta;
--             kosong = qty dalam satuan dasar produk (K-05); satuan beli
--             final ditetapkan di PO (pur_pesanan_item.id_inv_unit_ukur
--             NOT NULL). Referensi LIVE (bukan snapshot) — unit master
--             jarang berubah dan preferensi ikut master.
--   index   : partial WHERE deleted_at IS NULL (pola ix item lain).
--   seed    : kolom nullable — potret PR lama aman tanpa perubahan.
-- Idempoten: cek kolom/constraint/index sebelum dibuat.
-- =====================================================================

BEGIN;

-- 1) Kolom (nullable — preferensi satuan)
ALTER TABLE pur_permintaan_item
  ADD COLUMN IF NOT EXISTS id_inv_unit_ukur bigint;

-- 2) FK RESTRICT (unit master INV — hindari orphan preferensi)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_pur_permintaan_item_unit'
      AND conrelid = 'pur_permintaan_item'::regclass
  ) THEN
    ALTER TABLE pur_permintaan_item
      ADD CONSTRAINT fk_pur_permintaan_item_unit
      FOREIGN KEY (id_inv_unit_ukur)
      REFERENCES inv_unit_ukur (id)
      ON DELETE RESTRICT;
  END IF;
END $$;

-- 3) Index partial — pola ix item lain di tabel ini
CREATE INDEX IF NOT EXISTS ix_pur_permintaan_item_unit
  ON pur_permintaan_item (id_inv_unit_ukur)
  WHERE deleted_at IS NULL AND id_inv_unit_ukur IS NOT NULL;

COMMIT;
