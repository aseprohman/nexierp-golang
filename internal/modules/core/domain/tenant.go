// Package domain — aturan PURE fitur TENANTS modul core: transisi siklus
// hidup tenant, kosakata event, pesan 409 transisi, snapshot audit, dan
// dedupe kunci settings. TANPA echo/pgx/DB — input parameter, hasil return
// (uji tanpa DB). Port VERBATIM types/tenants-types.ts + pesanTransisi/
// snapshotTenant/dedupe di system-tenants.service.ts NestJS.
package domain

import (
	"fmt"

	"nexierp/internal/modules/core/types"
)

/* ------------------------------------------------------------------ */
/* Konstanta siklus hidup tenant (aturan bentuk 9 — verbatim)          */
/* ------------------------------------------------------------------ */

// Aksi siklus hidup yang sah (suspend/reactivate/close).
const (
	AksiSuspend    = "suspend"
	AksiReactivate = "reactivate"
	AksiClose      = "close"
)

// transisiStatus — Transisi status sah: dari → ke (sisanya 409).
// PROVISI TIDAK bisa langsung suspend/close — wajib reaktivasi dulu.
var transisiStatus = map[string]map[string]string{
	AksiSuspend:    {"AKTIF": "DITANGGUHKAN"},
	AksiReactivate: {"PROVISI": "AKTIF", "DITANGGUHKAN": "AKTIF"},
	AksiClose:      {"AKTIF": "DITUTUP", "DITANGGUHKAN": "DITUTUP"},
}

// aksiEvent — Nama event core_tenant_events per aksi siklus hidup.
var aksiEvent = map[string]string{
	AksiSuspend:    "SUSPEND",
	AksiReactivate: "REAKTIVASI",
	AksiClose:      "TUTUP",
}

// TransisiStatus — status tujuan bila transisi (aksi, status) sah; ok=false
// → 409 dengan pesan PesanTransisi.
func TransisiStatus(aksi, status string) (string, bool) {
	if m, ada := transisiStatus[aksi]; ada {
		if ke, sah := m[status]; sah {
			return ke, true
		}
	}
	return "", false
}

// AksiEvent — nama event core_tenant_events untuk aksi siklus hidup
// (aksi terjamin valid dari handler; aksi asing → "").
func AksiEvent(aksi string) string { return aksiEvent[aksi] }

/* ------------------------------------------------------------------ */
/* Pesan 409 transisi ilegal — jelas dan menyebut status sekarang      */
/* ------------------------------------------------------------------ */

// PesanTransisi — pesan 409 VERBATIM pesanTransisi service NestJS.
func PesanTransisi(aksi, status string) string {
	if aksi == AksiClose {
		if status == types.TenantDitutup {
			return "Tenant sudah DITUTUP — penutupan bersifat irreversibel."
		}
		if status == types.TenantProvisi {
			return "Tenant masih PROVISI — lakukan reaktivasi (aktifkan) lebih dulu sebelum penutupan."
		}
	}
	if aksi == AksiSuspend && status == types.TenantDitangguhkan {
		return "Tenant sudah DITANGGUHKAN — tidak ada yang perlu ditangguhkan lagi."
	}
	if aksi == AksiSuspend && status == types.TenantDitutup {
		return "Tenant sudah DITUTUP — status tidak bisa diubah lagi."
	}
	if aksi == AksiReactivate && status == types.TenantAktif {
		return "Tenant sudah AKTIF — reaktivasi tidak diperlukan."
	}
	if aksi == AksiReactivate && status == types.TenantDitutup {
		return "Tenant sudah DITUTUP — penutupan irreversibel, tidak bisa diaktifkan kembali."
	}
	return fmt.Sprintf("Transisi '%s' tidak sah dari status %s.", aksi, status)
}

/* ------------------------------------------------------------------ */
/* Snapshot audit (before/after) — ringkasan tenant                    */
/* ------------------------------------------------------------------ */

// TenantSnapshot — nilai baris core_tenants yang masuk snapshot audit.
type TenantSnapshot struct {
	Kode          string
	Nama          string
	PaketTier     string
	Status        string
	MaxUsers      *int32
	MaxLokasi     *int32
	KontakEmail   *string
	KontakTelepon *string
	Version       int32
}

// SnapshotTenant — ringkasan tenant utk audit before/after (kunci snake_case
// VERBATIM snapshotTenant service NestJS).
func SnapshotTenant(s TenantSnapshot) map[string]any {
	return map[string]any{
		"kode":           s.Kode,
		"nama":           s.Nama,
		"paket_tier":     s.PaketTier,
		"status":         s.Status,
		"max_users":      s.MaxUsers,
		"max_lokasi":     s.MaxLokasi,
		"kontak_email":   s.KontakEmail,
		"kontak_telepon": s.KontakTelepon,
		"version":        s.Version,
	}
}

/* ------------------------------------------------------------------ */
/* Dedupe entri settings — kunci duplikat: nilai TERAKHIR menang       */
/* ------------------------------------------------------------------ */

// DedupeEntriSettings — padanan dedupe `new Map()` service NestJS: posisi
// kunci = kemunculan PERTAMA, nilai = kemunculan TERAKHIR (idempoten).
func DedupeEntriSettings(entri []types.TenantSettingEntri) []types.TenantSettingEntri {
	urutan := make([]string, 0, len(entri))
	nilai := make(map[string]any, len(entri))
	for _, e := range entri {
		if _, ada := nilai[e.Kunci]; !ada {
			urutan = append(urutan, e.Kunci)
		}
		nilai[e.Kunci] = e.Nilai
	}
	out := make([]types.TenantSettingEntri, 0, len(urutan))
	for _, k := range urutan {
		out = append(out, types.TenantSettingEntri{Kunci: k, Nilai: nilai[k]})
	}
	return out
}
