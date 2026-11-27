// mutasi.go — orkestrasi fitur DOKUMEN MUTASI BARANG modul inv (padanan
// services/operasi/mutasi.service.ts NestJS patch 07/D-45 + generate dari
// GR PUR patch 59 — VERBATIM pesan, kode & urutan langkah):
//
//   - create : DRAFT + items (snapshot nama produk);
//   - update : hanya DRAFT — items REPLACE satu UoW (version cek DULU,
//     baru status DRAFT — verbatim sumber);
//   - ajukan : CFG-INV-14 WAJIB_APPROVAL → MENUNGGU_PERSETUJUAN;
//     default TANPA_APPROVAL → langsung DISETUJUI + posting;
//   - posting: header gerakan pola DO (nomor = kode dokumen, status DRAFT,
//     jenis_sumber MUTASI/GR-PO) + baris inv_gerakan_stok per item dengan
//     entity_id_sumber "{entityId header}:{id item}" — idempoten
//     uq_inv_gerakan_idempoten (onConflictDoNothing);
//   - keputusan: SoD penyusun ≠ penyetuju (INV-004); SETUJUI → DISETUJUI +
//     posting; TOLAK → DITOLAK (alasan wajib);
//   - batal  : hanya DRAFT/MENUNGGU_PERSETUJUAN, alasan wajib (INV-005);
//   - dari GR: GR wajib DITERIMA (409 INV-022), belum dimutasi (pre-check +
//     race 23505 uq_inv_mutasi_gr_ref → 409 INV-022), minimal 1 baris
//     non-TOLAK; lokasi sumber VENDOR pertama + tujuan INTERNAL gudang GR
//     (?? gudang PO) — di luar cakupan tulis → 409 INV-021; konversi
//     satuan PUR-BR16 dieksekusi INV (inv_unit_konversi, else 409 INV-016);
//     nilai putus4(net/faktor) — net = harga × (1 − diskon/100), faktor
//     fallback qtyDiminta/qtyGr;
//   - cakupan: DATA-SCOPE dinamis dimensi 'storages' — baca di luar cakupan
//     → 404 (paritas "tidak ada data"); susun → 409 INV-021; DENY_ALL list
//     → halaman kosong (bukan error).
package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/url"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/core/numbering"
	"nexierp/internal/core/pkcipher"
	"nexierp/internal/core/rbac"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// pgtextNil — pgtype.Text kosong (NULL) — dipakai utk set yang tidak
// menyentuh kolom (COALESCE keep di SQL).
var pgtextNil = pgtype.Text{}

// opUuidParam — string uuid → pgtype.UUID (param insert).
func opUuidParam(s string) pgtype.UUID {
	var u pgtype.UUID
	_ = u.Scan(s)
	return u
}

// MutasiService — dependensi kernel + repo mutasi.
type MutasiService struct {
	DB        *database.DB
	Audit     *audit.Service
	Numbering *numbering.Service
	Cfg       *moduleconfig.Service
	Scope     *rbac.Scope
	Cipher    *pkcipher.Cipher
	Repo      *repository.MutasiRepository
}

// NewMutasiService — wiring dari Deps modul (dipanggil handler).
func NewMutasiService(d types.Deps) *MutasiService {
	return &MutasiService{
		DB:        d.DB,
		Audit:     d.Audit,
		Numbering: d.Numbering,
		Cfg:       d.ModCfg,
		Scope:     d.Scope,
		Cipher:    d.Cipher,
		Repo:      repository.NewMutasiRepository(),
	}
}

// MutasiItemInput — baris item dokumen (hasil validasi handler).
type MutasiItemInput struct {
	IDInvProduk    int64
	IDInvLotSerial *int64
	IDInvUnitUkur  int64
	QtyDiminta     int
}

// MutasiCreateInput — body POST /mutasi.
type MutasiCreateInput struct {
	Jenis          string
	IDLokasiSumber int64
	IDLokasiTujuan int64
	TanggalDokumen *string
	Alasan         *string
	Items          []MutasiItemInput
}

// MutasiUpdateInput — body PATCH /mutasi/:id (field absen = nilai lama;
// flag *Ada menandai field dikirim — nullish terpisah).
type MutasiUpdateInput struct {
	Jenis          string // "" = tidak dikirim
	IDLokasiSumber *int64
	IDLokasiTujuan *int64
	TanggalAda     bool
	TanggalDokumen *string
	AlasanAda      bool
	Alasan         *string
	ItemsAda       bool
	Items          []MutasiItemInput
	Version        int64
}

// MutasiKeputusanInput — body keputusan approval.
type MutasiKeputusanInput struct {
	Keputusan string // SETUJUI | TOLAK
	Alasan    *string
}

/* -------------------------------------------------------------- */
/* Baca                                                          */
/* -------------------------------------------------------------- */

// List — halaman dokumen mutasi (ter-scope dimensi 'storages').
func (s *MutasiService) List(ctx context.Context, query url.Values, userID int64) (errkontrak.Page[repository.MutasiDokumenView], error) {
	var page errkontrak.Page[repository.MutasiDokumenView]
	// Cakupan gudang aktor (dimensi 'storages') — evaluasi di pool utama
	// (konfigurasi scope lambat-berubah). DENY_ALL → halaman kosong (bukan
	// error); DAFTAR → predicate endpoint sumber/tujuan.
	scope, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return page, err
	}
	pr, err := errkontrak.ParsePageRequest(query)
	if err != nil {
		return page, err
	}
	// Whitelist sort list dokumen (default -tanggal + kode).
	if err := opSortWhitelist(pr, "kode", "createdAt", "updatedAt", "tanggal"); err != nil {
		return page, err
	}
	if scope != nil && scope.Deny {
		return errkontrak.BuildPage([]repository.MutasiDokumenView{}, 0, pr), nil
	}
	sortCol, sortDesc := opPilihSort(pr, map[string]string{
		"kode": "kode", "createdAt": "createdAt", "updatedAt": "updatedAt", "tanggal": "tanggal",
	}, "")
	data, total, err := s.Repo.ListDokumen(ctx, s.DB.Pool, repository.MutasiListFilter{
		Status:   opFilterVal(pr, "status"),
		Jenis:    opFilterJenisMutasi(pr, "jenis"),
		Search:   opFilterVal(pr, "search"),
		Cakupan:  scope,
		SortCol:  sortCol,
		SortDesc: sortDesc,
		Limit:    int32(pr.Limit),
		Offset:   int32(pr.Offset),
	})
	if err != nil {
		return page, err
	}
	// Jumlah gerakan terposting per dokumen (jenis_sumber MUTASI; patch 59
	// mutasi dari GR menulis "GR-PO").
	kodes := make([]string, 0, len(data))
	for _, v := range data {
		kodes = append(kodes, v.Kode)
	}
	if len(kodes) > 0 {
		posting, err := s.Repo.HitungGerakanDipostingPerKode(ctx, s.DB.Pool, kodes)
		if err != nil {
			return page, err
		}
		for i := range data {
			data[i].JumlahGerakanDiposting = posting[data[i].Kode]
		}
	}
	// Token PK tersamar per baris (URL halaman form — pola pemasok PUR).
	for i := range data {
		if err := s.beriToken(&data[i]); err != nil {
			return page, err
		}
	}
	return errkontrak.BuildPage(data, total, pr), nil
}

// Get — detail dokumen (items lengkap); di luar cakupan → 404.
func (s *MutasiService) Get(ctx context.Context, idRaw string, userID int64) (repository.MutasiDokumenView, error) {
	id, err := opResolusiID(s.Cipher, idRaw)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	scope, err := cakupanStorages(ctx, s.Scope, s.Audit, userID, s.DB.Pool)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	if scope != nil && scope.Deny {
		return repository.MutasiDokumenView{}, domain.ErrDokumenTersembunyi(id)
	}
	header, err := s.Repo.DokumenHidupById(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	if err := s.assertDokumenTerlihat(ctx, s.DB.Pool, header, scope); err != nil {
		return repository.MutasiDokumenView{}, err
	}
	view, err := s.muatSatu(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	if err := s.beriToken(&view); err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Generate dari GR PUR (patch 59 — arah TERIMA jalur aktif)      */
/* -------------------------------------------------------------- */

// GrEligible — daftar GR PUR eligible generate mutasi penerimaan.
func (s *MutasiService) GrEligible(ctx context.Context) ([]repository.GrEligibleView, error) {
	return s.Repo.ListGrEligible(ctx, s.DB.Pool)
}

// MutasiDariGrInput — body POST /mutasi/dari-gr.
type MutasiDariGrInput struct {
	IDPurPenerimaan int64
	IDLokasiTujuan  *int64
}

// DariGr — generate dokumen mutasi PENERIMAAN dari GR PUR — satu UoW
// (urutan guard & pesan verbatim dariGr NestJS).
func (s *MutasiService) DariGr(ctx context.Context, in MutasiDariGrInput, c CtxMutasi) (repository.MutasiDokumenView, error) {
	var view repository.MutasiDokumenView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		gr, err := s.Repo.GrDenganPoById(ctx, tx, in.IDPurPenerimaan)
		if err != nil {
			return err
		}
		if gr == nil {
			return errkontrak.NotFound(
				fmt.Sprintf("GR pur_penerimaan id %d tidak ditemukan.", in.IDPurPenerimaan),
				domain.KodeInvTidakDitemukan,
			)
		}
		if string(gr.Status) != "DITERIMA" {
			return errkontrak.Conflict(
				fmt.Sprintf("GR %s bukan status DITERIMA (%s) — tidak eligible dimutasi (INV-022).", gr.Nomor, string(gr.Status)),
				opKodeInvGrTidakEligibel,
			)
		}
		// (a) Pre-check 1 GR = 1 mutasi hidup — patungan partial unique.
		sudah, err := s.Repo.MutasiHidupByGrId(ctx, tx, gr.ID)
		if err != nil {
			return err
		}
		if sudah != nil {
			return errkontrak.Conflict(
				fmt.Sprintf("GR %s sudah dimutasi (dokumen %s) — 1 GR = 1 mutasi (INV-022).", gr.Nomor, sudah.Kode),
				opKodeInvGrTidakEligibel,
			)
		}
		// (b) Baris GR non-TOLAK.
		grItems, err := s.Repo.PenerimaanItemsHidup(ctx, tx, gr.ID)
		if err != nil {
			return err
		}
		baris := make([]repository.PurPenerimaanItem, 0, len(grItems))
		for _, it := range grItems {
			if string(it.Kondisi) != "TOLAK" {
				baris = append(baris, it)
			}
		}
		if len(baris) == 0 {
			return errkontrak.Conflict(
				fmt.Sprintf("GR %s tidak memiliki baris non-TOLAK — tidak ada barang masuk stok (INV-022).", gr.Nomor),
				opKodeInvGrTidakEligibel,
			)
		}

		// (c) LOKASI — sumber VENDOR pertama (paritas PASANGAN_LOKASI_SAH
		// masuk VENDOR→INTERNAL), tujuan INTERNAL gudang GR ?? gudang PO.
		sumber, err := s.Repo.LokasiVendorPertama(ctx, tx)
		if err != nil {
			return err
		}
		if sumber == nil {
			return errkontrak.BadRequest(
				"Lokasi VENDOR tidak ditemukan — buat/pilih lokasi VENDOR terlebih dahulu (INV-021).",
				domain.KodeInvLokasiTidakDiizinkan,
			)
		}
		idInvGudang := opI8(gr.IDInvGudang)
		if idInvGudang == nil {
			idInvGudang = opI8(gr.IDInvGudangPo)
		}
		var tujuanID int64
		if in.IDLokasiTujuan != nil {
			pilihan, err := s.Repo.LokasiHidupById(ctx, tx, *in.IDLokasiTujuan)
			if err != nil {
				return err
			}
			if pilihan == nil {
				return errkontrak.BadRequest(
					fmt.Sprintf("Lokasi tujuan id %d tidak ditemukan (INV-021).", *in.IDLokasiTujuan),
					domain.KodeInvLokasiTidakDiizinkan,
				)
			}
			tujuanID = *pilihan
		} else {
			var internal *int64
			if idInvGudang != nil {
				internal, err = s.Repo.LokasiInternalPertamaGudang(ctx, tx, *idInvGudang)
				if err != nil {
					return err
				}
			}
			if internal == nil {
				labelGudang := "tidak ditentukan"
				if idInvGudang != nil {
					kodeGudang, err := s.Repo.KodeGudangById(ctx, tx, *idInvGudang)
					if err != nil {
						return err
					}
					if kodeGudang != nil {
						labelGudang = *kodeGudang
					} else {
						labelGudang = fmt.Sprintf("id %d", *idInvGudang)
					}
				}
				return errkontrak.BadRequest(
					fmt.Sprintf("Lokasi INTERNAL gudang %s tidak ditemukan — pilih manual (INV-021).", labelGudang),
					domain.KodeInvLokasiTidakDiizinkan,
				)
			}
			tujuanID = *internal
		}
		// Gerbang cakupan tulis (paritas create manual — INV-021 di luar scope).
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertLokasiDalamCakupan(ctx, tx, scope, *sumber, tujuanID); err != nil {
			return err
		}

		// (d) KONVERSI PUR-BR16 — satuan beli (baris PO) → unit dasar produk.
		poItemIDs := make([]int64, 0, len(baris))
		produkIDs := []int64{}
		for _, item := range baris {
			poItemIDs = append(poItemIDs, item.IDPurPesananItem)
			produkIDs = opUnikI64(produkIDs, item.IDInvProduk)
		}
		poItems, err := s.Repo.PesananItemsByIds(ctx, tx, poItemIDs)
		if err != nil {
			return err
		}
		poItemByID := map[int64]repository.PurPesananItem{}
		for _, p := range poItems {
			poItemByID[p.ID] = p
		}
		produkRows, err := s.Repo.ProdukRingkasHidupByIds(ctx, tx, produkIDs)
		if err != nil {
			return err
		}
		produkByID := map[int64]repository.ProdukRingkasHidupByIdsRow{}
		for _, p := range produkRows {
			produkByID[p.ID] = p
		}
		// Pasangan konversi unik yang dibutuhkan — satu query inv_unit_konversi.
		type pasangan struct{ dari, ke int64 }
		butuhKonversi := map[string]pasangan{}
		var urutan []string
		for _, item := range baris {
			poItem, ada := poItemByID[item.IDPurPesananItem]
			if !ada {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Baris PO id %d (sumber GR %s) tidak ditemukan.", item.IDPurPesananItem, gr.Nomor))
			}
			produk, ada := produkByID[item.IDInvProduk]
			if !ada {
				return errkontrak.BadRequest(fmt.Sprintf(
					"Produk id %d pada GR %s tidak ditemukan / tidak aktif.", item.IDInvProduk, gr.Nomor))
			}
			if poItem.IDInvUnitUkur != produk.IDInvUnitUkur {
				kunci := fmt.Sprintf("%d->%d", poItem.IDInvUnitUkur, produk.IDInvUnitUkur)
				if _, dup := butuhKonversi[kunci]; !dup {
					butuhKonversi[kunci] = pasangan{dari: poItem.IDInvUnitUkur, ke: produk.IDInvUnitUkur}
					urutan = append(urutan, kunci)
				}
			}
		}
		faktorByKunci := map[string]float64{}
		if len(butuhKonversi) > 0 {
			dari := make([]int64, 0, len(urutan))
			ke := make([]int64, 0, len(urutan))
			for _, k := range urutan {
				dari = append(dari, butuhKonversi[k].dari)
				ke = append(ke, butuhKonversi[k].ke)
			}
			konversiRows, err := s.Repo.FaktorKonversiPasangan(ctx, tx, dari, ke)
			if err != nil {
				return err
			}
			for _, k := range konversiRows {
				faktorByKunci[fmt.Sprintf("%d->%d", k.IDUnitDari, k.IDUnitKe)] = opAngka(k.Faktor)
			}
		}
		type barisKonversi struct {
			item     repository.PurPenerimaanItem
			produkID int64
			unitID   int64
			nama     string
			qtyDasar int
		}
		konversi := make([]barisKonversi, 0, len(baris))
		for _, item := range baris {
			poItem := poItemByID[item.IDPurPesananItem]
			produk := produkByID[item.IDInvProduk]
			faktor := 1.0
			if poItem.IDInvUnitUkur != produk.IDInvUnitUkur {
				f, ada := faktorByKunci[fmt.Sprintf("%d->%d", poItem.IDInvUnitUkur, produk.IDInvUnitUkur)]
				if !ada {
					return errkontrak.Conflict(fmt.Sprintf(
						"Konversi satuan beli→dasar tidak terdaftar untuk produk %s (INV-016).", produk.Nama),
						opKodeInvKombinasiTidakLengkap)
				}
				faktor = f
			}
			qtyDasar := int(math.Round(float64(item.QtyDiterima) * faktor))
			if qtyDasar < 1 {
				return errkontrak.Conflict(fmt.Sprintf(
					"Hasil konversi qty %d × %s < 1 untuk produk %s — periksa faktor konversi (INV-016).",
					item.QtyDiterima, opNumJS(faktor), produk.Nama),
					opKodeInvKombinasiTidakLengkap)
			}
			konversi = append(konversi, barisKonversi{
				item: item, produkID: produk.ID, unitID: produk.IDInvUnitUkur,
				nama: produk.Nama, qtyDasar: qtyDasar,
			})
		}

		// (e) HEADER + ITEMS satu UoW — nomor via numbering "MUT" yang sama.
		kode, err := s.Numbering.Next(ctx, tx, "inventory", "MUT", numbering.Options{Prefix: "MUT/{MMyy}", Padding: 4})
		if err != nil {
			return err
		}
		tanggal := opWaktuSekarang()
		if gr.TanggalTerima.Valid {
			tanggal = gr.TanggalTerima.Time
		}
		idPur := gr.ID
		header, err := s.Repo.InsertDokumen(ctx, tx, repository.InsertMutasiDokumenParams{
			EntityID:            opUuidParam(numbering.NewEntityID()),
			Kode:                kode,
			Jenis:               repository.EnumJenisGerakan("PENERIMAAN"),
			Status:              repository.EnumStatusMutasi("DRAFT"),
			IDLokasiSumber:      *sumber,
			IDLokasiTujuan:      tujuanID,
			TanggalDokumen:      opWaktu(tanggal),
			IDCoreUsersPenyusun: opI8N(opActorIDLonggar(c)),
			// Soft-id GR sumber — TANPA FK (pola PP-02/03).
			IDPurPenerimaan: opI8N(&idPur),
		})
		if err != nil {
			// Partial unique uq_inv_mutasi_gr_ref — dua generate paralel GR
			// sama: race 23505 → 409 INV-022 (pesan bisnis, bukan 500).
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "23505" {
				return errkontrak.Conflict(
					fmt.Sprintf("GR %s sudah dimutasi — 1 GR = 1 mutasi (INV-022).", gr.Nomor),
					opKodeInvGrTidakEligibel,
				)
			}
			return err
		}
		items := make([]MutasiItemInput, 0, len(konversi))
		itemGrIDs := make([]*int64, 0, len(konversi))
		for _, b := range konversi {
			produkID := b.produkID
			grItemID := b.item.ID
			items = append(items, MutasiItemInput{
				IDInvProduk:    produkID,
				IDInvLotSerial: nil,
				IDInvUnitUkur:  b.unitID,
				QtyDiminta:     b.qtyDasar,
			})
			itemGrIDs = append(itemGrIDs, &grItemID)
		}
		if err := s.sisipItems(ctx, tx, header.ID, items, itemGrIDs); err != nil {
			return err
		}
		totalQtyDasar := 0
		for _, b := range konversi {
			totalQtyDasar += b.qtyDasar
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_mutasi_dokumen",
				EntityID:   fmt.Sprintf("%d", header.ID),
				Action:     "dari_gr",
				AfterValue: audit.Snapshot{
					"kode":          header.Kode,
					"gr":            gr.Nomor,
					"nomorPo":       gr.NomorPo,
					"items":         len(konversi),
					"totalQtyDasar": totalQtyDasar,
				},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                         */
/* -------------------------------------------------------------- */

// Create — buat dokumen DRAFT (header + items satu UoW).
func (s *MutasiService) Create(ctx context.Context, in MutasiCreateInput, c CtxMutasi) (repository.MutasiDokumenView, error) {
	var view repository.MutasiDokumenView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		// Gerbang cakupan tulis (evaluasi di dalam tx — konsisten dengan
		// insert): minimal satu endpoint di gudang whitelist aktor → 409 INV-021.
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertLokasiDalamCakupan(ctx, tx, scope, in.IDLokasiSumber, in.IDLokasiTujuan); err != nil {
			return err
		}
		kode, err := s.Numbering.Next(ctx, tx, "inventory", "MUT", numbering.Options{Prefix: "MUT/{MMyy}", Padding: 4})
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
		header, err := s.Repo.InsertDokumen(ctx, tx, repository.InsertMutasiDokumenParams{
			EntityID: opUuidParam(numbering.NewEntityID()),
			Kode:     kode,
			Jenis:    repository.EnumJenisGerakan(in.Jenis),
			Status:   repository.EnumStatusMutasi("DRAFT"),
			// PATCH 08 — lokasi milik header (pola DO).
			IDLokasiSumber:      in.IDLokasiSumber,
			IDLokasiTujuan:      in.IDLokasiTujuan,
			TanggalDokumen:      opWaktu(tanggal),
			IDCoreUsersPenyusun: opI8N(opActorIDLonggar(c)),
			Alasan:              opTeks(in.Alasan),
		})
		if err != nil {
			return err
		}
		if err := s.sisipItems(ctx, tx, header.ID, in.Items, nil); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_mutasi_dokumen",
				EntityID:   fmt.Sprintf("%d", header.ID),
				Action:     "create_draft",
				AfterValue: audit.Snapshot{"kode": header.Kode, "jenis": string(header.Jenis), "items": len(in.Items)},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, header.ID)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

// Update — ubah DRAFT — items REPLACE satu UoW.
func (s *MutasiService) Update(ctx context.Context, idRaw string, in MutasiUpdateInput, c CtxMutasi) (repository.MutasiDokumenView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	var view repository.MutasiDokumenView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		header, err := s.Repo.DokumenHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		// Dokumen aktif di luar cakupan → 404 (paritas detail tersembunyi).
		if err := s.assertDokumenTerlihat(ctx, tx, header, scope); err != nil {
			return err
		}
		if int64(header.Version) != in.Version {
			return opVersiDokumenBentrok(int64(header.Version), in.Version)
		}
		if string(header.Status) != "DRAFT" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Dokumen %s status %s — hanya DRAFT bisa diubah (INV-012).", header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		// Pasangan lokasi FINAL (input menimpa header) wajib dalam cakupan.
		idSumber := header.IDLokasiSumber
		if in.IDLokasiSumber != nil {
			idSumber = *in.IDLokasiSumber
		}
		idTujuan := header.IDLokasiTujuan
		if in.IDLokasiTujuan != nil {
			idTujuan = *in.IDLokasiTujuan
		}
		if err := s.assertLokasiDalamCakupan(ctx, tx, scope, idSumber, idTujuan); err != nil {
			return err
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
			alasan = in.Alasan // null eksplisit → NULL
		}
		updated, err := s.Repo.UpdateDraft(ctx, tx, repository.UpdateMutasiDraftParams{
			Jenis:          repository.EnumJenisGerakan(jenis),
			IDLokasiSumber: idSumber,
			IDLokasiTujuan: idTujuan,
			TanggalDokumen: opWaktu(tanggal),
			Alasan:         opTeks(alasan),
			Version:        header.Version + 1,
			UpdatedAt:      opWaktu(opWaktuSekarang()),
			ID:             id,
		})
		if err != nil {
			return err
		}
		if in.ItemsAda {
			if err := s.gantiItems(ctx, tx, id, in.Items); err != nil {
				return err
			}
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_mutasi_dokumen",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update_draft",
				AfterValue: audit.Snapshot{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

// Ajukan — CFG-INV-14 WAJIB_APPROVAL → MENUNGGU_PERSETUJUAN; default
// TANPA_APPROVAL → langsung DISETUJUI + posting baris gerakan.
func (s *MutasiService) Ajukan(ctx context.Context, idRaw string, version int64, c CtxMutasi) (repository.MutasiDokumenView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	var view repository.MutasiDokumenView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.DokumenHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertDokumenTerlihat(ctx, tx, header, scope); err != nil {
			return err
		}
		if int64(header.Version) != version {
			return opVersiDokumenBentrok(int64(header.Version), version)
		}
		if string(header.Status) != "DRAFT" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Dokumen %s status %s — ajukan hanya utk DRAFT (INV-012).", header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		mode, err := s.Cfg.GetString(ctx, tx, "inventory", "CFG-INV-14", "TANPA_APPROVAL")
		if err != nil {
			return err
		}
		if strings.ToUpper(mode) == "WAJIB_APPROVAL" {
			if _, err := s.Repo.UpdateStatus(ctx, tx, repository.UpdateMutasiStatusParams{
				Status:    repository.EnumStatusMutasi("MENUNGGU_PERSETUJUAN"),
				Version:   header.Version + 1,
				UpdatedAt: opWaktu(opWaktuSekarang()),
				ID:        id,
			}); err != nil {
				return err
			}
			if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
				EntryInput: audit.EntryInput{
					ModuleKey:  "inventory",
					EntityType: "inv_mutasi_dokumen",
					EntityID:   fmt.Sprintf("%d", id),
					Action:     "ajukan",
					AfterValue: audit.Snapshot{"status": "MENUNGGU_PERSETUJUAN"},
				},
				Actor: c.Actor,
			}}); err != nil {
				return err
			}
			view, err = s.muatSatu(ctx, tx, id)
			if err != nil {
				return err
			}
			return s.beriToken(&view)
		}
		if _, err := s.Repo.UpdateStatus(ctx, tx, repository.UpdateMutasiStatusParams{
			Status:    repository.EnumStatusMutasi("DISETUJUI"),
			Version:   header.Version + 1,
			UpdatedAt: opWaktu(opWaktuSekarang()),
			ID:        id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_mutasi_dokumen",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "ajukan",
				AfterValue: audit.Snapshot{"status": "DISETUJUI"},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		items, err := s.Repo.ItemsHidupByDokumen(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := s.postingGerakan(ctx, tx, header, items, c); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

// Keputusan — approval SoD penyusun ≠ penyetuju (INV-004).
func (s *MutasiService) Keputusan(ctx context.Context, idRaw string, in MutasiKeputusanInput, c CtxMutasi) (repository.MutasiDokumenView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	var view repository.MutasiDokumenView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.DokumenHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		// Penyetuju wajib melihat dokumen — di luar cakupan → 404.
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertDokumenTerlihat(ctx, tx, header, scope); err != nil {
			return err
		}
		if string(header.Status) != "MENUNGGU_PERSETUJUAN" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Dokumen %s status %s — keputusan hanya utk MENUNGGU_PERSETUJUAN (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		if header.IDCoreUsersPenyusun.Valid && opActorIDLonggar(c) != nil &&
			header.IDCoreUsersPenyusun.Int64 == *opActorIDLonggar(c) {
			return errkontrak.Conflict(
				"SoD: penyusun tidak boleh memutuskan dokumennya sendiri (INV-004).",
				opKodeInvSodDilanggar)
		}
		if in.Keputusan == "TOLAK" {
			alasan := opTxt(header.Alasan)
			if in.Alasan != nil {
				alasan = in.Alasan
			}
			if _, err := s.Repo.UpdateKeputusan(ctx, tx, repository.UpdateMutasiKeputusanParams{
				Status:               repository.EnumStatusMutasi("DITOLAK"),
				IDCoreUsersPenyetuju: *opActorIDLonggar(c),
				Alasan:               opTeks(alasan),
				Version:              header.Version + 1,
				UpdatedAt:            opWaktu(opWaktuSekarang()),
				ID:                   id,
			}); err != nil {
				return err
			}
			if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
				EntryInput: audit.EntryInput{
					ModuleKey:  "inventory",
					EntityType: "inv_mutasi_dokumen",
					EntityID:   fmt.Sprintf("%d", id),
					Action:     "keputusan",
					AfterValue: audit.Snapshot{"status": "DITOLAK", "alasan": opSnap(in.Alasan)},
					Severity:   audit.SeverityWarning,
				},
				Actor: c.Actor,
			}}); err != nil {
				return err
			}
			view, err = s.muatSatu(ctx, tx, id)
			if err != nil {
				return err
			}
			return s.beriToken(&view)
		}
		if _, err := s.Repo.UpdateKeputusan(ctx, tx, repository.UpdateMutasiKeputusanParams{
			Status:               repository.EnumStatusMutasi("DISETUJUI"),
			IDCoreUsersPenyetuju: *opActorIDLonggar(c),
			Alasan:               pgtextNil, // tidak disentuh (COALESCE keep)
			Version:              header.Version + 1,
			UpdatedAt:            opWaktu(opWaktuSekarang()),
			ID:                   id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_mutasi_dokumen",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "keputusan",
				AfterValue: audit.Snapshot{"status": "DISETUJUI"},
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		items, err := s.Repo.ItemsHidupByDokumen(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := s.postingGerakan(ctx, tx, header, items, c); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

// Batal — draft/pengajuan — alasan wajib (INV-005).
func (s *MutasiService) Batal(ctx context.Context, idRaw, alasan string, c CtxMutasi) (repository.MutasiDokumenView, error) {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	var view repository.MutasiDokumenView
	err = s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.DokumenHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertDokumenTerlihat(ctx, tx, header, scope); err != nil {
			return err
		}
		if string(header.Status) != "DRAFT" && string(header.Status) != "MENUNGGU_PERSETUJUAN" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Dokumen %s status %s — batal hanya utk DRAFT/MENUNGGU (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		if _, err := s.Repo.UpdateBatal(ctx, tx, repository.UpdateMutasiBatalParams{
			Alasan:    opTeks(&alasan),
			Version:   header.Version + 1,
			UpdatedAt: opWaktu(opWaktuSekarang()),
			ID:        id,
		}); err != nil {
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_mutasi_dokumen",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "batal",
				BeforeValue: audit.Snapshot{"status": string(header.Status)},
				AfterValue:  audit.Snapshot{"status": "DIBATALKAN", "alasan": alasan},
				Severity:    audit.SeverityWarning,
			},
			Actor: c.Actor,
		}}); err != nil {
			return err
		}
		view, err = s.muatSatu(ctx, tx, id)
		if err != nil {
			return err
		}
		return s.beriToken(&view)
	})
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	return view, nil
}

// Remove — hapus DRAFT lunak (header + items CASCADE soft) — jejak tetap ada.
func (s *MutasiService) Remove(ctx context.Context, idRaw string, c CtxMutasi) error {
	id, err := opParseIDPositif(idRaw)
	if err != nil {
		return err
	}
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		header, err := s.Repo.DokumenHidupById(ctx, tx, id)
		if err != nil {
			return err
		}
		scope, err := cakupanStorages(ctx, s.Scope, s.Audit, c.UserID, tx)
		if err != nil {
			return err
		}
		if err := s.assertDokumenTerlihat(ctx, tx, header, scope); err != nil {
			return err
		}
		if string(header.Status) != "DRAFT" {
			return errkontrak.Conflict(fmt.Sprintf(
				"Dokumen %s status %s — hanya DRAFT bisa dihapus (INV-012).",
				header.Kode, string(header.Status)),
				opKodeInvGerakanFinal)
		}
		sekarang := opWaktuSekarang()
		if err := s.Repo.SoftDeleteDokumen(ctx, tx, id, sekarang, sekarang); err != nil {
			return err
		}
		if err := s.Repo.SoftDeleteItemsHidupByDokumen(ctx, tx, id, sekarang, sekarang); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_mutasi_dokumen",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": header.Kode},
				Severity:    audit.SeverityWarning,
			},
			Actor: c.Actor,
		}})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Posting                                                         */
/* -------------------------------------------------------------- */

// postingGerakan — baris `inv_gerakan_stok` per item — status DRAFT (saldo
// berubah saat konfirmasi SELESAI via alur gerakan yang ada). PATCH 09 —
// posting = HEADER gerakan (nomor = kode dokumen mutasi, pola DO) + baris
// detail per item polos. Patch 59 — mutasi dari GR (header.id_pur_penerimaan
// terisi): jenis_sumber "GR-PO" + nilaiPersatuan = harga PO net ÷ faktor
// konversi (putus4); mutasi manual tidak mengisi nilai.
func (s *MutasiService) postingGerakan(ctx context.Context, tx pgx.Tx, header repository.InvMutasiDokuman, items []repository.InvMutasiItem, c CtxMutasi) error {
	aktor := opActorIDLonggar(c)
	dariGr := header.IDPurPenerimaan.Valid
	itemIDs := make([]int64, 0, len(items))
	for _, it := range items {
		itemIDs = append(itemIDs, it.ID)
	}
	nilaiByItem := map[int64]float64{}
	if dariGr {
		var err error
		nilaiByItem, err = s.hargaSatuanPoByItemId(ctx, tx, itemIDs)
		if err != nil {
			return err
		}
	}
	jenisSumber := "MUTASI"
	if dariGr {
		jenisSumber = "GR-PO"
	}
	gerakanHeader, err := repository.InsertGerakanHeader(ctx, tx, repository.OpGerakanHeaderInput{
		EntityID:            numbering.NewEntityID(),
		NomorDokumen:        header.Kode,
		Jenis:               string(header.Jenis),
		Status:              "DRAFT",
		TanggalJadwal:       header.TanggalDokumen.Time,
		JenisSumber:         jenisSumber,
		IDCoreUsers:         aktor,
		IDCoreUsersPenyusun: aktor,
		IDLokasiSumber:      &header.IDLokasiSumber,
		IDLokasiTujuan:      &header.IDLokasiTujuan,
	})
	if err != nil {
		return err
	}
	entityID := opUuid(header.EntityID)
	for _, item := range items {
		var nilaiPersatuan *float64
		if nilai, ada := nilaiByItem[item.ID]; ada {
			v := domain.Putus4(nilai)
			nilaiPersatuan = &v
		}
		if err := repository.InsertGerakanStokAbaikanDuplikat(ctx, tx, repository.OpGerakanStokAbaikanDuplikatInput{
			EntityID:           numbering.NewEntityID(),
			IDInvGerakanHeader: gerakanHeader.ID,
			IDInvProduk:        item.IDInvProduk,
			IDInvLotSerial:     opI8(item.IDInvLotSerial),
			IDInvUnitUkur:      item.IDInvUnitUkur,
			QtyDiminta:         int(item.QtyDiminta),
			IDLokasiSumber:     header.IDLokasiSumber,
			IDLokasiTujuan:     header.IDLokasiTujuan,
			NilaiPersatuan:     nilaiPersatuan,
			EntityIDSumber:     fmt.Sprintf("%s:%d", entityID, item.ID),
		}); err != nil {
			return err
		}
	}
	_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
		EntryInput: audit.EntryInput{
			ModuleKey:  "inventory",
			EntityType: "inv_mutasi_dokumen_posting",
			EntityID:   fmt.Sprintf("%d", header.ID),
			Action:     "posting",
			AfterValue: audit.Snapshot{"kode": header.Kode, "items": len(items)},
		},
		Actor: c.Actor,
	}})
	return err
}

/* -------------------------------------------------------------- */
/* Cakupan data — dimensi 'storages' (evaluator core/rbac)          */
/* -------------------------------------------------------------- */

// dokumenTerlihat — keanggotaan dokumen dalam cakupan ("party semantics"):
// terlihat bila minimal SATU endpoint (sumber ATAU tujuan) berada di gudang
// whitelist — transfer keluar/masuk gudang aktor tetap terlihat agar stok
// gudangnya rekonsiliasi (blueprint inv §3.3/A-05). Lokasi virtual tanpa
// gudang (id_inv_gudang NULL) tidak pernah masuk whitelist.
func (s *MutasiService) dokumenTerlihat(ctx context.Context, exec repository.DBTX, scope *repository.CakupanStorages, idLokasiSumber, idLokasiTujuan int64) (bool, error) {
	if scope == nil { // SEMUA
		return true, nil
	}
	if scope.Deny {
		return false, nil
	}
	gudang, err := s.Repo.GudangLokasiPasangan(ctx, exec, idLokasiSumber, idLokasiTujuan)
	if err != nil {
		return false, err
	}
	whitelist := map[int64]bool{}
	for _, id := range scope.IDs {
		whitelist[id] = true
	}
	for _, g := range gudang {
		if g != nil && whitelist[*g] {
			return true, nil
		}
	}
	return false, nil
}

// assertDokumenTerlihat — visibilitas by id — di luar cakupan → 404.
func (s *MutasiService) assertDokumenTerlihat(ctx context.Context, exec repository.DBTX, header repository.InvMutasiDokuman, scope *repository.CakupanStorages) error {
	terlihat, err := s.dokumenTerlihat(ctx, exec, scope, header.IDLokasiSumber, header.IDLokasiTujuan)
	if err != nil {
		return err
	}
	if !terlihat {
		return domain.ErrDokumenTersembunyi(header.ID)
	}
	return nil
}

// assertLokasiDalamCakupan — gerbang tulis lokasi (create/update): dokumen
// boleh disusun bila minimal satu endpoint di gudang whitelist aktor —
// paritas visibilitas list/detail. Di luar cakupan → 409 INV-021 (lokasi
// adalah master yang aktor ketahui; beda dengan dokumen tersembunyi 404).
func (s *MutasiService) assertLokasiDalamCakupan(ctx context.Context, exec repository.DBTX, scope *repository.CakupanStorages, idLokasiSumber, idLokasiTujuan int64) error {
	if scope == nil { // SEMUA
		return nil
	}
	terlihat, err := s.dokumenTerlihat(ctx, exec, scope, idLokasiSumber, idLokasiTujuan)
	if err != nil {
		return err
	}
	if terlihat {
		return nil
	}
	return errkontrak.Conflict(
		"Lokasi sumber/tujuan di luar whitelist data-scope Anda (dimensi 'storages').",
		domain.KodeInvLokasiTidakDiizinkan)
}

/* -------------------------------------------------------------- */
/* Internal                                                         */
/* -------------------------------------------------------------- */

// sisipItems — snapshot nama produk + validasi referensi hidup.
func (s *MutasiService) sisipItems(ctx context.Context, tx pgx.Tx, idDokumen int64, items []MutasiItemInput, idGrItems []*int64) error {
	produkIDs := []int64{}
	for _, i := range items {
		produkIDs = opUnikI64(produkIDs, i.IDInvProduk)
	}
	namaRows, err := s.Repo.NamaProdukHidupByIds(ctx, tx, produkIDs)
	if err != nil {
		return err
	}
	namaByID := map[int64]string{}
	for _, r := range namaRows {
		namaByID[r.ID] = r.Nama
	}
	for i, item := range items {
		if _, ada := namaByID[item.IDInvProduk]; !ada {
			return errkontrak.BadRequest(fmt.Sprintf(
				"Produk id %d tidak ditemukan / tidak aktif.", item.IDInvProduk))
		}
		var idGrItem *int64
		if idGrItems != nil {
			idGrItem = idGrItems[i]
		}
		if err := s.Repo.InsertItem(ctx, tx, repository.InsertMutasiItemParams{
			EntityID:            opUuidParam(numbering.NewEntityID()),
			IDInvMutasiDokumen:  idDokumen,
			IDInvProduk:         item.IDInvProduk,
			IDInvLotSerial:      opI8N(item.IDInvLotSerial),
			IDInvUnitUkur:       item.IDInvUnitUkur,
			QtyDiminta:          int32(item.QtyDiminta),
			NamaProduk:          namaByID[item.IDInvProduk],
			IDPurPenerimaanItem: opI8N(idGrItem),
		}); err != nil {
			return err
		}
	}
	return nil
}

// gantiItems — REPLACE items draft — soft delete lama + sisip baru (satu UoW).
func (s *MutasiService) gantiItems(ctx context.Context, tx pgx.Tx, idDokumen int64, items []MutasiItemInput) error {
	sekarang := opWaktuSekarang()
	if err := s.Repo.SoftDeleteItemsHidupByDokumen(ctx, tx, idDokumen, sekarang, sekarang); err != nil {
		return err
	}
	return s.sisipItems(ctx, tx, idDokumen, items, nil)
}

// muatSatu — detail dokumen + referensi + items + jumlah posting.
func (s *MutasiService) muatSatu(ctx context.Context, exec repository.DBTX, id int64) (repository.MutasiDokumenView, error) {
	row, err := s.Repo.MutasiDokumenDenganRef(ctx, exec, id)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	if row == nil {
		return repository.MutasiDokumenView{}, domain.ErrDokumenTersembunyi(id)
	}
	itemViews, err := s.muatItemViews(ctx, exec, id)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	posting, err := s.Repo.HitungGerakanDipostingNomor(ctx, exec, row.Kode)
	if err != nil {
		return repository.MutasiDokumenView{}, err
	}
	v := repository.MutasiHeaderView(
		row.ID, row.Kode, string(row.Jenis), string(row.Status),
		row.IDLokasiSumber, row.IDLokasiTujuan,
		opIso(row.TanggalDokumen), opIso(row.CreatedAt), opIso(row.UpdatedAt),
		opTxt(row.Penyusun), opTxt(row.Penyetuju), opTxt(row.Alasan),
		row.Version, opI8(row.IDPurPenerimaan), opTxt(row.NomorGr), opTxt(row.NomorPo),
	)
	v.Items = itemViews
	v.JumlahGerakanDiposting = posting
	v.NamaLokasiSumber = row.NamaSumber
	v.NamaLokasiTujuan = row.NamaTujuan
	return v, nil
}

// muatItemViews — baris item ber-join + harga PO net per satuan dasar
// (patch 59 — recomputasi sama persis dengan posting — sumber helper sama).
func (s *MutasiService) muatItemViews(ctx context.Context, exec repository.DBTX, idDokumen int64) ([]repository.MutasiItemView, error) {
	rows, err := s.Repo.MutasiItemBaris(ctx, exec, idDokumen)
	if err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(rows))
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	hargaPo, err := s.hargaSatuanPoByItemId(ctx, exec, ids)
	if err != nil {
		return nil, err
	}
	out := make([]repository.MutasiItemView, 0, len(rows))
	for _, r := range rows {
		out = append(out, repository.MutasiItemView{
			ID:                 r.ID,
			IDInvMutasiDokumen: r.IDInvMutasiDokumen,
			IDInvProduk:        r.IDInvProduk,
			KodeProduk:         r.KodeProduk,
			NamaProduk:         r.NamaProduk,
			IDInvLotSerial:     opI8(r.IDInvLotSerial),
			KodeLot:            opTxt(r.KodeLot),
			IDInvUnitUkur:      r.IDInvUnitUkur,
			KodeUnit:           r.KodeUnit,
			QtyDiminta:         int(r.QtyDiminta),
			HargaSatuanPo:      hargaPoPtr(hargaPo, r.ID), // nil — tanpa jejak GR → fallback manual
			Version:            r.Version,
			CreatedAt:          opIso(r.CreatedAt),
			UpdatedAt:          opIso(r.UpdatedAt),
		})
	}
	return out, nil
}

// hargaSatuanPoByItemId — harga PO net per satuan dasar per item mutasi
// (patch 59) — SUMBER TUNGGAL view & posting: net = harga × (1 −
// diskon_persen/100); dibagi faktor konversi — faktor = qtyDiminta / qtyGr
// (qty dasar = qty GR × faktor konversi saat generate); satuan sama / qty ≤
// 0 → faktor 1. Item tanpa jejak GR tidak masuk map (→ null di view).
func (s *MutasiService) hargaSatuanPoByItemId(ctx context.Context, exec repository.DBTX, itemIDs []int64) (map[int64]float64, error) {
	out := map[int64]float64{}
	if len(itemIDs) == 0 {
		return out, nil
	}
	rows, err := s.Repo.HargaSatuanPoBaris(ctx, exec, itemIDs)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		satuanSama := r.IDUnitBeli == r.IDUnitDasar
		faktor := 1.0
		if !satuanSama && r.QtyGr > 0 && r.QtyDiminta > 0 {
			faktor = float64(r.QtyDiminta) / float64(r.QtyGr)
		}
		net := opAngka(r.Harga) * (1 - opAngka(r.Diskon)/100)
		out[r.IDItem] = domain.Putus4(net / faktor)
	}
	return out, nil
}

// hargaPoPtr — map harga → *float64 (absen = nil — fallback manual).
func hargaPoPtr(m map[int64]float64, id int64) *float64 {
	v, ada := m[id]
	if !ada {
		return nil
	}
	return &v
}

// beriToken — tempel token PK tersamar ke view (list/get/jalur tulis).
func (s *MutasiService) beriToken(v *repository.MutasiDokumenView) error {
	token, err := s.Cipher.EncryptID(v.ID)
	if err != nil {
		return err
	}
	v.Token = token
	return nil
}

/* -------------------------------------------------------------- */
/* Helper kecil bersama operasi                                     */
/* -------------------------------------------------------------- */

// opVersiDokumenBentrok — 409 INV-017 pesan verbatim mutasi.
func opVersiDokumenBentrok(server, kirim int64) error {
	return errkontrak.Conflict(fmt.Sprintf(
		"Versi dokumen tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok)
}

// opUnikI64 — dedupe id (urutan tetap).
func opUnikI64(s []int64, v int64) []int64 {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}

// opSortWhitelist — field sort di luar whitelist → 400 VAL-400 pesan
// verbatim `Field sort tidak dikenal: X.` (padanan drizzlePageBounds).
func opSortWhitelist(pr *errkontrak.PageRequest, allowed ...string) error {
	if pr == nil {
		return nil
	}
	set := map[string]bool{}
	for _, a := range allowed {
		set[a] = true
	}
	for _, sk := range pr.Sort {
		if !set[sk.Field] {
			return errkontrak.Validation([]errkontrak.FieldIssue{
				{Field: "sort", Message: fmt.Sprintf("Field sort tidak dikenal: %s.", sk.Field)},
			})
		}
	}
	return nil
}

// opPilihSort — SortKey PERTAMA yang terdaftar whitelist (urutan deklarasi
// dipertahankan); fallback ("", false) = urutan default SQL.
func opPilihSort(pr *errkontrak.PageRequest, whitelist map[string]string, fallback string) (string, bool) {
	for _, k := range pr.Sort {
		if label, ada := whitelist[k.Field]; ada {
			return label, k.Desc
		}
	}
	return fallback, false
}

// opFilterJenisMutasi — filter[jenis] multi koma-terpisah (halaman Mutasi
// InOut: PENERIMAAN,PENGIRIMAN) — nilai tunggal tetap eq (backward
// compatible); nilai di luar kosakata dibuang (verbatim filter enumValues).
func opFilterJenisMutasi(pr *errkontrak.PageRequest, key string) []string {
	raw := opFilterVal(pr, key)
	if raw == nil {
		return nil
	}
	sah := map[string]bool{"PENERIMAAN": true, "PENGIRIMAN": true, "TRANSFER_INTERNAL": true}
	out := []string{}
	for _, j := range strings.Split(*raw, ",") {
		j = strings.TrimSpace(j)
		if sah[j] {
			out = append(out, j)
		}
	}
	return out
}
