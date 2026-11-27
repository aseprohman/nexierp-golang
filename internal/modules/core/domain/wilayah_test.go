package domain

import (
	"testing"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/types"
)

// uji guard murni wilayah — pesan & kode error VERBATIM WilayahAdminService
// NestJS (tolakPrefixAnak/errVersi/errDuplikat/tolakKodeDipakaiChild/child
// hidup/tidak ditemukan).
func TestTolakPrefixAnak(t *testing.T) {
	if err := TolakPrefixAnak("Kota", "1101", "provinsi", "11"); err != nil {
		t.Fatalf("prefix cocok tidak boleh ditolak: %v", err)
	}
	err := TolakPrefixAnak("Kota", "3201", "provinsi", "11")
	if err == nil {
		t.Fatal("prefix beda wajib ditolak")
	}
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 422 || de.Code != types.WLYParamTidakSah {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Kode kota '3201' harus diawali kode provinsi induk '11' (WLY-001)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestVersiBentrokDanErrVersi(t *testing.T) {
	if err := VersiBentrok("Provinsi", "11", 3, 3); err != nil {
		t.Fatalf("versi cocok tidak boleh ditolak: %v", err)
	}
	err := VersiBentrok("Provinsi", "11", 3, 2)
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 409 || de.Code != types.WLYVersiBentrok {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Versi provinsi '11' tidak cocok (server 3, kirim 2) — muat ulang lalu ulangi (WLY-002)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}

	// bentuk tanpa "kirim" (race update/soft-delete).
	kirim := int64(9)
	err = ErrVersi("Kelurahan", "1101012001", 4, &kirim)
	de, _ = errkontrak.AsDomain(err)
	want = "Versi kelurahan '1101012001' tidak cocok (server 4, kirim 9) — muat ulang lalu ulangi (WLY-002)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestTolakKodeDipakaiChild(t *testing.T) {
	err := TolakKodeDipakaiChild("Provinsi", "11", 3, "kota")
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 422 || de.Code != types.WLYParamTidakSah {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Kode provinsi '11' dipakai 3 kota — ubah child lebih dulu (WLY-001)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestErrChildHidup(t *testing.T) {
	err := ErrChildHidup("Provinsi", "Aceh", 5, "kota")
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 409 || de.Code != types.WLYTerpakai {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Provinsi 'Aceh' masih punya 5 kota — hapus child lebih dulu (WLY-003)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestErrDuplikat(t *testing.T) {
	err := ErrDuplikat("Kecamatan", "110101")
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 409 || de.Code != types.WLYKodeDuplikat {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Kode kecamatan '110101' sudah dipakai baris hidup lain (WLY-004)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestErrTidakDitemukan(t *testing.T) {
	err := ErrTidakDitemukan("Kota", 42)
	de, ok := errkontrak.AsDomain(err)
	if !ok {
		t.Fatalf("bukan DomainError: %v", err)
	}
	if de.Status != 404 || de.Code != types.WLYTidakDitemukan {
		t.Fatalf("status/kode salah: %d %s", de.Status, de.Code)
	}
	want := "Kota id 42 tidak ditemukan (WLY-005)."
	if de.Detail != want {
		t.Fatalf("detail:\n got: %s\nwant: %s", de.Detail, want)
	}
}

func TestGuardBukanErrorLain(t *testing.T) {
	// semua guard menghasilkan *errkontrak.DomainError — bukan error generik.
	var errs []error
	errs = append(errs,
		TolakPrefixAnak("Kota", "9999", "provinsi", "11"),
		VersiBentrok("Kota", "1101", 1, 2),
		TolakKodeDipakaiChild("Kota", "1101", 1, "kecamatan"),
		ErrChildHidup("Kota", "Jakarta", 1, "kecamatan"),
		ErrDuplikat("Kota", "1101"),
		ErrTidakDitemukan("Kota", 1),
	)
	for i, err := range errs {
		if err == nil {
			t.Fatalf("guard %d harus error DomainError, dapat nil", i)
		}
		if _, ok := errkontrak.AsDomain(err); !ok {
			t.Fatalf("guard %d bukan *DomainError: %T", i, err)
		}
	}
}
