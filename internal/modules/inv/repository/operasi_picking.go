// operasi_picking.go — repository fitur PICKING modul inv (padanan
// repositories/operasi/picking.repository.ts NestJS, patch 04 A-02/D-25):
// agregasi daftar kerja per `nomor_dokumen` atas `inv_gerakan_stok` +
// `inv_gerakan_header` TERBUKA (rawSQL CTE baris/agg — VERBATIM, tanpa
// konversi query-builder; Picking TIDAK punya tabel sendiri D-07/D-25),
// master `inv_jenis_operasi` (label langkah aktif D-26), UPDATE langkah
// header (majukan tahap), dan view gerakan FLAT (delegasi get).
package repository

import (
	"context"
	"fmt"
	"strings"
	"time"

	"nexierp/internal/modules/inv/repository/gen"
)

// PickingRepository — agregat + master jenis operasi + header langkah.
type PickingRepository struct{}

// NewPickingRepository membuat repository picking.
func NewPickingRepository() *PickingRepository { return &PickingRepository{} }

// PickingListFilter — kriteria list agregat (parsed service).
type PickingListFilter struct {
	Jenis          *string
	IDGudang       *int64
	Search         *string
	OnlyBelumAkhir bool
	SortCol        string // whitelist: nomorDokumen|nomor_dokumen|tanggalJadwal|tanggal_jadwal
	SortDesc       bool
	Limit          int32
	Offset         int32
}

// pickingSortKolom — map whitelist sort → kolom mentah (verbatim SORT_KOLOM).
var pickingSortKolom = map[string]string{
	"nomorDokumen":   "nomor_dokumen",
	"nomor_dokumen":  "nomor_dokumen",
	"tanggalJadwal":  "tanggal_jadwal",
	"tanggal_jadwal": "tanggal_jadwal",
}

/* ------------------------------------------------------------------ */
/* Baca — daftar agregat per nomor_dokumen (rawSQL CTE VERBATIM)        */
/* ------------------------------------------------------------------ */

// List — daftar picking agregat GROUP BY nomor_dokumen pada gerakan TERBUKA
// (bukan SELESAI/BATAL); filter jenis/gudang/search/onlyTahapBelumAkhir.
// HAVING bekerja di dalam CTE agg (kolom baris). Sort whitelist 2 kolom,
// default tanggal_jadwal ASC lalu nomor_dokumen ASC.
func (r *PickingRepository) List(ctx context.Context, exec DBTX, f PickingListFilter) ([]PickingLangkahView, int, error) {
	// Filter baris (WHERE) — gudang via EXISTS lokasi sumber/tujuan.
	kondisi := []string{
		"g.deleted_at IS NULL AND h.deleted_at IS NULL",
		"h.status NOT IN ('SELESAI', 'BATAL')",
		"TRUE",
		"TRUE",
		"TRUE",
	}
	args := []any{}
	if f.Jenis != nil && *f.Jenis != "" {
		args = append(args, *f.Jenis)
		kondisi[2] = fmt.Sprintf("h.jenis::text = $%d", len(args))
	}
	if f.Search != nil && *f.Search != "" {
		args = append(args, "%"+*f.Search+"%")
		kondisi[3] = fmt.Sprintf("h.nomor_dokumen ILIKE $%d", len(args))
	}
	if f.IDGudang != nil {
		args = append(args, *f.IDGudang)
		kondisi[4] = fmt.Sprintf(`EXISTS (
			SELECT 1 FROM inv_lokasi_stok l
			WHERE l.deleted_at IS NULL
			  AND l.id_inv_gudang = $%d
			  AND (l.id = COALESCE(g.id_lokasi_sumber, h.id_lokasi_sumber)
				OR l.id = COALESCE(g.id_lokasi_tujuan, h.id_lokasi_tujuan))
		)`, len(args))
	}
	whereSQL := strings.Join(kondisi, " AND ")
	havingSQL := ""
	if f.OnlyBelumAkhir {
		havingSQL = "HAVING MAX(langkah) < MAX(total_langkah)"
	}
	kolom, ada := pickingSortKolom[f.SortCol]
	if !ada {
		kolom = "tanggal_jadwal"
	}
	arah := "ASC"
	if f.SortDesc {
		arah = "DESC"
	}
	args = append(args, f.Limit, f.Offset)
	phLimit := fmt.Sprintf("$%d", len(args)-1)
	phOffset := fmt.Sprintf("$%d", len(args))

	sqlList := fmt.Sprintf(`
		WITH baris AS (
			SELECT h.nomor_dokumen, h.jenis, h.kode_jenis_operasi, h.langkah,
			       h.total_langkah, h.status, g.qty_diminta, g.qty_selesai,
			       h.tanggal_jadwal, h.reservasi
			FROM inv_gerakan_stok g
			JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
			WHERE %s
		),
		agg AS (
			SELECT nomor_dokumen,
			       MAX(jenis::text) AS jenis,
			       MAX(kode_jenis_operasi) AS kode_jenis_operasi,
			       MAX(langkah)::int AS langkah,
			       MAX(total_langkah)::int AS total_langkah,
			       mode() WITHIN GROUP (ORDER BY status::text) AS status_dominan,
			       COUNT(*)::int AS jumlah_baris,
			       SUM(qty_diminta)::int AS qty_diminta,
			       SUM(qty_selesai)::int AS qty_selesai,
			       MIN(tanggal_jadwal) AS tanggal_jadwal,
			       BOOL_OR(reservasi = 'TERRESERVASI') AS reservasi
			FROM baris
			GROUP BY nomor_dokumen
			%s
		)
		SELECT * FROM agg ORDER BY %s %s, nomor_dokumen ASC LIMIT %s OFFSET %s
	`, whereSQL, havingSQL, kolom, arah, phLimit, phOffset)

	rows, err := exec.Query(ctx, sqlList, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	mentah := []AgregatPicking{}
	for rows.Next() {
		var jenis, status any
		var tanggal time.Time
		var a AgregatPicking
		if err := rows.Scan(
			&a.NomorDokumen, &jenis, &a.KodeJenisOperasi,
			&a.Langkah, &a.TotalLangkah, &status,
			&a.JumlahBaris, &a.QtyDiminta, &a.QtySelesai,
			&tanggal, &a.Reservasi,
		); err != nil {
			return nil, 0, err
		}
		if s, ok := jenis.(string); ok {
			a.Jenis = s
		}
		if s, ok := status.(string); ok {
			a.StatusDominan = s
		}
		a.TanggalJadwal = maIsoWaktu(tanggal)
		mentah = append(mentah, a)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	// Total — CTE sama (tanpa ORDER/LIMIT/OFFSET), count agregat.
	sqlCount := fmt.Sprintf(`
		WITH baris AS (
			SELECT h.nomor_dokumen, h.langkah, h.total_langkah
			FROM inv_gerakan_stok g
			JOIN inv_gerakan_header h ON h.id = g.id_inv_gerakan_header
			WHERE %s
		),
		agg AS (
			SELECT nomor_dokumen, MAX(langkah) AS langkah, MAX(total_langkah) AS total_langkah
			FROM baris GROUP BY nomor_dokumen %s
		)
		SELECT COUNT(*)::int AS total FROM agg
	`, whereSQL, havingSQL)
	var total int32
	if err := exec.QueryRow(ctx, sqlCount, args[:len(args)-2]...).Scan(&total); err != nil {
		return nil, 0, err
	}

	jenisOperasi, err := r.MuatJenisOperasi(ctx, exec)
	if err != nil {
		return nil, 0, err
	}
	out := make([]PickingLangkahView, 0, len(mentah))
	for i := range mentah {
		out = append(out, ToViewPicking(mentah[i], jenisOperasi))
	}
	return out, int(total), nil
}

/* ------------------------------------------------------------------ */
/* Detail / majukan tahap (D-25)                                        */
/* ------------------------------------------------------------------ */

// GerakanStokIdsByNomor — id semua baris gerakan satu nomor (urut id).
func (r *PickingRepository) GerakanStokIdsByNomor(ctx context.Context, exec DBTX, nomor string) ([]int64, error) {
	rows, err := gen.New(exec).GerakanStokIdsByNomor(ctx, nomor)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row)
	}
	return ids, nil
}

// MuatViewGerakan — view gerakan FLAT by set id (delegasi get picking —
// padanan GerakanService.viewsByIds → repo.muatView; enrichment baris ADJ
// via entityIdSumber "{uuid header}:{id item}").
func (r *PickingRepository) MuatViewGerakan(ctx context.Context, exec DBTX, ids []int64) ([]GerakanStokView, error) {
	if len(ids) == 0 {
		return []GerakanStokView{}, nil
	}
	rows, err := gen.New(exec).GerakanStokViewByIds(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]GerakanStokView, 0, len(rows))
	for _, row := range rows {
		out = append(out, GerakanStokView{
			ID:               row.ID,
			NomorDokumen:     row.NomorDokumen,
			Jenis:            string(row.JenisHeader),
			Status:           string(row.StatusHeader),
			Langkah:          int(row.Langkah),
			TotalLangkah:     int(row.TotalLangkah),
			Reservasi:        string(row.Reservasi),
			IDInvProduk:      row.IDInvProduk,
			KodeProduk:       row.KodeProduk,
			NamaProduk:       row.NamaProduk,
			IDInvLotSerial:   maI8Ptr(row.IDInvLotSerial),
			KodeLot:          maTxtPtr(row.KodeLot),
			IDInvUnitUkur:    row.IDInvUnitUkur,
			KodeUnit:         row.KodeUnit,
			QtyDiminta:       int(row.QtyDiminta),
			QtySelesai:       int(row.QtySelesai),
			IDLokasiSumber:   int64(row.IDLokasiSumberEfektif),
			KodeLokasiSumber: row.KodeSumber,
			NamaLokasiSumber: row.NamaSumber,
			IDLokasiTujuan:   int64(row.IDLokasiTujuanEfektif),
			KodeLokasiTujuan: row.KodeTujuan,
			NamaLokasiTujuan: row.NamaTujuan,
			NilaiPersatuan:   maAngkaPtr(row.NilaiPersatuan),
			TanggalJadwal:    maIso(row.TanggalJadwal),
			TanggalSelesai:   opIsoPtr(row.TanggalSelesai),
			JenisSumber:      row.JenisSumber,
			EntityIDSumber:   maTxtPtr(row.EntityIDSumber),
			Alasan:           maTxtPtr(row.Alasan),
			JenisPenyesuaian: opNullEnumStr(row.JenisPenyesuaian),
			QtySistem:        i4Int(maI4Ptr(row.QtySistem)),
			QtyHitung:        i4Int(maI4Ptr(row.QtyHitung)),
			QtySelisih:       i4Int(maI4Ptr(row.QtySelisih)),
			Version:          row.Version,
			CreatedAt:        maIso(row.CreatedAt),
			UpdatedAt:        maIso(row.UpdatedAt),
		})
	}
	return out, nil
}

// HeaderByNomor — header dokumen hidup by nomor; nil bila tidak ada.
func (r *PickingRepository) HeaderByNomor(ctx context.Context, exec DBTX, nomor string) (*gen.InvGerakanHeader, error) {
	rows, err := gen.New(exec).GerakanHeaderByNomor(ctx, nomor)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// JenisOperasiIdByKode — id master jenis operasi hidup by kode; nil bila
// tak dikenal (INV-020).
func (r *PickingRepository) JenisOperasiIdByKode(ctx context.Context, exec DBTX, kode string) (*int64, error) {
	rows, err := gen.New(exec).JenisOperasiIdByKode(ctx, kode)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	id := rows[0]
	return &id, nil
}

// UpdateHeaderLangkah — majukan tahap: UPDATE header by id (langkah+1,
// version+1 — SATU baris, PATCH 09).
func (r *PickingRepository) UpdateHeaderLangkah(ctx context.Context, exec DBTX, id int64, langkah, version int32, at time.Time) error {
	return gen.New(exec).UpdateGerakanHeaderLangkah(ctx, gen.UpdateGerakanHeaderLangkahParams{
		Langkah:   langkah,
		Version:   version,
		UpdatedAt: maWaktu(at),
		ID:        id,
	})
}

// AgregatNomorTerbuka — view agregat pasca-update (baris TERBUKA saja;
// kode_jenis_operasi NULL-able → dikonversi manual dari hasil ANY-scan).
func (r *PickingRepository) AgregatNomorTerbuka(ctx context.Context, exec DBTX, nomor string) (*AgregatPicking, error) {
	rows, err := gen.New(exec).AgregatNomorTerbuka(ctx, nomor)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	row := rows[0]
	var kodeOperasi *string
	if row.KodeJenisOperasi != nil {
		if s, ok := row.KodeJenisOperasi.(string); ok {
			kodeOperasi = &s
		}
	}
	return &AgregatPicking{
		NomorDokumen:     row.NomorDokumen,
		Jenis:            row.Jenis,
		KodeJenisOperasi: kodeOperasi,
		Langkah:          int(row.Langkah),
		TotalLangkah:     int(row.TotalLangkah),
		StatusDominan:    row.StatusDominan,
		JumlahBaris:      int(row.JumlahBaris),
		QtyDiminta:       int(row.QtyDiminta),
		QtySelesai:       int(row.QtySelesai),
		TanggalJadwal:    maIso(row.TanggalJadwal),
		Reservasi:        row.Reservasi,
	}, nil
}

/* ------------------------------------------------------------------ */
/* Master jenis operasi & mapper                                        */
/* ------------------------------------------------------------------ */

// MuatJenisOperasi — peta kode jenis operasi → { nama, label langkah }
// (tabel kecil, dimuat utuh).
func (r *PickingRepository) MuatJenisOperasi(ctx context.Context, exec DBTX) (map[string]JenisOperasiLabel, error) {
	rows, err := gen.New(exec).JenisOperasiSemua(ctx)
	if err != nil {
		return nil, err
	}
	out := make(map[string]JenisOperasiLabel, len(rows))
	for _, row := range rows {
		langkah := []string{}
		for _, n := range []*string{&row.NamaLangkah1, maTxtPtr(row.NamaLangkah2), maTxtPtr(row.NamaLangkah3)} {
			if n != nil {
				langkah = append(langkah, *n)
			}
		}
		if int(row.JumlahLangkah) < len(langkah) {
			langkah = langkah[:row.JumlahLangkah]
		}
		out[row.Kode] = JenisOperasiLabel{Nama: row.Nama, Langkah: langkah}
	}
	return out, nil
}

// ToViewPicking — mapper agregat → PickingLangkahView (kunci cermin
// views.ts) — publik utk service pasca-update langkah (majukanLangkah).
func ToViewPicking(a AgregatPicking, jenisOperasi map[string]JenisOperasiLabel) PickingLangkahView {
	var jo *JenisOperasiLabel
	if a.KodeJenisOperasi != nil {
		if v, ada := jenisOperasi[*a.KodeJenisOperasi]; ada {
			jo = &v
		}
	}
	namaLangkahAktif := fmt.Sprintf("Tahap %d", a.Langkah)
	if jo != nil && a.Langkah-1 < len(jo.Langkah) {
		namaLangkahAktif = jo.Langkah[a.Langkah-1]
	}
	// Langkah berikutnya dari master jenis operasi; null = sudah langkah akhir.
	var namaLangkahBerikut *string
	if a.Langkah < a.TotalLangkah {
		s := fmt.Sprintf("Tahap %d", a.Langkah+1)
		if jo != nil && a.Langkah < len(jo.Langkah) {
			s = jo.Langkah[a.Langkah]
		}
		namaLangkahBerikut = &s
	}
	var namaJenisOperasi *string
	if jo != nil {
		namaJenisOperasi = &jo.Nama
	}
	reservasi := "TIDAK"
	if a.Reservasi {
		reservasi = "TERRESERVASI"
	}
	return PickingLangkahView{
		NomorDokumen:       a.NomorDokumen,
		KodeJenisOperasi:   a.KodeJenisOperasi,
		NamaJenisOperasi:   namaJenisOperasi,
		Jenis:              a.Jenis,
		Langkah:            a.Langkah,
		TotalLangkah:       a.TotalLangkah,
		NamaLangkahAktif:   namaLangkahAktif,
		NamaLangkahBerikut: namaLangkahBerikut,
		StatusAgregat:      a.StatusDominan,
		JumlahBaris:        a.JumlahBaris,
		QtyDiminta:         a.QtyDiminta,
		QtySelesai:         a.QtySelesai,
		TanggalJadwal:      a.TanggalJadwal,
		Reservasi:          reservasi,
	}
}
