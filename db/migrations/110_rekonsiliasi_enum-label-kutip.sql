-- +goose Up
-- =====================================================================================
-- MIGRASI REKONSILIASI: 110_rekonsiliasi_enum-label-kutip.sql
-- APA    : membangun ulang 6 enum yang label-nya mengandung karakter kutip literal
--          ('"PPh 21"', '"Obat Bebas & OTC"', dst.) menjadi kosakata persis live:
--          acc_spt_kind, fin_withholding_type, kasir_authorizer_role,
--          lab_instrument_kind, lab_test_category, rme_drug_category.
-- KENAPA : porting ddl membuat label dengan kutip literal (artefak penulisan ddl),
--          sedangkan kosakata live (pg_enum 127.0.0.1:15433) bersih tanpa kutip;
--          live = acuan kerja backend Go.
-- SUMBER : pg_enum DB live dev (fakta); dibangun ulang hanya bila label berkutip ada.
-- IDEMPOTEN: ter-guard cek pg_enum berlabel kutip; kolom pemakai di-swap via text
--          sementara (saat ini 0 kolom memakai 6 tipe ini — aman).
-- CATATAN: DROP TYPE membutuhkan hak pemilik tipe; nilai tambah 'storages' pada
--          core_module_key sengaja dipertahankan (dibutuhkan guard ddl 53-inv-mutasi).
-- =====================================================================================

-- +goose StatementBegin
DO $$
DECLARE
  v_type text;
  v_labels text;
BEGIN
  FOREACH v_type IN ARRAY ARRAY[
    'acc_spt_kind',
    'fin_withholding_type',
    'kasir_authorizer_role',
    'lab_instrument_kind',
    'lab_test_category',
    'rme_drug_category'
  ] LOOP
    IF EXISTS (SELECT 1 FROM pg_enum e
               JOIN pg_type t ON t.oid = e.enumtypid
               WHERE t.typname = v_type AND e.enumlabel LIKE '"%') THEN
      RAISE NOTICE 'membangun ulang % (label berkutip)', v_type;
    END IF;
  END LOOP;
END $$;
-- +goose StatementEnd


-- acc_spt_kind: live = PPN | PPh 23 | PPh 21
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'acc_spt_kind' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'acc_spt_kind' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE acc_spt_kind;
  CREATE TYPE public.acc_spt_kind AS ENUM ('PPN','PPh 23','PPh 21');
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE table_schema = 'public' LOOP
    NULL; -- tidak ada kolom pemakai saat ini
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati acc_spt_kind: %', SQLERRM;
END $$;
-- +goose StatementEnd


-- fin_withholding_type: live = PPh 22 | PPh 23 | PPh 4(2)
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'fin_withholding_type' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'fin_withholding_type' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE fin_withholding_type;
  CREATE TYPE public.fin_withholding_type AS ENUM ('PPh 22','PPh 23','PPh 4(2)');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati fin_withholding_type: %', SQLERRM;
END $$;
-- +goose StatementEnd


-- kasir_authorizer_role: live = Supervisor Kasir | Manager Operasional | Direktur
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'kasir_authorizer_role' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'kasir_authorizer_role' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE kasir_authorizer_role;
  CREATE TYPE public.kasir_authorizer_role AS ENUM ('Supervisor Kasir','Manager Operasional','Direktur');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati kasir_authorizer_role: %', SQLERRM;
END $$;
-- +goose StatementEnd


-- lab_instrument_kind: live = hematologi | kimia klinik | urinalisis | serologi | centrifuge | rontgen | usg
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'lab_instrument_kind' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'lab_instrument_kind' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE lab_instrument_kind;
  CREATE TYPE public.lab_instrument_kind AS ENUM ('hematologi','kimia klinik','urinalisis','serologi','centrifuge','rontgen','usg');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati lab_instrument_kind: %', SQLERRM;
END $$;
-- +goose StatementEnd


-- lab_test_category: live = Hematologi | Kimia Darah | Urinalisis | Serologi | Radiologi | USG
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'lab_test_category' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'lab_test_category' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE lab_test_category;
  CREATE TYPE public.lab_test_category AS ENUM ('Hematologi','Kimia Darah','Urinalisis','Serologi','Radiologi','USG');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati lab_test_category: %', SQLERRM;
END $$;
-- +goose StatementEnd


-- rme_drug_category: live = Obat Keras | Obat Bebas & OTC
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                 WHERE t.typname = 'rme_drug_category' AND e.enumlabel LIKE '"%') THEN
    RETURN;
  END IF;
  FOR r IN SELECT table_name, column_name FROM information_schema.columns
           WHERE udt_name = 'rme_drug_category' AND table_schema = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I SET DATA TYPE text USING %I::text', r.table_name, r.column_name, r.column_name);
  END LOOP;
  DROP TYPE rme_drug_category;
  CREATE TYPE public.rme_drug_category AS ENUM ('Obat Keras','Obat Bebas & OTC');
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'lewati rme_drug_category: %', SQLERRM;
END $$;
-- +goose StatementEnd
