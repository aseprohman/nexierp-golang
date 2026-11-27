// mastera_induk.go — service fitur PRODUK INDUK modul inv (padanan
// ProdukIndukService NestJS — patch 06 hierarki mandiri D-42): induk adalah
// baris inv_produk sendiri (adalahIndukVarian, id_induk NULL). REPLACE
// konfigurasi atribut satu UoW (soft delete lama + sisip baru + bump version
// TANPA filter hidup); generate varian satu kombinasi per panggilan (D-19,
// 409 INV-016, SKU `${induk}-${nilaiTeks}`, warisan induk, versi induk TIDAK
// bump); hapus induk diblokir selama punya varian hidup (D-21).
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
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// ProdukIndukService — fitur produk induk.
type ProdukIndukService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.ProdukIndukRepository
}

// NewProdukIndukService membuat service produk induk.
func NewProdukIndukService(db *database.DB, aud *audit.Service) *ProdukIndukService {
	return &ProdukIndukService{db: db, auid: aud, repo: repository.NewProdukInduk()}
}

/* ------------------------------------------------------------------ */
/* Input DTO                                                          */
/* ------------------------------------------------------------------ */

// IndukBuatInput — produkIndukCreateSchema.
type IndukBuatInput struct {
	Kode                string
	Nama                string
	Deskripsi           *string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	Status              string
}

// IndukUbahInput — produkIndukUpdateSchema (parsial + version).
type IndukUbahInput struct {
	Nama                *string
	Deskripsi           *string
	DeskripsiAda        bool // tri-state zod (key hadir termasuk null)
	IDInvKategoriProduk *int64
	IDInvUnitUkur       *int64
	Status              *string
	Version             int32
}

// IndukAtributItem — baris konfigurasi atribut induk (LINE).
type IndukAtributItem struct {
	IDInvAtribut int64
	Wajib        bool
	Urutan       int32
}

// IndukAtributReplaceInput — indukAtributReplaceSchema (REPLACE penuh).
type IndukAtributReplaceInput struct {
	Items   []IndukAtributItem
	Version int32
}

// VarianGenerateInput — varianGenerateSchema (SATU kombinasi).
type VarianGenerateInput struct {
	Kombinasi  []VarianNilaiItem
	HargaJual  *float64
	HargaBiaya *float64
}

/* ------------------------------------------------------------------ */
/* Baca                                                               */
/* ------------------------------------------------------------------ */

// List — daftar induk paginated + search + jumlah varian.
func (s *ProdukIndukService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.ProdukIndukView], error) {
	f := repository.FilterInduk{
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"kode": "kode", "nama": "nama",
		"created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "kode")
	rows, total, err := s.repo.ListProdukInduk(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.ProdukIndukView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail induk — 404 INV-018.
func (s *ProdukIndukService) Get(ctx context.Context, id int64) (types.ProdukIndukView, error) {
	return s.repo.GetProdukInduk(ctx, s.db.Pool, id)
}

/* ------------------------------------------------------------------ */
/* Tulis                                                              */
/* ------------------------------------------------------------------ */

// Create — buat induk = baris inv_produk template + tandai induk.
func (s *ProdukIndukService) Create(ctx context.Context, in IndukBuatInput, actor audit.Actor) (types.ProdukIndukView, error) {
	var out types.ProdukIndukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.AssertKodeIndukBebas(ctx, tx, in.Kode); err != nil {
			return err
		}
		row, err := s.repo.InsertProduk(ctx, tx, repository.ProdukBaru{
			EntityID:            numbering.NewEntityID(),
			KodeProduk:          in.Kode,
			Nama:                in.Nama,
			Tipe:                "BARANG",
			IDInvKategoriProduk: in.IDInvKategoriProduk,
			IDInvUnitUkur:       in.IDInvUnitUkur,
			JejakStok:           true,
			Keterangan:          in.Deskripsi,
			Status:              in.Status,
			AdalahIndukVarian:   true,
		})
		if err != nil {
			return mapUniqueInduk(err, in.Kode)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_produk_induk",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: map[string]any{"kode": row.KodeProduk, "nama": row.Nama},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		// Respons create: label kategori/unit = "" (quirk verbatim sumber —
		// create mengembalikan view tanpa memuat peta referensi).
		out = repository.ProdukIndukToView(row, 0, []repository.KonfigurasiAtributInduk{}, map[int64]string{}, map[int64]string{})
		return nil
	})
	if err != nil {
		return types.ProdukIndukView{}, err
	}
	return out, nil
}

// Update — ubah induk — versi wajib cocok; kategori/unit terkunci selama
// punya varian (D-39). Respons label kategori/unit = "" (quirk verbatim).
func (s *ProdukIndukService) Update(ctx context.Context, id int64, in IndukUbahInput, actor audit.Actor) (types.ProdukIndukView, error) {
	var out types.ProdukIndukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertInduk memakai executor NON-tx (this.db).
		row, err := s.repo.AssertInduk(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiIndukBentrok(row.Version, in.Version)
		}
		punyaVarian, err := s.repo.HitungVarianHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if punyaVarian > 0 && in.IDInvKategoriProduk != nil && *in.IDInvKategoriProduk != row.IDInvKategoriProduk {
			return errkontrak.BadRequest(
				"Kategori induk terkunci selama punya varian hidup — varian mewarisi kategori induk (D-39).")
		}
		if punyaVarian > 0 && in.IDInvUnitUkur != nil && *in.IDInvUnitUkur != row.IDInvUnitUkur {
			return errkontrak.BadRequest(
				"Unit induk terkunci selama punya varian hidup — varian mewarisi unit induk (D-39).")
		}
		set := repository.IndukUbahSet{
			Nama:                row.Nama,
			Keterangan:          row.Keterangan,
			IDInvKategoriProduk: row.IDInvKategoriProduk,
			IDInvUnitUkur:       row.IDInvUnitUkur,
			Status:              row.Status,
			Version:             row.Version + 1,
			UpdatedAt:           time.Now(),
		}
		if in.Nama != nil {
			set.Nama = *in.Nama
		}
		if in.DeskripsiAda {
			set.Keterangan = in.Deskripsi // null → NULL
		}
		if in.IDInvKategoriProduk != nil {
			set.IDInvKategoriProduk = *in.IDInvKategoriProduk
		}
		if in.IDInvUnitUkur != nil {
			set.IDInvUnitUkur = *in.IDInvUnitUkur
		}
		if in.Status != nil {
			set.Status = *in.Status
		}
		updated, err := s.repo.UpdateIndukVersiHidup(ctx, tx, id, set, in.Version)
		if err != nil {
			return err
		}
		if updated == nil {
			// Optimistic locking atomik: kalah balapan → 0 baris → 409 INV-017.
			return versiIndukBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_produk_induk",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				AfterValue: map[string]any{"kode": updated.KodeProduk, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		// Respons update: label kategori/unit = "" (quirk verbatim sumber —
		// new Map([[id, ""]])).
		kategori := map[int64]string{updated.IDInvKategoriProduk: ""}
		unit := map[int64]string{updated.IDInvUnitUkur: ""}
		out = repository.ProdukIndukToView(*updated, punyaVarian, []repository.KonfigurasiAtributInduk{}, kategori, unit)
		return nil
	})
	if err != nil {
		return types.ProdukIndukView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — blokir selama masih punya varian hidup (D-21).
func (s *ProdukIndukService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertInduk memakai executor NON-tx (this.db).
		row, err := s.repo.AssertInduk(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		jumlahVarian, err := s.repo.HitungVarianHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if jumlahVarian > 0 {
			return errkontrak.Conflict(
				"Induk masih punya varian hidup — hapus varian dulu (D-21).",
				"INV-002")
		}
		now := time.Now()
		if err := s.repo.SoftDeleteIndukHidup(ctx, tx, id, now, now); err != nil {
			return err
		}
		if err := s.repo.SoftDeleteKonfigHidupByProduk(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_produk_induk",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "delete",
				BeforeValue: map[string]any{"kode": row.KodeProduk},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

// ReplaceAtribut — REPLACE konfigurasi atribut induk (LINE) satu UoW:
// soft delete baris lama + sisip baru + bump version TANPA filter hidup.
func (s *ProdukIndukService) ReplaceAtribut(ctx context.Context, id int64, in IndukAtributReplaceInput, actor audit.Actor) (types.ProdukIndukView, error) {
	var out types.ProdukIndukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertInduk memakai executor NON-tx (this.db).
		row, err := s.repo.AssertInduk(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiIndukBentrok(row.Version, in.Version)
		}
		// Atribut yang dirujuk wajib hidup.
		atributIds := make([]int64, 0, len(in.Items))
		seen := map[int64]bool{}
		for _, i := range in.Items {
			if !seen[i.IDInvAtribut] {
				seen[i.IDInvAtribut] = true
				atributIds = append(atributIds, i.IDInvAtribut)
			}
		}
		if len(atributIds) > 0 {
			ada, err := s.repo.ListAtributHidupByIds(ctx, tx, atributIds)
			if err != nil {
				return err
			}
			if len(ada) != len(atributIds) {
				return errkontrak.NotFound(
					"Ada atribut konfigurasi yang tidak ditemukan.", "INV-018")
			}
		}
		// Soft delete baris lama + sisip baris baru (satu transaksi).
		lama, err := s.repo.ListIdKonfigHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if len(lama) > 0 {
			now := time.Now()
			if err := s.repo.SoftDeleteKonfigHidupByProduk(ctx, tx, id, now, now); err != nil {
				return err
			}
		}
		if len(in.Items) > 0 {
			barisan := make([]repository.KonfigBaru, 0, len(in.Items))
			for _, i := range in.Items {
				barisan = append(barisan, repository.KonfigBaru{
					EntityID:     numbering.NewEntityID(),
					IDInvProduk:  id,
					IDInvAtribut: i.IDInvAtribut,
					Wajib:        i.Wajib,
					Urutan:       i.Urutan,
				})
			}
			if err := s.repo.InsertKonfigBanyak(ctx, tx, barisan); err != nil {
				return err
			}
		}
		// Optimistic locking atomik STD-07 — bump version TANPA filter hidup
		// (verbatim: WHERE id + version SAJA; drizzle returning() = baris penuh).
		updated, err := s.repo.UpdateProdukVersiTanpaHidup(ctx, tx, id, row.Version+1, in.Version, time.Now())
		if err != nil {
			return err
		}
		if updated == nil {
			return versiIndukBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_produk_induk_atribut",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "replace",
				BeforeValue: map[string]any{"jumlah": len(lama)},
				AfterValue:  map[string]any{"jumlah": len(in.Items), "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		ids := []int64{id}
		varianMap, err := s.repo.HitungVarianMap(ctx, s.db.Pool, ids)
		if err != nil {
			return err
		}
		atributMap, err := s.repo.MuatKonfigurasiAtribut(ctx, s.db.Pool, ids)
		if err != nil {
			return err
		}
		kategori, unit, err := repository.MuatPetaKategoriUnit(ctx, s.db.Pool)
		if err != nil {
			return err
		}
		out = repository.ProdukIndukToView(*updated, varianMap[id], atributMap[id], kategori, unit)
		return nil
	})
	if err != nil {
		return types.ProdukIndukView{}, err
	}
	return out, nil
}

// GenerateVarian — SATU panggilan = SATU kombinasi varian (D-19): validasi
// pasangan/kelengkapan INV-016 (400/409 PERSIS), kombinasi unik, SKU varian
// `${induk.kode}-${nilaiTeks}`, warisan induk, junction nilai; versi induk
// TIDAK bump.
func (s *ProdukIndukService) GenerateVarian(ctx context.Context, id int64, in VarianGenerateInput, actor audit.Actor) (map[string]any, error) {
	var out map[string]any
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertInduk + konfigurasi memakai executor NON-tx.
		induk, err := s.repo.AssertInduk(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		konfigurasiMap, err := s.repo.MuatKonfigurasiAtribut(ctx, s.db.Pool, []int64{id})
		if err != nil {
			return err
		}
		konfigurasi := konfigurasiMap[id]
		konfigDomain := make([]domain.KonfigAtribut, 0, len(konfigurasi))
		for _, k := range konfigurasi {
			konfigDomain = append(konfigDomain, domain.KonfigAtribut{
				IDInvAtribut: k.IDInvAtribut, KodeAtribut: k.KodeAtribut, Wajib: k.Wajib,
			})
		}
		// Muat nilai atribut yang dirujuk (hidup).
		nilaiIds := uniqueInt64(func() []int64 {
			ids := make([]int64, 0, len(in.Kombinasi))
			for _, k := range in.Kombinasi {
				ids = append(ids, k.IDInvNilaiAtribut)
			}
			return ids
		}())
		nilaiRows, err := s.repo.ListNilaiAtributHidup(ctx, tx, nilaiIds)
		if err != nil {
			return err
		}
		nilaiDomain := make([]domain.NilaiAtribut, 0, len(nilaiRows))
		nilaiById := map[int64]repository.NilaiAtributHidup{}
		for _, n := range nilaiRows {
			nilaiDomain = append(nilaiDomain, domain.NilaiAtribut{ID: n.ID, IDInvAtribut: n.IDInvAtribut, Nilai: n.Nilai})
			nilaiById[n.ID] = n
		}
		pasangan := make([]domain.PasanganVarian, 0, len(in.Kombinasi))
		for _, k := range in.Kombinasi {
			pasangan = append(pasangan, domain.PasanganVarian{
				IDInvAtribut:      k.IDInvAtribut,
				IDInvNilaiAtribut: k.IDInvNilaiAtribut,
			})
		}
		hasil, err := domain.ValidasiKombinasiGenerate(pasangan, konfigDomain, nilaiDomain)
		if err != nil {
			return err
		}
		// Kombinasi unik per induk — cek payload kunci vs DB (hidup).
		sudahAda, err := s.repo.CariVarianKombinasi(ctx, tx, id, hasil.KunciKombinasi)
		if err != nil {
			return err
		}
		if sudahAda {
			return errkontrak.Conflict(
				"Kombinasi '"+hasil.KunciKombinasi+"' sudah ada untuk induk ini (INV-016).",
				"INV-016")
		}
		// SKU varian = `${induk.kodeProduk}-${nilaiTeks}` (strip + slice 50).
		nilaiTeksList := make([]string, 0, len(in.Kombinasi))
		for _, v := range in.Kombinasi {
			if n, ada := nilaiById[v.IDInvNilaiAtribut]; ada {
				nilaiTeksList = append(nilaiTeksList, n.Nilai)
			} else {
				nilaiTeksList = append(nilaiTeksList, "")
			}
		}
		nilaiTeks := domain.BangunNilaiTeksVarian(nilaiTeksList)
		sku := domain.BangunSkuVarian(induk.KodeProduk, nilaiTeks)
		if err := s.repo.AssertSkuVarianBebas(ctx, tx, sku); err != nil {
			return err
		}
		varianID, _, err := s.repo.InsertVarian(ctx, tx, repository.ProdukBaru{
			EntityID:            numbering.NewEntityID(),
			KodeProduk:          sku,
			Nama:                induk.Nama + " — " + nilaiTeks,
			Tipe:                "BARANG",
			IDInvKategoriProduk: induk.IDInvKategoriProduk,
			IDInvUnitUkur:       induk.IDInvUnitUkur,
			IDInvProdukInduk:    &id,
			KunciKombinasi:      &hasil.KunciKombinasi,
			JejakStok:           true,
			HargaJual: func() *string {
				if in.HargaJual != nil {
					return toFixedPtr(in.HargaJual, 4)
				}
				return induk.HargaJual
			}(),
			HargaBiaya: func() *string {
				if in.HargaBiaya != nil {
					return toFixedPtr(in.HargaBiaya, 4)
				}
				return induk.HargaBiaya
			}(),
			StokMinimum:  induk.StokMinimum,
			ReorderAktif: induk.ReorderAktif,
		})
		if err != nil {
			return mapUniqueSkuVarian(err, sku)
		}
		pasanganJunction := make([]repository.ProdukAtributBaru, 0, len(in.Kombinasi))
		for _, v := range in.Kombinasi {
			pasanganJunction = append(pasanganJunction, repository.ProdukAtributBaru{
				IDInvProduk:       varianID,
				IDInvNilaiAtribut: v.IDInvNilaiAtribut,
			})
		}
		if err := s.repo.InsertAtributVarian(ctx, tx, pasanganJunction); err != nil {
			return err
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_produk_induk_varian",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "generate",
				AfterValue: map[string]any{"sku": sku, "kunci_kombinasi": hasil.KunciKombinasi},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		out = map[string]any{
			"dibuat": []map[string]any{{
				"id": varianID, "kodeProduk": sku, "kunciKombinasi": hasil.KunciKombinasi,
			}},
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

/* ------------------------------------------------------------------ */
/* Helper internal                                                    */
/* ------------------------------------------------------------------ */

// versiIndukBentrok — 409 INV-017 pesan verbatim induk.
func versiIndukBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi induk tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+").",
		"INV-017")
}

// mapUniqueInduk — race 23505 create induk → 409 pesan pre-check verbatim.
func mapUniqueInduk(err error, kode string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	if pe.ConstraintName == "uq_inv_produk_kode" {
		return errkontrak.Conflict("Kode induk '" + kode + "' sudah dipakai.")
	}
	return err
}

// mapUniqueSkuVarian — race 23505 insert varian (kombinasi) → 409 INV-016.
func mapUniqueSkuVarian(err error, sku string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	switch pe.ConstraintName {
	case "uq_inv_produk_kode":
		return errkontrak.Conflict("SKU varian '" + sku + "' sudah dipakai (INV-016).")
	case "uq_inv_produk_kombinasi":
		return errkontrak.Conflict("Kombinasi varian sudah ada untuk induk ini (INV-016).", "INV-016")
	}
	return err
}
