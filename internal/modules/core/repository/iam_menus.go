// repository/iam_menus.go — SATU-SATUNYA pengguna area sqlc MENUS (tabel
// `core_menus` + junction `core_roles_menus` — padanan MenusRepository
// NestJS). Pohon menu = penyusunan in-memory di service, bukan query.
package repository

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// MenusRepo — wrapper sqlc area menus.
type MenusRepo struct{}

// NewMenusRepo membuat repository menus.
func NewMenusRepo() *MenusRepo { return &MenusRepo{} }

// ListFlat — daftar menu FLAT (urut parent, "order", id persis sumber);
// moduleKey opsional (JOIN core_modules.key).
func (r *MenusRepo) ListFlat(ctx context.Context, exec DBTX, moduleKey *string) ([]gen.ListMenusFlatRow, error) {
	var nk gen.NullCoreModuleKey
	if moduleKey != nil && *moduleKey != "" {
		nk = gen.NullCoreModuleKey{CoreModuleKey: gen.CoreModuleKey(*moduleKey), Valid: true}
	}
	return gen.New(exec).ListMenusFlat(ctx, nk)
}

// FindById — menu by id (baris PENUH — audit beforeValue); null bila absen.
func (r *MenusRepo) FindById(ctx context.Context, exec DBTX, id int64) (*gen.FindMenuByIdRow, error) {
	row, err := gen.New(exec).FindMenuById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindIdById — id menu parent by id (ensureMenuExists); null bila tidak ada.
func (r *MenusRepo) FindIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindMenuIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindModuleIdById — id modul by id (ensureModuleExists); null bila absen.
func (r *MenusRepo) FindModuleIdById(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).FindModuleIdById(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// ListParentPairs — peta parent seluruh menu (tabel kecil) — input helper
// murni anti-siklus (domain.ApakahParentKeturunan).
func (r *MenusRepo) ListParentPairs(ctx context.Context, exec DBTX) ([]gen.ListParentPairsRow, error) {
	return gen.New(exec).ListParentPairs(ctx)
}

// ListMenuIdsByRole — id menu milik SATU role (junction).
func (r *MenusRepo) ListMenuIdsByRole(ctx context.Context, exec DBTX, roleID int64) ([]int64, error) {
	return gen.New(exec).IamListMenuIdsByRole(ctx, roleID)
}

// FindRoleById — role by id ({id, code} — entityId audit assign_roles).
func (r *MenusRepo) FindRoleById(ctx context.Context, exec DBTX, roleID int64) (*gen.FindRoleByIdRow, error) {
	row, err := gen.New(exec).FindRoleById(ctx, roleID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// FindRoleIdById — id role by id (ensure role ada); null bila tidak ada.
func (r *MenusRepo) FindRoleIdById(ctx context.Context, exec DBTX, roleID int64) (bool, error) {
	_, err := gen.New(exec).FindRoleIdById(ctx, roleID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// FindExistingMenuIds — menu id yang ada di antara kandidat (validasi assign).
func (r *MenusRepo) FindExistingMenuIds(ctx context.Context, exec DBTX, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return []int64{}, nil
	}
	return gen.New(exec).FindExistingMenuIds(ctx, ids)
}

// FindRoleUse — junction role↔menu masih memegang menu ini? (DELETE guard).
func (r *MenusRepo) FindRoleUse(ctx context.Context, exec DBTX, menuID int64) (bool, error) {
	_, err := gen.New(exec).FindMenuRoleUse(ctx, menuID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// Insert — insert menu (values dibangun service) → baris lengkap.
func (r *MenusRepo) Insert(ctx context.Context, exec DBTX, arg gen.InsertMenuParams) (*gen.InsertMenuRow, error) {
	row, err := gen.New(exec).InsertMenu(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// InsertMenuValues — rakit nilai insert menu (padankan insertMenu service
// NestJS: urlPath ?? null, parent ?? null, order ?? null, dst.).
func InsertMenuValues(text string, urlPath *string, parent *int64, order *int32, cssClass, icon, externalHref *string, moduleID *int64) gen.InsertMenuParams {
	return gen.InsertMenuParams{
		Text:          text,
		UrlPath:       TextPtrOf(urlPath),
		Parent:        Int8Of(parent),
		Order:         Int2Of(order),
		Class:         TextPtrOf(cssClass),
		Icon:          TextPtrOf(icon),
		ExternalHref:  TextPtrOf(externalHref),
		IDCoreModules: Int8Of(moduleID),
	}
}

// MenuPatch — set parsial UPDATE (persis drizzle .set(patch)): pointer nil =
// kolom tidak disentuh; nilai (termasuk NULL) = tulis.
type MenuPatch struct {
	Text         *string
	URLPath      *pgtype.Text
	Parent       *pgtype.Int8
	Order        *pgtype.Int2
	Class        *pgtype.Text
	Icon         *pgtype.Text
	ExternalHref *pgtype.Text
	ModuleID     *pgtype.Int8
	UpdatedAt    pgtype.Timestamptz
}

// Update — update menu by id (set dibangun pemanggil) → baris terbaru.
func (r *MenusRepo) Update(ctx context.Context, exec DBTX, id int64, p MenuPatch) (*gen.UpdateMenuRow, error) {
	arg := gen.UpdateMenuParams{UpdatedAt: p.UpdatedAt, ID: id}
	if p.Text != nil {
		arg.SetText = true
		arg.Text = *p.Text
	}
	if p.URLPath != nil {
		arg.SetUrlPath = true
		arg.UrlPath = *p.URLPath
	}
	if p.Parent != nil {
		arg.SetParent = true
		arg.Parent = *p.Parent
	}
	if p.Order != nil {
		arg.SetOrder = true
		arg.OrderIndex = *p.Order
	}
	if p.Class != nil {
		arg.SetClass = true
		arg.Class = *p.Class
	}
	if p.Icon != nil {
		arg.SetIcon = true
		arg.Icon = *p.Icon
	}
	if p.ExternalHref != nil {
		arg.SetExternalHref = true
		arg.ExternalHref = *p.ExternalHref
	}
	if p.ModuleID != nil {
		arg.SetModule = true
		arg.ModuleID = *p.ModuleID
	}
	row, err := gen.New(exec).UpdateMenu(ctx, arg)
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// DeleteById — hapus menu fisik by id (child ikut FK parent CASCADE).
func (r *MenusRepo) DeleteById(ctx context.Context, exec DBTX, id int64) error {
	_, err := gen.New(exec).DeleteMenuById(ctx, id)
	return err
}

// DeleteMenusByRole — REPLACE tahap 1 (hapus seluruh junction milik role).
func (r *MenusRepo) DeleteMenusByRole(ctx context.Context, exec DBTX, roleID int64) error {
	return gen.New(exec).DeleteMenusByRole(ctx, roleID)
}

// InsertRoleMenu — sisip satu pasangan junction role↔menu (idempoten).
func (r *MenusRepo) InsertRoleMenu(ctx context.Context, exec DBTX, roleID, menuID int64) error {
	return gen.New(exec).InsertRoleMenu(ctx, gen.InsertRoleMenuParams{
		IDCoreRoles: roleID,
		IDCoreMenus: menuID,
	})
}

// ---------------------------------------------------------------------
// Mapper menu → view (padankan menuToView; kolom `class` tak dipublikasikan)
// ---------------------------------------------------------------------

// MenuToView — baris core_menus → types.Menu (menuSchema).
func menuToViewCols(id int64, text string, urlPath, icon, externalHref pgtype.Text, order pgtype.Int2, parent pgtype.Int8, idCoreModules pgtype.Int8) types.Menu {
	return types.Menu{
		ID: id, Text: text, URLPath: PgTextPtr(urlPath), Order: Int2Ptr(order),
		Parent: Int8Ptr(parent), Icon: PgTextPtr(icon), ExternalHref: PgTextPtr(externalHref),
		IDCoreModules: Int8Ptr(idCoreModules),
	}
}

// MenuToViewList / Find / Insert / Update — varian Row gen berkolom live
// identik (entity_id porting tidak disertakan query-nya).
func MenuToViewList(m gen.ListMenusFlatRow) types.Menu {
	return menuToViewCols(m.ID, m.Text, m.UrlPath, m.Icon, m.ExternalHref, m.Order, m.Parent, m.IDCoreModules)
}

func MenuToViewFind(m gen.FindMenuByIdRow) types.Menu {
	return menuToViewCols(m.ID, m.Text, m.UrlPath, m.Icon, m.ExternalHref, m.Order, m.Parent, m.IDCoreModules)
}

func MenuToViewInsert(m gen.InsertMenuRow) types.Menu {
	return menuToViewCols(m.ID, m.Text, m.UrlPath, m.Icon, m.ExternalHref, m.Order, m.Parent, m.IDCoreModules)
}

func MenuToViewUpdate(m gen.UpdateMenuRow) types.Menu {
	return menuToViewCols(m.ID, m.Text, m.UrlPath, m.Icon, m.ExternalHref, m.Order, m.Parent, m.IDCoreModules)
}
