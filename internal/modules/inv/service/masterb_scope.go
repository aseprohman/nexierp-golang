// service/masterb_scope.go — evaluasi cakupan data dimensi 'storages' untuk
// fitur GUDANG & LOKASI modul inv (padanan filterStoragesIds NestJS di atas
// evaluator generik core/rbac — fitur lain MASTER-B TIDAK ber-scope).
//
// Semantik verbatim sumber:
//   - aktor tidak diketahui (userID 0) → SEMUA (fail-open);
//   - modul 'inventory' belum ter-seed → SEMUA (dimensinya pun belum
//     terdaftar di katalog);
//   - evaluator tiga-mode: SEMUA / DENY_ALL / DAFTAR (whitelist id gudang).
//
// Hasil dinormalisasi jadi *repository.CakupanStorages (nil = SEMUA) dan
// diteruskan ke repository gudang/lokasi. Aman dipanggil di dalam transaksi
// (exec = tx) maupun baca non-tx (exec = pool).
package service

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/inv/repository"
)

// cakupanStorages — keputusan cakupan 'storages' aktor pada executor
// (pool | tx). Param exec bertipe interface anonim (identik gen.DBTX hasil
// sqlc modul inv/rbac/audit — pgx.Tx & *pgxpool.Pool keduanya memenuhi).
// nil hasil = SEMUA (tanpa predicate).
func cakupanStorages(
	ctx context.Context,
	sc *rbac.Scope,
	aud *audit.Service,
	userID int64,
	exec interface {
		Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
		Query(context.Context, string, ...any) (pgx.Rows, error)
		QueryRow(context.Context, string, ...any) pgx.Row
	},
) (*repository.CakupanStorages, error) {
	// Aktor tidak diketahui → evaluasi per-user tak berlaku → fail-open
	// (endpoint-nya sendiri sudah wajib auth via guard).
	if userID == 0 {
		return nil, nil
	}
	// Modul 'inventory' belum ter-seed → dimensinya pun belum terdaftar → SEMUA.
	moduleID, err := aud.ResolveModuleID(ctx, exec, "inventory")
	if err != nil {
		return nil, err
	}
	if moduleID == nil {
		return nil, nil
	}
	d, err := sc.Values(ctx, exec, userID, "storages", moduleID)
	if err != nil {
		return nil, err
	}
	return repository.CakupanDariDecision(d), nil
}
