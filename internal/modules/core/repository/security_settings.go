// security_settings.go — SATU-SATUNYA pengguna sqlc fitur KEAMANAN AKUN
// modul core (padanan repositories/security/security-settings.repository.ts;
// tabel core_users + core_user_mfa + core_password_history +
// core_ip_allowlist + core_roles). Nilai INSERT/UPDATE dibangun service.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// SecuritySettingsRepository — wrapper sqlc area MFA, riwayat password,
// dan IP allowlist.
type SecuritySettingsRepository struct{}

// NewSecuritySettingsRepository membuat repository (tanpa state).
func NewSecuritySettingsRepository() *SecuritySettingsRepository {
	return &SecuritySettingsRepository{}
}

// ---------------------------------------------------------------------
// MFA
// ---------------------------------------------------------------------

// PageMfaStatus — SATU HALAMAN status MFA per PENGGUNA: LEFT JOIN
// core_users x core_user_mfa (pengguna tanpa baris MFA tetap tampil,
// mfa: null); search lintas nama/username; default users.id ASC.
func (r *SecuritySettingsRepository) PageMfaStatus(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.UserMfaStatus], error) {
	if err := shared.SortUnknown(pr, whitelistMfa); err != nil {
		return errkontrak.Page[types.UserMfaStatus]{}, err
	}
	needle := textOrNil(search)
	rows, err := gen.New(exec).PageMfa(ctx, gen.PageMfaParams{
		Search: needle,
		Sort:   sortToken(pr),
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	})
	if err != nil {
		return errkontrak.Page[types.UserMfaStatus]{}, err
	}
	total, err := gen.New(exec).CountMfa(ctx, needle)
	if err != nil {
		return errkontrak.Page[types.UserMfaStatus]{}, err
	}
	views := make([]types.UserMfaStatus, len(rows))
	for i, row := range rows {
		v := types.UserMfaStatus{
			UserID:   row.ID,
			UserName: row.Name,
			Username: row.Username,
		}
		if row.MfaUserID.Valid {
			v.Mfa = &types.UserMfa{
				UserID:            row.MfaUserID.Int64,
				UserName:          row.MfaUserName.String,
				Method:            string(row.Method.CoreMfaMethod),
				ConfirmedAt:       isoTZPtr(row.ConfirmedAt),
				Enabled:           row.Enabled.Bool,
				LastUsedAt:        isoTZPtr(row.LastUsedAt),
				RecoveryCodesLeft: int(row.RecoveryCodesLeft.Int32),
			}
		}
		views[i] = v
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// MuatUserRingkas — user ringkas (id + nama + flag mfa_enabled); nil bila
// absen (404 diputuskan service).
func (r *SecuritySettingsRepository) MuatUserRingkas(ctx context.Context, exec DBTX, userID int64) (*gen.MuatUserRingkasRow, error) {
	row, err := gen.New(exec).MuatUserRingkas(ctx, userID)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &row, nil
}

// MuatMfaUser — baris MFA satu pengguna (PK = FK); nil bila belum mendaftar.
func (r *SecuritySettingsRepository) MuatMfaUser(ctx context.Context, exec DBTX, userID int64) (*gen.MuatMfaUserRow, error) {
	row, err := gen.New(exec).MuatMfaUser(ctx, userID)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &row, nil
}

// InsertMfa — insert baris MFA baru (nilai dibangun service: method totp,
// confirmed_at now bila enable, recovery_codes_left 10/0).
func (r *SecuritySettingsRepository) InsertMfa(ctx context.Context, exec DBTX, userID int64, userName string, confirmedAt *time.Time, enabled bool, recoveryCodesLeft int) error {
	return gen.New(exec).InsertMfa(ctx, gen.InsertMfaParams{
		IDCoreUsers:       userID,
		UserName:          userName,
		ConfirmedAt:       tzPtr(confirmedAt),
		Enabled:           enabled,
		RecoveryCodesLeft: int32(recoveryCodesLeft),
	})
}

// UpdateMfa — update flag MFA + confirmed_at (dipertahankan bila pernah
// dikonfirmasi — dihitung service).
func (r *SecuritySettingsRepository) UpdateMfa(ctx context.Context, exec DBTX, userID int64, enabled bool, confirmedAt *time.Time) error {
	return gen.New(exec).UpdateMfa(ctx, gen.UpdateMfaParams{
		IDCoreUsers: userID,
		Enabled:     enabled,
		ConfirmedAt: tzPtr(confirmedAt),
	})
}

// UpdateUserMfaEnabled — sinkron flag core_users.mfa_enabled.
func (r *SecuritySettingsRepository) UpdateUserMfaEnabled(ctx context.Context, exec DBTX, userID int64, enabled bool) error {
	return gen.New(exec).UpdateUserMfaEnabled(ctx, gen.UpdateUserMfaEnabledParams{
		ID:         userID,
		MfaEnabled: enabled,
	})
}

// ---------------------------------------------------------------------
// Riwayat password
// ---------------------------------------------------------------------

// PagePasswordHistory — SATU HALAMAN riwayat password: search di
// user_name; default set_at DESC + tie-break id DESC.
func (r *SecuritySettingsRepository) PagePasswordHistory(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.PasswordHistoryEntry], error) {
	if err := shared.SortUnknown(pr, whitelistPasswordHis); err != nil {
		return errkontrak.Page[types.PasswordHistoryEntry]{}, err
	}
	needle := textOrNil(search)
	rows, err := gen.New(exec).PagePasswordHistory(ctx, gen.PagePasswordHistoryParams{
		Search: needle,
		Sort:   sortToken(pr),
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	})
	if err != nil {
		return errkontrak.Page[types.PasswordHistoryEntry]{}, err
	}
	total, err := gen.New(exec).CountPasswordHistory(ctx, needle)
	if err != nil {
		return errkontrak.Page[types.PasswordHistoryEntry]{}, err
	}
	views := make([]types.PasswordHistoryEntry, len(rows))
	for i, row := range rows {
		views[i] = types.PasswordHistoryEntry{
			ID:         row.ID,
			UserID:     row.IDCoreUsers,
			UserName:   row.UserName,
			SetAt:      isoTZ(row.SetAt),
			MaskedHash: row.MaskedHash,
		}
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// ---------------------------------------------------------------------
// IP allowlist
// ---------------------------------------------------------------------

// PageIpAllowlist — SATU HALAMAN aturan dengan JOIN core_roles untuk
// roleCode view; search lintas target/cidr/note; default id ASC.
func (r *SecuritySettingsRepository) PageIpAllowlist(ctx context.Context, exec DBTX, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.IpAllowlistRule], error) {
	if err := shared.SortUnknown(pr, whitelistIpAllowlist); err != nil {
		return errkontrak.Page[types.IpAllowlistRule]{}, err
	}
	needle := textOrNil(search)
	rows, err := gen.New(exec).PageIpAllowlist(ctx, gen.PageIpAllowlistParams{
		Search: needle,
		Sort:   sortToken(pr),
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	})
	if err != nil {
		return errkontrak.Page[types.IpAllowlistRule]{}, err
	}
	total, err := gen.New(exec).CountIpAllowlist(ctx, needle)
	if err != nil {
		return errkontrak.Page[types.IpAllowlistRule]{}, err
	}
	views := make([]types.IpAllowlistRule, len(rows))
	for i, row := range rows {
		views[i] = types.IpAllowlistRule{
			ID:        row.ID,
			RoleCode:  textPtr(row.RoleCode),
			UserID:    int8Ptr(row.IDCoreUsers),
			Target:    row.Target,
			Cidr:      row.Cidr,
			Note:      textPtr(row.Note),
			CreatedAt: isoTZ(row.CreatedAt),
		}
	}
	return errkontrak.BuildPage(views, int(total), pr), nil
}

// MuatNamaUser — nama user untuk label target `User: <nama>`; nil bila
// absen (404 diputuskan service).
func (r *SecuritySettingsRepository) MuatNamaUser(ctx context.Context, exec DBTX, userID int64) (*string, error) {
	name, err := gen.New(exec).MuatNamaUser(ctx, userID)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &name, nil
}

// MuatRoleByCode — role by code untuk label target `Role: <label>`; nil
// bila absen.
func (r *SecuritySettingsRepository) MuatRoleByCode(ctx context.Context, exec DBTX, roleCode string) (*gen.MuatRoleByCodeRow, error) {
	row, err := gen.New(exec).MuatRoleByCode(ctx, roleCode)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &row, nil
}

// InsertIpAllowlist — insert aturan allowlist (FK tetap id numerik; nilai
// label target dibangun service).
func (r *SecuritySettingsRepository) InsertIpAllowlist(ctx context.Context, exec DBTX, roleID, userID *int64, target, cidr string, note *string) error {
	return gen.New(exec).InsertIpAllowlist(ctx, gen.InsertIpAllowlistParams{
		IDCoreRoles: int8Narg(roleID),
		IDCoreUsers: int8Narg(userID),
		Target:      target,
		Cidr:        cidr,
		Note:        textOrNilPtr(note),
	})
}

// MuatIpAllowlist — aturan allowlist (target + cidr untuk audit before);
// nil bila absen.
func (r *SecuritySettingsRepository) MuatIpAllowlist(ctx context.Context, exec DBTX, id int64) (*gen.MuatIpAllowlistRow, error) {
	row, err := gen.New(exec).MuatIpAllowlist(ctx, id)
	if err != nil {
		if isNoRows(err) {
			return nil, nil
		}
		return nil, err
	}
	return &row, nil
}

// DeleteIpAllowlist — hapus aturan allowlist by id (DELETE fisik).
func (r *SecuritySettingsRepository) DeleteIpAllowlist(ctx context.Context, exec DBTX, id int64) error {
	return gen.New(exec).DeleteIpAllowlist(ctx, id)
}

// ---------------------------------------------------------------------
// Helper pgtype nullable
// ---------------------------------------------------------------------

// tzPtr — *time.Time → pgtype.Timestamptz (nil → NULL).
func tzPtr(t *time.Time) pgtype.Timestamptz {
	if t == nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: *t, Valid: true}
}

// int8Narg — *int64 → pgtype.Int8 (nil → NULL).
func int8Narg(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// textOrNilPtr — *string → pgtype.Text (nil → NULL).
func textOrNilPtr(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}
