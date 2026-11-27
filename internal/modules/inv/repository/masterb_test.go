// Unit test murni mapper MASTER-B: baris → view (rantai wilayah null-safe,
// namaLangkah ter-slice jumlahLangkah, ISO-8601) — tanpa DB.
package repository

import (
	"testing"
	"time"

	"nexierp/internal/core/rbac"
)

func TestGudangToViewWilayahNullSafe(t *testing.T) {
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)

	// Tanpa kelurahan → wilayah null.
	row := GudangRantaiRow{
		GudangRow: GudangRow{
			ID: 1, Kode: "GDK", Nama: "Gudang Karya", Status: "AKTIF",
			Version: 2, CreatedAt: now, UpdatedAt: now,
			Latitude: floatPtr(1.5), Longitude: floatPtr(2.5),
		},
	}
	v := GudangToView(row)
	if v.Wilayah != nil {
		t.Fatal("wilayah harus null bila rantai tak lengkap")
	}
	if v.Latitude == nil || *v.Latitude != 1.5 || v.Longitude == nil || *v.Longitude != 2.5 {
		t.Fatal("koordinat harus terkonversi number")
	}
	if v.CreatedAt != "2026-11-27T08:00:00.000Z" {
		t.Fatalf("createdAt = %q", v.CreatedAt)
	}

	// Rantai lengkap → wilayah terisi (null-safe pada pecahan).
	idKel := int64(11)
	row.IDCoreKelurahan = &idKel
	row.IDCoreKecamatan = &idKel
	row.IDCoreKota = &idKel
	row.IDCoreProvinsi = &idKel
	row.KelurahanNama = strPtr("Sukamaju")
	row.KecamatanNama = strPtr("Cibinong")
	row.KotaNama = strPtr("Bogor")
	row.ProvinsiNama = strPtr("Jawa Barat")
	row.KodePos = strPtr("16911")
	v = GudangToView(row)
	if v.Wilayah == nil {
		t.Fatal("wilayah harus terisi bila rantai lengkap")
	}
	if v.Wilayah.KodePos == nil || *v.Wilayah.KodePos != "16911" {
		t.Fatal("kodePos harus terisi")
	}
	// Pecahan rantai (kota hilang) → wilayah null (tidak panic).
	row.KotaNama = nil
	if GudangToView(row).Wilayah != nil {
		t.Fatal("wilayah harus null bila satu nama rantai hilang")
	}
}

func TestJenisOperasiToViewNamaLangkah(t *testing.T) {
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	l2 := "Verifikasi"

	row := JenisOperasiRow{
		ID: 5, Kode: "TRF", Nama: "Transfer", JenisGerakan: "TRANSFER_INTERNAL",
		Prefix: "TRF", JumlahLangkah: 2, NamaLangkah1: "Input", NamaLangkah2: &l2,
		Status: "AKTIF", Version: 1, CreatedAt: now, UpdatedAt: now,
	}
	v := JenisOperasiToView(row, nil, nil)
	if len(v.NamaLangkah) != 2 || v.NamaLangkah[0] != "Input" || v.NamaLangkah[1] != "Verifikasi" {
		t.Fatalf("namaLangkah = %v", v.NamaLangkah)
	}
	// jumlahLangkah 1 → namaLangkah terpotong 1.
	row.JumlahLangkah = 1
	v = JenisOperasiToView(row, nil, nil)
	if len(v.NamaLangkah) != 1 {
		t.Fatalf("namaLangkah = %v, mau 1", v.NamaLangkah)
	}
	// Resolver kode null → kedua kode null.
	if v.KodeLokasiSumberDefault != nil || v.KodeLokasiTujuanDefault != nil {
		t.Fatal("kode default harus null")
	}
}

func TestLokasiToViewDanLotToView(t *testing.T) {
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	g1 := int64(1)
	lot := LotRow{
		ID: 9, IDInvProduk: 2, Kode: "LOT-1", Status: "AKTIF", Version: 1,
		CreatedAt: now, UpdatedAt: now,
		TanggalProdiksi:    &now,
		TanggalKedaluwarsa: nil,
	}
	v := LotToView(lot, "BRG-1", "Barang Satu", 7)
	if v.SaldoOnHand != 7 || v.KodeProduk != "BRG-1" || v.NamaProduk != "Barang Satu" {
		t.Fatalf("lot view salah: %+v", v)
	}
	if v.TanggalProdiksi == nil || *v.TanggalProdiksi != "2026-11-27T08:00:00.000Z" {
		t.Fatalf("tanggalProdiksi = %v", v.TanggalProdiksi)
	}
	if v.TanggalKedaluwarsa != nil {
		t.Fatal("tanggalKedaluwarsa harus null")
	}

	lv := LokasiToView(LokasiRow{ID: 4, Kode: "LK-01", Nama: "Rak 01", Jenis: "INTERNAL", IDInvGudang: &g1, Status: "AKTIF", Version: 1, CreatedAt: now, UpdatedAt: now}, strPtr("GDK"), nil)
	if lv.NamaGudang == nil || *lv.NamaGudang != "GDK" || lv.NamaInduk != nil {
		t.Fatalf("lokasi view salah: %+v", lv)
	}
}

func TestMbIntAnyDanCakupanDariDecision(t *testing.T) {
	if mbIntAny(int32(5)) != 5 || mbIntAny(int64(6)) != 6 || mbIntAny(nil) != 0 {
		t.Fatal("mbIntAny salah")
	}
	if cak := CakupanDariDecision(nil); cak != nil {
		t.Fatal("Decision nil = SEMUA (nil)")
	}
	if cak := CakupanDariDecision(&rbac.Decision{Mode: rbac.ModeDenyAll}); cak == nil || !cak.Deny {
		t.Fatal("DENY_ALL harus deny")
	}
	if cak := CakupanDariDecision(&rbac.Decision{Mode: rbac.ModeDaftar, IDs: []int64{42}}); cak == nil || cak.Deny || len(cak.IDs) != 1 || cak.IDs[0] != 42 {
		t.Fatal("DAFTAR harus membawa ids")
	}
	if cak := CakupanDariDecision(&rbac.Decision{Mode: rbac.ModeSemua}); cak != nil {
		t.Fatal("SEMUA = nil (tanpa predicate)")
	}
}

func floatPtr(f float64) *float64 { return &f }
func strPtr(s string) *string     { return &s }
