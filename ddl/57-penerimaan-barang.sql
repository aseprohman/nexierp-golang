-- =============================================================================
-- PATCH DDL 57-penerimaan-barang.sql — FITUR PENERIMAAN BARANG (GR) PUR-F20
-- (2026-11-12)
-- =============================================================================
-- KARTU ARSITEKTUR (arsitektur-database):
--   pur_penerimaan         | [TRANSAKSI] | pemilik: PURCHASING (PUR-F20)
--   pur_penerimaan_item    | [LINE]      (baris terima per baris PO + kondisi)
--   PK `id bigint IDENTITY` + `entity_id uuid` Tier A (unique global) |
--   FK: id_pur_pesanan → pur_pesanan RESTRICT (riwayat PO selamat);
--       id_inv_gudang → inv_gudang RESTRICT (NULL = warisi gudang PO saat
--       create app-side; kolom tetap nullable di DB);
--       id_core_users_penerima → core_users SET NULL (user boleh dihapus,
--       jejak baris tinggal);
--       id_pur_pesanan_item → pur_pesanan_item RESTRICT;
--       id_inv_produk → inv_produk RESTRICT.
--   Konsumen rujuk/baca: INV (outbox `pur.penerimaan.diterima` — arah TERIMA
--   menggantikan jalur M04 lama), ACC (dasar draft faktur 3-way via status
--   akumulasi PO — tanpa FK).
--
-- ALASAN (keputusan pemilik 2026-11-12 — PUR-F20): PUR kini MEMILIKI entitas
-- penerimaan barang (GR) header-detail yang di-generate dari PO — parsial,
-- multi-GR per PO. Posting GR satu transaksi: akumulasi
-- pur_pesanan_item.qty_diterima (kondisi ≠ TOLAK) + recompute
-- pur_pesanan.status_penerimaan + outbox `pur.penerimaan.diterima`
-- (idempoten key `penerimaan:<id>`). A-03 analisa-modul-pur ("PUR memegang
-- status & akumulasi, bukan entitas penerimaan") ditulis ulang; M04 arah
-- TERIMA disupersedi — M04 tetap untuk arah KEMBALI retur & penanda_sisa.
--
-- ISI PATCH:
--   (a) 2 enum baru: pur_status_penerimaan (DRAFT|DITERIMA|DIBATALKAN —
--       lifecycle GR; BERBEDA dari enum_status_penerimaan_pur yang adalah
--       trek pelengkap progres PO) + pur_kondisi_terima (BAIK|RUSAK|TOLAK);
--   (b) TABEL pur_penerimaan (header) + pur_penerimaan_item (line) — trio
--       audit + entity_id uuid + version + partial index + CHECK batal wajib
--       alasan (pola ck_pur_pesanan_batal) + CHECK qty > 0 (pola ck_*_qty);
--   (c) TRIGGER set_updated_at untuk 2 tabel (fungsi global ddl/01 §4);
--   (d) SEQUENCE ensure `purchase_receipt` prefix 'GR-{yyyy}' pad 4
--       (pola ddl/33 §sequences — guard registry core_modules; counter
--       berjalan TIDAK disentuh);
--   (e) COMMENT ON TABLE/COLUMN kepemilikan PURCHASING (PUR-F20).
--
-- PRASYARAT: ddl/25-purchasing.sql (pur_pesanan/pur_pesanan_item) +
--            ddl/01-core.sql (core_users, set_updated_at, core_modules/
--            core_sequences) + ddl/02-inventory.sql (inv_gudang, inv_produk).
-- Idempoten: penuh — CREATE TYPE/TABLE/INDEX/trigger ter-guard katalog
--            (pg_type/pg_class/to_regclass) dengan RAISE NOTICE per aksi;
--            run ke-2 = no-op semua seksi.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/57-penerimaan-barang.sql (2×)
--            (db test: -d nexierp_test — 2× juga)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- (a) ENUM — pur_status_penerimaan + pur_kondisi_terima
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
             WHERE t.typname = 'pur_status_penerimaan' AND n.nspname = 'public') THEN
    RAISE NOTICE 'enum pur_status_penerimaan sudah ada — lewati';
  ELSE
    CREATE TYPE pur_status_penerimaan AS ENUM ('DRAFT','DITERIMA','DIBATALKAN');
    RAISE NOTICE 'enum pur_status_penerimaan dibuat (DRAFT/DITERIMA/DIBATALKAN)';
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
             WHERE t.typname = 'pur_kondisi_terima' AND n.nspname = 'public') THEN
    RAISE NOTICE 'enum pur_kondisi_terima sudah ada — lewati';
  ELSE
    CREATE TYPE pur_kondisi_terima AS ENUM ('BAIK','RUSAK','TOLAK');
    RAISE NOTICE 'enum pur_kondisi_terima dibuat (BAIK/RUSAK/TOLAK)';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- (b1) [TRANSAKSI] pur_penerimaan — header Goods Receipt (GR, F20); lifecycle
--      DRAFT → DITERIMA (posting) | DIBATALKAN (wajib alasan — CHECK); GR
--      DITERIMA immutable (koreksi via GR baru/batal-DRAFT; retur tetap F14).
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  IF to_regclass('public.pur_penerimaan') IS NOT NULL THEN
    RAISE NOTICE 'tabel pur_penerimaan sudah ada — lewati CREATE TABLE';
    RETURN;
  END IF;

  CREATE TABLE pur_penerimaan (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
    nomor                 varchar(150) NOT NULL,     -- numbering GR-{yyyy} (core_sequences, PUR-BR01) — unique global
    id_pur_pesanan        bigint NOT NULL,           -- PO sumber (DISETUJUI/SELESAI — PUR-BR31)
    id_inv_gudang         bigint,                    -- gudang terima; NULL = warisi gudang PO (diisi app saat create)
    id_core_users_penerima bigint,                   -- penerima = aktor JWT saat create — SET NULL
    referensi_surat_jalan varchar(150),              -- nomor surat jalan pemasok (jejak fisik)
    tanggal_terima        timestamptz,               -- diisi saat POST :id/posting (DITERIMA)
    status                pur_status_penerimaan NOT NULL DEFAULT 'DRAFT',
    catatan               varchar(300),
    alasan_pembatalan     varchar(300),              -- wajib bila DIBATALKAN (PUR-BR05 — CHECK di bawah)
    version               integer NOT NULL DEFAULT 1,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    deleted_at            timestamptz,
    CONSTRAINT uq_pur_penerimaan_entity_id UNIQUE (entity_id),
    CONSTRAINT uq_pur_penerimaan_nomor UNIQUE (nomor),
    CONSTRAINT fk_pur_penerimaan_pesanan FOREIGN KEY (id_pur_pesanan)
      REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
    CONSTRAINT fk_pur_penerimaan_gudang FOREIGN KEY (id_inv_gudang)
      REFERENCES inv_gudang (id) ON DELETE RESTRICT,
    CONSTRAINT fk_pur_penerimaan_penerima FOREIGN KEY (id_core_users_penerima)
      REFERENCES core_users (id) ON DELETE SET NULL,
    CONSTRAINT ck_pur_penerimaan_batal
      CHECK (status <> 'DIBATALKAN' OR alasan_pembatalan IS NOT NULL)
  );

  CREATE INDEX ix_pur_penerimaan_pesanan
    ON pur_penerimaan (id_pur_pesanan) WHERE deleted_at IS NULL;
  CREATE INDEX ix_pur_penerimaan_status
    ON pur_penerimaan (status) WHERE deleted_at IS NULL;

  RAISE NOTICE 'tabel pur_penerimaan dibuat (header GR)';
END $$;

-- -----------------------------------------------------------------------------
-- (b2) [LINE] pur_penerimaan_item — baris terima per baris PO: qty_diterima
--      > 0 + kondisi (BAIK|RUSAK|TOLAK); TOLAK tidak menambah qty_diterima
--      PO & tidak dihitung sisa (PUR-BR33).
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  IF to_regclass('public.pur_penerimaan_item') IS NOT NULL THEN
    RAISE NOTICE 'tabel pur_penerimaan_item sudah ada — lewati CREATE TABLE';
    RETURN;
  END IF;

  CREATE TABLE pur_penerimaan_item (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
    id_pur_penerimaan    bigint NOT NULL,           -- header CASCADE (line ikut hidup-mati GR)
    id_pur_pesanan_item  bigint NOT NULL,           -- baris PO sumber — RESTRICT
    id_inv_produk        bigint NOT NULL,           -- produk terima (divalidasi sama baris PO di app)
    qty_diterima         integer NOT NULL,          -- unit baris PO (id_inv_unit_ukur milik baris PO)
    kondisi              pur_kondisi_terima NOT NULL DEFAULT 'BAIK',
    catatan              varchar(300),
    version              integer NOT NULL DEFAULT 1,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    deleted_at           timestamptz,
    CONSTRAINT uq_pur_penerimaan_item_entity_id UNIQUE (entity_id),
    CONSTRAINT fk_pur_penerimaan_item_penerimaan FOREIGN KEY (id_pur_penerimaan)
      REFERENCES pur_penerimaan (id) ON DELETE CASCADE,
    CONSTRAINT fk_pur_penerimaan_item_pesanan_item FOREIGN KEY (id_pur_pesanan_item)
      REFERENCES pur_pesanan_item (id) ON DELETE RESTRICT,
    CONSTRAINT fk_pur_penerimaan_item_produk FOREIGN KEY (id_inv_produk)
      REFERENCES inv_produk (id) ON DELETE RESTRICT,
    CONSTRAINT ck_pur_penerimaan_item_qty CHECK (qty_diterima > 0)
  );

  CREATE INDEX ix_pur_penerimaan_item_penerimaan
    ON pur_penerimaan_item (id_pur_penerimaan) WHERE deleted_at IS NULL;
  CREATE INDEX ix_pur_penerimaan_item_pesanan_item
    ON pur_penerimaan_item (id_pur_pesanan_item) WHERE deleted_at IS NULL;

  RAISE NOTICE 'tabel pur_penerimaan_item dibuat (line GR)';
END $$;

-- -----------------------------------------------------------------------------
-- (c) TRIGGER set_updated_at — 2 tabel mutable (jejak transisi status via
--     core_audit_trail STD-01; pola ddl/25 §4)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY['pur_penerimaan','pur_penerimaan_item'] LOOP
    IF to_regclass(format('public.%I', v_t)) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
      EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                      FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
      RAISE NOTICE 'trigger trg_%_updated_at di-ensure', v_t;
    ELSE
      RAISE NOTICE 'tabel % absen — trigger dilewati', v_t;
    END IF;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- (d) SEQUENCE ensure `purchase_receipt` — prefix 'GR-{yyyy}' pad 4 (pola
--     ddl/33 §sequences; guard registry core_modules fail-loud; counter
--     berjalan di live TIDAK disentuh).
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'purchasing') THEN
    RAISE EXCEPTION 'PATCH 57-penerimaan: registry core_modules key=''purchasing'' absen — baseline CORE wajib dulu';
  END IF;
END $$;

INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, 0, v.padding
FROM core_modules m
CROSS JOIN (VALUES
  ('purchase_receipt', 'GR-{yyyy}', 4)
) AS v(doc_name, prefix, padding)
WHERE m.key = 'purchasing'
  AND NOT EXISTS (
    SELECT 1 FROM core_sequences s
    WHERE s.doc_name = v.doc_name AND s.id_core_modules = m.id
  );

-- -----------------------------------------------------------------------------
-- (e) COMMENT ON TABLE/COLUMN — kepemilikan PURCHASING (PUR-F20, 2026-11-12)
-- -----------------------------------------------------------------------------
COMMENT ON TABLE pur_penerimaan IS
  '[TRANSAKSI] Penerimaan barang (Goods Receipt, GR) — PEMILIK PURCHASING (PUR-F20, keputusan pemilik 2026-11-12): header-detail di-generate dari PO DISETUJUI/SELESAI, parsial multi-GR per PO. Posting (DRAFT→DITERIMA) satu tx: akumulasi pur_pesanan_item.qty_diterima (kondisi ≠ TOLAK) + recompute pur_pesanan.status_penerimaan + outbox `pur.penerimaan.diterima` (idempoten key penerimaan:<id>) — konsumen INV (arah TERIMA menggantikan jalur M04 lama). GR DITERIMA immutable; DIBATALKAN wajib alasan (CHECK).';
COMMENT ON TABLE pur_penerimaan_item IS
  '[LINE] Baris terima per baris PO — atribut pur_penerimaan (PUR-F20): qty_diterima > 0 + kondisi BAIK|RUSAK|TOLAK; TOLAK tidak menambah qty_diterima PO & tidak dihitung sisa (PUR-BR33). Over-receipt TIDAK lewat GR — sisa efektif ditegakkan app (PUR-BR32).';
COMMENT ON COLUMN pur_penerimaan.status IS
  'Siklus hidup GR — enum pur_status_penerimaan (ddl/57): DRAFT → DITERIMA (posting) | DIBATALKAN. Berbeda dari enum_status_penerimaan_pur yang adalah trek pelengkap progres PO.';
COMMENT ON COLUMN pur_penerimaan.tanggal_terima IS
  'Waktu posting GR (POST :id/posting) — NULL selama DRAFT.';
COMMENT ON COLUMN pur_penerimaan_item.kondisi IS
  'Kondisi barang diterima — enum pur_kondisi_terima (ddl/57): BAIK (masuk stok), RUSAK (tetap menambah qty_diterima PO — tercatat diterima), TOLAK (ditolak — tidak menambah qty_diterima & tidak dihitung sisa, PUR-BR33).';

-- -----------------------------------------------------------------------------
-- VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT count(*) FROM pg_tables WHERE tablename IN
--     ('pur_penerimaan','pur_penerimaan_item');                          -- 2
--   SELECT typname FROM pg_type WHERE typname IN
--     ('pur_status_penerimaan','pur_kondisi_terima');                    -- 2
--   SELECT doc_name, prefix, padding FROM core_sequences s
--     JOIN core_modules m ON m.id = s.id_core_modules
--     WHERE m.key='purchasing' AND s.doc_name='purchase_receipt';        -- 1 (GR-{yyyy},4)
--   \d pur_penerimaan
--   \d pur_penerimaan_item
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conrelid IN ('pur_penerimaan'::regclass,
--                        'pur_penerimaan_item'::regclass) ORDER BY conname;
-- =============================================================================
-- ddl/57-penerimaan-barang.sql selesai.
