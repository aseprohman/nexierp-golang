-- =============================================================================
-- PATCH DDL 50-ecom-portal.sql — ECOM fase 2: MEMBER PORTAL + FLASH/BANNER + V3 ALTERS
-- Domain   : OdooLikeERP (single tenant, konfigurable)
-- Sumber   : docs/analisa-modul-ecom-v3.md (blueprint portal; A-06 member milik ECOM,
--            A-13 fee vendor, A-14 kartu fisik turunan F09) + docs/audit-analisa-ecom-v2.md
--            (P1-1/P1-2) + docs/peta-modul.md §4 baris ECOM + §5 M50/M52/M55/M56/M58.
-- Kartu    : docs/arsitektur-database-ecom.md §6 (D-01…D-15 — hasil audit gerbang
--            arsitektur-database 2026-11-10; D-02 varian tetap milik INV).
-- Isi      : 9 tabel baru (member, member_alamat, member_sesi, member_token, wishlist,
--            ledger_poin, flash_sale, flash_sale_item, banner) + 7 enum baru + ALTER
--            ecom_pesanan_web/kupon/keranjang/keranjang_item/pesanan_web_item.
-- Integrasi: member tanpa FK ke core_users (auth publik terpisah); varian = SKU
--            inv_produk (id_inv_produk di item, tanpa tabel varian ECOM); tanpa FK ke
--            pgw_*/shp_* — integrasi kontrak-only (gateway_ref, order_kurir_ref,
--            kalkulasi_ref/opsi_ref varchar Tier B); fee gateway = pgw_channel (patch 49).
-- Idempoten: aman dijalankan berulang; tidak ada INSERT data; nilai enum 'ecom' pada
--            core_module_key sudah commit sejak ddl/36 (tidak di-ALTER lagi di sini).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--              -v ON_ERROR_STOP=1 < ddl/50-ecom-portal.sql   (jalankan 2× = idempoten)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- §1 ENUM BARU (fail-loud pola 36/41)
-- -----------------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE enum_status_member_ecom AS ENUM ('AKTIF', 'DIBLOKIR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_member_ecom')
     IS DISTINCT FROM ARRAY['AKTIF', 'DIBLOKIR']::text[] THEN
    RAISE EXCEPTION 'enum_status_member_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_jenis_token_member_ecom AS ENUM ('RESET_SANDI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_token_member_ecom')
     IS DISTINCT FROM ARRAY['RESET_SANDI']::text[] THEN
    RAISE EXCEPTION 'enum_jenis_token_member_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_tipe_poin_ecom AS ENUM ('EARN', 'REDEEM', 'HANGUS', 'KOREKSI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_tipe_poin_ecom')
     IS DISTINCT FROM ARRAY['EARN', 'REDEEM', 'HANGUS', 'KOREKSI']::text[] THEN
    RAISE EXCEPTION 'enum_tipe_poin_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_flash_ecom AS ENUM ('DRAFT', 'TERJADWAL', 'BERJALAN', 'SELESAI', 'DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_flash_ecom')
     IS DISTINCT FROM ARRAY['DRAFT', 'TERJADWAL', 'BERJALAN', 'SELESAI', 'DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'enum_status_flash_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_posisi_banner_ecom AS ENUM ('HERO', 'STRIP', 'KATEGORI');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_posisi_banner_ecom')
     IS DISTINCT FROM ARRAY['HERO', 'STRIP', 'KATEGORI']::text[] THEN
    RAISE EXCEPTION 'enum_posisi_banner_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_status_banner_ecom AS ENUM ('AKTIF', 'NONAKTIF');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_banner_ecom')
     IS DISTINCT FROM ARRAY['AKTIF', 'NONAKTIF']::text[] THEN
    RAISE EXCEPTION 'enum_status_banner_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

DO $$ BEGIN
  CREATE TYPE enum_sumber_resi_ecom AS ENUM ('M56', 'MANUAL');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_sumber_resi_ecom')
     IS DISTINCT FROM ARRAY['M56', 'MANUAL']::text[] THEN
    RAISE EXCEPTION 'enum_sumber_resi_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- §2 TABEL MASTER
-- -----------------------------------------------------------------------------

-- 2.1 ecom_member — akun pembeli portal [MASTER] (A-06; auth publik terpisah dari core_users)
CREATE TABLE IF NOT EXISTS ecom_member (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  email           varchar(150) NOT NULL,
  sandi_hash      varchar(150) NOT NULL,           -- argon2-encoded (<= ~123 karakter)
  nama            varchar(100) NOT NULL,
  telepon         varchar(50),
  saldo_poin      integer NOT NULL DEFAULT 0 CHECK (saldo_poin >= 0),
  gagal_login     integer NOT NULL DEFAULT 0 CHECK (gagal_login >= 0),
  terkunci_hingga timestamptz,
  status          enum_status_member_ecom NOT NULL DEFAULT 'AKTIF',
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_ecom_member_entity_id UNIQUE (entity_id)
);

COMMENT ON COLUMN ecom_member.email IS 'identitas login member; unik di antara baris hidup (boleh dipakai ulang pasca soft-delete — bukan numbering)';
COMMENT ON COLUMN ecom_member.saldo_poin IS 'cache saldo; sumber kebenaran = ecom_ledger_poin (rekonsiliasi ECOM-BR14)';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_member_email_hidup
  ON ecom_member (email) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_member_blokir
  ON ecom_member (status) WHERE status = 'DIBLOKIR' AND deleted_at IS NULL;

-- 2.2 ecom_member_alamat — buku alamat kirim member [MASTER] (F12; snapshot ke pesanan)
CREATE TABLE IF NOT EXISTS ecom_member_alamat (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id       uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ecom_member  bigint NOT NULL,
  penerima        varchar(100) NOT NULL,
  telepon         varchar(50),
  provinsi        varchar(100) NOT NULL,
  kota            varchar(100) NOT NULL,
  kecamatan       varchar(100) NOT NULL,
  kelurahan       varchar(100) NOT NULL,
  kode_pos        varchar(50),
  alamat_lengkap  varchar(300) NOT NULL,
  tanda_utama     boolean NOT NULL DEFAULT false,
  version         integer NOT NULL DEFAULT 1,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_ecom_member_alamat_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ecom_member_alamat_member FOREIGN KEY (id_ecom_member)
    REFERENCES ecom_member (id) ON DELETE RESTRICT
);

COMMENT ON COLUMN ecom_member_alamat.provinsi IS 'wilayah bertingkat divalidasi aplikasi ke master shp_wilayah (baca-saja, pemilik SHP — tanpa FK, D-06)';
COMMENT ON COLUMN ecom_member_alamat.alamat_lengkap IS 'disalin BEKU ke ecom_pesanan_web.alamat_kirim saat checkout — perubahan/hapus alamat tak pernah menyentuh pesanan lama (F12)';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_member_alamat_utama_hidup
  ON ecom_member_alamat (id_ecom_member) WHERE tanda_utama AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_member_alamat_member
  ON ecom_member_alamat (id_ecom_member) WHERE deleted_at IS NULL;

-- 2.3 ecom_banner — konten promosi portal [MASTER] (F19)
CREATE TABLE IF NOT EXISTS ecom_banner (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  judul            varchar(100) NOT NULL,
  posisi           enum_posisi_banner_ecom NOT NULL DEFAULT 'HERO',
  id_core_files    bigint,                          -- gambar utama (penyimpanan berkas platform — pemilik CORE)
  tautan           varchar(300),
  id_ecom_kupon    bigint,                          -- strip voucher: banner mengikuti kupon (SET NULL bila kupon dihapus)
  urutan           integer NOT NULL DEFAULT 0 CHECK (urutan >= 0),
  periode_mulai    timestamptz,
  periode_berakhir timestamptz,
  status           enum_status_banner_ecom NOT NULL DEFAULT 'AKTIF',
  alasan_nonaktif  varchar(300),
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_ecom_banner_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_banner_periode CHECK (
    periode_berakhir IS NULL OR periode_mulai IS NULL OR periode_berakhir > periode_mulai),
  CONSTRAINT fk_ecom_banner_file  FOREIGN KEY (id_core_files) REFERENCES core_files (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_banner_kupon FOREIGN KEY (id_ecom_kupon) REFERENCES ecom_kupon (id) ON DELETE SET NULL
);

COMMENT ON COLUMN ecom_banner.alasan_nonaktif IS 'ECOM-BR04: nonaktifkan banner berjalan wajib konfirmasi + alasan (dieksekusi app-side + audit; NONAKTIF awal tanpa alasan sah sebagai draft)';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_banner_posisi_urutan_hidup
  ON ecom_banner (posisi, urutan) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_banner_render
  ON ecom_banner (posisi) WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- §3 TABEL SESSION / JUNCTION / LOG
-- -----------------------------------------------------------------------------

-- 3.1 ecom_member_sesi — sesi login member [SESSION] (kartu fisik turunan F09, A-14;
--     tanpa version — pola core_sessions: mutasi sesi = revoke/rotasi idempoten)
CREATE TABLE IF NOT EXISTS ecom_member_sesi (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ecom_member bigint NOT NULL,
  token_hash     varchar(150) NOT NULL,            -- refresh token ter-hash; mentah tidak pernah disimpan
  device_ref     varchar(150) NOT NULL,            -- device key perangkat (x-device-key pola portal)
  ip_address     varchar(50),
  user_agent     varchar(300),
  waktu_login    timestamptz NOT NULL DEFAULT now(),
  berlaku_hingga timestamptz NOT NULL,
  dicabut_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_ecom_member_sesi_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ecom_member_sesi_member FOREIGN KEY (id_ecom_member)
    REFERENCES ecom_member (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_member_sesi_token
  ON ecom_member_sesi (token_hash);
CREATE INDEX IF NOT EXISTS ix_ecom_member_sesi_sweeper
  ON ecom_member_sesi (berlaku_hingga) WHERE dicabut_at IS NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_member_sesi_member
  ON ecom_member_sesi (id_ecom_member) WHERE deleted_at IS NULL;

-- 3.2 ecom_member_token — token one-time (reset sandi, dst.) [SESSION]
--     (kartu fisik turunan F09, A-14; tanpa version — one-time, tidak diedit)
CREATE TABLE IF NOT EXISTS ecom_member_token (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ecom_member bigint NOT NULL,
  jenis          enum_jenis_token_member_ecom NOT NULL DEFAULT 'RESET_SANDI',
  token_hash     varchar(150) NOT NULL,            -- SHA-256 hex dari token acak; mentah tidak pernah disimpan
  berlaku_hingga timestamptz NOT NULL,
  dipakai_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,
  CONSTRAINT uq_ecom_member_token_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ecom_member_token_member FOREIGN KEY (id_ecom_member)
    REFERENCES ecom_member (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_member_token_hash
  ON ecom_member_token (token_hash);
CREATE INDEX IF NOT EXISTS ix_ecom_member_token_sweeper
  ON ecom_member_token (berlaku_hingga);           -- token terpakai ikut dibersihkan (bukan partial)
CREATE INDEX IF NOT EXISTS ix_ecom_member_token_member
  ON ecom_member_token (id_ecom_member);

-- 3.3 ecom_wishlist — favorit member/tamu [JUNCTION] (F16; klaim F13/BR16)
--     sesi_perangkat NOT NULL = penanda pemilik dua-tier (member | perangkat tamu),
--     bukan atribut bisnis (kartu §6.2).
CREATE TABLE IF NOT EXISTS ecom_wishlist (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ecom_member         bigint,                   -- NULL = tamu per perangkat
  sesi_perangkat         varchar(150) NOT NULL,
  id_ecom_katalog_online bigint NOT NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT fk_ecom_wishlist_member  FOREIGN KEY (id_ecom_member)
    REFERENCES ecom_member (id) ON DELETE CASCADE,  -- preferensi personal, tidak historis (pola core_users_roles)
  CONSTRAINT fk_ecom_wishlist_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_wishlist_member_hidup
  ON ecom_wishlist (id_ecom_member, id_ecom_katalog_online)
  WHERE id_ecom_member IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_wishlist_tamu_hidup
  ON ecom_wishlist (sesi_perangkat, id_ecom_katalog_online)
  WHERE id_ecom_member IS NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_wishlist_sesi
  ON ecom_wishlist (sesi_perangkat) WHERE id_ecom_member IS NULL;

-- 3.4 ecom_ledger_poin — mutasi poin append-only [LOG/EVENT] (F17, ECOM-BR14)
--     append-only ditegakkan app-layer (konvensi log shp_log_*/pgw_log_* — tanpa REVOKE,
--     repo tidak punya role app terpisah); updated_at beku, deleted_at selalu NULL.
CREATE TABLE IF NOT EXISTS ecom_ledger_poin (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id             uuid NOT NULL DEFAULT gen_random_uuid(),
  id_ecom_member        bigint NOT NULL,
  id_ecom_pesanan_web   bigint,                    -- NULL bila referensi non-pesanan (registrasi/koreksi/hangus)
  tipe                  enum_tipe_poin_ecom NOT NULL,
  jumlah                integer NOT NULL CHECK (jumlah > 0),      -- selalu positif; arah dari tipe (D-07)
  saldo_setelah         integer NOT NULL CHECK (saldo_setelah >= 0),
  referensi             varchar(150) NOT NULL,    -- nomor WO / 'registrasi' / 'koreksi' / 'hangus-YYYYMMDD' / 'refund-<WO>'
  id_core_users_aktor   bigint,                   -- aktor KOREKSI CS; NULL = sistem (pola mockup memb_point_transactions)
  catatan               varchar(300),
  waktu                 timestamptz NOT NULL DEFAULT now(),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),  -- beku (append-only)
  deleted_at            timestamptz,                          -- selalu NULL (append-only)
  CONSTRAINT uq_ecom_ledger_poin_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_ledger_poin_koreksi CHECK (tipe <> 'KOREKSI' OR catatan IS NOT NULL),
  CONSTRAINT fk_ecom_ledger_poin_member  FOREIGN KEY (id_ecom_member) REFERENCES ecom_member (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_ledger_poin_pesanan FOREIGN KEY (id_ecom_pesanan_web) REFERENCES ecom_pesanan_web (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_ledger_poin_aktor   FOREIGN KEY (id_core_users_aktor) REFERENCES core_users (id) ON DELETE SET NULL
);

COMMENT ON COLUMN ecom_ledger_poin.referensi IS
  'pengembalian poin saat refund = mutasi EARN baru referensi refund-<WO> (order REFUND tak pernah EARN WO asli — tidak bentrok uq_mutasi); kasus ambigu = KOREKSI + catatan (kartu §6.2)';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_ledger_poin_mutasi
  ON ecom_ledger_poin (id_ecom_member, tipe, referensi) WHERE tipe <> 'KOREKSI';
CREATE INDEX IF NOT EXISTS ix_ecom_ledger_poin_member_waktu
  ON ecom_ledger_poin (id_ecom_member, waktu);
CREATE INDEX IF NOT EXISTS ix_ecom_ledger_poin_pesanan
  ON ecom_ledger_poin (id_ecom_pesanan_web);

-- -----------------------------------------------------------------------------
-- §4 TABEL TRANSAKSI + LINE
-- -----------------------------------------------------------------------------

-- 4.1 ecom_flash_sale — kampanye harga terjadwal [TRANSAKSI] (F18, ECOM-BR15)
CREATE TABLE IF NOT EXISTS ecom_flash_sale (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor            varchar(150) NOT NULL,           -- FLS-{yyyyMM} via core_sequences doc_name 'flash_sale'
  judul            varchar(100) NOT NULL,
  periode_mulai    timestamptz NOT NULL,
  periode_berakhir timestamptz NOT NULL,
  status           enum_status_flash_ecom NOT NULL DEFAULT 'DRAFT',
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_ecom_flash_sale_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_ecom_flash_sale_nomor UNIQUE (nomor),
  CONSTRAINT ck_ecom_flash_sale_periode CHECK (periode_berakhir > periode_mulai)
);

COMMENT ON COLUMN ecom_flash_sale.nomor IS 'nomor dokumen STD-08 anti-race; counter ditanam podman/seed-ecom-core.sql (doc_name flash_sale)';
COMMENT ON COLUMN ecom_flash_sale.periode_mulai IS 'timestamptz — kampanye berjalan per jam (D-14); satu katalog boleh di >=2 kampanye, overlap ditangani CFG-ECOM-08 app-side';

CREATE INDEX IF NOT EXISTS ix_ecom_flash_sale_berjalan
  ON ecom_flash_sale (periode_mulai, periode_berakhir) WHERE status = 'BERJALAN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_flash_sale_sweeper_mulai
  ON ecom_flash_sale (periode_mulai) WHERE status = 'TERJADWAL' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_flash_sale_sweeper_berakhir
  ON ecom_flash_sale (periode_berakhir) WHERE status = 'BERJALAN' AND deleted_at IS NULL;

-- 4.2 ecom_flash_sale_item — baris kampanye [LINE] (tanpa entity_id/version)
CREATE TABLE IF NOT EXISTS ecom_flash_sale_item (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_ecom_flash_sale     bigint NOT NULL,
  id_ecom_katalog_online bigint NOT NULL,
  harga_flash            numeric(18,4) NOT NULL CHECK (harga_flash > 0),
  kuota                  integer NOT NULL CHECK (kuota >= 1),       -- kuota kampanye TERPISAH dari stok (BR15)
  terpakai               integer NOT NULL DEFAULT 0 CHECK (terpakai >= 0),  -- decrement atomik saat DIBAYAR; kembali saat refund
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT ck_ecom_flash_sale_item_kuota CHECK (terpakai <= kuota),
  CONSTRAINT fk_ecom_flash_sale_item_flash   FOREIGN KEY (id_ecom_flash_sale)
    REFERENCES ecom_flash_sale (id) ON DELETE CASCADE,             -- LINE murni
  CONSTRAINT fk_ecom_flash_sale_item_katalog FOREIGN KEY (id_ecom_katalog_online)
    REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_flash_sale_item_hidup
  ON ecom_flash_sale_item (id_ecom_flash_sale, id_ecom_katalog_online) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_flash_sale_item_katalog
  ON ecom_flash_sale_item (id_ecom_katalog_online);

-- -----------------------------------------------------------------------------
-- §5 ALTER TABEL EXISTING (aditif; idempoten — IF NOT EXISTS + guard pg_constraint)
-- -----------------------------------------------------------------------------

-- 5.1 ecom_pesanan_web — kolom v3: member, fee, kirim SHP, bukti, resi, terima
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS id_ecom_member bigint;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS sesi_perangkat varchar(150);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS biaya_layanan numeric(18,4) NOT NULL DEFAULT 0 CHECK (biaya_layanan >= 0);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS poin_ditukar integer NOT NULL DEFAULT 0 CHECK (poin_ditukar >= 0);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS kalkulasi_ref varchar(150);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS opsi_ref varchar(150);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS opsi_kirim jsonb;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS id_core_files_bukti bigint;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS resi varchar(150);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS tracking_link varchar(300);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS order_kurir_ref varchar(150);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS sumber_resi enum_sumber_resi_ecom;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS waktu_diterima timestamptz;

COMMENT ON COLUMN ecom_pesanan_web.id_ecom_member IS 'pemilik member (tamu = NULL); klaim F13 idempoten: UPDATE WHERE sesi_perangkat=X AND id_ecom_member IS NULL (BR16)';
COMMENT ON COLUMN ecom_pesanan_web.sesi_perangkat IS 'device key sesi saat pesanan dibuat; TETAP tersimpan pasca-klaim = penanda anti-klaim-ganda (BR16)';
COMMENT ON COLUMN ecom_pesanan_web.biaya_layanan IS 'beku nilai yang dibayar pembeli (BR05 recompute server-side); gateway IKUT_VENDOR = fee per ketentuan pgw_channel patch 49 (D-15); CFG-ECOM-12';
COMMENT ON COLUMN ecom_pesanan_web.kalkulasi_ref IS 'referensi kalkulasi ongkir SHP (M55) untuk bentuk order M58 — varchar Tier B tanpa FK (D-08/D-13); NULL bila tanpa ongkir';
COMMENT ON COLUMN ecom_pesanan_web.opsi_ref IS 'referensi opsi tarif terpilih SHP (kanonik kurir:layanan) — pasangan wajib dengan kalkulasi_ref (CHECK)';
COMMENT ON COLUMN ecom_pesanan_web.opsi_kirim IS 'snapshot display kurir/layanan/eta/harga final saat checkout — murni tampilan, tidak difilter/di-join';
COMMENT ON COLUMN ecom_pesanan_web.id_core_files_bukti IS 'bukti transfer manual jalur CFG-ECOM-02 (BR17: wajib sebelum verifikasi CS); M15 jenis PEMBAYARAN sekali';
COMMENT ON COLUMN ecom_pesanan_web.resi IS 'waybill dari M56 atau input manual back-office ter-audit — BR13 tanpa resi fiktif';
COMMENT ON COLUMN ecom_pesanan_web.order_kurir_ref IS 'nomor order pengiriman SHP (SHO-…) tanpa FK (D-13); reverse lookup SHP via sumber=ECOM_OUTBOUND + ref_permintaan = nomor WO';
COMMENT ON COLUMN ecom_pesanan_web.kedaluwarsa_bayar_at IS 'jendela waktu bayar CFG-ECOM-13 (DITIMPA D-11: semula dikaitkan CFG-ECOM-10); juga expiry intent M50';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_pesanan_web_member') THEN
    ALTER TABLE ecom_pesanan_web ADD CONSTRAINT fk_ecom_pesanan_web_member
      FOREIGN KEY (id_ecom_member) REFERENCES ecom_member (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_pesanan_web_bukti') THEN
    ALTER TABLE ecom_pesanan_web ADD CONSTRAINT fk_ecom_pesanan_web_bukti
      FOREIGN KEY (id_core_files_bukti) REFERENCES core_files (id) ON DELETE RESTRICT;
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_pesanan_web_resi') THEN
    ALTER TABLE ecom_pesanan_web ADD CONSTRAINT ck_ecom_pesanan_web_resi
      CHECK (resi IS NULL OR sumber_resi IS NOT NULL);
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_pesanan_web_kalkulasi') THEN
    ALTER TABLE ecom_pesanan_web ADD CONSTRAINT ck_ecom_pesanan_web_kalkulasi
      CHECK ((kalkulasi_ref IS NULL) = (opsi_ref IS NULL));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_sesi
  ON ecom_pesanan_web (sesi_perangkat) WHERE sesi_perangkat IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_member
  ON ecom_pesanan_web (id_ecom_member) WHERE id_ecom_member IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_kalkulasi
  ON ecom_pesanan_web (kalkulasi_ref) WHERE kalkulasi_ref IS NOT NULL AND deleted_at IS NULL;

-- 5.2 ecom_kupon — kupon personal per member (kartu v3 pemilik_personal)
ALTER TABLE ecom_kupon ADD COLUMN IF NOT EXISTS id_ecom_member bigint;
COMMENT ON COLUMN ecom_kupon.id_ecom_member IS 'kupon personal milik member (F04: bukan miliknya ditolak); NULL = kupon publik';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_kupon_member') THEN
    ALTER TABLE ecom_kupon ADD CONSTRAINT fk_ecom_kupon_member
      FOREIGN KEY (id_ecom_member) REFERENCES ecom_member (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_ecom_kupon_member
  ON ecom_kupon (id_ecom_member) WHERE id_ecom_member IS NOT NULL AND deleted_at IS NULL;

-- 5.3 ecom_keranjang — pemilik member (koeksisten sesi/pelanggan; tidak menggeser)
ALTER TABLE ecom_keranjang ADD COLUMN IF NOT EXISTS id_ecom_member bigint;
COMMENT ON COLUMN ecom_keranjang.id_ecom_member IS 'pemilik member pra-bayar; id_sls_pelanggan DIPERTAHANKAN (terisi bila master pelanggan sudah dibuat — koeksisten)';
ALTER TABLE ecom_keranjang DROP CONSTRAINT IF EXISTS ck_ecom_keranjang_pemilik;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_keranjang_pemilik') THEN
    ALTER TABLE ecom_keranjang ADD CONSTRAINT ck_ecom_keranjang_pemilik
      CHECK (sesi_ref IS NOT NULL OR id_sls_pelanggan IS NOT NULL OR id_ecom_member IS NOT NULL);
  END IF;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_keranjang_member') THEN
    ALTER TABLE ecom_keranjang ADD CONSTRAINT fk_ecom_keranjang_member
      FOREIGN KEY (id_ecom_member) REFERENCES ecom_member (id) ON DELETE RESTRICT;
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_keranjang_member_aktif
  ON ecom_keranjang (id_ecom_member)
  WHERE status = 'AKTIF' AND id_ecom_member IS NOT NULL AND deleted_at IS NULL;

-- 5.4 ecom_keranjang_item — SKU varian INV + snapshot label (D-02; tabel kosong — DROP+CREATE aman)
ALTER TABLE ecom_keranjang_item ADD COLUMN IF NOT EXISTS id_inv_produk bigint;
ALTER TABLE ecom_keranjang_item ADD COLUMN IF NOT EXISTS varian_label varchar(300);
COMMENT ON COLUMN ecom_keranjang_item.id_inv_produk IS 'SKU varian INV terpilih (inv_produk dengan id_inv_produk_induk NOT NULL); NULL = produk sederhana; validasi qty per SKU via ATP M22';
COMMENT ON COLUMN ecom_keranjang_item.varian_label IS 'snapshot label kombinasi dari inv_produk.kunci_kombinasi (bucket 300 = sumber)';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_keranjang_item_sku') THEN
    ALTER TABLE ecom_keranjang_item ADD CONSTRAINT fk_ecom_keranjang_item_sku
      FOREIGN KEY (id_inv_produk) REFERENCES inv_produk (id) ON DELETE RESTRICT;
  END IF;
END $$;
DROP INDEX IF EXISTS uq_ecom_keranjang_item_hidup;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_keranjang_item_hidup
  ON ecom_keranjang_item (id_ecom_keranjang, id_ecom_katalog_online, COALESCE(id_inv_produk, 0))
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_keranjang_item_sku
  ON ecom_keranjang_item (id_inv_produk);

-- 5.5 ecom_pesanan_web_item — snapshot deal per varian (tabel kosong — DROP+CREATE aman)
ALTER TABLE ecom_pesanan_web_item ADD COLUMN IF NOT EXISTS id_inv_produk bigint;
ALTER TABLE ecom_pesanan_web_item ADD COLUMN IF NOT EXISTS varian_label varchar(300);
COMMENT ON COLUMN ecom_pesanan_web_item.id_inv_produk IS 'SKU varian INV terpilih saat checkout (snapshot deal); NULL = produk sederhana; berat M55 per item = inv_produk.berat_gram';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_pesanan_item_sku') THEN
    ALTER TABLE ecom_pesanan_web_item ADD CONSTRAINT fk_ecom_pesanan_item_sku
      FOREIGN KEY (id_inv_produk) REFERENCES inv_produk (id) ON DELETE RESTRICT;
  END IF;
END $$;
DROP INDEX IF EXISTS uq_ecom_pesanan_item_hidup;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_pesanan_item_hidup
  ON ecom_pesanan_web_item (id_ecom_pesanan_web, id_ecom_katalog_online, COALESCE(id_inv_produk, 0))
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_item_sku
  ON ecom_pesanan_web_item (id_inv_produk);

-- -----------------------------------------------------------------------------
-- §6 TRIGGER updated_at — 9 tabel baru (set_updated_at() milik baseline 01-core)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ecom_member','ecom_member_alamat','ecom_banner',
    'ecom_member_sesi','ecom_member_token','ecom_wishlist',
    'ecom_ledger_poin','ecom_flash_sale','ecom_flash_sale_item'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I;', t, t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- §7 SEED (rencana — dijalankan TERPISAH setelah patch commit; pola seed-shp-core.sql)
-- -----------------------------------------------------------------------------
-- podman/seed-ecom-core.sql:
--   1. guard pg_enum nilai 'ecom' (RAISE EXCEPTION bila patch 36 belum commit);
--   2. INSERT core_modules key='ecom' ON CONFLICT (key) DO NOTHING;
--   3. core_sequences: web_order WO-{yyyy} pad 4, kupon KPN-{yyyy} pad 4,
--      flash_sale FLS-{yyyyMM} pad 4 — ON CONFLICT (id_core_modules, doc_name) DO NOTHING;
--   4. core_module_configs CFG-ECOM-01..15 (CFG-ECOM-12 = 'IKUT_VENDOR' — D-15;
--      CFG-ECOM-14 = satu param_key value_type json) ON CONFLICT DO NOTHING;
--   5. preset fee channel demo SIMULATOR (qris PERSEN 0.7, bank_transfer NOMINAL 4000)
--      milik seed pgw — bukan scope seed ecom.
-- data bisnis (member/katalog/flash/banner demo) menyusul di seed transaksi.

-- -----------------------------------------------------------------------------
-- §8 VERIFIKASI (komentar introspeksi)
-- -----------------------------------------------------------------------------
-- SELECT count(*) FROM pg_tables WHERE tablename LIKE 'ecom\_%';        -- harap 16 (7 + 9)
-- SELECT count(*) FROM pg_type   WHERE typname LIKE 'enum\_%_ecom';     -- harap 16 (9 + 7)
-- SELECT count(*) FROM pg_trigger WHERE tgrelid::regclass::text LIKE 'ecom\_%'
--   AND tgname LIKE 'trg\_%_updated_at';                                -- harap 16 (7 + 9)
-- SELECT count(*) FROM pg_constraint WHERE conname IN (
--   'fk_ecom_pesanan_web_member','fk_ecom_pesanan_web_bukti','ck_ecom_pesanan_web_resi',
--   'ck_ecom_pesanan_web_kalkulasi','fk_ecom_kupon_member','ck_ecom_keranjang_pemilik',
--   'fk_ecom_keranjang_member','fk_ecom_keranjang_item_sku','fk_ecom_pesanan_item_sku'); -- harap 9
-- SELECT column_name FROM information_schema.columns WHERE table_name='ecom_pesanan_web'
--   AND column_name IN ('biaya_layanan','poin_ditukar','kalkulasi_ref','opsi_ref',
--   'opsi_kirim','id_core_files_bukti','resi','tracking_link','order_kurir_ref',
--   'sumber_resi','waktu_diterima','id_ecom_member','sesi_perangkat');   -- harap 13

-- PATCH 50-ecom-portal.sql selesai.
