-- =====================================================================
-- 75-wf-registry-modul.sql — Registry modul `wf` (Workflow Engine)
--
-- Latar: ddl/74 (8 tabel wf_*) sudah ter-apply; engine workflow approval
-- bersifat lintas modul (pemilik scaffold = modules/wf), kategori proses
-- dibawa per modul bisnis via wf_kategori_proses.id_core_modules. Untuk
-- RBAC route-centric (core_modules_features/core_permissions dari
-- scanroutes.sh) modul wf butuh baris registry core_modules sendiri.
--
-- Kartu: [CONFIG] registry modul — pemilik modul `wf`.
-- Isi  : 1) enum core_module_key + nilai 'wf' (ALTER TYPE di LUAR blok
--        transaksi — PG melarang pemakaian nilai enum baru pada transaksi
--        yang sama saat ditambahkan); 2) baris core_modules key='wf'
--        idempoten ON CONFLICT.
-- Idempoten: ADD VALUE IF NOT EXISTS + ON CONFLICT DO NOTHING.
-- =====================================================================

ALTER TYPE core_module_key ADD VALUE IF NOT EXISTS 'wf';

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'core_module_key' AND e.enumlabel = 'wf'
  ) THEN
    RAISE EXCEPTION 'PATCH 75: nilai enum ''wf'' gagal ditambahkan';
  END IF;
END $$;

BEGIN;

-- Registry modul WF (idempoten — jangan menimpa baris yang sudah ada).
INSERT INTO core_modules (key, name, tagline, tone, is_core, enabled)
VALUES
  ('wf', 'Workflow',
   'Engine approval & persetujuan lintas modul (kategori, template, inbox)',
   'violet', true, true)
ON CONFLICT (key) DO NOTHING;

COMMIT;
