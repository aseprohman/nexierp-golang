-- =============================================================================
-- PATCH DDL 35-ast.sql — Modul AST (ASSET TETAP / ASET)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-ast-v2.md (blueprint v2 ter-audit — kartu entitas
--            §4.1: aset, kategori_aset, jadwal_penyusutan + dokumen fitur F05
--            revaluasi / F06 disposisi / F07 opname / F09 mutasi; BR AST-BR01…13;
--            CFG-AST-01…08) + docs/audit-analisa-ast-v2.md (keputusan audit v2).
--            Kepemilikan mengikuti peta-modul §4 baris AST (3 entitas) — dokumen
--            fitur turunan dicatat di kartu untuk sinkronisasi peta.
-- Kartu    : docs/arsitektur-database-ast.md (kartu klasifikasi 8 tabel §2 +
--            keputusan desain §1–§4; gerbang arsitektur-database)
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at,
--            core_modules key='asset' [live id 11, enabled=false — aktivasi =
--            aksi admin/seed, BUKAN bagian patch ini], core_sequences dengan 5
--            doc_name asset/bast/transfer/disposal/je — counter hidup) + ACC 30
--            (acc_akun — FK nullable pemetaan akun kategori M36) + PUR kanonik
--            (pur_usulan_aset — jejak usulan registrasi/koreksi M17).
-- Isi      : 8 tabel ast_* — 1 MASTER kebijakan (kategori_aset + pemetaan akun)
--            + 1 MASTER/registrasi (aset) + 6 TRANSAKSI/LINE (jadwal_penyusutan
--            per periode, disposisi, revaluasi, mutasi_aset, opname, opname_temuan
--            LINE) + 11 enum enum_*_ast + trigger set_updated_at 8 tabel + ensure
--            core_sequences module asset (5 existing + 1 baru revaluasi).
-- Integrasi: FK keluar baca-saja — id_acc_akun_* ×4 (pemetaan akun kategori:
--            aset/akumulasi/beban/surplus-defisit revaluasi — M36 RESTRICT
--            nullable), id_core_users (penanggung jawab/penyetuju/pelaksana —
--            SET NULL), id_pur_usulan_aset (jejak usulan M17 USUL/KOREKSI —
--            RESTRICT nullable). AST tidak pernah menulis jurnal — keluaran via
--            M18 (jadwal POSTED/disposisi/revaluasi disetujui) dibukukan ACC.
-- Penomoran: core_sequences module asset — nomor aset → asset:{yyyy} (AST-{yyyy}),
--            nomor opname → bast:{yyyy} (BAST-{yyyy}), nomor mutasi →
--            transfer:{yyyy} (TRF-{yyyy}), nomor disposisi → disposal:{yyyy}
--            (DSP-{yyyy}), nomor jadwal per periode → je:JE-{yyyy-MM}
--            (JE-{yyyy-MM} — baris per-periode dibentuk app saat runtime),
--            nomor revaluasi → revaluasi:{yyyy} (REV-{yyyy} — BARU).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit (guard pg_constraint untuk FK pasca-ADD),
--            CREATE INDEX IF NOT EXISTS, trigger DO-block DROP+CREATE, sequences
--            ON CONFLICT (id_core_modules, doc_name) DO NOTHING (counter tidak
--            pernah diturunkan), guard registry RAISE EXCEPTION bila key='asset'
--            belum ada (pola ddl/30-acc.sql §8.1).
-- Catatan  : LINE (ast_opname_temuan) tanpa entity_id/version (pola tabel baris);
--            uang numeric(18,4), periode/tanggal murni date, waktu kejadian
--            timestamptz. Enum kosakata persis analisa v2 §4.1/§4.2/§5.2.
--            Seed master (kategori aset preset) = seed terpisah — di luar patch
--            DDL ini; registry asset enabled=false tetap (aktivasi = admin/seed).
-- =============================================================================

-- =============================================================================
-- §1 — ENUM (kosakata persis analisa v2 §4.1/§4.2/§5.2; fail-loud bila sudah ada
--      dengan kosakata menyimpang)
-- =============================================================================

-- §4.1 aset: DRAFT | AKTIF | FULLY_DEPRECIATED | DISPOSAL_PENDING | DISPOSED | DIBATALKAN
DO $$ BEGIN
  CREATE TYPE enum_status_aset_ast AS ENUM
    ('DRAFT','AKTIF','FULLY_DEPRECIATED','DISPOSAL_PENDING','DISPOSED','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_aset_ast')
     IS DISTINCT FROM ARRAY['DRAFT','AKTIF','FULLY_DEPRECIATED','DISPOSAL_PENDING','DISPOSED','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_aset_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §4.1 kategori_aset: AKTIF | NONAKTIF
DO $$ BEGIN
  CREATE TYPE enum_status_kategori_aset_ast AS ENUM ('AKTIF','NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kategori_aset_ast')
     IS DISTINCT FROM ARRAY['AKTIF','NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_kategori_aset_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §4.1 jadwal_penyusutan: TERJADWAL | POSTED | DITUNDA
DO $$ BEGIN
  CREATE TYPE enum_status_jadwal_ast AS ENUM ('TERJADWAL','POSTED','DITUNDA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_jadwal_ast')
     IS DISTINCT FROM ARRAY['TERJADWAL','POSTED','DITUNDA']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_jadwal_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §4.1 metode (kategori default / override per aset): GARIS_LURUS | SALDO_MENURUN | UNIT_PRODUKSI
DO $$ BEGIN
  CREATE TYPE enum_metode_penyusutan_ast AS ENUM ('GARIS_LURUS','SALDO_MENURUN','UNIT_PRODUKSI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_metode_penyusutan_ast')
     IS DISTINCT FROM ARRAY['GARIS_LURUS','SALDO_MENURUN','UNIT_PRODUKSI']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_metode_penyusutan_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- CFG-AST-02 konvensi prorata periode pertama: Harian (prorata temporis) · Bulanan penuh · Mulai bulan berikut
DO $$ BEGIN
  CREATE TYPE enum_konvensi_prorata_ast AS ENUM ('HARIAN','BULANAN_PENUH','MULAI_BULAN_BERIKUT');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_konvensi_prorata_ast')
     IS DISTINCT FROM ARRAY['HARIAN','BULANAN_PENUH','MULAI_BULAN_BERIKUT']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_konvensi_prorata_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §5.2 F06 jenis disposisi: dijual, tukar tambah, rusak, hibah
DO $$ BEGIN
  CREATE TYPE enum_jenis_disposisi_ast AS ENUM ('DIJUAL','TUKAR_TAMBAH','RUSAK','HIBAH');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_disposisi_ast')
     IS DISTINCT FROM ARRAY['DIJUAL','TUKAR_TAMBAH','RUSAK','HIBAH']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_jenis_disposisi_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- F06 alur usulan disposisi: ajukan (USULAN) → setuju (DISETUJUI) → M18 sukses (SELESAI);
--     tolak (DITOLAK — aset kembali AKTIF/FULLY_DEPRECIATED); usulan dibatalkan pencatat
DO $$ BEGIN
  CREATE TYPE enum_status_disposisi_ast AS ENUM ('USULAN','DISETUJUI','SELESAI','DITOLAK','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_disposisi_ast')
     IS DISTINCT FROM ARRAY['USULAN','DISETUJUI','SELESAI','DITOLAK','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_disposisi_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- F05 alur usulan revaluasi (SoD AST-BR02; aktif bila CFG-AST-06) — siklus sama dgn disposisi
DO $$ BEGIN
  CREATE TYPE enum_status_revaluasi_ast AS ENUM ('USULAN','DISETUJUI','SELESAI','DITOLAK','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_revaluasi_ast')
     IS DISTINCT FROM ARRAY['USULAN','DISETUJUI','SELESAI','DITOLAK','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_revaluasi_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §5.2 F07 opname: rencana (DRAFT) → survey (BERLANGSUNG) → tutup (SELESAI — diblok
--     bila temuan belum ditindaklanjuti, AST-BR12); batal
DO $$ BEGIN
  CREATE TYPE enum_status_opname_ast AS ENUM ('DRAFT','BERLANGSUNG','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_opname_ast')
     IS DISTINCT FROM ARRAY['DRAFT','BERLANGSUNG','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_status_opname_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §5.2 F07 hasil survey/scan: cocok, pindah lokasi, tidak ditemukan, tidak tercatat
DO $$ BEGIN
  CREATE TYPE enum_hasil_opname_ast AS ENUM ('COCOK','PINDAH_LOKASI','TIDAK_DITEMUKAN','TIDAK_TERCATAT');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_hasil_opname_ast')
     IS DISTINCT FROM ARRAY['COCOK','PINDAH_LOKASI','TIDAK_DITEMUKAN','TIDAK_TERCATAT']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_hasil_opname_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- §5.2 F07 usulan tindak lanjut selisih: mutasi lokasi (F09), usulan disposisi (F06),
--     registrasi aset tak tercatat (F03)
DO $$ BEGIN
  CREATE TYPE enum_tindak_lanjut_opname_ast AS ENUM ('MUTASI_LOKASI','USULAN_DISPOSISI','REGISTRASI_ASET');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_tindak_lanjut_opname_ast')
     IS DISTINCT FROM ARRAY['MUTASI_LOKASI','USULAN_DISPOSISI','REGISTRASI_ASET']::text[] THEN
    RAISE EXCEPTION 'PATCH 35-ast: enum_tindak_lanjut_opname_ast kosakata menyimpang dari mirror';
  END IF;
END $$;

-- =============================================================================
-- §2 — TABEL (urutan dependensi FK: kategori → aset → transaksi → LINE)
-- =============================================================================

-- 2.1 ast_kategori_aset — [MASTER] — kelas aset pemegang kebijakan akuntansi
--     (pemetaan akun M36 ke acc_akun ACC baca-saja; kelengkapan pemetaan tervalidasi
--     app saat simpan/pemakaian — F02/AST-BR01; kolom nullable di DB sesuai kartu)
CREATE TABLE IF NOT EXISTS ast_kategori_aset (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                        varchar(50) NOT NULL,      -- unique partial HIDUP (reusable setelah hapus)
  nama                        varchar(100) NOT NULL,
  metode_default              enum_metode_penyusutan_ast NOT NULL DEFAULT 'GARIS_LURUS',   -- CFG-AST-01
  konvensi_prorata_default    enum_konvensi_prorata_ast NOT NULL DEFAULT 'BULANAN_PENUH',  -- CFG-AST-02
  nilai_residu_default        numeric(18,4) NOT NULL DEFAULT 0,   -- opsional per kategori (A-05, default 0)
  flag_lacak_non_kapitalisasi boolean NOT NULL DEFAULT false,     -- CFG-AST-08 (lacak fisik di bawah threshold)
  id_acc_akun_aset            bigint,                    -- akun aset (RESTRICT nullable — M36)
  id_acc_akun_akumulasi       bigint,                    -- akun akumulasi penyusutan (RESTRICT nullable — M36)
  id_acc_akun_beban           bigint,                    -- akun beban penyusutan (RESTRICT nullable — M36)
  id_acc_akun_revaluasi       bigint,                    -- akun surplus/defisit revaluasi (RESTRICT nullable — M36)
  status                      enum_status_kategori_aset_ast NOT NULL DEFAULT 'AKTIF',  -- NONAKTIF = arsip
  keterangan                  varchar(300),
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_kategori_aset_entity_id UNIQUE (entity_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_kategori_akun_aset') THEN
    ALTER TABLE ast_kategori_aset ADD CONSTRAINT fk_ast_kategori_akun_aset
      FOREIGN KEY (id_acc_akun_aset) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_kategori_akun_akumulasi') THEN
    ALTER TABLE ast_kategori_aset ADD CONSTRAINT fk_ast_kategori_akun_akumulasi
      FOREIGN KEY (id_acc_akun_akumulasi) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_kategori_akun_beban') THEN
    ALTER TABLE ast_kategori_aset ADD CONSTRAINT fk_ast_kategori_akun_beban
      FOREIGN KEY (id_acc_akun_beban) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_kategori_akun_revaluasi') THEN
    ALTER TABLE ast_kategori_aset ADD CONSTRAINT fk_ast_kategori_akun_revaluasi
      FOREIGN KEY (id_acc_akun_revaluasi) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ast_kategori_aset_kode_hidup
  ON ast_kategori_aset (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ast_kategori_aset_status ON ast_kategori_aset (status);
CREATE INDEX IF NOT EXISTS ix_ast_kategori_akun_aset
  ON ast_kategori_aset (id_acc_akun_aset) WHERE id_acc_akun_aset IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ast_kategori_akun_akumulasi
  ON ast_kategori_aset (id_acc_akun_akumulasi) WHERE id_acc_akun_akumulasi IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ast_kategori_akun_beban
  ON ast_kategori_aset (id_acc_akun_beban) WHERE id_acc_akun_beban IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ast_kategori_akun_revaluasi
  ON ast_kategori_aset (id_acc_akun_revaluasi) WHERE id_acc_akun_revaluasi IS NOT NULL;

-- 2.2 ast_aset — [MASTER registrasi] — satu unit barang kapital yang disusutkan &
--     dilacak hingga pelepasan (§4.1; lifecycle §4.2; nomor doc_name asset:{yyyy};
--     jejak usulan M17 = id_pur_usulan_aset; validasi aktivasi (lokasi/PJ terisi,
--     pemetaan akun kategori lengkap) = app-side — F03)
CREATE TABLE IF NOT EXISTS ast_aset (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (penomoran tak dipakai ulang — BR07)
  nama                        varchar(150) NOT NULL,
  id_ast_kategori_aset        bigint NOT NULL,           -- RESTRICT (kategori dgn anggota AKTIF tak boleh hilang)
  tanggal_perolehan           date NOT NULL,
  nilai_perolehan             numeric(18,4) NOT NULL CHECK (nilai_perolehan >= 0),
  nilai_residu                numeric(18,4) NOT NULL DEFAULT 0,
  umur_manfaat_bulan          integer NOT NULL CHECK (umur_manfaat_bulan > 0),
  metode                      enum_metode_penyusutan_ast,  -- NULL = waris kategori (override per aset)
  lokasi                      varchar(150),              -- wajib terisi saat AKTIF (A-04; validasi app)
  id_core_users_penanggung_jawab bigint,                 -- PJ aktif (SET NULL — aktor; wajib saat AKTIF, app)
  id_pur_usulan_aset          bigint,                    -- jejak usulan registrasi/koreksi M17 (RESTRICT nullable)
  status                      enum_status_aset_ast NOT NULL DEFAULT 'DRAFT',
  keterangan                  varchar(300),
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_aset_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_aset_nomor UNIQUE (nomor),
  -- AST-BR03 basis penyusutan positif: residu tidak boleh menyamai/melebihi perolehan
  CONSTRAINT ck_ast_aset_residu
    CHECK (nilai_residu >= 0 AND nilai_residu < nilai_perolehan)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_aset_kategori') THEN
    ALTER TABLE ast_aset ADD CONSTRAINT fk_ast_aset_kategori
      FOREIGN KEY (id_ast_kategori_aset) REFERENCES ast_kategori_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_aset_penanggung_jawab') THEN
    ALTER TABLE ast_aset ADD CONSTRAINT fk_ast_aset_penanggung_jawab
      FOREIGN KEY (id_core_users_penanggung_jawab) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_aset_usulan_pembelian') THEN
    ALTER TABLE ast_aset ADD CONSTRAINT fk_ast_aset_usulan_pembelian
      FOREIGN KEY (id_pur_usulan_aset) REFERENCES pur_usulan_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ast_aset_kategori ON ast_aset (id_ast_kategori_aset);
CREATE INDEX IF NOT EXISTS ix_ast_aset_status ON ast_aset (status);
CREATE INDEX IF NOT EXISTS ix_ast_aset_penanggung_jawab
  ON ast_aset (id_core_users_penanggung_jawab) WHERE id_core_users_penanggung_jawab IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ast_aset_usulan
  ON ast_aset (id_pur_usulan_aset) WHERE id_pur_usulan_aset IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_ast_aset_lokasi ON ast_aset (lokasi);

-- 2.3 ast_jadwal_penyusutan — [TRANSAKSI] — kewajiban penyusutan 1 aset × 1 periode
--     (§4.1; idempoten per aset+periode — partial unique hidup; nomor per-periode
--     doc_name je:JE-{yyyy-MM} — baris doc_name per periode dibentuk app saat runtime;
--     POSTED beku — AST-BR13; DITUNDA = M18 gagal, jadwal ulang periode berikutnya)
CREATE TABLE IF NOT EXISTS ast_jadwal_penyusutan (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (BR07 nomor jadwal)
  id_ast_aset                 bigint NOT NULL,           -- RESTRICT (jadwal POSTED = historis finansial)
  periode                     date NOT NULL,             -- hari-1 periode bulanan (selaras acc_periode)
  beban_periode               numeric(18,4) NOT NULL CHECK (beban_periode >= 0),
  akumulasi_sampai_periode    numeric(18,4) NOT NULL CHECK (akumulasi_sampai_periode >= 0),
  nilai_buku_sisa             numeric(18,4) NOT NULL CHECK (nilai_buku_sisa >= 0),
  status                      enum_status_jadwal_ast NOT NULL DEFAULT 'TERJADWAL',
  keterangan                  varchar(300),              -- alasan DITUNDA (BR13) / jejak jadwal ulang
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_jadwal_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_jadwal_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_jadwal_aset') THEN
    ALTER TABLE ast_jadwal_penyusutan ADD CONSTRAINT fk_ast_jadwal_aset
      FOREIGN KEY (id_ast_aset) REFERENCES ast_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- Idempoten generate/batch per aset × periode (§4.1 "idempoten per aset+periode" —
-- batch ganda tidak melahirkan jadwal kedua; replay aman)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ast_jadwal_aset_periode_hidup
  ON ast_jadwal_penyusutan (id_ast_aset, periode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ast_jadwal_aset ON ast_jadwal_penyusutan (id_ast_aset);
-- Antrean eksekusi batch periode (F04) + antrean retry DITUNDA (BR13)
CREATE INDEX IF NOT EXISTS ix_ast_jadwal_antrian
  ON ast_jadwal_penyusutan (periode)
  WHERE status IN ('TERJADWAL','DITUNDA') AND deleted_at IS NULL;

-- 2.4 ast_disposisi — [TRANSAKSI] — usulan penghapusan/pelepasan aset dgn approval
--     (§5.2 F06 Must; SoD AST-BR02 dicek app; disposisi di atas ambang CFG-AST-05 →
--     + Direktur; nomor doc_name disposal:{yyyy}; M18 idempoten per usulan disposisi;
--     laba/rugi = realisasi − biaya − nilai buku saat eksekusi — bisa negatif)
CREATE TABLE IF NOT EXISTS ast_disposisi (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (DSP-{yyyy})
  id_ast_aset                 bigint NOT NULL,           -- RESTRICT (jejak disposisi = historis)
  jenis                       enum_jenis_disposisi_ast NOT NULL,  -- dijual/tukar tambah/rusak/hibah
  tanggal_disposisi           date NOT NULL,
  nilai_realisasi             numeric(18,4) NOT NULL DEFAULT 0 CHECK (nilai_realisasi >= 0),
  biaya_pelepasan             numeric(18,4) NOT NULL DEFAULT 0 CHECK (biaya_pelepasan >= 0),
  nilai_buku_saat_disposisi   numeric(18,4),             -- snapshot saat eksekusi (NULL = belum dieksekusi)
  laba_rugi                   numeric(18,4),             -- hasil hitung eksekusi (bisa negatif)
  alasan                      varchar(300) NOT NULL,
  alasan_penolakan            varchar(300),              -- wajib saat DITOLAK (§4.2 — jejak alasan)
  id_core_users_disetujui     bigint,                    -- Manajer Keuangan (SET NULL — aktor; SoD app)
  status                      enum_status_disposisi_ast NOT NULL DEFAULT 'USULAN',
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_disposisi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_disposisi_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_disposisi_aset') THEN
    ALTER TABLE ast_disposisi ADD CONSTRAINT fk_ast_disposisi_aset
      FOREIGN KEY (id_ast_aset) REFERENCES ast_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_disposisi_disetujui') THEN
    ALTER TABLE ast_disposisi ADD CONSTRAINT fk_ast_disposisi_disetujui
      FOREIGN KEY (id_core_users_disetujui) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ast_disposisi_aset ON ast_disposisi (id_ast_aset);
CREATE INDEX IF NOT EXISTS ix_ast_disposisi_antrian
  ON ast_disposisi (status) WHERE status IN ('USULAN','DISETUJUI') AND deleted_at IS NULL;

-- 2.5 ast_revaluasi — [TRANSAKSI] — usulan revaluasi dgn approval (§5.2 F05 Should,
--     aktif bila CFG-AST-06; selisih terbukukan ke akun surplus/defisit revaluasi
--     kategori — AST-BR11, dikirim via M18; nomor doc_name revaluasi:{yyyy} BARU;
--     jadwal penyusutan dihitung ulang periode berikutnya — lama tetap ter-audit)
CREATE TABLE IF NOT EXISTS ast_revaluasi (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (REV-{yyyy} — baru)
  id_ast_aset                 bigint NOT NULL,           -- RESTRICT (jejak revaluasi = historis)
  nilai_baru                  numeric(18,4) NOT NULL CHECK (nilai_baru >= 0),
  selisih                     numeric(18,4),             -- diisi saat eksekusi (nilai_baru − nilai tercatat; bisa negatif)
  alasan                      varchar(300) NOT NULL,
  referensi_lampiran          varchar(300),              -- jejak dokumen penilaian eksternal (tanpa FK —
                                                         -- berkas milik pemilik lain; validasi app)
  alasan_penolakan            varchar(300),
  id_core_users_disetujui     bigint,                    -- Manajer Keuangan (SET NULL — aktor; SoD app)
  status                      enum_status_revaluasi_ast NOT NULL DEFAULT 'USULAN',
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_revaluasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_revaluasi_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_revaluasi_aset') THEN
    ALTER TABLE ast_revaluasi ADD CONSTRAINT fk_ast_revaluasi_aset
      FOREIGN KEY (id_ast_aset) REFERENCES ast_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_revaluasi_disetujui') THEN
    ALTER TABLE ast_revaluasi ADD CONSTRAINT fk_ast_revaluasi_disetujui
      FOREIGN KEY (id_core_users_disetujui) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ast_revaluasi_aset ON ast_revaluasi (id_ast_aset);
CREATE INDEX IF NOT EXISTS ix_ast_revaluasi_antrian
  ON ast_revaluasi (status) WHERE status IN ('USULAN','DISETUJUI') AND deleted_at IS NULL;

-- 2.6 ast_mutasi_aset — [TRANSAKSI] — riwayat mutasi lokasi/penanggung jawab
--     (§5.2 F09 Must; A-04: aset punya satu lokasi & satu PJ aktif — kondisi terkini
--     hidup di ast_aset, baris ini = jejak historis; nomor doc_name transfer:{yyyy};
--     PJ lama/baru = snapshot NAMA beku — riwayat selamat dari penghapusan user,
--     pola snapshot baris hr; alasan wajib — F09 kriteria terima)
CREATE TABLE IF NOT EXISTS ast_mutasi_aset (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (TRF-{yyyy})
  id_ast_aset                 bigint NOT NULL,           -- RESTRICT (riwayat mutasi = historis)
  lokasi_lama                 varchar(150) NOT NULL,     -- snapshot sebelum mutasi
  lokasi_baru                 varchar(150) NOT NULL,     -- NULL tidak ada — isi ulang nilai lama bila hanya PJ berubah
  penanggung_jawab_lama       varchar(100),              -- snapshot nama PJ (NULL = sebelumnya kosong)
  penanggung_jawab_baru       varchar(100),              -- snapshot nama PJ baru (NULL = dikosongkan)
  tanggal_mutasi              date NOT NULL,
  alasan                      varchar(300) NOT NULL,
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_mutasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_mutasi_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_mutasi_aset') THEN
    ALTER TABLE ast_mutasi_aset ADD CONSTRAINT fk_ast_mutasi_aset
      FOREIGN KEY (id_ast_aset) REFERENCES ast_aset (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ast_mutasi_aset_tanggal
  ON ast_mutasi_aset (id_ast_aset, tanggal_mutasi);

-- 2.7 ast_opname — [TRANSAKSI] — dokumen opname/survey fisik aset (§5.2 F07 Should,
--     jadwal CFG-AST-07; scope lokasi/kategori; pelaksana ≠ PJ aset — AST-BR05 dicek
--     app; opname TIDAK pernah mengubah data aset langsung — AST-BR12; nomor doc_name
--     bast:{yyyy} — BR07 "nomor opname")
CREATE TABLE IF NOT EXISTS ast_opname (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id                   uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                       varchar(150) NOT NULL,     -- unique GLOBAL (BAST-{yyyy})
  tanggal_opname              date NOT NULL,
  scope_lokasi                varchar(150),              -- scope CFG-AST-07 (per lokasi bila terisi)
  id_ast_kategori_aset        bigint,                    -- scope kategori opsional (SET NULL)
  id_core_users_pelaksana     bigint,                    -- pelaksana survey (SET NULL — aktor; SoD app)
  status                      enum_status_opname_ast NOT NULL DEFAULT 'DRAFT',
  keterangan                  varchar(300),
  version                     integer NOT NULL DEFAULT 1,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT uq_ast_opname_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ast_opname_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_opname_kategori') THEN
    ALTER TABLE ast_opname ADD CONSTRAINT fk_ast_opname_kategori
      FOREIGN KEY (id_ast_kategori_aset) REFERENCES ast_kategori_aset (id) ON DELETE SET NULL;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ast_opname_pelaksana') THEN
    ALTER TABLE ast_opname ADD CONSTRAINT fk_ast_opname_pelaksana
      FOREIGN KEY (id_core_users_pelaksana) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ast_opname_status ON ast_opname (status);
CREATE INDEX IF NOT EXISTS ix_ast_opname_kategori
  ON ast_opname (id_ast_kategori_aset) WHERE id_ast_kategori_aset IS NOT NULL;

-- 2.8 ast_opname_temuan — [LINE of opname] — hasil survey per aset (tanpa entity_id/
--     version — pola tabel baris; berita acara WAJIB untuk selisih — AST-BR12
--     ditegakkan DB; tindak lanjut = keputusan Manajer saat tinjau, nullable utk COCOK)
CREATE TABLE IF NOT EXISTS ast_opname_temuan (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ast_opname               bigint NOT NULL,
  id_ast_aset                 bigint NOT NULL,           -- aset yang di survei (RESTRICT)
  hasil                       enum_hasil_opname_ast NOT NULL,
  lokasi_temuan               varchar(150),              -- lokasi fisik teramati (utk PINDAH_LOKASI)
  berita_acara                varchar(300),              -- wajib utk selisih (CHECK di bawah — BR12)
  tindak_lanjut               enum_tindak_lanjut_opname_ast,  -- mutasi/disposisi/registrasi (F07)
  keterangan                  varchar(300),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  deleted_at                  timestamptz,
  CONSTRAINT fk_ast_opname_temuan_opname FOREIGN KEY (id_ast_opname)
    REFERENCES ast_opname (id) ON DELETE CASCADE,
  CONSTRAINT fk_ast_opname_temuan_aset FOREIGN KEY (id_ast_aset)
    REFERENCES ast_aset (id) ON DELETE RESTRICT,
  -- AST-BR12: selisih (bukan COCOK) wajib punya berita acara
  CONSTRAINT ck_ast_opname_temuan_berita
    CHECK (hasil = 'COCOK' OR berita_acara IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_ast_opname_temuan_opname ON ast_opname_temuan (id_ast_opname);
CREATE INDEX IF NOT EXISTS ix_ast_opname_temuan_aset ON ast_opname_temuan (id_ast_aset);

-- =============================================================================
-- §3 — TRIGGER updated_at (8 tabel ast_* — satu blok DO; set_updated_at() milik
--      baseline CORE 01-core, TIDAK dibuat ulang di sini)
-- =============================================================================

DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'ast_kategori_aset','ast_aset','ast_jadwal_penyusutan','ast_disposisi',
    'ast_revaluasi','ast_mutasi_aset','ast_opname','ast_opname_temuan'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- =============================================================================
-- §4 — SEED PENOMORAN (idempoten — counter existing tidak pernah diturunkan)
-- =============================================================================

-- 4.1 Guard fail-loud registry modul (prasyarat baseline CORE; pola ddl/30-acc.sql §8.1).
--     Catatan: baris registry asset live berstatus enabled=false — patch ini TIDAK
--     mengubah enabled; aktivasi modul = aksi admin/seed terpisah.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'asset') THEN
    RAISE EXCEPTION 'PATCH 35-ast: registry core_modules key=''asset'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;

-- 4.2 core_sequences ensure (module asset) — 5 doc_name existing (counter hidup:
--     asset/bast/transfer/disposal/je) tidak pernah diturunkan — DO NOTHING menang;
--     1 doc_name BARU: revaluasi REV-{yyyy} (pola suffix periode :2026 konsisten
--     dengan disposal/transfer/bast; padding 4 konsisten kelompok aset).
--     doc_name je memakai pola PER-PERIODE (je:JE-{yyyy-MM}) — baris periode baru
--     dibentuk app saat runtime (ensure-if-missing); patch hanya menjamin baris
--     existing tetap ada.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('asset:2026',      'AST-2026',    0, 4),   -- existing (live, counter hidup) — DO NOTHING di situ
  ('bast:2026',       'BAST-2026',   0, 4),   -- existing (live) — DO NOTHING di situ
  ('transfer:2026',   'TRF-2026',    0, 4),   -- existing (live) — DO NOTHING di situ
  ('disposal:2026',   'DSP-2026',    0, 4),   -- existing (live) — DO NOTHING di situ
  ('je:JE-2026-10',   'JE-2026-10',  0, 3),   -- existing (live, pola per-periode) — DO NOTHING di situ
  ('revaluasi:2026',  'REV-2026',    0, 4)    -- BARU (nomor usulan revaluasi F05)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'asset'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- =============================================================================
-- §5 — VERIFIKASI (komentar introspeksi — jalankan manual setelah apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 5.1 Daftar tabel ast_* (harap 8):
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name LIKE 'ast\_%' ESCAPE '\'
-- ORDER BY table_name;
--
-- -- 5.2 Jumlah enum ast (harap 11):
-- SELECT count(*) AS jumlah_enum_ast
-- FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE t.typtype = 'e' AND t.typname LIKE 'enum\_%\_ast' ESCAPE '\'
--   AND n.nspname = 'public';
--
-- -- 5.3 Baris sequences module asset (harap 6; counter existing tidak berubah):
-- SELECT m.key, s.doc_name, s.prefix, s.current_value, s.padding
-- FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
-- WHERE m.key = 'asset' ORDER BY s.doc_name;
--
-- -- 5.4 Trigger set_updated_at pada tabel ast (harap 8):
-- SELECT count(*) AS jumlah_trigger_ast
-- FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
-- WHERE NOT t.tgisinternal AND c.relname LIKE 'ast\_%' ESCAPE '\'
--   AND t.tgname LIKE '%_updated_at';
--
-- -- 5.5 FK lintas modul (harap 9 keluar: 4 acc_akun + 4 core_users + 1 pur_usulan_aset):
-- SELECT conname, conrelid::regclass
-- FROM pg_constraint
-- WHERE contype = 'f' AND conrelid::regclass::text LIKE 'ast%'
-- ORDER BY conname;
--
-- PATCH 35-ast.sql selesai.
