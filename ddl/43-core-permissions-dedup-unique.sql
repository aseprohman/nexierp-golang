-- =============================================================================
-- PATCH DDL 43-core-permissions-dedup-unique.sql — Dedup + UNIQUE katalog permission
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : pemicu audit seed-rbac-correction P2-3 (katalog permission rentan
--            duplikat saat seeding paralel) + temuan dedup 2026-11-08:
--            130 baris core_permissions, 24 grup nama duplikat (54 baris):
--              - acc.* 10 grup  : 1 kanonik + 1 yatim (id_core_modules NULL)
--              - sls.* 8 grup   : 1 kanonik + 1 yatim
--              - pgw.* 6 grup   : 1 kanonik + 1 kembar se-modul + 1 yatim
--            Semua junction route SET-identik antar anggota grup
--            (distinct_route_sets = 1 per grup) dan grant loser ⊆ grant keeper
--            (keeper = baris id_core_modules NOT NULL ber-id terkecil).
-- Tanggal  : 2026-11-08
-- Prasyarat: baseline CORE 01-core (tabel core_permissions, junction
--            core_permissions_routes, core_role_permissions — FK RESTRICT).
-- Isi      : §1 DEDUP set-based idempoten (pindah-tutup junction/grant loser,
--            lalu DELETE loser; guard grup tersisa → EXCEPTION).
--            §2 UNIQUE INDEX uq_core_permissions_name (name).
-- Makna    : satu nama SET permission = tepat satu baris katalog. FK penerima
--            hanya core_permissions_routes & core_role_permissions (RESTRICT) —
--            keduanya ditutup dulu sebelum baris keeper tunggal didelete.
-- Idempoten: run-1 menghapus 30 baris yatim/kembar (live 2026-11-08: 130 → 100)
--            dan membuat unique index; run-2 no-op (DELETE 0, CREATE IF NOT
--            EXISTS skip). Guard akhir menolak transaksi bila grup duplikat
--            masih ada, sehingga §2 tidak pernah gagal 23505 karena data.
-- Sebab    : (historis, hanya dicatat) seed lama INSERT WHERE NOT EXISTS tanpa
--            cek modul (seed pgw lama) → kembar se-modul pgw.*; eksekusi
--            scanroutes paralel → yatim acc./sls. dengan id_core_modules NULL.
--            scanroutes kini module-aware; §2 menegakkan unikness level DB:
--            race paralel berikutnya gagal 23505 (fail-loud), bukan diam-diam
--            duplikat. Upsert scanroutes by name tetap kompatibel karena
--            guard NOT EXISTS-nya by name.
-- Catatan  : 1 baris name IS NULL tidak disentuh (unique index NULLS DISTINCT
--            mengizinkan banyak NULL); seed pgw lama TIDAK diubah di sini.
-- =============================================================================

BEGIN;

-- ==== §1 DEDUP set-based generik (tanpa hardcode nama) =======================
-- Keeper per grup : id terkecil di antara baris id_core_modules NOT NULL
--                   (fallback: id terkecil bila semua NULL — defensif).
-- Loser           : anggota grup lainnya (yatim NULL / kembar se-modul).
-- Urutan          : pindahkan junction/grant yang hanya dimiliki loser ke
--                   keeper dulu (live: 0 baris, set identik), hapus junction/
--                   grant loser, baru hapus baris loser — FK RESTRICT lolos.
WITH dupnames AS (
  SELECT name
  FROM core_permissions
  WHERE name IS NOT NULL
  GROUP BY name
  HAVING count(*) > 1
),
keepers AS (
  SELECT DISTINCT ON (cp.name) cp.name, cp.id
  FROM core_permissions cp
  WHERE cp.name IN (SELECT name FROM dupnames)
  ORDER BY cp.name, (cp.id_core_modules IS NULL) ASC, cp.id ASC
),
losers AS (
  SELECT cp.id, cp.name
  FROM core_permissions cp
  WHERE cp.name IN (SELECT name FROM dupnames)
    AND cp.id NOT IN (SELECT id FROM keepers)
),
ins_routes AS (   -- junction yang hanya dimiliki loser → salin ke keeper
  INSERT INTO core_permissions_routes (id_core_routes, id_core_permissions)
  SELECT DISTINCT r.id_core_routes, k.id
  FROM core_permissions_routes r
  JOIN losers l ON l.id = r.id_core_permissions
  JOIN keepers k ON k.name = l.name
  WHERE NOT EXISTS (
    SELECT 1 FROM core_permissions_routes kr
    WHERE kr.id_core_permissions = k.id
      AND kr.id_core_routes = r.id_core_routes
  )
  RETURNING 1
),
del_routes AS (   -- tutup junction loser (RESTRICT tidak blok baris keeper)
  DELETE FROM core_permissions_routes r
  USING losers l
  WHERE r.id_core_permissions = l.id
  RETURNING 1
),
ins_grants AS (   -- grant role yang hanya dimiliki loser → salin ke keeper
  INSERT INTO core_role_permissions (id_core_roles, id_core_permissions)
  SELECT DISTINCT p.id_core_roles, k.id
  FROM core_role_permissions p
  JOIN losers l ON l.id = p.id_core_permissions
  JOIN keepers k ON k.name = l.name
  WHERE NOT EXISTS (
    SELECT 1 FROM core_role_permissions kp
    WHERE kp.id_core_permissions = k.id
      AND kp.id_core_roles = p.id_core_roles
  )
  RETURNING 1
),
del_grants AS (   -- tutup grant loser
  DELETE FROM core_role_permissions p
  USING losers l
  WHERE p.id_core_permissions = l.id
  RETURNING 1
),
del_perms AS (    -- hapus baris yatim/kembar
  DELETE FROM core_permissions cp
  USING losers l
  WHERE cp.id = l.id
  RETURNING 1
)
SELECT
  (SELECT count(*) FROM ins_routes) AS junction_dipindah,
  (SELECT count(*) FROM del_routes) AS junction_dihapus,
  (SELECT count(*) FROM ins_grants) AS grant_dipindah,
  (SELECT count(*) FROM del_grants) AS grant_dihapus,
  (SELECT count(*) FROM del_perms)  AS permission_dihapus;

-- Guard: bila setelah dedup masih ada grup >1 → batalkan seluruh patch.
DO $$
DECLARE
  v_groups int;
BEGIN
  SELECT count(*) INTO v_groups
  FROM (
    SELECT name FROM core_permissions
    WHERE name IS NOT NULL
    GROUP BY name HAVING count(*) > 1
  ) t;
  IF v_groups > 0 THEN
    RAISE EXCEPTION 'DEDUP GAGAL: masih ada % grup nama duplikat di core_permissions — cek loser yang junction-nya berbeda dari keeper', v_groups;
  END IF;
END $$;

-- ==== §2 UNIQUE INDEX ========================================================
-- P2-3: seeding paralel yang race kini gagal 23505 (fail-loud), bukan diam-diam
-- melahirkan duplikat; upsert scanroutes by name tetap kompatibel (guard NOT
-- EXISTS by name). NULLS DISTINCT: name IS NULL tidak ikut ditegakkan.
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_permissions_name
  ON core_permissions (name);

COMMIT;

-- =============================================================================
-- VERIFIKASI (semua harus 0 / sesuai ekspektasi)
-- =============================================================================
-- (a) 0 grup duplikat
SELECT name, count(*) AS n FROM core_permissions
WHERE name IS NOT NULL GROUP BY name HAVING count(*) > 1;
-- (b) 0 yatim id_core_modules NULL (live: 30 yatim lama sudah terhapus;
--     keeper semuanya bermodul)
SELECT count(*) AS sisa_yatim FROM core_permissions WHERE id_core_modules IS NULL;
-- (c) unique index terpasang
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'core_permissions' AND indexname = 'uq_core_permissions_name';
-- (d) total SET (live: 130 → 100)
SELECT count(*) AS total_set FROM core_permissions;

-- ddl/43-core-permissions-dedup-unique.sql selesai.
