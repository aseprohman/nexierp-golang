-- +goose Up
-- Porting 1:1 dari ddl/84-wa-enum-botreply.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 84-wa-enum-botreply.sql — WA: rename jenis template SAMBUTAN →
-- BOTREPLY (keputusan pemilik 2026-11-23)
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — kosakata `enum_jenis_template_wa`. Nilai
--            `SAMBUTAN` tidak pernah dipakai logika BE/FE (hanya anggota
--            enum + default form) — diganti nama jadi `BOTREPLY` (template
--            balasan bot). RENAME VALUE otomatis memindahkan data baris yang
--            memakai nilai lama (data live ter-audit: 1 baris).
-- Idempoten: DO-block guard pg_enum — lari kedua = no-op (label lama sudah
--            tidak ada, label baru sudah ada).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/84-wa-enum-botreply.sql
--            (jalankan 2× — lari kedua = no-op)
-- Catatan  : ddl/66-wa.sql (CREATE TYPE + guard kosakata) disinkronkan di
--            patch ini agar restore-fresh tidak RAISE.
-- =============================================================================

BEGIN;

-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'enum_jenis_template_wa' AND e.enumlabel = 'SAMBUTAN'
  ) THEN
    ALTER TYPE enum_jenis_template_wa RENAME VALUE 'SAMBUTAN' TO 'BOTREPLY';
  END IF;
  -- Guard kosakata akhir (mirror ddl/66 yang disinkronkan).
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_template_wa')
     IS DISTINCT FROM ARRAY['BOTREPLY','BALASAN_AGEN','FALLBACK_BOT','TAUTAN_BAYAR',
                            'NOTIFIKASI','BROADCAST','STATUS_WA']::text[] THEN
    RAISE EXCEPTION 'PATCH 84-wa: enum_jenis_template_wa kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;