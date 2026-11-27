-- +goose Up
-- Porting 1:1 dari ddl/71-wa-instance-label.sql (urutan & isi sama, tanpa perubahan)

-- =========================================================================
-- PATCH 71 — wa_instance: kolom `label` (nama tampilan instance, nullable)
-- =========================================================================
-- KEPUTUSAN PEMILIK (2026-11-18; lanjutan patch 70):
--  1. `label` = NAMA TAMPILAN instance yang editable manusia (max 100;
--     NULL diperbolehkan). `nama` (instanceName Evolution, `wa-` + 8 hex)
--     TETAP kunci binding immutable — tampilan sekunder di UI.
--  2. Auto-fill dari live (sinkronLive/fetchInstances): bila `label` IS
--     NULL dan `profileName` perangkat (binding Baileys) tidak kosong →
--     label = profileName. Label yang SUDAH diisi user TIDAK PERNAH
--     ditimpa sinkron (komentar keputusan di service/repository).
--  3. NULL label = kembali ke mode auto (diisi profileName saat live
--     memberikannya) — ubahKonfig menerima label: null.
--  Tanpa index tambahan (label tidak difilter/unique — hanya display).
-- IDEMPOTEN: DO-block cek kolom dulu (lolos di-apply 2x).
-- =========================================================================

-- +goose StatementBegin
DO $$
DECLARE
  ada int;
BEGIN
  SELECT count(*) INTO ada
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND table_name = 'wa_instance'
    AND column_name = 'label';

  IF ada = 0 THEN
    ALTER TABLE wa_instance ADD COLUMN label varchar(100) NULL;
  END IF;
END
$$;
-- +goose StatementEnd
