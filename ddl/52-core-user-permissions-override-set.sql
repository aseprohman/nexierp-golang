-- =============================================================================
-- PATCH DDL 52-core-user-permissions-override-set.sql — Override per-user pindah
--            granularitas PER-ROUTE → PER-SET permission
-- Domain   : CORE — tabel `core_user_permissions` dirombak: target override
--            bukan lagi pasangan (id_core_modules, id_core_routes) melainkan
--            SATU SET permission (id_core_permissions → core_permissions).
--            Kompilasi tetap memancar ke route via junction
--            core_permissions_routes (1 SET ≥ 1 route).
-- Sumber   : keputusan pemilik 2026-11-11 (fondasi refactor RBAC; tabel live
--            KOSONG — 0 baris — aman diubah tanpa migrasi data).
-- Tanggal  : 2026-11-11
-- Prasyarat: baseline CORE 01-core (core_permissions, core_permissions_routes,
--            core_routes live; FK RESTRICT); ddl/45 sudah menjatuhkan
--            core_user_duties. VERIFIKASI live \d 2026-11-11: tabel kosong,
--            nama constraint persis seperti di §1.
-- Isi      : §1 drop FK + unique + index granularitas lama (guard DO $$);
--            §2 drop kolom id_core_modules & id_core_routes;
--            §3 ADD kolom id_core_permissions (NOT NULL + FK RESTRICT ke
--            core_permissions) + ADD deleted_at (lengkapi trio audit —
--            created_at/updated_at sudah ada);
--            §4 unique partial (user, permission) WHERE deleted_at IS NULL
--            + index id_core_permissions_idx.
-- Makna    : KARTU ARSITEKTUR core_user_permissions |
--            [JUNCTION] + atribut override (granted, expires_at) |
--            pemilik CORE (system.iam) | unique partial (user, permission) |
--            aliran invalidasi rbac.changed (mutasi override → invalidateUser
--            → event socket rbac.changed → klien muat ulang /auth/me).
--            Semantik kompilasi TIDAK berubah: grant di-ADD, deny di-REMOVE
--            terakhir (deny menang) — permission-compiler.service.ts.
-- Idempoten: DROP CONSTRAINT/COLUMN/INDEX IF EXISTS + ADD COLUMN IF NOT
--            EXISTS + guard pg_constraint + CREATE INDEX IF NOT EXISTS —
--            aman dijalankan 2× (run-2 no-op).
-- Catatan  : FK id_core_users & id_core_users_granted_by SUDAH RESTRICT di
--            live — tidak disentuh. FK id_core_permissions mengikuti gaya
--            FK tabel ini (ON UPDATE CASCADE ON DELETE RESTRICT). Nama
--            constraint drizzle `core_user_permissions_id_core_permissions_fkey`
--            disamakan agar mirror 1:1.
-- =============================================================================

BEGIN;

-- ==== §1 DROP penanda granularitas PER-ROUTE (nama persis \d live) ===========
-- FK route  : core_user_permissions_route_fk
-- FK modul  : core_user_permissions_id_core_modules_fkey
-- Unique lama (user,route) : core_user_permissions_triple_key
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'core_user_permissions_route_fk'
      AND conrelid = 'core_user_permissions'::regclass
  ) THEN
    ALTER TABLE core_user_permissions DROP CONSTRAINT core_user_permissions_route_fk;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'core_user_permissions_id_core_modules_fkey'
      AND conrelid = 'core_user_permissions'::regclass
  ) THEN
    ALTER TABLE core_user_permissions DROP CONSTRAINT core_user_permissions_id_core_modules_fkey;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'core_user_permissions_triple_key'
      AND conrelid = 'core_user_permissions'::regclass
  ) THEN
    ALTER TABLE core_user_permissions DROP CONSTRAINT core_user_permissions_triple_key;
  END IF;
END $$;

DROP INDEX IF EXISTS core_user_permissions_id_core_modules_idx;
DROP INDEX IF EXISTS core_user_permissions_id_core_routes_idx;

-- ==== §2 DROP kolom granularitas lama ========================================
ALTER TABLE core_user_permissions
  DROP COLUMN IF EXISTS id_core_modules,
  DROP COLUMN IF EXISTS id_core_routes;

-- ==== §3 Kolom baru: target SET permission + trio audit lengkap ==============
-- Tabel kosong → tanpa UPDATE pengisian nilai (tidak ada baris NULL).
ALTER TABLE core_user_permissions
  ADD COLUMN IF NOT EXISTS id_core_permissions bigint;
ALTER TABLE core_user_permissions
  ALTER COLUMN id_core_permissions SET NOT NULL;

-- FK → katalog SET permission; RESTRICT: baris katalog tidak boleh hilang
-- selama masih ada override yang menunjuknya.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'core_user_permissions_id_core_permissions_fkey'
      AND conrelid = 'core_user_permissions'::regclass
  ) THEN
    ALTER TABLE core_user_permissions
      ADD CONSTRAINT core_user_permissions_id_core_permissions_fkey
      FOREIGN KEY (id_core_permissions) REFERENCES core_permissions(id)
      ON UPDATE CASCADE ON DELETE RESTRICT;
  END IF;
END $$;

-- Trio audit lengkap: created_at + updated_at sudah ada sejak baseline.
ALTER TABLE core_user_permissions
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL;

-- ==== §4 UNIQUE partial (user, permission) + index pendukung =================
-- Partial WHERE deleted_at IS NULL: pasangan user×permission unik di antara
-- baris HIDUP — riwayat soft-delete tidak menghalangi re-grant.
CREATE UNIQUE INDEX IF NOT EXISTS core_user_permissions_pair_key
  ON core_user_permissions (id_core_users, id_core_permissions)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS core_user_permissions_id_core_permissions_idx
  ON core_user_permissions (id_core_permissions);

COMMIT;

-- =============================================================================
-- VERIFIKASI (semua harus 0 / sesuai ekspektasi)
-- =============================================================================
-- (a) Kolom final sesuai kontrak — harus persis 10 kolom berurutan:
--     id, id_core_users, id_core_permissions, granted, id_core_users_granted_by,
--     granted_at, expires_at, created_at, updated_at, deleted_at
SELECT column_name, is_nullable, data_type
FROM information_schema.columns
WHERE table_name = 'core_user_permissions'
ORDER BY ordinal_position;
-- (b) 0 kolom granularitas lama tersisa
SELECT count(*) AS sisa_kolom_lama FROM information_schema.columns
WHERE table_name = 'core_user_permissions'
  AND column_name IN ('id_core_modules', 'id_core_routes');
-- (c) FK sesuai — harus tepat 3, semuanya RESTRICT:
--     core_user_permissions_id_core_users_fkey,
--     core_user_permissions_id_core_users_granted_by_fkey,
--     core_user_permissions_id_core_permissions_fkey
SELECT conname, pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conrelid = 'core_user_permissions'::regclass AND contype = 'f'
ORDER BY conname;
-- (d) 0 constraint lama tersisa
SELECT count(*) AS sisa_constraint_lama FROM pg_constraint
WHERE conname IN (
  'core_user_permissions_route_fk',
  'core_user_permissions_id_core_modules_fkey',
  'core_user_permissions_triple_key'
);
-- (e) unique partial + index pendukung terpasang (pair_key harus 1 baris
--     berdefinisi WHERE deleted_at IS NULL)
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'core_user_permissions'
ORDER BY indexname;
SELECT count(*) AS pair_key_ada FROM pg_indexes
WHERE tablename = 'core_user_permissions'
  AND indexname = 'core_user_permissions_pair_key'
  AND indexdef LIKE '%deleted_at IS NULL%';

-- ddl/52-core-user-permissions-override-set.sql selesai.
