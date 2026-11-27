// service/cluster.go — fitur CLUSTER (konfigurasi Cluster Modul CORE,
// ddl/55-core-cluster) — padanan ClusterService NestJS: master core_cluster,
// junction core_cluster_modules (N:M cluster ↔ modul registry) dan
// core_cluster_features (detail cluster-modul ↔ fitur). UoW SATU pgx.Tx +
// audit.Append dalam transaksi yang sama (entityType core_cluster*/moduleKey
// "system"); optimistic locking `version` di master — `version` master HANYA
// dinaikkan PATCH (sinkronisasi junction TIDAK menaikkan version — jejak
// cukup audit trail).
package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// ClusterService — master + sinkronisasi cluster.
type ClusterService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.ClusterRepository
}

// NewClusterService membuat service cluster.
func NewClusterService(db *database.DB, aud *audit.Service) *ClusterService {
	return &ClusterService{db: db, auid: aud, repo: repository.NewClusterRepository()}
}

// ---------------------------------------------------------------------
// CRUD master cluster
// ---------------------------------------------------------------------

// List — daftar cluster paging (?page&limit&sort&search&status) —
// jumlahModul = count assignment hidup per cluster.
func (s *ClusterService) List(ctx context.Context, q types.ClusterAgamaListQuery) (errkontrak.Page[types.CoreClusterView], error) {
	rows, total, err := s.repo.ListCluster(ctx, s.db.Pool, repository.ClusterListQuery{
		Search:   trimTerm(q.Search),
		Status:   q.Status,
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   (q.Page - 1) * q.Limit,
	})
	if err != nil {
		return errkontrak.Page[types.CoreClusterView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), &errkontrak.PageRequest{Page: int(q.Page), Limit: int(q.Limit)}), nil
}

// ModulOptions — katalog modul registry + fitur aktif per modul — opsi UI
// assign cluster (GET /system/cluster/modul-options).
func (s *ClusterService) ModulOptions(ctx context.Context) ([]types.CoreClusterModulOption, error) {
	return s.repo.ModulOptions(ctx, s.db.Pool)
}

// Create — provisio cluster baru — code unik hidup (409 SYS-409 bila dup,
// race 23505 ditangkap). Audit create (severity default info).
func (s *ClusterService) Create(ctx context.Context, in types.ClusterBuat, actor audit.Actor) (types.CoreClusterView, error) {
	var out types.CoreClusterView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		dup, err := s.repo.CariHidupByKode(ctx, tx, in.Code)
		if err != nil {
			return err
		}
		if dup != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Kode cluster '%s' sudah dipakai cluster lain.", in.Code),
				"SYS-409",
			)
		}
		row, err := s.repo.InsertCluster(ctx, tx, in.Code, in.Nama, in.Deskripsi, in.Icon, in.Tone, in.Urutan, in.Status)
		if err != nil {
			// uq_core_cluster_code_hidup — race pre-check dup di atas.
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode cluster '%s' sudah dipakai cluster lain — muat ulang daftar (SYS-409).", in.Code),
					"SYS-409",
				)
			}
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_cluster",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: repository.SnapshotCluster(row),
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = repository.ClusterToView(row, 0)
		return nil
	})
	return out, err
}

// Get — detail satu cluster hidup + modul (assignment hidup, join
// core_modules, urut key) dengan fiturIds. 404 SYS-404 bila tidak ada.
func (s *ClusterService) Get(ctx context.Context, id int64) (types.CoreClusterDetail, error) {
	row, err := s.repo.CariClusterHidup(ctx, s.db.Pool, id)
	if err != nil {
		return types.CoreClusterDetail{}, err
	}
	if row == nil {
		return types.CoreClusterDetail{}, errkontrak.NotFound(
			fmt.Sprintf("Cluster id %d tidak ditemukan.", id), "SYS-404",
		)
	}
	jumlah, err := s.repo.JumlahModul(ctx, s.db.Pool, id)
	if err != nil {
		return types.CoreClusterDetail{}, err
	}
	modul, err := s.repo.RowsModul(ctx, s.db.Pool, id)
	if err != nil {
		return types.CoreClusterDetail{}, err
	}
	return types.CoreClusterDetail{
		CoreClusterView: repository.ClusterToView(*row, jumlah),
		Modul:           modul,
	}, nil
}

// Update — PATCH umum cluster — If-Match/body version (If-Match menang);
// versi beda → 409 SYS-409, sukses → version+1. Dup code hidup pada cluster
// LAIN → 409. Nullish semantics: absen = pertahankan, null = NULL.
func (s *ClusterService) Update(ctx context.Context, id int64, in types.ClusterUbah, actor audit.Actor, expectedVersion *int64) (types.CoreClusterView, error) {
	var out types.CoreClusterView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.CariClusterHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Cluster id %d tidak ditemukan.", id), "SYS-404",
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
					fmt.Sprintf("Kode cluster '%s' sudah dipakai cluster lain.", nextKode),
					"SYS-409",
				)
			}
		}

		updated, err := s.repo.UpdateBerVersion(ctx, tx, repository.ClusterUbahSet{
			ID:          id,
			VersiServer: row.Version,
			Code:        nextKode,
			Nama:        pilihTeks(in.Nama, row.Nama),
			Deskripsi:   pilihNullable(in.Deskripsi, in.DeskripsiNull, pgText(row.Deskripsi)),
			Icon:        pilihNullable(in.Icon, in.IconNull, pgText(row.Icon)),
			Tone:        pilihNullable(in.Tone, in.ToneNull, pgText(row.Tone)),
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
				fmt.Sprintf("Versi cluster %s berubah di server — muat ulang lalu ulangi (SYS-409).", row.Code),
				"SYS-409",
			)
		}

		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_cluster",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: repository.SnapshotCluster(*row),
				AfterValue:  repository.SnapshotCluster(*updated),
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		jumlah, err := s.repo.JumlahModul(ctx, tx, id)
		if err != nil {
			return err
		}
		out = repository.ClusterToView(*updated, jumlah)
		return nil
	})
	return out, err
}

// Remove — soft delete cluster (set deleted_at — JANGAN hard delete;
// TANPA version bump — kontrak endpoint terkunci). Audit delete warning.
func (s *ClusterService) Remove(ctx context.Context, id int64, actor audit.Actor) (types.ClusterHapusHasil, error) {
	var out types.ClusterHapusHasil
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.CariClusterHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Cluster id %d tidak ditemukan.", id), "SYS-404",
			)
		}
		if err := s.repo.SoftDelete(ctx, tx, id, time.Now()); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_cluster",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: repository.SnapshotCluster(*row),
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

// ---------------------------------------------------------------------
// Sinkronisasi assignment modul & fitur (junction)
// ---------------------------------------------------------------------

// SyncModul — REPLACE set assignment modul hidup cluster (semantik
// revive/insert). Setiap modulIds divalidasi ada di core_modules (400 bila
// ada yang tak dikenal). Return daftar modul ter-refresh (dengan fiturIds).
func (s *ClusterService) SyncModul(ctx context.Context, id int64, in types.ClusterSyncModul, actor audit.Actor) ([]types.CoreClusterModulView, error) {
	targetIds := dedupeIDCluster(in.ModulIDs)
	var out []types.CoreClusterModulView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.assertCluster(ctx, tx, id); err != nil {
			return err
		}
		dikenal, err := s.repo.IdModulDikenal(ctx, tx, targetIds)
		if err != nil {
			return err
		}
		dikenalSet := map[int64]bool{}
		for _, mid := range dikenal {
			dikenalSet[mid] = true
		}
		var missing []int64
		for _, mid := range targetIds {
			if !dikenalSet[mid] {
				missing = append(missing, mid)
			}
		}
		if len(missing) > 0 {
			return errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "modulIds", Message: fmt.Sprintf("Modul tidak dikenal: %s.", gabungIDCluster(missing))},
			})
		}

		sebelum, sesudah, err := s.repo.SyncModulJunction(ctx, tx, id, targetIds, time.Now())
		if err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_cluster_modul",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "sync_modul",
				BeforeValue: audit.Snapshot{"id_modules": sebelum},
				AfterValue:  audit.Snapshot{"id_modules": sesudah},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out, err = s.repo.RowsModul(ctx, tx, id)
		return err
	})
	return out, err
}

// SyncFitur — REPLACE set fitur hidup SATU baris cluster-modul. Baris
// parent wajib hidup (404); setiap fiturIds divalidasi milik id_core_modules
// parent (400 bila tak dikenal / bukan milik parent). Return fiturIds
// ter-refresh.
func (s *ClusterService) SyncFitur(ctx context.Context, idModulCluster int64, in types.ClusterSyncFitur, actor audit.Actor) (types.ClusterSyncFiturHasil, error) {
	targetIds := dedupeIDCluster(in.FiturIDs)
	var out types.ClusterSyncFiturHasil
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		parent, err := s.repo.CariModulHidup(ctx, tx, idModulCluster)
		if err != nil {
			return err
		}
		if parent == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Assignment cluster-modul id %d tidak ditemukan.", idModulCluster),
				"SYS-404",
			)
		}

		barisFitur, err := s.repo.BarisFiturByIds(ctx, tx, targetIds)
		if err != nil {
			return err
		}
		byId := map[int64]int64{}
		for _, r := range barisFitur {
			byId[r.ID] = r.IDCoreModules
		}
		var invalid []int64
		for _, fid := range targetIds {
			if byId[fid] != parent.IDCoreModules {
				invalid = append(invalid, fid)
			}
		}
		if len(invalid) > 0 {
			return errkontrak.Validation([]errkontrak.FieldIssue{
				{
					Field: "fiturIds",
					Message: fmt.Sprintf(
						"Fitur id %s tidak dikenal / bukan milik modul parent (id_core_modules %d).",
						gabungIDCluster(invalid), parent.IDCoreModules,
					),
				},
			})
		}

		sebelum, sesudah, err := s.repo.SyncFiturJunction(ctx, tx, idModulCluster, targetIds, time.Now())
		if err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_cluster_fitur",
				EntityID:    fmt.Sprintf("%d", idModulCluster),
				Action:      "sync_fitur",
				BeforeValue: audit.Snapshot{"id_features": sebelum},
				AfterValue:  audit.Snapshot{"id_features": sesudah},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.ClusterSyncFiturHasil{IDModulCluster: idModulCluster, FiturIDs: sesudah}
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// assertCluster — cluster hidup wajib ada — 404 SYS-404.
func (s *ClusterService) assertCluster(ctx context.Context, exec pgx.Tx, id int64) error {
	row, err := s.repo.CariClusterHidup(ctx, exec, id)
	if err != nil {
		return err
	}
	if row == nil {
		return errkontrak.NotFound(
			fmt.Sprintf("Cluster id %d tidak ditemukan.", id), "SYS-404",
		)
	}
	return nil
}

// ensureVersionSYS — 409 SYS-409 bila version kirim diberikan dan tidak
// cocok (padanan ensureVersion NestJS).
func ensureVersionSYS(current int32, expected *int64) error {
	if expected != nil && int64(current) != *expected {
		return errkontrak.Conflict(
			fmt.Sprintf(
				"Resource sudah diubah pihak lain — version kirim (%d) ≠ version terkini (%d) — muat ulang (SYS-409).",
				*expected, current,
			),
			"SYS-409",
		)
	}
	return nil
}

// dedupeIDCluster — padanan [...new Set(ids)]: unik, urutan pertama muncul.
func dedupeIDCluster(ids []int64) []int64 {
	seen := map[int64]bool{}
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// gabungIDCluster — padanan join(", ").
func gabungIDCluster(ids []int64) string {
	s := ""
	for i, id := range ids {
		if i > 0 {
			s += ", "
		}
		s += fmt.Sprintf("%d", id)
	}
	return s
}

// pilihNullable — tri-state PATCH cluster: null → nil (NULL); dikirim →
// nilai; absen → nilai row.
func pilihNullable(in *string, null bool, row *string) *string {
	if null {
		return nil
	}
	if in != nil {
		return in
	}
	return row
}

// pilihInt32 — input != nil ? *input : row.
func pilihInt32(in *int32, row int32) int32 {
	if in != nil {
		return *in
	}
	return row
}

// trimTerm — padanan query.search?.trim(): kosong setelah trim = tidak ada
// filter (NestJS memakai term ter-trim utk ILIKE).
func trimTerm(v *string) *string {
	if v == nil {
		return nil
	}
	t := strings.TrimSpace(*v)
	if t == "" {
		return nil
	}
	return &t
}
