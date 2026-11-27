// service/wilayah.go — fitur WILAYAH (lookup referensi wilayah Indonesia,
// READ-ONLY — tanpa mutasi apa pun, TANPA uow/audit): SATU pintu delegasi
// baca non-transaksi — padanan WilayahService NestJS. Parsing query
// (PageRequest + sort whitelist/alias + filter induk berjenjang) di sini;
// executor pool diteruskan repository.
package service

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/core/repository"
	"nexierp/internal/modules/core/shared"
	"nexierp/internal/modules/core/types"
)

// WilayahService — lookup baca-saja (baca non-transaksi lewat pool).
type WilayahService struct {
	db   *database.DB
	repo *repository.WilayahRepository
}

// NewWilayahService membuat service lookup (repository internal).
func NewWilayahService(db *database.DB) *WilayahService {
	return &WilayahService{db: db, repo: repository.NewWilayahRepository()}
}

// whitelist sort lookup wilayah — alias snake/camel satu kolom
// (padanan sortWilayah NestJS).
var sortWilayahAllowed = []string{"nama", "kode", "created_at", "createdAt", "updated_at", "updatedAt"}

// kanonikWilayah — alias → nama kolom kanonik untuk ORDER BY SQL.
var kanonikWilayah = map[string]string{
	"nama":       "nama",
	"kode":       "kode",
	"created_at": "created_at",
	"createdAt":  "created_at",
	"updated_at": "updated_at",
	"updatedAt":  "updated_at",
}

// wilayahListQuery — parse query seragam lookup: PageRequest (default
// page 1/limit 20, clamp 200) + whitelist sort + filter search.
func wilayahListQuery(q url.Values) (*errkontrak.PageRequest, *repository.ListQuery, error) {
	pr, err := errkontrak.ParsePageRequest(q)
	if err != nil {
		return nil, nil, err
	}
	if err := shared.SortUnknown(pr, sortWilayahAllowed); err != nil {
		return nil, nil, err
	}
	lq := &repository.ListQuery{SortCol: "", Limit: int32(pr.Limit), Offset: int32(pr.Offset)}
	if len(pr.Sort) > 0 {
		lq.SortCol = kanonikWilayah[pr.Sort[0].Field]
		lq.SortDesc = pr.Sort[0].Desc
	}
	if s := pr.Filters["search"]; s != "" {
		v := s
		lq.Search = &v
	}
	return pr, lq, nil
}

// parseFilterId — filter induk berjenjang WAJIB terisi (400 VAL-400 bila
// kosong) dan harus bilangan bulat >= 1 (padanan parseFilterId NestJS).
func parseFilterId(raw string, field string) (int64, error) {
	if raw == "" {
		return 0, errkontrak.Validation([]errkontrak.FieldIssue{
			{
				Field:   "filter[" + field + "]",
				Message: fmt.Sprintf("Wajib diisi — lookup berjenjang tanpa konteks induk ditolak (mis. ?filter[%s]=1).", field),
			},
		})
	}
	// padanan Number(raw): pecahan/teks → 400.
	var n float64
	if _, err := fmt.Sscanf(strings.TrimSpace(raw), "%g", &n); err != nil || n != float64(int64(n)) || n < 1 {
		return 0, errkontrak.Validation([]errkontrak.FieldIssue{
			{
				Field:   "filter[" + field + "]",
				Message: fmt.Sprintf("Harus bilangan bulat >= 1 (diterima: %s).", raw),
			},
		})
	}
	return int64(n), nil
}

// parseJenisKota — filter jenis opsional dibatasi KOTA/KABUPATEN.
func parseJenisKota(raw string) (*string, error) {
	if raw == "" {
		return nil, nil
	}
	if raw != types.JenisKota && raw != types.JenisKabupaten {
		return nil, errkontrak.Validation([]errkontrak.FieldIssue{
			{
				Field:   "filter[jenis]",
				Message: fmt.Sprintf("Harus KOTA / KABUPATEN (diterima: %s).", raw),
			},
		})
	}
	v := raw
	return &v, nil
}

// ---------------------------------------------------------------------
// Provinsi
// ---------------------------------------------------------------------

// ListProvinsi — filter ?search= nama; sort whitelist nama/kode/waktu.
func (s *WilayahService) ListProvinsi(ctx context.Context, q url.Values) (errkontrak.Page[types.WilayahProvinsiView], error) {
	pr, lq, err := wilayahListQuery(q)
	if err != nil {
		return errkontrak.Page[types.WilayahProvinsiView]{}, err
	}
	rows, total, err := s.repo.ListProvinsi(ctx, s.db.Pool, *lq)
	if err != nil {
		return errkontrak.Page[types.WilayahProvinsiView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}

// GetProvinsi — satu provinsi hidup — 404 NOTF-404 bila absen.
func (s *WilayahService) GetProvinsi(ctx context.Context, id int64) (types.WilayahProvinsiView, error) {
	return s.repo.GetProvinsi(ctx, s.db.Pool, id)
}

// ---------------------------------------------------------------------
// Kota (kabupaten/kota)
// ---------------------------------------------------------------------

// ListKota — WAJIB ?filter[idProvinsi]= (400 bila kosong); filter[jenis]
// opsional; ?search= nama.
func (s *WilayahService) ListKota(ctx context.Context, q url.Values) (errkontrak.Page[types.WilayahKotaView], error) {
	pr, lq, err := wilayahListQuery(q)
	if err != nil {
		return errkontrak.Page[types.WilayahKotaView]{}, err
	}
	idProvinsi, err := parseFilterId(pr.Filters["idProvinsi"], "idProvinsi")
	if err != nil {
		return errkontrak.Page[types.WilayahKotaView]{}, err
	}
	jenis, err := parseJenisKota(pr.Filters["jenis"])
	if err != nil {
		return errkontrak.Page[types.WilayahKotaView]{}, err
	}
	rows, total, err := s.repo.ListKota(ctx, s.db.Pool, idProvinsi, jenis, *lq)
	if err != nil {
		return errkontrak.Page[types.WilayahKotaView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}

// GetKota — satu kota + nama provinsi — 404 bila absen.
func (s *WilayahService) GetKota(ctx context.Context, id int64) (types.WilayahKotaView, error) {
	return s.repo.GetKota(ctx, s.db.Pool, id)
}

// ---------------------------------------------------------------------
// Kecamatan
// ---------------------------------------------------------------------

// ListKecamatan — WAJIB ?filter[idKota]=; ?search= nama.
func (s *WilayahService) ListKecamatan(ctx context.Context, q url.Values) (errkontrak.Page[types.WilayahKecamatanView], error) {
	pr, lq, err := wilayahListQuery(q)
	if err != nil {
		return errkontrak.Page[types.WilayahKecamatanView]{}, err
	}
	idKota, err := parseFilterId(pr.Filters["idKota"], "idKota")
	if err != nil {
		return errkontrak.Page[types.WilayahKecamatanView]{}, err
	}
	rows, total, err := s.repo.ListKecamatan(ctx, s.db.Pool, idKota, *lq)
	if err != nil {
		return errkontrak.Page[types.WilayahKecamatanView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}

// GetKecamatan — satu kecamatan + nama kota — 404 bila absen.
func (s *WilayahService) GetKecamatan(ctx context.Context, id int64) (types.WilayahKecamatanView, error) {
	return s.repo.GetKecamatan(ctx, s.db.Pool, id)
}

// ---------------------------------------------------------------------
// Kelurahan/desa + kode pos
// ---------------------------------------------------------------------

// ListKelurahan — WAJIB ?filter[idKecamatan]=; filter[kodePos] opsional
// (persis); ?search= nama.
func (s *WilayahService) ListKelurahan(ctx context.Context, q url.Values) (errkontrak.Page[types.WilayahKelurahanView], error) {
	pr, lq, err := wilayahListQuery(q)
	if err != nil {
		return errkontrak.Page[types.WilayahKelurahanView]{}, err
	}
	idKecamatan, err := parseFilterId(pr.Filters["idKecamatan"], "idKecamatan")
	if err != nil {
		return errkontrak.Page[types.WilayahKelurahanView]{}, err
	}
	var kodePos *string
	if kp := pr.Filters["kodePos"]; kp != "" {
		v := kp
		kodePos = &v
	}
	rows, total, err := s.repo.ListKelurahan(ctx, s.db.Pool, idKecamatan, kodePos, *lq)
	if err != nil {
		return errkontrak.Page[types.WilayahKelurahanView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}

// GetKelurahan — satu kelurahan + rantai lengkap — 404 bila absen.
func (s *WilayahService) GetKelurahan(ctx context.Context, id int64) (types.WilayahKelurahanLengkapView, error) {
	return s.repo.GetKelurahan(ctx, s.db.Pool, id)
}

// ListKodePos — daftar kelurahan ber-kode pos persis (paged ringkas).
// Param kodePos sudah tervalidasi 5 digit di handler (VAL-400).
func (s *WilayahService) ListKodePos(ctx context.Context, kodePos string, q url.Values) (errkontrak.Page[types.WilayahKelurahanView], error) {
	pr, lq, err := wilayahListQuery(q)
	if err != nil {
		return errkontrak.Page[types.WilayahKelurahanView]{}, err
	}
	rows, total, err := s.repo.ListKodePos(ctx, s.db.Pool, kodePos, *lq)
	if err != nil {
		return errkontrak.Page[types.WilayahKelurahanView]{}, err
	}
	return errkontrak.BuildPage(rows, int(total), pr), nil
}
