// service/iam_menus.go — menu tree data-driven (`core_menus`) + junction
// `core_roles_menus` (padanan IamMenusService NestJS). DELETE menolak menu
// yang masih dipegang role (409); child ikut terhapus (FK parent CASCADE);
// PUT /:id/roles REPLACE menu milik SATU role lalu compiler.InvalidateAll()
// SETELAH commit.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/domain"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// MenuInput — body menu (createMenuSchema / updateMenuSchema): hadir-nya
// field dibedakan dari nilainya (Has* + *nilai — null = bersihkan kolom).
type MenuInput struct {
	HasText       bool
	Text          string
	HasURLPath    bool
	URLPath       *string
	HasParent     bool
	Parent        *int64
	HasOrder      bool
	Order         *int32
	HasCssClass   bool
	CssClass      *string
	HasIcon       bool
	Icon          *string
	HasExtHref    bool
	ExternalHref  *string
	HasModuleID   bool
	IDCoreModules *int64
}

// ListFlat — daftar menu datar (urut parent, order, id — port nav mock);
// moduleKey opsional.
func (s *IamMenusService) ListFlat(ctx context.Context, moduleKey *string) ([]types.Menu, error) {
	rows, err := s.repo.ListFlat(ctx, s.db.Pool, moduleKey)
	if err != nil {
		return nil, err
	}
	out := make([]types.Menu, 0, len(rows))
	for _, m := range rows {
		out = append(out, repository.MenuToViewList(m))
	}
	return out, nil
}

// pmenu — node pohon internal (tautan pointer; dimaterialisasi setelah
// seluruh parent→children tersambung agar tidak ada copy basi).
type pmenu struct {
	view *types.MenuTreeNode
	kids []*pmenu
}

// ListTree — daftar menu bertingkat (parent → children); child yang
// parentnya ter-filter keluar naik jadi root (persis sumber).
func (s *IamMenusService) ListTree(ctx context.Context, moduleKey *string) ([]types.MenuTreeNode, error) {
	flat, err := s.ListFlat(ctx, moduleKey)
	if err != nil {
		return nil, err
	}
	byID := map[int64]*pmenu{}
	roots := []*pmenu{}
	nodes := make([]*pmenu, len(flat))
	for i := range flat {
		n := &pmenu{view: &types.MenuTreeNode{
			ID:            flat[i].ID,
			Text:          flat[i].Text,
			URLPath:       flat[i].URLPath,
			Order:         flat[i].Order,
			Icon:          flat[i].Icon,
			ExternalHref:  flat[i].ExternalHref,
			IDCoreModules: flat[i].IDCoreModules,
			Children:      []types.MenuTreeNode{},
		}}
		nodes[i] = n
		byID[n.view.ID] = n
	}
	for i := range flat {
		if flat[i].Parent != nil && byID[*flat[i].Parent] != nil {
			p := byID[*flat[i].Parent]
			p.kids = append(p.kids, nodes[i])
		} else {
			// parent tidak ada / null / di luar filter modul → root.
			roots = append(roots, nodes[i])
		}
	}
	out := []types.MenuTreeNode{}
	for _, r := range roots {
		out = append(out, materializeMenu(r))
	}
	return out, nil
}

// materializeMenu — pohon pointer → nilai view rekursif.
func materializeMenu(p *pmenu) types.MenuTreeNode {
	out := *p.view
	out.Children = []types.MenuTreeNode{}
	for _, k := range p.kids {
		out.Children = append(out.Children, materializeMenu(k))
	}
	return out
}

// Create — tambah menu; parent & modul wajib ada bila diisi (404 SYS-404).
func (s *IamMenusService) Create(ctx context.Context, in MenuInput, actor audit.Actor) (*types.Menu, error) {
	var view *types.Menu
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if in.Parent != nil {
			if err := s.ensureMenuExists(ctx, tx, *in.Parent); err != nil {
				return err
			}
		}
		if in.IDCoreModules != nil {
			if err := s.ensureModuleExists(ctx, tx, *in.IDCoreModules); err != nil {
				return err
			}
		}
		inserted, err := s.repo.Insert(ctx, tx, repository.InsertMenuValues(
			in.Text, in.URLPath, in.Parent, in.Order,
			in.CssClass, in.Icon, in.ExternalHref, in.IDCoreModules))
		if err != nil {
			return err
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "iam_menu",
			EntityID:   fmt.Sprintf("%d", inserted.ID),
			Action:     "create",
			AfterValue: menuSnapshot(inserted.Text, inserted.UrlPath, inserted.Parent),
		}, Actor: actor}}); err != nil {
			return err
		}
		v := repository.MenuToViewInsert(*inserted)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Update — ubah menu (semua field opsional; parent divalidasi +
// anti-self-parent + anti-siklus domain.ApakahParentKeturunan).
func (s *IamMenusService) Update(ctx context.Context, id int64, in MenuInput, actor audit.Actor) (*types.Menu, error) {
	var view *types.Menu
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Menu id %d tidak ditemukan.", id), "SYS-404")
		}

		patch := repository.MenuPatch{UpdatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true}}
		if in.HasText {
			patch.Text = &in.Text
		}
		if in.HasURLPath {
			patch.URLPath = &pgtype.Text{String: iamDerefStr(in.URLPath), Valid: in.URLPath != nil}
		}
		if in.HasOrder {
			patch.Order = &pgtype.Int2{Int16: int16(iamDerefInt32(in.Order)), Valid: in.Order != nil}
		}
		if in.HasCssClass {
			patch.Class = &pgtype.Text{String: iamDerefStr(in.CssClass), Valid: in.CssClass != nil}
		}
		if in.HasIcon {
			patch.Icon = &pgtype.Text{String: iamDerefStr(in.Icon), Valid: in.Icon != nil}
		}
		if in.HasExtHref {
			patch.ExternalHref = &pgtype.Text{String: iamDerefStr(in.ExternalHref), Valid: in.ExternalHref != nil}
		}
		if in.HasModuleID {
			if in.IDCoreModules != nil {
				if err := s.ensureModuleExists(ctx, tx, *in.IDCoreModules); err != nil {
					return err
				}
			}
			patch.ModuleID = &pgtype.Int8{Int64: iamDerefInt64(in.IDCoreModules), Valid: in.IDCoreModules != nil}
		}
		if in.HasParent {
			if in.Parent != nil && *in.Parent == id {
				return errkontrak.Validation([]errkontrak.FieldIssue{{
					Field:   "parent",
					Message: "Menu tidak boleh menjadi parent dirinya sendiri.",
				}})
			}
			if in.Parent != nil {
				if err := s.ensureMenuExists(ctx, tx, *in.Parent); err != nil {
					return err
				}
				// Anti-siklus non-trivial — parent tidak boleh keturunan
				// sendiri (guard FE saja tidak cukup). Satu query muat peta
				// parent seluruh menu (tabel kecil) — accessor sinkron untuk
				// helper murni.
				pairs, err := s.repo.ListParentPairs(ctx, tx)
				if err != nil {
					return err
				}
				petaParent := map[int64]*int64{}
				for _, p := range pairs {
					if p.Parent.Valid {
						v := p.Parent.Int64
						petaParent[p.ID] = &v
					} else {
						petaParent[p.ID] = nil
					}
				}
				if domain.ApakahParentKeturunan(func(mid int64) *int64 {
					return petaParent[mid]
				}, id, *in.Parent) {
					return errkontrak.Validation([]errkontrak.FieldIssue{{
						Field:   "parent",
						Message: "Parent tidak boleh turunan menu itu sendiri (membuat siklus).",
					}})
				}
			}
			patch.Parent = &pgtype.Int8{Int64: iamDerefInt64(in.Parent), Valid: in.Parent != nil}
		}

		updated, err := s.repo.Update(ctx, tx, id, patch)
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:   "system",
			EntityType:  "iam_menu",
			EntityID:    fmt.Sprintf("%d", id),
			Action:      "update",
			BeforeValue: menuSnapshot(row.Text, row.UrlPath, row.Parent),
			AfterValue:  menuSnapshot(updated.Text, updated.UrlPath, updated.Parent),
			Severity:    audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}
		v := repository.MenuToViewUpdate(*updated)
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}
	return view, nil
}

// Remove — hapus menu fisik; 409 SYS-409 bila masih dipegang role.
func (s *IamMenusService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Menu id %d tidak ditemukan.", id), "SYS-404")
		}

		used, err := s.repo.FindRoleUse(ctx, tx, id)
		if err != nil {
			return err
		}
		if used {
			return errkontrak.Conflict(fmt.Sprintf("Menu '%s' masih dipegang role — lepas dulu (PUT /system/menus/:id/roles).", row.Text), "SYS-409")
		}

		if err := s.repo.DeleteById(ctx, tx, id); err != nil { // child ikut (CASCADE)
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:   "system",
			EntityType:  "iam_menu",
			EntityID:    fmt.Sprintf("%d", id),
			Action:      "delete",
			BeforeValue: menuSnapshot(row.Text, row.UrlPath, row.Parent),
			Severity:    audit.SeverityWarning,
		}, Actor: actor}})
		return err
	})
}

// AssignMenusInput — body PUT /menus/:id/roles (assignMenusSchema).
type AssignMenusInput struct {
	RoleID  int64
	MenuIds []int64
}

// AssignMenusResult — hasil REPLACE.
type AssignMenusResult struct {
	MenuIds []int64 `json:"menuIds"`
}

// AssignMenusToRole — REPLACE menu milik SATU role; body.roleId wajib sama
// dengan path (400 bila beda). Setelah commit compiler.InvalidateAll() —
// set efektif + sesi berubah.
func (s *IamMenusService) AssignMenusToRole(ctx context.Context, roleId int64, in AssignMenusInput, actor audit.Actor) (*AssignMenusResult, error) {
	if in.RoleID != roleId {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
			Field:   "roleId",
			Message: fmt.Sprintf("roleId body (%d) harus sama dengan id di path (%d).", in.RoleID, roleId),
		}})
	}
	var assigned []int64
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		role, err := s.repo.FindRoleById(ctx, tx, roleId)
		if err != nil {
			return err
		}
		if role == nil {
			return errkontrak.NotFound(fmt.Sprintf("Role id %d tidak ditemukan.", roleId), "SYS-404")
		}

		before, err := s.repo.ListMenuIdsByRole(ctx, tx, roleId)
		if err != nil {
			return err
		}

		uniqueIds := iamDedupeInt64(in.MenuIds)
		if len(uniqueIds) > 0 {
			found, err := s.repo.FindExistingMenuIds(ctx, tx, uniqueIds)
			if err != nil {
				return err
			}
			if len(found) != len(uniqueIds) {
				foundSet := map[int64]bool{}
				for _, f := range found {
					foundSet[f] = true
				}
				missing := []int64{}
				for _, mid := range uniqueIds {
					if !foundSet[mid] {
						missing = append(missing, mid)
					}
				}
				return errkontrak.NotFound(fmt.Sprintf("Menu tidak ditemukan: %s.", iamJoinInt64(missing)), "SYS-404")
			}
		}

		// REPLACE junction role ↔ menu.
		if err := s.repo.DeleteMenusByRole(ctx, tx, roleId); err != nil {
			return err
		}
		for _, mid := range uniqueIds {
			if err := s.repo.InsertRoleMenu(ctx, tx, roleId, mid); err != nil {
				return err
			}
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:   "system",
			EntityType:  "iam_menu",
			EntityID:    role.Code,
			Action:      "assign_roles",
			BeforeValue: audit.Snapshot{"menu_ids": iamInt64sToAny(before)},
			AfterValue:  audit.Snapshot{"menu_ids": iamInt64sToAny(uniqueIds)},
			Severity:    audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}
		assigned = uniqueIds
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Sesi /auth/me membaca menu via JOIN junction — buang cache permission
	// supaya klien mendapat konteks konsisten setelah mutasi nav.
	s.compiler.InvalidateAll()
	return &AssignMenusResult{MenuIds: assigned}, nil
}

// ---------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------

// menuSnapshot — snapshot jsonb menu {text, url_path, parent}.
func menuSnapshot(text string, urlPath pgtype.Text, parent pgtype.Int8) audit.Snapshot {
	return audit.Snapshot{
		"text":     text,
		"url_path": repository.PgTextPtr(urlPath),
		"parent":   repository.Int8Ptr(parent),
	}
}

// ensureMenuExists — 404 `Menu parent id ${id} tidak ditemukan.` (persis).
func (s *IamMenusService) ensureMenuExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("Menu parent id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// ensureModuleExists — modul pemilik menu wajib ada bila diisi.
func (s *IamMenusService) ensureModuleExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ok, err := s.repo.FindModuleIdById(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ok {
		return errkontrak.NotFound(fmt.Sprintf("Modul id %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}
