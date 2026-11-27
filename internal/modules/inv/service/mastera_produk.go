// mastera_produk.go — service fitur PRODUK modul inv (padanan
// ProdukService NestJS INV-F01 + varian D-17/D-38/D-39): SKU unik global;
// hapus diblokir bila pernah dirujuk gerakan/lot (INV-002); saldo agregat
// readmodel; lookup ringkas picker (M36). Orkestrasi: validasi domain
// (SKU/barcode, entry varian), UoW SATU pgx.Tx, audit append DALAM transaksi
// yang sama, entityId = UUID v4 (numbering.NewEntityID), bump versi (STD-07).
// Race 23505 → 409 dengan pesan pre-check verbatim (keputusan ratifikasi).
package service

import (
	"context"
	"errors"
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

// ProdukService — fitur produk.
type ProdukService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.ProdukRepository
}

// NewProdukService membuat service produk.
func NewProdukService(db *database.DB, aud *audit.Service) *ProdukService {
	return &ProdukService{db: db, auid: aud, repo: repository.NewProduk()}
}

/* ------------------------------------------------------------------ */
/* Input DTO (padanan tipe zod packages/schemas inv/schemas.ts)        */
/* ------------------------------------------------------------------ */

// VarianNilaiItem — pasangan atribut/nilai entry varian (D-38).
type VarianNilaiItem struct {
	IDInvAtribut      int64
	IDInvNilaiAtribut int64
}

// ProdukBuatInput — produkCreateSchema (sudah ternormalisasi handler).
type ProdukBuatInput struct {
	KodeProduk          string
	Nama                string
	Tipe                string
	IDInvKategoriProduk int64
	IDInvUnitUkur       int64
	JejakStok           bool
	Barcode             *string
	HargaJual           *float64
	HargaBiaya          *float64
	StokMinimum         int32
	StokMaksimum        *int32
	ReorderAktif        bool
	AdalahIndukVarian   bool
	BeratGram           *int32
	VolumeCm3           *int32
	Keterangan          *string
	Status              string
	Varian              *VarianEntryInput
}

// VarianEntryInput — entry varian langsung saat create (D-38).
type VarianEntryInput struct {
	IDInvProdukInduk int64
	Nilai            []VarianNilaiItem
}

// ProdukUbahInput — produkUpdateSchema (kodeProduk TIDAK bisa diubah).
// Field *Ada = tri-state zod: key hadir di body (termasuk null) vs absen.
type ProdukUbahInput struct {
	Nama                *string
	Tipe                *string
	IDInvKategoriProduk *int64
	IDInvUnitUkur       *int64
	JejakStok           *bool
	Barcode             *string
	BarcodeAda          bool
	HargaJual           *float64
	HargaJualAda        bool
	HargaBiaya          *float64
	HargaBiayaAda       bool
	StokMinimum         *int32
	StokMaksimum        *int32
	StokMaksimumAda     bool
	ReorderAktif        *bool
	AdalahIndukVarian   *bool
	BeratGram           *int32
	BeratGramAda        bool
	VolumeCm3           *int32
	VolumeCm3Ada        bool
	Keterangan          *string
	KeteranganAda       bool
	Status              *string
	Version             int32
}

/* ------------------------------------------------------------------ */
/* Baca                                                               */
/* ------------------------------------------------------------------ */

// List — daftar produk paginated + filter status/tipe/kategori + search.
func (s *ProdukService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.ProdukView], error) {
	f := repository.FilterProduk{
		Status: pr.Filters["status"],
		Tipe:   pr.Filters["tipe"],
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	if raw := pr.Filters["idKategori"]; raw != "" {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n < 1 {
			return errkontrak.Page[types.ProdukView]{}, errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "idKategori", Message: "Harus bilangan bulat >= 1 (diterima: " + raw + ")."},
			})
		}
		f.IDKategori = &n
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"kode_produk": "kode_produk", "kodeProduk": "kode_produk",
		"nama": "nama", "created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "kode_produk")
	rows, total, err := s.repo.ListProduk(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.ProdukView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail produk — 404 INV-018 bila tidak ada / terhapus.
func (s *ProdukService) Get(ctx context.Context, id int64) (types.ProdukView, error) {
	return s.repo.GetProduk(ctx, s.db.Pool, id)
}

// Lookup — picker ringkas (M36): default 20 baris (maks 200 — clamp
// 1..200), hanya AKTIF; barcode eksak menang atas search.
func (s *ProdukService) Lookup(ctx context.Context, search, barcode string, limit *float64, idKategori *int64) ([]types.ProdukLookupView, error) {
	batas := float64(20)
	if limit != nil { // Number.isFinite sudah difilter handler
		batas = *limit
	}
	if batas < 1 {
		batas = 1
	}
	if batas > 200 {
		batas = 200
	}
	cari, scan := search, barcode
	if scan != "" { // barcode eksak menang (M15/M36)
		cari = ""
	}
	return s.repo.Lookup(ctx, s.db.Pool, cari, scan, int32(batas), idKategori)
}

/* ------------------------------------------------------------------ */
/* Tulis                                                              */
/* ------------------------------------------------------------------ */

// Create — buat produk — SKU unik global; barcode partial hidup; varian D-38.
func (s *ProdukService) Create(ctx context.Context, in ProdukBuatInput, actor audit.Actor) (types.ProdukView, error) {
	var out types.ProdukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.repo.AssertSkuBebas(ctx, tx, in.KodeProduk); err != nil {
			return err
		}
		if in.Barcode != nil && *in.Barcode != "" {
			if err := s.repo.AssertBarcodeBebas(ctx, tx, *in.Barcode, nil); err != nil {
				return err
			}
		}
		if in.Varian != nil && in.AdalahIndukVarian {
			return domain.VarianTidakBisaJadiInduk()
		}

		// harga toFixed(4) — representasi numeric PG (persis sumber).
		hargaJualEfektif := toFixedPtr(in.HargaJual, 4)
		hargaBiayaEfektif := toFixedPtr(in.HargaBiaya, 4)
		var kunciKombinasi *string
		var pasanganNilai []int64

		if in.Varian != nil {
			v := in.Varian
			induk, err := s.repo.CariIndukVarian(ctx, tx, v.IDInvProdukInduk)
			if err != nil {
				return err
			}
			if induk == nil {
				return errkontrak.NotFound(
					"Induk produk id "+strconv.FormatInt(v.IDInvProdukInduk, 10)+" tidak ditemukan (bukan produk induk).",
					"INV-018")
			}
			if induk.IDInvKategoriProduk != in.IDInvKategoriProduk {
				return errkontrak.BadRequest(
					"Kategori produk (" + strconv.FormatInt(in.IDInvKategoriProduk, 10) +
						") harus sama dengan kategori induk varian (" +
						strconv.FormatInt(induk.IDInvKategoriProduk, 10) + ").")
			}
			// D-39 — pewarisan template ditegakkan: unit, tipe, jejak stok.
			if in.IDInvUnitUkur != induk.IDInvUnitUkur {
				return errkontrak.BadRequest(
					"Unit varian mengikuti induk (induk memakai unit id " +
						strconv.FormatInt(induk.IDInvUnitUkur, 10) + ", kirim " +
						strconv.FormatInt(in.IDInvUnitUkur, 10) + ").")
			}
			if in.Tipe != "BARANG" {
				return errkontrak.BadRequest("Varian selalu BARANG — template varian adalah produk fisik per kombinasi.")
			}
			if !in.JejakStok {
				return errkontrak.BadRequest("Varian selalu menjejak stok (jejakStok=true) — qty hidup per kombinasi.")
			}
			konfigurasi, err := s.repo.ListKonfigurasiInduk(ctx, tx, induk.ID)
			if err != nil {
				return err
			}
			konfigDomain := make([]domain.KonfigAtribut, 0, len(konfigurasi))
			for _, k := range konfigurasi {
				konfigDomain = append(konfigDomain, domain.KonfigAtribut{IDInvAtribut: k.IDInvAtribut, KodeAtribut: k.KodeAtribut, Wajib: k.Wajib})
			}
			// Muat nilai yang dirujuk (hidup).
			nilaiIds := uniqueInt64(func() []int64 {
				out := make([]int64, 0, len(v.Nilai))
				for _, n := range v.Nilai {
					out = append(out, n.IDInvNilaiAtribut)
				}
				return out
			}())
			nilaiRows, err := s.repo.ListNilaiAtributHidup(ctx, tx, nilaiIds)
			if err != nil {
				return err
			}
			nilaiDomain := make([]domain.NilaiAtribut, 0, len(nilaiRows))
			for _, n := range nilaiRows {
				nilaiDomain = append(nilaiDomain, domain.NilaiAtribut{ID: n.ID, IDInvAtribut: n.IDInvAtribut, Nilai: n.Nilai})
			}
			pasangan := make([]domain.PasanganVarian, 0, len(v.Nilai))
			for _, item := range v.Nilai {
				pasangan = append(pasangan, domain.PasanganVarian{
					IDInvAtribut:      item.IDInvAtribut,
					IDInvNilaiAtribut: item.IDInvNilaiAtribut,
				})
			}
			hasil, err := domain.ValidasiVarianEntry(pasangan, konfigDomain, nilaiDomain)
			if err != nil {
				return err
			}
			pasanganNilai = hasil.PasanganNilai
			kunci := hasil.KunciKombinasi
			// Kunci kanonik + keunikan kombinasi per induk (INV-016).
			sudahAda, err := s.repo.CariVarianKombinasi(ctx, tx, induk.ID, kunci)
			if err != nil {
				return err
			}
			if sudahAda {
				return errkontrak.Conflict(
					"Kombinasi '"+kunci+"' sudah ada untuk induk ini (INV-016).",
					"INV-016")
			}
			kunciKombinasi = &kunci
			// D-39/D-42 — harga kosong → warisi induk (teks numeric apa adanya).
			if in.HargaJual == nil {
				hargaJualEfektif = induk.HargaJual
			}
			if in.HargaBiaya == nil {
				hargaBiayaEfektif = induk.HargaBiaya
			}
		}

		row, err := s.repo.InsertProduk(ctx, tx, repository.ProdukBaru{
			EntityID:            numbering.NewEntityID(),
			KodeProduk:          in.KodeProduk,
			Nama:                in.Nama,
			Tipe:                in.Tipe,
			IDInvKategoriProduk: in.IDInvKategoriProduk,
			IDInvUnitUkur:       in.IDInvUnitUkur,
			IDInvProdukInduk:    varianIndukPtr(in.Varian),
			KunciKombinasi:      kunciKombinasi,
			JejakStok:           in.JejakStok,
			Barcode:             barisBarcode(in.Barcode),
			HargaJual:           hargaJualEfektif,
			HargaBiaya:          hargaBiayaEfektif,
			StokMinimum:         in.StokMinimum,
			StokMaksimum:        in.StokMaksimum,
			ReorderAktif:        in.ReorderAktif,
			AdalahIndukVarian:   in.AdalahIndukVarian,
			BeratGram:           in.BeratGram,
			VolumeCm3:           in.VolumeCm3,
			Keterangan:          in.Keterangan,
			Status:              in.Status,
		})
		if err != nil {
			return mapUniqueProduk(err, in.KodeProduk, in.Barcode)
		}
		if kunciKombinasi != nil && len(pasanganNilai) > 0 {
			// Junction varian ↔ nilai atribut (junction murni — D-20).
			pasangan := make([]repository.ProdukAtributBaru, 0, len(pasanganNilai))
			for _, idNilai := range pasanganNilai {
				pasangan = append(pasangan, repository.ProdukAtributBaru{IDInvProduk: row.ID, IDInvNilaiAtribut: idNilai})
			}
			if err := s.repo.InsertAtributVarian(ctx, tx, pasangan); err != nil {
				return err
			}
		}
		after := map[string]any{"sku": row.KodeProduk, "nama": row.Nama, "tipe": row.Tipe}
		if kunciKombinasi != nil {
			after["kunci_kombinasi"] = *kunciKombinasi
			after["varian"] = true
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_produk",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: after,
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		ref, err := s.repo.MuatReferensi(ctx, s.db.Pool)
		if err != nil {
			return err
		}
		out = repository.ProdukToView(row, 0, []repository.PasanganAtributProduk{}, ref.Kategori, ref.Unit, ref.Induk)
		return nil
	})
	if err != nil {
		return types.ProdukView{}, err
	}
	return out, nil
}

// Update — ubah produk — SKU tidak boleh berubah; versi wajib cocok (STD-07).
func (s *ProdukService) Update(ctx context.Context, id int64, in ProdukUbahInput, actor audit.Actor) (types.ProdukView, error) {
	var out types.ProdukView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiProdukBentrok(row.Version, in.Version)
		}
		// D-17 — varian tidak boleh jadi induk; induk yang masih punya varian
		// hidup tidak boleh lepas dari perannya (D-21).
		if in.AdalahIndukVarian != nil && *in.AdalahIndukVarian && row.IDInvProdukInduk != nil {
			return errkontrak.BadRequest("Varian tidak bisa jadi induk varian — produk ini punya induk (D-17/D-39).")
		}
		if in.AdalahIndukVarian != nil && !*in.AdalahIndukVarian && row.AdalahIndukVarian {
			jumlahVarian, err := s.repo.HitungVarianHidup(ctx, tx, id)
			if err != nil {
				return err
			}
			if jumlahVarian > 0 {
				return errkontrak.Conflict(
					"Induk masih punya varian hidup — hapus varian dulu sebelum melepas penanda induk (D-21).",
					"INV-002")
			}
		}
		// D-39/D-42 — varian tidak boleh lepas dari induknya.
		if row.IDInvProdukInduk != nil {
			induk, err := s.repo.FindHidupById(ctx, tx, *row.IDInvProdukInduk)
			if err != nil {
				return err
			}
			if induk == nil {
				return errkontrak.NotFound(
					"Induk varian id "+strconv.FormatInt(*row.IDInvProdukInduk, 10)+" tidak ditemukan.",
					"INV-018")
			}
			if in.IDInvKategoriProduk != nil && *in.IDInvKategoriProduk != induk.IDInvKategoriProduk {
				return errkontrak.BadRequest("Kategori varian mengikuti induk — tidak bisa diubah terpisah (D-39).")
			}
			if in.IDInvUnitUkur != nil && *in.IDInvUnitUkur != induk.IDInvUnitUkur {
				return errkontrak.BadRequest("Unit varian mengikuti induk — tidak bisa diubah terpisah (D-39).")
			}
			if in.Tipe != nil && *in.Tipe != "BARANG" {
				return errkontrak.BadRequest("Varian selalu BARANG (D-39).")
			}
			if in.JejakStok != nil && !*in.JejakStok {
				return errkontrak.BadRequest("Varian selalu menjejak stok (D-39).")
			}
		}
		if in.Barcode != nil && *in.Barcode != "" &&
			(row.Barcode == nil || *in.Barcode != *row.Barcode) {
			if err := s.repo.AssertBarcodeBebas(ctx, tx, *in.Barcode, &id); err != nil {
				return err
			}
		}
		set := mergeProduk(row, in)
		updated, err := s.repo.UpdateProdukVersiHidup(ctx, tx, id, set, in.Version)
		if err != nil {
			return err
		}
		if updated == nil {
			// Optimistic locking atomik: kalah balapan → 0 baris → 409 INV-017.
			return versiProdukBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_produk",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				BeforeValue: map[string]any{
					"sku": row.KodeProduk, "version": row.Version,
				},
				AfterValue: map[string]any{
					"sku": updated.KodeProduk, "version": updated.Version,
				},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		saldoOnHand, err := s.repo.JumlahSaldoOnHand(ctx, tx, id)
		if err != nil {
			return err
		}
		atributMap, err := s.repo.MuatAtribut(ctx, s.db.Pool, []int64{id})
		if err != nil {
			return err
		}
		ref, err := s.repo.MuatReferensi(ctx, s.db.Pool)
		if err != nil {
			return err
		}
		out = repository.ProdukToView(*updated, saldoOnHand, atributMap[id], ref.Kategori, ref.Unit, ref.Induk)
		return nil
	})
	if err != nil {
		return types.ProdukView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — blokir bila pernah dirujuk gerakan/lot (INV-002).
func (s *ProdukService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		gerakan, err := s.repo.HitungGerakanHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		lot, err := s.repo.HitungLotHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if gerakan > 0 || lot > 0 {
			return errkontrak.Conflict(
				"Produk pernah dirujuk gerakan/lot — tidak bisa dihapus, gunakan status NONAKTIF.",
				"INV-002")
		}
		now := time.Now()
		if err := s.repo.SoftDeleteProdukHidup(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_produk",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "delete",
				BeforeValue: map[string]any{"sku": row.KodeProduk},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

/* ------------------------------------------------------------------ */
/* Helper internal                                                    */
/* ------------------------------------------------------------------ */

// versiProdukBentrok — 409 INV-017 pesan verbatim.
func versiProdukBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi produk tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+").",
		"INV-017")
}

// mergeProduk — gabungkan patch ke baris (nilai tidak dikirim = tetap).
func mergeProduk(row repository.ProdukRow, in ProdukUbahInput) repository.ProdukUbahSet {
	set := repository.ProdukUbahSet{
		Nama:                row.Nama,
		Tipe:                row.Tipe,
		IDInvKategoriProduk: row.IDInvKategoriProduk,
		IDInvUnitUkur:       row.IDInvUnitUkur,
		JejakStok:           row.JejakStok,
		Barcode:             row.Barcode,
		HargaJual:           row.HargaJual,
		HargaBiaya:          row.HargaBiaya,
		StokMinimum:         row.StokMinimum,
		StokMaksimum:        row.StokMaksimum,
		ReorderAktif:        row.ReorderAktif,
		AdalahIndukVarian:   row.AdalahIndukVarian,
		BeratGram:           row.BeratGram,
		VolumeCm3:           row.VolumeCm3,
		Keterangan:          row.Keterangan,
		Status:              row.Status,
		Version:             row.Version + 1,
		UpdatedAt:           time.Now(),
	}
	if in.Nama != nil {
		set.Nama = *in.Nama
	}
	if in.Tipe != nil {
		set.Tipe = *in.Tipe
	}
	if in.IDInvKategoriProduk != nil {
		set.IDInvKategoriProduk = *in.IDInvKategoriProduk
	}
	if in.IDInvUnitUkur != nil {
		set.IDInvUnitUkur = *in.IDInvUnitUkur
	}
	if in.JejakStok != nil {
		set.JejakStok = *in.JejakStok
	}
	// barcode: undefined = tetap; null/"" → NULL (input.barcode || null).
	if in.BarcodeAda {
		if in.Barcode == nil || *in.Barcode == "" {
			set.Barcode = nil
		} else {
			set.Barcode = in.Barcode
		}
	}
	if in.HargaJualAda {
		set.HargaJual = toFixedPtr(in.HargaJual, 4) // null → NULL
	}
	if in.HargaBiayaAda {
		set.HargaBiaya = toFixedPtr(in.HargaBiaya, 4)
	}
	if in.StokMinimum != nil {
		set.StokMinimum = *in.StokMinimum
	}
	if in.StokMaksimumAda {
		set.StokMaksimum = in.StokMaksimum // null → NULL
	}
	if in.ReorderAktif != nil {
		set.ReorderAktif = *in.ReorderAktif
	}
	if in.AdalahIndukVarian != nil {
		set.AdalahIndukVarian = *in.AdalahIndukVarian
	}
	if in.BeratGramAda {
		set.BeratGram = in.BeratGram
	}
	if in.VolumeCm3Ada {
		set.VolumeCm3 = in.VolumeCm3
	}
	if in.KeteranganAda {
		set.Keterangan = in.Keterangan
	}
	if in.Status != nil {
		set.Status = *in.Status
	}
	return set
}

// mapUniqueProduk — race 23505 insert inv_produk → 409 pesan pre-check
// verbatim (keputusan ratifikasi); nama constraint menentukan pesan.
func mapUniqueProduk(err error, sku string, barcode *string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	switch pe.ConstraintName {
	case "uq_inv_produk_kode":
		return errkontrak.Conflict("SKU '" + sku + "' sudah dipakai produk lain.")
	case "uq_inv_produk_barcode":
		bc := ""
		if barcode != nil {
			bc = *barcode
		}
		return errkontrak.Conflict("Barcode '" + bc + "' sudah dipakai produk lain.")
	}
	return err
}

/* ------------------------------------------------------------------ */
/* Helper kecil bersama (dipakai service lain di package ini)         */
/* ------------------------------------------------------------------ */

// toFixedPtr — padanan input.hargaJual.toFixed(4) / toFixed(6): *float64 →
// *string desimal titik-tetap; nil diteruskan.
func toFixedPtr(v *float64, presisi int) *string {
	if v == nil {
		return nil
	}
	s := strconv.FormatFloat(*v, 'f', presisi, 64)
	return &s
}

// barisBarcode — barcode kosong → nil (persis `input.barcode ?? null`).
func barisBarcode(b *string) *string {
	if b == nil || *b == "" {
		return nil
	}
	return b
}

// varianIndukPtr — id induk varian untuk kolom id_inv_produk_induk.
func varianIndukPtr(v *VarianEntryInput) *int64 {
	if v == nil {
		return nil
	}
	id := v.IDInvProdukInduk
	return &id
}

// uniqueInt64 — Set([...]) JS.
func uniqueInt64(ids []int64) []int64 {
	seen := map[int64]bool{}
	out := make([]int64, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// asPgError — ekstrak *pgconn.PgError (termasuk rantai cause).
func asPgError(err error, target **pgconn.PgError) bool {
	return errors.As(err, target)
}
