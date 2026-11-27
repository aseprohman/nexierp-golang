// service/lot.go — orkestrasi fitur LOT/SERIAL modul inv (padanan
// LotService NestJS INV-F07, VERBATIM urutan langkah, pesan & kode):
// identitas lot dengan saldo per lot dari READMODEL inv_saldo_stok. Lot
// dibuat manual via POST atau mengalir dari penerimaan. TANPA data-scope
// (bukan wilayah 'storages' — verbatim sumber).
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// LotService — dependensi kernel + repo lot.
type LotService struct {
	DB    *database.DB
	Audit *audit.Service
	Repo  *repository.LotRepository
}

// NewLotService — wiring dari Deps modul (dipanggil handler).
func NewLotService(d types.Deps) *LotService {
	return &LotService{DB: d.DB, Audit: d.Audit, Repo: repository.NewLotRepository()}
}

// LotCreateInput — body POST lot (hasil validasi handler; refine
// kedaluwarsa > prodiksi sudah dijaga schema zod-parity).
type LotCreateInput struct {
	IDInvProduk        int64
	Kode               string
	Barcode            *string
	TanggalProdiksi    *string
	TanggalKedaluwarsa *string
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// List — daftar lot — paginated + filter produk/status + search kode.
func (s *LotService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.LotSerialView], error) {
	return s.Repo.ListLot(ctx, s.DB.Pool, pr)
}

// Get — detail lot — 404 INV-018.
func (s *LotService) Get(ctx context.Context, id int64) (repository.LotSerialView, error) {
	row, err := s.Repo.MuatDetail(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.LotSerialView{}, err
	}
	if row == nil {
		return repository.LotSerialView{}, errkontrak.NotFound(
			fmt.Sprintf("Lot id %d tidak ditemukan.", id),
			domain.KodeInvTidakDitemukan,
		)
	}
	return repository.LotToView(row.Lot, row.KodeProduk, row.NamaProduk, row.SaldoOnHand), nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// Create — buat lot manual — kedaluwarsa wajib > prodiksi (schemas + CHECK
// DB); kode lot unik per produk (TANPA filter deleted — verbatim); barcode
// unik di antara lot HIDUP (partial — verbatim) → 409 INV-015.
func (s *LotService) Create(ctx context.Context, in LotCreateInput, actor audit.Actor) (repository.LotSerialView, error) {
	var view repository.LotSerialView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		produk, err := s.Repo.MuatProduk(ctx, tx, in.IDInvProduk)
		if err != nil {
			return err
		}
		if produk == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Produk id %d tidak ditemukan.", in.IDInvProduk),
				domain.KodeInvTidakDitemukan,
			)
		}
		dupe, err := s.Repo.CariDupeKode(ctx, tx, produk.ID, in.Kode)
		if err != nil {
			return err
		}
		if dupe != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Lot '%s' sudah ada untuk produk %s.", in.Kode, produk.KodeProduk),
			)
		}
		// Barcode lot unik di antara lot hidup (uq_inv_lot_serial_barcode).
		if in.Barcode != nil && *in.Barcode != "" {
			dupeBc, err := s.Repo.CariDupeBarcode(ctx, tx, *in.Barcode)
			if err != nil {
				return err
			}
			if dupeBc != nil {
				return errkontrak.Conflict(
					fmt.Sprintf("Barcode '%s' sudah dipakai lot lain (INV-015).", *in.Barcode),
					domain.KodeInvBarcodeTidakCocok,
				)
			}
		}
		prodiksi, err := mbTanggal(in.TanggalProdiksi)
		if err != nil {
			return err
		}
		kedaluwarsa, err := mbTanggal(in.TanggalKedaluwarsa)
		if err != nil {
			return err
		}
		row, err := s.Repo.InsertLot(ctx, tx, repository.LotBaru{
			EntityID:           numberingEntityID(),
			IDInvProduk:        produk.ID,
			Kode:               in.Kode,
			Barcode:            in.Barcode,
			TanggalProdiksi:    prodiksi,
			TanggalKedaluwarsa: kedaluwarsa,
		})
		if err != nil {
			// Race unik (kode per produk / barcode hidup) → 409 pesan
			// pre-check; pilih pesan sesuai guard yang tergolok.
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(
					fmt.Sprintf("Lot '%s' sudah ada untuk produk %s.", in.Kode, produk.KodeProduk),
				)
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_lot_serial",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode, "produk": produk.KodeProduk},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.LotToView(row, produk.KodeProduk, produk.Nama, 0)
		return nil
	})
	if err != nil {
		return repository.LotSerialView{}, err
	}
	return view, nil
}

// mbTanggal — string ISO → *time.Time (padanan `new Date(str)`): date-only
// = UTC (spesifikasi JS), lainnya RFC3339 offset / naive (UTC server).
func mbTanggal(raw *string) (*time.Time, error) {
	if raw == nil || *raw == "" {
		return nil, nil
	}
	s := *raw
	layouts := []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05.999",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05.999",
		"2006-01-02 15:04:05",
		"2006-01-02",
	}
	for i, layout := range layouts {
		if t, err := time.Parse(layout, s); err == nil {
			// "2006-01-02" tanpa offset = UTC (padanan new Date("yyyy-mm-dd")).
			if i == len(layouts)-1 && layout == "2006-01-02" {
				t = time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
			}
			return &t, nil
		}
	}
	// Format liar (Invalid Date di JS → gagal binding → 500 generik).
	return nil, errkontrak.Internal("")
}
