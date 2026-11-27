-- +goose Up
-- Porting 1:1 dari ddl/37-rsv.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 37-rsv.sql — Modul RSV (RESERVATION / RESERVASI) rekonstruksi
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : docs/analisa-modul-rsv-v2.md (blueprint v2 ter-audit — kartu entitas
--            §4.1, peta status §4.2, BR RSV-BR01…BR13, CFG-RSV-01…10) +
--            docs/audit-analisa-rsv-v2.md + docs/peta-modul.md §3/§4/§5
--            (M13/M21/M32/M33/M34/M35/M37). Kepemilikan peta-modul §4:
--            reservasi, jadwal_ketersediaan (slot & kamar embedded — A-03).
-- Kartu    : docs/arsitektur-database-rsv.md (keputusan desain §1, kartu
--            klasifikasi §2, gate §3, registry & penomoran §4, mismatch §5).
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core (core_users, core_files, fungsi
--            set_updated_at, core_modules key='book' [live id 8,
--            enabled=true — WARISAN generasi lama, tetap dipakai],
--            core_sequences) + FNB 24 (fnb_meja — kolom reserved
--            id_rsv_reservasi PP-03 "FK oleh patch RSV") + SLS 28
--            (sls_pelanggan) + ACC 30 (acc_pembayaran — kolom reserved
--            id_rsv_reservasi PP-03).
-- Isi      : 2 tabel rsv_* — 1 MASTER (jadwal_ketersediaan: kalender slot per
--            sumber×tanggal×jam; slot & kamar embedded, bukan entitas terpisah)
--            + 1 TRANSAKSI (reservasi) + 5 enum enum_*_rsv + trigger
--            set_updated_at 2 tabel + FK setoran/integrasi NOT VALID
--            (fnb_meja.id_rsv_reservasi, acc_pembayaran.id_rsv_reservasi) +
--            ensure core_sequences module book (2 legacy WARISAN tidak
--            disentuh + 1 doc_name baru).
-- Integrasi: FK keluar HANYA ke tabel live — id_fnb_meja (SET NULL + snapshot
--            meja_ref/meja_nama beku; M33/M13/M37), id_sls_pelanggan (SET NULL,
--            fallback tamu M32), id_core_users_setuju_overbook (SET NULL,
--            BR01). TANPA FK ke acc_pembayaran (jejak deposit berpaut balik
--            via acc_pembayaran.id_rsv_reservasi — FK setoran dihubungkan di
--            sini) dan DILARANG FK ke ecom_* (M34/M35 hanya kontrak; idempoten
--            via ref_web varchar). Deposit online M53/M52 = status_deposit.
-- Registry : kode modul analisa RSV ↔ key DB core_modules key='book' (analog
--            CORE↔'system') — guard fail-loud RAISE EXCEPTION bila belum ada.
-- Penomoran: doc_name legacy 'reservation' (RSV-2026, live counter 909) &
--            'payment' (PAY-2026, live counter 907) = WARISAN generasi lama —
--            JANGAN disentuh, JANGAN diturunkan (DO NOTHING menang). Keputusan
--            kartu §4.2: nomor reservasi modul ini memakai doc_name BARU
--            'reservasi' prefix 'RSV/{yyyy}' padding 4 — prefix legacy adalah
--            prefix ter-render (tahun membeku, tidak year-roll, menyimpang
--            konvensi template {yyyy}) sehingga konservatif = doc_name baru
--            dengan format slash yang tidak mungkin bertabrakan nomor legacy.
-- Idempoten: aman dijalankan berulang — enum DO-block duplicate_object
--            (fail-loud bila kosakata menyimpang), CREATE TABLE IF NOT EXISTS,
--            FK/check bernama eksplisit di-guard pg_constraint, CREATE INDEX
--            IF NOT EXISTS, trigger DO-block DROP+CREATE, sequences ON
--            CONFLICT (id_core_modules, doc_name) DO NOTHING (counter tidak
--            pernah diturunkan).
-- Catatan  : tidak ada tabel LINE (pola LINE hr tidak terpakai) dan tidak ada
--            tabel hold/session-like (hold time = kebijakan CFG-RSV-03 yang
--            dihitung job auto-release BR07; hold booking online = baris
--            DRAFT — BR13; anti dobel-kunci slot BR11 via version + kapasitas).
--            CFG-RSV-01…10 hidup di core_module_configs (pemilik CORE) —
--            seed terpisah Fase 2, di luar patch ini. Uang numeric(18,4),
--            waktu kejadian timestamptz, tanggal murni date, jam slot time
--            (pola hr_jadwal_kerja), menit integer; tanpa jsonb & tanpa text.
-- =============================================================================

-- =============================================================================
-- §1 — ENUM (kosakata persis analisa v2 §4.1/§4.2; fail-loud bila sudah ada
--      dengan kosakata menyimpang)
-- =============================================================================

-- jenis sumber dipesan: MEJA rujukan FNB | SLOT | KAMAR milik RSV (§4.1; slot & kamar
-- embedded di jadwal_ketersediaan — A-03, bukan entitas terpisah)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_jenis_sumber_rsv AS ENUM ('MEJA','SLOT','KAMAR');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_jenis_sumber_rsv')
     IS DISTINCT FROM ARRAY['MEJA','SLOT','KAMAR']::text[] THEN
    RAISE EXCEPTION 'PATCH 37-rsv: enum_jenis_sumber_rsv kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- kanal reservasi (§4.1)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_kanal_reservasi_rsv AS ENUM ('WALK_IN','MANUAL','ONLINE');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_kanal_reservasi_rsv')
     IS DISTINCT FROM ARRAY['WALK_IN','MANUAL','ONLINE']::text[] THEN
    RAISE EXCEPTION 'PATCH 37-rsv: enum_kanal_reservasi_rsv kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- status reservasi — peta transisi §4.2 (terminal: SELESAI, NO_SHOW, DIBATALKAN)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_reservasi_rsv AS ENUM
    ('DRAFT','DIKONFIRMASI','CHECK_IN','SELESAI','NO_SHOW','DIBATALKAN');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_reservasi_rsv')
     IS DISTINCT FROM ARRAY['DRAFT','DIKONFIRMASI','CHECK_IN','SELESAI','NO_SHOW','DIBATALKAN']::text[] THEN
    RAISE EXCEPTION 'PATCH 37-rsv: enum_status_reservasi_rsv kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- status deposit pada reservasi — hanya berubah setelah konfirmasi ACC via M21 (BR02)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_deposit_rsv AS ENUM
    ('TIDAK_PERLU','MENUNGGU','TERBAYAR','SEBAGIAN_REFUND','DIREFUND','HANGUS');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_deposit_rsv')
     IS DISTINCT FROM ARRAY['TIDAK_PERLU','MENUNGGU','TERBAYAR','SEBAGIAN_REFUND','DIREFUND','HANGUS']::text[] THEN
    RAISE EXCEPTION 'PATCH 37-rsv: enum_status_deposit_rsv kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- status slot jadwal_ketersediaan — peta sekunder §4.2 (DILEPAS = transien hasil
-- auto-release BR07, kembali TERSEDIA)
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_status_slot_rsv AS ENUM
    ('TERSEDIA','DIPESAN_SEBAGIAN','DIPESAN_PENUH','DIBLOKIR','DILEPAS');
EXCEPTION WHEN duplicate_object THEN
  IF (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'enum_status_slot_rsv')
     IS DISTINCT FROM ARRAY['TERSEDIA','DIPESAN_SEBAGIAN','DIPESAN_PENUH','DIBLOKIR','DILEPAS']::text[] THEN
    RAISE EXCEPTION 'PATCH 37-rsv: enum_status_slot_rsv kosakata menyimpang dari mirror';
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §2 — TABEL (urutan dependensi FK; 2 entitas milik RSV — peta-modul §4)
-- =============================================================================

-- 2.1 rsv_jadwal_ketersediaan — [MASTER kalender operasional] — slot per
--     sumber×tanggal×jam (F02; slot & kamar embedded — A-03). Kapasitas_total =
--     kapasitas_orang; kapasitas_terpakai + status dikonsumsi reservasi (BR11
--     optimistic locking via version); MEJA membaca master fnb_meja (M33,
--     fallback manual tanpa pemetaan = NULL).
CREATE TABLE IF NOT EXISTS rsv_jadwal_ketersediaan (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  jenis_sumber           enum_jenis_sumber_rsv NOT NULL,   -- MEJA | SLOT | KAMAR (§4.1)
  kode_sumber            varchar(50) NOT NULL,      -- identitas sumber: MEJA = kode_meja M33
                                                    -- (snapshot saat slot dibentuk); SLOT/KAMAR = kode RSV
  nama_sumber            varchar(100),              -- label tampil kalender
  tanggal                date NOT NULL,             -- tanggal slot (kalender harian)
  waktu_mulai            time NOT NULL,             -- jam slot (jam operasional lokal — pola hr_jadwal_kerja)
  durasi_menit           integer NOT NULL CHECK (durasi_menit > 0),  -- CFG-RSV-09 per jenis sumber
  kapasitas_orang        integer NOT NULL CHECK (kapasitas_orang > 0),  -- kapasitas_total kartu §4.1
  kapasitas_terpakai     integer NOT NULL DEFAULT 0 CHECK (kapasitas_terpakai >= 0),
  id_fnb_meja            bigint,                    -- hanya utk MEJA (FK di bawah, SET NULL — meja
                                                    -- boleh dihapus FNB; slot & riwayat tetap)
  status                 enum_status_slot_rsv NOT NULL DEFAULT 'TERSEDIA',
  alasan_blokir          varchar(200),              -- wajib saat DIBLOKIR (CHECK di bawah)
  version                integer NOT NULL DEFAULT 1,  -- optimistic locking BR11 (anti dobel-kunci)
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_rsv_jadwal_entity_id UNIQUE (entity_id),
  CONSTRAINT ck_rsv_jadwal_meja_hanya_meja
    CHECK (id_fnb_meja IS NULL OR jenis_sumber = 'MEJA'),
  CONSTRAINT ck_rsv_jadwal_blokir_alasan
    CHECK (status <> 'DIBLOKIR' OR alasan_blokir IS NOT NULL)
);
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_rsv_jadwal_meja') THEN
    ALTER TABLE rsv_jadwal_ketersediaan ADD CONSTRAINT fk_rsv_jadwal_meja
      FOREIGN KEY (id_fnb_meja) REFERENCES fnb_meja (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- kunci slot hidup — "tidak ada slot overlap per sumber" (kriteria terima F02); overlap
-- antar jam mulai berbeda divalidasi app (durasi seragam per jenis — CFG-RSV-09)
CREATE UNIQUE INDEX IF NOT EXISTS uq_rsv_jadwal_slot_hidup
  ON rsv_jadwal_ketersediaan (jenis_sumber, kode_sumber, tanggal, waktu_mulai)
  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_rsv_jadwal_tanggal_status
  ON rsv_jadwal_ketersediaan (tanggal, status) WHERE deleted_at IS NULL;
-- publikasi slot online M34 — hanya ketersediaan nyata (IN-05)
CREATE INDEX IF NOT EXISTS ix_rsv_jadwal_tersedia
  ON rsv_jadwal_ketersediaan (tanggal)
  WHERE status = 'TERSEDIA' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_rsv_jadwal_meja
  ON rsv_jadwal_ketersediaan (id_fnb_meja) WHERE id_fnb_meja IS NOT NULL;

-- 2.2 rsv_reservasi — [TRANSAKSI] — pemesanan atas sumber dipesan + deposit + status
--     kunjungan (§4.1; lifecycle §4.2; nomor doc_name 'reservasi' prefix RSV/{yyyy})
CREATE TABLE IF NOT EXISTS rsv_reservasi (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id              uuid NOT NULL DEFAULT gen_random_uuid(),
  nomor                  varchar(150) NOT NULL,     -- unique GLOBAL (doc_name 'reservasi' — §4.2 header)
  jenis_sumber           enum_jenis_sumber_rsv NOT NULL,
  id_rsv_jadwal_ketersediaan bigint,                -- slot_ref (FK di bawah, SET NULL — snapshot
                                                    -- waktu di bawah menjaga riwayat; NULL = jalur
                                                    -- manual fallback M33 tanpa slot terbentuk)
  waktu_mulai            timestamptz NOT NULL,      -- snapshot waktu slot (beku sejak dibuat)
  durasi_menit           integer NOT NULL CHECK (durasi_menit > 0),  -- CFG-RSV-09
  jumlah_orang           integer NOT NULL CHECK (jumlah_orang > 0),
  id_fnb_meja            bigint,                    -- FK di bawah (SET NULL); snapshot beku di bawah
  meja_ref               varchar(50),               -- SNAPSHOT kode meja — persis payload M13/M37
                                                    -- 'meja_ref' (riwayat beku walau meja dihapus FNB)
  meja_nama              varchar(100),              -- SNAPSHOT nama meja (beku)
  id_sls_pelanggan       bigint,                    -- FK di bawah (SET NULL — M32); NULL = tamu
  nama_tamu              varchar(100),              -- identitas tamu non-profil (fallback M32/IN-03)
  telepon_tamu           varchar(50),               -- kontak manual utk reminder (fallback IN-03)
  kanal                  enum_kanal_reservasi_rsv NOT NULL DEFAULT 'MANUAL',
  status                 enum_status_reservasi_rsv NOT NULL DEFAULT 'DRAFT',
  status_deposit         enum_status_deposit_rsv NOT NULL DEFAULT 'TIDAK_PERLU',  -- BR02
  nilai_deposit          numeric(18,4),             -- nilai pemicu M21 (CFG-RSV-01/02); saldo resmi
                                                    -- hidup di acc_pembayaran (A-04 — tanpa FK keluar)
  overbook_disetujui     boolean NOT NULL DEFAULT false,  -- BR01 (CFG-RSV-07 + approval MO)
  id_core_users_setuju_overbook bigint,             -- aktor approval overbooking (FK di bawah)
  ref_web                varchar(150),              -- ECOM M35 (Should) — idempoten per ref_web;
                                                    -- TANPA FK ecom_* (tabel ecom belum ada)
  alasan_batal           varchar(300),              -- wajib app saat DIBATALKAN (STD-06/BR04)
  konfirmasi_at          timestamptz,               -- jejak transisi (lead time F08)
  checkin_at             timestamptz,               -- M13 dipicu utk MEJA (BR09)
  selesai_at             timestamptz,
  batal_at               timestamptz,
  catatan                varchar(300),
  version                integer NOT NULL DEFAULT 1,  -- STD-07 optimistic locking
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  deleted_at             timestamptz,
  CONSTRAINT uq_rsv_reservasi_entity_id UNIQUE (entity_id),
  CONSTRAINT uq_rsv_reservasi_nomor UNIQUE (nomor),
  CONSTRAINT ck_rsv_reservasi_identitas
    CHECK (id_sls_pelanggan IS NOT NULL OR nama_tamu IS NOT NULL),
  CONSTRAINT ck_rsv_reservasi_meja_hanya_meja
    CHECK (
      (id_fnb_meja IS NULL OR jenis_sumber = 'MEJA')
      AND (meja_ref IS NULL OR jenis_sumber = 'MEJA')
    ),
  CONSTRAINT ck_rsv_reservasi_overbook_aktor
    CHECK (overbook_disetujui = false OR id_core_users_setuju_overbook IS NOT NULL),
  CONSTRAINT ck_rsv_reservasi_nilai_deposit
    CHECK (nilai_deposit IS NULL OR nilai_deposit >= 0),
  CONSTRAINT ck_rsv_reservasi_selesai_setelah_checkin
    CHECK (selesai_at IS NULL OR checkin_at IS NULL OR selesai_at >= checkin_at)
);
-- kunci idempoten M35 — ref_web TIDAK boleh dipakai ulang walau baris soft-delete
-- (kriteria terima F09 "tidak ada booking ganda per ref_web")
CREATE UNIQUE INDEX IF NOT EXISTS uq_rsv_reservasi_ref_web
  ON rsv_reservasi (ref_web) WHERE ref_web IS NOT NULL;
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_rsv_reservasi_slot') THEN
    ALTER TABLE rsv_reservasi ADD CONSTRAINT fk_rsv_reservasi_slot
      FOREIGN KEY (id_rsv_jadwal_ketersediaan) REFERENCES rsv_jadwal_ketersediaan (id)
      ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_rsv_reservasi_meja') THEN
    ALTER TABLE rsv_reservasi ADD CONSTRAINT fk_rsv_reservasi_meja
      FOREIGN KEY (id_fnb_meja) REFERENCES fnb_meja (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_rsv_reservasi_pelanggan') THEN
    ALTER TABLE rsv_reservasi ADD CONSTRAINT fk_rsv_reservasi_pelanggan
      FOREIGN KEY (id_sls_pelanggan) REFERENCES sls_pelanggan (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_rsv_reservasi_overbook_aktor') THEN
    ALTER TABLE rsv_reservasi ADD CONSTRAINT fk_rsv_reservasi_overbook_aktor
      FOREIGN KEY (id_core_users_setuju_overbook) REFERENCES core_users (id) ON DELETE SET NULL;
  END IF;
END $$;
-- +goose StatementEnd

CREATE INDEX IF NOT EXISTS ix_rsv_reservasi_status_aktif
  ON rsv_reservasi (status)
  WHERE status IN ('DRAFT','DIKONFIRMASI') AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_rsv_reservasi_waktu_mulai
  ON rsv_reservasi (waktu_mulai);
CREATE INDEX IF NOT EXISTS ix_rsv_reservasi_slot
  ON rsv_reservasi (id_rsv_jadwal_ketersediaan) WHERE id_rsv_jadwal_ketersediaan IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_rsv_reservasi_meja
  ON rsv_reservasi (id_fnb_meja) WHERE id_fnb_meja IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_rsv_reservasi_pelanggan
  ON rsv_reservasi (id_sls_pelanggan) WHERE id_sls_pelanggan IS NOT NULL;

-- =============================================================================
-- §3 — FK SETORAN / INTEGRASI LINTAS MODUL (NOT VALID — pola 30-acc §5; kolom
--      reserved PP-03 di tabel FNB & ACC yang menunggu patch RSV ini)
-- =============================================================================

-- 3.1 fnb_meja.id_rsv_reservasi → rsv_reservasi(id) — kolom reserved 24-fnb.sql
--     ("RESERVED (PP-03) — FK oleh patch RSV"); kontrak M13: meja menunjuk reservasi
--     yang menguncinya saat check-in; unique hidup uq_fnb_meja_reservasi sudah ada
--     di sisi FNB. SET NULL: reservasi dihapus → kaitan meja lepas, riwayat meja
--     tetap. NOT VALID: baris lama tidak di-scan (live: 0 baris terisi).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_fnb_meja_rsv_reservasi') THEN
    ALTER TABLE fnb_meja ADD CONSTRAINT fk_fnb_meja_rsv_reservasi
      FOREIGN KEY (id_rsv_reservasi) REFERENCES rsv_reservasi (id)
      ON DELETE SET NULL NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


-- 3.2 acc_pembayaran.id_rsv_reservasi → rsv_reservasi(id) — kolom reserved
--     30-acc.sql ("reserved TANPA FK, RSV belum ada — PP-03"); kontrak M21:
--     jejak deposit/refund/penyesuaian berpaut balik ke reservasi (idempoten
--     trio jenis_sumber+entity_id_sumber milik ACC tetap berlaku). SET NULL +
--     NOT VALID (live: 0 baris terisi).
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_acc_byr_rsv_reservasi') THEN
    ALTER TABLE acc_pembayaran ADD CONSTRAINT fk_acc_byr_rsv_reservasi
      FOREIGN KEY (id_rsv_reservasi) REFERENCES rsv_reservasi (id)
      ON DELETE SET NULL NOT VALID;
  END IF;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §4 — TRIGGER updated_at (2 tabel rsv_* — satu blok DO; set_updated_at() milik
--      baseline CORE 01-core, TIDAK dibuat ulang di sini)
-- =============================================================================

-- +goose StatementBegin
DO $$
DECLARE v_t text;
BEGIN
  FOREACH v_t IN ARRAY ARRAY[
    'rsv_jadwal_ketersediaan','rsv_reservasi'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated_at ON %I', v_t, v_t);
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', v_t, v_t);
  END LOOP;
END $$;
-- +goose StatementEnd


-- =============================================================================
-- §5 — SEED PENOMORAN (idempoten — lolos restore-DB-segar; counter tidak pernah
--      diturunkan)
-- =============================================================================

-- 5.1 Guard fail-loud registry modul (pola ddl/30-acc.sql §8.1). Mapping eksplisit
--     kartu §4.1: kode modul analisa RSV ↔ key DB 'book' (live id 8, enabled=true —
--     WARISAN generasi lama yang tetap dipakai, analog CORE↔'system').
-- +goose StatementBegin
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM core_modules WHERE key = 'book') THEN
    RAISE EXCEPTION 'PATCH 37-rsv: registry core_modules key=''book'' belum ada — jalankan baseline CORE lebih dulu';
  END IF;
END $$;
-- +goose StatementEnd


-- 5.2 core_sequences ensure (module book) — 2 doc_name WARISAN generasi lama
--     (reservation RSV-2026 live counter 909; payment PAY-2026 live counter 907)
--     JANGAN disentuh — ON CONFLICT DO NOTHING menang di live; nilai current di
--     VALUES hanya berlaku bila barisnya hilang (restore segar) agar tidak pernah
--     menurunkan counter. doc_name BARU 'reservasi' prefix 'RSV/{yyyy}' (keputusan
--     kartu §4.2: prefix legacy ter-render RSV-2026 tidak year-roll & menyimpang
--     konvensi template {yyyy}; format slash baru tidak mungkin bertabrakan nomor
--     legacy). RSV tidak menerbitkan dokumen pembayaran (penomoran deposit milik
--     ACC via M21) — doc_name 'payment' legacy hanya dijaga, tidak dipakai modul ini.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, current_value, padding)
SELECT m.id, v.doc_name, v.prefix, v.cur, v.pad
FROM core_modules m
CROSS JOIN (VALUES
  ('reservation', 'RSV-2026',   909, 4),   -- WARISAN legacy (live 909) — DO NOTHING di situ
  ('payment',     'PAY-2026',   907, 4),   -- WARISAN legacy (live 907) — DO NOTHING di situ
  ('reservasi',   'RSV/{yyyy}', 0,   4)    -- BARU (nomor reservasi modul ini — kartu §4.2)
) AS v(doc_name, prefix, cur, pad)
WHERE m.key = 'book'
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- =============================================================================
-- §6 — VERIFIKASI (komentar introspeksi — jalankan manual setelah apply,
--      BUKAN bagian eksekusi patch)
-- =============================================================================
--
-- -- 6.1 Daftar tabel rsv_* (harap 2):
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public' AND table_name LIKE 'rsv\_%' ESCAPE '\'
-- ORDER BY table_name;
--
-- -- 6.2 Jumlah enum rsv (harap 5):
-- SELECT count(*) AS jumlah_enum_rsv
-- FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
-- WHERE t.typtype = 'e' AND t.typname LIKE 'enum\_%\_rsv' ESCAPE '\'
--   AND n.nspname = 'public';
--
-- -- 6.3 Baris sequences module book (harap 3 — legacy counter TIDAK berubah):
-- SELECT m.key, s.doc_name, s.prefix, s.current_value, s.padding
-- FROM core_sequences s JOIN core_modules m ON m.id = s.id_core_modules
-- WHERE m.key = 'book' ORDER BY s.doc_name;
--
-- -- 6.4 FK setoran terpasang (harap 2 baris):
-- SELECT conname, conrelid::regclass, pg_get_constraintdef(oid)
-- FROM pg_constraint
-- WHERE conname IN ('fk_fnb_meja_rsv_reservasi','fk_acc_byr_rsv_reservasi');
--
-- -- 6.5 Trigger set_updated_at pada tabel rsv (harap 2):
-- SELECT c.relname, t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
-- WHERE NOT t.tgisinternal AND c.relname LIKE 'rsv\_%' ESCAPE '\';
--
-- PATCH 37-rsv.sql selesai.
