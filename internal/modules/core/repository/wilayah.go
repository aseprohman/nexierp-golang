// Package repository — SATU-SATUNYA pengguna pgx+sqlc modul core.
// wilayah.go — fitur WILAYAH (lookup referensi wilayah Indonesia, READ-ONLY
// — tanpa mutasi; referensi diisi seed): padanan WilayahRepository NestJS.
// Mirror tabel MASTER core_provinsi → core_kota → core_kecamatan →
// core_kelurahan (ddl/42-core-wilayah). Query sqlc di db/queries/core/
// wilayah.sql; baris → view di sini. Executor (pool | tx) diteruskan caller.
package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// WilayahRepository — lookup baca-saja (service meneruskan executor).
type WilayahRepository struct{}

// NewWilayahRepository membuat repository lookup wilayah.
func NewWilayahRepository() *WilayahRepository { return &WilayahRepository{} }

// ListQuery — kriteria list lookup: search nama (opsional) + sort kanonik
// (” = default level itu — nama ASC) + paging. Sort/limit diputuskan
// service (whitelist), repository hanya mengeksekusi.
type ListQuery struct {
	Search   *string
	SortCol  string
	SortDesc bool
	Limit    int32
	Offset   int32
}

func (q ListQuery) searchNarg() pgtype.Text { return teksNihil(q.Search) }

// ---------------------------------------------------------------------
// Provinsi
// ---------------------------------------------------------------------

// ListProvinsi — halaman provinsi hidup + total (meta pagination).
func (r *WilayahRepository) ListProvinsi(ctx context.Context, exec gen.DBTX, q ListQuery) ([]types.WilayahProvinsiView, int32, error) {
	rows, err := gen.New(exec).ListProvinsi(ctx, gen.ListProvinsiParams{
		Search:   q.searchNarg(),
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := gen.New(exec).CountProvinsi(ctx, q.searchNarg())
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.WilayahProvinsiView, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.WilayahProvinsiView{
			ID:      row.ID,
			Kode:    row.Kode,
			Nama:    row.Nama,
			Version: row.Version,
		})
	}
	return out, total, nil
}

// GetProvinsi — satu provinsi hidup — 404 NOTF-404 bila absen.
func (r *WilayahRepository) GetProvinsi(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahProvinsiView, error) {
	rows, err := gen.New(exec).MuatProvinsiByID(ctx, id)
	if err != nil {
		return types.WilayahProvinsiView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahProvinsiView{}, errkontrak.NotFound(
			notFoundLookup("Provinsi", id),
		)
	}
	row := rows[0]
	return types.WilayahProvinsiView{ID: row.ID, Kode: row.Kode, Nama: row.Nama, Version: row.Version}, nil
}

// ---------------------------------------------------------------------
// Kota (kabupaten/kota)
// ---------------------------------------------------------------------

// ListKota — halaman kota hidup satu provinsi (+jenis opsional) + total.
func (r *WilayahRepository) ListKota(ctx context.Context, exec gen.DBTX, idProvinsi int64, jenis *string, q ListQuery) ([]types.WilayahKotaView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListKota(ctx, gen.ListKotaParams{
		IDProvinsi: idProvinsi,
		Jenis:      teksNihil(jenis),
		Search:     q.searchNarg(),
		SortCol:    q.SortCol,
		SortDesc:   q.SortDesc,
		Limit:      q.Limit,
		Offset:     q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountKota(ctx, gen.CountKotaParams{
		IDProvinsi: idProvinsi,
		Jenis:      teksNihil(jenis),
		Search:     q.searchNarg(),
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.WilayahKotaView, 0, len(rows))
	for _, row := range rows {
		// CHECK ck_core_kota_jenis menjamin 'KOTA' | 'KABUPATEN'.
		out = append(out, types.WilayahKotaView{
			ID:             row.ID,
			Kode:           row.Kode,
			Nama:           row.Nama,
			Jenis:          row.Jenis,
			IDCoreProvinsi: row.IDCoreProvinsi,
			ProvinsiNama:   row.ProvinsiNama,
			Version:        row.Version,
		})
	}
	return out, total, nil
}

// GetKota — satu kota + nama provinsi — 404 NOTF-404 bila absen.
func (r *WilayahRepository) GetKota(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKotaView, error) {
	rows, err := gen.New(exec).MuatKotaByID(ctx, id)
	if err != nil {
		return types.WilayahKotaView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKotaView{}, errkontrak.NotFound(
			notFoundLookup("Kota", id),
		)
	}
	row := rows[0]
	return types.WilayahKotaView{
		ID:             row.ID,
		Kode:           row.Kode,
		Nama:           row.Nama,
		Jenis:          row.Jenis,
		IDCoreProvinsi: row.IDCoreProvinsi,
		ProvinsiNama:   row.ProvinsiNama,
		Version:        row.Version,
	}, nil
}

// ---------------------------------------------------------------------
// Kecamatan
// ---------------------------------------------------------------------

// ListKecamatan — halaman kecamatan hidup satu kota + total.
func (r *WilayahRepository) ListKecamatan(ctx context.Context, exec gen.DBTX, idKota int64, q ListQuery) ([]types.WilayahKecamatanView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListKecamatan(ctx, gen.ListKecamatanParams{
		IDKota:   idKota,
		Search:   q.searchNarg(),
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountKecamatan(ctx, gen.CountKecamatanParams{IDKota: idKota, Search: q.searchNarg()})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.WilayahKecamatanView, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.WilayahKecamatanView{
			ID:         row.ID,
			Kode:       row.Kode,
			Nama:       row.Nama,
			IDCoreKota: row.IDCoreKota,
			KotaNama:   row.KotaNama,
			Version:    row.Version,
		})
	}
	return out, total, nil
}

// GetKecamatan — satu kecamatan + nama kota — 404 NOTF-404 bila absen.
func (r *WilayahRepository) GetKecamatan(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKecamatanView, error) {
	rows, err := gen.New(exec).MuatKecamatanByID(ctx, id)
	if err != nil {
		return types.WilayahKecamatanView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKecamatanView{}, errkontrak.NotFound(
			notFoundLookup("Kecamatan", id),
		)
	}
	row := rows[0]
	return types.WilayahKecamatanView{
		ID:         row.ID,
		Kode:       row.Kode,
		Nama:       row.Nama,
		IDCoreKota: row.IDCoreKota,
		KotaNama:   row.KotaNama,
		Version:    row.Version,
	}, nil
}

// ---------------------------------------------------------------------
// Kelurahan/desa + kode pos
// ---------------------------------------------------------------------

// ListKelurahan — halaman kelurahan hidup satu kecamatan (kodePos filter
// PERSIS) + total.
func (r *WilayahRepository) ListKelurahan(ctx context.Context, exec gen.DBTX, idKecamatan int64, kodePos *string, q ListQuery) ([]types.WilayahKelurahanView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListKelurahan(ctx, gen.ListKelurahanParams{
		IDKecamatan: idKecamatan,
		KodePos:     teksNihil(kodePos),
		Search:      q.searchNarg(),
		SortCol:     q.SortCol,
		SortDesc:    q.SortDesc,
		Limit:       q.Limit,
		Offset:      q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountKelurahan(ctx, gen.CountKelurahanParams{
		IDKecamatan: idKecamatan,
		KodePos:     teksNihil(kodePos),
		Search:      q.searchNarg(),
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.WilayahKelurahanView, 0, len(rows))
	for _, row := range rows {
		out = append(out, kelurahanView(row.ID, row.Kode, row.Nama, row.KodePos, row.IDCoreKecamatan, row.KecamatanNama, row.Version))
	}
	return out, total, nil
}

// GetKelurahan — satu kelurahan + RANTAI LENGKAP (kecamatan/kota/provinsi —
// nama & kode) — bahan alamat member & payload ongkir SHP (M55). 404 bila absen.
func (r *WilayahRepository) GetKelurahan(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKelurahanLengkapView, error) {
	rows, err := gen.New(exec).MuatKelurahanLengkap(ctx, id)
	if err != nil {
		return types.WilayahKelurahanLengkapView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKelurahanLengkapView{}, errkontrak.NotFound(
			notFoundLookup("Kelurahan", id),
		)
	}
	row := rows[0]
	return types.WilayahKelurahanLengkapView{
		WilayahKelurahanView: kelurahanView(
			row.ID, row.Kode, row.Nama, row.KodePos, row.IDCoreKecamatan, row.KecamatanNama, row.Version,
		),
		KodeKecamatan: row.KodeKecamatan,
		KodeKota:      row.KodeKota,
		KodeProvinsi:  row.KodeProvinsi,
		KotaNama:      row.KotaNama,
		ProvinsiNama:  row.ProvinsiNama,
	}, nil
}

// ListKodePos — daftar kelurahan ber-kode pos PERSIS (paged ringkas) + total.
func (r *WilayahRepository) ListKodePos(ctx context.Context, exec gen.DBTX, kodePos string, q ListQuery) ([]types.WilayahKelurahanView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListKodePos(ctx, gen.ListKodePosParams{
		KodePos:  kodePos,
		Search:   q.searchNarg(),
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountKodePos(ctx, gen.CountKodePosParams{KodePos: kodePos, Search: q.searchNarg()})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.WilayahKelurahanView, 0, len(rows))
	for _, row := range rows {
		out = append(out, kelurahanView(row.ID, row.Kode, row.Nama, row.KodePos, row.IDCoreKecamatan, row.KecamatanNama, row.Version))
	}
	return out, total, nil
}

// kelurahanView — mapper baris kelurahan → view (kodePos pgtype.Text → *string).
func kelurahanView(id int64, kode, nama string, kodePos pgtype.Text, idCoreKecamatan int64, kecamatanNama string, version int32) types.WilayahKelurahanView {
	var kp *string
	if kodePos.Valid {
		v := kodePos.String
		kp = &v
	}
	return types.WilayahKelurahanView{
		ID:              id,
		Kode:            kode,
		Nama:            nama,
		KodePos:         kp,
		IDCoreKecamatan: idCoreKecamatan,
		KecamatanNama:   kecamatanNama,
		Version:         version,
	}
}
