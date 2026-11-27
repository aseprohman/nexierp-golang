// security_settings.go — service KEAMANAN AKUN (padanan
// services/security/security-settings.service.ts): port fetchMfa,
// setMfaEnabled, fetchPasswordHistory, fetchIpAllowlist, addIpAllowlistRule,
// removeIpAllowlistRule. Nilai INSERT/UPDATE (kolom bisnis) dibangun di
// sini; semua tulis + audit dalam SATU transaksi.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// SettingsService — kernel fitur keamanan akun (MFA, riwayat password,
// IP allowlist).
type SettingsService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.SecuritySettingsRepository
}

// NewSettingsService membuat service keamanan akun.
func NewSettingsService(db *database.DB, auditSvc *audit.Service) *SettingsService {
	return &SettingsService{db: db, audit: auditSvc, repo: repository.NewSecuritySettingsRepository()}
}

// ---------------------------------------------------------------------
// MFA
// ---------------------------------------------------------------------

// PageMfaStatus — SATU HALAMAN status MFA per PENGGUNA (paging server):
// LEFT JOIN core_users x core_user_mfa sehingga pengguna tanpa baris MFA
// tetap tampil (mfa: null); sort di-whitelist, default users.id ASC.
func (s *SettingsService) PageMfaStatus(ctx context.Context, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.UserMfaStatus], error) {
	return s.repo.PageMfaStatus(ctx, s.db.Pool, pr, search)
}

// SetMfaEnabled — user tidak ada → 404 SYS-404. Baris MFA belum ada →
// insert (confirmed_at = now bila enable, recovery_codes_left = 10; method
// totp); sudah ada → update flag (confirmed_at dipertahankan bila pernah
// dikonfirmasi). Flag core_users.mfa_enabled ikut diset. Semua + audit
// warning dalam satu tx.
func (s *SettingsService) SetMfaEnabled(ctx context.Context, userID int64, enabled bool, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		user, err := s.repo.MuatUserRingkas(ctx, tx, userID)
		if err != nil {
			return err
		}
		if user == nil {
			return errkontrak.NotFound(fmt.Sprintf("User %d tidak ditemukan.", userID), "SYS-404")
		}

		now := time.Now()
		row, err := s.repo.MuatMfaUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		if row == nil {
			var confirmed *time.Time
			recovery := 0
			if enabled {
				confirmed = &now
				recovery = 10
			}
			if err := s.repo.InsertMfa(ctx, tx, userID, user.Name, confirmed, enabled, recovery); err != nil {
				return err
			}
		} else {
			// enabled ? (row.confirmedAt ?? now) : row.confirmedAt
			var confirmed *time.Time
			if enabled {
				if row.ConfirmedAt.Valid {
					t := row.ConfirmedAt.Time
					confirmed = &t
				} else {
					confirmed = &now
				}
			} else if row.ConfirmedAt.Valid {
				t := row.ConfirmedAt.Time
				confirmed = &t
			}
			if err := s.repo.UpdateMfa(ctx, tx, userID, enabled, confirmed); err != nil {
				return err
			}
		}
		if err := s.repo.UpdateUserMfaEnabled(ctx, tx, userID, enabled); err != nil {
			return err
		}

		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "user_mfa",
				EntityID:    fmt.Sprintf("%d", userID),
				Action:      "update",
				BeforeValue: audit.Snapshot{"enabled": !enabled},
				AfterValue:  audit.Snapshot{"enabled": enabled},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// ---------------------------------------------------------------------
// Riwayat password
// ---------------------------------------------------------------------

// PagePasswordHistory — SATU HALAMAN (paging server): search di kolom
// user_name; default -set_at + tie-break id deterministik.
func (s *SettingsService) PagePasswordHistory(ctx context.Context, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.PasswordHistoryEntry], error) {
	return s.repo.PagePasswordHistory(ctx, s.db.Pool, pr, search)
}

// ---------------------------------------------------------------------
// IP allowlist
// ---------------------------------------------------------------------

// PageIpAllowlist — SATU HALAMAN aturan (paging server) dengan JOIN
// core_roles untuk roleCode view; search lintas target/cidr/note; default
// id ASC.
func (s *SettingsService) PageIpAllowlist(ctx context.Context, pr *errkontrak.PageRequest, search string) (errkontrak.Page[types.IpAllowlistRule], error) {
	return s.repo.PageIpAllowlist(ctx, s.db.Pool, pr, search)
}

// AddIpAllowlistRule — label target: `User: <nama>` / `Role: <label>` (FK
// tetap id numerik). Target wajib role ATAU user (refine zod = CHECK DDL);
// role/user tak dikenal → 404 SYS-404. Nilai insert + audit warning dalam
// tx yang sama.
func (s *SettingsService) AddIpAllowlistRule(ctx context.Context, input types.CreateIpAllowlistRuleInput, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		var roleID *int64
		var target string

		switch {
		case input.UserID != nil:
			name, err := s.repo.MuatNamaUser(ctx, tx, *input.UserID)
			if err != nil {
				return err
			}
			if name == nil {
				return errkontrak.NotFound(fmt.Sprintf("User %d tidak ditemukan.", *input.UserID), "SYS-404")
			}
			target = "User: " + *name
		case input.RoleCode != nil:
			role, err := s.repo.MuatRoleByCode(ctx, tx, *input.RoleCode)
			if err != nil {
				return err
			}
			if role == nil {
				return errkontrak.NotFound(fmt.Sprintf("Role '%s' tidak ditemukan.", *input.RoleCode), "SYS-404")
			}
			roleID = &role.ID
			target = "Role: " + role.Role
		default:
			// Dijaga refine zod — defensif terhadap CHECK DDL.
			return errkontrak.BadRequest("Aturan allowlist wajib menyasar role atau user.", "SYS-400")
		}

		if err := s.repo.InsertIpAllowlist(ctx, tx, roleID, input.UserID, target, input.Cidr, input.Note); err != nil {
			return err
		}
		_, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "ip_allowlist",
				EntityID:   input.Cidr,
				Action:     "create",
				AfterValue: audit.Snapshot{"target": target, "cidr": input.Cidr},
				Severity:   audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// RemoveIpAllowlistRule — baris tidak ada → 404 SYS-404 (REST DELETE
// eksplisit lebih aman untuk audit). Hapus fisik + audit warning dalam
// SATU tx.
func (s *SettingsService) RemoveIpAllowlistRule(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.MuatIpAllowlist(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Aturan allowlist %d tidak ditemukan.", id), "SYS-404")
		}
		if err := s.repo.DeleteIpAllowlist(ctx, tx, id); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "ip_allowlist",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"target": row.Target, "cidr": row.Cidr},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}
