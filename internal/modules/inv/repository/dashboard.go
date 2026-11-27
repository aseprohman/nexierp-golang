// Package repository — SATU-SATUNYA pengguna pgx+sqlc modul inv.
// dashboard.go — fitur DASHBOARD INVENTORY (INV-F14): agregat skalar KPI +
// tren gerakan harian — padanan DashboardRepository NestJS. Row → struct
// murni domain di sini (mapper view ada di domain); executor (pool | tx)
// diteruskan pemanggil. Helper konversi pgtype dipakai dari helpers.go.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository/gen"
)

// DashboardRepository — baca non-transaksi (service meneruskan executor).
type DashboardRepository struct{}

// NewDashboardRepository membuat repository dashboard.
func NewDashboardRepository() *DashboardRepository { return &DashboardRepository{} }

// lpWaktu — time.Time → pgtype.Timestamptz (prefix `lp` = fitur
// dashboard/laporan — pengaman kolisi nama package repository yang sama).
func lpWaktu(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

// HitungSku — total SKU hidup + berstatus AKTIF.
func (r *DashboardRepository) HitungSku(ctx context.Context, exec DBTX) (total int64, aktif int64, err error) {
	row, err := gen.New(exec).HitungSku(ctx)
	if err != nil {
		return 0, 0, err
	}
	return int64(row.Total), int64(row.Aktif), nil
}

// MuatTotalNilaiPersediaan — Σ nilai persediaan READMODEL saldo (JSON number).
func (r *DashboardRepository) MuatTotalNilaiPersediaan(ctx context.Context, exec DBTX) (float64, error) {
	n, err := gen.New(exec).MuatTotalNilaiPersediaan(ctx)
	if err != nil {
		return 0, err
	}
	return Angka0(n), nil
}

// HitungGerakanSejak — gerakan dibuat sejak awalHari (00:00 lokal).
func (r *DashboardRepository) HitungGerakanSejak(ctx context.Context, exec DBTX, awalHari time.Time) (int64, error) {
	n, err := gen.New(exec).HitungGerakanSejak(ctx, lpWaktu(awalHari))
	return int64(n), err
}

// HitungGerakanTerbuka — status bukan SELESAI/BATAL.
func (r *DashboardRepository) HitungGerakanTerbuka(ctx context.Context, exec DBTX) (int64, error) {
	n, err := gen.New(exec).HitungGerakanTerbuka(ctx)
	return int64(n), err
}

// HitungPenyesuaianMenunggu — status MENUNGGU_PERSETUJUAN.
func (r *DashboardRepository) HitungPenyesuaianMenunggu(ctx context.Context, exec DBTX) (int64, error) {
	n, err := gen.New(exec).HitungPenyesuaianMenunggu(ctx)
	return int64(n), err
}

// HitungLotKedaluwarsaBersaldo — kedaluwarsa lewat + masih bersaldo.
func (r *DashboardRepository) HitungLotKedaluwarsaBersaldo(ctx context.Context, exec DBTX) (int64, error) {
	n, err := gen.New(exec).HitungLotKedaluwarsaBersaldo(ctx)
	return int64(n), err
}

// ListProdukBawahMinimum — agregat saldo efektif per produk (sumber domain
// HitungBawahMinimum).
func (r *DashboardRepository) ListProdukBawahMinimum(ctx context.Context, exec DBTX) ([]domain.ProdukBawahMinRow, error) {
	rows, err := gen.New(exec).ListProdukBawahMinimum(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProdukBawahMinRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, domain.ProdukBawahMinRow{
			ID:           row.ID,
			Minimum:      int64(row.Minimum),
			ReorderAktif: row.ReorderAktif,
			OnHand:       int64(row.OnHand),
			Dipesan:      int64(row.Dipesan),
		})
	}
	return out, nil
}

// ListTrenHarian — tren gerakan SELESAI per hari; awal = 00:00 hari
// pertama, sekarang = batas atas query (verbatim).
func (r *DashboardRepository) ListTrenHarian(ctx context.Context, exec DBTX, awal time.Time) ([]domain.TrenHarianRow, error) {
	rows, err := gen.New(exec).ListTrenHarian(ctx, gen.ListTrenHarianParams{
		Awal:     lpWaktu(awal),
		Sekarang: lpWaktu(time.Now()),
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.TrenHarianRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, domain.TrenHarianRow{
			Tanggal:     row.Tanggal,
			Masuk:       int64(row.Masuk),
			Keluar:      int64(row.Keluar),
			NilaiMasuk:  Angka0(row.NilaiMasuk),
			NilaiKeluar: Angka0(row.NilaiKeluar),
		})
	}
	return out, nil
}
