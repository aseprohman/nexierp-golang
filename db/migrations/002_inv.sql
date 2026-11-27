-- 002_inv.sql -- sumber: DB live nexierp-postgres (pg_dump schema-only, 2026-11-27)
-- isi = ddl/inv.sql (modul inv + cross-read pur_penerimaan/_item, pur_pesanan/_item, pur_pemasok)
-- +goose Up

-- ddl/inv.sql
-- Sumber: DB live nexierp-postgres (pg_dump schema-only, 2026-11-27), hanya modul inv.
-- Cross-read oleh inv — bukan bagian modul lain: pur_penerimaan(+_item),
-- pur_pesanan(+_item), pur_pemasok (dibaca query inv mutasi dari GR).
-- Enum inv, tabel inv_*, FK inv->inv dan inv->core (target ada di core.sql),
-- index/constraint/trigger, fungsi khusus inv. Regenerate ulang dari DB live
-- setelah perubahan skema lewat repo NestJS (lihat docs/ARSITEKTUR-BACKEND-GO.md).

--
-- Name: enum_frekuensi_hitung; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_frekuensi_hitung AS ENUM (
    'HARIAN',
    'MINGGUAN',
    'BULANAN',
    'TRIWULAN'
);

--
-- Name: enum_jenis_gerakan; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_gerakan AS ENUM (
    'PENERIMAAN',
    'PENGIRIMAN',
    'TRANSFER_INTERNAL',
    'PRODUKSI',
    'SCRAP',
    'PENYESUAIAN'
);

--
-- Name: enum_jenis_lokasi; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_lokasi AS ENUM (
    'INTERNAL',
    'VENDOR',
    'CUSTOMER',
    'PRODUKSI',
    'SCRAP'
);

--
-- Name: enum_jenis_penyesuaian; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_penyesuaian AS ENUM (
    'PENYESUAIAN',
    'CYCLE_COUNT',
    'SCRAP'
);

--
-- Name: enum_metode_valuasi; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_metode_valuasi AS ENUM (
    'STANDAR',
    'AVCO',
    'FIFO'
);

--
-- Name: enum_pelacakan; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_pelacakan AS ENUM (
    'TANPA',
    'LOT',
    'SERIAL'
);

--
-- Name: enum_penutupan_baris_pur; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_penutupan_baris_pur AS ENUM (
    'TERBUKA',
    'SISA_DITUTUP'
);

--
-- Name: enum_sistem_valuasi; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_sistem_valuasi AS ENUM (
    'PERPETUAL',
    'PERIODIK'
);

--
-- Name: enum_status_faktur_pur; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_faktur_pur AS ENUM (
    'BELUM_DIFAKTUR',
    'FAKTUR_PARSIAL',
    'FAKTUR_PENUH',
    'DITAHAN_SELISIH'
);

--
-- Name: enum_status_gerakan; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_gerakan AS ENUM (
    'DRAFT',
    'MENUNGGU_STOK',
    'TERJADWAL',
    'SEBAGIAN',
    'SELESAI',
    'BATAL'
);

--
-- Name: enum_status_lot_serial; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_lot_serial AS ENUM (
    'AKTIF',
    'KEDALUWARSA',
    'HABIS'
);

--
-- Name: enum_status_mutasi; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_mutasi AS ENUM (
    'DRAFT',
    'MENUNGGU_PERSETUJUAN',
    'DISETUJUI',
    'DITOLAK',
    'DIBATALKAN',
    'SELESAI'
);

--
-- Name: enum_status_penerimaan_pur; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_penerimaan_pur AS ENUM (
    'BELUM_DITERIMA',
    'SEBAGIAN_DITERIMA',
    'DITERIMA_PENUH'
);

--
-- Name: enum_status_penyesuaian; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_penyesuaian AS ENUM (
    'DRAFT',
    'MENUNGGU_PERSETUJUAN',
    'DISETUJUI',
    'DITOLAK',
    'DIBATALKAN'
);

--
-- Name: enum_status_po_pur; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_po_pur AS ENUM (
    'DRAFT',
    'MENUNGGU_APPROVAL',
    'DISETUJUI',
    'SELESAI',
    'DIBATALKAN'
);

--
-- Name: enum_status_reservasi; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_reservasi AS ENUM (
    'TIDAK',
    'TERRESERVASI'
);

--
-- Name: enum_tipe_atribut; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_tipe_atribut AS ENUM (
    'PILIHAN',
    'BEBAS'
);

--
-- Name: enum_tipe_produk; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_tipe_produk AS ENUM (
    'BARANG',
    'JASA',
    'BAHAN'
);

--
-- Name: pur_kondisi_terima; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pur_kondisi_terima AS ENUM (
    'BAIK',
    'RUSAK',
    'TOLAK'
);

--
-- Name: pur_status_pemasok; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pur_status_pemasok AS ENUM (
    'PROSPEK',
    'AKTIF',
    'NONAKTIF',
    'DIBLOKIR'
);

--
-- Name: pur_status_penerimaan; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pur_status_penerimaan AS ENUM (
    'DRAFT',
    'DITERIMA',
    'DIBATALKAN'
);

--
-- Name: pur_pemasok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pur_pemasok (
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
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN id SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN entity_id SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN kode SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN nama SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN kontak SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN alamat SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN alamat_faktur SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN alamat_kirim SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN mata_uang SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN npwp SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN penanda_pkp SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN kode_termin SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN lead_time_hari SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN status SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN version SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN created_at SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN updated_at SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN deleted_at SET (pg_attver=32867752);
ALTER TABLE ONLY public.pur_pemasok ALTER COLUMN id_core_kelurahan SET (pg_attver=49984608);

--
-- Name: TABLE pur_pemasok; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pur_pemasok IS '[MASTER] Master mitra pemasok — PEMILIK PURCHASING (keputusan pemilik 2026-11-12: membalik keputusan 2026-11-06 yang memindahkan ke CORE; pengelolaan tetap fitur PUR-F01). Konsumen rujuk: PUR (pur_pesanan, pur_kesepakatan), ACC (faktur, pembayaran, bukti potong, rekonsiliasi), INV (reorder M27/valuasi).';

--
-- Name: COLUMN pur_pemasok.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pur_pemasok.status IS 'Siklus hidup pemasok — enum pur_status_pemasok (rename dari core_status_pemasok, ddl/55).';

--
-- Name: COLUMN pur_pemasok.id_core_kelurahan; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pur_pemasok.id_core_kelurahan IS 'Referensi wilayah daun core_kelurahan (pemilik CORE — pola ddl/48) untuk akurasi biaya shipment dari pemasok (A-08 ditutup ronde-4). NULL = wilayah belum diisi.';

--
-- Name: inv_atribut; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_atribut (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    tipe_input public.enum_tipe_atribut DEFAULT 'PILIHAN'::public.enum_tipe_atribut NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN id SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN entity_id SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN kode SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN nama SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN tipe_input SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN status SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN version SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN created_at SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN updated_at SET (pg_attver=34650808);
ALTER TABLE ONLY public.inv_atribut ALTER COLUMN deleted_at SET (pg_attver=34650808);

--
-- Name: inv_gerakan_header; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_gerakan_header (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nomor_dokumen character varying(150) NOT NULL,
    jenis public.enum_jenis_gerakan NOT NULL,
    status public.enum_status_gerakan DEFAULT 'DRAFT'::public.enum_status_gerakan NOT NULL,
    langkah integer DEFAULT 1 NOT NULL,
    total_langkah integer DEFAULT 1 NOT NULL,
    reservasi public.enum_status_reservasi DEFAULT 'TIDAK'::public.enum_status_reservasi NOT NULL,
    tanggal_jadwal timestamp with time zone DEFAULT now() NOT NULL,
    tanggal_selesai timestamp with time zone,
    jenis_sumber character varying(50) DEFAULT 'MANUAL'::character varying NOT NULL,
    entity_id_sumber character varying(255),
    id_core_users bigint,
    id_core_users_penyusun bigint,
    id_core_users_penyetuju bigint,
    alasan character varying(300),
    id_lokasi_sumber bigint,
    id_lokasi_tujuan bigint,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    kode_jenis_operasi character varying(50),
    CONSTRAINT ck_inv_gerakan_header_langkah CHECK (((langkah >= 1) AND (langkah <= total_langkah))),
    CONSTRAINT ck_inv_gerakan_header_lokasi_beda CHECK (((id_lokasi_sumber IS NULL) OR (id_lokasi_tujuan IS NULL) OR (id_lokasi_sumber <> id_lokasi_tujuan))),
    CONSTRAINT ck_inv_gerakan_header_selesai_saat_status CHECK (((status <> 'SELESAI'::public.enum_status_gerakan) OR (tanggal_selesai IS NOT NULL)))
);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN entity_id SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN nomor_dokumen SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN jenis SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN status SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN langkah SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN total_langkah SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN reservasi SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN tanggal_jadwal SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN tanggal_selesai SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN jenis_sumber SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN entity_id_sumber SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id_core_users SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id_core_users_penyusun SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id_core_users_penyetuju SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN alasan SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id_lokasi_sumber SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN id_lokasi_tujuan SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN version SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN created_at SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN updated_at SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN deleted_at SET (pg_attver=34713952);
ALTER TABLE ONLY public.inv_gerakan_header ALTER COLUMN kode_jenis_operasi SET (pg_attver=34713952);

--
-- Name: inv_gerakan_stok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_gerakan_stok (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_lot_serial bigint,
    id_inv_unit_ukur bigint NOT NULL,
    qty_diminta integer NOT NULL,
    qty_selesai integer DEFAULT 0 NOT NULL,
    id_lokasi_sumber bigint,
    id_lokasi_tujuan bigint,
    nilai_persatuan numeric(18,4),
    tanggal_selesai timestamp with time zone,
    entity_id_sumber character varying(255),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_inv_gerakan_header bigint NOT NULL,
    CONSTRAINT ck_inv_gerakan_lokasi_beda CHECK ((id_lokasi_sumber <> id_lokasi_tujuan)),
    CONSTRAINT ck_inv_gerakan_qty_diminta CHECK ((qty_diminta > 0)),
    CONSTRAINT ck_inv_gerakan_qty_selesai CHECK (((qty_selesai >= 0) AND (qty_selesai <= qty_diminta)))
);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN entity_id SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_inv_produk SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_inv_lot_serial SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_inv_unit_ukur SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN qty_diminta SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN qty_selesai SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_lokasi_sumber SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_lokasi_tujuan SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN nilai_persatuan SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN tanggal_selesai SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN entity_id_sumber SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN version SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN created_at SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN updated_at SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN deleted_at SET (pg_attver=34759744);
ALTER TABLE ONLY public.inv_gerakan_stok ALTER COLUMN id_inv_gerakan_header SET (pg_attver=34759744);

--
-- Name: inv_gudang; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_gudang (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    kode_satuan character varying(50),
    alamat character varying(300),
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_core_kelurahan bigint,
    latitude numeric(9,6),
    longitude numeric(9,6)
);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN id SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN entity_id SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN kode SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN nama SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN kode_satuan SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN alamat SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN status SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN version SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN created_at SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN updated_at SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN deleted_at SET (pg_attver=34785328);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN id_core_kelurahan SET (pg_attver=113142856);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN latitude SET (pg_attver=113166032);
ALTER TABLE ONLY public.inv_gudang ALTER COLUMN longitude SET (pg_attver=113171176);

--
-- Name: inv_jadwal_hitung; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_jadwal_hitung (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    id_inv_gudang bigint NOT NULL,
    id_inv_lokasi_stok bigint,
    frekuensi public.enum_frekuensi_hitung DEFAULT 'BULANAN'::public.enum_frekuensi_hitung NOT NULL,
    hari_eksekusi integer DEFAULT 1 NOT NULL,
    aktif boolean DEFAULT true NOT NULL,
    terakhir_dibuat_pada timestamp with time zone,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_jadwal_hitung_hari CHECK (((hari_eksekusi >= 0) AND (hari_eksekusi <= 28)))
);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN id SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN entity_id SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN kode SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN nama SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN id_inv_gudang SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN id_inv_lokasi_stok SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN frekuensi SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN hari_eksekusi SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN aktif SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN terakhir_dibuat_pada SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN version SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN created_at SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN updated_at SET (pg_attver=34809432);
ALTER TABLE ONLY public.inv_jadwal_hitung ALTER COLUMN deleted_at SET (pg_attver=34809432);

--
-- Name: inv_jenis_operasi; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_jenis_operasi (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    jenis_gerakan public.enum_jenis_gerakan NOT NULL,
    prefix character varying(20) NOT NULL,
    jumlah_langkah integer DEFAULT 1 NOT NULL,
    nama_langkah_1 character varying(100) DEFAULT 'Input'::character varying NOT NULL,
    nama_langkah_2 character varying(100),
    nama_langkah_3 character varying(100),
    id_lokasi_sumber_default bigint,
    id_lokasi_tujuan_default bigint,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_jenis_operasi_langkah CHECK (((jumlah_langkah >= 1) AND (jumlah_langkah <= 3))),
    CONSTRAINT ck_inv_jenis_operasi_nama_langkah CHECK ((((jumlah_langkah < 2) OR (nama_langkah_2 IS NOT NULL)) AND ((jumlah_langkah < 3) OR (nama_langkah_3 IS NOT NULL))))
);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN id SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN entity_id SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN kode SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN nama SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN jenis_gerakan SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN prefix SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN jumlah_langkah SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN nama_langkah_1 SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN nama_langkah_2 SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN nama_langkah_3 SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN id_lokasi_sumber_default SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN id_lokasi_tujuan_default SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN status SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN version SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN created_at SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN updated_at SET (pg_attver=34830528);
ALTER TABLE ONLY public.inv_jenis_operasi ALTER COLUMN deleted_at SET (pg_attver=34830528);

--
-- Name: inv_kategori_produk; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_kategori_produk (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nama character varying(100) NOT NULL,
    id_kategori_induk bigint,
    metode_valuasi public.enum_metode_valuasi DEFAULT 'STANDAR'::public.enum_metode_valuasi NOT NULL,
    sistem_valuasi public.enum_sistem_valuasi DEFAULT 'PERPETUAL'::public.enum_sistem_valuasi NOT NULL,
    kebijakan_pelacakan public.enum_pelacakan DEFAULT 'TANPA'::public.enum_pelacakan NOT NULL,
    kebijakan_kedaluwarsa boolean DEFAULT false NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN id SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN entity_id SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN nama SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN id_kategori_induk SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN metode_valuasi SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN sistem_valuasi SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN kebijakan_pelacakan SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN kebijakan_kedaluwarsa SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN status SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN version SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN created_at SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN updated_at SET (pg_attver=34856328);
ALTER TABLE ONLY public.inv_kategori_produk ALTER COLUMN deleted_at SET (pg_attver=34856328);

--
-- Name: inv_kemasan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_kemasan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_produk bigint NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    barcode character varying(50),
    id_inv_unit_ukur bigint NOT NULL,
    qty_isi integer NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_kemasan_isi CHECK ((qty_isi > 0))
);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN id SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN entity_id SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN id_inv_produk SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN kode SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN nama SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN barcode SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN id_inv_unit_ukur SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN qty_isi SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN status SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN version SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN created_at SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN updated_at SET (pg_attver=34879608);
ALTER TABLE ONLY public.inv_kemasan ALTER COLUMN deleted_at SET (pg_attver=34879608);

--
-- Name: inv_lapisan_biaya; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_lapisan_biaya (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_lot_serial bigint,
    nomor_dokumen_masuk character varying(150) NOT NULL,
    tanggal_masuk timestamp with time zone DEFAULT now() NOT NULL,
    qty_masuk integer NOT NULL,
    qty_terpakai integer DEFAULT 0 NOT NULL,
    biaya_persatuan numeric(18,4) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_lapisan_biaya_biaya CHECK ((biaya_persatuan >= (0)::numeric)),
    CONSTRAINT ck_inv_lapisan_biaya_qty CHECK (((qty_masuk > 0) AND (qty_terpakai >= 0) AND (qty_terpakai <= qty_masuk)))
);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN id SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN entity_id SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN id_inv_produk SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN id_inv_lot_serial SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN nomor_dokumen_masuk SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN tanggal_masuk SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN qty_masuk SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN qty_terpakai SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN biaya_persatuan SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN version SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN created_at SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN updated_at SET (pg_attver=34904376);
ALTER TABLE ONLY public.inv_lapisan_biaya ALTER COLUMN deleted_at SET (pg_attver=34904376);

--
-- Name: inv_lokasi_stok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_lokasi_stok (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    jenis public.enum_jenis_lokasi DEFAULT 'INTERNAL'::public.enum_jenis_lokasi NOT NULL,
    id_inv_gudang bigint,
    id_lokasi_induk bigint,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_lokasi_internal_punya_gudang CHECK (((jenis <> 'INTERNAL'::public.enum_jenis_lokasi) OR (id_inv_gudang IS NOT NULL)))
);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN id SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN entity_id SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN kode SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN nama SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN jenis SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN id_inv_gudang SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN id_lokasi_induk SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN status SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN version SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN created_at SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN updated_at SET (pg_attver=34930032);
ALTER TABLE ONLY public.inv_lokasi_stok ALTER COLUMN deleted_at SET (pg_attver=34930032);

--
-- Name: inv_lot_serial; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_lot_serial (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_produk bigint NOT NULL,
    kode character varying(100) NOT NULL,
    tanggal_prodiksi timestamp with time zone,
    tanggal_kedaluwarsa timestamp with time zone,
    status public.enum_status_lot_serial DEFAULT 'AKTIF'::public.enum_status_lot_serial NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    barcode character varying(50),
    CONSTRAINT ck_inv_lot_serial_tanggal CHECK (((tanggal_kedaluwarsa IS NULL) OR (tanggal_prodiksi IS NULL) OR (tanggal_kedaluwarsa > tanggal_prodiksi)))
);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN id SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN entity_id SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN id_inv_produk SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN kode SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN tanggal_prodiksi SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN tanggal_kedaluwarsa SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN status SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN version SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN created_at SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN updated_at SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN deleted_at SET (pg_attver=34950840);
ALTER TABLE ONLY public.inv_lot_serial ALTER COLUMN barcode SET (pg_attver=34950840);

--
-- Name: COLUMN inv_lot_serial.barcode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.inv_lot_serial.barcode IS 'barcode lot/serial (opsional) — resolver barcode terpadu bersama produk & kemasan;unik di antara lot hidup (partial unique, boleh dipakai ulang setelah soft delete)';

--
-- Name: inv_mutasi_dokumen; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_mutasi_dokumen (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    jenis public.enum_jenis_gerakan NOT NULL,
    status public.enum_status_mutasi DEFAULT 'DRAFT'::public.enum_status_mutasi NOT NULL,
    tanggal_dokumen timestamp with time zone DEFAULT now() NOT NULL,
    id_core_users_penyusun bigint,
    id_core_users_penyetuju bigint,
    alasan character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_lokasi_sumber bigint NOT NULL,
    id_lokasi_tujuan bigint NOT NULL,
    id_pur_penerimaan bigint,
    CONSTRAINT ck_inv_mutasi_lokasi_beda CHECK ((id_lokasi_sumber <> id_lokasi_tujuan))
);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN entity_id SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN kode SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN jenis SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN status SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN tanggal_dokumen SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id_core_users_penyusun SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id_core_users_penyetuju SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN alasan SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN version SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN created_at SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN updated_at SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN deleted_at SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id_lokasi_sumber SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id_lokasi_tujuan SET (pg_attver=34971240);
ALTER TABLE ONLY public.inv_mutasi_dokumen ALTER COLUMN id_pur_penerimaan SET (pg_attver=50306968);

--
-- Name: COLUMN inv_mutasi_dokumen.id_pur_penerimaan; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.inv_mutasi_dokumen.id_pur_penerimaan IS 'Soft-id GR PUR sumber (pur_penerimaan.id — pemilik PURCHASING, ddl/57) — TANPA FK (pola PP-02/03 "ACC/AST/FIN = id tanpa FK"): INV hanya membaca GR (pull generate mutasi penerimaan, arah TERIMA jalur aktif) dan tidak pernah menulis tabel PUR; integritas logis ditegakkan app (GR wajib DITERIMA saat generate). NULL = mutasi manual (bukan dari GR).';

--
-- Name: inv_mutasi_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_mutasi_items (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_mutasi_dokumen bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_lot_serial bigint,
    id_inv_unit_ukur bigint NOT NULL,
    qty_diminta integer NOT NULL,
    nama_produk character varying(100) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_pur_penerimaan_item bigint,
    CONSTRAINT ck_inv_mutasi_items_qty CHECK ((qty_diminta > 0))
);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN entity_id SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id_inv_mutasi_dokumen SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id_inv_produk SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id_inv_lot_serial SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id_inv_unit_ukur SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN qty_diminta SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN nama_produk SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN version SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN created_at SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN updated_at SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN deleted_at SET (pg_attver=34992784);
ALTER TABLE ONLY public.inv_mutasi_items ALTER COLUMN id_pur_penerimaan_item SET (pg_attver=50311120);

--
-- Name: COLUMN inv_mutasi_items.id_pur_penerimaan_item; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.inv_mutasi_items.id_pur_penerimaan_item IS 'Soft-id baris GR sumber (pur_penerimaan_item.id — pemilik PURCHASING, ddl/57) — TANPA FK (pola PP-02/03): jejak asal baris untuk konversi satuan PUR-BR16 (qty unit beli → qty dasar) & nilai harga PO net per satuan dasar saat posting/konfirmasi gerakan; baris GR TOLAK tidak pernah dimutasi (setara PUR-BR33). NULL = item manual.';

--
-- Name: inv_nilai_atribut; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_nilai_atribut (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_atribut bigint NOT NULL,
    nilai character varying(100) NOT NULL,
    urutan integer DEFAULT 0 NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN id SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN entity_id SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN id_inv_atribut SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN nilai SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN urutan SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN status SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN version SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN created_at SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN updated_at SET (pg_attver=35010120);
ALTER TABLE ONLY public.inv_nilai_atribut ALTER COLUMN deleted_at SET (pg_attver=35010120);

--
-- Name: inv_penyesuaian_stok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_penyesuaian_stok (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    jenis public.enum_jenis_penyesuaian DEFAULT 'PENYESUAIAN'::public.enum_jenis_penyesuaian NOT NULL,
    status public.enum_status_penyesuaian DEFAULT 'DRAFT'::public.enum_status_penyesuaian NOT NULL,
    id_inv_gudang bigint NOT NULL,
    tanggal_dokumen timestamp with time zone DEFAULT now() NOT NULL,
    id_core_users_penyusun bigint,
    id_core_users_penyetuju bigint,
    alasan character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN id SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN entity_id SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN kode SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN jenis SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN status SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN id_inv_gudang SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN tanggal_dokumen SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN id_core_users_penyusun SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN id_core_users_penyetuju SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN alasan SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN version SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN created_at SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN updated_at SET (pg_attver=35030704);
ALTER TABLE ONLY public.inv_penyesuaian_stok ALTER COLUMN deleted_at SET (pg_attver=35030704);

--
-- Name: inv_penyesuaian_stok_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_penyesuaian_stok_items (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_penyesuaian_stok bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_lot_serial bigint,
    id_inv_lokasi_stok bigint NOT NULL,
    id_inv_unit_ukur bigint NOT NULL,
    qty_sistem integer DEFAULT 0 NOT NULL,
    qty_hitung integer DEFAULT 0 NOT NULL,
    qty_selisih integer DEFAULT 0 NOT NULL,
    biaya_satuan numeric(18,4),
    nama_produk character varying(100) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_inv_kemasan bigint,
    isi_per_kemasan integer,
    CONSTRAINT ck_inv_penyesuaian_items_kemasan CHECK (((id_inv_kemasan IS NULL) OR (isi_per_kemasan > 0))),
    CONSTRAINT ck_inv_penyesuaian_items_qty CHECK (((qty_sistem >= 0) AND (qty_hitung >= 0)))
);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN entity_id SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_penyesuaian_stok SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_produk SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_lot_serial SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_lokasi_stok SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_unit_ukur SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN qty_sistem SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN qty_hitung SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN qty_selisih SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN biaya_satuan SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN nama_produk SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN version SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN created_at SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN updated_at SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN deleted_at SET (pg_attver=35053840);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN id_inv_kemasan SET (pg_attver=49936432);
ALTER TABLE ONLY public.inv_penyesuaian_stok_items ALTER COLUMN isi_per_kemasan SET (pg_attver=49936880);

--
-- Name: inv_produk; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_produk (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode_produk character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    tipe public.enum_tipe_produk DEFAULT 'BARANG'::public.enum_tipe_produk NOT NULL,
    id_inv_kategori_produk bigint NOT NULL,
    id_inv_unit_ukur bigint NOT NULL,
    jejak_stok boolean DEFAULT true NOT NULL,
    barcode character varying(50),
    harga_jual numeric(18,4),
    harga_biaya numeric(18,4),
    stok_minimum integer DEFAULT 0 NOT NULL,
    stok_maksimum integer,
    reorder_aktif boolean DEFAULT false NOT NULL,
    berat_gram integer,
    volume_cm3 integer,
    keterangan text,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_inv_produk_induk bigint,
    kunci_kombinasi character varying(300),
    adalah_induk_varian boolean DEFAULT false NOT NULL,
    CONSTRAINT ck_inv_produk_berat CHECK (((berat_gram IS NULL) OR (berat_gram >= 0))),
    CONSTRAINT ck_inv_produk_kombinasi CHECK (((kunci_kombinasi IS NULL) OR (id_inv_produk_induk IS NOT NULL))),
    CONSTRAINT ck_inv_produk_maks CHECK (((stok_maksimum IS NULL) OR (stok_maksimum > stok_minimum))),
    CONSTRAINT ck_inv_produk_volume CHECK (((volume_cm3 IS NULL) OR (volume_cm3 >= 0)))
);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN id SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN entity_id SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN kode_produk SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN nama SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN tipe SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN id_inv_kategori_produk SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN id_inv_unit_ukur SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN jejak_stok SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN barcode SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN harga_jual SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN harga_biaya SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN stok_minimum SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN stok_maksimum SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN reorder_aktif SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN berat_gram SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN volume_cm3 SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN keterangan SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN status SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN version SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN created_at SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN updated_at SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN deleted_at SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN id_inv_produk_induk SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN kunci_kombinasi SET (pg_attver=35076288);
ALTER TABLE ONLY public.inv_produk ALTER COLUMN adalah_induk_varian SET (pg_attver=35076288);

--
-- Name: COLUMN inv_produk.id_inv_produk_induk; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.inv_produk.id_inv_produk_induk IS 'NULL = produk sederhana (tanpa varian); terisi = varian dari inv_produk_induk';

--
-- Name: COLUMN inv_produk.kunci_kombinasi; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.inv_produk.kunci_kombinasi IS 'kombinasi kanonik nilai atribut, dibentuk app (sorted "atribut:nilai|...") — hanya untuk varian';

--
-- Name: inv_produk_atribut; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_produk_atribut (
    id_inv_produk bigint NOT NULL,
    id_inv_nilai_atribut bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_produk_atribut ALTER COLUMN id_inv_produk SET (pg_attver=35114416);
ALTER TABLE ONLY public.inv_produk_atribut ALTER COLUMN id_inv_nilai_atribut SET (pg_attver=35114416);
ALTER TABLE ONLY public.inv_produk_atribut ALTER COLUMN created_at SET (pg_attver=35114416);
ALTER TABLE ONLY public.inv_produk_atribut ALTER COLUMN updated_at SET (pg_attver=35114416);
ALTER TABLE ONLY public.inv_produk_atribut ALTER COLUMN deleted_at SET (pg_attver=35114416);

--
-- Name: inv_produk_varian_konfig; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_produk_varian_konfig (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_atribut bigint NOT NULL,
    wajib boolean DEFAULT true NOT NULL,
    urutan integer DEFAULT 0 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN id SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN entity_id SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN id_inv_produk SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN id_inv_atribut SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN wajib SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN urutan SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN version SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN created_at SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN updated_at SET (pg_attver=35126160);
ALTER TABLE ONLY public.inv_produk_varian_konfig ALTER COLUMN deleted_at SET (pg_attver=35126160);

--
-- Name: inv_saldo_stok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_saldo_stok (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_inv_lokasi_stok bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_lot_serial bigint,
    qty_on_hand integer DEFAULT 0 NOT NULL,
    qty_dipesan integer DEFAULT 0 NOT NULL,
    qty_tersedia integer DEFAULT 0 NOT NULL,
    nilai_persediaan numeric(18,4) DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_saldo_on_hand CHECK ((qty_on_hand >= 0))
);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN id SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN entity_id SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN id_inv_lokasi_stok SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN id_inv_produk SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN id_inv_lot_serial SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN qty_on_hand SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN qty_dipesan SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN qty_tersedia SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN nilai_persediaan SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN created_at SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN updated_at SET (pg_attver=35143136);
ALTER TABLE ONLY public.inv_saldo_stok ALTER COLUMN deleted_at SET (pg_attver=35143136);

--
-- Name: inv_unit_konversi; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_unit_konversi (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_unit_dari bigint NOT NULL,
    id_unit_ke bigint NOT NULL,
    faktor numeric(18,6) NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_inv_unit_konversi_beda_unit CHECK ((id_unit_dari <> id_unit_ke)),
    CONSTRAINT ck_inv_unit_konversi_faktor CHECK ((faktor > (0)::numeric))
);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN id SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN entity_id SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN id_unit_dari SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN id_unit_ke SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN faktor SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN status SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN version SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN created_at SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN updated_at SET (pg_attver=35163264);
ALTER TABLE ONLY public.inv_unit_konversi ALTER COLUMN deleted_at SET (pg_attver=35163264);

--
-- Name: inv_unit_ukur; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inv_unit_ukur (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    kategori_uom character varying(50) DEFAULT 'UNIT'::character varying NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN id SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN entity_id SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN kode SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN nama SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN kategori_uom SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN status SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN version SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN created_at SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN updated_at SET (pg_attver=35183384);
ALTER TABLE ONLY public.inv_unit_ukur ALTER COLUMN deleted_at SET (pg_attver=35183384);

--
-- Name: pur_penerimaan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pur_penerimaan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nomor character varying(150) NOT NULL,
    id_pur_pesanan bigint NOT NULL,
    id_inv_gudang bigint,
    id_core_users_penerima bigint,
    referensi_surat_jalan character varying(150),
    tanggal_terima timestamp with time zone,
    status public.pur_status_penerimaan DEFAULT 'DRAFT'::public.pur_status_penerimaan NOT NULL,
    catatan character varying(300),
    alasan_pembatalan character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_pur_penerimaan_batal CHECK (((status <> 'DIBATALKAN'::public.pur_status_penerimaan) OR (alasan_pembatalan IS NOT NULL)))
);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN id SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN entity_id SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN nomor SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN id_pur_pesanan SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN id_inv_gudang SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN id_core_users_penerima SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN referensi_surat_jalan SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN tanggal_terima SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN status SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN catatan SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN alasan_pembatalan SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN version SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN created_at SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN updated_at SET (pg_attver=50001080);
ALTER TABLE ONLY public.pur_penerimaan ALTER COLUMN deleted_at SET (pg_attver=50001080);

--
-- Name: TABLE pur_penerimaan; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pur_penerimaan IS '[TRANSAKSI] Penerimaan barang (Goods Receipt, GR) — PEMILIK PURCHASING (PUR-F20, keputusan pemilik 2026-11-12): header-detail di-generate dari PO DISETUJUI/SELESAI, parsial multi-GR per PO. Posting (DRAFT→DITERIMA) satu tx: akumulasi pur_pesanan_item.qty_diterima (kondisi ≠ TOLAK) + recompute pur_pesanan.status_penerimaan + outbox `pur.penerimaan.diterima` (idempoten key penerimaan:<id>) — konsumen INV (arah TERIMA menggantikan jalur M04 lama). GR DITERIMA immutable; DIBATALKAN wajib alasan (CHECK).';

--
-- Name: COLUMN pur_penerimaan.tanggal_terima; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pur_penerimaan.tanggal_terima IS 'Waktu posting GR (POST :id/posting) — NULL selama DRAFT.';

--
-- Name: COLUMN pur_penerimaan.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pur_penerimaan.status IS 'Siklus hidup GR — enum pur_status_penerimaan (ddl/57): DRAFT → DITERIMA (posting) | DIBATALKAN. Berbeda dari enum_status_penerimaan_pur yang adalah trek pelengkap progres PO.';

--
-- Name: pur_penerimaan_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pur_penerimaan_item (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_pur_penerimaan bigint NOT NULL,
    id_pur_pesanan_item bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    qty_diterima integer NOT NULL,
    kondisi public.pur_kondisi_terima DEFAULT 'BAIK'::public.pur_kondisi_terima NOT NULL,
    catatan character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_pur_penerimaan_item_qty CHECK ((qty_diterima > 0))
);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN id SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN entity_id SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN id_pur_penerimaan SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN id_pur_pesanan_item SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN id_inv_produk SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN qty_diterima SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN kondisi SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN catatan SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN version SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN created_at SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN updated_at SET (pg_attver=50062144);
ALTER TABLE ONLY public.pur_penerimaan_item ALTER COLUMN deleted_at SET (pg_attver=50062144);

--
-- Name: TABLE pur_penerimaan_item; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pur_penerimaan_item IS '[LINE] Baris terima per baris PO — atribut pur_penerimaan (PUR-F20): qty_diterima > 0 + kondisi BAIK|RUSAK|TOLAK; TOLAK tidak menambah qty_diterima PO & tidak dihitung sisa (PUR-BR33). Over-receipt TIDAK lewat GR — sisa efektif ditegakkan app (PUR-BR32).';

--
-- Name: COLUMN pur_penerimaan_item.kondisi; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pur_penerimaan_item.kondisi IS 'Kondisi barang diterima — enum pur_kondisi_terima (ddl/57): BAIK (masuk stok), RUSAK (tetap menambah qty_diterima PO — tercatat diterima), TOLAK (ditolak — tidak menambah qty_diterima & tidak dihitung sisa, PUR-BR33).';

--
-- Name: pur_pesanan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pur_pesanan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nomor character varying(150) NOT NULL,
    id_pur_pemasok bigint NOT NULL,
    id_inv_gudang bigint,
    mata_uang character varying(50) DEFAULT 'IDR'::character varying NOT NULL,
    nilai_total numeric(18,4) DEFAULT 0 NOT NULL,
    eta timestamp with time zone,
    rfq_terkirim_pada timestamp with time zone,
    status public.enum_status_po_pur DEFAULT 'DRAFT'::public.enum_status_po_pur NOT NULL,
    status_penerimaan public.enum_status_penerimaan_pur DEFAULT 'BELUM_DITERIMA'::public.enum_status_penerimaan_pur NOT NULL,
    status_faktur public.enum_status_faktur_pur DEFAULT 'BELUM_DIFAKTUR'::public.enum_status_faktur_pur NOT NULL,
    rev_no integer DEFAULT 0 NOT NULL,
    alasan_penutupan character varying(300),
    catatan character varying(300),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_core_users_penyusun bigint,
    po_terkirim_pada timestamp with time zone,
    eta_konfirmasi_pada timestamp with time zone,
    eta_konfirmasi_oleh bigint,
    pengiriman_langsung boolean DEFAULT false NOT NULL,
    so_ref character varying(150),
    id_pur_kesepakatan bigint,
    terkunci boolean DEFAULT false NOT NULL,
    tanggal_kunci timestamp with time zone,
    CONSTRAINT ck_pur_pesanan_batal CHECK (((status <> 'DIBATALKAN'::public.enum_status_po_pur) OR (alasan_penutupan IS NOT NULL)))
);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN id SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN entity_id SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN nomor SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN id_pur_pemasok SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN id_inv_gudang SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN mata_uang SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN nilai_total SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN eta SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN rfq_terkirim_pada SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN status SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN status_penerimaan SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN status_faktur SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN rev_no SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN alasan_penutupan SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN catatan SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN version SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN created_at SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN updated_at SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN deleted_at SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN id_core_users_penyusun SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN po_terkirim_pada SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN eta_konfirmasi_pada SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN eta_konfirmasi_oleh SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN pengiriman_langsung SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN so_ref SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN id_pur_kesepakatan SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN terkunci SET (pg_attver=35979088);
ALTER TABLE ONLY public.pur_pesanan ALTER COLUMN tanggal_kunci SET (pg_attver=35979088);

--
-- Name: pur_pesanan_item; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pur_pesanan_item (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_pur_pesanan bigint NOT NULL,
    id_inv_produk bigint NOT NULL,
    id_inv_unit_ukur bigint NOT NULL,
    id_pur_permintaan_item bigint,
    qty integer NOT NULL,
    harga numeric(18,4) NOT NULL,
    diskon_persen numeric(5,2),
    kode_pajak character varying(50),
    eta_baris timestamp with time zone,
    catatan character varying(300),
    qty_diterima integer DEFAULT 0 NOT NULL,
    qty_difaktur integer DEFAULT 0 NOT NULL,
    qty_diretur integer DEFAULT 0 NOT NULL,
    penanda_sisa public.enum_penutupan_baris_pur DEFAULT 'TERBUKA'::public.enum_penutupan_baris_pur NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    id_pur_kesepakatan_item bigint,
    pengiriman_langsung boolean DEFAULT false NOT NULL,
    alamat_kirim character varying(300),
    CONSTRAINT ck_pur_pesanan_item_akumulasi CHECK (((qty_diterima >= 0) AND (qty_difaktur >= 0) AND (qty_diretur >= 0))),
    CONSTRAINT ck_pur_pesanan_item_qty CHECK ((qty > 0))
);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN entity_id SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id_pur_pesanan SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id_inv_produk SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id_inv_unit_ukur SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id_pur_permintaan_item SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN qty SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN harga SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN diskon_persen SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN kode_pajak SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN eta_baris SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN catatan SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN qty_diterima SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN qty_difaktur SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN qty_diretur SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN penanda_sisa SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN version SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN created_at SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN updated_at SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN deleted_at SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN id_pur_kesepakatan_item SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN pengiriman_langsung SET (pg_attver=36021160);
ALTER TABLE ONLY public.pur_pesanan_item ALTER COLUMN alamat_kirim SET (pg_attver=36021160);

--
-- Name: inv_atribut inv_atribut_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_atribut
    ADD CONSTRAINT inv_atribut_pkey PRIMARY KEY (id);

--
-- Name: inv_gerakan_header inv_gerakan_header_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT inv_gerakan_header_pkey PRIMARY KEY (id);

--
-- Name: inv_gerakan_stok inv_gerakan_stok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT inv_gerakan_stok_pkey PRIMARY KEY (id);

--
-- Name: inv_gudang inv_gudang_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gudang
    ADD CONSTRAINT inv_gudang_pkey PRIMARY KEY (id);

--
-- Name: inv_jadwal_hitung inv_jadwal_hitung_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jadwal_hitung
    ADD CONSTRAINT inv_jadwal_hitung_pkey PRIMARY KEY (id);

--
-- Name: inv_jenis_operasi inv_jenis_operasi_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jenis_operasi
    ADD CONSTRAINT inv_jenis_operasi_pkey PRIMARY KEY (id);

--
-- Name: inv_kategori_produk inv_kategori_produk_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kategori_produk
    ADD CONSTRAINT inv_kategori_produk_pkey PRIMARY KEY (id);

--
-- Name: inv_kemasan inv_kemasan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kemasan
    ADD CONSTRAINT inv_kemasan_pkey PRIMARY KEY (id);

--
-- Name: inv_lapisan_biaya inv_lapisan_biaya_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lapisan_biaya
    ADD CONSTRAINT inv_lapisan_biaya_pkey PRIMARY KEY (id);

--
-- Name: inv_lokasi_stok inv_lokasi_stok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lokasi_stok
    ADD CONSTRAINT inv_lokasi_stok_pkey PRIMARY KEY (id);

--
-- Name: inv_lot_serial inv_lot_serial_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lot_serial
    ADD CONSTRAINT inv_lot_serial_pkey PRIMARY KEY (id);

--
-- Name: inv_mutasi_dokumen inv_mutasi_dokumen_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT inv_mutasi_dokumen_pkey PRIMARY KEY (id);

--
-- Name: inv_mutasi_items inv_mutasi_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT inv_mutasi_items_pkey PRIMARY KEY (id);

--
-- Name: inv_nilai_atribut inv_nilai_atribut_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_nilai_atribut
    ADD CONSTRAINT inv_nilai_atribut_pkey PRIMARY KEY (id);

--
-- Name: inv_penyesuaian_stok_items inv_penyesuaian_stok_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT inv_penyesuaian_stok_items_pkey PRIMARY KEY (id);

--
-- Name: inv_penyesuaian_stok inv_penyesuaian_stok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT inv_penyesuaian_stok_pkey PRIMARY KEY (id);

--
-- Name: inv_produk inv_produk_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT inv_produk_pkey PRIMARY KEY (id);

--
-- Name: inv_produk_varian_konfig inv_produk_varian_konfig_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_varian_konfig
    ADD CONSTRAINT inv_produk_varian_konfig_pkey PRIMARY KEY (id);

--
-- Name: inv_saldo_stok inv_saldo_stok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_saldo_stok
    ADD CONSTRAINT inv_saldo_stok_pkey PRIMARY KEY (id);

--
-- Name: inv_unit_konversi inv_unit_konversi_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_konversi
    ADD CONSTRAINT inv_unit_konversi_pkey PRIMARY KEY (id);

--
-- Name: inv_unit_ukur inv_unit_ukur_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_ukur
    ADD CONSTRAINT inv_unit_ukur_pkey PRIMARY KEY (id);

--
-- Name: inv_produk_atribut pk_inv_produk_atribut; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_atribut
    ADD CONSTRAINT pk_inv_produk_atribut PRIMARY KEY (id_inv_produk, id_inv_nilai_atribut);

--
-- Name: pur_pemasok pur_pemasok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT pur_pemasok_pkey PRIMARY KEY (id);

--
-- Name: pur_penerimaan_item pur_penerimaan_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan_item
    ADD CONSTRAINT pur_penerimaan_item_pkey PRIMARY KEY (id);

--
-- Name: pur_penerimaan pur_penerimaan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT pur_penerimaan_pkey PRIMARY KEY (id);

--
-- Name: pur_pesanan_item pur_pesanan_item_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan_item
    ADD CONSTRAINT pur_pesanan_item_pkey PRIMARY KEY (id);

--
-- Name: pur_pesanan pur_pesanan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT pur_pesanan_pkey PRIMARY KEY (id);

--
-- Name: inv_atribut uq_inv_atribut_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_atribut
    ADD CONSTRAINT uq_inv_atribut_entity_id UNIQUE (entity_id);

--
-- Name: inv_atribut uq_inv_atribut_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_atribut
    ADD CONSTRAINT uq_inv_atribut_kode UNIQUE (kode);

--
-- Name: inv_gerakan_header uq_inv_gerakan_header_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT uq_inv_gerakan_header_entity_id UNIQUE (entity_id);

--
-- Name: inv_gerakan_header uq_inv_gerakan_header_nomor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT uq_inv_gerakan_header_nomor UNIQUE (nomor_dokumen);

--
-- Name: inv_gerakan_stok uq_inv_gerakan_stok_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT uq_inv_gerakan_stok_entity_id UNIQUE (entity_id);

--
-- Name: inv_gudang uq_inv_gudang_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gudang
    ADD CONSTRAINT uq_inv_gudang_entity_id UNIQUE (entity_id);

--
-- Name: inv_gudang uq_inv_gudang_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gudang
    ADD CONSTRAINT uq_inv_gudang_kode UNIQUE (kode);

--
-- Name: inv_jadwal_hitung uq_inv_jadwal_hitung_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jadwal_hitung
    ADD CONSTRAINT uq_inv_jadwal_hitung_entity_id UNIQUE (entity_id);

--
-- Name: inv_jadwal_hitung uq_inv_jadwal_hitung_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jadwal_hitung
    ADD CONSTRAINT uq_inv_jadwal_hitung_kode UNIQUE (kode);

--
-- Name: inv_jenis_operasi uq_inv_jenis_operasi_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jenis_operasi
    ADD CONSTRAINT uq_inv_jenis_operasi_entity_id UNIQUE (entity_id);

--
-- Name: inv_jenis_operasi uq_inv_jenis_operasi_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jenis_operasi
    ADD CONSTRAINT uq_inv_jenis_operasi_kode UNIQUE (kode);

--
-- Name: inv_kategori_produk uq_inv_kategori_produk_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kategori_produk
    ADD CONSTRAINT uq_inv_kategori_produk_entity_id UNIQUE (entity_id);

--
-- Name: inv_kemasan uq_inv_kemasan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kemasan
    ADD CONSTRAINT uq_inv_kemasan_entity_id UNIQUE (entity_id);

--
-- Name: inv_kemasan uq_inv_kemasan_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kemasan
    ADD CONSTRAINT uq_inv_kemasan_kode UNIQUE (kode);

--
-- Name: inv_lapisan_biaya uq_inv_lapisan_biaya_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lapisan_biaya
    ADD CONSTRAINT uq_inv_lapisan_biaya_entity_id UNIQUE (entity_id);

--
-- Name: inv_lokasi_stok uq_inv_lokasi_stok_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lokasi_stok
    ADD CONSTRAINT uq_inv_lokasi_stok_entity_id UNIQUE (entity_id);

--
-- Name: inv_lokasi_stok uq_inv_lokasi_stok_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lokasi_stok
    ADD CONSTRAINT uq_inv_lokasi_stok_kode UNIQUE (kode);

--
-- Name: inv_lot_serial uq_inv_lot_serial_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lot_serial
    ADD CONSTRAINT uq_inv_lot_serial_entity_id UNIQUE (entity_id);

--
-- Name: inv_lot_serial uq_inv_lot_serial_produk_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lot_serial
    ADD CONSTRAINT uq_inv_lot_serial_produk_kode UNIQUE (id_inv_produk, kode);

--
-- Name: inv_mutasi_dokumen uq_inv_mutasi_dokumen_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT uq_inv_mutasi_dokumen_entity_id UNIQUE (entity_id);

--
-- Name: inv_mutasi_dokumen uq_inv_mutasi_dokumen_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT uq_inv_mutasi_dokumen_kode UNIQUE (kode);

--
-- Name: inv_mutasi_items uq_inv_mutasi_items_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT uq_inv_mutasi_items_entity_id UNIQUE (entity_id);

--
-- Name: inv_nilai_atribut uq_inv_nilai_atribut_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_nilai_atribut
    ADD CONSTRAINT uq_inv_nilai_atribut_entity_id UNIQUE (entity_id);

--
-- Name: inv_penyesuaian_stok_items uq_inv_penyesuaian_items_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT uq_inv_penyesuaian_items_entity_id UNIQUE (entity_id);

--
-- Name: inv_penyesuaian_stok uq_inv_penyesuaian_stok_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT uq_inv_penyesuaian_stok_entity_id UNIQUE (entity_id);

--
-- Name: inv_penyesuaian_stok uq_inv_penyesuaian_stok_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT uq_inv_penyesuaian_stok_kode UNIQUE (kode);

--
-- Name: inv_produk uq_inv_produk_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT uq_inv_produk_entity_id UNIQUE (entity_id);

--
-- Name: inv_produk uq_inv_produk_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT uq_inv_produk_kode UNIQUE (kode_produk);

--
-- Name: inv_produk_varian_konfig uq_inv_produk_varian_konfig_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_varian_konfig
    ADD CONSTRAINT uq_inv_produk_varian_konfig_entity_id UNIQUE (entity_id);

--
-- Name: inv_saldo_stok uq_inv_saldo_stok_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_saldo_stok
    ADD CONSTRAINT uq_inv_saldo_stok_entity_id UNIQUE (entity_id);

--
-- Name: inv_unit_konversi uq_inv_unit_konversi_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_konversi
    ADD CONSTRAINT uq_inv_unit_konversi_entity_id UNIQUE (entity_id);

--
-- Name: inv_unit_ukur uq_inv_unit_ukur_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_ukur
    ADD CONSTRAINT uq_inv_unit_ukur_entity_id UNIQUE (entity_id);

--
-- Name: inv_unit_ukur uq_inv_unit_ukur_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_ukur
    ADD CONSTRAINT uq_inv_unit_ukur_kode UNIQUE (kode);

--
-- Name: pur_pemasok uq_pur_pemasok_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT uq_pur_pemasok_entity_id UNIQUE (entity_id);

--
-- Name: pur_pemasok uq_pur_pemasok_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT uq_pur_pemasok_kode UNIQUE (kode);

--
-- Name: pur_penerimaan uq_pur_penerimaan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT uq_pur_penerimaan_entity_id UNIQUE (entity_id);

--
-- Name: pur_penerimaan_item uq_pur_penerimaan_item_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan_item
    ADD CONSTRAINT uq_pur_penerimaan_item_entity_id UNIQUE (entity_id);

--
-- Name: pur_penerimaan uq_pur_penerimaan_nomor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT uq_pur_penerimaan_nomor UNIQUE (nomor);

--
-- Name: pur_pesanan uq_pur_pesanan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT uq_pur_pesanan_entity_id UNIQUE (entity_id);

--
-- Name: pur_pesanan_item uq_pur_pesanan_item_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan_item
    ADD CONSTRAINT uq_pur_pesanan_item_entity_id UNIQUE (entity_id);

--
-- Name: pur_pesanan uq_pur_pesanan_nomor; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT uq_pur_pesanan_nomor UNIQUE (nomor);

--
-- Name: ix_inv_gerakan_header_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_header_status ON public.inv_gerakan_header USING btree (status, tanggal_jadwal);

--
-- Name: ix_inv_gerakan_header_sumber; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_header_sumber ON public.inv_gerakan_header USING btree (id_lokasi_sumber);

--
-- Name: ix_inv_gerakan_header_tujuan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_header_tujuan ON public.inv_gerakan_header USING btree (id_lokasi_tujuan);

--
-- Name: ix_inv_gerakan_stok_header; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_stok_header ON public.inv_gerakan_stok USING btree (id_inv_gerakan_header);

--
-- Name: ix_inv_gerakan_stok_produk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_stok_produk ON public.inv_gerakan_stok USING btree (id_inv_produk);

--
-- Name: ix_inv_gerakan_stok_unit_ukur; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gerakan_stok_unit_ukur ON public.inv_gerakan_stok USING btree (id_inv_unit_ukur);

--
-- Name: ix_inv_gudang_kelurahan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_gudang_kelurahan ON public.inv_gudang USING btree (id_core_kelurahan);

--
-- Name: ix_inv_jadwal_hitung_aktif; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_jadwal_hitung_aktif ON public.inv_jadwal_hitung USING btree (aktif, frekuensi) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_jenis_operasi_gerakan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_jenis_operasi_gerakan ON public.inv_jenis_operasi USING btree (jenis_gerakan) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_kategori_produk_induk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_kategori_produk_induk ON public.inv_kategori_produk USING btree (id_kategori_induk);

--
-- Name: ix_inv_kemasan_produk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_kemasan_produk ON public.inv_kemasan USING btree (id_inv_produk) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_lapisan_biaya_dokumen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lapisan_biaya_dokumen ON public.inv_lapisan_biaya USING btree (nomor_dokumen_masuk);

--
-- Name: ix_inv_lapisan_biaya_fefo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lapisan_biaya_fefo ON public.inv_lapisan_biaya USING btree (id_inv_produk, tanggal_masuk, id) WHERE ((deleted_at IS NULL) AND (qty_terpakai < qty_masuk));

--
-- Name: ix_inv_lokasi_stok_gudang; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lokasi_stok_gudang ON public.inv_lokasi_stok USING btree (id_inv_gudang);

--
-- Name: ix_inv_lokasi_stok_induk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lokasi_stok_induk ON public.inv_lokasi_stok USING btree (id_lokasi_induk);

--
-- Name: ix_inv_lot_serial_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lot_serial_barcode ON public.inv_lot_serial USING btree (barcode) WHERE ((deleted_at IS NULL) AND (barcode IS NOT NULL));

--
-- Name: ix_inv_lot_serial_fefo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_lot_serial_fefo ON public.inv_lot_serial USING btree (id_inv_produk, tanggal_kedaluwarsa);

--
-- Name: ix_inv_mutasi_dokumen_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_dokumen_status ON public.inv_mutasi_dokumen USING btree (status, tanggal_dokumen);

--
-- Name: ix_inv_mutasi_dokumen_sumber; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_dokumen_sumber ON public.inv_mutasi_dokumen USING btree (id_lokasi_sumber);

--
-- Name: ix_inv_mutasi_dokumen_tujuan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_dokumen_tujuan ON public.inv_mutasi_dokumen USING btree (id_lokasi_tujuan);

--
-- Name: ix_inv_mutasi_items_gr_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_items_gr_item ON public.inv_mutasi_items USING btree (id_pur_penerimaan_item) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_mutasi_items_header; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_items_header ON public.inv_mutasi_items USING btree (id_inv_mutasi_dokumen);

--
-- Name: ix_inv_mutasi_items_produk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_mutasi_items_produk ON public.inv_mutasi_items USING btree (id_inv_produk);

--
-- Name: ix_inv_nilai_atribut_atribut; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_nilai_atribut_atribut ON public.inv_nilai_atribut USING btree (id_inv_atribut, urutan);

--
-- Name: ix_inv_penyesuaian_items_header; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_penyesuaian_items_header ON public.inv_penyesuaian_stok_items USING btree (id_inv_penyesuaian_stok);

--
-- Name: ix_inv_penyesuaian_items_kemasan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_penyesuaian_items_kemasan ON public.inv_penyesuaian_stok_items USING btree (id_inv_kemasan);

--
-- Name: ix_inv_penyesuaian_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_penyesuaian_status ON public.inv_penyesuaian_stok USING btree (status, tanggal_dokumen);

--
-- Name: ix_inv_produk_atribut_nilai; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_atribut_nilai ON public.inv_produk_atribut USING btree (id_inv_nilai_atribut);

--
-- Name: ix_inv_produk_induk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_induk ON public.inv_produk USING btree (id_inv_produk_induk);

--
-- Name: ix_inv_produk_induk_varian; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_induk_varian ON public.inv_produk USING btree (adalah_induk_varian) WHERE ((deleted_at IS NULL) AND adalah_induk_varian);

--
-- Name: ix_inv_produk_kategori; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_kategori ON public.inv_produk USING btree (id_inv_kategori_produk);

--
-- Name: ix_inv_produk_reorder; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_reorder ON public.inv_produk USING btree (reorder_aktif) WHERE ((deleted_at IS NULL) AND (reorder_aktif IS TRUE));

--
-- Name: ix_inv_produk_varian_konfig_atribut; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_produk_varian_konfig_atribut ON public.inv_produk_varian_konfig USING btree (id_inv_atribut) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_saldo_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_saldo_lot ON public.inv_saldo_stok USING btree (id_inv_lot_serial);

--
-- Name: ix_inv_saldo_produk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_saldo_produk ON public.inv_saldo_stok USING btree (id_inv_produk);

--
-- Name: ix_inv_unit_konversi_dari; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_unit_konversi_dari ON public.inv_unit_konversi USING btree (id_unit_dari) WHERE (deleted_at IS NULL);

--
-- Name: ix_inv_unit_konversi_ke; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_inv_unit_konversi_ke ON public.inv_unit_konversi USING btree (id_unit_ke) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pemasok_kelurahan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pemasok_kelurahan ON public.pur_pemasok USING btree (id_core_kelurahan);

--
-- Name: ix_pur_pemasok_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pemasok_status ON public.pur_pemasok USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_penerimaan_item_penerimaan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_penerimaan_item_penerimaan ON public.pur_penerimaan_item USING btree (id_pur_penerimaan) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_penerimaan_item_pesanan_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_penerimaan_item_pesanan_item ON public.pur_penerimaan_item USING btree (id_pur_pesanan_item) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_penerimaan_pesanan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_penerimaan_pesanan ON public.pur_penerimaan USING btree (id_pur_pesanan) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_penerimaan_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_penerimaan_status ON public.pur_penerimaan USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_gudang; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_gudang ON public.pur_pesanan USING btree (id_inv_gudang) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_item_kesepakatan_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_item_kesepakatan_item ON public.pur_pesanan_item USING btree (id_pur_kesepakatan_item) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_item_permintaan_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_item_permintaan_item ON public.pur_pesanan_item USING btree (id_pur_permintaan_item) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_item_pesanan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_item_pesanan ON public.pur_pesanan_item USING btree (id_pur_pesanan) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_item_produk; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_item_produk ON public.pur_pesanan_item USING btree (id_inv_produk) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_kesepakatan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_kesepakatan ON public.pur_pesanan USING btree (id_pur_kesepakatan) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_pemasok; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_pemasok ON public.pur_pesanan USING btree (id_pur_pemasok) WHERE (deleted_at IS NULL);

--
-- Name: ix_pur_pesanan_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pur_pesanan_status ON public.pur_pesanan USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: uq_inv_gerakan_idempoten; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_gerakan_idempoten ON public.inv_gerakan_stok USING btree (id_inv_gerakan_header, id_inv_produk, entity_id_sumber) WHERE (deleted_at IS NULL);

--
-- Name: uq_inv_kategori_produk_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_kategori_produk_nama ON public.inv_kategori_produk USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: uq_inv_kemasan_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_kemasan_barcode ON public.inv_kemasan USING btree (barcode) WHERE ((deleted_at IS NULL) AND (barcode IS NOT NULL));

--
-- Name: uq_inv_lot_serial_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_lot_serial_barcode ON public.inv_lot_serial USING btree (barcode) WHERE ((deleted_at IS NULL) AND (barcode IS NOT NULL));

--
-- Name: uq_inv_mutasi_gr_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_mutasi_gr_ref ON public.inv_mutasi_dokumen USING btree (id_pur_penerimaan) WHERE ((deleted_at IS NULL) AND (id_pur_penerimaan IS NOT NULL));

--
-- Name: uq_inv_nilai_atribut_atribut_nilai; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_nilai_atribut_atribut_nilai ON public.inv_nilai_atribut USING btree (id_inv_atribut, nilai) WHERE (deleted_at IS NULL);

--
-- Name: uq_inv_produk_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_produk_barcode ON public.inv_produk USING btree (barcode) WHERE ((deleted_at IS NULL) AND (barcode IS NOT NULL));

--
-- Name: uq_inv_produk_kombinasi; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_produk_kombinasi ON public.inv_produk USING btree (id_inv_produk_induk, kunci_kombinasi) WHERE ((id_inv_produk_induk IS NOT NULL) AND (deleted_at IS NULL));

--
-- Name: uq_inv_produk_varian_konfig_pasangan; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_produk_varian_konfig_pasangan ON public.inv_produk_varian_konfig USING btree (id_inv_produk, id_inv_atribut) WHERE (deleted_at IS NULL);

--
-- Name: uq_inv_saldo_dengan_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_saldo_dengan_lot ON public.inv_saldo_stok USING btree (id_inv_lokasi_stok, id_inv_produk, id_inv_lot_serial) WHERE ((id_inv_lot_serial IS NOT NULL) AND (deleted_at IS NULL));

--
-- Name: uq_inv_saldo_tanpa_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_saldo_tanpa_lot ON public.inv_saldo_stok USING btree (id_inv_lokasi_stok, id_inv_produk) WHERE ((id_inv_lot_serial IS NULL) AND (deleted_at IS NULL));

--
-- Name: uq_inv_unit_konversi_pasangan; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_inv_unit_konversi_pasangan ON public.inv_unit_konversi USING btree (id_unit_dari, id_unit_ke) WHERE (deleted_at IS NULL);

--
-- Name: inv_atribut trg_inv_atribut_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_atribut_updated_at BEFORE UPDATE ON public.inv_atribut FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_gerakan_stok trg_inv_gerakan_stok_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_gerakan_stok_updated_at BEFORE UPDATE ON public.inv_gerakan_stok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_gudang trg_inv_gudang_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_gudang_updated_at BEFORE UPDATE ON public.inv_gudang FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_jadwal_hitung trg_inv_jadwal_hitung_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_jadwal_hitung_updated_at BEFORE UPDATE ON public.inv_jadwal_hitung FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_jenis_operasi trg_inv_jenis_operasi_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_jenis_operasi_updated_at BEFORE UPDATE ON public.inv_jenis_operasi FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_kategori_produk trg_inv_kategori_produk_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_kategori_produk_updated_at BEFORE UPDATE ON public.inv_kategori_produk FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_kemasan trg_inv_kemasan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_kemasan_updated_at BEFORE UPDATE ON public.inv_kemasan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_lapisan_biaya trg_inv_lapisan_biaya_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_lapisan_biaya_updated_at BEFORE UPDATE ON public.inv_lapisan_biaya FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_lokasi_stok trg_inv_lokasi_stok_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_lokasi_stok_updated_at BEFORE UPDATE ON public.inv_lokasi_stok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_lot_serial trg_inv_lot_serial_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_lot_serial_updated_at BEFORE UPDATE ON public.inv_lot_serial FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_nilai_atribut trg_inv_nilai_atribut_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_nilai_atribut_updated_at BEFORE UPDATE ON public.inv_nilai_atribut FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_penyesuaian_stok_items trg_inv_penyesuaian_stok_items_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_penyesuaian_stok_items_updated_at BEFORE UPDATE ON public.inv_penyesuaian_stok_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_penyesuaian_stok trg_inv_penyesuaian_stok_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_penyesuaian_stok_updated_at BEFORE UPDATE ON public.inv_penyesuaian_stok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_produk_atribut trg_inv_produk_atribut_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_produk_atribut_updated_at BEFORE UPDATE ON public.inv_produk_atribut FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_produk trg_inv_produk_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_produk_updated_at BEFORE UPDATE ON public.inv_produk FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_saldo_stok trg_inv_saldo_stok_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_saldo_stok_updated_at BEFORE UPDATE ON public.inv_saldo_stok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_unit_ukur trg_inv_unit_ukur_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_inv_unit_ukur_updated_at BEFORE UPDATE ON public.inv_unit_ukur FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: pur_pemasok trg_pur_pemasok_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pur_pemasok_updated_at BEFORE UPDATE ON public.pur_pemasok FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: pur_penerimaan_item trg_pur_penerimaan_item_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pur_penerimaan_item_updated_at BEFORE UPDATE ON public.pur_penerimaan_item FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: pur_penerimaan trg_pur_penerimaan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pur_penerimaan_updated_at BEFORE UPDATE ON public.pur_penerimaan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: pur_pesanan_item trg_pur_pesanan_item_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pur_pesanan_item_updated_at BEFORE UPDATE ON public.pur_pesanan_item FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: pur_pesanan trg_pur_pesanan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pur_pesanan_updated_at BEFORE UPDATE ON public.pur_pesanan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: inv_gerakan_stok fk_inv_gerakan_header; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_header FOREIGN KEY (id_inv_gerakan_header) REFERENCES public.inv_gerakan_header(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_header fk_inv_gerakan_header_pelaksana; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT fk_inv_gerakan_header_pelaksana FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_gerakan_header fk_inv_gerakan_header_penyetuju; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT fk_inv_gerakan_header_penyetuju FOREIGN KEY (id_core_users_penyetuju) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_gerakan_header fk_inv_gerakan_header_penyusun; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT fk_inv_gerakan_header_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_gerakan_header fk_inv_gerakan_header_sumber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT fk_inv_gerakan_header_sumber FOREIGN KEY (id_lokasi_sumber) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_header fk_inv_gerakan_header_tujuan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_header
    ADD CONSTRAINT fk_inv_gerakan_header_tujuan FOREIGN KEY (id_lokasi_tujuan) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_stok fk_inv_gerakan_lot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_lot FOREIGN KEY (id_inv_lot_serial) REFERENCES public.inv_lot_serial(id) ON DELETE SET NULL;

--
-- Name: inv_gerakan_stok fk_inv_gerakan_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_stok fk_inv_gerakan_sumber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_sumber FOREIGN KEY (id_lokasi_sumber) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_stok fk_inv_gerakan_tujuan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_tujuan FOREIGN KEY (id_lokasi_tujuan) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_gerakan_stok fk_inv_gerakan_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gerakan_stok
    ADD CONSTRAINT fk_inv_gerakan_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_gudang fk_inv_gudang_kelurahan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_gudang
    ADD CONSTRAINT fk_inv_gudang_kelurahan FOREIGN KEY (id_core_kelurahan) REFERENCES public.core_kelurahan(id) ON DELETE RESTRICT;

--
-- Name: inv_jadwal_hitung fk_inv_jadwal_hitung_gudang; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jadwal_hitung
    ADD CONSTRAINT fk_inv_jadwal_hitung_gudang FOREIGN KEY (id_inv_gudang) REFERENCES public.inv_gudang(id) ON DELETE RESTRICT;

--
-- Name: inv_jadwal_hitung fk_inv_jadwal_hitung_lokasi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jadwal_hitung
    ADD CONSTRAINT fk_inv_jadwal_hitung_lokasi FOREIGN KEY (id_inv_lokasi_stok) REFERENCES public.inv_lokasi_stok(id) ON DELETE SET NULL;

--
-- Name: inv_jenis_operasi fk_inv_jenis_operasi_sumber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jenis_operasi
    ADD CONSTRAINT fk_inv_jenis_operasi_sumber FOREIGN KEY (id_lokasi_sumber_default) REFERENCES public.inv_lokasi_stok(id) ON DELETE SET NULL;

--
-- Name: inv_jenis_operasi fk_inv_jenis_operasi_tujuan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_jenis_operasi
    ADD CONSTRAINT fk_inv_jenis_operasi_tujuan FOREIGN KEY (id_lokasi_tujuan_default) REFERENCES public.inv_lokasi_stok(id) ON DELETE SET NULL;

--
-- Name: inv_kategori_produk fk_inv_kategori_produk_induk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kategori_produk
    ADD CONSTRAINT fk_inv_kategori_produk_induk FOREIGN KEY (id_kategori_induk) REFERENCES public.inv_kategori_produk(id) ON DELETE SET NULL;

--
-- Name: inv_kemasan fk_inv_kemasan_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kemasan
    ADD CONSTRAINT fk_inv_kemasan_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_kemasan fk_inv_kemasan_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_kemasan
    ADD CONSTRAINT fk_inv_kemasan_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_lapisan_biaya fk_inv_lapisan_biaya_lot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lapisan_biaya
    ADD CONSTRAINT fk_inv_lapisan_biaya_lot FOREIGN KEY (id_inv_lot_serial) REFERENCES public.inv_lot_serial(id) ON DELETE SET NULL;

--
-- Name: inv_lapisan_biaya fk_inv_lapisan_biaya_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lapisan_biaya
    ADD CONSTRAINT fk_inv_lapisan_biaya_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_lokasi_stok fk_inv_lokasi_stok_gudang; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lokasi_stok
    ADD CONSTRAINT fk_inv_lokasi_stok_gudang FOREIGN KEY (id_inv_gudang) REFERENCES public.inv_gudang(id) ON DELETE RESTRICT;

--
-- Name: inv_lokasi_stok fk_inv_lokasi_stok_induk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lokasi_stok
    ADD CONSTRAINT fk_inv_lokasi_stok_induk FOREIGN KEY (id_lokasi_induk) REFERENCES public.inv_lokasi_stok(id) ON DELETE SET NULL;

--
-- Name: inv_lot_serial fk_inv_lot_serial_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_lot_serial
    ADD CONSTRAINT fk_inv_lot_serial_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_mutasi_items fk_inv_mutasi_items_header; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT fk_inv_mutasi_items_header FOREIGN KEY (id_inv_mutasi_dokumen) REFERENCES public.inv_mutasi_dokumen(id) ON DELETE CASCADE;

--
-- Name: inv_mutasi_items fk_inv_mutasi_items_lot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT fk_inv_mutasi_items_lot FOREIGN KEY (id_inv_lot_serial) REFERENCES public.inv_lot_serial(id) ON DELETE SET NULL;

--
-- Name: inv_mutasi_items fk_inv_mutasi_items_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT fk_inv_mutasi_items_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_mutasi_items fk_inv_mutasi_items_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_items
    ADD CONSTRAINT fk_inv_mutasi_items_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_mutasi_dokumen fk_inv_mutasi_penyetuju; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT fk_inv_mutasi_penyetuju FOREIGN KEY (id_core_users_penyetuju) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_mutasi_dokumen fk_inv_mutasi_penyusun; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT fk_inv_mutasi_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_mutasi_dokumen fk_inv_mutasi_sumber; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT fk_inv_mutasi_sumber FOREIGN KEY (id_lokasi_sumber) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_mutasi_dokumen fk_inv_mutasi_tujuan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_mutasi_dokumen
    ADD CONSTRAINT fk_inv_mutasi_tujuan FOREIGN KEY (id_lokasi_tujuan) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_nilai_atribut fk_inv_nilai_atribut_atribut; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_nilai_atribut
    ADD CONSTRAINT fk_inv_nilai_atribut_atribut FOREIGN KEY (id_inv_atribut) REFERENCES public.inv_atribut(id) ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok fk_inv_penyesuaian_gudang; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT fk_inv_penyesuaian_gudang FOREIGN KEY (id_inv_gudang) REFERENCES public.inv_gudang(id) ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_header; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_header FOREIGN KEY (id_inv_penyesuaian_stok) REFERENCES public.inv_penyesuaian_stok(id) ON DELETE CASCADE;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_kemasan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_kemasan FOREIGN KEY (id_inv_kemasan) REFERENCES public.inv_kemasan(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_lokasi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_lokasi FOREIGN KEY (id_inv_lokasi_stok) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_lot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_lot FOREIGN KEY (id_inv_lot_serial) REFERENCES public.inv_lot_serial(id) ON DELETE SET NULL;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok_items fk_inv_penyesuaian_items_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok_items
    ADD CONSTRAINT fk_inv_penyesuaian_items_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_penyesuaian_stok fk_inv_penyesuaian_penyetuju; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT fk_inv_penyesuaian_penyetuju FOREIGN KEY (id_core_users_penyetuju) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_penyesuaian_stok fk_inv_penyesuaian_penyusun; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_penyesuaian_stok
    ADD CONSTRAINT fk_inv_penyesuaian_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_produk_atribut fk_inv_produk_atribut_nilai; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_atribut
    ADD CONSTRAINT fk_inv_produk_atribut_nilai FOREIGN KEY (id_inv_nilai_atribut) REFERENCES public.inv_nilai_atribut(id) ON DELETE RESTRICT;

--
-- Name: inv_produk_atribut fk_inv_produk_atribut_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_atribut
    ADD CONSTRAINT fk_inv_produk_atribut_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE CASCADE;

--
-- Name: inv_produk fk_inv_produk_induk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT fk_inv_produk_induk FOREIGN KEY (id_inv_produk_induk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_produk fk_inv_produk_kategori; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT fk_inv_produk_kategori FOREIGN KEY (id_inv_kategori_produk) REFERENCES public.inv_kategori_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_produk fk_inv_produk_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk
    ADD CONSTRAINT fk_inv_produk_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_saldo_stok fk_inv_saldo_lokasi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_saldo_stok
    ADD CONSTRAINT fk_inv_saldo_lokasi FOREIGN KEY (id_inv_lokasi_stok) REFERENCES public.inv_lokasi_stok(id) ON DELETE RESTRICT;

--
-- Name: inv_saldo_stok fk_inv_saldo_lot; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_saldo_stok
    ADD CONSTRAINT fk_inv_saldo_lot FOREIGN KEY (id_inv_lot_serial) REFERENCES public.inv_lot_serial(id) ON DELETE RESTRICT;

--
-- Name: inv_saldo_stok fk_inv_saldo_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_saldo_stok
    ADD CONSTRAINT fk_inv_saldo_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: inv_unit_konversi fk_inv_unit_konversi_dari; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_konversi
    ADD CONSTRAINT fk_inv_unit_konversi_dari FOREIGN KEY (id_unit_dari) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: inv_unit_konversi fk_inv_unit_konversi_ke; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_unit_konversi
    ADD CONSTRAINT fk_inv_unit_konversi_ke FOREIGN KEY (id_unit_ke) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: pur_pemasok fk_pur_pemasok_kelurahan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pemasok
    ADD CONSTRAINT fk_pur_pemasok_kelurahan FOREIGN KEY (id_core_kelurahan) REFERENCES public.core_kelurahan(id) ON DELETE RESTRICT;

--
-- Name: pur_penerimaan fk_pur_penerimaan_gudang; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT fk_pur_penerimaan_gudang FOREIGN KEY (id_inv_gudang) REFERENCES public.inv_gudang(id) ON DELETE RESTRICT;

--
-- Name: pur_penerimaan_item fk_pur_penerimaan_item_penerimaan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan_item
    ADD CONSTRAINT fk_pur_penerimaan_item_penerimaan FOREIGN KEY (id_pur_penerimaan) REFERENCES public.pur_penerimaan(id) ON DELETE CASCADE;

--
-- Name: pur_penerimaan_item fk_pur_penerimaan_item_pesanan_item; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan_item
    ADD CONSTRAINT fk_pur_penerimaan_item_pesanan_item FOREIGN KEY (id_pur_pesanan_item) REFERENCES public.pur_pesanan_item(id) ON DELETE RESTRICT;

--
-- Name: pur_penerimaan_item fk_pur_penerimaan_item_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan_item
    ADD CONSTRAINT fk_pur_penerimaan_item_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: pur_penerimaan fk_pur_penerimaan_penerima; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT fk_pur_penerimaan_penerima FOREIGN KEY (id_core_users_penerima) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: pur_penerimaan fk_pur_penerimaan_pesanan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_penerimaan
    ADD CONSTRAINT fk_pur_penerimaan_pesanan FOREIGN KEY (id_pur_pesanan) REFERENCES public.pur_pesanan(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan fk_pur_pesanan_eta_konfirmasi_oleh; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT fk_pur_pesanan_eta_konfirmasi_oleh FOREIGN KEY (eta_konfirmasi_oleh) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: pur_pesanan fk_pur_pesanan_gudang; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT fk_pur_pesanan_gudang FOREIGN KEY (id_inv_gudang) REFERENCES public.inv_gudang(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan_item fk_pur_pesanan_item_pesanan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan_item
    ADD CONSTRAINT fk_pur_pesanan_item_pesanan FOREIGN KEY (id_pur_pesanan) REFERENCES public.pur_pesanan(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan_item fk_pur_pesanan_item_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan_item
    ADD CONSTRAINT fk_pur_pesanan_item_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan_item fk_pur_pesanan_item_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan_item
    ADD CONSTRAINT fk_pur_pesanan_item_unit FOREIGN KEY (id_inv_unit_ukur) REFERENCES public.inv_unit_ukur(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan fk_pur_pesanan_pemasok; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT fk_pur_pesanan_pemasok FOREIGN KEY (id_pur_pemasok) REFERENCES public.pur_pemasok(id) ON DELETE RESTRICT;

--
-- Name: pur_pesanan fk_pur_pesanan_penyusun; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pur_pesanan
    ADD CONSTRAINT fk_pur_pesanan_penyusun FOREIGN KEY (id_core_users_penyusun) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: inv_produk_varian_konfig fk_pvk_atribut; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_varian_konfig
    ADD CONSTRAINT fk_pvk_atribut FOREIGN KEY (id_inv_atribut) REFERENCES public.inv_atribut(id) ON DELETE RESTRICT;

--
-- Name: inv_produk_varian_konfig fk_pvk_produk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inv_produk_varian_konfig
    ADD CONSTRAINT fk_pvk_produk FOREIGN KEY (id_inv_produk) REFERENCES public.inv_produk(id) ON DELETE RESTRICT;
