// service/gerakan.go — orkestrasi fitur GERAKAN STOK modul inv
// (INV-F04/F05/F06/F12 — padanan services/operasi/gerakan.service.ts NestJS
// VERBATIM: alur konfirmasi 14 langkah SATU transaksi, pesan & kode error
// INV-0xx persis). SATU pgx tx per mutasi membungkus repo + audit + outbox +
// numbering + config + valuasi + recompute — outbox/audit/numbering DI DALAM
// transaksi. Jantung modul: satu-satunya jalur perubahan saldo (INV-BR03).
// Service TIDAK mengimpor gen sqlc (guard lapisan) — baris/params melalui
// tipe wrapper repository.
//
// Alur konfirmasi 14 langkah (urutan persis sumber):
//  1. muatRowLengkap (404 INV-018)          8. tuntas = qtySelesai ≥ qtyDiminta
//  2. guard status STATUS_TERBUKA (INV-012) 9. lapisan biaya HANYA saat tuntas
//  3. guard langkah D-25 (INV-019)             (STANDAR/AVCO/FIFO D-27/D-28)
//  4. master valuasi (default STANDAR)     10. updateDetail (version+1)
//  5. arah (masuk = PENERIMAAN/ADJ-INT)    11. derive status dokumen D-49
//  6. lot: FEFO paksa D-31 + INV-007/008/009 12. saat tuntas: RECOMPUTESALDOSTOK
//  7. saldoCukup keluar (INV-010)          13. emitEventsGerakanSelesai + reorder
//  14. backorder CFG-INV-05 + audit
package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/core/numbering"
	"nexierp/internal/core/outbox"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
)

// Kode error INV-xxx — verbatim KODE_ERROR_INV (STD-10).
const (
	invErrGerakanTidakSah     = "INV-003"
	invErrSaldoTidakCukup     = "INV-010"
	invErrGerakanFinal        = "INV-012"
	invErrTidakDitemukan      = "INV-018"
	invErrLangkahBelumSelesai = "INV-019"
)

// MutationContext — konteks mutasi (padanan MutationContext inv.views.ts):
// aktor WAJIB dari JWT (bukan payload client), IP & UA dari request.
type MutationContext struct {
	Actor     *rbac.AuthenticatedUser // nil = sistem ({id:0, username:"system"})
	IPAddress string
	UserAgent string
}

// aktorAudit — padanan mutationActor: idCoreUsers = actor?.id ?? null
// (LONGGAR — tanpa guard id>0, verbatim operasi/gerakan.service.ts).
func (m MutationContext) aktorAudit() audit.Actor {
	a := audit.Actor{
		ActorName: "system",
		IPAddress: m.IPAddress,
		UserAgent: m.UserAgent,
	}
	if m.Actor != nil {
		a.ActorName = m.Actor.Username
		id := m.Actor.ID
		a.IDCoreUsers = &id
	}
	return a
}

// idKetat — padanan actorId (ketat): id user aktor utk kolom pelaksana/
// penyusun header — id > 0, selain itu NULL (sistem).
func (m MutationContext) idKetat() *int64 {
	if m.Actor != nil && m.Actor.ID > 0 {
		id := m.Actor.ID
		return &id
	}
	return nil
}

// GerakanService — kernel fitur gerakan stok.
type GerakanService struct {
	db        *database.DB
	audit     *audit.Service
	outbox    *outbox.Service
	numbering *numbering.Service
	cfg       *moduleconfig.Service
	repo      *repository.GerakanRepository
}

// NewGerakanService membuat service gerakan.
func NewGerakanService(
	db *database.DB,
	auditSvc *audit.Service,
	ob *outbox.Service,
	num *numbering.Service,
	cfg *moduleconfig.Service,
) *GerakanService {
	return &GerakanService{
		db:        db,
		audit:     auditSvc,
		outbox:    ob,
		numbering: num,
		cfg:       cfg,
		repo:      repository.NewGerakanRepository(),
	}
}

/* ------------------------------------------------------------------ */
/* Masukan handler (hasil validasi zod-ekuivalen di handler)            */
/* ------------------------------------------------------------------ */

// BuatGerakanInput — padanan GerakanCreate (gerakanCreateSchema); jenis &
// status string enum (konversi domain di service).
type BuatGerakanInput struct {
	Jenis          string
	IDInvProduk    int64
	IDInvLotSerial *int64
	IDInvUnitUkur  int64
	QtyDiminta     int64
	IDLokasiSumber int64
	IDLokasiTujuan int64
	TanggalJadwal  *string
	JenisSumber    string
	EntityIDSumber *string
	Status         string
}

// KonfirmasiInput — padanan GerakanKonfirmasi (gerakanKonfirmasiSchema).
type KonfirmasiInput struct {
	QtySelesai     int64
	IDInvLotSerial *int64
	NilaiPersatuan *float64
}

/* ------------------------------------------------------------------ */
/* Baca                                                                */
/* ------------------------------------------------------------------ */

// List — daftar gerakan (filter jenis/status/produk/gudang + search nomor).
func (s *GerakanService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.GerakanStokView], error) {
	return s.repo.List(ctx, s.db.Pool, pr)
}

// Get — detail gerakan; 404 INV-018 (pesan memakai id RAW — verbatim).
func (s *GerakanService) Get(ctx context.Context, idRaw string) (repository.GerakanStokView, error) {
	id, _, err := parseIdGerakan(idRaw)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	view, err := s.repo.MuatViewSatu(ctx, s.db.Pool, id)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	if view == nil {
		return repository.GerakanStokView{}, errkontrak.NotFound(
			fmt.Sprintf("Gerakan id %s tidak ditemukan.", idRaw),
			invErrTidakDitemukan,
		)
	}
	return *view, nil
}

/* ------------------------------------------------------------------ */
/* Buat                                                                */
/* ------------------------------------------------------------------ */

// Create — buat gerakan manual/kontrak: nomor via penomoran; pasangan lokasi
// divalidasi PASANGAN_LOKASI_SAH; arah keluar dengan saldo kurang →
// MENUNGGU_STOK. PATCH 09: satu panggilan = HEADER baru + SATU detail.
func (s *GerakanService) Create(ctx context.Context, in BuatGerakanInput, mctx MutationContext) (repository.GerakanStokView, error) {
	var view repository.GerakanStokView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		// Produk harus ada & menjejak stok (jasa tidak punya gerakan).
		produk, err := s.repo.MuatProduk(ctx, tx, in.IDInvProduk)
		if err != nil {
			return err
		}
		if produk == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Produk id %d tidak ditemukan.", in.IDInvProduk),
				invErrTidakDitemukan,
			)
		}
		if !produk.JejakStok {
			return errkontrak.BadRequest(
				"Produk tidak menjejak stok (jasa) — tidak boleh punya gerakan (INV-003).",
				invErrGerakanTidakSah,
			)
		}

		// Lokasi sumber & tujuan harus ada dan pasangannya sah (INV-BR03).
		lokasi, err := s.repo.MuatLokasiStok(ctx, tx, []int64{in.IDLokasiSumber, in.IDLokasiTujuan})
		if err != nil {
			return err
		}
		var jenisSumber, jenisTujuan domain.JenisLokasi
		adaSumber, adaTujuan := false, false
		for _, l := range lokasi {
			switch l.ID {
			case in.IDLokasiSumber:
				jenisSumber, adaSumber = domain.JenisLokasi(l.Jenis), true
			case in.IDLokasiTujuan:
				jenisTujuan, adaTujuan = domain.JenisLokasi(l.Jenis), true
			}
		}
		if !adaSumber || !adaTujuan {
			return errkontrak.BadRequest(
				"Lokasi sumber/tujuan tidak ditemukan (INV-003).",
				invErrGerakanTidakSah,
			)
		}
		jenis := domain.JenisGerakan(in.Jenis)
		if !domain.PasanganLokasiSah(jenis, jenisSumber, jenisTujuan) {
			return errkontrak.BadRequest(
				fmt.Sprintf("Pasangan lokasi %s → %s tidak sah untuk jenis %s (INV-003).",
					jenisSumber, jenisTujuan, jenis),
				invErrGerakanTidakSah,
			)
		}

		// Status efektif: DRAFT mengikuti pembuat; selain itu cek ATP keluar.
		status := in.Status
		if status != string(domain.StatusDraft) && !domain.JenisGerakanMasuk(jenis) {
			cukup, err := s.repo.SaldoCukup(ctx, tx, in.IDLokasiSumber, in.IDInvProduk, in.IDInvLotSerial, in.QtyDiminta)
			if err != nil {
				return err
			}
			if cukup {
				status = string(domain.StatusTerjadwal)
			} else {
				status = string(domain.StatusMenungguStok)
			}
		}

		// Nomor dokumen — anti-race (STD-08) per jenis.
		nomor, err := s.numbering.Next(ctx, tx, "inventory", in.Jenis, numbering.Options{
			Prefix:  domain.PrefixJenis(jenis),
			Padding: 4,
		})
		if err != nil {
			return err
		}

		tanggalJadwal, err := gkWaktuAtauSekarang(in.TanggalJadwal)
		if err != nil {
			return err
		}
		header, err := s.repo.InsertHeaderCreate(ctx, tx, repository.HeaderGerakanBaru{
			EntityID:      numbering.NewEntityID(),
			Nomor:         nomor,
			Jenis:         in.Jenis,
			Status:        status,
			TanggalJadwal: tanggalJadwal,
			JenisSumber:   in.JenisSumber,
			IDKetat:       mctx.idKetat(),
			Sumber:        in.IDLokasiSumber,
			Tujuan:        in.IDLokasiTujuan,
		})
		if err != nil {
			return err
		}

		row, err := s.repo.InsertDetail(ctx, tx, repository.DetailGerakanBaru{
			EntityID:       numbering.NewEntityID(),
			IDHeader:       header.ID,
			IDProduk:       produk.ID,
			IDLot:          in.IDInvLotSerial,
			IDUnit:         in.IDInvUnitUkur,
			QtyDiminta:     int32(in.QtyDiminta),
			QtySelesai:     0,
			EntityIDSumber: in.EntityIDSumber, // D-50: per baris (D-48: lokasi di header)
		})
		if err != nil {
			return err
		}

		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_gerakan_stok",
				EntityID:   strconv.FormatInt(row.ID, 10),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"nomor":  header.NomorDokumen,
					"jenis":  header.Jenis,
					"status": header.Status,
					"qty":    int(row.QtyDiminta),
				},
			},
			Actor: mctx.aktorAudit(),
		}}); err != nil {
			return err
		}

		return s.muatViewTx(ctx, tx, row.ID, &view)
	})
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	return view, nil
}

/* ------------------------------------------------------------------ */
/* Konfirmasi — JANTUNG (14 langkah, satu tx)                          */
/* ------------------------------------------------------------------ */

// Konfirmasi — eksekusi gerakan: parsial → SEBAGIAN; tuntas → SELESAI +
// tanggal_selesai (baris & dokumen) + nilai snapshot; saldo recompute +
// event outbox satu UoW; STATUS DOKUMEN di-derive dari progres baris.
func (s *GerakanService) Konfirmasi(ctx context.Context, idRaw string, in KonfirmasiInput, mctx MutationContext) (repository.GerakanStokView, error) {
	id, tampil, err := parseIdGerakan(idRaw)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	var view repository.GerakanStokView
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		// (1) muatRowLengkap — 404 INV-018 (pesan id NUMERIK — verbatim).
		bar, err := s.repo.MuatBaris(ctx, tx, id)
		if err != nil {
			return err
		}
		if bar == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Gerakan id %s tidak ditemukan.", tampil),
				invErrTidakDitemukan,
			)
		}
		headerJenis := domain.JenisGerakan(bar.Header.Jenis)
		headerStatus := domain.StatusGerakan(bar.Header.Status)
		headerNomor := bar.Header.NomorDokumen

		// (2) guard status STATUS_TERBUKA → 409 INV-012.
		if !domain.StatusTerbuka(headerStatus) {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s sudah final (%s) — tidak bisa dikonfirmasi (INV-012).", headerNomor, headerStatus),
				invErrGerakanFinal,
			)
		}

		// (3) guard langkah (D-25): konfirmasi stok hanya pada langkah terakhir.
		if bar.Header.TotalLangkah > bar.Header.Langkah {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s masih di langkah %d/%d — majukan tahap picking sebelum konfirmasi (INV-019).",
					headerNomor, bar.Header.Langkah, bar.Header.TotalLangkah),
				invErrLangkahBelumSelesai,
			)
		}

		// (4) Produk + kategori (metode valuasi & pelacakan) — default STANDAR.
		produkRow, err := s.repo.MuatProdukValuasi(ctx, tx, bar.IDInvProduk)
		if err != nil {
			return err
		}
		metode := "STANDAR"
		var pelacakan string
		var hargaBiayaLama *float64
		if produkRow != nil {
			hargaBiayaLama = produkRow.HargaBiaya
			kategoriRow, err := s.repo.MuatKategoriValuasi(ctx, tx, produkRow.KategoriID)
			if err != nil {
				return err
			}
			if kategoriRow != nil {
				metode = kategoriRow.MetodeValuasi
				pelacakan = kategoriRow.Pelacakan
			}
		}
		// Patch 59 — nilai bawaan dari posting mutasi GR-PO (harga PO net per
		// satuan dasar); NULL untuk gerakan manual. Hanya STANDAR & AVCO
		// biayaMasuk yang menjatuhkan ke nilai ini (alur FIFO tidak disentuh).
		nilaiBawaanPosting := bar.NilaiPersatuan

		// (5) Lokasi efektif baris (D-48): override baris ?? header.
		lokasiSumber := bar.IDLokasiSumber
		if lokasiSumber == 0 && bar.Header.IDLokasiSumber != nil {
			lokasiSumber = *bar.Header.IDLokasiSumber
		}
		lokasiTujuan := bar.IDLokasiTujuan
		if lokasiTujuan == 0 && bar.Header.IDLokasiTujuan != nil {
			lokasiTujuan = *bar.Header.IDLokasiTujuan
		}

		// (6) Lot: pakai payload atau yang sudah menempel; wajib utk kategori
		// LOT/SERIAL. FEFO paksa (D-31) utk keluar tanpa lot.
		arahKeluar := !domain.JenisGerakanMasuk(headerJenis)
		lotID := in.IDInvLotSerial
		if lotID == nil {
			lotID = bar.IDInvLotSerial
		}
		wajibLot := pelacakan == "LOT" || pelacakan == "SERIAL"
		if wajibLot && lotID == nil && arahKeluar {
			// FEFO paksa (D-31): lot tertua bersaldo dipilih otomatis.
			lotID, err = s.pilihLotFefo(ctx, tx, lokasiSumber, bar.IDInvProduk)
			if err != nil {
				return err
			}
		}
		if wajibLot && lotID == nil {
			return errkontrak.Conflict(
				"Kategori produk wajib pelacakan lot/serial — pilih lot sebelum konfirmasi (INV-007).",
				"INV-007",
			)
		}
		var lotKode string
		if lotID != nil {
			lot, err := s.repo.MuatLot(ctx, tx, *lotID)
			if err != nil {
				return err
			}
			if lot == nil {
				return errkontrak.NotFound(
					fmt.Sprintf("Lot id %d tidak ditemukan.", *lotID),
					invErrTidakDitemukan,
				)
			}
			lotKode = lot.Kode
			// Mode CFG-INV-02 BLOKIR → lot kedaluwarsa tidak boleh keluar (INV-008).
			modeKedaluwarsa, err := s.cfg.GetString(ctx, tx, "inventory", "CFG-INV-02", "NONAKTIF")
			if err != nil {
				return err
			}
			if arahKeluar && modeKedaluwarsa == "BLOKIR" && lot.Status == "KEDALUWARSA" {
				return errkontrak.Conflict(
					fmt.Sprintf("Lot %s kedaluwarsa — diblokir keluar pada mode blokir (INV-008).", lotKode),
					"INV-008",
				)
			}
			// Serial unik: satu unit serial tak boleh keluar dua kali (INV-009).
			if arahKeluar && pelacakan == "SERIAL" {
				dipakai, err := s.repo.CariSerialTerpakai(ctx, tx, *lotID, bar.ID)
				if err != nil {
					return err
				}
				if dipakai != nil {
					return errkontrak.Conflict(
						"Serial sudah pernah dipakai pada gerakan keluar lain (INV-009).",
						"INV-009",
					)
				}
			}
		}

		// (7) Cek saldo sumber utk arah keluar/pindah (INV-010) — hanya pada
		// jalur konfirmasi ke SELESAI (qty benar-benar keluar).
		if arahKeluar {
			cukup, err := s.repo.SaldoCukup(ctx, tx, lokasiSumber, bar.IDInvProduk, lotID, in.QtySelesai)
			if err != nil {
				return err
			}
			if !cukup {
				return errkontrak.Conflict(
					"Saldo sumber tidak cukup untuk qty konfirmasi (INV-010).",
					invErrSaldoTidakCukup,
				)
			}
		}

		// (8) Status efektif dari progres qty (§4.2).
		tuntas := in.QtySelesai >= int64(bar.QtyDiminta)
		sekarang := time.Now()

		// (9) Valuasi bermetode (D-27/D-28) — hanya saat tuntas (snapshot
		// final). Arah masuk valuasi = PENERIMAAN atau PENYESUAIAN-plus
		// (tujuan INTERNAL).
		var nilaiSatuan *string
		var fallbackAudit []audit.Snapshot
		if tuntas {
			masuk := headerJenis == domain.JenisPenerimaan
			if headerJenis == domain.JenisPenyesuaian {
				jenisLok, err := s.repo.MuatJenisLokasi(ctx, tx, []int64{lokasiSumber, lokasiTujuan})
				if err != nil {
					return err
				}
				for _, l := range jenisLok {
					if l.ID == lokasiTujuan {
						masuk = domain.JenisLokasi(l.Jenis) == domain.LokasiInternal
					}
				}
			}

			switch metode {
			case "STANDAR":
				// STANDAR — perilaku lama: payload menang, default harga_biaya.
				// Patch 59: fallback tengah = nilai bawaan posting GR-PO.
				nilaiSatuan = gkPertamaToFixed4(in.NilaiPersatuan, nilaiBawaanPosting, hargaBiayaLama)
			case "AVCO":
				if masuk {
					// Inbound: biaya masuk (payload ?? bawaan GR-PO ?? harga_biaya)
					// menggeser rata-rata bergerak dari saldo on-hand tujuan;
					// hasil DITULIS BALIK ke harga_biaya produk (D-28).
					var biayaMasuk float64
					switch {
					case in.NilaiPersatuan != nil:
						biayaMasuk = *in.NilaiPersatuan
					case nilaiBawaanPosting != nil:
						biayaMasuk = *nilaiBawaanPosting
					case hargaBiayaLama != nil:
						biayaMasuk = *hargaBiayaLama
					}
					saldoTujuan, err := s.repo.SaldoOnHandInternal(ctx, tx, lokasiTujuan, bar.IDInvProduk)
					if err != nil {
						return err
					}
					avgLama := biayaMasuk
					if hargaBiayaLama != nil {
						avgLama = *hargaBiayaLama
					}
					avgBaru := domain.HitungRataRataBergerak(float64(saldoTujuan), avgLama, float64(in.QtySelesai), biayaMasuk)
					if err := s.repo.UpdateProdukHargaBiaya(ctx, tx, bar.IDInvProduk, gkToFixed4(avgBaru), sekarang); err != nil {
						return err
					}
					v := gkToFixed4(biayaMasuk)
					nilaiSatuan = &v
				} else {
					// Outbound: nilai persatuan = harga_biaya terkini.
					nilaiSatuan = gkPertamaToFixed4(in.NilaiPersatuan, hargaBiayaLama)
				}
			default:
				// FIFO (D-27).
				if masuk {
					var biayaMasuk float64
					switch {
					case in.NilaiPersatuan != nil:
						biayaMasuk = *in.NilaiPersatuan
					case hargaBiayaLama != nil:
						biayaMasuk = *hargaBiayaLama
					}
					if err := s.repo.InsertLapisanBiaya(ctx, tx, repository.LapisanBiayaBaru{
						EntityID:          numbering.NewEntityID(),
						IDProduk:          bar.IDInvProduk,
						IDLot:             lotID,
						NomorDokumenMasuk: headerNomor,
						TanggalMasuk:      sekarang,
						QtyMasuk:          int32(in.QtySelesai),
						BiayaPersatuan:    gkToFixed4(biayaMasuk),
					}); err != nil {
						return err
					}
					v := gkToFixed4(biayaMasuk)
					nilaiSatuan = &v
				} else {
					// Konsumsi lapisan tertua dulu — baris dikunci FOR UPDATE
					// agar konsumsi paralel tidak dobel.
					lapisanRows, err := s.repo.ListLapisanFifoKunci(ctx, tx, bar.IDInvProduk, lotID)
					if err != nil {
						return err
					}
					conv := make([]domain.LapisanFifo, 0, len(lapisanRows))
					for _, l := range lapisanRows {
						conv = append(conv, domain.LapisanFifo{
							ID:    l.ID,
							Sisa:  float64(l.QtyMasuk - l.QtyTerpakai),
							Biaya: l.BiayaPersatuan,
						})
					}
					hasil := domain.KonsumsiLapisanFifo(conv, float64(in.QtySelesai))
					for _, p := range hasil.Pemakaian {
						if err := s.repo.TambahQtyTerpakaiLapisan(ctx, tx, p.ID, int32(math.Round(p.Qty)), sekarang); err != nil {
							return err
						}
					}
					// Lapisan kurang (data lama pra-patch) → fallback harga_biaya,
					// TIDAK menggagalkan konfirmasi — dicatat audit.
					fb := 0.0
					if hargaBiayaLama != nil {
						fb = *hargaBiayaLama
					}
					if hasil.FallbackQty > 0 {
						fallbackAudit = append(fallbackAudit, audit.Snapshot{
							"nomor":        headerNomor,
							"fallback_qty": hasil.FallbackQty,
							"harga_biaya":  fb,
						})
					}
					v := gkToFixed4(domain.NilaiPersatuanFifo(hasil, float64(in.QtySelesai), fb))
					nilaiSatuan = &v
				}
			}
		}

		// (10) updateDetail (version + 1; tanggal_selesai NULL bila !tuntas).
		var tglSelesai *time.Time
		if tuntas {
			tglSelesai = &sekarang
		}
		updated, err := s.repo.UpdateDetailKonfirmasi(ctx, tx, repository.DetailKonfirmasiUbah{
			ID:             id,
			QtySelesai:     int32(in.QtySelesai),
			IDLot:          lotID,
			NilaiSatuan:    nilaiSatuan,
			TanggalSelesai: tglSelesai,
			Version:        bar.Version + 1,
			UpdatedAt:      sekarang,
		})
		if err != nil {
			return err
		}
		if updated == nil {
			return errkontrak.Internal("")
		}

		// (11) STATUS DOKUMEN di-derive dari progres seluruh baris (D-49).
		if err := s.segarkanStatusHeader(ctx, tx, bar, headerStatus); err != nil {
			return err
		}

		// (12)-(13) SATU UoW: recompute saldo + audit + outbox events + reorder.
		if tuntas {
			if _, err := repository.RecomputeSaldoStok(ctx, tx); err != nil {
				return s.petaRecompute(err)
			}
			if err := s.emitEventsGerakanSelesai(ctx, tx, updated, bar, headerNomor, headerJenis); err != nil {
				return err
			}
			if err := s.cekReorder(ctx, tx, bar.IDInvProduk); err != nil {
				return err
			}
		}

		// (14a) Backorder otomatis (CFG-INV-05) — keluar/pindah parsial saat
		// mode BACKORDER_OTOMATIS → DOKUMEN sisa satu UoW.
		if !tuntas && domain.JenisKeluarPindah(headerJenis) {
			sisaQty := int64(bar.QtyDiminta) - in.QtySelesai
			modeBackorder, err := s.cfg.GetString(ctx, tx, "inventory", "CFG-INV-05", "TANYA_OPERATOR")
			if err != nil {
				return err
			}
			if sisaQty > 0 && modeBackorder == "BACKORDER_OTOMATIS" {
				if err := s.buatBackorder(ctx, tx, bar, headerNomor, headerJenis, sisaQty, sekarang, mctx); err != nil {
					return err
				}
			}
		}

		// (14b) Audit konfirmasi.
		statusBaru := "SEBAGIAN"
		if tuntas {
			statusBaru = "SELESAI"
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_gerakan_stok",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "konfirmasi",
				BeforeValue: audit.Snapshot{"status": headerStatus, "qty_selesai": int(bar.QtySelesai)},
				AfterValue: audit.Snapshot{
					"status":          statusBaru,
					"qty_selesai":     in.QtySelesai,
					"metode_valuasi":  metode,
					"nilai_persatuan": nilaiSatuan,
				},
			},
			Actor: mctx.aktorAudit(),
		}}); err != nil {
			return err
		}
		// Audit terpisah untuk fallback FIFO (lapisan kurang — data lama).
		for _, detail := range fallbackAudit {
			if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
				EntryInput: audit.EntryInput{
					ModuleKey:  "inventory",
					EntityType: "inv_gerakan_stok",
					EntityID:   strconv.FormatInt(id, 10),
					Action:     "valuasi_fifo_fallback",
					AfterValue: detail,
					Severity:   audit.SeverityWarning,
				},
				Actor: mctx.aktorAudit(),
			}}); err != nil {
				return err
			}
		}

		return s.muatViewTx(ctx, tx, id, &view)
	})
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	return view, nil
}

/* ------------------------------------------------------------------ */
/* Batal dokumen & reservasi (D-29)                                    */
/* ------------------------------------------------------------------ */

// Batal DOKUMEN — alasan wajib (STD-06); hanya status terbuka; recompute saldo.
func (s *GerakanService) Batal(ctx context.Context, idRaw string, alasan string, mctx MutationContext) (repository.GerakanStokView, error) {
	id, tampil, err := parseIdGerakan(idRaw)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	var view repository.GerakanStokView
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		bar, err := s.repo.MuatBaris(ctx, tx, id)
		if err != nil {
			return err
		}
		if bar == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Gerakan id %s tidak ditemukan.", tampil),
				invErrTidakDitemukan,
			)
		}
		headerStatus := domain.StatusGerakan(bar.Header.Status)
		if !domain.StatusTerbuka(headerStatus) {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s sudah final (%s) — tidak bisa dibatalkan (INV-012).", bar.Header.NomorDokumen, headerStatus),
				invErrGerakanFinal,
			)
		}
		if err := s.repo.UpdateHeaderHidup(ctx, tx, repository.HeaderHidupUbah{
			ID:        bar.Header.ID,
			Status:    "BATAL",
			Alasan:    &alasan,
			Version:   bar.Header.Version + 1,
			UpdatedAt: time.Now(),
		}); err != nil {
			return err
		}
		// Reservasi TERJADWAL/SEBAGIAN hilang → saldo (dipesan) ikut berubah.
		if _, err := repository.RecomputeSaldoStok(ctx, tx); err != nil {
			return s.petaRecompute(err)
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_gerakan_stok",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "batal",
				BeforeValue: audit.Snapshot{"status": headerStatus},
				AfterValue:  audit.Snapshot{"status": "BATAL", "alasan": alasan},
				Severity:    audit.SeverityWarning,
			},
			Actor: mctx.aktorAudit(),
		}}); err != nil {
			return err
		}
		return s.muatViewTx(ctx, tx, id, &view)
	})
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	return view, nil
}

// Reservasi — stok utk picking: syarat dokumen terbuka jenis keluar/pindah,
// status MENUNGGU_STOK/TERJADWAL. Saldo efektif cukup → TERRESERVASI +
// TERJADWAL; kurang → 409 INV-010. Satu dokumen = satu reservasi penuh
// (D-29). PATCH 09: reservasi hidup di HEADER.
func (s *GerakanService) Reservasi(ctx context.Context, idRaw string, mctx MutationContext) (repository.GerakanStokView, error) {
	id, tampil, err := parseIdGerakan(idRaw)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	var view repository.GerakanStokView
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		bar, err := s.repo.MuatBaris(ctx, tx, id)
		if err != nil {
			return err
		}
		if bar == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Gerakan id %s tidak ditemukan.", tampil),
				invErrTidakDitemukan,
			)
		}
		headerStatus := domain.StatusGerakan(bar.Header.Status)
		headerJenis := domain.JenisGerakan(bar.Header.Jenis)
		if !domain.StatusTerbuka(headerStatus) {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s sudah final (%s) — tidak bisa direservasi (INV-012).", bar.Header.NomorDokumen, headerStatus),
				invErrGerakanFinal,
			)
		}
		if !domain.JenisKeluarPindah(headerJenis) {
			return errkontrak.BadRequest(
				fmt.Sprintf("Jenis %s bukan gerakan keluar/pindah — reservasi hanya untuk keluar/pindah (INV-003).", headerJenis),
				invErrGerakanTidakSah,
			)
		}
		if headerStatus != domain.StatusMenungguStok && headerStatus != domain.StatusTerjadwal {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s status %s — reservasi hanya untuk MENUNGGU_STOK/TERJADWAL (INV-003).", bar.Header.NomorDokumen, headerStatus),
				invErrGerakanTidakSah,
			)
		}
		lokasiSumber := bar.IDLokasiSumber
		if lokasiSumber == 0 && bar.Header.IDLokasiSumber != nil {
			lokasiSumber = *bar.Header.IDLokasiSumber
		}
		butuh := int64(bar.QtyDiminta) - int64(bar.QtySelesai)
		efektif, err := s.repo.SaldoEfektifReservasi(ctx, tx, lokasiSumber, bar.IDInvProduk, bar.IDInvLotSerial, bar.Header.ID)
		if err != nil {
			return err
		}
		if efektif < butuh {
			return errkontrak.Conflict(
				fmt.Sprintf("Saldo efektif %d < qty diminta %d — tidak bisa direservasi (INV-010).", efektif, butuh),
				invErrSaldoTidakCukup,
			)
		}
		reserv := "TERRESERVASI"
		if err := s.repo.UpdateHeaderHidup(ctx, tx, repository.HeaderHidupUbah{
			ID:        bar.Header.ID,
			Status:    "TERJADWAL",
			Reservasi: &reserv,
			Version:   bar.Header.Version + 1,
			UpdatedAt: time.Now(),
		}); err != nil {
			return err
		}
		// Dipesan berubah (MENUNGGU_STOK → TERJADWAL + TERRESERVASI) — recompute.
		if _, err := repository.RecomputeSaldoStok(ctx, tx); err != nil {
			return s.petaRecompute(err)
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_gerakan_stok",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "reservasi",
				BeforeValue: audit.Snapshot{"status": headerStatus, "reservasi": bar.Header.Reservasi},
				AfterValue:  audit.Snapshot{"status": "TERJADWAL", "reservasi": "TERRESERVASI", "qty": butuh},
			},
			Actor: mctx.aktorAudit(),
		}}); err != nil {
			return err
		}
		return s.muatViewTx(ctx, tx, id, &view)
	})
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	return view, nil
}

// BatalReservasi — reservasi kembali TIDAK, status TETAP; saldo efektif
// terbebas → recompute + audit.
func (s *GerakanService) BatalReservasi(ctx context.Context, idRaw string, mctx MutationContext) (repository.GerakanStokView, error) {
	id, tampil, err := parseIdGerakan(idRaw)
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	var view repository.GerakanStokView
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		bar, err := s.repo.MuatBaris(ctx, tx, id)
		if err != nil {
			return err
		}
		if bar == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("Gerakan id %s tidak ditemukan.", tampil),
				invErrTidakDitemukan,
			)
		}
		if bar.Header.Reservasi != "TERRESERVASI" {
			return errkontrak.Conflict(
				fmt.Sprintf("Gerakan %s tidak sedang TERRESERVASI — tidak ada reservasi untuk dibatalkan (INV-003).", bar.Header.NomorDokumen),
				invErrGerakanTidakSah,
			)
		}
		tidak := "TIDAK"
		if err := s.repo.UpdateHeaderHidup(ctx, tx, repository.HeaderHidupUbah{
			ID:        bar.Header.ID,
			Status:    bar.Header.Status,
			Reservasi: &tidak,
			Version:   bar.Header.Version + 1,
			UpdatedAt: time.Now(),
		}); err != nil {
			return err
		}
		if _, err := repository.RecomputeSaldoStok(ctx, tx); err != nil {
			return s.petaRecompute(err)
		}
		if _, err := s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_gerakan_stok",
				EntityID:    strconv.FormatInt(id, 10),
				Action:      "batal_reservasi",
				BeforeValue: audit.Snapshot{"status": bar.Header.Status, "reservasi": "TERRESERVASI"},
				AfterValue:  audit.Snapshot{"status": bar.Header.Status, "reservasi": "TIDAK"},
			},
			Actor: mctx.aktorAudit(),
		}}); err != nil {
			return err
		}
		return s.muatViewTx(ctx, tx, id, &view)
	})
	if err != nil {
		return repository.GerakanStokView{}, err
	}
	return view, nil
}

/* ------------------------------------------------------------------ */
/* Internal — derive status, FEFO, events, reorder, backorder          */
/* ------------------------------------------------------------------ */

// muatViewTx — baca view di dalam tx (nil = anomali → 500).
func (s *GerakanService) muatViewTx(ctx context.Context, tx repository.DBTX, id int64, out *repository.GerakanStokView) error {
	v, err := s.repo.MuatViewSatu(ctx, tx, id)
	if err != nil {
		return err
	}
	if v == nil {
		return errkontrak.Internal("")
	}
	*out = *v
	return nil
}

// segarkanStatusHeader — D-49: semua SELESAI → SELESAI (+tanggal_selesai
// dokumen); ada progres → SEBAGIAN; tanpa progres → status dipertahankan.
// BATAL tidak disentuh.
func (s *GerakanService) segarkanStatusHeader(ctx context.Context, tx repository.DBTX, bar *repository.BarisGerakan, headerStatus domain.StatusGerakan) error {
	if headerStatus == domain.StatusBatal {
		return nil
	}
	agg, err := s.repo.MuatAggProgresHeader(ctx, tx, bar.Header.ID)
	if err != nil {
		return err
	}
	total, selesai, adaProgres := 0, 0, 0
	if agg != nil {
		total, selesai, adaProgres = int(agg.Total), int(agg.Selesai), int(agg.AdaProgres)
	}
	sekarang := time.Now()
	if total > 0 && selesai == total {
		return s.repo.UpdateHeaderStatus(ctx, tx, repository.HeaderStatusUbah{
			ID:             bar.Header.ID,
			Status:         "SELESAI",
			TanggalSelesai: &sekarang,
			UpdatedAt:      sekarang,
		})
	}
	if selesai > 0 || adaProgres > 0 {
		if headerStatus != domain.StatusSebagian {
			return s.repo.UpdateHeaderStatus(ctx, tx, repository.HeaderStatusUbah{
				ID:        bar.Header.ID,
				Status:    "SEBAGIAN",
				UpdatedAt: sekarang,
			})
		}
	}
	return nil
}

// pilihLotFefo — FEFO paksa (D-31): kandidat repo (join READMODEL saldo per
// lot, ORDER tanggal_kedaluwarsa NULLS LAST). Mode CFG-INV-02 BLOKIR: lot
// KEDALUWARSA dilewati bila ada kandidat lain; bila semua kedaluwarsa, lot
// tertua tetap dikembalikan agar error yang muncul INV-008 (diblokir) —
// bukan INV-007 (lot wajib).
func (s *GerakanService) pilihLotFefo(ctx context.Context, tx repository.DBTX, idLokasiSumber, idProduk int64) (*int64, error) {
	modeKedaluwarsa, err := s.cfg.GetString(ctx, tx, "inventory", "CFG-INV-02", "NONAKTIF")
	if err != nil {
		return nil, err
	}
	kandidat, err := s.repo.CariKandidatLotFefo(ctx, tx, idLokasiSumber, idProduk)
	if err != nil {
		return nil, err
	}
	if len(kandidat) == 0 {
		return nil, nil
	}
	if modeKedaluwarsa == "BLOKIR" {
		for _, k := range kandidat {
			if k.Status != "KEDALUWARSA" {
				id := k.ID
				return &id, nil
			}
		}
	}
	id := kandidat[0].ID
	return &id, nil
}

// petaRecompute — KEPUTUSAN RATIFIKASI modul inv: pelanggaran
// ck_inv_saldo_on_hand (sentinel ErrSaldoOnHandNegatif) dari GERAKAN →
// 409 INV-010 (bukan 500); alur PENYESUAIAN memetakan pesannya sendiri.
func (s *GerakanService) petaRecompute(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, repository.ErrSaldoOnHandNegatif) {
		return errkontrak.Conflict(
			"Saldo sumber tidak cukup untuk qty konfirmasi (INV-010).",
			invErrSaldoTidakCukup,
		)
	}
	return err
}

// emitEventsGerakanSelesai — event outbox gerakan SELESAI: M16 (selalu),
// M02 PENGIRIMAN → SLS, M04 PENERIMAAN → PUR. Idempoten per move_id
// (kunci payload `_key`).
func (s *GerakanService) emitEventsGerakanSelesai(
	ctx context.Context,
	tx repository.DBTX,
	row *repository.DetailGerakanRow,
	bar *repository.BarisGerakan,
	headerNomor string,
	headerJenis domain.JenisGerakan,
) error {
	lokasiSumber := row.IDLokasiSumber
	if lokasiSumber == 0 && bar.Header.IDLokasiSumber != nil {
		lokasiSumber = *bar.Header.IDLokasiSumber
	}
	lokasiTujuan := row.IDLokasiTujuan
	if lokasiTujuan == 0 && bar.Header.IDLokasiTujuan != nil {
		lokasiTujuan = *bar.Header.IDLokasiTujuan
	}
	tujuan, err := s.repo.MuatGudangIdLokasi(ctx, tx, lokasiTujuan)
	if err != nil {
		return err
	}
	sumber, err := s.repo.MuatGudangIdLokasi(ctx, tx, lokasiSumber)
	if err != nil {
		return err
	}
	nilai := 0.0
	if row.NilaiPersatuan != nil {
		nilai = *row.NilaiPersatuan
	}
	nilai *= float64(row.QtySelesai)
	gudangID := tujuan
	if gudangID == nil {
		gudangID = sumber
	}
	keyMove := fmt.Sprintf("move:%d", row.ID)
	payloadBase := map[string]any{
		"moveId":       row.ID,
		"nomorDokumen": headerNomor,
		"jenis":        string(headerJenis),
		"qtySelesai":   int(row.QtySelesai),
		"nilai":        nilai,
		"gudang":       gudangID,
	}
	key := keyMove
	if _, err := s.outbox.Enqueue(ctx, tx, outbox.EventInput{
		Topic:   "inventory.move.completed", // M16 → ACC (valuasi)
		Key:     &key,
		Payload: payloadBase,
	}); err != nil {
		return err
	}
	if headerJenis == domain.JenisPengiriman {
		key := fmt.Sprintf("delivery:%d", row.ID)
		payload := gkClonePayload(payloadBase)
		payload["entityIdSumber"] = row.EntityIDSumber
		if _, err := s.outbox.Enqueue(ctx, tx, outbox.EventInput{
			Topic:   "inventory.delivery.completed", // M02 → SLS
			Key:     &key,
			Payload: payload,
		}); err != nil {
			return err
		}
	}
	if headerJenis == domain.JenisPenerimaan {
		key := fmt.Sprintf("receipt:%d", row.ID)
		payload := gkClonePayload(payloadBase)
		payload["entityIdSumber"] = row.EntityIDSumber
		if _, err := s.outbox.Enqueue(ctx, tx, outbox.EventInput{
			Topic:   "inventory.receipt.completed", // M04 → PUR
			Key:     &key,
			Payload: payload,
		}); err != nil {
			return err
		}
	}
	return nil
}

// cekReorder — reorder check (M27, INV-BR13): bila CFG-INV-10 OTOMATIS dan
// saldo efektif < stok_minimum dan reorder_aktif → enqueue
// `inventory.reorder.triggered` idempoten per produk-periode (satu event per
// produk per hari — cek core_outbox_events hari ini).
func (s *GerakanService) cekReorder(ctx context.Context, tx repository.DBTX, idProduk int64) error {
	mode, err := s.cfg.GetString(ctx, tx, "inventory", "CFG-INV-10", "MANUAL_HARIAN")
	if err != nil {
		return err
	}
	if mode != "OTOMATIS" {
		return nil
	}
	produk, err := s.repo.MuatProduk(ctx, tx, idProduk)
	if err != nil {
		return err
	}
	if produk == nil || !produk.ReorderAktif || produk.StokMinimum <= 0 {
		return nil
	}
	saldo, err := s.repo.MuatSaldoAggProduk(ctx, tx, idProduk)
	if err != nil {
		return err
	}
	var onHand, dipesan int64
	if saldo != nil {
		onHand, dipesan = int64(saldo.OnHand), int64(saldo.Dipesan)
	}
	efektif := onHand - dipesan
	if efektif >= int64(produk.StokMinimum) {
		return nil
	}
	// Idempoten per produk-periode: satu event per produk per hari.
	jumlahSudah, err := s.repo.HitungOutboxReorderHariIni(ctx, tx, idProduk)
	if err != nil {
		return err
	}
	if jumlahSudah > 0 {
		return nil
	}
	basis := int64(produk.StokMinimum)
	if produk.StokMaksimum != nil {
		basis = *produk.StokMaksimum
	}
	key := fmt.Sprintf("reorder:%d:%s", idProduk, time.Now().UTC().Format("2006-01-02"))
	if _, err := s.outbox.Enqueue(ctx, tx, outbox.EventInput{
		Topic: "inventory.reorder.triggered", // M27 → PUR
		Key:   &key,
		Payload: map[string]any{
			"produkId":     idProduk,
			"sku":          produk.KodeProduk,
			"saldoEfektif": efektif,
			"stokMinimum":  int64(produk.StokMinimum),
			"stokMaksimum": produk.StokMaksimum,
			"qtySaran":     int64(math.Max(0, float64(basis-efektif))),
		},
	}); err != nil {
		return err
	}
	return nil
}

// buatBackorder — dokumen sisa (CFG-INV-05 BACKORDER_OTOMATIS): nomor baru
// prefix jenis sama, jenis_sumber BACKORDER, status MENUNGGU_STOK, lot null,
// entity_id_sumber = nomor dokumen asal (header & detail) + audit
// backorder_buat — semua satu UoW.
func (s *GerakanService) buatBackorder(
	ctx context.Context,
	tx repository.DBTX,
	bar *repository.BarisGerakan,
	headerNomor string,
	headerJenis domain.JenisGerakan,
	sisaQty int64,
	sekarang time.Time,
	mctx MutationContext,
) error {
	nomorSisa, err := s.numbering.Next(ctx, tx, "inventory", string(headerJenis), numbering.Options{
		Prefix:  domain.PrefixJenis(headerJenis),
		Padding: 4,
	})
	if err != nil {
		return err
	}
	sisaHeader, err := s.repo.InsertHeaderBackorder(ctx, tx, repository.HeaderBackorderBaru{
		EntityID:         numbering.NewEntityID(),
		Nomor:            nomorSisa,
		Jenis:            string(headerJenis),
		Status:           "MENUNGGU_STOK",
		Langkah:          1,
		TotalLangkah:     bar.Header.TotalLangkah,
		TanggalJadwal:    sekarang,
		JenisSumber:      "BACKORDER",
		EntityIDSumber:   headerNomor,
		KodeJenisOperasi: bar.Header.KodeJenisOperasi,
		IDKetat:          mctx.idKetat(),
		Sumber:           bar.Header.IDLokasiSumber,
		Tujuan:           bar.Header.IDLokasiTujuan,
	})
	if err != nil {
		return err
	}
	sisaRow, err := s.repo.InsertDetail(ctx, tx, repository.DetailGerakanBaru{
		EntityID:       numbering.NewEntityID(),
		IDHeader:       sisaHeader.ID,
		IDProduk:       bar.IDInvProduk,
		IDLot:          nil,
		IDUnit:         bar.IDInvUnitUkur,
		QtyDiminta:     int32(sisaQty),
		QtySelesai:     0,
		EntityIDSumber: &headerNomor,
	})
	if err != nil {
		return err
	}
	_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
		EntryInput: audit.EntryInput{
			ModuleKey:  "inventory",
			EntityType: "inv_gerakan_stok",
			EntityID:   strconv.FormatInt(sisaRow.ID, 10),
			Action:     "backorder_buat",
			AfterValue: audit.Snapshot{
				"nomor":    nomorSisa,
				"sumber":   headerNomor,
				"qty_sisa": sisaQty,
				"mode":     "BACKORDER_OTOMATIS",
			},
		},
		Actor: mctx.aktorAudit(),
	}})
	return err
}
