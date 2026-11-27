-- =============================================================================
-- PATCH DDL 87-ai.sql — Modul AI (AI LLM PROVIDER) + PEMINDAHAN
--                       PERSONA/PENGETAHUAN DARI WA
-- =============================================================================
-- Domain   : NEXIERP · Modul AI — infrastruktur LLM multi-vendor platform:
--            konfigurasi provider & secret key, model + budget bulanan DALAM
--            UANG, harga resmi input/cache/output per model (moderasi biaya),
--            ledger biaya pemakaian (biaya akhir = harga resmi × faktor
--            markup, default ×3 — CFG-AI-01), serta kepemilikan BARU persona
--            & basis pengetahuan (pindah dari modul WA).
--            TANPA VENDOR SIMULATOR (keputusan pemilik 2026-11-23 — pola SHP:
--            vendor wajib live API; adapter simulator = perilaku adapter
--            pemanggil, bukan baris master). Vendor: openai, anthropic,
--            google, deepseek, zai (Z.AI/Zhipu — seluruh model GLM via API).
-- Kartu    : docs/arsitektur-database-ai.md (gerbang arsitektur-database).
-- Tanggal  : 2026-11-23
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at,
--            enum_status_aktif, core_files, core_modules, core_module_configs)
--            + modul WA 66-wa (wa_persona/wa_pengetahuan/wa_instance yang
--            dimigrasi — bila tabel WA belum ada, patch tetap jalan: bagian
--            migrasi lewat guard NOTICE).
-- Isi      : 6 tabel ai_* — 5 MASTER (provider, model, model_harga, persona,
--            pengetahuan) + 1 LOG/EVENT (pemakaian) + 3 enum enum_*_ai +
--            trigger set_updated_at 6 tabel + migrasi data wa_persona→
--            ai_persona & wa_pengetahuan→ai_pengetahuan (id/entity_id
--            dipertahankan) + rename FK wa_instance (id_wa_persona→
--            id_ai_persona → ai_persona) + DROP tabel WA lama + registry
--            core_modules key='ai-llm' (ALTER TYPE §0) + CFG-AI-01/02.
-- Integrasi: FK keluar baca-saja — id_core_files (lampiran pengetahuan,
--            SET NULL). wa_instance menaut persona AI via FK lintas modul
--            baca (pola wa_kontak→sls_pelanggan). Modul AI tidak pernah
--            menulis tabel modul lain; pemanggil LLM (WA, dll) kelak menulis
--            ai_pemakaian via layanan modul AI (sumber + entity_id_sumber).
--            Tanpa core_sequences (tidak ada dokumen berpenomoran).
-- Idempoten: ALTER TYPE ADD VALUE IF NOT EXISTS di LUAR transaksi (PG melarang
--            pemakaian nilai enum baru pada transaksi yang sama saat
--            ditambahkan — pola 75-wf); enum DO-block duplicate_object
--            fail-loud bila kosakata menyimpang; CREATE TABLE IF NOT EXISTS;
--            FK/check bernama eksplisit; CREATE INDEX IF NOT EXISTS; trigger
--            DO-block DROP+CREATE; migrasi ter-guard to_regclass (kali-2 =
--            skip NOTICE); CFG ON CONFLICT DO NOTHING.
-- Catatan  : uang numeric(18,4); HARGA per 1M token numeric(18,6) (presisi
--            harga vendor); teks bucket varchar 50/100/150/200/300; kolom
--            persona/pengetahuan prosa = text (pengecualian tipe teks
--            disepakati — konten prompt bebas); LOG/EVENT append-only
--            (updated_at beku, deleted_at selalu NULL, tanpa version);
--            token INTERNAL di DB untuk kalkulasi/audit — API/FE hanya
--            mengekspos nilai uang (keputusan pemilik 2026-11-23);
--            faktor_markup di-SNAPSHOT per baris log (perubahan config tidak
--            mengubah histori); seed master provider/model/harga resmi =
--            podman/seed-ai-core.sql — di luar patch ini.
-- =============================================================================

-- =============================================================================
-- §0 ENUM REGISTRY — nilai 'ai-llm' di luar transaksi (pola 75-wf-registry)
-- =============================================================================

ALTER TYPE core_module_key ADD VALUE IF NOT EXISTS 'ai-llm';

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'core_module_key' AND e.enumlabel = 'ai-llm'
  ) THEN
    RAISE EXCEPTION 'PATCH 87: nilai enum ''ai-llm'' gagal ditambahkan';
  END IF;
END $$;

-- =============================================================================
-- §1 ENUM — 3 tipe baru (fail-loud bila kosakata menyimpang dari mirror)
-- =============================================================================

BEGIN;

DO $$ BEGIN
  CREATE TYPE enum_environment_ai AS ENUM ('SANDBOX','PRODUKSI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_environment_ai')
     IS DISTINCT FROM ARRAY['SANDBOX','PRODUKSI']::text[] THEN
    RAISE EXCEPTION 'PATCH 87-ai: enum_environment_ai kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_konfigurasi_ai AS ENUM ('DRAFT','DIUJI','AKTIF','DINONAKTIFKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_konfigurasi_ai')
     IS DISTINCT FROM ARRAY['DRAFT','DIUJI','AKTIF','DINONAKTIFKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 87-ai: enum_status_konfigurasi_ai kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_hasil_panggilan_ai AS ENUM ('BERHASIL','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_panggilan_ai')
     IS DISTINCT FROM ARRAY['BERHASIL','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 87-ai: enum_hasil_panggilan_ai kosakata menyimpang dari mirror';
  END IF;
END $$;

-- =============================================================================
-- §2 TABEL MASTER — urutan dependensi FK (provider → model → harga;
--    persona/pengetahuan mandiri; pemakaian paling akhir)
-- =============================================================================

-- [MASTER] Vendor LLM (openai/anthropic/google/deepseek/zai) — konfigurasi
-- koneksi + secret key. api_key TERENKRIPSI app-layer AES-256-GCM (pola
-- PGW-BR01/WA-BR08 — plaintext tidak pernah sampai ke DB); tanpa vendor
-- simulator (keputusan pemilik 2026-11-23).
CREATE TABLE IF NOT EXISTS ai_provider (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode        varchar(50) NOT NULL,
  nama        varchar(100) NOT NULL,
  environment enum_environment_ai NOT NULL DEFAULT 'PRODUKSI',
  base_url    varchar(300),
  api_key     varchar(300),
  status      enum_status_konfigurasi_ai NOT NULL DEFAULT 'DRAFT',
  keterangan  varchar(300),
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  CONSTRAINT uq_ai_provider_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_provider_kode_hidup ON ai_provider (kode) WHERE deleted_at IS NULL;

COMMENT ON TABLE ai_provider IS
  'MASTER vendor LLM multi-provider + secret key (terenkrripsi app-layer) — modul AI; siklus DRAFT→DIUJI→AKTIF pola pgw_konfigurasi_vendor; tanpa vendor simulator (keputusan pemilik 2026-11-23).';

CREATE INDEX IF NOT EXISTS ix_ai_provider_status
  ON ai_provider (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Model LLM per provider — budget bulanan DALAM UANG (bukan token).
-- budget NULL = tanpa batas; realisasi = SUM(ai_pemakaian.biaya) per bulan
-- kalendar (index pemakaian (id_ai_model, waktu)); guard budget app-layer
-- sebelum panggilan (biaya baru diketahui pasca-respons vendor).
CREATE TABLE IF NOT EXISTS ai_model (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ai_provider bigint NOT NULL,
  kode           varchar(100) NOT NULL,
  nama           varchar(100) NOT NULL,
  konteks_window integer,
  max_output     integer,
  budget_bulanan numeric(18,2),
  mata_uang      varchar(50) NOT NULL DEFAULT 'USD',
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  keterangan     varchar(300),
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_ai_model_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ai_model_provider FOREIGN KEY (id_ai_provider)
    REFERENCES ai_provider (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_ai_model_budget_nonnegatif CHECK (
    budget_bulanan IS NULL OR budget_bulanan >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_model_kode_hidup
  ON ai_model (id_ai_provider, kode) WHERE deleted_at IS NULL;

COMMENT ON TABLE ai_model IS
  'MASTER model LLM per vendor — budget_bulanan = batas belanja per bulan kalendar DALAM UANG (NULL = tanpa batas); kode = id model API vendor (gpt-4o-mini, glm-4.6, …).';

CREATE INDEX IF NOT EXISTS ix_ai_model_provider
  ON ai_model (id_ai_provider) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ai_model_status
  ON ai_model (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER historis] Harga resmi per 1M token per tanggal berlaku — moderasi
-- biaya input/cache/output per model. Baris TIDAK pernah di-update (harga
-- baru = baris mulai_berlaku baru); UNIQUE GLOBAL (model, mulai_berlaku) —
-- tanggal berlaku tidak pernah dipakai ulang. Harga 0 = vendor tidak memakai
-- komponen itu (mis. OpenAI tanpa cache-write).
CREATE TABLE IF NOT EXISTS ai_model_harga (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ai_model         bigint NOT NULL,
  mulai_berlaku       date NOT NULL,
  harga_input_1m      numeric(18,6) NOT NULL DEFAULT 0,
  harga_cache_1m      numeric(18,6) NOT NULL DEFAULT 0,
  harga_cache_tulis_1m numeric(18,6) NOT NULL DEFAULT 0,
  harga_output_1m     numeric(18,6) NOT NULL DEFAULT 0,
  sumber_harga        varchar(300),
  version             integer NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_ai_model_harga_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ai_model_harga_berlaku UNIQUE (id_ai_model, mulai_berlaku),
  CONSTRAINT fk_ai_model_harga_model FOREIGN KEY (id_ai_model)
    REFERENCES ai_model (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_ai_model_harga_nonnegatif CHECK (
    harga_input_1m >= 0 AND harga_cache_1m >= 0
    AND harga_cache_tulis_1m >= 0 AND harga_output_1m >= 0)
);

COMMENT ON TABLE ai_model_harga IS
  'MASTER historis harga resmi per 1M token (input/cache-read/cache-write/output) per tanggal berlaku — potret pricing resmi provider; log biaya meng-snapshot harga (tidak join live).';

CREATE INDEX IF NOT EXISTS ix_ai_model_harga_model
  ON ai_model_harga (id_ai_model, mulai_berlaku DESC);

-- [MASTER] Persona chatbot LLM — PINDAH dari wa_persona (fitur WA-F05 →
-- modul AI). Struktur & kolom identik ddl/66 §2; migrasi data §3
-- mempertahankan id/entity_id. Konten prompt prosa bebas = text.
CREATE TABLE IF NOT EXISTS ai_persona (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  nama            varchar(100) NOT NULL,
  karakter        text,
  gaya_bahasa     text,
  batasan         text,
  bahasa          varchar(50) NOT NULL DEFAULT 'id',
  contoh_few_shot text,
  status          enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  revisi          integer NOT NULL DEFAULT 1,
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_ai_persona_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_persona_nama_hidup ON ai_persona (nama) WHERE deleted_at IS NULL;

COMMENT ON TABLE ai_persona IS
  'MASTER persona chatbot LLM (kepribadian & batasan prompt) — PEMILIK MODUL AI (pindah dari WA 2026-11-23, ddl/87); revisi = nomor revisi konten, version = optimistic lock.';

CREATE INDEX IF NOT EXISTS ix_ai_persona_status
  ON ai_persona (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Basis pengetahuan LLM — PINDAH dari wa_pengetahuan (fitur WA-F06 →
-- modul AI). Retrieval sederhana keyword+prioritas (A-08 tanpa vector);
-- NONAKTIF tidak ikut prompt (WA-BR14); lampiran via core_files (pemilik CORE).
CREATE TABLE IF NOT EXISTS ai_pengetahuan (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id     uuid NOT NULL DEFAULT gen_random_uuid(),
  judul         varchar(200) NOT NULL,
  isi           text NOT NULL,
  kategori      varchar(100) NOT NULL DEFAULT 'umum',
  prioritas     integer NOT NULL DEFAULT 0,
  id_core_files bigint,
  status        enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  revisi        integer NOT NULL DEFAULT 1,
  version       integer NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT uq_ai_pengetahuan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ai_pengetahuan_core_files FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON UPDATE CASCADE ON DELETE SET NULL
);
COMMENT ON TABLE ai_pengetahuan IS
  'MASTER basis pengetahuan chatbot LLM — PEMILIK MODUL AI (pindah dari WA 2026-11-23, ddl/87); lampiran via core_files (pemilik CORE).';

CREATE INDEX IF NOT EXISTS ix_ai_pengetahuan_retrieval
  ON ai_pengetahuan (prioritas DESC) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [LOG/EVENT] Ledger biaya panggilan LLM — APPEND-ONLY, biaya akhir = harga
-- resmi × faktor_markup (CFG-AI-01, default ×3). Token INTERNAL (kalkulasi &
-- audit) — API/FE hanya mengekspos nilai UANG (keputusan pemilik 2026-11-23).
-- Snapshot harga+faktor+mata_uang per baris → histori tetap akurat saat
-- harga/config berubah. Tanpa version (tak pernah dimutasi API).
CREATE TABLE IF NOT EXISTS ai_pemakaian (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ai_provider       bigint NOT NULL,
  id_ai_model          bigint NOT NULL,
  id_ai_model_harga    bigint NOT NULL,
  -- Snapshot beku saat panggilan (jangan join live ke ai_model_harga):
  harga_input_1m       numeric(18,6) NOT NULL DEFAULT 0,
  harga_cache_1m       numeric(18,6) NOT NULL DEFAULT 0,
  harga_cache_tulis_1m numeric(18,6) NOT NULL DEFAULT 0,
  harga_output_1m      numeric(18,6) NOT NULL DEFAULT 0,
  faktor_markup        numeric(6,2) NOT NULL DEFAULT 3,
  mata_uang            varchar(50) NOT NULL DEFAULT 'USD',
  -- Token INTERNAL — tidak pernah tampil di aplikasi:
  token_input          integer NOT NULL DEFAULT 0,
  token_cache          integer NOT NULL DEFAULT 0,
  token_cache_tulis    integer NOT NULL DEFAULT 0,
  token_output         integer NOT NULL DEFAULT 0,
  biaya_dasar          numeric(18,4) NOT NULL DEFAULT 0,
  biaya                numeric(18,4) NOT NULL DEFAULT 0,
  hasil                enum_hasil_panggilan_ai NOT NULL DEFAULT 'BERHASIL',
  sumber               varchar(50) NOT NULL,
  entity_id_sumber     varchar(255),
  durasi_ms            integer,
  waktu                timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_ai_pemakaian_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ai_pemakaian_provider FOREIGN KEY (id_ai_provider)
    REFERENCES ai_provider (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_ai_pemakaian_model FOREIGN KEY (id_ai_model)
    REFERENCES ai_model (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_ai_pemakaian_harga FOREIGN KEY (id_ai_model_harga)
    REFERENCES ai_model_harga (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_ai_pemakaian_biaya CHECK (biaya >= 0 AND biaya_dasar >= 0),
  CONSTRAINT ck_ai_pemakaian_token CHECK (
    token_input >= 0 AND token_cache >= 0
    AND token_cache_tulis >= 0 AND token_output >= 0),
  CONSTRAINT ck_ai_pemakaian_faktor CHECK (faktor_markup > 0)
);
COMMENT ON TABLE ai_pemakaian IS
  'LOG/EVENT ledger biaya pemakaian LLM append-only — modul AI; biaya = biaya_dasar × faktor_markup (default ×3 — CFG-AI-01); token internal tak diekspos UI; sumber = kode pemanggil (WA_CHATBOT, …) + entity_id_sumber (Tier B, pola PGW).';

CREATE INDEX IF NOT EXISTS ix_ai_pemakaian_model_waktu
  ON ai_pemakaian (id_ai_model, waktu);
CREATE INDEX IF NOT EXISTS ix_ai_pemakaian_waktu
  ON ai_pemakaian (waktu);
CREATE INDEX IF NOT EXISTS ix_ai_pemakaian_sumber
  ON ai_pemakaian (sumber, waktu);

-- =============================================================================
-- §3 MIGRASI PERSONA/PENGETAHUAN WA → AI (id & entity_id dipertahankan) +
--    RE-POINT FK wa_instance + DROP tabel WA lama. Ter-guard: kali-2 =
--    skip NOTICE (transaksi atomik — tidak ada keadaan setengah jadi).
-- =============================================================================

DO $$ DECLARE v_jml bigint; BEGIN
  IF to_regclass('public.wa_persona') IS NOT NULL THEN
    IF to_regclass('public.ai_persona') IS NULL THEN
      RAISE EXCEPTION 'PATCH 87: ai_persona tidak ada tetapi wa_persona ada — state tak terduga';
    END IF;

    -- (a) Salin data — id/entity_id + trio dipertahankan (referensi eksternal
    --     tetap valid; tidak ada periode dua salinan hidup: drop di akhir tx).
    INSERT INTO ai_persona (id, entity_id, nama, karakter, gaya_bahasa, batasan,
                            bahasa, contoh_few_shot, status, revisi, version,
                            created_at, updated_at, deleted_at)
    OVERRIDING SYSTEM VALUE
    SELECT id, entity_id, nama, karakter, gaya_bahasa, batasan,
           bahasa, contoh_few_shot, status, revisi, version,
           created_at, updated_at, deleted_at
    FROM wa_persona ORDER BY id;
    GET DIAGNOSTICS v_jml = ROW_COUNT;
    RAISE NOTICE 'PATCH 87: ai_persona migrasi % baris', v_jml;

    INSERT INTO ai_pengetahuan (id, entity_id, judul, isi, kategori, prioritas,
                                id_core_files, status, revisi, version,
                                created_at, updated_at, deleted_at)
    OVERRIDING SYSTEM VALUE
    SELECT id, entity_id, judul, isi, kategori, prioritas,
           id_core_files, status, revisi, version,
           created_at, updated_at, deleted_at
    FROM wa_pengetahuan ORDER BY id;
    GET DIAGNOSTICS v_jml = ROW_COUNT;
    RAISE NOTICE 'PATCH 87: ai_pengetahuan migrasi % baris', v_jml;

    -- (b) Sequence lanjut dari id migrasi (identity GENERATED ALWAYS).
    PERFORM setval(pg_get_serial_sequence('ai_persona', 'id'),
                   COALESCE((SELECT MAX(id) FROM ai_persona), 1));
    PERFORM setval(pg_get_serial_sequence('ai_pengetahuan', 'id'),
                   COALESCE((SELECT MAX(id) FROM ai_pengetahuan), 1));

    -- (c) wa_instance: ganti FK persona → ai_persona (rename kolom; nilai
    --     dipertahankan; SET NULL — persona terhapus = konfigurasi lepas,
    --     instance hidup; pola penautan lintas modul baca).
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wa_instance_persona') THEN
      ALTER TABLE wa_instance DROP CONSTRAINT fk_wa_instance_persona;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'wa_instance' AND column_name = 'id_wa_persona') THEN
      ALTER TABLE wa_instance RENAME COLUMN id_wa_persona TO id_ai_persona;
    END IF;
    ALTER TABLE wa_instance
      ADD CONSTRAINT fk_wa_instance_ai_persona FOREIGN KEY (id_ai_persona)
        REFERENCES ai_persona (id) ON UPDATE CASCADE ON DELETE SET NULL;

    DROP INDEX IF EXISTS ix_wa_instance_persona;
    CREATE INDEX IF NOT EXISTS ix_wa_instance_ai_persona
      ON wa_instance (id_ai_persona) WHERE id_ai_persona IS NOT NULL;

    COMMENT ON COLUMN wa_instance.id_ai_persona IS
      'Persona chatbot AI terpasang (pemilik modul AI — ai_persona, ddl/87); tepat satu per instance (WA-BR13); NULL = lepas';

    -- (d) Satu fakta satu tempat — tabel WA lama di-drop setelah migrasi.
    DROP TABLE wa_pengetahuan;
    DROP TABLE wa_persona;
    RAISE NOTICE 'PATCH 87: wa_persona/wa_pengetahuan di-drop — pemilik kini modul AI';
  ELSE
    RAISE NOTICE 'PATCH 87: wa_persona tidak ada — migrasi dilewati (fresh install / sudah migrasi)';
  END IF;
END $$;

-- =============================================================================
-- §4 TRIGGER updated_at — refresh updated_at tiap UPDATE (fungsi generik
--    set_updated_at() CORE; pola 66-wa §4)
-- =============================================================================

DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'ai_provider', 'ai_model', 'ai_model_harga',
    'ai_persona', 'ai_pengetahuan', 'ai_pemakaian'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- =============================================================================
-- §5 SEED REGISTRY + CFG — baris core_modules key='ai-llm' (enum di §0);
--    CFG-AI-01/02 via core_module_configs (pola CFG-WA-05).
-- =============================================================================

INSERT INTO core_modules (key, name, tagline, tone, is_core, enabled)
VALUES
  ('ai-llm', 'AI LLM',
   'Infrastruktur LLM multi-vendor: provider & secret key, model + budget bulanan, harga resmi, ledger biaya, persona & pengetahuan',
   'cyan', false, true)
ON CONFLICT (key) DO NOTHING;

-- CFG-AI-01: faktor markup biaya — biaya akhir = harga resmi vendor × 3
-- (keputusan pemilik 2026-11-23). CFG-AI-02: ambang alert realisasi budget.
INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-AI-01', '{"faktor_markup":3}', 'json',
   'Faktor markup biaya LLM — biaya akhir = harga resmi provider × faktor (default 3; keputusan pemilik 2026-11-23); faktor per-panggilan di-snapshot di ai_pemakaian'),
  ('CFG-AI-02', '{"ambang_alert":80}', 'json',
   'Ambang alert realisasi budget bulanan per model (persen; realisasi = SUM(ai_pemakaian.biaya) bulan kalendar vs ai_model.budget_bulanan)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key::text = 'ai-llm'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

COMMIT;

-- =============================================================================
-- §6 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Dry-run    : catatan — patch mengandung ALTER TYPE di luar transaksi; uji
--              idempotensi cukup jalankan ulang patch utuh 2× (kali-2
--              = no-op + NOTICE migrasi dilewati).
-- Apply      : podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/87-ai.sql   (jalankan 2× — identik)
-- Tabel      : SELECT table_name FROM information_schema.tables
--              WHERE table_name LIKE 'ai\_%' ORDER BY 1;           → 6 baris
-- Migrasi    : SELECT (SELECT count(*) FROM ai_persona) AS persona,
--                     (SELECT count(*) FROM ai_pengetahuan) AS pengetahuan;
--              → sama dengan hitungan wa_persona/wa_pengetahuan sebelum patch
-- FK         : SELECT conname FROM pg_constraint
--              WHERE conrelid = 'wa_instance'::regclass
--                AND conname LIKE 'fk_wa_instance_ai%';          → 1 baris
-- Tabel lama : SELECT to_regclass('public.wa_persona') IS NULL
--              AND to_regclass('public.wa_pengetahuan') IS NULL;  → true
-- Enum       : SELECT count(DISTINCT t.typname) FROM pg_type t
--              WHERE t.typname LIKE 'enum\_%\_ai' AND t.typtype='e'; → 3
-- Trigger    : SELECT tgrelid::regclass::text FROM pg_trigger
--              WHERE tgname LIKE 'trg\_ai\_%\_updated\_at';        → 6 baris
-- Registry   : SELECT key, name FROM core_modules WHERE key='ai-llm'; → 1
-- Config     : SELECT param_key FROM core_module_configs c
--              JOIN core_modules m ON m.id = c.id_core_modules
--              WHERE m.key = 'ai-llm' ORDER BY param_key;          → 2 baris
-- =============================================================================
