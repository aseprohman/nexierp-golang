// Package domain — aturan murni fitur LAPORAN/DASHBOARD inv (tanpa I/O).
// Mapper baris → view di-port VERBATIM dari mapper modul-level repo NestJS
// (dashboard.repository.ts: hitungBawahMinimum, susunTrenHarian;
// laporan.repository.ts: susunBarisKartuStok, petakanExpiring,
// petakanTraceability + hitungQtySaranReorder schemas/inv/tipe.ts).
package domain

import (
	"math"
	"time"

	"nexierp/internal/modules/inv/shared"
	"nexierp/internal/modules/inv/types"
)

// ---------------------------------------------------------------------
// Input baris murni (repo mengonversi pgtype → tipe dasar; urutan kolom
// persis gen laporan.sql.go/dashboard.sql.go).
// ---------------------------------------------------------------------

// ProdukBawahMinRow — baris agregat per produk (saldo efektif vs minimum).
type ProdukBawahMinRow struct {
	ID           int64
	Minimum      int64
	ReorderAktif bool
	OnHand       int64
	Dipesan      int64
}

// TrenHarianRow — baris tren harian mentah (to_char tanggal + FILTER masuk/keluar).
type TrenHarianRow struct {
	Tanggal     string
	Masuk       int64
	Keluar      int64
	NilaiMasuk  float64
	NilaiKeluar float64
}

// BarisKartuStok — baris mutasi kartu stok (JOIN header + dua lokasi).
type BarisKartuStok struct {
	TanggalSelesai    *time.Time // nullable — fallback tanggalJadwal (verbatim)
	TanggalJadwal     time.Time
	NomorDokumen      string
	Jenis             string
	IDInvLotSerial    *int64
	QtySelesai        int64
	NilaiPersatuan    *float64 // numeric nullable
	IDLokasiTujuan    int64
	JenisSumberLokasi string
	JenisTujuanLokasi string
}

// LotExpiring — baris lot expiring (JOIN produk + READMODEL saldo + gudang).
type LotExpiring struct {
	ID                 int64
	Kode               string
	TanggalKedaluwarsa *time.Time
	Status             string
	IDInvProduk        int64
	KodeProduk         string
	NamaProduk         string
	QtyOnHand          int64
	NilaiPersediaan    float64
}

// BarisTraceability — baris mutasi traceability (JOIN header + alias lokasi + lot).
type BarisTraceability struct {
	TanggalSelesai    *time.Time // nullable — fallback tanggalJadwal (verbatim)
	TanggalJadwal     time.Time
	NomorDokumen      string
	Jenis             string
	JenisSumber       string
	QtySelesai        int64
	NilaiPersatuan    *float64
	EntityIDSumber    *string
	JenisSumberLokasi string
	JenisTujuanLokasi string
	KodeSumber        string
	NamaSumber        string
	KodeTujuan        string
	NamaTujuan        string
	KodeLot           *string
}

// ---------------------------------------------------------------------
// Mapper (VERBATIM dari mapper repo NestJS)
// ---------------------------------------------------------------------

// HitungBawahMinimum — SKU di bawah minimum / reorder tertunda (saldo
// efektif agregat per produk) — VERBATIM DashboardService.ringkasan.
func HitungBawahMinimum(rows []ProdukBawahMinRow) (skuDiBawahMin int64, reorderTertunda int64) {
	for _, r := range rows {
		efektif := r.OnHand - r.Dipesan
		if efektif < r.Minimum {
			skuDiBawahMin++
			if r.ReorderAktif {
				reorderTertunda++
			}
		}
	}
	return skuDiBawahMin, reorderTertunda
}

// SusunTrenHarian — lengkapi hari tanpa mutasi agar grafik kontinu
// (deterministik). QUIRK UTC-slice (verbatim): label = toISOString().slice(0,10)
// dari tanggal lokal tengah malam — untuk TZ di depan UTC label bisa mundur
// satu hari vs tanggal DB. `hari` dibatasi pemanggil (clamp 1..90).
func SusunTrenHarian(rows []TrenHarianRow, hari int, awal time.Time) []types.DashboardTrenRowView {
	byDate := make(map[string]TrenHarianRow, len(rows))
	for _, r := range rows {
		byDate[r.Tanggal] = r
	}
	data := make([]types.DashboardTrenRowView, 0, hari)
	for i := 0; i < hari; i++ {
		d := awal.AddDate(0, 0, i)
		kunci := d.UTC().Format("2006-01-02")
		r, ada := byDate[kunci]
		masuk, keluar := int64(0), int64(0)
		nm, nk := 0.0, 0.0
		if ada {
			masuk, keluar, nm, nk = r.Masuk, r.Keluar, r.NilaiMasuk, r.NilaiKeluar
		}
		data = append(data, types.DashboardTrenRowView{
			Tanggal:     kunci,
			Masuk:       masuk,
			Keluar:      keluar,
			NilaiMasuk:  nm,
			NilaiKeluar: nk,
		})
	}
	return data
}

// SusunBarisKartuStok — susun baris kartu stok + saldo berjalan
// (server-side). Arah baris relatif lokasi yang dilihat:
//   - masuk : tujuan internal & (sumber non-internal ATAU berbeda lokasi);
//   - keluar: sumber internal & tujuan berbeda;
//   - transfer dua sisi di lokasi sama tidak mungkin (sumber ≠ tujuan).
//
// saldoAwal = Σ gerakan SELESAI `<=` tanggalDari (inklusif — verbatim).
func SusunBarisKartuStok(
	rows []BarisKartuStok,
	kodeLotByID map[int64]string,
	saldoAwal int64,
	idLokasi *int64,
) []types.KartuStokRowView {
	saldoBerjalan := saldoAwal
	data := make([]types.KartuStokRowView, 0, len(rows))
	for _, r := range rows {
		masuk, keluar := int64(0), int64(0)
		sumberInternal := r.JenisSumberLokasi == "INTERNAL"
		tujuanInternal := r.JenisTujuanLokasi == "INTERNAL"
		switch {
		case sumberInternal && tujuanInternal:
			// Transfer internal — sisi tergantung lokasi filter (atau keduanya
			// utk kartu lintas lokasi: masuk/keluar terpisah netral).
			if idLokasi != nil {
				if r.IDLokasiTujuan == *idLokasi {
					masuk = r.QtySelesai
				} else {
					keluar = r.QtySelesai
				}
			} else {
				masuk = r.QtySelesai // tampilan agregat: masuk (dan keluar sama)
				keluar = r.QtySelesai
			}
		case tujuanInternal:
			masuk = r.QtySelesai // penerimaan/penyesuaian plus
		case sumberInternal:
			keluar = r.QtySelesai // pengiriman/scrap/penyesuaian minus
		}
		nilai := float64(0)
		if r.NilaiPersatuan != nil {
			nilai = float64(r.QtySelesai) * *r.NilaiPersatuan
		}
		saldoBerjalan += masuk - keluar
		var kodeLot *string
		if r.IDInvLotSerial != nil {
			if kode, ada := kodeLotByID[*r.IDInvLotSerial]; ada {
				k := kode
				kodeLot = &k
			}
		}
		tanggal := r.TanggalJadwal
		if r.TanggalSelesai != nil {
			tanggal = *r.TanggalSelesai
		}
		data = append(data, types.KartuStokRowView{
			Tanggal:       shared.ISO(tanggal),
			NomorDokumen:  r.NomorDokumen,
			Jenis:         r.Jenis,
			KodeLot:       kodeLot,
			QtyMasuk:      masuk,
			QtyKeluar:     keluar,
			Nilai:         nilai,
			SaldoBerjalan: saldoBerjalan,
		})
	}
	return data
}

// PetakanExpiring — lot expiring → view (filter qty>0); hariTersisa =
// Math.floor((kedaluwarsa − sekarang)/msHari), negatif = lewat.
func PetakanExpiring(rows []LotExpiring, sekarang time.Time) []types.ExpiringRowView {
	const msHari = 24 * 60 * 60 * 1000
	sekarangMs := sekarang.UnixMilli() // JS Date ber-presisi milidetik
	data := make([]types.ExpiringRowView, 0, len(rows))
	for _, r := range rows {
		if r.QtyOnHand <= 0 {
			continue
		}
		tanggal, hariTersisa := "", int64(0)
		if r.TanggalKedaluwarsa != nil {
			tanggal = shared.ISO(*r.TanggalKedaluwarsa)
			hariTersisa = int64(math.Floor(float64(r.TanggalKedaluwarsa.UnixMilli()-sekarangMs) / msHari))
		}
		data = append(data, types.ExpiringRowView{
			IDInvLotSerial:     r.ID,
			KodeLot:            r.Kode,
			IDInvProduk:        r.IDInvProduk,
			KodeProduk:         r.KodeProduk,
			NamaProduk:         r.NamaProduk,
			TanggalKedaluwarsa: tanggal,
			Status:             r.Status,
			QtyOnHand:          r.QtyOnHand,
			NilaiPersediaan:    r.NilaiPersediaan,
			HariTersisa:        hariTersisa,
		})
	}
	return data
}

// PetakanTraceability — baris traceability → view. MASUK: PENERIMAAN, atau
// tujuan internal (masuk valuasi — termasuk penyesuaian-plus); KELUAR:
// keluar/pindah/penyesuaian-minus. kodeLokasiLawan = sumber (MASUK) / tujuan (KELUAR).
func PetakanTraceability(rows []BarisTraceability) []types.TraceabilityRowView {
	data := make([]types.TraceabilityRowView, 0, len(rows))
	for _, r := range rows {
		masuk := r.Jenis == "PENERIMAAN" ||
			(r.JenisTujuanLokasi == "INTERNAL" && r.Jenis == "PENYESUAIAN")
		tanggal := r.TanggalJadwal
		if r.TanggalSelesai != nil {
			tanggal = *r.TanggalSelesai
		}
		kode, nama := r.KodeTujuan, r.NamaTujuan
		if masuk {
			kode, nama = r.KodeSumber, r.NamaSumber
		}
		arah := "KELUAR"
		if masuk {
			arah = "MASUK"
		}
		data = append(data, types.TraceabilityRowView{
			Arah:            arah,
			NomorDokumen:    r.NomorDokumen,
			Jenis:           r.Jenis,
			Tanggal:         shared.ISO(tanggal),
			KodeLot:         r.KodeLot,
			Qty:             r.QtySelesai,
			NilaiPersatuan:  r.NilaiPersatuan,
			KodeLokasiLawan: kode,
			NamaLokasiLawan: nama,
			JenisSumber:     r.JenisSumber,
			EntityIDSumber:  r.EntityIDSumber,
		})
	}
	return data
}

// HitungQtySaranReorder — qty saran reorder = maks − saldo efektif
// (A-03 v2, INV-F09) — VERBATIM schemas/inv/tipe.ts.
func HitungQtySaranReorder(stokMinimum int64, stokMaksimum *int64, saldoEfektif int64) int64 {
	maks := stokMinimum
	if stokMaksimum != nil {
		maks = *stokMaksimum
	}
	if maks-saldoEfektif < 0 {
		return 0
	}
	return maks - saldoEfektif
}
