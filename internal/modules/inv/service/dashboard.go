// service/dashboard.go — fitur DASHBOARD INVENTORY (INV-F14): ringkasan KPI
// + tren gerakan harian — padanan DashboardService NestJS. Breakdown
// pendalaman (nilai/backlog/reorder/expiring) DELEGASI LaporanService — satu
// sumber query dengan halaman Laporan. Semua baca non-transaksi (pool).
package service

import (
	"context"
	"math"
	"strconv"
	"time"

	"nexierp/internal/core/database"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// DashboardService — KPI ringkasan + tren; delegasi breakdown ke LaporanService.
type DashboardService struct {
	laporan *LaporanService
	repo    *repository.DashboardRepository
}

// NewDashboardService membuat service dashboard (laporan service dibangun
// sekali — delegasi breakdown, pembaca CFG & repo dipakai bersama).
func NewDashboardService(db *database.DB, modCfg *moduleconfig.Service) *DashboardService {
	lap := NewLaporanService(db, modCfg)
	return &DashboardService{laporan: lap, repo: repository.NewDashboardRepository()}
}

// Ringkasan — total SKU, di bawah min, nilai persediaan, antrian.
func (s *DashboardService) Ringkasan(ctx context.Context) (types.DashboardRingkasanView, error) {
	sekarang := time.Now()
	y, m, d := sekarang.In(time.Local).Date()
	awalHari := time.Date(y, m, d, 0, 0, 0, 0, time.Local)

	total, aktif, err := s.repo.HitungSku(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	nilai, err := s.repo.MuatTotalNilaiPersediaan(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	gerakanHariIni, err := s.repo.HitungGerakanSejak(ctx, s.laporan.db.Pool, awalHari)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	terbuka, err := s.repo.HitungGerakanTerbuka(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	menunggu, err := s.repo.HitungPenyesuaianMenunggu(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	lotKedaluwarsa, err := s.repo.HitungLotKedaluwarsaBersaldo(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}

	// SKU di bawah minimum / reorder tertunda — saldo efektif agregat per produk.
	bawahMinRows, err := s.repo.ListProdukBawahMinimum(ctx, s.laporan.db.Pool)
	if err != nil {
		return types.DashboardRingkasanView{}, err
	}
	skuDiBawahMin, reorderTertunda := domain.HitungBawahMinimum(bawahMinRows)

	return types.DashboardRingkasanView{
		TotalSku:                    total,
		SkuAktif:                    aktif,
		SkuDiBawahMin:               skuDiBawahMin,
		TotalNilaiPersediaan:        nilai, // JSON number (Number() sebelum respons)
		GerakanHariIni:              gerakanHariIni,
		GerakanTerbuka:              terbuka,
		PenyesuaianMenungguApproval: menunggu,
		LotKedaluwarsa:              lotKedaluwarsa,
		ReorderTertunda:             reorderTertunda,
	}, nil
}

// Tren — gerakan SELESAI per hari; `hariRaw` kosong/invalid/0 → 14, clamp
// 1..90 TANPA 400 (verbatim).
func (s *DashboardService) Tren(ctx context.Context, hariRaw string) ([]types.DashboardTrenRowView, error) {
	hari := parseHariTren(hariRaw)

	awal := time.Now()
	ly, lm, ld := awal.In(time.Local).Date()
	awalLokal := time.Date(ly, lm, ld, 0, 0, 0, 0, time.Local).AddDate(0, 0, -(hari - 1))

	rows, err := s.repo.ListTrenHarian(ctx, s.laporan.db.Pool, awalLokal)
	if err != nil {
		return nil, err
	}
	// Lengkapi hari tanpa mutasi (deterministik) — label UTC-slice quirk.
	return domain.SusunTrenHarian(rows, hari, awalLokal), nil
}

// parseHariTren — padanan `Math.min(Math.max(Number(hariRaw ?? 14) || 14, 1), 90)`:
// NaN/""/"0" → 14; luar 1..90 → clamp; pecahan dipotong (iterasi hari).
func parseHariTren(raw string) int {
	f := 14.0
	if raw != "" {
		if v, err := strconv.ParseFloat(raw, 64); err == nil {
			f = v
		}
	}
	if f == 0 {
		f = 14
	}
	f = math.Min(math.Max(f, 1), 90)
	return int(f)
}

// Nilai — nilai persediaan per kelompok — delegasi LaporanService.Nilai.
func (s *DashboardService) Nilai(ctx context.Context, kelompokRaw string) ([]types.NilaiPersediaanRowView, error) {
	return s.laporan.Nilai(ctx, kelompokRaw)
}

// Backlog — gerakan terbuka — delegasi LaporanService.Backlog.
func (s *DashboardService) Backlog(ctx context.Context) ([]types.BacklogRowView, error) {
	return s.laporan.Backlog(ctx)
}

// Reorder — saldo efektif < min — delegasi LaporanService.Reorder.
func (s *DashboardService) Reorder(ctx context.Context) ([]types.ReorderRowView, error) {
	return s.laporan.Reorder(ctx)
}

// Expiring — lot kedaluwarsa (CFG-INV-12) — delegasi LaporanService.Expiring.
func (s *DashboardService) Expiring(ctx context.Context, idGudang *int64) ([]types.ExpiringRowView, error) {
	return s.laporan.Expiring(ctx, idGudang)
}
