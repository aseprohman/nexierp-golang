-- +goose Up
-- Porting 1:1 dari ddl/47-shp-webhook-setting.sql (urutan & isi sama, tanpa perubahan)

-- ============================================================================
-- PATCH DDL 47-shp-webhook-setting.sql — SHP setting webhook event Biteship
-- ============================================================================
-- Domain   : OdooLikeERP · Modul SHP (prioritas vendor: BITESHIP)
-- Sumber   : keputusan pemilik 2026-11-09 — fitur seting webhook event
--            (order.status / order.price / order.waybill_id): URL callback
--            didaftarkan MANUAL di dashboard Biteship (resmi Biteship tidak
--            punya API registrasi webhook); setting di aplikasi mengatur
--            EVENT mana yang DIPROSES — event nonaktif tetap dicatat log
--            (hasil NONAKTIF) tanpa efek ke order (anti retry-storm tetap).
-- Tanggal  : 2026-11-09
-- Prasyarat: ddl/41-shp.sql (shp_konfigurasi_vendor, enum_hasil_verifikasi_shp).
-- Isi      : (1) enum_hasil_verifikasi_shp += 'NONAKTIF' (event dikenal tapi
--            tidak diaktifkan — dicatat log, tanpa efek); (2) shp_konfigurasi_
--            vendor += kolom webhook_event_aktif jsonb (array event aktif;
--            NULL/absen = semua event resmi diproses — backward compatible).
-- Idempoten: ALTER TYPE ADD VALUE IF NOT EXISTS; ADD COLUMN IF NOT EXISTS.
-- Catatan  : ALTER TYPE ADD VALUE tidak boleh di dalam transaction block
--            yang memakai nilai barunya — patch dijalankan autocommit
--            (psql tanpa -1) dan nilai baru tidak dipakai statement lain.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/47-shp-webhook-setting.sql   (2×)
-- ============================================================================

-- (1) enum_hasil_verifikasi_shp += NONAKTIF
ALTER TYPE enum_hasil_verifikasi_shp ADD VALUE IF NOT EXISTS 'NONAKTIF';

-- (2) Setting event webhook per konfigurasi vendor.
--     Bentuk jsonb: ["ORDER_STATUS","ORDER_PRICE","ORDER_WAYBILL_ID"] (array
--     kosong = tidak ada event diproses; NULL = semua diproses — default).
ALTER TABLE shp_konfigurasi_vendor
  ADD COLUMN IF NOT EXISTS webhook_event_aktif jsonb;

COMMENT ON COLUMN shp_konfigurasi_vendor.webhook_event_aktif IS
  'Event webhook Biteship yang DIPROSES (jsonb array kosakata enum_event_webhook_shp); NULL/absen = semua event resmi diproses';

-- VERIFIKASI manual: kolom ada; enum berisi NONAKTIF.
-- ============================================================================
-- ddl/47-shp-webhook-setting.sql selesai.
