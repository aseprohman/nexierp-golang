// mastera_unit.go + mastera_konversi.go — service fitur UNIT UKUR (UOM
// K-05) & UNIT KONVERSI (patch 05) modul inv — padanan UnitService +
// UnitKonversiService NestJS: soft delete, optimistic locking STD-07,
// hapus unit diblokir bila masih dirujuk produk/gerakan/konversi (INV-002);
// konversi lintas kategori UOM ditolak (422 VAL-422, D-35), pasangan dua
// arah dicek app (D-34), faktor toFixed(6) → Number view.
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

/* ================================================================== */
/* UNIT UKUR                                                          */
/* ================================================================== */

// UnitService — fitur unit ukur.
type UnitService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.UnitRepository
}

// NewUnitService membuat service unit.
func NewUnitService(db *database.DB, aud *audit.Service) *UnitService {
	return &UnitService{db: db, auid: aud, repo: repository.NewUnit()}
}

// UnitBuatInput — unitUkurCreateSchema.
type UnitBuatInput struct {
	Kode        string
	Nama        string
	KategoriUom string
	Status      string
}

// UnitUbahInput — unitUkurUpdateSchema (parsial + version).
type UnitUbahInput struct {
	Kode        *string
	Nama        *string
	KategoriUom *string
	Status      *string
	Version     int32
}

// List — daftar unit paginated + filter status + search kode/nama.
func (s *UnitService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.UnitUkurView], error) {
	f := repository.FilterUnit{
		Status: pr.Filters["status"],
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"kode": "kode", "nama": "nama",
		"created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "kode")
	rows, total, err := s.repo.ListUnit(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.UnitUkurView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail unit — 404 INV-018.
func (s *UnitService) Get(ctx context.Context, id int64) (types.UnitUkurView, error) {
	row, err := s.repo.AssertAda(ctx, s.db.Pool, id)
	if err != nil {
		return types.UnitUkurView{}, err
	}
	return repository.ToUnitView(row), nil
}

// Create — buat unit — kode unik GLOBAL (tanpa filter deleted — verbatim).
func (s *UnitService) Create(ctx context.Context, in UnitBuatInput, actor audit.Actor) (types.UnitUkurView, error) {
	var out types.UnitUkurView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		dupe, err := s.repo.CariDupeKode(ctx, tx, in.Kode, nil)
		if err != nil {
			return err
		}
		if dupe {
			return errkontrak.Conflict("Kode unit '" + in.Kode + "' sudah dipakai.")
		}
		row, err := s.repo.Insert(ctx, tx, repository.UnitBaru{
			EntityID:    numbering.NewEntityID(),
			Kode:        in.Kode,
			Nama:        in.Nama,
			KategoriUom: in.KategoriUom,
			Status:      in.Status,
		})
		if err != nil {
			return mapUniqueUnit(err, in.Kode)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_unit_ukur",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: map[string]any{"kode": row.Kode},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		out = repository.ToUnitView(row)
		return nil
	})
	if err != nil {
		return types.UnitUkurView{}, err
	}
	return out, nil
}

// Update — ubah unit — versi wajib cocok (409 INV-017).
func (s *UnitService) Update(ctx context.Context, id int64, in UnitUbahInput, actor audit.Actor) (types.UnitUkurView, error) {
	var out types.UnitUkurView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertAda memakai executor NON-tx (this.db).
		row, err := s.repo.AssertAda(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		if row.Version != in.Version {
			return versiUnitBentrok(row.Version, in.Version)
		}
		if in.Kode != nil && *in.Kode != row.Kode {
			dupe, err := s.repo.CariDupeKode(ctx, tx, *in.Kode, &id)
			if err != nil {
				return err
			}
			if dupe {
				return errkontrak.Conflict("Kode unit '" + *in.Kode + "' sudah dipakai.")
			}
		}
		set := repository.UnitUbahSet{
			Kode: row.Kode, Nama: row.Nama, KategoriUom: row.KategoriUom,
			Status: row.Status, Version: row.Version + 1, UpdatedAt: time.Now(),
		}
		if in.Kode != nil {
			set.Kode = *in.Kode
		}
		if in.Nama != nil {
			set.Nama = *in.Nama
		}
		if in.KategoriUom != nil {
			set.KategoriUom = *in.KategoriUom
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
			return versiUnitBentrok(row.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_unit_ukur",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				AfterValue: map[string]any{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		out = repository.ToUnitView(*updated)
		return nil
	})
	if err != nil {
		return types.UnitUkurView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — blokir bila masih dirujuk produk/gerakan/konversi
// (INV-002).
func (s *UnitService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		// persis sumber: assertAda memakai executor NON-tx (this.db).
		row, err := s.repo.AssertAda(ctx, s.db.Pool, id)
		if err != nil {
			return err
		}
		produk, err := s.repo.HitungProduk(ctx, tx, id)
		if err != nil {
			return err
		}
		gerakan, err := s.repo.HitungGerakan(ctx, tx, id)
		if err != nil {
			return err
		}
		konversi, err := s.repo.HitungKonversi(ctx, tx, id)
		if err != nil {
			return err
		}
		if produk > 0 || gerakan > 0 || konversi > 0 {
			return errkontrak.Conflict(
				"Unit masih dirujuk produk/gerakan/konversi — tidak bisa dihapus, gunakan status NONAKTIF.",
				"INV-002")
		}
		now := time.Now()
		if err := s.repo.HapusLunak(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_unit_ukur",
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

// versiUnitBentrok — 409 INV-017 pesan verbatim unit.
func versiUnitBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi unit tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+").",
		"INV-017")
}

// mapUniqueUnit — race 23505 → 409 pesan pre-check verbatim.
func mapUniqueUnit(err error, kode string) error {
	var pe *pgconn.PgError
	if !asPgError(err, &pe) || pe.Code != "23505" {
		return err
	}
	if pe.ConstraintName == "uq_inv_unit_ukur_kode" {
		return errkontrak.Conflict("Kode unit '" + kode + "' sudah dipakai.")
	}
	return err
}

/* ================================================================== */
/* UNIT KONVERSI (patch 05)                                           */
/* ================================================================== */

// UnitKonversiService — fitur konversi satuan.
type UnitKonversiService struct {
	db   *database.DB
	auid *audit.Service
	repo *repository.UnitKonversiRepository
	unit *repository.UnitRepository
}

// NewUnitKonversiService membuat service konversi satuan.
func NewUnitKonversiService(db *database.DB, aud *audit.Service) *UnitKonversiService {
	return &UnitKonversiService{db: db, auid: aud, repo: repository.NewUnitKonversi(), unit: repository.NewUnit()}
}

// KonversiBuatInput — unitKonversiCreateSchema.
type KonversiBuatInput struct {
	IDUnitDari int64
	IDUnitKe   int64
	Faktor     float64
	Status     string
}

// KonversiUbahInput — unitKonversiUpdateSchema (parsial + version).
type KonversiUbahInput struct {
	IDUnitDari *int64
	IDUnitKe   *int64
	Faktor     *float64
	Status     *string
	Version    int32
}

// List — daftar konversi paginated + filter status + search kode/nama unit.
func (s *UnitKonversiService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[types.UnitKonversiView], error) {
	f := repository.FilterKonversi{
		Status: pr.Filters["status"],
		Search: pr.Filters["search"],
		Limit:  int32(pr.Limit),
		Offset: int32(pr.Offset),
	}
	f.SortField, f.SortDesc = repository.MaPilihSort(pr, map[string]string{
		"dari": "dari", "ke": "ke",
		"created_at": "created_at", "createdAt": "created_at",
		"updatedAt": "updated_at",
	}, "dari")
	rows, total, err := s.repo.ListKonversi(ctx, s.db.Pool, f)
	if err != nil {
		return errkontrak.Page[types.UnitKonversiView]{}, err
	}
	return errkontrak.BuildPage(rows, total, pr), nil
}

// Get — detail konversi — 404 INV-018.
func (s *UnitKonversiService) Get(ctx context.Context, id int64) (types.UnitKonversiView, error) {
	row, err := s.repo.MuatRow(ctx, s.db.Pool, id)
	if err != nil {
		return types.UnitKonversiView{}, err
	}
	if row == nil {
		return types.UnitKonversiView{}, errkontrak.NotFound(
			"Konversi id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
	}
	return repository.ToKonversiView(*row), nil
}

// Create — buat konversi — unit ada, satu kategori UOM (D-35, 422),
// pasangan belum terpakai dua arah (D-34).
func (s *UnitKonversiService) Create(ctx context.Context, in KonversiBuatInput, actor audit.Actor) (types.UnitKonversiView, error) {
	var out types.UnitKonversiView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		dari, err := s.unit.AssertUnitDenganLabel(ctx, tx, in.IDUnitDari, "Unit asal")
		if err != nil {
			return err
		}
		ke, err := s.unit.AssertUnitDenganLabel(ctx, tx, in.IDUnitKe, "Unit tujuan")
		if err != nil {
			return err
		}
		if err := assertSatuKategori(dari, ke); err != nil {
			return err
		}
		if err := assertPasanganBebas(ctx, s.repo, tx, in.IDUnitDari, in.IDUnitKe, nil); err != nil {
			return err
		}
		// faktor toFixed(6) — persis sumber.
		faktor := strconv.FormatFloat(in.Faktor, 'f', 6, 64)
		murni, err := s.repo.Insert(ctx, tx, repository.KonversiBaru{
			EntityID:   numbering.NewEntityID(),
			IDUnitDari: in.IDUnitDari,
			IDUnitKe:   in.IDUnitKe,
			Faktor:     faktor,
			Status:     in.Status,
		})
		if err != nil {
			return err
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_unit_konversi",
				EntityID:   strconv.FormatInt(murni.ID, 10),
				Action:     "create",
				AfterValue: map[string]any{"dari": dari.Kode, "ke": ke.Kode, "faktor": murni.Faktor},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		out = repository.ToKonversiView(repository.KonversiRow{Konversi: murni, Dari: dari, Ke: ke})
		return nil
	})
	if err != nil {
		return types.UnitKonversiView{}, err
	}
	return out, nil
}

// Update — ubah konversi — versi wajib cocok (409 INV-017); pasangan boleh
// diubah (tetap divalidasi satu kategori + pasangan bebas).
func (s *UnitKonversiService) Update(ctx context.Context, id int64, in KonversiUbahInput, actor audit.Actor) (types.UnitKonversiView, error) {
	var out types.UnitKonversiView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		cur, err := s.repo.MuatRow(ctx, tx, id)
		if err != nil {
			return err
		}
		if cur == nil {
			return errkontrak.NotFound(
				"Konversi id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		if cur.Konversi.Version != in.Version {
			return versiKonversiBentrok(cur.Konversi.Version, in.Version)
		}
		idDari := cur.Konversi.IDUnitDari
		if in.IDUnitDari != nil {
			idDari = *in.IDUnitDari
		}
		idKe := cur.Konversi.IDUnitKe
		if in.IDUnitKe != nil {
			idKe = *in.IDUnitKe
		}
		dari, err := s.unit.AssertUnitDenganLabel(ctx, tx, idDari, "Unit asal")
		if err != nil {
			return err
		}
		ke, err := s.unit.AssertUnitDenganLabel(ctx, tx, idKe, "Unit tujuan")
		if err != nil {
			return err
		}
		if err := assertSatuKategori(dari, ke); err != nil {
			return err
		}
		if err := assertPasanganBebas(ctx, s.repo, tx, idDari, idKe, &id); err != nil {
			return err
		}
		// faktor: input != null ? toFixed(6) : tetap (teks numeric apa adanya).
		faktor := cur.Konversi.Faktor
		if in.Faktor != nil {
			faktor = strconv.FormatFloat(*in.Faktor, 'f', 6, 64)
		}
		status := cur.Konversi.Status
		if in.Status != nil {
			status = *in.Status
		}
		updated, err := s.repo.Update(ctx, tx, id, in.Version, repository.KonversiUbahSet{
			IDUnitDari: idDari,
			IDUnitKe:   idKe,
			Faktor:     faktor,
			Status:     status,
			Version:    cur.Konversi.Version + 1,
			UpdatedAt:  time.Now(),
		})
		if err != nil {
			return err
		}
		if updated == nil {
			// Optimistic locking atomik: kalah balapan → 0 baris → 409 INV-017.
			return versiKonversiBentrok(cur.Konversi.Version, in.Version)
		}
		if _, err := s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_unit_konversi",
				EntityID:   strconv.FormatInt(id, 10),
				Action:     "update",
				AfterValue: map[string]any{"dari": dari.Kode, "ke": ke.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		out = repository.ToKonversiView(repository.KonversiRow{Konversi: *updated, Dari: dari, Ke: ke})
		return nil
	})
	if err != nil {
		return types.UnitKonversiView{}, err
	}
	return out, nil
}

// Remove — hapus lunak — konversi tidak dirujuk transaksi, hapus selalu boleh.
func (s *UnitKonversiService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		cur, err := s.repo.MuatRow(ctx, tx, id)
		if err != nil {
			return err
		}
		if cur == nil {
			return errkontrak.NotFound(
				"Konversi id "+strconv.FormatInt(id, 10)+" tidak ditemukan.", "INV-018")
		}
		now := time.Now()
		if err := s.repo.HapusLunak(ctx, tx, id, now, now); err != nil {
			return err
		}
		_, err = s.auid.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_unit_konversi",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "delete",
				BeforeValue: map[string]any{"dari": cur.Dari.Kode, "ke": cur.Ke.Kode},
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

// assertSatuKategori — D-35 konversi hanya dalam satu kategori UOM —
// 422 VAL-422 pesan verbatim.
func assertSatuKategori(dari, ke repository.UnitRow) error {
	if dari.KategoriUom != ke.KategoriUom {
		return errkontrak.Unprocessable(
			"Konversi lintas kategori UOM tidak diizinkan (" + dari.Kode + " = " + dari.KategoriUom +
				", " + ke.Kode + " = " + ke.KategoriUom + ").")
	}
	return nil
}

// assertPasanganBebas — D-34 satu baris per pasangan: tolak bila (dari→ke)
// maupun arah balik (ke→dari) sudah dipakai konversi hidup lain.
func assertPasanganBebas(ctx context.Context, repo *repository.UnitKonversiRepository, exec pgx.Tx, idDari, idKe int64, kecualiID *int64) error {
	dupe, err := repo.CariPasanganTerpakai(ctx, exec, idDari, idKe, kecualiID)
	if err != nil {
		return err
	}
	if dupe {
		return errkontrak.Conflict(
			"Pasangan unit ini sudah punya konversi (arah balik dihitung otomatis dari faktor).")
	}
	return nil
}

// versiKonversiBentrok — 409 INV-017 pesan verbatim konversi.
func versiKonversiBentrok(server, kirim int32) error {
	return errkontrak.Conflict(
		"Versi konversi tidak cocok (server "+strconv.FormatInt(int64(server), 10)+
			", kirim "+strconv.FormatInt(int64(kirim), 10)+").",
		"INV-017")
}
