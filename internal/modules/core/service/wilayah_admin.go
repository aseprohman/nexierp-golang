// service/wilayah_admin.go — fitur WILAYAH ADMIN — CRUD (tulis) referensi
// wilayah Indonesia (4 level MASTER) — padanan WilayahAdminService NestJS.
// TERPISAH dari WilayahService (lookup baca-saja) agar SET RBAC
// system.wilayah_admin terpisah dari SET baca system.wilayah.
// SEMUA tulis dalam SATU pgx.Tx + audit.Append transaksi yang sama; aktor
// dari JWT (handler), BUKAN payload; audit moduleKey "system", entityType
// core_provinsi/core_kota/core_kecamatan/core_kelurahan; entityId baris baru
// = entity_id DDL (gen_random_uuid). Race uq_*_kode_hidup (23505) → 409
// WLY-004. Guard bisnis murni (prefix anak WLY-001, versi bentrok WLY-002,
// duplikat WLY-004, child WLY-003, tidak ditemukan WLY-005) di domain/.
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/domain"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/types"
)

// WilayahAdminService — CRUD 4 level MASTER wilayah.
type WilayahAdminService struct {
	db    *database.DB
	audit *audit.Service
	repo  *repository.WilayahAdminRepository
}

// NewWilayahAdminService membuat service admin wilayah.
func NewWilayahAdminService(db *database.DB, aud *audit.Service) *WilayahAdminService {
	return &WilayahAdminService{db: db, audit: aud, repo: repository.NewWilayahAdminRepository()}
}

// ---------------------------------------------------------------------
// Provinsi
// ---------------------------------------------------------------------

// CreateProvinsi — kode 2 digit unik hidup (409 WLY-004 bila duplikat).
func (s *WilayahAdminService) CreateProvinsi(ctx context.Context, in types.WilayahProvinsiBuat, actor audit.Actor) (types.WilayahProvinsiView, error) {
	var out types.WilayahProvinsiView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		dup, err := s.repo.CariKodeHidupProvinsi(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dup {
			return domain.ErrDuplikat("Provinsi", in.Kode)
		}
		row, err := s.repo.InsertProvinsi(ctx, tx, in.Kode, in.Nama)
		if err != nil {
			// Race uq_core_provinsi_kode_hidup (baris hidup lain menyambar kode).
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Provinsi", in.Kode)
			}
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_provinsi",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.WilayahProvinsiView{ID: row.ID, Kode: row.Kode, Nama: row.Nama, Version: row.Version}
		return nil
	})
	return out, err
}

// UpdateProvinsi — nama bebas; kode hanya bila TANPA child kota hidup
// (422 WLY-001 "ubah child lebih dulu"); version WAJIB (WLY-002).
func (s *WilayahAdminService) UpdateProvinsi(ctx context.Context, id int64, in types.WilayahProvinsiUbah, actor audit.Actor) (types.WilayahProvinsiView, error) {
	var out types.WilayahProvinsiView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertProvinsiAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Provinsi", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		kodeBaru := row.Kode
		if in.Kode != nil {
			kodeBaru = *in.Kode
		}
		if kodeBaru != row.Kode {
			n, err := s.repo.HitungKotaHidup(ctx, tx, id)
			if err != nil {
				return err
			}
			if n > 0 {
				return domain.TolakKodeDipakaiChild("Provinsi", row.Kode, n, "kota")
			}
		}
		namaBaru := row.Nama
		if in.Nama != nil {
			namaBaru = *in.Nama
		}
		updated, err := s.repo.UpdateProvinsi(ctx, tx, repository.ProvinsiUbahSet{
			ID:          id,
			VersiServer: row.Version,
			Kode:        kodeBaru,
			Nama:        namaBaru,
			Version:     row.Version + 1,
			UpdatedAt:   time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Provinsi", kodeBaru)
			}
			return err
		}
		if updated == nil {
			// Version berubah di antara baca & tulis (race) — muat ulang dulu.
			return domain.ErrVersi("Provinsi", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_provinsi",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
				AfterValue:  audit.Snapshot{"kode": updated.Kode, "nama": updated.Nama, "version": updated.Version},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.WilayahProvinsiView{ID: updated.ID, Kode: updated.Kode, Nama: updated.Nama, Version: updated.Version}
		return nil
	})
	return out, err
}

// DeleteProvinsi — soft delete; ditolak 409 WLY-003 bila masih punya kota
// hidup (FK RESTRICT juga menahan hard-delete; referensi daerah nonaktif =
// deleted_at, bukan hapus — K-10).
func (s *WilayahAdminService) DeleteProvinsi(ctx context.Context, id int64, in types.WilayahHapus, actor audit.Actor) (types.OkTrue, error) {
	var out types.OkTrue
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertProvinsiAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Provinsi", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		n, err := s.repo.HitungKotaHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if n > 0 {
			return domain.ErrChildHidup("Provinsi", row.Nama, n, "kota")
		}
		ok, err := s.repo.SoftDeleteProvinsi(ctx, tx, id, row.Version, time.Now())
		if err != nil {
			return err
		}
		if !ok {
			return domain.ErrVersi("Provinsi", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_provinsi",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
				AfterValue:  audit.Snapshot{"deleted": true, "version": row.Version + 1},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.OkTrue{Ok: true}
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------
// Kota (kabupaten/kota)
// ---------------------------------------------------------------------

// CreateKota — parent wajib ada (404 WLY-005); kode = prefix provinsi (422).
func (s *WilayahAdminService) CreateKota(ctx context.Context, in types.WilayahKotaBuat, actor audit.Actor) (types.WilayahKotaView, error) {
	var out types.WilayahKotaView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		provinsi, err := s.repo.AssertProvinsiAda(ctx, tx, in.IDCoreProvinsi)
		if err != nil {
			return err
		}
		if err := domain.TolakPrefixAnak("Kota", in.Kode, "provinsi", provinsi.Kode); err != nil {
			return err
		}
		dup, err := s.repo.CariKodeHidupKota(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dup {
			return domain.ErrDuplikat("Kota", in.Kode)
		}
		row, err := s.repo.InsertKota(ctx, tx, in.Kode, in.Nama, in.Jenis, in.IDCoreProvinsi)
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kota", in.Kode)
			}
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kota",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"kode":           row.Kode,
					"nama":           row.Nama,
					"jenis":          row.Jenis,
					"idCoreProvinsi": row.IDCoreProvinsi,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		// CHECK ck_core_kota_jenis menjamin 'KOTA' | 'KABUPATEN'.
		out = types.WilayahKotaView{
			ID:             row.ID,
			Kode:           row.Kode,
			Nama:           row.Nama,
			Jenis:          row.Jenis,
			IDCoreProvinsi: row.IDCoreProvinsi,
			ProvinsiNama:   provinsi.Nama,
			Version:        row.Version,
		}
		return nil
	})
	return out, err
}

// UpdateKota — nama/jenis bebas; pindah parent atau ubah kode → parent baru
// wajib ada + prefix tetap; kode hanya bila TANPA child kecamatan hidup.
func (s *WilayahAdminService) UpdateKota(ctx context.Context, id int64, in types.WilayahKotaUbah, actor audit.Actor) (types.WilayahKotaView, error) {
	var out types.WilayahKotaView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKotaAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kota", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		idProvinsiTarget := row.IDCoreProvinsi
		if in.IDCoreProvinsi != nil {
			idProvinsiTarget = *in.IDCoreProvinsi
		}
		provinsi, err := s.repo.AssertProvinsiAda(ctx, tx, idProvinsiTarget)
		if err != nil {
			return err
		}
		kodeBaru := row.Kode
		if in.Kode != nil {
			kodeBaru = *in.Kode
		}
		if err := domain.TolakPrefixAnak("Kota", kodeBaru, "provinsi", provinsi.Kode); err != nil {
			return err
		}
		if kodeBaru != row.Kode {
			n, err := s.repo.HitungKecamatanHidup(ctx, tx, id)
			if err != nil {
				return err
			}
			if n > 0 {
				return domain.TolakKodeDipakaiChild("Kota", row.Kode, n, "kecamatan")
			}
		}
		updated, err := s.repo.UpdateKota(ctx, tx, repository.KotaUbahSet{
			ID:             id,
			VersiServer:    row.Version,
			Kode:           kodeBaru,
			Nama:           pilihTeks(in.Nama, row.Nama),
			Jenis:          pilihTeks(in.Jenis, row.Jenis),
			IDCoreProvinsi: idProvinsiTarget,
			Version:        row.Version + 1,
			UpdatedAt:      time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kota", kodeBaru)
			}
			return err
		}
		if updated == nil {
			return domain.ErrVersi("Kota", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kota",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				BeforeValue: audit.Snapshot{
					"kode":           row.Kode,
					"nama":           row.Nama,
					"jenis":          row.Jenis,
					"idCoreProvinsi": row.IDCoreProvinsi,
				},
				AfterValue: audit.Snapshot{
					"kode":           updated.Kode,
					"nama":           updated.Nama,
					"jenis":          updated.Jenis,
					"idCoreProvinsi": updated.IDCoreProvinsi,
					"version":        updated.Version,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out, err = s.repo.MuatKotaView(ctx, tx, id)
		return err
	})
	return out, err
}

// DeleteKota — soft delete; ditolak 409 WLY-003 bila masih punya kecamatan hidup.
func (s *WilayahAdminService) DeleteKota(ctx context.Context, id int64, in types.WilayahHapus, actor audit.Actor) (types.OkTrue, error) {
	var out types.OkTrue
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKotaAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kota", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		n, err := s.repo.HitungKecamatanHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if n > 0 {
			return domain.ErrChildHidup("Kota", row.Nama, n, "kecamatan")
		}
		ok, err := s.repo.SoftDeleteKota(ctx, tx, id, row.Version, time.Now())
		if err != nil {
			return err
		}
		if !ok {
			return domain.ErrVersi("Kota", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_kota",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
				AfterValue:  audit.Snapshot{"deleted": true, "version": row.Version + 1},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.OkTrue{Ok: true}
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------
// Kecamatan
// ---------------------------------------------------------------------

// CreateKecamatan — parent wajib ada (404 WLY-005); kode = prefix kota (422).
func (s *WilayahAdminService) CreateKecamatan(ctx context.Context, in types.WilayahKecamatanBuat, actor audit.Actor) (types.WilayahKecamatanView, error) {
	var out types.WilayahKecamatanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		kota, err := s.repo.AssertKotaAda(ctx, tx, in.IDCoreKota)
		if err != nil {
			return err
		}
		if err := domain.TolakPrefixAnak("Kecamatan", in.Kode, "kota", kota.Kode); err != nil {
			return err
		}
		dup, err := s.repo.CariKodeHidupKecamatan(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dup {
			return domain.ErrDuplikat("Kecamatan", in.Kode)
		}
		row, err := s.repo.InsertKecamatan(ctx, tx, in.Kode, in.Nama, in.IDCoreKota)
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kecamatan", in.Kode)
			}
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kecamatan",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"kode":       row.Kode,
					"nama":       row.Nama,
					"idCoreKota": row.IDCoreKota,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.WilayahKecamatanView{
			ID:         row.ID,
			Kode:       row.Kode,
			Nama:       row.Nama,
			IDCoreKota: row.IDCoreKota,
			KotaNama:   kota.Nama,
			Version:    row.Version,
		}
		return nil
	})
	return out, err
}

// UpdateKecamatan — pindah kota/ubah kode → prefix tetap; kode hanya bila
// TANPA child kelurahan hidup.
func (s *WilayahAdminService) UpdateKecamatan(ctx context.Context, id int64, in types.WilayahKecamatanUbah, actor audit.Actor) (types.WilayahKecamatanView, error) {
	var out types.WilayahKecamatanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKecamatanAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kecamatan", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		idKotaTarget := row.IDCoreKota
		if in.IDCoreKota != nil {
			idKotaTarget = *in.IDCoreKota
		}
		kota, err := s.repo.AssertKotaAda(ctx, tx, idKotaTarget)
		if err != nil {
			return err
		}
		kodeBaru := row.Kode
		if in.Kode != nil {
			kodeBaru = *in.Kode
		}
		if err := domain.TolakPrefixAnak("Kecamatan", kodeBaru, "kota", kota.Kode); err != nil {
			return err
		}
		if kodeBaru != row.Kode {
			n, err := s.repo.HitungKelurahanHidup(ctx, tx, id)
			if err != nil {
				return err
			}
			if n > 0 {
				return domain.TolakKodeDipakaiChild("Kecamatan", row.Kode, n, "kelurahan")
			}
		}
		updated, err := s.repo.UpdateKecamatan(ctx, tx, repository.KecamatanUbahSet{
			ID:          id,
			VersiServer: row.Version,
			Kode:        kodeBaru,
			Nama:        pilihTeks(in.Nama, row.Nama),
			IDCoreKota:  idKotaTarget,
			Version:     row.Version + 1,
			UpdatedAt:   time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kecamatan", kodeBaru)
			}
			return err
		}
		if updated == nil {
			return domain.ErrVersi("Kecamatan", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kecamatan",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				BeforeValue: audit.Snapshot{
					"kode":       row.Kode,
					"nama":       row.Nama,
					"idCoreKota": row.IDCoreKota,
				},
				AfterValue: audit.Snapshot{
					"kode":       updated.Kode,
					"nama":       updated.Nama,
					"idCoreKota": updated.IDCoreKota,
					"version":    updated.Version,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out, err = s.repo.MuatKecamatanView(ctx, tx, id)
		return err
	})
	return out, err
}

// DeleteKecamatan — soft delete; ditolak 409 WLY-003 bila masih punya
// kelurahan hidup.
func (s *WilayahAdminService) DeleteKecamatan(ctx context.Context, id int64, in types.WilayahHapus, actor audit.Actor) (types.OkTrue, error) {
	var out types.OkTrue
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKecamatanAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kecamatan", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		n, err := s.repo.HitungKelurahanHidup(ctx, tx, id)
		if err != nil {
			return err
		}
		if n > 0 {
			return domain.ErrChildHidup("Kecamatan", row.Nama, n, "kelurahan")
		}
		ok, err := s.repo.SoftDeleteKecamatan(ctx, tx, id, row.Version, time.Now())
		if err != nil {
			return err
		}
		if !ok {
			return domain.ErrVersi("Kecamatan", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_kecamatan",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
				AfterValue:  audit.Snapshot{"deleted": true, "version": row.Version + 1},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.OkTrue{Ok: true}
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------
// Kelurahan/desa — parent kecamatan; kode pos opsional
// ---------------------------------------------------------------------

// CreateKelurahan — parent wajib ada (404 WLY-005); kode = prefix kecamatan;
// kodePos opsional (NULL bila absen).
func (s *WilayahAdminService) CreateKelurahan(ctx context.Context, in types.WilayahKelurahanBuat, actor audit.Actor) (types.WilayahKelurahanView, error) {
	var out types.WilayahKelurahanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		kecamatan, err := s.repo.AssertKecamatanAda(ctx, tx, in.IDCoreKecamatan)
		if err != nil {
			return err
		}
		if err := domain.TolakPrefixAnak("Kelurahan", in.Kode, "kecamatan", kecamatan.Kode); err != nil {
			return err
		}
		dup, err := s.repo.CariKodeHidupKelurahan(ctx, tx, in.Kode)
		if err != nil {
			return err
		}
		if dup {
			return domain.ErrDuplikat("Kelurahan", in.Kode)
		}
		row, err := s.repo.InsertKelurahan(ctx, tx, in.Kode, in.Nama, in.KodePos, in.IDCoreKecamatan)
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kelurahan", in.Kode)
			}
			return err
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kelurahan",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"kode":            row.Kode,
					"nama":            row.Nama,
					"kodePos":         pgText(row.KodePos),
					"idCoreKecamatan": row.IDCoreKecamatan,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.WilayahKelurahanView{
			ID:              row.ID,
			Kode:            row.Kode,
			Nama:            row.Nama,
			KodePos:         pgText(row.KodePos),
			IDCoreKecamatan: row.IDCoreKecamatan,
			KecamatanNama:   kecamatan.Nama,
			Version:         row.Version,
		}
		return nil
	})
	return out, err
}

// UpdateKelurahan — tanpa child: kode/parent bebas (prefix tetap);
// kodePos: absen/"" mempertahankan, null menghapus.
func (s *WilayahAdminService) UpdateKelurahan(ctx context.Context, id int64, in types.WilayahKelurahanUbah, actor audit.Actor) (types.WilayahKelurahanView, error) {
	var out types.WilayahKelurahanView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKelurahanAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kelurahan", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		idKecamatanTarget := row.IDCoreKecamatan
		if in.IDCoreKecamatan != nil {
			idKecamatanTarget = *in.IDCoreKecamatan
		}
		kecamatan, err := s.repo.AssertKecamatanAda(ctx, tx, idKecamatanTarget)
		if err != nil {
			return err
		}
		kodeBaru := row.Kode
		if in.Kode != nil {
			kodeBaru = *in.Kode
		}
		if err := domain.TolakPrefixAnak("Kelurahan", kodeBaru, "kecamatan", kecamatan.Kode); err != nil {
			return err
		}
		// null = hapus kode pos; absen/"" = pertahankan (ternormalisasi handler).
		kodePosBaru := pgText(row.KodePos)
		if in.KodePosNull {
			kodePosBaru = nil
		} else if in.KodePos != nil {
			v := *in.KodePos
			kodePosBaru = &v
		}
		updated, err := s.repo.UpdateKelurahan(ctx, tx, repository.KelurahanUbahSet{
			ID:              id,
			VersiServer:     row.Version,
			Kode:            kodeBaru,
			Nama:            pilihTeks(in.Nama, row.Nama),
			KodePos:         kodePosBaru,
			IDCoreKecamatan: idKecamatanTarget,
			Version:         row.Version + 1,
			UpdatedAt:       time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return domain.ErrDuplikat("Kelurahan", kodeBaru)
			}
			return err
		}
		if updated == nil {
			return domain.ErrVersi("Kelurahan", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "core_kelurahan",
				EntityID:   fmt.Sprintf("%d", id),
				Action:     "update",
				BeforeValue: audit.Snapshot{
					"kode":            row.Kode,
					"nama":            row.Nama,
					"kodePos":         pgText(row.KodePos),
					"idCoreKecamatan": row.IDCoreKecamatan,
				},
				AfterValue: audit.Snapshot{
					"kode":            updated.Kode,
					"nama":            updated.Nama,
					"kodePos":         pgText(updated.KodePos),
					"idCoreKecamatan": updated.IDCoreKecamatan,
					"version":         updated.Version,
				},
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out, err = s.repo.MuatKelurahanView(ctx, tx, id)
		return err
	})
	return out, err
}

// DeleteKelurahan — level daun (tanpa child): langsung boleh.
func (s *WilayahAdminService) DeleteKelurahan(ctx context.Context, id int64, in types.WilayahHapus, actor audit.Actor) (types.OkTrue, error) {
	var out types.OkTrue
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.repo.AssertKelurahanAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if err := domain.VersiBentrok("Kelurahan", row.Kode, row.Version, in.Version); err != nil {
			return err
		}
		ok, err := s.repo.SoftDeleteKelurahan(ctx, tx, id, row.Version, time.Now())
		if err != nil {
			return err
		}
		if !ok {
			return domain.ErrVersi("Kelurahan", row.Kode, row.Version, nil)
		}
		_, err = s.audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "system",
				EntityType:  "core_kelurahan",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "nama": row.Nama},
				AfterValue:  audit.Snapshot{"deleted": true, "version": row.Version + 1},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		if err != nil {
			return err
		}
		out = types.OkTrue{Ok: true}
		return nil
	})
	return out, err
}

// ---------------------------------------------------------------------
// Helper kecil shared se-service
// ---------------------------------------------------------------------

// pilihTeks — nullish semantics PATCH: input != nil ? *input : row.
func pilihTeks(in *string, row string) string {
	if in != nil {
		return *in
	}
	return row
}

// pgText — pgtype.Text → *string (NULL → nil) untuk view/audit.
func pgText(v pgtype.Text) *string {
	if !v.Valid {
		return nil
	}
	out := v.String
	return &out
}
