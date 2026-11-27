// security_sessions.go — SATU-SATUNYA pengguna sqlc fitur SESI & LOG LOGIN
// modul core (padanan repositories/security/sessions.repository.ts; tabel
// core_sessions + core_login_audit). Mapper baris→View di sini; pemanggil
// (service) meneruskan executor pool | tx.
package repository

import (
	"context"
	"time"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// SessionsRepository — wrapper sqlc area sesi & log login.
type SessionsRepository struct{}

// NewSessionsRepository membuat repository (tanpa state — executor per call).
func NewSessionsRepository() *SessionsRepository { return &SessionsRepository{} }

// PageSessions — SATU HALAMAN sesi: search lintas user/IP/agent/device;
// whitelist sort login_at,user_name,expires_at,id; default login_at DESC +
// tie-break id DESC (di SQL). Baca non-transaksi.
func (r *SessionsRepository) PageSessions(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.SessionRow], error) {
	if err := shared.SortUnknown(pr, whitelistSessions); err != nil {
		return errkontrak.Page[types.SessionRow]{}, err
	}
	needle := textOrNil(search)
	rows, err := gen.New(exec).PageSessions(ctx, gen.PageSessionsParams{
		Search: needle,
		Sort:   sortToken(pr),
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	})
	if err != nil {
		return errkontrak.Page[types.SessionRow]{}, err
	}
	total, err := gen.New(exec).CountSessions(ctx, needle)
	if err != nil {
		return errkontrak.Page[types.SessionRow]{}, err
	}
	views := make([]types.SessionRow, len(rows))
	for i, row := range rows {
		views[i] = types.SessionRow{
			ID:        row.ID,
			UserID:    int8Ptr(row.IDCoreUsers),
			UserName:  row.UserName,
			DeviceKey: textPtr(row.DeviceKey),
			LoginAt:   isoTZ(row.LoginAt),
			ExpiresAt: isoTZ(row.ExpiresAt),
			LogoutAt:  isoTZPtr(row.LogoutAt),
			RevokedAt: isoTZPtr(row.RevokedAt),
			IPAddress: row.IpAddress,
			UserAgent: textVal(row.UserAgent),
			Device:    row.Device,
			IsValid:   row.IsValid,
		}
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// PageLoginAudit — SATU HALAMAN log login: filter username (ILIKE) +
// success (eksak); search lintas username/IP/user agent; default
// attempted_at DESC + tie-break id DESC. Baca non-transaksi.
func (r *SessionsRepository) PageLoginAudit(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, username string, success *bool, search string) (errkontrak.Page[types.LoginAuditEntry], error) {
	if err := shared.SortUnknown(pr, whitelistLoginAudit); err != nil {
		return errkontrak.Page[types.LoginAuditEntry]{}, err
	}
	needle := textOrNil(search)
	params := gen.PageLoginAuditParams{
		Username: textOrNil(username),
		Search:   needle,
		Sort:     sortToken(pr),
		Limit:    int32(pr.Limit),
		Offset:   int32(pr.Offset),
	}
	if success != nil {
		params.Success = pgtypeBool(*success)
	}
	rows, err := gen.New(exec).PageLoginAudit(ctx, params)
	if err != nil {
		return errkontrak.Page[types.LoginAuditEntry]{}, err
	}
	total, err := gen.New(exec).CountLoginAudit(ctx, gen.CountLoginAuditParams{
		Username: params.Username,
		Success:  params.Success,
		Search:   needle,
	})
	if err != nil {
		return errkontrak.Page[types.LoginAuditEntry]{}, err
	}
	views := make([]types.LoginAuditEntry, len(rows))
	for i, row := range rows {
		views[i] = types.LoginAuditEntry{
			ID:            row.ID,
			UserID:        int8Ptr(row.IDCoreUsers),
			UsernameTried: row.UsernameTried,
			Success:       row.Success,
			FailReason:    enumPtr(string(row.FailReason.CoreLoginFailReason), row.FailReason.Valid),
			IPAddress:     row.IpAddress,
			UserAgent:     row.UserAgent,
			AttemptedAt:   isoTZ(row.AttemptedAt),
		}
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// MuatSession — satu sesi (id + isValid); nil bila absen (404 di service).
func (r *SessionsRepository) MuatSession(ctx context.Context, exec DBTX, sessionID int64) (*gen.MuatSessionRow, error) {
	row, err := gen.New(exec).MuatSession(ctx, sessionID)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &row, nil
}

// RevokeSession — is_valid=false + revoked_at (now dibangun service);
// audit tetap di service dalam transaksi yang sama.
func (r *SessionsRepository) RevokeSession(ctx context.Context, exec DBTX, sessionID int64, revokedAt time.Time) error {
	return gen.New(exec).RevokeSession(ctx, gen.RevokeSessionParams{
		ID:        sessionID,
		RevokedAt: pgtypeTz(revokedAt),
	})
}
