// penyesuaian.go — orkestrasi fitur PENYESUAIAN STOK modul inv (padanan
// services/operasi/penyesuaian.service.ts NestJS INV-F08/F12 — VERBATIM
// pesan, kode & urutan langkah; TANPA data-scope — paritas sumber):
//
//   - draft dibuat dengan snapshot nama_produk + qty_selisih dihitung app;
//   - ajukan: lewati ambang CFG-INV-08/09 (lewatiAmbangApproval) →
//     MENUNGGU_PERSETUJUAN; tanpa ambang → langsung DISETUJUI + posting
//     gerakan PENYESUAIAN + recompute (aktor sistem, penyetuju NULL,
//     audit ajukan_auto_approve); PATCH guard DRAFT DULU baru versi
//     (urutan beda dari mutasi — verbatim);
//   - keputusan: SoD penyusun ≠ penyetuju (server-side, INV-004, pesan
//     BERBEDA dari mutasi — verbatim); SETUJUI → posting gerakan per item
//     selisih ≠ 0 (plus = ADJ-VIRTUAL → lokasi item; minus = lokasi item →
//     ADJ-VIRTUAL; SELESAI) → recompute → ck_inv_saldo_on_hand → 409
//     INV-010 pesan panjang; actorId KETAT (tolak id 0);
//   - batal: hanya DRAFT/MENUNGGU_PERSETUJUAN, alasan wajib (INV-005);
//   - kemasan (ddl/54): server OTORITAS konversi — qty_hitung :=
//     qty_kemasan_hitung × kemasan.qty_isi, mismatch kiriman FE → 400
//     (4 pesan verbatim); kode kemasan unik GLOBAL (ratifikasi);
//   - resolver barcode terpadu (D-37) PRODUK→LOT(+saldo)→KEMASAN — 404
//     INV-015 pesan verbatim;
//   - valuasi FIFO (D-27) — domain/valuasi.go milik fitur gerakan: plus
//     melahirkan lapisan, minus mengonsumsi lapisan tertua (fallback
//     harga_biaya → audit); recompute saldo via repository.RecomputeSaldoStok
//     (fungsi eksport milik fitur gerakan — dipanggil sesuai kontrak).
package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/core/numbering"
	"nexierp/internal/core/outbox"
	"nexierp/internal/core/pkcipher"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// KODE_LOKASI_ADJ — kode lokasi penyesuaian (konvensi seed & gerakan
// plus/minus — padanan types/penyesuaian-types.ts).
const KODE_LOKASI_ADJ = "ADJ-VIRTUAL"

// PenyesuaianService — dependensi kernel + repo penyesuaian.
type PenyesuaianService struct {
	DB        *database.DB
	Audit     *audit.Service
	Numbering *numbering.Service
	Outbox    *outbox.Service
	Cfg       *moduleconfig.Service
	Cipher    *pkcipher.Cipher
	Repo      *repository.PenyesuaianRepository
}

// NewPenyesuaianService — wiring dari Deps modul (dipanggil handler).
func NewPenyesuaianService(d types.Deps) *PenyesuaianService {
	return &PenyesuaianService{
		DB:        d.DB,
		Audit:     d.Audit,
		Numbering: d.Numbering,
		Outbox:    d.Outbox,
		Cfg:       d.ModCfg,
		Cipher:    d.Cipher,
		Repo:      repository.NewPenyesuaianRepository(),
	}
}

// PenyesuaianItemInput — baris item (hasil validasi handler; qtySelisih
// dihitung app saat simpan — DDL, bukan dipercaya dari FE).
type PenyesuaianItemInput struct {
	IDInvProduk      int64
	IDInvLotSerial   *int64
	IDInvLokasiStok  int64
	IDInvUnitUkur    int64
	IDInvKemasan     *int64
	QtyKemasanHitung *int
	QtySistem        int
	QtyHitung        int
	BiayaSatuan      *float64
}

// PenyesuaianCreateInput — body POST (header + items SATU transaksi).
type PenyesuaianCreateInput struct {
	Jenis          string
	IDInvGudang    int64
	TanggalDokumen *string
	Alasan         *string
	Items          []PenyesuaianItemInput
}

// PenyesuaianUpdateInput — body PATCH (items REPLACE penuh bila dikirim).
type PenyesuaianUpdateInput struct {
	Jenis          string // "" = tidak dikirim
	TanggalAda     bool
	TanggalDokumen *string
	AlasanAda      bool
	Alasan         *string
	ItemsAda       bool
	Items          []PenyesuaianItemInput
	Version        int64
}

// PenyesuaianKeputusanInput — body keputusan auditor.
type PenyesuaianKeputusanInput struct {
	Keputusan string // SETUJUI | TOLAK
	Alasan    *string
}

/* -------------------------------------------------------------- */
/* Baca                                                          */
/* -------------------------------------------------------------- */

// List — daftar penyesuaian — header + items (kelompok kecil) + filter
// status/jenis.
func (s *PenyesuaianService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.PenyesuaianView], error) {
	var page errkontrak.Page[repository.PenyesuaianView]
	// Whitelist sort list penyesuaian (default -id).
	if err := opSortWhitelist(pr, "kode", "tanggal_dokumen", "created_at", "createdAt", "updatedAt"); err != nil {
		return page, err
	}
	sortCol, sortDesc := opPilihSort(pr, map[string]string{
		"kode":            "kode",
		"tanggal_dokumen": "tanggal_dokumen",
		"created_at":      "created_at",
		"createdAt":       "createdAt",
		"updatedAt":       "updatedAt",
	}, "")
	data, total, err := s.Repo.ListPenyesuaian(ctx, s.DB.Pool, repository.PenyesuaianListFilter{
		Status:   opFilterVal(pr, "status"),
		Jenis:    opFilterVal(pr, "jenis"),
		Search:   opFilterVal(pr, "search"),
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Limit:    int32(pr.Limit),
		Offset:   int32(pr.Offset),
	})
	if err != nil {
		return page, err
	}
	// Token PK tersamar per baris (URL halaman form — pola pemasok PUR).
	for i := range data {
		if err := s.beriToken(&data[i]); err != nil {
			return page, err
		}
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Get — detail penyesuaian — items lengkap; 404 INV-018; :id menerima
// token ATAU numeric id.
func (s *PenyesuaianService) Get(ctx context.Context, idRaw string) (repository.PenyesuaianView, error) {
	id, err := opResolusiID(s.Cipher, idRaw)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	view, err := s.Repo.MuatSatu(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	if err := s.beriToken(&view); err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Draft                                                          */
/* -------------------------------------------------------------- */

// Create — buat draft — header + items SATU UoW; kode ADJ via penomoran.
func (s *PenyesuaianService) Create(ctx context.Context, in PenyesuaianCreateInput, c CtxMutasi) (repository.PenyesuaianView, error) {
	var view repository.PenyesuaianView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		gudang, err := s.Repo.GudangHidupById(ctx, tx, in.IDInvGudang)
		if err != nil {
			return err
		}
		if gudang == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Gudang id %d tidak ditemukan.", in.IDInvGudang),
				domain.KodeInvTidakDitemukan,
			)
		}
		kode, err := s.Numbering.Next(ctx, tx, "inventory", "ADJ", numbering.Options{Prefix: "ADJ/{MMyy}", Padding: 4})
		if err != nil {
			return err
		}
		tanggal := opWaktuSekarang()
		if in.TanggalDokumen != nil {
			t, err := opWaktuParse(*in.TanggalDokumen)
			if err != nil {
				return err
			}
			tanggal = t
		}
		header, err := s.Repo.InsertPenyesuaian(ctx, tx, repository.InsertPenyesuaianParams{
			EntityID:            opUuidParam(numbering.NewEntityID()),
			Kode:                kode,
			Jenis:               repository.EnumJenisPenyesuaian(in.Jenis),
			Status:              repository.EnumStatusPenyesuaian("DRAFT"),
			IDInvGudang:         in.IDInvGudang,
			TanggalDokumen:      opWaktu(tanggal),
			IDCoreUsersPenyusun: opI8N(opActorID(c)),
			Alasan:              opTeks(in.Alasan),
		})
		if err != nil {
			return err
		}
		if err := s.sisipItems(ctx, tx, header.ID, in.Items); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_penyesuaian_stok",
				EntityID:   fmt.Sprintf("%d", header.ID),
				Action:     "create_draft",
				AfterValue: audit.Snapshot{"kode": header.Kode, "jenis": string(header.Jenis), "items": len(in.Items)},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.Repo.MuatSatu(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

// Update — ubah draft — items REPLACE penuh; guard DRAFT DULU baru versi
// (urutan beda dari mutasi — verbatim sumber).
func (s *PenyesuaianService) Update(ctx context.Context, idRaw string, in PenyesuaianUpdateInput, c CtxMutasi) (repository.PenyesuaianView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	var view repository.PenyesuaianView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.PenyesuaianHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if string(header.Status) != "DRAFT" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Penyesuaian %s status %s — hanya DRAFT bisa diubah (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		if int64(header.Version) != in.Version {
			return errkontrak.Conflict(fmt.Sprintf(
				"Versi penyesuaian tidak cocok (server %d, kirim %d).", header.Version, in.Version),
				domain.KodeInvVersiBentrok)
		}
		jenis := string(header.Jenis)
		if in.Jenis != "" {
			jenis = in.Jenis
		}
		tanggal := header.TanggalDokumen.Time
		if in.TanggalAda && in.TanggalDokumen != nil {
			t, err := opWaktuParse(*in.TanggalDokumen)
			if err != nil {
				return err
			}
			tanggal = t
		}
		alasan := opTxt(header.Alasan)
		if in.AlasanAda {
			alasan = in.Alasan
		}
		if err := s.Repo.UpdateDraft(ctx, tx, repository.UpdatePenyesuaianDraftParams{
			Jenis:          repository.EnumJenisPenyesuaian(jenis),
			TanggalDokumen: opWaktu(tanggal),
			Alasan:         opTeks(alasan),
			Version:        header.Version + 1,
			UpdatedAt:      opWaktu(opWaktuSekarang()),
			ID:             id,
		}); err != nil {
			return err
		}
		if in.ItemsAda {
			// Soft delete item lama + sisip item baru (satu UoW).
			sekarang := opWaktuSekarang()
			if err := s.Repo.SoftDeleteItemsHidupByHeader(ctx, tx, id, sekarang, sekarang); err != nil {
				return err
			}
			if err := s.sisipItems(ctx, tx, id, in.Items); err != nil {
				return err
			}
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_penyesuaian_stok",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update_draft",
				AfterValue: audit.Snapshot{"version": header.Version + 1},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.Repo.MuatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Ajukan & keputusan                                             */
/* -------------------------------------------------------------- */

// Ajukan — di atas ambang CFG-INV-08/09 → MENUNGGU_PERSETUJUAN; di bawah
// ambang → langsung DISETUJUI + posting gerakan (aktor sistem, penyetuju
// NULL, audit ajukan_auto_approve).
func (s *PenyesuaianService) Ajukan(ctx context.Context, idRaw string, version int64, c CtxMutasi) (repository.PenyesuaianView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	var view repository.PenyesuaianView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.PenyesuaianHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if string(header.Status) != "DRAFT" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Penyesuaian %s status %s — hanya DRAFT bisa diajukan (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		if int64(header.Version) != version {
			return errkontrak.Conflict(fmt.Sprintf(
				"Versi penyesuaian tidak cocok (server %d, kirim %d).", header.Version, version),
				domain.KodeInvVersiBentrok)
		}
		items, err := s.Repo.ItemsHidupByHeader(ctx, tx, id)
		if err != nil {
			return err
		}
		mode, err := s.Cfg.GetString(ctx, tx, "inventory", "CFG-INV-08", "TANPA_APPROVAL")
		if err != nil {
			return err
		}
		if mode == "" {
			mode = "TANPA_APPROVAL"
		}
		ambang, err := s.ambangApproval(ctx, tx)
		if err != nil {
			return err
		}
		lewati := lewatiAmbangApproval(mode, barisAmbangDari(items), ambang.qty, ambang.nilai)
		if lewati {
			if err := s.Repo.UpdateStatus(ctx, tx, repository.UpdatePenyesuaianStatusParams{
				Status:    repository.EnumStatusPenyesuaian("MENUNGGU_PERSETUJUAN"),
				Version:   header.Version + 1,
				UpdatedAt: opWaktu(opWaktuSekarang()),
				ID:        id,
			}); err != nil {
				return err
			}
			if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
				EntryInput: audit.EntryInput{
					ModuleKey:  "inventory",
					EntityType: "inv_penyesuaian_stok",
					EntityID:   fmt.Sprintf("%d", id),
					Action:     "ajukan",
					AfterValue: audit.Snapshot{"status": "MENUNGGU_PERSETUJUAN"},
				},
				Actor: c.Actor,
			}}); err != nil {
				return err
			}
			view, err = s.Repo.MuatSatu(ctx, tx, id)
			if err != nil {
				return err
			}
			return s.beriToken(&view)
		}
		// Tanpa ambang — auto approve (aktor sistem, penyetuju NULL) + posting.
		if err := s.postingGerakan(ctx, tx, header, items, c); err != nil {
			return err
		}
		if err := s.Repo.UpdateStatus(ctx, tx, repository.UpdatePenyesuaianStatusParams{
			Status:    repository.EnumStatusPenyesuaian("DISETUJUI"),
			Version:   header.Version + 1,
			UpdatedAt: opWaktu(opWaktuSekarang()),
			ID:        id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_penyesuaian_stok",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "ajukan_auto_approve",
				AfterValue: audit.Snapshot{"status": "DISETUJUI"},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.Repo.MuatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

// Keputusan — auditor; SoD penyusun ≠ penyetuju server-side (INV-004 —
// pesan BERBEDA dari mutasi, verbatim); SETUJUI → posting gerakan
// PENYESUAIAN per item selisih ≠ 0; DITOLAK → simpan alasan (wajib,
// divalidasi schema).
func (s *PenyesuaianService) Keputusan(ctx context.Context, idRaw string, in PenyesuaianKeputusanInput, c CtxMutasi) (repository.PenyesuaianView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	var view repository.PenyesuaianView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.PenyesuaianHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if string(header.Status) != "MENUNGGU_PERSETUJUAN" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Penyesuaian %s status %s — keputusan hanya utk MENUNGGU_PERSETUJUAN (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		// SoD (INV-BR04): penyusun tidak boleh menyetujui dokumennya sendiri.
		aktor := opActorID(c)
		if aktor != nil && header.IDCoreUsersPenyusun.Valid && header.IDCoreUsersPenyusun.Int64 == *aktor {
			return errkontrak.Conflict(
				"SoD dilanggar — penyusun penyesuaian tidak boleh menjadi penyetujunya (INV-004).",
				opKodeInvSodDilanggar)
		}
		items, err := s.Repo.ItemsHidupByHeader(ctx, tx, id)
		if err != nil {
			return err
		}
		if in.Keputusan == "SETUJUI" {
			if err := s.postingGerakan(ctx, tx, header, items, c); err != nil {
				return err
			}
			// Gap kontrak tercatat: DDL tidak punya kolom alasan_keputusan —
			// jejak keputusan disimpan di kolom `alasan` (satu kolom).
			alasan := opTxt(header.Alasan)
			if in.Alasan != nil {
				alasan = in.Alasan
			}
			if err := s.Repo.UpdateStatus(ctx, tx, repository.UpdatePenyesuaianStatusParams{
				Status:               repository.EnumStatusPenyesuaian("DISETUJUI"),
				IDCoreUsersPenyetuju: opI8N(aktor),
				Alasan:               opTeks(alasan),
				Version:              header.Version + 1,
				UpdatedAt:            opWaktu(opWaktuSekarang()),
				ID:                   id,
			}); err != nil {
				return err
			}
		} else {
			if err := s.Repo.UpdateStatus(ctx, tx, repository.UpdatePenyesuaianStatusParams{
				Status:               repository.EnumStatusPenyesuaian("DITOLAK"),
				IDCoreUsersPenyetuju: opI8N(aktor),
				Alasan:               opTeks(in.Alasan), // wajib (schema) — selalu terisi saat TOLAK
				Version:              header.Version + 1,
				UpdatedAt:            opWaktu(opWaktuSekarang()),
				ID:                   id,
			}); err != nil {
				return err
			}
		}
		aksi := "keputusan_tolak"
		if in.Keputusan == "SETUJUI" {
			aksi = "keputusan_setujui"
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_penyesuaian_stok",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     aksi,
				AfterValue: audit.Snapshot{"keputusan": in.Keputusan, "alasan": opSnap(in.Alasan)},
				Severity:   audit.SeverityWarning,
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.Repo.MuatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

// Batal — draft/pengajuan — alasan wajib (INV-005).
func (s *PenyesuaianService) Batal(ctx context.Context, idRaw, alasan string, c CtxMutasi) (repository.PenyesuaianView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	var view repository.PenyesuaianView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.PenyesuaianHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		if string(header.Status) != "DRAFT" && string(header.Status) != "MENUNGGU_PERSETUJUAN" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Penyesuaian %s status %s — hanya DRAFT/MENUNGGU_PERSETUJUAN bisa dibatalkan (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		if err := s.Repo.UpdateStatus(ctx, tx, repository.UpdatePenyesuaianStatusParams{
			Status:    repository.EnumStatusPenyesuaian("DIBATALKAN"),
			Alasan:    opTeks(&alasan),
			Version:   header.Version + 1,
			UpdatedAt: opWaktu(opWaktuSekarang()),
			ID:        id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_penyesuaian_stok",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "batal",
				AfterValue: audit.Snapshot{"status": "DIBATALKAN", "alasan": alasan},
				Severity:   audit.SeverityWarning,
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.Repo.MuatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.PenyesuaianView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// ambangApproval — CFG-INV-09 (json {ambangQty, ambangNilai} nullable).
type ambangCFG struct {
	qty   *float64
	nilai *float64
}

func (s *PenyesuaianService) ambangApproval(ctx context.Context, exec repository.DBTX) (ambangCFG, error) {
	v, err := s.Cfg.GetJson(ctx, exec, "inventory", "CFG-INV-09", map[string]any{"ambangQty": nil, "ambangNilai": nil})
	if err != nil {
		return ambangCFG{}, err
	}
	out := ambangCFG{}
	if m, ok := v.(map[string]any); ok {
		if f, ok := m["ambangQty"].(float64); ok {
			out.qty = &f
		}
		if f, ok := m["ambangNilai"].(float64); ok {
			out.nilai = &f
		}
	}
	return out, nil
}

// barisAmbangDari — items → pasangan {qtySelisih, nilaiSelisih} utk
// lewatiAmbangApproval (nilai = selisih × biaya_satuan ?? 0).
func barisAmbangDari(items []repository.InvPenyesuaianStokItem) []barisAmbang {
	out := make([]barisAmbang, 0, len(items))
	for _, i := range items {
		out = append(out, barisAmbang{
			qtySelisih:   float64(i.QtySelisih),
			nilaiSelisih: float64(i.QtySelisih) * opAngka(i.BiayaSatuan),
		})
	}
	return out
}

// barisAmbang — satu baris evaluasi ambang.
type barisAmbang struct {
	qtySelisih   float64
	nilaiSelisih float64
}

// lewatiAmbangApproval — penyesuaian melewati ambang approval? (CFG-INV-08/09,
// INV-BR04 — padanan helper murni @nexierp/schemas tipe.ts): mode "SEMUA" →
// selalu; "TANPA_APPROVAL" → tidak; "DI_ATAS_AMBANG" → ada baris dengan
// |selisih| > ambangQty ATAU |nilai| > ambangNilai.
func lewatiAmbangApproval(mode string, baris []barisAmbang, ambangQty, ambangNilai *float64) bool {
	if mode == "SEMUA" {
		return true
	}
	if mode == "TANPA_APPROVAL" {
		return false
	}
	for _, b := range baris {
		if ambangQty != nil && math.Abs(b.qtySelisih) > *ambangQty {
			return true
		}
		if ambangNilai != nil && math.Abs(b.nilaiSelisih) > *ambangNilai {
			return true
		}
	}
	return false
}

// catatLapisanFifo — lapisan FIFO utk gerakan PENYESUAIAN SELESAI (D-27):
// plus → INSERT inv_lapisan_biaya (nomor dokumen ADJ sebagai dokumen masuk);
// minus → konsumsi lapisan tertua (lot dicocokkan bila item berlot); lapisan
// kurang → fallback harga_biaya (tidak menggagalkan posting). Hanya produk
// kategori FIFO yang diproses — kategori lain dilewati.
func (s *PenyesuaianService) catatLapisanFifo(ctx context.Context, tx pgx.Tx, item repository.InvPenyesuaianStokItem, plus bool, qty int, kodeDokumen string, idGerakan int64) error {
	metode, hargaBiaya, err := s.Repo.RefValuasiProduk(ctx, tx, item.IDInvProduk)
	if err != nil {
		return err
	}
	if metode == nil || *metode != "FIFO" {
		return nil
	}
	if plus {
		// biaya = biaya_satuan ?? harga_biaya ?? 0 (toFixed(4)).
		var biaya float64
		if item.BiayaSatuan.Valid {
			biaya = opAngka(item.BiayaSatuan)
		} else if hargaBiaya != nil {
			biaya = *hargaBiaya
		}
		var idLot *int64
		if item.IDInvLotSerial.Valid {
			idLot = &item.IDInvLotSerial.Int64
		}
		return s.Repo.InsertLapisanBiaya(ctx, tx, repository.InsertLapisanBiayaParams{
			EntityID:          opUuidParam(numbering.NewEntityID()),
			IDInvProduk:       item.IDInvProduk,
			IDInvLotSerial:    opI8N(idLot),
			NomorDokumenMasuk: kodeDokumen,
			TanggalMasuk:      opWaktu(opWaktuSekarang()),
			QtyMasuk:          int32(qty),
			BiayaPersatuan:    opNumN(biaya),
		})
	}
	var idLot *int64
	if item.IDInvLotSerial.Valid {
		idLot = &item.IDInvLotSerial.Int64
	}
	lapisanRows, err := s.Repo.LapisanFifoTerbuka(ctx, tx, item.IDInvProduk, idLot)
	if err != nil {
		return err
	}
	lapisan := make([]domain.LapisanFifo, 0, len(lapisanRows))
	for _, l := range lapisanRows {
		lapisan = append(lapisan, domain.LapisanFifo{
			ID:    l.ID,
			Sisa:  float64(l.QtyMasuk - l.QtyTerpakai),
			Biaya: opAngka(l.BiayaPersatuan),
		})
	}
	hasil := domain.KonsumsiLapisanFifo(lapisan, float64(qty))
	for _, p := range hasil.Pemakaian {
		if err := s.Repo.TambahQtyTerpakaiLapisan(ctx, tx, p.ID, int(p.Qty), opWaktuSekarang()); err != nil {
			return err
		}
	}
	// Fallback lapisan kurang → nilai gerakan tetap biaya_satuan snapshot;
	// catat di audit posting (nilai_persatuan tidak diubah di sini — sudah
	// ditetapkan dari biaya_satuan item).
	if hasil.FallbackQty > 0 {
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_gerakan_stok",
				EntityID:   fmt.Sprintf("%d", idGerakan),
				Action:     "valuasi_fifo_fallback",
				AfterValue: audit.Snapshot{"nomor": kodeDokumen, "fallback_qty": hasil.FallbackQty},
				Severity:   audit.SeverityWarning,
			},
			Actor: audit.Actor{ActorName: "system"},
		}}); err != nil {
			return err
		}
	}
	// Nilai gerakan minus = rata-rata tertimbang lapisan (konsisten D-27).
	if len(hasil.Pemakaian) > 0 {
		fallbackBiaya := 0.0
		if hargaBiaya != nil {
			fallbackBiaya = *hargaBiaya
		}
		nilai := domain.NilaiPersatuanFifo(hasil, float64(qty), fallbackBiaya)
		if err := s.Repo.SetNilaiPersatuanGerakan(ctx, tx, idGerakan, nilai); err != nil {
			return err
		}
	}
	return nil
}

// sisipItems — snapshot nama produk + qty_selisih hitung app. OTORITAS
// KONVERSI KEMASAN (ddl/54): baris ber-kemasan dihitung ulang server —
// qty_hitung := qty_kemasan_hitung × kemasan.qty_isi (satuan terkecil,
// kontrak readmodel inv_saldo_stok), mismatch kiriman FE → 400; faktor isi
// dibekukan sebagai snapshot isi_per_kemasan di baris.
func (s *PenyesuaianService) sisipItems(ctx context.Context, tx pgx.Tx, headerID int64, items []PenyesuaianItemInput) error {
	if len(items) == 0 {
		return nil
	}
	produkIDs := []int64{}
	for _, i := range items {
		produkIDs = opUnikI64(produkIDs, i.IDInvProduk)
	}
	produkRows, err := s.Repo.ProdukDenganUnitHidupByIds(ctx, tx, produkIDs)
	if err != nil {
		return err
	}
	produkByID := map[int64]repository.ProdukDenganUnitHidupByIdsRow{}
	for _, p := range produkRows {
		produkByID[p.ID] = p
	}
	// Master kemasan pemilik faktor konversi (hidup saja).
	kemasanIDs := []int64{}
	for _, i := range items {
		if i.IDInvKemasan != nil {
			kemasanIDs = opUnikI64(kemasanIDs, *i.IDInvKemasan)
		}
	}
	kemasanRows, err := s.Repo.KemasanHidupByIds(ctx, tx, kemasanIDs)
	if err != nil {
		return err
	}
	kemasanByID := map[int64]repository.KemasanHidupByIdsRow{}
	for _, k := range kemasanRows {
		kemasanByID[k.ID] = k
	}
	for _, item := range items {
		produk, ada := produkByID[item.IDInvProduk]
		if !ada {
			return errkontrak.NotFound(
				fmt.Sprintf("Produk id %d tidak ditemukan.", item.IDInvProduk),
				domain.KodeInvTidakDitemukan,
			)
		}
		var isiPerKemasan *int32
		qtyHitung := item.QtyHitung
		qtySelisih := qtyHitung - item.QtySistem // hitungSelisih app
		if item.IDInvKemasan != nil {
			kemasan, ada := kemasanByID[*item.IDInvKemasan]
			if !ada {
				return errkontrak.NotFound(
					fmt.Sprintf("Kemasan id %d tidak ditemukan / tidak aktif.", *item.IDInvKemasan),
					domain.KodeInvTidakDitemukan,
				)
			}
			if kemasan.IDInvProduk != item.IDInvProduk {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Kemasan %s bukan milik produk terpilih.", kemasan.Kode))
			}
			if kemasan.IDInvUnitUkur != produk.IDInvUnitUkur {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Kemasan %s wajib memakai unit dasar produk — konversi antar unit (unit_konversi) belum didukung pada entry penyesuaian.",
					kemasan.Kode))
			}
			if item.QtyKemasanHitung == nil {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Baris ber-kemasan %s wajib membawa qty kemasan hitung.", kemasan.Kode))
			}
			isi := kemasan.QtyIsi
			isiPerKemasan = &isi
			// Otoritas server — hitung ulang dari master kemasan (satuan terkecil).
			qtyHitung = *item.QtyKemasanHitung * int(kemasan.QtyIsi)
			if item.QtyHitung != qtyHitung {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Qty hitung tidak cocok: %d × %d (isi %s) = %d, kiriman %d.",
					*item.QtyKemasanHitung, kemasan.QtyIsi, kemasan.Kode, qtyHitung, item.QtyHitung))
			}
			qtySelisih = qtyHitung - item.QtySistem
		}
		if err := s.Repo.InsertItem(ctx, tx, repository.InsertPenyesuaianItemParams{
			EntityID:             opUuidParam(numbering.NewEntityID()),
			IDInvPenyesuaianStok: headerID,
			IDInvProduk:          item.IDInvProduk,
			IDInvLotSerial:       opI8N(item.IDInvLotSerial),
			IDInvLokasiStok:      item.IDInvLokasiStok,
			IDInvUnitUkur:        item.IDInvUnitUkur,
			IDInvKemasan:         opI8N(item.IDInvKemasan),
			IsiPerKemasan:        opI4N(isiPerKemasan),
			QtySistem:            int32(item.QtySistem),
			QtyHitung:            int32(qtyHitung),
			QtySelisih:           int32(qtySelisih),
			BiayaSatuan:          opNumNp(item.BiayaSatuan),
			NamaProduk:           produk.Nama,
		}); err != nil {
			return err
		}
	}
	return nil
}

// postingGerakan — posting gerakan PENYESUAIAN per item selisih ≠ 0
// (konvensi ADJ-VIRTUAL): plus = sumber ADJ → tujuan lokasi item; minus =
// sumber lokasi item → tujuan ADJ. Status SELESAI + nilai biaya_satuan;
// header SEKALI per dokumen (PATCH 09); recompute + M16 per gerakan.
func (s *PenyesuaianService) postingGerakan(ctx context.Context, tx pgx.Tx, header repository.InvPenyesuaianStok, items []repository.InvPenyesuaianStokItem, c CtxMutasi) error {
	adjLokasi, err := s.Repo.LokasiHidupByKode(ctx, tx, KODE_LOKASI_ADJ)
	if err != nil {
		return err
	}
	if adjLokasi == nil {
		return errkontrak.BadRequest(fmt.Sprintf(
			"Lokasi penyesuaian '%s' belum terpasang (INV-006).", KODE_LOKASI_ADJ),
			opKodeInvKonfigurasiTidakSah)
	}
	aktor := opActorID(c)
	gerakanHeaderInserted := false
	var gHeader repository.InvGerakanHeader
	entityIDHeader := ""
	for _, item := range items {
		if item.QtySelisih == 0 {
			continue // count tanpa selisih — tanpa gerakan
		}
		plus := item.QtySelisih > 0
		qty := int(math.Abs(float64(item.QtySelisih)))
		// entity_id_sumber per ITEM (bukan per dokumen) — uq_inv_gerakan_idempoten
		// melarang dua gerakan produk sama dalam satu dokumen; penyesuaian sah
		// punya beberapa item produk sama (lot/lokasi beda — hasil cycle count
		// per lot). Kunci per item tetap idempoten: retry posting item sama →
		// kunci sama. PATCH 09 — header gerakan (lokasi NULL — D-48, lokasi
		// per baris) SEKALI per dokumen + detail per item (override lokasi).
		if !gerakanHeaderInserted {
			entityIDBaru := numbering.NewEntityID()
			gh, err := repository.InsertGerakanHeader(ctx, tx, repository.OpGerakanHeaderInput{
				EntityID:            entityIDBaru,
				NomorDokumen:        header.Kode,
				Jenis:               "PENYESUAIAN",
				Status:              "SELESAI",
				TanggalJadwal:       opWaktuSekarang(),
				TanggalSelesai:      pointerTime(opWaktuSekarang()),
				JenisSumber:         "ADJ",
				IDCoreUsers:         aktor,
				IDCoreUsersPenyusun: aktor,
			})
			if err != nil {
				return err
			}
			gHeader = gh
			entityIDHeader = entityIDBaru
			gerakanHeaderInserted = true
		}
		var idLot *int64
		if item.IDInvLotSerial.Valid {
			idLot = &item.IDInvLotSerial.Int64
		}
		var nilai *float64
		if item.BiayaSatuan.Valid {
			v := opAngka(item.BiayaSatuan)
			nilai = &v
		}
		sekarang := opWaktuSekarang()
		gerakan, err := repository.InsertGerakanStok(ctx, tx, repository.OpGerakanStokInput{
			EntityID:           numbering.NewEntityID(),
			IDInvGerakanHeader: gHeader.ID,
			IDInvProduk:        item.IDInvProduk,
			IDInvLotSerial:     idLot,
			IDInvUnitUkur:      item.IDInvUnitUkur,
			QtyDiminta:         qty,
			QtySelesai:         qty,
			// D-48 — override lokasi per baris (plus: ADJ-VIRTUAL→lokasi).
			IDLokasiSumber: pilihLokasi(plus, adjLokasi.ID, item.IDInvLokasiStok),
			IDLokasiTujuan: pilihLokasi(!plus, adjLokasi.ID, item.IDInvLokasiStok),
			NilaiPersatuan: nilai,
			TanggalSelesai: pointerTime(sekarang),
			EntityIDSumber: fmt.Sprintf("%s:%d", entityIDHeader, item.ID),
		})
		if err != nil {
			return err
		}
		// Patch 04 (D-27): lapisan FIFO — penyesuaian-plus melahirkan lapisan,
		// penyesuaian-minus mengonsumsi lapisan tertua (fallback harga_biaya).
		if item.BiayaSatuan.Valid || !plus {
			if err := s.catatLapisanFifo(ctx, tx, item, plus, qty, header.Kode, gerakan.ID); err != nil {
				return err
			}
		}
		// M16 per gerakan (idempoten per move_id).
		kunci := fmt.Sprintf("move:%d", gerakan.ID)
		nilaiTotal := 0.0
		if nilai != nil {
			nilaiTotal = *nilai * float64(gerakan.QtySelesai)
		}
		if _, err := s.Outbox.Enqueue(ctx, tx, outbox.EventInput{
			Topic: "inventory.move.completed",
			Key:   &kunci,
			Payload: map[string]any{
				"moveId":       gerakan.ID,
				"nomorDokumen": gHeader.NomorDokumen,
				"jenis":        string(gHeader.Jenis),
				"qtySelesai":   gerakan.QtySelesai,
				"nilai":        nilaiTotal,
				"gudang":       header.IDInvGudang,
			},
		}); err != nil {
			return err
		}
	}
	if adaSelisih(items) {
		if err := recomputeSaldo(ctx, tx); err != nil {
			// Invariant INV-BR03 (ck_inv_saldo_on_hand) — penyesuaian minus
			// melebihi saldo aktual (sheet basi: saldo berubah sejak
			// generate). Gagal keras DB → 500 SYS-000 dipetakan jadi 409.
			var pe *pgconn.PgError
			if (errors.As(err, &pe) && strings.Contains(pe.ConstraintName, "ck_inv_saldo_on_hand")) ||
				strings.Contains(err.Error(), "ck_inv_saldo_on_hand") {
				return errkontrak.Conflict(
					"Penyesuaian minus melebihi saldo aktual — saldo berubah sejak count sheet dibuat; muat ulang sheet (INV-010/INV-BR03).",
					domain.KodeInvSaldoTidakCukup,
				)
			}
			return err
		}
	}
	return nil
}

// recomputeSaldo — repository.RecomputeSaldoStok milik fitur GERAKAN
// (fungsi eksport — satu-satunya jalur rebuild READMODEL). Men-trigger
// invariant ck_inv_saldo_on_hand (INV-BR03): penyesuaian minus melebihi
// saldo aktual → dipetakan 409 INV-010 oleh pemanggil.
func recomputeSaldo(ctx context.Context, exec repository.DBTX) error {
	_, err := repository.RecomputeSaldoStok(ctx, exec)
	return err
}

// pilihLokasi — plus → ADJ; minus → lokasi item (helper keterbacaan D-48).
func pilihLokasi(pakaiADJ bool, idADJ, idItem int64) int64 {
	if pakaiADJ {
		return idADJ
	}
	return idItem
}

// adaSelisih — items.some((i) => i.qtySelisih !== 0).
func adaSelisih(items []repository.InvPenyesuaianStokItem) bool {
	for _, i := range items {
		if i.QtySelisih != 0 {
			return true
		}
	}
	return false
}

// pointerTime — time.Time → *time.Time.
func pointerTime(t time.Time) *time.Time { return &t }

// beriToken — tempel token PK tersamar ke view.
func (s *PenyesuaianService) beriToken(v *repository.PenyesuaianView) error {
	token, err := s.Cipher.EncryptID(v.ID)
	if err != nil {
		return err
	}
	v.Token = token
	return nil
}

/* -------------------------------------------------------------- */
/* Resolver barcode terpadu (D-37) — mode entri scanner             */
/* -------------------------------------------------------------- */

// ResolveBarcode — resolve barcode → PRODUK / LOT / KEMASAN (prioritas
// urut; semua hidup, soft-delete-aware; produk nonaktif tetap cocok demi
// opname baris lama — draft tetap tervalidasi sisipItems).
func (s *PenyesuaianService) ResolveBarcode(ctx context.Context, kodeRaw string) (repository.BarcodeResolveView, error) {
	var kosong repository.BarcodeResolveView
	kode := strings.TrimSpace(kodeRaw)
	if kode == "" {
		return kosong, errkontrak.Validation([]errkontrak.FieldIssue{
			{Field: "kode", Message: "Barcode wajib diisi."},
		})
	}
	// 1) PRODUK — barcode kartu induk.
	produk, err := s.Repo.ProdukByBarcode(ctx, s.DB.Pool, kode)
	if err != nil {
		return kosong, err
	}
	if produk != nil {
		return repository.BarcodeResolveView{
			Sumber:  "PRODUK",
			Barcode: kode,
			Label:   fmt.Sprintf("%s · %s", produk.KodeProduk, produk.Nama),
			Produk:  *produk,
			Lot:     nil,
			Kemasan: nil,
		}, nil
	}
	// 2) LOT — barcode lot/serial (+ saldo lot hidup).
	produk, lot, err := s.Repo.LotByBarcode(ctx, s.DB.Pool, kode)
	if err != nil {
		return kosong, err
	}
	if produk != nil && lot != nil {
		return repository.BarcodeResolveView{
			Sumber:  "LOT",
			Barcode: kode,
			Label:   fmt.Sprintf("%s · %s (Lot %s)", produk.KodeProduk, produk.Nama, lot.Kode),
			Produk:  *produk,
			Lot:     lot,
			Kemasan: nil,
		}, nil
	}
	// 3) KEMASAN — barcode kemasan (unit isi = unit dasar produk, ddl/54).
	produk, kemasan, err := s.Repo.KemasanByBarcode(ctx, s.DB.Pool, kode)
	if err != nil {
		return kosong, err
	}
	if produk != nil && kemasan != nil {
		return repository.BarcodeResolveView{
			Sumber:  "KEMASAN",
			Barcode: kode,
			Label:   fmt.Sprintf("%s · %s (%s isi %d)", produk.KodeProduk, produk.Nama, kemasan.Kode, kemasan.QtyIsi),
			Produk:  *produk,
			Lot:     nil,
			Kemasan: kemasan,
		}, nil
	}
	return kosong, errkontrak.NotFound(
		fmt.Sprintf("Barcode '%s' tidak dikenali pada produk/lot/kemasan manapun.", kode),
		domain.KodeInvBarcodeTidakCocok,
	)
}
