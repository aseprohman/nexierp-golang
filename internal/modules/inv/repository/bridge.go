package repository

// Jembatan tipe untuk service (prinsip: gen hanya di repository/).
// Service memakai alias repository.X — definisi tetap di gen.
import (
	"nexierp/internal/modules/inv/repository/gen"
)

type (
	EnumFrekuensiHitung           = gen.EnumFrekuensiHitung
	EnumJenisGerakan              = gen.EnumJenisGerakan
	EnumJenisPenyesuaian          = gen.EnumJenisPenyesuaian
	EnumStatusMutasi              = gen.EnumStatusMutasi
	EnumStatusPenyesuaian         = gen.EnumStatusPenyesuaian
	InsertJadwalHitungParams      = gen.InsertJadwalHitungParams
	InsertLapisanBiayaParams      = gen.InsertLapisanBiayaParams
	InsertMutasiDokumenParams     = gen.InsertMutasiDokumenParams
	InsertMutasiItemParams        = gen.InsertMutasiItemParams
	InsertPenyesuaianItemParams   = gen.InsertPenyesuaianItemParams
	InsertPenyesuaianParams       = gen.InsertPenyesuaianParams
	InvGerakanHeader              = gen.InvGerakanHeader
	InvMutasiDokuman              = gen.InvMutasiDokuman
	InvMutasiItem                 = gen.InvMutasiItem
	InvPenyesuaianStok            = gen.InvPenyesuaianStok
	InvPenyesuaianStokItem        = gen.InvPenyesuaianStokItem
	KemasanHidupByIdsRow          = gen.KemasanHidupByIdsRow
	ProdukDenganUnitHidupByIdsRow = gen.ProdukDenganUnitHidupByIdsRow
	ProdukRingkasHidupByIdsRow    = gen.ProdukRingkasHidupByIdsRow
	PurPenerimaanItem             = gen.PurPenerimaanItem
	PurPesananItem                = gen.PurPesananItem
	UpdateJadwalHitungPatchParams = gen.UpdateJadwalHitungPatchParams
	UpdateMutasiBatalParams       = gen.UpdateMutasiBatalParams
	UpdateMutasiDraftParams       = gen.UpdateMutasiDraftParams
	UpdateMutasiKeputusanParams   = gen.UpdateMutasiKeputusanParams
	UpdateMutasiStatusParams      = gen.UpdateMutasiStatusParams
	UpdatePenyesuaianDraftParams  = gen.UpdatePenyesuaianDraftParams
	UpdatePenyesuaianStatusParams = gen.UpdatePenyesuaianStatusParams
)
