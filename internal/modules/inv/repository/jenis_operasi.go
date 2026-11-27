// repository/jenis_operasi.go — SATU-SATUNYA pengguna pgx+sqlc fitur JENIS
// OPERASI modul inv (padanan JenisOperasiRepository NestJS — patch 04 P1 #8,
// D-26: master alur operasi gudang RCV/DLV/TRF/ADJ/SCR — prefix penomoran +
// jumlah langkah 1..3 + lokasi default; tabel inv_jenis_operasi + read
// inv_lokasi_stok alias jo_sumber/jo_tujuan + inv_gerakan_header guard hapus
// INV-002). Mapping baris → view (kontrak JSON = packages/schemas
// inv/views.ts JenisOperasiView) di sini.
package repository

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository/gen"
)

// JenisOperasiRow — baris inv_jenis_operasi (pgtype telah dikonversi).
type JenisOperasiRow struct {
	ID                    int64
	EntityID              string
	Kode                  string
	Nama                  string
	JenisGerakan          string
	Prefix                string
	JumlahLangkah         int32
	NamaLangkah1          string
	NamaLangkah2          *string
	NamaLangkah3          *string
	IDLokasiSumberDefault *int64
	IDLokasiTujuanDefault *int64
	Status                string
	Version               int32
	CreatedAt             time.Time
	UpdatedAt             time.Time
	DeletedAt             *time.Time
}

// JenisOperasiDenganKode — baris jenis operasi + kode lokasi default
// ter-join (hasil muatDetail).
type JenisOperasiDenganKode struct {
	J          JenisOperasiRow
	KodeSumber *string
	KodeTujuan *string
}

// JenisOperasiView — kontrak respons (kunci cermin jenisOperasiViewSchema).
type JenisOperasiView struct {
	ID                      int64    `json:"id"`
	Kode                    string   `json:"kode"`
	Nama                    string   `json:"nama"`
	JenisGerakan            string   `json:"jenisGerakan"`
	Prefix                  string   `json:"prefix"`
	JumlahLangkah           int32    `json:"jumlahLangkah"`
	NamaLangkah             []string `json:"namaLangkah"`
	IDLokasiSumberDefault   *int64   `json:"idLokasiSumberDefault"`
	KodeLokasiSumberDefault *string  `json:"kodeLokasiSumberDefault"`
	IDLokasiTujuanDefault   *int64   `json:"idLokasiTujuanDefault"`
	KodeLokasiTujuanDefault *string  `json:"kodeLokasiTujuanDefault"`
	Status                  string   `json:"status"`
	Version                 int32    `json:"version"`
	CreatedAt               string   `json:"createdAt"`
	UpdatedAt               string   `json:"updatedAt"`
}

// Whitelist sort jenis operasi (persis peta kolom drizzlePageBounds sumber —
// termasuk alias ganda created_at/createdAt).
var whitelistSortJenisOperasi = []string{"kode", "nama", "created_at", "createdAt", "updatedAt"}

var kanonikSortJenisOperasi = map[string]string{
	"kode":       "kode",
	"nama":       "nama",
	"created_at": "created_at",
	"createdAt":  "created_at",
	"updatedAt":  "updated_at",
}

// JenisOperasiRepository — pembungkus gen.Querier fitur jenis operasi.
type JenisOperasiRepository struct{}

// NewJenisOperasiRepository — konstruksi repo jenis operasi.
func NewJenisOperasiRepository() *JenisOperasiRepository { return &JenisOperasiRepository{} }

// fromJenisOperasiGen — konversi baris RETURNING/tanpa-join → baris polos.
func fromJenisOperasiGen(r gen.InvJenisOperasi) JenisOperasiRow {
	return JenisOperasiRow{
		ID:                    r.ID,
		EntityID:              mbUUIDString(r.EntityID),
		Kode:                  r.Kode,
		Nama:                  r.Nama,
		JenisGerakan:          string(r.JenisGerakan),
		Prefix:                r.Prefix,
		JumlahLangkah:         r.JumlahLangkah,
		NamaLangkah1:          r.NamaLangkah1,
		NamaLangkah2:          mbTxt(r.NamaLangkah2),
		NamaLangkah3:          mbTxt(r.NamaLangkah3),
		IDLokasiSumberDefault: mbInt8(r.IDLokasiSumberDefault),
		IDLokasiTujuanDefault: mbInt8(r.IDLokasiTujuanDefault),
		Status:                string(r.Status),
		Version:               r.Version,
		CreatedAt:             r.CreatedAt.Time,
		UpdatedAt:             r.UpdatedAt.Time,
		DeletedAt:             mbTimePtr(r.DeletedAt),
	}
}

// rowToJenisOperasi — potong kolom jenis operasi dari baris join.
func rowToJenisOperasi(r gen.ListJenisOperasiRow) gen.InvJenisOperasi {
	return gen.InvJenisOperasi{
		ID: r.ID, EntityID: r.EntityID, Kode: r.Kode, Nama: r.Nama,
		JenisGerakan: r.JenisGerakan, Prefix: r.Prefix, JumlahLangkah: r.JumlahLangkah,
		NamaLangkah1: r.NamaLangkah1, NamaLangkah2: r.NamaLangkah2, NamaLangkah3: r.NamaLangkah3,
		IDLokasiSumberDefault: r.IDLokasiSumberDefault, IDLokasiTujuanDefault: r.IDLokasiTujuanDefault,
		Status: r.Status, Version: r.Version, CreatedAt: r.CreatedAt,
		UpdatedAt: r.UpdatedAt, DeletedAt: r.DeletedAt,
	}
}

// JenisOperasiToView — padanan toJenisOperasiView: namaLangkah = [1,2,3]
// ter-filter non-null lalu dipotong jumlahLangkah (kunci cermin views.ts).
func JenisOperasiToView(row JenisOperasiRow, kodeSumber, kodeTujuan *string) JenisOperasiView {
	namaLangkah := make([]string, 0, 3)
	for _, n := range []*string{&row.NamaLangkah1, row.NamaLangkah2, row.NamaLangkah3} {
		if n != nil {
			namaLangkah = append(namaLangkah, *n)
		}
	}
	if int32(len(namaLangkah)) > row.JumlahLangkah {
		namaLangkah = namaLangkah[:row.JumlahLangkah]
	}
	return JenisOperasiView{
		ID:                      row.ID,
		Kode:                    row.Kode,
		Nama:                    row.Nama,
		JenisGerakan:            row.JenisGerakan,
		Prefix:                  row.Prefix,
		JumlahLangkah:           row.JumlahLangkah,
		NamaLangkah:             namaLangkah,
		IDLokasiSumberDefault:   row.IDLokasiSumberDefault,
		KodeLokasiSumberDefault: kodeSumber,
		IDLokasiTujuanDefault:   row.IDLokasiTujuanDefault,
		KodeLokasiTujuanDefault: kodeTujuan,
		Status:                  row.Status,
		Version:                 row.Version,
		CreatedAt:               mbIso(pgtypeTz(row.CreatedAt)),
		UpdatedAt:               mbIso(pgtypeTz(row.UpdatedAt)),
	}
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// ListJenisOperasi — halaman jenis operasi — filter jenisGerakan (alias
// `jenis`)/status/search (kode ILIKE ATAU nama ILIKE). Sort whitelist alias
// sumber, default kode ASC.
func (r *JenisOperasiRepository) ListJenisOperasi(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest) (errkontrak.Page[JenisOperasiView], error) {
	if err := mbSortCek(pr, whitelistSortJenisOperasi); err != nil {
		return errkontrak.Page[JenisOperasiView]{}, err
	}
	// filter `jenisGerakan` ATAU alias `jenis` (verbatim sumber).
	jenis := filterVal(pr, "jenisGerakan")
	if jenis == nil {
		jenis = filterVal(pr, "jenis")
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortJenisOperasi)
	params := gen.ListJenisOperasiParams{
		Jenis:    mbTxtNil(jenis),
		Status:   mbTxtNil(filterVal(pr, "status")),
		Search:   mbTxtNil(filterVal(pr, "search")),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   pageOffset(pr),
		Limit:    pageLimit(pr),
	}
	rows, err := gen.New(exec).ListJenisOperasi(ctx, params)
	if err != nil {
		return errkontrak.Page[JenisOperasiView]{}, err
	}
	total, err := gen.New(exec).CountJenisOperasi(ctx, gen.CountJenisOperasiParams{
		Jenis:  params.Jenis,
		Status: params.Status,
		Search: params.Search,
	})
	if err != nil {
		return errkontrak.Page[JenisOperasiView]{}, err
	}
	views := make([]JenisOperasiView, 0, len(rows))
	for _, row := range rows {
		j := fromJenisOperasiGen(rowToJenisOperasi(row))
		views = append(views, JenisOperasiToView(j, mbTxt(row.KodeSumber), mbTxt(row.KodeTujuan)))
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// MuatDetail — detail jenis operasi hidup + kode lokasi default — nil bila
// absen/terhapus.
func (r *JenisOperasiRepository) MuatDetail(ctx context.Context, exec gen.DBTX, id int64) (*JenisOperasiDenganKode, error) {
	row, err := gen.New(exec).JenisOperasiDetail(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &JenisOperasiDenganKode{
		J:          fromJenisOperasiGen(rowToJenisOperasiList(row)),
		KodeSumber: mbTxt(row.KodeSumber),
		KodeTujuan: mbTxt(row.KodeTujuan),
	}, nil
}

// rowToJenisOperasiList — potong kolom jenis operasi dari baris detail.
func rowToJenisOperasiList(r gen.JenisOperasiDetailRow) gen.InvJenisOperasi {
	return gen.InvJenisOperasi{
		ID: r.ID, EntityID: r.EntityID, Kode: r.Kode, Nama: r.Nama,
		JenisGerakan: r.JenisGerakan, Prefix: r.Prefix, JumlahLangkah: r.JumlahLangkah,
		NamaLangkah1: r.NamaLangkah1, NamaLangkah2: r.NamaLangkah2, NamaLangkah3: r.NamaLangkah3,
		IDLokasiSumberDefault: r.IDLokasiSumberDefault, IDLokasiTujuanDefault: r.IDLokasiTujuanDefault,
		Status: r.Status, Version: r.Version, CreatedAt: r.CreatedAt,
		UpdatedAt: r.UpdatedAt, DeletedAt: r.DeletedAt,
	}
}

/* -------------------------------------------------------------- */
/* Guard baris & hitungan                                          */
/* -------------------------------------------------------------- */

// AssertAda — jenis operasi hidup by id — 404 INV-018 bila tidak ada
// (padanan assertAda yang melempar DomainError).
func (r *JenisOperasiRepository) AssertAda(ctx context.Context, exec gen.DBTX, id int64) (JenisOperasiRow, error) {
	row, err := gen.New(exec).JenisOperasiHidupByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return JenisOperasiRow{}, errkontrak.NotFound(
			"Jenis operasi id "+strconvI64(id)+" tidak ditemukan.",
			domain.KodeInvTidakDitemukan,
		)
	}
	if err != nil {
		return JenisOperasiRow{}, err
	}
	return fromJenisOperasiGen(row), nil
}

// CariDupeKode — kode sudah dipakai jenis operasi HIDUP lain (dengan filter
// deleted, verbatim sumber; kecualiID nil = cek semua)? — nil bila bebas.
func (r *JenisOperasiRepository) CariDupeKode(ctx context.Context, exec gen.DBTX, kode string, kecualiID *int64) (*int64, error) {
	id, err := gen.New(exec).JenisOperasiDupeKode(ctx, gen.JenisOperasiDupeKodeParams{
		Kode:      kode,
		KecualiID: mbInt8Nil(kecualiID),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// HitungGerakanPakai — jumlah gerakan hidup pemakai kode jenis operasi ini
// (guard hapus INV-002).
func (r *JenisOperasiRepository) HitungGerakanPakai(ctx context.Context, exec gen.DBTX, kode string) (int32, error) {
	return gen.New(exec).CountGerakanPakai(ctx, kode)
}

// KodeLokasiDefault — resolver kode lokasi default satu baris (batch inArray
// TANPA filter deleted — verbatim sumber; tanpa baris cocok → kode nil).
type KodeLokasiDefault struct {
	KodeSumber *string
	KodeTujuan *string
}

// ResolveKodeLokasiDefault — padanan kodeLokasiDefault: cari pasangan id →
// petakan kode sumber/tujuan (id tanpa baris → nil).
func (r *JenisOperasiRepository) ResolveKodeLokasiDefault(ctx context.Context, exec gen.DBTX, row JenisOperasiRow) (KodeLokasiDefault, error) {
	var out KodeLokasiDefault
	ids := make([]int64, 0, 2)
	if row.IDLokasiSumberDefault != nil {
		ids = append(ids, *row.IDLokasiSumberDefault)
	}
	if row.IDLokasiTujuanDefault != nil {
		ids = append(ids, *row.IDLokasiTujuanDefault)
	}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := gen.New(exec).KodeLokasiDefault(ctx, ids)
	if err != nil {
		return out, err
	}
	for _, l := range rows {
		if row.IDLokasiSumberDefault != nil && l.ID == *row.IDLokasiSumberDefault {
			k := l.Kode
			out.KodeSumber = &k
		}
		if row.IDLokasiTujuanDefault != nil && l.ID == *row.IDLokasiTujuanDefault {
			k := l.Kode
			out.KodeTujuan = &k
		}
	}
	return out, nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// JenisOperasiBaru — nilai insert inv_jenis_operasi (dibangun service).
type JenisOperasiBaru struct {
	EntityID              string
	Kode                  string
	Nama                  string
	JenisGerakan          string
	Prefix                string
	JumlahLangkah         int32
	NamaLangkah1          string
	NamaLangkah2          *string
	NamaLangkah3          *string
	IDLokasiSumberDefault *int64
	IDLokasiTujuanDefault *int64
	Status                string
}

// InsertJenisOperasi — insert jenis operasi baru → baris polos (23505 race
// DITITIPKAN mentah — dipetakan 409 pesan pre-check oleh service).
func (r *JenisOperasiRepository) InsertJenisOperasi(ctx context.Context, exec gen.DBTX, v JenisOperasiBaru) (JenisOperasiRow, error) {
	row, err := gen.New(exec).InsertJenisOperasi(ctx, gen.InsertJenisOperasiParams{
		EntityID:              mbUUID(v.EntityID),
		Kode:                  v.Kode,
		Nama:                  v.Nama,
		JenisGerakan:          gen.EnumJenisGerakan(v.JenisGerakan),
		Prefix:                v.Prefix,
		JumlahLangkah:         v.JumlahLangkah,
		NamaLangkah1:          v.NamaLangkah1,
		NamaLangkah2:          mbTxtNil(v.NamaLangkah2),
		NamaLangkah3:          mbTxtNil(v.NamaLangkah3),
		IDLokasiSumberDefault: mbInt8Nil(v.IDLokasiSumberDefault),
		IDLokasiTujuanDefault: mbInt8Nil(v.IDLokasiTujuanDefault),
		Status:                gen.EnumStatusAktif(v.Status),
	})
	if err != nil {
		return JenisOperasiRow{}, err
	}
	return fromJenisOperasiGen(row), nil
}

// JenisOperasiUbahSet — set update jenis operasi hasil merge service.
type JenisOperasiUbahSet struct {
	Kode                  string
	Nama                  string
	JenisGerakan          string
	Prefix                string
	JumlahLangkah         int32
	NamaLangkah1          string
	NamaLangkah2          *string
	NamaLangkah3          *string
	IDLokasiSumberDefault *int64
	IDLokasiTujuanDefault *int64
	Status                string
	Version               int32
	UpdatedAt             time.Time
}

// UpdateJenisOperasiHidup — update jenis operasi hidup — predicate id +
// hidup + version (STD-07); nil bila kalah balapan → 409 INV-017 di service.
func (r *JenisOperasiRepository) UpdateJenisOperasiHidup(ctx context.Context, exec gen.DBTX, id int64, versiHarap int32, set JenisOperasiUbahSet) (*JenisOperasiRow, error) {
	row, err := gen.New(exec).UpdateJenisOperasiHidup(ctx, gen.UpdateJenisOperasiHidupParams{
		Kode:                  set.Kode,
		Nama:                  set.Nama,
		JenisGerakan:          gen.EnumJenisGerakan(set.JenisGerakan),
		Prefix:                set.Prefix,
		JumlahLangkah:         set.JumlahLangkah,
		NamaLangkah1:          set.NamaLangkah1,
		NamaLangkah2:          mbTxtNil(set.NamaLangkah2),
		NamaLangkah3:          mbTxtNil(set.NamaLangkah3),
		IDLokasiSumberDefault: mbInt8Nil(set.IDLokasiSumberDefault),
		IDLokasiTujuanDefault: mbInt8Nil(set.IDLokasiTujuanDefault),
		Status:                gen.EnumStatusAktif(set.Status),
		Version:               set.Version,
		UpdatedAt:             mbTz(set.UpdatedAt),
		ID:                    id,
		VersiHarap:            versiHarap,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromJenisOperasiGen(row)
	return &out, nil
}

// HapusLunakJenisOperasi — soft delete (TANPA bump version, verbatim sumber).
func (r *JenisOperasiRepository) HapusLunakJenisOperasi(ctx context.Context, exec gen.DBTX, id int64, saat time.Time) error {
	return gen.New(exec).HapusLunakJenisOperasi(ctx, gen.HapusLunakJenisOperasiParams{
		DeletedAt: mbTz(saat),
		UpdatedAt: mbTz(saat),
		ID:        id,
	})
}
