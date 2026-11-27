-- +goose Up
-- Porting 1:1 dari ddl/89-wa-mode-chatbot-ai-model.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 89-wa-mode-chatbot-ai-model.sql — WA: kosakata mode_chatbot
--                       BOT|HYBRID|AI (MATI DIHAPUS) + FK id_ai_model
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — `enum_mode_chatbot_wa` + tabel [MASTER]
--            `wa_instance` (kolom mode_chatbot/id_ai_model milik instance).
--            Keputusan pemilik 2026-11-24: kosakata mode diganti menjadi
--            BOT|HYBRID|AI — NON_LLM→BOT, LLM→HYBRID (RENAME VALUE — data
--            otomatis ikut), **MATI DIHAPUS TOTAL** (baris eks-MATI dipetakan
--            ke BOT — mode paling rendah), nilai baru AI (LLM langsung).
--            Plus kolom FK baru `id_ai_model` → ai_model: pemilik memilih
--            model AI EKSPLISIT per instance (wajib mode AI/HYBRID —
--            ck_wa_instance_model_wajib); runtime kuota LLM mematikan ke BOT.
-- Migrasi  : §1 RENAME (data NON_LLM/LLM otomatis ikut) → §2 UPDATE
--            mode_chatbot='BOT' utk semua baris 'MATI' (WAJIB SEBELUM enum
--            MATI dihapus) → §3 bedah enum: drop nilai MATI + tambah AI +
--            SET DEFAULT 'BOT'. Baris eks-MATI kembali BOT lewat sinkron
--            manual (ubahKonfig) bila ingin dimatikan lagi.
-- Bedah    : ALTER TYPE … DROP VALUE hanya ada di PG17 — server dev PG16.
--            Patch ini memakai SWAP TIPE (pola 46-pgw §7, versi ringkas):
--            rename tipe lama → CREATE TYPE baru ('BOT','HYBRID','AI') →
--            drop default (default lama 'MATI' tidak ter-cast antar tipe) →
--            ALTER COLUMN TYPE USING cast text → drop tipe lama → SET
--            DEFAULT 'BOT'. Satu kolom pemakai (wa_instance.mode_chatbot);
--            tidak ada index/constraint/view lain yang menyentuh enum ini.
--            Swap bekerja identik di PG16 maupun PG17 — satu jalur kode.
-- Idempoten: DO-block guard pg_enum/pg_constraint/pg_attribute — lari kedua
--            = no-op. DUA transaksi terpisah: enum (§1) menambah/mengubah
--            kosakata TANPA memakai nilai baru dalam tx yang sama; §4 memakai
--            literal 'AI'/'HYBRID' di CHECK SETELAH tx enum commit.
-- Catatan  : (a) ck_wa_instance_model_wajib NOT VALID — baris warisan
--              HYBRID (eks LLM) belum punya id_ai_model; constraint tetap
--              menegakkan SEMUA insert/update baru (isi model wajib saat
--              ubahKonfig berikutnya — WA-BR06 via service).
--            (b) ddl/66-wa.sql §1 (CREATE TYPE + guard kosakata) + §2
--              (DEFAULT kolom mode_chatbot) disinkronkan di patch ini agar
--              restore-fresh tidak RAISE.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/89-wa-mode-chatbot-ai-model.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

-- =============================================================================
-- §1 ENUM — RENAME NON_LLM→BOT, LLM→HYBRID (data pemakai nilai lama ikut)
-- =============================================================================

BEGIN;

-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'enum_mode_chatbot_wa' AND e.enumlabel = 'NON_LLM'
  ) THEN
    ALTER TYPE enum_mode_chatbot_wa RENAME VALUE 'NON_LLM' TO 'BOT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'enum_mode_chatbot_wa' AND e.enumlabel = 'LLM'
  ) THEN
    ALTER TYPE enum_mode_chatbot_wa RENAME VALUE 'LLM' TO 'HYBRID';
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;

-- =============================================================================
-- §2 MIGRASI DATA — semua baris MATI → BOT (WAJIB sebelum MATI dihapus §3;
--    baris eks-MATI = mode paling rendah BOT, sinkron manual utk ubah lagi)
-- =============================================================================

BEGIN;

-- +goose StatementBegin
DO $$ DECLARE v_jml bigint; BEGIN
  -- Guard label enum (idempoten): literal 'MATI' tak ter-cast bila nilai
  -- sudah dihapus dari kosakata (rerun patch ini).
  IF EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'enum_mode_chatbot_wa' AND e.enumlabel = 'MATI'
  ) THEN
    UPDATE wa_instance SET mode_chatbot = 'BOT', updated_at = now()
    WHERE mode_chatbot = 'MATI';
    GET DIAGNOSTICS v_jml = ROW_COUNT;
    IF v_jml > 0 THEN
      RAISE NOTICE 'PATCH 89-wa: % baris wa_instance MATI dipetakan ke BOT', v_jml;
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;

-- =============================================================================
-- §3 BEDAH ENUM — hapus nilai MATI + pastikan AI ada + DEFAULT 'BOT'
--    (swap tipe pola 46-pgw §7; guard idempoten: hanya bila MATI masih ada)
-- =============================================================================

BEGIN;

-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'enum_mode_chatbot_wa' AND e.enumlabel = 'MATI'
  ) THEN
    -- Swap tipe: PG16 tidak punya ALTER TYPE … DROP VALUE (fitur PG17).
    ALTER TYPE enum_mode_chatbot_wa RENAME TO enum_mode_chatbot_wa_lama89;
    CREATE TYPE enum_mode_chatbot_wa AS ENUM ('BOT','HYBRID','AI');
    -- Default lama 'MATI' tidak ter-cast antar tipe — drop, pasang baru.
    ALTER TABLE wa_instance ALTER COLUMN mode_chatbot DROP DEFAULT;
    ALTER TABLE wa_instance ALTER COLUMN mode_chatbot TYPE enum_mode_chatbot_wa
      USING mode_chatbot::text::enum_mode_chatbot_wa;
    DROP TYPE enum_mode_chatbot_wa_lama89;
    ALTER TABLE wa_instance ALTER COLUMN mode_chatbot SET DEFAULT 'BOT';
  END IF;
END $$;
-- +goose StatementEnd


-- Belt-and-suspenders: nilai AI (sudah ada bila lewat swap / ddl/66 fresh).
ALTER TYPE enum_mode_chatbot_wa ADD VALUE IF NOT EXISTS 'AI' AFTER 'HYBRID';

-- Default kolom = BOT (idempoten; matikan default lama MATI yang sudah tak
-- ada di kosakata).
ALTER TABLE wa_instance ALTER COLUMN mode_chatbot SET DEFAULT 'BOT';

-- Guard kosakata akhir (mirror ddl/66 yang disinkronkan).
-- +goose StatementBegin
DO $$ BEGIN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_mode_chatbot_wa')
     IS DISTINCT FROM ARRAY['BOT','HYBRID','AI']::text[] THEN
    RAISE EXCEPTION 'PATCH 89-wa: enum_mode_chatbot_wa kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;

-- =============================================================================
-- §4 KOLOM FK MODEL AI + INDEX + CHECK WAJIB (literal enum aman — enum sudah
--    commit di §3)
-- =============================================================================

BEGIN;

-- [MASTER] Model AI pilihan pemilik utk instance ini — wajib terisi saat mode
-- AI/HYBRID (ck_wa_instance_model_wajib); NULL = belum dipilih / mode BOT.
ALTER TABLE wa_instance ADD COLUMN IF NOT EXISTS id_ai_model bigint;

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_wa_instance_ai_model'
  ) THEN
    ALTER TABLE wa_instance
      ADD CONSTRAINT fk_wa_instance_ai_model FOREIGN KEY (id_ai_model)
        REFERENCES ai_model (id) ON UPDATE CASCADE ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_wa_instance_ai_model
  ON wa_instance (id_ai_model) WHERE id_ai_model IS NOT NULL;

-- Model AI WAJIB ketika mode AI/HYBRID (keputusan pemilik 2026-11-24) —
-- NOT VALID utk baris warisan eks-LLM (lihat Catatan a).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ck_wa_instance_model_wajib'
  ) THEN
    ALTER TABLE wa_instance
      ADD CONSTRAINT ck_wa_instance_model_wajib
      CHECK (mode_chatbot NOT IN ('AI','HYBRID') OR id_ai_model IS NOT NULL)
      NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


COMMENT ON COLUMN wa_instance.mode_chatbot IS
  'Mode chatbot instance (ddl/89 keputusan pemilik 2026-11-24): BOT = aturan keyword + fallback; HYBRID = keyword → LLM tanpa cocok; AI = LLM langsung (MATI dihapus — matikan via mode BOT).';
COMMENT ON COLUMN wa_instance.id_ai_model IS
  'Model AI (ai_model, pemilik modul AI) pilihan instance — WAJIB mode AI/HYBRID (ck_wa_instance_model_wajib, ddl/89); NULL = belum dipilih / mode BOT; hapus model → SET NULL.';

COMMIT;

-- =============================================================================
-- §5 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Enum   : SELECT enumlabel, enumsortorder FROM pg_enum e
--            JOIN pg_type t ON t.oid = e.enumtypid
--          WHERE t.typname='enum_mode_chatbot_wa' ORDER BY 2;
--          → BOT(1), HYBRID(2), AI(3) — MATI tidak ada
-- Default: SELECT column_default FROM information_schema.columns
--          WHERE table_name='wa_instance' AND column_name='mode_chatbot';
--          → 'BOT'::enum_mode_chatbot_wa
-- Kolom  : SELECT column_name FROM information_schema.columns
--          WHERE table_name='wa_instance' AND column_name='id_ai_model'; → 1
-- FK     : SELECT conname FROM pg_constraint
--          WHERE conrelid='wa_instance'::regclass
--            AND conname IN ('fk_wa_instance_ai_model',
--                            'ck_wa_instance_model_wajib');     → 2 baris
-- Index  : SELECT indexname FROM pg_indexes
--          WHERE indexname='ix_wa_instance_ai_model';            → 1
-- Data   : SELECT mode_chatbot, count(*) FROM wa_instance GROUP BY 1;
--          → hanya BOT/HYBRID/AI (eks NON_LLM→BOT, LLM→HYBRID, MATI→BOT)
-- =============================================================================
