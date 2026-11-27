// Package repository — SATU-SATUNYA pengguna pgx+sqlc fitur TENANTS modul
// core (padanan TenantsRepository NestJS). Semua method menerima executor
// (pool pgx | pgx.Tx — keduanya memenuhi gen.DBTX): service meneruskan tx
// transaksi bisnis yang sama untuk mutasi, atau pool untuk baca non-tx.
// Konversi pgtype → tipe Go polos dan row→View dilakukan DI SINI (bentuk
// JSON = kontrak zod packages/schemas/core/tenants).
package repository

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// TenantsRepository — pembungkus gen.Querier per executor.
type TenantsRepository struct{}

// NewTenants — konstruksi tanpa state (executor diteruskan per method).
func NewTenants() *TenantsRepository { return &TenantsRepository{} }

/* ------------------------------------------------------------------ */
/* Baris polos (hasil konversi pgtype)                                 */
/* ------------------------------------------------------------------ */

// TenantRow — baris core_tenants (dipakai service utk pembanding version,
// merge patch, snapshot audit).
type TenantRow struct {
	ID            int64
	EntityID      string
	Kode          string
	Nama          string
	PaketTier     string
	Status        string
	MaxUsers      *int32
	MaxLokasi     *int32
	KontakEmail   *string
	KontakTelepon *string
	VersiSkema    int32
	Version       int32
	CreatedAt     time.Time
	UpdatedAt     time.Time
	DeletedAt     *time.Time
}

// AnggotaRow — baris core_users_tenants (keanggotaan).
type AnggotaRow struct {
	ID            int64
	IDCoreTenants int64
	IDCoreUsers   int64
	IsDefault     bool
	DicabutPada   *time.Time
}

/* ------------------------------------------------------------------ */
/* Konversi row → view (bentuk JSON PERSIS zod)                        */
/* ------------------------------------------------------------------ */

// TenantToView — padanan tenantToView (waktu ISO-8601 toISOString).
func TenantToView(row TenantRow) types.TenantView {
	return types.TenantView{
		ID:            row.ID,
		EntityID:      row.EntityID,
		Kode:          row.Kode,
		Nama:          row.Nama,
		PaketTier:     row.PaketTier,
		Status:        row.Status,
		MaxUsers:      row.MaxUsers,
		MaxLokasi:     row.MaxLokasi,
		KontakEmail:   row.KontakEmail,
		KontakTelepon: row.KontakTelepon,
		VersiSkema:    row.VersiSkema,
		Version:       row.Version,
		CreatedAt:     iso(row.CreatedAt),
		UpdatedAt:     iso(row.UpdatedAt),
		DeletedAt:     isoPtr(row.DeletedAt),
	}
}

// MemberToView — padanan memberToView: baris keanggotaan + identitas user
// (hasil LengkapiAnggotaDenganUser) → view tenantMemberViewSchema.
func MemberToView(row AnggotaRow, username, nama string) types.TenantMemberView {
	return types.TenantMemberView{
		IDCoreUsers: row.IDCoreUsers,
		Username:    username,
		Nama:        nama,
		IsDefault:   row.IsDefault,
		DicabutPada: isoPtr(row.DicabutPada),
	}
}

func fromCoreTenant(r gen.CoreTenant) TenantRow {
	return TenantRow{
		ID:            r.ID,
		EntityID:      uuidString(r.EntityID),
		Kode:          r.Kode,
		Nama:          r.Nama,
		PaketTier:     string(r.PaketTier),
		Status:        string(r.Status),
		MaxUsers:      i4Ptr(r.MaxUsers),
		MaxLokasi:     i4Ptr(r.MaxLokasi),
		KontakEmail:   txtPtr(r.KontakEmail),
		KontakTelepon: txtPtr(r.KontakTelepon),
		VersiSkema:    r.VersiSkema,
		Version:       r.Version,
		CreatedAt:     r.CreatedAt.Time,
		UpdatedAt:     r.UpdatedAt.Time,
		DeletedAt:     tsPtr(r.DeletedAt),
	}
}

func fromAnggota(r gen.CoreUsersTenant) AnggotaRow {
	return AnggotaRow{
		ID:            r.ID,
		IDCoreTenants: r.IDCoreTenants,
		IDCoreUsers:   r.IDCoreUsers,
		IsDefault:     r.IsDefault,
		DicabutPada:   tsPtr(r.DicabutPada),
	}
}

/* ------------------------------------------------------------------ */
/* Baca — daftar / detail / dup kode / konteks user                    */
/* ------------------------------------------------------------------ */

// ListTenants — daftar tenant paging (soft-delete aware; search kode+nama).
func (r *TenantsRepository) ListTenants(ctx context.Context, exec gen.DBTX, q types.TenantListQuery) (types.TenantList, error) {
	filter := gen.ListTenantsParams{
		Search: pgTextPtr(q.Search),
		Status: pgTextEmpty(q.Status),
		Tier:   pgTextEmpty(q.Tier),
		Offset: int32((q.Page - 1) * q.Limit),
		Limit:  int32(q.Limit),
	}
	rows, err := gen.New(exec).ListTenants(ctx, filter)
	if err != nil {
		return types.TenantList{}, err
	}
	total, err := gen.New(exec).CountTenants(ctx, gen.CountTenantsParams{
		Search: filter.Search, Status: filter.Status, Tier: filter.Tier,
	})
	if err != nil {
		return types.TenantList{}, err
	}
	out := make([]types.TenantView, 0, len(rows))
	for _, row := range rows {
		out = append(out, TenantToView(fromCoreTenant(row)))
	}
	return types.TenantList{Rows: out, Total: int64(total)}, nil
}

// AssertTenant — tenant hidup wajib ada; fail 404 SYS-404 bila absen/terhapus.
func (r *TenantsRepository) AssertTenant(ctx context.Context, exec gen.DBTX, id int64) (TenantRow, error) {
	row, err := gen.New(exec).GetTenantHidup(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return TenantRow{}, errkontrak.NotFound(fmt.Sprintf("Tenant id %d tidak ditemukan.", id), "SYS-404")
	}
	if err != nil {
		return TenantRow{}, err
	}
	return fromCoreTenant(row), nil
}

// FindTenantKodeHidup — tenant hidup by kode (cek duplikat); nil bila absen.
func (r *TenantsRepository) FindTenantKodeHidup(ctx context.Context, exec gen.DBTX, kode string) (*int64, error) {
	id, err := gen.New(exec).FindTenantKodeHidup(ctx, kode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &id, nil
}

// ListTenantContextUser — keanggotaan aktif user + tenant hidup (switcher FE):
// default dulu, sisanya stabil by kode.
func (r *TenantsRepository) ListTenantContextUser(ctx context.Context, exec gen.DBTX, userID int64) ([]types.TenantContextRow, error) {
	rows, err := gen.New(exec).ListTenantContextUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantContextRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.TenantContextRow{
			IDTenant:  row.IDTenant,
			Kode:      row.Kode,
			Nama:      row.Nama,
			Status:    string(row.Status),
			IsDefault: row.IsDefault,
		})
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Tulis — tenant                                                      */
/* ------------------------------------------------------------------ */

// TenantBaru — nilai insert core_tenants (status PROVISI dibangun service).
type TenantBaru struct {
	Kode          string
	Nama          string
	PaketTier     string
	Status        string
	MaxUsers      *int32
	MaxLokasi     *int32
	KontakEmail   *string
	KontakTelepon *string
}

// InsertTenant — insert tenant baru → baris lengkap.
func (r *TenantsRepository) InsertTenant(ctx context.Context, exec gen.DBTX, v TenantBaru) (TenantRow, error) {
	row, err := gen.New(exec).InsertTenant(ctx, gen.InsertTenantParams{
		Kode:          v.Kode,
		Nama:          v.Nama,
		PaketTier:     gen.EnumPaketTier(v.PaketTier),
		Status:        gen.EnumStatusTenant(v.Status),
		MaxUsers:      pgI4(v.MaxUsers),
		MaxLokasi:     pgI4(v.MaxLokasi),
		KontakEmail:   pgTxt(v.KontakEmail),
		KontakTelepon: pgTxt(v.KontakTelepon),
	})
	if err != nil {
		return TenantRow{}, err
	}
	return fromCoreTenant(row), nil
}

// TenantUbahLengkap — set patch umum hasil merge service (version+1 di sana).
type TenantUbahLengkap struct {
	Kode          string
	Nama          string
	PaketTier     string
	MaxUsers      *int32
	MaxLokasi     *int32
	KontakEmail   *string
	KontakTelepon *string
	Version       int32
	ID            int64
}

// UpdateTenantLengkap — update patch umum → baris terbaru.
func (r *TenantsRepository) UpdateTenantLengkap(ctx context.Context, exec gen.DBTX, v TenantUbahLengkap) (TenantRow, error) {
	row, err := gen.New(exec).UpdateTenantLengkap(ctx, gen.UpdateTenantLengkapParams{
		Kode:          v.Kode,
		Nama:          v.Nama,
		PaketTier:     gen.EnumPaketTier(v.PaketTier),
		MaxUsers:      pgI4(v.MaxUsers),
		MaxLokasi:     pgI4(v.MaxLokasi),
		KontakEmail:   pgTxt(v.KontakEmail),
		KontakTelepon: pgTxt(v.KontakTelepon),
		Version:       v.Version,
		ID:            v.ID,
	})
	if err != nil {
		return TenantRow{}, err
	}
	return fromCoreTenant(row), nil
}

// UpdateTenantStatus — transisi siklus hidup (status + version dari service).
func (r *TenantsRepository) UpdateTenantStatus(ctx context.Context, exec gen.DBTX, id int64, status string, version int32) (TenantRow, error) {
	row, err := gen.New(exec).UpdateTenantStatus(ctx, gen.UpdateTenantStatusParams{
		ID:      id,
		Status:  gen.EnumStatusTenant(status),
		Version: version,
	})
	if err != nil {
		return TenantRow{}, err
	}
	return fromCoreTenant(row), nil
}

// UpdateTenantTier — ganti tier paket (version dari service).
func (r *TenantsRepository) UpdateTenantTier(ctx context.Context, exec gen.DBTX, id int64, paketTier string, version int32) (TenantRow, error) {
	row, err := gen.New(exec).UpdateTenantTier(ctx, gen.UpdateTenantTierParams{
		ID:        id,
		PaketTier: gen.EnumPaketTier(paketTier),
		Version:   version,
	})
	if err != nil {
		return TenantRow{}, err
	}
	return fromCoreTenant(row), nil
}

// BumpVersionTenant — naikkan version +1 (semua mutasi sub-resource).
func (r *TenantsRepository) BumpVersionTenant(ctx context.Context, exec gen.DBTX, id int64) error {
	return gen.New(exec).BumpVersionTenant(ctx, id)
}

/* ------------------------------------------------------------------ */
/* Katalog global — snapshot PROVISIONING & validasi id REPLACE        */
/* ------------------------------------------------------------------ */

// ListSemuaModulId — id SEMUA modul global (tanpa filter).
func (r *TenantsRepository) ListSemuaModulId(ctx context.Context, exec gen.DBTX) ([]int64, error) {
	return gen.New(exec).ListSemuaModulId(ctx)
}

// ListFiturGlobalAktifId — id fitur global aktif (aktif + modulnya enabled).
func (r *TenantsRepository) ListFiturGlobalAktifId(ctx context.Context, exec gen.DBTX) ([]int64, error) {
	return gen.New(exec).ListFiturGlobalAktifId(ctx)
}

// ListModulId — id modul katalog by set id (validasi REPLACE; absen = 404 di service).
func (r *TenantsRepository) ListModulId(ctx context.Context, exec gen.DBTX, ids []int64) ([]int64, error) {
	return gen.New(exec).ListModulId(ctx, ids)
}

// ListFiturId — id fitur katalog by set id (validasi REPLACE; absen = 404 di service).
func (r *TenantsRepository) ListFiturId(ctx context.Context, exec gen.DBTX, ids []int64) ([]int64, error) {
	return gen.New(exec).ListFiturId(ctx, ids)
}

/* ------------------------------------------------------------------ */
/* Junction modul tenant (core_tenant_modules)                         */
/* ------------------------------------------------------------------ */

// InsertTenantModules — sisip modul aktif tenant (ON CONFLICT DO NOTHING).
func (r *TenantsRepository) InsertTenantModules(ctx context.Context, exec gen.DBTX, idCoreTenants int64, ids []int64) error {
	return gen.New(exec).InsertTenantModules(ctx, gen.InsertTenantModulesParams{IDCoreTenants: idCoreTenants, Column2: ids})
}

// DeleteTenantModulesByTenant — hapus seluruh set modul tenant (REPLACE).
func (r *TenantsRepository) DeleteTenantModulesByTenant(ctx context.Context, exec gen.DBTX, idCoreTenants int64) error {
	return gen.New(exec).DeleteTenantModulesByTenant(ctx, idCoreTenants)
}

// ListIdModulAktif — id modul aktif tenant (urut) — payload event SET_MODUL.
func (r *TenantsRepository) ListIdModulAktif(ctx context.Context, exec gen.DBTX, id int64) ([]int64, error) {
	return gen.New(exec).ListIdModulAktif(ctx, id)
}

// ListRowsModulTenant — katalog modul registry + flag aktif tenant (ORDER id).
func (r *TenantsRepository) ListRowsModulTenant(ctx context.Context, exec gen.DBTX, id int64) ([]types.TenantModuleRow, error) {
	rows, err := gen.New(exec).ListRowsModulTenant(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantModuleRow, 0, len(rows))
	for _, row := range rows {
		aktif, err := boolAny(row.Aktif)
		if err != nil {
			return nil, err
		}
		out = append(out, types.TenantModuleRow{ID: row.ID, Key: string(row.Key), Nama: row.Nama, Aktif: aktif})
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Junction fitur tenant (core_tenant_features)                        */
/* ------------------------------------------------------------------ */

// InsertTenantFeatures — sisip fitur aktif tenant (ON CONFLICT DO NOTHING).
func (r *TenantsRepository) InsertTenantFeatures(ctx context.Context, exec gen.DBTX, idCoreTenants int64, ids []int64) error {
	return gen.New(exec).InsertTenantFeatures(ctx, gen.InsertTenantFeaturesParams{IDCoreTenants: idCoreTenants, Column2: ids})
}

// DeleteTenantFeaturesByTenant — hapus seluruh set fitur tenant (REPLACE).
func (r *TenantsRepository) DeleteTenantFeaturesByTenant(ctx context.Context, exec gen.DBTX, idCoreTenants int64) error {
	return gen.New(exec).DeleteTenantFeaturesByTenant(ctx, idCoreTenants)
}

// ListIdFiturAktif — id fitur aktif tenant (urut) — payload event SET_FITUR.
func (r *TenantsRepository) ListIdFiturAktif(ctx context.Context, exec gen.DBTX, id int64) ([]int64, error) {
	return gen.New(exec).ListIdFiturAktif(ctx, id)
}

// ListRowsFiturTenant — katalog fitur registry + flag aktif; nama = label
// description jsonb bila object berkolom `label`, fallback features_folder.
func (r *TenantsRepository) ListRowsFiturTenant(ctx context.Context, exec gen.DBTX, id int64) ([]types.TenantFeatureRow, error) {
	rows, err := gen.New(exec).ListRowsFiturTenant(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantFeatureRow, 0, len(rows))
	for _, row := range rows {
		aktif, err := boolAny(row.Aktif)
		if err != nil {
			return nil, err
		}
		out = append(out, types.TenantFeatureRow{
			ID:        row.ID,
			ModuleKey: string(row.ModuleKey),
			Key:       row.Key,
			Nama:      row.Nama,
			Aktif:     aktif,
		})
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Settings tenant (core_tenant_settings)                              */
/* ------------------------------------------------------------------ */

// ListRowsSettingsTenant — baris setting (opsional satu kategori), urut
// kategori & kunci; nilai jsonb di-DECODE ke any (kontrak: selalu ada).
func (r *TenantsRepository) ListRowsSettingsTenant(ctx context.Context, exec gen.DBTX, id int64, kategori *string) ([]types.TenantSettingRow, error) {
	rows, err := gen.New(exec).ListRowsSettingsTenant(ctx, gen.ListRowsSettingsTenantParams{
		IDCoreTenants: id,
		Kategori:      pgTextPtr(kategori),
	})
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantSettingRow, 0, len(rows))
	for _, row := range rows {
		var nilai any
		if len(row.Nilai) > 0 {
			if err := json.Unmarshal(row.Nilai, &nilai); err != nil {
				return nil, fmt.Errorf("tenants: decode nilai jsonb: %w", err)
			}
		}
		out = append(out, types.TenantSettingRow{Kategori: row.Kategori, Kunci: row.Kunci, Nilai: nilai})
	}
	return out, nil
}

// DeleteTenantSettingsKategori — hapus seluruh entri SATU kategori (REPLACE).
func (r *TenantsRepository) DeleteTenantSettingsKategori(ctx context.Context, exec gen.DBTX, idCoreTenants int64, kategori string) error {
	return gen.New(exec).DeleteTenantSettingsKategori(ctx, gen.DeleteTenantSettingsKategoriParams{IDCoreTenants: idCoreTenants, Kategori: kategori})
}

// InsertTenantSetting — sisip SATU entri settings (batch = loop panggilan ini
// dalam executor yang sama); nilai jsonb: null → {} (persis `nilai ?? {}`).
func (r *TenantsRepository) InsertTenantSetting(ctx context.Context, exec gen.DBTX, idCoreTenants int64, kategori, kunci string, nilai any) error {
	bytes := []byte("{}")
	if nilai != nil {
		b, err := json.Marshal(nilai)
		if err != nil {
			return fmt.Errorf("tenants: encode nilai jsonb: %w", err)
		}
		bytes = b
	}
	return gen.New(exec).InsertTenantSetting(ctx, gen.InsertTenantSettingParams{
		IDCoreTenants: idCoreTenants, Kategori: kategori, Kunci: kunci, Nilai: bytes,
	})
}

// ListKunciSettingsTenant — kunci satu kategori (urut) — payload event.
func (r *TenantsRepository) ListKunciSettingsTenant(ctx context.Context, exec gen.DBTX, id int64, kategori string) ([]string, error) {
	return gen.New(exec).ListKunciSettingsTenant(ctx, gen.ListKunciSettingsTenantParams{IDCoreTenants: id, Kategori: kategori})
}

/* ------------------------------------------------------------------ */
/* Event tenant (core_tenant_events — append-only)                     */
/* ------------------------------------------------------------------ */

// InsertTenantEvent — tulis satu baris event (tx sama dengan mutasi).
func (r *TenantsRepository) InsertTenantEvent(ctx context.Context, exec gen.DBTX, idCoreTenants int64, aksi string, payload map[string]any, idCoreUsers *int64) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("tenants: encode payload event: %w", err)
	}
	return gen.New(exec).InsertTenantEvent(ctx, gen.InsertTenantEventParams{
		IDCoreTenants: idCoreTenants,
		Aksi:          aksi,
		Payload:       b,
		IDCoreUsers:   pgI8(idCoreUsers),
	})
}

// ListRowsEventTenant — riwayat event tenant, terbaru dulu, JOIN aktor.
func (r *TenantsRepository) ListRowsEventTenant(ctx context.Context, exec gen.DBTX, id int64) ([]types.TenantEventView, error) {
	rows, err := gen.New(exec).ListRowsEventTenant(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantEventView, 0, len(rows))
	for _, row := range rows {
		var payload any
		if len(row.Payload) > 0 {
			if err := json.Unmarshal(row.Payload, &payload); err != nil {
				return nil, fmt.Errorf("tenants: decode payload event: %w", err)
			}
		}
		out = append(out, types.TenantEventView{
			ID:        row.ID,
			Aksi:      row.Aksi,
			Payload:   payload,
			Aktor:     txtPtr(row.Aktor),
			CreatedAt: iso(row.CreatedAt.Time),
		})
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Keanggotaan (core_users_tenants)                                    */
/* ------------------------------------------------------------------ */

// FindAnggotaTenant — baris keanggotaan (tenant, user) apa pun statusnya;
// nil bila absen.
func (r *TenantsRepository) FindAnggotaTenant(ctx context.Context, exec gen.DBTX, idCoreTenants, idCoreUsers int64) (*AnggotaRow, error) {
	row, err := gen.New(exec).FindAnggotaTenant(ctx, gen.FindAnggotaTenantParams{IDCoreTenants: idCoreTenants, IDCoreUsers: idCoreUsers})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	a := fromAnggota(row)
	return &a, nil
}

// GetAnggotaAktif — keanggotaan AKTIF wajib ada — fail 404 SYS-404.
func (r *TenantsRepository) GetAnggotaAktif(ctx context.Context, exec gen.DBTX, idCoreTenants, idCoreUsers int64) (AnggotaRow, error) {
	row, err := gen.New(exec).GetAnggotaAktif(ctx, gen.GetAnggotaAktifParams{IDCoreTenants: idCoreTenants, IDCoreUsers: idCoreUsers})
	if errors.Is(err, pgx.ErrNoRows) {
		return AnggotaRow{}, errkontrak.NotFound(
			fmt.Sprintf("User id %d bukan anggota aktif tenant id %d.", idCoreUsers, idCoreTenants), "SYS-404")
	}
	if err != nil {
		return AnggotaRow{}, err
	}
	return fromAnggota(row), nil
}

// InsertTenantMember — insert keanggotaan baru.
func (r *TenantsRepository) InsertTenantMember(ctx context.Context, exec gen.DBTX, idCoreTenants, idCoreUsers int64, isDefault bool) (AnggotaRow, error) {
	row, err := gen.New(exec).InsertTenantMember(ctx, gen.InsertTenantMemberParams{
		IDCoreTenants: idCoreTenants, IDCoreUsers: idCoreUsers, IsDefault: isDefault,
	})
	if err != nil {
		return AnggotaRow{}, err
	}
	return fromAnggota(row), nil
}

// ReaktivasiAnggota — dicabut_pada dikosongkan + isDefault payload.
func (r *TenantsRepository) ReaktivasiAnggota(ctx context.Context, exec gen.DBTX, id int64, isDefault bool) (AnggotaRow, error) {
	row, err := gen.New(exec).ReaktivasiAnggota(ctx, gen.ReaktivasiAnggotaParams{ID: id, IsDefault: isDefault})
	if err != nil {
		return AnggotaRow{}, err
	}
	return fromAnggota(row), nil
}

// SetDefaultAnggota — set keanggotaan sebagai default user.
func (r *TenantsRepository) SetDefaultAnggota(ctx context.Context, exec gen.DBTX, id int64) (AnggotaRow, error) {
	row, err := gen.New(exec).SetDefaultAnggota(ctx, id)
	if err != nil {
		return AnggotaRow{}, err
	}
	return fromAnggota(row), nil
}

// CabutAnggota — cabut SOFT: dicabut_pada = now + default dikosongkan.
func (r *TenantsRepository) CabutAnggota(ctx context.Context, exec gen.DBTX, id int64) error {
	return gen.New(exec).CabutAnggota(ctx, id)
}

// CountAnggotaAktifLain — jumlah anggota aktif lain (guard anggota terakhir).
func (r *TenantsRepository) CountAnggotaAktifLain(ctx context.Context, exec gen.DBTX, idCoreTenants, idCoreUsers int64) (int64, error) {
	n, err := gen.New(exec).CountAnggotaAktifLain(ctx, gen.CountAnggotaAktifLainParams{IDCoreTenants: idCoreTenants, IDCoreUsers: idCoreUsers})
	return int64(n), err
}

// ClearDefaultLain — kosongkan default keanggotaan LAIN milik user.
func (r *TenantsRepository) ClearDefaultLain(ctx context.Context, exec gen.DBTX, idCoreUsers, keepID int64) error {
	return gen.New(exec).ClearDefaultLain(ctx, gen.ClearDefaultLainParams{IDCoreUsers: idCoreUsers, ID: keepID})
}

// ListRowsAnggotaAktif — anggota aktif (JOIN core_users): default dulu, lalu
// alfabetis by username (padanan listRowsAnggotaAktif).
func (r *TenantsRepository) ListRowsAnggotaAktif(ctx context.Context, exec gen.DBTX, id int64) ([]types.TenantMemberView, error) {
	rows, err := gen.New(exec).ListRowsAnggotaAktif(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]types.TenantMemberView, 0, len(rows))
	for _, row := range rows {
		out = append(out, types.TenantMemberView{
			IDCoreUsers: row.IDCoreUsers,
			Username:    row.Username,
			Nama:        row.Nama,
			IsDefault:   row.IsDefault,
			DicabutPada: isoPtr(tsPtr(row.DicabutPada)),
		})
	}
	return out, nil
}

// GetUserIdentitas — username+nama user by id; ada=false bila absen
// (service fallback String(id) — padanan lengkapiAnggotaDenganUser).
func (r *TenantsRepository) GetUserIdentitas(ctx context.Context, exec gen.DBTX, id int64) (username, nama string, ada bool, err error) {
	row, err := gen.New(exec).GetUserIdentitas(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	if err != nil {
		return "", "", false, err
	}
	return row.Username, row.Name, true, nil
}

// GetUserAda — user wajib ada — fail 404 SYS-404 bila id tak dikenal.
func (r *TenantsRepository) GetUserAda(ctx context.Context, exec gen.DBTX, id int64) error {
	_, err := gen.New(exec).GetUserAda(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return errkontrak.NotFound(fmt.Sprintf("User id %d tidak ditemukan.", id), "SYS-404")
	}
	return err
}

/* ------------------------------------------------------------------ */
/* Helper konversi pgtype                                              */
/* ------------------------------------------------------------------ */

// iso — padanan toISOString(): UTC, milidetik 3 digit, akhiran Z.
func iso(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

func isoPtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := iso(*t)
	return &s
}

func uuidString(u pgtype.UUID) string {
	if !u.Valid {
		return ""
	}
	return u.String()
}

func txtPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

func i4Ptr(i pgtype.Int4) *int32 {
	if !i.Valid {
		return nil
	}
	v := i.Int32
	return &v
}

func tsPtr(t pgtype.Timestamptz) *time.Time {
	if !t.Valid {
		return nil
	}
	v := t.Time
	return &v
}

func pgTextPtr(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}

func pgTxt(s *string) pgtype.Text { return pgTextPtr(s) }

// pgTextEmpty — string "" berarti filter tidak dipakai (param NULL).
func pgTextEmpty(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

func pgI4(i *int32) pgtype.Int4 {
	if i == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *i, Valid: true}
}

func pgI8(i *int64) pgtype.Int8 {
	if i == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *i, Valid: true}
}

// boolAny — kolom ekspresi `IS NOT NULL` hasil sqlc interface{} → bool.
func boolAny(v any) (bool, error) {
	b, ok := v.(bool)
	if !ok {
		return false, fmt.Errorf("tenants: kolom aktif bukan boolean: %T", v)
	}
	return b, nil
}
