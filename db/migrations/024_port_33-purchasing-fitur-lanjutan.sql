-- +goose Up
-- Porting 1:1 dari ddl/33-purchasing-fitur-lanjutan.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 33-purchasing-fitur-lanjutan.sql — FITUR LANJUTAN modul PURCHASING
-- Domain   : OdooLikeERP · Modul PURCHASING (FASE 3a fitur-modul-fullcycle)
-- Pemicu   : docs/analisa-modul-pur.md revisi 2026-11-07 — menerjemahkan
--            F15–F19 + CFG-PUR-16…22 (PUR-BR24…BR30) ke lapisan kontrak:
--              F15 uang muka (DP) pemasok ter-link PO  → `pur_uang_muka`
--              F16 kesepakatan/blanket order + release → `pur_kesepakatan`
--                 (+ item; release = PO normal via `pur_pesanan.id_pur_kesepakatan`)
--              F17 tender penawaran/RFQ alternatif     → `pur_pesanan.kelompok_penawaran`
--                 + `tender_pemenang`
--              F18 komunikasi pemasok                  → `pur_pesanan.po_terkirim_pada`
--                 + `eta_konfirmasi_pada/oleh` (CFG-PUR-21 pengingat = kode)
--              F19 dropship pemasok→pelanggan          → `pur_pesanan.pengiriman_langsung`
--                 /`so_ref` + baris `pengiriman_langsung`/`alamat_kirim` (CFG-PUR-22)
--              F9/M17 pemicu usulan aset               → `pur_usulan_aset` (partial
--                 UNIQUE idempoten — guard duplikat usulan per PO+produk+keadaan)
--              F10 landed cost alokasi multi-PO        → `pur_biaya_landed` (+ junction)
--              CFG-PUR-13 delegasi penyetuju           → `pur_delegasi_penyetuju`
--              CFG-PUR-20 kunci PO otomatis            → `pur_pesanan.terkunci/tanggal_kunci`
-- KARTU ARSITEKTUR (arsitektur-database — seluruh tabel milik modul PUR):
--   pur_kesepakatan      [TRANSAKSI] F16 — kesepakatan pembelian (blanket/template)
--   pur_kesepakatan_item [LINE]      baris kesepakatan (produk/qty/harga kontrak)
--   pur_uang_muka        [TRANSAKSI] F15 — usulan DP pemasok per PO
--   pur_biaya_landed     [TRANSAKSI] F10 — biaya tambahan alokasi ke banyak PO
--   pur_biaya_landed_po  [JUNCTION]  N:M landed ↔ PO (PK komposit, tanpa kolom bisnis)
--   pur_usulan_aset      [TRANSAKSI] F9/M17 — usulan aset dari baris PO
--   pur_delegasi_penyetuju [TRANSAKSI] CFG-PUR-13 — delegasi keputusan per periode
--   Semua tabel: trio audit (created_at/updated_at/deleted_at) + trigger
--   `trg_<tabel>_updated_at` (pola §4 ddl/25 — array FOREACH diperluas);
--   `entity_id uuid DEFAULT gen_random_uuid()` + UNIQUE (Tier A); PK
--   `bigint GENERATED ALWAYS AS IDENTITY`; `version integer NOT NULL
--   DEFAULT 1` (optimistic lock) pada TRANSAKSI & LINE — junction tanpa
--   version/entity_id; index partial `WHERE deleted_at IS NULL` untuk FK
--   yang sering di-join; teks varchar bucket 50/100/150/200/300 (tanpa text).
-- Integrasi: inv_produk/inv_unit_ukur FK RESTRICT; core_pemasok RESTRICT;
--   core_users aktor RESTRICT/SET NULL (pola ddl/25); pur_pesanan dirujuk
--   RESTRICT oleh DP/usulan aset/landed-PO; kesepakatan dirujuk SET NULL
--   (PO release tetap selamat bila kesepakatan soft/hard-close).
-- Mirror   : apps/api/src/core/database/schema/purchasing.ts (revisi-3)
--            + packages/schemas/src/purchasing/* (zod satu sumber).
-- Idempoten: enum DO-guard pg_type; CREATE TABLE IF NOT EXISTS; ALTER ADD
--   COLUMN IF NOT EXISTS + FK DO-guard constraint; index IF NOT EXISTS;
--   trigger DROP+CREATE; sequence/CFG INSERT…WHERE NOT EXISTS (counter &
--   nilai live TIDAK ditimpa). Aman dijalankan berulang.
-- Prasyarat: ddl/25-purchasing.sql (pur_pesanan/pur_pesanan_item, core_pemasok,
--   inv_*, registry core_modules key='purchasing') + baseline CORE
--   (core_users, set_updated_at, core_config_value_type).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) ENUM — 9 tipe baru (kosakata persis mirror purchasing.ts); bila sudah ada,
--    diverifikasi fail-loud (pola pg_type-guard ddl/23 + verifikasi ddl/25 §1).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_jenis_kesepakatan') THEN
    CREATE TYPE pur_jenis_kesepakatan AS ENUM ('BLANKET_ORDER', 'TEMPLATE');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_jenis_kesepakatan')
       IS DISTINCT FROM ARRAY['BLANKET_ORDER','TEMPLATE']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_jenis_kesepakatan kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_status_kesepakatan') THEN
    CREATE TYPE pur_status_kesepakatan AS ENUM ('DRAFT', 'DIKONFIRMASI', 'SELESAI', 'DIBATALKAN');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_status_kesepakatan')
       IS DISTINCT FROM ARRAY['DRAFT','DIKONFIRMASI','SELESAI','DIBATALKAN']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_status_kesepakatan kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_status_uang_muka') THEN
    CREATE TYPE pur_status_uang_muka AS ENUM ('DIAJUKAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_status_uang_muka')
       IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK','DIBATALKAN']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_status_uang_muka kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_dasar_alokasi') THEN
    CREATE TYPE pur_dasar_alokasi AS ENUM ('NILAI', 'QTY', 'BERAT', 'VOLUME');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_dasar_alokasi')
       IS DISTINCT FROM ARRAY['NILAI','QTY','BERAT','VOLUME']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_dasar_alokasi kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_status_landed') THEN
    CREATE TYPE pur_status_landed AS ENUM
      ('DIAJUKAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN', 'TERALOKASIKAN');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_status_landed')
       IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK','DIBATALKAN','TERALOKASIKAN']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_status_landed kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_keadaan_usulan_aset') THEN
    CREATE TYPE pur_keadaan_usulan_aset AS ENUM ('USUL', 'KOREKSI');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_keadaan_usulan_aset')
       IS DISTINCT FROM ARRAY['USUL','KOREKSI']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_keadaan_usulan_aset kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_status_usulan_aset') THEN
    CREATE TYPE pur_status_usulan_aset AS ENUM
      ('MENUNGGU_KONFIRMASI', 'DIKONFIRMASI', 'DITOLAK', 'TERKIRIM', 'GAGAL');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_status_usulan_aset')
       IS DISTINCT FROM ARRAY['MENUNGGU_KONFIRMASI','DIKONFIRMASI','DITOLAK','TERKIRIM','GAGAL']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_status_usulan_aset kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_status_delegasi') THEN
    CREATE TYPE pur_status_delegasi AS ENUM ('AKTIF', 'DINONAKTIFKAN', 'BERAKHIR');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_status_delegasi')
       IS DISTINCT FROM ARRAY['AKTIF','DINONAKTIFKAN','BERAKHIR']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_status_delegasi kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pur_jenis_baris') THEN
    CREATE TYPE pur_jenis_baris AS ENUM ('BARANG', 'JASA');
  ELSE
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
        FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'pur_jenis_baris')
       IS DISTINCT FROM ARRAY['BARANG','JASA']::text[] THEN
      RAISE EXCEPTION 'PATCH 33-purchasing: pur_jenis_baris kosakata menyimpang dari mirror';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 2) KESEPAKATAN PEMBELIAN — blanket order/template + release PO (F16)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_kesepakatan — kontrak berjangka dengan pemasok (F16,
--   PUR-BR26): BLANKET_ORDER wajib pemasok (CHECK); TEMPLATE = template
--   pembelian bebas pemasok; release = PO normal yang menaut
--   `pur_pesanan.id_pur_kesepakatan` (F03/F04). SoD: penyusun ≠ penyutuju
--   ditegakkan kode; penutupan/batal wajib alasan (CHECK DIBATALKAN).
CREATE TABLE IF NOT EXISTS pur_kesepakatan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,       -- numbering SKS-{yyyy} (core_sequences, PUR-BR01) — unique global
  tipe                   pur_jenis_kesepakatan NOT NULL DEFAULT 'BLANKET_ORDER',
  id_core_pemasok        bigint,                      -- wajib bila BLANKET_ORDER (ck_pur_kesepakatan_blanket)
  tanggal_mulai          date NOT NULL,
  tanggal_selesai        date,                        -- NULL = kontrak terbuka
  tanggal_pesan          date,                        -- jendela pesan release (template)
  tanggal_kirim          date,                        -- jendela kirim release (template)
  status                 pur_status_kesepakatan NOT NULL DEFAULT 'DRAFT',
  alasan_penutupan       varchar(300),                -- wajib bila DIBATALKAN (ck_pur_kesepakatan_batal)
  id_core_users_penyusun  bigint,                     -- penyusun kesepakatan — SoD (PUR-BR26) — SET NULL
  id_core_users_penyutuju bigint,                     -- konfirmasi Manajer (SoD pembuat ≠ penyetuju) — SET NULL
  catatan                varchar(300),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_pur_kesepakatan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_kesepakatan_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_kesepakatan_pemasok FOREIGN KEY (id_core_pemasok)
    REFERENCES core_pemasok (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_kesepakatan_penyusun FOREIGN KEY (id_core_users_penyusun)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pur_kesepakatan_penyutuju FOREIGN KEY (id_core_users_penyutuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_kesepakatan_blanket
    CHECK (tipe <> 'BLANKET_ORDER' OR id_core_pemasok IS NOT NULL),
  CONSTRAINT ck_pur_kesepakatan_batal
    CHECK (status <> 'DIBATALKAN' OR alasan_penutupan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_kesepakatan_status
  ON pur_kesepakatan (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_kesepakatan_pemasok
  ON pur_kesepakatan (id_core_pemasok) WHERE deleted_at IS NULL;

-- [LINE] pur_kesepakatan_item — baris kontrak kesepakatan (F16): qty_kesepakatan
--   = komitmen blanket; qty_dipesan = akumulasi release PO (PUR-BR26). Baris
--   harga DIKONFIRMASI menjadi prioritas efektif daftar harga selama validitas.
CREATE TABLE IF NOT EXISTS pur_kesepakatan_item (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_kesepakatan  bigint NOT NULL,
  id_inv_produk       bigint NOT NULL,
  id_inv_unit_ukur    bigint,                       -- satuan beli (PUR-BR16); NULL = unit dasar produk
  qty_kesepakatan     integer NOT NULL,             -- komitmen blanket
  qty_dipesan         integer NOT NULL DEFAULT 0,   -- akumulasi release PO
  harga               numeric(18,4) NOT NULL,       -- harga kontrak (snapshot beku)
  diskon_persen       numeric(5,2),
  catatan             varchar(300),
  version             integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_pur_kesepakatan_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_kesepakatan_item_kesepakatan FOREIGN KEY (id_pur_kesepakatan)
    REFERENCES pur_kesepakatan (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_kesepakatan_item_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_kesepakatan_item_unit FOREIGN KEY (id_inv_unit_ukur)
    REFERENCES inv_unit_ukur (id) ON DELETE RESTRICT,
  CONSTRAINT ck_pur_kesepakatan_item_qty CHECK (qty_kesepakatan > 0),
  CONSTRAINT ck_pur_kesepakatan_item_qty_dipesan CHECK (qty_dipesan >= 0)
);

CREATE INDEX IF NOT EXISTS ix_pur_kesepakatan_item_kesepakatan
  ON pur_kesepakatan_item (id_pur_kesepakatan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_kesepakatan_item_produk
  ON pur_kesepakatan_item (id_inv_produk) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 3) UANG MUKA (DP) PEMASOK TER-LINK PO (F15/M43, PUR-BR24; CFG-PUR-16)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_uang_muka — usulan DP atas PO DISETUJUI; batas persen
--   CFG-PUR-16 ditegakkan kode (PUR-BR24); penolakan wajib alasan (CHECK).
--   Posting ke ACC via M43 (kontrak tanpa FK, arsitektur-database-acc §40).
CREATE TABLE IF NOT EXISTS pur_uang_muka (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                   varchar(150) NOT NULL,      -- numbering DP-{yyyy} (core_sequences, PUR-BR01) — unique global
  id_pur_pesanan          bigint NOT NULL,            -- PO sumber — RESTRICT (riwayat PO selamat)
  nilai                   numeric(18,4) NOT NULL,
  persen                  numeric(5,2),               -- % nilai PO saat usulan (snapshot)
  rencana_bayar           date,                       -- dasar jadwal bayar ACC
  status                  pur_status_uang_muka NOT NULL DEFAULT 'DIAJUKAN',
  alasan_penolakan        varchar(300),               -- wajib bila DITOLAK (ck_pur_uang_muka_tolak)
  id_core_users_pengusul  bigint,                     -- Staf Pembelian — SET NULL
  id_core_users_penyutuju bigint,                     -- Manajer (SoD pembuat ≠ penyetuju) — SET NULL
  catatan                 varchar(300),
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_pur_uang_muka_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_uang_muka_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_uang_muka_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_uang_muka_pengusul FOREIGN KEY (id_core_users_pengusul)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pur_uang_muka_penyutuju FOREIGN KEY (id_core_users_penyutuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_uang_muka_nilai CHECK (nilai > 0),
  CONSTRAINT ck_pur_uang_muka_tolak
    CHECK (status <> 'DITOLAK' OR alasan_penolakan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_uang_muka_status
  ON pur_uang_muka (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_uang_muka_pesanan
  ON pur_uang_muka (id_pur_pesanan) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 4) BIAYA LANDED — alokasi biaya tambahan ke banyak PO (F10/M28)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_biaya_landed — dokumen biaya tambahan (freight/bea/dll);
--   dasar alokasi NILAI/QTY/BERAT/VOLUME (default CFG-PUR-12); penolakan ATAU
--   pembatalan wajib alasan (CHECK); TERALOKASIKAN = hasil eksekusi alokasi.
CREATE TABLE IF NOT EXISTS pur_biaya_landed (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                   varchar(150) NOT NULL,      -- numbering LC-{yyyy} (core_sequences, PUR-BR01) — unique global
  deskripsi               varchar(300) NOT NULL,
  nilai                   numeric(18,4) NOT NULL,
  dasar_alokasi           pur_dasar_alokasi NOT NULL DEFAULT 'NILAI',
  status                  pur_status_landed NOT NULL DEFAULT 'DIAJUKAN',
  alasan_penolakan        varchar(300),               -- wajib bila DITOLAK/DIBATALKAN (ck_pur_biaya_landed_keputusan)
  id_core_users_pengusul  bigint,                     -- SET NULL
  id_core_users_penyutuju bigint,                     -- Manajer (SoD pembuat ≠ penyetuju) — SET NULL
  catatan                 varchar(300),
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_pur_biaya_landed_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_pur_biaya_landed_nomor UNIQUE (nomor),
  CONSTRAINT fk_pur_biaya_landed_pengusul FOREIGN KEY (id_core_users_pengusul)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_pur_biaya_landed_penyutuju FOREIGN KEY (id_core_users_penyutuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_biaya_landed_nilai CHECK (nilai > 0),
  CONSTRAINT ck_pur_biaya_landed_keputusan
    CHECK (status NOT IN ('DITOLAK', 'DIBATALKAN') OR alasan_penolakan IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_pur_biaya_landed_status
  ON pur_biaya_landed (status) WHERE deleted_at IS NULL;

-- [JUNCTION] pur_biaya_landed_po — pautan biaya landed ↔ PO sasaran alokasi
--   (F10): N:M murni, PK komposit, tanpa kolom bisnis; landed CASCADE (baris
--   pautan ikut dokumen), PO RESTRICT (riwayat alokasi selamat). updated_at
--   beku OK (pautan tidak dimutasi — re-pautan = soft-delete + insert baru).
CREATE TABLE IF NOT EXISTS pur_biaya_landed_po (
  id_pur_biaya_landed bigint NOT NULL,
  id_pur_pesanan      bigint NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT pk_pur_biaya_landed_po PRIMARY KEY (id_pur_biaya_landed, id_pur_pesanan),
  CONSTRAINT fk_pur_biaya_landed_po_landed FOREIGN KEY (id_pur_biaya_landed)
    REFERENCES pur_biaya_landed (id) ON DELETE CASCADE,
  CONSTRAINT fk_pur_biaya_landed_po_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT
);

-- Sisi PO untuk pencarian balik "biaya landed yang menaut PO ini" (pola junction pos.ts).
CREATE INDEX IF NOT EXISTS ix_pur_biaya_landed_po_pesanan
  ON pur_biaya_landed_po (id_pur_pesanan) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 5) USULAN ASET DARI BARIS PO (F9/M17, PUR-BR25…; CFG-PUR-11)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_usulan_aset — usulan pencatatan aset (USUL) atau koreksi
--   nilai/keadaan (KOREKSI) atas barang belian per PO+produk; idempoten master
--   M17: satu usulan aktif per (PO, produk, keadaan) — partial UNIQUE
--   `uq_pur_usulan_aset_idempoten` (reusable setelah soft delete); penolakan
--   wajib alasan (CHECK); TERKIRIM = tersinkron ke modul AST (kontrak tanpa FK).
CREATE TABLE IF NOT EXISTS pur_usulan_aset (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_pur_pesanan          bigint NOT NULL,            -- PO sumber — RESTRICT
  id_inv_produk           bigint NOT NULL,            -- produk diusulkan jadi aset — RESTRICT
  qty                     integer NOT NULL,
  nilai                   numeric(18,4) NOT NULL,     -- nilai per unit usulan (dasar kapitalisasi AST)
  keadaan                 pur_keadaan_usulan_aset NOT NULL DEFAULT 'USUL',
  status                  pur_status_usulan_aset NOT NULL DEFAULT 'MENUNGGU_KONFIRMASI',
  id_core_users_penyutuju bigint,                     -- konfirmasi Manajer — SET NULL
  alasan_penolakan        varchar(300),               -- wajib bila DITOLAK (ck_pur_usulan_aset_tolak)
  catatan                 varchar(300),
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_pur_usulan_aset_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_usulan_aset_pesanan FOREIGN KEY (id_pur_pesanan)
    REFERENCES pur_pesanan (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_usulan_aset_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_usulan_aset_penyutuju FOREIGN KEY (id_core_users_penyutuju)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_usulan_aset_qty CHECK (qty > 0),
  CONSTRAINT ck_pur_usulan_aset_tolak
    CHECK (status <> 'DITOLAK' OR alasan_penolakan IS NOT NULL)
);

-- Partial UNIQUE idempoten (M17): reusable setelah soft delete (pola partial unique repo).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pur_usulan_aset_idempoten
  ON pur_usulan_aset (id_pur_pesanan, id_inv_produk, keadaan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_pur_usulan_aset_pesanan
  ON pur_usulan_aset (id_pur_pesanan) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 6) DELEGASI PENYETUJU (CFG-PUR-13, Should — PUR-BR03/BR26)
-- -----------------------------------------------------------------------------
-- [TRANSAKSI] pur_delegasi_penyetuju — penyetuju mendelegasikan keputusan per
--   periode ke pengganti tetap; delegasi ter-audit, TIDAK mengubah rantai
--   ambang (CFG-PUR-13); asal ≠ pengganti (CHECK SoD); pembuat catat jejak.
CREATE TABLE IF NOT EXISTS pur_delegasi_penyetuju (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users_asal       bigint NOT NULL,            -- penyetuju asal — RESTRICT
  id_core_users_pengganti  bigint NOT NULL,            -- pengganti — RESTRICT
  tanggal_mulai            date NOT NULL,
  tanggal_selesai          date NOT NULL,
  status                   pur_status_delegasi NOT NULL DEFAULT 'AKTIF',
  catatan                  varchar(300),
  id_core_users_pembuat    bigint,                     -- pembuat delegasi (jejak audit) — SET NULL
  version                  integer NOT NULL DEFAULT 1,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_pur_delegasi_penyetuju_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_pur_delegasi_penyetuju_asal FOREIGN KEY (id_core_users_asal)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_delegasi_penyetuju_pengganti FOREIGN KEY (id_core_users_pengganti)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_pur_delegasi_penyetuju_pembuat FOREIGN KEY (id_core_users_pembuat)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_pur_delegasi_penyetuju_beda
    CHECK (id_core_users_asal <> id_core_users_pengganti),
  CONSTRAINT ck_pur_delegasi_penyetuju_periode
    CHECK (tanggal_selesai >= tanggal_mulai)
);

CREATE INDEX IF NOT EXISTS ix_pur_delegasi_penyetuju_asal
  ON pur_delegasi_penyetuju (id_core_users_asal) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 7) REVISI-2 pur_pesanan & pur_pesanan_item — kolom fitur lanjutan (F16–F19,
--    CFG-PUR-20/22). Install segar: tabel sudah ada dari ddl/25 — blok ini
--    menambah kolom; ALTER ADD COLUMN IF NOT EXISTS (pola revisi-2 ddl/25 §0b).
-- -----------------------------------------------------------------------------
-- F17 tender (kelompok RFQ alternatif + pemenang), F18 komunikasi pemasok
-- (jejak kirim PO + konfirmasi ETA), F19 dropship (pemasok→pelanggan, M44),
-- F16 release kesepakatan, CFG-PUR-20 kunci PO otomatis (PUR-BR28).
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS kelompok_penawaran varchar(100); -- penaut bebas antar RFQ satu tender (F17) — tanpa FK
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS tender_pemenang boolean NOT NULL DEFAULT false; -- satu-satunya pemenang kelompok yang lanjut approval (PUR-BR27)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS po_terkirim_pada timestamptz;   -- jejak kirim PO ke pemasok via notifikasi CORE (F18)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS eta_konfirmasi_pada timestamptz; -- konfirmasi tanggal terima pemasok (F18)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS eta_konfirmasi_oleh bigint;     -- pemasok/aktor pencatat konfirmasi — SET NULL
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS pengiriman_langsung boolean NOT NULL DEFAULT false; -- dropship (F19, CFG-PUR-22)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS so_ref varchar(150);            -- rujukan Sales Order SLS sumber dropship (M44)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS id_pur_kesepakatan bigint;      -- release PO dari kesepakatan (F16) — SET NULL
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS terkunci boolean NOT NULL DEFAULT false;         -- kunci PO otomatis pasca-approval (CFG-PUR-20, PUR-BR28)
ALTER TABLE pur_pesanan ADD COLUMN IF NOT EXISTS tanggal_kunci timestamptz;      -- waktu penguncian (audit buka-kunci Manajer)

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE pur_pesanan ADD CONSTRAINT fk_pur_pesanan_eta_konfirmasi_oleh
    FOREIGN KEY (eta_konfirmasi_oleh) REFERENCES core_users (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE pur_pesanan ADD CONSTRAINT fk_pur_pesanan_kesepakatan
    FOREIGN KEY (id_pur_kesepakatan) REFERENCES pur_kesepakatan (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_pur_pesanan_kesepakatan
  ON pur_pesanan (id_pur_kesepakatan) WHERE deleted_at IS NULL;

-- pur_pesanan_item — baris jasa/non-stok (faktur langsung dari PO, CFG-PUR-14),
-- dropship per baris (alamat kirim pelanggan), jejak release kesepakatan.
ALTER TABLE pur_pesanan_item ADD COLUMN IF NOT EXISTS id_pur_kesepakatan_item bigint; -- baris kontrak sumber release (F16) — SET NULL
ALTER TABLE pur_pesanan_item ADD COLUMN IF NOT EXISTS jenis_baris pur_jenis_baris NOT NULL DEFAULT 'BARANG'; -- BARANG/JASA (dasar match faktur CFG-PUR-14)
ALTER TABLE pur_pesanan_item ADD COLUMN IF NOT EXISTS pengiriman_langsung boolean NOT NULL DEFAULT false;    -- dropship per baris (F19)
ALTER TABLE pur_pesanan_item ADD COLUMN IF NOT EXISTS alamat_kirim varchar(300);                             -- alamat kirim pelanggan (dropship, M44)

-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE pur_pesanan_item ADD CONSTRAINT fk_pur_pesanan_item_kesepakatan_item
    FOREIGN KEY (id_pur_kesepakatan_item) REFERENCES pur_kesepakatan_item (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_pur_pesanan_item_kesepakatan_item
  ON pur_pesanan_item (id_pur_kesepakatan_item) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- 8) TRIGGER set_updated_at — tabel baru patch ini (pola §4 ddl/25; tabel
--    lama pur_pesanan/pur_pesanan_item sudah ter-trigger di sana)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'pur_kesepakatan','pur_kesepakatan_item',
    'pur_uang_muka','pur_biaya_landed','pur_biaya_landed_po',
    'pur_usulan_aset','pur_delegasi_penyetuju'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- 9) SEKSI INTEGRASI CORE — guard registry, penomoran, konfigurasi CFG-PUR-16…22
-- -----------------------------------------------------------------------------
-- Guard fail-loud ringan: baseline registry wajib ada (ulang guard ddl/25 §5).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'purchasing') THEN
    RAISE EXCEPTION 'PATCH 33-purchasing: registry core_modules key=''purchasing'' absen — baseline CORE wajib dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- core_sequences (penomoran anti-race STD-08/PUR-BR01) — ensure; counter
-- berjalan di live TIDAK disentuh (NOT EXISTS).
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, 0, v.padding
FROM core_modules m
CROSS JOIN (VALUES
  ('purchase_agreement', 'SKS-{yyyy}', 4),
  ('purchase_dp',        'DP-{yyyy}',  4),
  ('purchase_landed',    'LC-{yyyy}',  4)
) AS v(doc_name, prefix, padding)
WHERE m.key = 'purchasing'
  AND NOT EXISTS (
    SELECT 1 FROM core_sequences s
    WHERE s.doc_name = v.doc_name AND s.id_core_modules = m.id
  );

-- core_module_configs CFG-PUR-16…22 — ensure utk install segar; nilai
-- existing TIDAK ditimpa (pemilik konfigurasi: CORE).
INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-PUR-16', 'OPSIONAL_MAKS_30', 'string',
   'Uang muka (DP) ke pemasok (F15/PUR-BR24): NONAKTIF / OPSIONAL_MAKS_30 (opsional per PO, batas persen maks) / WAJIB_PEMASOK_TERPILIH'),
  ('CFG-PUR-17', '10', 'number',
   'Batas diskon baris PO di atas daftar harga sebelum wajib persetujuan Manajer (%); 0 = setiap diskon manual wajib persetujuan (PUR-BR06)'),
  ('CFG-PUR-18', 'AKTIF', 'string',
   'Kesepakatan pembelian kontrak berjangka (F16/PUR-BR26): NONAKTIF / AKTIF (blanket order) / AKTIF_TEMPLATE (blanket + template)'),
  ('CFG-PUR-19', 'OPSIONAL', 'string',
   'Tender penawaran RFQ alternatif (F17/PUR-BR27): NONAKTIF / OPSIONAL / WAJIB_DI_ATAS_NILAI'),
  ('CFG-PUR-20', 'KUNCI_OTOMATIS', 'string',
   'PO terkonfirmasi dikunci dari perubahan manual (PUR-BR28): NONAKTIF (amendment bebas via rev_no) / KUNCI_OTOMATIS (buka kunci oleh Manajer)'),
  ('CFG-PUR-21', '1', 'number',
   'Hari sebelum ETA pengingat konfirmasi tanggal terima dikirim ke pemasok (F18/PUR-BR29); 0 = nonaktif'),
  ('CFG-PUR-22', 'AKTIF_PER_PRODUK', 'string',
   'Dropship pengiriman langsung pemasok ke pelanggan (F19/PUR-BR30): NONAKTIF / AKTIF_PER_PRODUK / AKTIF_AUTO_PO')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'purchasing'
  AND NOT EXISTS (
    SELECT 1 FROM core_module_configs c
    WHERE c.param_key = v.param_key AND c.id_core_modules = m.id
  );

-- =============================================================================
-- STATUS KONTRAK DOKUMEN — blueprint analisa-modul-pur.md revisi 2026-11-07:
-- F15 (DP), F16 (kesepakatan + release), F17 (tender), F18 (komunikasi
-- pemasok), F19 (dropship), F9/M17 (usulan aset), F10 (landed), CFG-PUR-13
-- (delegasi) dan CFG-PUR-16…22 TERTUTUP di lapis struktur; penegakan perilaku
-- (batas DP PUR-BR24, pemenang tunggal PUR-BR27, kunci/buka-kunci PUR-BR28,
-- pengingat PUR-BR29, dropship PUR-BR30, alokasi landed) milik lapisan kode
-- (FASE 3b modul). Kontrak sah sejak patch ini terpasang.
-- =============================================================================
-- PATCH 33-purchasing-fitur-lanjutan.sql selesai.
