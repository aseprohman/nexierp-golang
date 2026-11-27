-- =============================================================================
-- PATCH DDL 26-outbox-idempoten.sql — Dedupe outbox (G-29 P2, lapis DB)
-- Domain   : OdooLikeERP — core_outbox_events
-- Sumber   : audit gap G-29 — enqueue tanpa dedupe; retry sesi DITAHAN
--            membuat baris outbox duplikat (key hidup di payload->_key).
-- Pasangan : pre-check di apps/api OutboxService.enqueue (lapis app) +
--            relay worker apps/worker (G-01).
-- Idempoten: aman dijalankan berulang (dedupe dulu, lalu CREATE UNIQUE INDEX
--            IF NOT EXISTS — run kedua menghapus 0 baris dan no-op).
-- =============================================================================

-- 1) Bersihkan duplikat lama (akibat G-29) — pasangan (topic, _key) sama yang
--    masih hidup (pending/delivered): simpan yang TERLAMA (id terkecil),
--    hapus sisanya. Outbox = antrean event, bukan audit; duplikat adalah bug
--    yang diperbaiki patch ini. Baris 'failed' tidak disentuh.
DELETE FROM core_outbox_events a
USING core_outbox_events b
WHERE a.id > b.id
  AND a.topic = b.topic
  AND a.payload ? '_key'
  AND b.payload ? '_key'
  AND a.payload->>'_key' = b.payload->>'_key'
  AND a.status IN ('pending', 'delivered')
  AND b.status IN ('pending', 'delivered');

-- 2) Unik parsial: maks. satu baris hidup per (topic, key). Kolom `key` tidak
--    ada di tabel — key disimpan payload->_key, karenanya ekspresi
--    coalesce(payload->>'_key',''). Baris 'failed' TIDAK diliput index ini —
--    emit ulang event yang gagal tetap sah.
CREATE UNIQUE INDEX IF NOT EXISTS uq_outbox_topic_key_pending
  ON core_outbox_events (topic, coalesce(payload->>'_key', ''))
  WHERE status IN ('pending', 'delivered') AND payload ? '_key';
