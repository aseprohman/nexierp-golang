-- +goose Up
-- Porting 1:1 dari ddl/34-hr.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 34-hr.sql — Modul HR (KEPEGAWAIAN & PENGGAJIAN) rekonstruksi
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-hr.md (blueprint v1 ter-audit — kartu entitas §4,
--            BR HR-BR01…BR30, CFG-HR-01…15) + docs/analisa-modul-core.md.
--            Kepemilikan mengikuti peta-modul §4 (23 entitas HR).
-- Kartu    : docs/arsitektur-database-hr.md (kartu klasifikasi 23 tabel §2 +
--            keputusan desain §1–§4; gerbang arsitektur-database)
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, fungsi set_updated_at,
--            core_modules key='hr' [live id 5], core_sequences) + ACC 30
--            (acc_akun — FK nullable hr_aturan_gaji pemetaan akun M36).
-- Isi      : 23 tabel hr_* — 9 MASTER (departemen, jabatan, karyawan, jadwal_kerja,
--            hari_libur, jenis_cuti, rencana_akumulasi, jenis_input_lain,
--            struktur_gaji versi-baris) + 10 TRANSAKSI (alokasi_cuti, absensi,
--            pengajuan_lembur, pengajuan_cuti, entri_waktu, potongan_berulang,
--            kontrak_kerja, batch_payroll, slip_gaji, pemberhentian) + 4 LINE
--            (karyawan_dokumen, aturan_gaji, slip_gaji_baris, slip_gaji_input)
--            + 33 enum enum_*_hr + trigger set_updated_at 23 tabel + ensure
--            core_sequences module hr (7 existing + 3 baru).
-- Integrasi: FK keluar baca-saja — id_core_users (aktor/kepala/penyetuju),
--            id_core_files (dokumen karyawan & lampiran cuti), id_acc_akun
--            (pemetaan akun aturan gaji — RESTRICT nullable). HR tidak pernah
--            menulis master modul lain. Penomoran via core_sequences module hr:
--            payrun PR-{yyyyMM}, overtime OT-{yyyy}, loan LN-{yyyy},
--            settlement PR-SET, leave LV-{yyyy}, missing_punch MP-{yyyy},
--            shift_swap SW-{yyyy} (existing, tidak disentuh) + slip SLIP-{yyyyMM},
--            kontrak KTR-{yyyy}, pemberhentian PHT-{yyyy} (baru).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit, CREATE INDEX IF NOT EXISTS, trigger
--            DO-block DROP+CREATE, sequences ON CONFLICT DO NOTHING
--            (counter tidak pernah diturunkan).
-- Catatan  : LINE tanpa entity_id/version (pola tabel baris); uang numeric(18,4),
--            rasio numeric(18,6), hari cuti numeric(7,2) (cuti_belum_diambil
--            pemberhentian numeric(5,1) sesuai kartu), menit integer,
--            tanggal murni date, waktu kejadian timestamptz, jam jadwal time.
--            Seed master preset (jenis cuti, struktur gaji statutori, hari libur)
--            = podman/seed-hr-core.sql — di luar patch DDL ini.
-- =============================================================================

-- =============================================================================
-- §1 — ENUM (kosakata persis kartu §2 & blueprint; fail-loud bila sudah ada
--      dengan kosakata menyimpang)
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_pekerja_hr AS ENUM ('PEKERJA_TETAP','PKWT','PARUH_WAKTU','MAGANG','KONTRAKTOR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_pekerja_hr')
     IS DISTINCT FROM ARRAY['PEKERJA_TETAP','PKWT','PARUH_WAKTU','MAGANG','KONTRAKTOR']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_pekerja_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_ptkp_hr AS ENUM ('TK0','TK1','TK2','TK3','K0','K1','K2','K3');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_ptkp_hr')
     IS DISTINCT FROM ARRAY['TK0','TK1','TK2','TK3','K0','K1','K2','K3']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_ptkp_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_karyawan_hr AS ENUM ('AKTIF','NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_karyawan_hr')
     IS DISTINCT FROM ARRAY['AKTIF','NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_karyawan_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_dokumen_hr AS ENUM
    ('KTP','NPWP','IJAZAH','SERTIFIKAT','PENGALAMAN_KERJA','SURAT_SEHAT','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_dokumen_hr')
     IS DISTINCT FROM ARRAY['KTP','NPWP','IJAZAH','SERTIFIKAT','PENGALAMAN_KERJA','SURAT_SEHAT','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_dokumen_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_pola_jadwal_hr AS ENUM ('6H7J','5H8J');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_pola_jadwal_hr')
     IS DISTINCT FROM ARRAY['6H7J','5H8J']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_pola_jadwal_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_libur_hr AS ENUM ('NASIONAL','CUTI_BERSAMA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_libur_hr')
     IS DISTINCT FROM ARRAY['NASIONAL','CUTI_BERSAMA']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_libur_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_unit_cuti_hr AS ENUM ('HARI','SETENGAH','JAM');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_unit_cuti_hr')
     IS DISTINCT FROM ARRAY['HARI','SETENGAH','JAM']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_unit_cuti_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_entri_waktu_hr AS ENUM
    ('KERJA','LEMBUR','CUTI_DIBAYAR','CUTI_TANPA_UPAH','LIBUR','SAKIT','DI_LUAR_KONTRAK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_entri_waktu_hr')
     IS DISTINCT FROM ARRAY['KERJA','LEMBUR','CUTI_DIBAYAR','CUTI_TANPA_UPAH','LIBUR','SAKIT','DI_LUAR_KONTRAK']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_entri_waktu_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_sumber_entri_waktu_hr AS ENUM
    ('JADWAL','ABSENSI','PENGAJUAN_CUTI','PENGAJUAN_LEMBUR','MANUAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_entri_waktu_hr')
     IS DISTINCT FROM ARRAY['JADWAL','ABSENSI','PENGAJUAN_CUTI','PENGAJUAN_LEMBUR','MANUAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_sumber_entri_waktu_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_entri_waktu_hr AS ENUM ('DRAFT','TERVALIDASI','KONFLIK','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_entri_waktu_hr')
     IS DISTINCT FROM ARRAY['DRAFT','TERVALIDASI','KONFLIK','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_entri_waktu_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_sumber_absensi_hr AS ENUM ('SYSTRAY','KIOSK','MANUAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_absensi_hr')
     IS DISTINCT FROM ARRAY['SYSTRAY','KIOSK','MANUAL']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_sumber_absensi_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_absensi_hr AS ENUM ('BERLANGSUNG','SELESAI','DIKOREKSI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_absensi_hr')
     IS DISTINCT FROM ARRAY['BERLANGSUNG','SELESAI','DIKOREKSI']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_absensi_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pengajuan_cuti_hr AS ENUM
    ('DIAJUKAN','DIPROSES_1','DIPROSES_2','DISETUJUI','DITOLAK','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pengajuan_cuti_hr')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DIPROSES_1','DIPROSES_2','DISETUJUI','DITOLAK','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_pengajuan_cuti_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pengajuan_lembur_hr AS ENUM ('DIAJUKAN','DISETUJUI','DITOLAK','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pengajuan_lembur_hr')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_pengajuan_lembur_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_mode_alokasi_cuti_hr AS ENUM ('REGULER','AKUMULASI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_mode_alokasi_cuti_hr')
     IS DISTINCT FROM ARRAY['REGULER','AKUMULASI']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_mode_alokasi_cuti_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_alokasi_cuti_hr AS ENUM ('MENUNGGU','AKTIF','DITAMATKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_alokasi_cuti_hr')
     IS DISTINCT FROM ARRAY['MENUNGGU','AKTIF','DITAMATKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_alokasi_cuti_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_frekuensi_akumulasi_hr AS ENUM ('BULANAN','TAHUNAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_frekuensi_akumulasi_hr')
     IS DISTINCT FROM ARRAY['BULANAN','TAHUNAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_frekuensi_akumulasi_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_basis_akumulasi_hr AS ENUM ('KALENDER','HARI_KERJA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_basis_akumulasi_hr')
     IS DISTINCT FROM ARRAY['KALENDER','HARI_KERJA']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_basis_akumulasi_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_upah_hr AS ENUM ('BULANAN','HARIAN','JAM');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_upah_hr')
     IS DISTINCT FROM ARRAY['BULANAN','HARIAN','JAM']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_upah_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_struktur_gaji_hr AS ENUM ('AKTIF','ARSIP');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_struktur_gaji_hr')
     IS DISTINCT FROM ARRAY['AKTIF','ARSIP']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_struktur_gaji_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kategori_aturan_hr AS ENUM ('PENDAPATAN','POTONGAN','BEBAN_PERUSAHAAN','NET');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kategori_aturan_hr')
     IS DISTINCT FROM ARRAY['PENDAPATAN','POTONGAN','BEBAN_PERUSAHAAN','NET']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_kategori_aturan_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_basis_aturan_hr AS ENUM ('NILAI_TETAP','PERSEN_DASAR','REFERENSI_KOMPONEN','FORMULA_DSL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_basis_aturan_hr')
     IS DISTINCT FROM ARRAY['NILAI_TETAP','PERSEN_DASAR','REFERENSI_KOMPONEN','FORMULA_DSL']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_basis_aturan_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kategori_input_lain_hr AS ENUM
    ('THR','BONUS','KOMISI','REIMBURSEMENT','POTONGAN_KHUSUS');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kategori_input_lain_hr')
     IS DISTINCT FROM ARRAY['THR','BONUS','KOMISI','REIMBURSEMENT','POTONGAN_KHUSUS']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_kategori_input_lain_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_potongan_hr AS ENUM ('CICILAN_PINJAMAN','KOPERASI','GARNISHMENT','LAINNYA');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_potongan_hr')
     IS DISTINCT FROM ARRAY['CICILAN_PINJAMAN','KOPERASI','GARNISHMENT','LAINNYA']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_potongan_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_potongan_hr AS ENUM ('AKTIF','LUNAS','DITAMATKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_potongan_hr')
     IS DISTINCT FROM ARRAY['AKTIF','LUNAS','DITAMATKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_potongan_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_kontrak_hr AS ENUM ('PKW','PKWT');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_kontrak_hr')
     IS DISTINCT FROM ARRAY['PKW','PKWT']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_kontrak_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_kontrak_hr AS ENUM ('DRAFT','BERJALAN','BERAKHIR','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_kontrak_hr')
     IS DISTINCT FROM ARRAY['DRAFT','BERJALAN','BERAKHIR','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_kontrak_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_batch_payroll_hr AS ENUM ('BARU','DIKONFIRMASI','SELESAI','DIBAYAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_batch_payroll_hr')
     IS DISTINCT FROM ARRAY['BARU','DIKONFIRMASI','SELESAI','DIBAYAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_batch_payroll_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_slip_hr AS ENUM ('REGULER','THR','PEMBALIK');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_slip_hr')
     IS DISTINCT FROM ARRAY['REGULER','THR','PEMBALIK']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_jenis_slip_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_slip_hr AS ENUM
    ('DRAFT','DIHITUNG','DIAJUKAN','DITERBITKAN','DIBAYAR','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_slip_hr')
     IS DISTINCT FROM ARRAY['DRAFT','DIHITUNG','DIAJUKAN','DITERBITKAN','DIBAYAR','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_slip_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kategori_ter_hr AS ENUM ('A','B','C');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kategori_ter_hr')
     IS DISTINCT FROM ARRAY['A','B','C']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_kategori_ter_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- 18 nilai sesuai PP 35/2021 Pasal 36 (huruf a–p) + pengambilalihan + PKWT berakhir
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_alasan_pemberhentian_hr AS ENUM
    ('RESIGN','TIDAK_SAH','MANGKIR_5_HARI','PELANGGARAN_SP1_SP3','TINDAK_PIDANA',
     'EFISIENSI_RUGI','EFISIENSI_HINDARI_RUGI','TUTUP_RUGI','TUTUP_BUKAN_RUGI',
     'FORCE_MAJEURE','FORCE_MAJEURE_RUGI','FORCE_MAJEURE_HINDARI_RUGI',
     'USIA_PENSIUN','MENINGGAL','SAKIT_CACAT_KERJA_12BULAN','PUTUSAN_PENGADILAN',
     'PENGAMBILALIHAN','PKWT_BERAKHIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_alasan_pemberhentian_hr')
     IS DISTINCT FROM ARRAY['RESIGN','TIDAK_SAH','MANGKIR_5_HARI','PELANGGARAN_SP1_SP3','TINDAK_PIDANA',
       'EFISIENSI_RUGI','EFISIENSI_HINDARI_RUGI','TUTUP_RUGI','TUTUP_BUKAN_RUGI',
       'FORCE_MAJEURE','FORCE_MAJEURE_RUGI','FORCE_MAJEURE_HINDARI_RUGI',
       'USIA_PENSIUN','MENINGGAL','SAKIT_CACAT_KERJA_12BULAN','PUTUSAN_PENGADILAN',
       'PENGAMBILALIHAN','PKWT_BERAKHIR']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_alasan_pemberhentian_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_pemberhentian_hr AS ENUM ('USULAN','DISETUJUI','SELESAI','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_pemberhentian_hr')
     IS DISTINCT FROM ARRAY['USULAN','DISETUJUI','SELESAI','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 34-hr: enum_status_pemberhentian_hr kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 — TABEL MASTER (urutan dependensi FK)
-- =============================================================================

-- 2.1 hr_departemen — [MASTER] — unit organisasi bertingkat (setara hr.department)
CREATE TABLE IF NOT EXISTS hr_departemen (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique partial HIDUP (organisasi boleh hidup kembali)
  nama                   varchar(100) NOT NULL,
  id_hr_departemen       bigint,                    -- induk (di-ADD FK di bawah — self)
  id_core_users          bigint,                    -- kepala departemen (aktor CORE, SET NULL)
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_departemen_entity_id UNIQUE (entity_id)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_departemen_induk') THEN
    ALTER TABLE hr_departemen ADD CONSTRAINT fk_hr_departemen_induk
      FOREIGN KEY (id_hr_departemen) REFERENCES hr_departemen (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_departemen_kepala') THEN
    ALTER TABLE hr_departemen ADD CONSTRAINT fk_hr_departemen_kepala
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_departemen_induk_bukan_diri') THEN
    ALTER TABLE hr_departemen ADD CONSTRAINT ck_hr_departemen_induk_bukan_diri
      CHECK (id_hr_departemen IS NULL OR id_hr_departemen <> id);
  END IF;
END $$;
-- +goose StatementEnd

CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_departemen_kode_hidup
  ON hr_departemen (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_departemen_induk
  ON hr_departemen (id_hr_departemen) WHERE id_hr_departemen IS NOT NULL;

-- 2.2 hr_jabatan — [MASTER] — jabatan per departemen + kelas risiko JKK (PP 36/2021)
CREATE TABLE IF NOT EXISTS hr_jabatan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique partial HIDUP
  nama                   varchar(100) NOT NULL,
  id_hr_departemen       bigint,                    -- SET NULL saat departemen dihapus
  kelas_risiko_jkk       smallint,                  -- I..V (diskrit regulasi — bukan enum)
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_jabatan_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_jabatan_kelas_jkk
    CHECK (kelas_risiko_jkk IS NULL OR kelas_risiko_jkk BETWEEN 1 AND 5),
  CONSTRAINT fk_hr_jabatan_departemen FOREIGN KEY (id_hr_departemen)
    REFERENCES hr_departemen (id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_jabatan_kode_hidup
  ON hr_jabatan (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_jabatan_departemen ON hr_jabatan (id_hr_departemen);

-- 2.3 hr_karyawan — [MASTER] — pegawai (setara hr.employee; PTKP → kategori TER PP 58/2023)
CREATE TABLE IF NOT EXISTS hr_karyawan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nik_pegawai            varchar(50) NOT NULL,      -- unique partial HIDUP (registrasi kepegawaian)
  nama_lengkap           varchar(100) NOT NULL,
  jenis_pekerja          enum_jenis_pekerja_hr NOT NULL,
  ptkp                   enum_ptkp_hr NOT NULL DEFAULT 'TK0',  -- TER A/B/C diturunkan (HR-BR15)
  status                 enum_status_karyawan_hr NOT NULL DEFAULT 'AKTIF',
  id_hr_departemen       bigint,                    -- SET NULL (referensi organisasi)
  id_hr_jabatan          bigint,                    -- SET NULL
  id_hr_karyawan         bigint,                    -- atasan langsung (self — FK di bawah)
  id_core_users          bigint,                    -- link self-service (opsional, SET NULL)
  tanggal_masuk          date,
  tanggal_keluar         date,                      -- terisi oleh pemberhentian SELESAI
  bank                   varchar(100),              -- tujuan gaji (prasyarat slip HR-BR26)
  no_rekening            varchar(100),
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_karyawan_entity_id UNIQUE (entity_id)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_karyawan_atasan') THEN
    ALTER TABLE hr_karyawan ADD CONSTRAINT fk_hr_karyawan_atasan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_karyawan_departemen') THEN
    ALTER TABLE hr_karyawan ADD CONSTRAINT fk_hr_karyawan_departemen
      FOREIGN KEY (id_hr_departemen) REFERENCES hr_departemen (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_karyawan_jabatan') THEN
    ALTER TABLE hr_karyawan ADD CONSTRAINT fk_hr_karyawan_jabatan
      FOREIGN KEY (id_hr_jabatan) REFERENCES hr_jabatan (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_karyawan_link_user') THEN
    ALTER TABLE hr_karyawan ADD CONSTRAINT fk_hr_karyawan_link_user
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_karyawan_atasan_bukan_diri') THEN
    ALTER TABLE hr_karyawan ADD CONSTRAINT ck_hr_karyawan_atasan_bukan_diri
      CHECK (id_hr_karyawan IS NULL OR id_hr_karyawan <> id);
  END IF;
END $$;
-- +goose StatementEnd

CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_karyawan_nik_hidup
  ON hr_karyawan (nik_pegawai) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_karyawan_status ON hr_karyawan (status);
CREATE INDEX IF NOT EXISTS ix_hr_karyawan_departemen
  ON hr_karyawan (id_hr_departemen) WHERE id_hr_departemen IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_karyawan_jabatan
  ON hr_karyawan (id_hr_jabatan) WHERE id_hr_jabatan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_karyawan_atasan
  ON hr_karyawan (id_hr_karyawan) WHERE id_hr_karyawan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_karyawan_link_user
  ON hr_karyawan (id_core_users) WHERE id_core_users IS NOT NULL;

-- 2.4 hr_karyawan_dokumen — [LINE] — lampiran dokumen karyawan (id_core_files RESTRICT)
CREATE TABLE IF NOT EXISTS hr_karyawan_dokumen (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_hr_karyawan         bigint NOT NULL,
  id_core_files          bigint,                    -- berkas fisik (RESTRICT nullable)
  jenis_dokumen          enum_jenis_dokumen_hr NOT NULL,
  nomor                  varchar(150),              -- nomor berlaku pada dokumen (KTP/NPWP/ijazah)
  keterangan             varchar(200),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_hr_kar_dok_karyawan FOREIGN KEY (id_hr_karyawan)
    REFERENCES hr_karyawan (id) ON DELETE CASCADE,
  CONSTRAINT fk_hr_kar_dok_file FOREIGN KEY (id_core_files)
    REFERENCES core_files (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_hr_kar_dok_karyawan ON hr_karyawan_dokumen (id_hr_karyawan);
CREATE INDEX IF NOT EXISTS ix_hr_kar_dok_file
  ON hr_karyawan_dokumen (id_core_files) WHERE id_core_files IS NOT NULL;

-- 2.5 hr_jadwal_kerja — [MASTER] — kalender jam kerja (pola PP 35/2021 Pasal 21; CFG-HR-01)
CREATE TABLE IF NOT EXISTS hr_jadwal_kerja (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                   varchar(100) NOT NULL,     -- unique partial HIDUP
  pola                   enum_pola_jadwal_hr NOT NULL,  -- 6H7J | 5H8J
  hari_kerja             jsonb NOT NULL,            -- array hari aktif (jsonb — §1.4 kartu; tak difilter per hari)
  jam_masuk              time NOT NULL,
  jam_keluar             time NOT NULL,
  istirahat_menit        integer NOT NULL DEFAULT 0,  -- ≥30 menit setelah 4 jam (validasi app HR-BR09)
  toleransi_menit        integer NOT NULL DEFAULT 0,  -- toleransi telat/pulang awal
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_jadwal_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_jadwal_menit_nonnegatif
    CHECK (istirahat_menit >= 0 AND toleransi_menit >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_jadwal_nama_hidup
  ON hr_jadwal_kerja (nama) WHERE deleted_at IS NULL;

-- 2.6 hr_hari_libur — [MASTER] — libur nasional & cuti bersama per tahun (HR-BR09/BR10)
CREATE TABLE IF NOT EXISTS hr_hari_libur (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  tanggal                date NOT NULL,             -- unique partial HIDUP (1 hari 1 baris)
  nama                   varchar(100) NOT NULL,
  jenis                  enum_jenis_libur_hr NOT NULL,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_hari_libur_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_hari_libur_tanggal_hidup
  ON hr_hari_libur (tanggal) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_hari_libur_tahun ON hr_hari_libur (tanggal);

-- 2.7 hr_jenis_cuti — [MASTER] — tipe cuti/izin (preset regulasi HR-BR20 — seed terpisah)
CREATE TABLE IF NOT EXISTS hr_jenis_cuti (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique partial HIDUP
  nama                   varchar(100) NOT NULL,
  unit                   enum_unit_cuti_hr NOT NULL DEFAULT 'HARI',
  entri_waktu_terkait    enum_jenis_entri_waktu_hr, -- CUTI_DIBAYAR | CUTI_TANPA_UPAH | SAKIT | LIBUR | NULL
  preset_regulasi        varchar(50),               -- mis. 'CUTI_TAHUNAN_12' | 'HAID_2' | NULL (custom)
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_jenis_cuti_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_jenis_cuti_kode_hidup
  ON hr_jenis_cuti (kode) WHERE deleted_at IS NULL;

-- 2.8 hr_rencana_akumulasi — [MASTER] — rencana akumulasi kuota cuti (HR-BR20; cuti tahunan 12)
CREATE TABLE IF NOT EXISTS hr_rencana_akumulasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nama                   varchar(100) NOT NULL,
  frekuensi              enum_frekuensi_akumulasi_hr NOT NULL,
  jumlah_per_periode     numeric(7,2) NOT NULL CHECK (jumlah_per_periode >= 0),  -- hari per periode
  cap                    numeric(7,2),              -- batas maksimum saldo (NULL = tanpa cap)
  carryover              boolean NOT NULL DEFAULT false,  -- sisa dibawa periode berikut
  basis                  enum_basis_akumulasi_hr NOT NULL DEFAULT 'KALENDER',
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_rencana_akumulasi_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_rencana_cap CHECK (cap IS NULL OR cap >= 0)
);

-- =============================================================================
-- §3 — TABEL TRANSAKSI (kehadiran, cuti, lembur, entri waktu, gaji)
-- =============================================================================

-- 3.1 hr_alokasi_cuti — [TRANSAKSI] — pemberian kuota cuti per karyawan (HR-BR20)
CREATE TABLE IF NOT EXISTS hr_alokasi_cuti (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  id_hr_jenis_cuti       bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  id_hr_rencana_akumulasi bigint,                   -- wajib bila mode AKUMULASI (SET NULL)
  mode                   enum_mode_alokasi_cuti_hr NOT NULL DEFAULT 'REGULER',
  status                 enum_status_alokasi_cuti_hr NOT NULL DEFAULT 'MENUNGGU',
  jumlah                 numeric(7,2) NOT NULL CHECK (jumlah >= 0),  -- hari (HR-BR20)
  sisa                   numeric(7,2) NOT NULL DEFAULT 0 CHECK (sisa >= 0),
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_alokasi_cuti_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_alokasi_cuti_akumulasi_rencana
    CHECK (mode <> 'AKUMULASI' OR id_hr_rencana_akumulasi IS NOT NULL)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_alokasi_cuti_karyawan') THEN
    ALTER TABLE hr_alokasi_cuti ADD CONSTRAINT fk_hr_alokasi_cuti_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_alokasi_cuti_jenis') THEN
    ALTER TABLE hr_alokasi_cuti ADD CONSTRAINT fk_hr_alokasi_cuti_jenis
      FOREIGN KEY (id_hr_jenis_cuti) REFERENCES hr_jenis_cuti (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_alokasi_cuti_rencana') THEN
    ALTER TABLE hr_alokasi_cuti ADD CONSTRAINT fk_hr_alokasi_cuti_rencana
      FOREIGN KEY (id_hr_rencana_akumulasi) REFERENCES hr_rencana_akumulasi (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_alokasi_cuti_karyawan_jenis
  ON hr_alokasi_cuti (id_hr_karyawan, id_hr_jenis_cuti);
CREATE INDEX IF NOT EXISTS ix_hr_alokasi_cuti_status
  ON hr_alokasi_cuti (status);

-- 3.2 hr_absensi — [TRANSAKSI] — satu siklus check-in/check-out (tanpa unique —
--     satu hari bisa multi-sesi; selisih vs jadwal = telat/pulang awal)
CREATE TABLE IF NOT EXISTS hr_absensi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  tanggal                date NOT NULL,
  jam_masuk              timestamptz,
  jam_keluar             timestamptz,
  durasi_menit           integer,                   -- jam_keluar - jam_masuk
  selisih_menit          integer,                   -- telat(+)/pulang awal(-) vs jadwal
  sumber                 enum_sumber_absensi_hr NOT NULL,
  status                 enum_status_absensi_hr NOT NULL DEFAULT 'BERLANGSUNG',
  lokasi_gps             jsonb,                     -- {lat,lng} — tak difilter (§1.4 kartu)
  keterangan             varchar(300),              -- alasan koreksi manual (ter-audit)
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_absensi_entity_id UNIQUE (entity_id)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_absensi_karyawan') THEN
    ALTER TABLE hr_absensi ADD CONSTRAINT fk_hr_absensi_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_absensi_rentang') THEN
    ALTER TABLE hr_absensi ADD CONSTRAINT ck_hr_absensi_rentang
      CHECK (jam_masuk IS NULL OR jam_keluar IS NULL OR jam_keluar > jam_masuk);
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_absensi_karyawan_tanggal
  ON hr_absensi (id_hr_karyawan, tanggal);

-- 3.3 hr_pengajuan_lembur — [TRANSAKSI] — perintah + persetujuan lembur
--     (PP 35/2021 Pasal 28; batas 4j/hari & 18j/minggu di-validasi app — HR-BR09)
CREATE TABLE IF NOT EXISTS hr_pengajuan_lembur (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  tanggal                date NOT NULL,
  jam_mulai              timestamptz NOT NULL,
  jam_akhir              timestamptz NOT NULL,
  durasi_menit           integer NOT NULL CHECK (durasi_menit > 0),
  alasan                 varchar(300) NOT NULL,
  id_core_users          bigint,                    -- penyetuju (SET NULL — aktor)
  status                 enum_status_pengajuan_lembur_hr NOT NULL DEFAULT 'DIAJUKAN',
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_pengajuan_lembur_entity_id UNIQUE (entity_id)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_lembur_karyawan') THEN
    ALTER TABLE hr_pengajuan_lembur ADD CONSTRAINT fk_hr_lembur_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_lembur_penyetuju') THEN
    ALTER TABLE hr_pengajuan_lembur ADD CONSTRAINT fk_hr_lembur_penyetuju
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_lembur_rentang') THEN
    ALTER TABLE hr_pengajuan_lembur ADD CONSTRAINT ck_hr_lembur_rentang
      CHECK (jam_akhir > jam_mulai);
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_lembur_karyawan_tanggal
  ON hr_pengajuan_lembur (id_hr_karyawan, tanggal);
CREATE INDEX IF NOT EXISTS ix_hr_lembur_status ON hr_pengajuan_lembur (status);

-- 3.4 hr_pengajuan_cuti — [TRANSAKSI] — permintaan cuti/izin + approval berjenjang
--     (DIPROSES_1 Pimpinan Tim → DIPROSES_2 Staf HR bila CFG-HR-03)
CREATE TABLE IF NOT EXISTS hr_pengajuan_cuti (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  id_hr_jenis_cuti       bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  tanggal                date NOT NULL,             -- awal rentang
  tanggal_akhir          date,                      -- NULL = satu hari
  jumlah                 numeric(7,2) NOT NULL CHECK (jumlah > 0),  -- hari (HR-BR20)
  id_core_files          bigint,                    -- lampiran (izin KIA/haid wajib — HR-BR20)
  id_core_users_penyetuju_1 bigint,                 -- Pimpinan Tim (SET NULL)
  id_core_users_penyetuju_2 bigint,                 -- Staf HR (SET NULL, bila double)
  status                 enum_status_pengajuan_cuti_hr NOT NULL DEFAULT 'DIAJUKAN',
  keterangan             varchar(300),              -- alasan penolakan/pembatalan (STD-06)
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_pengajuan_cuti_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_pengajuan_cuti_rentang
    CHECK (tanggal_akhir IS NULL OR tanggal_akhir >= tanggal)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_cutikaryawan') THEN
    ALTER TABLE hr_pengajuan_cuti ADD CONSTRAINT fk_hr_cutikaryawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_cuti_jenis') THEN
    ALTER TABLE hr_pengajuan_cuti ADD CONSTRAINT fk_hr_cuti_jenis
      FOREIGN KEY (id_hr_jenis_cuti) REFERENCES hr_jenis_cuti (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_cuti_lampiran') THEN
    ALTER TABLE hr_pengajuan_cuti ADD CONSTRAINT fk_hr_cuti_lampiran
      FOREIGN KEY (id_core_files) REFERENCES core_files (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_cuti_penyetuju_1') THEN
    ALTER TABLE hr_pengajuan_cuti ADD CONSTRAINT fk_hr_cuti_penyetuju_1
      FOREIGN KEY (id_core_users_penyetuju_1) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_cuti_penyetuju_2') THEN
    ALTER TABLE hr_pengajuan_cuti ADD CONSTRAINT fk_hr_cuti_penyetuju_2
      FOREIGN KEY (id_core_users_penyetuju_2) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_cuti_karyawan_tanggal
  ON hr_pengajuan_cuti (id_hr_karyawan, tanggal);
CREATE INDEX IF NOT EXISTS ix_hr_cuti_status ON hr_pengajuan_cuti (status);
CREATE INDEX IF NOT EXISTS ix_hr_cuti_lampiran
  ON hr_pengajuan_cuti (id_core_files) WHERE id_core_files IS NOT NULL;

-- 3.5 hr_entri_waktu — [TRANSAKSI volume tinggi] — work entry yang dibaca payroll
--     (tanpa unique multi-kolom — idempotensi regenerate di layer kode STD-07;
--     3 FK sumber polimorfik nullable, maks satu terisi)
CREATE TABLE IF NOT EXISTS hr_entri_waktu (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  tanggal                date NOT NULL,
  jenis                  enum_jenis_entri_waktu_hr NOT NULL,
  sumber                 enum_sumber_entri_waktu_hr NOT NULL,
  durasi_menit           integer NOT NULL CHECK (durasi_menit >= 0),
  id_hr_absensi          bigint,                    -- sumber 1/3 (FK di bawah)
  id_hr_pengajuan_cuti   bigint,                    -- sumber 2/3 (FK di bawah)
  id_hr_pengajuan_lembur bigint,                    -- sumber 3/3 (FK di bawah)
  status                 enum_status_entri_waktu_hr NOT NULL DEFAULT 'DRAFT',
  keterangan             varchar(300),              -- wajib utk MANUAL (validasi app)
  version                integer NOT NULL DEFAULT 1,  -- edit manual (optimistic locking)
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_entri_waktu_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_hr_entri_waktu_satus_sumber
    CHECK (
      (id_hr_absensi IS NOT NULL)::int
      + (id_hr_pengajuan_cuti IS NOT NULL)::int
      + (id_hr_pengajuan_lembur IS NOT NULL)::int
      <= 1
    )
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_entri_waktu_karyawan') THEN
    ALTER TABLE hr_entri_waktu ADD CONSTRAINT fk_hr_entri_waktu_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_entri_waktu_absensi') THEN
    ALTER TABLE hr_entri_waktu ADD CONSTRAINT fk_hr_entri_waktu_absensi
      FOREIGN KEY (id_hr_absensi) REFERENCES hr_absensi (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_entri_waktu_cuti') THEN
    ALTER TABLE hr_entri_waktu ADD CONSTRAINT fk_hr_entri_waktu_cuti
      FOREIGN KEY (id_hr_pengajuan_cuti) REFERENCES hr_pengajuan_cuti (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_entri_waktu_lembur') THEN
    ALTER TABLE hr_entri_waktu ADD CONSTRAINT fk_hr_entri_waktu_lembur
      FOREIGN KEY (id_hr_pengajuan_lembur) REFERENCES hr_pengajuan_lembur (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_entri_waktu_karyawan_tanggal
  ON hr_entri_waktu (id_hr_karyawan, tanggal);
CREATE INDEX IF NOT EXISTS ix_hr_entri_waktu_antrian
  ON hr_entri_waktu (status) WHERE status IN ('DRAFT','KONFLIK');
CREATE INDEX IF NOT EXISTS ix_hr_entri_waktu_absensi
  ON hr_entri_waktu (id_hr_absensi) WHERE id_hr_absensi IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_entri_waktu_cuti
  ON hr_entri_waktu (id_hr_pengajuan_cuti) WHERE id_hr_pengajuan_cuti IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_entri_waktu_lembur
  ON hr_entri_waktu (id_hr_pengajuan_lembur) WHERE id_hr_pengajuan_lembur IS NOT NULL;

-- 3.6 hr_struktur_gaji — [MASTER versi = baris] — struktur komponen upah
--     (versi berikutnya = baris baru; slip beku pada baris ARSIP — HR-BR05)
CREATE TABLE IF NOT EXISTS hr_struktur_gaji (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- (kode, versi) unique partial HIDUP
  nama                   varchar(100) NOT NULL,
  versi                  integer NOT NULL DEFAULT 1 CHECK (versi >= 1),
  jenis_upah             enum_jenis_upah_hr NOT NULL,
  status                 enum_status_struktur_gaji_hr NOT NULL DEFAULT 'AKTIF',
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_struktur_gaji_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_struktur_gaji_kode_versi_hidup
  ON hr_struktur_gaji (kode, versi) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_struktur_gaji_kode
  ON hr_struktur_gaji (kode) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_struktur_gaji_aktif
  ON hr_struktur_gaji (kode) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- 3.7 hr_aturan_gaji — [LINE of struktur] — aturan komponen (mengikuti versi induk;
--     CASCADE — LINE murni; snapshot di hr_slip_gaji_baris saat slip terbit)
CREATE TABLE IF NOT EXISTS hr_aturan_gaji (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_hr_struktur_gaji    bigint NOT NULL,
  kode                   varchar(50) NOT NULL,      -- BASIC | LEMBUR | THR | BPJS_* | PPH21 | NET | …
  ref_kode               varchar(50),               -- rujukan komponen lain (REFERENSI_KOMPONEN)
  nama                   varchar(100) NOT NULL,     -- label tampil slip
  kategori               enum_kategori_aturan_hr NOT NULL,
  basis                  enum_basis_aturan_hr NOT NULL,
  urutan                 integer NOT NULL DEFAULT 0,
  persen                 numeric(18,6),             -- utk PERSEN_DASAR (rasio — bucket 18,6)
  nilai_dasar            numeric(18,4),             -- utk NILAI_TETAP (uang)
  formula                varchar(300),              -- ekspresi FORMULA_DSL (bucket — bukan text)
  id_acc_akun            bigint,                    -- pemetaan akun ACC (RESTRICT nullable — M36)
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_hr_aturan_gaji_struktur FOREIGN KEY (id_hr_struktur_gaji)
    REFERENCES hr_struktur_gaji (id) ON DELETE CASCADE,
  CONSTRAINT ck_hr_aturan_gaji_nilai
    CHECK ((persen IS NULL OR persen >= 0) AND (nilai_dasar IS NULL OR nilai_dasar >= 0))
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_aturan_gaji_akun') THEN
    ALTER TABLE hr_aturan_gaji ADD CONSTRAINT fk_hr_aturan_gaji_akun
      FOREIGN KEY (id_acc_akun) REFERENCES acc_akun (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_aturan_gaji_struktur
  ON hr_aturan_gaji (id_hr_struktur_gaji);
CREATE INDEX IF NOT EXISTS ix_hr_aturan_gaji_akun
  ON hr_aturan_gaji (id_acc_akun) WHERE id_acc_akun IS NOT NULL;

-- 3.8 hr_jenis_input_lain — [MASTER] — tipe input insidental slip (THR, bonus, komisi —)
CREATE TABLE IF NOT EXISTS hr_jenis_input_lain (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  kode                   varchar(50) NOT NULL,      -- unique partial HIDUP; dirujuk aturan inputs.kode
  nama                   varchar(100) NOT NULL,
  kategori               enum_kategori_input_lain_hr NOT NULL,
  eligible_pph           boolean NOT NULL DEFAULT false,
  eligible_bpjs          boolean NOT NULL DEFAULT false,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_jenis_input_entity_id UNIQUE (entity_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_jenis_input_kode_hidup
  ON hr_jenis_input_lain (kode) WHERE deleted_at IS NULL;

-- 3.9 hr_potongan_berulang — [TRANSAKSI] — potongan antar periode (setara hr.salary.attachment)
CREATE TABLE IF NOT EXISTS hr_potongan_berulang (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT (hist.) — FK di bawah
  jenis                  enum_jenis_potongan_hr NOT NULL,
  keterangan             varchar(200),
  nilai_per_periode      numeric(18,4) NOT NULL CHECK (nilai_per_periode >= 0),
  sisa_total             numeric(18,4) NOT NULL DEFAULT 0 CHECK (sisa_total >= 0),
  tanggal_mulai          date,
  estimasi_selesai       date,
  status                 enum_status_potongan_hr NOT NULL DEFAULT 'AKTIF',
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_potongan_berulang_entity_id UNIQUE (entity_id)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_potongan_karyawan') THEN
    ALTER TABLE hr_potongan_berulang ADD CONSTRAINT fk_hr_potongan_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_potongan_berjalan
  ON hr_potongan_berulang (id_hr_karyawan, status)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- 3.10 hr_kontrak_kerja — [TRANSAKSI] — PKW/PKWT (PP 35/2021; PKWT maks 5 tahun & tanpa
--      masa percobaan — HR-BR08/BR22; nomor doc_name 'kontrak' prefix KTR-{yyyy})
CREATE TABLE IF NOT EXISTS hr_kontrak_kerja (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL (penomoran tak dipakai ulang)
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT — FK di bawah
  id_hr_jadwal_kerja     bigint NOT NULL,           -- RESTRICT — FK di bawah
  id_hr_struktur_gaji    bigint NOT NULL,           -- RESTRICT — FK di bawah (live ref baris AKTIF)
  jenis                  enum_jenis_kontrak_hr NOT NULL,
  jenis_upah             enum_jenis_upah_hr NOT NULL,
  status                 enum_status_kontrak_hr NOT NULL DEFAULT 'DRAFT',
  tanggal_mulai          date NOT NULL,
  tanggal_akhir          date,                      -- PKWT — dasar kompensasi Pasal 15-16
  upah                   numeric(18,4) NOT NULL CHECK (upah >= 0),
  masa_percobaan_akhir   date,                      -- PKW saja (CHECK di bawah — PP 35/2021 Pasal 12)
  kelas_risiko_jkk       smallint,                  -- I..V kontrak berjalan
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_kontrak_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_hr_kontrak_nomor UNIQUE (nomor),
  CONSTRAINT ck_hr_kontrak_percobaan_hanya_pkw
    CHECK (jenis = 'PKW' OR masa_percobaan_akhir IS NULL),
  CONSTRAINT ck_hr_kontrak_akhir_setelah_mulai
    CHECK (tanggal_akhir IS NULL OR tanggal_akhir > tanggal_mulai)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_kontrak_karyawan') THEN
    ALTER TABLE hr_kontrak_kerja ADD CONSTRAINT fk_hr_kontrak_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_kontrak_jadwal') THEN
    ALTER TABLE hr_kontrak_kerja ADD CONSTRAINT fk_hr_kontrak_jadwal
      FOREIGN KEY (id_hr_jadwal_kerja) REFERENCES hr_jadwal_kerja (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_kontrak_struktur') THEN
    ALTER TABLE hr_kontrak_kerja ADD CONSTRAINT fk_hr_kontrak_struktur
      FOREIGN KEY (id_hr_struktur_gaji) REFERENCES hr_struktur_gaji (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_kontrak_kelas_jkk') THEN
    ALTER TABLE hr_kontrak_kerja ADD CONSTRAINT ck_hr_kontrak_kelas_jkk
      CHECK (kelas_risiko_jkk IS NULL OR kelas_risiko_jkk BETWEEN 1 AND 5);
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_kontrak_berjalan
  ON hr_kontrak_kerja (id_hr_karyawan, status)
  WHERE status = 'BERJALAN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_hr_kontrak_karyawan
  ON hr_kontrak_kerja (id_hr_karyawan);

-- 3.11 hr_batch_payroll — [TRANSAKSI] — run payroll satu periode (nomor doc_name
--      'payrun' prefix PR-{yyyyMM} — existing; BARU→DIKONFIRMASI→SELESAI→DIBAYAR)
CREATE TABLE IF NOT EXISTS hr_batch_payroll (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL
  periode                date NOT NULL,
  status                 enum_status_batch_payroll_hr NOT NULL DEFAULT 'BARU',
  ringkasan_beban        numeric(18,4) NOT NULL DEFAULT 0,  -- biaya perusahaan
  total_thp              numeric(18,4) NOT NULL DEFAULT 0,
  konfirmasi_at          timestamptz,
  dibayar_at             timestamptz,
  keterangan             varchar(200),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_batch_payroll_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_hr_batch_payroll_nomor UNIQUE (nomor)
);
CREATE INDEX IF NOT EXISTS ix_hr_batch_payroll_periode ON hr_batch_payroll (periode);

-- 3.12 hr_slip_gaji — [TRANSAKSI] — bukti upah satu karyawan satu periode (PP 36/2021
--      Pasal 53(2); baris = snapshot beku HR-BR05; PEMBALIK wajib merujuk slip asal —
--      HR-BR02/BR29; nomor doc_name 'slip' prefix SLIP-{yyyyMM})
CREATE TABLE IF NOT EXISTS hr_slip_gaji (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT — FK di bawah
  id_hr_kontrak_kerja    bigint NOT NULL,           -- RESTRICT — FK di bawah
  id_hr_batch_payroll    bigint,                    -- SET NULL (anggota batch opsional — THR off-cycle)
  id_hr_struktur_gaji    bigint NOT NULL,           -- RESTRICT — FK di bawah (versi ARSIP = snapshot)
  id_hr_slip_gaji_asal   bigint,                    -- self-FK SET NULL — wajib utk PEMBALIK
  jenis                  enum_jenis_slip_hr NOT NULL DEFAULT 'REGULER',
  status                 enum_status_slip_hr NOT NULL DEFAULT 'DRAFT',
  kategori_ter           enum_kategori_ter_hr,      -- A/B/C (PP 58/2023 Pasal 2(4))
  periode                date NOT NULL,
  total_bruto            numeric(18,4) NOT NULL DEFAULT 0,
  total_potongan         numeric(18,4) NOT NULL DEFAULT 0,
  total_thp              numeric(18,4) NOT NULL DEFAULT 0,
  dasar_ter              numeric(18,4),             -- dasar TER bulan berjalan
  pph21                  numeric(18,4) NOT NULL DEFAULT 0,
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_slip_gaji_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_hr_slip_gaji_nomor UNIQUE (nomor),
  CONSTRAINT ck_hr_slip_gaji_pembalik_asal
    CHECK (jenis <> 'PEMBALIK' OR id_hr_slip_gaji_asal IS NOT NULL)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_slip_gaji_karyawan') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT fk_hr_slip_gaji_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_slip_gaji_kontrak') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT fk_hr_slip_gaji_kontrak
      FOREIGN KEY (id_hr_kontrak_kerja) REFERENCES hr_kontrak_kerja (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_slip_gaji_batch') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT fk_hr_slip_gaji_batch
      FOREIGN KEY (id_hr_batch_payroll) REFERENCES hr_batch_payroll (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_slip_gaji_struktur') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT fk_hr_slip_gaji_struktur
      FOREIGN KEY (id_hr_struktur_gaji) REFERENCES hr_struktur_gaji (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_slip_gaji_asal') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT fk_hr_slip_gaji_asal
      FOREIGN KEY (id_hr_slip_gaji_asal) REFERENCES hr_slip_gaji (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_hr_slip_gaji_asal_bukan_diri') THEN
    ALTER TABLE hr_slip_gaji ADD CONSTRAINT ck_hr_slip_gaji_asal_bukan_diri
      CHECK (id_hr_slip_gaji_asal IS NULL OR id_hr_slip_gaji_asal <> id);
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_slip_gaji_karyawan_periode
  ON hr_slip_gaji (id_hr_karyawan, periode);
CREATE INDEX IF NOT EXISTS ix_hr_slip_gaji_batch
  ON hr_slip_gaji (id_hr_batch_payroll) WHERE id_hr_batch_payroll IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_slip_gaji_antrian
  ON hr_slip_gaji (status) WHERE status = 'DIAJUKAN';
CREATE INDEX IF NOT EXISTS ix_hr_slip_gaji_asal
  ON hr_slip_gaji (id_hr_slip_gaji_asal) WHERE id_hr_slip_gaji_asal IS NOT NULL;

-- 3.13 hr_slip_gaji_baris — [LINE of slip] — snapshot aturan beku saat terbit (HR-BR05;
--      tanpa FK ke hr_aturan_gaji — koreksi historis tidak boleh bergeser)
CREATE TABLE IF NOT EXISTS hr_slip_gaji_baris (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_hr_slip_gaji        bigint NOT NULL,
  kode                   varchar(50) NOT NULL,      -- snapshot kode aturan
  kategori               enum_kategori_aturan_hr NOT NULL,  -- snapshot kategori
  label                  varchar(100) NOT NULL,     -- snapshot label tampil slip
  dasar                  numeric(18,4) NOT NULL DEFAULT 0,
  nilai                  numeric(18,4) NOT NULL DEFAULT 0,
  urutan                 integer NOT NULL DEFAULT 0,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_hr_slip_baris_slip FOREIGN KEY (id_hr_slip_gaji)
    REFERENCES hr_slip_gaji (id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_hr_slip_baris_slip ON hr_slip_gaji_baris (id_hr_slip_gaji);

-- 3.14 hr_slip_gaji_input — [LINE of slip] — nilai input lain per slip (petugas payroll)
CREATE TABLE IF NOT EXISTS hr_slip_gaji_input (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_hr_slip_gaji        bigint NOT NULL,
  id_hr_jenis_input_lain bigint NOT NULL,
  nilai                  numeric(18,4) NOT NULL CHECK (nilai >= 0),
  keterangan             varchar(200),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_hr_slip_input_slip FOREIGN KEY (id_hr_slip_gaji)
    REFERENCES hr_slip_gaji (id) ON DELETE CASCADE,
  CONSTRAINT fk_hr_slip_input_jenis FOREIGN KEY (id_hr_jenis_input_lain)
    REFERENCES hr_jenis_input_lain (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_hr_slip_input_slip ON hr_slip_gaji_input (id_hr_slip_gaji);
CREATE INDEX IF NOT EXISTS ix_hr_slip_input_jenis ON hr_slip_gaji_input (id_hr_jenis_input_lain);

-- 3.15 hr_pemberhentian — [TRANSAKSI] — offboarding + final settlement Indonesia
--      (pesangon Pasal 40(2) × multiplier Pasal 41-57; nomor doc_name 'pemberhentian'
--      prefix PHT-{yyyy}; jsonb rincian = dokumen display — agregat tetap kolom)
CREATE TABLE IF NOT EXISTS hr_pemberhentian (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL
  id_hr_karyawan         bigint NOT NULL,           -- RESTRICT — FK di bawah
  id_hr_kontrak_kerja    bigint,                    -- RESTRICT nullable — FK di bawah
  id_core_users          bigint,                    -- disetujui_oleh (SET NULL — aktor)
  alasan                 enum_alasan_pemberhentian_hr NOT NULL,  -- 18 nilai PP 35/2021
  status                 enum_status_pemberhentian_hr NOT NULL DEFAULT 'USULAN',
  tanggal_efektif        date NOT NULL,
  masa_kerja_bulan       integer NOT NULL CHECK (masa_kerja_bulan >= 0),
  pesangon               numeric(18,4) NOT NULL DEFAULT 0,
  uup                    numeric(18,4) NOT NULL DEFAULT 0,   -- upah penghargaan masa kerja Pasal 40(3)
  penggantian_hak        numeric(18,4) NOT NULL DEFAULT 0,   -- Pasal 40(4) termasuk cuti belum diambil
  kompensasi             numeric(18,4) NOT NULL DEFAULT 0,   -- kompensasi PKWT Pasal 15-16
  uang_pisah             numeric(18,4) NOT NULL DEFAULT 0,   -- per PK/PP/PKB (default 0 — A-10)
  multiplier             numeric(18,6),             -- faktor pesangon per alasan (Pasal 41-57)
  cuti_belum_diambil     numeric(5,1),              -- hari (kartu §2 — bucket 5,1)
  rincian_hitungan       jsonb,                     -- dokumen display pesangon (§1.4 kartu)
  keterangan             varchar(300),
  version                integer NOT NULL DEFAULT 1,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_hr_pemberhentian_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_hr_pemberhentian_nomor UNIQUE (nomor)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_pemberhentian_karyawan') THEN
    ALTER TABLE hr_pemberhentian ADD CONSTRAINT fk_hr_pemberhentian_karyawan
      FOREIGN KEY (id_hr_karyawan) REFERENCES hr_karyawan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_pemberhentian_kontrak') THEN
    ALTER TABLE hr_pemberhentian ADD CONSTRAINT fk_hr_pemberhentian_kontrak
      FOREIGN KEY (id_hr_kontrak_kerja) REFERENCES hr_kontrak_kerja (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_hr_pemberhentian_disetujui') THEN
    ALTER TABLE hr_pemberhentian ADD CONSTRAINT fk_hr_pemberhentian_disetujui
      FOREIGN KEY (id_core_users) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_hr_pemberhentian_karyawan ON hr_pemberhentian (id_hr_karyawan);
CREATE INDEX IF NOT EXISTS ix_hr_pemberhentian_kontrak
  ON hr_pemberhentian (id_hr_kontrak_kerja) WHERE id_hr_kontrak_kerja IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_hr_pemberhentian_status ON hr_pemberhentian (status);

-- =============================================================================
-- §4 — TRIGGER updated_at (23 tabel hr_* — satu blok DO; set_updated_at() milik
--      baseline CORE 01-core, TIDAK dibuat ulang di sini)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'hr_departemen','hr_jabatan','hr_karyawan','hr_karyawan_dokumen',
    'hr_jadwal_kerja','hr_hari_libur','hr_jenis_cuti','hr_rencana_akumulasi',
    'hr_alokasi_cuti','hr_absensi','hr_pengajuan_lembur','hr_pengajuan_cuti',
    'hr_entri_waktu','hr_struktur_gaji','hr_aturan_gaji','hr_jenis_input_lain',
    'hr_potongan_berulang','hr_kontrak_kerja','hr_batch_payroll',
    'hr_slip_gaji','hr_slip_gaji_baris','hr_slip_gaji_input','hr_pemberhentian'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §5 — SEED PENOMORAN (idempoten — lolos restore-DB-segar)
-- =============================================================================

-- 5.1 Guard fail-loud registry modul (prasyarat baseline CORE; pola ddl/30-acc.sql §8.1)
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'hr') THEN
    RAISE EXCEPTION 'PATCH 34-hr: registry core_modules key=''hr'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- 5.2 core_sequences ensure (module hr) — 7 doc_name existing (payrun/overtime/loan/
--     settlement/leave/missing_punch/shift_swap) tidak pernah diturunkan — DO NOTHING
--     menang; 3 doc_name baru: slip SLIP-{yyyyMM} (HR-A-02), kontrak KTR-{yyyy},
--     pemberhentian PHT-{yyyy}. Padding konsisten 4 (keputusan patch; settlement
--     PR-SET bila belum ada ikut 4).
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('payrun',        'PR-{yyyyMM}',  0, 4),   -- existing (live) — DO NOTHING di situ
  ('overtime',      'OT-{yyyy}',    0, 4),   -- existing — DO NOTHING di situ
  ('loan',          'LN-{yyyy}',    0, 4),   -- existing — DO NOTHING di situ
  ('settlement',    'PR-SET',       0, 4),   -- existing — DO NOTHING di situ
  ('leave',         'LV-{yyyy}',    0, 4),   -- existing — DO NOTHING di situ
  ('missing_punch', 'MP-{yyyy}',    0, 4),   -- existing — DO NOTHING di situ
  ('shift_swap',    'SW-{yyyy}',    0, 4),   -- existing — DO NOTHING di situ
  ('slip',          'SLIP-{yyyyMM}',0, 4),   -- BARU (HR-A-02 nomor slip)
  ('kontrak',       'KTR-{yyyy}',   0, 4),   -- BARU (nomor kontrak kerja)
  ('pemberhentian', 'PHT-{yyyy}',   0, 4)    -- BARU (nomor pemberhentian)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'hr'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- =============================================================================
-- §6 — VERIFIKASI (komentar introspeksi — jalankan manual setelah apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 6.1 Daftar tabel hr_* (harap 23):
-- SELECT table_name
-- FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name LIKE 'hr\_%' ESCAPE '\'
-- ORDER BY table_name;
-- SELECT count(*) AS jumlah_tabel_hr FROM (
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' AND table_name LIKE 'hr\_%' ESCAPE '\'
-- ) t;
--
-- -- 6.2 Jumlah enum hr (harap 33):
-- SELECT count(*) AS jumlah_enum_hr
-- FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE t.typtype = 'e' AND t.typname LIKE 'enum\_%\_hr' ESCAPE '\'
--   AND n.nspname = 'public';
--
-- -- 6.3 Baris sequences module hr (harap 10):
-- SELECT m.key, s.doc_name, s.prefix, s.current_value, s.padding
-- FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
-- WHERE m.key = 'hr' ORDER BY s.doc_name;
--
-- -- 6.4 Trigger set_updated_at pada tabel hr (harap 23):
-- SELECT count(*) AS jumlah_trigger_hr
-- FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
-- WHERE NOT t.tgisinternal AND c.relname LIKE 'hr\_%' ESCAPE '\'
--   AND t.tgname LIKE '%_updated_at';
--
-- -- 6.5 Constraint & index hr (ringkasan):
-- SELECT c.relname, count(con.oid) AS constraints
-- FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
-- LEFT JOIN pg_constraint con ON con.conrelid = c.oid
-- WHERE c.relkind = 'r' AND c.relname LIKE 'hr\_%' ESCAPE '\'
--   AND n.nspname = 'public'
-- GROUP BY c.relname ORDER BY c.relname;
--
-- PATCH 34-hr.sql selesai.
