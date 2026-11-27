-- =============================================================================
-- PATCH DDL 31-pos-sls-integrasi.sql — Integrasi POS→SLS (jembatan struk ↔ SO)
-- Domain   : OdooLikeERP · Modul POS (pemilik junction) × Modul SLS (pemilik SO)
--            — struk kasir dan sales order menjadi SATU sumber transaksi
--            penjualan.
-- Keputusan: user/pemilik modul POS & SLS (2026-11-06) — integrasi POS→SLS
--            disetujui: setiap struk kasir (pos_pesanan) dijembatani 1:1 ke
--            sales order (sls_pesanan_penjualan) via DUA tabel junction baru
--            milik modul POS; enum jenis_sumber SO (enum_jenis_sumber_so_sls)
--            mendapat nilai 'POS'. Kartu klasifikasi sudah lolos gerbang
--            arsitektur-database.
-- Isi      : ALTER TYPE enum_jenis_sumber_so_sls ADD VALUE 'POS' (statement
--            TOP-LEVEL — aturan transaksi ALTER TYPE ADD VALUE; nilai baru
--            TIDAK dipakai statement lain di patch ini) + 2 tabel [JUNCTION]
--            murni tanpa kolom bisnis (tanpa kolom varchar/text/enum/jsonb
--            baru; TANPA seed):
--            • pos_pesanan_sls       — jembatan 1:1 HEADER struk↔SO
--            • pos_pesanan_item_sls  — jembatan 1:1 BARIS struk↔baris SO
-- Prasyarat: ddl/23-pos.sql (pos_pesanan, pos_pesanan_items, fungsi
--            set_updated_at dari 01-core) + ddl/28-sls.sql
--            (enum_jenis_sumber_so_sls, sls_pesanan_penjualan,
--            sls_pesanan_items).
-- Idempoten: aman dijalankan berulang (ADD VALUE IF NOT EXISTS, CREATE TABLE
--            IF NOT EXISTS, trigger DO-block DROP+CREATE).
-- Status   : MENYUSUL EKSEKUSI — patch ditulis 2026-11-06; belum dieksekusi
--            ke DB (TERPASANG dicatat setelah eksekusi + verifikasi idempoten).
-- Mirror   : schema/pos.ts + schema/sls.ts (Drizzle) disinkronkan di batch
--            yang sama dengan eksekusi patch ini.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. ENUM — jenis_sumber SO SLS bertambah 'POS' (struk kasir = sumber SO)
-- -----------------------------------------------------------------------------
-- Dijalankan sebagai STATEMENT TOP-LEVEL — bukan di dalam DO block / transaksi
-- eksplisit (ALTER TYPE ... ADD VALUE punya aturan transaksi PG tersendiri;
-- nilai baru tidak dirujuk statement mana pun di patch ini sehingga aman).
-- IF NOT EXISTS = idempoten; jenis_sumber tetap DEFAULT 'MANUAL' untuk SO lain.
ALTER TYPE enum_jenis_sumber_so_sls ADD VALUE IF NOT EXISTS 'POS';

-- -----------------------------------------------------------------------------
-- B. [JUNCTION] pos_pesanan_sls — jembatan 1:1 HEADER struk kasir ↔ sales order
-- -----------------------------------------------------------------------------
-- Milik modul POS (pola junction 23-pos: tanpa entity_id/version, tanpa kolom
-- bisnis). 1 struk = tepat 1 SO (PK dari sisi struk); 1 SO maksimal 1 link
-- (uq_pos_pesanan_sls_so). Baris IMMUTABLE — append-only via service, tidak
-- di-update/dihapus; link tidak dipakai ulang → UNIQUE GLOBAL tanpa filter
-- deleted_at. Akses dua arah tercakup PK + UNIQUE (tanpa index tambahan).
CREATE TABLE IF NOT EXISTS pos_pesanan_sls (
  id_pos_pesanan           bigint NOT NULL,
  id_sls_pesanan_penjualan bigint NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT pk_pos_pesanan_sls PRIMARY KEY (id_pos_pesanan),
  CONSTRAINT uq_pos_pesanan_sls_so UNIQUE (id_sls_pesanan_penjualan),
  CONSTRAINT fk_pos_pesanan_sls_struk FOREIGN KEY (id_pos_pesanan)
    REFERENCES pos_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_sls_so FOREIGN KEY (id_sls_pesanan_penjualan)
    REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT
);

COMMENT ON TABLE pos_pesanan_sls IS
  '[JUNCTION] jembatan 1:1 struk kasir (pos_pesanan) <-> sales order'
  ' (sls_pesanan_penjualan) — satu sumber transaksi penjualan; tanpa kolom'
  ' bisnis; baris immutable (append-only via service); pemilik modul POS.';

-- -----------------------------------------------------------------------------
-- C. [JUNCTION] pos_pesanan_item_sls — jembatan 1:1 BARIS struk ↔ baris SO
-- -----------------------------------------------------------------------------
-- Pemetaan baris struk↔baris SO untuk faktur M07/audit; dipakai refund jalur
-- lama menyusul retur SLS. Baris IMMUTABLE (append-only via service); link
-- baris SO tidak dipakai ulang → UNIQUE GLOBAL tanpa filter deleted_at.
-- Akses dua arah tercakup PK + UNIQUE (tanpa index tambahan).
CREATE TABLE IF NOT EXISTS pos_pesanan_item_sls (
  id_pos_pesanan_items bigint NOT NULL,
  id_sls_pesanan_items bigint NOT NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT pk_pos_pesanan_item_sls PRIMARY KEY (id_pos_pesanan_items),
  CONSTRAINT uq_pos_pesanan_item_sls_baris_so UNIQUE (id_sls_pesanan_items),
  CONSTRAINT fk_pos_pesanan_item_sls_item_pos FOREIGN KEY (id_pos_pesanan_items)
    REFERENCES pos_pesanan_items (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pos_pesanan_item_sls_baris_so FOREIGN KEY (id_sls_pesanan_items)
    REFERENCES sls_pesanan_items (id) ON DELETE RESTRICT
);

COMMENT ON TABLE pos_pesanan_item_sls IS
  '[JUNCTION] jembatan 1:1 baris struk kasir (pos_pesanan_items) <-> baris SO'
  ' (sls_pesanan_items) — pemetaan baris struk↔baris SO untuk faktur M07/'
  'audit; dipakai refund jalur lama menyusul retur SLS; tanpa kolom bisnis;'
  ' baris immutable (append-only via service); pemilik modul POS.';

-- -----------------------------------------------------------------------------
-- D. Trigger updated_at — 2 tabel junction (satu jalur refresh, D-04; fungsi
--    di 01-core; pola 23-pos)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'pos_pesanan_sls',
    'pos_pesanan_item_sls'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- PATCH 31-pos-sls-integrasi.sql selesai.
