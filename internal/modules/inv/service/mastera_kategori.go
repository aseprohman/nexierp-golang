// mastera_kategori.go — service fitur KATEGORI PRODUK modul inv (padanan
// KategoriService NestJS INV-F01 — master kebijakan stok & valuasi):
// soft delete semua query; hapus diblokir bila punya kategori anak ATAU
// produk (INV-002); ubah metode valuasi ditolak bila punya mutasi gerakan
// (INV-011); optimistic locking version (STD-07 — 409 INV-017); mutasi dalam
// satu pgx.Tx + audit append dalam transaksi yang sama.
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

// KategoriService — fitur kategori produk.
type KategoriService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.KategoriRepository
}

// NewKategoriService membuat service kategori.
func NewKategoriService(db *database.DB, aud *audit.Service) *KategoriService {
	return &KategoriService{db: db, auid: aud, repo: repository.NewKategori()}
}

/* ------------------------------------------------------------------ */
/* Input DTO                                                          */
/* ------------------------------------------------------------------ */

// KategoriBuatInput — kategoriProdukCreateSchema (default zod di handler).
type KategoriBuatInput struct {
	Nama                 string
	IDKategoriInduk      *int64
	MetodeValuasi        string
	SistemValuasi        string
	KebijakanPelacakan   string
	KebijakanKedaluwarsa bool
	Status               string
}

// KategoriUbahInput — kategoriProdukUpdateSchema (parsial + version).
type KategoriUbahInput struct {
	Nama                 *string
	IDKategoriInduk      *int64
	IDKategoriIndukAda   bool // tri-state zod (key hadir termasuk null)
	MetodeValuasi        *string
	SistemValuasi        *string
	KebijakanPelacakan   *string
	KebijakanKedaluwarsa *bool
	Status               *string
	Version              int32
}

/* ------------------------------------------------------------------ */
/* Baca                                                               */
/* ------------------------------------------------------------------ */

// List — daftar kategori paginated + filter status + search nama.
func (s *KategoriService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.KategoriProdukView], error) {
	f := repository.FilterKategori{
		Status: pr.Filters["status"],
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"nama": "nama", "created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "nama")
	rows, total, err := s.repo.ListKategori(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.KategoriProdukView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail kategori — 404 INV-018 bila tidak ada / terhapus.
func (s *KategoriService) Get(ctx context.Context, id int64) (types.KategoriProdukView, error) {
	row, err := s.repo.MuatDetail(ctx, s.db.Pool, id)
	if err != nil {
		return types.KategoriProdukView{}, err
	}
	if row == nil {
		return types.KategoriProdukView{}, errkontrak.NotFound(
			"Kategori id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
	}
	return *row, nil
}

/* ------------------------------------------------------------------ */
/* Tulis                                                              */
/* ------------------------------------------------------------------ */

// Create — buat kategori — nama unik di antara baris hidup (partial unique).
func (s *KategoriService) Create(ctx context.Context, in KategoriBuatInput, actor audit.Actor) (types.KategoriProdukView, error) {
	var out types.KategoriProdukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if in.IDKategoriInduk != nil {
			if _, err := s.repo.AssertAda(ctx, tx, *in.IDKategoriInduk); err != nil {
				return err
			}
		}
		if err := s.assertNamaBebas(ctx, tx, in.Nama, nil); err != nil {
			return err
		}
		row, err := s.repo.Insert(ctx, tx, repository.KategoriBaru{
			EntityID:             numbering.NewEntityID(),
			Nama:                 in.Nama,
			IDKategoriInduk:      in.IDKategoriInduk,
			MetodeValuasi:        in.MetodeValuasi,
			SistemValuasi:        in.SistemValuasi,
			KebijakanPelacakan:   in.KebijakanPelacakan,
			KebijakanKedaluwarsa: in.KebijakanKedaluwarsa,
			Status:               in.Status,
		})
		if err != nil {
			return mapUniqueKategori(err, in.Nama)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_kategori_produk",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: map[string]any{"nama": row.Nama, "metode_valuasi": row.MetodeValuasi},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		// toKategoriView(row, null, false) — verbatim sumber.
		out = repository.ToKategoriView(row, nil, false)
		return nil
	})
	if err != nil {
		return types.KategoriProdukView{}, err
	}
	return out, nil
}

// Update — ubah kategori — versi wajib cocok (409 INV-017); ubah metode
// valuasi ditolak bila punya mutasi (409 INV-011).
func (s *KategoriService) Update(ctx context.Context, id int64, in KategoriUbahInput, actor audit.Actor) (types.KategoriProdukView, error) {
	var out types.KategoriProdukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiKategoriBentrok(row.Version, in.Version)
		}
		punyaMutasi, err := s.repo.AdaMutasi(ctx, tx, id)
		if err != nil {
			return err
		}
		if in.MetodeValuasi != nil && *in.MetodeValuasi != row.MetodeValuasi && punyaMutasi {
			return errkontrak.Conflict(
				"Kategori sudah memiliki mutasi gerakan — metode valuasi tidak boleh diubah (koreksi hanya via penyesuaian valuasi).",
				"INV-011")
		}
		if in.Nama != nil && *in.Nama != row.Nama {
			if err := s.assertNamaBebas(ctx, tx, *in.Nama, &id); err != nil {
				return err
			}
		}
		set := repository.KategoriUbahSet{
			Nama:                 row.Nama,
			IDKategoriInduk:      row.IDKategoriInduk,
			MetodeValuasi:        row.MetodeValuasi,
			SistemValuasi:        row.SistemValuasi,
			KebijakanPelacakan:   row.KebijakanPelacakan,
			KebijakanKedaluwarsa: row.KebijakanKedaluwarsa,
			Status:               row.Status,
			Version:              row.Version + 1,
			UpdatedAt:            time.Now(),
		}
		if in.Nama != nil {
			set.Nama = *in.Nama
		}
		if in.IDKategoriIndukAda {
			set.IDKategoriInduk = in.IDKategoriInduk // null → NULL (persis !== undefined)
		}
		if in.MetodeValuasi != nil {
			set.MetodeValuasi = *in.MetodeValuasi
		}
		if in.SistemValuasi != nil {
			set.SistemValuasi = *in.SistemValuasi
		}
		if in.KebijakanPelacakan != nil {
			set.KebijakanPelacakan = *in.KebijakanPelacakan
		}
		if in.KebijakanKedaluwarsa != nil {
			set.KebijakanKedaluwarsa = *in.KebijakanKedaluwarsa
		}
		if in.Status != nil {
			set.Status = *in.Status
		}
		updated, err := s.repo.Update(ctx, tx, id, in.Version, set)
		if err != nil {
			return err
		}
		if updated == nil {
			// Optimistic locking atomik: kalah balapan → 0 baris → 409 INV-017.
			return versiKategoriBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_kategori_produk",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				BeforeValue: map[string]any{
					"nama": row.Nama, "metode_valuasi": row.MetodeValuasi, "version": row.Version,
				},
				AfterValue: map[string]any{
					"nama": updated.Nama, "metode_valuasi": updated.MetodeValuasi, "version": updated.Version,
				},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		var namaInduk *string
		if updated.IDKategoriInduk != nil {
			indukRow, err := s.repo.AssertAda(ctx, s.db.Pool, *updated.IDKategoriInduk)
			if err != nil {
				return err
			}
			namaInduk = &indukRow.Nama
		}
		out = repository.ToKategoriView(*updated, namaInduk, punyaMutasi)
		return nil
	})
	if err != nil {
		return types.KategoriProdukView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — blokir bila punya anak/produk (409 INV-002).
func (s *KategoriService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertAda(ctx, tx, id)
		if err != nil {
			return err
		}
		anak, err := s.repo.HitungAnak(ctx, tx, id)
		if err != nil {
			return err
		}
		produk, err := s.repo.HitungProduk(ctx, tx, id)
		if err != nil {
			return err
		}
		if anak > 0 || produk > 0 {
			return errkontrak.Conflict(
				"Kategori masih dipakai (punya kategori anak atau produk) — tidak bisa dihapus, gunakan status NONAKTIF.",
				"INV-002")
		}
		now := time.Now()
		if err := s.repo.HapusLunak(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_kategori_produk",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "delete",
				BeforeValue: map[string]any{"nama": row.Nama},
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

// assertNamaBebas — nama unik di antara baris hidup — 409 duplikat verbatim.
func (s *KategoriService) assertNamaBebas(ctx context.Context, exec pgx.Tx, nama string, kecualiID *int64) error {
	dupe, err := s.repo.CariDupeNama(ctx, exec, nama, kecualiID)
	if err != nil {
		return err
	}
	if dupe {
		return errkontrak.Conflict("Nama kategori '" + nama + "' sudah dipakai kategori lain.")
	}
	return nil
}

// versiKategoriBentrok — 409 INV-017 pesan verbatim kategori.
func versiKategoriBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi kategori tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+") — muat ulang lalu ulangi.",
		"INV-017")
}

// mapUniqueKategori — race 23505 → 409 pesan pre-check verbatim.
func mapUniqueKategori(err error, nama string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	if pe.ConstraintName == "uq_inv_kategori_produk_nama" || pe.ConstraintName == "uq_inv_kategori_produk_entity_id" {
		return errkontrak.Conflict("Nama kategori '" + nama + "' sudah dipakai kategori lain.")
	}
	return err
}
