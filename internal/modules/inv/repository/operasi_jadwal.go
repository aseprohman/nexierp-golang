// operasi_jadwal.go — repository fitur JADWAL HITUNG modul inv (padanan
// repositories/operasi/jadwal-hitung.repository.ts NestJS, patch 04 P1 #7):
// penjadwalan cycle count per gudang/lokasi + eksekusi generate draft
// `inv_penyesuaian_stok` jenis CYCLE_COUNT (count sheet: qty_sistem dari
// saldo READMODEL, qty_hitung 0 — approval tetap lewat alur penyesuaian
// biasa, SoD terjaga). Aturan murni BatasJatuhTempo TIDAK di sini (milik
// domain/jadwal.go); audit/penomoran tetap di service.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/inv/repository/gen"
)

// JadwalHitungRepository — SATU-SATUNYA pengguna query inv operasi fitur
// jadwal hitung.
type JadwalHitungRepository struct{}

// NewJadwalHitungRepository membuat repository jadwal hitung.
func NewJadwalHitungRepository() *JadwalHitungRepository { return &JadwalHitungRepository{} }

// JadwalListFilter — filter daftar jadwal (parsed service dari PageRequest).
type JadwalListFilter struct {
	IDGudang *int64
	Aktif    *string // "1"/"true" → aktif; "0"/"false" → nonaktif; lain → tanpa filter
	Search   *string
	SortCol  string // whitelist: kode|created_at|createdAt|updatedAt
	SortDesc bool
	Limit    int32
	Offset   int32
}

// JadwalAktifFilter — terjemahan filter teks `aktif` → boolean SQL (verbatim
// aktif === "1" || "true" → true; "0"/"false" → false; else undefined).
func JadwalAktifFilter(aktif *string) *bool {
	if aktif == nil {
		return nil
	}
	switch *aktif {
	case "1", "true":
		v := true
		return &v
	case "0", "false":
		v := false
		return &v
	}
	return nil
}

// JadwalToView — mapper baris jadwal (+ kode gudang/lokasi join) → view.
func JadwalToView(
	id int64, kode, nama string, idGudang int64, kodeGudang string,
	idLokasi *int64, kodeLokasi *string,
	frekuensi string, hariEksekusi int, aktif bool,
	terakhirDibuatPada *string, version int32, createdAt, updatedAt string,
) JadwalHitungView {
	return JadwalHitungView{
		ID:                 id,
		Kode:               kode,
		Nama:               nama,
		IDInvGudang:        idGudang,
		KodeGudang:         kodeGudang,
		IDInvLokasiStok:    idLokasi,
		KodeLokasi:         kodeLokasi,
		Frekuensi:          frekuensi,
		HariEksekusi:       hariEksekusi,
		Aktif:              aktif,
		TerakhirDibuatPada: terakhirDibuatPada,
		Version:            version,
		CreatedAt:          createdAt,
		UpdatedAt:          updatedAt,
	}
}

// jadwalRowToView — mapper baris gen (list/detail sama bentuk kolom).
func jadwalRowToView(row gen.ListJadwalHitungRow) JadwalHitungView {
	return JadwalToView(
		row.ID, row.Kode, row.Nama, row.IDInvGudang, row.KodeGudang,
		maI8Ptr(row.IDInvLokasiStok), maTxtPtr(row.KodeLokasi),
		string(row.Frekuensi), int(row.HariEksekusi), row.Aktif,
		opIsoPtr(row.TerakhirDibuatPada), row.Version, maIso(row.CreatedAt), maIso(row.UpdatedAt),
	)
}

/* ------------------------------------------------------------------ */
/* Baca — daftar / detail                                               */
/* ------------------------------------------------------------------ */

// ListJadwal — daftar jadwal paging (filter gudang/aktif + search kode/nama).
func (r *JadwalHitungRepository) ListJadwal(ctx context.Context, exec DBTX, f JadwalListFilter) ([]JadwalHitungView, int, error) {
	g := gen.New(exec)
	aktif := JadwalAktifFilter(f.Aktif)
	p := gen.ListJadwalHitungParams{
		IDGudang: maI8Nilai(f.IDGudang),
		Aktif:    opBool(aktif),
		Search:   maTeksNihil(f.Search),
		SortCol:  f.SortCol,
		SortDesc: f.SortDesc,
		Limit:    f.Limit,
		Offset:   f.Offset,
	}
	rows, err := g.ListJadwalHitung(ctx, p)
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountJadwalHitung(ctx, gen.CountJadwalHitungParams{IDGudang: p.IDGudang, Aktif: p.Aktif, Search: p.Search})
	if err != nil {
		return nil, 0, err
	}
	out := make([]JadwalHitungView, 0, len(rows))
	for _, row := range rows {
		out = append(out, jadwalRowToView(row))
	}
	return out, int(total), nil
}

// MuatViewById — satu jadwal (JOIN kode gudang/lokasi) → view; nil bila
// tidak ada (404 di service dengan pesan id mentah).
func (r *JadwalHitungRepository) MuatViewById(ctx context.Context, exec DBTX, id int64) (*JadwalHitungView, error) {
	rows, err := gen.New(exec).JadwalHitungViewById(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	row := rows[0]
	v := JadwalToView(
		row.ID, row.Kode, row.Nama, row.IDInvGudang, row.KodeGudang,
		maI8Ptr(row.IDInvLokasiStok), maTxtPtr(row.KodeLokasi),
		string(row.Frekuensi), int(row.HariEksekusi), row.Aktif,
		opIsoPtr(row.TerakhirDibuatPada), row.Version, maIso(row.CreatedAt), maIso(row.UpdatedAt),
	)
	return &v, nil
}

// JadwalHidupById — jadwal hidup by id (404 di service); baris penuh.
func (r *JadwalHitungRepository) JadwalHidupById(ctx context.Context, exec DBTX, id int64) (*gen.InvJadwalHitung, error) {
	row, err := gen.New(exec).JadwalHitungHidupById(ctx, id)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// KodeDipakai — true bila jadwal HIDUP lain berkode sama (soft-delete aware).
func (r *JadwalHitungRepository) KodeDipakai(ctx context.Context, exec DBTX, kode string, kecualiID *int64) (bool, error) {
	rows, err := gen.New(exec).JadwalKodeDipakai(ctx, gen.JadwalKodeDipakaiParams{
		Kode:      kode,
		KecualiID: maI8Nilai(kecualiID),
	})
	if err != nil {
		return false, err
	}
	return len(rows) > 0, nil
}

/* ------------------------------------------------------------------ */
/* Tulis — jadwal                                                       */
/* ------------------------------------------------------------------ */

// InsertJadwal — insert jadwal baru → baris lengkap.
func (r *JadwalHitungRepository) InsertJadwal(ctx context.Context, exec DBTX, p gen.InsertJadwalHitungParams) (*gen.InvJadwalHitung, error) {
	row, err := gen.New(exec).InsertJadwalHitung(ctx, p)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// UpdatePatch — update jadwal hidup by id (patch penuh + version+1).
func (r *JadwalHitungRepository) UpdatePatch(ctx context.Context, exec DBTX, p gen.UpdateJadwalHitungPatchParams) error {
	return gen.New(exec).UpdateJadwalHitungPatch(ctx, p)
}

// SoftDelete — hapus lunak (jadwal tak direferensikan — aman).
func (r *JadwalHitungRepository) SoftDelete(ctx context.Context, exec DBTX, id int64, at time.Time) error {
	return gen.New(exec).SoftDeleteJadwalHitung(ctx, gen.SoftDeleteJadwalHitungParams{
		DeletedAt: maWaktu(at),
		UpdatedAt: maWaktu(at),
		ID:        id,
	})
}

// StampGenerate — jejak generate (terakhir_dibuat_pada + version+1).
func (r *JadwalHitungRepository) StampGenerate(ctx context.Context, exec DBTX, id int64, at time.Time, version int32) error {
	return gen.New(exec).StampJadwalHitungGenerate(ctx, gen.StampJadwalHitungGenerateParams{
		TerakhirDibuatPada: maWaktu(at),
		Version:            version,
		UpdatedAt:          maWaktu(at),
		ID:                 id,
	})
}

/* ------------------------------------------------------------------ */
/* Generate cycle count                                                 */
/* ------------------------------------------------------------------ */

// LokasiInternalGudang — id lokasi INTERNAL hidup satu gudang (lingkup
// hitung bila jadwal tanpa lokasi terpilih).
func (r *JadwalHitungRepository) LokasiInternalGudang(ctx context.Context, exec DBTX, idGudang int64) ([]int64, error) {
	rows, err := gen.New(exec).LokasiInternalSemuaGudang(ctx, idGudang)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row)
	}
	return ids, nil
}

// SaldoLingkupHitung — items count sheet dari READMODEL saldo (qty_sistem =
// on-hand >0, JOIN produk utk unit/biaya/nama snapshot; urut id stabil).
func (r *JadwalHitungRepository) SaldoLingkupHitung(ctx context.Context, exec DBTX, lokasiIDs []int64) ([]gen.SaldoLingkupHitungRow, error) {
	return gen.New(exec).SaldoLingkupHitung(ctx, lokasiIDs)
}

// InsertPenyesuaianHeader — insert header draft CYCLE_COUNT → baris lengkap
// (nilai dibangun service).
func (r *JadwalHitungRepository) InsertPenyesuaianHeader(ctx context.Context, exec DBTX, p gen.InsertPenyesuaianParams) (*gen.InvPenyesuaianStok, error) {
	row, err := gen.New(exec).InsertPenyesuaian(ctx, p)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// InsertPenyesuaianItem — insert satu baris count sheet (nilai dibangun service).
func (r *JadwalHitungRepository) InsertPenyesuaianItem(ctx context.Context, exec DBTX, p gen.InsertPenyesuaianItemParams) error {
	return gen.New(exec).InsertPenyesuaianItem(ctx, p)
}

// opBool — *bool → pgtype.Bool (nil = NULL).
func opBool(v *bool) pgtype.Bool {
	if v == nil {
		return pgtype.Bool{}
	}
	return pgtype.Bool{Bool: *v, Valid: true}
}
