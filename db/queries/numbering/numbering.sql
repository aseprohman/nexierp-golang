-- Numbering dokumen — padanan NumberingRepository NestJS (raw SQL VERBATIM,
-- DILARANG dikonversi bentuk lain). Pola anti-race: UPDATE dulu (jalur umum),
-- bila 0 baris seed-if-missing lalu UPDATE LAGI dalam statement BARU
-- (snapshot segar) — dua eksekusi diputuskan di service.

-- name: IncrementSequence :many
-- UPDATE current_value+1 — VERBATIM dari service lama. Kosong (0 baris) =
-- baris counter belum ada → service memutuskan seed + eksekusi ulang.
UPDATE core_sequences s
SET current_value = s.current_value + 1, updated_at = now()
FROM core_modules m
WHERE m.id = s.id_core_modules
  AND m.key = $1
  AND s.doc_name = $2
RETURNING s.current_value, s.prefix, s.padding;

-- name: SeedSequence :exec
-- Seed baris counter (idempoten) — VERBATIM dari service lama:
-- INSERT-if-missing ON CONFLICT (id_core_modules, doc_name) DO NOTHING.
INSERT INTO core_sequences (id_core_modules, doc_name, prefix, padding)
SELECT m.id, $2, $3, $4
FROM core_modules m
WHERE m.key = $1
ON CONFLICT (id_core_modules, doc_name) DO NOTHING;

-- name: FindModuleIdByKey :many
-- Natural key modul → id; kosong bila tidak terdaftar.
SELECT id
FROM core_modules
WHERE key = $1
LIMIT 1;
