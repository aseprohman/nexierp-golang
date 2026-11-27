-- +goose Up
-- Porting 1:1 dari ddl/51-core-log-sinkron.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 51-core-log-sinkron.sql — EKSPANSI CORE: Log Sinkronisasi
--                                           Dapodik/EMIS (layanan antrean)
-- Domain   : OdooLikeERP · Proyek: SISPANDU (cluster aplikasi akademik)
-- Sumber   : akd-v3 (keputusan pemilik 2026-11-10: "log sinkronisasi
--            Dapodik/EMIS — pemilik: CORE, layanan ekspansi untuk eksekusi
--            IN-10 — A-10 direvisi") + kartu entitas sispandu core
--            `log_sinkronisasi_dapodik_emis` + kebutuhan PSN IN-06 (payload
--            EMIS/e-RKAM/ijazah PKPPS) + PPDB ekspor murid (penampung event
--            `ppdb.murid.masuk` — ppdb A-11).
-- Kartu    : docs/arsitektur-database-psn.md §2 baris pertama (D-12).
-- Tanggal  : 2026-11-10
-- Prasyarat: baseline CORE 01-core (core_modules, fungsi set_updated_at).
--            TIDAK ada perubahan registry modul — tabel milik CORE.
-- Isi      : 1 tabel LOG/EVENT append-only `core_log_sinkron_dapodik_emis`
--            + 3 enum enum_*_sinkron_core. Tanpa trigger updated_at
--            (append-only — updated_at beku, deleted_at selalu NULL,
--            tanpa version — D-12).
-- Integrasi: FK keluar baca-saja — core_modules (penghasil payload, nullable:
--            NULL = job CORE sendiri), RESTRICT. Konsumen: AKD IN-10, PSN
--            IN-06, PPDB ekspor murid kelak — modul lain tidak pernah menulis
--            tabel core_* lain; eksekusi koneksi portal Dapodik/EMIS tetap
--            pekerjaan CORE (AKD-BR18/PSN IN-06).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT
--            EXISTS, FK bernama eksplisit, CREATE INDEX IF NOT EXISTS.
-- Catatan  : nomor batch UNIQUE GLOBAL tanpa filter deleted_at (kode tak
--            pernah dipakai ulang — pola D-09 akd); jsonb hanya referensi
--            payload tidak difilter (Fase 3.4).
-- =============================================================================

-- =============================================================================
-- §1 ENUM — 3 tipe baru (fail-loud bila kosakata menyimpang dari mirror)
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_sistem_sinkron_core AS ENUM ('DAPODIK','VERVALPD','DNS','DNT','EMIS','E_RKAM','E_IJAZAH_PKPPS');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sistem_sinkron_core')
     IS DISTINCT FROM ARRAY['DAPODIK','VERVALPD','DNS','DNT','EMIS','E_RKAM','E_IJAZAH_PKPPS']::text[] THEN
    RAISE EXCEPTION 'PATCH 51-core-log-sinkron: enum_sistem_sinkron_core kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_arah_sinkron_core AS ENUM ('IMPOR','EKSPOR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_arah_sinkron_core')
     IS DISTINCT FROM ARRAY['IMPOR','EKSPOR']::text[] THEN
    RAISE EXCEPTION 'PATCH 51-core-log-sinkron: enum_arah_sinkron_core kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_sinkron_core AS ENUM ('BERJALAN','BERHASIL','PARSIAL','GAGAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_sinkron_core')
     IS DISTINCT FROM ARRAY['BERJALAN','BERHASIL','PARSIAL','GAGAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 51-core-log-sinkron: enum_status_sinkron_core kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 TABEL — [LOG/EVENT] append-only (kartu D-12)
-- =============================================================================

CREATE TABLE IF NOT EXISTS core_log_sinkron_dapodik_emis (
  id                            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nomor_batch                   varchar(50) NOT NULL,  -- nomor batch unik (via core_sequences key 'system' kelak / generator CORE)
  id_core_modules               bigint,                -- modul penghasil payload; NULL = job CORE sendiri
  sistem                        enum_sistem_sinkron_core NOT NULL,
  arah                          enum_arah_sinkron_core NOT NULL,
  jenis_data                    varchar(100) NOT NULL, -- murid/ptk/rombel/nilai/ijazah/rkam/diniyah/…
  jumlah_baris                  int NOT NULL DEFAULT 0,
  baris_gagal                   int NOT NULL DEFAULT 0,
  status                        enum_status_sinkron_core NOT NULL DEFAULT 'BERJALAN',
  waktu_mulai                   timestamptz NOT NULL DEFAULT now(),
  waktu_selesai                 timestamptz,
  referensi_payload             jsonb,                 -- referensi/kunci payload asal (outbox key, doc list) — tidak difilter
  pesan_error                   varchar(300),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),  -- beku (append-only, tanpa trigger)
  deleted_at                    timestamptz,                         -- selalu NULL (append-only)
  CONSTRAINT uq_core_log_sinkron_nomor_batch UNIQUE (nomor_batch),   -- GLOBAL — kode tak pernah dipakai ulang
  CONSTRAINT fk_core_log_sinkron_modul FOREIGN KEY (id_core_modules)
    REFERENCES core_modules (id) ON DELETE RESTRICT,
  CONSTRAINT ck_core_log_sinkron_baris CHECK (jumlah_baris >= 0 AND baris_gagal >= 0 AND baris_gagal <= jumlah_baris)
);

-- =============================================================================
-- §3 INDEX — jalur monitoring (pantau gagal/parsial, riwayat per modul)
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_core_log_sinkron_status_waktu
  ON core_log_sinkron_dapodik_emis (status, waktu_mulai);
CREATE INDEX IF NOT EXISTS ix_core_log_sinkron_modul
  ON core_log_sinkron_dapodik_emis (id_core_modules, waktu_mulai);

-- =============================================================================
-- §4 SEED — TIDAK ADA (LOG/EVENT: seed-nya mengalir dari transaksi sinkron;
--    tidak ada registry/CFG baru — pemilik CORE sudah terdaftar key 'system').
-- =============================================================================

-- ddl/51-core-log-sinkron.sql selesai.
