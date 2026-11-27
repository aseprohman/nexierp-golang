// Package repository — SATU-SATUNYA pengguna pgx+sqlc fitur RBAC: pembungkus
// tipis query gen (routes, permissions, datascope) untuk service
// registry/compiler/scope. Parsing segmen, sort precedence, cache, dan
// semantik merge tetap di service (internal/core/rbac).
package repository

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/rbac/repository/gen"
)

// Executor — executor yang boleh dilewatkan: pool (database.DB.Pool) atau
// tx (pgx.Tx) — padanan `Db | Tx` NestJS. Keduanya memenuhi gen.DBTX.
type Executor = gen.DBTX

// Repo — pembungkus query sqlc rbac.
type Repo struct {
	q *gen.Queries
}

// New membuat repo di atas executor (pool atau tx).
func New(exec Executor) *Repo {
	return &Repo{q: gen.New(exec)}
}

// WithTx mengembalikan repo yang berjalan di atas transaksi (pola unit-of-
// work: teruskan tx, jangan buka tx baru di dalam tx).
func (r *Repo) WithTx(tx pgx.Tx) *Repo {
	return &Repo{q: r.q.WithTx(tx)}
}

// ListRoutes — muat SELURUH baris core_routes (dipakai RouteRegistry.doLoad;
// registry kosong saat gagal ditangani service — fail-closed).
func (r *Repo) ListRoutes(ctx context.Context) ([]gen.ListRoutesRow, error) {
	return r.q.ListRoutes(ctx)
}

// RoleRouteCodes — (1) UNION DISTINCT code route via SEMUA SET yang
// di-grant ke role user — hanya SET 'active' dan modulnya enabled (SET
// tanpa modul tetap dihitung).
func (r *Repo) RoleRouteCodes(ctx context.Context, userID int64) ([]string, error) {
	return r.q.RoleRouteCodes(ctx, userID)
}

// UserRouteOverrides — (2) override per-user PER SET permission (granted +
// code route hasil pancaran junction); hanya baris hidup yang belum
// kedaluwarsa.
func (r *Repo) UserRouteOverrides(ctx context.Context, userID int64) ([]gen.UserRouteOverridesRow, error) {
	return r.q.UserRouteOverrides(ctx, userID)
}

// ScopeDefinitionIDs — definisi aktif untuk scope_key (opsional persempit
// per modul); kosong = dimensi belum terdaftar (service memutuskan
// fail-open).
func (r *Repo) ScopeDefinitionIDs(ctx context.Context, scopeKey string, moduleID *int64) ([]int64, error) {
	var mod pgtype.Int8
	if moduleID != nil {
		mod = pgtype.Int8{Int64: *moduleID, Valid: true}
	}
	return r.q.ScopeDefinitionIDs(ctx, gen.ScopeDefinitionIDsParams{
		ScopeKey: scopeKey,
		ModuleID: mod,
	})
}

// UserRoleIDs — id semua role milik user (union assignment role).
func (r *Repo) UserRoleIDs(ctx context.Context, userID int64) ([]int64, error) {
	return r.q.UserRoleIDs(ctx, userID)
}

// ScopeAssignmentValueRows — baris assignment aktif milik user ATAU
// role-nya untuk definisi defIDs — LEFT JOIN values agar assignment dengan
// 0 nilai tetap terdeteksi (value NULL = deny-all, bukan fallback ke role).
// roleIDs kosong = hanya pencocokan user.
func (r *Repo) ScopeAssignmentValueRows(ctx context.Context, defIDs []int64, userID int64, roleIDs []int64) ([]gen.ScopeAssignmentValueRowsRow, error) {
	return r.q.ScopeAssignmentValueRows(ctx, gen.ScopeAssignmentValueRowsParams{
		DefIds:  defIDs,
		UserID:  userID,
		RoleIds: roleIDs,
	})
}
