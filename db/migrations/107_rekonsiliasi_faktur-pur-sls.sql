-- +goose Up
-- ============================================================================
-- MIGRASI REKONSILIASI: 107_rekonsiliasi_faktur-pur-sls.sql
-- APA    : membuat objek LIVE-ONLY: pur_faktur_pembelian, pur_faktur_pembelian_items, sls_faktur_pelanggan, sls_faktur_pelanggan_items
--          faktur pembelian PUR & faktur pelanggan SLS v2 (+items)
-- KENAPA  : bentuk live DB dev = acuan kerja backend Go; tabel-tabel ini ada
--          di live (baseline Drizzle deploy) tetapi TIDAK dibuat oleh porting
--          ddl 1:1 (001..091) — file 012/025/037/045/046/048/051/055/056/061/
--          062/070/076/079/083/084 mereferensikannya lewat FK dan gagal di DB segar.
-- SUMBER : pg_dump --schema-only DB live dev 127.0.0.1:15433 (fakta, bukan tebakan);
--          bukti: /tmp/live-schema.sql
-- IDEMPOTEN: CREATE TABLE IF NOT EXISTS; constraint & identity dalam DO $$ dengan
--          cek pg_constraint / penangkap duplicate_object; index IF NOT EXISTS;
--          trigger DROP IF EXISTS + CREATE.
-- CATATAN: opsi reloption pg_attver milik ekstensi live sengaja dilewati (bukan struktur).
-- ============================================================================

-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_basis_pajak_acc AS ENUM (
    'INCLUSIVE',
    'EXCLUSIVE'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_jenis_faktur_pelanggan_acc AS ENUM (
    'REGULER',
    'UANG_MUKA'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_faktur_acc AS ENUM (
    'DRAFT',
    'POSTED',
    'LUNAS',
    'DIBATALKAN'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_faktur_pemasok_acc AS ENUM (
    'DRAFT',
    'DITAHAN_SELISIH',
    'POSTED',
    'LUNAS',
    'DIBATALKAN'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_status_match_acc AS ENUM (
    'COCOK',
    'SELISIH_TOLERANSI',
    'DI_LUAR_TOLERANSI'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.enum_sumber_faktur_pelanggan_acc AS ENUM (
    'SLS',
    'POS',
    'MANUAL'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- TABEL (IF NOT EXISTS, kolom persis live) ----
CREATE TABLE IF NOT EXISTS public.pur_faktur_pembelian (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nomor character varying(150) NOT NULL,
    nomor_bill_pemasok character varying(150) NOT NULL,
    jenis_sumber character varying(50) DEFAULT 'MANUAL'::character varying NOT NULL,
    entity_id_sumber character varying(255),
    id_pur_pemasok bigint NOT NULL,
    id_pur_pesanan_pembelian bigint,
    receipt_ref character varying(255),
    id_acc_termin bigint,
    tanggal date NOT NULL,
    jatuh_tempo date NOT NULL,
    kode_mata_uang character varying(3),
    kurs numeric(18,6),
    subtotal numeric(18,4) DEFAULT 0 NOT NULL,
    pajak numeric(18,4) DEFAULT 0 NOT NULL,
    total numeric(18,4) DEFAULT 0 NOT NULL,
    sisa numeric(18,4) DEFAULT 0 NOT NULL,
    status_match public.enum_status_match_acc,
    status public.enum_status_faktur_pemasok_acc DEFAULT 'DRAFT'::public.enum_status_faktur_pemasok_acc NOT NULL,
    id_core_users_penyusun bigint NOT NULL,
    alasan_batal character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.pur_faktur_pembelian_items (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_pur_faktur_pembelian bigint NOT NULL,
    id_inv_produk bigint,
    deskripsi character varying(200) NOT NULL,
    qty integer NOT NULL,
    harga_satuan numeric(18,4) NOT NULL,
    harga_po_snapshot numeric(18,4),
    diskon_persen numeric(18,6) DEFAULT 0 NOT NULL,
    id_acc_pajak bigint,
    tarif_pajak numeric(18,6),
    basis_pajak public.enum_basis_pajak_acc,
    pengali_dpp numeric(9,6) DEFAULT 1 NOT NULL,
    nilai_dpp numeric(18,4) DEFAULT 0 NOT NULL,
    nilai_pajak numeric(18,4) DEFAULT 0 NOT NULL,
    urutan integer DEFAULT 0 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT pur_faktur_pembelian_items_qty_check CHECK ((qty > 0))
);

CREATE TABLE IF NOT EXISTS public.sls_faktur_pelanggan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nomor character varying(150) NOT NULL,
    jenis_sumber character varying(50) DEFAULT 'MANUAL'::character varying NOT NULL,
    entity_id_sumber character varying(255),
    sumber public.enum_sumber_faktur_pelanggan_acc DEFAULT 'MANUAL'::public.enum_sumber_faktur_pelanggan_acc NOT NULL,
    jenis_faktur public.enum_jenis_faktur_pelanggan_acc DEFAULT 'REGULER'::public.enum_jenis_faktur_pelanggan_acc NOT NULL,
    id_sls_pelanggan bigint,
    id_sls_pesanan_penjualan bigint,
    id_acc_termin bigint,
    tanggal_faktur date NOT NULL,
    jatuh_tempo date NOT NULL,
    kode_mata_uang character varying(3),
    kurs numeric(18,6),
    subtotal numeric(18,4) DEFAULT 0 NOT NULL,
    diskon numeric(18,4) DEFAULT 0 NOT NULL,
    pajak numeric(18,4) DEFAULT 0 NOT NULL,
    total numeric(18,4) DEFAULT 0 NOT NULL,
    sisa numeric(18,4) DEFAULT 0 NOT NULL,
    status public.enum_status_faktur_acc DEFAULT 'DRAFT'::public.enum_status_faktur_acc NOT NULL,
    id_core_users_penyusun bigint NOT NULL,
    alasan_batal character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.sls_faktur_pelanggan_items (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_sls_faktur_pelanggan bigint NOT NULL,
    id_inv_produk bigint,
    deskripsi character varying(200) NOT NULL,
    qty integer NOT NULL,
    harga_satuan numeric(18,4) NOT NULL,
    diskon_persen numeric(18,6) DEFAULT 0 NOT NULL,
    id_acc_pajak bigint,
    tarif_pajak numeric(18,6),
    basis_pajak public.enum_basis_pajak_acc,
    pengali_dpp numeric(9,6) DEFAULT 1 NOT NULL,
    nilai_dpp numeric(18,4) DEFAULT 0 NOT NULL,
    nilai_pajak numeric(18,4) DEFAULT 0 NOT NULL,
    urutan integer DEFAULT 0 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT sls_faktur_pelanggan_items_qty_check CHECK ((qty > 0))
);

-- kolom identity (persis live; setelah tabel, dilewati bila sudah identity)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='pur_faktur_pembelian'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.pur_faktur_pembelian ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.pur_faktur_pembelian_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='pur_faktur_pembelian_items'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.pur_faktur_pembelian_items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.pur_faktur_pembelian_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='sls_faktur_pelanggan'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.sls_faktur_pelanggan ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sls_faktur_pelanggan_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='sls_faktur_pelanggan_items'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.sls_faktur_pelanggan_items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sls_faktur_pelanggan_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- CONSTRAINT (FK/PK/UNIQUE/CHECK persis live; idempoten) ----
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pur_faktur_pembelian_pkey'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT pur_faktur_pembelian_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_fktpms_entity_id'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT uq_pur_fktpms_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_fktpms_nomor'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT uq_pur_fktpms_nomor UNIQUE (nomor);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_pemasok'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT fk_pur_fktpms_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES public.pur_pemasok(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_penyusun'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT fk_pur_fktpms_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_po'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT fk_pur_fktpms_po FOREIGN KEY (id_pur_pesanan_pembelian) REFERENCES public.pur_pesanan(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_termin'
                 AND conrelid = 'public.pur_faktur_pembelian'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian
    ADD CONSTRAINT fk_pur_fktpms_termin FOREIGN KEY (id_acc_termin) REFERENCES public.acc_termin_pembayaran(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pur_faktur_pembelian_items_pkey'
                 AND conrelid = 'public.pur_faktur_pembelian_items'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian_items
    ADD CONSTRAINT pur_faktur_pembelian_items_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_fktpms_items_entity_id'
                 AND conrelid = 'public.pur_faktur_pembelian_items'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian_items
    ADD CONSTRAINT uq_pur_fktpms_items_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_items_faktur'
                 AND conrelid = 'public.pur_faktur_pembelian_items'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian_items
    ADD CONSTRAINT fk_pur_fktpms_items_faktur FOREIGN KEY (id_pur_faktur_pembelian) REFERENCES public.pur_faktur_pembelian(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_items_pajak'
                 AND conrelid = 'public.pur_faktur_pembelian_items'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian_items
    ADD CONSTRAINT fk_pur_fktpms_items_pajak FOREIGN KEY (id_acc_pajak) REFERENCES public.acc_pajak(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_fktpms_items_produk'
                 AND conrelid = 'public.pur_faktur_pembelian_items'::regclass) THEN
    ALTER TABLE ONLY public.pur_faktur_pembelian_items
    ADD CONSTRAINT fk_pur_fktpms_items_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sls_faktur_pelanggan_pkey'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT sls_faktur_pelanggan_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_sls_fktplg_entity_id'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT uq_sls_fktplg_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_sls_fktplg_nomor'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT uq_sls_fktplg_nomor UNIQUE (nomor);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_pelanggan'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT fk_sls_fktplg_pelanggan FOREIGN KEY (id_sls_pelanggan) REFERENCES public.sls_pelanggan(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_penyusun'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT fk_sls_fktplg_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_pesanan_penjualan'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT fk_sls_fktplg_pesanan_penjualan FOREIGN KEY (id_sls_pesanan_penjualan) REFERENCES public.sls_pesanan_penjualan(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_termin'
                 AND conrelid = 'public.sls_faktur_pelanggan'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan
    ADD CONSTRAINT fk_sls_fktplg_termin FOREIGN KEY (id_acc_termin) REFERENCES public.acc_termin_pembayaran(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sls_faktur_pelanggan_items_pkey'
                 AND conrelid = 'public.sls_faktur_pelanggan_items'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan_items
    ADD CONSTRAINT sls_faktur_pelanggan_items_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_sls_fktplg_items_entity_id'
                 AND conrelid = 'public.sls_faktur_pelanggan_items'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan_items
    ADD CONSTRAINT uq_sls_fktplg_items_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_items_faktur'
                 AND conrelid = 'public.sls_faktur_pelanggan_items'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan_items
    ADD CONSTRAINT fk_sls_fktplg_items_faktur FOREIGN KEY (id_sls_faktur_pelanggan) REFERENCES public.sls_faktur_pelanggan(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_items_pajak'
                 AND conrelid = 'public.sls_faktur_pelanggan_items'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan_items
    ADD CONSTRAINT fk_sls_fktplg_items_pajak FOREIGN KEY (id_acc_pajak) REFERENCES public.acc_pajak(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_fktplg_items_produk'
                 AND conrelid = 'public.sls_faktur_pelanggan_items'::regclass) THEN
    ALTER TABLE ONLY public.sls_faktur_pelanggan_items
    ADD CONSTRAINT fk_sls_fktplg_items_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- INDEX (persis live; IF NOT EXISTS) ----
CREATE INDEX IF NOT EXISTS ix_pur_fktpms_aging ON public.pur_faktur_pembelian USING btree (id_pur_pemasok, jatuh_tempo) WHERE ((status = 'POSTED'::public.enum_status_faktur_pemasok_acc) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_pur_fktpms_draft ON public.pur_faktur_pembelian USING btree (tanggal) WHERE ((status = ANY (ARRAY['DRAFT'::public.enum_status_faktur_pemasok_acc, 'DITAHAN_SELISIH'::public.enum_status_faktur_pemasok_acc])) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_pur_fktpms_po ON public.pur_faktur_pembelian USING btree (id_pur_pesanan_pembelian) WHERE (id_pur_pesanan_pembelian IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktpms_bill_pemasok ON public.pur_faktur_pembelian USING btree (id_pur_pemasok, nomor_bill_pemasok) WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktpms_idempoten ON public.pur_faktur_pembelian USING btree (jenis_sumber, entity_id_sumber) WHERE ((entity_id_sumber IS NOT NULL) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_pur_fktpms_items_faktur ON public.pur_faktur_pembelian_items USING btree (id_pur_faktur_pembelian) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_sls_fktplg_aging ON public.sls_faktur_pelanggan USING btree (id_sls_pelanggan, jatuh_tempo) WHERE ((status = 'POSTED'::public.enum_status_faktur_acc) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_sls_fktplg_draft ON public.sls_faktur_pelanggan USING btree (tanggal_faktur) WHERE ((status = 'DRAFT'::public.enum_status_faktur_acc) AND (deleted_at IS NULL));

CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktplg_idempoten ON public.sls_faktur_pelanggan USING btree (jenis_sumber, entity_id_sumber) WHERE ((entity_id_sumber IS NOT NULL) AND (deleted_at IS NULL));

CREATE INDEX IF NOT EXISTS ix_sls_fktplg_items_faktur ON public.sls_faktur_pelanggan_items USING btree (id_sls_faktur_pelanggan) WHERE (deleted_at IS NULL);

-- ---- TRIGGER (persis live) ----
DROP TRIGGER IF EXISTS trg_pur_faktur_pembelian_updated_at ON public.pur_faktur_pembelian;
CREATE TRIGGER trg_pur_faktur_pembelian_updated_at BEFORE UPDATE ON public.pur_faktur_pembelian FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_pur_faktur_pembelian_items_updated_at ON public.pur_faktur_pembelian_items;
CREATE TRIGGER trg_pur_faktur_pembelian_items_updated_at BEFORE UPDATE ON public.pur_faktur_pembelian_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_sls_faktur_pelanggan_updated_at ON public.sls_faktur_pelanggan;
CREATE TRIGGER trg_sls_faktur_pelanggan_updated_at BEFORE UPDATE ON public.sls_faktur_pelanggan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_sls_faktur_pelanggan_items_updated_at ON public.sls_faktur_pelanggan_items;
CREATE TRIGGER trg_sls_faktur_pelanggan_items_updated_at BEFORE UPDATE ON public.sls_faktur_pelanggan_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();