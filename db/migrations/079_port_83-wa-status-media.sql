-- +goose Up
-- Porting 1:1 dari ddl/83-wa-status-media.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 83-wa-status-media.sql — WA: media library di status WA (story)
-- =============================================================================
-- Domain   : NEXIERP · Modul WA — form status WA melampirkan media library
--            (MediaUploader scope "wa-status") tapi BE MEMBUANGNYA DIAM-DIAM:
--            schema zod menerima `lampiran` (lampiranPesanSchema) sementara
--            DDL wa_status tidak punya kolom media (komentar batasan di
--            status.service "kolom wa_status belum menyimpan metadata media").
--            Akibat: media hilang saat simpan/edit, kirim hanya teks.
-- Isi      : 4 kolom — `id_core_files` (FK RESTRICT live CORE, pola ddl/80)
--            + denormalisasi metadata (nama_file, ukuran_file, mime_type —
--            mirror lampiranPesanSchema; pola kolom media wa_pesan).
--            TANPA kolom url: URL kirim = presign FRESH saat kirim/preview
--            (presigned URL kedaluwarsa 1 jam — menympan URL antrean lama =
--            kirim gagal); TANPA index baru (tidak ada reverse-lookup by file).
-- Kartu    :
--   wa_status | [TRANSAKSI] | wa | +kolom id_core_files (FK core_files,
--   RESTRICT) + nama_file + ukuran_file + mime_type — lampiran status story
-- Idempoten: ADD COLUMN IF NOT EXISTS + DO-block guard pg_constraint — lari
--            kedua = no-op (kolom & FK sudah ada, semua langkah lewati).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/83-wa-status-media.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 Kolom media — nullable; NULL = status teks-saja (form lampiran opsional).
-- -----------------------------------------------------------------------------

ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS id_core_files bigint;
ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS nama_file varchar(255);
ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS ukuran_file bigint;
ALTER TABLE wa_status ADD COLUMN IF NOT EXISTS mime_type varchar(100);

COMMENT ON COLUMN wa_status.id_core_files IS 'Lampiran media library status story — referensi core_files; NULL = status teks-saja';
COMMENT ON COLUMN wa_status.nama_file IS 'Nama file lampiran (denormalisasi core_files.original_name — mirror lampiranPesanSchema)';
COMMENT ON COLUMN wa_status.ukuran_file IS 'Ukuran file lampiran bytes (denormalisasi core_files.size_bytes)';
COMMENT ON COLUMN wa_status.mime_type IS 'MIME type lampiran (denormalisasi core_files.mime_type — penentu jenis story image/video)';

-- -----------------------------------------------------------------------------
-- §2 FK fk_wa_status_core_files — RESTRICT live CORE (pola media ddl/80
--    fk_ecom_kategori_core_files; guard pg_constraint pola ddl/67).
-- -----------------------------------------------------------------------------

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_wa_status_core_files') THEN
    ALTER TABLE wa_status
      ADD CONSTRAINT fk_wa_status_core_files FOREIGN KEY (id_core_files)
      REFERENCES core_files (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


COMMENT ON CONSTRAINT fk_wa_status_core_files ON wa_status IS 'lampiran RESTRICT live CORE — file terpakai status tidak boleh terhapus (pola ddl/80)';

COMMIT;