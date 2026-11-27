-- +goose Up
-- Porting 1:1 dari ddl/81-core-mail-log-auth-token.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 81-core-mail-log-auth-token.sql — CORE: layanan email SMTP + token
-- aktivasi member portal (registrasi via link email)
-- =============================================================================
-- Domain   : NEXIERP · Kernel CORE — infra email + keamanan akun.
-- Sumber   : permintaan pemilik 2026-11-22 — "buat library service kirim email
--            (SMTP env MAIL_*) + registrasi member front shop harus diaktivasi
--            via link email". Pola acuan: core_password_resets (ddl/01,
--            [SESSION] belum terpakai), ecom_member_token (ddl/50 — token_hash
--            SHA-256 one-time), ecom_ledger_poin (LOG/EVENT trio).
-- Kartu    :
--   core_mail_log    | [LOG/EVENT] | core/mailer | jejak kirim email append-only
--                      (penerima/subjek/jenis/status/error/message-id) —
--                      observabilitas SMTP semua pemanggil (aktivasi dulu,
--                      lupa-sandi/notifikasi menyusul); updated_at beku,
--                      deleted_at selalu NULL.
--   core_auth_tokens | [SESSION]   | core/auth   | token one-time akun CORE
--                      (AKTIVASI registrasi member portal) — token mentah TIDAK
--                      pernah disimpan (token_hash SHA-256), TTL kedaluwarsa,
--                      one-time dipakai_at; FK core_users CASCADE (pola
--                      core_password_resets ddl/01); versi tidak ada
--                      (tidak diedit — pola ecom_member_token).
-- Keputusan: status akun tetap `core_users.is_active` (register → false,
--            aktivasi → true) — TANPA kolom baru di core_users; token AKTIVASI
--            milik CORE (bukan ecom_member_token) karena pemilik status akun =
--            core_users (core/auth), dan registrasi beroperasi pada core_users.
-- Idempoten: CREATE TYPE fail-loud (pola 50) + CREATE TABLE IF NOT EXISTS +
--            guard pg_constraint/index — lari kedua = no-op.
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/81-core-mail-log-auth-token.sql
--            (jalankan 2× — lari kedua = no-op)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1 ENUM BARU (fail-loud pola 50)
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_mail AS ENUM ('TERKIRIM', 'GAGAL', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_mail')
     IS DISTINCT FROM ARRAY['TERKIRIM', 'GAGAL', 'NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'enum_status_mail kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_token_core AS ENUM ('AKTIVASI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_token_core')
     IS DISTINCT FROM ARRAY['AKTIVASI']::text[] THEN
    RAISE EXCEPTION 'enum_jenis_token_core kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- §2 core_mail_log — jejak kirim email [LOG/EVENT] (append-only; pemilik
--    core/mailer). text TIDAK dipakai — subjek = bucket 200 (judul notifikasi),
--    penerima = bucket 150 (email), error/message-id = bucket 300.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_mail_log (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id           uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users       bigint,                    -- NULL = penerima non-user (tanpa akun CORE)
  penerima            varchar(150) NOT NULL,     -- alamat email tujuan
  penerima_nama       varchar(100),              -- nama tampil; NULL = tanpa nama
  subjek              varchar(200) NOT NULL,
  jenis               varchar(50) NOT NULL,      -- kode keperluan (AKTIVASI_MEMBER, …)
  status              enum_status_mail NOT NULL, -- TERKIRIM | GAGAL | NONAKTIF (SMTP mati)
  pesan_error         varchar(300),              -- NULL bila sukses
  provider_message_id varchar(300),              -- message-id vendor SMTP; NULL bila gagal/nonaktif
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),  -- beku (append-only)
  deleted_at          timestamptz,               -- selalu NULL (log tak dihapus)
  CONSTRAINT uq_core_mail_log_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_mail_log_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE SET NULL  -- riwayat kiriman selamat dari induk
);

COMMENT ON TABLE core_mail_log IS '[LOG/EVENT] jejak kirim email SMTP (core/mailer) — append-only; updated_at beku, deleted_at selalu NULL';
COMMENT ON COLUMN core_mail_log.status IS 'TERKIRIM | GAGAL (SMTP error) | NONAKTIF (MAIL_HOST kosong — layanan mati)';

CREATE INDEX IF NOT EXISTS ix_core_mail_log_penerima
  ON core_mail_log (penerima, created_at DESC);    -- query riwayat per alamat (aturan LOG: subjek, waktu)
CREATE INDEX IF NOT EXISTS ix_core_mail_log_waktu
  ON core_mail_log (created_at DESC);              -- trail terbaru dulu

-- -----------------------------------------------------------------------------
-- §3 core_auth_tokens — token one-time akun CORE [SESSION] (pemilik core/auth).
--    Pola ecom_member_token (ddl/50): SHA-256 hex, mentah tidak pernah
--    disimpan; pola core_password_resets (ddl/01): FK core_users CASCADE.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core_auth_tokens (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users  bigint NOT NULL,
  jenis          enum_jenis_token_core NOT NULL DEFAULT 'AKTIVASI',
  token_hash     varchar(150) NOT NULL,           -- SHA-256 hex dari token acak
  berlaku_hingga timestamptz NOT NULL,
  dipakai_at     timestamptz,                     -- NULL = belum terpakai
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_core_auth_tokens_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_core_auth_tokens_users FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE CASCADE   -- pola core_password_resets ddl/01
);

COMMENT ON TABLE core_auth_tokens IS '[SESSION] token one-time akun CORE (aktivasi registrasi member portal) — expiry + job bersih-bersih';
COMMENT ON COLUMN core_auth_tokens.token_hash IS 'SHA-256 hex token mentah — token asli hanya hidup di email, tidak pernah disimpan';

CREATE UNIQUE INDEX IF NOT EXISTS uq_core_auth_tokens_hash
  ON core_auth_tokens (token_hash);
CREATE INDEX IF NOT EXISTS ix_core_auth_tokens_sweeper
  ON core_auth_tokens (berlaku_hingga);            -- token terpakai ikut dibersihkan (bukan partial)
CREATE INDEX IF NOT EXISTS ix_core_auth_tokens_users
  ON core_auth_tokens (id_core_users);

COMMIT;