-- =============================================================================
-- PATCH DDL 25-purchasing.sql — Modul PURCHASING (rekonstruksi baru)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-pur.md (kanonik — revisi 2026-11-05, hasil
--            audit vs Odoo, lihat docs/audit-pur-vs-odoo.md; temuan P1–P4
--            teradopsi: retur F14, qty_diterima/qty_difaktur baris, penguncian
--            baris PUR-BR13, CFG-PUR-14 dasar faktur, atribut pajak pemasok,
--            tier harga + algoritma pemilihan PUR-BR06, rev_no penanda
--            amendment). Kepemilikan mengikuti docs/peta-modul.md §4.
-- Keputusan: master PEMASOK dipakai lintas modul (PUR, ACC — kartu
--   arsitektur-database-acc.md, INV reorder/valuasi) → pindah modul CORE
--   (keputusan pemilik 2026-11-06: "tabel lintas modul masuk core"):
--   core_pemasok / core_pemasok_kontak / core_pemasok_harga, enum
--   core_status_pemasok (rename yatim enum_status_pemasok_pur). Dokumen
--   transaksi tetap pur_* (pemilik PUR); 7 enum pur_* terdaftar di DB live
--   dipakai ulang persis.
-- KONDISI  : pgdb/nexierp live TANPA tabel pur_*/core_pemasok* (patch ini
--   DB LIVE  sumber kebenaran pertama struktur PUR), namun sudah membawa
--            (a) 8 enum yatim (7 pur_* + enum_status_pemasok_pur) berkosakata
--            persis mirror apps/api/src/core/database/schema/purchasing.ts
--            (diverifikasi blok §1 — fail-loud bila menyimpang),
--            (b) core_sequences 10 baris milik modul purchasing
--            (SUP/PR-/PO-/GR-/PINV-/PAY-/RET-/CN-/DN-/RLS — 4 yang dipakai
--            patch ini di-ensure §5, sisanya milik fase ACC/gratis),
--            (c) core_module_configs CFG-PUR-01..15 terisi skala PS2
--            (di-ensure ulang §5 utk install segar).
-- Prasyarat: baseline CORE (core_users, core_modules key='purchasing',
--            fungsi set_updated_at, ext btree_gist) + INV (inv_produk,
--            inv_unit_ukur, inv_gudang) — FK sungguhan ke id bigint.
-- Isi      : 10 tabel — 3 master CORE (1 MASTER + 2 LINE) + 3 TRANSAKSI PUR
--            + 4 LINE transaksi. Trio audit (created_at/updated_at/deleted_at)
--            + version (optimistic lock) + entity_id uuid + trigger
--            set_updated_at di SEMUA tabel.
-- Integrasi: inv_produk/inv_unit_ukur/inv_gudang FK RESTRICT; core_users FK
--            RESTRICT/SET NULL; ACC/AST/FIN = kontrak tanpa FK (id lintas
--            modul tanpa FK, konsisten arsitektur-database-acc.md §40);
--            penerimaan fisik tetap milik INV (A-03) via M03/M04.
-- Mirror   : apps/api/src/core/database/schema/purchasing.ts (1:1)
-- Idempoten: aman dijalankan berulang; REVISI-2: kolom penyusun SoD
--            (PUR-BR03/BR05 pembuat ≠ penyetuju) pada pur_pesanan & pur_retur
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0b) REVISI-2 — kolom penyusun SoD pada tabel transaksi yang sudah live
--     (install segar: sudah di-cover CREATE TABLE §3; blok ini no-op di sana)
-- -----------------------------------------------------------------------------
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS id_core_users_penyusun bigint;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pesanan_penyusun') THEN
    ALTER TABLE pur_pesanan ADD CONSTRAINT fk_pur_pesanan_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
ALTER TABLE pur_retur ADD COLUMN IF NOT EXISTS id_core_users_penyusun bigint;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_retur_penyusun') THEN
    ALTER TABLE pur_retur ADD CONSTRAINT fk_pur_retur_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1) ENUM — verifikasi kosakata fail-loud; rename yatim pemasok → core
-- -----------------------------------------------------------------------------
-- 1a) Master pemasok pindah modul CORE: legacy enum_status_pemasok_pur (yatim,
--     0 kolom pemakai — diverifikasi 2026-11-06) di-rename bila kosakata
--     persis; dibuang bila core_status_pemasok sudah ada.
DO $$
DECLARE
  v_cocok boolean;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
             WHERE t.typname = 'enum_status_pemasok_pur' AND n.nspname = 'public') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                   WHERE t.typname = 'core_status_pemasok' AND n.nspname = 'public') THEN
      SELECT (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
              FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
              WHERE t.typname = 'enum_status_pemasok_pur')
             = ARRAY['PROSPEK','AKTIF','NONAKTIF','DIBLOKIR']::text[]
      INTO v_cocok;
      IF NOT v_cocok THEN
        RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_pemasok_pur kosakata menyimpang dari mirror — selaraskan manual dulu';
      END IF;
      ALTER TYPE enum_status_pemasok_pur RENAME TO core_status_pemasok;
    ELSE
      DROP TYPE enum_status_pemasok_pur; -- kedua tipe ada → legacy yatim dibuang
    END IF;
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE core_status_pemasok AS ENUM ('PROSPEK','AKTIF','NONAKTIF','DIBLOKIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'core_status_pemasok')
     IS DISTINCT FROM ARRAY['PROSPEK','AKTIF','NONAKTIF','DIBLOKIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: core_status_pemasok kosakata menyimpang dari mirror';
  END IF;
END $$;

-- 1b) Tujuh enum transaksi pur_* — buat bila belum ada; bila sudah, verifikasi
--     kosakata persis mirror (fail-loud bila menyimpang).
DO $$ BEGIN
  CREATE TYPE enum_status_permintaan_pur AS ENUM
    ('DRAFT','DIAJUKAN','DISETUJUI','DITOLAK','TERKONVERSI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_permintaan_pur')
     IS DISTINCT FROM ARRAY['DRAFT','DIAJUKAN','DISETUJUI','DITOLAK','TERKONVERSI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_permintaan_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_po_pur AS ENUM
    ('DRAFT','MENUNGGU_APPROVAL','DISETUJUI','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_po_pur')
     IS DISTINCT FROM ARRAY['DRAFT','MENUNGGU_APPROVAL','DISETUJUI','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_po_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_penerimaan_pur AS ENUM
    ('BELUM_DITERIMA','SEBAGIAN_DITERIMA','DITERIMA_PENUH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_penerimaan_pur')
     IS DISTINCT FROM ARRAY['BELUM_DITERIMA','SEBAGIAN_DITERIMA','DITERIMA_PENUH']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_penerimaan_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_faktur_pur AS ENUM
    ('BELUM_DIFAKTUR','FAKTUR_PARSIAL','FAKTUR_PENUH','DITAHAN_SELISIH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_faktur_pur')
     IS DISTINCT FROM ARRAY['BELUM_DIFAKTUR','FAKTUR_PARSIAL','FAKTUR_PENUH','DITAHAN_SELISIH']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_faktur_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_penutupan_baris_pur AS ENUM ('TERBUKA','SISA_DITUTUP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_penutupan_baris_pur')
     IS DISTINCT FROM ARRAY['TERBUKA','SISA_DITUTUP']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_penutupan_baris_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_keputusan_persetujuan_pur AS ENUM ('SETUJUI','TOLAK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_keputusan_persetujuan_pur')
     IS DISTINCT FROM ARRAY['SETUJUI','TOLAK']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_keputusan_persetujuan_pur kosakata menyimpang';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_retur_pur AS ENUM
    ('DIAJUKAN','DISETUJUI','DIKELUARKAN','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
      FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
      WHERE t.typname = 'enum_status_retur_pur')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DIKELUARKAN','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: enum_status_retur_pur kosakata menyimpang';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2) MASTER modul CORE — pemasok (dipakai lintas modul: PUR, ACC, INV)
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist; -- dipakai EXCLUDE overlap periode harga (F01)

-- [MASTER] core_pemasok — master mitra pemasok, pemilik CORE (keputusan
--   pemilik 2026-11-06: master lintas modul → core). Konsumen: PUR (PO,
--   PUR-BR06), ACC (faktur/nota kredit — FK RESTRICT di sisi ACC nanti,
--   arsitektur-database-acc.md §40), INV (reorder M27/valuasi).
CREATE TABLE IF NOT EXISTS core_pemasok (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  kode            varchar(50) NOT NULL,          -- numbering SUP (core_sequences, PUR-BR01) — unique global, tidak dipakai ulang
  nama            varchar(100) NOT NULL,
  kontak          varchar(100),                  -- kontak ringkas utama
  alamat          varchar(300),
  alamat_faktur   varchar(300),                  -- dasar draft faktur & e-Faktur ACC (F01)
  alamat_kirim    varchar(300),
  mata_uang       varchar(50) NOT NULL DEFAULT 'IDR', -- diwarisi PO (PUR-BR06); konversi kurs dieksekusi ACC (A-02)
  npwp            varchar(50),
  penanda_pkp     boolean NOT NULL DEFAULT false,
  kode_termin     varchar(50),                   -- rujukan termin pembayaran (pemilik ACC — tanpa FK sampai ACC live, A-02)
  lead_time_hari  integer,                       -- default pemasok — dioverride baris harga (PUR-BR17)
  status          core_status_pemasok NOT NULL DEFAULT 'PROSPEK',
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_pemasok_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_core_pemasok_kode UNIQUE (kode)
);

CREATE INDEX IF NOT EXISTS ix_core_pemasok_status
  ON core_pemasok (status) WHERE deleted_at IS NULL;

-- [LINE] core_pemasok_kontak — PIC pemasok (nama/telepon/email/fungsi) — F01.
CREATE TABLE IF NOT EXISTS core_pemasok_kontak (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_pemasok bigint NOT NULL,
  nama            varchar(100) NOT NULL,
  telepon         varchar(50),
  email           varchar(150),
  fungsi          varchar(50),
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_pemasok_kontak_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_pemasok_kontak_pemasok FOREIGN KEY (id_core_pemasok)
    REFERENCES core_pemasok (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_core_pemasok_kontak_pemasok
  ON core_pemasok_kontak (id_core_pemasok) WHERE deleted_at IS NULL;

-- [LINE] core_pemasok_harga — daftar harga kontrak berperiode per produk — F01
--   (atribut master pemasok, BUKAN pricelist terpisah; algoritma pemilihan
--   PUR-BR06: urutan_prioritas → harga → lead_time; satuan beli PUR-BR16).
--   Harga bertingkat per qty (tier `qty_minimal` berbeda boleh berdampingan
--   dalam satu periode per pemasok+produk, ala Odoo min_qty multi-baris);
--   yang ditegakkan DB (EXCLUDE gist, revisi-3): duplikat tier sama pada
--   periode tumpang-tindih — F01/BR06.
CREATE TABLE IF NOT EXISTS core_pemasok_harga (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_pemasok bigint NOT NULL,
  id_inv_produk   bigint NOT NULL,
  id_inv_unit_ukur bigint,                       -- satuan beli (PUR-BR16)
  qty_minimal     integer NOT NULL DEFAULT 1,
  harga           numeric(18,4) NOT NULL,
  diskon_persen   numeric(5,2),
  mata_uang       varchar(50) NOT NULL DEFAULT 'IDR',
  lead_time_hari  integer,                       -- override lead time pemasok (PUR-BR17)
  urutan_prioritas integer NOT NULL DEFAULT 1,
  tanggal_mulai   date NOT NULL,
  tanggal_selesai date,                          -- NULL = kontrak terbuka
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_pemasok_harga_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_pemasok_harga_pemasok FOREIGN KEY (id_core_pemasok)
    REFERENCES core_pemasok (id) ON DELETE CASCADE,
  CONSTRAINT fk_core_pemasok_harga_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_pemasok_harga_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_core_pemasok_harga_qty CHECK (qty_minimal > 0),
  CONSTRAINT ck_core_pemasok_harga_periode
    CHECK (tanggal_selesai IS NULL OR tanggal_selesai >= tanggal_mulai)
);

CREATE INDEX IF NOT EXISTS ix_core_pemasok_harga_pemasok
  ON core_pemasok_harga (id_core_pemasok) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_core_pemasok_harga_produk
  ON core_pemasok_harga (id_inv_produk) WHERE deleted_at IS NULL;

-- Cegah duplikat tier harga per pemasok+produk+tier (qty_minimal) pada periode
-- tumpang-tindih (F01/BR06; revisi-3 harga bertingkat — tier qty berbeda boleh
-- berdampingan dalam satu periode) — DB-side; sengaja tidak diekspresikan di
-- mirror Drizzle (constraint eksklusif PG). Guard mendeteksi bentuk lama
-- (tanpa qty_minimal) dan menggantinya dengan bentuk tier.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
    WHERE c.conname = 'ex_core_pemasok_harga_overlap'
      AND c.conrelid = 'core_pemasok_harga'::regclass
      AND a.attname = 'qty_minimal'
  ) THEN
    ALTER TABLE core_pemasok_harga
      DROP CONSTRAINT IF EXISTS ex_core_pemasok_harga_overlap;
    ALTER TABLE core_pemasok_harga ADD CONSTRAINT ex_core_pemasok_harga_overlap
      EXCLUDE USING gist (
        id_core_pemasok WITH =,
        id_inv_produk   WITH =,
        qty_minimal     WITH =,
        daterange(tanggal_mulai, COALESCE(tanggal_selesai, 'infinity'::date), '[)') WITH &&
      ) WHERE (deleted_at IS NULL);
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 3) TRANSAKSI modul PUR — permintaan, pesanan (PO/RFQ), retur
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_permintaan — permintaan pembelian (PR, F02); lifecycle via
--   status, tanpa hard-delete (PUR-BR02); penolakan wajib alasan (PUR-BR05);
--   bila PO sumber dibatalkan PR kembali DISETUJUI (PUR-BR07/BR14).
CREATE TABLE IF NOT EXISTS pur_permintaan (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor            varchar(150) NOT NULL,        -- numbering PR-{yyyy} (core_sequences, PUR-BR01) — unique global
  id_core_users    bigint NOT NULL,              -- peminta (peminta_ref); SoD peminta ≠ staf pembelian (PUR-BR04)
  tanggal          date NOT NULL,
  butuh_pada       date,
  status           enum_status_permintaan_pur NOT NULL DEFAULT 'DRAFT',
  alasan_penolakan varchar(300),                 -- wajib bila DITOLAK (PUR-BR05)
  catatan          varchar(300),
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_pur_permintaan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_permintaan_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_permintaan_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pur_permintaan_tolak
    CHECK (status <> 'DITOLAK' OR alasan_penolakan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_permintaan_status
  ON pur_permintaan (status, tanggal) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_permintaan_users
  ON pur_permintaan (id_core_users) WHERE deleted_at IS NULL;

-- [LINE] pur_permintaan_item — baris PR; qty memakai satuan dasar produk (K-05,
--   konversi dieksekusi INV per PUR-BR16).
CREATE TABLE IF NOT EXISTS pur_permintaan_item (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_permintaan bigint NOT NULL,
  id_inv_produk    bigint NOT NULL,
  qty              integer NOT NULL,
  catatan          varchar(300),
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_pur_permintaan_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_permintaan_item_permintaan FOREIGN KEY (id_pur_permintaan)
    REFERENCES pur_permintaan (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_permintaan_item_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pur_permintaan_item_qty CHECK (qty > 0)
);

CREATE INDEX IF NOT EXISTS ix_pur_permintaan_item_permintaan
  ON pur_permintaan_item (id_pur_permintaan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_permintaan_item_produk
  ON pur_permintaan_item (id_inv_produk) WHERE deleted_at IS NULL;

-- [TRANSAKSI] pur_pesanan — RFQ/pesanan pembelian (PO, F03/F04/F05/F06);
--   status inti SATU dimensi lifecycle; status_penerimaan & status_faktur =
--   trek pelengkap terpisah (hasil M04/M06); rfq_terkirim_pada = Should A-04
--   (RFQ TERKIRIM + jejak kirim); rev_no = penanda amendment PO (audit P4;
--   perubahan nilai pasca-approval menaikkan rev_no → alur approval ulang);
--   penutupan/batal wajib alasan (PUR-BR05/BR13/BR14). Aktor transisi via
--   core_audit_trail (STD-01) — tidak dikolomkan.
CREATE TABLE IF NOT EXISTS pur_pesanan (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor             varchar(150) NOT NULL,       -- numbering PO-{yyyy} — unique global
  id_core_pemasok   bigint NOT NULL,             -- wajib pemasok AKTIF (PUR-BR06)
  id_inv_gudang     bigint,                      -- gudang tujuan (opsional)
  id_core_users_penyusun bigint,                 -- penyusun PO — SoD pembuat ≠ penyetuju (PUR-BR03)
  mata_uang         varchar(50) NOT NULL DEFAULT 'IDR', -- diwarisi pemasok (PUR-BR06)
  nilai_total       numeric(18,4) NOT NULL DEFAULT 0,
  eta               timestamptz,                 -- fallback header eta baris (PUR-BR17)
  rfq_terkirim_pada timestamptz,                 -- Should A-04: jejak kirim RFQ ke pemasok
  status            enum_status_po_pur NOT NULL DEFAULT 'DRAFT',
  status_penerimaan enum_status_penerimaan_pur NOT NULL DEFAULT 'BELUM_DITERIMA', -- dari M04
  status_faktur     enum_status_faktur_pur NOT NULL DEFAULT 'BELUM_DIFAKTUR',     -- dari M06
  rev_no            integer NOT NULL DEFAULT 0,  -- penanda revisi/amendment (audit P4)
  alasan_penutupan  varchar(300),                -- wajib bila DIBATALKAN / penutupan kurang-terima di luar toleransi (PUR-BR13/BR14)
  catatan           varchar(300),
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_pur_pesanan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_pesanan_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_pesanan_pemasok FOREIGN KEY (id_core_pemasok)
    REFERENCES core_pemasok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_pesanan_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pur_pesanan_gudang FOREIGN KEY (id_inv_gudang)
    REFERENCES inv_gudang (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pur_pesanan_batal
    CHECK (status <> 'DIBATALKAN' OR alasan_penutupan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_pesanan_status
  ON pur_pesanan (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_pesanan_pemasok
  ON pur_pesanan (id_core_pemasok) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_pesanan_gudang
  ON pur_pesanan (id_inv_gudang) WHERE deleted_at IS NULL;

-- [LINE] pur_pesanan_item — baris PO; snapshot harga/deskripsi/satuan saat
--   transaksi (data beku); qty_diterima/qty_difaktur/qty_diretur = akumulasi
--   mutakhir dari M04/M06/retur (A-03: PUR memegang status & akumulasi, bukan
--   entitas penerimaan); baris terkunci setelah mutasi parsial (PUR-BR13) —
--   pengurangan hanya via retur (PUR-BR20) atau penutupan sisa; penanda_sisa =
--   hasil keputusan backorder Staf Gudang (M04 SISA_DITUTUP, PUR-BR13).
CREATE TABLE IF NOT EXISTS pur_pesanan_item (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_pesanan        bigint NOT NULL,
  id_inv_produk         bigint NOT NULL,
  id_inv_unit_ukur      bigint NOT NULL,         -- satuan beli (PUR-BR16); konversi dasar dieksekusi INV
  id_pur_permintaan_item bigint,                 -- jejak konversi PR→PO; NULL = PO langsung / reorder
  deskripsi             varchar(300) NOT NULL,   -- snapshot deskripsi baris
  qty                   integer NOT NULL,
  harga                 numeric(18,4) NOT NULL,  -- dari daftar harga (PUR-BR06) atau harga manual ter-approval
  diskon_persen         numeric(5,2),
  kode_pajak            varchar(50),             -- data pajak dibawa, tidak dihitung PUR (A-02; pemilik ACC)
  eta_baris             timestamptz,             -- override tercatat (PUR-BR17); NULL = ikut header
  catatan               varchar(300),
  qty_diterima          integer NOT NULL DEFAULT 0,
  qty_difaktur          integer NOT NULL DEFAULT 0,
  qty_diretur           integer NOT NULL DEFAULT 0,
  penanda_sisa          enum_penutupan_baris_pur NOT NULL DEFAULT 'TERBUKA',
  version               integer NOT NULL DEFAULT 1,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  deleted_at            timestamptz,
  CONSTRAINT uq_pur_pesanan_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_pesanan_item_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_pesanan_item_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_pesanan_item_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_pesanan_item_permintaan_item FOREIGN KEY (id_pur_permintaan_item)
    REFERENCES pur_permintaan_item (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_pesanan_item_qty CHECK (qty > 0),
  CONSTRAINT ck_pur_pesanan_item_akumulasi CHECK (
    qty_diterima >= 0 AND qty_difaktur >= 0 AND qty_diretur >= 0
  )
);

CREATE INDEX IF NOT EXISTS ix_pur_pesanan_item_pesanan
  ON pur_pesanan_item (id_pur_pesanan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_pesanan_item_produk
  ON pur_pesanan_item (id_inv_produk) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_pesanan_item_permintaan_item
  ON pur_pesanan_item (id_pur_permintaan_item) WHERE deleted_at IS NULL;

-- [LINE] pur_pesanan_persetujuan — keputusan approval PO berjenjang (F04,
--   PUR-BR03); level mengikuti CFG-PUR-02/03; pembuat ≠ penyetuju (SoD);
--   delegasi CFG-PUR-13 tidak mengubah rantai ambang. Tanpa unique
--   (pesanan, level) — penolakan → kembali DRAFT → pengajuan ulang
--   menghasilkan baris level sama lagi.
CREATE TABLE IF NOT EXISTS pur_pesanan_persetujuan (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_pesanan bigint NOT NULL,
  level          integer NOT NULL,
  id_core_users  bigint,                         -- penyetuju; NULL bila user terhapus (SET NULL)
  keputusan      enum_keputusan_persetujuan_pur NOT NULL,
  alasan         varchar(300),                   -- wajib bila TOLAK (PUR-BR05)
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_pur_pesanan_persetujuan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_pesanan_persetujuan_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_pesanan_persetujuan_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_pesanan_persetujuan_level CHECK (level >= 1),
  CONSTRAINT ck_pur_pesanan_persetujuan_tolak
    CHECK (keputusan <> 'TOLAK' OR alasan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_pesanan_persetujuan_pesanan
  ON pur_pesanan_persetujuan (id_pur_pesanan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_pesanan_persetujuan_users
  ON pur_pesanan_persetujuan (id_core_users) WHERE deleted_at IS NULL;

-- [TRANSAKSI] pur_retur — retur pembelian (F14): usulan Staf Pembelian atas
--   baris qty_diterima − retur kumulatif (PUR-BR20); disetujui → M03
--   {arah: KEMBALI} ke INV + M08 {jenis: NOTA_KREDIT} ke ACC; status inti PO
--   tidak berubah ("PO SELESAI tetap SELESAI" §4.2).
CREATE TABLE IF NOT EXISTS pur_retur (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor          varchar(150) NOT NULL,          -- numbering RET-{yyyy} — unique global
  id_pur_pesanan bigint NOT NULL,
  id_core_users_penyusun bigint,                 -- penyusun usulan — SoD pembuat ≠ penyetuju (PUR-BR05)
  status         enum_status_retur_pur NOT NULL DEFAULT 'DIAJUKAN',
  alasan         varchar(300) NOT NULL,          -- cacat/rusak/kelebihan kirim/pembatalan sebagian (F14, PUR-BR05)
  catatan        varchar(300),
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_pur_retur_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_retur_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_retur_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_retur_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pur_retur_status
  ON pur_retur (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_retur_pesanan
  ON pur_retur (id_pur_pesanan) WHERE deleted_at IS NULL;

-- [LINE] pur_retur_item — baris retur per baris PO; qty > 0; pengurangan
--   qty_diterima/qty_difaktur baris PO terjadi saat nota kredit terposting
--   (M06 → PUR-BR20), bukan saat retur dibuat.
CREATE TABLE IF NOT EXISTS pur_retur_item (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id          uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_retur       bigint NOT NULL,
  id_pur_pesanan_item bigint NOT NULL,
  qty                integer NOT NULL,
  catatan            varchar(300),
  version            integer NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CONSTRAINT uq_pur_retur_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_retur_item_retur FOREIGN KEY (id_pur_retur)
    REFERENCES pur_retur (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_retur_item_pesanan_item FOREIGN KEY (id_pur_pesanan_item)
    REFERENCES pur_pesanan_item (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pur_retur_item_qty CHECK (qty > 0)
);

CREATE INDEX IF NOT EXISTS ix_pur_retur_item_retur
  ON pur_retur_item (id_pur_retur) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_retur_item_pesanan_item
  ON pur_retur_item (id_pur_pesanan_item) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4) TRIGGER set_updated_at — 10 tabel mutable (semua tabel patch ini; tidak
--    ada [LOG/EVENT] — jejak transisi status memakai core_audit_trail STD-01)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'core_pemasok','core_pemasok_kontak','core_pemasok_harga',
    'pur_permintaan','pur_permintaan_item',
    'pur_pesanan','pur_pesanan_item','pur_pesanan_persetujuan',
    'pur_retur','pur_retur_item'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 5) SEKSI INTEGRASI CORE — registry modul, penomoran, konfigurasi CFG-PUR
-- -----------------------------------------------------------------------------
-- Guard fail-loud: baseline registry wajib ada (konsisten patch purchasing lama).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'purchasing') THEN
    RAISE EXCEPTION 'PATCH 25-purchasing: registry core_modules key=''purchasing'' absen — baseline CORE wajib dulu';
  END IF;
END $$;

-- core_sequences (penomoran anti-race STD-08/PUR-BR01) — ensure utk install
-- segar; DB live sudah membawa 4 baris ini (counter berjalan TIDAK disentuh).
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, 0, v.padding
FROM core_modules m
CROSS JOIN (VALUES
  ('supplier',         'SUP',        3),
  ('purchase_request', 'PR-{yyyy}',  4),
  ('purchase_order',   'PO-{yyyy}',  4),
  ('purchase_return',  'RET-{yyyy}', 4)
) AS v(doc_name, prefix, padding)
WHERE m.key = 'purchasing'
  AND NOT EXISTS (
    SELECT 1 FROM core_sequences s
    WHERE s.doc_name = v.doc_name AND s.id_core_modules = m.id
  );

-- core_module_configs CFG-PUR-01..15 (F13) — ensure utk install segar; nilai
-- default = skala PS2 (persis nilai live, pemilik konfigurasi: CORE).
INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-PUR-01', 'PR_WAJIB_DI_ATAS_AMBANG', 'string',
   'Apakah pembelian wajib mulai dari permintaan pembelian (PR)? PO_LANGSUNG / PR_WAJIB_DI_ATAS_AMBANG / PR_WAJIB_SEMUA'),
  ('CFG-PUR-02', 'SATU_LEVEL', 'string',
   'Rantai persetujuan PO: TANPA_APPROVAL / SATU_LEVEL / BERJENJANG'),
  ('CFG-PUR-03', '{"level_1":20000000,"level_2":null}', 'json',
   'Ambang nominal persetujuan PO per level'),
  ('CFG-PUR-04', '5', 'number', 'Toleransi penerimaan lebih — over-receipt (%)'),
  ('CFG-PUR-05', '5', 'number', 'Toleransi penerimaan kurang sebelum PO boleh ditutup (%)'),
  ('CFG-PUR-06', '3WAY', 'string', 'Pencocokan faktur pemasok: 3WAY / 2WAY'),
  ('CFG-PUR-07', '2', 'number', 'Toleransi selisih harga faktur vs PO (%)'),
  ('CFG-PUR-08', '10000000', 'number', 'Ambang komitmen anggaran PO (M05); 0 = nonaktif'),
  ('CFG-PUR-09', 'APPROVAL_TAMBAHAN', 'string',
   'Aksi bila anggaran kategori kurang (M26): BLOK / APPROVAL_TAMBAHAN / IZINKAN_TANDAI'),
  ('CFG-PUR-10', 'DRAFT_PR_OTOMATIS', 'string',
   'Reorder otomatis (M27): NONAKTIF / DRAFT_PR_OTOMATIS / DRAFT_PO_OTOMATIS / PO_OTOMATIS'),
  ('CFG-PUR-11', 'KATEGORI_DAN_AMBANG', 'string',
   'Pemicu usulan aset (M17): NONAKTIF / KATEGORI_TERPILIH / KATEGORI_DAN_AMBANG'),
  ('CFG-PUR-12', 'NILAI_PER_PO', 'string',
   'Alokasi biaya tambahan/landed cost (M28): NILAI / QTY / BERAT / VOLUME; per PO atau per periode'),
  ('CFG-PUR-13', 'DELEGASI_MANUAL', 'string',
   'Penyetuju tidak tersedia: NONAKTIF / DELEGASI_MANUAL / DELEGASI_ESKALASI'),
  ('CFG-PUR-14', 'IKUT_JENIS_BARIS', 'string',
   'Dasar kuantitas match faktur: IKUT_JENIS_BARIS / ORDERED / RECEIVED'),
  ('CFG-PUR-15', '2', 'number', 'Security lead time pada perhitungan eta otomatis (hari)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'purchasing'
  AND NOT EXISTS (
    SELECT 1 FROM core_module_configs c
    WHERE c.param_key = v.param_key AND c.id_core_modules = m.id
  );
