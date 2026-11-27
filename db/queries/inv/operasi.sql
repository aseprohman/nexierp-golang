-- OPERASI-LAIN modul inv — padanan repositories/operasi/{mutasi,penyesuaian,
-- picking,jadwal-hitung}.repository.ts NestJS (READ-ONLY sumber): dokumen
-- mutasi barang (+dari GR PUR mirror baca-saja), penyesuaian stok (+posting
-- ADJ + lapisan FIFO D-27 + resolver barcode D-37), picking (agregat
-- nomor_dokumen), jadwal hitung (cycle count). Query VERBATIM sumber;
-- filter/sort dinamis via param eksplisit (pola cluster.sql core).
-- Sort whitelist kanonik (sort_col '' = default urutan sumber).

-- ===========================================================================
-- MUTASI — dokumen mutasi barang (patch 07/D-45 + dari GR patch 59)
-- ===========================================================================

-- name: ListMutasiDokumen :many
-- Halaman dokumen mutasi — join endpoint sumber/tujuan (PK, tak fan-out) +
-- penyusun/penyetuju + jejak GR (patch 59). Filter status/jenis (multi koma
-- disederhanakan jadi ANY — nilai tervalidasi handler)/search ILIKE kode;
-- cakupan 'storages' mode DAFTAR = sumber/tujuan IN ids (party semantics);
-- ids NULL = SEMUA (fail-open). Default urut tanggal DESC, kode ASC.
SELECT d.*,
       sumber.username AS penyusun,
       penyetuju.username AS penyetuju,
       ls.nama AS nama_sumber,
       lt.nama AS nama_tujuan,
       gr.nomor AS nomor_gr,
       po.nomor AS nomor_po
FROM inv_mutasi_dokumen d
JOIN inv_lokasi_stok ls ON ls.id = d.id_lokasi_sumber
JOIN inv_lokasi_stok lt ON lt.id = d.id_lokasi_tujuan
LEFT JOIN core_users sumber ON sumber.id = d.id_core_users_penyusun
LEFT JOIN core_users penyetuju ON penyetuju.id = d.id_core_users_penyetuju
LEFT JOIN pur_penerimaan gr ON gr.id = d.id_pur_penerimaan
LEFT JOIN pur_pesanan po ON po.id = gr.id_pur_pesanan
WHERE d.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR d.status::text = sqlc.narg('status'))
  AND (cardinality(sqlc.arg('jenis')::text[]) = 0 OR d.jenis::text = ANY (sqlc.arg('jenis')::text[]))
  AND (sqlc.narg('search')::text IS NULL OR d.kode ILIKE '%' || sqlc.narg('search') || '%')
  AND (cardinality(sqlc.arg('ids_gudang')::bigint[]) = 0
       OR ls.id_inv_gudang = ANY (sqlc.arg('ids_gudang')::bigint[])
       OR lt.id_inv_gudang = ANY (sqlc.arg('ids_gudang')::bigint[]))
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN d.tanggal_dokumen END DESC NULLS LAST,
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN d.kode END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN d.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND sqlc.arg('sort_desc')::boolean THEN d.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'tanggal' AND NOT sqlc.arg('sort_desc')::boolean THEN d.tanggal_dokumen
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN d.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND NOT sqlc.arg('sort_desc')::boolean THEN d.created_at
    WHEN sqlc.arg('sort_col')::text = 'updated_at' AND NOT sqlc.arg('sort_desc')::boolean THEN d.updated_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND NOT sqlc.arg('sort_desc')::boolean THEN d.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'tanggal' AND sqlc.arg('sort_desc')::boolean THEN d.tanggal_dokumen
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN d.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND sqlc.arg('sort_desc')::boolean THEN d.created_at
    WHEN sqlc.arg('sort_col')::text = 'updated_at' AND sqlc.arg('sort_desc')::boolean THEN d.updated_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND sqlc.arg('sort_desc')::boolean THEN d.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountMutasiDokumen :one
-- Total dokumen (predicate + join endpoint SAMA dengan ListMutasiDokumen —
-- count tak fan-out).
SELECT count(*)::int AS total
FROM inv_mutasi_dokumen d
JOIN inv_lokasi_stok ls ON ls.id = d.id_lokasi_sumber
JOIN inv_lokasi_stok lt ON lt.id = d.id_lokasi_tujuan
WHERE d.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR d.status::text = sqlc.narg('status'))
  AND (cardinality(sqlc.arg('jenis')::text[]) = 0 OR d.jenis::text = ANY (sqlc.arg('jenis')::text[]))
  AND (sqlc.narg('search')::text IS NULL OR d.kode ILIKE '%' || sqlc.narg('search') || '%')
  AND (cardinality(sqlc.arg('ids_gudang')::bigint[]) = 0
       OR ls.id_inv_gudang = ANY (sqlc.arg('ids_gudang')::bigint[])
       OR lt.id_inv_gudang = ANY (sqlc.arg('ids_gudang')::bigint[]));

-- name: HitungGerakanDipostingPerKode :many
-- Jumlah gerakan terposting per dokumen (jenis_sumber MUTASI/GR-PO — patch
-- 59) untuk sekumpulan kode.
SELECT h.nomor_dokumen AS nomor, count(*)::int AS n
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE h.jenis_sumber IN ('MUTASI', 'GR-PO')
  AND h.nomor_dokumen = ANY (sqlc.arg('kodes')::text[])
  AND g.deleted_at IS NULL
GROUP BY h.nomor_dokumen;

-- name: MutasiDokumenDenganRefById :many
-- Detail dokumen + referensi join (penyusun/penyetuju/nama lokasi/GR).
SELECT d.*,
       sumber.username AS penyusun,
       penyetuju.username AS penyetuju,
       ls.nama AS nama_sumber,
       lt.nama AS nama_tujuan,
       gr.nomor AS nomor_gr,
       po.nomor AS nomor_po
FROM inv_mutasi_dokumen d
JOIN inv_lokasi_stok ls ON ls.id = d.id_lokasi_sumber
JOIN inv_lokasi_stok lt ON lt.id = d.id_lokasi_tujuan
LEFT JOIN core_users sumber ON sumber.id = d.id_core_users_penyusun
LEFT JOIN core_users penyetuju ON penyetuju.id = d.id_core_users_penyetuju
LEFT JOIN pur_penerimaan gr ON gr.id = d.id_pur_penerimaan
LEFT JOIN pur_pesanan po ON po.id = gr.id_pur_pesanan
WHERE d.id = sqlc.arg('id')::bigint
LIMIT 1;

-- name: MutasiDokumenHidupById :one
-- Header dokumen hidup — fail 404 INV di wrapper bila absen.
SELECT * FROM inv_mutasi_dokumen
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: GudangLokasiPasangan :many
-- Gudang dari pasangan lokasi (sumber, tujuan) — bahan keputusan cakupan
-- data-scope 'storages'; lokasi virtual tanpa gudang → NULL.
SELECT id_inv_gudang FROM inv_lokasi_stok
WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: MutasiItemsHidupByDokumen :many
-- Items hidup dokumen (urut id) — bahan posting ajukan/keputusan.
SELECT * FROM inv_mutasi_items
WHERE id_inv_mutasi_dokumen = sqlc.arg('id_dokumen')::bigint AND deleted_at IS NULL
ORDER BY id;

-- name: MutasiItemBarisByDokumen :many
-- Baris item view ber-join kode produk/lot/unit (detail).
SELECT i.*, p.kode_produk AS kode_produk, l.kode AS kode_lot, u.kode AS kode_unit
FROM inv_mutasi_items i
JOIN inv_produk p ON p.id = i.id_inv_produk
JOIN inv_unit_ukur u ON u.id = i.id_inv_unit_ukur
LEFT JOIN inv_lot_serial l ON l.id = i.id_inv_lot_serial
WHERE i.id_inv_mutasi_dokumen = sqlc.arg('id_dokumen')::bigint AND i.deleted_at IS NULL
ORDER BY i.id;

-- name: HitungGerakanDipostingNomor :one
-- Jumlah gerakan terposting SATU dokumen (nomor = kode dokumen).
SELECT count(*)::int AS n
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE h.nomor_dokumen = sqlc.arg('nomor')
  AND h.jenis_sumber IN ('MUTASI', 'GR-PO')
  AND g.deleted_at IS NULL;

-- name: HargaSatuanPoBaris :many
-- Baris mentah harga PO per item mutasi (patch 59) — net/faktor dihitung
-- service (SUMBER TUNGGAL view & posting).
SELECT i.id AS id_item,
       i.id_inv_unit_ukur AS id_unit_dasar,
       i.qty_diminta,
       pi.id_inv_unit_ukur AS id_unit_beli,
       ri.qty_diterima AS qty_gr,
       pi.harga,
       pi.diskon_persen AS diskon
FROM inv_mutasi_items i
JOIN pur_penerimaan_item ri ON ri.id = i.id_pur_penerimaan_item
JOIN pur_pesanan_item pi ON pi.id = ri.id_pur_pesanan_item
WHERE i.id = ANY (sqlc.arg('ids')::bigint[]);

-- name: ListGrEligible :many
-- Daftar GR PUR eligible generate mutasi penerimaan (DITERIMA, belum
-- dimutasi — uq_inv_mutasi_gr_ref, minimal 1 baris non-TOLAK).
SELECT gr.id AS id_pur_penerimaan,
       gr.nomor AS nomor_gr,
       po.nomor AS nomor_po,
       mk.nama AS nama_pemasok,
       gd.kode AS kode_gudang,
       gr.tanggal_terima,
       COALESCE(SUM(ri.qty_diterima), 0)::int AS total_qty,
       count(*)::int AS jumlah_baris
FROM pur_penerimaan gr
JOIN pur_pesanan po ON po.id = gr.id_pur_pesanan
JOIN pur_pemasok mk ON mk.id = po.id_pur_pemasok
LEFT JOIN inv_gudang gd ON gd.id = COALESCE(gr.id_inv_gudang, po.id_inv_gudang)
JOIN pur_penerimaan_item ri
  ON ri.id_pur_penerimaan = gr.id AND ri.deleted_at IS NULL AND ri.kondisi <> 'TOLAK'
WHERE gr.status = 'DITERIMA' AND gr.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM inv_mutasi_dokumen m
    WHERE m.id_pur_penerimaan = gr.id AND m.deleted_at IS NULL
  )
GROUP BY gr.id, gr.nomor, po.nomor, mk.nama, gd.kode, gr.tanggal_terima
ORDER BY gr.tanggal_terima DESC, gr.nomor ASC;

-- name: GrDenganPoById :many
-- GR PUR by id + nomor PO + gudang PO (dariGr) — null bila absen/terhapus.
SELECT gr.*, po.nomor AS nomor_po, po.id_inv_gudang AS id_inv_gudang_po
FROM pur_penerimaan gr
JOIN pur_pesanan po ON po.id = gr.id_pur_pesanan
WHERE gr.id = sqlc.arg('id')::bigint AND gr.deleted_at IS NULL
LIMIT 1;

-- name: MutasiHidupByGrId :many
-- Mutasi hidup sumber GR (pre-check 1 GR = 1 mutasi — patungan partial
-- unique uq_inv_mutasi_gr_ref).
SELECT id, kode FROM inv_mutasi_dokumen
WHERE id_pur_penerimaan = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: PenerimaanItemsHidup :many
-- Seluruh baris GR hidup (urut id) — filter non-TOLAK keputusan service.
SELECT * FROM pur_penerimaan_item
WHERE id_pur_penerimaan = sqlc.arg('id')::bigint AND deleted_at IS NULL
ORDER BY id;

-- name: LokasiVendorPertama :many
-- Lokasi VENDOR pertama (sumber mutasi dari GR).
SELECT id FROM inv_lokasi_stok
WHERE jenis = 'VENDOR' AND deleted_at IS NULL
ORDER BY id
LIMIT 1;

-- name: LokasiHidupById :many
-- Lokasi hidup by id (pilihan tujuan manual dariGr).
SELECT id FROM inv_lokasi_stok
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: LokasiInternalPertamaGudang :many
-- Lokasi INTERNAL pertama terikat gudang (tujuan default dariGr) — juga
-- lingkup generate jadwal (semua INTERNAL gudang, tanpa LIMIT? tidak —
-- jadwal pakai query sendiri).
SELECT id FROM inv_lokasi_stok
WHERE jenis = 'INTERNAL' AND id_inv_gudang = sqlc.arg('id_gudang')::bigint AND deleted_at IS NULL
ORDER BY id
LIMIT 1;

-- name: KodeGudangById :many
-- Kode gudang by id (label pesan INV-021 dariGr).
SELECT kode FROM inv_gudang WHERE id = sqlc.arg('id')::bigint LIMIT 1;

-- name: PesananItemsByIds :many
-- Baris PO item by set id (konversi satuan beli→dasar PUR-BR16).
SELECT * FROM pur_pesanan_item WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: ProdukRingkasHidupByIds :many
-- Produk ringkas hidup by set id (id/nama/unit dasar) — validasi referensi.
SELECT id, nama, id_inv_unit_ukur FROM inv_produk
WHERE id = ANY (sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL;

-- name: FaktorKonversiPasangan :many
-- Faktor konversi antar unit (PUR-BR16 dieksekusi INV); pasangan via array
-- paralel (dari[i] → ke[i]); tanpa baris hidup → INV-016 di service.
SELECT id_unit_dari, id_unit_ke, faktor
FROM inv_unit_konversi k
WHERE k.deleted_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM unnest(sqlc.arg('dari')::bigint[]) AS ud(dari)
    JOIN unnest(sqlc.arg('ke')::bigint[]) AS uk(ke) ON true
    WHERE k.id_unit_dari = ud.dari AND k.id_unit_ke = uk.ke
  );

-- name: NamaProdukHidupByIds :many
-- Nama produk hidup by set id (snapshot nama + validasi referensi).
SELECT id, nama FROM inv_produk
WHERE id = ANY (sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL;

-- name: InsertMutasiDokumen :one
-- Insert dokumen (DRAFT; nilai dibangun service) → baris lengkap.
INSERT INTO inv_mutasi_dokumen (
  entity_id, kode, jenis, status, id_lokasi_sumber, id_lokasi_tujuan,
  tanggal_dokumen, id_core_users_penyusun, alasan, id_pur_penerimaan
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('kode'),
  sqlc.arg('jenis')::enum_jenis_gerakan,
  sqlc.arg('status')::enum_status_mutasi,
  sqlc.arg('id_lokasi_sumber')::bigint,
  sqlc.arg('id_lokasi_tujuan')::bigint,
  sqlc.arg('tanggal_dokumen')::timestamptz,
  sqlc.narg('id_core_users_penyusun')::bigint,
  sqlc.narg('alasan')::text,
  sqlc.narg('id_pur_penerimaan')::bigint
)
RETURNING *;

-- name: UpdateMutasiDraft :one
-- Ubah DRAFT — set dibangun service (jenis/lokasi/tanggal/alasan/version).
UPDATE inv_mutasi_dokumen SET
  jenis = sqlc.arg('jenis')::enum_jenis_gerakan,
  id_lokasi_sumber = sqlc.arg('id_lokasi_sumber')::bigint,
  id_lokasi_tujuan = sqlc.arg('id_lokasi_tujuan')::bigint,
  tanggal_dokumen = sqlc.arg('tanggal_dokumen')::timestamptz,
  alasan = sqlc.narg('alasan')::text,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- name: UpdateMutasiStatus :one
-- Transisi status (ajukan MENUNGGU/DISETUJUI — tanpa penyentuh alasan).
UPDATE inv_mutasi_dokumen SET
  status = sqlc.arg('status')::enum_status_mutasi,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- name: UpdateMutasiKeputusan :one
-- Keputusan approval — SETUJUI (status DISETUJUI + penyetuju) / TOLAK
-- (status DITOLAK + penyetuju + alasan).
UPDATE inv_mutasi_dokumen SET
  status = sqlc.arg('status')::enum_status_mutasi,
  id_core_users_penyetuju = sqlc.arg('id_core_users_penyetuju')::bigint,
  alasan = sqlc.narg('alasan')::text,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- name: UpdateMutasiBatal :one
-- Batal draft/pengajuan — status DIBATALKAN + alasan wajib.
UPDATE inv_mutasi_dokumen SET
  status = 'DIBATALKAN'::enum_status_mutasi,
  alasan = sqlc.arg('alasan'),
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint
RETURNING *;

-- name: SoftDeleteMutasiDokumen :exec
-- Hapus DRAFT lunak — header (jejak tetap ada).
UPDATE inv_mutasi_dokumen SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint;

-- name: SoftDeleteMutasiItemsByDokumen :exec
-- Hapus lunak SEMUA items hidup dokumen (CASCADE soft / langkah REPLACE).
UPDATE inv_mutasi_items SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_inv_mutasi_dokumen = sqlc.arg('id_dokumen')::bigint AND deleted_at IS NULL;

-- name: InsertMutasiItem :exec
-- Sisip SATU item dokumen (snapshot nama dibangun service).
INSERT INTO inv_mutasi_items (
  entity_id, id_inv_mutasi_dokumen, id_inv_produk, id_inv_lot_serial,
  id_inv_unit_ukur, qty_diminta, nama_produk, id_pur_penerimaan_item
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_mutasi_dokumen')::bigint,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('id_inv_unit_ukur')::bigint,
  sqlc.arg('qty_diminta')::int,
  sqlc.arg('nama_produk'),
  sqlc.narg('id_pur_penerimaan_item')::bigint
);

-- name: InsertGerakanHeader :one
-- Insert HEADER gerakan (nomor = kode dokumen, pola DO) → baris lengkap.
INSERT INTO inv_gerakan_header (
  entity_id, nomor_dokumen, jenis, status, tanggal_jadwal, tanggal_selesai,
  jenis_sumber, id_core_users, id_core_users_penyusun,
  id_lokasi_sumber, id_lokasi_tujuan
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('nomor_dokumen'),
  sqlc.arg('jenis')::enum_jenis_gerakan,
  sqlc.arg('status')::enum_status_gerakan,
  sqlc.arg('tanggal_jadwal')::timestamptz,
  sqlc.narg('tanggal_selesai')::timestamptz,
  sqlc.arg('jenis_sumber'),
  sqlc.narg('id_core_users')::bigint,
  sqlc.narg('id_core_users_penyusun')::bigint,
  sqlc.narg('id_lokasi_sumber')::bigint,
  sqlc.narg('id_lokasi_tujuan')::bigint
)
RETURNING *;

-- name: InsertGerakanStokAbaikanDuplikat :exec
-- Insert baris inv_gerakan_stok status DRAFT — onConflictDoNothing (retry
-- posting → kunci idempoten sama → unique index menahan duplikat).
INSERT INTO inv_gerakan_stok (
  entity_id, id_inv_gerakan_header, id_inv_produk, id_inv_lot_serial,
  id_inv_unit_ukur, qty_diminta, qty_selesai, id_lokasi_sumber,
  id_lokasi_tujuan, nilai_persatuan, entity_id_sumber
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_gerakan_header')::bigint,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('id_inv_unit_ukur')::bigint,
  sqlc.arg('qty_diminta')::int,
  0,
  sqlc.arg('id_lokasi_sumber')::bigint,
  sqlc.arg('id_lokasi_tujuan')::bigint,
  sqlc.narg('nilai_persatuan')::numeric,
  sqlc.arg('entity_id_sumber')
)
ON CONFLICT DO NOTHING;

-- name: InsertGerakanStok :one
-- Insert gerakan per item selisih ≠ 0 (override lokasi per baris D-48) →
-- baris lengkap (status SELESAI).
INSERT INTO inv_gerakan_stok (
  entity_id, id_inv_gerakan_header, id_inv_produk, id_inv_lot_serial,
  id_inv_unit_ukur, qty_diminta, qty_selesai, id_lokasi_sumber,
  id_lokasi_tujuan, nilai_persatuan, tanggal_selesai, entity_id_sumber
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_gerakan_header')::bigint,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('id_inv_unit_ukur')::bigint,
  sqlc.arg('qty_diminta')::int,
  sqlc.arg('qty_selesai')::int,
  sqlc.arg('id_lokasi_sumber')::bigint,
  sqlc.arg('id_lokasi_tujuan')::bigint,
  sqlc.narg('nilai_persatuan')::numeric,
  sqlc.narg('tanggal_selesai')::timestamptz,
  sqlc.arg('entity_id_sumber')
)
RETURNING *;

-- ===========================================================================
-- PENYESUAIAN — dokumen penyesuaian/cycle count/scrap (INV-F08/F12)
-- ===========================================================================

-- name: ListPenyesuaian :many
-- Halaman penyesuaian — join gudang/penyusun/penyetuju; filter
-- status/jenis/search ILIKE kode; default urut id DESC.
SELECT p.*,
       gd.kode AS kode_gudang,
       gd.nama AS nama_gudang,
       penyusun.username AS nama_penyusun,
       penyetuju.username AS nama_penyetuju
FROM inv_penyesuaian_stok p
JOIN inv_gudang gd ON gd.id = p.id_inv_gudang
LEFT JOIN core_users penyusun ON penyusun.id = p.id_core_users_penyusun
LEFT JOIN core_users penyetuju ON penyetuju.id = p.id_core_users_penyetuju
WHERE p.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR p.status::text = sqlc.narg('status'))
  AND (sqlc.narg('jenis')::text IS NULL OR p.jenis::text = sqlc.narg('jenis'))
  AND (sqlc.narg('search')::text IS NULL OR p.kode ILIKE '%' || sqlc.narg('search') || '%')
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN p.id END DESC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN p.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND sqlc.arg('sort_desc')::boolean THEN p.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'tanggal_dokumen' AND NOT sqlc.arg('sort_desc')::boolean THEN p.tanggal_dokumen
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN p.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND NOT sqlc.arg('sort_desc')::boolean THEN p.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND NOT sqlc.arg('sort_desc')::boolean THEN p.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'tanggal_dokumen' AND sqlc.arg('sort_desc')::boolean THEN p.tanggal_dokumen
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN p.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND sqlc.arg('sort_desc')::boolean THEN p.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND sqlc.arg('sort_desc')::boolean THEN p.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountPenyesuaian :one
-- Total penyesuaian (kriteria sama dengan ListPenyesuaian).
SELECT count(*)::int AS total
FROM inv_penyesuaian_stok p
WHERE p.deleted_at IS NULL
  AND (sqlc.narg('status')::text IS NULL OR p.status::text = sqlc.narg('status'))
  AND (sqlc.narg('jenis')::text IS NULL OR p.jenis::text = sqlc.narg('jenis'))
  AND (sqlc.narg('search')::text IS NULL OR p.kode ILIKE '%' || sqlc.narg('search') || '%');

-- name: PenyesuaianDenganRefById :many
-- Muat SATU penyesuaian lewat executor tertentu — WAJIB tx pada jalur
-- mutasi; 404 INV-018 di wrapper bila absen/terhapus.
SELECT p.*,
       gd.kode AS kode_gudang,
       gd.nama AS nama_gudang,
       penyusun.username AS nama_penyusun,
       penyetuju.username AS nama_penyetuju
FROM inv_penyesuaian_stok p
JOIN inv_gudang gd ON gd.id = p.id_inv_gudang
LEFT JOIN core_users penyusun ON penyusun.id = p.id_core_users_penyusun
LEFT JOIN core_users penyetuju ON penyetuju.id = p.id_core_users_penyetuju
WHERE p.id = sqlc.arg('id')::bigint AND p.deleted_at IS NULL
LIMIT 1;

-- name: PenyesuaianHidupById :one
-- Header penyesuaian hidup — fail 404 INV di wrapper bila absen.
SELECT * FROM inv_penyesuaian_stok
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: PenyesuaianItemsHidupByHeader :many
-- Items hidup untuk sekumpulan header (urut id) — bahan mapper view.
SELECT * FROM inv_penyesuaian_stok_items
WHERE id_inv_penyesuaian_stok = ANY (sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL
ORDER BY id;

-- name: KodeProdukByIds :many
SELECT id, kode_produk FROM inv_produk WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: KodeLotByIds :many
SELECT id, kode FROM inv_lot_serial WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: KodeLokasiByIds :many
SELECT id, kode FROM inv_lokasi_stok WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: KodeUnitByIds :many
SELECT id, kode FROM inv_unit_ukur WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: KodeKemasanByIds :many
SELECT id, kode FROM inv_kemasan WHERE id = ANY (sqlc.arg('ids')::bigint[]);

-- name: GudangHidupById :many
-- Gudang hidup by id (validasi create draft) — null bila absen/terhapus.
SELECT * FROM inv_gudang
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: ProdukDenganUnitHidupByIds :many
-- Produk hidup by set id (id/nama/unit dasar) — snapshot & validasi kemasan.
SELECT id, nama, id_inv_unit_ukur FROM inv_produk
WHERE id = ANY (sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL;

-- name: KemasanHidupByIds :many
-- Master kemasan pemilik faktor konversi by set id (hidup saja — ddl/54).
SELECT id, kode, id_inv_produk, id_inv_unit_ukur, qty_isi FROM inv_kemasan
WHERE id = ANY (sqlc.arg('ids')::bigint[]) AND deleted_at IS NULL;

-- name: InsertPenyesuaian :one
-- Insert penyesuaian DRAFT (nilai dibangun service) → baris lengkap.
INSERT INTO inv_penyesuaian_stok (
  entity_id, kode, jenis, status, id_inv_gudang, tanggal_dokumen,
  id_core_users_penyusun, alasan
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('kode'),
  sqlc.arg('jenis')::enum_jenis_penyesuaian,
  sqlc.arg('status')::enum_status_penyesuaian,
  sqlc.arg('id_inv_gudang')::bigint,
  sqlc.arg('tanggal_dokumen')::timestamptz,
  sqlc.narg('id_core_users_penyusun')::bigint,
  sqlc.narg('alasan')::text
)
RETURNING *;

-- name: UpdatePenyesuaianDraft :exec
-- Ubah draft — jenis/tanggal/alasan/version (set dibangun service).
UPDATE inv_penyesuaian_stok SET
  jenis = sqlc.arg('jenis')::enum_jenis_penyesuaian,
  tanggal_dokumen = sqlc.arg('tanggal_dokumen')::timestamptz,
  alasan = sqlc.narg('alasan')::text,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint;

-- name: UpdatePenyesuaianStatus :exec
-- Transisi status (ajukan MENUNGGU/DISETUJUI auto — penyetuju/alasan NULL =
-- tidak disentuh); keputusan SETUJUI/TOLAK & batal mengirim nilai konkret.
UPDATE inv_penyesuaian_stok SET
  status = sqlc.arg('status')::enum_status_penyesuaian,
  id_core_users_penyetuju = COALESCE(sqlc.narg('id_core_users_penyetuju')::bigint, id_core_users_penyetuju),
  alasan = COALESCE(sqlc.narg('alasan')::text, alasan),
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint;

-- name: SoftDeletePenyesuaianItemsByHeader :exec
-- Soft delete SEMUA items hidup header (langkah REPLACE draft).
UPDATE inv_penyesuaian_stok_items SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id_inv_penyesuaian_stok = sqlc.arg('id_header')::bigint AND deleted_at IS NULL;

-- name: InsertPenyesuaianItem :exec
-- Sisip SATU baris item (nilai + snapshot nama dibangun service — otoritas
-- konversi kemasan ddl/54 dihitung di service).
INSERT INTO inv_penyesuaian_stok_items (
  entity_id, id_inv_penyesuaian_stok, id_inv_produk, id_inv_lot_serial,
  id_inv_lokasi_stok, id_inv_unit_ukur, id_inv_kemasan, isi_per_kemasan,
  qty_sistem, qty_hitung, qty_selisih, biaya_satuan, nama_produk
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_penyesuaian_stok')::bigint,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('id_inv_lokasi_stok')::bigint,
  sqlc.arg('id_inv_unit_ukur')::bigint,
  sqlc.narg('id_inv_kemasan')::bigint,
  sqlc.narg('isi_per_kemasan')::int,
  sqlc.arg('qty_sistem')::int,
  sqlc.arg('qty_hitung')::int,
  sqlc.arg('qty_selisih')::int,
  sqlc.narg('biaya_satuan')::numeric,
  sqlc.arg('nama_produk')
);

-- name: LokasiHidupByKode :many
-- Lokasi hidup by kode (konvensi ADJ-VIRTUAL — kode dikirim pemanggil).
SELECT * FROM inv_lokasi_stok
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- name: RefValuasiProduk :many
-- Referensi valuasi produk (metode kategori + fallback harga_biaya) — hanya
-- produk kategori FIFO diproses catatLapisanFifo.
SELECT kp.metode_valuasi, p.harga_biaya
FROM inv_produk p
JOIN inv_kategori_produk kp ON kp.id = p.id_inv_kategori_produk
WHERE p.id = sqlc.arg('id')::bigint AND p.deleted_at IS NULL
LIMIT 1;

-- name: InsertLapisanBiaya :exec
-- INSERT lapisan biaya (penyesuaian-plus melahirkan lapisan — nomor ADJ).
INSERT INTO inv_lapisan_biaya (
  entity_id, id_inv_produk, id_inv_lot_serial, nomor_dokumen_masuk,
  tanggal_masuk, qty_masuk, qty_terpakai, biaya_persatuan
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('id_inv_produk')::bigint,
  sqlc.narg('id_inv_lot_serial')::bigint,
  sqlc.arg('nomor_dokumen_masuk'),
  sqlc.arg('tanggal_masuk')::timestamptz,
  sqlc.arg('qty_masuk')::int,
  0,
  sqlc.arg('biaya_persatuan')::numeric
);

-- name: LapisanFifoTerbuka :many
-- Lapisan FIFO terbuka (qtyTerpakai < qtyMasuk) produk/lot — TERLAMA dulu,
-- FOR UPDATE (konsumsi tertua D-27; lot dicocokkan bila item berlot, tanpa
-- lot → lapisan tanpa lot).
SELECT * FROM inv_lapisan_biaya
WHERE id_inv_produk = sqlc.arg('id_produk')::bigint
  AND (CASE WHEN sqlc.arg('ada_lot')::boolean
       THEN id_inv_lot_serial = sqlc.arg('id_lot')::bigint
       ELSE id_inv_lot_serial IS NULL END)
  AND deleted_at IS NULL
  AND qty_terpakai < qty_masuk
ORDER BY tanggal_masuk ASC, id ASC
FOR UPDATE;

-- name: TambahQtyTerpakaiLapisan :exec
-- Konsumsi lapisan FIFO — tambah qty_terpakai + version.
UPDATE inv_lapisan_biaya SET
  qty_terpakai = qty_terpakai + sqlc.arg('qty')::int,
  version = version + 1,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- name: SetNilaiPersatuanGerakan :exec
-- Nilai gerakan minus = rata-rata tertimbang lapisan (dihitung service).
UPDATE inv_gerakan_stok SET nilai_persatuan = sqlc.arg('nilai')::numeric
WHERE id = sqlc.arg('id')::bigint;

-- name: ProdukByBarcode :many
-- Resolve barcode → PRODUK (kartu induk; hidup) + saldo on-hand agregat.
SELECT p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_produk_induk,
       p.id_inv_unit_ukur, u.kode AS kode_unit, p.harga_jual,
       (
         SELECT COALESCE(SUM(s.qty_on_hand), 0)::int
         FROM inv_saldo_stok s
         WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
       ) AS saldo_on_hand
FROM inv_produk p
JOIN inv_unit_ukur u ON u.id = p.id_inv_unit_ukur
WHERE p.barcode = sqlc.arg('kode') AND p.deleted_at IS NULL
LIMIT 1;

-- name: LotByBarcode :many
-- Resolve barcode → LOT/serial (+ saldo lot hidup; produk nonaktif tetap
-- cocok demi opname baris lama).
SELECT p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_produk_induk,
       p.id_inv_unit_ukur, u.kode AS kode_unit, p.harga_jual,
       (
         SELECT COALESCE(SUM(s.qty_on_hand), 0)::int
         FROM inv_saldo_stok s
         WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
       ) AS saldo_on_hand,
       l.id AS lot_id, l.kode AS lot_kode, l.status AS lot_status,
       (
         SELECT COALESCE(SUM(s.qty_on_hand), 0)::int
         FROM inv_saldo_stok s
         WHERE s.id_inv_lot_serial = l.id AND s.deleted_at IS NULL
       ) AS lot_saldo
FROM inv_lot_serial l
JOIN inv_produk p ON p.id = l.id_inv_produk
JOIN inv_unit_ukur u ON u.id = p.id_inv_unit_ukur
WHERE l.barcode = sqlc.arg('kode') AND l.deleted_at IS NULL
LIMIT 1;

-- name: KemasanByBarcode :many
-- Resolve barcode → KEMASAN (unit isi = unit dasar produk, ddl/54).
SELECT p.id, p.kode_produk, p.nama, p.tipe, p.id_inv_produk_induk,
       p.id_inv_unit_ukur, u.kode AS kode_unit, p.harga_jual,
       (
         SELECT COALESCE(SUM(s.qty_on_hand), 0)::int
         FROM inv_saldo_stok s
         WHERE s.id_inv_produk = p.id AND s.deleted_at IS NULL
       ) AS saldo_on_hand,
       k.id AS kemasan_id, k.kode AS kemasan_kode, k.nama AS kemasan_nama,
       k.qty_isi AS kemasan_isi
FROM inv_kemasan k
JOIN inv_produk p ON p.id = k.id_inv_produk
JOIN inv_unit_ukur u ON u.id = k.id_inv_unit_ukur
WHERE k.barcode = sqlc.arg('kode') AND k.deleted_at IS NULL
LIMIT 1;

-- ===========================================================================
-- PICKING — agregat kerja per nomor_dokumen (tanpa tabel; D-07/D-25)
-- ===========================================================================

-- name: GerakanStokIdsByNomor :many
-- Detail picking — id semua baris gerakan satu nomor (urut id).
SELECT g.id FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE h.nomor_dokumen = sqlc.arg('nomor') AND g.deleted_at IS NULL
ORDER BY g.id;

-- name: GerakanHeaderByNomor :many
-- Header dokumen hidup by nomor — null bila tidak ada.
SELECT * FROM inv_gerakan_header
WHERE nomor_dokumen = sqlc.arg('nomor') AND deleted_at IS NULL
LIMIT 1;

-- name: JenisOperasiIdByKode :many
-- Id master jenis operasi hidup by kode — null bila tak dikenal (INV-020).
SELECT id FROM inv_jenis_operasi
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
LIMIT 1;

-- name: UpdateGerakanHeaderLangkah :exec
-- Majukan tahap — UPDATE header by id (langkah+1, version+1; SATU baris —
-- PATCH 09).
UPDATE inv_gerakan_header SET
  langkah = sqlc.arg('langkah')::int,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint;

-- name: AgregatNomorTerbuka :many
-- View agregat pasca-update — agregasi atas baris TERBUKA saja satu nomor
-- (konsisten daftar picking; mode() WITHIN GROUP verbatim sumber).
SELECT h.nomor_dokumen,
       MAX(h.jenis::text)::text AS jenis,
       MAX(h.kode_jenis_operasi) AS kode_jenis_operasi,
       MAX(h.langkah)::int AS langkah,
       MAX(h.total_langkah)::int AS total_langkah,
       (mode() WITHIN GROUP (ORDER BY h.status::text))::text AS status_dominan,
       COUNT(*)::int AS jumlah_baris,
       SUM(g.qty_diminta)::int AS qty_diminta,
       SUM(g.qty_selesai)::int AS qty_selesai,
       MIN(h.tanggal_jadwal)::timestamptz AS tanggal_jadwal,
       BOOL_OR(h.reservasi = 'TERRESERVASI') AS reservasi
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
WHERE h.nomor_dokumen = sqlc.arg('nomor') AND h.deleted_at IS NULL
  AND h.status NOT IN ('SELESAI', 'BATAL')
GROUP BY h.nomor_dokumen;

-- name: JenisOperasiSemua :many
-- Peta kode jenis operasi → label langkah (tabel kecil, dimuat utuh).
SELECT kode, nama, nama_langkah_1, nama_langkah_2, nama_langkah_3, jumlah_langkah
FROM inv_jenis_operasi
WHERE deleted_at IS NULL;

-- name: GerakanStokViewByIds :many
-- Muat view gerakan FLAT (join header + produk/lot/unit/lokasi efektif
-- COALESCE baris/header D-48) + enrichment baris ADJ via entityIdSumber
-- "{uuid header}:{id item}" — dipakai picking get (delegasi view gerakan).
SELECT g.id, g.entity_id, g.id_inv_gerakan_header, g.id_inv_produk,
       g.id_inv_lot_serial, g.id_inv_unit_ukur, g.qty_diminta, g.qty_selesai,
       CASE WHEN g.id_lokasi_sumber IS NULL THEN NULL ELSE g.id_lokasi_sumber END AS id_lokasi_sumber,
       CASE WHEN g.id_lokasi_tujuan IS NULL THEN NULL ELSE g.id_lokasi_tujuan END AS id_lokasi_tujuan,
       g.nilai_persatuan, g.tanggal_selesai, g.entity_id_sumber, g.version,
       g.created_at, g.updated_at, g.deleted_at,
       h.nomor_dokumen, h.jenis AS jenis_header, h.status AS status_header,
       h.langkah, h.total_langkah, h.reservasi, h.tanggal_jadwal, h.jenis_sumber,
       h.alasan,
       p.kode_produk, p.nama AS nama_produk,
       l.kode AS kode_lot,
       u.kode AS kode_unit,
       ls.kode AS kode_sumber, ls.nama AS nama_sumber,
       lt.kode AS kode_tujuan, lt.nama AS nama_tujuan,
       COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)::int AS id_lokasi_sumber_efektif,
       COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)::int AS id_lokasi_tujuan_efektif,
       adj.jenis AS jenis_penyesuaian,
       ai.qty_sistem AS qty_sistem, ai.qty_hitung AS qty_hitung, ai.qty_selisih AS qty_selisih
FROM inv_gerakan_stok g
JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
JOIN inv_produk p ON p.id = g.id_inv_produk
LEFT JOIN inv_lot_serial l ON l.id = g.id_inv_lot_serial
JOIN inv_unit_ukur u ON u.id = g.id_inv_unit_ukur
JOIN inv_lokasi_stok ls ON ls.id = COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)
JOIN inv_lokasi_stok lt ON lt.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan)
LEFT JOIN inv_penyesuaian_stok adj
  ON adj.entity_id::text = split_part(g.entity_id_sumber, ':', 1)
LEFT JOIN inv_penyesuaian_stok_items ai
  ON ai.id_inv_penyesuaian_stok = adj.id
  AND ai.id::text = split_part(g.entity_id_sumber, ':', 2)
WHERE g.id = ANY (sqlc.arg('ids')::bigint[]) AND g.deleted_at IS NULL
ORDER BY g.id;

-- ===========================================================================
-- JADWAL HITUNG — cycle count terjadwal (patch 04 — P1 #7)
-- ===========================================================================

-- name: ListJadwalHitung :many
-- Daftar jadwal — filter gudang/aktif + search ILIKE kode/nama; default
-- urut kode ASC.
SELECT j.*,
       gd.kode AS kode_gudang,
       lk.kode AS kode_lokasi
FROM inv_jadwal_hitung j
JOIN inv_gudang gd ON gd.id = j.id_inv_gudang
LEFT JOIN inv_lokasi_stok lk ON lk.id = j.id_inv_lokasi_stok
WHERE j.deleted_at IS NULL
  AND (sqlc.narg('id_gudang')::bigint IS NULL OR j.id_inv_gudang = sqlc.narg('id_gudang'))
  AND (sqlc.narg('aktif')::boolean IS NULL OR j.aktif = sqlc.narg('aktif'))
  AND (sqlc.narg('search')::text IS NULL
       OR (j.kode ILIKE '%' || sqlc.narg('search') || '%'
           OR j.nama ILIKE '%' || sqlc.narg('search') || '%'))
ORDER BY
  CASE WHEN sqlc.arg('sort_col')::text = '' THEN j.kode END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND NOT sqlc.arg('sort_desc')::boolean THEN j.kode
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'kode' AND sqlc.arg('sort_desc')::boolean THEN j.kode
  END DESC NULLS FIRST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND NOT sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND NOT sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND NOT sqlc.arg('sort_desc')::boolean THEN j.updated_at
  END ASC NULLS LAST,
  CASE
    WHEN sqlc.arg('sort_col')::text = 'created_at' AND sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col')::text = 'createdAt' AND sqlc.arg('sort_desc')::boolean THEN j.created_at
    WHEN sqlc.arg('sort_col')::text = 'updatedAt' AND sqlc.arg('sort_desc')::boolean THEN j.updated_at
  END DESC NULLS FIRST
LIMIT sqlc.arg('limit')
OFFSET sqlc.arg('offset');

-- name: CountJadwalHitung :one
-- Total jadwal (kriteria sama dengan ListJadwalHitung).
SELECT count(*)::int AS total
FROM inv_jadwal_hitung j
WHERE j.deleted_at IS NULL
  AND (sqlc.narg('id_gudang')::bigint IS NULL OR j.id_inv_gudang = sqlc.narg('id_gudang'))
  AND (sqlc.narg('aktif')::boolean IS NULL OR j.aktif = sqlc.narg('aktif'))
  AND (sqlc.narg('search')::text IS NULL
       OR (j.kode ILIKE '%' || sqlc.narg('search') || '%'
           OR j.nama ILIKE '%' || sqlc.narg('search') || '%'));

-- name: JadwalHitungViewById :many
-- Muat satu jadwal (JOIN kode gudang/lokasi) → view; null bila tidak ada.
SELECT j.*,
       gd.kode AS kode_gudang,
       lk.kode AS kode_lokasi
FROM inv_jadwal_hitung j
JOIN inv_gudang gd ON gd.id = j.id_inv_gudang
LEFT JOIN inv_lokasi_stok lk ON lk.id = j.id_inv_lokasi_stok
WHERE j.id = sqlc.arg('id')::bigint AND j.deleted_at IS NULL
LIMIT 1;

-- name: JadwalHitungHidupById :one
-- Jadwal hidup wajib ada — fail 404 INV-018 di wrapper bila tidak ada.
SELECT * FROM inv_jadwal_hitung
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL
LIMIT 1;

-- name: JadwalKodeDipakai :many
-- Kode jadwal bebas (unique global, soft-delete aware) — baris lain berkode
-- sama (409 di wrapper bila ada).
SELECT id FROM inv_jadwal_hitung
WHERE kode = sqlc.arg('kode') AND deleted_at IS NULL
  AND (sqlc.narg('kecuali_id')::bigint IS NULL OR id <> sqlc.narg('kecuali_id'))
LIMIT 1;

-- name: InsertJadwalHitung :one
-- Insert jadwal baru → baris lengkap (entityId/kode/kolom bisnis dibangun
-- service).
INSERT INTO inv_jadwal_hitung (
  entity_id, kode, nama, id_inv_gudang, id_inv_lokasi_stok,
  frekuensi, hari_eksekusi, aktif
) VALUES (
  sqlc.arg('entity_id')::uuid,
  sqlc.arg('kode'),
  sqlc.arg('nama'),
  sqlc.arg('id_inv_gudang')::bigint,
  sqlc.narg('id_inv_lokasi_stok')::bigint,
  sqlc.arg('frekuensi')::enum_frekuensi_hitung,
  sqlc.arg('hari_eksekusi')::int,
  sqlc.arg('aktif')::boolean
)
RETURNING *;

-- name: UpdateJadwalHitungPatch :exec
-- Update jadwal hidup by id — patch penuh (kode/nama/gudang/lokasi/
-- frekuensi/hari/aktif) + version+1; lokasi NULL eksplisit via param
-- lokasi_null (tri-state zod nullish).
UPDATE inv_jadwal_hitung SET
  kode = sqlc.arg('kode'),
  nama = sqlc.arg('nama'),
  id_inv_gudang = sqlc.arg('id_inv_gudang')::bigint,
  id_inv_lokasi_stok = CASE WHEN sqlc.arg('lokasi_null')::boolean
    THEN NULL
    ELSE COALESCE(sqlc.narg('id_inv_lokasi_stok')::bigint, id_inv_lokasi_stok) END,
  frekuensi = sqlc.arg('frekuensi')::enum_frekuensi_hitung,
  hari_eksekusi = sqlc.arg('hari_eksekusi')::int,
  aktif = sqlc.arg('aktif')::boolean,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- name: SoftDeleteJadwalHitung :exec
-- Hapus lunak — jadwal tak direferensikan (aman).
UPDATE inv_jadwal_hitung SET deleted_at = sqlc.arg('deleted_at')::timestamptz,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- name: StampJadwalHitungGenerate :exec
-- Jejak generate — stamp terakhir_dibuat_pada + version+1.
UPDATE inv_jadwal_hitung SET
  terakhir_dibuat_pada = sqlc.arg('terakhir_dibuat_pada')::timestamptz,
  version = sqlc.arg('version')::int,
  updated_at = sqlc.arg('updated_at')::timestamptz
WHERE id = sqlc.arg('id')::bigint AND deleted_at IS NULL;

-- name: LokasiInternalSemuaGudang :many
-- Id lokasi INTERNAL hidup satu gudang — lingkup hitung bila jadwal tanpa
-- lokasi terpilih.
SELECT id FROM inv_lokasi_stok
WHERE id_inv_gudang = sqlc.arg('id_gudang')::bigint AND jenis = 'INTERNAL' AND deleted_at IS NULL;

-- name: SaldoLingkupHitung :many
-- Items count sheet dari READMODEL saldo — qty_sistem = on-hand (>0), JOIN
-- produk utk unit/biaya/nama snapshot; urut id stabil.
SELECT s.id_inv_produk, s.id_inv_lot_serial, s.id_inv_lokasi_stok,
       s.qty_on_hand,
       p.id_inv_unit_ukur AS id_unit,
       p.harga_biaya,
       p.nama AS nama_produk
FROM inv_saldo_stok s
JOIN inv_produk p ON p.id = s.id_inv_produk
WHERE s.id_inv_lokasi_stok = ANY (sqlc.arg('lokasi_ids')::bigint[])
  AND s.deleted_at IS NULL AND p.deleted_at IS NULL
  AND s.qty_on_hand > 0
ORDER BY s.id;
