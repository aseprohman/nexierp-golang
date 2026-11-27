// Package types — kontrak fitur TENANTS modul core (area system,
// ddl/22-core-tenants): bentuk JSON view + input request padanan zod
// packages/schemas/src/core/tenants.ts + types/tenants-types.ts NestJS.
// TANPA framework — penanda validasi & pesan zod hidup di handler.
package types

// Kosakata enum core_tenants (persis DDL enum_paket_tier / enum_status_tenant).
const (
	TenantProvisi      = "PROVISI"
	TenantAktif        = "AKTIF"
	TenantDitangguhkan = "DITANGGUHKAN"
	TenantDitutup      = "DITUTUP"

	TierPS1 = "PS1"
	TierPS2 = "PS2"
	TierPS3 = "PS3"
)

// StatusTenantValid / PaketTierValid — anggota enum utk validasi handler.
var StatusTenantValid = []string{TenantProvisi, TenantAktif, TenantDitangguhkan, TenantDitutup}
var PaketTierValid = []string{TierPS1, TierPS2, TierPS3}

// Aksi siklus hidup yang sah (suspend/reactivate/close).
const (
	AksiSuspend    = "suspend"
	AksiReactivate = "reactivate"
	AksiClose      = "close"
)

/* ------------------------------------------------------------------ */
/* View (bentuk JSON PERSIS zod — waktu ISO-8601, null tetap null)     */
/* ------------------------------------------------------------------ */

// TenantView — padanan tenantViewSchema.
type TenantView struct {
	ID            int64   `json:"id"`
	EntityID      string  `json:"entityId"`
	Kode          string  `json:"kode"`
	Nama          string  `json:"nama"`
	PaketTier     string  `json:"paketTier"`
	Status        string  `json:"status"`
	MaxUsers      *int32  `json:"maxUsers"`
	MaxLokasi     *int32  `json:"maxLokasi"`
	KontakEmail   *string `json:"kontakEmail"`
	KontakTelepon *string `json:"kontakTelepon"`
	VersiSkema    int32   `json:"versiSkema"`
	Version       int32   `json:"version"`
	CreatedAt     string  `json:"createdAt"`
	UpdatedAt     string  `json:"updatedAt"`
	DeletedAt     *string `json:"deletedAt"`
}

// TenantMemberView — padanan tenantMemberViewSchema.
type TenantMemberView struct {
	IDCoreUsers int64   `json:"idCoreUsers"`
	Username    string  `json:"username"`
	Nama        string  `json:"nama"`
	IsDefault   bool    `json:"isDefault"`
	DicabutPada *string `json:"dicabutPada"`
}

// TenantEventView — padanan tenantEventViewSchema (payload jsonb apa adanya).
type TenantEventView struct {
	ID        int64   `json:"id"`
	Aksi      string  `json:"aksi"`
	Payload   any     `json:"payload"`
	Aktor     *string `json:"aktor"`
	CreatedAt string  `json:"createdAt"`
}

// TenantModuleRow — padanan tenantModuleRowSchema (katalog + flag aktif).
type TenantModuleRow struct {
	ID    int64  `json:"id"`
	Key   string `json:"key"`
	Nama  string `json:"nama"`
	Aktif bool   `json:"aktif"`
}

// TenantFeatureRow — padanan tenantFeatureRowSchema.
type TenantFeatureRow struct {
	ID        int64  `json:"id"`
	ModuleKey string `json:"moduleKey"`
	Key       string `json:"key"`
	Nama      string `json:"nama"`
	Aktif     bool   `json:"aktif"`
}

// TenantSettingRow — padanan tenantSettingRowSchema; `nilai` jsonb WAJIB ada
// (kolom NOT NULL default {}).
type TenantSettingRow struct {
	Kategori string `json:"kategori"`
	Kunci    string `json:"kunci"`
	Nilai    any    `json:"nilai"`
}

// TenantContextRow — baris konteks tenant user (switcher FE, GET /context).
type TenantContextRow struct {
	IDTenant  int64  `json:"idTenant"`
	Kode      string `json:"kode"`
	Nama      string `json:"nama"`
	Status    string `json:"status"`
	IsDefault bool   `json:"isDefault"`
}

// TenantList — envelope `{ rows, total }` GET /system/tenants (BUKAN Page).
type TenantList struct {
	Rows  []TenantView `json:"rows"`
	Total int64        `json:"total"`
}

/* ------------------------------------------------------------------ */
/* Input request — hasil validasi zod-parity di handler                */
/* ------------------------------------------------------------------ */

// TenantCreateInput — padanan tenantCreateSchema (setelah trim + default PS2).
type TenantCreateInput struct {
	Kode          string
	Nama          string
	PaketTier     string  // default "PS2" diterapkan validasi
	MaxUsers      *int32  // nullish → nil = NULL
	MaxLokasi     *int32  // nullish → nil = NULL
	KontakEmail   *string // nullish → nil = NULL
	KontakTelepon *string // nullish → nil = NULL
}

// TenantUpdateInput — padanan tenantUpdateSchema (partial + version WAJIB).
// Nilai opsional pakai pasangan *T + Ada bool: absen vs eksplisit-null berbeda
// makna (absen = pertahankan lama; null = kosongkan kolom).
type TenantUpdateInput struct {
	Kode      *string // nil = tidak dikirim
	Nama      *string // nil = tidak dikirim
	PaketTier string  // "" = tidak dikirim (enum tak pernah kosong)

	MaxUsers         *int32
	MaxUsersAda      bool
	MaxLokasi        *int32
	MaxLokasiAda     bool
	KontakEmail      *string
	KontakEmailAda   bool
	KontakTelepon    *string
	KontakTeleponAda bool

	Version int64 // WAJIB di body (zod tanpa .optional())
}

// TenantTierSetInput — padanan tenantTierSetSchema `{ paketTier, version? }`.
type TenantTierSetInput struct {
	PaketTier string
	Version   *int64 // opsional — fallback If-Match
}

// TenantAksiInput — padanan tenantAksiSchema `{ alasan? }`.
type TenantAksiInput struct {
	Alasan *string // nullish → nil
}

// TenantMembersAddInput — padanan tenantMembersAddSchema.
type TenantMembersAddInput struct {
	IDCoreUsers int64
	IsDefault   bool // default false diterapkan validasi
}

// TenantModuleSetInput — padanan tenantModuleSetSchema (dedupe di service).
type TenantModuleSetInput struct {
	IDModules []int64
}

// TenantFeatureSetInput — padanan tenantFeatureSetSchema (dedupe di service).
type TenantFeatureSetInput struct {
	IDFeatures []int64
}

// TenantSettingEntri — item `entri` tenantSettingsSetSchema (nilai unknown).
type TenantSettingEntri struct {
	Kunci string
	Nilai any
}

// TenantSettingsSetInput — padanan tenantSettingsSetSchema.
type TenantSettingsSetInput struct {
	Kategori string
	Entri    []TenantSettingEntri
}

// TenantListQuery — padanan tenantListQuerySchema (hasil zod, nilai default
// page=1 limit=20 sudah diterapkan; Search nil = tidak dikirim; Status/Tier
// kosong = tidak difilter).
type TenantListQuery struct {
	Page   int64
	Limit  int64
	Search *string
	Status string
	Tier   string
}

// TenantSettingsQuery — padanan tenantSettingsQuerySchema (Kategori nil =
// tanpa filter; bila ada SUDAH di-trim).
type TenantSettingsQuery struct {
	Kategori *string
}
