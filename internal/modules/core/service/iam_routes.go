// service/iam_routes.go — CRUD registry `core_routes` (padanan
// IamRoutesService NestJS). Invalidasi registry SETELAH mutasi adalah
// urusan service (list/detail/get adalah baca murni). Peta `map` =
// rakitan in-memory hasil baca repo.
package service

import (
	"context"
	"fmt"
	"strings"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// Map — peta "METHOD /uri" → permission code (seluruh core_routes, tanpa
// paging); method di-KAPITALKAN (persis r.method.toUpperCase()).
func (s *IamRoutesService) Map(ctx context.Context) (map[string]string, error) {
	rows, err := s.repo.ListAllForMap(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(rows))
	for _, r := range rows {
		out[strings.ToUpper(string(r.Method))+" "+r.UriPattern] = r.PermissionCode
	}
	return out, nil
}

// List — halaman route (filter method/module/search + sort whitelist;
// default uri_pattern asc, id asc).
func (s *IamRoutesService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.RouteView], error) {
	data, total, err := s.repo.List(ctx, s.db.Pool, pr)
	if err != nil {
		return errkontrak.Page[types.RouteView]{}, err
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Get — detail satu route; 404 SYS-404 pesan verbatim.
func (s *IamRoutesService) Get(ctx context.Context, id int64) (*types.RouteView, error) {
	row, err := s.repo.FindById(ctx, s.db.Pool, id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, errkontrak.NotFound(fmt.Sprintf("Route id %d tidak ditemukan.", id), "SYS-404")
	}
	view := repository.RouteToView(row.ID, string(row.Method), row.UriPattern, row.PermissionCode, row.CreatedAt, row.UpdatedAt)
	return &view, nil
}

// ReloadResult — hasil POST /reload.
type ReloadResult struct {
	Total int `json:"total"`
}

// Reload — paksa registry muat ulang core_routes (TANPA audit); total =
// registry.Size() persis sumber.
func (s *IamRoutesService) Reload() ReloadResult {
	s.registry.Invalidate()
	return ReloadResult{Total: s.registry.Size()}
}
