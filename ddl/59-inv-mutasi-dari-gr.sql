-- =============================================================================
-- PATCH DDL 59-inv-mutasi-dari-gr.sql — MUTASI PENERIMAAN DARI GR (INV ↔ GR PUR)
-- (2026-11-12)
-- =============================================================================
-- KARTU ARSITEKTUR (arsitektur-database):
--   inv_mutasi_dokumen     | PERLUASAN [TRANSAKSI] — pemilik: INVENTORY
--                          | +1 kolom soft-id `id_pur_penerimaan` (tanpa FK)
--                          | +1 partial unique `uq_inv_mutasi_gr_ref`
--   inv_mutasi_items       | PERLUASAN [LINE] — pemilik: INVENTORY
--                          | +1 kolom soft-id `id_pur_penerimaan_item` (tanpa FK)
--                          | +1 partial index `ix_inv_mutasi_items_gr_item`
--   Referensi GR PUR = SOFT-ID (pola PP-02/03 "ACC/AST/FIN = id tanpa FK"):
--   inv_mutasi_dokumen.id_pur_penerimaan → pur_penerimaan.id (pemilik PUR,
--   ddl/57) TANPA constraint FK — INV hanya MEMBACA GR (pull generate),
--   tidak pernah menulis tabel PUR; pemutusan ketergantungan deploy
--   (urutan patch modul bebas), GR tetap hidup walau mutasi dihapus lunak
--   dan sebaliknya. Integritas logis ditegakkan app (mutasi.service.ts):
--   GR wajib ada & DITERIMA saat generate; partial unique menjaga 1 GR = 1
--   mutasi hidup (idempoten generate).
--
-- ALASAN (keputusan pemilik 2026-11-12): arah TERIMA jalur aktif kini
--   GR→mutasi (pull, bukan konsumen outbox) — Staf Gudang membuka daftar GR
--   DITERIMA yang belum dimutasi, INV membentuk dokumen mutasi PENERIMAAN
--   (VENDOR→INTERNAL) per GR. Konversi satuan PUR-BR16 dieksekusi INV (qty
--   GR unit beli → qty dasar via inv_unit_konversi). Nilai persediaan =
--   harga PO net (harga × (1 − diskon_persen/100)) ÷ faktor konversi per
--   satuan dasar — dibawa ke inv_gerakan_stok.nilai_persatuan saat posting.
--   Baris GR kondisi TOLAK tidak dimutasi (setara PUR-BR33 — tidak masuk
--   stok). Outbox `pur.penerimaan.diterima` tetap BELUM dikonsumsi (backlog)
--   — jalur aktif = pull generate ini.
--
-- ISI PATCH:
--   (a) ALTER TABLE inv_mutasi_dokumen ADD COLUMN id_pur_penerimaan bigint
--       NULL — TANPA FK (soft-id; komentar alasan di kolom);
--   (b) partial UNIQUE uq_inv_mutasi_gr_ref ON inv_mutasi_dokumen
--       (id_pur_penerimaan) WHERE deleted_at IS NULL AND
--       id_pur_penerimaan IS NOT NULL — 1 GR = 1 mutasi hidup;
--   (c) ALTER TABLE inv_mutasi_items ADD COLUMN id_pur_penerimaan_item
--       bigint NULL — TANPA FK + partial index
--       ix_inv_mutasi_items_gr_item (id_pur_penerimaan_item) WHERE
--       deleted_at IS NULL (jejak baris GR sumber per item mutasi);
--   (d) COMMENT ON COLUMN alasan soft-id (pola PP-02/03).
--
-- PRASYARAT: ddl/02-inventory.sql (inv_mutasi_dokumen, inv_mutasi_items) +
--            ddl/57-penerimaan-barang.sql (pur_penerimaan, pur_penerimaan_item).
-- Idempoten: penuh — ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT EXISTS
--            (partial index dengan predikat identik; COMMENT no-op) —
--            run ke-2 = no-op semua seksi.
-- Penerapan: PGPASSWORD=<pw> psql -h 127.0.0.1 -p 15433 -U nexierp \
--              -d nexierp -v ON_ERROR_STOP=1 < ddl/59-inv-mutasi-dari-gr.sql
--              (2×; db test: -d nexierp_test — 2× juga)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- (a) inv_mutasi_dokumen.id_pur_penerimaan — soft-id GR sumber (tanpa FK)
-- -----------------------------------------------------------------------------
ALTER TABLE inv_mutasi_dokumen
  ADD COLUMN IF NOT EXISTS id_pur_penerimaan bigint NULL;
COMMENT ON COLUMN inv_mutasi_dokumen.id_pur_penerimaan IS
  'Soft-id GR PUR sumber (pur_penerimaan.id — pemilik PURCHASING, ddl/57) — TANPA FK (pola PP-02/03 "ACC/AST/FIN = id tanpa FK"): INV hanya membaca GR (pull generate mutasi penerimaan, arah TERIMA jalur aktif) dan tidak pernah menulis tabel PUR; integritas logis ditegakkan app (GR wajib DITERIMA saat generate). NULL = mutasi manual (bukan dari GR).';

-- -----------------------------------------------------------------------------
-- (b) partial unique — 1 GR = 1 mutasi hidup (idempoten generate)
--     Retry/klik ganda "generate dari GR" → kunci sama → unique index
--     menahan duplikat; GR lama yang mutasinya dihapus lunak bisa
--     di-generate ulang (predikat deleted_at).
-- -----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_inv_mutasi_gr_ref
  ON inv_mutasi_dokumen (id_pur_penerimaan)
  WHERE deleted_at IS NULL AND id_pur_penerimaan IS NOT NULL;

-- -----------------------------------------------------------------------------
-- (c) inv_mutasi_items.id_pur_penerimaan_item — soft-id baris GR sumber
-- -----------------------------------------------------------------------------
ALTER TABLE inv_mutasi_items
  ADD COLUMN IF NOT EXISTS id_pur_penerimaan_item bigint NULL;
COMMENT ON COLUMN inv_mutasi_items.id_pur_penerimaan_item IS
  'Soft-id baris GR sumber (pur_penerimaan_item.id — pemilik PURCHASING, ddl/57) — TANPA FK (pola PP-02/03): jejak asal baris untuk konversi satuan PUR-BR16 (qty unit beli → qty dasar) & nilai harga PO net per satuan dasar saat posting/konfirmasi gerakan; baris GR TOLAK tidak pernah dimutasi (setara PUR-BR33). NULL = item manual.';
CREATE INDEX IF NOT EXISTS ix_inv_mutasi_items_gr_item
  ON inv_mutasi_items (id_pur_penerimaan_item)
  WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT column_name, data_type FROM information_schema.columns
--     WHERE table_name='inv_mutasi_dokumen'
--       AND column_name='id_pur_penerimaan';                       -- 1 (bigint)
--   SELECT column_name, data_type FROM information_schema.columns
--     WHERE table_name='inv_mutasi_items'
--       AND column_name='id_pur_penerimaan_item';                  -- 1 (bigint)
--   SELECT indexdef FROM pg_indexes WHERE indexname IN
--     ('uq_inv_mutasi_gr_ref','ix_inv_mutasi_items_gr_item');      -- 2 (partial)
--   SELECT obj_description('inv_mutasi_dokumen'::regclass::oid) IS NOT NULL; -- true
-- =============================================================================
