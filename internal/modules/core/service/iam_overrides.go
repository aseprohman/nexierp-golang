// service/iam_overrides.go — pengecualian permission per-USER berbasis
// PERMISSION (SET) `core_user_permissions` (padanan IamUserOverridesService
// NestJS): baris unik (user, permission) untuk baris hidup; granted=false =
// deny eksplisit; hapus = SOFT DELETE. Semua mutasi → audit (`user_permission`)
// + compiler.InvalidateUser. Presedensi invalidasi VERBATIM sumber: create
// SETELAH commit; delete DI DALAM closure tx.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// iamISO — format ISO-8601 offset padanan toISOString JS (UTC + milidetik).
const iamISO = "2006-01-02T15:04:05.000Z07:00"

// OverrideBuat — body POST (userOverrideBuatSchema): userId, permissionId,
// granted, expiresAt (ISO 8601; null/tidak dikirim = permanen).
type OverrideBuat struct {
	UserID       int64
	PermissionID int64
	Granted      bool
	ExpiresAt    *string // nil = permanen
}

// List — daftar override milik SATU user (paginated + filter `search`
// ILIKE nama SET). Default `granted_at desc, id desc` (terbaru dulu).
func (s *IamUserOverridesService) List(ctx context.Context, pr *errkontrak.PageRequest, userID int64, search *string) (errkontrak.Page[types.UserOverrideView], error) {
	data, total, err := s.repo.List(ctx, s.db.Pool, pr, userID, search)
	if err != nil {
		return errkontrak.Page[types.UserOverrideView]{}, err
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Create — tambah/upsert override; pemberi (granted_by) dari JWT. Invalidasi
// compiler SETELAH commit (persis presedensi sumber).
func (s *IamUserOverridesService) Create(ctx context.Context, in OverrideBuat, actor audit.Actor) (*types.UserOverrideView, error) {
	var expiresAt pgtype.Timestamptz
	if in.ExpiresAt != nil {
		t, err := time.Parse(time.RFC3339, *in.ExpiresAt)
		if err != nil {
			return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
				Field:   "expiresAt",
				Message: "Invalid datetime", // tidak terjadi — zod datetime di handler
			}})
		}
		expiresAt = pgtype.Timestamptz{Time: t, Valid: true}
	}

	var view *types.UserOverrideView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		targetUser, err := s.repo.FindUserById(ctx, tx, in.UserID)
		if err != nil {
			return err
		}
		if !targetUser {
			return errkontrak.NotFound(fmt.Sprintf("User id %d tidak ditemukan.", in.UserID), "SYS-404")
		}

		permission, err := s.repo.FindPermissionById(ctx, tx, in.PermissionID)
		if err != nil {
			return err
		}
		if permission == nil {
			return errkontrak.NotFound(fmt.Sprintf("SET permission id %d tidak ditemukan.", in.PermissionID), "SYS-404")
		}

		grantedBy := int64(0) // padankan ctx.actor.id ?? 0 (fallback mutationCtx)
		if actor.IDCoreUsers != nil {
			grantedBy = *actor.IDCoreUsers
		}
		now := pgtype.Timestamptz{Time: time.Now(), Valid: true}
		if err := s.repo.Upsert(ctx, tx, repository.OverrideUpsert{
			IDCoreUsers:          in.UserID,
			IDCorePermissions:    in.PermissionID,
			Granted:              in.Granted,
			IDCoreUsersGrantedBy: grantedBy,
			GrantedAt:            now,
			ExpiresAt:            expiresAt,
			UpdatedAt:            now,
		}); err != nil {
			return err
		}

		flat, err := s.repo.FindJoinRow(ctx, tx, in.UserID, in.PermissionID)
		if err != nil {
			return err
		}
		if flat == nil {
			return errkontrak.NotFound(fmt.Sprintf("Override user %d × permission %d tidak ditemukan setelah upsert.", in.UserID, in.PermissionID), "SYS-404")
		}
		v := repository.OverrideToView(*flat)

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "user_permission",
			EntityID:   fmt.Sprintf("%d/%s", in.UserID, permissionNameFallback(permission.Name, permission.ID)),
			Action:     "upsert",
			AfterValue: iamSnapshotOf(v),
			Severity:   audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}
		view = &v
		return nil
	})
	if err != nil {
		return nil, err
	}

	// SETELAH commit — set efektif user berubah seketika (invalidasi
	// memancar event socket `rbac.changed`).
	s.compiler.InvalidateUser(in.UserID)
	return view, nil
}

// Remove — hapus override by id baris (SOFT DELETE); 404 SYS-404 bila
// tidak ada. Invalidasi compiler DI DALAM tx closure — presedensi verbatim.
func (s *IamUserOverridesService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.FindLiveById(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Override permission id %d tidak ditemukan.", id), "SYS-404")
		}

		now := pgtype.Timestamptz{Time: time.Now(), Valid: true}
		if err := s.repo.SoftDeleteById(ctx, tx, id, now, now); err != nil {
			return err
		}

		var expires *string
		if row.ExpiresAt.Valid {
			v := row.ExpiresAt.Time.UTC().Format(iamISO)
			expires = &v
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{EntryInput: audit.EntryInput{
			ModuleKey:  "system",
			EntityType: "user_permission",
			EntityID:   fmt.Sprintf("%d/permission#%d", row.IDCoreUsers, row.IDCorePermissions),
			Action:     "delete",
			BeforeValue: audit.Snapshot{
				"granted":    row.Granted,
				"expires_at": expires,
			},
			Severity: audit.SeverityWarning,
		}, Actor: actor}}); err != nil {
			return err
		}

		// DI DALAM closure tx — presedensi verbatim NestJS.
		s.compiler.InvalidateUser(row.IDCoreUsers)
		return nil
	})
}

// permissionNameFallback — `${permission.name ?? `set#${permission.id}`}`.
func permissionNameFallback(name pgtype.Text, id int64) string {
	if name.Valid && name.String != "" {
		return name.String
	}
	return "set#" + fmt.Sprintf("%d", id)
}
