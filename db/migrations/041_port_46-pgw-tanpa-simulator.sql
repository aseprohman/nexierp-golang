-- +goose Up
-- Porting 1:1 dari ddl/46-pgw-tanpa-simulator.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 46-pgw-tanpa-simulator.sql — PEMBASMIAN VENDOR SIMULATOR dari
-- modul PGW (PAYMENT GATEWAY)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : keputusan pemilik 2026-11-10 — modul PGW HANYA vendor real
--            (MIDTRANS/DOKU); adapter simulator F04 dibasmikan dari DB/seed/
--            mirror (S1 membasmi sisi apps/api + packages/schemas, C3 sisi
--            apps/web; berkas ini membasmi sisi DB).
-- Tanggal  : 2026-11-10
-- Prasyarat: baseline CORE 01-core + 39-pgw.sql + 41-pgw-tanpa-refund.sql
--            (tabel pgw_* live, enum_environment_pgw 3 nilai). ddl/39 & ddl/41
--            TIDAK diubah — tetap riwayat baseline (replay 39→41→46 konvergen
--            ke keadaan tanpa simulator).
-- Isi      : §1 core_outbox_events jejak transaksi simulator; §2 log webhook/
--            api + pengiriman tautan milik simulator; §3 rekonsiliasi (baris
--            yatim simulator dihapus, header kode_vendor SIMULATOR→MIDTRANS
--            dev + resync Σ baris); §4 pgw_transaksi (vendor SIMULATOR /
--            jenis_sumber SIMULATOR / environment SIMULASI); §5 pgw_channel
--            konfig simulator; §6 pgw_konfigurasi_vendor SIMULATOR (DELETE
--            FISIK termasuk baris soft-deleted); §7 enum (bangun-ulang
--            enum_environment_pgw TANPA 'SIMULASI' — pola ddl/41 §5b);
--            §8 CFG-PGW-06; §9 RBAC (SET pgw.simulasi%, junction, rute
--            /pgw/simulasi%, menu); §10 core_meta pgw_seed_version bump.
-- Makna    : PGW tidak lagi membawa vendor simulator; environment transaksi
--            kembali 2 nilai (SANDBOX|PRODUKSI — kredensial ck konfigurasi
--            sudah 2 nilai sejak ddl/39). Log/pengiriman yang merujuk
--            transaksi terhapus ikut DIHAPUS demi bersih di dev (catatan
--            jumlah via RAISE NOTICE) — beda dengan ddl/41 yang membiarkan
--            log SET NULL (di sini pemiliknya bukan hanya status, tapi
--            vendor yang seluruh artefaknya dibasmikan).
-- PENTING  : berkas TIDAK dibungkus BEGIN/COMMIT (tiap statement autocommit;
--            ON_ERROR_STOP=1 berhenti di statement gagal pertama — bagian yang
--            sudah jalan tidak dibatalkan, tiap bagian idempoten, ulangi apply
--            sampai lulus penuh). PENGECUALIAN §7: PostgreSQL TIDAK
--            mengimplementasikan ALTER TYPE ... DROP VALUE ("dropping an enum
--            value is not implemented", berlaku s.d. PG 18) — nilai enum
--            dibasmikan lewat pola REBUILD standar ddl/41 §5b: rename tipe
--            lama → CREATE TYPE kosakata baru → pindahkan semua kolom pemakai
--            → DROP TYPE lama → rename tipe baru ke nama kanonik → pasang
--            kembali index/constraint dari definisi tersimpan.
-- Idempoten: aman dijalankan berulang — IF EXISTS / DO-guard pg_enum/
--            pg_attribute, DELETE berkriteria eksplisit (0 baris di apply
--            ke-2), swap enum skip + fail-loud bila kosakata menyimpang.
-- Catatan  : pgw_rekonsiliasi.kode_vendor adalah varchar bebas (bukan FK) —
--            2 header live 'SIMULATOR' di-UPDATE ke 'MIDTRANS' (dev, keputusan
--            pemilik) supaya portret seed rekonsiliasi & KPI dashboard tetap
--            bermakna setelah vendor simulator dibasmikan.
-- =============================================================================

-- =============================================================================
-- §1 OUTBOX — hapus event pgw.% yang payment_ref/_key merujuk transaksi yang
--    akan dihapus §4 (konfig vendor SIMULATOR / jenis_sumber 'SIMULATOR' /
--    environment 'SIMULASI'). Dry-run count dilaporkan via RAISE NOTICE.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_outbox_events e
  WHERE e.topic LIKE 'pgw.%'
    AND e.payload->>'payment_ref' IN (
      SELECT t.nomor FROM pgw_transaksi t
      JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
      WHERE k.kode_vendor = 'SIMULATOR'
         OR t.jenis_sumber = 'SIMULATOR'
         OR t.environment::text = 'SIMULASI');
  DELETE FROM core_outbox_events e
  USING pgw_transaksi t
  JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
  WHERE e.topic LIKE 'pgw.%'
    AND e.payload->>'payment_ref' = t.nomor
    AND (k.kode_vendor = 'SIMULATOR'
         OR t.jenis_sumber = 'SIMULATOR'
         OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §1: core_outbox_events jejak transaksi simulator dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 LOG & PENGIRIMAN — baris milik simulator dihapus (dev bersih, jumlah
--    dicatat): kode_vendor='SIMULATOR' ATAU environment='SIMULASI' ATAU
--    merujuk transaksi kriteria §4. pgw_pengiriman_tautan tidak punya kolom
--    vendor/environment — dihapus via rujukan transaksinya.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_wh bigint; v_api bigint; v_ki bigint;
BEGIN
  SELECT count(*) INTO v_wh FROM pgw_log_webhook w
  WHERE w.kode_vendor = 'SIMULATOR' OR w.environment::text = 'SIMULASI'
     OR w.id_pgw_transaksi IN (
       SELECT t.id FROM pgw_transaksi t
       JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
       WHERE k.kode_vendor = 'SIMULATOR'
          OR t.jenis_sumber = 'SIMULATOR'
          OR t.environment::text = 'SIMULASI');
  DELETE FROM pgw_log_webhook w
  WHERE w.kode_vendor = 'SIMULATOR' OR w.environment::text = 'SIMULASI'
     OR w.id_pgw_transaksi IN (
       SELECT t.id FROM pgw_transaksi t
       JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
       WHERE k.kode_vendor = 'SIMULATOR'
          OR t.jenis_sumber = 'SIMULATOR'
          OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §2a: pgw_log_webhook simulator/simulasi dihapus = %', v_wh;

  SELECT count(*) INTO v_api FROM pgw_log_api l
  WHERE l.kode_vendor = 'SIMULATOR' OR l.environment::text = 'SIMULASI'
     OR l.id_pgw_transaksi IN (
       SELECT t.id FROM pgw_transaksi t
       JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
       WHERE k.kode_vendor = 'SIMULATOR'
          OR t.jenis_sumber = 'SIMULATOR'
          OR t.environment::text = 'SIMULASI');
  DELETE FROM pgw_log_api l
  WHERE l.kode_vendor = 'SIMULATOR' OR l.environment::text = 'SIMULASI'
     OR l.id_pgw_transaksi IN (
       SELECT t.id FROM pgw_transaksi t
       JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
       WHERE k.kode_vendor = 'SIMULATOR'
          OR t.jenis_sumber = 'SIMULATOR'
          OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §2b: pgw_log_api simulator/simulasi dihapus = %', v_api;

  SELECT count(*) INTO v_ki FROM pgw_pengiriman_tautan p
  WHERE p.id_pgw_transaksi IN (
    SELECT t.id FROM pgw_transaksi t
    JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
    WHERE k.kode_vendor = 'SIMULATOR'
       OR t.jenis_sumber = 'SIMULATOR'
       OR t.environment::text = 'SIMULASI');
  DELETE FROM pgw_pengiriman_tautan p
  USING pgw_transaksi t
  JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
  WHERE p.id_pgw_transaksi = t.id
    AND (k.kode_vendor = 'SIMULATOR'
         OR t.jenis_sumber = 'SIMULATOR'
         OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §2c: pgw_pengiriman_tautan rujukan transaksi simulator dihapus = %', v_ki;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §3 REKONSILIASI — baris yang merujuk transaksi simulator dihapus SEBELUM
--    transaksinya (menghindari SET NULL yatim), header 'SIMULATOR' di-UPDATE
--    ke 'MIDTRANS' (varchar bebas — keputusan pemilik 2026-11-10, dev), lalu
--    jumlah_cocok/jumlah_selisih diresync dari Σ baris (invarian V4).
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_b bigint; v_h bigint;
BEGIN
  SELECT count(*) INTO v_b FROM pgw_rekonsiliasi_baris b
  WHERE b.id_pgw_transaksi IN (
    SELECT t.id FROM pgw_transaksi t
    JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
    WHERE k.kode_vendor = 'SIMULATOR'
       OR t.jenis_sumber = 'SIMULATOR'
       OR t.environment::text = 'SIMULASI');
  DELETE FROM pgw_rekonsiliasi_baris b
  USING pgw_transaksi t
  JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
  WHERE b.id_pgw_transaksi = t.id
    AND (k.kode_vendor = 'SIMULATOR'
         OR t.jenis_sumber = 'SIMULATOR'
         OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §3a: pgw_rekonsiliasi_baris rujukan transaksi simulator dihapus = %', v_b;

  UPDATE pgw_rekonsiliasi h
  SET kode_vendor = 'MIDTRANS', updated_at = now()
  WHERE h.kode_vendor = 'SIMULATOR';
  GET DIAGNOSTICS v_h = ROW_COUNT;
  RAISE NOTICE '46-pgw §3b: pgw_rekonsiliasi kode_vendor SIMULATOR→MIDTRANS = %', v_h;

  UPDATE pgw_rekonsiliasi h
  SET jumlah_cocok   = x.cocok,
      jumlah_selisih = x.selisih,
      updated_at     = now()
  FROM (
    SELECT h2.id,
           count(b.id) FILTER (WHERE b.jenis = 'COCOK')  AS cocok,
           count(b.id) FILTER (WHERE b.jenis <> 'COCOK') AS selisih
    FROM pgw_rekonsiliasi h2
    LEFT JOIN pgw_rekonsiliasi_baris b ON b.id_pgw_rekonsiliasi = h2.id
    WHERE h2.deleted_at IS NULL
    GROUP BY h2.id
  ) x
  WHERE h.id = x.id
    AND (h.jumlah_cocok <> x.cocok OR h.jumlah_selisih <> x.selisih);
  RAISE NOTICE '46-pgw §3c: header rekonsiliasi diresync dari Σ baris (invarian V4)';
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §4 TRANSAKSI — hapus baris kriteria simulator (RESTRICT anak sudah bersih:
--    §1–§3). Log/pengiriman/baris yang tersisa menunjuk id lain — sah.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n
  FROM pgw_transaksi t
  JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
  WHERE k.kode_vendor = 'SIMULATOR'
     OR t.jenis_sumber = 'SIMULATOR'
     OR t.environment::text = 'SIMULASI';
  DELETE FROM pgw_transaksi t
  USING pgw_konfigurasi_vendor k
  WHERE k.id = t.id_pgw_konfigurasi_vendor
    AND (k.kode_vendor = 'SIMULATOR'
         OR t.jenis_sumber = 'SIMULATOR'
         OR t.environment::text = 'SIMULASI');
  RAISE NOTICE '46-pgw §4: pgw_transaksi simulator/simulasi dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §5 CHANNEL — hapus channel konfigurasi simulator (RESTRICT dari transaksi
--    sudah lepas via §4).
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pgw_channel c
  JOIN pgw_konfigurasi_vendor k ON k.id = c.id_pgw_konfigurasi_vendor
  WHERE k.kode_vendor = 'SIMULATOR';
  DELETE FROM pgw_channel c
  USING pgw_konfigurasi_vendor k
  WHERE k.id = c.id_pgw_konfigurasi_vendor AND k.kode_vendor = 'SIMULATOR';
  RAISE NOTICE '46-pgw §5: pgw_channel konfigurasi simulator dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §6 KONFIGURASI VENDOR — DELETE FISIK semua baris SIMULATOR (hidup + baris
--    soft-deleted ikut dibasmikan — soft delete bukan tempat artefak vendor
--    yang dihapus keputusan pemilik).
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pgw_konfigurasi_vendor WHERE kode_vendor = 'SIMULATOR';
  DELETE FROM pgw_konfigurasi_vendor WHERE kode_vendor = 'SIMULATOR';
  RAISE NOTICE '46-pgw §6: pgw_konfigurasi_vendor SIMULATOR dihapus (fisik, incl. soft-deleted) = %', v_n;
END $$;
-- +goose StatementEnd


-- 6b) Jejak nama '(simulator)' pada channel VENDOR REAL (warisan seed lama
--     pra-refactor katalog F05 — mis. 'QRIS (simulator)' di konfigurasi
--     MIDTRANS): nama dibereskan, baris channel vendor real tetap dipertahani
--     (idempoten — 0 baris di apply ke-2).
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pgw_channel WHERE nama LIKE '% (simulator)';
  UPDATE pgw_channel
  SET nama = replace(nama, ' (simulator)', ''), updated_at = now()
  WHERE nama LIKE '% (simulator)';
  RAISE NOTICE '46-pgw §6b: nama channel vendor real ber-jejak "(simulator)" dibereskan = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §7 ENUM — guard data dulu, bangun-ulang enum_environment_pgw TANPA
--    'SIMULASI' (ALTER TYPE ... DROP VALUE tidak diimplementasikan
--    PostgreSQL — pola REBUILD ddl/41 §5b, atomik dalam satu DO-block).
-- =============================================================================
-- 7a) guard: tidak boleh ada lagi baris pemakai nilai 'SIMULASI' (§1–§6 harus
--     sudah lulus; bila gagal = apply sebelumnya belum tuntas)
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT (SELECT count(*) FROM pgw_konfigurasi_vendor WHERE environment::text = 'SIMULASI')
       + (SELECT count(*) FROM pgw_transaksi        WHERE environment::text = 'SIMULASI')
       + (SELECT count(*) FROM pgw_log_webhook      WHERE environment::text = 'SIMULASI')
       + (SELECT count(*) FROM pgw_log_api          WHERE environment::text = 'SIMULASI')
  INTO v_n;
  IF v_n > 0 THEN
    RAISE EXCEPTION
      '46-pgw §7: masih ada % baris environment SIMULASI — bersihkan dulu (jalankan §1–§6)', v_n;
  END IF;
END $$;
-- +goose StatementEnd

-- 7b) rebuild enum_environment_pgw tanpa SIMULASI — pola ddl/41 §5b:
--     tipe BARU (OID segar) → drop index/constraint bergantung enum lama
--     (konstanta di predikat/definisinya terikat OID lama — tanpa ini ALTER
--     COLUMN TYPE gagal) → pindahkan kolom pemakai → drop tipe lama → rename
--     tipe baru ke nama kanonik → pasang kembali index/constraint. Constraint
--     NOT NULL (contype 'n') TIDAK disentuh — bertahan otomatis lewat
--     ALTER COLUMN TYPE dan definisinya tidak merujuk enum. Idempoten:
--     skip + fail-loud bila kosakata menyimpang dari mirror
--     (schema/pgw.ts pgwEnvironment = ['SANDBOX','PRODUKSI']).
-- +goose StatementBegin
DO $$
DECLARE
  v_old_oid  oid;
  v_pakai    record;
  v_dep      record;
  v_def_bersih text;
  v_idxdefs  text[];
  v_condefs  text[];
BEGIN
  IF to_regtype('enum_environment_pgw') IS NULL THEN
    RAISE EXCEPTION '46-pgw §7: enum_environment_pgw tidak ditemukan — baseline 39-pgw.sql belum dipasang?';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
             WHERE t.typname = 'enum_environment_pgw'
               AND e.enumlabel = 'SIMULASI') THEN
    v_old_oid := to_regtype('enum_environment_pgw');
    -- sisa apply gagal sebelumnya (seharusnya tidak ada — DO atomik): basmi dulu
    DROP TYPE IF EXISTS enum_environment_pgw_baru46;
    -- tipe BARU (OID segar) — kosakata = lama MINUS SIMULASI (urutan relatif
    -- dipertahankan — mirror schema/pgw.ts pgwEnvironment)
    CREATE TYPE enum_environment_pgw_baru46 AS ENUM ('SANDBOX','PRODUKSI');

    -- 1) tangkap definisi index yang menyentuh enum lama (kolom kunci ATAU
    --    ekspresi/predikat — pg_depend) lalu drop
    SELECT coalesce(array_agg(pg_get_indexdef(d.idxrelid) ORDER BY d.idxrelid), ARRAY[]::text[])
      INTO v_idxdefs
    FROM (
      SELECT i.indexrelid AS idxrelid
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid
       AND a.attnum = ANY (i.indkey::int2[]) AND a.attisdropped = false
      WHERE a.atttypid = v_old_oid
      UNION
      SELECT d.objid
      FROM pg_depend d
      JOIN pg_class c ON c.oid = d.objid AND c.relkind = 'i'
      WHERE d.classid = 'pg_class'::regclass
        AND d.refclassid = 'pg_type'::regclass
        AND d.refobjid = v_old_oid
    ) d;
    FOREACH v_def_bersih IN ARRAY v_idxdefs LOOP
      RAISE NOTICE '46-pgw §7: index ditangkap-untuk-dibangun-ulang: %', v_def_bersih;
    END LOOP;
    FOR v_dep IN
      SELECT n.nspname, c.relname
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE i.indexrelid IN (
        SELECT i2.indexrelid
        FROM pg_index i2
        JOIN pg_attribute a ON a.attrelid = i2.indrelid
         AND a.attnum = ANY (i2.indkey::int2[]) AND a.attisdropped = false
        WHERE a.atttypid = v_old_oid
        UNION
        SELECT d.objid
        FROM pg_depend d
        JOIN pg_class c2 ON c2.oid = d.objid AND c2.relkind = 'i'
        WHERE d.classid = 'pg_class'::regclass
          AND d.refclassid = 'pg_type'::regclass
          AND d.refobjid = v_old_oid
      )
    LOOP
      EXECUTE format('DROP INDEX %I.%I', v_dep.nspname, v_dep.relname);
      RAISE NOTICE '46-pgw §7: index %.% di-drop sementara (rebuild pasca-swap)', v_dep.nspname, v_dep.relname;
    END LOOP;

    -- 2) tangkap definisi constraint yang menyentuh enum lama lalu drop.
    --    contype='n' (NOT NULL bernama, PG≥15) dikecualikan: definisinya tidak
    --    merujuk enum dan bertahan otomatis lewat ALTER COLUMN TYPE.
    SELECT coalesce(array_agg(
             format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                    n.nspname, c.relname, k.conname, pg_get_constraintdef(k.oid))
             ORDER BY k.oid), ARRAY[]::text[])
      INTO v_condefs
    FROM (
      SELECT k.oid
      FROM pg_constraint k
      JOIN pg_attribute a ON a.attrelid = k.conrelid
       AND a.attnum = ANY (k.conkey) AND a.attisdropped = false
      WHERE a.atttypid = v_old_oid AND k.contype <> 'n'
      UNION
      SELECT d.objid
      FROM pg_depend d
      JOIN pg_constraint k2 ON k2.oid = d.objid AND k2.contype <> 'n'
      WHERE d.classid = 'pg_constraint'::regclass
        AND d.refclassid = 'pg_type'::regclass
        AND d.refobjid = v_old_oid
    ) u
    JOIN pg_constraint k ON k.oid = u.oid
    JOIN pg_class c ON c.oid = k.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace;
    FOREACH v_def_bersih IN ARRAY v_condefs LOOP
      RAISE NOTICE '46-pgw §7: constraint ditangkap-untuk-dibangun-ulang: %', v_def_bersih;
    END LOOP;
    FOR v_dep IN
      SELECT n.nspname, c.relname, k.conname
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE k.oid IN (
        SELECT k2.oid
        FROM pg_constraint k2
        JOIN pg_attribute a ON a.attrelid = k2.conrelid
         AND a.attnum = ANY (k2.conkey) AND a.attisdropped = false
        WHERE a.atttypid = v_old_oid AND k2.contype <> 'n'
        UNION
        SELECT d.objid
        FROM pg_depend d
        JOIN pg_constraint k3 ON k3.oid = d.objid AND k3.contype <> 'n'
        WHERE d.classid = 'pg_constraint'::regclass
          AND d.refclassid = 'pg_type'::regclass
          AND d.refobjid = v_old_oid
      )
    LOOP
      EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', v_dep.nspname, v_dep.relname, v_dep.conname);
      RAISE NOTICE '46-pgw §7: constraint % di-drop sementara (rebuild pasca-swap)', v_dep.conname;
    END LOOP;

    -- 3) pindahkan SEMUA kolom pemakai tipe lama (live: environment pada
    --    pgw_konfigurasi_vendor / pgw_transaksi / pgw_log_webhook / pgw_log_api
    --    — tanpa default); default di-drop dulu (tidak ter-cast otomatis antar
    --    tipe), dipasang kembali dengan literal sama terhadap tipe baru.
    FOR v_pakai IN
      SELECT n.nspname, c.relname, a.attname, a.attnum,
             pg_get_expr(d.adbin, d.adrelid) AS def_expr
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE a.atttypid = v_old_oid
        AND a.attisdropped = false AND c.relkind = 'r'
    LOOP
      IF v_pakai.def_expr IS NOT NULL THEN
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP DEFAULT',
                       v_pakai.nspname, v_pakai.relname, v_pakai.attname);
      END IF;
      EXECUTE format(
        'ALTER TABLE %I.%I ALTER COLUMN %I TYPE enum_environment_pgw_baru46 USING %I::text::enum_environment_pgw_baru46',
        v_pakai.nspname, v_pakai.relname, v_pakai.attname, v_pakai.attname);
      IF v_pakai.def_expr IS NOT NULL THEN
        -- lepas cast '::(public.)enum_environment_pgw' dari literal default
        v_def_bersih := replace(v_pakai.def_expr,
                                '::public.enum_environment_pgw', '');
        v_def_bersih := replace(v_def_bersih,
                                '::enum_environment_pgw', '');
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT %s',
                       v_pakai.nspname, v_pakai.relname, v_pakai.attname, v_def_bersih);
      END IF;
      RAISE NOTICE '46-pgw §7: kolom %.% dipindah ke enum baru (default: %)',
        v_pakai.relname, v_pakai.attname, coalesce(v_pakai.def_expr, '-');
    END LOOP;

    -- 4) drop tipe lama (sudah tak dipakai), rename tipe baru → nama kanonik
    DROP TYPE enum_environment_pgw;
    ALTER TYPE enum_environment_pgw_baru46 RENAME TO enum_environment_pgw;

    -- 5) pasang kembali index & constraint dari definisi tersimpan
    --    (cast '::enum_environment_pgw' menunjuk nama kanonik yang kini
    --    dimiliki tipe baru — nilai 'SANDBOX'/'PRODUKSI' ada di kosakata baru,
    --    jadi ck konfigurasi IN (SANDBOX,PRODUKSI) swap-safe)
    FOREACH v_def_bersih IN ARRAY v_idxdefs LOOP
      EXECUTE v_def_bersih;
    END LOOP;
    FOREACH v_def_bersih IN ARRAY v_condefs LOOP
      EXECUTE v_def_bersih;
    END LOOP;

    RAISE NOTICE '46-pgw §7: enum_environment_pgw dibangun ulang tanpa SIMULASI (index rebuild=%, constraint rebuild=%)',
      coalesce(array_length(v_idxdefs, 1), 0), coalesce(array_length(v_condefs, 1), 0);
  ELSE
    RAISE NOTICE '46-pgw §7: enum_environment_pgw sudah tanpa SIMULASI — skip';
    -- fail-loud bila kosakata menyimpang dari mirror
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'enum_environment_pgw')
       IS DISTINCT FROM
       ARRAY['SANDBOX','PRODUKSI']::text[] THEN
      RAISE EXCEPTION '46-pgw §7: enum_environment_pgw kosakata menyimpang dari mirror (harus 2 nilai tanpa SIMULASI)';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §8 CFG — core_module_configs param_key='CFG-PGW-06' (guard simulator di
--    instansi produksi F04/BR08/BR12) — fitur simulator dibasmikan, registry
--    sisi kode dihapus sesi S1.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_module_configs c
  JOIN core_modules m ON m.id = c.id_core_modules
  WHERE m.key = 'payment-gateway' AND c.param_key = 'CFG-PGW-06';
  DELETE FROM core_module_configs c
  USING core_modules m
  WHERE m.id = c.id_core_modules AND m.key = 'payment-gateway'
    AND c.param_key = 'CFG-PGW-06';
  RAISE NOTICE '46-pgw §8: core_module_configs CFG-PGW-06 dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §9 RBAC — SET pgw.simulasi%, junction-nya (rute + role), rute
--    /pgw/simulasi% (controller simulator sudah dihapus sesi S1 — baris rute
--    basmi di sini agar tidak menunggu rescan; rescan berikut tidak akan
--    menciptakan ulang), menu /pgw/simulasi + junction role→menu.
-- =============================================================================
-- 9a) junction SET ↔ rute, SET ↔ role (RESTRICT pra-hapus SET; grant user
--     RBAC v2 merujuk rute langsung — dibasmi 9c via id_core_routes)
DELETE FROM core_permissions_routes pr
USING core_permissions p
WHERE pr.id_core_permissions = p.id AND p.name LIKE 'pgw.simulasi%';
DELETE FROM core_role_permissions rp
USING core_permissions p
WHERE rp.id_core_permissions = p.id AND p.name LIKE 'pgw.simulasi%';
-- 9b) SET-nya sendiri (pgw.simulasi.tulis + SET otomatis scanroutes
--     'pgw.simulasi' bila ada)
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_permissions WHERE name LIKE 'pgw.simulasi%';
  DELETE FROM core_permissions WHERE name LIKE 'pgw.simulasi%';
  RAISE NOTICE '46-pgw §9b: SET pgw.simulasi* dihapus = %', v_n;
END $$;
-- +goose StatementEnd

-- 9c) rute /pgw/simulasi% — junction SET↔rute sudah lepas (9a); junction
--     core_user_permissions ke rute dihapus dulu (RESTRICT), baru baris rute.
DELETE FROM core_user_permissions up
USING core_routes r
WHERE up.id_core_routes = r.id AND r.uri_pattern LIKE '/pgw/simulasi%';
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_routes WHERE uri_pattern LIKE '/pgw/simulasi%';
  DELETE FROM core_routes WHERE uri_pattern LIKE '/pgw/simulasi%';
  RAISE NOTICE '46-pgw §9c: rute /pgw/simulasi* dihapus = %', v_n;
END $$;
-- +goose StatementEnd

-- 9d) menu simulator: junction role→menu dulu (FK RESTRICT), lalu menunya
DELETE FROM core_roles_menus rm
USING core_menus c
WHERE rm.id_core_menus = c.id AND c.url_path = '/pgw/simulasi';
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_menus c
  WHERE c.url_path = '/pgw/simulasi'
    AND c.id_core_modules = (SELECT id FROM core_modules WHERE key = 'payment-gateway');
  DELETE FROM core_menus c
  WHERE c.url_path = '/pgw/simulasi'
    AND c.id_core_modules = (SELECT id FROM core_modules WHERE key = 'payment-gateway');
  RAISE NOTICE '46-pgw §9d: menu /pgw/simulasi dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §10 META — core_meta pgw_seed_version bump aditif (GREATEST, 6 = pembasmian
--     vendor simulator; monotonic terhadap seed lama).
-- =============================================================================
INSERT INTO core_meta (id, value)
VALUES ('pgw_seed_version', '6'::jsonb)
ON CONFLICT (id) DO UPDATE
SET value = to_jsonb(GREATEST((core_meta.value #>> '{}')::numeric, 6)),
    updated_at = now();

-- =============================================================================
-- VERIFIKASI (0 baris = lolos)
-- =============================================================================
SELECT 'cek 1 konfigurasi SIMULATOR sisa' AS cek, count(*)
FROM pgw_konfigurasi_vendor WHERE kode_vendor = 'SIMULATOR';
SELECT 'cek 2 channel konfigurasi SIMULATOR sisa' AS cek, count(*)
FROM pgw_channel c JOIN pgw_konfigurasi_vendor k ON k.id = c.id_pgw_konfigurasi_vendor
WHERE k.kode_vendor = 'SIMULATOR';
SELECT 'cek 3 transaksi vendor/jenis SIMULATOR atau env SIMULASI sisa' AS cek, count(*)
FROM pgw_transaksi t JOIN pgw_konfigurasi_vendor k ON k.id = t.id_pgw_konfigurasi_vendor
WHERE k.kode_vendor = 'SIMULATOR' OR t.jenis_sumber = 'SIMULATOR'
   OR t.environment::text = 'SIMULASI';
SELECT 'cek 4 transaksi environment SIMULASI sisa (global)' AS cek, count(*)
FROM pgw_transaksi WHERE environment::text = 'SIMULASI';
SELECT 'cek 5 log webhook SIMULATOR/SIMULASI sisa' AS cek, count(*)
FROM pgw_log_webhook WHERE kode_vendor = 'SIMULATOR' OR environment::text = 'SIMULASI';
SELECT 'cek 6 log api SIMULATOR/SIMULASI sisa' AS cek, count(*)
FROM pgw_log_api WHERE kode_vendor = 'SIMULATOR' OR environment::text = 'SIMULASI';
SELECT 'cek 7 pengiriman yatim (rujukan transaksi hilang) sisa' AS cek, count(*)
FROM pgw_pengiriman_tautan p
LEFT JOIN pgw_transaksi t ON t.id = p.id_pgw_transaksi
WHERE p.id_pgw_transaksi IS NOT NULL AND t.id IS NULL;
SELECT 'cek 8 rekonsiliasi kode_vendor SIMULATOR sisa' AS cek, count(*)
FROM pgw_rekonsiliasi WHERE kode_vendor = 'SIMULATOR';
SELECT 'cek 9 baris rekonsiliasi yatim sisa' AS cek, count(*)
FROM pgw_rekonsiliasi_baris b
LEFT JOIN pgw_transaksi t ON t.id = b.id_pgw_transaksi
WHERE b.id_pgw_transaksi IS NOT NULL AND t.id IS NULL;
SELECT 'cek 10 outbox pgw.% payment_ref yatim sisa' AS cek, count(*)
FROM core_outbox_events e
WHERE e.topic LIKE 'pgw.%' AND e.payload ? 'payment_ref'
  AND NOT EXISTS (SELECT 1 FROM pgw_transaksi t
                  WHERE t.nomor = e.payload->>'payment_ref');
SELECT 'cek 11 SET pgw.simulasi* sisa' AS cek, count(*)
FROM core_permissions WHERE name LIKE 'pgw.simulasi%';
SELECT 'cek 12 junction SET pgw.simulasi* sisa' AS cek, count(*)
FROM core_permissions_routes pr
JOIN core_permissions p ON p.id = pr.id_core_permissions
WHERE p.name LIKE 'pgw.simulasi%';
SELECT 'cek 13 rute /pgw/simulasi* sisa' AS cek, count(*)
FROM core_routes WHERE uri_pattern LIKE '/pgw/simulasi%';
SELECT 'cek 14 menu /pgw/simulasi sisa' AS cek, count(*)
FROM core_menus WHERE url_path = '/pgw/simulasi';
SELECT 'cek 15 junction menu /pgw/simulasi sisa' AS cek, count(*)
FROM core_roles_menus rm
JOIN core_menus c ON c.id = rm.id_core_menus
WHERE c.url_path = '/pgw/simulasi';
SELECT 'cek 16 CFG-PGW-06 sisa' AS cek, count(*)
FROM core_module_configs c JOIN core_modules m ON m.id = c.id_core_modules
WHERE m.key = 'payment-gateway' AND c.param_key = 'CFG-PGW-06';
SELECT 'cek 17 nilai enum SIMULASI sisa' AS cek, count(*)
FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'enum_environment_pgw' AND e.enumlabel = 'SIMULASI';
SELECT 'cek 18 kosakata enum_environment_pgw = 2 nilai (SANDBOX,PRODUKSI)' AS cek, count(*)
FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'enum_environment_pgw';

-- ddl/46-pgw-tanpa-simulator.sql selesai.
