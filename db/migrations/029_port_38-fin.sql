-- +goose Up
-- Porting 1:1 dari ddl/38-fin.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 38-fin.sql — Modul FIN (FINANCE / KEUANGAN)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-fin-v2.md (blueprint v2 ter-audit — kartu entitas
--            §4.1: anggaran, rencana_arus_kas, jadwal_pembayaran; peta status §4.2;
--            BR FIN-BR01…BR12; CFG-FIN-01…08) + docs/audit-analisa-fin-v2.md
--            (P2-1 lifecycle, P2-2 TERLAMBAT, P2-3 pelabelan M31 — diikuti) +
--            kontrak docs/peta-modul.md §5 (M19, M20, M26, M31) & §4 kepemilikan.
-- Kartu    : docs/arsitektur-database-fin.md (kartu klasifikasi 10 tabel §2 +
--            READMODEL §2.1 + keputusan desain §1–§5; gerbang arsitektur-database)
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, core_files, fungsi set_updated_at,
--            core_modules key='finance' [live id 4, enabled], core_sequences) +
--            ACC 30 (acc_akun — FK pemetaan akun→kategori; acc_pembayaran — FK
--            jejak eksekusi M20 SET NULL). ACC live menyediakan pula
--            acc_entri_jurnal & acc_snapshot_harian sebagai sumber kebenaran
--            baca-saja M19/M31 (TANPA FK dari sisi FIN — kontrak, bukan tautan).
-- Isi      : 10 tabel fin_* — 2 MASTER (kategori_anggaran, pemetaan_akun) +
--            5 TRANSAKSI (anggaran versi-baris, rencana_arus_kas versi-baris,
--            jadwal_pembayaran, cek_anggaran jejak M26, realisasi_anggaran
--            [READMODEL]) + 3 LINE (anggaran_alokasi, anggaran_lampiran,
--            arus_kas_baris) + 9 enum enum_*_fin + trigger set_updated_at
--            10 tabel + guard registry finance + ensure core_sequences module
--            finance (3 doc_name baru; 15 legacy finance-* TIDAK disentuh).
-- Integrasi: FK keluar HANYA ke tabel live — id_acc_akun (RESTRICT NOT NULL,
--            pemetaan akun→kategori), id_acc_pembayaran (SET NULL nullable,
--            jejak hasil eksekusi M20), id_core_users (aktor SET NULL),
--            id_core_files (lampiran RESTRICT). Tanpa FK pur_pesanan (cek M26
--            di tahap draft — rujukan string po_draft idempoten), tanpa FK ke
--            pgw_*/ecom_*/rsv_*. FIN tidak pernah menulis jurnal — pemicu ACC.
-- Penomoran: core_sequences module finance BARU — finance-anggaran ANG-{yyyy},
--            finance-arus-kas RAK-{yyyy}, finance-jadwal-pembayaran
--            JDP-{yyyy} (padding 4). fin_cek_anggaran & fin_realisasi_anggaran
--            tidak bernomor (identitas idempoten, bukan dokumen).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit, CREATE INDEX IF NOT EXISTS, trigger
--            DO-block DROP+CREATE, sequences ON CONFLICT DO NOTHING
--            (counter tidak pernah diturunkan).
-- Catatan  : LINE tanpa entity_id/version (pola tabel baris); READMODEL tanpa
--            entity_id/version (pola acc_snapshot_harian). Uang numeric(18,4),
--            rasio numeric(18,6), tanggal murni date, waktu kejadian timestamptz.
--            Data M31 (aging/kas/komitmen) TIDAK disalin jadi tabel FIN —
--            pemilik ACC (acc_snapshot_harian), FIN baca langsung baca-saja.
--            Seed CFG-FIN-01…08 & master (kategori/pemetaan) = seed terpisah,
--            di luar patch ini (pola HR).
-- =============================================================================

-- =============================================================================
-- §1 — ENUM (kosakata persis kartu §1.5 & analisa §4.1/§4.2/CFG; fail-loud bila
--      sudah ada dengan kosakata menyimpang)
-- =============================================================================

-- CFG-FIN-03: periode anggaran
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_periode_anggaran_fin AS ENUM ('BULANAN','KWARTER','TAHUNAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_periode_anggaran_fin')
     IS DISTINCT FROM ARRAY['BULANAN','KWARTER','TAHUNAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_periode_anggaran_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- CFG-FIN-07: horizon rencana arus kas (rolling — fix audit 2026-11-07)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_horizon_kas_fin AS ENUM ('MINGGU_4','BULAN_3','BULAN_12');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_horizon_kas_fin')
     IS DISTINCT FROM ARRAY['MINGGU_4','BULAN_3','BULAN_12']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_horizon_kas_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- CFG-FIN-03: dimensi anggaran (kategori/departemen/cabang; Q-01 "proyek" menunggu
-- keputusan pemilik bisnis — enum diperluas nanti bila disetujui)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_dimensi_anggaran_fin AS ENUM ('KATEGORI','DEPARTEMEN','CABANG');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_dimensi_anggaran_fin')
     IS DISTINCT FROM ARRAY['KATEGORI','DEPARTEMEN','CABANG']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_dimensi_anggaran_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- §4.1/§4.2 analisa — lifecycle anggaran (DITUTUP hanya dari AKTIF — P2-1)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_anggaran_fin AS ENUM
    ('DRAFT','DIAJUKAN','DISETUJUI','AKTIF','DITUTUP','DITOLAK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_anggaran_fin')
     IS DISTINCT FROM ARRAY['DRAFT','DIAJUKAN','DISETUJUI','AKTIF','DITUTUP','DITOLAK']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_status_anggaran_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- §4.1/§4.2 analisa — lifecycle rencana arus kas (versi TERBIT immutable)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_arus_kas_fin AS ENUM ('DRAFT','TERBIT','ARSIP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_arus_kas_fin')
     IS DISTINCT FROM ARRAY['DRAFT','TERBIT','ARSIP']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_status_arus_kas_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- §4.1/§4.2 analisa — lifecycle jadwal pembayaran (transisi keluar TERLAMBAT — P2-2:
-- TERLAMBAT → DIBAYAR via konfirmasi ACC eksekusi ulang; → DIBATALKAN beralasan)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_jadwal_fin AS ENUM
    ('TERJADWAL','JATUH_TEMPO','DIBAYAR','TERLAMBAT','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_jadwal_fin')
     IS DISTINCT FROM ARRAY['TERJADWAL','JATUH_TEMPO','DIBAYAR','TERLAMBAT','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_status_jadwal_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- CFG-FIN-08: urutan prioritas pembayaran baku
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kategori_prioritas_fin AS ENUM
    ('PAJAK','GAJI','PEMASOK_STRATEGIS','OPERASIONAL','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kategori_prioritas_fin')
     IS DISTINCT FROM ARRAY['PAJAK','GAJI','PEMASOK_STRATEGIS','OPERASIONAL','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_kategori_prioritas_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- §4.1 baris_proyeksi: penerimaan (MASUK) / pengeluaran (KELUAR)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_arah_arus_kas_fin AS ENUM ('MASUK','KELUAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_arah_arus_kas_fin')
     IS DISTINCT FROM ARRAY['MASUK','KELUAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_arah_arus_kas_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- FIN-BR11: baris proyeksi hanya dari sumber resmi; asumsi manual wajib berlabel
-- + penanggung jawab (CHECK pada fin_arus_kas_baris)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_sumber_baris_kas_fin AS ENUM
    ('AGING_AR','AGING_AP','JADWAL_PEMBAYARAN','ANGGARAN','ASUMSI_MANUAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_baris_kas_fin')
     IS DISTINCT FROM ARRAY['AGING_AR','AGING_AP','JADWAL_PEMBAYARAN','ANGGARAN','ASUMSI_MANUAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_sumber_baris_kas_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- CFG-FIN-01 + FIN-BR07: keputusan kontrol anggaran M26 (TANPA_CEK = anggaran/kategori
-- tidak ada; IZINKAN_PENGECEKALIAN = blok yang disetujui pengecualiannya oleh Direktur)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_keputusan_cek_fin AS ENUM
    ('TANPA_CEK','IZINKAN','PERINGATKAN','BLOK','IZINKAN_PENGECEKALIAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_keputusan_cek_fin')
     IS DISTINCT FROM ARRAY['TANPA_CEK','IZINKAN','PERINGATKAN','BLOK','IZINKAN_PENGECEKALIAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 38-fin: enum_keputusan_cek_fin kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 — TABEL MASTER (urutan dependensi FK)
-- =============================================================================

-- 2.1 fin_kategori_anggaran — [MASTER] — kategori anggaran (basis alokasi,
--     pemetaan akun, dan identitas kategori pada cek M26)
CREATE TABLE IF NOT EXISTS fin_kategori_anggaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique partial HIDUP
  nama                   varchar(100) NOT NULL,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_kategori_anggaran_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fin_kategori_anggaran_kode_hidup
  ON fin_kategori_anggaran (kode) WHERE deleted_at IS NULL;

-- 2.2 fin_pemetaan_akun — [MASTER] — pemetaan akun COA ACC → kategori anggaran
--     (dipakai akumulasi realisasi M19 — FIN-F04; "kategori tanpa pemetaan" =
--     belum dipetakan). FK acc_akun RESTRICT NOT NULL (deviasi sadar dari
--     "nullable" umum — baris pemetaan tanpa akun tidak bermakna; kartu §2).
CREATE TABLE IF NOT EXISTS fin_pemetaan_akun (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_akun            bigint NOT NULL,           -- RESTRICT (live ACC) — FK di bawah
  id_fin_kategori_anggaran bigint NOT NULL,         -- RESTRICT — FK di bawah
  aktif                  boolean NOT NULL DEFAULT true,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_pemetaan_akun_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fin_pemetaan_akun_akun FOREIGN KEY (id_acc_akun)
    REFERENCES acc_akun (id) ON DELETE RESTRICT,
  CONSTRAINT fk_fin_pemetaan_akun_kategori FOREIGN KEY (id_fin_kategori_anggaran)
    REFERENCES fin_kategori_anggaran (id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fin_pemetaan_akun_akun_hidup
  ON fin_pemetaan_akun (id_acc_akun) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fin_pemetaan_akun_kategori
  ON fin_pemetaan_akun (id_fin_kategori_anggaran);

-- =============================================================================
-- §3 — TABEL TRANSAKSI + LINE + READMODEL
-- =============================================================================

-- 3.1 fin_anggaran — [TRANSAKSI versi = baris] — rencana alokasi dana (analisa §4.1;
--     revisi anggaran AKTIF = baris versi baru + approval ulang — FIN-BR05, pola
--     hr_struktur_gaji; DITUTUP hanya dari AKTIF — FIN-BR12/P2-1; nomor doc_name
--     'finance-anggaran' prefix ANG-{yyyy} — BARU)
CREATE TABLE IF NOT EXISTS fin_anggaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL (per baris versi)
  kode                   varchar(50) NOT NULL,      -- identitas keluarga antar versi
  versi                  integer NOT NULL DEFAULT 1 CHECK (versi >= 1),
  nama                   varchar(100) NOT NULL,
  periode_jenis          enum_periode_anggaran_fin NOT NULL,   -- CFG-FIN-03
  dimensi_jenis          enum_dimensi_anggaran_fin NOT NULL,   -- CFG-FIN-03
  tanggal_mulai          date NOT NULL,
  tanggal_akhir          date NOT NULL,
  status                 enum_status_anggaran_fin NOT NULL DEFAULT 'DRAFT',
  id_core_users_penyusun bigint,                    -- SET NULL (aktor; SoD FIN-BR01 dicek app)
  id_core_users_penyetuju bigint,                   -- SET NULL (aktor)
  disetujui_at           timestamptz,
  catatan                varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_anggaran_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fin_anggaran_nomor UNIQUE (nomor),
  CONSTRAINT ck_fin_anggaran_rentang CHECK (tanggal_akhir >= tanggal_mulai)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fin_anggaran_kode_versi_hidup
  ON fin_anggaran (kode, versi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_status ON fin_anggaran (status);
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_aktif
  ON fin_anggaran (tanggal_mulai, tanggal_akhir)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;    -- lookup M26 (FIN-BR07)
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_penyusun
  ON fin_anggaran (id_core_users_penyusun) WHERE id_core_users_penyusun IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_penyetuju
  ON fin_anggaran (id_core_users_penyetuju) WHERE id_core_users_penyetuju IS NOT NULL;
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_anggaran_penyusun') THEN
    ALTER TABLE fin_anggaran ADD CONSTRAINT fk_fin_anggaran_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_anggaran_penyetuju') THEN
    ALTER TABLE fin_anggaran ADD CONSTRAINT fk_fin_anggaran_penyetuju
      FOREIGN KEY (id_core_users_penyetuju) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd


-- 3.2 fin_anggaran_alokasi — [LINE of anggaran] — baris alokasi per kategori × dimensi
--     (analisa §4.1 baris_alokasi: "kategori akun, nilai per periode"; "alokasi tidak
--     negatif" — kriteria terima F02; ikut versi induk — CASCADE LINE murni)
CREATE TABLE IF NOT EXISTS fin_anggaran_alokasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fin_anggaran        bigint NOT NULL,
  id_fin_kategori_anggaran bigint NOT NULL,         -- RESTRICT — FK di bawah
  dimensi_departemen     varchar(100),              -- rujukan lintas modul TANPA FK (aturan patch; CFG-FIN-03)
  dimensi_cabang         varchar(100),              -- idem
  nilai_per_periode      numeric(18,4) NOT NULL CHECK (nilai_per_periode >= 0),
  keterangan             varchar(200),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_fin_anggaran_alokasi_anggaran FOREIGN KEY (id_fin_anggaran)
    REFERENCES fin_anggaran (id) ON DELETE CASCADE,
  CONSTRAINT fk_fin_anggaran_alokasi_kategori FOREIGN KEY (id_fin_kategori_anggaran)
    REFERENCES fin_kategori_anggaran (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_alokasi_anggaran
  ON fin_anggaran_alokasi (id_fin_anggaran);
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_alokasi_kategori
  ON fin_anggaran_alokasi (id_fin_kategori_anggaran);

-- 3.3 fin_anggaran_lampiran — [LINE of anggaran] — lampiran dokumen anggaran
--     (input FIN-F02 "catatan, lampiran"; id_core_files RESTRICT nullable)
CREATE TABLE IF NOT EXISTS fin_anggaran_lampiran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fin_anggaran        bigint NOT NULL,
  id_core_files          bigint,                    -- berkas fisik (RESTRICT nullable)
  keterangan             varchar(200),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_fin_anggaran_lampiran_anggaran FOREIGN KEY (id_fin_anggaran)
    REFERENCES fin_anggaran (id) ON DELETE CASCADE,
  CONSTRAINT fk_fin_anggaran_lampiran_file FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_lampiran_anggaran
  ON fin_anggaran_lampiran (id_fin_anggaran);
CREATE INDEX IF NOT EXISTS ix_fin_anggaran_lampiran_file
  ON fin_anggaran_lampiran (id_core_files) WHERE id_core_files IS NOT NULL;

-- 3.4 fin_rencana_arus_kas — [TRANSAKSI versi = baris] — proyeksi arus kas per horizon
--     (analisa §4.1; CFG-FIN-07; versi TERBIT immutable, revisi = versi baru, lama →
--     ARSIP; tanggal_snapshot = basis snapshot M31 yang dipakai — kesegaran ≤ 7 hari
--     dicek app terhadap acc_snapshot_harian baca-saja; nomor doc_name
--     'finance-arus-kas' prefix RAK-{yyyy} — BARU)
CREATE TABLE IF NOT EXISTS fin_rencana_arus_kas (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL (per baris versi)
  kode                   varchar(50) NOT NULL,      -- identitas keluarga antar versi
  versi                  integer NOT NULL DEFAULT 1 CHECK (versi >= 1),
  nama                   varchar(100) NOT NULL,
  horizon                enum_horizon_kas_fin NOT NULL,        -- CFG-FIN-07 (MINGGU_4/BULAN_3/BULAN_12)
  status                 enum_status_arus_kas_fin NOT NULL DEFAULT 'DRAFT',
  tanggal_mulai          date NOT NULL,             -- rentang terproyeksi
  tanggal_akhir          date NOT NULL,
  tanggal_snapshot       date,                      -- basis snapshot M31 (baca-saja ACC)
  total_masuk            numeric(18,4) NOT NULL DEFAULT 0,
  total_keluar           numeric(18,4) NOT NULL DEFAULT 0,
  saldo_akhir_proyeksi   numeric(18,4) NOT NULL DEFAULT 0,  -- analisa §4.1
  id_core_users_penerbit bigint,                    -- SET NULL (aktor terbit — Manajer Keuangan)
  terbit_at              timestamptz,
  catatan                varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_rencana_kas_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fin_rencana_kas_nomor UNIQUE (nomor),
  CONSTRAINT ck_fin_rencana_kas_rentang CHECK (tanggal_akhir >= tanggal_mulai),
  CONSTRAINT ck_fin_rencana_kas_terbit CHECK (status <> 'TERBIT' OR terbit_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fin_rencana_kas_kode_versi_hidup
  ON fin_rencana_arus_kas (kode, versi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fin_rencana_kas_status ON fin_rencana_arus_kas (status);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_rencana_kas_penerbit') THEN
    ALTER TABLE fin_rencana_arus_kas ADD CONSTRAINT fk_fin_rencana_kas_penerbit
      FOREIGN KEY (id_core_users_penerbit) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd


-- 3.5 fin_arus_kas_baris — [LINE of rencana kas] — baris proyeksi penerimaan/pengeluaran
--     (analisa §4.1 baris_proyeksi; FIN-BR11: hanya sumber resmi, asumsi manual wajib
--     berlabel + penanggung jawab — CHECK di bawah)
CREATE TABLE IF NOT EXISTS fin_arus_kas_baris (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fin_rencana_arus_kas bigint NOT NULL,
  arah                   enum_arah_arus_kas_fin NOT NULL,      -- MASUK | KELUAR
  sumber                 enum_sumber_baris_kas_fin NOT NULL,   -- FIN-BR11
  tanggal_proyeksi       date NOT NULL,
  nilai                  numeric(18,4) NOT NULL CHECK (nilai >= 0),
  label_asumsi           varchar(200),              -- wajib utk ASUMSI_MANUAL (CHECK)
  id_core_users_penanggung_jawab bigint,            -- wajib utk ASUMSI_MANUAL (CHECK; SET NULL)
  keterangan             varchar(200),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_fin_arus_kas_baris_rencana FOREIGN KEY (id_fin_rencana_arus_kas)
    REFERENCES fin_rencana_arus_kas (id) ON DELETE CASCADE,
  CONSTRAINT ck_fin_arus_kas_baris_asumsi
    CHECK (sumber <> 'ASUMSI_MANUAL' OR (label_asumsi IS NOT NULL
           AND id_core_users_penanggung_jawab IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS ix_fin_arus_kas_baris_rencana
  ON fin_arus_kas_baris (id_fin_rencana_arus_kas);
CREATE INDEX IF NOT EXISTS ix_fin_arus_kas_baris_tanggal
  ON fin_arus_kas_baris (tanggal_proyeksi);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_arus_kas_baris_pj') THEN
    ALTER TABLE fin_arus_kas_baris ADD CONSTRAINT fk_fin_arus_kas_baris_pj
      FOREIGN KEY (id_core_users_penanggung_jawab) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd


-- 3.6 fin_jadwal_pembayaran — [TRANSAKSI] — antrian pembayaran terencana berprioritas
--     (analisa §4.1; CFG-FIN-05/08; eksekusi via M20 ke ACC — FIN tidak pernah membuat
--     pembayaran; DIBAYAR hanya dari konfirmasi ACC — FIN-BR04; idempoten per jadwal_id
--     — tanpa eksekusi ganda; TERLAMBAT punya keluar DIBAYAR/DIBATALKAN — P2-2;
--     nomor doc_name 'finance-jadwal-pembayaran' prefix JDP-{yyyy} — BARU)
CREATE TABLE IF NOT EXISTS fin_jadwal_pembayaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL
  id_acc_pembayaran      bigint,                    -- jejak hasil eksekusi M20 (SET NULL — FK di bawah)
  faktur_ref             varchar(150),              -- rujukan nomor faktur ACC (tanpa FK — aturan patch)
  pemasok_rujukan        varchar(150) NOT NULL,     -- pemasok/mitra (payload M20 kirim sebagai data)
  kategori_prioritas     enum_kategori_prioritas_fin NOT NULL,  -- CFG-FIN-08
  prioritas_urutan       integer,                   -- urutan efektif hasil CFG-FIN-08
  prioritas_override     integer,                   -- override urutan (FIN-BR10)
  alasan_override        varchar(300),              -- override wajib alasan (CHECK — FIN-BR10)
  jumlah                 numeric(18,4) NOT NULL CHECK (jumlah > 0),
  tanggal_jadwal         date NOT NULL,
  status                 enum_status_jadwal_fin NOT NULL DEFAULT 'TERJADWAL',
  alasan_batal           varchar(300),              -- DIBATALKAN wajib alasan (CHECK)
  eksekusi_at            timestamptz,               -- terakhir kirim M20 (idempoten per jadwal_id)
  dibayar_at             timestamptz,               -- konfirmasi ACC (FIN-BR04)
  catatan                varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_jadwal_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_fin_jadwal_nomor UNIQUE (nomor),
  CONSTRAINT ck_fin_jadwal_override_alasan
    CHECK (prioritas_override IS NULL OR alasan_override IS NOT NULL),
  CONSTRAINT ck_fin_jadwal_batal_alasan
    CHECK (status <> 'DIBATALKAN' OR alasan_batal IS NOT NULL),
  CONSTRAINT ck_fin_jadwal_dibayar_waktu
    CHECK (status <> 'DIBAYAR' OR dibayar_at IS NOT NULL)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_jadwal_pembayaran') THEN
    ALTER TABLE fin_jadwal_pembayaran ADD CONSTRAINT fk_fin_jadwal_pembayaran
      FOREIGN KEY (id_acc_pembayaran) REFERENCES acc_pembayaran (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_fin_jadwal_antrian
  ON fin_jadwal_pembayaran (kategori_prioritas, tanggal_jadwal)
  WHERE status IN ('TERJADWAL','JATUH_TEMPO','TERLAMBAT') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fin_jadwal_status ON fin_jadwal_pembayaran (status);
CREATE INDEX IF NOT EXISTS ix_fin_jadwal_tanggal ON fin_jadwal_pembayaran (tanggal_jadwal);
CREATE INDEX IF NOT EXISTS ix_fin_jadwal_pembayaran_acc
  ON fin_jadwal_pembayaran (id_acc_pembayaran) WHERE id_acc_pembayaran IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_fin_jadwal_faktur_ref
  ON fin_jadwal_pembayaran (faktur_ref) WHERE faktur_ref IS NOT NULL;

-- 3.7 fin_cek_anggaran — [TRANSAKSI jejak keputusan M26] — setiap jawaban cek kontrol
--     anggaran dari PUR ter-audit (FIN-BR02; "setiap cek M26 terjawab tercatat" — §1;
--     idempoten per po_draft+kategori — payload IN-04 {po_draft, kategori, nilai};
--     snapshot payload beku saat dijawab; kategori tak terdaftar → TANPA_CEK — FIN-BR07;
--     tanpa nomor dokumen — identitas idempoten, bukan dokumen bernomor)
CREATE TABLE IF NOT EXISTS fin_cek_anggaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  po_draft               varchar(150) NOT NULL,     -- referensi draft PR/PO (tanpa FK — draft belum tentu pur_pesanan)
  kategori               varchar(100) NOT NULL,     -- snapshot payload PUR (bukan FK — log historis)
  id_fin_anggaran        bigint,                    -- anggaran AKTIF dasar keputusan (SET NULL — FK di bawah)
  nilai_dicek            numeric(18,4) NOT NULL CHECK (nilai_dicek >= 0),
  sisa_anggaran          numeric(18,4),             -- NULL bila TANPA_CEK (sisa boleh negatif — overspend)
  toleransi_persen       numeric(18,6),             -- snapshot CFG-FIN-06 saat dijawab
  keputusan              enum_keputusan_cek_fin NOT NULL,
  alasan                 varchar(300),
  id_core_users_pengecualian bigint,                -- Direktur penyetuju pengecualian blok (SET NULL)
  pengecualian_at        timestamptz,
  alasan_pengecualian    varchar(300),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_cek_anggaran_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_fin_cek_anggaran_pengecualian
    CHECK (keputusan <> 'IZINKAN_PENGECEKALIAN' OR id_core_users_pengecualian IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fin_cek_anggaran_po_kategori_hidup
  ON fin_cek_anggaran (po_draft, kategori) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fin_cek_anggaran_keputusan ON fin_cek_anggaran (keputusan);
CREATE INDEX IF NOT EXISTS ix_fin_cek_anggaran_anggaran
  ON fin_cek_anggaran (id_fin_anggaran) WHERE id_fin_anggaran IS NOT NULL;
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_cek_anggaran_anggaran') THEN
    ALTER TABLE fin_cek_anggaran ADD CONSTRAINT fk_fin_cek_anggaran_anggaran
      FOREIGN KEY (id_fin_anggaran) REFERENCES fin_anggaran (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fin_cek_anggaran_pengecualian') THEN
    ALTER TABLE fin_cek_anggaran ADD CONSTRAINT fk_fin_cek_anggaran_pengecualian
      FOREIGN KEY (id_core_users_pengecualian) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd


-- 3.8 fin_realisasi_anggaran — [READMODEL] — agregat turunan realisasi (opsi CFG-FIN-04:
--     komitmen PO + jurnal POSTED) per baris alokasi × bulan kalender. SUMBER KEBENARAN:
--     acc_entri_jurnal POSTED via stream M19 (FIN-BR03 — FIN tidak pernah menghitung
--     realisasi di luar data ACC) + acc_komitmen_po/acc_snapshot_harian (M31, baca-saja).
--     JALUR RECOMPUTE: (a) inkremental — stream idempoten per entri jurnal, upsert UNIQUE
--     (alokasi, periode) + watermark posisi_stream; (b) rebuild penuh — nol-kan lalu
--     agregasi ulang seluruh mutasi POSTED dalam rentang anggaran (selisih vs buku besar
--     ACC wajib 0 — KPI F04). Tanpa entity_id/version (pola acc_snapshot_harian); aman
--     di-drop/rebuild — tidak pernah dirujuk modul lain sebagai sumber.
CREATE TABLE IF NOT EXISTS fin_realisasi_anggaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fin_anggaran_alokasi bigint NOT NULL,          -- CASCADE (turunan penuh — selalu recompute-able)
  periode                date NOT NULL,             -- bulan kalender
  realisasi              numeric(18,4) NOT NULL DEFAULT 0,  -- tanpa CHECK tanda (jurnal pembalik ACC)
  komitmen               numeric(18,4) NOT NULL DEFAULT 0,  -- basis CFG-FIN-04 opsi komitmen
  posisi_stream          bigint,                    -- watermark id acc_entri_jurnal terakhir (tanpa FK — baca-saja)
  dihitung_at            timestamptz NOT NULL DEFAULT now(),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_fin_realisasi_alokasi_periode UNIQUE (id_fin_anggaran_alokasi, periode),
  CONSTRAINT fk_fin_realisasi_alokasi FOREIGN KEY (id_fin_anggaran_alokasi)
    REFERENCES fin_anggaran_alokasi (id) ON DELETE CASCADE
);

-- =============================================================================
-- §4 — TRIGGER updated_at (10 tabel fin_* — satu blok DO; set_updated_at() milik
--      baseline CORE 01-core, TIDAK dibuat ulang di sini)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'fin_kategori_anggaran','fin_pemetaan_akun',
    'fin_anggaran','fin_anggaran_alokasi','fin_anggaran_lampiran',
    'fin_rencana_arus_kas','fin_arus_kas_baris',
    'fin_jadwal_pembayaran','fin_cek_anggaran','fin_realisasi_anggaran'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §5 — GUARD REGISTRY & SEED PENOMORAN (idempoten — lolos restore-DB-segar)
-- =============================================================================

-- 5.1 Guard fail-loud registry modul (prasyarat baseline CORE; pola ddl/30-acc.sql §8.1)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'finance') THEN
    RAISE EXCEPTION 'PATCH 38-fin: registry core_modules key=''finance'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- 5.2 core_sequences ensure (module finance) — HANYA 3 doc_name BARU (insert-if-missing,
--     counter tidak pernah diturunkan). 15 doc_name WARISAN generasi lama
--     (finance-expense EXP, finance-payment PAY, finance-petty PC,
--     finance-reimbursement RMB, finance-loan LN, finance-receipt RCV,
--     finance-kw KW-{yyyy}, finance-transfer TRF, finance-mutation MUT,
--     finance-budget-revision BRV, finance-giro GRO, finance-disbursement DISB,
--     finance-payment-request PAYREQ-{yyyy}, finance-bupot BUPOT-{yyyy},
--     finance-btb BTB-{yyyy}) adalah counter hidup — SENGAJA TIDAK masuk daftar ini
--     dan tidak disentuh (kartu §4.2). Padding 4 konsisten keluarga finance live.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('finance-anggaran',           'ANG-{yyyy}', 0, 4),   -- BARU (nomor fin_anggaran)
  ('finance-arus-kas',           'RAK-{yyyy}', 0, 4),   -- BARU (nomor fin_rencana_arus_kas)
  ('finance-jadwal-pembayaran',  'JDP-{yyyy}', 0, 4)    -- BARU (nomor fin_jadwal_pembayaran)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'finance'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- =============================================================================
-- §6 — VERIFIKASI (komentar introspeksi — jalankan manual setelah apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 6.1 Daftar tabel fin_* (harap 10):
-- SELECT table_name
-- FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name LIKE 'fin\_%' ESCAPE '\'
-- ORDER BY table_name;
-- SELECT count(*) AS jumlah_tabel_fin FROM (
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' AND table_name LIKE 'fin\_%' ESCAPE '\'
-- ) t;
--
-- -- 6.2 Jumlah enum fin (harap 10):
-- SELECT count(*) AS jumlah_enum_fin
-- FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE t.typtype = 'e' AND t.typname LIKE 'enum\_%\_fin' ESCAPE '\'
--   AND n.nspname = 'public';
--
-- -- 6.3 Baris sequences module finance (harap 18 = 15 legacy tak tersentuh + 3 baru;
-- --     counter legacy harus tetap: btb=34, kw=93, mut=40, …):
-- SELECT m.key, s.doc_name, s.prefix, s.current_value, s.padding
-- FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
-- WHERE m.key = 'finance' ORDER BY s.doc_name;
--
-- -- 6.4 Trigger set_updated_at pada tabel fin (harap 10):
-- SELECT count(*) AS jumlah_trigger_fin
-- FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
-- WHERE NOT t.tgisinternal AND c.relname LIKE 'fin\_%' ESCAPE '\'
--   AND t.tgname LIKE '%_updated_at';
--
-- -- 6.5 Constraint & index fin (ringkasan):
-- SELECT c.relname, count(con.oid) AS constraints
-- FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
-- LEFT JOIN pg_constraint con ON con.conrelid = c.oid
-- WHERE c.relkind = 'r' AND c.relname LIKE 'fin\_%' ESCAPE '\'
--   AND n.nspname = 'public'
-- GROUP BY c.relname ORDER BY c.relname;
--
-- PATCH 38-fin.sql selesai.
