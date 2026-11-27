-- =============================================================================
-- PATCH DDL 54-inv-penyesuaian-kemasan.sql — Entry kemasan pada penyesuaian stok
-- Domain   : INV — tabel LINE `inv_penyesuaian_stok_items` menambah dukungan
--            entry ber-KEMASAN (refactor-modul-audit + arsitektur-database,
--            permintaan pemilik 2026-11-11): baris item kini membawa referensi
--            kemasan + SNAPSHOT faktor konversi agar ledger stok selalu
--            menerima qty SATUAN TERKECIL (kontrak readmodel inv_saldo_stok —
--            recompute-saldo menjumlah qty_selesai mentah).
-- Sumber   : audit form /inventory/operasi/penyesuaian — item belum mendukung
--            kemasan; ledger wajib dikonversi ke satuan terkecil. Kemasan
--            master (inv_kemasan) sudah punya qty_isi + barcode (patch 04,
--            P1 #10). Konversi ditegakkan SERVER: qty_hitung := qty_kemasan_
--            hitung × kemasan.qty_isi (apps/api penyesuaian.service sisipItems);
--            kemasan wajib memakai UNIT DASAR produk (inv_produk.
--            id_inv_unit_ukur) — kemasan ber-unit non-dasar ditolak 400
--            (konversi-chain unit_konversi = rekomendasi terpisah).
-- Tanggal  : 2026-11-11
-- Prasyarat: inv_kemasan live (patch 04); trio audit + version tabel LINE
--            sudah ada (tidak disentuh). VERIFIKASI live 2026-11-11: 2 kolom
--            belum ada; tabel hidup 0 baris transaksi (baru dikosongkan) —
--            backfill kolom aman tanpa migrasi data.
-- Isi      : §1 ADD COLUMN id_inv_kemasan (nullable — NULL = entry satuan
--            biasa) + isi_per_kemasan (snapshot beku faktor konversi);
--            §2 FK RESTRICT ke inv_kemasan (kemasan pernah dipakai historis
--            tidak boleh hilang — ON DELETE policy finansial/historis);
--            §3 CHECK snapshot: id terisi ⇒ isi_per_kemasan > 0;
--            §4 index FK utk join view.
-- Makna    : KARTU ARSITEKTUR inv_penyesuaian_stok_items | [LINE] + snapshot
--            (nama_produk, biaya_satuan, isi_per_kemasan) | pemilik INV |
--            id_inv_kemasan nullable (baris tanpa kemasan tetap sah).
-- Idempoten: ADD COLUMN IF NOT EXISTS + guard pg_constraint + CREATE INDEX
--            IF NOT EXISTS — aman dijalankan 2× (run-2 no-op).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom entry kemasan + snapshot faktor konversi.
-- -----------------------------------------------------------------------------
ALTER TABLE inv_penyesuaian_stok_items
  ADD COLUMN IF NOT EXISTS id_inv_kemasan bigint,
  ADD COLUMN IF NOT EXISTS isi_per_kemasan integer;

-- -----------------------------------------------------------------------------
-- §2 FK sungguhan — RESTRICT (baris LINE historis merujuk master kemasan).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_inv_penyesuaian_items_kemasan'
      AND conrelid = 'inv_penyesuaian_stok_items'::regclass
  ) THEN
    ALTER TABLE inv_penyesuaian_stok_items
      ADD CONSTRAINT fk_inv_penyesuaian_items_kemasan
      FOREIGN KEY (id_inv_kemasan)
      REFERENCES inv_kemasan(id)
      ON UPDATE CASCADE
      ON DELETE RESTRICT;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §3 CHECK — snapshot wajib terisi (> 0) bila kemasan direferensikan.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'ck_inv_penyesuaian_items_kemasan'
      AND conrelid = 'inv_penyesuaian_stok_items'::regclass
  ) THEN
    ALTER TABLE inv_penyesuaian_stok_items
      ADD CONSTRAINT ck_inv_penyesuaian_items_kemasan
      CHECK (id_inv_kemasan IS NULL OR isi_per_kemasan > 0);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §4 Index FK (join view / jejak per kemasan).
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_inv_penyesuaian_items_kemasan
  ON inv_penyesuaian_stok_items (id_inv_kemasan);

COMMIT;

-- ddl/54-inv-penyesuaian-kemasan.sql selesai.
