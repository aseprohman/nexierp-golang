// Unit spec valuasi murni (padanan domain/valuasi.spec.ts VERBATIM) —
// matematika AVCO, konsumsi FIFO, fallback lapisan kurang, pembulatan 4
// desimal, dan aturan status/prefix gerakan (gerakan-rules). Tanpa DB.
package domain_test

import (
	"testing"

	"nexierp/internal/modules/inv/domain"
)

// =====================================================================
// valuasi — Putus4
// =====================================================================

func TestPutus4(t *testing.T) {
	kasus := []struct {
		n   float64
		mau float64
	}{
		{1.6666666, 1.6667},
		{27142.857142857, 27142.8571},
		{3500, 3500},
		{0.00005, 0.0001}, // Math.round(0.5) = 1 (floor(x+0.5))
		{0.000049, 0},
		{-1.23456, -1.2346}, // floor(-12345.6+0.5)=floor(-12345.1)=-12346 → -1.2346
	}
	for _, k := range kasus {
		if got := domain.Putus4(k.n); got != k.mau {
			t.Errorf("Putus4(%v) = %v, mau %v", k.n, got, k.mau)
		}
	}
}

// =====================================================================
// valuasi AVCO — HitungRataRataBergerak
// =====================================================================

func TestHitungRataRataBergerak(t *testing.T) {
	t.Run("rata-rata bergerak standar: ((saldo×avg) + (qty×biaya)) / total", func(t *testing.T) {
		// saldo 100 @ 3000 + masuk 100 @ 4000 → 3500.
		if got := domain.HitungRataRataBergerak(100, 3000, 100, 4000); got != 3500 {
			t.Fatalf("got %v, mau 3500", got)
		}
	})
	t.Run("saldo tidak seimbang dibobot benar", func(t *testing.T) {
		// saldo 60 @ 10000 + masuk 40 @ 5000 → (600000 + 200000)/100 = 8000.
		if got := domain.HitungRataRataBergerak(60, 10_000, 40, 5_000); got != 8000 {
			t.Fatalf("got %v, mau 8000", got)
		}
	})
	t.Run("saldo kosong → biaya masuk langsung (avgLama diabaikan)", func(t *testing.T) {
		if got := domain.HitungRataRataBergerak(0, 3000, 50, 4_200); got != 4200 {
			t.Fatalf("got %v, mau 4200", got)
		}
	})
	t.Run("pembulatan 4 desimal", func(t *testing.T) {
		// (1×1 + 2×2)/3 = 1.666666... → 1.6667.
		if got := domain.HitungRataRataBergerak(1, 1, 2, 2); got != 1.6667 {
			t.Fatalf("got %v, mau 1.6667", got)
		}
	})
	t.Run("total qty nol → fallback biaya masuk", func(t *testing.T) {
		if got := domain.HitungRataRataBergerak(0, 0, 0, 5000); got != 5000 {
			t.Fatalf("got %v, mau 5000", got)
		}
	})
}

// =====================================================================
// valuasi FIFO — KonsumsiLapisanFifo
// =====================================================================

func lapisanSpec() []domain.LapisanFifo {
	return []domain.LapisanFifo{
		{ID: 1, Sisa: 40, Biaya: 25_000}, // tertua
		{ID: 2, Sisa: 60, Biaya: 30_000},
		{ID: 3, Sisa: 10, Biaya: 28_000},
	}
}

func TestKonsumsiLapisanFifo(t *testing.T) {
	t.Run("keluar kecil → hanya lapisan tertua terpakai", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo(lapisanSpec(), 20)
		if len(h.Pemakaian) != 1 || h.Pemakaian[0] != (domain.PemakaianLapisan{ID: 1, Qty: 20, Biaya: 25_000}) {
			t.Fatalf("pemakaian salah: %+v", h.Pemakaian)
		}
		if h.QtyTerlayani != 20 || h.FallbackQty != 0 {
			t.Fatalf("terlayani=%v fallback=%v, mau 20/0", h.QtyTerlayani, h.FallbackQty)
		}
	})
	t.Run("keluar melewati lapisan → beberapa lapisan terpakai urut lama dulu", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo(lapisanSpec(), 70)
		mau := []domain.PemakaianLapisan{
			{ID: 1, Qty: 40, Biaya: 25_000},
			{ID: 2, Qty: 30, Biaya: 30_000},
		}
		if len(h.Pemakaian) != 2 || h.Pemakaian[0] != mau[0] || h.Pemakaian[1] != mau[1] {
			t.Fatalf("pemakaian salah: %+v", h.Pemakaian)
		}
		if h.QtyTerlayani != 70 || h.FallbackQty != 0 {
			t.Fatalf("terlayani=%v fallback=%v, mau 70/0", h.QtyTerlayani, h.FallbackQty)
		}
	})
	t.Run("keluar lebih besar dari total lapisan → fallbackQty tercatat (bukan gagal)", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo(lapisanSpec(), 150)
		// Lapisan hanya 110 → 40 terlayani dari fallback.
		if h.QtyTerlayani != 110 || h.FallbackQty != 40 {
			t.Fatalf("terlayani=%v fallback=%v, mau 110/40", h.QtyTerlayani, h.FallbackQty)
		}
		if len(h.Pemakaian) != 3 {
			t.Fatalf("pemakaian harus 3 lapisan, got %d", len(h.Pemakaian))
		}
	})
	t.Run("lapisan kosong (data lama pra-patch) → seluruh qty fallback", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo([]domain.LapisanFifo{}, 12)
		if len(h.Pemakaian) != 0 || h.QtyTerlayani != 0 || h.FallbackQty != 12 {
			t.Fatalf("salah: %+v", h)
		}
	})
	t.Run("lapisan sisa nol dilewati", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo([]domain.LapisanFifo{
			{ID: 1, Sisa: 0, Biaya: 10},
			{ID: 2, Sisa: 5, Biaya: 20},
		}, 4)
		if len(h.Pemakaian) != 1 || h.Pemakaian[0] != (domain.PemakaianLapisan{ID: 2, Qty: 4, Biaya: 20}) {
			t.Fatalf("pemakaian salah: %+v", h.Pemakaian)
		}
	})
}

// =====================================================================
// valuasi FIFO — NilaiPersatuanFifo
// =====================================================================

func TestNilaiPersatuanFifo(t *testing.T) {
	t.Run("nilai = Σ(qty×biaya lapisan) / qty selesai", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo([]domain.LapisanFifo{
			{ID: 1, Sisa: 40, Biaya: 25_000},
			{ID: 2, Sisa: 60, Biaya: 30_000},
		}, 70)
		// (40×25000 + 30×30000)/70 = (1.000.000+900.000)/70 = 27142.8571…
		if got := domain.NilaiPersatuanFifo(h, 70, 9999); got != domain.Putus4(1_900_000.0/70.0) {
			t.Fatalf("got %v, mau %v", got, domain.Putus4(1_900_000.0/70.0))
		}
	})
	t.Run("fallback lapisan kurang memakai harga_biaya produk", func(t *testing.T) {
		h := domain.KonsumsiLapisanFifo([]domain.LapisanFifo{{ID: 1, Sisa: 10, Biaya: 1000}}, 15)
		// (10×1000 + 5×2000)/15 = 20000/15 = 1333.3333…
		if got := domain.NilaiPersatuanFifo(h, 15, 2000); got != domain.Putus4(20_000.0/15.0) {
			t.Fatalf("got %v, mau %v", got, domain.Putus4(20_000.0/15.0))
		}
	})
	t.Run("qty selesai nol → 0 (hindari pembagian nol)", func(t *testing.T) {
		if got := domain.NilaiPersatuanFifo(domain.HasilKonsumsiFifo{}, 0, 1000); got != 0 {
			t.Fatalf("got %v, mau 0", got)
		}
	})
}

// =====================================================================
// gerakan-rules — prefix/status/keluar-pindah/masuk/pasangan/progres
// =====================================================================

func TestPrefixJenis(t *testing.T) {
	mau := map[domain.JenisGerakan]string{
		domain.JenisPenerimaan:       "RCV/{MMyy}",
		domain.JenisPengiriman:       "DLV/{MMyy}",
		domain.JenisTransferInternal: "TRF/{MMyy}",
		domain.JenisProduksi:         "PRD/{MMyy}",
		domain.JenisScrap:            "SCR/{MMyy}",
		domain.JenisPenyesuaian:      "ADJ/{MMyy}",
	}
	for jenis, prefix := range mau {
		if got := domain.PrefixJenis(jenis); got != prefix {
			t.Errorf("PrefixJenis(%s) = %q, mau %q", jenis, got, prefix)
		}
	}
	if got := domain.PrefixJenis("TIDAK_ADA"); got != "" {
		t.Errorf("jenis asing harus kosong, got %q", got)
	}
}

func TestStatusTerbuka(t *testing.T) {
	for _, s := range []domain.StatusGerakan{"DRAFT", "MENUNGGU_STOK", "TERJADWAL", "SEBAGIAN"} {
		if !domain.StatusTerbuka(s) {
			t.Errorf("%s harus terbuka", s)
		}
	}
	for _, s := range []domain.StatusGerakan{"SELESAI", "BATAL"} {
		if domain.StatusTerbuka(s) {
			t.Errorf("%s harus final", s)
		}
	}
}

func TestJenisKeluarPindahDanMasuk(t *testing.T) {
	for _, j := range []domain.JenisGerakan{"PENGIRIMAN", "TRANSFER_INTERNAL", "SCRAP", "PRODUKSI"} {
		if !domain.JenisKeluarPindah(j) {
			t.Errorf("%s harus keluar/pindah", j)
		}
		if domain.JenisGerakanMasuk(j) {
			t.Errorf("%s tidak boleh masuk", j)
		}
	}
	for _, j := range []domain.JenisGerakan{"PENERIMAAN", "PENYESUAIAN"} {
		if !domain.JenisGerakanMasuk(j) {
			t.Errorf("%s harus masuk", j)
		}
		if domain.JenisKeluarPindah(j) {
			t.Errorf("%s tidak boleh keluar/pindah", j)
		}
	}
}

func TestPasanganLokasiSah(t *testing.T) {
	// masuk: VENDOR→INTERNAL sah; INTERNAL→CUSTOMER tidak utk PENERIMAAN.
	if !domain.PasanganLokasiSah(domain.JenisPenerimaan, "VENDOR", "INTERNAL") {
		t.Fatal("VENDOR→INTERNAL harus sah utk PENERIMAAN")
	}
	if domain.PasanganLokasiSah(domain.JenisPenerimaan, "INTERNAL", "CUSTOMER") {
		t.Fatal("INTERNAL→CUSTOMER tidak sah utk PENERIMAAN")
	}
	// keluar: INTERNAL→CUSTOMER sah utk PENGIRIMAN.
	if !domain.PasanganLokasiSah(domain.JenisPengiriman, "INTERNAL", "CUSTOMER") {
		t.Fatal("INTERNAL→CUSTOMER harus sah utk PENGIRIMAN")
	}
	// pindah: hanya INTERNAL→INTERNAL.
	if !domain.PasanganLokasiSah(domain.JenisTransferInternal, "INTERNAL", "INTERNAL") {
		t.Fatal("INTERNAL→INTERNAL harus sah utk TRANSFER_INTERNAL")
	}
	if domain.PasanganLokasiSah(domain.JenisTransferInternal, "VENDOR", "INTERNAL") {
		t.Fatal("VENDOR→INTERNAL tidak sah utk TRANSFER_INTERNAL")
	}
	// penyesuaian: INTERNAL→INTERNAL sah.
	if !domain.PasanganLokasiSah(domain.JenisPenyesuaian, "INTERNAL", "INTERNAL") {
		t.Fatal("INTERNAL→INTERNAL harus sah utk PENYESUAIAN")
	}
}

func TestStatusDariProgres(t *testing.T) {
	if got := domain.StatusDariProgres(domain.StatusMenungguStok, 0, 10); got != domain.StatusMenungguStok {
		t.Errorf("qty 0 pertahankan status, got %s", got)
	}
	if got := domain.StatusDariProgres(domain.StatusTerjadwal, 10, 10); got != domain.StatusSelesai {
		t.Errorf("qty ≥ diminta → SELESAI, got %s", got)
	}
	if got := domain.StatusDariProgres(domain.StatusTerjadwal, 4, 10); got != domain.StatusSebagian {
		t.Errorf("0 < qty < diminta → SEBAGIAN, got %s", got)
	}
}
