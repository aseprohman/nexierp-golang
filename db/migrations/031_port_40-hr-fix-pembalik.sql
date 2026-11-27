-- +goose Up
-- Porting 1:1 dari ddl/40-hr-fix-pembalik.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 40-hr-fix-pembalik.sql — Unique index PEMBALIK aktif per asal
-- Domain   : NexiERP (modul HR — payroll slip gaji)
-- Sumber   : temuan audit Batch B — guard "satu PEMBALIK aktif per slip asal"
--            (HR-BR29) hanya ada di layer service (pre-check
--            slip-gaji.service.pembalik); dua request paralel bisa lolos
--            pre-check bersamaan → dua slip PEMBALIK untuk satu slip asal
--            → jurnal kebalikan dobel (M47 hr.slip.pembalik 2×).
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core + 34-hr.sql (tabel hr_slip_gaji live).
-- Isi      : CREATE UNIQUE INDEX partial uq_hr_slip_gaji_pembalik_aktif.
-- Makna    : satu baris PEMBALIK HIDUP per `id_hr_slip_gaji_asal` —
--            pelanggaran (race) ditolak DB (23505) meski pre-check service
--            lolos bersamaan.
-- Keputusan: predikat = `deleted_at IS NULL AND jenis='PEMBALIK'
--            AND status <> 'DIBATALKAN'` — guard status ditambahkan atas
--            draft audit (yang hanya deleted_at+jenis) agar persis sama
--            dengan invarian service (pembalik(): aktif = hidup & belum
--            DIBATALKAN). Tanpa guard status, alur sah "batal pembalik →
--            buat pembalik ulang" akan ditolak index (23505) karena baris
--            DIBATALKAN masih hidup (deleted_at NULL) — regresi alur F18.
-- Idempoten: DO-block cek to_regclass — index sudah ada → skip (aman
--            dijalankan berulang; CREATE INDEX IF NOT EXISTS di dalam
--            DO tetap diberi guard eksplisit untuk keterbacaan audit).
-- =============================================================================

BEGIN;

-- +goose StatementBegin
DO $$
DECLARE
  v_ada text;
BEGIN
  -- Skip bila tabel belum ada (baseline belum di-apply) ATAU index sudah ada.
  SELECT to_regclass('public.hr_slip_gaji')::text INTO v_ada;
  IF v_ada IS NULL THEN
    RAISE NOTICE 'hr_slip_gaji belum ada — patch dilewati.';
    RETURN;
  END IF;

  IF to_regclass('public.uq_hr_slip_gaji_pembalik_aktif') IS NOT NULL THEN
    RAISE NOTICE 'uq_hr_slip_gaji_pembalik_aktif sudah ada — idempoten, dilewati.';
    RETURN;
  END IF;

  -- Data pra-cek: bila sudah ada >1 PEMBALIK aktif per asal (race lama),
  -- index unik tidak bisa dibuat — gagal cepat dengan pesan jelas.
  IF EXISTS (
    SELECT 1 FROM hr_slip_gaji
    WHERE deleted_at IS NULL AND jenis = 'PEMBALIK' AND status <> 'DIBATALKAN'
    GROUP BY id_hr_slip_gaji_asal
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Data ganda: ada >1 slip PEMBALIK aktif untuk satu slip asal — rapikan dahulu sebelum membuat index unik.';
  END IF;

  CREATE UNIQUE INDEX IF NOT EXISTS uq_hr_slip_gaji_pembalik_aktif
    ON hr_slip_gaji (id_hr_slip_gaji_asal)
    WHERE deleted_at IS NULL AND jenis = 'PEMBALIK' AND status <> 'DIBATALKAN';

  RAISE NOTICE 'uq_hr_slip_gaji_pembalik_aktif dibuat.';
END
$$;
-- +goose StatementEnd


COMMIT;