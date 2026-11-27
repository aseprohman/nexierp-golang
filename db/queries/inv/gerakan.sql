-- Query fitur GERAKAN STOK modul INVENTORY — padanan repositories/operasi/
-- gerakan.repository.ts NestJS (+ repositori stok/recompute-saldo rawSQL yang
-- diport sebagai fungsi ekspor repository.RecomputeSaldoStok via exec, bukan
-- sqlc, agar rawSQL 1:1). Tabel: inv_gerakan_stok [LINE] +
-- inv_gerakan_header [TRANSAKSI] (patch 09), master inv_produk /
-- inv_kategori_produk / inv_lot_serial / inv_unit_ukur / inv_lokasi_stok,
-- lapisan FIFO inv_lapisan_biaya, readmodel inv_saldo_stok (READ ONLY),
-- konteks penyesuaian inv_penyesuaian_stok(+items) utk enrichment baris ADJ.
-- Disiplin: kolom EKSPLISIT; soft-delete `deleted_at IS NULL` mengikuti
-- sumber (muatJenisLokasi & updateHeaderById TANPA filter — verbatim Nest);
-- fragmen lokasi efektif D-48 = COALESCE(g.id_lokasi_*, h.id_lokasi_*).
-- CATATAN skema: ddl menandai inv_gerakan_stok.id_lokasi_* NOT NULL sementara
-- service Nest menyisipkan NULL (drizzle schema nullable — D-48); port tetap
-- menyisipkan NULL via sqlc.narg agar perilaku identik dua runtime.

-- ===========================================================================
-- BACA — list / view
-- ===========================================================================

-- name: ListGerakanIds :many
-- Halaman id baris gerakan (filter jenis/status/idProduk/idGudang/search);
-- status='TERBUKA' pseudo-filter worklist (NOT IN SELESAI/BATAL); idGudang =
-- gudang sumber ATAU tujuan (lokasi efektif D-48, INNER JOIN verbatim);
-- search ILIKE nomor dokumen. sort token kanonik ('' = default g.id ASC).
SELECT g.id
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
JOIN inv_lokasi_stok lok_sumber
     ON lok_sumber.id = COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)
JOIN inv_lokasi_stok lok_tujuan
     ON lok_tujuan.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)
WHERE g.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR h.jenis::text = sqlc.narg('jenis')::text)
  AND (
    sqlc.narg('status')::text IS NULL
    OR (sqlc.narg('status')::text = 'TERBUKA' AND h.status::text NOT IN ('SELESAI', 'BATAL'))
    OR h.status::text = sqlc.narg('status')::text
  )
  AND (sqlc.narg('id_produk')::bigint IS NULL OR g.id_inv_produk = sqlc.narg('id_produk')::bigint)
  AND (
    sqlc.narg('id_gudang')::bigint IS NULL
    OR lok_sumber.id_inv_gudang = sqlc.narg('id_gudang')::bigint
    OR lok_tujuan.id_inv_gudang = sqlc.narg('id_gudang')::bigint
  )
  AND (sqlc.narg('search')::text IS NULL
       OR h.nomor_dokumen ILIKE '%' || sqlc.narg('search')::text || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort')::text = 'nomor_dokumen:asc' THEN h.nomor_dokumen END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'nomor_dokumen:desc' THEN h.nomor_dokumen END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'tanggal_jadwal:asc' THEN h.tanggal_jadwal END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'tanggal_jadwal:desc' THEN h.tanggal_jadwal END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'created_at:asc' THEN g.created_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'created_at:desc' THEN g.created_at END DESC,
  CASE WHEN sqlc.arg('sort')::text = 'updated_at:asc' THEN g.updated_at END ASC,
  CASE WHEN sqlc.arg('sort')::text = 'updated_at:desc' THEN g.updated_at END DESC,
  g.id ASC
LIMIT sqlc.arg('limit')::int
OFFSET sqlc.arg('offset')::int;

-- name: CountGerakan :one
-- Total baris filter ListGerakanIds (envelope meta.total).
SELECT count(*)::bigint AS total
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
JOIN inv_lokasi_stok lok_sumber
     ON lok_sumber.id = COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)
JOIN inv_lokasi_stok lok_tujuan
     ON lok_tujuan.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)
WHERE g.deleted_at IS NULL
  AND (sqlc.narg('jenis')::text IS NULL OR h.jenis::text = sqlc.narg('jenis')::text)
  AND (
    sqlc.narg('status')::text IS NULL
    OR (sqlc.narg('status')::text = 'TERBUKA' AND h.status::text NOT IN ('SELESAI', 'BATAL'))
    OR h.status::text = sqlc.narg('status')::text
  )
  AND (sqlc.narg('id_produk')::bigint IS NULL OR g.id_inv_produk = sqlc.narg('id_produk')::bigint)
  AND (
    sqlc.narg('id_gudang')::bigint IS NULL
    OR lok_sumber.id_inv_gudang = sqlc.narg('id_gudang')::bigint
    OR lok_tujuan.id_inv_gudang = sqlc.narg('id_gudang')::bigint
  )
  AND (sqlc.narg('search')::text IS NULL
       OR h.nomor_dokumen ILIKE '%' || sqlc.narg('search')::text || '%');

-- name: MuatGerakanBaris :one
-- Pasangan baris detail + header utk guard mutasi (muatRowLengkap) — 404
-- INV-018 diputuskan service bila sqlc.ErrNoRows.
SELECT g.id,
       g.entity_id,
       g.id_inv_gerakan_header,
       g.id_inv_produk,
       g.id_inv_lot_serial,
       g.id_inv_unit_ukur,
       g.qty_diminta,
       g.qty_selesai,
       CASE WHEN g.id_lokasi_sumber IS NULL THEN NULL ELSE g.id_lokasi_sumber END AS id_lokasi_sumber,
       CASE WHEN g.id_lokasi_tujuan IS NULL THEN NULL ELSE g.id_lokasi_tujuan END AS id_lokasi_tujuan,
       g.nilai_persatuan,
       g.tanggal_selesai,
       g.entity_id_sumber,
       g.version,
       g.created_at,
       g.updated_at,
       h.id                       AS h_id,
       h.nomor_dokumen            AS h_nomor_dokumen,
       h.jenis::text              AS h_jenis,
       h.status::text             AS h_status,
       h.langkah                  AS h_langkah,
       h.total_langkah            AS h_total_langkah,
       h.reservasi::text          AS h_reservasi,
       h.tanggal_jadwal           AS h_tanggal_jadwal,
       h.tanggal_selesai          AS h_tanggal_selesai,
       h.jenis_sumber             AS h_jenis_sumber,
       h.entity_id_sumber         AS h_entity_id_sumber,
       h.kode_jenis_operasi       AS h_kode_jenis_operasi,
       h.id_core_users            AS h_id_core_users,
       h.id_core_users_penyusun   AS h_id_core_users_penyusun,
       h.id_core_users_penyetuju  AS h_id_core_users_penyetuju,
       h.alasan                   AS h_alasan,
       CASE WHEN h.id_lokasi_sumber IS NULL THEN NULL ELSE h.id_lokasi_sumber END AS h_id_lokasi_sumber,
       CASE WHEN h.id_lokasi_tujuan IS NULL THEN NULL ELSE h.id_lokasi_tujuan END AS h_id_lokasi_tujuan,
       h.version                  AS h_version
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE g.id = sqlc.arg('id')::bigint
  AND g.deleted_at IS NULL
  AND h.deleted_at IS NULL
LIMIT 1;

-- ===========================================================================
-- MASTER pendukung konfirmasi/valuasi/reorder
-- ===========================================================================

-- name: MuatProdukValuasi :one
-- Kolom valuasi produk (kategori + harga_biaya) by id produk hidup.
SELECT p.id_inv_kategori_produk AS kategori_id,
       p.harga_biaya
FROM inv_produk p
WHERE p.id = sqlc.arg('id')::bigint
  AND p.deleted_at IS NULL
LIMIT 1;

-- name: UpdateProdukHargaBiaya :exec
-- Tulis balik harga_biaya produk hidup (AVCO D-28 — nilai dibangun service).
UPDATE inv_produk
SET harga_biaya = sqlc.arg('harga_biaya')::numeric,
    updated_at  = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL;

-- name: MuatKategoriValuasi :one
-- Kebijakan pelacakan + metode valuasi kategori produk hidup by id.
SELECT kebijakan_pelacakan::text AS pelacakan,
       metode_valuasi::text      AS metode_valuasi
FROM inv_kategori_produk
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
LIMIT 1;

-- name: MuatLokasiStok :many
-- Lokasi sumber+tujuan (id/kode/jenis) hidup by sekumpulan id.
SELECT id, kode, jenis::text AS jenis
FROM inv_lokasi_stok
WHERE id = ANY(sqlc.arg('ids')::bigint[])
  AND deleted_at IS NULL;

-- name: MuatJenisLokasi :many
-- Jenis lokasi TANPA filter deleted (verbatim valuasi PENYESUAIAN).
SELECT id, jenis::text AS jenis
FROM inv_lokasi_stok
WHERE id = ANY(sqlc.arg('ids')::bigint[]);

-- name: MuatGudangIdLokasi :one
-- Gudang pemilik satu lokasi (id_inv_gudang) — ErrNoRows → null di pemanggil.
SELECT id_inv_gudang
FROM inv_lokasi_stok
WHERE id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: MuatLotById :one
-- Lot hidup by id — ErrNoRows → 404 INV-018 di service.
SELECT id, entity_id, id_inv_produk, kode, tanggal_prodiksi,
       tanggal_kedaluwarsa, status::text AS status, version,
       created_at, updated_at, deleted_at
FROM inv_lot_serial
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
LIMIT 1;

-- name: CariSerialTerpakai :one
-- Serial sudah terpakai pada gerakan keluar lain (INV-009) — SELESAI, jenis
-- keluar/pindah, lot sama, bukan baris ini — ErrNoRows → aman.
SELECT g.id
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE g.id_inv_lot_serial = sqlc.arg('lot_id')::bigint
  AND h.status::text = 'SELESAI'
  AND h.jenis::text = ANY(sqlc.arg('jenis_keluar')::text[])
  AND g.deleted_at IS NULL
  AND g.id <> sqlc.arg('kecuali_detail_id')::bigint
LIMIT 1;

-- ===========================================================================
-- RAW saldo & FEFO — tetap rawSQL (exec) di repository Go: saldoCukup,
-- cariKandidatLotFefo, saldoOnHandInternal, saldoEfektifReservasi,
-- hitungOutboxReorderHariIni, recomputeSaldoStok — VERBATIM sumber.
-- ===========================================================================

-- ===========================================================================
-- TULIS — header / detail / lapisan FIFO
-- ===========================================================================

-- NOTE: InsertGerakanHeader (create manual — default langkah/total 1/1,
-- entity_id_sumber NULL), InsertLapisanBiaya (qty_terpakai 0), dan
-- TambahQtyTerpakaiLapisan sudah ada di operasi.sql (fitur mutasi/
-- penyesuaian — query bersama, semantik identik); view GerakanStokViewByIds
-- (join D-48 + enrichment ADJ) juga dipakai dari operasi.sql. Varian
-- BACKORDER di bawah butuh kolom ekstra (entity_id_sumber,
-- kode_jenis_operasi, total_langkah) — query terpisah.

-- name: InsertGerakanHeaderBackorder :one
-- Insert HEADER dokumen BACKORDER (CFG-INV-05): jenis_sumber BACKORDER,
-- entity_id_sumber = nomor dokumen asal, kode_jenis_operasi & total_langkah
-- diwarisi header asal, status MENUNGGU_STOK (nilai dibangun service).
INSERT INTO inv_gerakan_header (
  entity_id, nomor_dokumen, jenis, status, langkah, total_langkah,
  tanggal_jadwal, jenis_sumber, entity_id_sumber, kode_jenis_operasi,
  id_core_users, id_core_users_penyusun,
  id_lokasi_sumber, id_lokasi_tujuan
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('nomor_dokumen')::text,
  sqlc.arg('jenis')::enum_jenis_gerakan,
  sqlc.arg('status')::enum_status_gerakan,
  sqlc.arg('langkah')::int,
  sqlc.arg('total_langkah')::int,
  sqlc.arg('tanggal_jadwal')::timestamptz,
  sqlc.arg('jenis_sumber')::text,
  sqlc.arg('entity_id_sumber')::text,
  sqlc.narg('kode_jenis_operasi')::text,
  sqlc.narg('id_core_users')::bigint,
  sqlc.narg('id_core_users_penyusun')::bigint,
  sqlc.narg('id_lokasi_sumber')::bigint,
  sqlc.narg('id_lokasi_tujuan')::bigint
)
RETURNING id, entity_id, nomor_dokumen, jenis::text AS jenis, status::text AS status,
          langkah, total_langkah, reservasi::text AS reservasi,
          tanggal_jadwal, tanggal_selesai, jenis_sumber, entity_id_sumber,
          kode_jenis_operasi, id_core_users, id_core_users_penyusun,
          id_core_users_penyetuju, alasan, id_lokasi_sumber, id_lokasi_tujuan,
          version, created_at, updated_at, deleted_at;

-- name: InsertGerakanDetail :one
-- Insert baris detail gerakan (produk/qty/lot dibangun service) — override
-- lokasi NULL (D-48: lokasi hidup di header); entity_id_sumber per baris
-- (D-50). Catatan skema: lihat header file — narg disengaja (perilaku Nest).
INSERT INTO inv_gerakan_stok (
  entity_id, id_inv_gerakan_header, id_inv_produk, id_inv_lot_serial,
  id_inv_unit_ukur, qty_diminta, qty_selesai,
  id_lokasi_sumber, id_lokasi_tujuan, entity_id_sumber
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_gerakan_header')::bigint,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('id_inv_unit_ukur')::bigint,
  sqlc.arg('qty_diminta')::int,
  sqlc.arg('qty_selesai')::int,
  sqlc.narg('id_lokasi_sumber')::bigint,
  sqlc.narg('id_lokasi_tujuan')::bigint,
  sqlc.narg('entity_id_sumber')::text
)
RETURNING id, entity_id, id_inv_gerakan_header, id_inv_produk, id_inv_lot_serial,
          id_inv_unit_ukur, qty_diminta, qty_selesai, id_lokasi_sumber,
          id_lokasi_tujuan, nilai_persatuan, tanggal_selesai, entity_id_sumber,
          version, created_at, updated_at, deleted_at;

-- name: UpdateGerakanDetailKonfirmasi :one
-- Update baris gerakan hidup saat konfirmasi (nilai dibangun service):
-- version +1, tanggal_selesai NULL bila belum tuntas (narg). RETURNING baris
-- baru — dipakai payload event & view.
UPDATE inv_gerakan_stok
SET qty_selesai      = sqlc.arg('qty_selesai')::int,
    id_inv_lot_serial = sqlc.narg('id_inv_lot_serial')::bigint,
    nilai_persatuan   = sqlc.narg('nilai_persatuan')::numeric,
    tanggal_selesai   = sqlc.narg('tanggal_selesai')::timestamptz,
    version           = sqlc.arg('version')::int,
    updated_at        = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL
RETURNING id, entity_id, id_inv_gerakan_header, id_inv_produk, id_inv_lot_serial,
          id_inv_unit_ukur, qty_diminta, qty_selesai, id_lokasi_sumber,
          id_lokasi_tujuan, nilai_persatuan, tanggal_selesai, entity_id_sumber,
          version, created_at, updated_at, deleted_at;

-- name: UpdateGerakanHeaderHidup :exec
-- Update header hidup (id + deleted_at IS NULL) — set parsial dibangun
-- service: batal (status BATAL + alasan) / reservasi (TERJADWAL +
-- TERRESERVASI); kolom narg NULL = tidak diubah (padanan set parsial Drizzle).
UPDATE inv_gerakan_header
SET status      = sqlc.arg('status')::enum_status_gerakan,
    alasan      = COALESCE(sqlc.narg('alasan')::text, alasan),
    reservasi   = COALESCE(sqlc.narg('reservasi')::enum_status_reservasi, reservasi),
    version     = sqlc.arg('version')::int,
    updated_at  = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
  AND deleted_at IS NULL;

-- name: UpdateGerakanHeaderStatus :exec
-- Derive status dokumen D-49 — where id SAJA (tanpa filter deleted —
-- verbatim updateHeaderById); tanggal_selesai hanya diset saat SELESAI penuh.
UPDATE inv_gerakan_header
SET status          = sqlc.arg('status')::enum_status_gerakan,
    tanggal_selesai = COALESCE(sqlc.narg('tanggal_selesai')::timestamptz, tanggal_selesai),
    updated_at      = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint;

-- NOTE: InsertLapisanBiaya & TambahQtyTerpakaiLapisan dipakai dari
-- operasi.sql (query bersama fitur penyesuaian — kolom/semantik identik).

-- name: ListLapisanFifoKunci :many
-- Lapisan FIFO belum habis (qty_terpakai < qty_masuk) — tertua dulu
-- (tanggal_masuk, id); baris DIKUNCI FOR UPDATE agar konsumsi paralel tidak
-- dobel; lot dicocokkan IS NOT DISTINCT FROM (gerakan tanpa lot → lapisan
-- tanpa lot).
SELECT id, entity_id, id_inv_produk, id_inv_lot_serial, nomor_dokumen_masuk,
       tanggal_masuk, qty_masuk, qty_terpakai, biaya_persatuan, version,
       created_at, updated_at, deleted_at
FROM inv_lapisan_biaya
WHERE id_inv_produk = sqlc.arg('id_inv_produk')::bigint
  AND id_inv_lot_serial IS NOT DISTINCT FROM sqlc.narg('id_inv_lot_serial')::bigint
  AND deleted_at IS NULL
  AND qty_terpakai < qty_masuk
ORDER BY tanggal_masuk ASC, id ASC
FOR UPDATE;

-- ===========================================================================
-- Agregat progres & reorder (M27)
-- ===========================================================================

-- name: MuatAggProgresHeader :one
-- Agregat progres baris satu header (D-49): total, selesai, adaProgres —
-- STATUS DOKUMEN di-derive dari sini (agg FILTER count).
SELECT count(*)::int AS total,
       count(*) FILTER (WHERE g.qty_selesai >= g.qty_diminta)::int AS selesai,
       count(*) FILTER (WHERE g.qty_selesai > 0 AND g.qty_selesai < g.qty_diminta)::int AS ada_progres
FROM inv_gerakan_stok g
WHERE g.id_inv_gerakan_header = sqlc.arg('id_header')::bigint
  AND g.deleted_at IS NULL;

-- name: MuatSaldoAggProduk :one
-- Agregat saldo readmodel satu produk (on-hand & dipesan).
SELECT COALESCE(SUM(s.qty_on_hand), 0)::int AS on_hand,
       COALESCE(SUM(s.qty_dipesan), 0)::int AS dipesan
FROM inv_saldo_stok s
WHERE s.id_inv_produk = sqlc.arg('id_produk')::bigint
  AND s.deleted_at IS NULL;

-- name: HitungOutboxReorderHariIni :one
-- Idempoten per produk-periode (M27): hitung event reorder yang sudah
-- diterbitkan hari ini (rawSQL verbatim — core_outbox_events).
SELECT count(*)::int AS n
FROM core_outbox_events e
WHERE e.topic = 'inventory.reorder.triggered'
  AND e.created_at::date = CURRENT_DATE
  AND e.payload->>'produkId' = sqlc.arg('produk_id')::text;
