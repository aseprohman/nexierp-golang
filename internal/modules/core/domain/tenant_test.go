// Test domain TENANTS — fungsi pure diuji tanpa DB (aturan bentuk 9,
// pesan verbatim, dedupe last-wins, snapshot kunci audit).
package domain

import (
	"reflect"
	"testing"

	"nexierp/internal/modules/core/types"
)

func TestTransisiStatus(t *testing.T) {
	kasus := []struct {
		aksi, dari string
		ke         string
		sah        bool
	}{
		{AksiSuspend, "AKTIF", "DITANGGUHKAN", true},
		{AksiSuspend, "PROVISI", "", false},      // PROVISI wajib reaktivasi dulu
		{AksiSuspend, "DITANGGUHKAN", "", false}, // sudah ditangguhkan
		{AksiSuspend, "DITUTUP", "", false},      // irreversibel
		{AksiReactivate, "PROVISI", "AKTIF", true},
		{AksiReactivate, "DITANGGUHKAN", "AKTIF", true},
		{AksiReactivate, "AKTIF", "", false},
		{AksiReactivate, "DITUTUP", "", false},
		{AksiClose, "AKTIF", "DITUTUP", true},
		{AksiClose, "DITANGGUHKAN", "DITUTUP", true},
		{AksiClose, "PROVISI", "", false},
		{AksiClose, "DITUTUP", "", false},
		{"aksi palsu", "AKTIF", "", false},
	}
	for _, k := range kasus {
		ke, sah := TransisiStatus(k.aksi, k.dari)
		if sah != k.sah || ke != k.ke {
			t.Fatalf("TransisiStatus(%q, %q) = (%q, %v); harapan (%q, %v)", k.aksi, k.dari, ke, sah, k.ke, k.sah)
		}
	}
}

func TestAksiEvent(t *testing.T) {
	if AksiEvent(AksiSuspend) != "SUSPEND" ||
		AksiEvent(AksiReactivate) != "REAKTIVASI" ||
		AksiEvent(AksiClose) != "TUTUP" {
		t.Fatal("pemetaan AKSI_EVENT tidak verbatim")
	}
	if AksiEvent("tak-dikenal") != "" {
		t.Fatal("aksi tak dikenal harus kosong")
	}
}

// Pesan verbatim service NestJS — satu string pun tidak boleh geser.
func TestPesanTransisiVerbatim(t *testing.T) {
	kasus := []struct {
		aksi, status, pesan string
	}{
		{AksiClose, "DITUTUP", "Tenant sudah DITUTUP — penutupan bersifat irreversibel."},
		{AksiClose, "PROVISI", "Tenant masih PROVISI — lakukan reaktivasi (aktifkan) lebih dulu sebelum penutupan."},
		{AksiSuspend, "DITANGGUHKAN", "Tenant sudah DITANGGUHKAN — tidak ada yang perlu ditangguhkan lagi."},
		{AksiSuspend, "DITUTUP", "Tenant sudah DITUTUP — status tidak bisa diubah lagi."},
		{AksiReactivate, "AKTIF", "Tenant sudah AKTIF — reaktivasi tidak diperlukan."},
		{AksiReactivate, "DITUTUP", "Tenant sudah DITUTUP — penutupan irreversibel, tidak bisa diaktifkan kembali."},
		{AksiReactivate, "PROVISI", "Transisi 'reactivate' tidak sah dari status PROVISI."}, // fallback — PROVISI→AKTIF sah, ini hanya cek format fallback
	}
	for _, k := range kasus {
		if got := PesanTransisi(k.aksi, k.status); got != k.pesan {
			t.Fatalf("PesanTransisi(%q, %q) = %q; harapan %q", k.aksi, k.status, got, k.pesan)
		}
	}
}

func TestSnapshotTenant(t *testing.T) {
	kuota := int32(25)
	email := "ops@pt.id"
	s := SnapshotTenant(TenantSnapshot{
		Kode: "pt-maju", Nama: "PT Maju", PaketTier: "PS2", Status: "AKTIF",
		MaxUsers: &kuota, KontakEmail: &email, Version: 7,
	})
	harapan := map[string]any{
		"kode": "pt-maju", "nama": "PT Maju", "paket_tier": "PS2", "status": "AKTIF",
		"max_users": &kuota, "max_lokasi": (*int32)(nil),
		"kontak_email": &email, "kontak_telepon": (*string)(nil),
		"version": int32(7),
	}
	if !reflect.DeepEqual(s, harapan) {
		t.Fatalf("snapshot = %#v; harapan %#v", s, harapan)
	}
}

func TestDedupeEntriSettingsLastWins(t *testing.T) {
	out := DedupeEntriSettings([]types.TenantSettingEntri{
		{Kunci: "b", Nilai: 1},
		{Kunci: "a", Nilai: "lama"},
		{Kunci: "b", Nilai: 2}, // duplikat — nilai terakhir menang, posisi pertama
		{Kunci: "c", Nilai: nil},
	})
	if len(out) != 3 {
		t.Fatalf("panjang hasil = %d; harapan 3", len(out))
	}
	if out[0].Kunci != "b" || out[0].Nilai != 2 {
		t.Fatalf("entri pertama = %+v; harapan kunci b nilai 2 (posisi pertama, nilai terakhir)", out[0])
	}
	if out[1].Kunci != "a" || out[1].Nilai != "lama" {
		t.Fatalf("entri kedua = %+v; harapan a=lama", out[1])
	}
	if out[2].Kunci != "c" || out[2].Nilai != nil {
		t.Fatalf("entri ketiga = %+v; harapan c=nil", out[2])
	}
}

func TestDedupeEntriSettingsKosong(t *testing.T) {
	if got := DedupeEntriSettings(nil); len(got) != 0 {
		t.Fatalf("dedupe nil = %#v; harapan kosong", got)
	}
}
