// repository/iam_permissions.go — SATU-SATUNYA pengguna area sqlc PERMISSIONS
// (katalog SET `core_permissions` + junction `core_permissions_routes` —
// padanan PermissionsRepository NestJS). List ber-pagination + sort dinamis
// lewat executor (whitelist statis); nilai filter tetap parameter $n.
package repository

import (
	"context"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// PermissionsRepo — wrapper sqlc area permissions.
type PermissionsRepo struct{}

// NewPermissionsRepo membuat repository permissions.
func NewPermissionsRepo() *PermissionsRepo { return &PermissionsRepo{} }

// kolomSortPermissions — whitelist sort list SET (persis drizzlePageBounds).
var kolomSortPermissions = map[string]string{
	"id":         "core_permissions.id",
	"name":       "core_permissions.name",
	"status":     "core_permissions.status",
	"created_at": "core_permissions.created_at",
}

// FindById — SET by id (baris PENUH — audit before/after); null bila absen.
func (r *PermissionsRepo) FindById(ctx context.Context, exec DBTX, id int64) (*gen.CorePermission, error) {
	row, err := gen.New(exec).FindPermissionById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindIdById — id SET by id (guard junction GET /:id/routes).
func (r *PermissionsRepo) FindIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindPermissionIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindDuplicateByName — duplikat nama SET pada modul (unique index
// (name, id_core_modules)); modul null → bandingkan baris TANPA modul.
func (r *PermissionsRepo) FindDuplicateByName(ctx context.Context, exec DBTX, name string, idCoreModules *int64) (bool, error) {
	_, err := gen.New(exec).FindPermissionDuplicateByName(ctx, gen.FindPermissionDuplicateByNameParams{
		Name:     pgtype.Text{String: name, Valid: true},
		ModuleID: int64OrZero(idCoreModules),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindModuleKeyById — moduleKey by id modul (id null → null; absen → null).
func (r *PermissionsRepo) FindModuleKeyById(ctx context.Context, exec DBTX, id *int64) (*string, error) {
	if id == nil {
		return nil, nil
	}
	key, err := gen.New(exec).FindModuleKeyById(ctx, *id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s := string(key)
	return &s, nil
}

// FindModuleIdByKey — id modul by key (resolveModuleRefs); null bila absen.
func (r *PermissionsRepo) FindModuleIdByKey(ctx context.Context, exec DBTX, moduleKey string) (*int64, error) {
	id, err := gen.New(exec).FindModuleIdByKey(ctx, moduleKey)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// FindFeatureIdByModuleAndFolder — id fitur (modul + folder); null bila absen.
func (r *PermissionsRepo) FindFeatureIdByModuleAndFolder(ctx context.Context, exec DBTX, idCoreModules int64, featuresFolder string) (*int64, error) {
	id, err := gen.New(exec).FindFeatureIdByModuleAndFolder(ctx, gen.FindFeatureIdByModuleAndFolderParams{
		IDCoreModules:  idCoreModules,
		FeaturesFolder: featuresFolder,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// FindRoleUse — SET masih disandang role? (junction core_role_permissions).
func (r *PermissionsRepo) FindRoleUse(ctx context.Context, exec DBTX, permissionID int64) (bool, error) {
	_, err := gen.New(exec).FindPermissionRoleUse(ctx, permissionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindRouteUse — SET masih terhubung route? (junction core_permissions_routes).
func (r *PermissionsRepo) FindRouteUse(ctx context.Context, exec DBTX, permissionID int64) (bool, error) {
	_, err := gen.New(exec).FindPermissionRouteUse(ctx, permissionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// ListRouteIds — id route ter-junction ke SET (centangan FE; sort numeric
// asc dilakukan service).
func (r *PermissionsRepo) ListRouteIds(ctx context.Context, exec DBTX, permissionID int64) ([]int64, error) {
	return gen.New(exec).ListRouteIdsByPermission(ctx, permissionID)
}

// FindExistingRouteIds — route id yang ada di antara kandidat (validasi assign).
func (r *PermissionsRepo) FindExistingRouteIds(ctx context.Context, exec DBTX, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return []int64{}, nil
	}
	return gen.New(exec).FindExistingRouteIds(ctx, ids)
}

// CountRoutesByPermission — jumlah route pada SET (junction).
func (r *PermissionsRepo) CountRoutesByPermission(ctx context.Context, exec DBTX, permissionID int64) (int, error) {
	n, err := gen.New(exec).CountRoutesByPermission(ctx, permissionID)
	return int(n), err
}

// Insert — insert SET permission (values dibangun service) → baris lengkap.
func (r *PermissionsRepo) Insert(ctx context.Context, exec DBTX, arg gen.InsertPermissionParams) (*gen.CorePermission, error) {
	row, err := gen.New(exec).InsertPermission(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// PermissionPatch — set parsial UPDATE (persis drizzle .set(patch)): pointer
// nil = kolom tidak disentuh; nilai (termasuk NULL) = tulis.
type PermissionPatch struct {
	Name        *pgtype.Text
	Description *pgtype.Text
	Status      *gen.CorePermissionStatus
	ModuleID    *pgtype.Int8
	FeatureID   *pgtype.Int8
	UpdatedAt   pgtype.Timestamptz
}

// Update — update SET by id (set dibangun pemanggil) → baris terbaru.
func (r *PermissionsRepo) Update(ctx context.Context, exec DBTX, id int64, p PermissionPatch) (*gen.CorePermission, error) {
	arg := gen.UpdatePermissionParams{UpdatedAt: p.UpdatedAt, ID: id}
	if p.Name != nil {
		arg.SetName = true
		arg.Name = *p.Name
	}
	if p.Description != nil {
		arg.SetDescription = true
		arg.Description = *p.Description
	}
	if p.Status != nil {
		arg.SetStatus = true
		arg.Status = *p.Status
	}
	if p.ModuleID != nil {
		arg.SetModule = true
		arg.ModuleID = *p.ModuleID
	}
	if p.FeatureID != nil {
		arg.SetFeature = true
		arg.FeatureID = *p.FeatureID
	}
	row, err := gen.New(exec).UpdatePermission(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// DeleteById — hapus fisik SET (guard role/route oleh service).
func (r *PermissionsRepo) DeleteById(ctx context.Context, exec DBTX, id int64) error {
	_, err := gen.New(exec).DeletePermissionById(ctx, id)
	return err
}

// DeleteRoutesByPermission — REPLACE tahap 1 (hapus seluruh junction milik SET).
func (r *PermissionsRepo) DeleteRoutesByPermission(ctx context.Context, exec DBTX, permissionID int64) error {
	return gen.New(exec).DeleteRoutesByPermission(ctx, permissionID)
}

// InsertPermissionRoute — sisip satu pasangan junction (idempoten DO NOTHING).
func (r *PermissionsRepo) InsertPermissionRoute(ctx context.Context, exec DBTX, routeID, permissionID int64) error {
	return gen.New(exec).InsertPermissionRoute(ctx, gen.InsertPermissionRouteParams{
		IDCoreRoutes:      routeID,
		IDCorePermissions: permissionID,
	})
}

// List — daftar SET paginated + filter `module` (key) & `status`; default
// `name ASC` (persis sumber); routeCount = subquery scalar junction.
func (r *PermissionsRepo) List(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest) ([]types.PermissionView, int, error) {
	if err := shared.SortUnknown(pr, keysOf(kolomSortPermissions)); err != nil {
		return nil, 0, err
	}

	conds := []string{}
	args := []any{}
	moduleKey := firstOf(pr.Filters, "module", "moduleKey")
	if moduleKey != "" {
		conds = append(conds, "core_modules.key::text = $"+strconv.Itoa(len(args)+1))
		args = append(args, moduleKey)
	}
	if status := pr.Filters["status"]; status == "active" || status == "disabled" {
		conds = append(conds, "core_permissions.status::text = $"+strconv.Itoa(len(args)+1))
		args = append(args, status)
	}
	where := ""
	if len(conds) > 0 {
		where = " WHERE " + joinAnd(conds)
	}

	var total int
	if err := exec.QueryRow(ctx, "SELECT count(*) FROM core_permissions LEFT JOIN core_modules ON core_permissions.id_core_modules = core_modules.id"+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}

	// routeCount = jumlah route pada SET (subquery scalar — aman pagination).
	sql := `SELECT core_permissions.id, core_permissions.name, core_permissions.description,
	       core_modules.key, core_permissions.status, core_permissions.is_system,
	       core_permissions.created_at,
	       (SELECT count(*) FROM core_permissions_routes pr WHERE pr.id_core_permissions = core_permissions.id) AS route_count
	FROM core_permissions
	LEFT JOIN core_modules ON core_permissions.id_core_modules = core_modules.id` +
		where + " ORDER BY " + orderClause(pr, kolomSortPermissions, "core_permissions.name ASC") +
		" LIMIT $" + strconv.Itoa(len(args)+1) + " OFFSET $" + strconv.Itoa(len(args)+2)
	args = append(args, pr.Limit, pr.Offset)

	rows, err := exec.Query(ctx, sql, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []types.PermissionView{}
	for rows.Next() {
		var id int64
		var name, description, moduleKey pgtype.Text
		var status gen.CorePermissionStatus
		var isSystem bool
		var createdAt pgtype.Timestamptz
		var routeCount int
		if err := rows.Scan(&id, &name, &description, &moduleKey, &status, &isSystem, &createdAt, &routeCount); err != nil {
			return nil, 0, err
		}
		out = append(out, types.PermissionView{
			ID:          id,
			Name:        PermissionNameOf(name, id),
			Description: PgTextPtr(description),
			ModuleKey:   PgTextPtr(moduleKey),
			Status:      string(status),
			IsSystem:    isSystem,
			RouteCount:  routeCount,
			CreatedAt:   IsoRequired(createdAt),
		})
	}
	return out, total, rows.Err()
}

// ---------------------------------------------------------------------
// helper kecil (dipakai file iam_*.go lain dalam package ini)
// ---------------------------------------------------------------------

// InsertPermissionValues — rakit nilai insert SET permission (dibangun service).
func InsertPermissionValues(name string, description *string, moduleID, featureID *int64) gen.InsertPermissionParams {
	return gen.InsertPermissionParams{
		Name:                  pgtype.Text{String: name, Valid: true},
		Description:           TextPtrOf(description),
		IDCoreModules:         Int8Of(moduleID),
		IDCoreModulesFeatures: Int8Of(featureID),
		IsSystem:              false,
	}
}

// StatusOf — string body → enum pg core_permission_status (zod membatasi
// active|disabled sebelum sampai sini).
func StatusOf(s string) gen.CorePermissionStatus {
	return gen.CorePermissionStatus(s)
}

// PermissionToView — baris core_permissions → PermissionView (padankan
// permissionToView: name NULL → fallback `set#<id>`).
func PermissionToView(row *gen.CorePermission, moduleKey *string, routeCount int) types.PermissionView {
	return types.PermissionView{
		ID:          row.ID,
		Name:        PermissionNameOf(row.Name, row.ID),
		Description: PgTextPtr(row.Description),
		ModuleKey:   moduleKey,
		Status:      string(row.Status),
		IsSystem:    row.IsSystem,
		RouteCount:  routeCount,
		CreatedAt:   IsoRequired(row.CreatedAt),
	}
}

func int64OrZero(v *int64) int64 {
	if v == nil {
		return 0
	}
	return *v
}

func firstOf(m map[string]string, keys ...string) string {
	for _, k := range keys {
		if v := m[k]; v != "" {
			return v
		}
	}
	return ""
}

func joinAnd(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += " AND "
		}
		out += p
	}
	return out
}
