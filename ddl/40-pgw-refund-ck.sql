-- =============================================================================
-- PATCH DDL 40-pgw-refund-ck.sql — Perbaikan check penyetuju refund PGW
-- Domain   : OdooLikeERP (single tenant konfigurable, Profil Skala PS1/PS2/PS3)
-- Sumber   : temuan audit P0 — ck_pgw_refund_penyetuju memblokir refund
--            DIAJUKAN: insert (penyetuju_sistem=false, penyetuju NULL) ditolak
--            23514, sehingga pengajuan refund manual (di bawah/di atas ambang
--            CFG-PGW-02) tidak pernah bisa masuk (F10 macet total).
-- Tanggal  : 2026-11-07
-- Prasyarat: baseline CORE 01-core + 39-pgw.sql (tabel pgw_refund live).
-- Isi      : ganti definisi ck_pgw_refund_penyetuju.
-- Makna    : keputusan refund datang dari SISTEM (webhook auto-refund,
--            penyetuju_sistem=true) ATAU dari MANUSIA (id_core_users_penyetuju
--            terisi); larang keduanya sekaligus (satu keputusan, satu aktor).
--            Lama: (penyetuju_sistem OR penyetuju IS NOT NULL) — memaksa
--            status DIAJUKAN (belum ada keputusan) memenuhi salah satu,
--            kontradiksi dengan default penyetuju_sistem=false.
--            Baru: NOT (penyetuju_sistem AND penyetuju IS NOT NULL).
-- Idempoten: DO-block cek pg_get_constraintdef — definisi baru → skip;
--            definisi lama/berbeda → DROP + ADD (nama constraint tetap).
-- Catatan  : data lama valid secara semantik — baris DIAJUKAN yang lolos ck
--            lama tidak ada (ck lama menolaknya); baris SELESAI (id 9) memenuhi
--            definisi baru (penyetuju terisi, penyetuju_sistem=false).
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM pg_constraint
  WHERE conname = 'ck_pgw_refund_penyetuju'
    AND conrelid = 'pgw_refund'::regclass;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'ck_pgw_refund_penyetuju tidak ditemukan di pgw_refund — baseline 39-pgw.sql belum dipasang?';
  END IF;

  IF v_def = 'CHECK ((NOT (penyetuju_sistem AND (id_core_users_penyetuju IS NOT NULL))))' THEN
    RAISE NOTICE 'ck_pgw_refund_penyetuju sudah definisi baru — skip';
  ELSE
    ALTER TABLE pgw_refund DROP CONSTRAINT ck_pgw_refund_penyetuju;
    ALTER TABLE pgw_refund ADD CONSTRAINT ck_pgw_refund_penyetuju
      CHECK (NOT (penyetuju_sistem AND id_core_users_penyetuju IS NOT NULL));
    RAISE NOTICE 'ck_pgw_refund_penyetuju diganti: lama (%) → baru', v_def;
  END IF;
END $$;

COMMIT;

-- VERIFIKASI (0 baris = lolos)
-- Baris apa pun tidak boleh melanggar definisi baru
SELECT 'pelanggar ck baru' AS cek, id, nomor, status
FROM pgw_refund
WHERE penyetuju_sistem AND id_core_users_penyetuju IS NOT NULL;
-- Definisi terpasang (harus: CHECK (NOT (penyetuju_sistem AND (id_core_users_penyetuju IS NOT NULL))))
SELECT conname, pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conrelid = 'pgw_refund'::regclass AND conname = 'ck_pgw_refund_penyetuju';

-- ddl/40-pgw-refund-ck.sql selesai.
