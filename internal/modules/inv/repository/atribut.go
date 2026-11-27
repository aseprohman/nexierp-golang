// repository/atribut.go — SATU-SATUNYA pengguna pgx+sqlc fitur ATRIBUT
// varian + NILAI ATRIBUT modul inv (padanan AtributRepository NestJS —
// patch 03: inv_atribut definisi WARNA/UKURAN/GRAVIR, inv_nilai_atribut
// nilai terkurasi partial unique di antara baris hidup, junction
// inv_produk_atribut guard hapus nilai yang masih dipakai varian). Mapping
// baris → view (kontrak JSON = packages/schemas inv/views.ts AtributView +
// NilaiAtributView) di sini.
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

// AtributRow — baris inv_atribut (pgtype telah dikonversi).
type AtributRow struct {
	ID        int64
	EntityID  string
	Kode      string
	Nama      string
	TipeInput string
	Status    string
	Version   int32
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

// NilaiRow — baris inv_nilai_atribut.
type NilaiRow struct {
	ID           int64
	EntityID     string
	IDInvAtribut int64
	Nilai        string
	Urutan       int32
	Status       string
	Version      int32
	CreatedAt    time.Time
	UpdatedAt    time.Time
	DeletedAt    *time.Time
}

// AtributView — kontrak respons atribut (kunci cermin atributViewSchema).
type AtributView struct {
	ID        int64  `json:"id"`
	Kode      string `json:"kode"`
	Nama      string `json:"nama"`
	TipeInput string `json:"tipeInput"`
	Status    string `json:"status"`
	Version   int32  `json:"version"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// NilaiAtributView — kontrak respons nilai atribut (kunci cermin
// nilaiAtributViewSchema — TANPA createdAt/updatedAt).
type NilaiAtributView struct {
	ID           int64  `json:"id"`
	IDInvAtribut int64  `json:"idInvAtribut"`
	KodeAtribut  string `json:"kodeAtribut"`
	NamaAtribut  string `json:"namaAtribut"`
	Nilai        string `json:"nilai"`
	Urutan       int32  `json:"urutan"`
	Status       string `json:"status"`
	Version      int32  `json:"version"`
}

// Whitelist sort atribut (persis peta kolom drizzlePageBounds sumber).
var whitelistSortAtribut = []string{"kode", "nama", "createdAt", "updatedAt"}

var kanonikSortAtribut = map[string]string{
	"kode":      "kode",
	"nama":      "nama",
	"createdAt": "created_at",
	"updatedAt": "updated_at",
}

// AtributRepository — pembungkus gen.Querier fitur atribut+nilai.
type AtributRepository struct{}

// NewAtributRepository — konstruksi repo atribut.
func NewAtributRepository() *AtributRepository { return &AtributRepository{} }

// fromAtributGen — konversi baris gen → baris polos.
func fromAtributGen(r gen.InvAtribut) AtributRow {
	return AtributRow{
		ID:        r.ID,
		EntityID:  mbUUIDString(r.EntityID),
		Kode:      r.Kode,
		Nama:      r.Nama,
		TipeInput: string(r.TipeInput),
		Status:    string(r.Status),
		Version:   r.Version,
		CreatedAt: r.CreatedAt.Time,
		UpdatedAt: r.UpdatedAt.Time,
		DeletedAt: mbTimePtr(r.DeletedAt),
	}
}

// fromNilaiGen — konversi baris gen → baris polos.
func fromNilaiGen(r gen.InvNilaiAtribut) NilaiRow {
	return NilaiRow{
		ID:           r.ID,
		EntityID:     mbUUIDString(r.EntityID),
		IDInvAtribut: r.IDInvAtribut,
		Nilai:        r.Nilai,
		Urutan:       r.Urutan,
		Status:       string(r.Status),
		Version:      r.Version,
		CreatedAt:    r.CreatedAt.Time,
		UpdatedAt:    r.UpdatedAt.Time,
		DeletedAt:    mbTimePtr(r.DeletedAt),
	}
}

// AtributToView — padanan atributToView.
func AtributToView(row AtributRow) AtributView {
	return AtributView{
		ID:        row.ID,
		Kode:      row.Kode,
		Nama:      row.Nama,
		TipeInput: row.TipeInput,
		Status:    row.Status,
		Version:   row.Version,
		CreatedAt: mbIso(pgtypeTz(row.CreatedAt)),
		UpdatedAt: mbIso(pgtypeTz(row.UpdatedAt)),
	}
}

// NilaiAtributToView — padanan nilaiAtributToView (butuh baris atribut
// induk utk kode/nama).
func NilaiAtributToView(row NilaiRow, atribut AtributRow) NilaiAtributView {
	return NilaiAtributView{
		ID:           row.ID,
		IDInvAtribut: row.IDInvAtribut,
		KodeAtribut:  atribut.Kode,
		NamaAtribut:  atribut.Nama,
		Nilai:        row.Nilai,
		Urutan:       row.Urutan,
		Status:       row.Status,
		Version:      row.Version,
	}
}

/* ================================================================ */
/* Atribut — baca                                                   */
/* ================================================================ */

// ListAtribut — halaman atribut varian (hidup, tanpa filter — verbatim
// sumber). Sort whitelist alias sumber, default kode ASC.
func (r *AtributRepository) ListAtribut(ctx context.Context, exec gen.DBTX, pr *errkontrak.PageRequest) (errkontrak.Page[AtributView], error) {
	if err := mbSortCek(pr, whitelistSortAtribut); err != nil {
		return errkontrak.Page[AtributView]{}, err
	}
	sortCol, sortDesc := mbSort(pr, kanonikSortAtribut)
	rows, err := gen.New(exec).ListAtribut(ctx, gen.ListAtributParams{
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Offset:   pageOffset(pr),
		Limit:    pageLimit(pr),
	})
	if err != nil {
		return errkontrak.Page[AtributView]{}, err
	}
	total, err := gen.New(exec).CountAtribut(ctx)
	if err != nil {
		return errkontrak.Page[AtributView]{}, err
	}
	views := make([]AtributView, 0, len(rows))
	for _, row := range rows {
		views = append(views, AtributToView(fromAtributGen(row)))
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// AssertAtribut — atribut hidup wajib ada — 404 INV-018 (padanan
// assertAtribut yang melempar DomainError).
func (r *AtributRepository) AssertAtribut(ctx context.Context, exec gen.DBTX, id int64) (AtributRow, error) {
	row, err := gen.New(exec).AtributHidupByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return AtributRow{}, errkontrak.NotFound(
			"Atribut id "+strconvI64(id)+" tidak ditemukan.",
			domain.KodeInvTidakDitemukan,
		)
	}
	if err != nil {
		return AtributRow{}, err
	}
	return fromAtributGen(row), nil
}

// CariByKode — atribut by kode (uq GLOBAL — TANPA filter deleted, verbatim
// sumber)? — nil bila bebas.
func (r *AtributRepository) CariByKode(ctx context.Context, exec gen.DBTX, kode string) (*int64, error) {
	id, err := gen.New(exec).AtributDupeKode(ctx, kode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

/* ================================================================ */
/* Atribut — tulis                                                  */
/* ================================================================ */

// AtributBaru — nilai insert inv_atribut (entityId dibangun service).
type AtributBaru struct {
	EntityID  string
	Kode      string
	Nama      string
	TipeInput string
	Status    string
}

// InsertAtribut — insert atribut baru → baris polos (23505 race DITITIPKAN
// mentah — dipetakan 409 pesan pre-check oleh service).
func (r *AtributRepository) InsertAtribut(ctx context.Context, exec gen.DBTX, v AtributBaru) (AtributRow, error) {
	row, err := gen.New(exec).InsertAtribut(ctx, gen.InsertAtributParams{
		EntityID:  mbUUID(v.EntityID),
		Kode:      v.Kode,
		Nama:      v.Nama,
		TipeInput: gen.EnumTipeAtribut(v.TipeInput),
		Status:    gen.EnumStatusAktif(v.Status),
	})
	if err != nil {
		return AtributRow{}, err
	}
	return fromAtributGen(row), nil
}

// AtributUbahSet — set update atribut hasil merge service (version+1 di sana).
type AtributUbahSet struct {
	Nama      string
	TipeInput string
	Status    string
	Version   int32
	UpdatedAt time.Time
}

// UpdateAtributHidup — update atribut hidup by id + predicate version
// (STD-07); nil bila kalah balapan → 409 INV-017 di service.
func (r *AtributRepository) UpdateAtributHidup(ctx context.Context, exec gen.DBTX, id int64, versiHarap int32, set AtributUbahSet) (*AtributRow, error) {
	row, err := gen.New(exec).UpdateAtributHidup(ctx, gen.UpdateAtributHidupParams{
		Nama:       set.Nama,
		TipeInput:  gen.EnumTipeAtribut(set.TipeInput),
		Status:     gen.EnumStatusAktif(set.Status),
		Version:    set.Version,
		UpdatedAt:  mbTz(set.UpdatedAt),
		ID:         id,
		VersiHarap: versiHarap,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromAtributGen(row)
	return &out, nil
}

// HitungNilaiHidup — jumlah nilai terkurasi hidup satu atribut (guard hapus
// atribut INV-002).
func (r *AtributRepository) HitungNilaiHidup(ctx context.Context, exec gen.DBTX, idAtribut int64) (int32, error) {
	return gen.New(exec).CountNilaiHidup(ctx, idAtribut)
}

// HapusLunakAtribut — soft delete atribut (TANPA bump version, verbatim).
func (r *AtributRepository) HapusLunakAtribut(ctx context.Context, exec gen.DBTX, id int64, saat time.Time) error {
	return gen.New(exec).HapusLunakAtribut(ctx, gen.HapusLunakAtributParams{
		DeletedAt: mbTz(saat),
		UpdatedAt: mbTz(saat),
		ID:        id,
	})
}

/* ================================================================ */
/* Nilai atribut — baca                                             */
/* ================================================================ */

// ListNilaiByAtribut — daftar nilai satu atribut hidup — urut urutan lalu
// nilai (BUKAN Page — verbatim sumber).
func (r *AtributRepository) ListNilaiByAtribut(ctx context.Context, exec gen.DBTX, idAtribut int64) ([]NilaiRow, error) {
	rows, err := gen.New(exec).ListNilaiByAtribut(ctx, idAtribut)
	if err != nil {
		return nil, err
	}
	out := make([]NilaiRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, fromNilaiGen(row))
	}
	return out, nil
}

// FindNilaiHidupByID — nilai atribut hidup by id — nil bila absen/terhapus.
func (r *AtributRepository) FindNilaiHidupByID(ctx context.Context, exec gen.DBTX, id int64) (*NilaiRow, error) {
	row, err := gen.New(exec).NilaiHidupByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromNilaiGen(row)
	return &out, nil
}

// CariNilaiDuplikat — duplikat (atribut, nilai) di antara baris HIDUP
// (partial unique, verbatim sumber)? — nil bila bebas.
func (r *AtributRepository) CariNilaiDuplikat(ctx context.Context, exec gen.DBTX, idAtribut int64, nilai string) (*int64, error) {
	id, err := gen.New(exec).NilaiDuplikat(ctx, gen.NilaiDuplikatParams{ID: idAtribut, Nilai: nilai})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// HitungPemakaianNilai — jumlah pemakaian nilai oleh varian (junction hidup
// — guard hapus nilai INV-002).
func (r *AtributRepository) HitungPemakaianNilai(ctx context.Context, exec gen.DBTX, idNilai int64) (int32, error) {
	return gen.New(exec).CountPemakaianNilai(ctx, idNilai)
}

/* ================================================================ */
/* Nilai atribut — tulis                                            */
/* ================================================================ */

// NilaiBaru — nilai insert inv_nilai_atribut (entityId dibangun service).
type NilaiBaru struct {
	EntityID     string
	IDInvAtribut int64
	Nilai        string
	Urutan       int32
	Status       string
}

// InsertNilai — insert nilai atribut baru → baris polos (23505 race
// DITITIPKAN mentah — dipetakan 409 pesan pre-check oleh service).
func (r *AtributRepository) InsertNilai(ctx context.Context, exec gen.DBTX, v NilaiBaru) (NilaiRow, error) {
	row, err := gen.New(exec).InsertNilai(ctx, gen.InsertNilaiParams{
		EntityID:     mbUUID(v.EntityID),
		IDInvAtribut: v.IDInvAtribut,
		Nilai:        v.Nilai,
		Urutan:       v.Urutan,
		Status:       gen.EnumStatusAktif(v.Status),
	})
	if err != nil {
		return NilaiRow{}, err
	}
	return fromNilaiGen(row), nil
}

// NilaiUbahSet — set update nilai atribut hasil merge service.
type NilaiUbahSet struct {
	Nilai     string
	Urutan    int32
	Status    string
	Version   int32
	UpdatedAt time.Time
}

// UpdateNilaiHidup — update nilai atribut hidup by id + predicate version
// (STD-07); nil bila kalah balapan → 409 INV-017 di service.
func (r *AtributRepository) UpdateNilaiHidup(ctx context.Context, exec gen.DBTX, id int64, versiHarap int32, set NilaiUbahSet) (*NilaiRow, error) {
	row, err := gen.New(exec).UpdateNilaiHidup(ctx, gen.UpdateNilaiHidupParams{
		Nilai:      set.Nilai,
		Urutan:     set.Urutan,
		Status:     gen.EnumStatusAktif(set.Status),
		Version:    set.Version,
		UpdatedAt:  mbTz(set.UpdatedAt),
		ID:         id,
		VersiHarap: versiHarap,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	out := fromNilaiGen(row)
	return &out, nil
}

// HapusLunakNilai — soft delete nilai atribut (TANPA bump version, verbatim).
func (r *AtributRepository) HapusLunakNilai(ctx context.Context, exec gen.DBTX, id int64, saat time.Time) error {
	return gen.New(exec).HapusLunakNilai(ctx, gen.HapusLunakNilaiParams{
		DeletedAt: mbTz(saat),
		UpdatedAt: mbTz(saat),
		ID:        id,
	})
}
