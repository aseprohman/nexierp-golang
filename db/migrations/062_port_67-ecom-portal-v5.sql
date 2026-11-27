-- +goose Up
-- Porting 1:1 dari ddl/67-ecom-portal-v5.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 67-ecom-portal-v5.sql — ECOM PORTAL v5 (kelengkapan storefront)
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : gap-analysis storefront mockup /Storages/www/mockup-ecommerce
--            (metadata halaman = acuan data & fitur; temuan P1–P3, 2026-11-17)
--            atas blueprint docs/analisa-modul-ecom-v3.md.
-- Kartu    : docs/arsitektur-database-ecom.md §7 (gerbang arsitektur-database,
--            keputusan D-21…D-33).
-- Tanggal  : 2026-11-17
-- Prasyarat: ddl/36-ecom.sql + 50-ecom-portal.sql + 65-ecom-portal-v4.sql
--            (16 tabel ecom_*); baseline CORE (core_users, core_files,
--            core_kelurahan, enum_status_aktif, core_sequences,
--            core_module_configs, fungsi set_updated_at).
-- Isi      : 3 tabel baru — 1 MASTER (ecom_kategori — kategori storefront),
--            1 TRANSAKSI (ecom_pengajuan_refund — lifecycle pengajuan refund
--            member, penomoran RF-{yyyyMM}) + 1 LOG/EVENT
--            (ecom_pesanan_web_riwayat — timeline kejadian pesanan) + 3 enum
--            baru (badge katalog, status refund, kejadian pesanan; status
--            kategori REUSE enum_status_aktif CORE — pola 66-wa) + ALTER 5
--            tabel eksisting (kategori FK + badge + pre-order + readmodel
--            kartu + deskripsi/highlights → katalog_online; nilai_maks +
--            terikat produk → kupon; label → member_alamat; deskripsi prose
--            text → review; DP pre-order + destinasi terstruktur →
--            pesanan_web) + trigger set_updated_at 3 tabel baru + seed
--            core_sequences 'pengajuan_refund'.
-- Integrasi: FK keluar — core_kelurahan (RESTRICT NULL, destinasi kirim),
--            core_files (RESTRICT NULL, bukti DP), core_users (SET NULL,
--            aktor keputusan refund & aktor kejadian riwayat); FK dalam
--            modul — ecom_kategori (RESTRICT), ecom_pesanan_web (RESTRICT),
--            ecom_member (RESTRICT), ecom_katalog_online (RESTRICT — kupon
--            terikat produk). Harga per kombinasi varian TANPA DDL — dijawab
--            PRICELIST SLS (`sls_pricelist_aturan.jenis_target='PRODUK'`
--            menunjuk baris SKU varian inv_produk; D-32).
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            fail-loud (pola 66), CREATE TABLE/INDEX IF NOT EXISTS, ALTER ADD
--            COLUMN IF NOT EXISTS, FK/CHECK guard pg_constraint, ALTER TYPE
--            text no-op saat diulang, ADD CONSTRAINT … NOT VALID (baris lama
--            tidak dibalikkan — VALIDATE menyusul setelah seed v2 mengisi
--            kategori), seed ON CONFLICT DO NOTHING.
-- Catatan  : readmodel kartu produk (terjual/rating/ulasan cache) = kolom
--            denormalisasi di katalog_online — sumber kebenaran
--            ecom_pesanan_web_item (pesanan DIBAYAR…SELESAI) & ecom_review
--            TAYANG; jalur sinkron app-side saat transisi status + sweep
--            rekonsiliasi (D-30). Seed TIDAK mengarang nilai cache (tabel
--            transaksi kosong → 0/NULL — Fase 4 seed-realistik).
-- Penerapan: podman exec -i nexierp-postgres psql -U nexierp -d nexierp \
--             -v ON_ERROR_STOP=1 < ddl/67-ecom-portal-v5.sql  (jalankan 2×)
--           Dry-run: { echo 'BEGIN;'; cat ddl/67-ecom-portal-v5.sql;
--             echo 'ROLLBACK;'; } | podman exec -i nexierp-postgres psql …
-- =============================================================================

BEGIN;

-- =============================================================================
-- §1 ENUM — 3 kosakata baru (fail-loud: bila tipe sudah ada dengan isi berbeda
--    dari mirror Drizzle schema/ecom.ts → EXCEPTION; pola 66-wa)
-- =============================================================================

-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_badge_katalog_ecom AS ENUM ('TERLARIS','OFFICIAL','BARU');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_badge_katalog_ecom')
     IS DISTINCT FROM ARRAY['TERLARIS','OFFICIAL','BARU']::text[] THEN
    RAISE EXCEPTION 'PATCH 67-ecom: enum_badge_katalog_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_refund_ecom AS ENUM ('DIAJUKAN','DISETUJUI','DITOLAK','DIBAYAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_refund_ecom')
     IS DISTINCT FROM ARRAY['DIAJUKAN','DISETUJUI','DITOLAK','DIBAYAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 67-ecom: enum_status_refund_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kejadian_pesanan_ecom AS ENUM ('DIBUAT','DIBAYAR','DIPROSES','DIKEMAS',
    'DIKIRIM','SELESAI','DIBATALKAN','KEDALUWARSA','REFUND_DIAJUKAN','REFUND_DISETUJUI',
    'REFUND_DITOLAK','REFUND_DIBAYAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kejadian_pesanan_ecom')
     IS DISTINCT FROM ARRAY['DIBUAT','DIBAYAR','DIPROSES','DIKEMAS','DIKIRIM','SELESAI',
       'DIBATALKAN','KEDALUWARSA','REFUND_DIAJUKAN','REFUND_DISETUJUI','REFUND_DITOLAK',
       'REFUND_DIBAYAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 67-ecom: enum_kejadian_pesanan_ecom kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- Status kategori REUSE enum_status_aktif CORE (AKTIF|NONAKTIF) — pola 66-wa
-- (persona/pengetahuan/aturan); tanpa CREATE TYPE di sini.

-- =============================================================================
-- §2 MASTER — ecom_kategori (kategori storefront: tile beranda, filter
--    katalog, breadcrumb, kolom footer — gap P1-1)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ecom_kategori (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id uuid NOT NULL,
  slug varchar(200) NOT NULL,
  nama varchar(100) NOT NULL,
  label_pendek varchar(50),
  deskripsi varchar(300),
  urutan integer NOT NULL DEFAULT 0,
  status enum_status_aktif NOT NULL DEFAULT 'AKTIF',
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT uq_ecom_kategori_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_ecom_kategori_urutan CHECK (urutan >= 0)
);

COMMENT ON TABLE ecom_kategori IS '[MASTER] kategori storefront milik ECOM — tile beranda, filter ?kategori=, breadcrumb, kolom footer (gap P1-1 mockup); datar tanpa induk (tile mockup datar — hierarki menyusul bila blueprint minta); product_count = COUNT katalog PUBLIK via ix_ecom_katalog_kategori (readmodel by query — D-31, tanpa kolom counter)';
COMMENT ON COLUMN ecom_kategori.slug IS 'kunci URL publik ?kategori=slug — unique di antara baris hidup (boleh dipakai ulang pasca soft-delete)';
COMMENT ON COLUMN ecom_kategori.nama IS 'label tampil tile/breadcrumb/footer (bucket 100)';
COMMENT ON COLUMN ecom_kategori.label_pendek IS 'label pendek chip navbar mobile (mockup short); NULL = pakai nama';
COMMENT ON COLUMN ecom_kategori.deskripsi IS 'keterangan singkat kategori (bucket 300)';
COMMENT ON COLUMN ecom_kategori.urutan IS 'urutan tampil tile beranda & chip navbar; 0 = default';
COMMENT ON COLUMN ecom_kategori.status IS 'AKTIF|NONAKTIF (enum_status_aktif CORE — reuse pola 66-wa); NONAKTIF = disembunyikan dari storefront';

COMMENT ON CONSTRAINT uq_ecom_kategori_entity_id ON ecom_kategori IS 'identitas entity dua-tier Tier A';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_kategori_slug_hidup
  ON ecom_kategori (slug)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_kategori_render
  ON ecom_kategori (urutan)
  WHERE status = 'AKTIF' AND deleted_at IS NULL;

-- =============================================================================
-- §3 ALTER ecom_katalog_online — kategori (P1-1), badge & pre-order (P2-5,
--    P1-3a), deskripsi prose + highlights (P2-6), readmodel kartu (P3 — D-30)
-- =============================================================================

ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS id_ecom_kategori bigint;
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS badge enum_badge_katalog_ecom;
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS pre_order boolean NOT NULL DEFAULT false;
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS catatan_pre_order varchar(300);
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS highlights jsonb;
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS terjual_cache integer NOT NULL DEFAULT 0;
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS rating_rata_cache numeric(3,2);
ALTER TABLE ecom_katalog_online ADD COLUMN IF NOT EXISTS ulasan_count_cache integer NOT NULL DEFAULT 0;

-- Deskripsi produk = prosa bebas panjangnya tak terprediksi → text (disiplin
-- tipe teks; mantan varchar(300) memotong konten sah). ALTER TYPE idempoten.
ALTER TABLE ecom_katalog_online ALTER COLUMN deskripsi TYPE text;

COMMENT ON COLUMN ecom_katalog_online.id_ecom_kategori IS 'kategori storefront (fk_ecom_katalog_kategori RESTRICT) — NULL sah untuk DRAFT/TERSEMBUNYI; wajib untuk PUBLIK (ck NOT VALID — baris lama tidak dibalikkan, write baru ditegakkan)';
COMMENT ON COLUMN ecom_katalog_online.badge IS 'badge marketing kartu produk: TERLARIS|OFFICIAL|BARU (enum_badge_katalog_ecom); NULL = tanpa badge (mockup product.badge)';
COMMENT ON COLUMN ecom_katalog_online.pre_order IS 'chip Pre-Order di kartu & detail (mockup); pesanan pre-order berjalan di jalur DP ecom_pesanan_web.nilai_dp (D-23)';
COMMENT ON COLUMN ecom_katalog_online.catatan_pre_order IS 'catatan chip pre-order ("dipesan dulu, dikirim setelah tersedia") — bucket 300';
COMMENT ON COLUMN ecom_katalog_online.highlights IS 'bullet spesifikasi singkat detail produk (mockup highlights[]) — jsonb array-of-string TIDAK difilter/di-join (aturan jsonb)';
COMMENT ON COLUMN ecom_katalog_online.deskripsi IS 'deskripsi prosa bebas detail produk — text (patch 67: mantan varchar(300))';
COMMENT ON COLUMN ecom_katalog_online.terjual_cache IS '[READMODEL] Σ qty ecom_pesanan_web_item ber-pesanan status DIBAYAR/DIPROSES/DIKIRIM/SELESAI — sumber kebenaran item pesanan; sinkron app saat transisi status + sweep rekonsiliasi (D-30); bukan sumber kebenaran';
COMMENT ON COLUMN ecom_katalog_online.rating_rata_cache IS '[READMODEL] AVG(rating) ecom_review status TAYANG (2 desimal); NULL = belum ada ulasan tayang; sinkron sama D-30';
COMMENT ON COLUMN ecom_katalog_online.ulasan_count_cache IS '[READMODEL] COUNT ecom_review status TAYANG; sinkron sama D-30';

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_katalog_kategori') THEN
    ALTER TABLE ecom_katalog_online
      ADD CONSTRAINT fk_ecom_katalog_kategori FOREIGN KEY (id_ecom_kategori)
      REFERENCES ecom_kategori (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- Wajib kategori bila tayang — NOT VALID: potret seed lama (PUBLIK tanpa
-- kategori) tidak dibalikkan; write PUBLIK baru ditegakkan DB; VALIDATE
-- dijalankan SETELAH seed v2 mengisi kategori (di luar patch ini).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_katalog_kategori_publik') THEN
    ALTER TABLE ecom_katalog_online
      ADD CONSTRAINT ck_ecom_katalog_kategori_publik
      CHECK (status <> 'PUBLIK' OR id_ecom_kategori IS NOT NULL) NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_katalog_readmodel') THEN
    ALTER TABLE ecom_katalog_online
      ADD CONSTRAINT ck_ecom_katalog_readmodel CHECK (
        terjual_cache >= 0 AND ulasan_count_cache >= 0
        AND (rating_rata_cache IS NULL OR rating_rata_cache BETWEEN 1 AND 5)
      );
  END IF;
END $$;
-- +goose StatementEnd


-- COUNT kategori (readmodel product_count — D-31) + filter katalog server-side.
CREATE INDEX IF NOT EXISTS ix_ecom_katalog_kategori
  ON ecom_katalog_online (id_ecom_kategori)
  WHERE status = 'PUBLIK' AND deleted_at IS NULL;

-- =============================================================================
-- §4 ALTER ecom_kupon — batas maks potongan PERSEN + terikat produk (P2-8)
-- =============================================================================

ALTER TABLE ecom_kupon ADD COLUMN IF NOT EXISTS nilai_maks numeric(18,4);
ALTER TABLE ecom_kupon ADD COLUMN IF NOT EXISTS id_ecom_katalog_online bigint;

COMMENT ON COLUMN ecom_kupon.nilai_maks IS 'batas maksimal potongan kupon PERSEN (mockup percent_cut.max; NULL = tanpa batas) — juga sah diabaikan utk NOMINAL/GRATIS_ONGKIR';
COMMENT ON COLUMN ecom_kupon.id_ecom_katalog_online IS 'kupon terikat SATU produk katalog (mockup for_product; NULL = berlaku umum) (fk_ecom_kupon_produk RESTRICT — katalog tak pernah hard-delete STD-02)';

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_kupon_produk') THEN
    ALTER TABLE ecom_kupon
      ADD CONSTRAINT fk_ecom_kupon_produk FOREIGN KEY (id_ecom_katalog_online)
      REFERENCES ecom_katalog_online (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_kupon_nilai_maks') THEN
    ALTER TABLE ecom_kupon
      ADD CONSTRAINT ck_ecom_kupon_nilai_maks
      CHECK (nilai_maks IS NULL OR nilai_maks >= 0);
  END IF;
END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_ecom_kupon_produk
  ON ecom_kupon (id_ecom_katalog_online)
  WHERE id_ecom_katalog_online IS NOT NULL AND deleted_at IS NULL;

-- =============================================================================
-- §5 ALTER ecom_member_alamat + ecom_review — label alamat (P2-7), prose
--    ulasan/balasan (P2-6)
-- =============================================================================

ALTER TABLE ecom_member_alamat ADD COLUMN IF NOT EXISTS label varchar(50);

COMMENT ON COLUMN ecom_member_alamat.label IS 'label alamat (mockup "Simpan sebagai": Rumah/Kantor/Kos/Lainnya — bebas); NULL = tanpa label, FE fallback "Alamat"';

ALTER TABLE ecom_review ALTER COLUMN isi TYPE text;
ALTER TABLE ecom_review ALTER COLUMN balasan TYPE text;

COMMENT ON COLUMN ecom_review.isi IS 'isi ulasan prosa bebas — text (patch 67: mantan varchar(300)); minim panjang diegakkan app-side';
COMMENT ON COLUMN ecom_review.balasan IS 'balasan pengelola prosa bebas — text (patch 67: mantan varchar(300))';

-- =============================================================================
-- §6 TRANSAKSI + LOG/EVENT — ecom_pengajuan_refund (P1-4) +
--    ecom_pesanan_web_riwayat (P1-2)
-- =============================================================================

CREATE TABLE IF NOT EXISTS ecom_pengajuan_refund (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id uuid NOT NULL,
  nomor varchar(150) NOT NULL,
  id_ecom_pesanan_web bigint NOT NULL,
  id_ecom_member bigint NOT NULL,
  alasan varchar(300) NOT NULL,
  item_alasan varchar(300),
  nilai numeric(18,4) NOT NULL DEFAULT 0,
  status enum_status_refund_ecom NOT NULL DEFAULT 'DIAJUKAN',
  alasan_keputusan varchar(300),
  id_core_users_keputusan bigint,
  waktu_keputusan timestamptz,
  referensi_bayar varchar(150),
  waktu_dibayar timestamptz,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT uq_ecom_pengajuan_refund_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ecom_pengajuan_refund_pesanan FOREIGN KEY (id_ecom_pesanan_web)
    REFERENCES ecom_pesanan_web (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_pengajuan_refund_member FOREIGN KEY (id_ecom_member)
    REFERENCES ecom_member (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_pengajuan_refund_aktor FOREIGN KEY (id_core_users_keputusan)
    REFERENCES core_users (id) ON DELETE SET NULL,
  CONSTRAINT ck_ecom_pengajuan_refund_nilai CHECK (nilai >= 0),
  CONSTRAINT ck_ecom_pengajuan_refund_alasan_tolak
    CHECK (status <> 'DITOLAK' OR alasan_keputusan IS NOT NULL),
  CONSTRAINT ck_ecom_pengajuan_refund_keputusan
    CHECK (status = 'DIAJUKAN' OR (id_core_users_keputusan IS NOT NULL AND waktu_keputusan IS NOT NULL)),
  CONSTRAINT ck_ecom_pengajuan_refund_dibayar
    CHECK (status <> 'DIBAYAR' OR (referensi_bayar IS NOT NULL AND waktu_dibayar IS NOT NULL))
);

COMMENT ON TABLE ecom_pengajuan_refund IS '[TRANSAKSI] pengajuan refund oleh member (gap P1-4 mockup ord_refunds): DIAJUKAN → DISETUJUI/DITOLAK (Pengelola) → DIBAYAR (M15 ACC jenis REFUND). Outcome fisik tetap ecom_pesanan_web.status=REFUND + nilai_refund — pengajuan ini buku sebab-akibat alur member; min 10 char alasan diegakkan app-side';
COMMENT ON COLUMN ecom_pengajuan_refund.nomor IS 'RF-{yyyyMM} — core_sequences doc_name pengajuan_refund (STD-08 anti-race); unique global';
COMMENT ON COLUMN ecom_pengajuan_refund.alasan IS 'alasan pengajuan member (mockup reason min 10 char — panjang diegakkan app-side); bucket 300';
COMMENT ON COLUMN ecom_pengajuan_refund.item_alasan IS 'item bermasalah (mockup item_reason, opsional); bucket 300';
COMMENT ON COLUMN ecom_pengajuan_refund.nilai IS 'nominal diajukan — DIHITUNG SERVER (mockup: penuh; bukan input member); refund fee vendor tidak dikembalikan (D-15)';
COMMENT ON COLUMN ecom_pengajuan_refund.alasan_keputusan IS 'catatan Pengelola saat DISETUJUI/DITOLAK (wajib bila DITOLAK — ck)';
COMMENT ON COLUMN ecom_pengajuan_refund.referensi_bayar IS 'ref pembayaran M15 ACC (mockup paid_ref) — wajib bila DIBAYAR (ck)';
COMMENT ON CONSTRAINT uq_ecom_pengajuan_refund_entity_id ON ecom_pengajuan_refund IS 'identitas entity dua-tier Tier A';

CREATE UNIQUE INDEX IF NOT EXISTS uq_ecom_pengajuan_refund_aktif
  ON ecom_pengajuan_refund (id_ecom_pesanan_web)
  WHERE status = 'DIAJUKAN' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pengajuan_refund_pesanan
  ON ecom_pengajuan_refund (id_ecom_pesanan_web);
CREATE INDEX IF NOT EXISTS ix_ecom_pengajuan_refund_member
  ON ecom_pengajuan_refund (id_ecom_member)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ecom_pengajuan_refund_antrian
  ON ecom_pengajuan_refund (status)
  WHERE status = 'DIAJUKAN' AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS ecom_pesanan_web_riwayat (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id uuid NOT NULL,
  id_ecom_pesanan_web bigint NOT NULL,
  kejadian enum_kejadian_pesanan_ecom NOT NULL,
  catatan varchar(300),
  id_core_users_aktor bigint,
  waktu timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  CONSTRAINT uq_ecom_pesanan_web_riwayat_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_ecom_pesanan_web_riwayat_pesanan FOREIGN KEY (id_ecom_pesanan_web)
    REFERENCES ecom_pesanan_web (id) ON DELETE RESTRICT,
  CONSTRAINT fk_ecom_pesanan_web_riwayat_aktor FOREIGN KEY (id_core_users_aktor)
    REFERENCES core_users (id) ON DELETE SET NULL
);

COMMENT ON TABLE ecom_pesanan_web_riwayat IS '[LOG/EVENT] timeline kejadian pesanan storefront (gap P1-2 mockup order events) — append-only ditegakkan app-layer (pola ecom_ledger_poin; updated_at beku, deleted_at selalu NULL); label display diturunkan app dari kejadian, catatan = narasi tambahan';
COMMENT ON COLUMN ecom_pesanan_web_riwayat.kejadian IS 'DIBUAT/DIBAYAR/DIPROSES/DIKEMAS/DIKIRIM/SELESAI/DIBATALKAN/KEDALUWARSA + siklus REFUND_* (enum_kejadian_pesanan_ecom)';
COMMENT ON COLUMN ecom_pesanan_web_riwayat.id_core_users_aktor IS 'aktor manusia (SET NULL); NULL = sistem/job/webhook (sweeper M50/M56, konfirmasi gateway)';
COMMENT ON COLUMN ecom_pesanan_web_riwayat.waktu IS 'waktu kejadian (bukan created_at — jejak backfill/audit diperbolehkan lewat insert eksplisit)';
COMMENT ON CONSTRAINT uq_ecom_pesanan_web_riwayat_entity_id ON ecom_pesanan_web_riwayat IS 'identitas entity dua-tier Tier A';

CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_riwayat_pesanan
  ON ecom_pesanan_web_riwayat (id_ecom_pesanan_web, waktu);

-- =============================================================================
-- §7 ALTER ecom_pesanan_web — DP pre-order (P1-3b) + destinasi terstruktur
--    (P2-9)
-- =============================================================================

ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS nilai_dp numeric(18,4);
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS id_core_files_bukti_dp bigint;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS waktu_dp_verifikasi timestamptz;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS id_core_kelurahan_kirim bigint;
ALTER TABLE ecom_pesanan_web ADD COLUMN IF NOT EXISTS kode_pos_kirim varchar(50);

COMMENT ON COLUMN ecom_pesanan_web.nilai_dp IS 'uang muka pre-order (mockup dp_amount; NULL = bukan alur DP); pelunasan = nilai_total − nilai_dp; verifikasi DP memakai jalur bukti_dp + waktu_dp_verifikasi, pelunasan tetap jalur bukti/status_bayar eksisting (D-23)';
COMMENT ON COLUMN ecom_pesanan_web.id_core_files_bukti_dp IS 'bukti transfer DP (fk_ecom_pesanan_web_bukti_dp RESTRICT) — resemantik: id_core_files_bukti eksisting = bukti pelunasan/pembayaran penuh (mockup kind dp/pelunasan)';
COMMENT ON COLUMN ecom_pesanan_web.waktu_dp_verifikasi IS 'waktu DP terverifikasi Pengelola ("DP TERVERIFIKASI" mockup); aktor = id_core_users_verifikasi eksisting (pemakai bersama dua verifikasi — jejak penuh di audit)';
COMMENT ON COLUMN ecom_pesanan_web.id_core_kelurahan_kirim IS 'destinasi terstruktur snapshot kirim (fk_ecom_pesanan_web_kelurahan_kirim RESTRICT; NULL sah untuk baris lama) — wajib diisi app saat checkout baru (member & tamu kaskade) agar tarif ulang/pelacakan M55/M58 punya destinasi kanonik (D-29)';
COMMENT ON COLUMN ecom_pesanan_web.kode_pos_kirim IS 'snapshot kode pos kirim (NULL fallback baca dari kelurahan)';

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_pesanan_web_bukti_dp') THEN
    ALTER TABLE ecom_pesanan_web
      ADD CONSTRAINT fk_ecom_pesanan_web_bukti_dp FOREIGN KEY (id_core_files_bukti_dp)
      REFERENCES core_files (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_ecom_pesanan_web_kelurahan_kirim') THEN
    ALTER TABLE ecom_pesanan_web
      ADD CONSTRAINT fk_ecom_pesanan_web_kelurahan_kirim FOREIGN KEY (id_core_kelurahan_kirim)
      REFERENCES core_kelurahan (id) ON DELETE RESTRICT;
  END IF;
END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ck_ecom_pesanan_web_dp') THEN
    ALTER TABLE ecom_pesanan_web
      ADD CONSTRAINT ck_ecom_pesanan_web_dp
      CHECK (nilai_dp IS NULL OR (nilai_dp >= 0 AND nilai_dp <= nilai_total));
  END IF;
END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_ecom_pesanan_web_kelurahan_kirim
  ON ecom_pesanan_web (id_core_kelurahan_kirim)
  WHERE id_core_kelurahan_kirim IS NOT NULL;

-- =============================================================================
-- §8 TRIGGER + SEQUENCE — trigger set_updated_at 3 tabel baru (fungsi milik
--    baseline CORE 01-core, TIDAK dibuat ulang) + seed penomoran
--    pengajuan_refund (fail-soft: tanpa registry = NOTICE, ditanam
--    podman/seed-ecom-core.sql)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY['ecom_kategori','ecom_pengajuan_refund','ecom_pesanan_web_riwayat'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- Penomoran RF-{yyyyMM} (TRANSAKSI berkode STD-08). Registry belum ada =
-- fail-soft (pola 36 §0 — nilai enum 'ecom' tidak dipakai di sini, hanya id
-- numerik; bila row registry belum ada SELECT kosong = 0 baris).
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, 'pengajuan_refund', 'RF-{yyyyMM}', 0, 4
FROM core_modules m
WHERE m.key::text = 'ecom'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
                 WHERE m.key::text = 'ecom' AND s.doc_name = 'pengajuan_refund') THEN
    RAISE NOTICE 'PATCH 67-ecom: sequence pengajuan_refund belum tertanam — registry core_modules key=''ecom'' belum ada; ditanam via podman/seed-ecom-core.sql';
  END IF;
END $$;
-- +goose StatementEnd


COMMIT;

-- =============================================================================
-- §9 VERIFIKASI (komentar introspeksi — jalankan manual SETELAH apply,
--    BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 9.1 Tabel & kolom baru:
-- \d+ ecom_kategori
-- \d+ ecom_pengajuan_refund
-- \d+ ecom_pesanan_web_riwayat
-- SELECT column_name, data_type, character_maximum_length, is_nullable
--   FROM information_schema.columns
--   WHERE table_name IN ('ecom_katalog_online','ecom_kupon','ecom_member_alamat',
--                        'ecom_review','ecom_pesanan_web')
--     AND column_name IN ('id_ecom_kategori','badge','pre_order','catatan_pre_order',
--       'highlights','terjual_cache','rating_rata_cache','ulasan_count_cache',
--       'nilai_maks','id_ecom_katalog_online','label','nilai_dp',
--       'id_core_files_bukti_dp','waktu_dp_verifikasi','id_core_kelurahan_kirim',
--       'kode_pos_kirim')
--   ORDER BY table_name, column_name;
-- -- deskripsi/isi/balasan → data_type 'text':
-- SELECT table_name, column_name, data_type FROM information_schema.columns
--   WHERE table_name IN ('ecom_katalog_online','ecom_review')
--     AND column_name IN ('deskripsi','isi','balasan');
--
-- -- 9.2 Constraint NOT VALID (kategori publik):
-- SELECT conname, convalidated FROM pg_constraint
--   WHERE conrelid = 'ecom_katalog_online'::regclass
--     AND conname IN ('fk_ecom_katalog_kategori','ck_ecom_katalog_kategori_publik',
--                     'ck_ecom_katalog_readmodel');
--
-- -- 9.3 Trigger & sequence:
-- SELECT tgname FROM pg_trigger WHERE tgrelid = 'ecom_kategori'::regclass AND NOT tgisinternal;
-- SELECT s.doc_name, s.prefix FROM core_sequences s JOIN core_modules m ON m.id=s.id_core_modules
--   WHERE m.key::text='ecom' ORDER BY s.doc_name;   -- kupon, flash_sale, pengajuan_refund, web_order
--
-- -- 9.4 Dry-run idempoten (2×): hasil identik, 0 error, INSERT sequence 0 baris pada run ke-2.
