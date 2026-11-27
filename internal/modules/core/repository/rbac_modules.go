// Fitur MODULES REGISTRY modul core — SATU-SATUNYA pengguna pgx+sqlc untuk
// tabel core_modules + join nama penonaktif core_users (port VERBATIM
// repositories/rbac/modules-registry.repository.ts NestJS; mapper
// moduleToView dari rbac.views). Row→View di sini; guard 404/409 di service.
package repository

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// ModulesRepo — pembungkus query sqlc fitur modules registry.
type ModulesRepo struct{}

// NewModulesRepo membuat repo (tanpa state — executor per panggilan).
func NewModulesRepo() *ModulesRepo { return &ModulesRepo{} }

// moduleViewOf — mapper baris modul → ModuleRegistryView (moduleToView;
// disabledBy = nama user penonaktif dari LEFT JOIN).
func moduleViewOf(row gen.ListModulesRow) types.ModuleRegistryView {
	return types.ModuleRegistryView{
		ID:         row.ID,
		Key:        string(row.Key),
		Name:       row.Name,
		Tagline:    row.Tagline,
		Tone:       row.Tone,
		IsCore:     row.IsCore,
		Enabled:    row.Enabled,
		EnabledAt:  IsoRequired(row.EnabledAt),
		DisabledAt: Iso(row.DisabledAt),
		DisabledBy: PgTextPtr(row.DisablerName),
	}
}

// List — daftar modul berelasi, terurut rank moduleKeySchema.enumValues
// (key di luar enum → rank 99; sort stabil persis Array.prototype.sort).
func (r *ModulesRepo) List(ctx context.Context, exec gen.DBTX) ([]types.ModuleRegistryView, error) {
	rows, err := gen.New(exec).ListModules(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]types.ModuleRegistryView, len(rows))
	for i, row := range rows {
		out[i] = moduleViewOf(row)
	}
	sort.SliceStable(out, func(i, j int) bool {
		ri, oki := types.ModuleKeyRank[out[i].Key]
		if !oki {
			ri = 99
		}
		rj, okj := types.ModuleKeyRank[out[j].Key]
		if !okj {
			rj = 99
		}
		return ri < rj
	})
	return out, nil
}

// MuatByKey — modul by key unik (false = tidak ada; service 404 SYS-404).
func (r *ModulesRepo) MuatByKey(ctx context.Context, exec gen.DBTX, key string) (gen.MuatModuleByKeyRow, bool, error) {
	row, err := gen.New(exec).MuatModuleByKey(ctx, gen.CoreModuleKey(key))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return gen.MuatModuleByKeyRow{}, false, nil
		}
		return gen.MuatModuleByKeyRow{}, false, err
	}
	return row, true, nil
}

// UpdateStatus — enable/disable modul (set dibangun service: enabledAt
// diperbarui saat mengaktifkan, disabledAt NULL saat aktif / now saat
// menonaktifkan, id_core_users = penonaktif atau NULL; TANPA updated_at —
// persis drizzle).
func (r *ModulesRepo) UpdateStatus(ctx context.Context, exec gen.DBTX, id int64,
	enabled bool, enabledAt time.Time, disabledAt *time.Time, idCoreUsers *int64) error {
	var dis pgtype.Timestamptz
	if disabledAt != nil {
		dis = pgtype.Timestamptz{Time: *disabledAt, Valid: true}
	}
	var disabler pgtype.Int8
	if idCoreUsers != nil {
		disabler = pgtype.Int8{Int64: *idCoreUsers, Valid: true}
	}
	return gen.New(exec).UpdateModuleStatus(ctx, gen.UpdateModuleStatusParams{
		ID:          id,
		Enabled:     enabled,
		EnabledAt:   pgtype.Timestamptz{Time: enabledAt, Valid: true},
		DisabledAt:  dis,
		IDCoreUsers: disabler,
	})
}
