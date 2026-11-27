// service/agama.go — fitur AGAMA (kosakata agama resmi, ddl/72-core-agama)
// — padanan AgamaService NestJS: master core_agama, pola persis
// ClusterService minus junction. UoW SATU pgx.Tx + audit.Append dalam
// transaksi yang sama (entityType core_agama, moduleKey "system");
// optimistic locking `version` (If-Match/body — versi beda → 409; sukses →
// version+1). Penghapusan agama yang masih dirujuk tabel transaksi (FK
// RESTRICT — PG 23503) → dipetakan 409 SYS-409.
package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// AgamaService — master agama.
type AgamaService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.AgamaRepository
}

// NewAgamaService membuat service agama.
func NewAgamaService(db *database.DB, aud *audit.Service) *AgamaService {
	return &AgamaService{db: db, auid: aud, repo: repository.NewAgamaRepository()}
}

// isForeignKeyViolation — padanan kodePg(err) === "23503" (termasuk rantai
// cause drizzle; pgx langsung memberi *pgconn.PgError).
func isForeignKeyViolation(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "23503"
	}
	return false
}

// List — daftar agama paging (?page&limit&sort&search&status).
func (s *AgamaService) List(ctx context.Context, q types.ClusterAgamaListQuery) (errkontrak.Page[types.CoreAgamaView], error) {
	rows, total, err := s.repo.ListAgama(ctx, s.db.Pool, repository.AgamaListQuery{
		Search:   trimTerm(q.Search),
		Status:   q.Status,
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   (q.Page - 1) * q.Limit,
	})
	if err != nil {
		return errkontrak.Page[types.CoreAgamaView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), &errkontrak.PageRequest{Page: int(q.Page), Limit: int(q.Limit)}), nil
}

// Create — provisio agama baru — code unik hidup (409 SYS-409 bila dup,
// race 23505 ditangkap). Audit create (severity default info).
func (s *AgamaService) Create(ctx context.Context, in types.AgamaBuat, actor audit.Actor) (types.CoreAgamaView, error) {
	var out types.CoreAgamaView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		dup, err := s.repo.CariHidupByKode(ctx, tx, in.Code)
		if err != nil {
			return err
		}
		if dup != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Kode agama '%s' sudah dipakai agama lain.", in.Code),
				"SYS-409",
			)
		}
		row, err := s.repo.InsertAgama(ctx, tx, in.Code, in.Nama, in.Urutan, in.Status)
		if err != nil {
			// uq_core_agama_code_hidup — race pre-check dup di atas.
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode agama '%s' sudah dipakai agama lain — muat ulang daftar (SYS-409).", in.Code),
					"SYS-409",
				)
			}
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_agama",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: repository.SnapshotAgama(row),
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = repository.AgamaToView(row)
		return nil
	})
	return out, err
}

// Get — detail satu agama hidup — 404 SYS-404 bila tidak ada / terhapus.
func (s *AgamaService) Get(ctx context.Context, id int64) (types.CoreAgamaView, error) {
	row, err := s.repo.CariAgamaHidup(ctx, s.db.Pool, id)
	if err != nil {
		return types.CoreAgamaView{}, err
	}
	if row == nil {
		return types.CoreAgamaView{}, errkontrak.NotFound(
			fmt.Sprintf("Agama id %d tidak ditemukan.", id), "SYS-404",
		)
	}
	return repository.AgamaToView(*row), nil
}

// Update — PATCH umum agama — If-Match/body version (If-Match menang); versi
// beda → 409 SYS-409, sukses → version+1. Dup code hidup pada agama LAIN →
// 409. Audit update (before/after, severity warning).
func (s *AgamaService) Update(ctx context.Context, id int64, in types.AgamaUbah, actor audit.Actor, expectedVersion *int64) (types.CoreAgamaView, error) {
	var out types.CoreAgamaView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.CariAgamaHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Agama id %d tidak ditemukan.", id), "SYS-404",
			)
		}
		if err := ensureVersionSYS(row.Version, expectedVersion); err != nil {
			return err
		}

		nextKode := row.Code
		if in.Code != nil {
			nextKode = *in.Code
		}
		if nextKode != row.Code {
			dup, err := s.repo.CariHidupByKode(ctx, tx, nextKode)
			if err != nil {
				return err
			}
			if dup != nil && *dup != id {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode agama '%s' sudah dipakai agama lain.", nextKode),
					"SYS-409",
				)
			}
		}

		updated, err := s.repo.UpdateBerVersion(ctx, tx, repository.AgamaUbahSet{
			ID:          id,
			VersiServer: row.Version,
			Code:        nextKode,
			Nama:        pilihTeks(in.Nama, row.Nama),
			Urutan:      pilihInt32(in.Urutan, row.Urutan),
			Status:      pilihTeks(in.Status, string(row.Status)),
			Version:     row.Version + 1,
			UpdatedAt:   time.Now(),
		})
		if err != nil {
			return err
		}
		if updated == nil {
			// Version berubah di antara baca & tulis (race) — muat ulang dulu.
			return errkontrak.Conflict(
				fmt.Sprintf("Versi agama %s berubah di server — muat ulang lalu ulangi (SYS-409).", row.Code),
				"SYS-409",
			)
		}

		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_agama",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: repository.SnapshotAgama(*row),
				AfterValue:  repository.SnapshotAgama(*updated),
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = repository.AgamaToView(*updated)
		return nil
	})
	return out, err
}

// Remove — soft delete agama (set deleted_at — JANGAN hard delete; TANPA
// version bump). Masih dirujuk pendaftaran/siswa → FK RESTRICT 23503 → 409
// SYS-409. Audit delete (severity warning).
func (s *AgamaService) Remove(ctx context.Context, id int64, actor audit.Actor) (types.ClusterHapusHasil, error) {
	var out types.ClusterHapusHasil
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.CariAgamaHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Agama id %d tidak ditemukan.", id), "SYS-404",
			)
		}
		if err := s.repo.SoftDelete(ctx, tx, id, time.Now()); err != nil {
			// FK RESTRICT (nama constraint tergantung pemakai) — riwayat masih rujuk.
			if isForeignKeyViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf(
						"Agama '%s' masih dirujuk data calon siswa/siswa — matikan lewat status NONAKTIF, bukan hapus (SYS-409).",
						row.Nama,
					),
					"SYS-409",
				)
			}
			return err
		}

		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_agama",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: repository.SnapshotAgama(*row),
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.ClusterHapusHasil{ID: id}
		return nil
	})
	return out, err
}
