// picking.go — orkestrasi fitur PICKING modul inv (padanan
// services/operasi/picking.service.ts NestJS patch 04 — A-02/D-25, VERBATIM
// pesan & urutan): daftar kerja agregat per `nomor_dokumen` + eksekusi
// multi-langkah. Picking TIDAK punya tabel sendiri (D-07/D-25): agregat
// dihitung dari inv_gerakan_stok/header TERBUKA (bukan SELESAI/BATAL); semua
// gerakan satu nomor berbagi `langkah/total_langkah` dan dimajukan BERSAMA
// lewat POST /picking/{nomor}/langkah. Konfirmasi stok tetap di endpoint
// gerakan dan hanya boleh pada langkah terakhir (guard INV-019 milik fitur
// gerakan). Coupling ke service gerakan DIPERTAHANKAN lewat repository view
// (MuatViewGerakan — padanan GerakanService.viewsByIds; delegasi di repo
// karena service gerakan milik agent gerakan — mapper muatView FLAT D-51
// dipindah verbatim).
package service

import (
	"context"
	"fmt"
	"net/url"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// PickingService — dependensi kernel + repo picking.
type PickingService struct {
	DB    *database.DB
	Audit *audit.Service
	Repo  *repository.PickingRepository
}

// NewPickingService — wiring dari Deps modul (dipanggil handler).
func NewPickingService(d types.Deps) *PickingService {
	return &PickingService{DB: d.DB, Audit: d.Audit, Repo: repository.NewPickingRepository()}
}

// pickingListFilter — filter list (parsed dari filter paging).
type pickingListFilter struct {
	jenis          *string
	idGudang       *int64
	search         *string
	onlyBelumAkhir bool
	sortCol        string
	sortDesc       bool
	limit          int32
	offset         int32
}

// List — daftar picking agregat GROUP BY nomor_dokumen pada gerakan TERBUKA;
// filter jenis/gudang/search/onlyTahapBelumAkhir.
func (s *PickingService) List(ctx context.Context, query url.Values) (errkontrak.Page[repository.PickingLangkahView], error) {
	var page errkontrak.Page[repository.PickingLangkahView]
	pr, err := errkontrak.ParsePageRequest(query)
	if err != nil {
		return page, err
	}
	// Whitelist sort query-side (manual map — agregat rawSQL).
	if err := opSortWhitelist(pr, "nomorDokumen", "nomor_dokumen", "tanggalJadwal", "tanggal_jadwal"); err != nil {
		return page, err
	}
	f := pickingListFilter{
		jenis:    opFilterVal(pr, "jenis"),
		search:   opFilterVal(pr, "search"),
		sortCol:  "tanggal_jadwal",
		sortDesc: false,
		limit:    int32(pr.Limit),
		offset:   int32(pr.Offset),
	}
	sortCol, sortDesc := opPilihSort(pr, map[string]string{
		"nomorDokumen":   "nomor_dokumen",
		"nomor_dokumen":  "nomor_dokumen",
		"tanggalJadwal":  "tanggal_jadwal",
		"tanggal_jadwal": "tanggal_jadwal",
	}, "tanggal_jadwal")
	f.sortCol = sortCol
	f.sortDesc = sortDesc
	if v := opFilterVal(pr, "idGudang"); v != nil {
		id, err := opFilterAngka(*v)
		if err != nil {
			return page, err
		}
		f.idGudang = id
	}
	if v := opFilterVal(pr, "onlyTahapBelumAkhir"); v != nil {
		f.onlyBelumAkhir = *v == "1" || *v == "true"
	}
	data, total, err := s.Repo.List(ctx, s.DB.Pool, repository.PickingListFilter{
		Jenis:          f.jenis,
		IDGudang:       f.idGudang,
		Search:         f.search,
		OnlyBelumAkhir: f.onlyBelumAkhir,
		SortCol:        f.sortCol,
		SortDesc:       f.sortDesc,
		Limit:          f.limit,
		Offset:         f.offset,
	})
	if err != nil {
		return page, err
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Get — detail picking — semua baris gerakan satu nomor (terbuka maupun
// final); kosong → 404 INV-018 pesan verbatim.
func (s *PickingService) Get(ctx context.Context, nomorDokumen string) ([]repository.GerakanStokView, error) {
	rows, err := s.Repo.GerakanStokIdsByNomor(ctx, s.DB.Pool, nomorDokumen)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, errkontrak.NotFound(
			fmt.Sprintf("Picking %s tidak ditemukan.", nomorDokumen),
			domain.KodeInvTidakDitemukan,
		)
	}
	return s.Repo.MuatViewGerakan(ctx, s.DB.Pool, rows)
}

// MajukanLangkah — UPDATE SEMUA gerakan nomor SET langkah+1 (satu UoW +
// audit). Ditolak: nomor tak ada (404), sudah final (409 INV-012), sudah di
// langkah akhir (409 INV-019 — konfirmasi stok saja), jenis operasi tak
// dikenal (409 INV-020).
func (s *PickingService) MajukanLangkah(ctx context.Context, nomorDokumen string, c CtxMutasi) (repository.PickingLangkahView, error) {
	var view repository.PickingLangkahView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		// PATCH 09 — langkah milik HEADER dokumen; satu UPDATE satu baris.
		header, err := s.Repo.HeaderByNomor(ctx, tx, nomorDokumen)
		if err != nil {
			return err
		}
		if header == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Picking %s tidak ditemukan.", nomorDokumen),
				domain.KodeInvTidakDitemukan,
			)
		}
		if header.Status == "SELESAI" || header.Status == "BATAL" {
			return errkontrak.Conflict(
				fmt.Sprintf("Picking %s sudah final — tidak bisa dimajukan (INV-012).", nomorDokumen),
				opKodeInvGerakanFinal,
			)
		}
		langkah := int(header.Langkah)
		totalLangkah := int(header.TotalLangkah)
		if langkah >= totalLangkah {
			// INV-019 dibalik: bukan "belum selesai" melainkan "sudah langkah akhir".
			return errkontrak.Conflict(
				fmt.Sprintf("Picking %s sudah di langkah akhir (%d/%d) — lanjutkan dengan konfirmasi stok (INV-019).",
					nomorDokumen, langkah, totalLangkah),
				opKodeInvLangkahBelumSelesai,
			)
		}
		kodeOperasi := opTxt(header.KodeJenisOperasi)
		if kodeOperasi == nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Picking %s tanpa jenis operasi (kode null) — tidak bisa dimajukan (INV-020).", nomorDokumen),
				opKodeInvJenisOperasiTidakSah,
			)
		}
		jenisOperasiRow, err := s.Repo.JenisOperasiIdByKode(ctx, tx, *kodeOperasi)
		if err != nil {
			return err
		}
		if jenisOperasiRow == nil {
			return errkontrak.Conflict(
				fmt.Sprintf("Jenis operasi '%s' tidak dikenal (dihapus/arsip) — tidak bisa dimajukan (INV-020).", *kodeOperasi),
				opKodeInvJenisOperasiTidakSah,
			)
		}

		sekarang := opWaktuSekarang()
		if err := s.Repo.UpdateHeaderLangkah(ctx, tx, header.ID, header.Langkah+1, header.Version+1, sekarang); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_gerakan_stok",
				EntityID:   nomorDokumen,
				Action:     "picking_majukan_langkah",
				AfterValue: audit.Snapshot{
					"nomor":         nomorDokumen,
					"langkah_dari":  langkah,
					"langkah_ke":    langkah + 1,
					"total_langkah": totalLangkah,
				},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}

		// Susun view agregat pasca-update (dalam tx yang sama) — agregasi atas
		// baris TERBUKA saja (konsisten daftar picking).
		agregat, err := s.Repo.AgregatNomorTerbuka(ctx, tx, nomorDokumen)
		if err != nil {
			return err
		}
		if agregat == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Picking %s tidak ditemukan.", nomorDokumen),
				domain.KodeInvTidakDitemukan,
			)
		}
		jenisOperasiMap, err := s.Repo.MuatJenisOperasi(ctx, tx)
		if err != nil {
			return err
		}
		view = repository.ToViewPicking(*agregat, jenisOperasiMap)
		return nil
	})
	if err != nil {
		return repository.PickingLangkahView{}, err
	}
	return view, nil
}

// opFilterAngka — filter numerik semantik Number(); gagal → 500 generik
// (NestJS mengikat NaN ke query → PG error → 500; jalur praktis tak ditempuh
// pemakai normal).
func opFilterAngka(raw string) (*int64, error) {
	var f float64
	if _, err := fmt.Sscanf(raw, "%g", &f); err != nil {
		return nil, errkontrak.Internal("")
	}
	v := int64(f)
	return &v, nil
}
