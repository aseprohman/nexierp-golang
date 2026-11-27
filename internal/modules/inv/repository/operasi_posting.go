// operasi_posting.go — wrapper posting gerakan bersama fitur MUTASI &
// PENYESUAIAN modul inv (insert `inv_gerakan_header` / `inv_gerakan_stok`,
// idempoten via uq_inv_gerakan_idempoten pada entity_id_sumber): nilai
// INSERT dibangun SERVICE (jenis_sumber MUTASI/GR-PO/ADJ, pasangan lokasi
// ADJ-VIRTUAL per baris D-48, nilai putus4) — wrapper hanya pemetaan param.
package repository

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/modules/inv/repository/gen"
)

// OpGerakanHeaderInput — nilai insert inv_gerakan_header (dibangun service).
type OpGerakanHeaderInput struct {
	EntityID            string
	NomorDokumen        string
	Jenis               string // enum_jenis_gerakan
	Status              string // enum_status_gerakan
	TanggalJadwal       time.Time
	TanggalSelesai      *time.Time
	JenisSumber         string
	IDCoreUsers         *int64
	IDCoreUsersPenyusun *int64
	IDLokasiSumber      *int64 // NULL utk posting ADJ (lokasi per baris D-48)
	IDLokasiTujuan      *int64
}

// InsertGerakanHeader — insert HEADER gerakan → baris lengkap (dipakai
// posting mutasi & penyesuaian).
func InsertGerakanHeader(ctx context.Context, exec DBTX, in OpGerakanHeaderInput) (gen.InvGerakanHeader, error) {
	return gen.New(exec).InsertGerakanHeader(ctx, gen.InsertGerakanHeaderParams{
		EntityID:            maUuidNilai(in.EntityID),
		NomorDokumen:        in.NomorDokumen,
		Jenis:               gen.EnumJenisGerakan(in.Jenis),
		Status:              gen.EnumStatusGerakan(in.Status),
		TanggalJadwal:       maWaktu(in.TanggalJadwal),
		TanggalSelesai:      waktuNihil(in.TanggalSelesai),
		JenisSumber:         in.JenisSumber,
		IDCoreUsers:         maI8Nilai(in.IDCoreUsers),
		IDCoreUsersPenyusun: maI8Nilai(in.IDCoreUsersPenyusun),
		IDLokasiSumber:      maI8Nilai(in.IDLokasiSumber),
		IDLokasiTujuan:      maI8Nilai(in.IDLokasiTujuan),
	})
}

// OpGerakanStokAbaikanDuplikatInput — nilai insert inv_gerakan_stok status
// DRAFT (posting mutasi — onConflictDoNothing; retry → kunci idempoten sama
// → unique index menahan duplikat).
type OpGerakanStokAbaikanDuplikatInput struct {
	EntityID           string
	IDInvGerakanHeader int64
	IDInvProduk        int64
	IDInvLotSerial     *int64
	IDInvUnitUkur      int64
	QtyDiminta         int
	IDLokasiSumber     int64
	IDLokasiTujuan     int64
	NilaiPersatuan     *float64 // NULL = mutasi manual (fallback valuasi harga_biaya)
	EntityIDSumber     string
}

// InsertGerakanStokAbaikanDuplikat — insert baris inv_gerakan_stok DRAFT.
func InsertGerakanStokAbaikanDuplikat(ctx context.Context, exec DBTX, in OpGerakanStokAbaikanDuplikatInput) error {
	return gen.New(exec).InsertGerakanStokAbaikanDuplikat(ctx, gen.InsertGerakanStokAbaikanDuplikatParams{
		EntityID:           maUuidNilai(in.EntityID),
		IDInvGerakanHeader: in.IDInvGerakanHeader,
		IDInvProduk:        in.IDInvProduk,
		IDInvLotSerial:     maI8Nilai(in.IDInvLotSerial),
		IDInvUnitUkur:      in.IDInvUnitUkur,
		QtyDiminta:         int32(in.QtyDiminta),
		IDLokasiSumber:     in.IDLokasiSumber,
		IDLokasiTujuan:     in.IDLokasiTujuan,
		NilaiPersatuan:     opNumericN(in.NilaiPersatuan),
		EntityIDSumber:     maTeksNihil(&in.EntityIDSumber),
	})
}

// OpGerakanStokInput — nilai insert inv_gerakan_stok SELESAI (posting
// penyesuaian per item selisih ≠ 0 — override lokasi per baris D-48).
type OpGerakanStokInput struct {
	EntityID           string
	IDInvGerakanHeader int64
	IDInvProduk        int64
	IDInvLotSerial     *int64
	IDInvUnitUkur      int64
	QtyDiminta         int
	QtySelesai         int
	IDLokasiSumber     int64
	IDLokasiTujuan     int64
	NilaiPersatuan     *float64
	TanggalSelesai     *time.Time
	EntityIDSumber     string
}

// InsertGerakanStok — insert gerakan per item → baris lengkap.
func InsertGerakanStok(ctx context.Context, exec DBTX, in OpGerakanStokInput) (gen.InvGerakanStok, error) {
	return gen.New(exec).InsertGerakanStok(ctx, gen.InsertGerakanStokParams{
		EntityID:           maUuidNilai(in.EntityID),
		IDInvGerakanHeader: in.IDInvGerakanHeader,
		IDInvProduk:        in.IDInvProduk,
		IDInvLotSerial:     maI8Nilai(in.IDInvLotSerial),
		IDInvUnitUkur:      in.IDInvUnitUkur,
		QtyDiminta:         int32(in.QtyDiminta),
		QtySelesai:         int32(in.QtySelesai),
		IDLokasiSumber:     in.IDLokasiSumber,
		IDLokasiTujuan:     in.IDLokasiTujuan,
		NilaiPersatuan:     opNumericN(in.NilaiPersatuan),
		TanggalSelesai:     waktuNihil(in.TanggalSelesai),
		EntityIDSumber:     maTeksNihil(&in.EntityIDSumber),
	})
}

// waktuNihil — *time.Time → pgtype.Timestamptz (nil = NULL).
func waktuNihil(t *time.Time) (v pgtype.Timestamptz) {
	if t == nil {
		return v
	}
	return maWaktu(*t)
}
