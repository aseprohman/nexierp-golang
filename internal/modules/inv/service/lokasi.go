// service/lokasi.go — orkestrasi fitur LOKASI STOK modul inv (padanan
// LokasiService NestJS INV-F02 — node perhitungan stok, VERBATIM urutan
// langkah, pesan & kode): dup kode → 409 CONF-409 (race 23505 → pesan sama);
// hapus diblokir bila saldo ≠ 0 (409 INV-014 hitungSaldo COALESCE SUM);
// INTERNAL wajib gudang induk (INV-003 di update; create dijaga schema +
// CHECK DB).
//
// DATA-SCOPE dimensi 'storages' VIA GUDANG INDUK (evaluator core/rbac via
// cakupanStorages): scope HANYA menyentuh lokasi INTERNAL (ber-gudang
// induk). Lokasi VIRTUAL (jenis != INTERNAL — VENDOR/CUSTOMER/PRODUKSI/
// SCRAP) adalah jembatan lintas pihak tanpa pemilik gudang → SELALU tampil
// di semua mode (SEMUA/DAFTAR/DENY_ALL — keputusan pemilik 2026-11-11).
// Lokasi INTERNAL di luar whitelist gudang aktor = tidak ada (404 paritas
// list); pindah gudang ke luar whitelist → 409 INV-021; create tidak di-
// gerbang (paritas master lain).
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

// LokasiService — dependensi kernel + repo lokasi.
type LokasiService struct {
	DB    *database.DB
	Audit *audit.Service
	Scope *rbac.Scope
	Repo  *repository.LokasiRepository
}

// NewLokasiService — wiring dari Deps modul (dipanggil handler).
func NewLokasiService(d types.Deps) *LokasiService {
	return &LokasiService{DB: d.DB, Audit: d.Audit, Scope: d.Scope, Repo: repository.NewLokasiRepository()}
}

// LokasiCreateInput — body POST lokasi (hasil validasi handler — refine
// INTERNAL wajib gudang sudah dijaga schema zod-parity + CHECK DB).
type LokasiCreateInput struct {
	Kode          string
	Nama          string
	Jenis         string
	IDInvGudang   *int64
	IDLokasiInduk *int64
	Status        string
}

// LokasiUpdateInput — body PATCH lokasi (3-state nullish).
type LokasiUpdateInput struct {
	Nama             *string
	Jenis            string // "" = tidak dikirim
	IDInvGudangAda   bool
	IDInvGudang      *int64
	IDLokasiIndukAda bool
	IDLokasiInduk    *int64
	Status           string // "" = tidak dikirim
	Version          int64
}

// terlihatLokasi — keanggotaan lokasi dalam keputusan cakupan — lokasi
// virtual (jenis != INTERNAL) SELALU lolos (di luar domain dimensi
// 'storages'); INTERNAL: SEMUA lolos, DENY_ALL / gudang di luar whitelist →
// tersembunyi.
func terlihatLokasi(row *repository.LokasiRow, cak *repository.CakupanStorages) bool {
	if row.Jenis != "INTERNAL" {
		return true
	}
	if cak == nil { // SEMUA
		return true
	}
	if cak.Deny {
		return false
	}
	if row.IDInvGudang == nil {
		return false
	}
	for _, id := range cak.IDs {
		if id == *row.IDInvGudang {
			return true
		}
	}
	return false
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// List — halaman lokasi — ter-scope dimensi 'storages' via gudang induk
// (predikat virtual-SELALU-tampil dibangun di query repo).
func (s *LokasiService) List(ctx context.Context, pr *errkontrak.PageRequest, userID int64) (errkontrak.Page[repository.LokasiStokView], error) {
	cak, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return errkontrak.Page[repository.LokasiStokView]{}, err
	}
	return s.Repo.ListLokasi(ctx, s.DB.Pool, pr, cak)
}

// Get — detail lokasi — di luar cakupan = 404 paritas "tidak ada data".
func (s *LokasiService) Get(ctx context.Context, id int64, userID int64) (repository.LokasiStokView, error) {
	cak, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return repository.LokasiStokView{}, err
	}
	row, err := s.Repo.MuatDetail(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.LokasiStokView{}, err
	}
	if row == nil {
		return repository.LokasiStokView{}, lokasiNotFound(id)
	}
	if !terlihatLokasi(&row.Lokasi, cak) {
		return repository.LokasiStokView{}, domain.ErrLokasiTersembunyi(id)
	}
	return repository.LokasiToView(row.Lokasi, row.NamaGudang, row.NamaInduk), nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// Create — buat lokasi (201) — dup kode → 409 (race 23505 → pesan sama);
// TANPA gerbang scope (paritas master lain).
func (s *LokasiService) Create(ctx context.Context, in LokasiCreateInput, actor audit.Actor) (repository.LokasiStokView, error) {
	var view repository.LokasiStokView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		dupe, err := s.Repo.CariDupeKode(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dupe != nil {
			return errkontrak.Conflict(fmt.Sprintf("Kode lokasi '%s' sudah dipakai.", in.Kode))
		}
		row, err := s.Repo.InsertLokasi(ctx, tx, repository.LokasiBaru{
			EntityID:      numberingEntityID(),
			Kode:          in.Kode,
			Nama:          in.Nama,
			Jenis:         in.Jenis,
			IDInvGudang:   in.IDInvGudang,
			IDLokasiInduk: in.IDLokasiInduk,
			Status:        in.Status,
		})
		if err != nil {
			// Race unik kode (uq) → 409 pesan pre-check sama (ratifikasi).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode lokasi '%s' sudah dipakai.", in.Kode))
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_lokasi_stok",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode, "jenis": row.Jenis},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.LokasiToView(row, nil, nil)
		return nil
	})
	if err != nil {
		return repository.LokasiStokView{}, err
	}
	return view, nil
}

// Update — ubah lokasi — versi wajib cocok (409 INV-017 pre-check + atomic);
// scope via gudang induk (404 tersembunyi); pindah gudang luar whitelist →
// 409 INV-021; INTERNAL tanpa gudang → 400 INV-003.
func (s *LokasiService) Update(ctx context.Context, id int64, in LokasiUpdateInput, actor audit.Actor) (repository.LokasiStokView, error) {
	var view repository.LokasiStokView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.MuatByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return lokasiNotFound(id)
		}
		// Lokasi di luar cakupan gudang aktor = tidak ada (404 paritas list).
		cak, err := cakupanStorages(ctx, s.Scope, s.Audit, actorIDOf(actor), tx)
		if err != nil {
			return err
		}
		if !terlihatLokasi(row, cak) {
			return domain.ErrLokasiTersembunyi(id)
		}
		if int64(row.Version) != in.Version {
			return versiLokasiBentrok(row.Version, in.Version)
		}
		jenisBaru := mergeStatus(in.Jenis, row.Jenis)
		gudangBaru := merge3(in.IDInvGudangAda, in.IDInvGudang, row.IDInvGudang)
		// Pindah gudang induk ke luar whitelist → 409 INV-021 (lokasi
		// diketahui aktor; gudang tujuan bukan haknya — beda dengan 404).
		if gudangBaru != nil && cak != nil && !cak.Deny && !idDalam(cak.IDs, *gudangBaru) {
			return errkontrak.Conflict(
				"Gudang induk tujuan di luar whitelist data-scope Anda (dimensi 'storages').",
				domain.KodeInvLokasiTidakDiizinkan,
			)
		}
		if jenisBaru == "INTERNAL" && gudangBaru == nil {
			return errkontrak.BadRequest(
				"Lokasi INTERNAL wajib punya gudang induk (INV-003).",
				domain.KodeInvGerakanTidakSah,
			)
		}
		updated, err := s.Repo.UpdateLokasiHidup(ctx, tx, id, row.Version, repository.LokasiUbahSet{
			Nama:          mergeStr(in.Nama, row.Nama),
			Jenis:         jenisBaru,
			IDInvGudang:   gudangBaru,
			IDLokasiInduk: merge3(in.IDLokasiIndukAda, in.IDLokasiInduk, row.IDLokasiInduk),
			Status:        mergeStatus(in.Status, row.Status),
			Version:       row.Version + 1,
			UpdatedAt:     time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode lokasi '%s' sudah dipakai.", row.Kode))
			}
			return err
		}
		if updated == nil {
			// Kalah balapan versi (0 baris) → 409 INV-017 lagi (ratifikasi).
			return versiLokasiBentrok(row.Version, in.Version)
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_lokasi_stok",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				AfterValue: audit.Snapshot{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.LokasiToView(*updated, nil, nil)
		return nil
	})
	if err != nil {
		return repository.LokasiStokView{}, err
	}
	return view, nil
}

// Remove — hapus lunak — ditolak bila saldo ≠ 0 (409 INV-014 COALESCE SUM).
func (s *LokasiService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.MuatByID(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return lokasiNotFound(id)
		}
		cak, err := cakupanStorages(ctx, s.Scope, s.Audit, actorIDOf(actor), tx)
		if err != nil {
			return err
		}
		if !terlihatLokasi(row, cak) {
			return domain.ErrLokasiTersembunyi(id)
		}
		saldo, err := s.Repo.HitungSaldo(ctx, tx, id)
		if err != nil {
			return err
		}
		if saldo != 0 {
			return errkontrak.Conflict(
				"Lokasi masih berisi saldo stok — tidak bisa dihapus (INV-014).",
				domain.KodeInvLokasiMasihBerisi,
			)
		}
		saat := time.Now()
		if err := s.Repo.HapusLunakLokasi(ctx, tx, id, saat); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_lokasi_stok",
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

// lokasiNotFound — 404 INV-018 pesan verbatim (idRaw sudah tervalidasi angka).
func lokasiNotFound(id int64) error {
	return errkontrak.NotFound(fmt.Sprintf("Lokasi id %d tidak ditemukan.", id), domain.KodeInvTidakDitemukan)
}

// versiLokasiBentrok — 409 INV-017 pesan verbatim.
func versiLokasiBentrok(server int32, kirim int64) error {
	return errkontrak.Conflict(
		fmt.Sprintf("Versi lokasi tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok,
	)
}

// idDalam — whitelist scope berisi id?
func idDalam(ids []int64, id int64) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}
