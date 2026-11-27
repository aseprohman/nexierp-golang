// service/gudang.go — orkestrasi fitur GUDANG modul inv (padanan
// GudangService NestJS INV-F02, VERBATIM urutan langkah, pesan & kode):
// validasi domain (koordinat berpasangan 400, kelurahan CORE hidup 400) →
// SATU pgx tx (dup kode → race 23505 → 409 pesan pre-check; insert; audit;
// re-read rantai wilayah) → view.
//
// DATA-SCOPE dinamis dimensi 'storages' (core_scope_* — evaluator core/rbac
// via cakupanStorages): list/detail/ubah/hapus gudang di luar whitelist
// aktor = tidak ada (404 — paritas "tidak ada data"); tanpa assignment =
// semua (fail-open). Create tidak di-gerbang (paritas master lain).
// Optimistic locking BODY version DANDA: pre-check 409 INV-017 + UPDATE
// WHERE id+hidup+version (0 baris → 409 lagi).
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// GudangService — dependensi kernel + repo gudang.
type GudangService struct {
	DB    *database.DB
	Audit *audit.Service
	Scope *rbac.Scope
	Repo  *repository.GudangRepository
}

// NewGudangService — wiring dari Deps modul (dipanggil handler).
func NewGudangService(d types.Deps) *GudangService {
	return &GudangService{DB: d.DB, Audit: d.Audit, Scope: d.Scope, Repo: repository.NewGudangRepository()}
}

// GudangCreateInput — body POST gudang (hasil validasi handler).
type GudangCreateInput struct {
	Kode            string
	Nama            string
	KodeSatuan      *string
	Alamat          *string
	IDCoreKelurahan *int64
	Latitude        *float64
	Longitude       *float64
	Status          string
}

// GudangUpdateInput — body PATCH gudang (3-state untuk field nullish:
// Ada=false = tidak dikirim → nilai lama; Ada=true+nil = null → clear).
type GudangUpdateInput struct {
	Nama               *string
	KodeSatuanAda      bool
	KodeSatuan         *string
	AlamatAda          bool
	Alamat             *string
	IDCoreKelurahanAda bool
	IDCoreKelurahan    *int64
	LatitudeAda        bool
	Latitude           *float64
	LongitudeAda       bool
	Longitude          *float64
	Status             string // "" = tidak dikirim
	Version            int64
}

// terlihat — keanggotaan baris gudang dalam keputusan cakupan: SEMUA lolos;
// DENY_ALL / id di luar whitelist → tersembunyi.
func terlihatGudang(row *repository.GudangRantaiRow, cak *repository.CakupanStorages) bool {
	if cak == nil { // SEMUA
		return true
	}
	if cak.Deny {
		return false
	}
	for _, id := range cak.IDs {
		if id == row.ID {
			return true
		}
	}
	return false
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// List — halaman gudang rantai wilayah — ter-scope dimensi 'storages'.
func (s *GudangService) List(ctx context.Context, pr *errkontrak.PageRequest, userID int64) (errkontrak.Page[repository.GudangView], error) {
	cak, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return errkontrak.Page[repository.GudangView]{}, err
	}
	return s.Repo.ListGudang(ctx, s.DB.Pool, pr, cak)
}

// Get — detail gudang — di luar cakupan = 404 paritas "tidak ada data".
func (s *GudangService) Get(ctx context.Context, id int64, userID int64) (repository.GudangView, error) {
	cak, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return repository.GudangView{}, err
	}
	row, err := s.Repo.AssertAda(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.GudangView{}, err
	}
	if !terlihatGudang(&row, cak) {
		return repository.GudangView{}, domain.ErrGudangTersembunyi(row.ID)
	}
	return repository.GudangToView(row), nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// Create — buat gudang (201) — koordinat berpasangan wajib; dup kode → 409
// CONF-409 (race 23505 → pesan sama); kelurahan CORE wajib hidup.
func (s *GudangService) Create(ctx context.Context, in GudangCreateInput, actor audit.Actor) (repository.GudangView, error) {
	issues := []errkontrak.FieldIssue{}
	domain.KoordinatPasang(&issues, in.Latitude, in.Longitude)
	if len(issues) > 0 {
		return repository.GudangView{}, errkontrak.Validation(issues)
	}
	var view repository.GudangView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		dupe, err := s.Repo.CariDupeKode(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dupe != nil {
			return errkontrak.Conflict(fmt.Sprintf("Kode gudang '%s' sudah dipakai.", in.Kode))
		}
		var kelErr error
		issues, kelErr = s.assertKelurahanHidup(ctx, tx, in.IDCoreKelurahan, issues[:0])
		if kelErr != nil {
			return kelErr
		}
		if len(issues) > 0 {
			return errkontrak.Validation(issues)
		}
		row, err := s.Repo.InsertGudang(ctx, tx, repository.GudangBaru{
			EntityID:        numberingEntityID(),
			Kode:            in.Kode,
			Nama:            in.Nama,
			KodeSatuan:      in.KodeSatuan,
			Alamat:          in.Alamat,
			IDCoreKelurahan: in.IDCoreKelurahan,
			Latitude:        in.Latitude,
			Longitude:       in.Longitude,
			Status:          in.Status,
		})
		if err != nil {
			// Race unik kode (uq) → 409 pesan pre-check sama (ratifikasi).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode gudang '%s' sudah dipakai.", in.Kode))
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_gudang",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		rantai, err := s.Repo.RantaiByID(ctx, tx, row.ID)
		if err != nil {
			return err
		}
		if rantai == nil {
			return errkontrak.Internal("")
		}
		view = repository.GudangToView(*rantai)
		return nil
	})
	if err != nil {
		return repository.GudangView{}, err
	}
	return view, nil
}

// Update — ubah gudang — versi wajib cocok (409 INV-017 pre-check + atomic);
// scope 'storages' di-gerbang (404 tersembunyi).
func (s *GudangService) Update(ctx context.Context, id int64, in GudangUpdateInput, actor audit.Actor) (repository.GudangView, error) {
	issues := []errkontrak.FieldIssue{}
	// Pasangan koordinat dinilai pada INPUT (verbatim sumber — bukan gabungan
	// baris): kirim satu sisi saja → 400.
	domain.KoordinatPasang(&issues, in.Latitude, in.Longitude)
	if len(issues) > 0 {
		return repository.GudangView{}, errkontrak.Validation(issues)
	}
	var view repository.GudangView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		// Baris dibaca di POOL (verbatim sumber memakai this.db), scope
		// dievaluasi di tx yang sama dengan mutasi.
		row, err := s.Repo.AssertAda(ctx, s.DB.Pool, id)
		if err != nil {
			return err
		}
		cak, err := cakupanStorages(ctx, s.Scope, s.Audit, actorIDOf(actor), tx)
		if err != nil {
			return err
		}
		if !terlihatGudang(&row, cak) {
			return domain.ErrGudangTersembunyi(row.ID)
		}
		if int64(row.Version) != in.Version {
			return versiGudangBentrok(row.Version, in.Version)
		}
		issues, err = s.assertKelurahanHidup(ctx, tx, in.IDCoreKelurahan, issues[:0])
		if err != nil {
			return err
		}
		if len(issues) > 0 {
			return errkontrak.Validation(issues)
		}
		updated, err := s.Repo.UpdateGudangHidup(ctx, tx, id, row.Version, repository.GudangUbahSet{
			Nama:            mergeStr(in.Nama, row.Nama),
			KodeSatuan:      merge3(in.KodeSatuanAda, in.KodeSatuan, row.KodeSatuan),
			Alamat:          merge3(in.AlamatAda, in.Alamat, row.Alamat),
			IDCoreKelurahan: merge3(in.IDCoreKelurahanAda, in.IDCoreKelurahan, row.IDCoreKelurahan),
			Latitude:        merge3(in.LatitudeAda, in.Latitude, row.Latitude),
			Longitude:       merge3(in.LongitudeAda, in.Longitude, row.Longitude),
			Status:          mergeStatus(in.Status, row.Status),
			Version:         row.Version + 1,
			UpdatedAt:       time.Now(),
		})
		if err != nil {
			return err
		}
		if updated == nil {
			// Kalah balapan versi (0 baris) → 409 INV-017 lagi (ratifikasi).
			return versiGudangBentrok(row.Version, in.Version)
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_gudang",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				AfterValue: audit.Snapshot{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		rantai, err := s.Repo.RantaiByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if rantai == nil {
			return errkontrak.Internal("")
		}
		view = repository.GudangToView(*rantai)
		return nil
	})
	if err != nil {
		return repository.GudangView{}, err
	}
	return view, nil
}

// Remove — hapus lunak — diblokir bila masih punya lokasi stok hidup
// (409 INV-002); scope 'storages' di-gerbang (404 tersembunyi).
func (s *GudangService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertAda(ctx, s.DB.Pool, id)
		if err != nil {
			return err
		}
		cak, err := cakupanStorages(ctx, s.Scope, s.Audit, actorIDOf(actor), tx)
		if err != nil {
			return err
		}
		if !terlihatGudang(&row, cak) {
			return domain.ErrGudangTersembunyi(row.ID)
		}
		lokasi, err := s.Repo.HitungLokasi(ctx, tx, id)
		if err != nil {
			return err
		}
		if lokasi > 0 {
			return errkontrak.Conflict(
				"Gudang masih punya lokasi stok — tidak bisa dihapus.",
				domain.KodeInvHapusDiblokir,
			)
		}
		saat := time.Now()
		if err := s.Repo.HapusLunakGudang(ctx, tx, id, saat); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_gudang",
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

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// assertKelurahanHidup — kelurahan CORE harus ada & hidup (FK RESTRICT
// hanya hard delete — soft delete divalidasi di sini; SOFT-DELETE-AWARE).
func (s *GudangService) assertKelurahanHidup(ctx context.Context, tx pgx.Tx, idKelurahan *int64, issues []errkontrak.FieldIssue) ([]errkontrak.FieldIssue, error) {
	if idKelurahan == nil {
		return issues, nil
	}
	row, err := s.Repo.CariKelurahanHidup(ctx, tx, *idKelurahan)
	if err != nil {
		return issues, err
	}
	if row == nil {
		issues = append(issues, errkontrak.FieldIssue{
			Field:   "idCoreKelurahan",
			Message: "Kelurahan wilayah tidak ditemukan / sudah tidak aktif — pilih ulang dari picker.",
		})
	}
	return issues, nil
}

// versiGudangBentrok — 409 INV-017 pesan verbatim.
func versiGudangBentrok(server int32, kirim int64) error {
	return errkontrak.Conflict(
		fmt.Sprintf("Versi gudang tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok,
	)
}
