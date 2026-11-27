-- +goose Up
-- Porting 1:1 dari ddl/41-pgw-tanpa-refund.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 41-pgw-tanpa-refund.sql — PEMBASMIAN FITUR REFUND dari modul PGW
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : keputusan pemilik 2026-11-07 — modul PGW TANPA fitur refund;
--            refund manual tetap di ECOM/ACC via M15. Semua artefak F10
--            (tabel pgw_refund, enum refund, jejak kolom, RBAC/menu/sequence)
--            dibasmikan — BUKAN soft delete.
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core + 39-pgw.sql + 40-pgw-refund-ck.sql
--            (tabel pgw_* & RBAC PGW live). ddl/39 & ddl/40 TIDAK diubah —
--            tetap sebagai riwayat baseline (replay penuh 39→40→41 tetap
--            konvergen ke keadaan tanpa refund).
-- Isi      : §1 core_outbox_events jejak refund; §2 pgw_rekonsiliasi_baris
--            (FK/kolom id_pgw_refund); §3 DROP TABLE pgw_refund CASCADE;
--            §4 pgw_transaksi (hapus baris REFUND_PENUH, ck + kolom
--            jumlah_terrefund); §5 enum (bangun-ulang
--            enum_status_transaksi_pgw TANPA 'REFUND_PENUH' +
--            DROP TYPE enum_status_refund_pgw); §6 core_sequences doc_name
--            'refund'; §7 RBAC (SET pgw.refund.*, junction, menu /pgw/refund,
--            ROLE pgw_manajer, USER pgw.manajer + jejak sesi/auditnya).
-- Makna    : PGW tidak lagi membawa alur ajukan–setujui–eksekusi refund.
--            Log pgw_log_webhook / pgw_log_api append-only SELAMAT — baris
--            log transaksi REFUND_PENUH yang dihapus menjadi id NULL (sah:
--            log tetap terbaca sebagai kejadian vendor yang tidak memetakan
--            transaksi apa pun). Baris rekonsiliasi COCOK yang rujukan
--            transaksinya REFUND_PENUH kehilangan id (SET NULL) tetapi
--            referensi_vendor teks tetap — jejak audit teks selamat.
-- PENTING  : berkas TIDAK dibungkus BEGIN/COMMIT (tiap statement autocommit;
--            ON_ERROR_STOP=1 berhenti di statement gagal pertama — bagian yang
--            sudah jalan tidak dibatalkan, tiap bagian idempoten, ulangi apply
--            sampai lulus penuh). PENGECUALIAN §5: PostgreSQL TIDAK
--            mengimplementasikan ALTER TYPE ... DROP VALUE ("dropping an enum
--            value is not implemented", berlaku s.d. PG 18) — nilai enum
--            dibasmikan lewat pola REBUILD standar: rename tipe lama → CREATE
--            TYPE kosakata baru tanpa 'REFUND_PENUH' → pindahkan semua kolom
--            pemakai → DROP TYPE lama. Semua statement rebuild transactional-
--            safe, dijalankan dalam SATU DO-block agar swap atomik.
-- Idempoten: aman dijalankan berulang — IF EXISTS (tabel/kolom/constraint/
--            tipe/nilai enum), DO-guard pg_attribute/pg_enum/pg_class, DELETE
--            tanpa syarat idempoten (0 baris di apply ke-2).
-- Catatan  : USER pgw.manajer adalah akun DEV DEMO (pola seed "Sls@Demo123") —
--            pembasmian baris sesi/login_audit/audit_trail miliknya sah
--            (keputusan pemilik 2026-11-07); FK RESTRICT dibersihkan dulu
--            agar DELETE user tidak gagal 23503.
-- =============================================================================

-- =============================================================================
-- §1 OUTBOX — hapus event refund (topic pgw.% dengan jejak refund)
--    jenis='REFUND' ATAU _key berakhiran ':REFUND*' ATAU membawa refund_jumlah.
--    Dry-run count dilaporkan via RAISE NOTICE sebelum DELETE.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_outbox_events
  WHERE topic LIKE 'pgw.%'
    AND (payload->>'jenis' = 'REFUND'
         OR payload->>'_key' LIKE '%:REFUND%'
         OR payload->>'refund_jumlah' IS NOT NULL);
  DELETE FROM core_outbox_events
  WHERE topic LIKE 'pgw.%'
    AND (payload->>'jenis' = 'REFUND'
         OR payload->>'_key' LIKE '%:REFUND%'
         OR payload->>'refund_jumlah' IS NOT NULL);
  RAISE NOTICE '41-pgw §1: core_outbox_events jejak refund dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 REKONSILIASI BARIS — lepas FK & kolom id_pgw_refund SEBELUM drop tabel
--    (urutan eksplisit agar CASCADE tidak menyentuh apa pun di luar daftar).
-- =============================================================================
ALTER TABLE pgw_rekonsiliasi_baris
  DROP CONSTRAINT IF EXISTS fk_pgw_rekonsiliasi_baris_refund;
ALTER TABLE pgw_rekonsiliasi_baris
  DROP COLUMN IF EXISTS id_pgw_refund;

-- =============================================================================
-- §3 TABEL REFUND — DROP penuh (bukan soft delete); index uq/ix_pgw_refund_*
--    ikut terhapus bersama tabel.
-- =============================================================================
DROP TABLE IF EXISTS pgw_refund CASCADE;

-- =============================================================================
-- §4 TRANSAKSI — hapus baris REFUND_PENUH (data refund ikut basmi; log
--    webhook/api & baris rekonsiliasi terkait otomatis jadi id NULL via
--    ON DELETE SET NULL — sah, append-only selamat), lalu lepas ck + kolom
--    jumlah_terrefund.
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pgw_transaksi WHERE status::text = 'REFUND_PENUH';
  IF v_n > 0 THEN
    DELETE FROM pgw_transaksi WHERE status::text = 'REFUND_PENUH';
    RAISE NOTICE '41-pgw §4: pgw_transaksi REFUND_PENUH dihapus = % (log terkait → id NULL)', v_n;
  ELSE
    RAISE NOTICE '41-pgw §4: pgw_transaksi tanpa baris REFUND_PENUH — skip delete';
  END IF;
END $$;
-- +goose StatementEnd

ALTER TABLE pgw_transaksi DROP CONSTRAINT IF EXISTS ck_pgw_transaksi_refund;
ALTER TABLE pgw_transaksi DROP COLUMN IF EXISTS jumlah_terrefund;

-- =============================================================================
-- §5 ENUM — guard data dulu, bangun-ulang enum transaksi TANPA 'REFUND_PENUH'
--    (ALTER TYPE ... DROP VALUE tidak diimplementasikan PostgreSQL), lalu
--    DROP TYPE enum_status_refund_pgw dengan guard dependency.
-- =============================================================================
-- 5a) guard: enum_status_transaksi_pgw tidak boleh masih dipakai data
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pgw_transaksi WHERE status::text = 'REFUND_PENUH';
  IF v_n > 0 THEN
    RAISE EXCEPTION
      '41-pgw §5: masih ada % pgw_transaksi REFUND_PENUH — bersihkan dulu (jalankan §4; instruksinya: hapus/baseline ulang baris REFUND_PENUH sebelum bangun-ulang enum)', v_n;
  END IF;
END $$;
-- +goose StatementEnd

-- 5b) rebuild enum_status_transaksi_pgw tanpa REFUND_PENUH — atomik dalam satu
--     DO-block. Pola: buat tipe BARU (OID segar) → drop index/constraint yang
--     bergantung enum lama (konstanta di predikat/definisinya terikat OID lama
--     — tanpa ini ALTER COLUMN TYPE gagal "operator does not exist
--     enum_baru = enum_lama") → pindahkan kolom pemakai → drop tipe lama →
--     rename tipe baru ke nama kanonik → pasang kembali index/constraint dari
--     definisi tersimpan (cast '::enum_status_transaksi_pgw' menunjuk nama
--     kanonik yang kini dimiliki tipe baru — kosakata sama). Idempoten: skip +
--     fail-loud bila kosakata menyimpang.
-- +goose StatementBegin
DO $$
DECLARE
  v_old_oid  oid;
  v_pakai    record;
  v_dep      record;
  v_def_bersih text;
  v_idxdefs  text[];
  v_condefs  text[];
  v_i        int;
BEGIN
  IF to_regtype('enum_status_transaksi_pgw') IS NULL THEN
    RAISE EXCEPTION '41-pgw §5: enum_status_transaksi_pgw tidak ditemukan — baseline 39-pgw.sql belum dipasang?';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
             WHERE t.typname = 'enum_status_transaksi_pgw'
               AND e.enumlabel = 'REFUND_PENUH') THEN
    v_old_oid := to_regtype('enum_status_transaksi_pgw');
    -- sisa apply gagal sebelumnya (seharusnya tidak ada — DO atomik): basmi dulu
    DROP TYPE IF EXISTS enum_status_transaksi_pgw_baru41;
    -- tipe BARU (OID segar) — kosakata = lama MINUS REFUND_PENUH (urutan
    -- relatif dipertahankan — mirror schema/pgw.ts pgwStatusTransaksi)
    CREATE TYPE enum_status_transaksi_pgw_baru41 AS ENUM
      ('DIBUAT','MENUNGGU_BAYAR','CHALLENGE','DIBAYAR','GAGAL','KADALUARSA','DIBATALKAN');

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
      RAISE NOTICE '41-pgw §5: index ditangkap-untuk-dibangun-ulang: %', v_def_bersih;
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
      RAISE NOTICE '41-pgw §5: index %.% di-drop sementara (rebuild pasca-swap)', v_dep.nspname, v_dep.relname;
    END LOOP;

    -- 2) tangkap definisi constraint yang menyentuh enum lama lalu drop
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
      WHERE a.atttypid = v_old_oid
      UNION
      SELECT d.objid
      FROM pg_depend d
      JOIN pg_constraint k2 ON k2.oid = d.objid
      WHERE d.classid = 'pg_constraint'::regclass
        AND d.refclassid = 'pg_type'::regclass
        AND d.refobjid = v_old_oid
    ) u
    JOIN pg_constraint k ON k.oid = u.oid
    JOIN pg_class c ON c.oid = k.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace;
    FOREACH v_def_bersih IN ARRAY v_condefs LOOP
      RAISE NOTICE '41-pgw §5: constraint ditangkap-untuk-dibangun-ulang: %', v_def_bersih;
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
        WHERE a.atttypid = v_old_oid
        UNION
        SELECT d.objid
        FROM pg_depend d
        JOIN pg_constraint k3 ON k3.oid = d.objid
        WHERE d.classid = 'pg_constraint'::regclass
          AND d.refclassid = 'pg_type'::regclass
          AND d.refobjid = v_old_oid
      )
    LOOP
      EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', v_dep.nspname, v_dep.relname, v_dep.conname);
      RAISE NOTICE '41-pgw §5: constraint % di-drop sementara (rebuild pasca-swap)', v_dep.conname;
    END LOOP;

    -- 3) pindahkan SEMUA kolom pemakai tipe lama (live: pgw_transaksi.status
    --    saja); default di-drop dulu (tidak ter-cast otomatis antar tipe),
    --    dipasang kembali dengan literal sama terhadap tipe baru.
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
        'ALTER TABLE %I.%I ALTER COLUMN %I TYPE enum_status_transaksi_pgw_baru41 USING %I::text::enum_status_transaksi_pgw_baru41',
        v_pakai.nspname, v_pakai.relname, v_pakai.attname, v_pakai.attname);
      IF v_pakai.def_expr IS NOT NULL THEN
        -- lepas cast '::(public.)enum_status_transaksi_pgw' dari literal default
        v_def_bersih := replace(v_pakai.def_expr,
                                '::public.enum_status_transaksi_pgw', '');
        v_def_bersih := replace(v_def_bersih,
                                '::enum_status_transaksi_pgw', '');
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT %s',
                       v_pakai.nspname, v_pakai.relname, v_pakai.attname, v_def_bersih);
      END IF;
      RAISE NOTICE '41-pgw §5: kolom %.% dipindah ke enum baru (default: %)',
        v_pakai.relname, v_pakai.attname, coalesce(v_pakai.def_expr, '-');
    END LOOP;

    -- 4) drop tipe lama (sudah tak dipakai), rename tipe baru → nama kanonik
    DROP TYPE enum_status_transaksi_pgw;
    ALTER TYPE enum_status_transaksi_pgw_baru41 RENAME TO enum_status_transaksi_pgw;

    -- 5) pasang kembali index & constraint dari definisi tersimpan
    FOREACH v_def_bersih IN ARRAY v_idxdefs LOOP
      EXECUTE v_def_bersih;
    END LOOP;
    FOREACH v_def_bersih IN ARRAY v_condefs LOOP
      EXECUTE v_def_bersih;
    END LOOP;

    RAISE NOTICE '41-pgw §5: enum_status_transaksi_pgw dibangun ulang tanpa REFUND_PENUH (index rebuild=%, constraint rebuild=%)',
      coalesce(array_length(v_idxdefs, 1), 0), coalesce(array_length(v_condefs, 1), 0);
  ELSE
    RAISE NOTICE '41-pgw §5: enum_status_transaksi_pgw sudah tanpa REFUND_PENUH — skip';
    -- fail-loud bila kosakata menyimpang dari mirror
    IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        WHERE t.typname = 'enum_status_transaksi_pgw')
       IS DISTINCT FROM
       ARRAY['DIBUAT','MENUNGGU_BAYAR','CHALLENGE','DIBAYAR','GAGAL','KADALUARSA','DIBATALKAN']::text[] THEN
      RAISE EXCEPTION '41-pgw §5: enum_status_transaksi_pgw kosakata menyimpang dari mirror (harus 7 nilai tanpa REFUND_PENUH)';
    END IF;
  END IF;
END $$;
-- +goose StatementEnd

-- 5c) guard dependency: enum_status_refund_pgw tidak boleh masih dipakai kolom
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM pg_attribute a
  WHERE a.atttypid = to_regtype('enum_status_refund_pgw')
    AND a.attisdropped = false;
  IF v_n > 0 THEN
    RAISE EXCEPTION
      '41-pgw §5: enum_status_refund_pgw masih dipakai % kolom — drop tabel/kolom pemakai dulu', v_n;
  END IF;
END $$;
-- +goose StatementEnd

-- 5d) bare statement (idempoten)
DROP TYPE IF EXISTS enum_status_refund_pgw;

-- =============================================================================
-- §6 SEQUENCES — core_sequences doc_name='refund' modul payment-gateway
--    (penomoran PGWRF-{yyyyMM} ikut basmi).
-- =============================================================================
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_sequences cs
  JOIN core_modules m ON m.id = cs.id_core_modules
  WHERE m.key = 'payment-gateway' AND cs.doc_name = 'refund';
  DELETE FROM core_sequences cs
  USING core_modules m
  WHERE m.id = cs.id_core_modules AND m.key = 'payment-gateway'
    AND cs.doc_name = 'refund';
  RAISE NOTICE '41-pgw §6: core_sequences refund dihapus = %', v_n;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §7 RBAC — SET pgw.refund.*, junction-nya, menu /pgw/refund, ROLE pgw_manajer,
--    USER pgw.manajer (+ jejak sesi/audit akun demo). Pola 'pgw.refund%'
--    mencakup SET bisnis pgw.refund.ajukan/pgw.refund.setujui SEKALIGUS SET
--    otomatis scanroutes 'pgw.refund' — artefak fitur yang sama; tanpa rute
--    pemakai, SET sisa akan menolak verifikasi G2 seed (SET tanpa rute).
-- =============================================================================
-- 7a) junction SET ↔ rute + SET ↔ role
DELETE FROM core_permissions_routes pr
USING core_permissions p
WHERE pr.id_core_permissions = p.id AND p.name LIKE 'pgw.refund%';
DELETE FROM core_role_permissions rp
USING core_permissions p
WHERE rp.id_core_permissions = p.id AND p.name LIKE 'pgw.refund%';
-- 7b) SET-nya sendiri (tidak ada tabel lain merujuk core_permissions selain
--     dua junction di atas — lihat \d core_permissions)
-- +goose StatementBegin
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM core_permissions WHERE name LIKE 'pgw.refund%';
  DELETE FROM core_permissions WHERE name LIKE 'pgw.refund%';
  RAISE NOTICE '41-pgw §7b: SET pgw.refund* dihapus = %', v_n;
END $$;
-- +goose StatementEnd

-- 7c) menu refund: junction role→menu dulu, lalu menunya
DELETE FROM core_roles_menus rm
USING core_menus c
WHERE rm.id_core_menus = c.id AND c.url_path = '/pgw/refund';
DELETE FROM core_menus c
WHERE c.url_path = '/pgw/refund'
  AND c.id_core_modules = (SELECT id FROM core_modules WHERE key = 'payment-gateway');
-- 7d) ROLE pgw_manajer — junction penuh dulu (semua FK RESTRICT), lalu role
-- +goose StatementBegin
DO $$
DECLARE v_rp bigint; v_rm bigint; v_ur bigint; v_sa bigint;
BEGIN
  SELECT count(*) INTO v_rp FROM core_role_permissions
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  SELECT count(*) INTO v_rm FROM core_roles_menus
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  SELECT count(*) INTO v_ur FROM core_users_roles
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  SELECT count(*) INTO v_sa FROM core_scope_assignments
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');

  DELETE FROM core_role_permissions
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  DELETE FROM core_roles_menus
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  DELETE FROM core_users_roles
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  -- CASCADE di DDL live — dihapus eksplisit agar jejak terhitung
  DELETE FROM core_scope_assignments
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  -- holder RESTRICT lain (kosong pada live — no-op; guard ke depan)
  DELETE FROM core_approval_limits
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');
  DELETE FROM core_ip_allowlist
  WHERE id_core_roles IN (SELECT id FROM core_roles WHERE code = 'pgw_manajer');

  DELETE FROM core_roles WHERE code = 'pgw_manajer';
  RAISE NOTICE '41-pgw §7d: role pgw_manajer dihapus (junction rp=% rm=% ur=% scope=%)',
    v_rp, v_rm, v_ur, v_sa;
END $$;
-- +goose StatementEnd

-- 7e) USER pgw.manajer — akun DEV DEMO (pembasmian sah, keputusan pemilik);
--     jejak RESTRICT (sesi/login_audit/audit_trail) dibersihkan dulu agar
--     DELETE core_users tidak gagal 23503. core_files/core_module_configs
--     pakai ON DELETE SET NULL — tidak perlu pra-bersih.
-- +goose StatementBegin
DO $$
DECLARE v_uid bigint; v_ur bigint; v_ses bigint; v_la bigint; v_at bigint;
BEGIN
  SELECT id INTO v_uid FROM core_users WHERE username = 'pgw.manajer';
  IF v_uid IS NOT NULL THEN
    SELECT count(*) INTO v_ur FROM core_users_roles WHERE id_core_users = v_uid
      OR id_core_users_assigned_by = v_uid;
    SELECT count(*) INTO v_ses FROM core_sessions WHERE id_core_users = v_uid;
    SELECT count(*) INTO v_la FROM core_login_audit WHERE id_core_users = v_uid;
    SELECT count(*) INTO v_at FROM core_audit_trail WHERE id_core_users = v_uid;

    DELETE FROM core_users_roles WHERE id_core_users = v_uid
      OR id_core_users_assigned_by = v_uid;
    DELETE FROM core_sessions WHERE id_core_users = v_uid;
    DELETE FROM core_login_audit WHERE id_core_users = v_uid;
    DELETE FROM core_audit_trail WHERE id_core_users = v_uid;
    -- holder RESTRICT lain (kosong pada live — no-op; guard ke depan)
    DELETE FROM core_user_permissions WHERE id_core_users = v_uid
      OR id_core_users_granted_by = v_uid;
    DELETE FROM core_user_duties WHERE id_core_users = v_uid;
    DELETE FROM core_user_mfa WHERE id_core_users = v_uid;
    DELETE FROM core_password_history WHERE id_core_users = v_uid;
    DELETE FROM core_users_tenants WHERE id_core_users = v_uid;
    DELETE FROM core_scope_assignments WHERE id_core_users = v_uid;
    DELETE FROM core_approval_limits WHERE id_core_users = v_uid;
    DELETE FROM core_ip_allowlist WHERE id_core_users = v_uid;
    DELETE FROM core_modules_features WHERE id_core_users_activated = v_uid
      OR id_core_users_deactivated = v_uid;

    DELETE FROM core_users WHERE id = v_uid;
    RAISE NOTICE '41-pgw §7e: user pgw.manajer dihapus (ur=% sesi=% login_audit=% audit_trail=%)',
      v_ur, v_ses, v_la, v_at;
  ELSE
    RAISE NOTICE '41-pgw §7e: user pgw.manajer tidak ada — skip';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- VERIFIKASI (0 baris = lolos)
-- =============================================================================
SELECT 'cek 1 tabel refund sisa' AS cek, count(*) FROM pg_class
WHERE relname = 'pgw_refund' AND relkind = 'r';
SELECT 'cek 2 enum refund sisa' AS cek, count(*) FROM pg_type
WHERE typname = 'enum_status_refund_pgw';
SELECT 'cek 3 nilai REFUND_PENUH sisa' AS cek, count(*)
FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
WHERE t.typname = 'enum_status_transaksi_pgw' AND e.enumlabel = 'REFUND_PENUH';
SELECT 'cek 4 kolom refund sisa' AS cek, count(*)
FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
WHERE a.attisdropped = false
  AND ((c.relname = 'pgw_transaksi' AND a.attname = 'jumlah_terrefund')
    OR (c.relname = 'pgw_rekonsiliasi_baris' AND a.attname = 'id_pgw_refund'));
SELECT 'cek 5 transaksi REFUND_PENUH sisa' AS cek, count(*)
FROM pgw_transaksi WHERE status::text = 'REFUND_PENUH';
SELECT 'cek 6 outbox jejak refund sisa' AS cek, count(*)
FROM core_outbox_events
WHERE topic LIKE 'pgw.%'
  AND (payload->>'jenis' = 'REFUND'
       OR payload->>'_key' LIKE '%:REFUND%'
       OR payload->>'refund_jumlah' IS NOT NULL);
SELECT 'cek 7 SET pgw.refund* sisa' AS cek, count(*)
FROM core_permissions WHERE name LIKE 'pgw.refund%';
SELECT 'cek 8 junction SET refund sisa' AS cek, count(*)
FROM core_permissions_routes pr
JOIN core_permissions p ON p.id = pr.id_core_permissions
WHERE p.name LIKE 'pgw.refund%';
SELECT 'cek 9 role pgw_manajer sisa' AS cek, count(*)
FROM core_roles WHERE code = 'pgw_manajer';
SELECT 'cek 10 user pgw.manajer sisa' AS cek, count(*)
FROM core_users WHERE username = 'pgw.manajer';
SELECT 'cek 11 menu /pgw/refund sisa' AS cek, count(*)
FROM core_menus WHERE url_path = '/pgw/refund';
SELECT 'cek 12 sequence refund sisa' AS cek, count(*)
FROM core_sequences cs JOIN core_modules m ON m.id = cs.id_core_modules
WHERE m.key = 'payment-gateway' AND cs.doc_name = 'refund';

-- ddl/41-pgw-tanpa-refund.sql selesai.
