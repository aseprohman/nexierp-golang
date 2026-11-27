// Service Manajemen Modul (Sheet "Manajemen Modul") fitur RBAC modul core —
// port VERBATIM services/rbac/modules-registry.service.ts NestJS:
// modul nonaktif mengeluarkan permission-nya dari set efektif SEMUA user
// (compiler meng-join core_modules.enabled saat kompilasi), sehingga setiap
// perubahan status memicu Compiler.InvalidateAll() SETELAH transaksi commit.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// ModulesService — orkestrasi fitur modules registry.
type ModulesService struct {
	db       *database.DB
	audit    *audit.Service
	compiler *rbac.Compiler
	repo     *repository.ModulesRepo
}

// NewModulesService membangun service modules dari deps modul.
func NewModulesService(d types.Deps) *ModulesService {
	return &ModulesService{db: d.DB, audit: d.Audit, compiler: d.Compiler, repo: repository.NewModulesRepo()}
}

// List — daftar modul (VIEW berelasi, disabledBy di-JOIN dari core_users)
// terurut rank moduleKeySchema.enumValues.
func (s *ModulesService) List(ctx context.Context) ([]types.ModuleRegistryView, error) {
	views, err := s.repo.List(ctx, s.db.Pool)
	if err != nil {
		return nil, err
	}
	if views == nil {
		views = []types.ModuleRegistryView{}
	}
	return views, nil
}

// SetEnabled — aktifkan/nonaktifkan modul (port setModuleEnabled):
//   - modul inti (`is_core`) TIDAK BOLEH dinonaktifkan → 409 SYS-409;
//   - status sudah sama → no-op tanpa audit (idempoten, changed=false);
//   - aktor penonaktif dicatat di id_core_users (NULL saat mengaktifkan);
//   - audit severity warning (action enable/disable);
//   - Compiler.InvalidateAll() SETELAH commit.
func (s *ModulesService) SetEnabled(ctx context.Context, key string, enabled bool, actor audit.Actor) (types.ModuleEnabledResult, error) {
	changed := false
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		mod, ada, err := s.repo.MuatByKey(ctx, tx, key)
		if err != nil {
			return err
		}
		if !ada {
			return errkontrak.NotFound(fmt.Sprintf("Modul '%s' tidak ditemukan.", key), "SYS-404")
		}
		if mod.IsCore && !enabled {
			return errkontrak.Conflict(
				"Modul System & Authorization adalah infrastruktur inti dan tidak dapat dinonaktifkan.",
				"SYS-409",
			)
		}
		if mod.Enabled == enabled {
			return nil // idempoten — port mock (return tanpa audit)
		}

		now := time.Now()
		enabledAt := mod.EnabledAt // menonaktifkan: enabled_at tetap
		if enabled {
			enabledAt = pgtype.Timestamptz{Time: now, Valid: true}
		}
		var disabledAt *time.Time
		if !enabled {
			disabledAt = &now
		}
		var disabler *int64
		if !enabled && actor.IDCoreUsers != nil {
			disabler = actor.IDCoreUsers
		}
		if err := s.repo.UpdateStatus(ctx, tx, mod.ID, enabled, enabledAt.Time, disabledAt, disabler); err != nil {
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "module_registry",
				EntityID:    key,
				Action:      actionEnabled(enabled),
				BeforeValue: audit.Snapshot{"enabled": !enabled},
				AfterValue:  audit.Snapshot{"enabled": enabled},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		changed = true
		return nil
	})
	if err != nil {
		return types.ModuleEnabledResult{}, err
	}

	// Set efektif user berubah → buang seluruh cache compiler (model v2).
	if changed {
		s.compiler.InvalidateAll()
	}
	return types.ModuleEnabledResult{Changed: changed, Key: key, Enabled: enabled}, nil
}

// actionEnabled — string action audit enable/disable.
func actionEnabled(enabled bool) string {
	if enabled {
		return "enable"
	}
	return "disable"
}
