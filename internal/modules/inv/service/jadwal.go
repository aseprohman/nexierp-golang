// jadwal.go — orkestrasi fitur JADWAL HITUNG modul inv (padanan
// services/operasi/jadwal-hitung.service.ts NestJS patch 04 — P1 #7,
// VERBATIM pesan & urutan): penjadwalan cycle count per gudang/lokasi.
// Eksekusi = generate DRAFT inv_penyesuaian_stok jenis CYCLE_COUNT (count
// sheet: qty_sistem dari saldo, qty_hitung 0) — approval tetap lewat alur
// penyesuaian biasa (SoD terjaga).
//
// Aturan:
//   - soft delete semua query; kode unik global; CHECK hari 0..28 (DB);
//   - jatuh tempo (frekuensi HARIAN/MINGGUAN/BULANAN/TRIWULAN vs
//     terakhir_dibuat_pada) via domain.BatasJatuhTempo (aturan murni):
//     belum jatuh tempo → 409 INV-020 "belum jatuh tempo";
//   - generate SATU UoW: draft ADJ (penomoran ADJ) + items (qty_sistem =
//     qty_on_hand READMODEL, qty_hitung = 0, biaya dari harga_biaya produk,
//     snapshot nama_produk) + stamp terakhir_dibuat_pada + version+1 +
//     audit; return PenyesuaianView (PASCA-commit via PenyesuaianService.Get).
package service

import (
	"context"
	"fmt"
	"net/url"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/numbering"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// JadwalService — dependensi kernel + repo jadwal + service penyesuaian
// (return generate = PenyesuaianView).
type JadwalService struct {
	DB          *database.DB
	Audit       *audit.Service
	Numbering   *numbering.Service
	Penyesuaian *PenyesuaianService
	Repo        *repository.JadwalHitungRepository
}

// NewJadwalService — wiring dari Deps modul (dipanggil handler).
func NewJadwalService(d types.Deps) *JadwalService {
	return &JadwalService{
		DB:          d.DB,
		Audit:       d.Audit,
		Numbering:   d.Numbering,
		Penyesuaian: NewPenyesuaianService(d),
		Repo:        repository.NewJadwalHitungRepository(),
	}
}

// JadwalCreateInput — body POST jadwal-hitung.
type JadwalCreateInput struct {
	Kode            string
	Nama            string
	IDInvGudang     int64
	IDInvLokasiStok *int64
	Frekuensi       string
	HariEksekusi    int
	Aktif           bool
}

// JadwalUpdateInput — body PATCH (field absen = nilai lama; lokasi tri-state
// via LokasiAda + null).
type JadwalUpdateInput struct {
	Kode            string // "" = tidak dikirim
	Nama            string // "" = tidak dikirim
	IDInvGudang     *int64
	LokasiAda       bool // idInvLokasiStok dikirim
	IDInvLokasiStok *int64
	Frekuensi       string // "" = tidak dikirim
	HariEksekusi    *int
	AktifAda        bool
	Aktif           *bool
	Version         int64
}

/* -------------------------------------------------------------- */
/* Baca                                                          */
/* -------------------------------------------------------------- */

// List — daftar jadwal — filter gudang/aktif + search kode/nama.
func (s *JadwalService) List(ctx context.Context, query url.Values) (errkontrak.Page[repository.JadwalHitungView], error) {
	var page errkontrak.Page[repository.JadwalHitungView]
	pr, err := errkontrak.ParsePageRequest(query)
	if err != nil {
		return page, err
	}
	// Whitelist sort daftar jadwal (default kode ASC).
	if err := opSortWhitelist(pr, "kode", "created_at", "createdAt", "updatedAt"); err != nil {
		return page, err
	}
	sortCol, sortDesc := opPilihSort(pr, map[string]string{
		"kode": "kode", "created_at": "created_at", "createdAt": "createdAt", "updatedAt": "updatedAt",
	}, "")
	var idGudang *int64
	if v := opFilterVal(pr, "idGudang"); v != nil {
		id, err := opFilterAngka(*v)
		if err != nil {
			return page, err
		}
		idGudang = id
	}
	data, total, err := s.Repo.ListJadwal(ctx, s.DB.Pool, repository.JadwalListFilter{
		IDGudang: idGudang,
		Aktif:    opFilterVal(pr, "aktif"),
		Search:   opFilterVal(pr, "search"),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Limit:    int32(pr.Limit),
		Offset:   int32(pr.Offset),
	})
	if err != nil {
		return page, err
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Get — detail jadwal — 404 INV-018 (pesan memakai id mentah — verbatim).
func (s *JadwalService) Get(ctx context.Context, idRaw string) (repository.JadwalHitungView, error) {
	var kosong repository.JadwalHitungView
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return kosong, err
	}
	view, err := s.Repo.MuatViewById(ctx, s.DB.Pool, id)
	if err != nil {
		return kosong, err
	}
	if view == nil {
		return kosong, errkontrak.NotFound(
			fmt.Sprintf("Jadwal hitung id %s tidak ditemukan.", idRaw),
			domain.KodeInvTidakDitemukan,
		)
	}
	return *view, nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                         */
/* -------------------------------------------------------------- */

// Create — buat jadwal — gudang wajib ada; lokasi opsional (NULL = semua
// gudang).
func (s *JadwalService) Create(ctx context.Context, in JadwalCreateInput, c CtxMutasi) (repository.JadwalHitungView, error) {
	var view repository.JadwalHitungView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.assertKodeBebas(ctx, tx, in.Kode, nil); err != nil {
			return err
		}
		row, err := s.Repo.InsertJadwal(ctx, tx, repository.InsertJadwalHitungParams{
			EntityID:        opUuidParam(numbering.NewEntityID()),
			Kode:            in.Kode,
			Nama:            in.Nama,
			IDInvGudang:     in.IDInvGudang,
			IDInvLokasiStok: opI8N(in.IDInvLokasiStok),
			Frekuensi:       repository.EnumFrekuensiHitung(in.Frekuensi),
			HariEksekusi:    int32(in.HariEksekusi),
			Aktif:           in.Aktif,
		})
		if err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_jadwal_hitung",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode, "frekuensi": string(row.Frekuensi), "hari": row.HariEksekusi},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		return s.muatViewBaris(ctx, tx, row.ID, &view)
	})
	if err != nil {
		return repository.JadwalHitungView{}, err
	}
	return view, nil
}

// Update — ubah jadwal — versi wajib cocok (409 INV-017).
func (s *JadwalService) Update(ctx context.Context, idRaw string, in JadwalUpdateInput, c CtxMutasi) (repository.JadwalHitungView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.JadwalHitungView{}, err
	}
	var view repository.JadwalHitungView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.JadwalHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if int64(row.Version) != in.Version {
			return errkontrak.Conflict(fmt.Sprintf(
				"Versi jadwal tidak cocok (server %d, kirim %d).", row.Version, in.Version),
				domain.KodeInvVersiBentrok)
		}
		kode := row.Kode
		if in.Kode != "" && in.Kode != row.Kode {
			if err := s.assertKodeBebas(ctx, tx, in.Kode, &id); err != nil {
				return err
			}
			kode = in.Kode
		}
		nama := row.Nama
		if in.Nama != "" {
			nama = in.Nama
		}
		idGudang := row.IDInvGudang
		if in.IDInvGudang != nil {
			idGudang = *in.IDInvGudang
		}
		// Lokasi: absen → nilai lama (CASE COALESCE keep); dikirim null →
		// NULL (lokasi_null); dikirim angka → ganti.
		lokasiNull := false
		var lokasiBaru *int64
		if in.LokasiAda {
			lokasiNull = in.IDInvLokasiStok == nil
			lokasiBaru = in.IDInvLokasiStok
		}
		frekuensi := string(row.Frekuensi)
		if in.Frekuensi != "" {
			frekuensi = in.Frekuensi
		}
		hari := int(row.HariEksekusi)
		if in.HariEksekusi != nil {
			hari = *in.HariEksekusi
		}
		aktif := row.Aktif
		if in.AktifAda && in.Aktif != nil {
			aktif = *in.Aktif
		}
		if err := s.Repo.UpdatePatch(ctx, tx, repository.UpdateJadwalHitungPatchParams{
			Kode:            kode,
			Nama:            nama,
			IDInvGudang:     idGudang,
			LokasiNull:      lokasiNull,
			IDInvLokasiStok: opI8N(lokasiBaru),
			Frekuensi:       repository.EnumFrekuensiHitung(frekuensi),
			HariEksekusi:    int32(hari),
			Aktif:           aktif,
			Version:         row.Version + 1,
			UpdatedAt:       opWaktu(opWaktuSekarang()),
			ID:              id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_jadwal_hitung",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "version": row.Version},
				AfterValue:  audit.Snapshot{"kode": kode, "version": row.Version + 1},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		return s.muatViewBaris(ctx, tx, id, &view)
	})
	if err != nil {
		return repository.JadwalHitungView{}, err
	}
	return view, nil
}

// Remove — hapus lunak — jadwal tak direferensikan (aman).
func (s *JadwalService) Remove(ctx context.Context, idRaw string, c CtxMutasi) error {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return err
	}
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.JadwalHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := s.Repo.SoftDelete(ctx, tx, id, opWaktuSekarang()); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_jadwal_hitung",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode},
				Severity:    audit.SeverityWarning,
			},
			Actor: c.Actor,
		}})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Generate cycle count                                           */
/* -------------------------------------------------------------- */

// Generate — draft CYCLE_COUNT bila jadwal jatuh tempo (aktif & due) — satu
// UoW: draft ADJ + items dari inv_saldo_stok (qty_sistem, hitung 0) + stamp
// terakhir_dibuat_pada + audit; return PenyesuaianView (muat PASCA-commit —
// get memakai pool).
func (s *JadwalService) Generate(ctx context.Context, idRaw string, c CtxMutasi) (repository.PenyesuaianView, error) {
	var kosong repository.PenyesuaianView
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return kosong, err
	}
	penyesuaianID := int64(0)
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		jadwal, err := s.Repo.JadwalHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if !jadwal.Aktif {
			return errkontrak.Conflict(fmt.Sprintf(
				"Jadwal %s nonaktif — aktifkan dulu sebelum generate (INV-020).", jadwal.Kode),
				opKodeInvJenisOperasiTidakSah)
		}
		sekarang := opWaktuSekarang()
		batas := domain.BatasJatuhTempo(string(jadwal.Frekuensi), int(jadwal.HariEksekusi), sekarang)
		if jadwal.TerakhirDibuatPada.Valid && !jadwal.TerakhirDibuatPada.Time.Before(batas) {
			return errkontrak.Conflict(fmt.Sprintf(
				"Jadwal %s belum jatuh tempo (frekuensi %s, hari %d; terakhir dibuat %s, batas berikutnya %s).",
				jadwal.Kode, string(jadwal.Frekuensi), jadwal.HariEksekusi,
				opIsoP(jadwal.TerakhirDibuatPada.Time), opIsoP(batas)),
				opKodeInvJenisOperasiTidakSah)
		}

		// Lingkup saldo: lokasi terpilih, atau SEMUA lokasi INTERNAL gudang.
		var lokasiIDs []int64
		if jadwal.IDInvLokasiStok.Valid {
			lokasiIDs = []int64{jadwal.IDInvLokasiStok.Int64}
		} else {
			lokasiIDs, err = s.Repo.LokasiInternalGudang(ctx, tx, jadwal.IDInvGudang)
			if err != nil {
				return err
			}
		}
		if len(lokasiIDs) == 0 {
			return errkontrak.Conflict(fmt.Sprintf(
				"Jadwal %s: gudang tidak punya lokasi internal — tidak ada yang dihitung (INV-020).", jadwal.Kode),
				opKodeInvJenisOperasiTidakSah)
		}

		// Items dari READMODEL saldo — qty_sistem = on-hand, qty_hitung = 0.
		saldoRows, err := s.Repo.SaldoLingkupHitung(ctx, tx, lokasiIDs)
		if err != nil {
			return err
		}
		if len(saldoRows) == 0 {
			return errkontrak.Conflict(fmt.Sprintf(
				"Jadwal %s: tidak ada saldo pada lingkup hitung — tidak ada yang dihitung (INV-020).", jadwal.Kode),
				opKodeInvJenisOperasiTidakSah)
		}

		kode, err := s.Numbering.Next(ctx, tx, "inventory", "ADJ", numbering.Options{Prefix: "ADJ/{MMyy}", Padding: 4})
		if err != nil {
			return err
		}
		header, err := s.Repo.InsertPenyesuaianHeader(ctx, tx, repository.InsertPenyesuaianParams{
			EntityID:            opUuidParam(numbering.NewEntityID()),
			Kode:                kode,
			Jenis:               repository.EnumJenisPenyesuaian("CYCLE_COUNT"),
			Status:              repository.EnumStatusPenyesuaian("DRAFT"),
			IDInvGudang:         jadwal.IDInvGudang,
			TanggalDokumen:      opWaktu(sekarang),
			IDCoreUsersPenyusun: opI8N(opActorID(c)),
			Alasan:              opTeks(pointerString(fmt.Sprintf("Cycle count dari jadwal %s (%s)", jadwal.Kode, jadwal.Nama))),
		})
		if err != nil {
			return err
		}
		for _, sr := range saldoRows {
			var idLot *int64
			if sr.IDInvLotSerial.Valid {
				idLot = &sr.IDInvLotSerial.Int64
			}
			if err := s.Repo.InsertPenyesuaianItem(ctx, tx, repository.InsertPenyesuaianItemParams{
				EntityID:             opUuidParam(numbering.NewEntityID()),
				IDInvPenyesuaianStok: header.ID,
				IDInvProduk:          sr.IDInvProduk,
				IDInvLotSerial:       opI8N(idLot),
				IDInvLokasiStok:      sr.IDInvLokasiStok,
				IDInvUnitUkur:        sr.IDUnit,
				QtySistem:            sr.QtyOnHand,
				QtyHitung:            0,
				QtySelisih:           -sr.QtyOnHand,
				BiayaSatuan:          sr.HargaBiaya,
				NamaProduk:           sr.NamaProduk,
			}); err != nil {
				return err
			}
		}
		// Jejak generate + audit.
		if err := s.Repo.StampGenerate(ctx, tx, id, sekarang, jadwal.Version+1); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_jadwal_hitung",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "generate",
				AfterValue: audit.Snapshot{
					"kode":        jadwal.Kode,
					"penyesuaian": header.Kode,
					"items":       len(saldoRows),
					"batas":       opIsoP(batas),
				},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		penyesuaianID = header.ID
		return nil
	})
	if err != nil {
		return kosong, err
	}
	// Muat PenyesuaianView pasca-commit (get memakai pool).
	return s.Penyesuaian.Get(ctx, fmt.Sprintf("%d", penyesuaianID))
}

/* -------------------------------------------------------------- */
/* Internal                                                       */
/* -------------------------------------------------------------- */

// assertKodeBebas — kode jadwal bebas (unique global, soft-delete aware) —
// fail 409 bila dipakai (pesan verbatim, tanpa kode).
func (s *JadwalService) assertKodeBebas(ctx context.Context, exec repository.DBTX, kode string, kecualiID *int64) error {
	dipakai, err := s.Repo.KodeDipakai(ctx, exec, kode, kecualiID)
	if err != nil {
		return err
	}
	if dipakai {
		return errkontrak.Conflict(fmt.Sprintf("Kode jadwal '%s' sudah dipakai.", kode))
	}
	return nil
}

// muatViewBaris — muat view pasca-tulis (insert/update) — 404 INV-018 bila
// tak ada (pesan verbatim id numerik).
func (s *JadwalService) muatViewBaris(ctx context.Context, exec repository.DBTX, id int64, out *repository.JadwalHitungView) error {
	view, err := s.Repo.MuatViewById(ctx, exec, id)
	if err != nil {
		return err
	}
	if view == nil {
		return errkontrak.NotFound(
			fmt.Sprintf("Jadwal hitung id %d tidak ditemukan.", id),
			domain.KodeInvTidakDitemukan,
		)
	}
	*out = *view
	return nil
}

// pointerString — string → *string.
func pointerString(s string) *string { return &s }
