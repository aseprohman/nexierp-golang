-- +goose Up
-- Porting 1:1 dari ddl/32-fnb-keputusan.sql (urutan & isi sama, tanpa perubahan)

-- =============================================================================
-- PATCH DDL 32-fnb-keputusan.sql — Keputusan pemilik bisnis FNB (2026-11-07)
-- Domain   : OdooLikeERP · Modul FNB
-- Pemicu   : keputusan pemilik bisnis FNB 2026-11-07 — menerjemahkan jawaban
--            Q-04/Q-05/Q-06/Q-07/Q-08/Q-10 `docs/analisa-modul-fnb-v4.md`
--            (kartu klasifikasi disetujui — patch hanya menerjemahkannya):
--              Q-04 ambang review waste        → `fnb_produksi` nilai_bahan/
--                 nilai_waste (snapshot Σ harga_biaya INV saat SELESAI) +
--                 `waste_review_*` + CFG-FNB-13 (preset PS1=0/PS2=5/PS3=2)
--              Q-05 role bisnis FNB            → podman/seed-fnb-rbac.sql
--                 (BUKAN patch DDL — fnb_manajer / fnb_dapur)
--              Q-06 pengajuan batal produksi   → `fnb_produksi` trio pengajuan
--                 batal (alasan/penugasan/waktu) + backfill semantik lama
--              Q-07 penugasan stasiun KDS      → `fnb_stasiun_penugasan`
--                 [JUNCTION] user ↔ kategori stasiun
--              Q-08/Q-10 buka-86 otomatis      → `fnb_menu.habis_86_otomatis`
--                 (reaksi otomatis kekurangan bahan) + CFG-FNB-12/14
-- Kartu    : fnb_produksi [TRANSAKSI] · fnb_menu [MASTER] (FNB) ·
--            fnb_stasiun_penugasan [JUNCTION] (FNB) · core_module_configs
--            [CONFIG] (CORE) — ALTER/CREATE/seed, tanpa perubahan pemilik.
-- Pola     : ddl/24-fnb.sql (enum DO-guard, ALTER IF NOT EXISTS, trio + trigger
--            `set_updated_at`, seed insert-if-missing) + template entri patch
--            32 ACC/SLS di docs/MIGRASI-BACKEND.md.
-- Idempoten: enum DO-block duplicate_object; ADD COLUMN IF NOT EXISTS; FK
--            DO-guard constraint; index IF NOT EXISTS; backfill UPDATE guarded
--            (`alasan_pengajuan_batal IS NULL` — sekali jalan, re-run 0 baris);
--            seed ON CONFLICT DO NOTHING. Aman dijalankan berulang.
-- Jebakan   : enum legacy `fnb_*` lowercase (fnb_station, fnb_production_status,
--            …) era runtime lama MATI — sengaja tidak disentuh; CFG dine-in
--            warisan CFG-FNB-04/05/06/11 yang ada di live tidak disentuh;
--            `fnb_produksi`/`fnb_menu` sudah punya `version` + trio audit —
--            tidak dibuat ulang.
-- Prasyarat: ddl/01-core.sql (set_updated_at, core_users, core_modules,
--            core_module_configs, core_config_value_type) + ddl/24-fnb.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- a) ENUM — status review waste (Q-04): TIDAK_PERLU = nilai batal/waste di bawah
--    ambang CFG-FNB-13 (atau fitur nonaktif); MENUNGGU_REVIEW = diajukan;
--    DITERIMA/DITOLAK = keputusan Manajer FNB (SoD BR03, gate role di kode).
-- -----------------------------------------------------------------------------
-- +goose StatementBegin
DO $$ BEGIN
  CREATE TYPE enum_fnb_waste_review AS ENUM ('TIDAK_PERLU', 'MENUNGGU_REVIEW', 'DITERIMA', 'DITOLAK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- b) [TRANSAKSI] fnb_produksi — ALTER: pengajuan batal (Q-06), snapshot nilai
--    bahan/waste + alur review waste (Q-04)
-- -----------------------------------------------------------------------------

-- Trio pengajuan batal (Q-06): semantik lama menumpuk pengajuan pada `alasan`
-- dokumen terjalankan; kini dipisah ke kolom sendiri agar `alasan` kembali
-- murni alasan keputusan BATAL (STD-06) dan pengajuan punya penugasan + waktu.
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS alasan_pengajuan_batal varchar(200);
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS id_core_users_pengajuan_batal bigint;
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS pengajuan_batal_at timestamptz;

-- Snapshot nilai (Q-04): Σ harga_biaya INV bahan saat status SELESAI — beku di
-- waktu transaksi (aturan snapshot arsitektur-database; bukan query live),
-- dasar perbandingan ambang % CFG-FNB-13 tanpa join modul INV.
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS nilai_bahan numeric(18, 2);
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS nilai_waste numeric(18, 2);

-- Alur review waste (Q-04): default TIDAK_PERLU (batal/waste di bawah ambang);
-- MENUNGGU_REVIEW = masuk antrean persetujuan Manajer FNB — partial index
-- updated_at DESC melayani layar antrean review (query panas repo).
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS waste_review_status enum_fnb_waste_review NOT NULL DEFAULT 'TIDAK_PERLU';
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS waste_review_oleh bigint;
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS waste_review_at timestamptz;
ALTER TABLE fnb_produksi ADD COLUMN IF NOT EXISTS waste_review_catatan varchar(200);

-- FK aktor pengajuan/reviewer — SET NULL: riwayat dokumen harus selamat bila
-- user dihapus (pola aktor fnb_produksi di 24-fnb).
-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE fnb_produksi ADD CONSTRAINT fk_fnb_produksi_pengajuan_batal_user
    FOREIGN KEY (id_core_users_pengajuan_batal) REFERENCES core_users (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


-- +goose StatementBegin
DO $$ BEGIN
  ALTER TABLE fnb_produksi ADD CONSTRAINT fk_fnb_produksi_waste_review_user
    FOREIGN KEY (waste_review_oleh) REFERENCES core_users (id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- +goose StatementEnd


CREATE INDEX IF NOT EXISTS ix_fnb_produksi_waste_review
  ON fnb_produksi (updated_at DESC) WHERE waste_review_status = 'MENUNGGU_REVIEW';

-- Backfill semantik lama (SEKALI jalan — guarded oleh target IS NULL): alasan
-- terisi saat status DIJALANKAN/SELESAI = pengajuan batal yang menunggu
-- keputusan (Q-06). Re-run menjangkau 0 baris — idempoten.
UPDATE fnb_produksi
SET alasan_pengajuan_batal     = alasan,
    id_core_users_pengajuan_batal = id_core_users,
    pengajuan_batal_at         = updated_at
WHERE status IN ('DIJALANKAN', 'SELESAI')
  AND alasan IS NOT NULL
  AND alasan_pengajuan_batal IS NULL;

-- -----------------------------------------------------------------------------
-- c) [MASTER] fnb_menu — ALTER: penanda 86 reaksi otomatis (Q-08/Q-10)
-- -----------------------------------------------------------------------------

-- true = status HABIS_86 AKIBAT reaksi otomatis kekurangan bahan (CFG-FNB-02
-- TANDAI_86/BLOKIR) — bukan tanda tangan manual; pembukaan kembali oleh job
-- buka-86 otomatis (CFG-FNB-03=OTOMATIS + CFG-FNB-14) atau keputusan Manajer.
ALTER TABLE fnb_menu ADD COLUMN IF NOT EXISTS habis_86_otomatis boolean NOT NULL DEFAULT false;

-- -----------------------------------------------------------------------------
-- d) [JUNCTION] fnb_stasiun_penugasan — user ↔ kategori stasiun (Q-07)
-- -----------------------------------------------------------------------------

-- [JUNCTION] penugasan staf per kategori stasiun KDS — dasar penegakan BR12
-- (`BUKAN_STASIUN_ANDA`) saat CFG-FNB-10 = PER_STASIUN.
-- Klasifikasi: JUNCTION murni N:M user ↔ kategori_stasiun (unique pasangan),
-- tanpa kolom bisnis di luar trio/version.
-- JUSTIFIKASI kategori_stasiun = nilai varchar, BUKAN baris master: kategori
-- stasiun adalah label operasional bebas yang membagi antrian dapur (grill/bar/
-- cold/…) — muncul sebagai snapshot varchar di fnb_resep & fnb_produksi_baris
-- (24-fnb); menjadikannya master row memaksa sinkronisasi snapshot lama tiap
-- penambahan label dan memberi tabel yatim tanpa manajemen. Kardinalitas
-- kecil, dikontrol CHECK panjang 1..50; referensi integritas yang penting
-- (user) tetap FK sungguhan ON DELETE CASCADE (penugasan = data ikutan user,
-- bukan riwayat).
CREATE TABLE IF NOT EXISTS fnb_stasiun_penugasan (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entity_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  id_core_users    bigint NOT NULL,                     -- staf dapur (FK CASCADE — ikut user)
  kategori_stasiun varchar(50) NOT NULL,                -- label bebas; bukan master (lihat justifikasi)
  version          integer NOT NULL DEFAULT 1,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz,
  CONSTRAINT uq_fnb_stasiun_entity_id UNIQUE (entity_id),
  CONSTRAINT fk_fnb_stasiun_user FOREIGN KEY (id_core_users)
    REFERENCES core_users (id) ON DELETE CASCADE,
  CONSTRAINT ck_fnb_stasiun_kategori CHECK (length(kategori_stasiun) BETWEEN 1 AND 50)
);

-- Unique pasangan reusable setelah soft delete — partial (pola partial unique repo).
CREATE UNIQUE INDEX IF NOT EXISTS uq_fnb_stasiun_user
  ON fnb_stasiun_penugasan (id_core_users, kategori_stasiun) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_fnb_stasiun_user
  ON fnb_stasiun_penugasan (id_core_users) WHERE deleted_at IS NULL;

-- Trigger updated_at — sama dengan tabel fnb lain (24-fnb §5).
-- +goose StatementBegin
DO $$ BEGIN
  DROP TRIGGER IF EXISTS trg_fnb_stasiun_penugasan_updated_at ON fnb_stasiun_penugasan;
  CREATE TRIGGER trg_fnb_stasiun_penugasan_updated_at BEFORE UPDATE ON fnb_stasiun_penugasan
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
END $$;
-- +goose StatementEnd


-- -----------------------------------------------------------------------------
-- e) [CONFIG] core_module_configs (pemilik CORE) — seed 3 param number (Q-04/
--    Q-08/Q-10), insert-if-missing; nilai existing TIDAK ditimpa (BR06).
--    Warisan dine-in CFG-FNB-04/05/06/11 di live sengaja tidak disentuh.
-- -----------------------------------------------------------------------------
INSERT INTO core_module_configs (id_core_modules, param_key, param_value, value_type, description)
SELECT m.id, v.param_key, v.param_value, v.value_type::core_config_value_type, v.description
FROM core_modules m
CROSS JOIN (VALUES
  ('CFG-FNB-12', '12', 'number',
   'Target waktu masak GLOBAL menit (CFG-FNB-09=GLOBAL)'),
  ('CFG-FNB-13', '5', 'number',
   'Ambang review waste % nilai bahan per dokumen (0 = nonaktif; arah preset PS1=0/PS2=5/PS3=2)'),
  ('CFG-FNB-14', '15', 'number',
   'Interval menit job buka-86 otomatis (0 = mati)')
) AS v(param_key, param_value, value_type, description)
WHERE m.key = 'fnb'
ON CONFLICT (id_core_modules, param_key) DO NOTHING;

-- =============================================================================
-- STATUS KONTRAK DOKUMEN — analisa v4 revisi keputusan (2026-11-07):
-- Q-04 (review waste + snapshot nilai), Q-05 (role fnb_manajer/fnb_dapur via
-- podman/seed-fnb-rbac.sql — SETELAH podman/scanroutes.sh; approval hanya
-- manajer ditegakkan server-side gate role, bukan granularity SET), Q-06
-- (pengajuan batal + backfill), Q-07 (junction penugasan stasiun), Q-08
-- (habis_86_otomatis), Q-10 (CFG-FNB-14 job buka-86 otomatis) TERTUTUP di
-- lapis struktur; penegakan perilakunya (job, gate role, pengecekan stasiun)
-- milik lapisan kode. Kontrak dokumen analisa-modul-fnb-v4.md sah sejak patch
-- ini terpasang; kolom/pertanyaan lain di v4 tetap berlaku apa adanya.
-- =============================================================================
-- PATCH 32-fnb-keputusan.sql selesai.
