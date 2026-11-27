-- +goose Up
-- Porting 1:1 dari ddl/70-wa-instance-nomor-nullable.sql (urutan & isi sama, tanpa perubahan)

-- =========================================================================
-- PATCH 70 — wa_instance: `nomor` NULLABLE (identitas device dari sinkron live)
-- =========================================================================
-- KEPUTUSAN PEMILIK (2026-11-18; semantik BARU fitur INSTANCE modul WA):
--  Halaman instance BUKAN CRUD — ia MENGHUBUNGKAN WhatsApp device ke
--  Evolution API. Identitas instance (nama/nomor) TIDAK diisi manusia:
--  - `nama` dibangkitkan server (`wa-` + 8 hex) saat POST /wa/instance/
--    hubungkan (POST /instance/create vendor);
--  - `nomor` (dan status koneksi) diisi OTOMATIS dari real koneksi device —
--    hasil GET /instance/fetchInstances via endpoint sinkron live
--    (GET /wa/instance/status-live) + webhook CONNECTION_UPDATE (ownerJid).
--  Akibatnya nomor BELUM ADA sebelum device pairing sukses → kolom `nomor`
--  harus nullable. Nilai NULL = device belum pairing / nomor belum diketahui
--  vendor; display FE "—".
--  Partial unique `uq_wa_instance_nomor_hidup (nomor) WHERE deleted_at IS
--  NULL` TETAP — di PostgreSQL baris NULL tidak saling bentrok (multiple
--  NULL sah), jadi banyak instance menunggu pairing diperbolehkan, dan
--  nomor E.164 tetap unik di antara baris hidup yang sudah pairing.
-- IDEMPOTEN: DO-block cek nullable dulu — ALTER hanya jalan bila masih
-- NOT NULL (lolos di-apply 2x).
-- =========================================================================

-- +goose StatementBegin
DO $$
DECLARE
  nullable text;
BEGIN
  SELECT is_nullable INTO nullable
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND table_name = 'wa_instance'
    AND column_name = 'nomor';

  IF nullable IS NULL THEN
    RAISE WARNING 'kolom wa_instance.nomor tidak ada — ALTER dilewati';
  ELSIF nullable = 'NO' THEN
    ALTER TABLE wa_instance ALTER COLUMN nomor DROP NOT NULL;
  END IF;
END
$$;
-- +goose StatementEnd
