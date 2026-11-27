// service/jenis_operasi.go — orkestrasi fitur JENIS OPERASI modul inv
// (padanan JenisOperasiService NestJS — patch 04 P1 #8, D-26; VERBATIM
// urutan langkah, pesan & kode): master alur operasi gudang RCV/DLV/TRF/
// ADJ/SCR — prefix penomoran + jumlah langkah 1..3 + lokasi default.
// Aturan verbatim sumber:
//   - soft delete semua query (`deleted_at IS NULL`);
//   - hapus diblokir bila masih dipakai gerakan (kode_jenis_operasi) —
//     409 INV-002;
//   - kode unik global di antara baris hidup (race 23505 → pesan sama);
//   - CHECK jumlah_langkah 1..3 + nama langkah wajib sesuai jumlah (DB);
//   - optimistic locking BODY `version` (STD-07) — beda → 409 INV-017
//     pre-check + atomic WHERE version;
//   - update TIDAK memvalidasi ulang refine langkah (quirk verbatim —
//     refine hanya di create-schema);
//   - resolver kode lokasi default = batch inArray TANPA filter deleted,
//     dibaca di POOL di dalam tx (verbatim).
package service

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/domain"
	"nexierp/internal/modules/inv/repository"
	"nexierp/internal/modules/inv/types"
)

// JenisOperasiService — dependensi kernel + repo jenis operasi.
type JenisOperasiService struct {
	DB    *database.DB
	Audit *audit.Service
	Repo  *repository.JenisOperasiRepository
}

// NewJenisOperasiService — wiring dari Deps modul (dipanggil handler).
func NewJenisOperasiService(d types.Deps) *JenisOperasiService {
	return &JenisOperasiService{DB: d.DB, Audit: d.Audit, Repo: repository.NewJenisOperasiRepository()}
}

// JenisOperasiCreateInput — body POST jenis operasi (hasil validasi handler;
// refine langkah 2/3 verbatim sudah dijaga schema).
type JenisOperasiCreateInput struct {
	Kode                  string
	Nama                  string
	JenisGerakan          string
	Prefix                string
	JumlahLangkah         int64
	NamaLangkah1          string
	NamaLangkah2          *string
	NamaLangkah3          *string
	IDLokasiSumberDefault *int64
	IDLokasiTujuanDefault *int64
	Status                string
}

// JenisOperasiUpdateInput — body PATCH jenis operasi (3-state nullish untuk
// namaLangkah2/3 & lokasi default — padanan `!== undefined`).
type JenisOperasiUpdateInput struct {
	Kode                     *string
	Nama                     *string
	JenisGerakan             string // "" = tidak dikirim
	Prefix                   *string
	JumlahLangkah            *int64
	NamaLangkah1             *string
	NamaLangkah2Ada          bool
	NamaLangkah2             *string
	NamaLangkah3Ada          bool
	NamaLangkah3             *string
	IDLokasiSumberDefaultAda bool
	IDLokasiSumberDefault    *int64
	IDLokasiTujuanDefaultAda bool
	IDLokasiTujuanDefault    *int64
	Status                   string // "" = tidak dikirim
	Version                  int64
}

/* -------------------------------------------------------------- */
/* Baca                                                            */
/* -------------------------------------------------------------- */

// List — daftar jenis operasi — filter jenisGerakan/status + search.
func (s *JenisOperasiService) List(ctx context.Context, pr *errkontrak.PageRequest) (errkontrak.Page[repository.JenisOperasiView], error) {
	return s.Repo.ListJenisOperasi(ctx, s.DB.Pool, pr)
}

// Get — detail jenis operasi — 404 INV-018.
func (s *JenisOperasiService) Get(ctx context.Context, id int64) (repository.JenisOperasiView, error) {
	row, err := s.Repo.MuatDetail(ctx, s.DB.Pool, id)
	if err != nil {
		return repository.JenisOperasiView{}, err
	}
	if row == nil {
		return repository.JenisOperasiView{}, errkontrak.NotFound(
			fmt.Sprintf("Jenis operasi id %d tidak ditemukan.", id),
			domain.KodeInvTidakDitemukan,
		)
	}
	return repository.JenisOperasiToView(row.J, row.KodeSumber, row.KodeTujuan), nil
}

/* -------------------------------------------------------------- */
/* Tulis                                                           */
/* -------------------------------------------------------------- */

// Create — buat jenis operasi — kode unik; CHECK langkah ditakeover DB.
func (s *JenisOperasiService) Create(ctx context.Context, in JenisOperasiCreateInput, actor audit.Actor) (repository.JenisOperasiView, error) {
	var view repository.JenisOperasiView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		if err := s.assertKodeBebas(ctx, tx, in.Kode, nil); err != nil {
			return err
		}
		row, err := s.Repo.InsertJenisOperasi(ctx, tx, repository.JenisOperasiBaru{
			EntityID:              numberingEntityID(),
			Kode:                  in.Kode,
			Nama:                  in.Nama,
			JenisGerakan:          in.JenisGerakan,
			Prefix:                in.Prefix,
			JumlahLangkah:         int32(in.JumlahLangkah),
			NamaLangkah1:          in.NamaLangkah1,
			NamaLangkah2:          in.NamaLangkah2,
			NamaLangkah3:          in.NamaLangkah3,
			IDLokasiSumberDefault: in.IDLokasiSumberDefault,
			IDLokasiTujuanDefault: in.IDLokasiTujuanDefault,
			Status:                in.Status,
		})
		if err != nil {
			// Race unik kode (uq) → 409 pesan pre-check sama (ratifikasi).
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode jenis operasi '%s' sudah dipakai.", in.Kode))
			}
			return err
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:  "inventory",
				EntityType: "inv_jenis_operasi",
				EntityID:   fmt.Sprintf("%d", row.ID),
				Action:     "create",
				AfterValue: audit.Snapshot{
					"kode":          row.Kode,
					"jenis_gerakan": row.JenisGerakan,
					"langkah":       row.JumlahLangkah,
				},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		view = repository.JenisOperasiToView(row, nil, nil)
		return nil
	})
	if err != nil {
		return repository.JenisOperasiView{}, err
	}
	return view, nil
}

// Update — ubah jenis operasi — versi wajib cocok (409 INV-017); ganti kode
// dicek bebas; TANPA validasi ulang refine langkah (quirk verbatim).
func (s *JenisOperasiService) Update(ctx context.Context, id int64, in JenisOperasiUpdateInput, actor audit.Actor) (repository.JenisOperasiView, error) {
	var view repository.JenisOperasiView
	err := s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertAda(ctx, tx, id)
		if err != nil {
			return err
		}
		if int64(row.Version) != in.Version {
			return versiJenisOperasiBentrok(row.Version, in.Version)
		}
		if in.Kode != nil && *in.Kode != row.Kode {
			if err := s.assertKodeBebas(ctx, tx, *in.Kode, &id); err != nil {
				return err
			}
		}
		updated, err := s.Repo.UpdateJenisOperasiHidup(ctx, tx, id, row.Version, repository.JenisOperasiUbahSet{
			Kode:                  mergeStr(in.Kode, row.Kode),
			Nama:                  mergeStr(in.Nama, row.Nama),
			JenisGerakan:          mergeStatus(in.JenisGerakan, row.JenisGerakan),
			Prefix:                mergeStr(in.Prefix, row.Prefix),
			JumlahLangkah:         mergeInt32(in.JumlahLangkah, row.JumlahLangkah),
			NamaLangkah1:          mergeStr(in.NamaLangkah1, row.NamaLangkah1),
			NamaLangkah2:          merge3(in.NamaLangkah2Ada, in.NamaLangkah2, row.NamaLangkah2),
			NamaLangkah3:          merge3(in.NamaLangkah3Ada, in.NamaLangkah3, row.NamaLangkah3),
			IDLokasiSumberDefault: merge3(in.IDLokasiSumberDefaultAda, in.IDLokasiSumberDefault, row.IDLokasiSumberDefault),
			IDLokasiTujuanDefault: merge3(in.IDLokasiTujuanDefaultAda, in.IDLokasiTujuanDefault, row.IDLokasiTujuanDefault),
			Status:                mergeStatus(in.Status, row.Status),
			Version:               row.Version + 1,
			UpdatedAt:             time.Now(),
		})
		if err != nil {
			if errkontrak.IsUniqueViolation(err) {
				return errkontrak.Conflict(fmt.Sprintf("Kode jenis operasi '%s' sudah dipakai.", row.Kode))
			}
			return err
		}
		if updated == nil {
			// Kalah balapan versi (0 baris) → 409 INV-017 lagi (ratifikasi).
			return versiJenisOperasiBentrok(row.Version, in.Version)
		}
		if _, err := s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_jenis_operasi",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "update",
				BeforeValue: audit.Snapshot{"kode": row.Kode, "version": row.Version},
				AfterValue:  audit.Snapshot{"kode": updated.Kode, "version": updated.Version},
			},
			Actor: actor,
		}}); err != nil {
			return err
		}
		// Resolver kode lokasi default — dibaca di POOL di dalam tx
		// (verbatim sumber memakai this.db), batch inArray TANPA filter
		// deleted.
		ref, err := s.Repo.ResolveKodeLokasiDefault(ctx, s.DB.Pool, *updated)
		if err != nil {
			return err
		}
		view = repository.JenisOperasiToView(*updated, ref.KodeSumber, ref.KodeTujuan)
		return nil
	})
	if err != nil {
		return repository.JenisOperasiView{}, err
	}
	return view, nil
}

// Remove — hapus lunak — blokir bila masih dipakai gerakan (409 INV-002).
func (s *JenisOperasiService) Remove(ctx context.Context, id int64, actor audit.Actor) error {
	return s.DB.Tx(ctx, func(tx pgx.Tx) error {
		row, err := s.Repo.AssertAda(ctx, tx, id)
		if err != nil {
			return err
		}
		dipakai, err := s.Repo.HitungGerakanPakai(ctx, tx, row.Kode)
		if err != nil {
			return err
		}
		if dipakai > 0 {
			return errkontrak.Conflict(
				fmt.Sprintf("Jenis operasi %s masih dipakai %d gerakan — tidak bisa dihapus, gunakan status NONAKTIF.", row.Kode, dipakai),
				domain.KodeInvHapusDiblokir,
			)
		}
		saat := time.Now()
		if err := s.Repo.HapusLunakJenisOperasi(ctx, tx, id, saat); err != nil {
			return err
		}
		_, err = s.Audit.Append(ctx, tx, []audit.AppendInput{{
			EntryInput: audit.EntryInput{
				ModuleKey:   "inventory",
				EntityType:  "inv_jenis_operasi",
				EntityID:    fmt.Sprintf("%d", id),
				Action:      "delete",
				BeforeValue: audit.Snapshot{"kode": row.Kode},
				Severity:    audit.SeverityWarning,
			},
			Actor: actor,
		}})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// assertKodeBebas — kode unik di antara baris hidup — 409 duplikat.
func (s *JenisOperasiService) assertKodeBebas(ctx context.Context, exec pgx.Tx, kode string, kecualiID *int64) error {
	dupe, err := s.Repo.CariDupeKode(ctx, exec, kode, kecualiID)
	if err != nil {
		return err
	}
	if dupe != nil {
		return errkontrak.Conflict(fmt.Sprintf("Kode jenis operasi '%s' sudah dipakai.", kode))
	}
	return nil
}

// versiJenisOperasiBentrok — 409 INV-017 pesan verbatim.
func versiJenisOperasiBentrok(server int32, kirim int64) error {
	return errkontrak.Conflict(
		fmt.Sprintf("Versi jenis operasi tidak cocok (server %d, kirim %d).", server, kirim),
		domain.KodeInvVersiBentrok,
	)
}

// mergeInt32 — padanan `input.x ?? row.x` utk angka opsional.
func mergeInt32(in *int64, lama int32) int32 {
	if in != nil {
		return int32(*in)
	}
	return lama
}
