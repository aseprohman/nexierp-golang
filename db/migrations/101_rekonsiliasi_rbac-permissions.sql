-- +goose Up
-- ============================================================================
-- MIGRASI REKONSILIASI: 101_rekonsiliasi_rbac-permissions.sql
-- APA    : membuat objek LIVE-ONLY: core_permissions, core_permissions_routes, core_role_permissions, core_user_permissions, core_user_mfa, core_password_history, core_ip_allowlist, core_login_audit
--          RBAC inti Drizzle live (permissions, peta route, peran, override user, MFA, password history, ip allowlist, login audit)
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
  CREATE TYPE public.core_login_fail_reason AS ENUM (
    'unknown_user',
    'wrong_password',
    'locked',
    'inactive',
    'mfa_failed'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.core_mfa_method AS ENUM (
    'totp'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- enum dipakai kolom tabel live-only ini (kosakata persis live)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE public.core_permission_status AS ENUM (
    'active',
    'disabled'
);
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- TABEL (IF NOT EXISTS, kolom persis live) ----
CREATE TABLE IF NOT EXISTS public.core_permissions (
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

CREATE TABLE IF NOT EXISTS public.core_permissions_routes (
    id bigint NOT NULL,
    id_core_routes bigint NOT NULL,
    id_core_permissions bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.core_role_permissions (
    id bigint NOT NULL,
    id_core_roles bigint NOT NULL,
    id_core_permissions bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.core_user_permissions (
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

CREATE TABLE IF NOT EXISTS public.core_user_mfa (
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

CREATE TABLE IF NOT EXISTS public.core_password_history (
    id bigint NOT NULL,
    id_core_users bigint NOT NULL,
    user_name character varying(42) NOT NULL,
    set_at timestamp with time zone NOT NULL,
    masked_hash character varying(105) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.core_ip_allowlist (
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

CREATE TABLE IF NOT EXISTS public.core_login_audit (
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

-- kolom identity (persis live; setelah tabel, dilewati bila sudah identity)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='core_permissions'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_permissions_id_seq
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
                 WHERE table_schema='public' AND table_name='core_permissions_routes'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_permissions_routes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_permissions_routes_id_seq
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
                 WHERE table_schema='public' AND table_name='core_role_permissions'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_role_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_role_permissions_id_seq
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
                 WHERE table_schema='public' AND table_name='core_user_permissions'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_user_permissions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_user_permissions_id_seq
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
                 WHERE table_schema='public' AND table_name='core_password_history'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_password_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_password_history_id_seq
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
                 WHERE table_schema='public' AND table_name='core_ip_allowlist'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_ip_allowlist ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_ip_allowlist_id_seq
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
                 WHERE table_schema='public' AND table_name='core_login_audit'
                   AND column_name='id' AND is_identity='YES') THEN
    ALTER TABLE public.core_login_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.core_login_audit_id_seq
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
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_pkey'
                 AND conrelid = 'public.core_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_id_core_modules_features_fkey'
                 AND conrelid = 'public.core_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_id_core_modules_features_fkey FOREIGN KEY (id_core_modules_features) REFERENCES public.core_modules_features(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_id_core_modules_fkey'
                 AND conrelid = 'public.core_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions
    ADD CONSTRAINT core_permissions_id_core_modules_fkey FOREIGN KEY (id_core_modules) REFERENCES public.core_modules(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_routes_pair_key'
                 AND conrelid = 'public.core_permissions_routes'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_pair_key UNIQUE (id_core_routes, id_core_permissions);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_routes_pkey'
                 AND conrelid = 'public.core_permissions_routes'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_routes_id_core_permissions_fkey'
                 AND conrelid = 'public.core_permissions_routes'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_permissions_routes_id_core_routes_fkey'
                 AND conrelid = 'public.core_permissions_routes'::regclass) THEN
    ALTER TABLE ONLY public.core_permissions_routes
    ADD CONSTRAINT core_permissions_routes_id_core_routes_fkey FOREIGN KEY (id_core_routes) REFERENCES public.core_routes(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_role_permissions_pair_key'
                 AND conrelid = 'public.core_role_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_pair_key UNIQUE (id_core_roles, id_core_permissions);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_role_permissions_pkey'
                 AND conrelid = 'public.core_role_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_role_permissions_id_core_permissions_fkey'
                 AND conrelid = 'public.core_role_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_role_permissions_id_core_roles_fkey'
                 AND conrelid = 'public.core_role_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_role_permissions
    ADD CONSTRAINT core_role_permissions_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_permissions_pkey'
                 AND conrelid = 'public.core_user_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_permissions_id_core_permissions_fkey'
                 AND conrelid = 'public.core_user_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_permissions_fkey FOREIGN KEY (id_core_permissions) REFERENCES public.core_permissions(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_permissions_id_core_users_fkey'
                 AND conrelid = 'public.core_user_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_permissions_id_core_users_granted_by_fkey'
                 AND conrelid = 'public.core_user_permissions'::regclass) THEN
    ALTER TABLE ONLY public.core_user_permissions
    ADD CONSTRAINT core_user_permissions_id_core_users_granted_by_fkey FOREIGN KEY (id_core_users_granted_by) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_mfa_pkey'
                 AND conrelid = 'public.core_user_mfa'::regclass) THEN
    ALTER TABLE ONLY public.core_user_mfa
    ADD CONSTRAINT core_user_mfa_pkey PRIMARY KEY (id_core_users);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_user_mfa_id_core_users_fkey'
                 AND conrelid = 'public.core_user_mfa'::regclass) THEN
    ALTER TABLE ONLY public.core_user_mfa
    ADD CONSTRAINT core_user_mfa_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_password_history_pkey'
                 AND conrelid = 'public.core_password_history'::regclass) THEN
    ALTER TABLE ONLY public.core_password_history
    ADD CONSTRAINT core_password_history_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_password_history_id_core_users_fkey'
                 AND conrelid = 'public.core_password_history'::regclass) THEN
    ALTER TABLE ONLY public.core_password_history
    ADD CONSTRAINT core_password_history_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_ip_allowlist_pkey'
                 AND conrelid = 'public.core_ip_allowlist'::regclass) THEN
    ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_ip_allowlist_id_core_roles_fkey'
                 AND conrelid = 'public.core_ip_allowlist'::regclass) THEN
    ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_id_core_roles_fkey FOREIGN KEY (id_core_roles) REFERENCES public.core_roles(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_ip_allowlist_id_core_users_fkey'
                 AND conrelid = 'public.core_ip_allowlist'::regclass) THEN
    ALTER TABLE ONLY public.core_ip_allowlist
    ADD CONSTRAINT core_ip_allowlist_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_login_audit_pkey'
                 AND conrelid = 'public.core_login_audit'::regclass) THEN
    ALTER TABLE ONLY public.core_login_audit
    ADD CONSTRAINT core_login_audit_pkey PRIMARY KEY (id);
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'core_login_audit_id_core_users_fkey'
                 AND conrelid = 'public.core_login_audit'::regclass) THEN
    ALTER TABLE ONLY public.core_login_audit
    ADD CONSTRAINT core_login_audit_id_core_users_fkey FOREIGN KEY (id_core_users) REFERENCES public.core_users(id) ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; WHEN duplicate_table THEN NULL; END $$;
-- +goose StatementEnd


-- ---- INDEX (persis live; IF NOT EXISTS) ----
CREATE INDEX IF NOT EXISTS core_permissions_id_core_modules_features_idx ON public.core_permissions USING btree (id_core_modules_features);

CREATE INDEX IF NOT EXISTS core_permissions_id_core_modules_idx ON public.core_permissions USING btree (id_core_modules);

CREATE INDEX IF NOT EXISTS core_permissions_routes_id_core_permissions_idx ON public.core_permissions_routes USING btree (id_core_permissions);

CREATE INDEX IF NOT EXISTS core_permissions_routes_id_core_routes_idx ON public.core_permissions_routes USING btree (id_core_routes);

CREATE INDEX IF NOT EXISTS core_role_permissions_id_core_permissions_idx ON public.core_role_permissions USING btree (id_core_permissions);

CREATE INDEX IF NOT EXISTS core_role_permissions_id_core_roles_idx ON public.core_role_permissions USING btree (id_core_roles);

CREATE INDEX IF NOT EXISTS core_user_permissions_id_core_permissions_idx ON public.core_user_permissions USING btree (id_core_permissions);

CREATE INDEX IF NOT EXISTS core_user_permissions_id_core_users_idx ON public.core_user_permissions USING btree (id_core_users);

CREATE UNIQUE INDEX IF NOT EXISTS core_user_permissions_pair_key ON public.core_user_permissions USING btree (id_core_users, id_core_permissions) WHERE (deleted_at IS NULL);

CREATE INDEX IF NOT EXISTS core_password_history_id_core_users_idx ON public.core_password_history USING btree (id_core_users);

CREATE INDEX IF NOT EXISTS core_ip_allowlist_id_core_roles_idx ON public.core_ip_allowlist USING btree (id_core_roles);

CREATE INDEX IF NOT EXISTS core_ip_allowlist_id_core_users_idx ON public.core_ip_allowlist USING btree (id_core_users);

CREATE INDEX IF NOT EXISTS core_login_audit_attempted_at_idx ON public.core_login_audit USING btree (attempted_at);

CREATE INDEX IF NOT EXISTS core_login_audit_id_core_users_idx ON public.core_login_audit USING btree (id_core_users);