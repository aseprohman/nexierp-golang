-- =============================================================================
-- PATCH DDL 30-acc.sql — Modul ACCOUNTING (ACC) rekonstruksi (basis blueprint v4)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-acc-v4.md (16 entitas; F01–F23; BR01–BR31;
--            CFG-ACC-01–21) + docs/audit-analisa-acc-v4.md (acuan ganda Odoo +
--            peraturan keuangan Indonesia). Kepemilikan mengikuti peta-modul §4
--            (16 entitas ACC).
-- Kartu    : docs/arsitektur-database-acc.md revisi v4 (PP-01…PP-22)
-- Status   : TERPASANG — dieksekusi di DB dev nexierp-postgres (db nexierp) 2026-11-06
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at, enum_status_aktif,
--            core_modules key='accounting' [SUDAH live & enabled], core_sequences,
--            core_module_configs, core_outbox_events, core_audit_trail) + INV
--            (inv_produk) + PUR 25 (core_pemasok, pur_pesanan) + POS 23
--            (pos_pesanan, kolom reserved id_acc_faktur) + SLS 28 (sls_pelanggan,
--            sls_pesanan_penjualan, kolom reserved kode_termin).
-- Isi      : 33 tabel — 11 MASTER (akun_coa, jurnal/buku, pajak+distribusi,
--            posisi_fiskal+pemetaan, termin_pembayaran+cicilan, kurs, periode,
--            model_rekonsiliasi, jurnal_berulang template) + 17 TRANSAKSI/LINE
--            (entri_jurnal+baris, faktur_pelanggan+items+cicilan,
--            faktur_pemasok+items, nota_kredit+items, pembayaran+alokasi,
--            rekonsiliasi_bank+koran+cocok, faktur_pajak+items, bukti_potong,
--            komitmen_po) + 1 READMODEL (snapshot_harian) + 1 LOG (event_log)
--            + 28 enum enum_*_acc + FK setoran/integrasi §5 + trigger
--            set_updated_at 32 tabel + seed registry/sequences/CFG-ACC-01–21/
--            COA 28 akun + 5 induk (§8.4b)/pajak 14/buku 5/periode 2026/kurs/termin/pemetaan
--            metode bayar.
-- Integrasi: kontrak masuk IN-01…IN-09/15/19/20 (M05/M07/M08/M10/M15/M16/M18/
--            M20/M21/M38/M40/M43) via trio idempotensi jenis_sumber+
--            entity_id_sumber (tanpa FK transaksional lintas modul); FK
--            SUNGGUHAN ke master live: core_pemasok, core_metode_bayar,
--            sls_pelanggan, sls_pesanan_penjualan, pur_pesanan, inv_produk;
--            FK setoran NOT VALID: core_metode_bayar.id_acc_akun_kas/
--            pendapatan, pos_pesanan.id_acc_faktur, core_pemasok.kode_termin,
--            sls_pelanggan.kode_termin; outbox keluar M06/M19/M31 app-side.
-- Mirror   : apps/api/src/core/database/schema/acc.ts (1:1) + barrel index.ts
-- Idempoten: aman dijalankan berulang (CREATE IF NOT EXISTS, enum DO-block
--            fail-loud verifikasi kosakata, FK guard pg_constraint, seed
--            ON CONFLICT/NOT EXISTS, trigger DO-block DROP+CREATE).
-- Catatan  : 36 enum legacy `acc_*` lowercase (runtime lama, tak terpakai tabel
--            mana pun) SENGAJA tidak di-drop dan tidak dipakai — kosakata v4
--            memakai `enum_*_acc` UPPERCASE Indonesia sesuai konvensi tabel live
--            (PP-21). Baris core_sequences accounting legacy (JV/KM/KK/INV/PUR/
--            BUPOT) di-REUSE (counter dilanjutkan) — PP-22.
-- =============================================================================

-- =============================================================================
-- §1 — ENUM (kosakata persis blueprint v4; fail-loud bila sudah ada dengan
--      kosakata menyimpang)
-- =============================================================================

DO $$ BEGIN
  CREATE TYPE enum_tipe_akun_acc AS ENUM ('ASET','KEWAJIBAN','MODAL','PENDAPATAN','BEBAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_tipe_akun_acc')
     IS DISTINCT FROM ARRAY['ASET','KEWAJIBAN','MODAL','PENDAPATAN','BEBAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_tipe_akun_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_buku_acc AS ENUM ('PENJUALAN','PEMBELIAN','BANK','KAS','UMUM','PEMBUKA','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_buku_acc')
     IS DISTINCT FROM ARRAY['PENJUALAN','PEMBELIAN','BANK','KAS','UMUM','PEMBUKA','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_buku_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_entri_jurnal_acc AS ENUM ('DRAFT','POSTED','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_entri_jurnal_acc')
     IS DISTINCT FROM ARRAY['DRAFT','POSTED','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_entri_jurnal_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_faktur_pelanggan_acc AS ENUM ('REGULER','UANG_MUKA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_faktur_pelanggan_acc')
     IS DISTINCT FROM ARRAY['REGULER','UANG_MUKA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_faktur_pelanggan_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_sumber_faktur_pelanggan_acc AS ENUM ('SLS','POS','MANUAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_faktur_pelanggan_acc')
     IS DISTINCT FROM ARRAY['SLS','POS','MANUAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_sumber_faktur_pelanggan_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_faktur_acc AS ENUM ('DRAFT','POSTED','LUNAS','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_faktur_acc')
     IS DISTINCT FROM ARRAY['DRAFT','POSTED','LUNAS','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_faktur_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_faktur_pemasok_acc AS ENUM ('DRAFT','DITAHAN_SELISIH','POSTED','LUNAS','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_faktur_pemasok_acc')
     IS DISTINCT FROM ARRAY['DRAFT','DITAHAN_SELISIH','POSTED','LUNAS','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_faktur_pemasok_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_match_acc AS ENUM ('COCOK','SELISIH_TOLERANSI','DI_LUAR_TOLERANSI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_match_acc')
     IS DISTINCT FROM ARRAY['COCOK','SELISIH_TOLERANSI','DI_LUAR_TOLERANSI']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_match_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_nota_acc AS ENUM ('NOTA_KREDIT_PENJUALAN','NOTA_KREDIT_PEMBELIAN','DEBIT_NOTA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_nota_acc')
     IS DISTINCT FROM ARRAY['NOTA_KREDIT_PENJUALAN','NOTA_KREDIT_PEMBELIAN','DEBIT_NOTA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_nota_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_nota_acc AS ENUM ('DRAFT','POSTED','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_nota_acc')
     IS DISTINCT FROM ARRAY['DRAFT','POSTED','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_nota_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_pembayaran_acc AS ENUM ('PEMBAYARAN','REFUND','TRANSFER_INTERNAL','UANG_MUKA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_pembayaran_acc')
     IS DISTINCT FROM ARRAY['PEMBAYARAN','REFUND','TRANSFER_INTERNAL','UANG_MUKA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_pembayaran_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_arah_pembayaran_acc AS ENUM ('MASUK','KELUAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_arah_pembayaran_acc')
     IS DISTINCT FROM ARRAY['MASUK','KELUAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_arah_pembayaran_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_pembayaran_acc AS ENUM ('DRAFT','MENUNGGU_PERSETUJUAN','POSTED','DIREKONSILIASI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pembayaran_acc')
     IS DISTINCT FROM ARRAY['DRAFT','MENUNGGU_PERSETUJUAN','POSTED','DIREKONSILIASI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_pembayaran_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_dokumen_pajak_acc AS ENUM
    ('PPN_KELUARAN','PPN_MASUKAN','PPH_22','PPH_23','PPH_4_2_FINAL','PPH_21_26','PPH_25_29','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_dokumen_pajak_acc')
     IS DISTINCT FROM ARRAY['PPN_KELUARAN','PPN_MASUKAN','PPH_22','PPH_23','PPH_4_2_FINAL','PPH_21_26','PPH_25_29','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_dokumen_pajak_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_basis_pajak_acc AS ENUM ('INCLUSIVE','EXCLUSIVE');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_basis_pajak_acc')
     IS DISTINCT FROM ARRAY['INCLUSIVE','EXCLUSIVE']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_basis_pajak_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_wajib_tempo_pajak_acc AS ENUM ('SAAT_DOKUMEN','BERDASAR_PEMBAYARAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_wajib_tempo_pajak_acc')
     IS DISTINCT FROM ARRAY['SAAT_DOKUMEN','BERDASAR_PEMBAYARAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_wajib_tempo_pajak_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_faktor_dpp_acc AS ENUM ('PENUH','NILAI_LAIN_11_12','SETENGAH','BESARAN_TERTENTU');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_faktor_dpp_acc')
     IS DISTINCT FROM ARRAY['PENUH','NILAI_LAIN_11_12','SETENGAH','BESARAN_TERTENTU']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_faktor_dpp_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_dasar_pemotongan_acc AS ENUM ('BRUTO','BRUTO_50','NILAI_TERTENTU');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_dasar_pemotongan_acc')
     IS DISTINCT FROM ARRAY['BRUTO','BRUTO_50','NILAI_TERTENTU']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_dasar_pemotongan_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_pemetaan_posisi_acc AS ENUM ('PAJAK','AKUN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_pemetaan_posisi_acc')
     IS DISTINCT FROM ARRAY['PAJAK','AKUN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_pemetaan_posisi_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_periode_acc AS ENUM ('BULANAN','KWARTER','TAHUNAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_periode_acc')
     IS DISTINCT FROM ARRAY['BULANAN','KWARTER','TAHUNAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_periode_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_periode_acc AS ENUM ('TERBUKA','TUTUP_SEMENTARA','TERKUNCI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_periode_acc')
     IS DISTINCT FROM ARRAY['TERBUKA','TUTUP_SEMENTARA','TERKUNCI']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_periode_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_rekonsiliasi_acc AS ENUM ('BARU','DALAM_PROSES','SELESAI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_rekonsiliasi_acc')
     IS DISTINCT FROM ARRAY['BARU','DALAM_PROSES','SELESAI']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_rekonsiliasi_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_model_rekonsiliasi_acc AS ENUM
    ('COCOK_SEMPURNA','TOLERANSI_BAYAR_KURANG','USUL_BARIS_LAWAN','PEMETAAN_MITRA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_model_rekonsiliasi_acc')
     IS DISTINCT FROM ARRAY['COCOK_SEMPURNA','TOLERANSI_BAYAR_KURANG','USUL_BARIS_LAWAN','PEMETAAN_MITRA']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_model_rekonsiliasi_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_kurs_acc AS ENUM ('AKUNTANSI','PAJAK_BI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_kurs_acc')
     IS DISTINCT FROM ARRAY['AKUNTANSI','PAJAK_BI']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_jenis_kurs_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_faktur_pajak_acc AS ENUM ('DRAFT','TERBIT','PENGKANTI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_faktur_pajak_acc')
     IS DISTINCT FROM ARRAY['DRAFT','TERBIT','PENGKANTI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_faktur_pajak_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_bukti_potong_acc AS ENUM ('DRAFT','TERBIT','DISAMPAIKAN','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_bukti_potong_acc')
     IS DISTINCT FROM ARRAY['DRAFT','TERBIT','DISAMPAIKAN','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_status_bukti_potong_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_keadaan_komitmen_acc AS ENUM ('CATAT','SESUAIKAN','LEPAS');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_keadaan_komitmen_acc')
     IS DISTINCT FROM ARRAY['CATAT','SESUAIKAN','LEPAS']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_keadaan_komitmen_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_subjek_acc AS ENUM
    ('JURNAL','FAKTUR_PELANGGAN','FAKTUR_PEMASOK','NOTA_KREDIT','PEMBAYARAN',
     'PERIODE','REKONSILIASI','FAKTUR_PAJAK','BUKTI_POTONG','AKUN','PAJAK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_subjek_acc')
     IS DISTINCT FROM ARRAY['JURNAL','FAKTUR_PELANGGAN','FAKTUR_PEMASOK','NOTA_KREDIT','PEMBAYARAN',
       'PERIODE','REKONSILIASI','FAKTUR_PAJAK','BUKTI_POTONG','AKUN','PAJAK']::text[] THEN
    RAISE EXCEPTION 'PATCH 30-acc: enum_subjek_acc kosakata menyimpang dari mirror';
  END IF;
END $$;

-- =============================================================================
-- §2 — TABEL MASTER (urutan dependensi FK)
-- =============================================================================

-- 2.1 acc_akun — [MASTER] — akun_coa (ACC-BR16; akun sistem PP-19)
CREATE TABLE IF NOT EXISTS acc_akun (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode_akun              varchar(50) NOT NULL,      -- unique GLOBAL (PP-05: tak dipakai ulang)
  nama                   varchar(100) NOT NULL,
  tipe                   enum_tipe_akun_acc NOT NULL,
  sub_tipe_laporan       varchar(100),              -- kas|bank|piutang|utang|pajak|outstanding|transit|selisih|suspense|ditangguhkan|dst (mapping laporan F11)
  id_acc_akun_induk      bigint,                    -- hierarki self-FK (di-ADD setelah tabel ada)
  flag_rekonsiliasi      boolean NOT NULL DEFAULT false,  -- akun kas/bank (F08)
  flag_non_posting       boolean NOT NULL DEFAULT false,  -- grup/agregat
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_akun_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_akun_kode UNIQUE (kode_akun)    -- GLOBAL tanpa deleted_at (PP-05)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_akun_induk') THEN
    ALTER TABLE acc_akun ADD CONSTRAINT fk_acc_akun_induk
      FOREIGN KEY (id_acc_akun_induk) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_acc_akun_induk_bukan_diri') THEN
    ALTER TABLE acc_akun ADD CONSTRAINT ck_acc_akun_induk_bukan_diri
      CHECK (id_acc_akun_induk IS NULL OR id_acc_akun_induk <> id);
  END IF;
END $$;

-- 2.2 acc_jurnal — [MASTER] — jurnal (buku; memetakan doc_name penomoran)
CREATE TABLE IF NOT EXISTS acc_jurnal (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique GLOBAL
  nama                   varchar(100) NOT NULL,
  jenis                  enum_jenis_buku_acc NOT NULL,
  id_acc_akun_default    bigint,                    -- akun default buku kas/bank/penjualan
  doc_name_penomoran     varchar(50),               -- doc_name core_sequences untuk entri buku ini
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_jurnal_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_jurnal_kode UNIQUE (kode)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_jurnal_akun_default') THEN
    ALTER TABLE acc_jurnal ADD CONSTRAINT fk_acc_jurnal_akun_default
      FOREIGN KEY (id_acc_akun_default) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 2.3 acc_pajak — [MASTER] — pajak (v4: jenis dokumen PPN/PPh, faktor DPP — ACC-BR28,
--     pembulatan rezim CFG-ACC-19, wajib tempo ACC-BR25, tarif non-identitas ACC-BR29)
CREATE TABLE IF NOT EXISTS acc_pajak (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique GLOBAL
  nama                   varchar(100) NOT NULL,
  jenis_dokumen          enum_jenis_dokumen_pajak_acc NOT NULL,
  rate                   numeric(18,6) NOT NULL CHECK (rate >= 0),
  faktor_dpp             enum_faktor_dpp_acc NOT NULL DEFAULT 'PENUH',      -- ACC-BR28 (PP-16)
  pengali_dpp            numeric(9,6) NOT NULL DEFAULT 1 CHECK (pengali_dpp > 0),  -- 1 / 0.916667 / 0.5 / custom
  basis                  enum_basis_pajak_acc NOT NULL DEFAULT 'EXCLUSIVE',
  wajib_tempo            enum_wajib_tempo_pajak_acc NOT NULL DEFAULT 'SAAT_DOKUMEN',
  kode_dokumen_pajak     varchar(50),               -- kode transaksi FP / kode bukti potong e-Bupot
  dasar_pemotongan       enum_dasar_pemotongan_acc, -- wajib utk PPh (cek app F09)
  pengali_tarif_non_identitas numeric(5,2) NOT NULL DEFAULT 2.00 CHECK (pengali_tarif_non_identitas > 1), -- ACC-BR29: tanpa NPWP = 100% lebih tinggi (2×)
  id_acc_akun_pajak      bigint NOT NULL,           -- akun pajak keluaran/masukan/PPh dipotong
  id_acc_akun_transit    bigint,                    -- wajib bila BERDASAR_PEMBAYARAN (ACC-BR25, CHECK di bawah)
  id_acc_pajak_grup      bigint,                    -- self-FK grup multi-rate (anggota → grup)
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_pajak_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_pajak_kode UNIQUE (kode),
  CONSTRAINT ck_acc_pajak_transit_cash_basis
    CHECK (wajib_tempo <> 'BERDASAR_PEMBAYARAN' OR id_acc_akun_transit IS NOT NULL)  -- ACC-BR25 di DB
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_pajak_akun_pajak') THEN
    ALTER TABLE acc_pajak ADD CONSTRAINT fk_acc_pajak_akun_pajak
      FOREIGN KEY (id_acc_akun_pajak) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_pajak_akun_transit') THEN
    ALTER TABLE acc_pajak ADD CONSTRAINT fk_acc_pajak_akun_transit
      FOREIGN KEY (id_acc_akun_transit) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_pajak_grup') THEN
    ALTER TABLE acc_pajak ADD CONSTRAINT fk_acc_pajak_grup
      FOREIGN KEY (id_acc_pajak_grup) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 2.4 acc_pajak_distribusi — [LINE] master — distribusi_akun (split satu pajak ke beberapa akun)
CREATE TABLE IF NOT EXISTS acc_pajak_distribusi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_pajak           bigint NOT NULL,
  id_acc_akun            bigint NOT NULL,
  persen                 numeric(5,2) NOT NULL CHECK (persen > 0),
  grid_pajak             varchar(100),              -- label grid laporan pajak (F23) utk baris distribusi ini
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_pajak_distribusi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_pajak_distribusi_pasangan UNIQUE (id_acc_pajak, id_acc_akun)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_pajak_distribusi_pajak') THEN
    ALTER TABLE acc_pajak_distribusi ADD CONSTRAINT fk_acc_pajak_distribusi_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_pajak_distribusi_akun') THEN
    ALTER TABLE acc_pajak_distribusi ADD CONSTRAINT fk_acc_pajak_distribusi_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 2.5 acc_posisi_fiskal — [MASTER] — posisi_fiskal (F20; pemetaan pajak & akun per kondisi mitra)
CREATE TABLE IF NOT EXISTS acc_posisi_fiskal (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique GLOBAL
  nama                   varchar(100) NOT NULL,
  jenis_mitra            varchar(100),              -- kondisi: jenis mitra (mis. PKP/BUKAN_PKP/WPLN)
  lokasi                 varchar(100),              -- kondisi: lokasi (mis. EKSPOR/DALAM_NEGERI)
  urutan                 int NOT NULL DEFAULT 0,    -- prioritas bila kondisi bertumpuk (F20)
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_posisi_fiskal_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_posisi_fiskal_kode UNIQUE (kode)
);

-- 2.6 acc_posisi_fiskal_pemetaan — [LINE] master — pemetaan_pajak/pemetaan_akun (F20)
CREATE TABLE IF NOT EXISTS acc_posisi_fiskal_pemetaan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_posisi_fiskal   bigint NOT NULL,
  jenis                  enum_jenis_pemetaan_posisi_acc NOT NULL,
  id_acc_pajak_dari      bigint,                    -- PAJAK: dari pajak → ke pajak (NULL ke = hapus pajak)
  id_acc_pajak_ke        bigint,
  id_acc_akun_dari       bigint,                    -- AKUN: dari akun → ke akun
  id_acc_akun_ke         bigint,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_posisi_pemetaan_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_posisi_pemetaan_pasangan CHECK (
    (jenis = 'PAJAK'  AND id_acc_pajak_dari IS NOT NULL AND id_acc_akun_dari IS NULL AND id_acc_akun_ke IS NULL)
    OR
    (jenis = 'AKUN'   AND id_acc_akun_dari IS NOT NULL AND id_acc_akun_ke IS NOT NULL
                       AND id_acc_pajak_dari IS NULL AND id_acc_pajak_ke IS NULL)
  )
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_posisi_pemetaan_posisi') THEN
    ALTER TABLE acc_posisi_fiskal_pemetaan ADD CONSTRAINT fk_acc_posisi_pemetaan_posisi
      FOREIGN KEY (id_acc_posisi_fiskal) REFERENCES acc_posisi_fiskal (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_posisi_pemetaan_pajak_dari') THEN
    ALTER TABLE acc_posisi_fiskal_pemetaan ADD CONSTRAINT fk_acc_posisi_pemetaan_pajak_dari
      FOREIGN KEY (id_acc_pajak_dari) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_posisi_pemetaan_pajak_ke') THEN
    ALTER TABLE acc_posisi_fiskal_pemetaan ADD CONSTRAINT fk_acc_posisi_pemetaan_pajak_ke
      FOREIGN KEY (id_acc_pajak_ke) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_posisi_pemetaan_akun_dari') THEN
    ALTER TABLE acc_posisi_fiskal_pemetaan ADD CONSTRAINT fk_acc_posisi_pemetaan_akun_dari
      FOREIGN KEY (id_acc_akun_dari) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_posisi_pemetaan_akun_ke') THEN
    ALTER TABLE acc_posisi_fiskal_pemetaan ADD CONSTRAINT fk_acc_posisi_pemetaan_akun_ke
      FOREIGN KEY (id_acc_akun_ke) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 2.7 acc_termin_pembayaran — [MASTER] — termin_pembayaran (F16/BR22; FK target kolom
--     kode_termin live di core_pemasok & sls_pelanggan)
CREATE TABLE IF NOT EXISTS acc_termin_pembayaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique GLOBAL; target FK kode_termin live
  nama                   varchar(100) NOT NULL,
  pakai_diskon_dipercepat boolean NOT NULL DEFAULT false,  -- CFG-ACC-16
  diskon_rate            numeric(5,2),
  diskon_hari            int,
  diskon_mode_pajak      varchar(50),               -- Q-10 (kebijakan dampak pajak diskon dipercepat)
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_termin_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_termin_kode UNIQUE (kode)
);

-- 2.8 acc_termin_pembayaran_cicilan — [LINE] master — baris_cicilan (BR22; total 100% dicek app)
CREATE TABLE IF NOT EXISTS acc_termin_pembayaran_cicilan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_termin_pembayaran bigint NOT NULL,
  urutan                 int NOT NULL DEFAULT 1,
  porsi_persen           numeric(5,2) NOT NULL CHECK (porsi_persen > 0 AND porsi_persen <= 100),
  offset_hari            int NOT NULL DEFAULT 0,
  formula_eom            boolean NOT NULL DEFAULT false,  -- akhir bulan berikutnya
  hari_bulan             int,                       -- hari tetap bulan berikutnya (mis. tgl 25)
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_termin_cicilan_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_termin_cicilan_urutan UNIQUE (id_acc_termin_pembayaran, urutan)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_termin_cicilan_termin') THEN
    ALTER TABLE acc_termin_pembayaran_cicilan ADD CONSTRAINT fk_acc_termin_cicilan_termin
      FOREIGN KEY (id_acc_termin_pembayaran) REFERENCES acc_termin_pembayaran (id) ON DELETE CASCADE;
  END IF;
END $$;

-- 2.9 acc_kurs — [MASTER] — kurs (AKUNTANSI CFG-ACC-06 + PAJAK_BI ACC-BR31/UU PPh 36b)
CREATE TABLE IF NOT EXISTS acc_kurs (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  jenis                  enum_jenis_kurs_acc NOT NULL DEFAULT 'AKUNTANSI',
  kode_mata_uang         varchar(3) NOT NULL,       -- ISO 4217 (selaras core_pemasok.mata_uang)
  tanggal                date NOT NULL,
  kurs                   numeric(18,6) NOT NULL CHECK (kurs > 0),
  sumber                 varchar(100),              -- mis. 'BI_MIDDLE_RATE' / 'MANUAL'
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_kurs_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_kurs_fakta UNIQUE (jenis, kode_mata_uang, tanggal)  -- global (PP-05; revisi = update)
);

-- 2.10 acc_periode — [MASTER kontrol] — periode_akuntansi (F10/BR03/BR23; lock 3 lapis)
CREATE TABLE IF NOT EXISTS acc_periode (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                   varchar(50) NOT NULL,      -- '2026-11'; unique GLOBAL
  jenis                  enum_jenis_periode_acc NOT NULL DEFAULT 'BULANAN',
  tanggal_mulai          date NOT NULL,
  tanggal_selesai        date NOT NULL,
  status                 enum_status_periode_acc NOT NULL DEFAULT 'TERBUKA',
  lock_pajak             date,                      -- CFG-ACC-05/BR23 (entri berdampak pajak digeser)
  lock_lunak             date,                      -- exception ber-alasan ter-log
  lock_keras             date,                      -- permanen, tak dapat dibuka (BR23)
  waktu_kunci            timestamptz,
  id_core_users_penutup  bigint,
  id_core_users_pembuka  bigint,                    -- unlock lunak ter-audit
  alasan_buka            varchar(300),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_periode_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_periode_nama UNIQUE (nama),
  CONSTRAINT ck_acc_periode_rentang CHECK (tanggal_mulai < tanggal_selesai)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_periode_penutup') THEN
    ALTER TABLE acc_periode ADD CONSTRAINT fk_acc_periode_penutup
      FOREIGN KEY (id_core_users_penutup) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_periode_pembuka') THEN
    ALTER TABLE acc_periode ADD CONSTRAINT fk_acc_periode_pembuka
      FOREIGN KEY (id_core_users_pembuka) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;

-- 2.11 acc_model_rekonsiliasi — [MASTER] — model_rekonsiliasi (F08; aturan otomatis berjenjang)
CREATE TABLE IF NOT EXISTS acc_model_rekonsiliasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique GLOBAL
  nama                   varchar(100) NOT NULL,
  jenis                  enum_jenis_model_rekonsiliasi_acc NOT NULL,
  pola_label             varchar(200),              -- pola label/referensi (USUL_BARIS_LAWAN)
  id_core_pemasok        bigint,                    -- PEMETAAN_MITRA: pemasok tetap
  toleransi              numeric(18,4) CHECK (toleransi IS NULL OR toleransi >= 0),
  urutan                 int NOT NULL DEFAULT 0,    -- prioritas eksekusi model
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_model_rkn_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_model_rkn_kode UNIQUE (kode)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_model_rkn_pemasok') THEN
    ALTER TABLE acc_model_rekonsiliasi ADD CONSTRAINT fk_acc_model_rkn_pemasok
      FOREIGN KEY (id_core_pemasok) REFERENCES core_pemasok (id) ON DELETE SET NULL;
  END IF;
END $$;

-- 2.12 acc_jurnal_berulang — [MASTER template] — jurnal berulang F13
CREATE TABLE IF NOT EXISTS acc_jurnal_berulang (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering JRB; unique GLOBAL
  nama                   varchar(100) NOT NULL,
  id_acc_jurnal          bigint NOT NULL,
  frekuensi              enum_jenis_periode_acc NOT NULL DEFAULT 'BULANAN',
  tanggal_mulai          date NOT NULL,
  tanggal_berakhir       date,
  periode_terakhir_digenerate varchar(50),          -- nama periode; idempotensi draft tetap via uq entri (PP-04)
  status                 enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  id_core_users_penyusun bigint NOT NULL,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_jurnal_berulang_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_jurnal_berulang_nomor UNIQUE (nomor)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_jurnal_berulang_jurnal') THEN
    ALTER TABLE acc_jurnal_berulang ADD CONSTRAINT fk_acc_jurnal_berulang_jurnal
      FOREIGN KEY (id_acc_jurnal) REFERENCES acc_jurnal (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_jurnal_berulang_penyusun') THEN
    ALTER TABLE acc_jurnal_berulang ADD CONSTRAINT fk_acc_jurnal_berulang_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 2.13 acc_jurnal_berulang_baris — [LINE] template
CREATE TABLE IF NOT EXISTS acc_jurnal_berulang_baris (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_jurnal_berulang bigint NOT NULL,
  id_acc_akun            bigint NOT NULL,
  deskripsi              varchar(200),
  debit                  numeric(18,4) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  kredit                 numeric(18,4) NOT NULL DEFAULT 0 CHECK (kredit >= 0),
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_jurnal_berulang_baris_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_jurnal_berulang_baris_sisi
    CHECK (NOT (debit > 0 AND kredit > 0) AND (debit > 0 OR kredit > 0))
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_jurnal_berulang_baris_template') THEN
    ALTER TABLE acc_jurnal_berulang_baris ADD CONSTRAINT fk_acc_jurnal_berulang_baris_template
      FOREIGN KEY (id_acc_jurnal_berulang) REFERENCES acc_jurnal_berulang (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_jurnal_berulang_baris_akun') THEN
    ALTER TABLE acc_jurnal_berulang_baris ADD CONSTRAINT fk_acc_jurnal_berulang_baris_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- =============================================================================
-- §3 — TABEL TRANSAKSI + LINE + MIRROR + READMODEL + LOG
-- =============================================================================

-- 3.1 acc_entri_jurnal — [TRANSAKSI] — entri_jurnal header (BR01–BR04; PP-04 idempotensi;
--     STD-11 hash_rantai; reversal self-FK ACC-BR02)
CREATE TABLE IF NOT EXISTS acc_entri_jurnal (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering JV (doc_name 'journal'); unique GLOBAL
  tanggal                date NOT NULL,
  id_acc_jurnal          bigint NOT NULL,
  id_acc_periode         bigint NOT NULL,           -- PP-10
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- jejak idempotensi kontrak IN-01…IN-09/15/19/20 (PP-04)
  status                 enum_status_entri_jurnal_acc NOT NULL DEFAULT 'DRAFT',
  deskripsi              varchar(200),
  path_bukti             varchar(300),
  hash_rantai            varchar(100),              -- STD-11: hash berantai diisi app saat POSTED
  kode_mata_uang         varchar(3),                -- NULL = mata uang dasar (PP-12)
  kurs                   numeric(18,6),
  id_core_users_penyusun  bigint NOT NULL,
  id_core_users_penyetuju bigint,                   -- PP-11 (SoD app ACC-BR05)
  waktu_posting          timestamptz,
  waktu_persetujuan      timestamptz,
  alasan_penolakan       varchar(300),
  id_acc_entri_jurnal_asal bigint,                  -- reversal (di-ADD self-FK setelah tabel ada)
  id_acc_faktur_pelanggan  bigint,                  -- sumber internal (FK §4, pecah siklus)
  id_acc_faktur_pemasok    bigint,
  id_acc_pembayaran        bigint,
  id_acc_nota_kredit       bigint,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_entri_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_entri_nomor UNIQUE (nomor)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_entri_idempoten
  ON acc_entri_jurnal (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;              -- ACC-BR06 (PP-04)
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_entri_reversal
  ON acc_entri_jurnal (id_acc_entri_jurnal_asal)
  WHERE id_acc_entri_jurnal_asal IS NOT NULL AND deleted_at IS NULL;      -- satu reversal per asal (BR02)
CREATE INDEX IF NOT EXISTS ix_acc_entri_posted
  ON acc_entri_jurnal (tanggal) WHERE status = 'POSTED' AND deleted_at IS NULL;   -- muara laporan F11
CREATE INDEX IF NOT EXISTS ix_acc_entri_draft
  ON acc_entri_jurnal (id_acc_periode) WHERE status = 'DRAFT' AND deleted_at IS NULL; -- checklist BR13
CREATE INDEX IF NOT EXISTS ix_acc_entri_periode
  ON acc_entri_jurnal (id_acc_periode, status);

-- 3.2 acc_entri_jurnal_baris — [LINE] — baris debit/kredit (BR01/BR14; masa_pajak grid F23;
--     PP-15 dimensi + distribusi analitik)
CREATE TABLE IF NOT EXISTS acc_entri_jurnal_baris (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_entri_jurnal    bigint NOT NULL,
  id_acc_akun            bigint NOT NULL,
  id_acc_pajak           bigint,                    -- pajak pada baris (grid — F23)
  masa_pajak             varchar(50),               -- masa lapor pajak '2026-11' (BR25/F23; NULL = ikut periode)
  deskripsi              varchar(200),
  debit                  numeric(18,4) NOT NULL DEFAULT 0,
  kredit                 numeric(18,4) NOT NULL DEFAULT 0,
  debit_asing            numeric(18,4),             -- PP-12 (nullable, bila mata uang asing)
  kredit_asing           numeric(18,4),
  dimensi_cabang         varchar(100),              -- PP-15
  dimensi_departemen     varchar(100),              -- PP-15
  distribusi_analitik    jsonb,                     -- PP-15b: {dimensi:persen} multi-dimensi — tak difilter/join DB
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_baris_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_baris_sisi
    CHECK (debit >= 0 AND kredit >= 0 AND NOT (debit > 0 AND kredit > 0))
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_baris_entri') THEN
    ALTER TABLE acc_entri_jurnal_baris ADD CONSTRAINT fk_acc_baris_entri
      FOREIGN KEY (id_acc_entri_jurnal) REFERENCES acc_entri_jurnal (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_baris_akun') THEN
    ALTER TABLE acc_entri_jurnal_baris ADD CONSTRAINT fk_acc_baris_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_baris_pajak') THEN
    ALTER TABLE acc_entri_jurnal_baris ADD CONSTRAINT fk_acc_baris_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_baris_akun ON acc_entri_jurnal_baris (id_acc_akun);      -- buku besar F11
CREATE INDEX IF NOT EXISTS ix_acc_baris_entri ON acc_entri_jurnal_baris (id_acc_entri_jurnal);
CREATE INDEX IF NOT EXISTS ix_acc_baris_pajak_masa
  ON acc_entri_jurnal_baris (masa_pajak) WHERE id_acc_pajak IS NOT NULL AND masa_pajak IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_baris_cabang
  ON acc_entri_jurnal_baris (dimensi_cabang) WHERE dimensi_cabang IS NOT NULL;   -- F14

-- 3.3 acc_faktur_pelanggan — [TRANSAKSI] — faktur pelanggan (F05/BR08; M07/M38; aging AR per
--     cicilan BR22; FK sungguhan ke master SLS live)
CREATE TABLE IF NOT EXISTS acc_faktur_pelanggan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering invoice_sales INV; unique GLOBAL
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- idempoten per invoice_id SLS / pesanan POS (BR08)
  sumber                 enum_sumber_faktur_pelanggan_acc NOT NULL DEFAULT 'MANUAL',
  jenis_faktur           enum_jenis_faktur_pelanggan_acc NOT NULL DEFAULT 'REGULER',
  id_sls_pelanggan       bigint,                    -- FK sungguhan master live (pp-02b); wajib utk sumber POS (app)
  id_sls_pesanan_penjualan bigint,                  -- FK sungguhan; NULL utk manual/POS
  id_acc_termin          bigint,                    -- master termin (F16/BR22); NULL → due manual
  tanggal_faktur         date NOT NULL,
  jatuh_tempo            date NOT NULL,             -- jatuh tempo utama (cicilan rinci di acc_faktur_cicilan)
  kode_mata_uang         varchar(3),
  kurs                   numeric(18,6),
  subtotal               numeric(18,4) NOT NULL DEFAULT 0,
  diskon                 numeric(18,4) NOT NULL DEFAULT 0,
  pajak                  numeric(18,4) NOT NULL DEFAULT 0,
  total                  numeric(18,4) NOT NULL DEFAULT 0,
  sisa                   numeric(18,4) NOT NULL DEFAULT 0,   -- PP-08 (recompute total − Σalokasi − Σnota)
  status                 enum_status_faktur_acc NOT NULL DEFAULT 'DRAFT',
  id_core_users_penyusun bigint NOT NULL,
  alasan_batal           varchar(300),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fktplg_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_fktplg_nomor UNIQUE (nomor)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktplg_idempoten
  ON acc_faktur_pelanggan (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;              -- BR08
CREATE INDEX IF NOT EXISTS ix_acc_fktplg_aging
  ON acc_faktur_pelanggan (id_sls_pelanggan, jatuh_tempo)
  WHERE status = 'POSTED' AND deleted_at IS NULL;                          -- aging & cek limit M25
CREATE INDEX IF NOT EXISTS ix_acc_fktplg_draft
  ON acc_faktur_pelanggan (tanggal_faktur) WHERE status = 'DRAFT' AND deleted_at IS NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_pelanggan') THEN
    ALTER TABLE acc_faktur_pelanggan ADD CONSTRAINT fk_acc_fktplg_pelanggan
      FOREIGN KEY (id_sls_pelanggan) REFERENCES sls_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_pesanan_penjualan') THEN
    ALTER TABLE acc_faktur_pelanggan ADD CONSTRAINT fk_acc_fktplg_pesanan_penjualan
      FOREIGN KEY (id_sls_pesanan_penjualan) REFERENCES sls_pesanan_penjualan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_termin') THEN
    ALTER TABLE acc_faktur_pelanggan ADD CONSTRAINT fk_acc_fktplg_termin
      FOREIGN KEY (id_acc_termin) REFERENCES acc_termin_pembayaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_penyusun') THEN
    ALTER TABLE acc_faktur_pelanggan ADD CONSTRAINT fk_acc_fktplg_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 3.4 acc_faktur_pelanggan_items — [LINE] — snapshot harga & pajak (PP-09/PP-16: pengali_dpp + dpp beku)
CREATE TABLE IF NOT EXISTS acc_faktur_pelanggan_items (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_faktur_pelanggan bigint NOT NULL,
  id_inv_produk          bigint,                    -- master live; NULL utk baris deskripsi bebas
  deskripsi              varchar(200) NOT NULL,
  qty                    int NOT NULL CHECK (qty > 0),
  harga_satuan           numeric(18,4) NOT NULL,
  diskon_persen          numeric(18,6) NOT NULL DEFAULT 0,
  id_acc_pajak           bigint,                    -- RESTRICT (di-ADD di bawah)
  tarif_pajak            numeric(18,6),             -- snapshot PP-09
  basis_pajak            enum_basis_pajak_acc,      -- snapshot
  pengali_dpp            numeric(9,6) NOT NULL DEFAULT 1,   -- snapshot ACC-BR28
  nilai_dpp              numeric(18,4) NOT NULL DEFAULT 0,  -- snapshot DPP beku
  nilai_pajak            numeric(18,4) NOT NULL DEFAULT 0,  -- snapshot (pembulatan rezim — BR26)
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fktplg_items_entity_id UNIQUE (entity_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_items_faktur') THEN
    ALTER TABLE acc_faktur_pelanggan_items ADD CONSTRAINT fk_acc_fktplg_items_faktur
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_items_produk') THEN
    ALTER TABLE acc_faktur_pelanggan_items ADD CONSTRAINT fk_acc_fktplg_items_produk
      FOREIGN KEY (id_inv_produk) REFERENCES inv_produk (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktplg_items_pajak') THEN
    ALTER TABLE acc_faktur_pelanggan_items ADD CONSTRAINT fk_acc_fktplg_items_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_fktplg_items_faktur
  ON acc_faktur_pelanggan_items (id_acc_faktur_pelanggan) WHERE deleted_at IS NULL;

-- 3.5 acc_faktur_cicilan — [LINE] — jatuh tempo per cicilan (BR22: aging & follow-up per cicilan;
--     tepat satu faktur induk)
CREATE TABLE IF NOT EXISTS acc_faktur_cicilan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_faktur_pelanggan bigint,
  id_acc_faktur_pemasok   bigint,
  urutan                 int NOT NULL DEFAULT 1,
  tanggal_jatuh_tempo    date NOT NULL,
  nilai_cicilan          numeric(18,4) NOT NULL CHECK (nilai_cicilan > 0),
  sisa_cicilan           numeric(18,4) NOT NULL DEFAULT 0 CHECK (sisa_cicilan >= 0),  -- PP-08b recompute
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fkt_cicilan_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_fkt_cicilan_tepat_satu
    CHECK ((id_acc_faktur_pelanggan IS NULL) <> (id_acc_faktur_pemasok IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fkt_cicilan_pelanggan
  ON acc_faktur_cicilan (id_acc_faktur_pelanggan, urutan)
  WHERE id_acc_faktur_pelanggan IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fkt_cicilan_pemasok
  ON acc_faktur_cicilan (id_acc_faktur_pemasok, urutan)
  WHERE id_acc_faktur_pemasok IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_fkt_cicilan_jatuh_tempo
  ON acc_faktur_cicilan (tanggal_jatuh_tempo)
  WHERE deleted_at IS NULL AND sisa_cicilan > 0;                            -- aging per cicilan F11/F18
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fkt_cicilan_pelanggan') THEN
    ALTER TABLE acc_faktur_cicilan ADD CONSTRAINT fk_acc_fkt_cicilan_pelanggan
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE CASCADE;
  END IF;
END $$;
-- (fk_acc_fkt_cicilan_pemasok → acc_faktur_pemasok di-ADD di §4 — pecah siklus, tabelnya
--  dibuat pada §3.6)

-- 3.6 acc_faktur_pemasok — [TRANSAKSI] — faktur pemasok 3-way match (F06/BR09; M06; DITAHAN_SELISIH;
--     FK sungguhan core_pemasok & pur_pesanan live)
CREATE TABLE IF NOT EXISTS acc_faktur_pemasok (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering invoice_purchase PUR; unique GLOBAL
  nomor_bill_pemasok     varchar(150) NOT NULL,     -- bill ganda per pemasok ditolak (uq partial di bawah)
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- idempoten per pemicu PUR M08 (BR06)
  id_core_pemasok        bigint NOT NULL,
  id_pur_pesanan_pembelian bigint,                  -- FK sungguhan master live
  receipt_ref            varchar(255),              -- jejak penerimaan PUR (tanpa FK — transaksional)
  id_acc_termin          bigint,
  tanggal                date NOT NULL,
  jatuh_tempo            date NOT NULL,
  kode_mata_uang         varchar(3),
  kurs                   numeric(18,6),
  subtotal               numeric(18,4) NOT NULL DEFAULT 0,
  pajak                  numeric(18,4) NOT NULL DEFAULT 0,
  total                  numeric(18,4) NOT NULL DEFAULT 0,
  sisa                   numeric(18,4) NOT NULL DEFAULT 0,   -- PP-08
  status_match           enum_status_match_acc,     -- COCOK|SELISIH_TOLERANSI|DI_LUAR_TOLERANSI
  status                 enum_status_faktur_pemasok_acc NOT NULL DEFAULT 'DRAFT',
  id_core_users_penyusun bigint NOT NULL,
  alasan_batal           varchar(300),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fktpms_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_fktpms_nomor UNIQUE (nomor)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktpms_idempoten
  ON acc_faktur_pemasok (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fktpms_bill_pemasok
  ON acc_faktur_pemasok (id_core_pemasok, nomor_bill_pemasok)
  WHERE deleted_at IS NULL;                                                 -- F06 kriteria
CREATE INDEX IF NOT EXISTS ix_acc_fktpms_aging
  ON acc_faktur_pemasok (id_core_pemasok, jatuh_tempo)
  WHERE status = 'POSTED' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_fktpms_draft
  ON acc_faktur_pemasok (tanggal) WHERE status IN ('DRAFT','DITAHAN_SELISIH') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_fktpms_po
  ON acc_faktur_pemasok (id_pur_pesanan_pembelian) WHERE id_pur_pesanan_pembelian IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_pemasok') THEN
    ALTER TABLE acc_faktur_pemasok ADD CONSTRAINT fk_acc_fktpms_pemasok
      FOREIGN KEY (id_core_pemasok) REFERENCES core_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_po') THEN
    ALTER TABLE acc_faktur_pemasok ADD CONSTRAINT fk_acc_fktpms_po
      FOREIGN KEY (id_pur_pesanan_pembelian) REFERENCES pur_pesanan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_termin') THEN
    ALTER TABLE acc_faktur_pemasok ADD CONSTRAINT fk_acc_fktpms_termin
      FOREIGN KEY (id_acc_termin) REFERENCES acc_termin_pembayaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_penyusun') THEN
    ALTER TABLE acc_faktur_pemasok ADD CONSTRAINT fk_acc_fktpms_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 3.7 acc_faktur_pemasok_items — [LINE] — snapshot + hasil match (harga_po_snapshot → akun beda harga)
CREATE TABLE IF NOT EXISTS acc_faktur_pemasok_items (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_faktur_pemasok  bigint NOT NULL,
  id_inv_produk          bigint,
  deskripsi              varchar(200) NOT NULL,
  qty                    int NOT NULL CHECK (qty > 0),
  harga_satuan           numeric(18,4) NOT NULL,
  harga_po_snapshot      numeric(18,4),             -- hasil 3-way match (BR09 — dasar buku selisih harga)
  diskon_persen          numeric(18,6) NOT NULL DEFAULT 0,
  id_acc_pajak           bigint,
  tarif_pajak            numeric(18,6),
  basis_pajak            enum_basis_pajak_acc,
  pengali_dpp            numeric(9,6) NOT NULL DEFAULT 1,
  nilai_dpp              numeric(18,4) NOT NULL DEFAULT 0,
  nilai_pajak            numeric(18,4) NOT NULL DEFAULT 0,
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fktpms_items_entity_id UNIQUE (entity_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_items_faktur') THEN
    ALTER TABLE acc_faktur_pemasok_items ADD CONSTRAINT fk_acc_fktpms_items_faktur
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_items_produk') THEN
    ALTER TABLE acc_faktur_pemasok_items ADD CONSTRAINT fk_acc_fktpms_items_produk
      FOREIGN KEY (id_inv_produk) REFERENCES inv_produk (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fktpms_items_pajak') THEN
    ALTER TABLE acc_faktur_pemasok_items ADD CONSTRAINT fk_acc_fktpms_items_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_fktpms_items_faktur
  ON acc_faktur_pemasok_items (id_acc_faktur_pemasok) WHERE deleted_at IS NULL;

-- 3.8 acc_nota_kredit — [TRANSAKSI] — kredit/debit nota (F15/BR17; pemicu M08 NOTA_KREDIT,
--     M15 REFUND, M40 retur penjualan, koreksi manual ber-alasan)
CREATE TABLE IF NOT EXISTS acc_nota_kredit (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering credit_note/debit_note; unique GLOBAL
  nomor_dokumen_asal     varchar(150) NOT NULL,     -- ter-link nomor dokumen asal (BR04/BR17)
  jenis                  enum_jenis_nota_acc NOT NULL,
  id_acc_faktur_pelanggan bigint,
  id_acc_faktur_pemasok  bigint,
  alasan                 varchar(300) NOT NULL,     -- STD-06: koreksi wajib alasan
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- idempoten per retur_id M40 / payment_ref M15 / bill M08
  tanggal                date NOT NULL,
  subtotal               numeric(18,4) NOT NULL DEFAULT 0,
  pajak                  numeric(18,4) NOT NULL DEFAULT 0,
  total                  numeric(18,4) NOT NULL DEFAULT 0,
  status                 enum_status_nota_acc NOT NULL DEFAULT 'DRAFT',
  id_core_users_penyusun bigint NOT NULL,
  alasan_batal           varchar(300),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_nota_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_nota_nomor UNIQUE (nomor),
  CONSTRAINT ck_acc_nota_tepat_satu_faktur
    CHECK ((id_acc_faktur_pelanggan IS NULL) <> (id_acc_faktur_pemasok IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_nota_idempoten
  ON acc_nota_kredit (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_nota_faktur_pelanggan
  ON acc_nota_kredit (id_acc_faktur_pelanggan) WHERE id_acc_faktur_pelanggan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_nota_faktur_pemasok
  ON acc_nota_kredit (id_acc_faktur_pemasok) WHERE id_acc_faktur_pemasok IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_faktur_pelanggan') THEN
    ALTER TABLE acc_nota_kredit ADD CONSTRAINT fk_acc_nota_faktur_pelanggan
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_faktur_pemasok') THEN
    ALTER TABLE acc_nota_kredit ADD CONSTRAINT fk_acc_nota_faktur_pemasok
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_penyusun') THEN
    ALTER TABLE acc_nota_kredit ADD CONSTRAINT fk_acc_nota_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 3.9 acc_nota_kredit_items — [LINE] — kebalikan baris dokumen asal (BR17)
CREATE TABLE IF NOT EXISTS acc_nota_kredit_items (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_nota_kredit     bigint NOT NULL,
  id_inv_produk          bigint,
  deskripsi              varchar(200) NOT NULL,
  qty                    int NOT NULL CHECK (qty > 0),
  harga_satuan           numeric(18,4) NOT NULL,
  diskon_persen          numeric(18,6) NOT NULL DEFAULT 0,
  id_acc_pajak           bigint,
  tarif_pajak            numeric(18,6),
  basis_pajak            enum_basis_pajak_acc,
  pengali_dpp            numeric(9,6) NOT NULL DEFAULT 1,
  nilai_dpp              numeric(18,4) NOT NULL DEFAULT 0,
  nilai_pajak            numeric(18,4) NOT NULL DEFAULT 0,
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_nota_items_entity_id UNIQUE (entity_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_items_nota') THEN
    ALTER TABLE acc_nota_kredit_items ADD CONSTRAINT fk_acc_nota_items_nota
      FOREIGN KEY (id_acc_nota_kredit) REFERENCES acc_nota_kredit (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_items_produk') THEN
    ALTER TABLE acc_nota_kredit_items ADD CONSTRAINT fk_acc_nota_items_produk
      FOREIGN KEY (id_inv_produk) REFERENCES inv_produk (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_nota_items_pajak') THEN
    ALTER TABLE acc_nota_kredit_items ADD CONSTRAINT fk_acc_nota_items_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_nota_items_nota
  ON acc_nota_kredit_items (id_acc_nota_kredit) WHERE deleted_at IS NULL;

-- 3.10 acc_pembayaran — [TRANSAKSI] — pembayaran (F07/BR10–BR11/BR18–BR19; M15/M20/M21/M43;
--     metode = master core_metode_bayar (integrasi); batch_ref; write-off CFG-ACC-21)
CREATE TABLE IF NOT EXISTS acc_pembayaran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering cash_in KM / cash_out KK; unique GLOBAL
  arah                   enum_arah_pembayaran_acc NOT NULL,
  jenis                  enum_jenis_pembayaran_acc NOT NULL DEFAULT 'PEMBAYARAN',
  id_acc_akun            bigint NOT NULL,           -- akun kas/bank sumber/tujuan
  id_acc_akun_tujuan     bigint,                    -- wajib utk TRANSFER_INTERNAL (CHECK di bawah — BR19)
  id_core_metode_bayar   bigint,                    -- master metode bayar CORE (flag tunai/non-tunai BR30)
  id_core_pemasok        bigint,
  id_sls_pelanggan       bigint,                    -- FK sungguhan master live
  id_rsv_reservasi       bigint,                    -- reserved TANPA FK (RSV belum ada — PP-03)
  id_pur_pesanan_pembelian bigint,                  -- DP ter-link PO (M43/BR10) — FK sungguhan
  id_fin_jadwal_pembayaran bigint,                  -- reserved TANPA FK (FIN belum ada)
  id_ecom_pesanan_web    bigint,                    -- reserved TANPA FK (ECOM belum ada)
  batch_ref              varchar(50),               -- pengelompokan deposit/file bank (F08 pencocokan batch)
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- idempoten M15/M20/M21/M43 (PP-04)
  referensi              varchar(150),              -- no. giro / ref gateway / no. transfer
  tanggal_bayar          date NOT NULL,
  kode_mata_uang         varchar(3),
  kurs                   numeric(18,6),
  nilai                  numeric(18,4) NOT NULL CHECK (nilai > 0),
  nilai_selisih_writeoff numeric(18,4) NOT NULL DEFAULT 0 CHECK (nilai_selisih_writeoff >= 0),  -- CFG-ACC-21/BR10
  selisih_kurs           numeric(18,4),             -- realisasi BR15 (bila CFG-ACC-06)
  status                 enum_status_pembayaran_acc NOT NULL DEFAULT 'DRAFT',
  id_core_users_penyusun  bigint NOT NULL,
  id_core_users_penyetuju bigint,
  waktu_persetujuan      timestamptz,
  alasan_penolakan       varchar(300),
  alasan_batal           varchar(300),
  path_bukti             varchar(300),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_byr_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_byr_nomor UNIQUE (nomor),
  CONSTRAINT ck_acc_byr_transfer_tujuan
    CHECK (jenis <> 'TRANSFER_INTERNAL' OR id_acc_akun_tujuan IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_byr_idempoten
  ON acc_pembayaran (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_byr_menunggu
  ON acc_pembayaran (status) WHERE status = 'MENUNGGU_PERSETUJUAN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_byr_rekonsiliasi
  ON acc_pembayaran (id_acc_akun, tanggal_bayar)
  WHERE status = 'POSTED' AND deleted_at IS NULL;                            -- antrian F08
CREATE INDEX IF NOT EXISTS ix_acc_byr_batch
  ON acc_pembayaran (batch_ref) WHERE batch_ref IS NOT NULL AND deleted_at IS NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_akun') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_akun_tujuan') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_akun_tujuan
      FOREIGN KEY (id_acc_akun_tujuan) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_metode_bayar') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_metode_bayar
      FOREIGN KEY (id_core_metode_bayar) REFERENCES core_metode_bayar (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_pemasok') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_pemasok
      FOREIGN KEY (id_core_pemasok) REFERENCES core_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_pelanggan') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_pelanggan
      FOREIGN KEY (id_sls_pelanggan) REFERENCES sls_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_po') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_po
      FOREIGN KEY (id_pur_pesanan_pembelian) REFERENCES pur_pesanan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_penyusun') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_penyetuju') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_penyetuju
      FOREIGN KEY (id_core_users_penyetuju) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3.11 acc_pembayaran_alokasi — [LINE] — alokasi ke faktur (BR10/BR11; recompute `sisa` PP-08)
CREATE TABLE IF NOT EXISTS acc_pembayaran_alokasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_pembayaran      bigint NOT NULL,
  id_acc_faktur_pelanggan bigint,
  id_acc_faktur_pemasok  bigint,
  nilai_alokasi          numeric(18,4) NOT NULL CHECK (nilai_alokasi > 0),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_alok_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_alok_tepat_satu_faktur
    CHECK ((id_acc_faktur_pelanggan IS NULL) <> (id_acc_faktur_pemasok IS NULL))
);
CREATE INDEX IF NOT EXISTS ix_acc_alok_fktplg
  ON acc_pembayaran_alokasi (id_acc_faktur_pelanggan) WHERE id_acc_faktur_pelanggan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_alok_fktpms
  ON acc_pembayaran_alokasi (id_acc_faktur_pemasok) WHERE id_acc_faktur_pemasok IS NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_pembayaran') THEN
    ALTER TABLE acc_pembayaran_alokasi ADD CONSTRAINT fk_acc_alok_pembayaran
      FOREIGN KEY (id_acc_pembayaran) REFERENCES acc_pembayaran (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fktplg') THEN
    ALTER TABLE acc_pembayaran_alokasi ADD CONSTRAINT fk_acc_alok_fktplg
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_alok_fktpms') THEN
    ALTER TABLE acc_pembayaran_alokasi ADD CONSTRAINT fk_acc_alok_fktpms
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 3.12 acc_rekonsiliasi_bank — [TRANSAKSI] — rekonsiliasi (F08/BR12; selisih=0 CHECK di DB PP-07)
CREATE TABLE IF NOT EXISTS acc_rekonsiliasi_bank (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- numbering reconciliation RKN; unique GLOBAL
  id_acc_akun            bigint NOT NULL,           -- akun bank flag_rekonsiliasi (cek app)
  id_acc_periode         bigint NOT NULL,           -- PP-10
  tanggal_rekonsiliasi   date NOT NULL,
  saldo_buku             numeric(18,4) NOT NULL,
  saldo_koran            numeric(18,4) NOT NULL,
  selisih                numeric(18,4) NOT NULL DEFAULT 0,
  status                 enum_status_rekonsiliasi_acc NOT NULL DEFAULT 'BARU',
  id_core_users_penyusun bigint NOT NULL,           -- SoD BR05: bukan pengelola kas (app)
  id_core_users_finalisator bigint,
  waktu_finalisasi       timestamptz,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_rkn_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_rkn_nomor UNIQUE (nomor),
  CONSTRAINT ck_acc_rkn_selisih CHECK (status <> 'SELESAI' OR selisih = 0)  -- BR12 di DB (PP-07)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_rkn_akun') THEN
    ALTER TABLE acc_rekonsiliasi_bank ADD CONSTRAINT fk_acc_rkn_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_rkn_periode') THEN
    ALTER TABLE acc_rekonsiliasi_bank ADD CONSTRAINT fk_acc_rkn_periode
      FOREIGN KEY (id_acc_periode) REFERENCES acc_periode (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_rkn_penyusun') THEN
    ALTER TABLE acc_rekonsiliasi_bank ADD CONSTRAINT fk_acc_rkn_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_rkn_finalisator') THEN
    ALTER TABLE acc_rekonsiliasi_bank ADD CONSTRAINT fk_acc_rkn_finalisator
      FOREIGN KEY (id_core_users_finalisator) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_rkn_status
  ON acc_rekonsiliasi_bank (status) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_rkn_akun_periode
  ON acc_rekonsiliasi_bank (id_acc_akun, id_acc_periode);

-- 3.13 acc_rekonsiliasi_koran — [LINE] — baris rekening koran hasil impor
CREATE TABLE IF NOT EXISTS acc_rekonsiliasi_koran (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_rekonsiliasi_bank bigint NOT NULL,
  tanggal                date NOT NULL,
  deskripsi              varchar(200) NOT NULL,
  masuk                  numeric(18,4) NOT NULL DEFAULT 0,
  keluar                 numeric(18,4) NOT NULL DEFAULT 0,
  referensi              varchar(150),
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_koran_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_koran_sisi CHECK ((masuk > 0)::int + (keluar > 0)::int = 1)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_koran_rkn') THEN
    ALTER TABLE acc_rekonsiliasi_koran ADD CONSTRAINT fk_acc_koran_rkn
      FOREIGN KEY (id_acc_rekonsiliasi_bank) REFERENCES acc_rekonsiliasi_bank (id) ON DELETE CASCADE;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_koran_rkn
  ON acc_rekonsiliasi_koran (id_acc_rekonsiliasi_bank, tanggal);

-- 3.14 acc_rekonsiliasi_cocok — [LINE pencocokan] — koran ↔ buku; target tepat satu; "hanya
--      sekali dicocokkan" = 3 uq partial GLOBAL (PP-07); jejak model otomatis
CREATE TABLE IF NOT EXISTS acc_rekonsiliasi_cocok (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_rekonsiliasi_bank bigint NOT NULL,
  id_acc_rekonsiliasi_koran bigint NOT NULL,
  id_acc_pembayaran      bigint,
  id_acc_entri_jurnal_baris bigint,
  id_acc_model_rekonsiliasi bigint,          -- jejak model otomatis yang mencocokkan (NULL = manual)
  catatan                varchar(200),
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_cocok_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_cocok_tepat_satu_target CHECK (
    (id_acc_pembayaran IS NOT NULL)::int + (id_acc_entri_jurnal_baris IS NOT NULL)::int = 1
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_cocok_koran
  ON acc_rekonsiliasi_cocok (id_acc_rekonsiliasi_koran) WHERE deleted_at IS NULL;       -- PP-07
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_cocok_pembayaran
  ON acc_rekonsiliasi_cocok (id_acc_pembayaran)
  WHERE id_acc_pembayaran IS NOT NULL AND deleted_at IS NULL;                            -- PP-07
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_cocok_baris_jurnal
  ON acc_rekonsiliasi_cocok (id_acc_entri_jurnal_baris)
  WHERE id_acc_entri_jurnal_baris IS NOT NULL AND deleted_at IS NULL;                    -- PP-07
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_cocok_rkn') THEN
    ALTER TABLE acc_rekonsiliasi_cocok ADD CONSTRAINT fk_acc_cocok_rkn
      FOREIGN KEY (id_acc_rekonsiliasi_bank) REFERENCES acc_rekonsiliasi_bank (id) ON DELETE CASCADE;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_cocok_koran') THEN
    ALTER TABLE acc_rekonsiliasi_cocok ADD CONSTRAINT fk_acc_cocok_koran
      FOREIGN KEY (id_acc_rekonsiliasi_koran) REFERENCES acc_rekonsiliasi_koran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_cocok_pembayaran') THEN
    ALTER TABLE acc_rekonsiliasi_cocok ADD CONSTRAINT fk_acc_cocok_pembayaran
      FOREIGN KEY (id_acc_pembayaran) REFERENCES acc_pembayaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_cocok_baris_jurnal') THEN
    ALTER TABLE acc_rekonsiliasi_cocok ADD CONSTRAINT fk_acc_cocok_baris_jurnal
      FOREIGN KEY (id_acc_entri_jurnal_baris) REFERENCES acc_entri_jurnal_baris (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_cocok_model') THEN
    ALTER TABLE acc_rekonsiliasi_cocok ADD CONSTRAINT fk_acc_cocok_model
      FOREIGN KEY (id_acc_model_rekonsiliasi) REFERENCES acc_model_rekonsiliasi (id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3.15 acc_faktur_pajak — [TRANSAKSI] — faktur pajak turunan (F21/BR27; NSFP dari Coretax,
--      TIDAK digenerate sistem; FP pengganti self-FK; snapshot identitas penerima)
CREATE TABLE IF NOT EXISTS acc_faktur_pajak (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_seri_fp          varchar(50),               -- NSFP hasil unggah Coretax; UNIQUE (NULL = belum terbit)
  kode_transaksi         varchar(50),               -- kode transaksi FP Coretax (verifikasi PER-11/PJ/2025)
  jenis                  varchar(50) NOT NULL DEFAULT 'NORMAL',  -- NORMAL | PENGKANTI
  id_acc_faktur_pelanggan bigint NOT NULL,          -- dokumen asal (1 FP normal per faktur — uq partial)
  id_acc_faktur_pajak_diganti bigint,                -- FP pengganti → FP yang diganti (self-FK)
  masa_pajak             varchar(50) NOT NULL,      -- '2026-11'
  identitas_penerima     varchar(50) NOT NULL,      -- NPWP 16 digit / NITKU / NIK (snapshot beku)
  nama_penerima          varchar(200) NOT NULL,
  alamat_penerima        varchar(300),
  total_harga            numeric(18,4) NOT NULL DEFAULT 0,
  total_diskon           numeric(18,4) NOT NULL DEFAULT 0,
  total_dpp              numeric(18,4) NOT NULL DEFAULT 0,   -- Σ DPP per faktor (BR28)
  total_ppn              numeric(18,4) NOT NULL DEFAULT 0,   -- pembulatan rezim CFG-ACC-19 (BR26)
  status                 enum_status_faktur_pajak_acc NOT NULL DEFAULT 'DRAFT',
  tanggal_terbit         date,                      -- tanggal NSFP terisi (hasil unggah)
  path_xml               varchar(300),              -- berkas ekspor XML Coretax (immutable — STD-11)
  id_core_users_penyusun bigint NOT NULL,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fpajak_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_fpajak_nsfp UNIQUE (nomor_seri_fp)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fpajak_normal_per_faktur
  ON acc_faktur_pajak (id_acc_faktur_pelanggan)
  WHERE jenis = 'NORMAL' AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_fpajak_pengganti_per_asal
  ON acc_faktur_pajak (id_acc_faktur_pajak_diganti)
  WHERE id_acc_faktur_pajak_diganti IS NOT NULL AND deleted_at IS NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_faktur_pelanggan') THEN
    ALTER TABLE acc_faktur_pajak ADD CONSTRAINT fk_acc_fpajak_faktur_pelanggan
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_diganti') THEN
    ALTER TABLE acc_faktur_pajak ADD CONSTRAINT fk_acc_fpajak_diganti
      FOREIGN KEY (id_acc_faktur_pajak_diganti) REFERENCES acc_faktur_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_penyusun') THEN
    ALTER TABLE acc_faktur_pajak ADD CONSTRAINT fk_acc_fpajak_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_fpajak_masa
  ON acc_faktur_pajak (masa_pajak, status) WHERE deleted_at IS NULL;   -- rekap SPT F23

-- 3.16 acc_faktur_pajak_items — [LINE] — elemen per baris (BR28: faktur campuran pecah per faktor)
CREATE TABLE IF NOT EXISTS acc_faktur_pajak_items (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_acc_faktur_pajak    bigint NOT NULL,
  deskripsi              varchar(200) NOT NULL,
  kode_bkp_jkp           varchar(50),               -- kode produk e-Faktur / jenis BKP/JKP
  nilai_harga            numeric(18,4) NOT NULL DEFAULT 0,
  diskon                 numeric(18,4) NOT NULL DEFAULT 0,
  pengali_dpp            numeric(9,6) NOT NULL DEFAULT 1,   -- snapshot faktor DPP
  dpp                    numeric(18,4) NOT NULL DEFAULT 0,
  tarif_pajak            numeric(18,6) NOT NULL DEFAULT 0,
  nilai_pajak            numeric(18,4) NOT NULL DEFAULT 0,
  urutan                 int NOT NULL DEFAULT 0,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_fpajak_items_entity_id UNIQUE (entity_id)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fpajak_items_faktur') THEN
    ALTER TABLE acc_faktur_pajak_items ADD CONSTRAINT fk_acc_fpajak_items_faktur
      FOREIGN KEY (id_acc_faktur_pajak) REFERENCES acc_faktur_pajak (id) ON DELETE CASCADE;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_acc_fpajak_items_faktur
  ON acc_faktur_pajak_items (id_acc_faktur_pajak) WHERE deleted_at IS NULL;

-- 3.17 acc_bukti_potong — [TRANSAKSI] — bukti pemotongan PPh (F22/BR29; e-Bupot Unifikasi;
--      pembulatan rupiah penuh; diberikan ke pihak ke-3)
CREATE TABLE IF NOT EXISTS acc_bukti_potong (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor_bukti            varchar(150) NOT NULL,     -- numbering bupot BUPOT; unique GLOBAL
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'MANUAL',
  entity_id_sumber       varchar(255),              -- idempoten per dokumen asal + pajak (PP-04)
  id_acc_pajak           bigint NOT NULL,           -- kode dokumen PPh (snapshot kode di bawah)
  kode_dokumen_snapshot  varchar(50),
  id_core_pemasok        bigint,
  identitas_penerima     varchar(50) NOT NULL,      -- NPWP/NITKU/NIK/NPPN (snapshot beku)
  nama_penerima          varchar(200) NOT NULL,
  dokumen_target         varchar(50) NOT NULL DEFAULT 'FAKTUR_PEMASOK',  -- FAKTUR_PEMASOK|NOTA_KREDIT|ENTRI_JURNAL
  id_acc_faktur_pemasok  bigint,
  id_acc_nota_kredit     bigint,
  id_acc_entri_jurnal    bigint,
  dasar_pemotongan       numeric(18,4) NOT NULL CHECK (dasar_pemotongan >= 0),
  nilai_potong           numeric(18,4) NOT NULL CHECK (nilai_potong >= 0),
  masa_pajak             varchar(50) NOT NULL,
  status                 enum_status_bukti_potong_acc NOT NULL DEFAULT 'DRAFT',
  tanggal_terbit         date,
  tanggal_disampaikan    date,
  id_core_users_penyusun bigint NOT NULL,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_bupot_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_bupot_nomor UNIQUE (nomor_bukti),
  CONSTRAINT ck_acc_bupot_tepat_satu_dokumen CHECK (
    (id_acc_faktur_pemasok IS NOT NULL)::int
    + (id_acc_nota_kredit IS NOT NULL)::int
    + (id_acc_entri_jurnal IS NOT NULL)::int = 1
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_bupot_idempoten
  ON acc_bukti_potong (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;
-- tunggal per dokumen-asal + pajak (BR29: bukti potong ganda terblokir)
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_bupot_faktur_pajak
  ON acc_bukti_potong (id_acc_faktur_pemasok, id_acc_pajak)
  WHERE id_acc_faktur_pemasok IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_bupot_nota_pajak
  ON acc_bukti_potong (id_acc_nota_kredit, id_acc_pajak)
  WHERE id_acc_nota_kredit IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_bupot_masa
  ON acc_bukti_potong (masa_pajak, status) WHERE deleted_at IS NULL;   -- rekap e-Bupot F23
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_pajak') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_pemasok') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_pemasok
      FOREIGN KEY (id_core_pemasok) REFERENCES core_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_faktur_pemasok') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_faktur_pemasok
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_nota') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_nota
      FOREIGN KEY (id_acc_nota_kredit) REFERENCES acc_nota_kredit (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_entri_jurnal') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_entri_jurnal
      FOREIGN KEY (id_acc_entri_jurnal) REFERENCES acc_entri_jurnal (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_bupot_penyusun') THEN
    ALTER TABLE acc_bukti_potong ADD CONSTRAINT fk_acc_bupot_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 3.18 acc_komitmen_po — [MIRROR] — komitmen PO (M05/BR21; penulis tunggal = konsumsi event PUR;
--     keadaan CATAT|SESUAIKAN|LEPAS; bukan jurnal)
CREATE TABLE IF NOT EXISTS acc_komitmen_po (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  jenis_sumber           varchar(50) NOT NULL DEFAULT 'PUR_KOMITMEN',
  entity_id_sumber       varchar(255) NOT NULL,     -- idempoten per PO (uq partial di bawah)
  keadaan                enum_keadaan_komitmen_acc NOT NULL DEFAULT 'CATAT',  -- M05; status turunannya: CATAT=terbuka, SESUAIKAN=terrealisasi, LEPAS=lepas
  nomor_po_ref           varchar(150),
  kategori               varchar(100),
  mata_uang              varchar(3),                -- payload M05 (konversi kurs di ACC bila perlu)
  nilai                  numeric(18,4) NOT NULL CHECK (nilai >= 0),
  id_pur_pesanan_pembelian bigint,                  -- FK sungguhan master live
  id_core_users          bigint,
  version                int NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_komit_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_acc_komit_idempoten
  ON acc_komitmen_po (jenis_sumber, entity_id_sumber)
  WHERE entity_id_sumber IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_komit_terbuka
  ON acc_komitmen_po (keadaan) WHERE keadaan = 'CATAT' AND deleted_at IS NULL;  -- snapshot M31
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_komit_po') THEN
    ALTER TABLE acc_komitmen_po ADD CONSTRAINT fk_acc_komit_po
      FOREIGN KEY (id_pur_pesanan_pembelian) REFERENCES pur_pesanan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_komit_users') THEN
    ALTER TABLE acc_komitmen_po ADD CONSTRAINT fk_acc_komit_users
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;

-- 3.19 acc_snapshot_harian — [READMODEL] — snapshot M31/IN-14 untuk FIN (idempoten per tanggal;
--      dibangun ulang job F11 — tanpa version, K-05 pengecualian READMODEL)
CREATE TABLE IF NOT EXISTS acc_snapshot_harian (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tanggal                date NOT NULL,
  aging_ar               jsonb,                     -- per pelanggan × bucket cicilan (tak difilter DB)
  aging_ap               jsonb,
  saldo_kas_bank         jsonb,                     -- per akun
  rekap_pajak            jsonb,                     -- per jenis pajak (basis grid F23)
  total_piutang          numeric(18,4) NOT NULL DEFAULT 0,
  total_utang            numeric(18,4) NOT NULL DEFAULT 0,
  total_kas_bank         numeric(18,4) NOT NULL DEFAULT 0,
  total_komitmen         numeric(18,4) NOT NULL DEFAULT 0,  -- Σ komitmen keadaan CATAT
  dihitung_pada          timestamptz NOT NULL DEFAULT now(),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_acc_snapshot_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_acc_snapshot_tanggal UNIQUE (tanggal)
);

-- 3.20 acc_event_log — [LOG/EVENT] append-only — jejak transisi/keputusan (STD-01/BR02; payload
--      kontrak M05/M07/M08/…; tanpa trigger updated_at — beku; deleted_at selalu NULL)
CREATE TABLE IF NOT EXISTS acc_event_log (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  subjek                 enum_subjek_acc NOT NULL,
  id_acc_entri_jurnal       bigint,
  id_acc_faktur_pelanggan   bigint,
  id_acc_faktur_pemasok     bigint,
  id_acc_nota_kredit        bigint,
  id_acc_pembayaran         bigint,
  id_acc_periode            bigint,
  id_acc_rekonsiliasi_bank  bigint,
  id_acc_faktur_pajak       bigint,
  id_acc_bukti_potong       bigint,
  id_acc_akun                bigint,
  id_acc_pajak               bigint,
  id_core_users           bigint,                    -- NULL = aktor sistem/kontrak
  aksi                    varchar(50) NOT NULL,      -- POSTED|REVERSAL|PERIODE_TERKUNCI|SOD_DILANGGAR|…
  dari_status             varchar(50),
  ke_status               varchar(50),
  alasan                  varchar(300),
  payload                 jsonb,                     -- konteks kontrak masuk/keluar (tak difilter/join)
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  deleted_at              timestamptz,
  CONSTRAINT uq_acc_event_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_acc_event_tepat_satu_subjek CHECK (
    (id_acc_entri_jurnal      IS NOT NULL)::int
    + (id_acc_faktur_pelanggan IS NOT NULL)::int
    + (id_acc_faktur_pemasok  IS NOT NULL)::int
    + (id_acc_nota_kredit     IS NOT NULL)::int
    + (id_acc_pembayaran      IS NOT NULL)::int
    + (id_acc_periode         IS NOT NULL)::int
    + (id_acc_rekonsiliasi_bank IS NOT NULL)::int
    + (id_acc_faktur_pajak    IS NOT NULL)::int
    + (id_acc_bukti_potong    IS NOT NULL)::int
    + (id_acc_akun            IS NOT NULL)::int
    + (id_acc_pajak           IS NOT NULL)::int = 1
  )
);
CREATE INDEX IF NOT EXISTS ix_acc_event_entri
  ON acc_event_log (id_acc_entri_jurnal, created_at) WHERE id_acc_entri_jurnal IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_fktplg
  ON acc_event_log (id_acc_faktur_pelanggan, created_at) WHERE id_acc_faktur_pelanggan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_fktpms
  ON acc_event_log (id_acc_faktur_pemasok, created_at) WHERE id_acc_faktur_pemasok IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_pembayaran
  ON acc_event_log (id_acc_pembayaran, created_at) WHERE id_acc_pembayaran IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_periode
  ON acc_event_log (id_acc_periode, created_at) WHERE id_acc_periode IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_rekonsiliasi
  ON acc_event_log (id_acc_rekonsiliasi_bank, created_at) WHERE id_acc_rekonsiliasi_bank IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_fpajak
  ON acc_event_log (id_acc_faktur_pajak, created_at) WHERE id_acc_faktur_pajak IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_bupot
  ON acc_event_log (id_acc_bukti_potong, created_at) WHERE id_acc_bukti_potong IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_acc_event_subjek_aksi
  ON acc_event_log (subjek, aksi, created_at);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_entri') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_entri
      FOREIGN KEY (id_acc_entri_jurnal) REFERENCES acc_entri_jurnal (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fktplg') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_fktplg
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fktpms') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_fktpms
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_nota') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_nota
      FOREIGN KEY (id_acc_nota_kredit) REFERENCES acc_nota_kredit (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_pembayaran') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_pembayaran
      FOREIGN KEY (id_acc_pembayaran) REFERENCES acc_pembayaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_periode') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_periode
      FOREIGN KEY (id_acc_periode) REFERENCES acc_periode (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_rekonsiliasi') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_rekonsiliasi
      FOREIGN KEY (id_acc_rekonsiliasi_bank) REFERENCES acc_rekonsiliasi_bank (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_fpajak') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_fpajak
      FOREIGN KEY (id_acc_faktur_pajak) REFERENCES acc_faktur_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_bupot') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_bupot
      FOREIGN KEY (id_acc_bukti_potong) REFERENCES acc_bukti_potong (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_akun') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_pajak') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_pajak
      FOREIGN KEY (id_acc_pajak) REFERENCES acc_pajak (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_event_users') THEN
    ALTER TABLE acc_event_log ADD CONSTRAINT fk_acc_event_users
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;

-- =============================================================================
-- §4 — FK pecah siklus pada acc_entri_jurnal (sumber internal ACC — pola FNB 9b)
-- =============================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fktplg') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_fktplg
      FOREIGN KEY (id_acc_faktur_pelanggan) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_fktpms') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_fktpms
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_pembayaran') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_pembayaran
      FOREIGN KEY (id_acc_pembayaran) REFERENCES acc_pembayaran (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_nota') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_nota
      FOREIGN KEY (id_acc_nota_kredit) REFERENCES acc_nota_kredit (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_jurnal_asal') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_jurnal_asal
      FOREIGN KEY (id_acc_entri_jurnal_asal) REFERENCES acc_entri_jurnal (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_jurnal_buku') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_jurnal_buku
      FOREIGN KEY (id_acc_jurnal) REFERENCES acc_jurnal (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_periode') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_periode
      FOREIGN KEY (id_acc_periode) REFERENCES acc_periode (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_penyusun') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_penyusun
      FOREIGN KEY (id_core_users_penyusun) REFERENCES core_users (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_entri_penyetuju') THEN
    ALTER TABLE acc_entri_jurnal ADD CONSTRAINT fk_acc_entri_penyetuju
      FOREIGN KEY (id_core_users_penyetuju) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_fkt_cicilan_pemasok') THEN
    ALTER TABLE acc_faktur_cicilan ADD CONSTRAINT fk_acc_fkt_cicilan_pemasok
      FOREIGN KEY (id_acc_faktur_pemasok) REFERENCES acc_faktur_pemasok (id) ON DELETE CASCADE;
  END IF;
END $$;

-- =============================================================================
-- §5 — FK SETORAN & INTEGRASI LINTAS MODUL (NOT VALID — pola 28-sls §5a; ACC pemilik target)
-- =============================================================================

-- 5.1 pemetaan akun jurnal per metode bayar (PP-20/M10): core_metode_bayar.id_acc_akun_kas/
--     id_acc_akun_pendapatan → acc_akun
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_metode_bayar_acc_kas') THEN
    ALTER TABLE core_metode_bayar ADD CONSTRAINT fk_core_metode_bayar_acc_kas
      FOREIGN KEY (id_acc_akun_kas) REFERENCES acc_akun (id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_metode_bayar_acc_pendapatan') THEN
    ALTER TABLE core_metode_bayar ADD CONSTRAINT fk_core_metode_bayar_acc_pendapatan
      FOREIGN KEY (id_acc_akun_pendapatan) REFERENCES acc_akun (id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;

-- 5.2 faktur pesanan POS (M38/M41): pos_pesanan.id_acc_faktur → acc_faktur_pelanggan
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_pos_pesanan_acc_faktur') THEN
    ALTER TABLE pos_pesanan ADD CONSTRAINT fk_pos_pesanan_acc_faktur
      FOREIGN KEY (id_acc_faktur) REFERENCES acc_faktur_pelanggan (id) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;

-- 5.3 master termin (A-07 terjawab): core_pemasok.kode_termin & sls_pelanggan.kode_termin
--     → acc_termin_pembayaran.kode (NOT VALID — nilai lama bebas divalidasi menyusul)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_acc_termin') THEN
    ALTER TABLE core_pemasok ADD CONSTRAINT fk_core_pemasok_acc_termin
      FOREIGN KEY (kode_termin) REFERENCES acc_termin_pembayaran (kode) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sls_pelanggan_acc_termin') THEN
    ALTER TABLE sls_pelanggan ADD CONSTRAINT fk_sls_pelanggan_acc_termin
      FOREIGN KEY (kode_termin) REFERENCES acc_termin_pembayaran (kode) ON DELETE RESTRICT NOT VALID;
  END IF;
END $$;

-- =============================================================================
-- §6 — INDEX MASTER (tambahan di luar yang terikat tabel)
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_acc_akun_tipe ON acc_akun (tipe) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_akun_aktif
  ON acc_akun (kode_akun) WHERE status = 'AKTIF' AND deleted_at IS NULL;     -- pemilih entri (BR16)
CREATE INDEX IF NOT EXISTS ix_acc_akun_rekonsiliasi
  ON acc_akun (id) WHERE flag_rekonsiliasi = true AND status = 'AKTIF' AND deleted_at IS NULL;  -- F08
CREATE INDEX IF NOT EXISTS ix_acc_pajak_aktif
  ON acc_pajak (kode) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_posisi_fiskal_urutan
  ON acc_posisi_fiskal (urutan) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_posisi_pemetaan_posisi
  ON acc_posisi_fiskal_pemetaan (id_acc_posisi_fiskal) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_termin_aktif
  ON acc_termin_pembayaran (kode) WHERE status = 'AKTIF' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_acc_kurs_lookup
  ON acc_kurs (jenis, kode_mata_uang, tanggal DESC) WHERE deleted_at IS NULL;  -- konversi hari transaksi
CREATE INDEX IF NOT EXISTS ix_acc_periode_status ON acc_periode (status);

-- =============================================================================
-- §7 — TRIGGER updated_at (32 tabel; event_log append-only sengaja tanpa trigger)
-- =============================================================================

DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'acc_akun','acc_jurnal','acc_pajak','acc_pajak_distribusi',
    'acc_posisi_fiskal','acc_posisi_fiskal_pemetaan',
    'acc_termin_pembayaran','acc_termin_pembayaran_cicilan',
    'acc_kurs','acc_periode','acc_model_rekonsiliasi',
    'acc_jurnal_berulang','acc_jurnal_berulang_baris',
    'acc_entri_jurnal','acc_entri_jurnal_baris',
    'acc_faktur_pelanggan','acc_faktur_pelanggan_items','acc_faktur_cicilan',
    'acc_faktur_pemasok','acc_faktur_pemasok_items',
    'acc_nota_kredit','acc_nota_kredit_items',
    'acc_pembayaran','acc_pembayaran_alokasi',
    'acc_rekonsiliasi_bank','acc_rekonsiliasi_koran','acc_rekonsiliasi_cocok',
    'acc_faktur_pajak','acc_faktur_pajak_items','acc_bukti_potong',
    'acc_komitmen_po','acc_snapshot_harian'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;

-- =============================================================================
-- §8 — SEED (idempoten deterministik — lolos restore-DB-segar)
-- =============================================================================

-- 8.1 Guard fail-loud registry modul (prasyarat baseline CORE)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'accounting') THEN
    RAISE EXCEPTION 'PATCH 30-acc: registry core_modules key=''accounting'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;

-- 8.2 core_sequences — REUSE baris legacy accounting (counter dilanjutkan — PP-22) +
--     doc_name baru. doc_name mapping: journal=JV (entri jurnal), invoice_sales=INV (faktur
--     pelanggan), invoice_purchase=PUR (faktur pemasok), cash_in=KM (pembayaran masuk),
--     cash_out=KK (pembayaran keluar), bupot=BUPOT (bukti potong PPh), credit_note=NK,
--     debit_note=DN, reconciliation=RKN, recurring_journal=JRB.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('journal',           'JV-{yyyy}',   0, 3),
  ('invoice_sales',     'INV-{yyyy}',  0, 4),
  ('invoice_purchase',  'PUR-{yyyy}',  0, 4),
  ('cash_in',           'KM-{yyyy}',   0, 3),
  ('cash_out',          'KK-{yyyy}',   0, 3),
  ('bupot',             'BUPOT-{yyyy}',0, 3),
  ('credit_note',       'NK-{yyyy}',   0, 4),
  ('debit_note',        'DN-{yyyy}',   0, 4),
  ('reconciliation',    'RKN-{yyyy}',  0, 3),
  ('recurring_journal', 'JRB-{yyyy}',  0, 3)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'accounting'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- 8.3 core_module_configs — CFG-ACC-01…21 (nilai default Profil Skala PS2 — keputusan operasional
--     single tenant; value machine-code, dokumen v4 §5.2 tabel CFG adalah kamusnya)
INSERT INTO core_module_configs (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-ACC-01','AKRUAL','string','Basis pencatatan: AKRUAL atau KAS (kapan jurnal pendapatan/beban terbit).'),
  ('CFG-ACC-02','TERPILIH','string','Jurnal dari modul lain: SEMUA_DRAFT | TERPILIH (faktur pemasok & jurnal manual draft, lainnya langsung) | SEMUA_LANGSUNG.'),
  ('CFG-ACC-03','MASTER_ACC_PAJAK','string','Sumber kebijakan pajak = master acc_pajak (multi-rate, faktor DPP, kode dokumen); sinkron CFG-PLT-04.'),
  ('CFG-ACC-04','AMBANG','string','Posting jurnal manual di atas ambang wajib approval: TANPA_AMBANG | AMBANG | AMBANG_MULTI_LEVEL.'),
  ('CFG-ACC-05','PAJAK_LUNAK','string','Lapis lock periode: TANPA_LOCK | LOCK_PAJAK | PAJAK_LUNAK | PAJAK_LUNAK_KERAS.'),
  ('CFG-ACC-06','TIDAK','string','Aktifkan transaksi multi-mata uang + kurs akuntansi (TIDAK | AKTIF).'),
  ('CFG-ACC-07','5-9100','string','Kode akun selisih (beda) harga 3-way match; nilai toleransi = CFG-PUR-07 (sumber tunggal PUR).'),
  ('CFG-ACC-08','AMBANG','string','Pembayaran di atas ambang wajib approval: TANPA | AMBANG (penyetuju ≠ pembuat wajib).'),
  ('CFG-ACC-09','INDIRECT','string','Metode laporan arus kas: INDIRECT | DIRECT.'),
  ('CFG-ACC-10','YA_ALASAN_WAJIB','string','Faktur pelanggan manual tanpa SO: TIDAK | YA | YA_ALASAN_WAJIB.'),
  ('CFG-ACC-11','OUTSTANDING','string','Pembayaran diparkir di akun outstanding (LANGSUNG | OUTSTANDING) — akun sistem wajib ada.'),
  ('CFG-ACC-12','MANUAL','string','Follow-up penagihan: TIDAK | MANUAL | OTOMATIS.'),
  ('CFG-ACC-13','TIDAK','string','Jurnal pengakuan bertahap (deferred): TIDAK | OTOMATIS_PER_BARIS | MANUAL_KELOMPOK.'),
  ('CFG-ACC-14','1-9300','string','Kode akun selisih kas sesi kasir (over/short).'),
  ('CFG-ACC-15','AKTIF','string','Transfer internal antar kas/bank via akun transit (TIDAK | AKTIF).'),
  ('CFG-ACC-16','TIDAK','string','Diskon dipercepat pada termin pembayaran (TIDAK | AKTIF) — mode dampak pajak = Q-10.'),
  ('CFG-ACC-17','PKP','string','Status PKP instansi: BUKAN_PKP | PKP | PKP_XML (ekspor XML Coretax — F21/BR27).'),
  ('CFG-ACC-18','AKTIF','string','Pemotongan PPh & bukti potong e-Bupot per master pajak (TIDAK | AKTIF — F22/BR29).'),
  ('CFG-ACC-19','INDO_PAJAK','string','Rezim pembulatan pajak: UMUM | INDO_PAJAK (PPN ke bawah ratusan; PPh rupiah penuh) | INDO_PAJAK_DPP (DPP nilai lain ke ratusan 2025–2029).'),
  ('CFG-ACC-20','SAK_UMUM','string','Kerangka standar laporan: SAK_UMUM | SAK_EP | SAK_EMKM (preset F11).'),
  ('CFG-ACC-21','10000','number','Ambang selisih pelunasan yang boleh dianggap lunas penuh → akun selisih pembayaran (rupiah; 0 = tidak boleh).')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'accounting'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

-- 8.4 COA seed — 28 akun baku + akun sistem (A-04; kode global, ON CONFLICT by kode_akun)
INSERT INTO acc_akun (kode_akun, nama, tipe, sub_tipe_laporan, flag_rekonsiliasi)
SELECT v.kode, v.nama, v.tipe::enum_tipe_akun_acc, v.sub, v.rekon
FROM (VALUES
  ('1-1000','Kas','ASET','kas',true),
  ('1-1100','Bank','ASET','bank',true),
  ('1-1200','Piutang Usaha','ASET','piutang',false),
  ('1-1300','Persediaan','ASET','persediaan',false),
  ('1-1400','PPN Masukan','ASET','pajak',false),
  ('1-1500','PPh Dibayar di Muka / Dipotong','ASET','pajak',false),
  ('1-1600','Beban Ditangguhkan','ASET','ditangguhkan',false),
  ('1-9100','Akun Outstanding Penerimaan','ASET','outstanding',false),
  ('1-9110','Akun Outstanding Pengeluaran','ASET','outstanding',false),
  ('1-9200','Akun Transit Transfer Internal','ASET','transit',false),
  ('1-9300','Selisih Kas Kasir (Over/Short)','ASET','selisih',false),
  ('1-9400','Selisih Pembayaran (Write-off Kecil)','ASET','selisih',false),
  ('1-9500','Selisih Kurs','ASET','selisih',false),
  ('1-9600','Suspense Bank (Belum Terekonsiliasi)','ASET','suspense',false),
  ('2-1000','Utang Usaha','KEWAJIBAN','utang',false),
  ('2-1100','PPN Keluaran','KEWAJIBAN','pajak',false),
  ('2-1200','Utang PPh Dipotong / Terutang','KEWAJIBAN','pajak',false),
  ('2-1300','Pendapatan Diterima di Muka','KEWAJIBAN','ditangguhkan',false),
  ('2-1400','Transit Pajak Wajib Tempo Berdasar Pembayaran','KEWAJIBAN','transit_pajak',false),
  ('3-1000','Modal Disetor','MODAL','modal',false),
  ('3-9000','Laba (Rugi) Berjalan','MODAL','laba_berjalan',false),
  ('4-1000','Pendapatan Penjualan','PENDAPATAN','pendapatan',false),
  ('4-1100','Potongan Penjualan (termasuk Tukar Poin)','PENDAPATAN','potongan',false),
  ('5-1000','Harga Pokok Penjualan','BEBAN','hpp',false),
  ('5-1100','Beban Gaji & Upah','BEBAN','beban_operasional',false),
  ('5-1200','Beban Sewa','BEBAN','beban_operasional',false),
  ('5-1300','Beban Operasional Lainnya','BEBAN','beban_operasional',false),
  ('5-9100','Selisih Harga Pembelian (Beda Harga 3-Way Match)','BEBAN','selisih_harga',false)
) AS v(kode, nama, tipe, sub, rekon)
WHERE NOT EXISTS (SELECT 1 FROM acc_akun a WHERE a.kode_akun = v.kode);

-- 8.4b Hierarki COA — 5 akun induk (header per tipe, flag_non_posting = tak
-- bisa menerima entri jurnal) + pautkan 28 akun baku ke induknya via FK
-- id_acc_akun_induk. Idempoten: header WHERE NOT EXISTS by kode_akun;
-- pautan hanya mengisi baris yang induknya masih NULL (pilihan manual
-- pengguna tidak ditimpa). Anak dicocokkan dari digit awal kode (1-… → '1').
INSERT INTO acc_akun (kode_akun, nama, tipe, flag_non_posting)
SELECT v.kode, v.nama, v.tipe::enum_tipe_akun_acc, true
FROM (VALUES
  ('1','Aset','ASET'),
  ('2','Kewajiban','KEWAJIBAN'),
  ('3','Modal','MODAL'),
  ('4','Pendapatan','PENDAPATAN'),
  ('5','Beban','BEBAN')
) AS v(kode, nama, tipe)
WHERE NOT EXISTS (SELECT 1 FROM acc_akun a WHERE a.kode_akun = v.kode);

UPDATE acc_akun an
SET    id_acc_akun_induk = h.id
FROM   acc_akun h
WHERE  an.kode_akun ~ '^[1-5]-'
AND    h.kode_akun = left(an.kode_akun, 1)
AND    h.flag_non_posting = true
AND    an.id_acc_akun_induk IS NULL;

-- 8.5 Buku (acc_jurnal) — 5 buku baku; doc_name_penomoran mengikuti §8.2
INSERT INTO acc_jurnal (kode, nama, jenis, id_acc_akun_default, doc_name_penomoran)
SELECT v.kode, v.nama, v.jenis::enum_jenis_buku_acc,
       (SELECT a.id FROM acc_akun a WHERE a.kode_akun = v.akun_def),
       v.doc_name
FROM (VALUES
  ('UMUM','Jurnal Umum','UMUM','1-1000','journal'),
  ('PENJUALAN','Jurnal Penjualan','PENJUALAN','4-1000','invoice_sales'),
  ('PEMBELIAN','Jurnal Pembelian','PEMBELIAN','2-1000','invoice_purchase'),
  ('KAS','Jurnal Kas','KAS','1-1000','cash_in'),
  ('BANK','Jurnal Bank','BANK','1-1100','cash_out')
) AS v(kode, nama, jenis, akun_def, doc_name)
WHERE NOT EXISTS (SELECT 1 FROM acc_jurnal j WHERE j.kode = v.kode);

-- 8.6 Pajak seed — preset Indonesia (PMK 131/2024 jo. PMK 11/2025; PMK 37/2022; PMK 141/2015;
--     UU PPh 4(2)). Kode transaksi FP: verifikasi daftar Coretax PER-11/PJ/2025 terkini.
INSERT INTO acc_pajak (
  kode, nama, jenis_dokumen, rate, faktor_dpp, pengali_dpp, basis, wajib_tempo,
  kode_dokumen_pajak, dasar_pemotongan, id_acc_akun_pajak, id_acc_akun_transit
)
SELECT v.kode, v.nama, v.jenis::enum_jenis_dokumen_pajak_acc, v.rate,
       v.faktor::enum_faktor_dpp_acc, v.pengali, v.basis::enum_basis_pajak_acc,
       v.tempo::enum_wajib_tempo_pajak_acc, v.kode_dok,
       NULLIF(v.dasar, '')::enum_dasar_pemotongan_acc,
       (SELECT a.id FROM acc_akun a WHERE a.kode_akun = v.akun),
       (SELECT a.id FROM acc_akun a
        WHERE a.kode_akun = CASE WHEN v.tempo = 'BERDASAR_PEMBAYARAN' THEN '2-1400' END)
FROM (VALUES
  ('PPN-KEL-UMUM','PPN Keluaran Umum (12% × DPP 11/12)','PPN_KELUARAN',12,'NILAI_LAIN_11_12',0.916667,'EXCLUSIVE','SAAT_DOKUMEN','01','','2-1100'),
  ('PPN-KEL-MEWAH','PPN Keluaran Barang Mewah (12% × DPP Penuh)','PPN_KELUARAN',12,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN','08','','2-1100'),
  ('PPN-KEL-STRATEGIS','PPN Keluaran Barang/Jasa Strategis (12% × DPP 50%)','PPN_KELUARAN',12,'SETENGAH',0.5,'EXCLUSIVE','SAAT_DOKUMEN','07','','2-1100'),
  ('PPN-KEL-EXPOR','PPN Keluaran Ekspor (0%)','PPN_KELUARAN',0,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN','13','','2-1100'),
  ('PPN-MAS-UMUM','PPN Masukan Umum (12% × DPP 11/12)','PPN_MASUKAN',12,'NILAI_LAIN_11_12',0.916667,'EXCLUSIVE','SAAT_DOKUMEN','01','','1-1400'),
  ('PPN-MAS-MEWAH','PPN Masukan Barang Mewah (12% × DPP Penuh)','PPN_MASUKAN',12,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN','08','','1-1400'),
  ('PPN-MAS-EXPOR','PPN Masukan Ekspor (0%)','PPN_MASUKAN',0,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN','13','','1-1400'),
  ('PPN-KEL-CASH','PPN Keluaran Wajib Tempo Berdasar Pembayaran','PPN_KELUARAN',12,'NILAI_LAIN_11_12',0.916667,'EXCLUSIVE','BERDASAR_PEMBAYARAN','01','','2-1400'),
  ('PPH-22-UMUM','PPh 22 Penyerahan Barang Umum (1,5%)','PPH_22',1.5,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200'),
  ('PPH-23-JASA','PPh 23 Jasa (2%)','PPH_23',2,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200'),
  ('PPH-23-ROYALTI','PPh 23 Royalti (15%)','PPH_23',15,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200'),
  ('PPH-42-KONSTR-KECIL','PPh 4(2) Final Jasa Konstruksi — Kualifikasi Kecil (2%)','PPH_4_2_FINAL',2,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200'),
  ('PPH-42-KONSTR-LAIN','PPh 4(2) Final Jasa Konstruksi — Lainnya (3%)','PPH_4_2_FINAL',3,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200'),
  ('PPH-42-SEWA-TANAH-BNG','PPh 4(2) Final Sewa Tanah/Bangunan (10%)','PPH_4_2_FINAL',10,'PENUH',1,'EXCLUSIVE','SAAT_DOKUMEN',NULL,'BRUTO','2-1200')
) AS v(kode, nama, jenis, rate, faktor, pengali, basis, tempo, kode_dok, dasar, akun)
WHERE NOT EXISTS (SELECT 1 FROM acc_pajak p WHERE p.kode = v.kode);

-- 8.7 Posisi fiskal preset — ekspor tarif 0% (UU PPN 16A(1)a) + penjualan non-PKP
INSERT INTO acc_posisi_fiskal (kode, nama, jenis_mitra, lokasi, urutan)
SELECT v.kode, v.nama, v.mitra, v.lokasi, v.urutan
FROM (VALUES
  ('EKSPOR','Penyerahan Ekspor (PPN 0%)','WPLN','EKSPOR',1),
  ('BUKAN_PKP_LOKAL','Penyerahan kepada Bukan PKP Lokal',NULL,'DALAM_NEGERI',10)
) AS v(kode, nama, mitra, lokasi, urutan)
WHERE NOT EXISTS (SELECT 1 FROM acc_posisi_fiskal f WHERE f.kode = v.kode);

-- 8.8 Termin pembayaran — selaras nilai kode_termin live (NET14/NET30) + SEWAKTU
INSERT INTO acc_termin_pembayaran (kode, nama)
SELECT v.kode, v.nama
FROM (VALUES
  ('SEWAKTU','Jatuh Tempo Sebareng Faktur'),
  ('NET14','Net 14 Hari'),
  ('NET30','Net 30 Hari')
) AS v(kode, nama)
WHERE NOT EXISTS (SELECT 1 FROM acc_termin_pembayaran t WHERE t.kode = v.kode);

INSERT INTO acc_termin_pembayaran_cicilan (id_acc_termin_pembayaran, urutan, porsi_persen, offset_hari)
SELECT t.id, 1, 100,
       CASE t.kode WHEN 'NET14' THEN 14 WHEN 'NET30' THEN 30 ELSE 0 END
FROM acc_termin_pembayaran t
WHERE NOT EXISTS (
  SELECT 1 FROM acc_termin_pembayaran_cicilan c WHERE c.id_acc_termin_pembayaran = t.id
);

-- 8.9 Periode akuntansi — kalender bulanan tahun berjalan (idempoten by nama)
INSERT INTO acc_periode (nama, jenis, tanggal_mulai, tanggal_selesai)
SELECT v.nama, 'BULANAN', v.mulai::date, v.selesai::date
FROM (VALUES
  ('2026-01','2026-01-01','2026-01-31'),('2026-02','2026-02-01','2026-02-28'),
  ('2026-03','2026-03-01','2026-03-31'),('2026-04','2026-04-01','2026-04-30'),
  ('2026-05','2026-05-01','2026-05-31'),('2026-06','2026-06-01','2026-06-30'),
  ('2026-07','2026-07-01','2026-07-31'),('2026-08','2026-08-01','2026-08-31'),
  ('2026-09','2026-09-01','2026-09-30'),('2026-10','2026-10-01','2026-10-31'),
  ('2026-11','2026-11-01','2026-11-30'),('2026-12','2026-12-01','2026-12-31')
) AS v(nama, mulai, selesai)
WHERE NOT EXISTS (SELECT 1 FROM acc_periode p WHERE p.nama = v.nama);

-- 8.10 Kurs dasar — IDR = 1 (akuntansi + pajak BI) pada awal tahun berjalan
INSERT INTO acc_kurs (jenis, kode_mata_uang, tanggal, kurs, sumber)
SELECT j.jenis::enum_jenis_kurs_acc, 'IDR', DATE '2026-01-01', 1, 'DEFAULT_IDR'
FROM (VALUES ('AKUNTANSI'),('PAJAK_BI')) AS j(jenis)
WHERE NOT EXISTS (
  SELECT 1 FROM acc_kurs k
  WHERE k.kode_mata_uang = 'IDR' AND k.tanggal = DATE '2026-01-01'
    AND k.jenis = j.jenis::enum_jenis_kurs_acc
);

-- 8.11 Pemetaan akun per metode bayar (PP-20/M10) — UPDATE idempoten by kode;
--      POIN = bukan kas (NULL) dan pendapatannya = potongan penjualan (tukar poin)
UPDATE core_metode_bayar m
SET id_acc_akun_kas = (SELECT a.id FROM acc_akun a WHERE a.kode_akun = '1-1000' AND a.deleted_at IS NULL),
    id_acc_akun_pendapatan = (SELECT a.id FROM acc_akun a WHERE a.kode_akun = '4-1000' AND a.deleted_at IS NULL),
    updated_at = now()
WHERE m.kode = 'TUNAI' AND m.id_acc_akun_kas IS NULL;

UPDATE core_metode_bayar m
SET id_acc_akun_kas = (SELECT a.id FROM acc_akun a WHERE a.kode_akun = '1-1100' AND a.deleted_at IS NULL),
    id_acc_akun_pendapatan = (SELECT a.id FROM acc_akun a WHERE a.kode_akun = '4-1000' AND a.deleted_at IS NULL),
    updated_at = now()
WHERE m.kode IN ('KARTU','QRIS','TRANSFER','LAINNYA') AND m.id_acc_akun_kas IS NULL;

UPDATE core_metode_bayar m
SET id_acc_akun_pendapatan = (SELECT a.id FROM acc_akun a WHERE a.kode_akun = '4-1100' AND a.deleted_at IS NULL),
    updated_at = now()
WHERE m.kode = 'POIN' AND m.id_acc_akun_pendapatan IS NULL;

-- PATCH 30-acc.sql selesai.
