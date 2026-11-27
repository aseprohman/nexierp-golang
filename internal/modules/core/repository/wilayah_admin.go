// wilayah_admin.go — fitur WILAYAH ADMIN (CRUD/tulis referensi wilayah
// Indonesia, 4 level MASTER) — padanan WilayahAdminRepository NestJS:
// assert baris hidup (404 WLY-005) & muat view level itu melempar DomainError;
// pre-check kode hidup duplikat HANYA query — 409 WLY-004 diputuskan service;
// hitung child hidup; INSERT/UPDATE/soft-delete dengan WHERE optimistic-lock
// `version`. Race uq_*_kode_hidup (23505) DILEMPAR MENTAH — service
// memetakan via errkontrak.IsUniqueViolation. Baris penuh (SELECT *)
// dikembalikan untuk snapshot audit.
package repository

import (
	"context"
	"time"

	"nexierp/internal/modules/core/domain"
	"nexierp/internal/modules/core/repository/gen"
	"nexierp/internal/modules/core/types"
)

// WilayahAdminRepository — CRUD 4 level MASTER wilayah.
type WilayahAdminRepository struct{}

// NewWilayahAdminRepository membuat repository admin wilayah.
func NewWilayahAdminRepository() *WilayahAdminRepository { return &WilayahAdminRepository{} }

// ---------------------------------------------------------------------
// Assert baris hidup (404 WLY-005)
// ---------------------------------------------------------------------

// AssertProvinsiAda — baris provinsi hidup penuh.
func (r *WilayahAdminRepository) AssertProvinsiAda(ctx context.Context, exec gen.DBTX, id int64) (gen.CoreProvinsi, error) {
	rows, err := gen.New(exec).AssertProvinsiAda(ctx, id)
	if err != nil {
		return gen.CoreProvinsi{}, err
	}
	if len(rows) == 0 {
		return gen.CoreProvinsi{}, domain.ErrTidakDitemukan("Provinsi", id)
	}
	return rows[0], nil
}

// AssertKotaAda — baris kota hidup penuh.
func (r *WilayahAdminRepository) AssertKotaAda(ctx context.Context, exec gen.DBTX, id int64) (gen.CoreKotum, error) {
	rows, err := gen.New(exec).AssertKotaAda(ctx, id)
	if err != nil {
		return gen.CoreKotum{}, err
	}
	if len(rows) == 0 {
		return gen.CoreKotum{}, domain.ErrTidakDitemukan("Kota", id)
	}
	return rows[0], nil
}

// AssertKecamatanAda — baris kecamatan hidup penuh.
func (r *WilayahAdminRepository) AssertKecamatanAda(ctx context.Context, exec gen.DBTX, id int64) (gen.CoreKecamatan, error) {
	rows, err := gen.New(exec).AssertKecamatanAda(ctx, id)
	if err != nil {
		return gen.CoreKecamatan{}, err
	}
	if len(rows) == 0 {
		return gen.CoreKecamatan{}, domain.ErrTidakDitemukan("Kecamatan", id)
	}
	return rows[0], nil
}

// AssertKelurahanAda — baris kelurahan hidup penuh.
func (r *WilayahAdminRepository) AssertKelurahanAda(ctx context.Context, exec gen.DBTX, id int64) (gen.CoreKelurahan, error) {
	rows, err := gen.New(exec).AssertKelurahanAda(ctx, id)
	if err != nil {
		return gen.CoreKelurahan{}, err
	}
	if len(rows) == 0 {
		return gen.CoreKelurahan{}, domain.ErrTidakDitemukan("Kelurahan", id)
	}
	return rows[0], nil
}

// ---------------------------------------------------------------------
// Pre-check kode hidup duplikat (409 WLY-004 diputuskan service)
// ---------------------------------------------------------------------

// CariKodeHidupProvinsi — true bila provinsi hidup ber-kode sama ada
// (race → 23505).
func (r *WilayahAdminRepository) CariKodeHidupProvinsi(ctx context.Context, exec gen.DBTX, kode string) (bool, error) {
	rows, err := gen.New(exec).CariKodeHidupProvinsi(ctx, kode)
	return len(rows) > 0, err
}

// CariKodeHidupKota — true bila kota hidup ber-kode sama ada.
func (r *WilayahAdminRepository) CariKodeHidupKota(ctx context.Context, exec gen.DBTX, kode string) (bool, error) {
	rows, err := gen.New(exec).CariKodeHidupKota(ctx, kode)
	return len(rows) > 0, err
}

// CariKodeHidupKecamatan — true bila kecamatan hidup ber-kode sama ada.
func (r *WilayahAdminRepository) CariKodeHidupKecamatan(ctx context.Context, exec gen.DBTX, kode string) (bool, error) {
	rows, err := gen.New(exec).CariKodeHidupKecamatan(ctx, kode)
	return len(rows) > 0, err
}

// CariKodeHidupKelurahan — true bila kelurahan hidup ber-kode sama ada.
func (r *WilayahAdminRepository) CariKodeHidupKelurahan(ctx context.Context, exec gen.DBTX, kode string) (bool, error) {
	rows, err := gen.New(exec).CariKodeHidupKelurahan(ctx, kode)
	return len(rows) > 0, err
}

// ---------------------------------------------------------------------
// Hitung child hidup (guard ubah kode WLY-001 & hapus WLY-003)
// ---------------------------------------------------------------------

// HitungKotaHidup — jumlah kota hidup satu provinsi.
func (r *WilayahAdminRepository) HitungKotaHidup(ctx context.Context, exec gen.DBTX, idProvinsi int64) (int32, error) {
	return gen.New(exec).HitungKotaHidup(ctx, idProvinsi)
}

// HitungKecamatanHidup — jumlah kecamatan hidup satu kota.
func (r *WilayahAdminRepository) HitungKecamatanHidup(ctx context.Context, exec gen.DBTX, idKota int64) (int32, error) {
	return gen.New(exec).HitungKecamatanHidup(ctx, idKota)
}

// HitungKelurahanHidup — jumlah kelurahan hidup satu kecamatan.
func (r *WilayahAdminRepository) HitungKelurahanHidup(ctx context.Context, exec gen.DBTX, idKecamatan int64) (int32, error) {
	return gen.New(exec).HitungKelurahanHidup(ctx, idKecamatan)
}

// ---------------------------------------------------------------------
// Muat view level itu (join nama induk) — respons create/update
// ---------------------------------------------------------------------

// MuatKotaView — satu kota + nama provinsi — 404 WLY-005 bila absen.
func (r *WilayahAdminRepository) MuatKotaView(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKotaView, error) {
	rows, err := gen.New(exec).MuatKotaByID(ctx, id)
	if err != nil {
		return types.WilayahKotaView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKotaView{}, domain.ErrTidakDitemukan("Kota", id)
	}
	row := rows[0]
	return types.WilayahKotaView{
		ID:             row.ID,
		Kode:           row.Kode,
		Nama:           row.Nama,
		Jenis:          row.Jenis,
		IDCoreProvinsi: row.IDCoreProvinsi,
		ProvinsiNama:   row.ProvinsiNama,
		Version:        row.Version,
	}, nil
}

// MuatKecamatanView — satu kecamatan + nama kota — 404 WLY-005 bila absen.
func (r *WilayahAdminRepository) MuatKecamatanView(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKecamatanView, error) {
	rows, err := gen.New(exec).MuatKecamatanByID(ctx, id)
	if err != nil {
		return types.WilayahKecamatanView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKecamatanView{}, domain.ErrTidakDitemukan("Kecamatan", id)
	}
	row := rows[0]
	return types.WilayahKecamatanView{
		ID:         row.ID,
		Kode:       row.Kode,
		Nama:       row.Nama,
		IDCoreKota: row.IDCoreKota,
		KotaNama:   row.KotaNama,
		Version:    row.Version,
	}, nil
}

// MuatKelurahanView — satu kelurahan + nama kecamatan — 404 WLY-005 bila absen.
func (r *WilayahAdminRepository) MuatKelurahanView(ctx context.Context, exec gen.DBTX, id int64) (types.WilayahKelurahanView, error) {
	rows, err := gen.New(exec).MuatKelurahanLengkap(ctx, id)
	if err != nil {
		return types.WilayahKelurahanView{}, err
	}
	if len(rows) == 0 {
		return types.WilayahKelurahanView{}, domain.ErrTidakDitemukan("Kelurahan", id)
	}
	row := rows[0]
	return kelurahanView(row.ID, row.Kode, row.Nama, row.KodePos, row.IDCoreKecamatan, row.KecamatanNama, row.Version), nil
}

// ---------------------------------------------------------------------
// CRUD — provinsi
// ---------------------------------------------------------------------

// InsertProvinsi — baris lengkap; race uq kode hidup (23505) mentah.
func (r *WilayahAdminRepository) InsertProvinsi(ctx context.Context, exec gen.DBTX, kode, nama string) (gen.CoreProvinsi, error) {
	return gen.New(exec).InsertProvinsi(ctx, gen.InsertProvinsiParams{Kode: kode, Nama: nama, Version: 1})
}

// ProvinsiUbahSet — nilai kolom dibangun service (version = bump).
type ProvinsiUbahSet struct {
	ID          int64
	VersiServer int32
	Kode        string
	Nama        string
	Version     int32
	UpdatedAt   time.Time
}

// UpdateProvinsi — nil = versi bentrok (race).
func (r *WilayahAdminRepository) UpdateProvinsi(ctx context.Context, exec gen.DBTX, s ProvinsiUbahSet) (*gen.CoreProvinsi, error) {
	rows, err := gen.New(exec).UpdateProvinsi(ctx, gen.UpdateProvinsiParams{
		Kode:        s.Kode,
		Nama:        s.Nama,
		Version:     s.Version,
		UpdatedAt:   waktu(s.UpdatedAt),
		ID:          s.ID,
		VersiServer: s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDeleteProvinsi — false = versi bentrok (race).
func (r *WilayahAdminRepository) SoftDeleteProvinsi(ctx context.Context, exec gen.DBTX, id int64, versiServer int32, now time.Time) (bool, error) {
	rows, err := gen.New(exec).SoftDeleteProvinsi(ctx, gen.SoftDeleteProvinsiParams{
		DeletedAt:   waktu(now),
		UpdatedAt:   waktu(now),
		ID:          id,
		VersiServer: versiServer,
	})
	return len(rows) > 0, err
}

// ---------------------------------------------------------------------
// CRUD — kota
// ---------------------------------------------------------------------

// InsertKota — baris lengkap; race uq kode hidup (23505) mentah.
func (r *WilayahAdminRepository) InsertKota(ctx context.Context, exec gen.DBTX, kode, nama, jenis string, idCoreProvinsi int64) (gen.CoreKotum, error) {
	return gen.New(exec).InsertKota(ctx, gen.InsertKotaParams{
		Kode:           kode,
		Nama:           nama,
		Jenis:          jenis,
		IDCoreProvinsi: idCoreProvinsi,
		Version:        1,
	})
}

// KotaUbahSet — nilai kolom dibangun service.
type KotaUbahSet struct {
	ID             int64
	VersiServer    int32
	Kode           string
	Nama           string
	Jenis          string
	IDCoreProvinsi int64
	Version        int32
	UpdatedAt      time.Time
}

// UpdateKota — nil = versi bentrok (race).
func (r *WilayahAdminRepository) UpdateKota(ctx context.Context, exec gen.DBTX, s KotaUbahSet) (*gen.CoreKotum, error) {
	rows, err := gen.New(exec).UpdateKota(ctx, gen.UpdateKotaParams{
		Kode:           s.Kode,
		Nama:           s.Nama,
		Jenis:          s.Jenis,
		IDCoreProvinsi: s.IDCoreProvinsi,
		Version:        s.Version,
		UpdatedAt:      waktu(s.UpdatedAt),
		ID:             s.ID,
		VersiServer:    s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDeleteKota — false = versi bentrok.
func (r *WilayahAdminRepository) SoftDeleteKota(ctx context.Context, exec gen.DBTX, id int64, versiServer int32, now time.Time) (bool, error) {
	rows, err := gen.New(exec).SoftDeleteKota(ctx, gen.SoftDeleteKotaParams{
		DeletedAt:   waktu(now),
		UpdatedAt:   waktu(now),
		ID:          id,
		VersiServer: versiServer,
	})
	return len(rows) > 0, err
}

// ---------------------------------------------------------------------
// CRUD — kecamatan
// ---------------------------------------------------------------------

// InsertKecamatan — baris lengkap; race uq kode hidup (23505) mentah.
func (r *WilayahAdminRepository) InsertKecamatan(ctx context.Context, exec gen.DBTX, kode, nama string, idCoreKota int64) (gen.CoreKecamatan, error) {
	return gen.New(exec).InsertKecamatan(ctx, gen.InsertKecamatanParams{
		Kode:       kode,
		Nama:       nama,
		IDCoreKota: idCoreKota,
		Version:    1,
	})
}

// KecamatanUbahSet — nilai kolom dibangun service.
type KecamatanUbahSet struct {
	ID          int64
	VersiServer int32
	Kode        string
	Nama        string
	IDCoreKota  int64
	Version     int32
	UpdatedAt   time.Time
}

// UpdateKecamatan — nil = versi bentrok (race).
func (r *WilayahAdminRepository) UpdateKecamatan(ctx context.Context, exec gen.DBTX, s KecamatanUbahSet) (*gen.CoreKecamatan, error) {
	rows, err := gen.New(exec).UpdateKecamatan(ctx, gen.UpdateKecamatanParams{
		Kode:        s.Kode,
		Nama:        s.Nama,
		IDCoreKota:  s.IDCoreKota,
		Version:     s.Version,
		UpdatedAt:   waktu(s.UpdatedAt),
		ID:          s.ID,
		VersiServer: s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDeleteKecamatan — false = versi bentrok.
func (r *WilayahAdminRepository) SoftDeleteKecamatan(ctx context.Context, exec gen.DBTX, id int64, versiServer int32, now time.Time) (bool, error) {
	rows, err := gen.New(exec).SoftDeleteKecamatan(ctx, gen.SoftDeleteKecamatanParams{
		DeletedAt:   waktu(now),
		UpdatedAt:   waktu(now),
		ID:          id,
		VersiServer: versiServer,
	})
	return len(rows) > 0, err
}

// ---------------------------------------------------------------------
// CRUD — kelurahan/desa (level daun — soft delete TANPA child-check)
// ---------------------------------------------------------------------

// InsertKelurahan — kodePos nil = NULL (belum tercantum); race uq kode hidup
// (23505) mentah.
func (r *WilayahAdminRepository) InsertKelurahan(ctx context.Context, exec gen.DBTX, kode, nama string, kodePos *string, idCoreKecamatan int64) (gen.CoreKelurahan, error) {
	return gen.New(exec).InsertKelurahan(ctx, gen.InsertKelurahanParams{
		Kode:            kode,
		Nama:            nama,
		KodePos:         teksNihil(kodePos),
		IDCoreKecamatan: idCoreKecamatan,
		Version:         1,
	})
}

// KelurahanUbahSet — nilai kolom dibangun service (kodePos nil = hapus).
type KelurahanUbahSet struct {
	ID              int64
	VersiServer     int32
	Kode            string
	Nama            string
	KodePos         *string
	IDCoreKecamatan int64
	Version         int32
	UpdatedAt       time.Time
}

// UpdateKelurahan — nil = versi bentrok (race).
func (r *WilayahAdminRepository) UpdateKelurahan(ctx context.Context, exec gen.DBTX, s KelurahanUbahSet) (*gen.CoreKelurahan, error) {
	rows, err := gen.New(exec).UpdateKelurahan(ctx, gen.UpdateKelurahanParams{
		Kode:            s.Kode,
		Nama:            s.Nama,
		KodePos:         teksNihil(s.KodePos),
		IDCoreKecamatan: s.IDCoreKecamatan,
		Version:         s.Version,
		UpdatedAt:       waktu(s.UpdatedAt),
		ID:              s.ID,
		VersiServer:     s.VersiServer,
	})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	return &rows[0], nil
}

// SoftDeleteKelurahan — false = versi bentrok.
func (r *WilayahAdminRepository) SoftDeleteKelurahan(ctx context.Context, exec gen.DBTX, id int64, versiServer int32, now time.Time) (bool, error) {
	rows, err := gen.New(exec).SoftDeleteKelurahan(ctx, gen.SoftDeleteKelurahanParams{
		DeletedAt:   waktu(now),
		UpdatedAt:   waktu(now),
		ID:          id,
		VersiServer: versiServer,
	})
	return len(rows) > 0, err
}
