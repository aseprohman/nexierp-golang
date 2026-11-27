-- =====================================================================
-- 74-wf-workflow-engine.sql — ENGINE WORKFLOW/APPROVAL SHARED (modul wf)
--
-- Konsep baru (bukan kelanjutan skema lama): engine generik lintas modul
-- untuk approval data per KATEGORI PROSES di masing-masing modul bisnis.
-- Pemilik engine: modul `core` (infrastruktur lintas modul) — kategori
-- dibawa per modul bisnis lewat `id_core_modules`.
--
-- Kartu klasifikasi (arsitektur-database):
--   wf_kategori_proses   [MASTER]    — registry kategori proses per modul
--                 (mis. purchasing/PESANAN, acc/JURNAL). Pemilik modul
--                 core; kategori baku di-seed. uq (id_core_modules, kode).
--   wf_template          [MASTER]    — definisi workflow per kategori,
--                 berversi: revisi = salin DRAFT versi+1; baris lama
--                 NONAKTIF (riwayat). SATU template AKTIF per kategori
--                 (partial unique) — resolusi kategori → template selalu
--                 deterministik tanpa kolom is_default.
--   wf_template_step     [LINE]      — langkah berurutan template; WIRING
--                 authority GANDA: id_core_routes_approve (gerbang aksi
--                 SETUJUI) + id_core_routes_reject (gerbang aksi TOLAK —
--                 boleh berbeda dari approve, mis. verifikator boleh
--                 setuju, hanya atasan boleh menolak & mengarahkan ulang;
--                 isi route sama bila kewenangan identik). Snapshot
--                 kebijakan saat instance mulai.
--   wf_template_approver [LINE]      — penugasan per langkah: tipe ROLE
--                 dan/atau USER (CHECK persis satu FK sesuai tipe).
--   wf_instance          [TRANSAKSI] — eksekusi workflow atas satu
--                 dokumen (polimorfik pola core_audit: tabel_sumber +
--                 entity_id_sumber Tier B). SATU instance BERJALAN per
--                 dokumen (partial unique). Jangan hard-delete — mati
--                 via status.
--   wf_instance_step     [LINE]      — salinan BEKU langkah saat mulai
--                 (snapshot kode/nama/dua route/kebijakan) + langkah ADHOC
--                 hasil tolak "BEBAS". Referensi definisi (template_step)
--                 hanya untuk reporting — truth runtime = snapshot.
--   wf_tugas             [TRANSAKSI] — INBOX USER: satu baris per approver
--                 per langkah (ROLE di-expand ke anggota role saat
--                 langkah aktif). Memuat keputusan SETUJUI/TOLAK + alasan
--                 + PILIHAN TUJUAN saat TOLAK (tipe_tujuan: PENGAJU /
--                 USER / STEP) — pengaju langkah menentukan ke mana
--                 proses berikutnya dituju sesuai kebijakan_tolak.
--   wf_log               [LOG/EVENT] — append-only, riwayat penuh per
--                 instance (aktor, aksi, posisi langkah, routing tolak,
--                 payload jsonb). Tanpa UPDATE/DELETE; trigger
--                 updated_at sengaja tidak dipasang (beku).
--
-- Alur engine:
--   AJUKAN → wf_instance (snapshot step TEMPLATE) + wf_tugas langkah
--   pertama + log MULAI → approver memutus via tugas (authority tervalidasi
--   lewat permission route langkah: wf_instance_step.id_core_routes_approve
--   untuk aksi SETUJUI, id_core_routes_reject untuk aksi TOLAK →
--   core_permissions_routes → role/user permissions) → SETUJUI: kebijakan
--   SALAH_SATU/SEMUA/KUORUM → langkah berikut AKTIF; langkah terakhir →
--   instance DISETUJUI. TOLAK (selain setujui): wajib alasan + tujuan
--   sesuai kebijakan_tolak — KE_PENGAJU (pengaju revisi + AJUKAN_ULANG),
--   KE_STEP_SEBELUMNYA / KE_STEP_TERTENTU (buka ulang langkah snapshot),
--   BEBAS (aktor pilih USER → langkah ADHOC, atau STEP). BATALKAN oleh
--   pengaju → instance DIBATALKAN. Eksekusi langkah dikendalikan engine
--   via status AKTIF (bukan urutan otomatis) — urutan = kronologi tampilan.
--
-- Catatan desain:
--   - id_wf_instance di wf_tugas = denormalisasi TERUKUR (query panas
--     inbox); ditulis engine saat generate tugas, ikut step CASCADE.
--   - SoD "pengaju ≠ penyetuju" = kebijakan engine service (butuh konteks
--     kategori), tidak ditegakkan DB.
--   - Tugas dibuka ulang di-RESET ke MENUNGGU (bukan baris baru) — putusan
--     lama tidak berlaku, tetap tercatat di wf_log; karenanya uq
--     (id_wf_instance_step, id_core_users) full unique.
--   - Authority dicek LIVE saat aksi (route permission), inbox hanya
--     papan tugas — user kehilangan kewenangan tidak bisa memutus walau
--     tugasnya masih MENUNGGU.
--
-- Idempoten: enum DO-block, IF NOT EXISTS, trigger DROP+CREATE, seed
-- ON CONFLICT DO NOTHING. Prasyarat: core_modules, core_routes,
-- core_roles, core_users (baseline live).
-- =====================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Enum (12)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE wf_status_aktif AS ENUM ('AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_status_template AS ENUM ('DRAFT', 'AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_kebijakan_setujui AS ENUM ('SALAH_SATU', 'SEMUA', 'KUORUM');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_kebijakan_tolak AS ENUM ('KE_PENGAJU', 'KE_STEP_SEBELUMNYA', 'KE_STEP_TERTENTU', 'BEBAS');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_tipe_approver AS ENUM ('ROLE', 'USER');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_status_instance AS ENUM ('BERJALAN', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_sumber_step AS ENUM ('TEMPLATE', 'ADHOC');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_status_step AS ENUM ('MENUNGGU', 'AKTIF', 'DISETUJUI', 'DITOLAK', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_sumber_tugas AS ENUM ('ROLE', 'USER', 'ADHOC');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_status_tugas AS ENUM ('MENUNGGU', 'SELESAI', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_keputusan AS ENUM ('SETUJUI', 'TOLAK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_tipe_tujuan AS ENUM ('PENGAJU', 'USER', 'STEP');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE wf_aksi_log AS ENUM ('MULAI', 'SETUJUI', 'TOLAK', 'BATALKAN', 'AJUKAN_ULANG', 'LANGKAH_ADHOC');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- Migrasi dari patch 74 bentuk PERTAMA (sudah terpasang di DB) → bentuk final:
-- id_core_routes di wf_template_step/wf_instance_step menjadi
-- id_core_routes_approve + kolom baru id_core_routes_reject.
-- Harus sebelum CREATE TABLE/index — nama kolom baru dipakai di bawah.
-- No-op pada DB segar (tabel belum ada; dibuat langsung bentuk final).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'wf_template_step' AND column_name = 'id_core_routes') THEN
    ALTER TABLE wf_template_step RENAME COLUMN id_core_routes TO id_core_routes_approve;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema()
               AND table_name = 'wf_instance_step' AND column_name = 'id_core_routes') THEN
    ALTER TABLE wf_instance_step RENAME COLUMN id_core_routes TO id_core_routes_approve;
  END IF;
  -- selaraskan nama constraint FK approve dari bentuk v1
  -- (to_regclass = NULL-safe bila tabel belum ada pada DB segar)
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wf_template_step_routes'
             AND conrelid = to_regclass('wf_template_step')) THEN
    ALTER TABLE wf_template_step RENAME CONSTRAINT fk_wf_template_step_routes
      TO fk_wf_template_step_routes_approve;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wf_instance_step_routes'
             AND conrelid = to_regclass('wf_instance_step')) THEN
    ALTER TABLE wf_instance_step RENAME CONSTRAINT fk_wf_instance_step_routes
      TO fk_wf_instance_step_routes_approve;
  END IF;
  -- kolom reject bila tabel bentuk v1 sudah ada tanpa kolom itu
  IF to_regclass(current_schema() || '.wf_template_step') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = current_schema()
                       AND table_name = 'wf_template_step'
                       AND column_name = 'id_core_routes_reject') THEN
    ALTER TABLE wf_template_step ADD COLUMN id_core_routes_reject bigint;
  END IF;
  IF to_regclass(current_schema() || '.wf_instance_step') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = current_schema()
                       AND table_name = 'wf_instance_step'
                       AND column_name = 'id_core_routes_reject') THEN
    ALTER TABLE wf_instance_step ADD COLUMN id_core_routes_reject bigint;
  END IF;
  -- buang index v1 yang menunjuk nama kolom lama (dibuat ulang dengan nama baru)
  DROP INDEX IF EXISTS ix_wf_template_step_routes;
END $$;

-- -----------------------------------------------------------------------------
-- wf_kategori_proses — registry kategori proses per modul [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_kategori_proses (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_modules  bigint NOT NULL,
  kode             varchar(50) NOT NULL,           -- PESANAN, JURNAL, CUTI, ...
  nama             varchar(100) NOT NULL,
  deskripsi        varchar(200),
  status           wf_status_aktif NOT NULL DEFAULT 'AKTIF',
  version          int NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_wf_kategori_proses_entity_id UNIQUE (entity_id),
  -- kode kategori = kosakata domain — tidak dipakai ulang (unique global)
  CONSTRAINT uq_wf_kategori_proses_komposit UNIQUE (id_core_modules, kode),
  CONSTRAINT fk_wf_kategori_proses_modules FOREIGN KEY (id_core_modules)
    REFERENCES core_modules (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_wf_kategori_proses_modules
  ON wf_kategori_proses (id_core_modules) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- wf_template — definisi workflow berversi per kategori [MASTER]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_template (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_kategori_proses  bigint NOT NULL,
  kode                   varchar(50) NOT NULL,    -- identitas keluarga template
  nama                   varchar(100) NOT NULL,
  deskripsi              varchar(200),
  versi                  int NOT NULL DEFAULT 1,  -- revisi = salin DRAFT versi+1
  status                 wf_status_template NOT NULL DEFAULT 'DRAFT',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_wf_template_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_wf_template_komposit UNIQUE (id_wf_kategori_proses, kode, versi),
  CONSTRAINT ck_wf_template_versi CHECK (versi >= 1),
  CONSTRAINT fk_wf_template_kategori FOREIGN KEY (id_wf_kategori_proses)
    REFERENCES wf_kategori_proses (id) ON DELETE RESTRICT
);

-- SATU template AKTIF per kategori — resolusi kategori → template deterministik
CREATE UNIQUE INDEX IF NOT EXISTS uq_wf_template_aktif_per_kategori
  ON wf_template (id_wf_kategori_proses)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_template_kategori
  ON wf_template (id_wf_kategori_proses) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- wf_template_step — langkah berurutan + wiring core_routes [LINE]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_template_step (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_template      bigint NOT NULL,
  urutan              int NOT NULL,                 -- 1..n (kronologi tampilan)
  kode                varchar(50) NOT NULL,         -- VERIFIKASI, PENGESAHAN, ...
  nama                varchar(100) NOT NULL,
  -- WIRING AUTHORITY SETUJUI: route gerbang aksi SETUJUI langkah ini;
  -- kewenangan penyetuju = permission route (core_permissions_routes → role/user).
  id_core_routes_approve bigint NOT NULL,
  -- WIRING AUTHORITY TOLAK: route gerbang aksi TOLAK — boleh berbeda dari
  -- approve (mis. verifikator boleh setuju, hanya atasan boleh menolak &
  -- mengarahkan ulang); isi route yang sama bila kewenangan identik.
  id_core_routes_reject  bigint NOT NULL,
  kebijakan_setujui   wf_kebijakan_setujui NOT NULL DEFAULT 'SALAH_SATU',
  jumlah_minimal      int,                          -- wajib bila KUORUM
  kebijakan_tolak     wf_kebijakan_tolak NOT NULL DEFAULT 'KE_PENGAJU',
  urutan_step_tolak   int,                          -- wajib bila KE_STEP_TERTENTU
  batas_waktu_jam     int,                          -- SLA inbox (jam); NULL = tanpa SLA
  version             int NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_wf_template_step_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_wf_template_step_urutan UNIQUE (id_wf_template, urutan),
  CONSTRAINT uq_wf_template_step_kode UNIQUE (id_wf_template, kode),
  CONSTRAINT ck_wf_template_step_urutan CHECK (urutan >= 1),
  CONSTRAINT ck_wf_template_step_kuorum CHECK (
    (kebijakan_setujui <> 'KUORUM' OR (jumlah_minimal IS NOT NULL AND jumlah_minimal >= 2))
    AND (kebijakan_setujui = 'KUORUM' OR jumlah_minimal IS NULL)),
  CONSTRAINT ck_wf_template_step_tolak_target CHECK (
    (kebijakan_tolak <> 'KE_STEP_TERTENTU' OR urutan_step_tolak IS NOT NULL)
    AND (kebijakan_tolak = 'KE_STEP_TERTENTU' OR urutan_step_tolak IS NULL)),
  -- tolak selalu MUNDUR (tak boleh melompat ke langkah di depannya)
  CONSTRAINT ck_wf_template_step_tolak_mundur CHECK (urutan_step_tolak IS NULL OR urutan_step_tolak < urutan),
  CONSTRAINT ck_wf_template_step_sla CHECK (batas_waktu_jam IS NULL OR batas_waktu_jam >= 1),
  CONSTRAINT fk_wf_template_step_template FOREIGN KEY (id_wf_template)
    REFERENCES wf_template (id) ON DELETE CASCADE,
  CONSTRAINT fk_wf_template_step_routes_approve FOREIGN KEY (id_core_routes_approve)
    REFERENCES core_routes (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_template_step_routes_reject FOREIGN KEY (id_core_routes_reject)
    REFERENCES core_routes (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_wf_template_step_template ON wf_template_step (id_wf_template);
CREATE INDEX IF NOT EXISTS ix_wf_template_step_routes_approve ON wf_template_step (id_core_routes_approve);
CREATE INDEX IF NOT EXISTS ix_wf_template_step_routes_reject ON wf_template_step (id_core_routes_reject);

-- -----------------------------------------------------------------------------
-- wf_template_approver — penugasan ROLE dan/atau USER per langkah [LINE]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_template_approver (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_template_step bigint NOT NULL,
  tipe                wf_tipe_approver NOT NULL,
  id_core_roles       bigint,
  id_core_users       bigint,
  version             int NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_wf_template_approver_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_wf_template_approver_tunggal CHECK (
    (tipe = 'ROLE' AND id_core_roles IS NOT NULL AND id_core_users IS NULL)
    OR (tipe = 'USER' AND id_core_users IS NOT NULL AND id_core_roles IS NULL)),
  CONSTRAINT fk_wf_template_approver_step FOREIGN KEY (id_wf_template_step)
    REFERENCES wf_template_step (id) ON DELETE CASCADE,
  CONSTRAINT fk_wf_template_approver_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_template_approver_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT
);

-- anti duplikat penugasan per langkah (partial sesuai tipe)
CREATE UNIQUE INDEX IF NOT EXISTS uq_wf_template_approver_roles
  ON wf_template_approver (id_wf_template_step, id_core_roles)
  WHERE id_core_roles IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_wf_template_approver_users
  ON wf_template_approver (id_wf_template_step, id_core_users)
  WHERE id_core_users IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_template_approver_step
  ON wf_template_approver (id_wf_template_step) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- wf_instance — eksekusi workflow atas satu dokumen [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_instance (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_template          bigint NOT NULL,        -- referensi reporting (truth = snapshot step)
  id_wf_kategori_proses   bigint NOT NULL,        -- baca hidup (kategori master stabil)
  template_versi          int NOT NULL,           -- snapshot versi definisi saat mulai
  -- subjek dokumen (pola core_audit) — Tier B:
  tabel_sumber            varchar(50) NOT NULL,   -- mis. pur_pesanan, acc_jurnal
  entity_id_sumber        varchar(255) NOT NULL,
  nomor_dokumen           varchar(150),           -- snapshot tampilan inbox
  id_core_users_pengaju   bigint NOT NULL,        -- inisiator; target routing KE_PENGAJU
  status                  wf_status_instance NOT NULL DEFAULT 'BERJALAN',
  urutan_step_aktif       int,                    -- NULL = tidak ada langkah berjalan
  mulai_pada              timestamptz NOT NULL DEFAULT now(),
  selesai_pada            timestamptz,
  version                 int NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_wf_instance_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_wf_instance_selesai CHECK (selesai_pada IS NULL OR status <> 'BERJALAN'),
  CONSTRAINT fk_wf_instance_template FOREIGN KEY (id_wf_template)
    REFERENCES wf_template (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_instance_kategori FOREIGN KEY (id_wf_kategori_proses)
    REFERENCES wf_kategori_proses (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_instance_pengaju FOREIGN KEY (id_core_users_pengaju)
    REFERENCES core_users (id) ON DELETE RESTRICT
);

-- SATU instance BERJALAN per dokumen (pengajuan ulang setelah selesai = baris baru)
CREATE UNIQUE INDEX IF NOT EXISTS uq_wf_instance_sumber_berjalan
  ON wf_instance (tabel_sumber, entity_id_sumber)
  WHERE status = 'BERJALAN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_instance_sumber
  ON wf_instance (tabel_sumber, entity_id_sumber) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_instance_pengaju
  ON wf_instance (id_core_users_pengaju, status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_instance_template ON wf_instance (id_wf_template);

-- -----------------------------------------------------------------------------
-- wf_instance_step — salinan BEKU langkah + langkah ADHOC [LINE]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_instance_step (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_instance      bigint NOT NULL,
  id_wf_template_step bigint,                     -- NULL = langkah ADHOC
  sumber              wf_sumber_step NOT NULL DEFAULT 'TEMPLATE',
  urutan              int NOT NULL,
  -- SNAPSHOT beku definisi saat instance mulai / langkah adhoc dibuat:
  kode                varchar(50) NOT NULL,
  nama                varchar(100) NOT NULL,
  id_core_routes_approve bigint NOT NULL,         -- wiring authority SETUJUI terbekukan
  id_core_routes_reject  bigint NOT NULL,         -- wiring authority TOLAK terbekukan
  kebijakan_setujui   wf_kebijakan_setujui NOT NULL,
  jumlah_minimal      int,
  kebijakan_tolak     wf_kebijakan_tolak NOT NULL,
  urutan_step_tolak   int,
  batas_waktu_jam     int,
  status              wf_status_step NOT NULL DEFAULT 'MENUNGGU',
  jumlah_setuju       int NOT NULL DEFAULT 0,
  mulai_pada          timestamptz,
  selesai_pada        timestamptz,
  version             int NOT NULL DEFAULT 1,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT uq_wf_instance_step_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_wf_instance_step_urutan UNIQUE (id_wf_instance, urutan),
  CONSTRAINT ck_wf_instance_step_urutan CHECK (urutan >= 1),
  CONSTRAINT ck_wf_instance_step_kuorum CHECK (
    (kebijakan_setujui <> 'KUORUM' OR (jumlah_minimal IS NOT NULL AND jumlah_minimal >= 2))
    AND (kebijakan_setujui = 'KUORUM' OR jumlah_minimal IS NULL)),
  CONSTRAINT ck_wf_instance_step_tolak_target CHECK (
    (kebijakan_tolak <> 'KE_STEP_TERTENTU' OR urutan_step_tolak IS NOT NULL)
    AND (kebijakan_tolak = 'KE_STEP_TERTENTU' OR urutan_step_tolak IS NULL)),
  CONSTRAINT ck_wf_instance_step_tolak_mundur CHECK (urutan_step_tolak IS NULL OR urutan_step_tolak < urutan),
  -- langkah adhoc = hasil tolak BEBAS tanpa asal definisi template
  CONSTRAINT ck_wf_instance_step_adhoc CHECK (sumber <> 'ADHOC' OR id_wf_template_step IS NULL),
  CONSTRAINT fk_wf_instance_step_instance FOREIGN KEY (id_wf_instance)
    REFERENCES wf_instance (id) ON DELETE CASCADE,
  CONSTRAINT fk_wf_instance_step_definisi FOREIGN KEY (id_wf_template_step)
    REFERENCES wf_template_step (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_instance_step_routes_approve FOREIGN KEY (id_core_routes_approve)
    REFERENCES core_routes (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_instance_step_routes_reject FOREIGN KEY (id_core_routes_reject)
    REFERENCES core_routes (id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_wf_instance_step_status
  ON wf_instance_step (id_wf_instance, status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_instance_step_definisi ON wf_instance_step (id_wf_template_step);

-- -----------------------------------------------------------------------------
-- wf_tugas — inbox user + keputusan + routing tolak [TRANSAKSI]
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_tugas (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  -- denormalisasi terukur (query panas inbox); sinkron ditulis engine
  id_wf_instance       bigint NOT NULL,
  id_wf_instance_step  bigint NOT NULL,
  id_core_users        bigint NOT NULL,          -- penerima inbox
  sumber               wf_sumber_tugas NOT NULL, -- ROLE (expand) | USER | ADHOC
  id_core_roles        bigint,                   -- role yg membuat user eligible (audit)
  status               wf_status_tugas NOT NULL DEFAULT 'MENUNGGU',
  keputusan            wf_keputusan,
  alasan               varchar(300),             -- wajib bila TOLAK
  -- PILIHAN TUJUAN saat TOLAK — ke mana proses selanjutnya dituju:
  tipe_tujuan          wf_tipe_tujuan,
  id_core_users_tujuan bigint,                   -- bila USER
  urutan_step_tujuan   int,                      -- bila STEP
  selesai_pada         timestamptz,
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_wf_tugas_entity_id UNIQUE (entity_id),
  -- satu tugas per user per langkah; dibuka ulang = RESET baris (log di wf_log)
  CONSTRAINT uq_wf_tugas_step_users UNIQUE (id_wf_instance_step, id_core_users),
  CONSTRAINT ck_wf_tugas_tolak_alasan CHECK (keputusan <> 'TOLAK' OR alasan IS NOT NULL),
  CONSTRAINT ck_wf_tugas_tolak_tujuan CHECK (keputusan <> 'TOLAK' OR tipe_tujuan IS NOT NULL),
  CONSTRAINT ck_wf_tugas_tujuan_hanya_tolak CHECK (tipe_tujuan IS NULL OR keputusan = 'TOLAK'),
  CONSTRAINT ck_wf_tugas_tujuan_user CHECK (tipe_tujuan <> 'USER' OR id_core_users_tujuan IS NOT NULL),
  CONSTRAINT ck_wf_tugas_tujuan_step CHECK (tipe_tujuan <> 'STEP' OR urutan_step_tujuan IS NOT NULL),
  CONSTRAINT ck_wf_tugas_sumber_role CHECK (sumber <> 'ROLE' OR id_core_roles IS NOT NULL),
  CONSTRAINT fk_wf_tugas_instance FOREIGN KEY (id_wf_instance)
    REFERENCES wf_instance (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_tugas_step FOREIGN KEY (id_wf_instance_step)
    REFERENCES wf_instance_step (id) ON DELETE CASCADE,
  CONSTRAINT fk_wf_tugas_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_tugas_roles FOREIGN KEY (id_core_roles)
    REFERENCES core_roles (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_tugas_users_tujuan FOREIGN KEY (id_core_users_tujuan)
    REFERENCES core_users (id) ON DELETE SET NULL
);

-- INBOX: tugas menunggu milik seorang user
CREATE INDEX IF NOT EXISTS ix_wf_tugas_inbox
  ON wf_tugas (id_core_users, status)
  WHERE status = 'MENUNGGU' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wf_tugas_instance
  ON wf_tugas (id_wf_instance, status) WHERE deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- wf_log — riwayat penuh per instance [LOG/EVENT] append-only
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wf_log (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wf_instance       bigint NOT NULL,
  id_wf_instance_step  bigint,
  id_wf_tugas          bigint,
  id_core_users        bigint,                  -- aktor; NULL = [sistem]
  aksi                 wf_aksi_log NOT NULL,
  urutan_step          int,                     -- posisi langkah saat kejadian
  catatan              text,                    -- prosa bebas (alasan, keterangan)
  -- snapshot hasil routing tolak (beku — riwayat selamat walau FK tujuan null):
  tipe_tujuan          wf_tipe_tujuan,
  id_core_users_tujuan bigint,
  urutan_step_tujuan   int,
  payload              jsonb,                   -- snapshot teknis; tidak difilter
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),  -- beku di log
  deleted_at           timestamptz,             -- selalu NULL
  CONSTRAINT uq_wf_log_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wf_log_instance FOREIGN KEY (id_wf_instance)
    REFERENCES wf_instance (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_log_step FOREIGN KEY (id_wf_instance_step)
    REFERENCES wf_instance_step (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_log_tugas FOREIGN KEY (id_wf_tugas)
    REFERENCES wf_tugas (id) ON DELETE RESTRICT,
  CONSTRAINT fk_wf_log_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT fk_wf_log_users_tujuan FOREIGN KEY (id_core_users_tujuan)
    REFERENCES core_users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_wf_log_instance ON wf_log (id_wf_instance, created_at);
CREATE INDEX IF NOT EXISTS ix_wf_log_aktor ON wf_log (id_core_users, created_at);

-- Kolom reject untuk DB bentuk v1 (di DB segar sudah NOT NULL inline)
ALTER TABLE wf_template_step  ADD COLUMN IF NOT EXISTS id_core_routes_reject bigint;
ALTER TABLE wf_instance_step  ADD COLUMN IF NOT EXISTS id_core_routes_reject bigint;

-- backfill + NOT NULL: kewenangan tolak default = kewenangan setuju
UPDATE wf_template_step SET id_core_routes_reject = id_core_routes_approve
  WHERE id_core_routes_reject IS NULL;
UPDATE wf_instance_step SET id_core_routes_reject = id_core_routes_approve
  WHERE id_core_routes_reject IS NULL;
ALTER TABLE wf_template_step ALTER COLUMN id_core_routes_reject SET NOT NULL;
ALTER TABLE wf_instance_step ALTER COLUMN id_core_routes_reject SET NOT NULL;

-- FK reject — di DB segar sudah inline di CREATE TABLE; blok ini untuk DB v1
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wf_template_step_routes_reject'
                 AND conrelid = 'wf_template_step'::regclass) THEN
    ALTER TABLE wf_template_step ADD CONSTRAINT fk_wf_template_step_routes_reject
      FOREIGN KEY (id_core_routes_reject) REFERENCES core_routes (id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wf_instance_step_routes_reject'
                 AND conrelid = 'wf_instance_step'::regclass) THEN
    ALTER TABLE wf_instance_step ADD CONSTRAINT fk_wf_instance_step_routes_reject
      FOREIGN KEY (id_core_routes_reject) REFERENCES core_routes (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Trigger updated_at — 7 tabel (wf_log append-only sengaja tanpa trigger)
-- -----------------------------------------------------------------------------
-- satu jalur refresh updated_at — CREATE OR REPLACE idempoten (sinkron baseline)
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $fn$;

DO $$
DECLARE
  v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'wf_kategori_proses', 'wf_template', 'wf_template_step', 'wf_template_approver',
    'wf_instance', 'wf_instance_step', 'wf_tugas'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- Seed kategori baku [MASTER] — idempoten; template dibuat lewat manajemen
-- workflow (butuh route & role live, tidak di-seed).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_row record;
BEGIN
  FOR v_row IN
    SELECT m.id AS id_modul, k.kode, k.nama
    FROM (VALUES
      ('purchasing', 'PESANAN',    'Approval Pesanan Pembelian (PO)'),
      ('purchasing', 'RETUR',      'Approval Retur Pembelian'),
      ('accounting', 'JURNAL',     'Approval Jurnal Manual'),
      ('accounting', 'PEMBAYARAN', 'Approval Pembayaran di Atas Ambang'),
      ('hr',         'CUTI',       'Approval Pengajuan Cuti/Izin'),
      ('hr',         'LEMBUR',     'Approval Pengajuan Lembur')
    ) AS k(modul_key, kode, nama)
    JOIN core_modules m ON m.key = k.modul_key::text::core_module_key
  LOOP
    INSERT INTO wf_kategori_proses (id_core_modules, kode, nama, status)
    VALUES (v_row.id_modul, v_row.kode, v_row.nama, 'AKTIF')
    ON CONFLICT (id_core_modules, kode) DO NOTHING;
  END LOOP;
END $$;

COMMIT;
