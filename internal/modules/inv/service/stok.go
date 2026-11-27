// service/stok.go — orkestrasi fitur STOK modul inv (padanan
// services/stok/saldo.service.ts NestJS, INV-F13/F14):
//
//   - PageSaldo: baca READMODEL inv_saldo_stok (dibangun recompute;
//     soft-delete aman — recompute hanya menulis baris hidup);
//   - Recompute: full rebuild TRUNCATE + INSERT dari gerakan SELESAI via
//     repository.RecomputeSaldoStok (FUNGSI BERSAMA seed & endpoint —
//     satu-satunya jalur TRUNCATE sah di modul INV; PEMILIKAN fitur
//     GERAKAN — file repository eksport milik agent gerakan). Keputusan
//     ratifikasi modul inv: CHECK `ck_inv_saldo_on_hand` gagal → 409
//     INV-010 (bukan 500 SYS-000);
//   - Atp: jawaban ketersediaan sesuai CFG-INV-13 (ON_HAND / ATP_KETAT /
//     ATP_KETAT_BUFFER) — buffer = stok_minimum produk; produk tanpa jejak
//     stok (jasa) → selaluTersedia=true (INV-BR14: tidak pernah melebihi
//     fisik − terjadwal).
package service

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
)

// SaldoService — kebutuhan fitur saldo (DB + CFG + repo sqlc).
type SaldoService struct {
	db  *database.DB
	cfg *moduleconfig.Service
}

// NewSaldoService — konstruksi service saldo (repo sqlc tanpa state,
// dibangun per pemanggilan di repository wrapper).
func NewSaldoService(db *database.DB, cfg *moduleconfig.Service) *SaldoService {
	return &SaldoService{db: db, cfg: cfg}
}

// PageSaldo — daftar saldo paging (filter lokasi/produk/gudang/onlyBelowMin
// + search; sort whitelist di repository — persis drizzlePageBounds).
func (s *SaldoService) PageSaldo(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.SaldoStokView], error) {
	return repository.NewSaldoRepository().PageSaldoStok(ctx, s.db.Pool, pr)
}

// Recompute — recompute penuh inv_saldo_stok (opsi operasi) — TRUNCATE +
// rebuild dari gerakan SELESAI via fungsi bersama seed & API. Aman dipanggil
// manual untuk penyelarasan sweep harian. Konteks hanya info — recompute
// READMODEL tidak menulis audit bisnis.
func (s *SaldoService) Recompute(ctx context.Context) (repository.SaldoRecomputeView, error) {
	mulai := time.Now()
	var baris int64
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// PEMILIKAN: RecomputeSaldoStok = eksport repository milik fitur
		// GERAKAN (padanan repositories/stok/recompute-saldo.repository.ts).
		n, err := repository.RecomputeSaldoStok(ctx, tx)
		baris = int64(n)
		return err
	})
	if err != nil {
		// Keputusan ratifikasi modul inv: CHECK `ck_inv_saldo_on_hand`
		// (qty_on_hand >= 0, invariant INV-BR03) gagal saat rebuild → 409
		// yang jelas (bukan 500 SYS-000 generik).
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "23514" &&
			strings.Contains(pe.ConstraintName, "ck_inv_saldo_on_hand") {
			return repository.SaldoRecomputeView{}, errkontrak.Conflict(
				"Recompute saldo stok gagal — ada hasil saldo on-hand negatif dari gerakan SELESAI (invariant saldo >= 0, INV-BR03); periksa data gerakan.",
				domain.KodeInvSaldoTidakCukup,
			)
		}
		return repository.SaldoRecomputeView{}, err
	}
	return repository.SaldoRecomputeView{
		BarisDibangun: baris,
		DurasiMs:      time.Since(mulai).Milliseconds(),
	}, nil
}

// Atp — jawaban ATP (M22) sesuai CFG-INV-13; maks 200 produk per query
// (INV-BR14 — atpQuerySchema .min(1).max(200), dua pesan verbatim).
func (s *SaldoService) Atp(ctx context.Context, produkIdsRaw string) ([]repository.AtpItemView, error) {
	produkIds, err := parseIdCsvStok(produkIdsRaw, "produkIds")
	if err != nil {
		return nil, err
	}
	if len(produkIds) == 0 {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
			Field:   "produkIds",
			Message: "Wajib isi produkIds (mis. ?produkIds=1,2,3).",
		}})
	}
	if len(produkIds) > 200 {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
			Field:   "produkIds",
			Message: "Maksimal 200 produk per query (atpQuerySchema).",
		}})
	}
	mode, err := s.cfg.GetString(ctx, s.db.Pool, "inventory", "CFG-INV-13", "ATP_KETAT")
	if err != nil {
		return nil, err
	}
	rows, err := repository.NewSaldoRepository().ListSaldoAtp(ctx, s.db.Pool, produkIds)
	if err != nil {
		return nil, err
	}
	return repository.PetakanAtp(rows, mode), nil
}

// parseIdCsvStok — padanan parseIdCsv shared/inv.views.ts: string CSV id
// (`?produkIds=1,2,3`) → array angka (400 VAL-400 bila salah; raw kosong →
// array kosong — cek "wajib" ada di pemanggil). Pesan verbatim:
// `Berisi id bilangan bulat >= 1 dipisah koma (diterima: ${raw}).`
func parseIdCsvStok(raw, field string) ([]int64, error) {
	if strings.TrimSpace(raw) == "" {
		return []int64{}, nil
	}
	parts := strings.Split(raw, ",")
	ids := make([]int64, 0, len(parts))
	for _, p := range parts {
		// Number(s.trim()) — JS: "" → 0, "3.5" → pecah, "abc" → NaN.
		s := strings.TrimSpace(p)
		f, err := strconv.ParseFloat(s, 64)
		if err != nil || f != float64(int64(f)) || f < 1 {
			return nil, errkontrak.Validation([]errkontrak.FieldIssue{{
				Field:   field,
				Message: fmt.Sprintf("Berisi id bilangan bulat >= 1 dipisah koma (diterima: %s).", raw),
			}})
		}
		ids = append(ids, int64(f))
	}
	return ids, nil
}
