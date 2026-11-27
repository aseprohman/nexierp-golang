// Package types — kontrak kawat fitur WILAYAH + WILAYAH ADMIN + CLUSTER +
// AGAMA modul core (padanan packages/schemas core/wilayah.ts, cluster.ts,
// agama.ts NestJS): view JSON camelCase PERSIS controller, DTO tulis hasil
// validasi zod-ekuivalen (di handler), registri kode error WLY.
package types

import (
	"encoding/json"
	"regexp"
)

// Kode error modul wilayah (KODE_ERROR_WLY — problem+json `code`).
const (
	// WLY-001 (422): param/body/query tidak sah — termasuk prefix kode anak
	// ≠ kode induk.
	WLYParamTidakSah = "WLY-001"
	// WLY-002 (409): optimistic locking — version kirim ≠ version server.
	WLYVersiBentrok = "WLY-002"
	// WLY-003 (409): masih dipakai child — soft delete ditolak.
	WLYTerpakai = "WLY-003"
	// WLY-004 (409): kode wilayah hidup sudah dipakai baris lain.
	WLYKodeDuplikat = "WLY-004"
	// WLY-005 (404): baris/induk tidak ditemukan atau ter-soft-delete.
	WLYTidakDitemukan = "WLY-005"
)

// KodePosRE — kode pos Pos Indonesia: tepat 5 digit angka (padanan
// KODE_POS_RE wilayah-types.ts).
var KodePosRE = regexp.MustCompile(`^\d{5}$`)

// Jenis kota/kabupaten — cermin ck_core_kota_jenis (ddl/42).
const (
	JenisKota      = "KOTA"
	JenisKabupaten = "KABUPATEN"
)

// ---------------------------------------------------------------------
// VIEW lookup wilayah (kunci CERMIN respons controller /system/wilayah)
// ---------------------------------------------------------------------

// WilayahProvinsiView — {id, kode, nama, version}.
type WilayahProvinsiView struct {
	ID      int64  `json:"id"`
	Kode    string `json:"kode"`
	Nama    string `json:"nama"`
	Version int32  `json:"version"`
}

// WilayahKotaView — kota/kabupaten + nama provinsi induk.
type WilayahKotaView struct {
	ID             int64  `json:"id"`
	Kode           string `json:"kode"`
	Nama           string `json:"nama"`
	Jenis          string `json:"jenis"`
	IDCoreProvinsi int64  `json:"idCoreProvinsi"`
	ProvinsiNama   string `json:"provinsiNama"`
	Version        int32  `json:"version"`
}

// WilayahKecamatanView — kecamatan + nama kota induk.
type WilayahKecamatanView struct {
	ID         int64  `json:"id"`
	Kode       string `json:"kode"`
	Nama       string `json:"nama"`
	IDCoreKota int64  `json:"idCoreKota"`
	KotaNama   string `json:"kotaNama"`
	Version    int32  `json:"version"`
}

// WilayahKelurahanView — kelurahan/desa + kode pos (NULL = belum tercantum
// di sumber resmi) + nama kecamatan induk.
type WilayahKelurahanView struct {
	ID              int64   `json:"id"`
	Kode            string  `json:"kode"`
	Nama            string  `json:"nama"`
	KodePos         *string `json:"kodePos"`
	IDCoreKecamatan int64   `json:"idCoreKecamatan"`
	KecamatanNama   string  `json:"kecamatanNama"`
	Version         int32   `json:"version"`
}

// WilayahKelurahanLengkapView — rantai lengkap (kecamatan/kota/provinsi —
// nama & kode) — bahan alamat member & payload ongkir SHP (M55).
type WilayahKelurahanLengkapView struct {
	WilayahKelurahanView
	KodeKecamatan string `json:"kodeKecamatan"`
	KodeKota      string `json:"kodeKota"`
	KodeProvinsi  string `json:"kodeProvinsi"`
	KotaNama      string `json:"kotaNama"`
	ProvinsiNama  string `json:"provinsiNama"`
}

// OkTrue — respons delete seragam wilayah_admin `{ ok: true }` (okTrueSchema).
type OkTrue struct {
	Ok bool `json:"ok"`
}

// ---------------------------------------------------------------------
// DTO tulis wilayah_admin — hasil validasi zod-ekuivalen di handler.
// Pointer = field DIKIRIM (ubah PATCH); nil = tidak dikirim (pertahankan).
// ---------------------------------------------------------------------

// WilayahProvinsiBuat — POST /system/wilayah/provinsi.
type WilayahProvinsiBuat struct {
	Kode string
	Nama string
}

// WilayahKotaBuat — POST /system/wilayah/kota.
type WilayahKotaBuat struct {
	Kode           string
	Nama           string
	Jenis          string
	IDCoreProvinsi int64
}

// WilayahKecamatanBuat — POST /system/wilayah/kecamatan.
type WilayahKecamatanBuat struct {
	Kode       string
	Nama       string
	IDCoreKota int64
}

// WilayahKelurahanBuat — POST /system/wilayah/kelurahan (KodePos nil = NULL).
type WilayahKelurahanBuat struct {
	Kode            string
	Nama            string
	KodePos         *string
	IDCoreKecamatan int64
}

// WilayahProvinsiUbah — PATCH provinsi; version WAJIB (WLY-002).
type WilayahProvinsiUbah struct {
	Kode    *string
	Nama    *string
	Version int64
}

// WilayahKotaUbah — PATCH kota; version WAJIB.
type WilayahKotaUbah struct {
	Kode           *string
	Nama           *string
	Jenis          *string
	IDCoreProvinsi *int64
	Version        int64
}

// WilayahKecamatanUbah — PATCH kecamatan; version WAJIB.
type WilayahKecamatanUbah struct {
	Kode       *string
	Nama       *string
	IDCoreKota *int64
	Version    int64
}

// WilayahKelurahanUbah — PATCH kelurahan; version WAJIB.
// kodePos tri-state: `""` dinormalisasi tidak dikirim (pertahankan); null =
// KodePosNull (hapus kode pos); string = ganti (regex 5 digit).
type WilayahKelurahanUbah struct {
	Kode            *string
	Nama            *string
	KodePos         *string
	KodePosNull     bool
	IDCoreKecamatan *int64
	Version         int64
}

// WilayahHapus — body DELETE wilayah_admin (soft delete — version WAJIB).
type WilayahHapus struct {
	Version int64
}

// ---------------------------------------------------------------------
// VIEW + DTO cluster (core/cluster.ts)
// ---------------------------------------------------------------------

// CoreClusterView — view cluster (list & dasar detail); waktu ISO-8601.
type CoreClusterView struct {
	ID          int64   `json:"id"`
	EntityID    string  `json:"entityId"`
	Code        string  `json:"code"`
	Nama        string  `json:"nama"`
	Deskripsi   *string `json:"deskripsi"`
	Icon        *string `json:"icon"`
	Tone        *string `json:"tone"`
	Urutan      int32   `json:"urutan"`
	Status      string  `json:"status"`
	Version     int32   `json:"version"`
	CreatedAt   string  `json:"createdAt"`
	UpdatedAt   string  `json:"updatedAt"`
	JumlahModul int32   `json:"jumlahModul"`
}

// CoreClusterModulView — 1 baris core_cluster_modules hidup + fiturIds.
type CoreClusterModulView struct {
	ID            int64   `json:"id"`
	IDCoreModules int64   `json:"idCoreModules"`
	Key           string  `json:"key"`
	Name          string  `json:"name"`
	Tagline       string  `json:"tagline"`
	Enabled       bool    `json:"enabled"`
	FiturIDs      []int64 `json:"fiturIds"`
}

// CoreClusterDetail — view + daftar modul ter-assign beserta fiturnya.
type CoreClusterDetail struct {
	CoreClusterView
	Modul []CoreClusterModulView `json:"modul"`
}

// CoreClusterModulFitur — opsi fitur aktif satu modul (katalog UI assign).
type CoreClusterModulFitur struct {
	ID             int64           `json:"id"`
	FeaturesFolder string          `json:"featuresFolder"`
	Description    json.RawMessage `json:"description"`
}

// CoreClusterModulOption — opsi modul untuk UI assign cluster.
type CoreClusterModulOption struct {
	ID      int64                   `json:"id"`
	Key     string                  `json:"key"`
	Name    string                  `json:"name"`
	Tagline string                  `json:"tagline"`
	Enabled bool                    `json:"enabled"`
	Fitur   []CoreClusterModulFitur `json:"fitur"`
}

// ClusterBuat — POST /system/cluster (urutan default 0, status default AKTIF
// sudah diterapkan handler sesuai zod).
type ClusterBuat struct {
	Code      string
	Nama      string
	Deskripsi *string // nil = NULL (nullish)
	Icon      *string
	Tone      *string
	Urutan    int32
	Status    string
}

// ClusterUbah — PATCH cluster; version WAJIB di body (If-Match menang bila
// ada). Deskripsi/Icon/Tone tri-state (absen = pertahankan; null = NULL).
type ClusterUbah struct {
	Code          *string
	Nama          *string
	Deskripsi     *string
	DeskripsiNull bool
	Icon          *string
	IconNull      bool
	Tone          *string
	ToneNull      bool
	Urutan        *int32
	Status        *string
	Version       int64
}

// ClusterSyncModul — PUT /system/cluster/:id/modul (modulIds = REPLACE set).
type ClusterSyncModul struct {
	ModulIDs []int64
}

// ClusterSyncFitur — PUT /system/cluster/modul/:idModulCluster/fitur.
type ClusterSyncFitur struct {
	FiturIDs []int64
}

// ClusterSyncFiturHasil — respons sync fitur ter-refresh.
type ClusterSyncFiturHasil struct {
	IDModulCluster int64   `json:"idModulCluster"`
	FiturIDs       []int64 `json:"fiturIds"`
}

// ClusterAgamaListQuery — hasil parse query list cluster/agama di handler
// (zod ekuivalen coreClusterListQuerySchema/coreAgamaListQuerySchema:
// default page 1 / limit 50, limit > 200 → 400; search max 120; status
// AKTIF|NONAKTIF; sort ^-?\w+$ whitelist).
type ClusterAgamaListQuery struct {
	Page     int32
	Limit    int32
	Search   *string
	Status   *string
	SortCol  string
	SortDesc bool
}

// ClusterHapusHasil — respons DELETE cluster `{ id }`.
type ClusterHapusHasil struct {
	ID int64 `json:"id"`
}

// ---------------------------------------------------------------------
// VIEW + DTO agama (core/agama.ts)
// ---------------------------------------------------------------------

// CoreAgamaView — view agama (list & dropdown).
type CoreAgamaView struct {
	ID        int64  `json:"id"`
	EntityID  string `json:"entityId"`
	Code      string `json:"code"`
	Nama      string `json:"nama"`
	Urutan    int32  `json:"urutan"`
	Status    string `json:"status"`
	Version   int32  `json:"version"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// AgamaBuat — POST /system/agama (urutan default 0, status default AKTIF).
type AgamaBuat struct {
	Code   string
	Nama   string
	Urutan int32
	Status string
}

// AgamaUbah — PATCH agama; version WAJIB di body (If-Match menang bila ada).
type AgamaUbah struct {
	Code    *string
	Nama    *string
	Urutan  *int32
	Status  *string
	Version int64
}
