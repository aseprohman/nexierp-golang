package domain

import (
	"testing"

	"nexierp/internal/core/errkontrak"
)

// TestSusunKunciKombinasi — padanan kasus D-19 (WARNA:Merah|UKURAN:XL).
func TestSusunKunciKombinasi(t *testing.T) {
	kasus := []struct {
		nama  string
		input [][2]string
		harap string
	}{
		{
			nama:  "urut kode asc lalu nilai",
			input: [][2]string{{"ukuran", "XL"}, {"warna", "Merah"}},
			harap: "UKURAN:XL|WARNA:Merah",
		},
		{
			nama:  "kode sama → nilai localeCompare",
			input: [][2]string{{"warna", "Putih"}, {"Warna", "Hitam"}},
			harap: "WARNA:Hitam|WARNA:Putih",
		},
		{
			nama:  "trim spasi",
			input: [][2]string{{" warna ", " Merah "}},
			harap: "WARNA:Merah",
		},
		{
			nama:  "kosong",
			input: [][2]string{},
			harap: "",
		},
		{
			nama:  "satu pasangan",
			input: [][2]string{{"Ukuran", "S"}},
			harap: "UKURAN:S",
		},
	}
	for _, k := range kasus {
		t.Run(k.nama, func(t *testing.T) {
			got := SusunKunciKombinasi(k.input)
			if got != k.harap {
				t.Fatalf("SusunKunciKombinasi(%v) = %q, harap %q", k.input, got, k.harap)
			}
		})
	}
}

// TestBangunSkuVarian — padanan `${induk}-${nilaiTeks}` strip + slice 50.
func TestBangunSkuVarian(t *testing.T) {
	kasus := []struct {
		induk, nilai, harap string
	}{
		{"KMEJA", "MERAH-XL", "KMEJA-MERAH-XL"},
		{"K@MEJA", "ME/RAH XL", "KMEJA-MERAHXL"}, // karakter ilegal dibuang
		{"ABCDE", "12345678901234567890123456789012345678901234567890", "ABCDE-12345678901234567890123456789012345678901234"}, // potong 50
	}
	for _, k := range kasus {
		got := BangunSkuVarian(k.induk, k.nilai)
		if got != k.harap {
			t.Fatalf("BangunSkuVarian(%q,%q) = %q, harap %q", k.induk, k.nilai, got, k.harap)
		}
		if len(got) > 50 {
			t.Fatalf("SKU varian melebihi 50: %q", got)
		}
	}
}

// TestBangunNilaiTeksVarian — join "-" + uppercase.
func TestBangunNilaiTeksVarian(t *testing.T) {
	if got := BangunNilaiTeksVarian([]string{"merah", "xl"}); got != "MERAH-XL" {
		t.Fatalf("got %q", got)
	}
}

// TestValidasiVarianEntry — pesan verbatim produk.service.ts (400 tanpa kode).
func TestValidasiVarianEntry(t *testing.T) {
	konfig := []KonfigAtribut{
		{IDInvAtribut: 1, KodeAtribut: "WARNA", Wajib: true},
		{IDInvAtribut: 2, KodeAtribut: "UKURAN", Wajib: false},
	}
	nilai := []NilaiAtribut{
		{ID: 10, IDInvAtribut: 1, Nilai: "Merah"},
		{ID: 11, IDInvAtribut: 1, Nilai: "Putih"},
		{ID: 20, IDInvAtribut: 2, Nilai: "XL"},
		{ID: 30, IDInvAtribut: 3, Nilai: "Lain"}, // pasangan cocok, tapi atribut 3 di luar konfigurasi
	}

	t.Run("lulus + kunci kanonik", func(t *testing.T) {
		h, err := ValidasiVarianEntry([]PasanganVarian{
			{IDInvAtribut: 2, IDInvNilaiAtribut: 20},
			{IDInvAtribut: 1, IDInvNilaiAtribut: 10},
		}, konfig, nilai)
		if err != nil {
			t.Fatalf("err %v", err)
		}
		if h.KunciKombinasi != "UKURAN:XL|WARNA:Merah" {
			t.Fatalf("kunci %q", h.KunciKombinasi)
		}
		if len(h.PasanganNilai) != 2 || h.PasanganNilai[0] != 20 || h.PasanganNilai[1] != 10 {
			t.Fatalf("pasanganNilai %v", h.PasanganNilai)
		}
	})

	t.Run("pasangan tidak cocok", func(t *testing.T) {
		_, err := ValidasiVarianEntry([]PasanganVarian{{IDInvAtribut: 2, IDInvNilaiAtribut: 10}}, konfig, nilai)
		harap := "Pasangan atribut/nilai tidak cocok atau tidak ditemukan (atribut 2)."
		if err == nil || err.Error() != harap {
			t.Fatalf("err %v, harap %q", err, harap)
		}
		if de, ok := errkontrak.AsDomain(err); !ok || de.Status != 400 || de.Code != "VAL-400" {
			t.Fatalf("kontrak salah: %+v", de)
		}
	})

	t.Run("atribut bukan konfigurasi induk", func(t *testing.T) {
		_, err := ValidasiVarianEntry([]PasanganVarian{{IDInvAtribut: 3, IDInvNilaiAtribut: 30}}, konfig, nilai)
		harap := "Atribut 3 bukan bagian konfigurasi induk ini."
		if err == nil || err.Error() != harap {
			t.Fatalf("err %v, harap %q", err, harap)
		}
	})

	t.Run("duplikat atribut", func(t *testing.T) {
		_, err := ValidasiVarianEntry([]PasanganVarian{
			{IDInvAtribut: 1, IDInvNilaiAtribut: 10},
			{IDInvAtribut: 1, IDInvNilaiAtribut: 11},
		}, konfig, nilai)
		harap := "Satu varian hanya boleh membawa satu nilai per atribut."
		if err == nil || err.Error() != harap {
			t.Fatalf("err %v, harap %q", err, harap)
		}
	})

	t.Run("wajib kurang", func(t *testing.T) {
		_, err := ValidasiVarianEntry([]PasanganVarian{{IDInvAtribut: 2, IDInvNilaiAtribut: 20}}, konfig, nilai)
		harap := "Atribut wajib induk belum semua punya nilai (atribut 1)."
		if err == nil || err.Error() != harap {
			t.Fatalf("err %v, harap %q", err, harap)
		}
	})
}

// TestValidasiKombinasiGenerate — pesan & kode PERSIS generateVarian
// (400/409 INV-016).
func TestValidasiKombinasiGenerate(t *testing.T) {
	konfig := []KonfigAtribut{
		{IDInvAtribut: 1, KodeAtribut: "WARNA", Wajib: true},
		{IDInvAtribut: 99, KodeAtribut: "", Wajib: false}, // kode kosong → fallback String(id)
	}
	nilai := []NilaiAtribut{
		{ID: 10, IDInvAtribut: 1, Nilai: "Merah"},
	}

	t.Run("lulus + fallback kode id", func(t *testing.T) {
		h, err := ValidasiKombinasiGenerate([]PasanganVarian{
			{IDInvAtribut: 99, IDInvNilaiAtribut: 10}, // pasangan ini tidak cocok nilai 10 (atribut 1)…
		}, konfig, nilai)
		// nilai 10 milik atribut 1, bukan 99 → harus gagal pasangan.
		if err == nil {
			t.Fatalf("harusnya gagal pasangan, dapat %+v", h)
		}

		h, err = ValidasiKombinasiGenerate([]PasanganVarian{{IDInvAtribut: 1, IDInvNilaiAtribut: 10}}, konfig, nilai)
		if err != nil {
			t.Fatalf("err %v", err)
		}
		if h.KunciKombinasi != "WARNA:Merah" {
			t.Fatalf("kunci %q", h.KunciKombinasi)
		}
	})

	t.Run("pasangan tidak cocok = 400 INV-016", func(t *testing.T) {
		_, err := ValidasiKombinasiGenerate([]PasanganVarian{{IDInvAtribut: 99, IDInvNilaiAtribut: 10}}, konfig, nilai)
		de, ok := errkontrak.AsDomain(err)
		if !ok || de.Status != 400 || de.Code != "INV-016" {
			t.Fatalf("de %+v", de)
		}
		if de.Detail != "Pasangan atribut/nilai tidak cocok atau tidak ditemukan (INV-016)." {
			t.Fatalf("detail %q", de.Detail)
		}
	})

	t.Run("duplikat atribut = 409 INV-016", func(t *testing.T) {
		_, err := ValidasiKombinasiGenerate([]PasanganVarian{
			{IDInvAtribut: 1, IDInvNilaiAtribut: 10},
			{IDInvAtribut: 1, IDInvNilaiAtribut: 10},
		}, konfig, nilai)
		de, ok := errkontrak.AsDomain(err)
		if !ok || de.Status != 409 || de.Code != "INV-016" {
			t.Fatalf("de %+v", de)
		}
		if de.Detail != "Satu kombinasi hanya boleh memuat satu nilai per atribut (INV-016)." {
			t.Fatalf("detail %q", de.Detail)
		}
	})

	t.Run("kelengkapan = 409 INV-016", func(t *testing.T) {
		_, err := ValidasiKombinasiGenerate([]PasanganVarian{}, konfig, nilai)
		de, ok := errkontrak.AsDomain(err)
		if !ok || de.Status != 409 || de.Code != "INV-016" {
			t.Fatalf("de %+v", de)
		}
		if de.Detail != "Kombinasi tidak lengkap — atribut wajib induk belum semua punya nilai (INV-016)." {
			t.Fatalf("detail %q", de.Detail)
		}
	})
}
