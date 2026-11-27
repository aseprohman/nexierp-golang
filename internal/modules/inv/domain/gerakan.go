// gerakan.go — konstanta & aturan murni fitur GERAKAN STOK modul inv
// (padanan domain/gerakan-rules.ts + kosakata packages/schemas inv/tipe.ts
// yang dipakai alur gerakan). Semua fungsi murni — unit-testable.
package domain

// JenisGerakan — enum_jenis_gerakan (persis DDL).
type JenisGerakan string

// Nilai enum jenis gerakan — urutan persis DDL.
const (
	JenisPenerimaan       JenisGerakan = "PENERIMAAN"
	JenisPengiriman       JenisGerakan = "PENGIRIMAN"
	JenisTransferInternal JenisGerakan = "TRANSFER_INTERNAL"
	JenisProduksi         JenisGerakan = "PRODUKSI"
	JenisScrap            JenisGerakan = "SCRAP"
	JenisPenyesuaian      JenisGerakan = "PENYESUAIAN"
)

// DaftarJenisGerakan — JENIS_GERAKAN tipe.ts (urutan persis) — dipakai
// validasi handler (pesan z.enum) & filter list.
var DaftarJenisGerakan = []JenisGerakan{
	JenisPenerimaan,
	JenisPengiriman,
	JenisTransferInternal,
	JenisProduksi,
	JenisScrap,
	JenisPenyesuaian,
}

// StatusGerakan — enum_status_gerakan (persis DDL, §4.2).
type StatusGerakan string

// Nilai enum status gerakan.
const (
	StatusDraft        StatusGerakan = "DRAFT"
	StatusMenungguStok StatusGerakan = "MENUNGGU_STOK"
	StatusTerjadwal    StatusGerakan = "TERJADWAL"
	StatusSebagian     StatusGerakan = "SEBAGIAN"
	StatusSelesai      StatusGerakan = "SELESAI"
	StatusBatal        StatusGerakan = "BATAL"
)

// DaftarStatusAwalCreate — enum status yg boleh di-input create
// (gerakanCreateSchema: z.enum(["DRAFT","TERJADWAL","MENUNGGU_STOK"])).
var DaftarStatusAwalCreate = []StatusGerakan{StatusDraft, StatusTerjadwal, StatusMenungguStok}

// statusReservasi — enum_status_reservasi (patch 04, D-29).
const (
	ReservasiTidak        = "TIDAK"
	ReservasiTerreservasi = "TERRESERVASI"
)

// prefixJenis — PREFIX_JENIS gerakan-rules.ts VERBATIM: prefix penomoran
// per jenis gerakan (INV-BR01) — template {MMyy} dirender NumberingService.
var prefixJenis = map[JenisGerakan]string{
	JenisPenerimaan:       "RCV/{MMyy}",
	JenisPengiriman:       "DLV/{MMyy}",
	JenisTransferInternal: "TRF/{MMyy}",
	JenisProduksi:         "PRD/{MMyy}",
	JenisScrap:            "SCR/{MMyy}",
	JenisPenyesuaian:      "ADJ/{MMyy}",
}

// PrefixJenis — prefix penomoran per jenis gerakan (INV-BR01); kosong bila
// jenis tidak dikenal.
func PrefixJenis(jenis JenisGerakan) string { return prefixJenis[jenis] }

// statusTerbuka — STATUS_TERBUKA gerakan-rules.ts VERBATIM: status dokumen
// yang masih boleh dikonfirmasi/dibatalkan/direservasi.
var statusTerbuka = []StatusGerakan{StatusDraft, StatusMenungguStok, StatusTerjadwal, StatusSebagian}

// StatusTerbuka — apakah status masih terbuka (non-final)?
func StatusTerbuka(status StatusGerakan) bool {
	for _, s := range statusTerbuka {
		if s == status {
			return true
		}
	}
	return false
}

// jenisKeluarPindah — JENIS_KELUAR_PINDAH gerakan-rules.ts VERBATIM: jenis
// arah keluar/pindah — penerima reservasi & backorder (D-25/D-29).
var jenisKeluarPindah = []JenisGerakan{JenisPengiriman, JenisTransferInternal, JenisScrap, JenisProduksi}

// JenisKeluarPindah — apakah jenis termasuk arah keluar/pindah?
func JenisKeluarPindah(jenis JenisGerakan) bool {
	for _, j := range jenisKeluarPindah {
		if j == jenis {
			return true
		}
	}
	return false
}

// jenisGerakanMasuk — JENIS_GERAKAN_MASUK tipe.ts VERBATIM: stok bertambah
// di tujuan.
var jenisGerakanMasuk = []JenisGerakan{JenisPenerimaan, JenisPenyesuaian}

// JenisGerakanMasuk — apakah jenis termasuk arah masuk?
func JenisGerakanMasuk(jenis JenisGerakan) bool {
	for _, j := range jenisGerakanMasuk {
		if j == jenis {
			return true
		}
	}
	return false
}

// ArahGerakan — arah stok per jenis gerakan (tipe.ts): dasar recompute saldo
// & validasi lokasi.
type ArahGerakan string

// Nilai arah gerakan.
const (
	ArahMasuk       ArahGerakan = "masuk"
	ArahKeluar      ArahGerakan = "keluar"
	ArahPindah      ArahGerakan = "pindah"
	ArahPenyesuaian ArahGerakan = "penyesuaian"
)

// arahGerakan — ARAH_GERAKAN tipe.ts VERBATIM.
var arahGerakan = map[JenisGerakan]ArahGerakan{
	JenisPenerimaan:       ArahMasuk,
	JenisPengiriman:       ArahKeluar,
	JenisTransferInternal: ArahPindah,
	JenisProduksi:         ArahKeluar,
	JenisScrap:            ArahKeluar,
	JenisPenyesuaian:      ArahPenyesuaian,
}

// ArahOf — arah stok satu jenis gerakan; kosong bila jenis tidak dikenal.
func ArahOf(jenis JenisGerakan) ArahGerakan { return arahGerakan[jenis] }

// jenisLokasi — enum_jenis_lokasi (persis DDL).
type JenisLokasi string

// Nilai enum jenis lokasi.
const (
	LokasiInternal JenisLokasi = "INTERNAL"
	LokasiVendor   JenisLokasi = "VENDOR"
	LokasiCustomer JenisLokasi = "CUSTOMER"
	LokasiProduksi JenisLokasi = "PRODUKSI"
	LokasiScrap    JenisLokasi = "SCRAP"
)

// pasanganLokasiSah — PASANGAN_LOKASI_SAH tipe.ts VERBATIM (INV-BR03):
// pasangan (jenis_sumber, jenis_tujuan) sah per arah.
var pasanganLokasiSah = map[ArahGerakan][][2]JenisLokasi{
	ArahMasuk: {
		{LokasiVendor, LokasiInternal},
		{LokasiProduksi, LokasiInternal},
		{LokasiScrap, LokasiInternal},
	},
	ArahKeluar: {
		{LokasiInternal, LokasiCustomer},
		{LokasiInternal, LokasiVendor},
		{LokasiInternal, LokasiProduksi},
		{LokasiInternal, LokasiScrap},
	},
	ArahPindah:      {{LokasiInternal, LokasiInternal}},
	ArahPenyesuaian: {{LokasiInternal, LokasiInternal}},
}

// PasanganLokasiSah — pasangan (jenis sumber → jenis tujuan) sah utk arah
// jenis gerakan? (INV-BR03 — validasi app di samping CHECK DB.)
func PasanganLokasiSah(jenis JenisGerakan, jenisSumber, jenisTujuan JenisLokasi) bool {
	sah, ada := pasanganLokasiSah[arahGerakan[jenis]]
	if !ada {
		return false
	}
	for _, p := range sah {
		if p[0] == jenisSumber && p[1] == jenisTujuan {
			return true
		}
	}
	return false
}

// StatusDariProgres — status gerakan efektif dari progres qty — §4.2 tipe.ts
// VERBATIM (DRAFT ditentukan pembuat): ≤0 pertahankan; ≥diminta SELESAI;
// selain itu SEBAGIAN.
func StatusDariProgres(statusSaatIni StatusGerakan, qtySelesai, qtyDiminta int64) StatusGerakan {
	if qtySelesai <= 0 {
		return statusSaatIni
	}
	if qtySelesai >= qtyDiminta {
		return StatusSelesai
	}
	return StatusSebagian
}
