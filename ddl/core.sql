-- ddl/core.sql
-- Sumber: DB live nexierp-postgres (pg_dump schema-only, 2026-11-27), hanya modul core.
-- Cross-read oleh core — bukan bagian modul lain: hr_karyawan (dipakai auth/me).
-- Enum, fungsi set_updated_at + trigger, index/constraint, dan FK antar tabel
-- di file ini ikut disertakan. FK ke tabel di luar scope (mis. core_metode_bayar
-- -> acc_akun, hr_karyawan -> hr_departemen/hr_jabatan) sengaja dibuang.
-- Regenerate ulang dari DB live setelah perubahan skema lewat repo NestJS
-- (lihat docs/ARSITEKTUR-BACKEND-GO.md).

--
-- Name: core_audit_severity; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_audit_severity AS ENUM (
    'info',
    'warning',
    'critical'
);

--
-- Name: core_config_value_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_config_value_type AS ENUM (
    'string',
    'number',
    'boolean',
    'json'
);

--
-- Name: core_env_category; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_env_category AS ENUM (
    'company',
    'smtp',
    'app',
    'storage'
);

--
-- Name: core_http_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_http_method AS ENUM (
    'get',
    'post',
    'patch',
    'put',
    'delete'
);

--
-- Name: core_login_fail_reason; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_login_fail_reason AS ENUM (
    'unknown_user',
    'wrong_password',
    'locked',
    'inactive',
    'mfa_failed'
);

--
-- Name: core_mfa_method; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_mfa_method AS ENUM (
    'totp'
);

--
-- Name: core_module_key; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_module_key AS ENUM (
    'inventory',
    'accounting',
    'sales',
    'finance',
    'hr',
    'crm',
    'whatsapp-crm',
    'book',
    'pos',
    'purchasing',
    'asset',
    'ess',
    'fnb',
    'system',
    'payment-gateway',
    'regpas',
    'farmasi',
    'lab',
    'kasir',
    'rme',
    'penjamin',
    'jasmed',
    'kepatuhan',
    'dokter-portal',
    'ecom',
    'shipment',
    'ppdb',
    'akd',
    'tgs',
    'psn',
    'tendik',
    'wf',
    'ai-llm'
);

--
-- Name: core_outbox_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_outbox_status AS ENUM (
    'pending',
    'delivered',
    'failed'
);

--
-- Name: core_permission_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_permission_status AS ENUM (
    'active',
    'disabled'
);

--
-- Name: core_scope_operator; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.core_scope_operator AS ENUM (
    'in'
);

--
-- Name: enum_jenis_metode_bayar_core; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_metode_bayar_core AS ENUM (
    'TUNAI',
    'KARTU',
    'QRIS',
    'TRANSFER',
    'LAINNYA',
    'POIN'
);

--
-- Name: enum_jenis_pekerja_hr; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_pekerja_hr AS ENUM (
    'PEKERJA_TETAP',
    'PKWT',
    'PARUH_WAKTU',
    'MAGANG',
    'KONTRAKTOR'
);

--
-- Name: enum_jenis_token_core; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_jenis_token_core AS ENUM (
    'AKTIVASI'
);

--
-- Name: enum_paket_tier; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_paket_tier AS ENUM (
    'PS1',
    'PS2',
    'PS3'
);

--
-- Name: enum_ptkp_hr; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_ptkp_hr AS ENUM (
    'TK0',
    'TK1',
    'TK2',
    'TK3',
    'K0',
    'K1',
    'K2',
    'K3'
);

--
-- Name: enum_status_aktif; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_aktif AS ENUM (
    'AKTIF',
    'NONAKTIF'
);

--
-- Name: enum_status_karyawan_hr; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_karyawan_hr AS ENUM (
    'AKTIF',
    'NONAKTIF'
);

--
-- Name: enum_status_mail; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_mail AS ENUM (
    'TERKIRIM',
    'GAGAL',
    'NONAKTIF'
);

--
-- Name: enum_status_tenant; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.enum_status_tenant AS ENUM (
    'PROVISI',
    'AKTIF',
    'DITANGGUHKAN',
    'DITUTUP'
);

--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: core_agama; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_agama (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    urutan integer DEFAULT 0 NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_core_agama_code CHECK ((length(btrim((code)::text)) > 0)),
    CONSTRAINT ck_core_agama_nama CHECK ((length(btrim((nama)::text)) > 0))
);
ALTER TABLE ONLY public.core_agama ALTER COLUMN id SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN entity_id SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN code SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN nama SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN urutan SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN status SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN version SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN created_at SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN updated_at SET (pg_attver=204332128);
ALTER TABLE ONLY public.core_agama ALTER COLUMN deleted_at SET (pg_attver=204332128);

--
-- Name: core_app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_app_settings (
    id public.core_env_category NOT NULL,
    fields jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_app_settings ALTER COLUMN id SET (pg_attver=32583752);
ALTER TABLE ONLY public.core_app_settings ALTER COLUMN fields SET (pg_attver=32583752);
ALTER TABLE ONLY public.core_app_settings ALTER COLUMN created_at SET (pg_attver=32583752);
ALTER TABLE ONLY public.core_app_settings ALTER COLUMN updated_at SET (pg_attver=32583752);

--
-- Name: TABLE core_app_settings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_app_settings IS '[PLATFORM] Konfigurasi environment per kategori';

--
-- Name: core_approval_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_approval_limits (
    id bigint NOT NULL,
    id_core_roles bigint,
    id_core_users bigint,
    id_core_modules bigint NOT NULL,
    doc_type character varying(30) NOT NULL,
    min_amount numeric(18,2) DEFAULT 0 NOT NULL,
    max_amount numeric(18,2),
    currency character(3) DEFAULT 'IDR'::bpchar NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT core_approval_limits_amount_check CHECK (((min_amount >= (0)::numeric) AND ((max_amount IS NULL) OR (max_amount >= min_amount)))),
    CONSTRAINT core_approval_limits_subject_required CHECK (((id_core_roles IS NOT NULL) OR (id_core_users IS NOT NULL)))
);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN id SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN id_core_roles SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN id_core_users SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN id_core_modules SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN doc_type SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN min_amount SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN max_amount SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN currency SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN active SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN created_at SET (pg_attver=32602192);
ALTER TABLE ONLY public.core_approval_limits ALTER COLUMN updated_at SET (pg_attver=32602192);

--
-- Name: TABLE core_approval_limits; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_approval_limits IS '[ACCESS] Batas nominal approval per subjek (role/user) × modul × jenis dokumen — mesin approval generik core/approval';

--
-- Name: core_audit_trail; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_audit_trail (
    id bigint NOT NULL,
    at timestamp with time zone NOT NULL,
    id_core_users bigint,
    actor_name character varying(42) NOT NULL,
    id_core_modules bigint,
    entity_type character varying(57) NOT NULL,
    action character varying(105) NOT NULL,
    before_value jsonb,
    after_value jsonb,
    severity public.core_audit_severity NOT NULL,
    ip_address character varying(88) NOT NULL,
    user_agent character varying(402) NOT NULL,
    request_id character varying(48) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    entity_id character varying(255) NOT NULL
);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN id SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN at SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN id_core_users SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN actor_name SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN id_core_modules SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN entity_type SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN action SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN before_value SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN after_value SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN severity SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN ip_address SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN user_agent SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN request_id SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN created_at SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN updated_at SET (pg_attver=32623448);
ALTER TABLE ONLY public.core_audit_trail ALTER COLUMN entity_id SET (pg_attver=32623448);

--
-- Name: TABLE core_audit_trail; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_audit_trail IS '[AUDIT] Audit trail pusat append-only';

--
-- Name: core_auth_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_auth_tokens (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_core_users bigint NOT NULL,
    jenis public.enum_jenis_token_core DEFAULT 'AKTIVASI'::public.enum_jenis_token_core NOT NULL,
    token_hash character varying(150) NOT NULL,
    berlaku_hingga timestamp with time zone NOT NULL,
    dipakai_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN id SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN entity_id SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN id_core_users SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN jenis SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN token_hash SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN berlaku_hingga SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN dipakai_at SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN created_at SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN updated_at SET (pg_attver=740983928);
ALTER TABLE ONLY public.core_auth_tokens ALTER COLUMN deleted_at SET (pg_attver=740983928);

--
-- Name: TABLE core_auth_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_auth_tokens IS '[SESSION] token one-time akun CORE (aktivasi registrasi member portal) — expiry + job bersih-bersih';

--
-- Name: COLUMN core_auth_tokens.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_auth_tokens.token_hash IS 'SHA-256 hex token mentah — token asli hanya hidup di email, tidak pernah disimpan';

--
-- Name: core_cluster; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_cluster (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    code character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    deskripsi character varying(200),
    icon character varying(50),
    tone character varying(100),
    urutan integer DEFAULT 0 NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_core_cluster_code CHECK ((length(btrim((code)::text)) > 0)),
    CONSTRAINT ck_core_cluster_nama CHECK ((length(btrim((nama)::text)) > 0))
);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN id SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN entity_id SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN code SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN nama SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN deskripsi SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN icon SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN tone SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN urutan SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN status SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN version SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN created_at SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN updated_at SET (pg_attver=131842584);
ALTER TABLE ONLY public.core_cluster ALTER COLUMN deleted_at SET (pg_attver=131842584);

--
-- Name: core_cluster_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_cluster_features (
    id bigint NOT NULL,
    id_core_cluster_modules bigint NOT NULL,
    id_core_modules_features bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN id SET (pg_attver=131913088);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN id_core_cluster_modules SET (pg_attver=131913088);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN id_core_modules_features SET (pg_attver=131913088);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN created_at SET (pg_attver=131913088);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN updated_at SET (pg_attver=131913088);
ALTER TABLE ONLY public.core_cluster_features ALTER COLUMN deleted_at SET (pg_attver=131913088);

--
-- Name: core_cluster_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_cluster_modules (
    id bigint NOT NULL,
    id_core_cluster bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN id SET (pg_attver=131882928);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN id_core_cluster SET (pg_attver=131882928);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN id_core_modules SET (pg_attver=131882928);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN created_at SET (pg_attver=131882928);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN updated_at SET (pg_attver=131882928);
ALTER TABLE ONLY public.core_cluster_modules ALTER COLUMN deleted_at SET (pg_attver=131882928);

--
-- Name: core_data_scopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_data_scopes (
    id bigint NOT NULL,
    id_core_roles bigint,
    id_core_users bigint,
    scope_type character varying(72) NOT NULL,
    id_ref bigint NOT NULL,
    granted boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT core_data_scopes_id_ref_check CHECK ((id_ref > 0)),
    CONSTRAINT core_data_scopes_scope_type_check CHECK (((scope_type)::text = ANY (ARRAY['company'::text, 'warehouse'::text, 'outlet'::text, 'property'::text, 'channel'::text]))),
    CONSTRAINT core_data_scopes_subject_required CHECK (((id_core_roles IS NOT NULL) OR (id_core_users IS NOT NULL)))
);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN id SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN id_core_roles SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN id_core_users SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN scope_type SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN id_ref SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN granted SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN created_at SET (pg_attver=113249152);
ALTER TABLE ONLY public.core_data_scopes ALTER COLUMN updated_at SET (pg_attver=113249152);

--
-- Name: core_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_files (
    id bigint NOT NULL,
    entity_id uuid NOT NULL,
    bucket character varying(50) NOT NULL,
    object_key character varying(300) NOT NULL,
    original_name character varying(300) NOT NULL,
    mime_type character varying(100) NOT NULL,
    size_bytes bigint NOT NULL,
    checksum_sha256 character varying(64),
    scope character varying(50) DEFAULT 'general'::text NOT NULL,
    id_core_users bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    id_core_modules bigint,
    id_core_media_categories bigint,
    version integer DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT core_files_size_check CHECK ((size_bytes >= 0))
);
ALTER TABLE ONLY public.core_files ALTER COLUMN id SET (pg_attver=32647600);
ALTER TABLE ONLY public.core_files ALTER COLUMN entity_id SET (pg_attver=32647600);
ALTER TABLE ONLY public.core_files ALTER COLUMN bucket SET (pg_attver=49720392);
ALTER TABLE ONLY public.core_files ALTER COLUMN object_key SET (pg_attver=49726512);
ALTER TABLE ONLY public.core_files ALTER COLUMN original_name SET (pg_attver=49732280);
ALTER TABLE ONLY public.core_files ALTER COLUMN mime_type SET (pg_attver=49737736);
ALTER TABLE ONLY public.core_files ALTER COLUMN size_bytes SET (pg_attver=49737736);
ALTER TABLE ONLY public.core_files ALTER COLUMN checksum_sha256 SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN scope SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN id_core_users SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN created_at SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN id_core_modules SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN id_core_media_categories SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN version SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN updated_at SET (pg_attver=49747992);
ALTER TABLE ONLY public.core_files ALTER COLUMN deleted_at SET (pg_attver=49747992);

--
-- Name: core_ip_allowlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_ip_allowlist (
    id bigint NOT NULL,
    id_core_roles bigint,
    id_core_users bigint,
    target character varying(63) NOT NULL,
    cidr character varying(42) NOT NULL,
    note character varying(111),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT core_ip_allowlist_target_required CHECK (((id_core_roles IS NOT NULL) OR (id_core_users IS NOT NULL)))
);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN id SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN id_core_roles SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN id_core_users SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN target SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN cidr SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN note SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN created_at SET (pg_attver=32669432);
ALTER TABLE ONLY public.core_ip_allowlist ALTER COLUMN updated_at SET (pg_attver=32669432);

--
-- Name: TABLE core_ip_allowlist; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_ip_allowlist IS '[SECURITY] Daftar putih IP per role/user';

--
-- Name: core_kecamatan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_kecamatan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    id_core_kota bigint NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN id SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN entity_id SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN kode SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN nama SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN id_core_kota SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN version SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN created_at SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN updated_at SET (pg_attver=50561968);
ALTER TABLE ONLY public.core_kecamatan ALTER COLUMN deleted_at SET (pg_attver=50561968);

--
-- Name: core_kelurahan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_kelurahan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    kode_pos character varying(50),
    id_core_kecamatan bigint NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN id SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN entity_id SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN kode SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN nama SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN kode_pos SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN id_core_kecamatan SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN version SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN created_at SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN updated_at SET (pg_attver=50586344);
ALTER TABLE ONLY public.core_kelurahan ALTER COLUMN deleted_at SET (pg_attver=50586344);

--
-- Name: core_kota; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_kota (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    jenis character varying(50) NOT NULL,
    id_core_provinsi bigint NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_core_kota_jenis CHECK (((jenis)::text = ANY ((ARRAY['KOTA'::character varying, 'KABUPATEN'::character varying])::text[])))
);
ALTER TABLE ONLY public.core_kota ALTER COLUMN id SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN entity_id SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN kode SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN nama SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN jenis SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN id_core_provinsi SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN version SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN created_at SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN updated_at SET (pg_attver=50534480);
ALTER TABLE ONLY public.core_kota ALTER COLUMN deleted_at SET (pg_attver=50534480);

--
-- Name: core_login_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_login_audit (
    id bigint NOT NULL,
    id_core_users bigint,
    username_tried character varying(42) NOT NULL,
    success boolean NOT NULL,
    fail_reason public.core_login_fail_reason,
    ip_address character varying(42) NOT NULL,
    user_agent character varying(402) NOT NULL,
    attempted_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN id SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN id_core_users SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN username_tried SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN success SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN fail_reason SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN ip_address SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN user_agent SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN attempted_at SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN created_at SET (pg_attver=32684752);
ALTER TABLE ONLY public.core_login_audit ALTER COLUMN updated_at SET (pg_attver=32684752);

--
-- Name: TABLE core_login_audit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_login_audit IS '[AUDIT] Jejak percobaan login';

--
-- Name: core_mail_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_mail_log (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    id_core_users bigint,
    penerima character varying(150) NOT NULL,
    penerima_nama character varying(100),
    subjek character varying(200) NOT NULL,
    jenis character varying(50) NOT NULL,
    status public.enum_status_mail NOT NULL,
    pesan_error character varying(300),
    provider_message_id character varying(300),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN id SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN entity_id SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN id_core_users SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN penerima SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN penerima_nama SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN subjek SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN jenis SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN status SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN pesan_error SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN provider_message_id SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN created_at SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN updated_at SET (pg_attver=740807168);
ALTER TABLE ONLY public.core_mail_log ALTER COLUMN deleted_at SET (pg_attver=740807168);

--
-- Name: TABLE core_mail_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_mail_log IS '[LOG/EVENT] jejak kirim email SMTP (core/mailer) — append-only; updated_at beku, deleted_at selalu NULL';

--
-- Name: COLUMN core_mail_log.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_mail_log.status IS 'TERKIRIM | GAGAL (SMTP error) | NONAKTIF (MAIL_HOST kosong — layanan mati)';

--
-- Name: core_media_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_media_categories (
    id bigint NOT NULL,
    entity_id uuid NOT NULL,
    id_core_modules bigint,
    nama character varying(100) NOT NULL,
    keterangan character varying(200),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN id SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN entity_id SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN id_core_modules SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN nama SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN keterangan SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN version SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN created_at SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN updated_at SET (pg_attver=49683520);
ALTER TABLE ONLY public.core_media_categories ALTER COLUMN deleted_at SET (pg_attver=49683520);

--
-- Name: core_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_menus (
    id bigint NOT NULL,
    text character varying(63) NOT NULL,
    url_path character varying(78),
    parent bigint,
    "order" smallint,
    class character varying(30),
    icon character varying(96),
    external_href character varying(30),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    id_core_modules bigint
);
ALTER TABLE ONLY public.core_menus ALTER COLUMN id SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN text SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN url_path SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN parent SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN "order" SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN class SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN icon SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN external_href SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN created_at SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN updated_at SET (pg_attver=32704936);
ALTER TABLE ONLY public.core_menus ALTER COLUMN id_core_modules SET (pg_attver=32704936);

--
-- Name: TABLE core_menus; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_menus IS '[MASTER] Menu tree (data-driven nav) — tree kanonik NexiERP modul core & inventory; pengelompokan kontekstual tanpa tier paket (ddl/37).';

--
-- Name: core_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_meta (
    id character varying(210) NOT NULL,
    value jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_meta ALTER COLUMN id SET (pg_attver=32718376);
ALTER TABLE ONLY public.core_meta ALTER COLUMN value SET (pg_attver=32718376);
ALTER TABLE ONLY public.core_meta ALTER COLUMN created_at SET (pg_attver=32718376);
ALTER TABLE ONLY public.core_meta ALTER COLUMN updated_at SET (pg_attver=32718376);

--
-- Name: TABLE core_meta; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_meta IS '[PLATFORM] Key-value (logo, seed_version, security)';

--
-- Name: core_metode_bayar; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_metode_bayar (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    jenis public.enum_jenis_metode_bayar_core NOT NULL,
    butuh_referensi boolean DEFAULT false NOT NULL,
    id_acc_akun_kas bigint,
    id_acc_akun_pendapatan bigint,
    urutan integer DEFAULT 0 NOT NULL,
    status public.enum_status_aktif DEFAULT 'AKTIF'::public.enum_status_aktif NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_core_metode_bayar_urutan CHECK ((urutan >= 0))
);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN id SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN entity_id SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN kode SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN nama SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN jenis SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN butuh_referensi SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN id_acc_akun_kas SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN id_acc_akun_pendapatan SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN urutan SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN status SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN version SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN created_at SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN updated_at SET (pg_attver=32735696);
ALTER TABLE ONLY public.core_metode_bayar ALTER COLUMN deleted_at SET (pg_attver=32735696);

--
-- Name: TABLE core_metode_bayar; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_metode_bayar IS '[MASTER] metode bayar (CORE, PP-20) — dirujuk pembayaran/kas/refund POS, pemetaan akun jurnal ACC, deposit RSV; kosakata: TUNAI/KARTU/QRIS/TRANSFER/LAINNYA/POIN (POIN = redeem loyalitas F19).';

--
-- Name: COLUMN core_metode_bayar.id_acc_akun_kas; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_metode_bayar.id_acc_akun_kas IS 'reserved — FK ke acc_akun_coa ditambahkan patch modul ACC (PP-03/D-11).';

--
-- Name: core_module_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_module_configs (
    id bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    param_key character varying(96) NOT NULL,
    param_value text NOT NULL,
    value_type public.core_config_value_type DEFAULT 'string'::public.core_config_value_type NOT NULL,
    description character varying(255) DEFAULT ''::character varying NOT NULL,
    version bigint DEFAULT 0 NOT NULL,
    updated_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT core_module_configs_value_type_check CHECK ((value_type = ANY (ARRAY['string'::public.core_config_value_type, 'number'::public.core_config_value_type, 'boolean'::public.core_config_value_type, 'json'::public.core_config_value_type])))
);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN id SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN id_core_modules SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN param_key SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN param_value SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN value_type SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN description SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN version SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN updated_by SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN created_at SET (pg_attver=32757104);
ALTER TABLE ONLY public.core_module_configs ALTER COLUMN updated_at SET (pg_attver=32757104);

--
-- Name: TABLE core_module_configs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_module_configs IS '[PLATFORM] Konfigurasi parameter bisnis ber-owner modul (ambang, flag fitur, batas nilai) — owner via FK core_modules; nilai text + value_type; version utk optimistic locking — service: core/config/module-config.service';

--
-- Name: COLUMN core_module_configs.param_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_module_configs.param_key IS 'Natural key parameter dalam modul — konvensi dotted `fitur.nama`, mis. ''opname.reconcile_auto_approve_max_value''';

--
-- Name: COLUMN core_module_configs.param_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_module_configs.param_value IS 'Nilai terserialisasi TEXT — string apa adanya; number cast; boolean ''true''/''false''; json JSON valid';

--
-- Name: COLUMN core_module_configs.version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_module_configs.version IS 'Nomor versi baris (optimistic locking) — naik 1 tiap update sukses; edit kirim expectedVersion, tidak cocok → 409 VAL-409';

--
-- Name: COLUMN core_module_configs.updated_by; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_module_configs.updated_by IS 'User terakhir pengubah — NULL bila diisi sistem/seed (jejak lengkap tetap di core_audit_trail)';

--
-- Name: core_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_modules (
    id bigint NOT NULL,
    key public.core_module_key NOT NULL,
    name character varying(66) NOT NULL,
    tagline character varying(255) NOT NULL,
    tone character varying(87) NOT NULL,
    is_core boolean DEFAULT false NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    enabled_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled_at timestamp with time zone,
    id_core_users bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_modules ALTER COLUMN id SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN key SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN name SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN tagline SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN tone SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN is_core SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN enabled SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN enabled_at SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN disabled_at SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN id_core_users SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN created_at SET (pg_attver=32787992);
ALTER TABLE ONLY public.core_modules ALTER COLUMN updated_at SET (pg_attver=32787992);

--
-- Name: TABLE core_modules; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_modules IS '[MASTER] Katalog modul ERP — key enum core_module_key (termasuk 10 modul klinik via ddl/24b); toggle aktif/nonaktif per instalasi.';

--
-- Name: core_modules_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_modules_features (
    id bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    features_folder character varying(54) NOT NULL,
    description jsonb,
    is_system boolean,
    is_active boolean DEFAULT true NOT NULL,
    id_core_users_activated bigint,
    active_until timestamp with time zone,
    id_core_users_deactivated bigint,
    deactivated_from timestamp with time zone,
    created_at timestamp(0) with time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) with time zone,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL
);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN id SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN id_core_modules SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN features_folder SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN description SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN is_system SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN is_active SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN id_core_users_activated SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN active_until SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN id_core_users_deactivated SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN deactivated_from SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN created_at SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN updated_at SET (pg_attver=32801168);
ALTER TABLE ONLY public.core_modules_features ALTER COLUMN entity_id SET (pg_attver=32801168);

--
-- Name: TABLE core_modules_features; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_modules_features IS '[MASTER] Fitur per modul (ex core_features) + siklus aktif — tanpa tier paket (semua fitur aktif).';

--
-- Name: core_outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_outbox_events (
    id bigint NOT NULL,
    topic character varying(78) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status public.core_outbox_status DEFAULT 'pending'::public.core_outbox_status NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error character varying(30),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT core_outbox_events_attempts_check CHECK ((attempts >= 0))
);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN id SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN topic SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN payload SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN status SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN available_at SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN attempts SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN last_error SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN created_at SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN processed_at SET (pg_attver=32828024);
ALTER TABLE ONLY public.core_outbox_events ALTER COLUMN updated_at SET (pg_attver=32828024);

--
-- Name: TABLE core_outbox_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_outbox_events IS '[PLATFORM] Outbox integrasi terpusat';

--
-- Name: core_password_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_password_history (
    id bigint NOT NULL,
    id_core_users bigint NOT NULL,
    user_name character varying(42) NOT NULL,
    set_at timestamp with time zone NOT NULL,
    masked_hash character varying(105) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN id SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN id_core_users SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN user_name SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN set_at SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN masked_hash SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN created_at SET (pg_attver=32853776);
ALTER TABLE ONLY public.core_password_history ALTER COLUMN updated_at SET (pg_attver=32853776);

--
-- Name: TABLE core_password_history; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_password_history IS '[AUDIT|SECURITY] Riwayat password';

--
-- Name: core_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_permissions (
    id bigint NOT NULL,
    name character varying(222),
    description character varying(30),
    id_core_modules bigint,
    id_core_modules_features bigint,
    status public.core_permission_status DEFAULT 'active'::public.core_permission_status NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    metadata jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN id SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN name SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN description SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN id_core_modules SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN id_core_modules_features SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN status SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN is_system SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN metadata SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN created_at SET (pg_attver=32935672);
ALTER TABLE ONLY public.core_permissions ALTER COLUMN updated_at SET (pg_attver=32935672);

--
-- Name: TABLE core_permissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_permissions IS '[ACCESS] Katalog permission (code kanonik unik), terhubung ke routes via core_permissions_routes';

--
-- Name: core_permissions_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_permissions_routes (
    id bigint NOT NULL,
    id_core_routes bigint NOT NULL,
    id_core_permissions bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);
ALTER TABLE ONLY public.core_permissions_routes ALTER COLUMN id SET (pg_attver=32958056);
ALTER TABLE ONLY public.core_permissions_routes ALTER COLUMN id_core_routes SET (pg_attver=32958056);
ALTER TABLE ONLY public.core_permissions_routes ALTER COLUMN id_core_permissions SET (pg_attver=32958056);
ALTER TABLE ONLY public.core_permissions_routes ALTER COLUMN created_at SET (pg_attver=32958056);
ALTER TABLE ONLY public.core_permissions_routes ALTER COLUMN updated_at SET (pg_attver=32958056);

--
-- Name: TABLE core_permissions_routes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_permissions_routes IS '[ACCESS] Junction permission ↔ route';

--
-- Name: core_provinsi; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_provinsi (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN id SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN entity_id SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN kode SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN nama SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN version SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN created_at SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN updated_at SET (pg_attver=50514032);
ALTER TABLE ONLY public.core_provinsi ALTER COLUMN deleted_at SET (pg_attver=50514032);

--
-- Name: core_role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_role_permissions (
    id bigint NOT NULL,
    id_core_roles bigint NOT NULL,
    id_core_permissions bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_role_permissions ALTER COLUMN id SET (pg_attver=32969296);
ALTER TABLE ONLY public.core_role_permissions ALTER COLUMN id_core_roles SET (pg_attver=32969296);
ALTER TABLE ONLY public.core_role_permissions ALTER COLUMN id_core_permissions SET (pg_attver=32969296);
ALTER TABLE ONLY public.core_role_permissions ALTER COLUMN created_at SET (pg_attver=32969296);
ALTER TABLE ONLY public.core_role_permissions ALTER COLUMN updated_at SET (pg_attver=32969296);

--
-- Name: TABLE core_role_permissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_role_permissions IS '[ACCESS] Role menyandang permission (unik pair)';

--
-- Name: core_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_roles (
    id bigint NOT NULL,
    code character varying(45) NOT NULL,
    role character varying(48) NOT NULL,
    description character varying(279),
    is_system boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_roles ALTER COLUMN id SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN code SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN role SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN description SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN is_system SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN created_at SET (pg_attver=32981744);
ALTER TABLE ONLY public.core_roles ALTER COLUMN updated_at SET (pg_attver=32981744);

--
-- Name: TABLE core_roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_roles IS '[ACCESS] Role sebagai data RBAC (multi-role per user) — tanpa batas tier; tier paket diatur di tabel tenant.';

--
-- Name: core_roles_menus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_roles_menus (
    id bigint NOT NULL,
    id_core_menus bigint NOT NULL,
    id_core_roles bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);
ALTER TABLE ONLY public.core_roles_menus ALTER COLUMN id SET (pg_attver=32995128);
ALTER TABLE ONLY public.core_roles_menus ALTER COLUMN id_core_menus SET (pg_attver=32995128);
ALTER TABLE ONLY public.core_roles_menus ALTER COLUMN id_core_roles SET (pg_attver=32995128);
ALTER TABLE ONLY public.core_roles_menus ALTER COLUMN created_at SET (pg_attver=32995128);
ALTER TABLE ONLY public.core_roles_menus ALTER COLUMN updated_at SET (pg_attver=32995128);

--
-- Name: TABLE core_roles_menus; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_roles_menus IS '[ACCESS] Junction role ↔ menu';

--
-- Name: core_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_routes (
    id bigint NOT NULL,
    method public.core_http_method NOT NULL,
    uri_pattern character varying(195) NOT NULL,
    permission_code character varying(222) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    id_core_modules_features bigint
);
ALTER TABLE ONLY public.core_routes ALTER COLUMN id SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN method SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN uri_pattern SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN permission_code SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN created_at SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN updated_at SET (pg_attver=33006464);
ALTER TABLE ONLY public.core_routes ALTER COLUMN id_core_modules_features SET (pg_attver=33006464);

--
-- Name: TABLE core_routes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_routes IS '[ACCESS] Registry semua endpoint API — (method, uri_pattern) unik, permission_code "{modul}.{fitur}.{method}"';

--
-- Name: COLUMN core_routes.id_core_modules_features; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_routes.id_core_modules_features IS '[ACCESS] Fitur fisik controller (folder api/{fitur}) — diisi scanroutes.sh; NULL = controller di root modul / core (tanpa folder fitur)';

--
-- Name: core_scope_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_scope_assignments (
    id bigint NOT NULL,
    id_core_scope_definitions bigint NOT NULL,
    id_core_roles bigint,
    id_core_users bigint,
    is_active boolean DEFAULT true NOT NULL,
    note character varying(200) DEFAULT ''::character varying NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT core_scope_assignments_subject_required CHECK (((((id_core_roles IS NOT NULL))::integer + ((id_core_users IS NOT NULL))::integer) = 1))
);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN id SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN id_core_scope_definitions SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN id_core_roles SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN id_core_users SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN is_active SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN note SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN version SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN created_at SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN updated_at SET (pg_attver=33019032);
ALTER TABLE ONLY public.core_scope_assignments ALTER COLUMN deleted_at SET (pg_attver=33019032);

--
-- Name: TABLE core_scope_assignments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_scope_assignments IS '[CONFIG] Pemberian scope whitelist per definisi ke role (default) atau user (override menimpa role). ddl/50.';

--
-- Name: core_scope_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_scope_definitions (
    id bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    scope_key character varying(50) NOT NULL,
    label character varying(100) NOT NULL,
    description character varying(300) DEFAULT ''::character varying NOT NULL,
    target_table character varying(100) NOT NULL,
    target_field character varying(100) NOT NULL,
    operator public.core_scope_operator DEFAULT 'in'::public.core_scope_operator NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    version bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN id SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN id_core_modules SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN scope_key SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN label SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN description SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN target_table SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN target_field SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN operator SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN is_active SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN version SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN created_at SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN updated_at SET (pg_attver=33038264);
ALTER TABLE ONLY public.core_scope_definitions ALTER COLUMN deleted_at SET (pg_attver=33038264);

--
-- Name: TABLE core_scope_definitions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_scope_definitions IS '[MASTER/CONFIG] Katalog dimensi data-scope generik per modul: objek scope = (tabel, field, operator). ddl/50.';

--
-- Name: core_scope_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_scope_values (
    id bigint NOT NULL,
    id_core_scope_assignments bigint NOT NULL,
    value character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN id SET (pg_attver=33063264);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN id_core_scope_assignments SET (pg_attver=33063264);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN value SET (pg_attver=33063264);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN created_at SET (pg_attver=33063264);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN updated_at SET (pg_attver=33063264);
ALTER TABLE ONLY public.core_scope_values ALTER COLUMN deleted_at SET (pg_attver=33063264);

--
-- Name: TABLE core_scope_values; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_scope_values IS '[LINE] Nilai whitelist scope — 1 baris = 1 id baris target; tanpa baris = deny-all. ddl/50.';

--
-- Name: core_sequences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_sequences (
    id bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    doc_name character varying(84) NOT NULL,
    prefix character varying(42) NOT NULL,
    current_value bigint DEFAULT 0 NOT NULL,
    padding smallint DEFAULT 4 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT core_sequences_current_value_check CHECK ((current_value >= 0)),
    CONSTRAINT core_sequences_padding_check CHECK (((padding >= 1) AND (padding <= 12)))
);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN id SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN id_core_modules SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN doc_name SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN prefix SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN current_value SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN padding SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN created_at SET (pg_attver=33076096);
ALTER TABLE ONLY public.core_sequences ALTER COLUMN updated_at SET (pg_attver=33076096);

--
-- Name: TABLE core_sequences; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_sequences IS '[PLATFORM] Counter penomoran dokumen anti-race — service numbering: UPDATE ... RETURNING per (modul, doc_name)';

--
-- Name: core_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_sessions (
    id bigint NOT NULL,
    id_core_users bigint NOT NULL,
    user_name character varying(42) NOT NULL,
    device_key character varying(108),
    login_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    logout_at timestamp with time zone,
    revoked_at timestamp with time zone,
    ip_address character varying(88) NOT NULL,
    user_agent character varying(402) NOT NULL,
    device character varying(66) NOT NULL,
    is_valid boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN id SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN id_core_users SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN user_name SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN device_key SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN login_at SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN expires_at SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN logout_at SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN revoked_at SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN ip_address SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN user_agent SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN device SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN is_valid SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN created_at SET (pg_attver=33093848);
ALTER TABLE ONLY public.core_sessions ALTER COLUMN updated_at SET (pg_attver=33093848);

--
-- Name: TABLE core_sessions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_sessions IS '[SESSION] Sesi per perangkat';

--
-- Name: core_tenant_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_tenant_events (
    id bigint NOT NULL,
    id_core_tenants bigint NOT NULL,
    aksi character varying(100) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    id_core_users bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN id SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN id_core_tenants SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN aksi SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN payload SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN id_core_users SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN created_at SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN updated_at SET (pg_attver=33136992);
ALTER TABLE ONLY public.core_tenant_events ALTER COLUMN deleted_at SET (pg_attver=33136992);

--
-- Name: core_tenant_features; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_tenant_features (
    id bigint NOT NULL,
    id_core_tenants bigint NOT NULL,
    id_core_modules_features bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN id SET (pg_attver=33157712);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN id_core_tenants SET (pg_attver=33157712);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN id_core_modules_features SET (pg_attver=33157712);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN created_at SET (pg_attver=33157712);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN updated_at SET (pg_attver=33157712);
ALTER TABLE ONLY public.core_tenant_features ALTER COLUMN deleted_at SET (pg_attver=33157712);

--
-- Name: core_tenant_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_tenant_modules (
    id bigint NOT NULL,
    id_core_tenants bigint NOT NULL,
    id_core_modules bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN id SET (pg_attver=33170104);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN id_core_tenants SET (pg_attver=33170104);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN id_core_modules SET (pg_attver=33170104);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN created_at SET (pg_attver=33170104);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN updated_at SET (pg_attver=33170104);
ALTER TABLE ONLY public.core_tenant_modules ALTER COLUMN deleted_at SET (pg_attver=33170104);

--
-- Name: core_tenant_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_tenant_settings (
    id bigint NOT NULL,
    id_core_tenants bigint NOT NULL,
    kategori character varying(100) NOT NULL,
    kunci character varying(100) NOT NULL,
    nilai jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN id SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN id_core_tenants SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN kategori SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN kunci SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN nilai SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN created_at SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN updated_at SET (pg_attver=33182176);
ALTER TABLE ONLY public.core_tenant_settings ALTER COLUMN deleted_at SET (pg_attver=33182176);

--
-- Name: core_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_tenants (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kode character varying(50) NOT NULL,
    nama character varying(100) NOT NULL,
    paket_tier public.enum_paket_tier DEFAULT 'PS2'::public.enum_paket_tier NOT NULL,
    status public.enum_status_tenant DEFAULT 'PROVISI'::public.enum_status_tenant NOT NULL,
    max_users integer,
    max_lokasi integer,
    kontak_email character varying(150),
    kontak_telepon character varying(50),
    versi_skema integer DEFAULT 1 NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_core_tenants_kode_lower CHECK (((kode)::text = lower((kode)::text))),
    CONSTRAINT ck_core_tenants_kuota CHECK ((((max_users IS NULL) OR (max_users >= 0)) AND ((max_lokasi IS NULL) OR (max_lokasi >= 0))))
);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN id SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN entity_id SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN kode SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN nama SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN paket_tier SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN status SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN max_users SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN max_lokasi SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN kontak_email SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN kontak_telepon SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN versi_skema SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN version SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN created_at SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN updated_at SET (pg_attver=33207728);
ALTER TABLE ONLY public.core_tenants ALTER COLUMN deleted_at SET (pg_attver=33207728);

--
-- Name: TABLE core_tenants; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_tenants IS 'registry tenant Opsi C — master identitas, paket & kuota tenant;belum menyentuh tabel bisnis (patch aditif murni)';

--
-- Name: COLUMN core_tenants.kode; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_tenants.kode IS 'slug lowercase unik global — tak pernah dipakai ulang setelah tenant ditutup;satuan kebenaran subdomain/host per tenant';

--
-- Name: COLUMN core_tenants.paket_tier; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_tenants.paket_tier IS 'Profil Skala langganan — PS1/PS2/PS3; menentukan kuota default via SET_TIER';

--
-- Name: COLUMN core_tenants.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_tenants.status IS 'siklus hidup tenant: PROVISI → AKTIF → DITANGGUHKAN/DITUTUP;perubahan status wajib menulis core_tenant_events';

--
-- Name: COLUMN core_tenants.versi_skema; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_tenants.versi_skema IS 'posisi patch DDL skema bisnis tenant — dipakai jalur migrasi per-tenant';

--
-- Name: core_user_mfa; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_user_mfa (
    id_core_users bigint NOT NULL,
    user_name character varying(42) NOT NULL,
    method public.core_mfa_method NOT NULL,
    confirmed_at timestamp with time zone,
    enabled boolean DEFAULT false NOT NULL,
    last_used_at timestamp with time zone,
    recovery_codes_left integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT core_user_mfa_recovery_codes_left_check CHECK ((recovery_codes_left >= 0))
);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN id_core_users SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN user_name SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN method SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN confirmed_at SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN enabled SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN last_used_at SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN recovery_codes_left SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN created_at SET (pg_attver=33248488);
ALTER TABLE ONLY public.core_user_mfa ALTER COLUMN updated_at SET (pg_attver=33248488);

--
-- Name: TABLE core_user_mfa; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_user_mfa IS '[SECURITY] MFA 1:1 core_users (PK = FK)';

--
-- Name: core_user_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_user_permissions (
    id bigint NOT NULL,
    id_core_users bigint NOT NULL,
    granted boolean NOT NULL,
    id_core_users_granted_by bigint NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    id_core_permissions bigint NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN id SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN id_core_users SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN granted SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN id_core_users_granted_by SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN granted_at SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN expires_at SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN created_at SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN updated_at SET (pg_attver=33260848);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN id_core_permissions SET (pg_attver=49917328);
ALTER TABLE ONLY public.core_user_permissions ALTER COLUMN deleted_at SET (pg_attver=49922208);

--
-- Name: TABLE core_user_permissions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_user_permissions IS '[ACCESS] Override per-user (grant/deny + expiry)';

--
-- Name: core_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_users (
    id bigint NOT NULL,
    username character varying(150) NOT NULL,
    password_hash character varying(291) NOT NULL,
    name character varying(100) NOT NULL,
    email character varying(150) NOT NULL,
    department character varying(96),
    is_active boolean DEFAULT true NOT NULL,
    password_changed_at timestamp with time zone,
    must_change_password boolean DEFAULT false NOT NULL,
    failed_login_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    mfa_enabled boolean DEFAULT false NOT NULL,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    pin_hash character varying(255),
    pin_at timestamp with time zone,
    CONSTRAINT core_users_failed_login_attempts_check CHECK ((failed_login_attempts >= 0)),
    CONSTRAINT core_users_username_check CHECK (((username)::text = lower((username)::text)))
);
ALTER TABLE ONLY public.core_users ALTER COLUMN id SET (pg_attver=33275232);
ALTER TABLE ONLY public.core_users ALTER COLUMN username SET (pg_attver=177627120);
ALTER TABLE ONLY public.core_users ALTER COLUMN password_hash SET (pg_attver=177627120);
ALTER TABLE ONLY public.core_users ALTER COLUMN name SET (pg_attver=177635848);
ALTER TABLE ONLY public.core_users ALTER COLUMN email SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN department SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN is_active SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN password_changed_at SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN must_change_password SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN failed_login_attempts SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN locked_until SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN mfa_enabled SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN last_login_at SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN created_at SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN updated_at SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN pin_hash SET (pg_attver=177639280);
ALTER TABLE ONLY public.core_users ALTER COLUMN pin_at SET (pg_attver=177639280);

--
-- Name: TABLE core_users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_users IS '[SESSION|SECURITY] Pengguna & kredensial (role hanya via core_users_roles)';

--
-- Name: COLUMN core_users.pin_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_users.pin_hash IS 'PIN kasir 4-6 digit (hash argon2id) untuk kunci/buka layar kasir POS; NULL = belum set — kasir wajib mengatur saat pertama kali (PP-21).';

--
-- Name: COLUMN core_users.pin_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.core_users.pin_at IS 'Waktu PIN kasir terakhir diatur/diubah.';

--
-- Name: core_users_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_users_roles (
    id bigint NOT NULL,
    id_core_users bigint NOT NULL,
    id_core_roles bigint NOT NULL,
    id_core_users_assigned_by bigint NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN id SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN id_core_users SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN id_core_roles SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN id_core_users_assigned_by SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN assigned_at SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN created_at SET (pg_attver=33309456);
ALTER TABLE ONLY public.core_users_roles ALTER COLUMN updated_at SET (pg_attver=33309456);

--
-- Name: TABLE core_users_roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.core_users_roles IS '[ACCESS] Junction user ↔ role (MULTI-ROLE)';

--
-- Name: core_users_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.core_users_tenants (
    id bigint NOT NULL,
    id_core_tenants bigint NOT NULL,
    id_core_users bigint NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    dicabut_pada timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN id SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN id_core_tenants SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN id_core_users SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN is_default SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN dicabut_pada SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN created_at SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN updated_at SET (pg_attver=33323016);
ALTER TABLE ONLY public.core_users_tenants ALTER COLUMN deleted_at SET (pg_attver=33323016);

--
-- Name: hr_karyawan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hr_karyawan (
    id bigint NOT NULL,
    entity_id uuid DEFAULT gen_random_uuid() NOT NULL,
    nik_pegawai character varying(50) NOT NULL,
    nama_lengkap character varying(100) NOT NULL,
    jenis_pekerja public.enum_jenis_pekerja_hr NOT NULL,
    ptkp public.enum_ptkp_hr DEFAULT 'TK0'::public.enum_ptkp_hr NOT NULL,
    status public.enum_status_karyawan_hr DEFAULT 'AKTIF'::public.enum_status_karyawan_hr NOT NULL,
    id_hr_departemen bigint,
    id_hr_jabatan bigint,
    id_hr_karyawan bigint,
    id_core_users bigint,
    tanggal_masuk date,
    tanggal_keluar date,
    bank character varying(100),
    no_rekening character varying(100),
    keterangan character varying(200),
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT ck_hr_karyawan_atasan_bukan_diri CHECK (((id_hr_karyawan IS NULL) OR (id_hr_karyawan <> id)))
);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN id SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN entity_id SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN nik_pegawai SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN nama_lengkap SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN jenis_pekerja SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN ptkp SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN status SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN id_hr_departemen SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN id_hr_jabatan SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN id_hr_karyawan SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN id_core_users SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN tanggal_masuk SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN tanggal_keluar SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN bank SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN no_rekening SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN keterangan SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN version SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN created_at SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN updated_at SET (pg_attver=34355408);
ALTER TABLE ONLY public.hr_karyawan ALTER COLUMN deleted_at SET (pg_attver=34355408);

--
-- Name: core_agama core_agama_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_agama
    ADD CONSTRAINT core_agama_pkey PRIMARY KEY (id);

--
-- Name: core_app_settings core_app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_app_settings
    ADD CONSTRAINT core_app_settings_pkey PRIMARY KEY (id);

--
-- Name: core_approval_limits core_approval_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_approval_limits
    ADD CONSTRAINT core_approval_limits_pkey PRIMARY KEY (id);

--
-- Name: core_approval_limits core_approval_limits_subject_doc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_approval_limits
    ADD CONSTRAINT core_approval_limits_subject_doc_key UNIQUE NULLS NOT DISTINCT (id_core_roles, id_core_users, id_core_modules, doc_type, currency);

--
-- Name: core_audit_trail core_audit_trail_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_audit_trail
    ADD CONSTRAINT core_audit_trail_pkey PRIMARY KEY (id);

--
-- Name: core_auth_tokens core_auth_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_auth_tokens
    ADD CONSTRAINT core_auth_tokens_pkey PRIMARY KEY (id);

--
-- Name: core_cluster_features core_cluster_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_features
    ADD CONSTRAINT core_cluster_features_pkey PRIMARY KEY (id);

--
-- Name: core_cluster_modules core_cluster_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_modules
    ADD CONSTRAINT core_cluster_modules_pkey PRIMARY KEY (id);

--
-- Name: core_cluster core_cluster_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster
    ADD CONSTRAINT core_cluster_pkey PRIMARY KEY (id);

--
-- Name: core_data_scopes core_data_scopes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_scopes
    ADD CONSTRAINT core_data_scopes_pkey PRIMARY KEY (id);

--
-- Name: core_data_scopes core_data_scopes_subject_type_ref_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_scopes
    ADD CONSTRAINT core_data_scopes_subject_type_ref_key UNIQUE NULLS NOT DISTINCT (id_core_roles, id_core_users, scope_type, id_ref);

--
-- Name: core_files core_files_bucket_object_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_bucket_object_key_key UNIQUE (bucket, object_key);

--
-- Name: core_files core_files_entity_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_entity_id_key UNIQUE (entity_id);

--
-- Name: core_files core_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_pkey PRIMARY KEY (id);

--
-- Name: core_ip_allowlist core_ip_allowlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_pkey PRIMARY KEY (id);

--
-- Name: core_kecamatan core_kecamatan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kecamatan
    ADD CONSTRAINT core_kecamatan_pkey PRIMARY KEY (id);

--
-- Name: core_kelurahan core_kelurahan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kelurahan
    ADD CONSTRAINT core_kelurahan_pkey PRIMARY KEY (id);

--
-- Name: core_kota core_kota_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kota
    ADD CONSTRAINT core_kota_pkey PRIMARY KEY (id);

--
-- Name: core_login_audit core_login_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_login_audit
    ADD CONSTRAINT core_login_audit_pkey PRIMARY KEY (id);

--
-- Name: core_mail_log core_mail_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_mail_log
    ADD CONSTRAINT core_mail_log_pkey PRIMARY KEY (id);

--
-- Name: core_media_categories core_media_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_media_categories
    ADD CONSTRAINT core_media_categories_pkey PRIMARY KEY (id);

--
-- Name: core_menus core_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_menus
    ADD CONSTRAINT core_menus_pkey PRIMARY KEY (id);

--
-- Name: core_meta core_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_meta
    ADD CONSTRAINT core_meta_pkey PRIMARY KEY (id);

--
-- Name: core_metode_bayar core_metode_bayar_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_metode_bayar
    ADD CONSTRAINT core_metode_bayar_pkey PRIMARY KEY (id);

--
-- Name: core_module_configs core_module_configs_module_param_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_module_configs
    ADD CONSTRAINT core_module_configs_module_param_key UNIQUE (id_core_modules, param_key);

--
-- Name: core_module_configs core_module_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_module_configs
    ADD CONSTRAINT core_module_configs_pkey PRIMARY KEY (id);

--
-- Name: core_modules_features core_modules_features_module_folder_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules_features
    ADD CONSTRAINT core_modules_features_module_folder_key UNIQUE (id_core_modules, features_folder);

--
-- Name: core_modules_features core_modules_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules_features
    ADD CONSTRAINT core_modules_features_pkey PRIMARY KEY (id);

--
-- Name: core_modules core_modules_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules
    ADD CONSTRAINT core_modules_key_key UNIQUE (key);

--
-- Name: core_modules core_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules
    ADD CONSTRAINT core_modules_pkey PRIMARY KEY (id);

--
-- Name: core_outbox_events core_outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_outbox_events
    ADD CONSTRAINT core_outbox_events_pkey PRIMARY KEY (id);

--
-- Name: core_password_history core_password_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_password_history
    ADD CONSTRAINT core_password_history_pkey PRIMARY KEY (id);

--
-- Name: core_permissions core_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_pkey PRIMARY KEY (id);

--
-- Name: core_permissions_routes core_permissions_routes_pair_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_pair_key UNIQUE (id_core_routes, id_core_permissions);

--
-- Name: core_permissions_routes core_permissions_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_pkey PRIMARY KEY (id);

--
-- Name: core_provinsi core_provinsi_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_provinsi
    ADD CONSTRAINT core_provinsi_pkey PRIMARY KEY (id);

--
-- Name: core_role_permissions core_role_permissions_pair_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_pair_key UNIQUE (id_core_roles, id_core_permissions);

--
-- Name: core_role_permissions core_role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_pkey PRIMARY KEY (id);

--
-- Name: core_roles core_roles_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles
    ADD CONSTRAINT core_roles_code_key UNIQUE (code);

--
-- Name: core_roles_menus core_roles_menus_pair_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles_menus
    ADD CONSTRAINT core_roles_menus_pair_key UNIQUE (id_core_menus, id_core_roles);

--
-- Name: core_roles_menus core_roles_menus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles_menus
    ADD CONSTRAINT core_roles_menus_pkey PRIMARY KEY (id);

--
-- Name: core_roles core_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles
    ADD CONSTRAINT core_roles_pkey PRIMARY KEY (id);

--
-- Name: core_routes core_routes_method_uri_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_routes
    ADD CONSTRAINT core_routes_method_uri_key UNIQUE (method, uri_pattern);

--
-- Name: core_routes core_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_routes
    ADD CONSTRAINT core_routes_pkey PRIMARY KEY (id);

--
-- Name: core_scope_assignments core_scope_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_assignments
    ADD CONSTRAINT core_scope_assignments_pkey PRIMARY KEY (id);

--
-- Name: core_scope_definitions core_scope_definitions_module_key_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_definitions
    ADD CONSTRAINT core_scope_definitions_module_key_uq UNIQUE NULLS NOT DISTINCT (id_core_modules, scope_key);

--
-- Name: core_scope_definitions core_scope_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_definitions
    ADD CONSTRAINT core_scope_definitions_pkey PRIMARY KEY (id);

--
-- Name: core_scope_values core_scope_values_pair_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_values
    ADD CONSTRAINT core_scope_values_pair_uq UNIQUE NULLS NOT DISTINCT (id_core_scope_assignments, value);

--
-- Name: core_scope_values core_scope_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_values
    ADD CONSTRAINT core_scope_values_pkey PRIMARY KEY (id);

--
-- Name: core_sequences core_sequences_module_doc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_sequences
    ADD CONSTRAINT core_sequences_module_doc_key UNIQUE (id_core_modules, doc_name);

--
-- Name: core_sequences core_sequences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_sequences
    ADD CONSTRAINT core_sequences_pkey PRIMARY KEY (id);

--
-- Name: core_sessions core_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_sessions
    ADD CONSTRAINT core_sessions_pkey PRIMARY KEY (id);

--
-- Name: core_tenant_events core_tenant_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_events
    ADD CONSTRAINT core_tenant_events_pkey PRIMARY KEY (id);

--
-- Name: core_tenant_features core_tenant_features_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_features
    ADD CONSTRAINT core_tenant_features_pkey PRIMARY KEY (id);

--
-- Name: core_tenant_modules core_tenant_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_modules
    ADD CONSTRAINT core_tenant_modules_pkey PRIMARY KEY (id);

--
-- Name: core_tenant_settings core_tenant_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_settings
    ADD CONSTRAINT core_tenant_settings_pkey PRIMARY KEY (id);

--
-- Name: core_tenants core_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenants
    ADD CONSTRAINT core_tenants_pkey PRIMARY KEY (id);

--
-- Name: core_user_mfa core_user_mfa_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_mfa
    ADD CONSTRAINT core_user_mfa_pkey PRIMARY KEY (id_core_users);

--
-- Name: core_user_permissions core_user_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_pkey PRIMARY KEY (id);

--
-- Name: core_users core_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users
    ADD CONSTRAINT core_users_pkey PRIMARY KEY (id);

--
-- Name: core_users_roles core_users_roles_pair_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_roles
    ADD CONSTRAINT core_users_roles_pair_key UNIQUE (id_core_users, id_core_roles);

--
-- Name: core_users_roles core_users_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_roles
    ADD CONSTRAINT core_users_roles_pkey PRIMARY KEY (id);

--
-- Name: core_users_tenants core_users_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_tenants
    ADD CONSTRAINT core_users_tenants_pkey PRIMARY KEY (id);

--
-- Name: core_users core_users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users
    ADD CONSTRAINT core_users_username_key UNIQUE (username);

--
-- Name: hr_karyawan hr_karyawan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hr_karyawan
    ADD CONSTRAINT hr_karyawan_pkey PRIMARY KEY (id);

--
-- Name: core_agama uq_core_agama_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_agama
    ADD CONSTRAINT uq_core_agama_entity_id UNIQUE (entity_id);

--
-- Name: core_auth_tokens uq_core_auth_tokens_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_auth_tokens
    ADD CONSTRAINT uq_core_auth_tokens_entity_id UNIQUE (entity_id);

--
-- Name: core_cluster uq_core_cluster_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster
    ADD CONSTRAINT uq_core_cluster_entity_id UNIQUE (entity_id);

--
-- Name: core_kecamatan uq_core_kecamatan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kecamatan
    ADD CONSTRAINT uq_core_kecamatan_entity_id UNIQUE (entity_id);

--
-- Name: core_kelurahan uq_core_kelurahan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kelurahan
    ADD CONSTRAINT uq_core_kelurahan_entity_id UNIQUE (entity_id);

--
-- Name: core_kota uq_core_kota_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kota
    ADD CONSTRAINT uq_core_kota_entity_id UNIQUE (entity_id);

--
-- Name: core_mail_log uq_core_mail_log_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_mail_log
    ADD CONSTRAINT uq_core_mail_log_entity_id UNIQUE (entity_id);

--
-- Name: core_media_categories uq_core_media_categories_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_media_categories
    ADD CONSTRAINT uq_core_media_categories_entity_id UNIQUE (entity_id);

--
-- Name: core_metode_bayar uq_core_metode_bayar_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_metode_bayar
    ADD CONSTRAINT uq_core_metode_bayar_entity_id UNIQUE (entity_id);

--
-- Name: core_provinsi uq_core_provinsi_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_provinsi
    ADD CONSTRAINT uq_core_provinsi_entity_id UNIQUE (entity_id);

--
-- Name: core_tenant_features uq_core_tenant_features; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_features
    ADD CONSTRAINT uq_core_tenant_features UNIQUE (id_core_tenants, id_core_modules_features);

--
-- Name: core_tenant_modules uq_core_tenant_modules; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_modules
    ADD CONSTRAINT uq_core_tenant_modules UNIQUE (id_core_tenants, id_core_modules);

--
-- Name: core_tenant_settings uq_core_tenant_settings; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_settings
    ADD CONSTRAINT uq_core_tenant_settings UNIQUE (id_core_tenants, kategori, kunci);

--
-- Name: core_tenants uq_core_tenants_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenants
    ADD CONSTRAINT uq_core_tenants_entity_id UNIQUE (entity_id);

--
-- Name: core_tenants uq_core_tenants_kode; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenants
    ADD CONSTRAINT uq_core_tenants_kode UNIQUE (kode);

--
-- Name: core_users_tenants uq_core_users_tenants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_tenants
    ADD CONSTRAINT uq_core_users_tenants UNIQUE (id_core_tenants, id_core_users);

--
-- Name: hr_karyawan uq_hr_karyawan_entity_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hr_karyawan
    ADD CONSTRAINT uq_hr_karyawan_entity_id UNIQUE (entity_id);

--
-- Name: core_approval_limits_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_approval_limits_id_core_modules_idx ON public.core_approval_limits USING btree (id_core_modules);

--
-- Name: core_approval_limits_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_approval_limits_id_core_roles_idx ON public.core_approval_limits USING btree (id_core_roles);

--
-- Name: core_approval_limits_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_approval_limits_id_core_users_idx ON public.core_approval_limits USING btree (id_core_users);

--
-- Name: core_approval_limits_module_doc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_approval_limits_module_doc_idx ON public.core_approval_limits USING btree (id_core_modules, doc_type);

--
-- Name: core_audit_trail_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_audit_trail_at_idx ON public.core_audit_trail USING btree (at DESC);

--
-- Name: core_audit_trail_entity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_audit_trail_entity_idx ON public.core_audit_trail USING btree (entity_type, entity_id);

--
-- Name: core_audit_trail_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_audit_trail_id_core_modules_idx ON public.core_audit_trail USING btree (id_core_modules);

--
-- Name: core_audit_trail_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_audit_trail_id_core_users_idx ON public.core_audit_trail USING btree (id_core_users);

--
-- Name: core_data_scopes_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_data_scopes_id_core_roles_idx ON public.core_data_scopes USING btree (id_core_roles);

--
-- Name: core_data_scopes_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_data_scopes_id_core_users_idx ON public.core_data_scopes USING btree (id_core_users);

--
-- Name: core_data_scopes_ref_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_data_scopes_ref_idx ON public.core_data_scopes USING btree (scope_type, id_ref);

--
-- Name: core_files_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_files_created_at_idx ON public.core_files USING btree (created_at DESC);

--
-- Name: core_files_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_files_scope_idx ON public.core_files USING btree (scope);

--
-- Name: core_ip_allowlist_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_ip_allowlist_id_core_roles_idx ON public.core_ip_allowlist USING btree (id_core_roles);

--
-- Name: core_ip_allowlist_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_ip_allowlist_id_core_users_idx ON public.core_ip_allowlist USING btree (id_core_users);

--
-- Name: core_login_audit_attempted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_login_audit_attempted_at_idx ON public.core_login_audit USING btree (attempted_at);

--
-- Name: core_login_audit_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_login_audit_id_core_users_idx ON public.core_login_audit USING btree (id_core_users);

--
-- Name: core_menus_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_menus_id_core_modules_idx ON public.core_menus USING btree (id_core_modules);

--
-- Name: core_menus_parent_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_menus_parent_idx ON public.core_menus USING btree (parent);

--
-- Name: core_module_configs_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_module_configs_id_core_modules_idx ON public.core_module_configs USING btree (id_core_modules);

--
-- Name: core_modules_features_entity_folder_uk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX core_modules_features_entity_folder_uk ON public.core_modules_features USING btree (id_core_modules, features_folder);

--
-- Name: core_modules_features_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_modules_features_id_core_modules_idx ON public.core_modules_features USING btree (id_core_modules);

--
-- Name: core_modules_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_modules_id_core_users_idx ON public.core_modules USING btree (id_core_users);

--
-- Name: core_outbox_events_available_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_outbox_events_available_at_idx ON public.core_outbox_events USING btree (available_at);

--
-- Name: core_outbox_events_poll_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_outbox_events_poll_idx ON public.core_outbox_events USING btree (available_at) WHERE (status = 'pending'::public.core_outbox_status);

--
-- Name: core_outbox_events_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_outbox_events_status_idx ON public.core_outbox_events USING btree (status);

--
-- Name: core_outbox_events_topic_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_outbox_events_topic_idx ON public.core_outbox_events USING btree (topic);

--
-- Name: core_password_history_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_password_history_id_core_users_idx ON public.core_password_history USING btree (id_core_users);

--
-- Name: core_permissions_id_core_modules_features_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_permissions_id_core_modules_features_idx ON public.core_permissions USING btree (id_core_modules_features);

--
-- Name: core_permissions_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_permissions_id_core_modules_idx ON public.core_permissions USING btree (id_core_modules);

--
-- Name: core_permissions_routes_id_core_permissions_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_permissions_routes_id_core_permissions_idx ON public.core_permissions_routes USING btree (id_core_permissions);

--
-- Name: core_permissions_routes_id_core_routes_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_permissions_routes_id_core_routes_idx ON public.core_permissions_routes USING btree (id_core_routes);

--
-- Name: core_role_permissions_id_core_permissions_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_role_permissions_id_core_permissions_idx ON public.core_role_permissions USING btree (id_core_permissions);

--
-- Name: core_role_permissions_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_role_permissions_id_core_roles_idx ON public.core_role_permissions USING btree (id_core_roles);

--
-- Name: core_roles_menus_id_core_menus_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_roles_menus_id_core_menus_idx ON public.core_roles_menus USING btree (id_core_menus);

--
-- Name: core_roles_menus_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_roles_menus_id_core_roles_idx ON public.core_roles_menus USING btree (id_core_roles);

--
-- Name: core_routes_id_core_modules_features_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_routes_id_core_modules_features_idx ON public.core_routes USING btree (id_core_modules_features);

--
-- Name: core_routes_permission_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_routes_permission_code_idx ON public.core_routes USING btree (permission_code);

--
-- Name: core_scope_assignments_def_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_assignments_def_idx ON public.core_scope_assignments USING btree (id_core_scope_definitions);

--
-- Name: core_scope_assignments_role_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_assignments_role_idx ON public.core_scope_assignments USING btree (id_core_roles);

--
-- Name: core_scope_assignments_role_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX core_scope_assignments_role_uq ON public.core_scope_assignments USING btree (id_core_scope_definitions, id_core_roles) WHERE ((id_core_roles IS NOT NULL) AND (deleted_at IS NULL));

--
-- Name: core_scope_assignments_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_assignments_user_idx ON public.core_scope_assignments USING btree (id_core_users);

--
-- Name: core_scope_assignments_user_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX core_scope_assignments_user_uq ON public.core_scope_assignments USING btree (id_core_scope_definitions, id_core_users) WHERE ((id_core_users IS NOT NULL) AND (deleted_at IS NULL));

--
-- Name: core_scope_definitions_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_definitions_active_idx ON public.core_scope_definitions USING btree (scope_key) WHERE ((deleted_at IS NULL) AND is_active);

--
-- Name: core_scope_definitions_module_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_definitions_module_idx ON public.core_scope_definitions USING btree (id_core_modules);

--
-- Name: core_scope_values_assignment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_scope_values_assignment_idx ON public.core_scope_values USING btree (id_core_scope_assignments);

--
-- Name: core_sequences_id_core_modules_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_sequences_id_core_modules_idx ON public.core_sequences USING btree (id_core_modules);

--
-- Name: core_sessions_device_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_sessions_device_key_idx ON public.core_sessions USING btree (device_key);

--
-- Name: core_sessions_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_sessions_id_core_users_idx ON public.core_sessions USING btree (id_core_users);

--
-- Name: core_sessions_is_valid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_sessions_is_valid_idx ON public.core_sessions USING btree (is_valid) WHERE is_valid;

--
-- Name: core_user_permissions_id_core_permissions_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_user_permissions_id_core_permissions_idx ON public.core_user_permissions USING btree (id_core_permissions);

--
-- Name: core_user_permissions_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_user_permissions_id_core_users_idx ON public.core_user_permissions USING btree (id_core_users);

--
-- Name: core_user_permissions_pair_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX core_user_permissions_pair_key ON public.core_user_permissions USING btree (id_core_users, id_core_permissions) WHERE (deleted_at IS NULL);

--
-- Name: core_users_roles_id_core_roles_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_users_roles_id_core_roles_idx ON public.core_users_roles USING btree (id_core_roles);

--
-- Name: core_users_roles_id_core_users_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX core_users_roles_id_core_users_idx ON public.core_users_roles USING btree (id_core_users);

--
-- Name: ix_core_agama_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_agama_status ON public.core_agama USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_auth_tokens_sweeper; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_auth_tokens_sweeper ON public.core_auth_tokens USING btree (berlaku_hingga);

--
-- Name: ix_core_auth_tokens_users; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_auth_tokens_users ON public.core_auth_tokens USING btree (id_core_users);

--
-- Name: ix_core_cluster_features_cm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_cluster_features_cm ON public.core_cluster_features USING btree (id_core_cluster_modules);

--
-- Name: ix_core_cluster_features_cmf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_cluster_features_cmf ON public.core_cluster_features USING btree (id_core_modules_features);

--
-- Name: ix_core_cluster_modules_cluster; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_cluster_modules_cluster ON public.core_cluster_modules USING btree (id_core_cluster);

--
-- Name: ix_core_cluster_modules_modul; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_cluster_modules_modul ON public.core_cluster_modules USING btree (id_core_modules);

--
-- Name: ix_core_cluster_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_cluster_status ON public.core_cluster USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_files_kategori; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_files_kategori ON public.core_files USING btree (id_core_media_categories) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_files_modul; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_files_modul ON public.core_files USING btree (id_core_modules) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kecamatan_kota; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kecamatan_kota ON public.core_kecamatan USING btree (id_core_kota) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kecamatan_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kecamatan_nama ON public.core_kecamatan USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kelurahan_kecamatan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kelurahan_kecamatan ON public.core_kelurahan USING btree (id_core_kecamatan) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kelurahan_kode_pos; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kelurahan_kode_pos ON public.core_kelurahan USING btree (kode_pos) WHERE ((deleted_at IS NULL) AND (kode_pos IS NOT NULL));

--
-- Name: ix_core_kelurahan_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kelurahan_nama ON public.core_kelurahan USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kota_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kota_nama ON public.core_kota USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_kota_provinsi; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_kota_provinsi ON public.core_kota USING btree (id_core_provinsi) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_mail_log_penerima; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_mail_log_penerima ON public.core_mail_log USING btree (penerima, created_at DESC);

--
-- Name: ix_core_mail_log_waktu; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_mail_log_waktu ON public.core_mail_log USING btree (created_at DESC);

--
-- Name: ix_core_media_categories_modul; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_media_categories_modul ON public.core_media_categories USING btree (id_core_modules) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_metode_bayar_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_metode_bayar_status ON public.core_metode_bayar USING btree (status) WHERE ((status = 'AKTIF'::public.enum_status_aktif) AND (deleted_at IS NULL));

--
-- Name: ix_core_provinsi_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_provinsi_nama ON public.core_provinsi USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_tenant_events_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_tenant_events_tenant ON public.core_tenant_events USING btree (id_core_tenants, created_at);

--
-- Name: ix_core_tenants_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_tenants_status ON public.core_tenants USING btree (status) WHERE (deleted_at IS NULL);

--
-- Name: ix_core_users_tenants_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_core_users_tenants_user ON public.core_users_tenants USING btree (id_core_users);

--
-- Name: ix_hr_karyawan_atasan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hr_karyawan_atasan ON public.hr_karyawan USING btree (id_hr_karyawan) WHERE (id_hr_karyawan IS NOT NULL);

--
-- Name: ix_hr_karyawan_departemen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hr_karyawan_departemen ON public.hr_karyawan USING btree (id_hr_departemen) WHERE (id_hr_departemen IS NOT NULL);

--
-- Name: ix_hr_karyawan_jabatan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hr_karyawan_jabatan ON public.hr_karyawan USING btree (id_hr_jabatan) WHERE (id_hr_jabatan IS NOT NULL);

--
-- Name: ix_hr_karyawan_link_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hr_karyawan_link_user ON public.hr_karyawan USING btree (id_core_users) WHERE (id_core_users IS NOT NULL);

--
-- Name: ix_hr_karyawan_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hr_karyawan_status ON public.hr_karyawan USING btree (status);

--
-- Name: uq_core_agama_code_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_agama_code_hidup ON public.core_agama USING btree (code) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_auth_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_auth_tokens_hash ON public.core_auth_tokens USING btree (token_hash);

--
-- Name: uq_core_cluster_code_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_cluster_code_hidup ON public.core_cluster USING btree (code) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_cluster_features_pair_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_cluster_features_pair_hidup ON public.core_cluster_features USING btree (id_core_cluster_modules, id_core_modules_features) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_cluster_modules_pair_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_cluster_modules_pair_hidup ON public.core_cluster_modules USING btree (id_core_cluster, id_core_modules) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_kecamatan_kode_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_kecamatan_kode_hidup ON public.core_kecamatan USING btree (kode) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_kelurahan_kode_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_kelurahan_kode_hidup ON public.core_kelurahan USING btree (kode) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_kota_kode_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_kota_kode_hidup ON public.core_kota USING btree (kode) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_media_categories_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_media_categories_nama ON public.core_media_categories USING btree (COALESCE(id_core_modules, (0)::bigint), nama) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_metode_bayar_kode; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_metode_bayar_kode ON public.core_metode_bayar USING btree (kode) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_metode_bayar_nama; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_metode_bayar_nama ON public.core_metode_bayar USING btree (nama) WHERE (deleted_at IS NULL);

--
-- Name: uq_core_provinsi_kode_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_core_provinsi_kode_hidup ON public.core_provinsi USING btree (kode) WHERE (deleted_at IS NULL);

--
-- Name: uq_hr_karyawan_nik_hidup; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_hr_karyawan_nik_hidup ON public.hr_karyawan USING btree (nik_pegawai) WHERE (deleted_at IS NULL);

--
-- Name: uq_outbox_topic_key_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_outbox_topic_key_pending ON public.core_outbox_events USING btree (topic, COALESCE((payload ->> '_key'::text), ''::text)) WHERE ((status = ANY (ARRAY['pending'::public.core_outbox_status, 'delivered'::public.core_outbox_status])) AND (payload ? '_key'::text));

--
-- Name: core_agama trg_core_agama_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_agama_updated_at BEFORE UPDATE ON public.core_agama FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_cluster_features trg_core_cluster_features_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_cluster_features_updated_at BEFORE UPDATE ON public.core_cluster_features FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_cluster_modules trg_core_cluster_modules_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_cluster_modules_updated_at BEFORE UPDATE ON public.core_cluster_modules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_cluster trg_core_cluster_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_cluster_updated_at BEFORE UPDATE ON public.core_cluster FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_kecamatan trg_core_kecamatan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_kecamatan_updated_at BEFORE UPDATE ON public.core_kecamatan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_kelurahan trg_core_kelurahan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_kelurahan_updated_at BEFORE UPDATE ON public.core_kelurahan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_kota trg_core_kota_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_kota_updated_at BEFORE UPDATE ON public.core_kota FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_metode_bayar trg_core_metode_bayar_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_metode_bayar_updated_at BEFORE UPDATE ON public.core_metode_bayar FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_provinsi trg_core_provinsi_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_provinsi_updated_at BEFORE UPDATE ON public.core_provinsi FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_tenant_events trg_core_tenant_events_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_tenant_events_updated_at BEFORE UPDATE ON public.core_tenant_events FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_tenant_features trg_core_tenant_features_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_tenant_features_updated_at BEFORE UPDATE ON public.core_tenant_features FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_tenant_modules trg_core_tenant_modules_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_tenant_modules_updated_at BEFORE UPDATE ON public.core_tenant_modules FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_tenant_settings trg_core_tenant_settings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_tenant_settings_updated_at BEFORE UPDATE ON public.core_tenant_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_tenants trg_core_tenants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_tenants_updated_at BEFORE UPDATE ON public.core_tenants FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_users_tenants trg_core_users_tenants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_core_users_tenants_updated_at BEFORE UPDATE ON public.core_users_tenants FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: hr_karyawan trg_hr_karyawan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_hr_karyawan_updated_at BEFORE UPDATE ON public.hr_karyawan FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

--
-- Name: core_approval_limits core_approval_limits_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_approval_limits
    ADD CONSTRAINT core_approval_limits_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_approval_limits core_approval_limits_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_approval_limits
    ADD CONSTRAINT core_approval_limits_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_approval_limits core_approval_limits_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_approval_limits
    ADD CONSTRAINT core_approval_limits_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_audit_trail core_audit_trail_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_audit_trail
    ADD CONSTRAINT core_audit_trail_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_audit_trail core_audit_trail_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_audit_trail
    ADD CONSTRAINT core_audit_trail_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_data_scopes core_data_scopes_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_scopes
    ADD CONSTRAINT core_data_scopes_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON DELETE CASCADE;

--
-- Name: core_data_scopes core_data_scopes_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_data_scopes
    ADD CONSTRAINT core_data_scopes_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE CASCADE;

--
-- Name: core_files core_files_id_core_media_categories_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_id_core_media_categories_fkey FOREIGN KEY (id_core_media_categories) REFERENCES public.core_media_categories(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_files core_files_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_files core_files_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_files
    ADD CONSTRAINT core_files_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_ip_allowlist core_ip_allowlist_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_ip_allowlist core_ip_allowlist_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_login_audit core_login_audit_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_login_audit
    ADD CONSTRAINT core_login_audit_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_media_categories core_media_categories_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_media_categories
    ADD CONSTRAINT core_media_categories_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_menus core_menus_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_menus
    ADD CONSTRAINT core_menus_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_menus core_menus_parent_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_menus
    ADD CONSTRAINT core_menus_parent_fkey FOREIGN KEY (parent) REFERENCES public.core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_module_configs core_module_configs_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_module_configs
    ADD CONSTRAINT core_module_configs_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_module_configs core_module_configs_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_module_configs
    ADD CONSTRAINT core_module_configs_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_modules_features core_modules_features_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules_features
    ADD CONSTRAINT core_modules_features_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_modules_features core_modules_features_id_core_users_activated_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules_features
    ADD CONSTRAINT core_modules_features_id_core_users_activated_fkey FOREIGN KEY (id_core_users_activated) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_modules_features core_modules_features_id_core_users_deactivated_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_modules_features
    ADD CONSTRAINT core_modules_features_id_core_users_deactivated_fkey FOREIGN KEY (id_core_users_deactivated) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_password_history core_password_history_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_password_history
    ADD CONSTRAINT core_password_history_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_permissions core_permissions_id_core_modules_features_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_id_core_modules_features_fkey FOREIGN KEY (id_core_modules_features) REFERENCES public.core_modules_features(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_permissions core_permissions_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_permissions_routes core_permissions_routes_id_core_permissions_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_permissions_routes core_permissions_routes_id_core_routes_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_id_core_routes_fkey FOREIGN KEY (id_core_routes) REFERENCES public.core_routes(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_role_permissions core_role_permissions_id_core_permissions_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_role_permissions core_role_permissions_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_roles_menus core_roles_menus_id_core_menus_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles_menus
    ADD CONSTRAINT core_roles_menus_id_core_menus_fkey FOREIGN KEY (id_core_menus) REFERENCES public.core_menus(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_roles_menus core_roles_menus_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_roles_menus
    ADD CONSTRAINT core_roles_menus_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_routes core_routes_id_core_modules_features_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_routes
    ADD CONSTRAINT core_routes_id_core_modules_features_fkey FOREIGN KEY (id_core_modules_features) REFERENCES public.core_modules_features(id) ON UPDATE CASCADE ON DELETE SET NULL;

--
-- Name: core_scope_assignments core_scope_assignments_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_assignments
    ADD CONSTRAINT core_scope_assignments_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE CASCADE;

--
-- Name: core_scope_assignments core_scope_assignments_id_core_scope_definitions_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_assignments
    ADD CONSTRAINT core_scope_assignments_id_core_scope_definitions_fkey FOREIGN KEY (id_core_scope_definitions) REFERENCES public.core_scope_definitions(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_scope_assignments core_scope_assignments_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_assignments
    ADD CONSTRAINT core_scope_assignments_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE CASCADE;

--
-- Name: core_scope_definitions core_scope_definitions_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_definitions
    ADD CONSTRAINT core_scope_definitions_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_scope_values core_scope_values_id_core_scope_assignments_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_scope_values
    ADD CONSTRAINT core_scope_values_id_core_scope_assignments_fkey FOREIGN KEY (id_core_scope_assignments) REFERENCES public.core_scope_assignments(id) ON UPDATE CASCADE ON DELETE CASCADE;

--
-- Name: core_sequences core_sequences_id_core_modules_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_sequences
    ADD CONSTRAINT core_sequences_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_sessions core_sessions_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_sessions
    ADD CONSTRAINT core_sessions_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_user_mfa core_user_mfa_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_mfa
    ADD CONSTRAINT core_user_mfa_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_user_permissions core_user_permissions_id_core_permissions_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_user_permissions core_user_permissions_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_user_permissions core_user_permissions_id_core_users_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_users_granted_by_fkey FOREIGN KEY (id_core_users_granted_by) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_users_roles core_users_roles_id_core_roles_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_roles
    ADD CONSTRAINT core_users_roles_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_users_roles core_users_roles_id_core_users_assigned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_roles
    ADD CONSTRAINT core_users_roles_id_core_users_assigned_by_fkey FOREIGN KEY (id_core_users_assigned_by) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_users_roles core_users_roles_id_core_users_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_roles
    ADD CONSTRAINT core_users_roles_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: core_auth_tokens fk_core_auth_tokens_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_auth_tokens
    ADD CONSTRAINT fk_core_auth_tokens_users FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE CASCADE;

--
-- Name: core_cluster_features fk_core_cluster_features_cm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_features
    ADD CONSTRAINT fk_core_cluster_features_cm FOREIGN KEY (id_core_cluster_modules) REFERENCES public.core_cluster_modules(id) ON DELETE CASCADE;

--
-- Name: core_cluster_features fk_core_cluster_features_cmf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_features
    ADD CONSTRAINT fk_core_cluster_features_cmf FOREIGN KEY (id_core_modules_features) REFERENCES public.core_modules_features(id) ON DELETE CASCADE;

--
-- Name: core_cluster_modules fk_core_cluster_modules_cluster; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_modules
    ADD CONSTRAINT fk_core_cluster_modules_cluster FOREIGN KEY (id_core_cluster) REFERENCES public.core_cluster(id) ON DELETE CASCADE;

--
-- Name: core_cluster_modules fk_core_cluster_modules_modul; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_cluster_modules
    ADD CONSTRAINT fk_core_cluster_modules_modul FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON DELETE CASCADE;

--
-- Name: core_kecamatan fk_core_kecamatan_kota; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kecamatan
    ADD CONSTRAINT fk_core_kecamatan_kota FOREIGN KEY (id_core_kota) REFERENCES public.core_kota(id) ON DELETE RESTRICT;

--
-- Name: core_kelurahan fk_core_kelurahan_kecamatan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kelurahan
    ADD CONSTRAINT fk_core_kelurahan_kecamatan FOREIGN KEY (id_core_kecamatan) REFERENCES public.core_kecamatan(id) ON DELETE RESTRICT;

--
-- Name: core_kota fk_core_kota_provinsi; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_kota
    ADD CONSTRAINT fk_core_kota_provinsi FOREIGN KEY (id_core_provinsi) REFERENCES public.core_provinsi(id) ON DELETE RESTRICT;

--
-- Name: core_mail_log fk_core_mail_log_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_mail_log
    ADD CONSTRAINT fk_core_mail_log_users FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: core_tenant_events fk_core_tenant_events_tenants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_events
    ADD CONSTRAINT fk_core_tenant_events_tenants FOREIGN KEY (id_core_tenants) REFERENCES public.core_tenants(id) ON DELETE RESTRICT;

--
-- Name: core_tenant_events fk_core_tenant_events_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_events
    ADD CONSTRAINT fk_core_tenant_events_users FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE SET NULL;

--
-- Name: core_tenant_features fk_core_tenant_features_modules_features; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_features
    ADD CONSTRAINT fk_core_tenant_features_modules_features FOREIGN KEY (id_core_modules_features) REFERENCES public.core_modules_features(id) ON DELETE RESTRICT;

--
-- Name: core_tenant_features fk_core_tenant_features_tenants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_features
    ADD CONSTRAINT fk_core_tenant_features_tenants FOREIGN KEY (id_core_tenants) REFERENCES public.core_tenants(id) ON DELETE RESTRICT;

--
-- Name: core_tenant_modules fk_core_tenant_modules_modules; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_modules
    ADD CONSTRAINT fk_core_tenant_modules_modules FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON DELETE RESTRICT;

--
-- Name: core_tenant_modules fk_core_tenant_modules_tenants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_modules
    ADD CONSTRAINT fk_core_tenant_modules_tenants FOREIGN KEY (id_core_tenants) REFERENCES public.core_tenants(id) ON DELETE RESTRICT;

--
-- Name: core_tenant_settings fk_core_tenant_settings_tenants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_tenant_settings
    ADD CONSTRAINT fk_core_tenant_settings_tenants FOREIGN KEY (id_core_tenants) REFERENCES public.core_tenants(id) ON DELETE RESTRICT;

--
-- Name: core_users_tenants fk_core_users_tenants_tenants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_tenants
    ADD CONSTRAINT fk_core_users_tenants_tenants FOREIGN KEY (id_core_tenants) REFERENCES public.core_tenants(id) ON DELETE RESTRICT;

--
-- Name: core_users_tenants fk_core_users_tenants_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.core_users_tenants
    ADD CONSTRAINT fk_core_users_tenants_users FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE RESTRICT;

--
-- Name: hr_karyawan fk_hr_karyawan_atasan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hr_karyawan
    ADD CONSTRAINT fk_hr_karyawan_atasan FOREIGN KEY (id_hr_karyawan) REFERENCES public.hr_karyawan(id) ON DELETE SET NULL;

--
-- Name: hr_karyawan fk_hr_karyawan_link_user; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hr_karyawan
    ADD CONSTRAINT fk_hr_karyawan_link_user FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON DELETE SET NULL;
