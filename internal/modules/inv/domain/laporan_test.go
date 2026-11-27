// Uji aturan murni laporan/dashboard — parity mapper repo NestJS.
package domain

import (
	"math"
	"testing"
	"time"

	"nexierp/internal/modules/inv/shared"
)

// jam — helper time dari epoch (UTC stabil utk test).
func jam(h ...int) time.Time {
	base := time.Date(2026, 11, 27, 0, 0, 0, 0, time.UTC)
	return base.Add(time.Duration(h[0]) * time.Hour)
}

func TestHitungBawahMinimum(t *testing.T) {
	rows := []ProdukBawahMinRow{
		{ID: 1, Minimum: 10, ReorderAktif: true, OnHand: 5, Dipesan: 0},    // efektif 5 < 10 → bawah min + reorder
		{ID: 2, Minimum: 10, ReorderAktif: false, OnHand: 20, Dipesan: 15}, // efektif 5 < 10 → bawah min saja
		{ID: 3, Minimum: 10, ReorderAktif: true, OnHand: 12, Dipesan: 0},   // efektif 12 ≥ 10 → lewat
	}
	bawah, tertunda := HitungBawahMinimum(rows)
	if bawah != 2 || tertunda != 1 {
		t.Fatalf("harap (2,1) dapat (%d,%d)", bawah, tertunda)
	}
}

func TestSusunTrenHarianLengkapiHariKosong(t *testing.T) {
	awal := time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC)
	rows := []TrenHarianRow{{Tanggal: "2026-11-21", Masuk: 3, Keluar: 1, NilaiMasuk: 300, NilaiKeluar: 100}}
	data := SusunTrenHarian(rows, 3, awal)
	if len(data) != 3 {
		t.Fatalf("harap 3 baris dapat %d", len(data))
	}
	if data[0].Tanggal != "2026-11-20" || data[0].Masuk != 0 || data[0].NilaiMasuk != 0 {
		t.Fatalf("hari kosong tidak nol: %+v", data[0])
	}
	if data[1].Tanggal != "2026-11-21" || data[1].Masuk != 3 || data[1].NilaiKeluar != 100 {
		t.Fatalf("hari berisi salah: %+v", data[1])
	}
	if data[2].Tanggal != "2026-11-22" {
		t.Fatalf("label hari ke-3 salah: %+v", data[2])
	}
}

// Quirk label UTC-slice: awal tengah malam LOKAL (UTC+7) → toISOString
// mundur satu hari (17:00 UTC hari sebelumnya).
func TestSusunTrenHarianQuirkLabelUTC(t *testing.T) {
	loc := time.FixedZone("WIB", 7*3600)
	awal := time.Date(2026, 11, 20, 0, 0, 0, 0, loc)
	rows := []TrenHarianRow{{Tanggal: "2026-11-19", Masuk: 7, Keluar: 0, NilaiMasuk: 1, NilaiKeluar: 0}}
	data := SusunTrenHarian(rows, 1, awal)
	// Label JS = toISOString().slice(0,10) dari 2026-11-20T00:00+07 = 2026-11-19T17:00Z → "2026-11-19".
	if data[0].Tanggal != "2026-11-19" {
		t.Fatalf("quirk label UTC tidak ter-port: %+v", data[0])
	}
	if data[0].Masuk != 7 {
		t.Fatalf("baris harus cocok label quirk: %+v", data[0])
	}
}

func TestSusunBarisKartuStokArahDanSaldo(t *testing.T) {
	kedaluwarsa := jam(9)
	jadwal := jam(8)
	selesai := kedaluwarsa
	idTujuan := int64(55)
	rows := []BarisKartuStok{
		// Penerimaan: tujuan internal → masuk.
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "RCV-1", Jenis: "PENERIMAAN",
			QtySelesai: 10, NilaiPersatuan: ptr(2.5), IDLokasiTujuan: idTujuan,
			JenisSumberLokasi: "SUPPLIER", JenisTujuanLokasi: "INTERNAL"},
		// Pengiriman: sumber internal → keluar.
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "DLV-1", Jenis: "PENGIRIMAN",
			QtySelesai: 4, NilaiPersatuan: nil, IDLokasiTujuan: 99,
			JenisSumberLokasi: "INTERNAL", JenisTujuanLokasi: "CUSTOMER"},
		// Transfer internal tanpa filter lokasi → masuk DAN keluar (agregat).
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "MUT-1", Jenis: "MUTASI",
			QtySelesai: 6, NilaiPersatuan: ptr(1.0), IDLokasiTujuan: 77,
			JenisSumberLokasi: "INTERNAL", JenisTujuanLokasi: "INTERNAL"},
	}
	data := SusunBarisKartuStok(rows, map[int64]string{2: "LOT-2"}, 100, nil)
	if len(data) != 3 {
		t.Fatalf("harap 3 baris dapat %d", len(data))
	}
	if data[0].QtyMasuk != 10 || data[0].QtyKeluar != 0 || data[0].Nilai != 25 || data[0].SaldoBerjalan != 110 {
		t.Fatalf("baris penerimaan salah: %+v", data[0])
	}
	if data[1].QtyMasuk != 0 || data[1].QtyKeluar != 4 || data[1].Nilai != 0 || data[1].SaldoBerjalan != 106 {
		t.Fatalf("baris pengiriman salah: %+v", data[1])
	}
	if data[2].QtyMasuk != 6 || data[2].QtyKeluar != 6 || data[2].SaldoBerjalan != 106 {
		t.Fatalf("baris transfer agregat salah: %+v", data[2])
	}
	if data[0].Tanggal != "2026-11-27T09:00:00.000Z" {
		t.Fatalf("ISO tidak 3ms+Z: %s", data[0].Tanggal)
	}

	// Dengan filter lokasi: transfer internal memilih sisi tujuan.
	idLok := int64(77)
	data2 := SusunBarisKartuStok(rows[2:], nil, 0, &idLok)
	if data2[0].QtyMasuk != 6 || data2[0].QtyKeluar != 0 {
		t.Fatalf("sisi transfer dengan filter lokasi salah: %+v", data2[0])
	}
	// Tanpa tanggal_selesai → fallback tanggal_jadwal.
	tanpaSelesai := BarisKartuStok{TanggalJadwal: jadwal, NomorDokumen: "X", Jenis: "PENERIMAAN",
		QtySelesai: 1, IDLokasiTujuan: 1, JenisSumberLokasi: "SUPPLIER", JenisTujuanLokasi: "INTERNAL"}
	data3 := SusunBarisKartuStok([]BarisKartuStok{tanpaSelesai}, nil, 0, nil)
	if data3[0].Tanggal != "2026-11-27T08:00:00.000Z" {
		t.Fatalf("fallback tanggalJadwal salah: %s", data3[0].Tanggal)
	}
}

func TestPetakanExpiringHariTersisaFloor(t *testing.T) {
	sekarang := jam(12)
	rows := []LotExpiring{
		{ID: 1, Kode: "L1", IDInvProduk: 7, KodeProduk: "P1", NamaProduk: "Prod",
			TanggalKedaluwarsa: ptrTime(sekarang.Add(36 * time.Hour)), Status: "AKTIF",
			QtyOnHand: 5, NilaiPersediaan: 1000},
		{ID: 2, Kode: "L2", IDInvProduk: 7, KodeProduk: "P1", NamaProduk: "Prod",
			TanggalKedaluwarsa: ptrTime(sekarang.Add(-2*time.Hour - 30*time.Minute)), Status: "AKTIF",
			QtyOnHand: 1, NilaiPersediaan: 10},
		{ID: 3, Kode: "L3", QtyOnHand: 0, NilaiPersediaan: 5}, // qty 0 → dibuang
		{ID: 4, Kode: "L4", QtyOnHand: 2, NilaiPersediaan: 5}, // tanpa tanggal → "" + 0
	}
	data := PetakanExpiring(rows, sekarang)
	if len(data) != 3 {
		t.Fatalf("harap 3 baris (qty 0 dibuang) dapat %d", len(data))
	}
	if data[0].HariTersisa != 1 { // floor(1.5) = 1
		t.Fatalf("hariTersisa floor salah: %d", data[0].HariTersisa)
	}
	if data[1].HariTersisa != -1 { // floor(-0.104) = -1 (negatif = lewat)
		t.Fatalf("hariTersisa negatif salah: %d", data[1].HariTersisa)
	}
	if data[2].TanggalKedaluwarsa != "" || data[2].HariTersisa != 0 {
		t.Fatalf("lot tanpa tanggal salah: %+v", data[2])
	}
}

func TestPetakanTraceabilityLotMenangArahMasuk(t *testing.T) {
	selesai := jam(10)
	jadwal := jam(9)
	lot := "LOT-9"
	rows := []BarisTraceability{
		// PENERIMAAN → MASUK, lawan = sumber.
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "RCV-2", Jenis: "PENERIMAAN",
			JenisSumber: "MANUAL", QtySelesai: 3, NilaiPersatuan: ptr(1.25), EntityIDSumber: ptr("e-1"),
			JenisSumberLokasi: "SUPPLIER", JenisTujuanLokasi: "INTERNAL",
			KodeSumber: "SUP", NamaSumber: "Pemasok", KodeTujuan: "GD", NamaTujuan: "Gudang", KodeLot: &lot},
		// PENYESUAIAN tujuan INTERNAL → MASUK (penyesuaian-plus).
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "ADJ-1", Jenis: "PENYESUAIAN",
			JenisSumber: "MANUAL", QtySelesai: 2, NilaiPersatuan: nil,
			JenisSumberLokasi: "INTERNAL", JenisTujuanLokasi: "INTERNAL",
			KodeSumber: "LK-A", NamaSumber: "Lokasi A", KodeTujuan: "LK-B", NamaTujuan: "Lokasi B"},
		// PENYESUAIAN sumber internal (tujuan non-internal) → KELUAR.
		{TanggalSelesai: &selesai, TanggalJadwal: jadwal, NomorDokumen: "ADJ-2", Jenis: "PENYESUAIAN",
			JenisSumber: "MANUAL", QtySelesai: 1, NilaiPersatuan: ptr(9.0),
			JenisSumberLokasi: "INTERNAL", JenisTujuanLokasi: "SCRAP",
			KodeSumber: "LK-A", NamaSumber: "Lokasi A", KodeTujuan: "SCR", NamaTujuan: "Scrap"},
	}
	data := PetakanTraceability(rows)
	if data[0].Arah != "MASUK" || data[0].KodeLokasiLawan != "SUP" || data[0].NamaLokasiLawan != "Pemasok" {
		t.Fatalf("arah/lawan penerimaan salah: %+v", data[0])
	}
	if data[0].NilaiPersatuan == nil || *data[0].NilaiPersatuan != 1.25 {
		t.Fatalf("nilaiPersatuan number|null salah: %+v", data[0].NilaiPersatuan)
	}
	if data[1].Arah != "MASUK" || data[1].KodeLokasiLawan != "LK-A" || data[1].NilaiPersatuan != nil {
		t.Fatalf("penyesuaian-plus salah: %+v", data[1])
	}
	if data[2].Arah != "KELUAR" || data[2].KodeLokasiLawan != "SCR" {
		t.Fatalf("penyesuaian-minus salah: %+v", data[2])
	}
	if data[0].Tanggal != "2026-11-27T10:00:00.000Z" {
		t.Fatalf("ISO traceability salah: %s", data[0].Tanggal)
	}
}

func TestHitungQtySaranReorder(t *testing.T) {
	maks := int64(50)
	if got := HitungQtySaranReorder(10, &maks, 15); got != 35 {
		t.Fatalf("qtySaran = maks − efektif salah: %d", got)
	}
	if got := HitungQtySaranReorder(10, nil, 5); got != 5 {
		t.Fatalf("tanpa maks → minimum yang dipakai: %d", got)
	}
	if got := HitungQtySaranReorder(10, &maks, 60); got != 0 {
		t.Fatalf("harap clamp 0: %d", got)
	}
}

// Guard bentuk waktu: ISO 3 digit ms + Z (persis toISOString).
func TestISOFormat(t *testing.T) {
	got := shared.ISO(time.Date(2026, 3, 5, 7, 8, 9, 123000000, time.UTC))
	want := "2026-03-05T07:08:09.123Z"
	if got != want {
		t.Fatalf("harap %s dapat %s", want, got)
	}
	if math.IsNaN(0) {
		t.Fatal("unreachable")
	}
}

func ptr[T any](v T) *T              { return &v }
func ptrTime(v time.Time) *time.Time { return &v }
