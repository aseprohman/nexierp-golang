// mastera_kemasan.go — service fitur KEMASAN modul inv (padanan
// KemasanService NestJS — patch 04 P1 #10): kemasan jual per produk untuk
// pemindaian barcode → produk × qty_isi (F15). kode unik GLOBAL (sesuai DB
// — pre-check tanpa deleted_at); barcode partial-unique hidup (pakai ulang
// setelah hapus); qty_isi > 0 (CHECK DB); optimistic locking STD-07 —
// 409 INV-017; mutasi dalam satu pgx.Tx + audit append. Lookup barcode tak
// terdaftar → 404 INV-015 BARCODE_TIDAK_COCOK.
package service

import (
	"context"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/numbering"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// KemasanService — fitur kemasan.
type KemasanService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.KemasanRepository
}

// NewKemasanService membuat service kemasan.
func NewKemasanService(db *database.DB, aud *audit.Service) *KemasanService {
	return &KemasanService{db: db, auid: aud, repo: repository.NewKemasan()}
}

/* ------------------------------------------------------------------ */
/* Input DTO                                                          */
/* ------------------------------------------------------------------ */

// KemasanBuatInput — kemasanCreateSchema.
type KemasanBuatInput struct {
	IDInvProduk   int64
	Kode          string
	Nama          string
	Barcode       *string
	IDInvUnitUkur int64
	QtyIsi        int32
	Status        string
}

// KemasanUbahInput — kemasanUpdateSchema (parsial + version).
type KemasanUbahInput struct {
	IDInvProduk   *int64
	Kode          *string
	Nama          *string
	Barcode       *string
	BarcodeAda    bool // tri-state zod (key hadir termasuk null)
	IDInvUnitUkur *int64
	QtyIsi        *int32
	Status        *string
	Version       int32
}

/* ------------------------------------------------------------------ */
/* Baca                                                               */
/* ------------------------------------------------------------------ */

// List — daftar kemasan — filter produk/status + search kode/nama/barcode.
func (s *KemasanService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.KemasanView], error) {
	f := repository.FilterKemasan{
		Status: pr.Filters["status"],
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	if raw := pr.Filters["idProduk"]; raw != "" {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n < 1 {
			return errkontrak.Page[types.KemasanView]{}, errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "idProduk", Message: "Harus bilangan bulat >= 1 (diterima: " + raw + ")."},
			})
		}
		f.IDProduk = &n
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"kode": "kode", "created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "kode")
	rows, total, err := s.repo.ListKemasan(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.KemasanView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail kemasan — 404 INV-018.
func (s *KemasanService) Get(ctx context.Context, id int64) (types.KemasanView, error) {
	view, err := s.repo.MuatViewHidupById(ctx, s.db.Pool, id)
	if err != nil {
		return types.KemasanView{}, err
	}
	if view == nil {
		return types.KemasanView{}, errkontrak.NotFound(
			"Kemasan id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
	}
	return *view, nil
}

// Lookup — barcode kemasan → {kemasan, produk, qtyIsi}; tak terdaftar →
// 404 INV-015 `Barcode '${barcode}' tidak cocok dengan kemasan manapun.`
func (s *KemasanService) Lookup(ctx context.Context, barcode string) (types.KemasanLookupView, error) {
	hasil, err := s.repo.CariBarcodeView(ctx, s.db.Pool, barcode)
	if err != nil {
		return types.KemasanLookupView{}, err
	}
	if hasil == nil {
		return types.KemasanLookupView{}, errkontrak.NotFound(
			"Barcode '"+barcode+"' tidak cocok dengan kemasan manapun.",
			"INV-015")
	}
	return *hasil, nil
}

/* ------------------------------------------------------------------ */
/* Tulis                                                              */
/* ------------------------------------------------------------------ */

// Create — buat kemasan — kode unik GLOBAL + barcode unik hidup.
func (s *KemasanService) Create(ctx context.Context, in KemasanBuatInput, actor audit.Actor) (types.KemasanView, error) {
	var out types.KemasanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.AssertProdukAda(ctx, tx, in.IDInvProduk); err != nil {
			return err
		}
		if err := s.repo.AssertKodeBebas(ctx, tx, in.Kode, nil); err != nil {
			return err
		}
		if in.Barcode != nil && *in.Barcode != "" {
			if err := s.repo.AssertBarcodeBebas(ctx, tx, *in.Barcode, nil); err != nil {
				return err
			}
		}
		row, err := s.repo.InsertKemasan(ctx, tx, repository.KemasanBaru{
			EntityID:      numbering.NewEntityID(),
			IDInvProduk:   in.IDInvProduk,
			Kode:          in.Kode,
			Nama:          in.Nama,
			Barcode:       barisBarcode(in.Barcode),
			IDInvUnitUkur: in.IDInvUnitUkur,
			QtyIsi:        in.QtyIsi,
			Status:        in.Status,
		})
		if err != nil {
			return mapUniqueKemasan(err, in.Kode, in.Barcode)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_kemasan",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: map[string]any{"kode": row.Kode, "produk": in.IDInvProduk, "qty_isi": row.QtyIsi},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		v, err := s.repo.MuatViewBaris(ctx, tx, row.ID)
		if err != nil {
			return err
		}
		out = v
		return nil
	})
	if err != nil {
		return types.KemasanView{}, err
	}
	return out, nil
}

// Update — ubah kemasan — versi wajib cocok (409 INV-017).
func (s *KemasanService) Update(ctx context.Context, id int64, in KemasanUbahInput, actor audit.Actor) (types.KemasanView, error) {
	var out types.KemasanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKemasan(ctx, tx, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiKemasanBentrok(row.Version, in.Version)
		}
		if in.Kode != nil && *in.Kode != row.Kode {
			if err := s.repo.AssertKodeBebas(ctx, tx, *in.Kode, &id); err != nil {
				return err
			}
		}
		if in.Barcode != nil && *in.Barcode != "" &&
			(row.Barcode == nil || *in.Barcode != *row.Barcode) {
			if err := s.repo.AssertBarcodeBebas(ctx, tx, *in.Barcode, &id); err != nil {
				return err
			}
		}
		set := repository.KemasanUbahSet{
			IDInvProduk:   row.IDInvProduk,
			Kode:          row.Kode,
			Nama:          row.Nama,
			Barcode:       row.Barcode,
			IDInvUnitUkur: row.IDInvUnitUkur,
			QtyIsi:        row.QtyIsi,
			Status:        row.Status,
			Version:       row.Version + 1,
			UpdatedAt:     time.Now(),
		}
		if in.IDInvProduk != nil {
			set.IDInvProduk = *in.IDInvProduk
		}
		if in.Kode != nil {
			set.Kode = *in.Kode
		}
		if in.Nama != nil {
			set.Nama = *in.Nama
		}
		// barcode: undefined = tetap; null/"" → NULL (input.barcode || null).
		if in.BarcodeAda {
			if in.Barcode == nil || *in.Barcode == "" {
				set.Barcode = nil
			} else {
				set.Barcode = in.Barcode
			}
		}
		if in.IDInvUnitUkur != nil {
			set.IDInvUnitUkur = *in.IDInvUnitUkur
		}
		if in.QtyIsi != nil {
			set.QtyIsi = *in.QtyIsi
		}
		if in.Status != nil {
			set.Status = *in.Status
		}
		ubah, err := s.repo.UpdateSetVersiHidup(ctx, tx, id, set, in.Version)
		if err != nil {
			return err
		}
		if !ubah {
			// Optimistic locking atomik: kalah balapan → 0 baris → 409 INV-017.
			return versiKemasanBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_kemasan",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				BeforeValue: map[string]any{
					"kode": row.Kode, "version": row.Version,
				},
				AfterValue: map[string]any{
					"kode": kodeAtauRow(in.Kode, row.Kode), "version": row.Version + 1,
				},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		v, err := s.repo.MuatViewBaris(ctx, tx, id)
		if err != nil {
			return err
		}
		out = v
		return nil
	})
	if err != nil {
		return types.KemasanView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — kemasan tidak direferensikan gerakan (aman).
func (s *KemasanService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKemasan(ctx, tx, id)
		if err != nil {
			return err
		}
		now := time.Now()
		if err := s.repo.SoftDeleteHidupById(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_kemasan",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "delete",
				BeforeValue: map[string]any{"kode": row.Kode},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

/* ------------------------------------------------------------------ */
/* Internal                                                           */
/* ------------------------------------------------------------------ */

// versiKemasanBentrok — 409 INV-017 pesan verbatim kemasan.
func versiKemasanBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi kemasan tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+").",
		"INV-017")
}

// kodeAtauRow — padanan `input.kode ?? row.kode` utk audit afterValue.
func kodeAtauRow(kode *string, fallback string) string {
	if kode != nil {
		return *kode
	}
	return fallback
}

// mapUniqueKemasan — race 23505 → 409 pesan pre-check verbatim (constraint
// menentukan pesan: kode GLOBAL / barcode partial).
func mapUniqueKemasan(err error, kode string, barcode *string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	switch pe.ConstraintName {
	case "uq_inv_kemasan_kode":
		return errkontrak.Conflict("Kode kemasan '" + kode + "' sudah dipakai.")
	case "uq_inv_kemasan_barcode":
		bc := ""
		if barcode != nil {
			bc = *barcode
		}
		return errkontrak.Conflict("Barcode '"+bc+"' sudah dipakai kemasan lain.", "INV-015")
	}
	return err
}
