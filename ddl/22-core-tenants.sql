-- =============================================================================
-- PATCH DDL 22-core-tenants.sql — Registry tenant (Opsi C)
-- Domain   : OdooLikeERP (single tenant, konfigurable, Profil Skala PS1/PS2/PS3)
--            → multi-tenant registry Opsi C; tabel bisnis BELUM disentuh
-- Sumber   : kontrak fitur tenant management (registry tenant, keanggotaan,
--            modul/fitur aktif per tenant, setting, event siklus hidup)
-- Kartu    : docs/arsitektur-database-core-inv.md
-- Idempoten: aman dijalankan berulang (enum DO-block, IF NOT EXISTS, trigger DO-block)
-- Catatan  : modul/fitur direferensikan dari registry v2 (core_modules,
--            core_modules_features) — bukan core_modul skema 01; FK ke
--            core_users merujuk tabel pengguna yang sudah ada di 01-core.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enum (kosakata kontrak tenant management)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_paket_tier AS ENUM ('PS1', 'PS2', 'PS3');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_tenant AS ENUM ('PROVISI', 'AKTIF', 'DITANGGUHKAN', 'DITUTUP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- core_tenants — registry tenant [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_tenants (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  kode           varchar(50) NOT NULL,            -- slug lowercase; tak pernah dipakai ulang
  nama           varchar(100) NOT NULL,
  paket_tier     enum_paket_tier NOT NULL DEFAULT 'PS2',
  status         enum_status_tenant NOT NULL DEFAULT 'PROVISI',
  max_users      int,                             -- NULL = tak terbatas
  max_lokasi     int,                             -- NULL = tak terbatas
  kontak_email   varchar(150),
  kontak_telepon varchar(50),
  versi_skema    int NOT NULL DEFAULT 1,          -- posisi patch DDL skema bisnis tenant
  version        int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_core_tenants_entity_id UNIQUE (entity_id),
  -- global: kode tenant tak pernah dipakai ulang (identitas antar tenant)
  CONSTRAINT uq_core_tenants_kode UNIQUE (kode),
  CONSTRAINT ck_core_tenants_kode_lower CHECK (kode::text = lower(kode::text)),
  CONSTRAINT ck_core_tenants_kuota
    CHECK ((max_users IS NULL OR max_users >= 0) AND (max_lokasi IS NULL OR max_lokasi >= 0))
);

CREATE INDEX IF NOT EXISTS ix_core_tenants_status
  ON core_tenants (status) WHERE deleted_at IS NULL;

COMMENT ON TABLE core_tenants IS
  'registry tenant Opsi C — master identitas, paket & kuota tenant;'
  'belum menyentuh tabel bisnis (patch aditif murni)';
COMMENT ON COLUMN core_tenants.kode IS
  'slug lowercase unik global — tak pernah dipakai ulang setelah tenant ditutup;'
  'satuan kebenaran subdomain/host per tenant';
COMMENT ON COLUMN core_tenants.paket_tier IS
  'Profil Skala langganan — PS1/PS2/PS3; menentukan kuota default via SET_TIER';
COMMENT ON COLUMN core_tenants.status IS
  'siklus hidup tenant: PROVISI → AKTIF → DITANGGUHKAN/DITUTUP;'
  'perubahan status wajib menulis core_tenant_events';
COMMENT ON COLUMN core_tenants.versi_skema IS
  'posisi patch DDL skema bisnis tenant — dipakai jalur migrasi per-tenant';

-- -----------------------------------------------------------------------------
-- core_users_tenants — keanggotaan user ↔ tenant [JUNCTION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_users_tenants (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_tenants bigint NOT NULL,
  id_core_users   bigint NOT NULL,
  is_default      boolean NOT NULL DEFAULT false, -- tenant default saat login multi-tenant
  dicabut_pada    timestamptz,                    -- status bisnis dicabut (≠ deleted_at)
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  -- penuh (bukan partial): re-aktif keanggotaan = UPDATE baris lama, bukan INSERT baru
  CONSTRAINT uq_core_users_tenants UNIQUE (id_core_tenants, id_core_users),
  CONSTRAINT fk_core_users_tenants_tenants FOREIGN KEY (id_core_tenants)
    REFERENCES core_tenants (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_users_tenants_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_core_users_tenants_user
  ON core_users_tenants (id_core_users);

-- -----------------------------------------------------------------------------
-- core_tenant_modules — modul aktif per tenant [JUNCTION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_tenant_modules (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_tenants bigint NOT NULL,
  id_core_modules bigint NOT NULL,                -- registry modul v2
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_tenant_modules UNIQUE (id_core_tenants, id_core_modules),
  CONSTRAINT fk_core_tenant_modules_tenants FOREIGN KEY (id_core_tenants)
    REFERENCES core_tenants (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_tenant_modules_modules FOREIGN KEY (id_core_modules)
    REFERENCES core_modules (id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- core_tenant_features — fitur aktif per tenant [JUNCTION]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_tenant_features (
  id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_tenants          bigint NOT NULL,
  id_core_modules_features bigint NOT NULL,       -- registry fitur per modul v2
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  deleted_at               timestamptz,
  CONSTRAINT uq_core_tenant_features UNIQUE (id_core_tenants, id_core_modules_features),
  CONSTRAINT fk_core_tenant_features_tenants FOREIGN KEY (id_core_tenants)
    REFERENCES core_tenants (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_tenant_features_modules_features FOREIGN KEY (id_core_modules_features)
    REFERENCES core_modules_features (id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- core_tenant_settings — setting key-value per tenant [CONFIG]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_tenant_settings (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_tenants bigint NOT NULL,
  kategori        varchar(100) NOT NULL,          -- mis. 'invoice', 'keamanan'
  kunci           varchar(100) NOT NULL,
  nilai           jsonb NOT NULL DEFAULT '{}'::jsonb,  -- struktur bebas; tafsir di service
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_core_tenant_settings UNIQUE (id_core_tenants, kategori, kunci),
  CONSTRAINT fk_core_tenant_settings_tenants FOREIGN KEY (id_core_tenants)
    REFERENCES core_tenants (id) ON DELETE RESTRICT
);

-- -----------------------------------------------------------------------------
-- core_tenant_events — event siklus hidup tenant [LOG/EVENT] append-only
-- aksi: PROVISI/SUSPEND/REAKTIVASI/TUTUP/SET_TIER/SET_MODUL/SET_FITUR/
--       SET_ANGGOTA/SET_PENGATURAN
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_tenant_events (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_core_tenants bigint NOT NULL,
  aksi            varchar(100) NOT NULL,
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- snapshot sebelum/sesudah; tidak difilter
  id_core_users   bigint,                         -- aktor; NULL = [sistem]
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),  -- tetap ada demi keseragaman skema (beku di log)
  deleted_at      timestamptz,                         -- selalu NULL (append-only)
  CONSTRAINT fk_core_tenant_events_tenants FOREIGN KEY (id_core_tenants)
    REFERENCES core_tenants (id) ON DELETE RESTRICT,
  CONSTRAINT fk_core_tenant_events_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_core_tenant_events_tenant
  ON core_tenant_events (id_core_tenants, created_at);

-- -----------------------------------------------------------------------------
-- Trigger updated_at — semua tabel tenant registry (D-04; set_updated_at di 01-core)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'core_tenants','core_users_tenants','core_tenant_modules',
    'core_tenant_features','core_tenant_settings','core_tenant_events'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- PATCH 22-core-tenants.sql selesai.
