// cluster.go — fitur CLUSTER modul core — padanan ClusterRepository NestJS:
// master core_cluster (list/paging dengan jumlahModul correlated subquery
// hidup, cari hidup, insert, patch ber-version, soft delete TANPA bump),
// junction core_cluster_modules & core_cluster_features — REPLACE set hidup
// semantik revive → insert ON CONFLICT DO NOTHING → soft-delete hilang —
// dan katalog global core_modules / core_modules_features. Mapping BARIS →
// VIEW (clusterToView/snapshotCluster) di sini; guard bisnis di service.
package repository

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"nexierp/internal/core/audit"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// ClusterRepository — master + junction cluster.
type ClusterRepository struct{}

// NewClusterRepository membuat repository cluster.
func NewClusterRepository() *ClusterRepository { return &ClusterRepository{} }

// ClusterListQuery — kriteria list cluster (service yang memutuskan dari
// whitelist sort & zod ekuivalen).
type ClusterListQuery struct {
	Search   *string // SUDAH di-trim service (term kosong → nil)
	Status   *string
	SortCol  string
	SortDesc bool
	Limit    int32
	Offset   int32
}

// ClusterToView — mapper baris core_cluster → view (waktu ISO-8601).
func ClusterToView(row gen.CoreCluster, jumlahModul int32) types.CoreClusterView {
	return types.CoreClusterView{
		ID:          row.ID,
		EntityID:    row.EntityID.String(),
		Code:        row.Code,
		Nama:        row.Nama,
		Deskripsi:   teksNilai(row.Deskripsi),
		Icon:        teksNilai(row.Icon),
		Tone:        teksNilai(row.Tone),
		Urutan:      row.Urutan,
		Status:      string(row.Status),
		Version:     row.Version,
		CreatedAt:   isoZ(row.CreatedAt.Time),
		UpdatedAt:   isoZ(row.UpdatedAt.Time),
		JumlahModul: jumlahModul,
	}
}

// SnapshotCluster — ringkasan cluster utk audit before/after (verbatim
// snapshotCluster NestJS — snake_case pola tenants).
func SnapshotCluster(row gen.CoreCluster) audit.Snapshot {
	return audit.Snapshot{
		"code":      row.Code,
		"nama":      row.Nama,
		"deskripsi": teksNilai(row.Deskripsi),
		"icon":      teksNilai(row.Icon),
		"tone":      teksNilai(row.Tone),
		"urutan":    row.Urutan,
		"status":    string(row.Status),
		"version":   row.Version,
	}
}

// ---------------------------------------------------------------------
// CRUD master
// ---------------------------------------------------------------------

// ListCluster — halaman cluster hidup + total; jumlahModul = count
// assignment hidup per cluster (subquery terkorelasi).
func (r *ClusterRepository) ListCluster(ctx context.Context, exec gen.DBTX, q ClusterListQuery) ([]types.CoreClusterView, int32, error) {
	g := gen.New(exec)
	rows, err := g.ListCluster(ctx, gen.ListClusterParams{
		Search:   teksNihil(q.Search),
		Status:   teksNihil(q.Status),
		SortCol:  q.SortCol,
		SortDesc: q.SortDesc,
		Limit:    q.Limit,
		Offset:   q.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := g.CountCluster(ctx, gen.CountClusterParams{
		Search: teksNihil(q.Search),
		Status: teksNihil(q.Status),
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]types.CoreClusterView, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.CoreClusterView{
			ID:          row.ID,
			EntityID:    row.EntityID.String(),
			Code:        row.Code,
			Nama:        row.Nama,
			Deskripsi:   teksNilai(row.Deskripsi),
			Icon:        teksNilai(row.Icon),
			Tone:        teksNilai(row.Tone),
			Urutan:      row.Urutan,
			Status:      string(row.Status),
			Version:     row.Version,
			CreatedAt:   isoZ(row.CreatedAt.Time),
			UpdatedAt:   isoZ(row.UpdatedAt.Time),
			JumlahModul: row.JumlahModul,
		})
	}
	return out, total, nil
}

// ModulOptions — katalog modul registry (SEMUA core_modules, urut key —
// urutan enum) + fitur aktif (is_active = true, urut id) per modul.
func (r *ClusterRepository) ModulOptions(ctx context.Context, exec gen.DBTX) ([]types.CoreClusterModulOption, error) {
	g := gen.New(exec)
	modulRows, err := g.ModulOptionsModul(ctx)
	if err != nil {
		return nil, err
	}
	fiturRows, err := g.ModulOptionsFitur(ctx)
	if err != nil {
		return nil, err
	}
	fiturByModul := map[int64][]types.CoreClusterModulFitur{}
	for _, f := range fiturRows {
		fiturByModul[f.IDCoreModules] = append(fiturByModul[f.IDCoreModules], types.CoreClusterModulFitur{
			ID:             f.ID,
			FeaturesFolder: f.FeaturesFolder,
			Description:    json.RawMessage(f.Description), // []byte nil → null
		})
	}
	out := make([]types.CoreClusterModulOption, 0, len(modulRows))
	for _, m := range modulRows {
		fitur := fiturByModul[m.ID]
		if fitur == nil {
			fitur = []types.CoreClusterModulFitur{}
		}
		out = append(out, types.CoreClusterModulOption{
			ID:      m.ID,
			Key:     string(m.Key),
			Name:    m.Name,
			Tagline: m.Tagline,
			Enabled: m.Enabled,
			Fitur:   fitur,
		})
	}
	return out, nil
}

// CariClusterHidup — baris hidup by id — nil bila tidak ada / terhapus.
func (r *ClusterRepository) CariClusterHidup(ctx context.Context, exec gen.DBTX, id int64) (*gen.CoreCluster, error) {
	rows, err := gen.New(exec).CariClusterHidup(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// CariModulHidup — baris cluster-modul hidup by id (parent sync fitur).
func (r *ClusterRepository) CariModulHidup(ctx context.Context, exec gen.DBTX, id int64) (*gen.CoreClusterModule, error) {
	rows, err := gen.New(exec).CariClusterModulHidup(ctx, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// CariHidupByKode — id cluster hidup lain berkode sama (pre-check dup code).
func (r *ClusterRepository) CariHidupByKode(ctx context.Context, exec gen.DBTX, code string) (*int64, error) {
	rows, err := gen.New(exec).CariClusterHidupByKode(ctx, code)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// JumlahModul — count assignment modul hidup satu cluster.
func (r *ClusterRepository) JumlahModul(ctx context.Context, exec gen.DBTX, id int64) (int32, error) {
	return gen.New(exec).JumlahModulCluster(ctx, id)
}

// IdModulDikenal — id modul registry yang dikenal dari set (validasi sync).
func (r *ClusterRepository) IdModulDikenal(ctx context.Context, exec gen.DBTX, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return []int64{}, nil
	}
	return gen.New(exec).IdModulDikenal(ctx, ids)
}

// BarisFiturByIds — (id fitur → id modul pemilik) untuk validasi syncFitur.
func (r *ClusterRepository) BarisFiturByIds(ctx context.Context, exec gen.DBTX, ids []int64) ([]gen.BarisFiturByIdsRow, error) {
	if len(ids) == 0 {
		return []gen.BarisFiturByIdsRow{}, nil
	}
	return gen.New(exec).BarisFiturByIds(ctx, ids)
}

// InsertCluster — insert cluster baru (version 1; race 23505 mentah).
func (r *ClusterRepository) InsertCluster(ctx context.Context, exec gen.DBTX, code, nama string, deskripsi, icon, tone *string, urutan int32, status string) (gen.CoreCluster, error) {
	return gen.New(exec).InsertCluster(ctx, gen.InsertClusterParams{
		Code:      code,
		Nama:      nama,
		Deskripsi: teksNihil(deskripsi),
		Icon:      teksNihil(icon),
		Tone:      teksNihil(tone),
		Urutan:    urutan,
		Status:    gen.EnumStatusAktif(status),
		Version:   1,
	})
}

// ClusterUbahSet — nilai kolom dibangun service (nullish semantics).
type ClusterUbahSet struct {
	ID          int64
	VersiServer int32
	Code        string
	Nama        string
	Deskripsi   *string
	Icon        *string
	Tone        *string
	Urutan      int32
	Status      string
	Version     int32
	UpdatedAt   time.Time
}

// UpdateBerVersion — patch ber-version; nil = version berubah di antara
// baca & tulis (race — 409 di service).
func (r *ClusterRepository) UpdateBerVersion(ctx context.Context, exec gen.DBTX, s ClusterUbahSet) (*gen.CoreCluster, error) {
	rows, err := gen.New(exec).UpdateClusterBerVersion(ctx, gen.UpdateClusterBerVersionParams{
		Code:        s.Code,
		Nama:        s.Nama,
		Deskripsi:   teksNihil(s.Deskripsi),
		Icon:        teksNihil(s.Icon),
		Tone:        teksNihil(s.Tone),
		Urutan:      s.Urutan,
		Status:      gen.EnumStatusAktif(s.Status),
		Version:     s.Version,
		UpdatedAt:   waktu(s.UpdatedAt),
		ID:          s.ID,
		VersiServer: s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDelete — set deleted_at saja (JANGAN hard delete; TANPA version bump).
func (r *ClusterRepository) SoftDelete(ctx context.Context, exec gen.DBTX, id int64, now time.Time) error {
	err := gen.New(exec).SoftDeleteCluster(ctx, gen.SoftDeleteClusterParams{
		DeletedAt: waktu(now),
		UpdatedAt: waktu(now),
		ID:        id,
	})
	return err
}

// ---------------------------------------------------------------------
// Sinkronisasi junction (algoritma PERSIS syncModulJunction NestJS)
// ---------------------------------------------------------------------

// SyncModulJunction — REPLACE set assignment modul hidup cluster:
// baca SEMUA baris (hidup/mati) → revive deleted_at=NULL → insert baru
// ON CONFLICT DO NOTHING → soft-delete hilang. Return id modul hidup
// SEBELUM & SESUDAH (urut asc — payload audit sync_modul).
func (r *ClusterRepository) SyncModulJunction(ctx context.Context, exec gen.DBTX, idCluster int64, targetIds []int64, now time.Time) (sebelum []int64, sesudah []int64, err error) {
	g := gen.New(exec)
	existing, err := g.BacaClusterModulCluster(ctx, idCluster)
	if err != nil {
		return nil, nil, err
	}
	hidup := map[int64]bool{}
	mati := map[int64]bool{}
	var hidupList []int64
	for _, row := range existing {
		if row.DeletedAt.Valid {
			mati[row.IDCoreModules] = true
		} else {
			if !hidup[row.IDCoreModules] {
				hidupList = append(hidupList, row.IDCoreModules)
			}
			hidup[row.IDCoreModules] = true
		}
	}
	diminta := map[int64]bool{}
	for _, id := range targetIds {
		diminta[id] = true
	}

	// (1) Revive pasangan soft-deleted yang masuk lagi dalam set.
	var revive []int64
	for _, x := range targetIds {
		if mati[x] {
			revive = append(revive, x)
		}
	}
	if len(revive) > 0 {
		if _, err = g.ReviveClusterModul(ctx, gen.ReviveClusterModulParams{
			UpdatedAt: waktu(now),
			IDCluster: idCluster,
			Ids:       revive,
		}); err != nil {
			return nil, nil, err
		}
	}
	// (2) Insert pasangan yang belum pernah ada.
	var baru []int64
	for _, x := range targetIds {
		if !hidup[x] && !mati[x] {
			baru = append(baru, x)
		}
	}
	if len(baru) > 0 {
		if _, err = g.InsertClusterModul(ctx, gen.InsertClusterModulParams{
			IDCluster: idCluster,
			Ids:       baru,
		}); err != nil {
			return nil, nil, err
		}
	}
	// (3) Soft delete pasangan hidup yang hilang dari set.
	var hilang []int64
	for _, x := range hidupList {
		if !diminta[x] {
			hilang = append(hilang, x)
		}
	}
	if len(hilang) > 0 {
		if _, err = g.SoftDeleteClusterModul(ctx, gen.SoftDeleteClusterModulParams{
			DeletedAt: waktu(now),
			UpdatedAt: waktu(now),
			IDCluster: idCluster,
			Ids:       hilang,
		}); err != nil {
			return nil, nil, err
		}
	}

	sort.Slice(hidupList, func(i, j int) bool { return hidupList[i] < hidupList[j] })
	sesudah, err = r.IdsModulAktif(ctx, exec, idCluster)
	if err != nil {
		return nil, nil, err
	}
	return hidupList, sesudah, nil
}

// SyncFiturJunction — REPLACE set fitur hidup SATU baris cluster-modul —
// semantik SyncModulJunction di level core_cluster_features.
func (r *ClusterRepository) SyncFiturJunction(ctx context.Context, exec gen.DBTX, idModulCluster int64, targetIds []int64, now time.Time) (sebelum []int64, sesudah []int64, err error) {
	g := gen.New(exec)
	existing, err := g.BacaClusterFiturBaris(ctx, idModulCluster)
	if err != nil {
		return nil, nil, err
	}
	hidup := map[int64]bool{}
	mati := map[int64]bool{}
	var hidupList []int64
	for _, row := range existing {
		if row.DeletedAt.Valid {
			mati[row.IDCoreModulesFeatures] = true
		} else {
			if !hidup[row.IDCoreModulesFeatures] {
				hidupList = append(hidupList, row.IDCoreModulesFeatures)
			}
			hidup[row.IDCoreModulesFeatures] = true
		}
	}
	diminta := map[int64]bool{}
	for _, id := range targetIds {
		diminta[id] = true
	}

	// (1) Revive fitur soft-deleted yang masuk lagi dalam set.
	var revive []int64
	for _, x := range targetIds {
		if mati[x] {
			revive = append(revive, x)
		}
	}
	if len(revive) > 0 {
		if _, err = g.ReviveClusterFitur(ctx, gen.ReviveClusterFiturParams{
			UpdatedAt:      waktu(now),
			IDModulCluster: idModulCluster,
			Ids:            revive,
		}); err != nil {
			return nil, nil, err
		}
	}
	// (2) Insert fitur yang belum pernah ada.
	var baru []int64
	for _, x := range targetIds {
		if !hidup[x] && !mati[x] {
			baru = append(baru, x)
		}
	}
	if len(baru) > 0 {
		if _, err = g.InsertClusterFitur(ctx, gen.InsertClusterFiturParams{
			IDModulCluster: idModulCluster,
			Ids:            baru,
		}); err != nil {
			return nil, nil, err
		}
	}
	// (3) Soft delete fitur hidup yang hilang dari set.
	var hilang []int64
	for _, x := range hidupList {
		if !diminta[x] {
			hilang = append(hilang, x)
		}
	}
	if len(hilang) > 0 {
		if _, err = g.SoftDeleteClusterFitur(ctx, gen.SoftDeleteClusterFiturParams{
			DeletedAt:      waktu(now),
			UpdatedAt:      waktu(now),
			IDModulCluster: idModulCluster,
			Ids:            hilang,
		}); err != nil {
			return nil, nil, err
		}
	}

	sort.Slice(hidupList, func(i, j int) bool { return hidupList[i] < hidupList[j] })
	sesudah, err = r.IdsFiturAktif(ctx, exec, idModulCluster)
	if err != nil {
		return nil, nil, err
	}
	return hidupList, sesudah, nil
}

// IdsModulAktif — id modul assignment hidup cluster (urut asc).
func (r *ClusterRepository) IdsModulAktif(ctx context.Context, exec gen.DBTX, id int64) ([]int64, error) {
	rows, err := gen.New(exec).IdsModulAktif(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, len(rows))
	out = append(out, rows...)
	return out, nil
}

// IdsFiturAktif — id fitur hidup satu baris cluster-modul (urut asc).
func (r *ClusterRepository) IdsFiturAktif(ctx context.Context, exec gen.DBTX, idModulCluster int64) ([]int64, error) {
	rows, err := gen.New(exec).IdsFiturAktif(ctx, idModulCluster)
	if err != nil {
		return nil, err
	}
	out := make([]int64, 0, len(rows))
	out = append(out, rows...)
	return out, nil
}

// RowsModul — baris modul assignment hidup cluster (join core_modules, urut
// key) + fiturIds per assignment — dipakai GET detail & hasil PUT modul.
func (r *ClusterRepository) RowsModul(ctx context.Context, exec gen.DBTX, id int64) ([]types.CoreClusterModulView, error) {
	g := gen.New(exec)
	modulRows, err := g.RowsModulCluster(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(modulRows) == 0 {
		return []types.CoreClusterModulView{}, nil
	}
	ids := make([]int64, 0, len(modulRows))
	for _, m := range modulRows {
		ids = append(ids, m.ID)
	}
	fiturRows, err := g.RowsFiturUntukModul(ctx, ids)
	if err != nil {
		return nil, err
	}
	fiturByModul := map[int64][]int64{}
	for _, f := range fiturRows {
		fiturByModul[f.IDCoreClusterModules] = append(fiturByModul[f.IDCoreClusterModules], f.IDCoreModulesFeatures)
	}
	out := make([]types.CoreClusterModulView, 0, len(modulRows))
	for _, m := range modulRows {
		fiturIds := fiturByModul[m.ID]
		if fiturIds == nil {
			fiturIds = []int64{}
		}
		out = append(out, types.CoreClusterModulView{
			ID:            m.ID,
			IDCoreModules: m.IDCoreModules,
			Key:           string(m.Key),
			Name:          m.Name,
			Tagline:       m.Tagline,
			Enabled:       m.Enabled,
			FiturIDs:      fiturIds,
		})
	}
	return out, nil
}

// isoZ — padanan toISOString() JS (UTC, milidetik 3 digit, Z).
func isoZ(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}
