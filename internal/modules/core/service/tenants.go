// Service TENANTS — orkestrasi fitur tenant modul core (padanan
// SystemTenantsService NestJS, VERBATIM urutan langkah, pesan & kode error):
// validasi domain → SATU pgx tx (repo + core_tenant_events + audit.append
// dalam tx yang sama) → mapping. Patch umum TIDAK menulis event tenant.
// PROVISIONING: tenant baru lahir PROVISI + snapshot SEMUA modul global dan
// semua fitur global aktif ke junction (ON CONFLICT DO NOTHING).
package service

import (
	"context"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/domain"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// TenantsService — dependensi kernel + repo tenants.
type TenantsService struct {
	DB    *database.DB
	Audit *audit.Service
	Repo  *repository.TenantsRepository
}

// NewTenantsService — wiring dari Deps modul (dipanggil handler/module.go).
func NewTenantsService(d types.Deps) *TenantsService {
	return &TenantsService{DB: d.DB, Audit: d.Audit, Repo: repository.NewTenants()}
}

/* -------------------------------------------------------------- */
/* CRUD tenant                                                     */
/* -------------------------------------------------------------- */

// List — daftar tenant paging (?page&limit&search&status&tier) — envelope
// `{ rows, total }` (BUKAN Page); soft-delete aware, urut id.
func (s *TenantsService) List(ctx context.Context, q types.TenantListQuery) (types.TenantList, error) {
	return s.Repo.ListTenants(ctx, s.DB.Pool, q)
}

// Create — PROVISIO tenant baru: SATU tx berisi dup-kode → insert PROVISI →
// preset modul/fitur global → event PROVISI → audit create. Race 23505
// (keputusan ratifikasi modul core) → 409 pesan verbatim yang sama.
func (s *TenantsService) Create(ctx context.Context, in types.TenantCreateInput, actor audit.Actor) (types.TenantView, error) {
	var view types.TenantView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		dup, err := s.Repo.FindTenantKodeHidup(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dup != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Kode tenant '%s' sudah dipakai tenant lain.", in.Kode),
				"SYS-409",
			)
		}

		inserted, err := s.Repo.InsertTenant(ctx, tx, repository.TenantBaru{
			Kode:          in.Kode,
			Nama:          in.Nama,
			PaketTier:     in.PaketTier,
			Status:        types.TenantProvisi,
			MaxUsers:      in.MaxUsers,
			MaxLokasi:     in.MaxLokasi,
			KontakEmail:   in.KontakEmail,
			KontakTelepon: in.KontakTelepon,
		})
		if err != nil {
			// Race unik kode (uq_core_tenants_kode) → 409 pesan sama (verbatim).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode tenant '%s' sudah dipakai tenant lain.", in.Kode),
					"SYS-409",
				)
			}
			return err
		}

		// PROVISIONING — preset awal tenant: snapshot SEMUA modul global
		// (tanpa filter) dan semua fitur global enabled (aktif + modulnya
		// enabled). Preset PS1/PS2/PS3 otomatis menyusul (penyetelan per
		// tier belum ada — saat ini seluruh katalog global di-copy).
		modules, err := s.Repo.ListSemuaModulId(ctx, tx)
		if err != nil {
			return err
		}
		if len(modules) > 0 {
			if err := s.Repo.InsertTenantModules(ctx, tx, inserted.ID, modules); err != nil {
				return err
			}
		}
		features, err := s.Repo.ListFiturGlobalAktifId(ctx, tx)
		if err != nil {
			return err
		}
		if len(features) > 0 {
			if err := s.Repo.InsertTenantFeatures(ctx, tx, inserted.ID, features); err != nil {
				return err
			}
		}

		if err := s.appendEvent(ctx, tx, inserted.ID, "PROVISI", map[string]any{
			"kode":        inserted.Kode,
			"nama":        inserted.Nama,
			"paketTier":   inserted.PaketTier,
			"presetModul": len(modules),
			"presetFitur": len(features),
		}, actor); err != nil {
			return err
		}

		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_tenant",
				EntityID:   fmt.Sprintf("%d", inserted.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"kode":         inserted.Kode,
					"nama":         inserted.Nama,
					"paket_tier":   inserted.PaketTier,
					"status":       inserted.Status,
					"preset_modul": len(modules),
					"preset_fitur": len(features),
				},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		view = repository.TenantToView(inserted)
		return nil
	})
	if err != nil {
		return types.TenantView{}, err
	}
	return view, nil
}

// Get — detail satu tenant — 404 SYS-404 bila tidak ada / sudah terhapus.
func (s *TenantsService) Get(ctx context.Context, id int64) (types.TenantView, error) {
	row, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id)
	if err != nil {
		return types.TenantView{}, err
	}
	return repository.TenantToView(row), nil
}

// Update — PATCH umum (nama/kode/kuota/kontak) — If-Match `version` (412
// SYS-412 bila stale); version naik 1 tiap edit. Patch umum TIDAK menulis
// event tenant — jejak cukup lewat audit trail (before/after, warning).
func (s *TenantsService) Update(ctx context.Context, id int64, in types.TenantUpdateInput, actor audit.Actor, expectedVersion *int64) (types.TenantView, error) {
	var view types.TenantView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertTenant(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := ensureVersion(row.Version, expectedVersion); err != nil {
			return err
		}

		// Merge parsial — field tak dikirim → nilai lama (persis NestJS).
		nextKode := row.Kode
		if in.Kode != nil {
			nextKode = *in.Kode
		}
		if nextKode != row.Kode {
			dup, err := s.Repo.FindTenantKodeHidup(ctx, tx, nextKode)
			if err != nil {
				return err
			}
			if dup != nil && *dup != id {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode tenant '%s' sudah dipakai tenant lain.", nextKode),
					"SYS-409",
				)
			}
		}

		nama := row.Nama
		if in.Nama != nil {
			nama = *in.Nama
		}
		paketTier := row.PaketTier
		if in.PaketTier != "" {
			paketTier = in.PaketTier
		}
		maxUsers := row.MaxUsers
		if in.MaxUsersAda {
			maxUsers = in.MaxUsers
		}
		maxLokasi := row.MaxLokasi
		if in.MaxLokasiAda {
			maxLokasi = in.MaxLokasi
		}
		kontakEmail := row.KontakEmail
		if in.KontakEmailAda {
			kontakEmail = in.KontakEmail
		}
		kontakTelepon := row.KontakTelepon
		if in.KontakTeleponAda {
			kontakTelepon = in.KontakTelepon
		}

		updated, err := s.Repo.UpdateTenantLengkap(ctx, tx, repository.TenantUbahLengkap{
			Kode:          nextKode,
			Nama:          nama,
			PaketTier:     paketTier,
			MaxUsers:      maxUsers,
			MaxLokasi:     maxLokasi,
			KontakEmail:   kontakEmail,
			KontakTelepon: kontakTelepon,
			Version:       row.Version + 1,
			ID:            id,
		})
		if err != nil {
			// Race unik kode saat ganti kode → 409 pesan sama (verbatim).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Kode tenant '%s' sudah dipakai tenant lain.", nextKode),
					"SYS-409",
				)
			}
			return err
		}

		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_tenant",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: audit.Snapshot(domain.SnapshotTenant(snapshotOf(row))),
				AfterValue:  audit.Snapshot(domain.SnapshotTenant(snapshotOf(updated))),
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.TenantToView(updated)
		return nil
	})
	if err != nil {
		return types.TenantView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Siklus hidup (suspend / reactivate / close)                     */
/* -------------------------------------------------------------- */

// SetAksi — aksi siklus hidup: transisi sah (sisanya 409 pesan verbatim);
// event SUSPEND/REAKTIVASI/TUTUP membawa payload alasan; audit severity
// warning (info bila reactivate).
func (s *TenantsService) SetAksi(ctx context.Context, id int64, aksi string, in types.TenantAksiInput, actor audit.Actor) (types.TenantView, error) {
	var view types.TenantView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertTenant(ctx, tx, id)
		if err != nil {
			return err
		}
		transisi, sah := domain.TransisiStatus(aksi, row.Status)
		if !sah {
			return errkontrak.Conflict(domain.PesanTransisi(aksi, row.Status), "SYS-409")
		}

		updated, err := s.Repo.UpdateTenantStatus(ctx, tx, id, transisi, row.Version+1)
		if err != nil {
			return err
		}

		var alasan any
		if in.Alasan != nil {
			alasan = *in.Alasan
		}
		if err := s.appendEvent(ctx, tx, id, domain.AksiEvent(aksi), map[string]any{
			"dari":   row.Status,
			"ke":     updated.Status,
			"alasan": alasan,
		}, actor); err != nil {
			return err
		}

		severity := audit.SeverityWarning // penangguhan/penutupan berdampak luas
		if aksi == domain.AksiReactivate {
			severity = audit.SeverityInfo
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_tenant",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     aksi,
				BeforeValue: audit.Snapshot{
					"status":  row.Status,
					"version": row.Version,
				},
				AfterValue: audit.Snapshot{
					"status":  updated.Status,
					"version": updated.Version,
					"alasan":  alasan,
				},
				Severity: severity,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.TenantToView(updated)
		return nil
	})
	if err != nil {
		return types.TenantView{}, err
	}
	return view, nil
}

// SetTier — ubah tier paket — If-Match `version`; event SET_TIER (dari → ke);
// audit warning.
func (s *TenantsService) SetTier(ctx context.Context, id int64, paketTier string, actor audit.Actor, expectedVersion *int64) (types.TenantView, error) {
	var view types.TenantView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertTenant(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := ensureVersion(row.Version, expectedVersion); err != nil {
			return err
		}

		updated, err := s.Repo.UpdateTenantTier(ctx, tx, id, paketTier, row.Version+1)
		if err != nil {
			return err
		}

		if err := s.appendEvent(ctx, tx, id, "SET_TIER", map[string]any{
			"dari": row.PaketTier,
			"ke":   updated.PaketTier,
		}, actor); err != nil {
			return err
		}

		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_tenant",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "set_tier",
				BeforeValue: audit.Snapshot{
					"paket_tier": row.PaketTier,
					"version":    row.Version,
				},
				AfterValue: audit.Snapshot{
					"paket_tier": updated.PaketTier,
					"version":    updated.Version,
				},
				Severity: audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.TenantToView(updated)
		return nil
	})
	if err != nil {
		return types.TenantView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Modul & fitur tenant                                            */
/* -------------------------------------------------------------- */

// ListModules — katalog modul registry + status aktif tenant (aktif = ada
// baris junction) — seluruh katalog global agar FE menampilkan checkbox penuh.
func (s *TenantsService) ListModules(ctx context.Context, id int64) ([]types.TenantModuleRow, error) {
	if _, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id); err != nil {
		return nil, err
	}
	return s.Repo.ListRowsModulTenant(ctx, s.DB.Pool, id)
}

// SetModules — REPLACE set modul aktif tenant: hapus junction + sisip payload
// (id tak dikenal → 404); version +1; event SET_MODUL (dari → ke urut asc);
// audit core_tenant_modul replace warning.
func (s *TenantsService) SetModules(ctx context.Context, id int64, in types.TenantModuleSetInput, actor audit.Actor) ([]types.TenantModuleRow, error) {
	targetIDs := dedupeInt64(in.IDModules)
	var rows []types.TenantModuleRow
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}

		before, err := s.Repo.ListIdModulAktif(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(targetIDs) > 0 {
			found, err := s.Repo.ListModulId(ctx, tx, targetIDs)
			if err != nil {
				return err
			}
			if missing := missingIDs(targetIDs, found); len(missing) > 0 {
				return errkontrak.NotFound(
					fmt.Sprintf("Modul tidak ditemukan: %s.", joinInt64(missing)), "SYS-404")
			}
		}

		if err := s.Repo.DeleteTenantModulesByTenant(ctx, tx, id); err != nil {
			return err
		}
		if len(targetIDs) > 0 {
			if err := s.Repo.InsertTenantModules(ctx, tx, id, targetIDs); err != nil {
				return err
			}
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		after, err := s.Repo.ListIdModulAktif(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := s.appendEvent(ctx, tx, id, "SET_MODUL", map[string]any{
			"dari": before,
			"ke":   after,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_tenant_modul",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "replace",
				BeforeValue: audit.Snapshot{"id_modules": toAnySlice(before)},
				AfterValue:  audit.Snapshot{"id_modules": toAnySlice(after)},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		rows, err = s.Repo.ListRowsModulTenant(ctx, tx, id)
		return err
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// ListFeatures — katalog fitur registry + status aktif tenant.
func (s *TenantsService) ListFeatures(ctx context.Context, id int64) ([]types.TenantFeatureRow, error) {
	if _, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id); err != nil {
		return nil, err
	}
	return s.Repo.ListRowsFiturTenant(ctx, s.DB.Pool, id)
}

// SetFeatures — REPLACE set fitur aktif tenant (semantik SetModules;
// 404 bila ada id fitur tak dikenal); version +1; event SET_FITUR.
func (s *TenantsService) SetFeatures(ctx context.Context, id int64, in types.TenantFeatureSetInput, actor audit.Actor) ([]types.TenantFeatureRow, error) {
	targetIDs := dedupeInt64(in.IDFeatures)
	var rows []types.TenantFeatureRow
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}

		before, err := s.Repo.ListIdFiturAktif(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(targetIDs) > 0 {
			found, err := s.Repo.ListFiturId(ctx, tx, targetIDs)
			if err != nil {
				return err
			}
			if missing := missingIDs(targetIDs, found); len(missing) > 0 {
				return errkontrak.NotFound(
					fmt.Sprintf("Fitur tidak ditemukan: %s.", joinInt64(missing)), "SYS-404")
			}
		}

		if err := s.Repo.DeleteTenantFeaturesByTenant(ctx, tx, id); err != nil {
			return err
		}
		if len(targetIDs) > 0 {
			if err := s.Repo.InsertTenantFeatures(ctx, tx, id, targetIDs); err != nil {
				return err
			}
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		after, err := s.Repo.ListIdFiturAktif(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := s.appendEvent(ctx, tx, id, "SET_FITUR", map[string]any{
			"dari": before,
			"ke":   after,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_tenant_fitur",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "replace",
				BeforeValue: audit.Snapshot{"id_features": toAnySlice(before)},
				AfterValue:  audit.Snapshot{"id_features": toAnySlice(after)},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		rows, err = s.Repo.ListRowsFiturTenant(ctx, tx, id)
		return err
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

/* -------------------------------------------------------------- */
/* Settings per kategori                                           */
/* -------------------------------------------------------------- */

// ListSettings — daftar setting (urut kategori, kunci) — opsional filter
// kategori (sudah di-trim di handler).
func (s *TenantsService) ListSettings(ctx context.Context, id int64, kategori *string) ([]types.TenantSettingRow, error) {
	if _, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id); err != nil {
		return nil, err
	}
	return s.Repo.ListRowsSettingsTenant(ctx, s.DB.Pool, id, kategori)
}

// SetSettings — REPLACE settings SATU kategori: dedupe kunci (entri terakhir
// menang) → hapus kategori → sisip payload; version +1; event SET_PENGATURAN
// {kategori, dari kunci lama, ke kunci baru sorted}; audit warning.
func (s *TenantsService) SetSettings(ctx context.Context, id int64, in types.TenantSettingsSetInput, actor audit.Actor) ([]types.TenantSettingRow, error) {
	// Dedupe kunci dalam payload — entri terakhir menang (idempoten).
	entri := domain.DedupeEntriSettings(in.Entri)
	var rows []types.TenantSettingRow
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}

		before, err := s.Repo.ListKunciSettingsTenant(ctx, tx, id, in.Kategori)
		if err != nil {
			return err
		}
		if err := s.Repo.DeleteTenantSettingsKategori(ctx, tx, id, in.Kategori); err != nil {
			return err
		}
		for _, e := range entri {
			// `nilai ?? {}` — null → jsonb {} (persis NestJS).
			if err := s.Repo.InsertTenantSetting(ctx, tx, id, in.Kategori, e.Kunci, e.Nilai); err != nil {
				return err
			}
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		after := make([]string, 0, len(entri))
		for _, e := range entri {
			after = append(after, e.Kunci)
		}
		sort.Strings(after) // padanan [...keys].sort()

		if err := s.appendEvent(ctx, tx, id, "SET_PENGATURAN", map[string]any{
			"kategori": in.Kategori,
			"dari":     before,
			"ke":       after,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_tenant_pengaturan",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "set_settings",
				BeforeValue: audit.Snapshot{"kategori": in.Kategori, "kunci": toAnySlice(before)},
				AfterValue:  audit.Snapshot{"kategori": in.Kategori, "kunci": toAnySlice(after)},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		rows, err = s.Repo.ListRowsSettingsTenant(ctx, tx, id, &in.Kategori)
		return err
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

/* -------------------------------------------------------------- */
/* Riwayat event (core_tenant_events) — append-only, terbaru dulu   */
/* -------------------------------------------------------------- */

// ListEvents — riwayat event tenant (tab Riwayat FE) — urut terbaru dulu.
func (s *TenantsService) ListEvents(ctx context.Context, id int64) ([]types.TenantEventView, error) {
	if _, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id); err != nil {
		return nil, err
	}
	return s.Repo.ListRowsEventTenant(ctx, s.DB.Pool, id)
}

/* -------------------------------------------------------------- */
/* Keanggotaan (core_users_tenants)                                */
/* -------------------------------------------------------------- */

// ListMembers — daftar anggota AKTIF (dicabut_pada NULL) — default dulu,
// lalu alfabetis by username (port switcher FE).
func (s *TenantsService) ListMembers(ctx context.Context, id int64) ([]types.TenantMemberView, error) {
	if _, err := s.Repo.AssertTenant(ctx, s.DB.Pool, id); err != nil {
		return nil, err
	}
	return s.Repo.ListRowsAnggotaAktif(ctx, s.DB.Pool, id)
}

// AddMember — tambah anggota: dup aktif → 409; keanggotaan pernah dicabut
// diaktifkan kembali; isDefault=true mengosongkan default lain user itu;
// version +1; event SET_ANGGOTA; audit info.
func (s *TenantsService) AddMember(ctx context.Context, id int64, in types.TenantMembersAddInput, actor audit.Actor) (types.TenantMemberView, error) {
	var view types.TenantMemberView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}
		if err := s.Repo.GetUserAda(ctx, tx, in.IDCoreUsers); err != nil {
			return err
		}

		existing, err := s.Repo.FindAnggotaTenant(ctx, tx, id, in.IDCoreUsers)
		if err != nil {
			return err
		}
		if existing != nil && existing.DicabutPada == nil {
			return errkontrak.Conflict(
				fmt.Sprintf("User id %d sudah menjadi anggota aktif tenant ini.", in.IDCoreUsers),
				"SYS-409",
			)
		}

		var row repository.AnggotaRow
		aksi := "tambah"
		auditAction := "add_member"
		if existing != nil {
			// REAKTIVASI keanggotaan lama — dicabut_pada dikosongkan kembali.
			aksi = "reaktivasi"
			auditAction = "reactivate_member"
			row, err = s.Repo.ReaktivasiAnggota(ctx, tx, existing.ID, in.IsDefault)
			if err != nil {
				return err
			}
		} else {
			row, err = s.Repo.InsertTenantMember(ctx, tx, id, in.IDCoreUsers, in.IsDefault)
			if err != nil {
				return err
			}
		}

		if in.IsDefault {
			if err := s.Repo.ClearDefaultLain(ctx, tx, in.IDCoreUsers, row.ID); err != nil {
				return err
			}
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		if err := s.appendEvent(ctx, tx, id, "SET_ANGGOTA", map[string]any{
			"aksi":        aksi,
			"idCoreUsers": in.IDCoreUsers,
			"isDefault":   in.IsDefault,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_tenant_anggota",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     auditAction,
				AfterValue: audit.Snapshot{"id_core_users": in.IDCoreUsers, "is_default": in.IsDefault},
				Severity:   audit.SeverityInfo,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		return s.lengkapiAnggota(ctx, tx, row, &view)
	})
	if err != nil {
		return types.TenantMemberView{}, err
	}
	return view, nil
}

// SetMemberDefault — set keanggotaan (tenant, :userId) sebagai DEFAULT user
// itu — default lain dikosongkan; 404 bila bukan anggota aktif; event
// SET_ANGGOTA; audit info.
func (s *TenantsService) SetMemberDefault(ctx context.Context, id, userID int64, actor audit.Actor) (types.TenantMemberView, error) {
	var view types.TenantMemberView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}
		row, err := s.Repo.GetAnggotaAktif(ctx, tx, id, userID)
		if err != nil {
			return err
		}

		updated, err := s.Repo.SetDefaultAnggota(ctx, tx, row.ID)
		if err != nil {
			return err
		}
		if err := s.Repo.ClearDefaultLain(ctx, tx, userID, updated.ID); err != nil {
			return err
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		if err := s.appendEvent(ctx, tx, id, "SET_ANGGOTA", map[string]any{
			"aksi":        "set_default",
			"idCoreUsers": userID,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_tenant_anggota",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "set_default_member",
				AfterValue: audit.Snapshot{"id_core_users": userID, "is_default": true},
				Severity:   audit.SeverityInfo,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}

		return s.lengkapiAnggota(ctx, tx, updated, &view)
	})
	if err != nil {
		return types.TenantMemberView{}, err
	}
	return view, nil
}

// RemoveMember — cabut anggota SOFT (dicabut_pada=now, default dikosongkan):
// 409 bila dia anggota AKTIF terakhir; version +1; event cabut; audit warning.
func (s *TenantsService) RemoveMember(ctx context.Context, id, userID int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if _, err := s.Repo.AssertTenant(ctx, tx, id); err != nil {
			return err
		}
		row, err := s.Repo.GetAnggotaAktif(ctx, tx, id, userID)
		if err != nil {
			return err
		}

		lainnya, err := s.Repo.CountAnggotaAktifLain(ctx, tx, id, userID)
		if err != nil {
			return err
		}
		if lainnya == 0 {
			return errkontrak.Conflict(
				"Tidak bisa mencabut anggota terakhir — tenant wajib punya minimal satu anggota aktif.",
				"SYS-409",
			)
		}

		if err := s.Repo.CabutAnggota(ctx, tx, row.ID); err != nil {
			return err
		}
		if err := s.Repo.BumpVersionTenant(ctx, tx, id); err != nil {
			return err
		}

		if err := s.appendEvent(ctx, tx, id, "SET_ANGGOTA", map[string]any{
			"aksi":        "cabut",
			"idCoreUsers": userID,
		}, actor); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_tenant_anggota",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "revoke_member",
				BeforeValue: audit.Snapshot{"id_core_users": userID, "is_default": row.IsDefault},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		return nil
	})
}

/* -------------------------------------------------------------- */
/* Konteks tenant user saat ini                                    */
/* -------------------------------------------------------------- */

// Context — tenant milik user SAAT INI (JWT) — keanggotaan aktif pada tenant
// hidup; default user tampil paling atas, sisanya stabil by kode.
func (s *TenantsService) Context(ctx context.Context, userID int64) ([]types.TenantContextRow, error) {
	return s.Repo.ListTenantContextUser(ctx, s.DB.Pool, userID)
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// appendEvent — tulis satu baris event tenant (append-only) — tx sama
// dengan mutasi; aktor = user login (nil = [sistem]).
func (s *TenantsService) appendEvent(ctx context.Context, tx pgx.Tx, idCoreTenants int64, aksi string, payload map[string]any, actor audit.Actor) error {
	return s.Repo.InsertTenantEvent(ctx, tx, idCoreTenants, aksi, payload, actor.IDCoreUsers)
}

// lengkapiAnggota — username+nama user untuk view keanggotaan (fallback
// String(id) persis lengkapiAnggotaDenganUser NestJS).
func (s *TenantsService) lengkapiAnggota(ctx context.Context, tx pgx.Tx, row repository.AnggotaRow, out *types.TenantMemberView) error {
	username, nama, ada, err := s.Repo.GetUserIdentitas(ctx, tx, row.IDCoreUsers)
	if err != nil {
		return err
	}
	if !ada {
		idStr := fmt.Sprintf("%d", row.IDCoreUsers)
		username, nama = idStr, idStr
	}
	*out = repository.MemberToView(row, username, nama)
	return nil
}

// ensureVersion — 412 SYS-412 bila If-Match diberikan dan version tidak cocok.
func ensureVersion(current int32, expected *int64) error {
	if expected != nil && *expected != int64(current) {
		return &errkontrak.DomainError{
			Code:   "SYS-412",
			Status: 412,
			Detail: fmt.Sprintf("Resource sudah diubah pihak lain — If-Match (%d) ≠ version terkini (%d).", *expected, current),
		}
	}
	return nil
}

// snapshotOf — baris repo → input snapshot domain (audit before/after).
func snapshotOf(row repository.TenantRow) domain.TenantSnapshot {
	return domain.TenantSnapshot{
		Kode:          row.Kode,
		Nama:          row.Nama,
		PaketTier:     row.PaketTier,
		Status:        row.Status,
		MaxUsers:      row.MaxUsers,
		MaxLokasi:     row.MaxLokasi,
		KontakEmail:   row.KontakEmail,
		KontakTelepon: row.KontakTelepon,
		Version:       row.Version,
	}
}

/* -------------------------------------------------------------- */
/* Util kecil (urutan stabil tanpa bergantung library)             */
/* -------------------------------------------------------------- */

// dedupeInt64 — dedupe id mempertahankan urutan kemunculan pertama
// (padanan [...new Set(ids)]).
func dedupeInt64(ids []int64) []int64 {
	seen := make(map[int64]bool, len(ids))
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, id)
	}
	return out
}

// missingIDs — id target yang tidak ada di katalog (urutan target dipertahankan
// — pesan 404 urut sesuai payload, persis filter missing NestJS).
func missingIDs(target, found []int64) []int64 {
	set := make(map[int64]bool, len(found))
	for _, id := range found {
		set[id] = true
	}
	out := []int64{}
	for _, id := range target {
		if !set[id] {
			out = append(out, id)
		}
	}
	return out
}

// joinInt64 — padanan missing.join(", ").
func joinInt64(ids []int64) string {
	out := ""
	for i, id := range ids {
		if i > 0 {
			out += ", "
		}
		out += fmt.Sprintf("%d", id)
	}
	return out
}

// toAnySlice — []int64 / []string → []any utk snapshot jsonb (bukan null).
func toAnySlice[T any](in []T) []any {
	out := make([]any, 0, len(in))
	for _, v := range in {
		out = append(out, v)
	}
	return out
}
