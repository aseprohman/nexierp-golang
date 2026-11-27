-- +goose Up
-- Porting 1:1 dari ddl/91-hapus-inv-landed.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 91-hapus-inv-landed.sql — INV: HAPUS FITUR LANDED COST (INV-F11)
-- =============================================================================
-- Domain   : NEXIERP · Modul INVENTORY — tabel [TRANSAKSI]
--            `inv_biaya_pembelian_landed` + [LINE] `inv_biaya_pembelian_landed_items`
--            + enum `enum_status_landed` & `enum_dasar_alokasi` (ddl/02) + jejak
--            registry (menu, junction role↔menu, route, sequence penomoran 'LC').
--            Keputusan pemilik 2026-11-25: **FITUR DIHAPUS TOTAL** dari modul
--            INV — landed cost kini MILIK modul PURCHASING (PUR-F10, alokasi
--            per item PO `pur_biaya_landed_item`, ddl/90). Kode FE/BE/schemas/
--            seed/menu INV sudah dihapus bersamaan di repo (arsip lengkap:
--            `arsip-hapus-inv-landed-20261125.tgz` di root repo — berisi dump
--            schema `schema-inv-landed.sql` + data CSV `inv_biaya_pembelian_landed.csv`
--            (1 baris) & `inv_biaya_pembelian_landed_items.csv` (0 baris) + semua
--            file terhapus sebelum dihapus).
-- Migrasi  : Data potret seed INV yang membaca/menulis tabel ini sudah dibersihkan
--            (seed-definitions.ts v8, seed-menus.sql, verifikasi.mjs) — TANPA
--            backfill: baris DB eksisting (1 dokumen DITERIMA + 0 item) tidak
--            dimigrasi ke PUR (riwayat alokasi INV tidak direkonstruksi; nilai
--            gerakan seed v8 dihitung ulang murni dari harga biaya penerimaan).
--            Registry (menu/junction/route/sequence 'LC') dihapus §3 agar seed
--            & RBAC tidak lagi menampilkan fitur mati.
-- Bedah    : DROP tabel anak dulu (items) → induk (landed) → enum dengan guard
--            introspeksi pg_attribute (hanya drop bila TIDAK ada kolom lain yang
--            memakai; bila masih ada → RAISE WARNING, enum dibiarkan hidup).
-- Idempoten: DROP TABLE IF EXISTS + guard pg_type/pg_attribute + DELETE … WHERE
--            EXISTS — lari kedua = no-op.
-- Catatan  : (a) sequence 'LC' milik modul `inventory` SAJA yang dihapus —
--              sequence 'purchase_landed' (PUR, prefix LC-{yyyy}) JANGAN disentuh.
--            (b) permission code `inventory.operasi.*` DIKEKANKAN (shared dengan
--              endpoint operasi lain) — hanya BARIS route ber-uri_pattern landed
--              yang dihapus, bukan permission-nya.
--            (c) helper murni `hitungBobotAlokasi`/`bagiAlokasi` TETAP HIDUP di
--              packages/schemas core (dipakai purchasing — ddl/90).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/91-hapus-inv-landed.sql
--            (jalankan 2× — lari kedua = no-op). TIDAK dijalankan otomatis oleh
--            sesi refactor — koordinator mengeksekusi setelah review.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 DROP TABEL — anak (items) dulu → induk (landed)
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS inv_biaya_pembelian_landed_items;
DROP TABLE IF EXISTS inv_biaya_pembelian_landed;

-- -----------------------------------------------------------------------------
-- §2 DROP ENUM — hanya bila tak ada kolom lain yang memakai (guard dinamis)
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$
BEGIN
  -- enum_status_landed
  IF EXISTS (SELECT 1 FROM pg_type t WHERE t.typname = 'enum_status_landed') THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE udt_name = 'enum_status_landed'
    ) THEN
      RAISE WARNING 'enum_status_landed MASIH dipakai kolom lain — tidak di-drop';
    ELSE
      DROP TYPE enum_status_landed;
    END IF;
  END IF;
  -- enum_dasar_alokasi
  IF EXISTS (SELECT 1 FROM pg_type t WHERE t.typname = 'enum_dasar_alokasi') THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE udt_name = 'enum_dasar_alokasi'
    ) THEN
      RAISE WARNING 'enum_dasar_alokasi MASIH dipakai kolom lain — tidak di-drop';
    ELSE
      DROP TYPE enum_dasar_alokasi;
    END IF;
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §3 BERSIH REGISTRY — junction → menu → route → sequence ('LC' INV saja)
-- -----------------------------------------------------------------------------

-- Junction role↔menu yang menunjuk menu landed (FK core_roles_menus → core_menus
-- = RESTRICT, jadi junction WAJIB dihapus sebelum baris menu-nya).
DELETE FROM core_roles_menus
WHERE id_core_menus IN (
  SELECT id FROM core_menus WHERE url_path = '/inventory/operasi/landed'
);

-- Menu "Landed Cost" /inventory/operasi/landed.
DELETE FROM core_menus
WHERE url_path = '/inventory/operasi/landed';

-- Junction permission↔route yang menunjuk route landed (FK
-- core_permissions_routes → core_routes = RESTRICT — WAJIB dihapus dulu;
-- pembelajaran uji db test: clone schema-only lulus, DB berdata GAGAL di sini).
DELETE FROM core_permissions_routes
WHERE id_core_routes IN (
  SELECT id FROM core_routes WHERE uri_pattern LIKE '/inventory/operasi/landed%'
);

-- Route izin fitur landed (permission code `inventory.operasi.*` shared — tidak disentuh).
DELETE FROM core_routes
WHERE uri_pattern LIKE '/inventory/operasi/landed%';

-- Sequence penomoran dokumen 'LC' MILIK MODUL INVENTORY — guard per modul;
-- sequence 'purchase_landed' milik PUR (ddl/90) TIDAK disentuh.
DELETE FROM core_sequences
WHERE doc_name = 'LC'
  AND id_core_modules = (SELECT id FROM core_modules WHERE key = 'inventory');

COMMIT;

-- -----------------------------------------------------------------------------
-- §4 VERIFIKASI (jalankan manual setelah patch — semua harus kosong/NULL)
-- -----------------------------------------------------------------------------
-- SELECT to_regclass('public.inv_biaya_pembelian_landed');        -- NULL
-- SELECT to_regclass('public.inv_biaya_pembelian_landed_items');  -- NULL
-- SELECT to_regclass('public.enum_status_landed');                -- NULL
-- SELECT to_regclass('public.enum_dasar_alokasi');                -- NULL
-- SELECT count(*) FROM pg_type WHERE typname IN
--   ('enum_status_landed','enum_dasar_alokasi');                  -- 0
-- SELECT count(*) FROM core_menus WHERE url_path = '/inventory/operasi/landed'; -- 0
-- SELECT count(*) FROM core_routes WHERE uri_pattern LIKE '/inventory/operasi/landed%'; -- 0
-- SELECT doc_name, prefix FROM core_sequences WHERE doc_name = 'LC';  -- hanya purchase_landed?
--   (cek eksplisit: baris 'LC' modul inventory harus 0)
-- SELECT count(*) FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
--   WHERE s.doc_name = 'LC' AND m.key = 'inventory';              -- 0
