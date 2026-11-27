// repository/iam_routes.go — SATU-SATUNYA pengguna area sqlc ROUTES
// (registry `core_routes` — padanan RoutesRepository NestJS). List ber-
// pagination ditulis langsung lewat executor (ORDER BY dinamis dari
// whitelist statis — sqlc tidak mendukung ORDER BY dinamis); nilai filter
// tetap parameter $n. Mapper RouteToView ada di iam_views.go.
package repository

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// RoutesRepo — wrapper sqlc area routes (tanpa state — executor per panggilan).
type RoutesRepo struct{}

// NewRoutesRepo membuat repository routes.
func NewRoutesRepo() *RoutesRepo { return &RoutesRepo{} }

// kolomSortRoutes — whitelist sort list routes (persis drizzlePageBounds).
var kolomSortRoutes = map[string]string{
	"id":              "id",
	"method":          "method",
	"uri_pattern":     "uri_pattern",
	"permission_code": "permission_code",
	"created_at":      "created_at",
	"updated_at":      "updated_at",
}

// ListAllForMap — peta "METHOD /uri" → permission code (tanpa paging);
// method DI-KAPITALKAN oleh service (persis r.method.toUpperCase()).
func (r *RoutesRepo) ListAllForMap(ctx context.Context, exec DBTX) ([]gen.ListAllForMapRow, error) {
	return gen.New(exec).ListAllForMap(ctx)
}

// FindById — route by id (null bila tidak ada; service → 404).
func (r *RoutesRepo) FindById(ctx context.Context, exec DBTX, id int64) (*gen.CoreRoute, error) {
	row, err := gen.New(exec).FindRouteById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// List — daftar route paginated: filter `method` (exact, lowercase),
// `module` (prefix permission_code `key.`), `search` (ILIKE uri/kode).
// Default urut `uri_pattern ASC, id ASC` (persis sumber).
func (r *RoutesRepo) List(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest) ([]types.RouteView, int, error) {
	if err := shared.SortUnknown(pr, keysOf(kolomSortRoutes)); err != nil {
		return nil, 0, err
	}

	conds := []string{}
	args := []any{}
	if method := pr.Filters["method"]; method != "" {
		conds = append(conds, fmt.Sprintf("method::text = $%d", len(args)+1))
		args = append(args, strings.ToLower(method))
	}
	if module := pr.Filters["module"]; module != "" {
		conds = append(conds, fmt.Sprintf("permission_code LIKE $%d", len(args)+1))
		args = append(args, module+".%")
	}
	if search := pr.Filters["search"]; search != "" {
		n := len(args) + 1
		conds = append(conds, fmt.Sprintf("(uri_pattern ILIKE $%d OR permission_code ILIKE $%d)", n, n))
		args = append(args, "%"+search+"%")
	}
	where := ""
	if len(conds) > 0 {
		where = " WHERE " + strings.Join(conds, " AND ")
	}

	var total int
	if err := exec.QueryRow(ctx,
		"SELECT count(*) FROM core_routes"+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	sql := "SELECT id, method, uri_pattern, permission_code, created_at, updated_at FROM core_routes" +
		where + " ORDER BY " + orderClause(pr, kolomSortRoutes, "uri_pattern ASC, id ASC") +
		fmt.Sprintf(" LIMIT $%d OFFSET $%d", len(args)+1, len(args)+2)
	args = append(args, pr.Limit, pr.Offset)

	rows, err := exec.Query(ctx, sql, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []types.RouteView{}
	for rows.Next() {
		var id int64
		var method gen.CoreHttpMethod
		var uri, code string
		var createdAt, updatedAt pgtype.Timestamptz
		if err := rows.Scan(&id, &method, &uri, &code, &createdAt, &updatedAt); err != nil {
			return nil, 0, err
		}
		out = append(out, RouteToView(id, string(method), uri, code, createdAt, updatedAt))
	}
	return out, total, rows.Err()
}

// keysOf — kunci map whitelist (untuk shared.SortUnknown).
func keysOf(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
