-- +goose Up
-- Porting 1:1 dari ddl/27-kasir-pin.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 27-kasir-pin.sql — PIN PETUGAS KASIR (fitur lock/unlock layar kasir)
-- Domain   : OdooLikeERP · Modul POS (fitur-modul-fullcycle) · pemilik data CORE
-- Kartu    : docs/arsitektur-database-pos.md PP-21 (+ kartu core: kredensial
--            sekunder user mengikuti pola password_hash di tabel yang sama)
-- Idempoten: ADD COLUMN IF NOT EXISTS — aman dijalankan berulang
--
-- Desain (gerbang arsitektur-database):
--   • PIN = kredensial sekunder 4–6 digit per petugas kasir (Odoo pos_hr style,
--     diadaptasi A-10: satu sesi = satu kasir) — bukan pengganti password login.
--   • Disimpan HASH argon2id (kontrak lapis backend — pernah plaintext = larang).
--   • NULL = belum pernah set PIN → layar kasir memaksa pengaturan pertama.
--   • Verifikasi hanya via endpoint BE (`/pos/kasir/unlock`); FE tidak pernah
--     memegang/memverifikasi PIN.
-- =============================================================================

ALTER TABLE core_users ADD COLUMN IF NOT EXISTS pin_hash varchar(255);
ALTER TABLE core_users ADD COLUMN IF NOT EXISTS pin_at timestamptz;

COMMENT ON COLUMN core_users.pin_hash IS
  'PIN kasir 4-6 digit (hash argon2id) untuk kunci/buka layar kasir POS;'
  ' NULL = belum set — kasir wajib mengatur saat pertama kali (PP-21).';
COMMENT ON COLUMN core_users.pin_at IS
  'Waktu PIN kasir terakhir diatur/diubah.';

-- PATCH 27-kasir-pin.sql selesai.
