// produk-rules.go — aturan MURNI fitur PRODUK/INDUK (padanan potongan murni
// produk.service.ts & produk-induk.service.ts NestJS): builder SKU varian
// (D-39) + validasi pasangan/kelengkapan kombinasi varian (D-38/D-39) dengan
// pesan VERBATIM. Potongan yang butuh DB (cari induk/konfigurasi/nilai,
// cek kombinasi sudah ada) tetap di service/repo — yang murni pindah ke sini.
package domain

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"nexierp/internal/core/errkontrak"
)

// KonfigAtribut — baris konfigurasi atribut induk (ringkas, murni).
type KonfigAtribut struct {
	IDInvAtribut int64
	KodeAtribut  string
	Wajib        bool
}

// NilaiAtribut — baris inv_nilai_atribut hidup (ringkas, murni).
type NilaiAtribut struct {
	ID           int64
	IDInvAtribut int64
	Nilai        string
}

// PasanganVarian — satu pasangan input varian (D-38).
type PasanganVarian struct {
	IDInvAtribut      int64
	IDInvNilaiAtribut int64
}

// HasilVarian — hasil validasi entry/kombinasi varian yang lulus.
type HasilVarian struct {
	PasanganKode   [][2]string // [kodeAtribut, nilai] — input SusunKunciKombinasi
	PasanganNilai  []int64     // id inv_nilai_atribut (junction inv_produk_atribut)
	KunciKombinasi string      // kunci kanonik D-19
}

// BangunNilaiTeksVarian — nilai varian gabungan `-` + UPPERCASE (padanan
// nilaiTeks generateVarian: `.join("-").toUpperCase()`).
func BangunNilaiTeksVarian(nilai []string) string {
	return strings.ToUpper(strings.Join(nilai, "-"))
}

// reSkuVarian — padanan regex `.replace(/[^A-Za-z0-9_.-]/g, "")` SKU varian.
var reSkuVarian = regexp.MustCompile(`[^A-Za-z0-9_.-]`)

// BangunSkuVarian — SKU varian = `${induk.kodeProduk}-${nilaiTeks}` yang
// dibersihkan dari karakter di luar [A-Za-z0-9_.-] lalu dipotong 50 karakter
// (padanan `.replace(...).slice(0, 50)` — karakter tersisa ASCII sehingga
// potongan byte = potongan karakter).
func BangunSkuVarian(indukKode, nilaiTeks string) string {
	gabung := indukKode + "-" + nilaiTeks
	bersih := reSkuVarian.ReplaceAllString(gabung, "")
	if len(bersih) > 50 {
		bersih = bersih[:50]
	}
	return bersih
}

// ValidasiVarianEntry — validasi MURNI entry varian langsung saat create
// produk (padanan produk.service.ts create, blok `if (input.varian)`,
// PESAN VERBATIM, semua 400 tanpa kode):
//   - "Pasangan atribut/nilai tidak cocok atau tidak ditemukan (atribut %d)."
//   - "Atribut %d bukan bagian konfigurasi induk ini."
//   - "Satu varian hanya boleh membawa satu nilai per atribut."
//   - "Atribut wajib induk belum semua punya nilai (atribut %s)."
func ValidasiVarianEntry(pasangan []PasanganVarian, konfig []KonfigAtribut, nilai []NilaiAtribut) (HasilVarian, error) {
	konfigByID := make(map[int64]KonfigAtribut, len(konfig))
	for _, k := range konfig {
		konfigByID[k.IDInvAtribut] = k
	}
	nilaiByID := make(map[int64]NilaiAtribut, len(nilai))
	for _, n := range nilai {
		nilaiByID[n.ID] = n
	}

	terpakai := make(map[int64]string)
	hasil := HasilVarian{PasanganNilai: []int64{}}
	for _, item := range pasangan {
		n, ada := nilaiByID[item.IDInvNilaiAtribut]
		if !ada || n.IDInvAtribut != item.IDInvAtribut {
			return HasilVarian{}, errkontrak.BadRequest(
				fmt.Sprintf("Pasangan atribut/nilai tidak cocok atau tidak ditemukan (atribut %d).", item.IDInvAtribut),
			)
		}
		konfig, ada := konfigByID[item.IDInvAtribut]
		if !ada {
			return HasilVarian{}, errkontrak.BadRequest(
				fmt.Sprintf("Atribut %d bukan bagian konfigurasi induk ini.", item.IDInvAtribut),
			)
		}
		if _, sudah := terpakai[item.IDInvAtribut]; sudah {
			return HasilVarian{}, errkontrak.BadRequest(
				"Satu varian hanya boleh membawa satu nilai per atribut.",
			)
		}
		terpakai[item.IDInvAtribut] = n.Nilai
		hasil.PasanganKode = append(hasil.PasanganKode, [2]string{konfig.KodeAtribut, n.Nilai})
		hasil.PasanganNilai = append(hasil.PasanganNilai, item.IDInvNilaiAtribut)
	}

	// kurang = wajibIds.filter(a => !terpakai.has(a)) — urutan ikut konfigurasi.
	var kurang []string
	for _, k := range konfig {
		if !k.Wajib {
			continue
		}
		if _, ada := terpakai[k.IDInvAtribut]; !ada {
			kurang = append(kurang, strconv.FormatInt(k.IDInvAtribut, 10))
		}
	}
	if len(kurang) > 0 {
		return HasilVarian{}, errkontrak.BadRequest(
			fmt.Sprintf("Atribut wajib induk belum semua punya nilai (atribut %s).", strings.Join(kurang, ", ")),
		)
	}

	hasil.KunciKombinasi = SusunKunciKombinasi(hasil.PasanganKode)
	return hasil, nil
}

// ValidasiKombinasiGenerate — validasi MURNI kombinasi generate varian
// (padanan produk-induk.service.ts generateVarian, PESAN & STATUS/KEDE PERSIS):
//   - 400 INV-016 "Pasangan atribut/nilai tidak cocok atau tidak ditemukan (INV-016)."
//   - 409 INV-016 "Satu kombinasi hanya boleh memuat satu nilai per atribut (INV-016)."
//   - 409 INV-016 "Kombinasi tidak lengkap — atribut wajib induk belum semua punya nilai (INV-016)."
//
// kodeAtribut yang tak dikenal (tidak ada di konfigurasi) memakai fallback
// String(id) — persis `kodeById.get(item.idInvAtribut) ?? String(item.idInvAtribut)`.
func ValidasiKombinasiGenerate(kombinasi []PasanganVarian, konfig []KonfigAtribut, nilai []NilaiAtribut) (HasilVarian, error) {
	kodeByID := make(map[int64]string, len(konfig))
	var wajibIDs []int64
	for _, k := range konfig {
		kodeByID[k.IDInvAtribut] = k.KodeAtribut
		if k.Wajib {
			wajibIDs = append(wajibIDs, k.IDInvAtribut)
		}
	}
	nilaiByID := make(map[int64]NilaiAtribut, len(nilai))
	for _, n := range nilai {
		nilaiByID[n.ID] = n
	}

	terpakai := make(map[int64]string)
	hasil := HasilVarian{}
	for _, item := range kombinasi {
		n, ada := nilaiByID[item.IDInvNilaiAtribut]
		if !ada || n.IDInvAtribut != item.IDInvAtribut {
			return HasilVarian{}, errkontrak.BadRequest(
				"Pasangan atribut/nilai tidak cocok atau tidak ditemukan (INV-016).",
				"INV-016",
			)
		}
		if _, sudah := terpakai[item.IDInvAtribut]; sudah {
			return HasilVarian{}, errkontrak.Conflict(
				"Satu kombinasi hanya boleh memuat satu nilai per atribut (INV-016).",
				"INV-016",
			)
		}
		terpakai[item.IDInvAtribut] = n.Nilai
		kode, adaKode := kodeByID[item.IDInvAtribut]
		if !adaKode {
			kode = strconv.FormatInt(item.IDInvAtribut, 10)
		}
		hasil.PasanganKode = append(hasil.PasanganKode, [2]string{kode, n.Nilai})
	}

	var kurang []int64
	for _, a := range wajibIDs {
		if _, ada := terpakai[a]; !ada {
			kurang = append(kurang, a)
		}
	}
	if len(kurang) > 0 {
		return HasilVarian{}, errkontrak.Conflict(
			"Kombinasi tidak lengkap — atribut wajib induk belum semua punya nilai (INV-016).",
			"INV-016",
		)
	}

	hasil.PasanganNilai = make([]int64, 0, len(kombinasi))
	for _, item := range kombinasi {
		hasil.PasanganNilai = append(hasil.PasanganNilai, item.IDInvNilaiAtribut)
	}
	hasil.KunciKombinasi = SusunKunciKombinasi(hasil.PasanganKode)
	return hasil, nil
}

// VarianTidakBisaJadiInduk — pesan create produk: varian + penanda induk
// sekaligus (D-17/D-39) — 400 verbatim.
func VarianTidakBisaJadiInduk() error {
	return errkontrak.BadRequest("Varian tidak bisa sekaligus jadi induk varian (D-17/D-39).")
}
