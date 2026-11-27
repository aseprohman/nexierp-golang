-- =============================================================================
-- PATCH DDL 66-wa.sql — Modul WA (WHATSAPP CRM)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-wa.md (2026-11-16) + keputusan pemilik
--            2026-11-16 (katalog = kurasi produk INV tanpa master kedua; human
--            mode hybrid assign+klaim CFG-WA-07; LLM adapter multi-vendor OpenAI
--            + simulator; multi-nomor per instansi; kontrak M64/M65).
-- Kartu    : docs/arsitektur-database-wa.md (gerbang arsitektur-database).
-- Tanggal  : 2026-11-17
-- Prasyarat: baseline CORE 01-core (core_users, core_modules key='whatsapp-crm'
--            SUDAH baseline id=7 — TANPA ALTER TYPE di patch ini, core_files,
--            core_outbox_events, core_sequences, core_module_configs, fungsi
--            set_updated_at), INV inv_produk, SLS sls_pelanggan.
-- Isi      : 14 tabel wa_* — 7 MASTER (wa_instance, wa_kontak, wa_persona,
--            wa_pengetahuan, wa_aturan_balasan, wa_template, wa_katalog_item)
--            + 3 TRANSAKSI (wa_percakapan, wa_status, wa_kampanye) + 1 LINE
--            (wa_kampanye_penerima) + 3 LOG/EVENT append-only (wa_pesan,
--            wa_llm_pemakaian, wa_analisa_kontak) + 15 enum enum_*_wa (reuse
--            enum_status_aktif CORE utk persona/pengetahuan/aturan) + trigger
--            set_updated_at 14 tabel + seed core_sequences 'kampanye' +
--            core_module_configs CFG-WA-01..10.
-- Integrasi: FK keluar baca-saja — inv_produk (M65; RESTRICT), sls_pelanggan
--            (penautan opsional; SET NULL), core_users (aktor/agen; RESTRICT
--            wajib / SET NULL opsional), core_files (lampiran; SET NULL),
--            core_outbox_events (jejak pesan M54/M64; SET NULL). Status balik
--            ke PGW via pembaruan kejadian pgw_pengiriman_tautan (app-layer).
--            WA tidak pernah menulis entitas modul lain (§7.2 analisa).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            CREATE INDEX IF NOT EXISTS, trigger DROP+CREATE, seed ON CONFLICT
--            DO NOTHING.
-- Catatan  : penomoran HANYA kampanye (STD-08, prefix WK-{yyyyMM}) — percakapan
--            & pesan sengaja tanpa nomor dokumen (A-06). Log transisi mode
--            percakapan menyusul via core_audit_trail (STD-01) — tanpa tabel
--            khusus. Q-02 retensi & Q-03 moderasi story terbuka di dokumen →
--            fase ini tanpa partisi arsip & tanpa status moderasi story.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--             -v ON_ERROR_STOP=1 < ddl/66-wa.sql     (jalankan 2× — identik)
--           Dry-run: { echo 'BEGIN;'; cat ddl/66-wa.sql; echo 'ROLLBACK;'; } \
--             | podman exec -i nexierp-postgres psql -U nexierp -d nexierp
-- =============================================================================

-- =============================================================================
-- §1 ENUM — kosakata status WA (fail-loud: bila tipe sudah ada dengan isi
--    berbeda dari mirror Drizzle schema/wa.ts → EXCEPTION)
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE enum_environment_wa AS ENUM ('SANDBOX','PRODUKSI','SIMULASI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_environment_wa')
     IS DISTINCT FROM ARRAY['SANDBOX','PRODUKSI','SIMULASI']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_environment_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_koneksi_wa AS ENUM ('TERPUTUS','MENUNGGU_QR','TERHUBUNG');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_koneksi_wa')
     IS DISTINCT FROM ARRAY['TERPUTUS','MENUNGGU_QR','TERHUBUNG']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_koneksi_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

-- Mirror ddl/89 (keputusan pemilik 2026-11-24): NON_LLM→BOT, LLM→HYBRID,
-- MATI DIHAPUS (baris eks-MATI dipetakan ke BOT), + nilai AI — kosakata
-- final BOT|HYBRID|AI; kolom FK id_ai_model dari patch 89.
DO $$ BEGIN
  CREATE TYPE enum_mode_chatbot_wa AS ENUM ('BOT','HYBRID','AI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_mode_chatbot_wa')
     IS DISTINCT FROM ARRAY['BOT','HYBRID','AI']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_mode_chatbot_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_fallback_chatbot_wa AS ENUM ('BALAS_TEMPLATE','ESKALASI_AGEN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_fallback_chatbot_wa')
     IS DISTINCT FROM ARRAY['BALAS_TEMPLATE','ESKALASI_AGEN']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_fallback_chatbot_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_mode_percakapan_wa AS ENUM ('BOT','MENUNGGU_AGEN','HUMAN','DITUTUP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_mode_percakapan_wa')
     IS DISTINCT FROM ARRAY['BOT','MENUNGGU_AGEN','HUMAN','DITUTUP']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_mode_percakapan_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_arah_pesan_wa AS ENUM ('MASUK','KELUAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_arah_pesan_wa')
     IS DISTINCT FROM ARRAY['MASUK','KELUAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_arah_pesan_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_pesan_wa AS ENUM ('TEKS','GAMBAR','DOKUMEN','UNKNOWN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_pesan_wa')
     IS DISTINCT FROM ARRAY['TEKS','GAMBAR','DOKUMEN','UNKNOWN']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_jenis_pesan_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_kirim_pesan_wa AS ENUM ('ANTRIAN','TERKIRIM','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kirim_pesan_wa')
     IS DISTINCT FROM ARRAY['ANTRIAN','TERKIRIM','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_kirim_pesan_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_katalog_wa AS ENUM ('DIUSULKAN','DISETUJUI','DITOLAK','NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_katalog_wa')
     IS DISTINCT FROM ARRAY['DIUSULKAN','DISETUJUI','DITOLAK','NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_katalog_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_template_wa AS ENUM ('DRAFT','MENUNGGU_MODERASI','AKTIF','NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_template_wa')
     IS DISTINCT FROM ARRAY['DRAFT','MENUNGGU_MODERASI','AKTIF','NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_template_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_template_wa AS ENUM
    ('BOTREPLY','BALASAN_AGEN','FALLBACK_BOT','TAUTAN_BAYAR','NOTIFIKASI','BROADCAST','STATUS_WA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_template_wa')
     IS DISTINCT FROM ARRAY['BOTREPLY','BALASAN_AGEN','FALLBACK_BOT','TAUTAN_BAYAR',
                            'NOTIFIKASI','BROADCAST','STATUS_WA']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_jenis_template_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_publikasi_wa AS ENUM ('DRAFT','TERKIRIM','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_publikasi_wa')
     IS DISTINCT FROM ARRAY['DRAFT','TERKIRIM','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_publikasi_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_kampanye_wa AS ENUM
    ('DRAFT','MENUNGGU_MODERASI','DIJADWALKAN','BERJALAN','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kampanye_wa')
     IS DISTINCT FROM ARRAY['DRAFT','MENUNGGU_MODERASI','DIJADWALKAN','BERJALAN',
                            'SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_kampanye_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_penerima_wa AS ENUM ('DIANTRIKAN','TERKIRIM','GAGAL','DILEWATI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_penerima_wa')
     IS DISTINCT FROM ARRAY['DIANTRIKAN','TERKIRIM','GAGAL','DILEWATI']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_status_penerima_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_sentimen_wa AS ENUM ('POSITIF','NETRAL','NEGATIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sentimen_wa')
     IS DISTINCT FROM ARRAY['POSITIF','NETRAL','NEGATIF']::text[] THEN
    RAISE EXCEPTION 'PATCH 66-wa: enum_sentimen_wa kosakata menyimpang dari mirror';
  END IF;
END $$;

-- =============================================================================
-- §2 TABEL MASTER — urutan dependensi FK (persona dulu: wa_instance memakai
--    id_wa_persona; template dulu: wa_aturan_balasan memakai id_wa_template)
-- =============================================================================

-- [MASTER] Persona chatbot — prompt LLM (karakter/gaya/batasan/few-shot);
-- konten prosa bebas = text (pengecualian tipe teks yang disepakati).
CREATE TABLE IF NOT EXISTS wa_persona (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  nama           varchar(100) NOT NULL,
  karakter       text,
  gaya_bahasa    text,
  batasan        text,
  bahasa         varchar(50) NOT NULL DEFAULT 'id',
  contoh_few_shot text,
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  revisi         integer NOT NULL DEFAULT 1,
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_wa_persona_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_persona_nama_hidup ON wa_persona (nama) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_persona IS
  'MASTER persona chatbot (kepribadian & batasan prompt LLM) — WA-F05; revisi = nomor revisi konten, version = optimistic lock.';

CREATE INDEX IF NOT EXISTS ix_wa_persona_status
  ON wa_persona (status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Instance/nomor WhatsApp tersambung Evolution API + konfigurasi
-- chatbot 1:1 (F01/F03). Kredensial disimpan TERENKRIPSI app-layer (WA-BR08);
-- nomor dipakai ulang setelah hapus lunak (WA-BR07 → partial unique hidup);
-- tepat satu instance default outbox (CFG-WA-01 → partial unique boolean).
CREATE TABLE IF NOT EXISTS wa_instance (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  nama            varchar(100) NOT NULL,
  nomor           varchar(50) NOT NULL,
  environment     enum_environment_wa NOT NULL DEFAULT 'PRODUKSI',
  base_url        varchar(300),
  apikey          varchar(300),
  webhook_token   varchar(100),
  status_koneksi  enum_status_koneksi_wa NOT NULL DEFAULT 'TERPUTUS',
  mode_chatbot    enum_mode_chatbot_wa NOT NULL DEFAULT 'BOT',
  fallback        enum_fallback_chatbot_wa NOT NULL DEFAULT 'BALAS_TEMPLATE',
  ambang_eskalasi integer NOT NULL DEFAULT 3,
  id_wa_persona   bigint,
  default_outbox  boolean NOT NULL DEFAULT false,
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_wa_instance_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_instance_persona FOREIGN KEY (id_wa_persona)
    REFERENCES wa_persona (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_instance_ambang_positif CHECK (ambang_eskalasi > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_instance_nomor_hidup ON wa_instance (nomor) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_instance_default_outbox_hidup ON wa_instance (default_outbox)
  WHERE default_outbox AND deleted_at IS NULL;

COMMENT ON TABLE wa_instance IS
  'MASTER instance WhatsApp (Evolution API) + konfigurasi chatbot per nomor — WA-F01/F03; satu persona aktif per instance ditegakkan bentuk lewat satu kolom id_wa_persona (WA-BR13).';

CREATE INDEX IF NOT EXISTS ix_wa_instance_status
  ON wa_instance (status_koneksi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wa_instance_persona
  ON wa_instance (id_wa_persona) WHERE id_wa_persona IS NOT NULL;

-- [MASTER] Kontak WhatsApp pelanggan — GLOBAL per perusahaan (bukan per
-- instance); penautan opsional ke sls_pelanggan (A-05) selamat dari hapus
-- pelanggan (SET NULL); opt-out broadcast (Q-06/WA-BR22).
CREATE TABLE IF NOT EXISTS wa_kontak (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id         uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_wa          varchar(50) NOT NULL,
  nama_profil       varchar(100),
  opt_out_broadcast boolean NOT NULL DEFAULT false,
  id_sls_pelanggan  bigint,
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT uq_wa_kontak_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_kontak_sls_pelanggan FOREIGN KEY (id_sls_pelanggan)
    REFERENCES sls_pelanggan (id) ON UPDATE CASCADE ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_kontak_nomor_hidup ON wa_kontak (nomor_wa) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_kontak IS
  'MASTER kontak WhatsApp (pelanggan CRM kanal WA) — WA-F02; nomor unik hidup global.';

CREATE INDEX IF NOT EXISTS ix_wa_kontak_optout
  ON wa_kontak (opt_out_broadcast) WHERE opt_out_broadcast;

-- [MASTER] Template pesan bermoderasi (7 jenis §4.1) — hanya AKTIF ter-setujui
-- dipakai kirim (WA-BR17); SoD penyusun ≠ penyetuju (WA-BR03); revisi template
-- AKTIF kembali MENUNGGU_MODERASI (§4.2).
CREATE TABLE IF NOT EXISTS wa_template (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                    varchar(100) NOT NULL,
  jenis                   enum_jenis_template_wa NOT NULL,
  isi                     text NOT NULL,
  variabel                jsonb NOT NULL DEFAULT '[]',
  status                  enum_status_template_wa NOT NULL DEFAULT 'DRAFT',
  alasan_moderasi         varchar(300),
  id_core_users_disusun   bigint NOT NULL,
  id_core_users_disetujui bigint,
  penyetuju_sistem        boolean NOT NULL DEFAULT false,
  revisi                  integer NOT NULL DEFAULT 1,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_wa_template_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_template_disusun FOREIGN KEY (id_core_users_disusun)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_template_disetujui FOREIGN KEY (id_core_users_disetujui)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_template_sod CHECK (
    id_core_users_disetujui IS NULL OR id_core_users_disusun IS NULL
    OR id_core_users_disetujui <> id_core_users_disusun),
  CONSTRAINT ck_wa_template_aktif_bersetuju CHECK (
    status <> 'AKTIF' OR id_core_users_disetujui IS NOT NULL OR penyetuju_sistem)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_template_nama_hidup ON wa_template (nama) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_template IS
  'MASTER template pesan bermoderasi — WA-F08; konsumen: bot, agen (canned), worker outbox M54/M64, broadcast, status WA.';

CREATE INDEX IF NOT EXISTS ix_wa_template_render
  ON wa_template (jenis, status) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Basis pengetahuan LLM (FAQ/dokumen/teks) — retrieval sederhana
-- keyword+prioritas+budget token (A-08 tanpa vector); NONAKTIF tidak ikut
-- prompt (WA-BR14).
CREATE TABLE IF NOT EXISTS wa_pengetahuan (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id    uuid NOT NULL DEFAULT gen_random_uuid(),
  judul        varchar(200) NOT NULL,
  isi          text NOT NULL,
  kategori     varchar(100) NOT NULL DEFAULT 'umum',
  prioritas    integer NOT NULL DEFAULT 0,
  id_core_files bigint,
  status       enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  revisi       integer NOT NULL DEFAULT 1,
  version      integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  CONSTRAINT uq_wa_pengetahuan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_pengetahuan_core_files FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON UPDATE CASCADE ON DELETE SET NULL
);
COMMENT ON TABLE wa_pengetahuan IS
  'MASTER basis pengetahuan chatbot LLM — WA-F06; lampiran via core_files (pemilik CORE).';

CREATE INDEX IF NOT EXISTS ix_wa_pengetahuan_retrieval
  ON wa_pengetahuan (prioritas DESC) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Aturan keyword → template balasan (mode NON-LLM) — fallback tak
-- cocok mengikuti CFG-WA-02 (WA-BR10); pencocokan per pesan masuk = index
-- panas (instance, prioritas).
CREATE TABLE IF NOT EXISTS wa_aturan_balasan (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_instance bigint NOT NULL,
  pola_keyword   varchar(300) NOT NULL,
  id_wa_template bigint NOT NULL,
  prioritas      integer NOT NULL DEFAULT 0,
  status         enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version        integer NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_wa_aturan_balasan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_aturan_balasan_instance FOREIGN KEY (id_wa_instance)
    REFERENCES wa_instance (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_aturan_balasan_template FOREIGN KEY (id_wa_template)
    REFERENCES wa_template (id) ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_aturan_balasan_pola_hidup ON wa_aturan_balasan (id_wa_instance, pola_keyword) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_aturan_balasan IS
  'MASTER aturan balasan chatbot NON-LLM — WA-F03; balasan = template AKTIF (render server-side WA-BR17).';

CREATE INDEX IF NOT EXISTS ix_wa_aturan_balasan_match
  ON wa_aturan_balasan (id_wa_instance, prioritas DESC)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- [MASTER] Kurasi produk INV yang boleh ditawarkan bot (F07) — TANPA master
-- produk kedua (keputusan pemilik 2026-11-16); harga master selalu dari INV
-- via M65 (IN-03); harga_promo_override berlaku HANYA bila DISETUJUI
-- (WA-BR15/BR16); SoD pengusul ≠ penyetuju (WA-BR03).
CREATE TABLE IF NOT EXISTS wa_katalog_item (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  id_inv_produk           bigint NOT NULL,
  teks_tawar_override     text,
  harga_promo_override    numeric(18,4),
  status                  enum_status_katalog_wa NOT NULL DEFAULT 'DIUSULKAN',
  alasan_moderasi         varchar(300),
  id_core_users_diusulkan   bigint NOT NULL,
  id_core_users_disetujui   bigint,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_wa_katalog_item_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_katalog_item_inv_produk FOREIGN KEY (id_inv_produk)
    REFERENCES inv_produk (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_katalog_item_diusulkan FOREIGN KEY (id_core_users_diusulkan)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_katalog_item_disetujui FOREIGN KEY (id_core_users_disetujui)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_katalog_item_sod CHECK (
    id_core_users_disetujui IS NULL OR id_core_users_diusulkan IS NULL
    OR id_core_users_disetujui <> id_core_users_diusulkan),
  CONSTRAINT ck_wa_katalog_item_ditolak_alasan CHECK (
    status <> 'DITOLAK' OR alasan_moderasi IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_katalog_item_produk_hidup ON wa_katalog_item (id_inv_produk) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_katalog_item IS
  'MASTER kurasi katalog chatbot dari produk INV — WA-F07; transisi DIUSULKAN→DISETUJUI/DITOLAK, DISETUJUI↔NONAKTIF (§4.2); produk INV nonaktif → item NONAKTIF + audit (job, BR16).';

CREATE INDEX IF NOT EXISTS ix_wa_katalog_item_tawar
  ON wa_katalog_item (status) WHERE status = 'DISETUJUI' AND deleted_at IS NULL;

-- =============================================================================
-- §3 TABEL TRANSAKSI + LINE + LOG/EVENT — urutan dependensi FK
-- =============================================================================

-- [TRANSAKSI] Sesi chat satu kontak pada satu instance — lifecycle
-- BOT→MENUNGGU_AGEN→HUMAN→DITUTUP (§4.2); DITUTUP → chat lagi = sesi baru
-- mulai BOT; version = optimistic lock klaim/assign (WA-BR11 → 409);
-- HUMAN wajib berpemilik agen; tanpa nomor dokumen (A-06).
CREATE TABLE IF NOT EXISTS wa_percakapan (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id          uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_instance     bigint NOT NULL,
  id_wa_kontak       bigint NOT NULL,
  mode               enum_mode_percakapan_wa NOT NULL DEFAULT 'BOT',
  id_core_users_agen bigint,
  waktu_mulai        timestamptz NOT NULL DEFAULT now(),
  waktu_tutup        timestamptz,
  alasan_tutup       varchar(300),
  version            integer NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz,
  CONSTRAINT uq_wa_percakapan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_percakapan_instance FOREIGN KEY (id_wa_instance)
    REFERENCES wa_instance (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_percakapan_kontak FOREIGN KEY (id_wa_kontak)
    REFERENCES wa_kontak (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_percakapan_agen FOREIGN KEY (id_core_users_agen)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_percakapan_human_pemilik CHECK (
    mode <> 'HUMAN' OR id_core_users_agen IS NOT NULL),
  CONSTRAINT ck_wa_percakapan_tutup CHECK (
    mode <> 'DITUTUP' OR waktu_tutup IS NOT NULL)
);
COMMENT ON TABLE wa_percakapan IS
  'TRANSAKSI percakapan WhatsApp — WA-F02/F04; transisi mode ter-audit via core_audit_trail (aktor/waktu/alasan).';

CREATE INDEX IF NOT EXISTS ix_wa_percakapan_antrian_sla
  ON wa_percakapan (created_at)
  WHERE mode = 'MENUNGGU_AGEN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_wa_percakapan_inbox
  ON wa_percakapan (id_wa_kontak, created_at);
CREATE INDEX IF NOT EXISTS ix_wa_percakapan_agen
  ON wa_percakapan (id_core_users_agen) WHERE id_core_users_agen IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_wa_percakapan_instance
  ON wa_percakapan (id_wa_instance, created_at);

-- [LOG/EVENT] Pesan masuk/keluar — APPEND-ONLY (tanpa UPDATE isi; §5.3
-- deviasi). Idempoten webhook per id vendor (WA-BR09); satu event outbox →
-- maks satu pesan (WA-BR19); pesan keluar wajib status akhir (WA-BR17).
CREATE TABLE IF NOT EXISTS wa_pesan (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_percakapan     bigint NOT NULL,
  arah                 enum_arah_pesan_wa NOT NULL,
  jenis                enum_jenis_pesan_wa NOT NULL DEFAULT 'TEKS',
  isi                  text,
  url_media            varchar(300),
  status_kirim         enum_status_kirim_pesan_wa,
  kode_gagal           varchar(50),
  waktu_kirim          timestamptz,
  id_wa_template       bigint,
  id_core_outbox_event bigint,
  id_eksternal         varchar(150),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT uq_wa_pesan_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_pesan_percakapan FOREIGN KEY (id_wa_percakapan)
    REFERENCES wa_percakapan (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_pesan_template FOREIGN KEY (id_wa_template)
    REFERENCES wa_template (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT fk_wa_pesan_outbox FOREIGN KEY (id_core_outbox_event)
    REFERENCES core_outbox_events (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_pesan_keluar_status CHECK (
    arah <> 'KELUAR' OR status_kirim IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_pesan_eksternal ON wa_pesan (id_eksternal) WHERE id_eksternal IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_pesan_event ON wa_pesan (id_core_outbox_event) WHERE id_core_outbox_event IS NOT NULL;

COMMENT ON TABLE wa_pesan IS
  'LOG/EVENT pesan WhatsApp append-only — WA-F02/F10; idempoten webhook WA-BR09, jejak outbox M54/M64 WA-BR19; isi tidak pernah di-update (koreksi = pesan baru).';

CREATE INDEX IF NOT EXISTS ix_wa_pesan_timeline
  ON wa_pesan (id_wa_percakapan, created_at);
CREATE INDEX IF NOT EXISTS ix_wa_pesan_gagal
  ON wa_pesan (status_kirim, created_at)
  WHERE arah = 'KELUAR' AND status_kirim = 'GAGAL';

-- [TRANSAKSI] Konten WhatsApp status (story) — DRAFT/TERKIRIM/GAGAL (Q-03
-- moderasi terbuka → tanpa MENUNGGU_MODERASI); konten via template jenis
-- STATUS_WA ATAU prosa langsung (xor); rate CFG-WA-06 (WA-BR18).
CREATE TABLE IF NOT EXISTS wa_status (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_instance  bigint NOT NULL,
  id_wa_template  bigint,
  konten          text,
  status          enum_status_publikasi_wa NOT NULL DEFAULT 'DRAFT',
  kode_gagal      varchar(50),
  waktu_kirim     timestamptz,
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_wa_status_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_status_instance FOREIGN KEY (id_wa_instance)
    REFERENCES wa_instance (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_status_template FOREIGN KEY (id_wa_template)
    REFERENCES wa_template (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_status_konten CHECK (
    id_wa_template IS NOT NULL OR konten IS NOT NULL),
  CONSTRAINT ck_wa_status_terkirim CHECK (
    status <> 'TERKIRIM' OR waktu_kirim IS NOT NULL)
);
COMMENT ON TABLE wa_status IS
  'TRANSAKSI WhatsApp status (story) — WA-F09; kirim dibatasi rate CFG-WA-06; instance TERPUTUS ditolak app-layer (WA-BR18).';

CREATE INDEX IF NOT EXISTS ix_wa_status_instance
  ON wa_status (id_wa_instance, created_at);

-- [TRANSAKSI] Broadcast kampanye bermoderasi (F13) — SATU-SATUNYA entitas WA
-- berpenomoran (STD-08: core_sequences doc 'kampanye', WK-{yyyyMM}); SoD
-- penyusun ≠ penyetuju (WA-BR03); batal wajib alasan (WA-BR04/BR22).
CREATE TABLE IF NOT EXISTS wa_kampanye (
  id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id               uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                   varchar(150) NOT NULL,
  nama                    varchar(200) NOT NULL,
  id_wa_template          bigint NOT NULL,
  segmen_filter           jsonb NOT NULL DEFAULT '{}',
  jadwal                  timestamptz,
  rate_limit              integer,
  status                  enum_status_kampanye_wa NOT NULL DEFAULT 'DRAFT',
  alasan_batal            varchar(300),
  id_core_users_disusun   bigint NOT NULL,
  id_core_users_disetujui bigint,
  version                 integer NOT NULL DEFAULT 1,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_wa_kampanye_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_wa_kampanye_nomor UNIQUE (nomor),
  CONSTRAINT fk_wa_kampanye_template FOREIGN KEY (id_wa_template)
    REFERENCES wa_template (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_kampanye_disusun FOREIGN KEY (id_core_users_disusun)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_kampanye_disetujui FOREIGN KEY (id_core_users_disetujui)
    REFERENCES core_users (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_kampanye_sod CHECK (
    id_core_users_disetujui IS NULL OR id_core_users_disusun IS NULL
    OR id_core_users_disetujui <> id_core_users_disusun),
  CONSTRAINT ck_wa_kampanye_batal_alasan CHECK (
    status <> 'DIBATALKAN' OR alasan_batal IS NOT NULL)
);
COMMENT ON TABLE wa_kampanye IS
  'TRANSAKSI broadcast kampanye — WA-F13; segmen_filter jsonb (kriteria kontak, dievaluasi app-layer saat enqueue — bukan join SQL); transisi §4.2; berjalan dapat dibatalkan — sisa antrian tidak terkirim.';

CREATE INDEX IF NOT EXISTS ix_wa_kampanye_sweep
  ON wa_kampanye (status, jadwal)
  WHERE status IN ('DIJADWALKAN','BERJALAN') AND deleted_at IS NULL;

-- [LINE] Baris penerima kampanye — progres per kontak (terkirim/gagal/skip
-- opt-out; F13/WA-BR22); LINE murni: tanpa entity_id/version, CASCADE ke
-- parent (konvensi pgw_rekonsiliasi_baris).
CREATE TABLE IF NOT EXISTS wa_kampanye_penerima (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_wa_kampanye    bigint NOT NULL,
  id_wa_kontak      bigint NOT NULL,
  status            enum_status_penerima_wa NOT NULL DEFAULT 'DIANTRIKAN',
  id_wa_pesan       bigint,
  alasan_lewat      varchar(300),
  waktu_kirim       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  CONSTRAINT fk_wa_kampanye_penerima_kampanye FOREIGN KEY (id_wa_kampanye)
    REFERENCES wa_kampanye (id) ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_wa_kampanye_penerima_kontak FOREIGN KEY (id_wa_kontak)
    REFERENCES wa_kontak (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_wa_kampanye_penerima_pesan FOREIGN KEY (id_wa_pesan)
    REFERENCES wa_pesan (id) ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT ck_wa_kampanye_penerima_lewat CHECK (
    status <> 'DILEWATI' OR alasan_lewat IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wa_kampanye_penerima_hidup ON wa_kampanye_penerima (id_wa_kampanye, id_wa_kontak) WHERE deleted_at IS NULL;

COMMENT ON TABLE wa_kampanye_penerima IS
  'LINE penerima kampanye — entitas implisit F13; skip opt-out terekam beralasan (WA-BR22); link hasil ke wa_pesan.';

CREATE INDEX IF NOT EXISTS ix_wa_kampanye_penerima_progres
  ON wa_kampanye_penerima (id_wa_kampanye, status);

-- [LOG/EVENT] Ledger biaya panggilan LLM — APPEND-ONLY, ditulis SEBELUM
-- balasan dikirim (WA-BR20); biaya = mata uang VENDOR (A-04; Q-04 konversi
-- IDR terbuka → tanpa kolom IDR); model bebas format (adapter multi-vendor).
CREATE TABLE IF NOT EXISTS wa_llm_pemakaian (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_percakapan bigint NOT NULL,
  model            varchar(100) NOT NULL,
  token_masuk      integer NOT NULL DEFAULT 0,
  token_keluar     integer NOT NULL DEFAULT 0,
  biaya            numeric(18,4) NOT NULL DEFAULT 0,
  durasi_ms        integer,
  waktu            timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_wa_llm_pemakaian_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_wa_llm_pemakaian_percakapan FOREIGN KEY (id_wa_percakapan)
    REFERENCES wa_percakapan (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_wa_llm_pemakaian_token CHECK (
    token_masuk >= 0 AND token_keluar >= 0 AND biaya >= 0)
);
COMMENT ON TABLE wa_llm_pemakaian IS
  'LOG/EVENT ledger biaya token LLM append-only — WA-F11; sumber agregasi kuota/alert CFG-WA-05 & laporan F11/F14.';

CREATE INDEX IF NOT EXISTS ix_wa_llm_pemakaian_periode
  ON wa_llm_pemakaian (created_at);
CREATE INDEX IF NOT EXISTS ix_wa_llm_pemakaian_percakapan
  ON wa_llm_pemakaian (id_wa_percakapan);

-- [LOG/EVENT] Ringkasan AI per kontak — APPEND versi (WA-BR21: lama tetap
-- terbaca, tidak di-overwrite); versi = nomor versi analisa (bukan optimistic
-- lock; tabel tanpa UPDATE); pemicu manual supervisor / jadwal CFG-WA-08.
CREATE TABLE IF NOT EXISTS wa_analisa_kontak (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id    uuid NOT NULL DEFAULT gen_random_uuid(),
  id_wa_kontak bigint NOT NULL,
  versi        integer NOT NULL,
  ringkasan    text NOT NULL,
  sentimen     enum_sentimen_wa,
  intent       varchar(200),
  dibuat_oleh  varchar(50) NOT NULL DEFAULT 'SISTEM',
  waktu        timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  CONSTRAINT uq_wa_analisa_kontak_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_wa_analisa_kontak_versi UNIQUE (id_wa_kontak, versi),
  CONSTRAINT fk_wa_analisa_kontak_kontak FOREIGN KEY (id_wa_kontak)
    REFERENCES wa_kontak (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT ck_wa_analisa_kontak_versi_positif CHECK (versi > 0)
);
COMMENT ON TABLE wa_analisa_kontak IS
  'LOG/EVENT analisa pelanggan AI berversi — WA-F12; sentimen/intent hasil LLM (nullable bila tak teranalisa); dibaca agen pemilik & supervisor (WA-BR02).';

CREATE INDEX IF NOT EXISTS ix_wa_analisa_kontak_terakhir
  ON wa_analisa_kontak (id_wa_kontak, versi DESC);

-- =============================================================================
-- §4 TRIGGER updated_at — trio trio trio: refresh updated_at tiap UPDATE
--    (fungsi generik set_updated_at() CORE sudah ada)
-- =============================================================================

DO $$ DECLARE v_t text; BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'wa_instance', 'wa_kontak', 'wa_persona', 'wa_pengetahuan',
    'wa_aturan_balasan', 'wa_template', 'wa_katalog_item',
    'wa_percakapan', 'wa_pesan', 'wa_status',
    'wa_kampanye', 'wa_kampanye_penerima',
    'wa_llm_pemakaian', 'wa_analisa_kontak'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- =============================================================================
-- §5 SEED REGISTRY — core_sequences 'kampanye' + core_module_configs
--    CFG-WA-01..10. Registry core_modules key='whatsapp-crm' SUDAH baseline
--    (enum core_module_key + row id=7) → guard fail-loud pola 39-pgw, TANPA
--    ALTER TYPE ADD VALUE.
-- =============================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key::text = 'whatsapp-crm') THEN
    RAISE EXCEPTION 'PATCH 66-wa: registry core_modules key=''whatsapp-crm'' tidak ada — '
      'baseline CORE wajib memuatnya sebelum patch ini';
  END IF;
END $$;

-- Penomoran kampanye (STD-08) — deterministik, counter tidak pernah diturunkan.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, 'kampanye', 'WK-{yyyyMM}', 0, 4
FROM core_modules m WHERE m.key::text = 'whatsapp-crm'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- CFG-WA-01..10 (§4.1 analisa) — nilai default awal; ubah via FE Pengaturan
-- Modul (core_module_configs milik CORE; CFG-WA-09 harga per model = json).
INSERT INTO core_module_configs
  (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-WA-01', '', 'string',
   'Instance WhatsApp default untuk kirim event outbox M54/M64 (pilih id wa_instance; kosong = belum dipilih)'),
  ('CFG-WA-02', 'BALAS_TEMPLATE', 'string',
   'Fallback chatbot NON-LLM saat tak ada aturan cocok: BALAS_TEMPLATE | ESKALASI_AGEN (WA-BR10/BR06)'),
  ('CFG-WA-03', '15', 'number',
   'SLA menunggu agen (menit) sebelum eskalasi/notifikasi — target KPI 15 menit (WA-BR12)'),
  ('CFG-WA-04', '2000', 'number',
   'Budget token basis pengetahuan per request prompt (melebihi → ambil prioritas teratas — WA-BR14)'),
  ('CFG-WA-05', '{"kuota_token":1000000,"periode":"BULANAN","ambang_alert":80}', 'json',
   'Kuota token/biaya LLM per periode + ambang alert persen (habis → LLM dimatikan otomatis — WA-BR20)'),
  ('CFG-WA-06', '{"chat_per_menit":20,"status_per_hari":2}', 'json',
   'Rate limit kirim: chat pesan/menit & status WhatsApp per hari (WA-BR18)'),
  ('CFG-WA-07', 'true', 'boolean',
   'Izinkan agen mengklaim sendiri percakapan dari antrian (human mode hybrid — keputusan pemilik 2026-11-16)'),
  ('CFG-WA-08', '', 'string',
   'Jadwal analisa pelanggan otomatis (kron pola job platform; kosong = hanya manual supervisor — F12/CFG-WA-08)'),
  ('CFG-WA-09', '[{"model":"simulator","input_per_1k":0,"output_per_1k":0}]', 'json',
   'Harga token per model LLM (input/output per 1k token; mata uang vendor — A-04/Q-04)'),
  ('CFG-WA-10', '{"maks_retry":5,"backoff_detik":300}', 'json',
   'Batas retry & backoff pengiriman outbox (M54/M64 — selama tautan/keperluan masih berlaku; WA-BR19)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key::text = 'whatsapp-crm'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

-- =============================================================================
-- §6 VERIFIKASI (introspeksi manual SETELAH apply — bukan bagian eksekusi)
-- =============================================================================
-- Dry-run    : { echo 'BEGIN;'; cat ddl/66-wa.sql; echo 'ROLLBACK;'; } |
--              podman exec -i nexierp-postgres psql -U nexierp -d nexierp
-- Apply      : podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/66-wa.sql   (jalankan 2× — identik)
-- Tabel      : SELECT table_name FROM information_schema.tables
--              WHERE table_name LIKE 'wa\_%' ORDER BY 1;          → 14 baris
-- Enum       : SELECT count(DISTINCT t.typname) FROM pg_type t
--              WHERE t.typname LIKE 'enum\_%\_wa' AND t.typtype='e'; → 15
-- Trigger    : SELECT tgrelid::regclass::text FROM pg_trigger
--              WHERE tgname LIKE 'trg\_wa\_%\_updated\_at';       → 14 baris
-- Sequence   : SELECT doc_name, prefix FROM core_sequences s
--              JOIN core_modules m ON m.id = s.id_core_modules
--              WHERE m.key = 'whatsapp-crm';                      → kampanye WK-
-- Config     : SELECT param_key, value_type FROM core_module_configs c
--              JOIN core_modules m ON m.id = c.id_core_modules
--              WHERE m.key = 'whatsapp-crm' ORDER BY param_key;   → 10 baris
-- =============================================================================
