// service/atribut.go — orkestrasi fitur ATRIBUT varian + NILAI ATRIBUT
// modul inv (padanan AtributService NestJS — patch 03; VERBATIM urutan
// langkah, pesan & kode): atribut = definisi (WARNA/UKURAN/GRAVIR) dengan
// kode unik GLOBAL tanpa filter deleted; nilai = nilai terkurasi per
// atribut (partial unique per atribut di antara baris hidup); hapus nilai
// diblokir bila dipakai varian (junction hidup) — 409 INV-002. Optimistic
// locking BODY `version` DANDA: pre-check 409 INV-017 + atomic WHERE
// version. assertAtribut dibaca di POOL di dalam tx (verbatim sumber
// memakai this.db). TANPA data-scope (bukan wilayah 'storages').
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// AtributService — dependensi kernel + repo atribut+nilai.
type AtributService struct {
	DB    *database.DB
	Audit *audit.Service
	Repo  *repository.AtributRepository
}

// NewAtributService — wiring dari Deps modul (dipanggil handler).
func NewAtributService(d types.Deps) *AtributService {
	return &AtributService{DB: d.DB, Audit: d.Audit, Repo: repository.NewAtributRepository()}
}

/* -------------------------------------------------------------- */
/* Input                                                           */
/* -------------------------------------------------------------- */

// AtributCreateInput — body POST atribut.
type AtributCreateInput struct {
	Kode      string
	Nama      string
	TipeInput string
	Status    string
}

// AtributUpdateInput — body PATCH atribut.
type AtributUpdateInput struct {
	Nama      *string
	TipeInput string // "" = tidak dikirim
	Status    string // "" = tidak dikirim
	Version   int64
}

// NilaiCreateInput — body POST /:id/nilai (idInvAtribut body divalidasi
// handler tapi TIDAK dipakai — sumber memakai param path, verbatim).
type NilaiCreateInput struct {
	IDInvAtribut int64
	Nilai        string
	Urutan       int64
	Status       string
}

// NilaiUpdateInput — body PATCH atributnilai/:id.
type NilaiUpdateInput struct {
	Nilai   *string
	Urutan  *int64
	Status  string // "" = tidak dikirim
	Version int64
}

/* ---------------- Atribut ---------------- */

// List — daftar atribut — paginated.
func (s *AtributService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.AtributView], error) {
	return s.Repo.ListAtribut(ctx, s.DB.Pool, pr)
}

// Get — detail atribut — 404 INV-018.
func (s *AtributService) Get(ctx context.Context, id int64) (repository.AtributView, error) {
	row, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.AtributView{}, err
	}
	return repository.AtributToView(row), nil
}

// Create — buat atribut — kode unik global (race 23505 → pesan sama).
func (s *AtributService) Create(ctx context.Context, in AtributCreateInput, actor audit.Actor) (repository.AtributView, error) {
	var view repository.AtributView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		dupe, err := s.Repo.CariByKode(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dupe != nil {
			return errkontrak.Conflict(fmt.Sprintf("Kode atribut '%s' sudah dipakai.", in.Kode))
		}
		row, err := s.Repo.InsertAtribut(ctx, tx, repository.AtributBaru{
			EntityID:  numberingEntityID(),
			Kode:      in.Kode,
			Nama:      in.Nama,
			TipeInput: in.TipeInput,
			Status:    in.Status,
		})
		if err != nil {
			// Race unik kode (uq) → 409 pesan pre-check sama (ratifikasi).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode atribut '%s' sudah dipakai.", in.Kode))
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_atribut",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.AtributToView(row)
		return nil
	})
	if err != nil {
		return repository.AtributView{}, err
	}
	return view, nil
}

// Update — ubah atribut — versi wajib cocok (409 INV-017 pre-check + atomic).
func (s *AtributService) Update(ctx context.Context, id int64, in AtributUpdateInput, actor audit.Actor) (repository.AtributView, error) {
	var view repository.AtributView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		// assertAtribut di POOL di dalam tx (verbatim sumber memakai this.db).
		row, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, id)
		if err != nil {
			return err
		}
		if int64(row.Version) != in.Version {
			return versiAtributBentrok(row.Version, in.Version)
		}
		updated, err := s.Repo.UpdateAtributHidup(ctx, tx, id, row.Version, repository.AtributUbahSet{
			Nama:      mergeStr(in.Nama, row.Nama),
			TipeInput: mergeStatus(in.TipeInput, row.TipeInput),
			Status:    mergeStatus(in.Status, row.Status),
			Version:   row.Version + 1,
			UpdatedAt: time.Now(),
		})
		if err != nil {
			return err
		}
		if updated == nil {
			// Kalah balapan versi (0 baris) → 409 INV-017 lagi (ratifikasi).
			return versiAtributBentrok(row.Version, in.Version)
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_atribut",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				AfterValue: audit.Snapshot{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.AtributToView(*updated)
		return nil
	})
	if err != nil {
		return repository.AtributView{}, err
	}
	return view, nil
}

// Remove — hapus lunak atribut — blokir bila masih punya nilai hidup
// (409 INV-002).
func (s *AtributService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, id)
		if err != nil {
			return err
		}
		jumlahNilai, err := s.Repo.HitungNilaiHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if jumlahNilai > 0 {
			return errkontrak.Conflict(
				"Atribut masih punya nilai terkurasi — hapus nilai dulu.",
				domain.KodeInvHapusDiblokir,
			)
		}
		saat := time.Now()
		if err := s.Repo.HapusLunakAtribut(ctx, tx, id, saat); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_atribut",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

/* ---------------- Nilai atribut ---------------- */

// ListNilai — daftar nilai satu atribut — urut urutan (BUKAN Page).
func (s *AtributService) ListNilai(ctx context.Context, id int64) ([]repository.NilaiAtributView, error) {
	atribut, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, id)
	if err != nil {
		return nil, err
	}
	rows, err := s.Repo.ListNilaiByAtribut(ctx, s.DB.Pool, atribut.ID)
	if err != nil {
		return nil, err
	}
	views := make([]repository.NilaiAtributView, 0, len(rows))
	for _, r := range rows {
		views = append(views, repository.NilaiAtributToView(r, atribut))
	}
	return views, nil
}

// CreateNilai — tambah nilai atribut — (atribut, nilai) unik di antara
// baris hidup (race 23505 → pesan sama).
func (s *AtributService) CreateNilai(ctx context.Context, id int64, in NilaiCreateInput, actor audit.Actor) (repository.NilaiAtributView, error) {
	// assertAtribut SEBELUM tx (verbatim sumber — dipanggil di luar uow).
	atribut, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.NilaiAtributView{}, err
	}
	var view repository.NilaiAtributView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		dupe, err := s.Repo.CariNilaiDuplikat(ctx, tx, atribut.ID, in.Nilai)
		if err != nil {
			return err
		}
		if dupe != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Nilai '%s' sudah ada pada atribut %s.", in.Nilai, atribut.Kode),
			)
		}
		row, err := s.Repo.InsertNilai(ctx, tx, repository.NilaiBaru{
			EntityID:     numberingEntityID(),
			IDInvAtribut: atribut.ID,
			Nilai:        in.Nilai,
			Urutan:       int32(in.Urutan),
			Status:       in.Status,
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Nilai '%s' sudah ada pada atribut %s.", in.Nilai, atribut.Kode),
				)
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_nilai_atribut",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"atribut": atribut.Kode, "nilai": row.Nilai},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.NilaiAtributToView(row, atribut)
		return nil
	})
	if err != nil {
		return repository.NilaiAtributView{}, err
	}
	return view, nil
}

// UpdateNilai — ubah nilai atribut — versi wajib cocok (409 INV-017).
func (s *AtributService) UpdateNilai(ctx context.Context, id int64, in NilaiUpdateInput, actor audit.Actor) (repository.NilaiAtributView, error) {
	var view repository.NilaiAtributView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.FindNilaiHidupByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Nilai atribut id %d tidak ditemukan.", id),
				domain.KodeInvTidakDitemukan,
			)
		}
		if int64(row.Version) != in.Version {
			return versiNilaiBentrok(row.Version, in.Version)
		}
		// assertAtribut di POOL di dalam tx (verbatim sumber memakai this.db).
		atribut, err := s.Repo.AssertAtribut(ctx, s.DB.Pool, row.IDInvAtribut)
		if err != nil {
			return err
		}
		urutan := row.Urutan
		if in.Urutan != nil {
			urutan = int32(*in.Urutan)
		}
		updated, err := s.Repo.UpdateNilaiHidup(ctx, tx, id, row.Version, repository.NilaiUbahSet{
			Nilai:     mergeStr(in.Nilai, row.Nilai),
			Urutan:    urutan,
			Status:    mergeStatus(in.Status, row.Status),
			Version:   row.Version + 1,
			UpdatedAt: time.Now(),
		})
		if err != nil {
			return err
		}
		if updated == nil {
			// Kalah balapan versi (0 baris) → 409 INV-017 lagi (ratifikasi).
			return versiNilaiBentrok(row.Version, in.Version)
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_nilai_atribut",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				AfterValue: audit.Snapshot{"nilai": updated.Nilai, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.NilaiAtributToView(*updated, atribut)
		return nil
	})
	if err != nil {
		return repository.NilaiAtributView{}, err
	}
	return view, nil
}

// RemoveNilai — hapus lunak nilai atribut — blokir bila dipakai varian
// (junction hidup, 409 INV-002).
func (s *AtributService) RemoveNilai(ctx context.Context, id int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.FindNilaiHidupByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Nilai atribut id %d tidak ditemukan.", id),
				domain.KodeInvTidakDitemukan,
			)
		}
		dipakai, err := s.Repo.HitungPemakaianNilai(ctx, tx, id)
		if err != nil {
			return err
		}
		if dipakai > 0 {
			return errkontrak.Conflict(
				"Nilai atribut masih dipakai varian — tidak bisa dihapus.",
				domain.KodeInvHapusDiblokir,
			)
		}
		saat := time.Now()
		if err := s.Repo.HapusLunakNilai(ctx, tx, id, saat); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_nilai_atribut",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"nilai": row.Nilai},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// versiAtributBentrok — 409 INV-017 pesan verbatim.
func versiAtributBentrok(server int32, kirim int64) error {
	return errkontrak.Conflict(
		fmt.Sprintf("Versi atribut tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok,
	)
}

// versiNilaiBentrok — 409 INV-017 pesan verbatim.
func versiNilaiBentrok(server int32, kirim int64) error {
	return errkontrak.Conflict(
		fmt.Sprintf("Versi nilai atribut tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok,
	)
}
