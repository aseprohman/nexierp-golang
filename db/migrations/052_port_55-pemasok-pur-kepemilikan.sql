-- +goose Up
-- Porting 1:1 dari ddl/55-pemasok-pur-kepemilikan.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 55-pemasok-pur-kepemilikan.sql — KEPEMILIKAN PEMASOK KEMBALI KE
-- PURCHASING + FK WILAYAH (2026-11-12)
-- =============================================================================
-- KARTU ARSITEKTUR (arsitektur-database):
--   pur_pemasok            | [MASTER] | pemilik: PURCHASING (dikelola PUR-F01)
--   pur_pemasok_kontak     | [LINE]   (atribut master pur_pemasok)
--   pur_pemasok_harga      | [LINE]   (atribut master pur_pemasok — harga
--                            kontrak berperiode bertingkat)
--   PK `id bigint IDENTITY` + `entity_id uuid` Tier A (unique global) |
--   FK kelurahan: id_core_kelurahan → core_kelurahan RESTRICT (pola
--   ddl/48-inv-gudang-wilayah — master wilayah tetap milik CORE) |
--   kunci produksi: EXCLUDE gist ex_pur_pemasok_harga_overlap (pemasok +
--   produk + tier qty_minimal + daterange periode) WHERE deleted_at IS NULL.
--   Konsumen baca-saja/rujuk FK: PUR (pur_pesanan, pur_kesepakatan), ACC
--   (acc_faktur_pemasok, acc_pembayaran, acc_bukti_potong,
--   acc_model_rekonsiliasi), INV (reorder M27/valuasi).
--
-- ALASAN (keputusan pemilik 2026-11-12 — MEMBALIK keputusan 2026-11-06
-- "tabel lintas modul masuk core"): master pemasok dikelola oleh fitur
-- PUR-F01 (staf pembelian satu-satunya penulis), pemasok dilihat pemilik
-- bisnis sebagai bagian proses belanja — bukan master umum seperti
-- core_users. Doc-keputusan: docs/peta-modul.md §4 & docs/analisa-modul-pur.md
-- §4.1. Pola penamaan kembali ke modul pemilik: core_pemasok* → pur_pemasok*.
--
-- ISI PATCH:
--   (a) RENAME 3 tabel + enum core_status_pemasok → pur_status_pemasok;
--   (b) RENAME kolom FK id_core_pemasok → id_pur_pemasok di 8 tabel dependen
--       (pur_pemasok_kontak, pur_pemasok_harga, pur_pesanan, pur_kesepakatan,
--       acc_model_rekonsiliasi, acc_faktur_pemasok, acc_pembayaran,
--       acc_bukti_potong);
--   (c) RENAME constraint/index/trigger berprefiks core_pemasok pada 3 tabel
--       renamed (uq_/ck_/ex_/fk_/ix_/trg_). Nama constraint FK di tabel
--       MILIK modul lain TIDAK diubah (fk_pur_pesanan_pemasok,
--       fk_pur_kesepakatan_pemasok, fk_acc_fktpms_pemasok, fk_acc_byr_pemasok,
--       fk_acc_bupot_pemasok, fk_acc_model_rkn_pemasok) — hanya kolomnya;
--   (d) ADD COLUMN pur_pemasok.id_core_kelurahan bigint NULL + FK
--       `core_kelurahan(id) ON DELETE RESTRICT` + index — pola persis
--       ddl/48 (FK RESTRICT, NULL = belum diisi; transisi baris lama);
--   (e) COMMENT ON TABLE/COLUMN kepemilikan PURCHASING (keputusan 2026-11-12);
--   (f) VERIFIKASI EXCLUDE `ex_pur_pemasok_harga_overlap` tetap valid —
--       definisi mengikuti rename kolom, nama baru dicek fail-loud.
--
-- PRASYARAT: ddl/25-purchasing.sql (core_pemasok* / pur_pesanan /
--            pur_kesepakatan) + ddl/42-core-wilayah.sql (core_kelurahan —
--            FK fail-loud bila absen) + ddl/30-acc.sql (4 tabel ACC).
-- Idempoten: penuh — setiap rename ter-guard katalog (pg_class/pg_type/
--            pg_constraint/pg_indexes/pg_trigger/information_schema) dan
--            RAISE NOTICE per aksi; run ke-2 = no-op semua seksi.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/55-pemasok-pur-kepemilikan.sql (2×)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- (a1) RENAME ENUM — core_status_pemasok → pur_status_pemasok
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
             WHERE t.typname = 'core_status_pemasok' AND n.nspname = 'public') THEN
    IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
               WHERE t.typname = 'pur_status_pemasok' AND n.nspname = 'public') THEN
      RAISE EXCEPTION 'PATCH 55: enum core_status_pemasok DAN pur_status_pemasok keduanya ada — selaraskan manual dulu';
    END IF;
    ALTER TYPE core_status_pemasok RENAME TO pur_status_pemasok;
    RAISE NOTICE 'enum core_status_pemasok → pur_status_pemasok';
  ELSIF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                WHERE t.typname = 'pur_status_pemasok' AND n.nspname = 'public') THEN
    RAISE NOTICE 'enum pur_status_pemasok sudah ada — lewati rename enum';
  ELSE
    RAISE EXCEPTION 'PATCH 55: enum core_status_pemasok absen — ddl/25-purchasing.sql wajib dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- (a2) RENAME 3 TABEL — core_pemasok* → pur_pemasok*
--     (row type pg_class ikut rename; pkey & not-null internal mengikuti)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.core_pemasok') IS NOT NULL THEN
    IF to_regclass('public.pur_pemasok') IS NOT NULL THEN
      RAISE EXCEPTION 'PATCH 55: tabel core_pemasok DAN pur_pemasok keduanya ada — selaraskan manual dulu';
    END IF;
    ALTER TABLE core_pemasok RENAME TO pur_pemasok;
    RAISE NOTICE 'tabel core_pemasok → pur_pemasok';
  ELSIF to_regclass('public.pur_pemasok') IS NULL THEN
    RAISE EXCEPTION 'PATCH 55: tabel core_pemasok/pur_pemasok absen — ddl/25-purchasing.sql wajib dulu';
  ELSE
    RAISE NOTICE 'tabel pur_pemasok sudah ada — lewati rename tabel induk';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.core_pemasok_kontak') IS NOT NULL THEN
    ALTER TABLE core_pemasok_kontak RENAME TO pur_pemasok_kontak;
    RAISE NOTICE 'tabel core_pemasok_kontak → pur_pemasok_kontak';
  ELSIF to_regclass('public.pur_pemasok_kontak') IS NOT NULL THEN
    RAISE NOTICE 'tabel pur_pemasok_kontak sudah ada — lewati';
  ELSE
    RAISE EXCEPTION 'PATCH 55: tabel core_pemasok_kontak absen — ddl/25-purchasing.sql wajib dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.core_pemasok_harga') IS NOT NULL THEN
    ALTER TABLE core_pemasok_harga RENAME TO pur_pemasok_harga;
    RAISE NOTICE 'tabel core_pemasok_harga → pur_pemasok_harga';
  ELSIF to_regclass('public.pur_pemasok_harga') IS NOT NULL THEN
    RAISE NOTICE 'tabel pur_pemasok_harga sudah ada — lewati';
  ELSE
    RAISE EXCEPTION 'PATCH 55: tabel core_pemasok_harga absen — ddl/25-purchasing.sql wajib dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- (b) RENAME KOLOM FK — id_core_pemasok → id_pur_pemasok di 8 tabel
--     (definisi constraint/index yang merefer kolom mengikuti otomatis)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'pur_pemasok_kontak' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE pur_pemasok_kontak RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom pur_pemasok_kontak.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'pur_pemasok_kontak.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'pur_pemasok_harga' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE pur_pemasok_harga RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom pur_pemasok_harga.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'pur_pemasok_harga.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.pur_pesanan') IS NULL THEN
    RAISE NOTICE 'tabel pur_pesanan absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'pur_pesanan' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE pur_pesanan RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom pur_pesanan.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'pur_pesanan.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.pur_kesepakatan') IS NULL THEN
    RAISE NOTICE 'tabel pur_kesepakatan absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'pur_kesepakatan' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE pur_kesepakatan RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom pur_kesepakatan.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'pur_kesepakatan.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.acc_model_rekonsiliasi') IS NULL THEN
    RAISE NOTICE 'tabel acc_model_rekonsiliasi absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'acc_model_rekonsiliasi' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE acc_model_rekonsiliasi RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom acc_model_rekonsiliasi.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'acc_model_rekonsiliasi.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.acc_faktur_pemasok') IS NULL THEN
    RAISE NOTICE 'tabel acc_faktur_pemasok absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'acc_faktur_pemasok' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE acc_faktur_pemasok RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom acc_faktur_pemasok.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'acc_faktur_pemasok.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.acc_pembayaran') IS NULL THEN
    RAISE NOTICE 'tabel acc_pembayaran absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'acc_pembayaran' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE acc_pembayaran RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom acc_pembayaran.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'acc_pembayaran.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.acc_bukti_potong') IS NULL THEN
    RAISE NOTICE 'tabel acc_bukti_potong absen — lewati rename kolom (patch pemiliknya belum di-apply di DB ini)';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_name = 'acc_bukti_potong' AND column_name = 'id_core_pemasok') THEN
    ALTER TABLE acc_bukti_potong RENAME COLUMN id_core_pemasok TO id_pur_pemasok;
    RAISE NOTICE 'kolom acc_bukti_potong.id_core_pemasok → id_pur_pemasok';
  ELSE
    RAISE NOTICE 'acc_bukti_potong.id_pur_pemasok sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- (c) RENAME CONSTRAINT / INDEX / TRIGGER — prefiks core_pemasok pada 3 tabel
--     renamed. Nama constraint FK di tabel milik modul lain TIDAK disentuh.
--     (ALTER TABLE RENAME TO tidak merename constraint bernama/index/trigger.)
-- -----------------------------------------------------------------------------
-- c1) pur_pemasok
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_core_pemasok_entity_id'
             AND conrelid = 'pur_pemasok'::regclass) THEN
    ALTER TABLE pur_pemasok RENAME CONSTRAINT uq_core_pemasok_entity_id TO uq_pur_pemasok_entity_id;
    RAISE NOTICE 'constraint uq_core_pemasok_entity_id → uq_pur_pemasok_entity_id';
  ELSE RAISE NOTICE 'uq_pur_pemasok_entity_id sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_core_pemasok_kode'
             AND conrelid = 'pur_pemasok'::regclass) THEN
    ALTER TABLE pur_pemasok RENAME CONSTRAINT uq_core_pemasok_kode TO uq_pur_pemasok_kode;
    RAISE NOTICE 'constraint uq_core_pemasok_kode → uq_pur_pemasok_kode';
  ELSE RAISE NOTICE 'uq_pur_pemasok_kode sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_acc_termin'
             AND conrelid = 'pur_pemasok'::regclass) THEN
    ALTER TABLE pur_pemasok RENAME CONSTRAINT fk_core_pemasok_acc_termin TO fk_pur_pemasok_acc_termin;
    RAISE NOTICE 'constraint fk_core_pemasok_acc_termin → fk_pur_pemasok_acc_termin (kolom kode_termin tak berubah)';
  ELSE RAISE NOTICE 'fk_pur_pemasok_acc_termin sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_core_pemasok_status'
             AND tablename = 'pur_pemasok') THEN
    ALTER INDEX ix_core_pemasok_status RENAME TO ix_pur_pemasok_status;
    RAISE NOTICE 'index ix_core_pemasok_status → ix_pur_pemasok_status';
  ELSE RAISE NOTICE 'ix_pur_pemasok_status sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_core_pemasok_updated_at'
             AND tgrelid = 'pur_pemasok'::regclass AND NOT tgisinternal) THEN
    ALTER TRIGGER trg_core_pemasok_updated_at ON pur_pemasok RENAME TO trg_pur_pemasok_updated_at;
    RAISE NOTICE 'trigger trg_core_pemasok_updated_at → trg_pur_pemasok_updated_at';
  ELSE RAISE NOTICE 'trg_pur_pemasok_updated_at sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- c2) pur_pemasok_kontak
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_core_pemasok_kontak_entity_id'
             AND conrelid = 'pur_pemasok_kontak'::regclass) THEN
    ALTER TABLE pur_pemasok_kontak RENAME CONSTRAINT uq_core_pemasok_kontak_entity_id TO uq_pur_pemasok_kontak_entity_id;
    RAISE NOTICE 'constraint uq_core_pemasok_kontak_entity_id → uq_pur_pemasok_kontak_entity_id';
  ELSE RAISE NOTICE 'uq_pur_pemasok_kontak_entity_id sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_kontak_pemasok'
             AND conrelid = 'pur_pemasok_kontak'::regclass) THEN
    ALTER TABLE pur_pemasok_kontak RENAME CONSTRAINT fk_core_pemasok_kontak_pemasok TO fk_pur_pemasok_kontak_pemasok;
    RAISE NOTICE 'constraint fk_core_pemasok_kontak_pemasok → fk_pur_pemasok_kontak_pemasok';
  ELSE RAISE NOTICE 'fk_pur_pemasok_kontak_pemasok sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_core_pemasok_kontak_pemasok'
             AND tablename = 'pur_pemasok_kontak') THEN
    ALTER INDEX ix_core_pemasok_kontak_pemasok RENAME TO ix_pur_pemasok_kontak_pemasok;
    RAISE NOTICE 'index ix_core_pemasok_kontak_pemasok → ix_pur_pemasok_kontak_pemasok';
  ELSE RAISE NOTICE 'ix_pur_pemasok_kontak_pemasok sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_core_pemasok_kontak_updated_at'
             AND tgrelid = 'pur_pemasok_kontak'::regclass AND NOT tgisinternal) THEN
    ALTER TRIGGER trg_core_pemasok_kontak_updated_at ON pur_pemasok_kontak RENAME TO trg_pur_pemasok_kontak_updated_at;
    RAISE NOTICE 'trigger trg_core_pemasok_kontak_updated_at → trg_pur_pemasok_kontak_updated_at';
  ELSE RAISE NOTICE 'trg_pur_pemasok_kontak_updated_at sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- c3) pur_pemasok_harga
-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_core_pemasok_harga_entity_id'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT uq_core_pemasok_harga_entity_id TO uq_pur_pemasok_harga_entity_id;
    RAISE NOTICE 'constraint uq_core_pemasok_harga_entity_id → uq_pur_pemasok_harga_entity_id';
  ELSE RAISE NOTICE 'uq_pur_pemasok_harga_entity_id sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_harga_pemasok'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT fk_core_pemasok_harga_pemasok TO fk_pur_pemasok_harga_pemasok;
    RAISE NOTICE 'constraint fk_core_pemasok_harga_pemasok → fk_pur_pemasok_harga_pemasok';
  ELSE RAISE NOTICE 'fk_pur_pemasok_harga_pemasok sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_harga_produk'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT fk_core_pemasok_harga_produk TO fk_pur_pemasok_harga_produk;
    RAISE NOTICE 'constraint fk_core_pemasok_harga_produk → fk_pur_pemasok_harga_produk';
  ELSE RAISE NOTICE 'fk_pur_pemasok_harga_produk sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_core_pemasok_harga_unit'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT fk_core_pemasok_harga_unit TO fk_pur_pemasok_harga_unit;
    RAISE NOTICE 'constraint fk_core_pemasok_harga_unit → fk_pur_pemasok_harga_unit';
  ELSE RAISE NOTICE 'fk_pur_pemasok_harga_unit sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_core_pemasok_harga_qty'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT ck_core_pemasok_harga_qty TO ck_pur_pemasok_harga_qty;
    RAISE NOTICE 'constraint ck_core_pemasok_harga_qty → ck_pur_pemasok_harga_qty';
  ELSE RAISE NOTICE 'ck_pur_pemasok_harga_qty sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_core_pemasok_harga_periode'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT ck_core_pemasok_harga_periode TO ck_pur_pemasok_harga_periode;
    RAISE NOTICE 'constraint ck_core_pemasok_harga_periode → ck_pur_pemasok_harga_periode';
  ELSE RAISE NOTICE 'ck_pur_pemasok_harga_periode sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ex_core_pemasok_harga_overlap'
             AND conrelid = 'pur_pemasok_harga'::regclass) THEN
    ALTER TABLE pur_pemasok_harga RENAME CONSTRAINT ex_core_pemasok_harga_overlap TO ex_pur_pemasok_harga_overlap;
    RAISE NOTICE 'constraint ex_core_pemasok_harga_overlap → ex_pur_pemasok_harga_overlap';
  ELSE RAISE NOTICE 'ex_pur_pemasok_harga_overlap sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_core_pemasok_harga_pemasok'
             AND tablename = 'pur_pemasok_harga') THEN
    ALTER INDEX ix_core_pemasok_harga_pemasok RENAME TO ix_pur_pemasok_harga_pemasok;
    RAISE NOTICE 'index ix_core_pemasok_harga_pemasok → ix_pur_pemasok_harga_pemasok';
  ELSE RAISE NOTICE 'ix_pur_pemasok_harga_pemasok sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_core_pemasok_harga_produk'
             AND tablename = 'pur_pemasok_harga') THEN
    ALTER INDEX ix_core_pemasok_harga_produk RENAME TO ix_pur_pemasok_harga_produk;
    RAISE NOTICE 'index ix_core_pemasok_harga_produk → ix_pur_pemasok_harga_produk';
  ELSE RAISE NOTICE 'ix_pur_pemasok_harga_produk sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_core_pemasok_harga_updated_at'
             AND tgrelid = 'pur_pemasok_harga'::regclass AND NOT tgisinternal) THEN
    ALTER TRIGGER trg_core_pemasok_harga_updated_at ON pur_pemasok_harga RENAME TO trg_pur_pemasok_harga_updated_at;
    RAISE NOTICE 'trigger trg_core_pemasok_harga_updated_at → trg_pur_pemasok_harga_updated_at';
  ELSE RAISE NOTICE 'trg_pur_pemasok_harga_updated_at sudah ada — lewati'; END IF;
END $$;
-- +goose StatementEnd


-- c4) Constraint INTERNAL otomatis (pkey + not_null) yang tersisa berprefiks
--     core_pemasok — PostgreSQL TIDAK merename pg_constraint internal saat
--     ALTER TABLE RENAME TO / RENAME COLUMN (diverifikasi PG 18). Index pkey
--     underlying ikut rename bersama constraint. Tabel disasar: 3 tabel
--     renamed + pur_pesanan & acc_faktur_pemasok (not_null kolom FK renamed).
--     Nama constraint FK bernama di tabel ACC/pur NAMA TIDAK disentuh di sini
--     (fk_pur_pesanan_pemasok dkk. tak memuat substring core_pemasok).
-- +goose StatementBegin
DO $$
DECLARE
  r record;
  v_new text;
  v_count int := 0;
BEGIN
  -- to_regclass: tabel absen (patch pemiliknya belum di-apply) → NULL = lewati
  FOR r IN
    SELECT c.oid, c.conname, c.conrelid::regclass::text AS tbl
    FROM pg_constraint c
    WHERE c.conname LIKE '%core_pemasok%'
      AND c.conrelid IN (
        to_regclass('public.pur_pemasok'),
        to_regclass('public.pur_pemasok_kontak'),
        to_regclass('public.pur_pemasok_harga'),
        to_regclass('public.pur_pesanan'),
        to_regclass('public.pur_kesepakatan'),
        to_regclass('public.acc_faktur_pemasok'),
        to_regclass('public.acc_pembayaran'),
        to_regclass('public.acc_bukti_potong'),
        to_regclass('public.acc_model_rekonsiliasi')
      )
    ORDER BY c.conrelid::regclass::text, c.conname
  LOOP
    -- substring core_pemasok juga menangani bentuk id_core_pemasok (not_null)
    v_new := replace(r.conname, 'core_pemasok', 'pur_pemasok');
    EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I', r.tbl, r.conname, v_new);
    RAISE NOTICE 'constraint internal % → % (di %)', r.conname, v_new, r.tbl;
    v_count := v_count + 1;
  END LOOP;
  IF v_count = 0 THEN
    RAISE NOTICE 'tidak ada constraint internal core_pemasok tersisa — lewati';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- (d) KOLOM WILAYAH — pur_pemasok.id_core_kelurahan (pola ddl/48:
--     FK RESTRICT ke master CORE core_kelurahan; NULL = wilayah belum diisi).
--     Fail-loud bila ddl/42 belum di-apply di DB target.
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  IF to_regclass('public.core_kelurahan') IS NULL THEN
    RAISE EXCEPTION 'PATCH 55: tabel core_kelurahan absen — jalankan ddl/42-core-wilayah.sql dulu (prasyarat FK wilayah)';
  END IF;
END $$;
-- +goose StatementEnd


ALTER TABLE pur_pemasok
  ADD COLUMN IF NOT EXISTS id_core_kelurahan bigint;

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_pur_pemasok_kelurahan'
      AND conrelid = 'pur_pemasok'::regclass
  ) THEN
    ALTER TABLE pur_pemasok
      ADD CONSTRAINT fk_pur_pemasok_kelurahan
      FOREIGN KEY (id_core_kelurahan)
      REFERENCES core_kelurahan (id) ON DELETE RESTRICT;
    RAISE NOTICE 'FK fk_pur_pemasok_kelurahan dibuat (RESTRICT)';
  ELSE
    RAISE NOTICE 'fk_pur_pemasok_kelurahan sudah ada — lewati';
  END IF;
END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_pur_pemasok_kelurahan
  ON pur_pemasok (id_core_kelurahan);

-- -----------------------------------------------------------------------------
-- (e) COMMENT ON TABLE/COLUMN — catat keputusan kepemilikan 2026-11-12
-- -----------------------------------------------------------------------------
COMMENT ON TABLE pur_pemasok IS
  '[MASTER] Master mitra pemasok — PEMILIK PURCHASING (keputusan pemilik 2026-11-12: membalik keputusan 2026-11-06 yang memindahkan ke CORE; pengelolaan tetap fitur PUR-F01). Konsumen rujuk: PUR (pur_pesanan, pur_kesepakatan), ACC (faktur, pembayaran, bukti potong, rekonsiliasi), INV (reorder M27/valuasi).';
COMMENT ON TABLE pur_pemasok_kontak IS
  '[LINE] PIC pemasok (nama/telepon/email/fungsi) — atribut master pur_pemasok, pemilik PURCHASING (PUR-F01; keputusan pemilik 2026-11-12).';
COMMENT ON TABLE pur_pemasok_harga IS
  '[LINE] Daftar harga kontrak berperiode bertingkat per produk — atribut master pur_pemasok, pemilik PURCHASING (PUR-F01/PUR-BR06; keputusan pemilik 2026-11-12). Kunci produksi EXCLUDE ex_pur_pemasok_harga_overlap.';
COMMENT ON COLUMN pur_pemasok.id_core_kelurahan IS
  'Referensi wilayah daun core_kelurahan (pemilik CORE — pola ddl/48) untuk akurasi biaya shipment dari pemasok (A-08 ditutup ronde-4). NULL = wilayah belum diisi.';
COMMENT ON COLUMN pur_pemasok.status IS
  'Siklus hidup pemasok — enum pur_status_pemasok (rename dari core_status_pemasok, ddl/55).';

-- -----------------------------------------------------------------------------
-- (f) VERIFIKASI EXCLUDE — definisi mengikuti rename kolom; nama baru wajib
--     ada dan definisinya memuat id_pur_pemasok (fail-loud bila tergelincir)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM pg_constraint
  WHERE conname = 'ex_pur_pemasok_harga_overlap'
    AND conrelid = 'pur_pemasok_harga'::regclass;
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'PATCH 55: ex_pur_pemasok_harga_overlap absen setelah rename — periksa manual';
  END IF;
  IF position('id_pur_pemasok' in v_def) = 0 THEN
    RAISE EXCEPTION 'PATCH 55: definisi EXCLUDE tidak memuat id_pur_pemasok: %', v_def;
  END IF;
  RAISE NOTICE 'verifikasi EXCLUDE ok: %', v_def;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- VERIFIKASI — introspeksi manual SETELAH apply (BUKAN bagian eksekusi)
--   SELECT count(*) FROM pg_tables WHERE tablename IN
--     ('pur_pemasok','pur_pemasok_kontak','pur_pemasok_harga');         -- 3
--   SELECT count(*) FROM pg_tables WHERE tablename LIKE 'core_pemasok%'; -- 0
--   SELECT count(*) FROM information_schema.columns
--     WHERE column_name='id_pur_pemasok';                                -- 8
--   SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conrelid='pur_pemasok'::regclass ORDER BY conname;
--   SELECT indexname FROM pg_indexes WHERE tablename LIKE 'pur_pemasok%';
--   SELECT tgname FROM pg_trigger WHERE tgrelid LIKE 'pur_pemasok%'::regclass
--     AND NOT tgisinternal;
--   SELECT count(*) FROM information_schema.columns
--     WHERE table_name='pur_pemasok' AND column_name='id_core_kelurahan'; -- 1
-- =============================================================================
-- ddl/55-pemasok-pur-kepemilikan.sql selesai.
