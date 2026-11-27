-- Query kategori library core_media_categories (ddl/44) — pemilik core/storage.
-- Baris HIDUP = deleted_at IS NULL; hapus kategori = soft delete + file
-- terkait di-SET NULL ("Tanpa kategori") — aset TIDAK pernah ikut terhapus.

-- Daftar kategori HIDUP + jumlah file hidup per kategori (badge FE).
-- Tanpa filter modul (0) = semua (global NULL + milik modul apa pun).
-- name: ListKategori :many
SELECT k.*, count(f.id)::int AS jumlah_file
FROM core_media_categories k
LEFT JOIN core_files f
  ON f.id_core_media_categories = k.id AND f.deleted_at IS NULL
WHERE k.deleted_at IS NULL
  AND (sqlc.narg('id_core_modules')::bigint IS NULL OR k.id_core_modules = sqlc.narg('id_core_modules'))
GROUP BY k.id
ORDER BY k.nama ASC;

-- Simpan kategori baru (SELALU dalam tx create dari service).
-- name: InsertKategori :one
INSERT INTO core_media_categories (
  entity_id, id_core_modules, nama, keterangan
) VALUES (
  $1, $2, $3, $4
)
RETURNING *;

-- Kategori HIDUP + kunci baris (FOR UPDATE — ubah/hapus, optimistic lock).
-- name: GetKategoriHidupForUpdate :one
SELECT * FROM core_media_categories
WHERE id = $1 AND deleted_at IS NULL
LIMIT 1
FOR UPDATE;

-- Ubah kategori — field dibangun service (optimistic lock), repo eksekusi.
-- name: UpdateKategori :one
UPDATE core_media_categories
SET nama = $2, keterangan = $3, id_core_modules = $4, version = $5, updated_at = now()
WHERE id = $1
RETURNING *;

-- SOFT DELETE kategori — deleted_at=now(), version+1.
-- name: SoftDeleteKategori :exec
UPDATE core_media_categories
SET deleted_at = now(), version = $2, updated_at = now()
WHERE id = $1;

-- Detach file terkait (hapus kategori — ddl/44): core_files terkait
-- di-SET NULL → jadi "Tanpa kategori"; aset TIDAK pernah ikut terhapus.
-- name: DetachFilesFromKategori :exec
UPDATE core_files
SET id_core_media_categories = NULL, updated_at = now()
WHERE id_core_media_categories = $1;

-- Kategori ada & HIDUP (deleted_at IS NULL)?
-- name: KategoriHidupAda :one
SELECT id FROM core_media_categories
WHERE id = $1 AND deleted_at IS NULL
LIMIT 1;

-- Nama kategori sudah dipakai kategori HIDUP lain dalam lingkup modul yang
-- sama (NULL modul = lingkup global)? exclude_id = 0 berarti tanpa exclude.
-- name: KategoriNamaDipakai :one
SELECT id FROM core_media_categories
WHERE nama = $1
  AND deleted_at IS NULL
  AND (
    (sqlc.narg('id_core_modules')::bigint IS NULL AND id_core_modules IS NULL)
    OR id_core_modules = sqlc.narg('id_core_modules')
  )
  AND (sqlc.arg('exclude_id')::bigint = 0 OR id <> sqlc.arg('exclude_id'))
LIMIT 1;

-- Jumlah file HIDUP dalam satu kategori (badge FE, setelah update).
-- name: CountLiveFilesInKategori :one
SELECT count(*)::int AS total
FROM core_files
WHERE id_core_media_categories = $1 AND deleted_at IS NULL;
