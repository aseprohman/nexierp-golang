-- +goose Up
-- ============================================================================
-- MIGRASI REKONSILIASI: 106_rekonsiliasi_pur-pemasok.sql
-- APA    : membuat objek LIVE-ONLY: pur_pemasok, pur_pemasok_kontak, pur_pemasok_harga
--          master pemasok PUR v2 (pemasok, kontak, harga)
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

-- ekstensi btree_gist: dibutuhkan constraint EXCLUDE USING gist (persis live;
-- butuh hak superuser / sudah terpasang di lingkungan target)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.pur_status_pemasok AS ENUM (
    'PROSPEK',
    'AKTIF',
    'NONAKTIF',
    'DIBLOKIR'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- TABEL (IF NOT EXISTS, kolom persis live) ----
CREATE TABLE IF NOT EXISTS public.pur_pemasok (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    kontak character varying(100),
    alamat character varying(300),
    alamat_faktur character varying(300),
    alamat_kirim character varying(300),
    mata_uang character varying(50) DEFAULT 'IDR'::character varying NOT NULL,
    npwp character varying(50),
    penanda_pkp boolean DEFAULT false NOT NULL,
    kode_termin character varying(50),
    lead_time_hari integer,
    status public.pur_status_pemasok DEFAULT 'PROSPEK'::public.pur_status_pemasok NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_core_kelurahan bigint
);

CREATE TABLE IF NOT EXISTS public.pur_pemasok_kontak (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_pur_pemasok bigint NOT NULL,
    nama character varying(100) NOT NULL,
    telepon character varying(50),
    email character varying(150),
    fungsi character varying(50),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.pur_pemasok_harga (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_pur_pemasok bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_unit_ukur bigint,
    qty_minimal integer DEFAULT 1 NOT NULL,
    harga numeric(18,4) NOT NULL,
    diskon_persen numeric(5,2),
    mata_uang character varying(50) DEFAULT 'IDR'::character varying NOT NULL,
    lead_time_hari integer,
    urutan_prioritas integer DEFAULT 1 NOT NULL,
    tanggal_mulai date NOT NULL,
    tanggal_selesai date,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_pur_pemasok_harga_periode CHECK (((tanggal_selesai IS NULL) OR (tanggal_selesai >= tanggal_mulai))),
    CONSTRAINT ck_pur_pemasok_harga_qty CHECK ((qty_minimal > 0))
);

-- kolom identity (persis live; setelah tabel, dilewati bila sudah identity)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='pur_pemasok'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.pur_pemasok ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.core_pemasok_id_seq
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
                 WHERE table_schema='public' AND table_name='pur_pemasok_kontak'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.pur_pemasok_kontak ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.core_pemasok_kontak_id_seq
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
                 WHERE table_schema='public' AND table_name='pur_pemasok_harga'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.pur_pemasok_harga ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.core_pemasok_harga_id_seq
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
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pur_pemasok_pkey'
                 AND conrelid = 'public.pur_pemasok'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT pur_pemasok_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_pemasok_entity_id'
                 AND conrelid = 'public.pur_pemasok'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT uq_pur_pemasok_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_pemasok_kode'
                 AND conrelid = 'public.pur_pemasok'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT uq_pur_pemasok_kode UNIQUE (kode);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_acc_termin'
                 AND conrelid = 'public.pur_pemasok'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT fk_pur_pemasok_acc_termin FOREIGN KEY (kode_termin) REFERENCES public.acc_termin_pembayaran(kode) ON DELETE RESTRICT NOT VALID;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_kelurahan'
                 AND conrelid = 'public.pur_pemasok'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT fk_pur_pemasok_kelurahan FOREIGN KEY (id_core_kelurahan) REFERENCES public.core_kelurahan(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pur_pemasok_kontak_pkey'
                 AND conrelid = 'public.pur_pemasok_kontak'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_kontak
    ADD CONSTRAINT pur_pemasok_kontak_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_pemasok_kontak_entity_id'
                 AND conrelid = 'public.pur_pemasok_kontak'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_kontak
    ADD CONSTRAINT uq_pur_pemasok_kontak_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_kontak_pemasok'
                 AND conrelid = 'public.pur_pemasok_kontak'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_kontak
    ADD CONSTRAINT fk_pur_pemasok_kontak_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES public.pur_pemasok(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ex_pur_pemasok_harga_overlap'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT ex_pur_pemasok_harga_overlap EXCLUDE USING gist (id_pur_pemasok WITH =, id_inv_produk WITH =, qty_minimal WITH =, daterange(tanggal_mulai, COALESCE(tanggal_selesai, 'infinity'::date), '[)'::text) WITH &&) WHERE ((deleted_at IS NULL));
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pur_pemasok_harga_pkey'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT pur_pemasok_harga_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_pur_pemasok_harga_entity_id'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT uq_pur_pemasok_harga_entity_id UNIQUE (entity_id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_harga_pemasok'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT fk_pur_pemasok_harga_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES public.pur_pemasok(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_harga_produk'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT fk_pur_pemasok_harga_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pur_pemasok_harga_unit'
                 AND conrelid = 'public.pur_pemasok_harga'::regclass) THEN
    ALTER TABLE ONLY public.pur_pemasok_harga
    ADD CONSTRAINT fk_pur_pemasok_harga_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- INDEX (persis live; IF NOT EXISTS) ----
CREATE INDEX IF NOT EXISTS ix_pur_pemasok_kelurahan ON public.pur_pemasok USING btree (id_core_kelurahan);

CREATE INDEX IF NOT EXISTS ix_pur_pemasok_status ON public.pur_pemasok USING btree (status) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_pur_pemasok_kontak_pemasok ON public.pur_pemasok_kontak USING btree (id_pur_pemasok) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_pur_pemasok_harga_pemasok ON public.pur_pemasok_harga USING btree (id_pur_pemasok) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS ix_pur_pemasok_harga_produk ON public.pur_pemasok_harga USING btree (id_inv_produk) WHERE (deleted_at IS NULL);

-- ---- TRIGGER (persis live) ----
DROP TRIGGER IF EXISTS trg_pur_pemasok_updated_at ON public.pur_pemasok;
CREATE TRIGGER trg_pur_pemasok_updated_at BEFORE UPDATE ON public.pur_pemasok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_pur_pemasok_kontak_updated_at ON public.pur_pemasok_kontak;
CREATE TRIGGER trg_pur_pemasok_kontak_updated_at BEFORE UPDATE ON public.pur_pemasok_kontak FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_pur_pemasok_harga_updated_at ON public.pur_pemasok_harga;
CREATE TRIGGER trg_pur_pemasok_harga_updated_at BEFORE UPDATE ON public.pur_pemasok_harga FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();