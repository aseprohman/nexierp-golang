// MediaLibraryService — LIBRARY resmi unggah/unduh/hapus file untuk SEMUA
// modul (padanan services/media-library.service.ts NestJS). Satu jalur
// eksekusi upload:
//
//	validasi (scope, ukuran 8 MB, mime) → SHA-256 → StorageService.Put
//	(S3/MinIO) DULU → INSERT core_files + audit — dalam SATU transaksi DB.
//
// ATURAN STORAGE (direktif pemilik): fisik file HANYA di S3/MinIO; buffer
// in-memory; pembacaan lewat presigned URL / streaming same-origin.
//
// ddl/44: hapus = SOFT DELETE (deleted_at, version+1) — object MinIO SENGAJA
// tidak dihapus di sini (sweep terpisah, deferred); hapus kategori → file
// terkait di-SET NULL ("Tanpa kategori") — aset TIDAK pernah ikut terhapus.
package storage

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"strings"

	"github.com/jackc/pgx/v5"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/storage/repository"
)

// AuditSink — interface lokal untuk service audit (sedang ditulis terpisah;
// padanan AuditService.appendOne). Wiring dilakukan bootstrap via PasangAudit.
type AuditSink interface {
	AppendOne(ctx context.Context, exec pgx.Tx, e audit.AppendInput) (int64, error)
}

// MediaLibraryService — padanan MediaLibraryService NestJS; MURNI orkestrasi
// (validasi → S3 → tx → audit; urutan S3 DULU baru tx: gagal S3 = tanpa
// baris yatim di DB).
type MediaLibraryService struct {
	db      *database.DB
	storage *Service
	audit   AuditSink
}

// NewMediaLibraryService — audit dipasang terpisah via PasangAudit (wiring).
func NewMediaLibraryService(db *database.DB, st *Service) *MediaLibraryService {
	return &MediaLibraryService{db: db, storage: st}
}

// PasangAudit — pasang sink audit (wiring nanti oleh bootstrap).
func (s *MediaLibraryService) PasangAudit(a AuditSink) { s.audit = a }

/* -------------------------------------------------------------- */
/* Upload                                                          */
/* -------------------------------------------------------------- */

// Upload — simpan file (buffer/base64 → S3 → registry + audit, satu tx).
func (s *MediaLibraryService) Upload(ctx context.Context, in MediaUploadInput, actor audit.Actor) (FileView, error) {
	scope := strings.ToLower(strings.TrimSpace(in.Scope))
	if !ScopeValid(scope) {
		return FileView{}, errkontrak.Validation(
			[]errkontrak.FieldIssue{{Field: "scope", Message: fmt.Sprintf("Format scope tidak valid (diterima: %q).", in.Scope)}},
		)
	}
	if strings.TrimSpace(in.FileName) == "" {
		return FileView{}, errkontrak.Validation(
			[]errkontrak.FieldIssue{{Field: "fileName", Message: "Nama file wajib diisi."}},
		)
	}
	var buffer []byte
	if in.Buffer != nil {
		buffer = in.Buffer
	} else {
		// padanan Buffer.from(b64, "base64") — toleran; gagal decode = kosong.
		buffer, _ = base64.StdEncoding.DecodeString(in.DataBase64)
	}
	if len(buffer) == 0 {
		return FileView{}, errkontrak.Validation(
			[]errkontrak.FieldIssue{{Field: "dataBase64", Message: "Isi file kosong."}},
		)
	}
	if len(buffer) > MAX_FILE_BYTES {
		return FileView{}, &errkontrak.DomainError{
			Code:   "SYS-413",
			Status: 413,
			Detail: fmt.Sprintf("Ukuran file %d byte melebihi batas %d byte.", len(buffer), MAX_FILE_BYTES),
		}
	}
	mimeType := in.MimeType
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}
	mimeType = potongRunes(mimeType, 120)

	// ddl/44 — pemilik modul & kategori divalidasi SEBELUM S3 disentuh
	// (gagal cepat: FK tidak valid = 404 tanpa object yatim di MinIO).
	if in.IDCoreModules != nil {
		if err := s.assertModuleExists(ctx, s.db.Pool, *in.IDCoreModules); err != nil {
			return FileView{}, err
		}
	}
	if in.IDKategori != nil {
		if err := s.assertKategoriHidup(ctx, s.db.Pool, *in.IDKategori); err != nil {
			return FileView{}, err
		}
	}

	entityID := uuidV4()
	objectKey := fmt.Sprintf("%s/%s--%s", scope, entityID, SanitizeName(in.FileName))
	sum := sha256.Sum256(buffer)
	checksum := hex.EncodeToString(sum[:])

	// S3 dulu — gagal S3 = tidak ada baris registry (tanpa file yatim di DB).
	if _, err := s.storage.Put(ctx, objectKey, buffer, mimeType); err != nil {
		return FileView{}, err
	}

	var view FileView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := repository.InsertFile(ctx, tx, repository.FileInsert{
			EntityID:              entityID,
			Bucket:                s.storage.BucketName(),
			ObjectKey:             objectKey,
			OriginalName:          potongRunes(in.FileName, 200),
			MimeType:              mimeType,
			SizeBytes:             int64(len(buffer)),
			ChecksumSha256:        &checksum,
			Scope:                 scope,
			IDCoreUsers:           actor.IDCoreUsers,
			IDCoreModules:         in.IDCoreModules,
			IDCoreMediaCategories: in.IDKategori,
		})
		if err != nil {
			return err
		}
		_, err = s.appendAudit(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "iam_media_file",
				EntityID:   entityID,
				Action:     "create",
				AfterValue: audit.Snapshot{
					"fileName":      in.FileName,
					"scope":         scope,
					"sizeBytes":     len(buffer),
					"idCoreModules": nilaiOrNull(in.IDCoreModules),
					"idKategori":    nilaiOrNull(in.IDKategori),
				},
			},
			Actor: actor,
		})
		if err != nil {
			return err
		}
		view = ToFileView(row, &actor.ActorName)
		return nil
	})
	if err != nil {
		return FileView{}, err
	}
	return view, nil
}

/* -------------------------------------------------------------- */
/* Baca / unduh                                                    */
/* -------------------------------------------------------------- */

// ListFilesReq — filter daftar file (padanan req list NestJS).
type ListFilesReq struct {
	Page          *int
	Limit         *int
	Scope         string
	Search        string
	IDCoreModules *int64
	IDKategori    *int64 // 0 = sentinel "tanpa kategori"
}

// ListFilesResult — envelope list {data,total,page,limit}.
type ListFilesResult struct {
	Data  []FileView `json:"data"`
	Total int64      `json:"total"`
	Page  int        `json:"page"`
	Limit int        `json:"limit"`
}

// List — daftar file HIDUP (paginasi manual, terbaru dulu); soft-deleted tak
// pernah tampil.
func (s *MediaLibraryService) List(ctx context.Context, req ListFilesReq) (ListFilesResult, error) {
	page := 1
	if req.Page != nil && *req.Page > 0 {
		page = *req.Page
	}
	limit := 50
	if req.Limit != nil && *req.Limit > 0 {
		limit = *req.Limit
	}
	rows, total, err := repository.ListFiles(ctx, s.db.Pool, repository.FileFilter{
		Scope:         req.Scope,
		Search:        req.Search,
		IDCoreModules: req.IDCoreModules,
		IDKategori:    req.IDKategori,
		Limit:         int32(limit),
		Offset:        int32(page-1) * int32(limit),
	})
	if err != nil {
		return ListFilesResult{}, err
	}
	views := make([]FileView, 0, len(rows))
	for _, r := range rows {
		views = append(views, ToFileView(r.Baris, r.Uploader))
	}
	return ListFilesResult{Data: views, Total: total, Page: page, Limit: limit}, nil
}

// Get — ambil satu view registry HIDUP by entity_id ATAU id numerik;
// tidak ada → (nil, nil) (pemanggil memetakan ke 404 SYS-404).
func (s *MediaLibraryService) Get(ctx context.Context, fileRef string) (*FileView, error) {
	b, uploader, err := repository.FindByRef(ctx, s.db.Pool, fileRef)
	if err != nil || b == nil {
		return nil, err
	}
	view := ToFileView(*b, uploader)
	return &view, nil
}

// SignedURLOpts — opsi presign satu file.
type SignedURLOpts struct {
	Inline           bool
	ExpiresInSeconds int // 0 → 3600
}

// SignedURLView — hasil SignedURLOf.
type SignedURLView struct {
	ID        string    `json:"id"`
	FileID    int64     `json:"fileId"`
	Kind      MediaKind `json:"kind"`
	URL       string    `json:"url"`
	ExpiresIn int       `json:"expiresIn"`
}

// SignedURLOf — presigned URL GET (`Inline` untuk preview; default unduh).
// Signature mengikat host klien signing (MINIO_PUBLIC_ENDPOINT).
func (s *MediaLibraryService) SignedURLOf(ctx context.Context, fileRef string, opts SignedURLOpts) (*SignedURLView, error) {
	row, err := repository.GetRaw(ctx, s.db.Pool, fileRef)
	if err != nil || row == nil {
		return nil, err
	}
	expires := opts.ExpiresInSeconds
	if expires <= 0 {
		expires = 3600
	}
	url, err := s.storage.SignedGetURL(ctx, row.ObjectKey, Opts{
		ExpiresInSeconds: expires,
		Inline:           opts.Inline,
		FileName:         row.OriginalName,
	})
	if err != nil {
		return nil, err
	}
	return &SignedURLView{
		ID:        row.EntityID,
		FileID:    row.ID,
		Kind:      MediaKindOf(row.MimeType),
		URL:       url,
		ExpiresIn: expires,
	}, nil
}

// FileStream — hasil StreamOf (body dibungkus StreamableFile endpoint raw).
type FileStream struct {
	Body        io.ReadCloser
	ContentType string
	Size        *int64
	FileName    string
}

// StreamOf — stream object file HIDUP — jalur preview same-origin (endpoint
// `/system/files/:id/raw`): GetObject INTERNAL MinIO, TANPA presigned URL.
// nil bila baris tidak ada / soft-deleted (pemanggil → 404 SYS-404).
func (s *MediaLibraryService) StreamOf(ctx context.Context, fileRef string) (*FileStream, error) {
	row, err := repository.GetRaw(ctx, s.db.Pool, fileRef)
	if err != nil || row == nil {
		return nil, err
	}
	body, ct, size, err := s.storage.GetObjectInfo(ctx, row.ObjectKey)
	if err != nil {
		return nil, err
	}
	return &FileStream{Body: body, ContentType: ct, Size: size, FileName: row.OriginalName}, nil
}

/* -------------------------------------------------------------- */
/* Hapus file                                                      */
/* -------------------------------------------------------------- */

// Remove — hapus file = SOFT DELETE (ddl/44): deleted_at=now(), version+1
// DALAM tx + audit. Object MinIO SENGAJA tidak dihapus di sini (konsumen FK
// RESTRICT tetap hidup; fisik dibersihkan sweep terpisah). 404 bila tak ada.
func (s *MediaLibraryService) Remove(ctx context.Context, fileRef string, actor audit.Actor) error {
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := repository.GetRawForUpdate(ctx, tx, fileRef)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("File %q tidak ditemukan.", fileRef), "SYS-404")
		}
		updatedVersion, err := repository.SoftDeleteFile(ctx, tx, row.ID, row.Version+1)
		if err != nil {
			return err
		}
		versiAkhir := row.Version + 1
		if updatedVersion != nil {
			versiAkhir = *updatedVersion
		}
		_, err = s.appendAudit(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "iam_media_file",
				EntityID:   row.EntityID,
				Action:     "delete",
				BeforeValue: audit.Snapshot{
					"fileName": row.OriginalName,
					"scope":    row.Scope,
					"version":  row.Version,
				},
				AfterValue: audit.Snapshot{
					"fileName": row.OriginalName,
					"scope":    row.Scope,
					"version":  versiAkhir,
				},
			},
			Actor: actor,
		})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Kategori library (core_media_categories — ddl/44)               */
/* -------------------------------------------------------------- */

// ListKategori — daftar kategori HIDUP + jumlah file hidup per kategori;
// idCoreModules nil = semua (global NULL + milik modul apa pun).
func (s *MediaLibraryService) ListKategori(ctx context.Context, idCoreModules *int64) ([]MediaKategoriView, error) {
	rows, err := repository.ListKategori(ctx, s.db.Pool, idCoreModules)
	if err != nil {
		return nil, err
	}
	views := make([]MediaKategoriView, 0, len(rows))
	for _, r := range rows {
		views = append(views, ToKategoriView(r.Baris, r.JumlahFile))
	}
	return views, nil
}

// CreateKategori — tambah kategori; NULL modul = kategori bersama. Nama
// duplikat dalam lingkup modul yang sama → 409 NAMA_DIPAKAI (ditegakkan
// juga unique parsial DB sebagai jaring pengaman).
func (s *MediaLibraryService) CreateKategori(ctx context.Context, in MediaKategoriCreateInput, actor audit.Actor) (MediaKategoriView, error) {
	nama := strings.TrimSpace(in.Nama)
	if nama == "" {
		return MediaKategoriView{}, errkontrak.Validation(
			[]errkontrak.FieldIssue{{Field: "nama", Message: "Nama kategori wajib diisi."}},
		)
	}
	if in.IDCoreModules != nil {
		if err := s.assertModuleExists(ctx, s.db.Pool, *in.IDCoreModules); err != nil {
			return MediaKategoriView{}, err
		}
	}
	if err := s.assertNamaBebas(ctx, s.db.Pool, nama, in.IDCoreModules, 0); err != nil {
		return MediaKategoriView{}, err
	}
	var view MediaKategoriView
	err := s.db.Tx(ctx, func(tx pgx.Tx) error {
		entityID := uuidV4()
		row, err := repository.InsertKategori(ctx, tx, repository.KategoriInsert{
			EntityID:      entityID,
			IDCoreModules: in.IDCoreModules,
			Nama:          potongRunes(nama, 100),
			Keterangan:    TrimOrNull(in.Keterangan),
		})
		if err != nil {
			return err
		}
		_, err = s.appendAudit(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "iam_media_kategori",
				EntityID:   row.EntityID,
				Action:     "create",
				AfterValue: audit.Snapshot{
					"nama":          nama,
					"idCoreModules": nilaiOrNull(in.IDCoreModules),
				},
			},
			Actor: actor,
		})
		if err != nil {
			return err
		}
		view = ToKategoriView(row, 0)
		return nil
	})
	if err != nil {
		return MediaKategoriView{}, err
	}
	return view, nil
}

// UpdateKategori — ubah kategori; optimistic lock: version body ≠ version
// row → 409 VERSI_BENTROK. Sukses → version+1 + updatedAt=now() + audit.
func (s *MediaLibraryService) UpdateKategori(ctx context.Context, idRef string, in MediaKategoriUpdateInput, actor audit.Actor) (MediaKategoriView, error) {
	id, err := ParseNumericID(idRef, "id")
	if err != nil {
		return MediaKategoriView{}, err
	}
	var view MediaKategoriView
	err = s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := repository.GetKategoriHidupForUpdate(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Kategori %s tidak ditemukan.", idRef), "SYS-404")
		}
		if in.Version != row.Version {
			return errkontrak.Conflict(
				fmt.Sprintf(
					"Kategori %q sudah diubah pihak lain — version body (%d) ≠ version terkini (%d).",
					row.Nama, in.Version, row.Version,
				),
				"VERSI_BENTROK",
			)
		}
		// Modul target: field absen → pertahankan; null → NULL; ada nilai → validasi dulu.
		targetModul := row.IDCoreModules
		if in.IDCoreModules.Set && in.IDCoreModules.Value != nil &&
			(row.IDCoreModules == nil || *in.IDCoreModules.Value != *row.IDCoreModules) {
			if err := s.assertModuleExists(ctx, tx, *in.IDCoreModules.Value); err != nil {
				return err
			}
		}
		if in.IDCoreModules.Set {
			targetModul = in.IDCoreModules.Value
		}
		nama := row.Nama
		if in.Nama.Set {
			if in.Nama.Value != nil {
				nama = strings.TrimSpace(*in.Nama.Value)
			} else {
				nama = ""
			}
		}
		if nama == "" {
			return errkontrak.Validation(
				[]errkontrak.FieldIssue{{Field: "nama", Message: "Nama kategori wajib diisi."}},
			)
		}
		namaBerubah := nama != row.Nama
		modulBerubah := in.IDCoreModules.Set && !int64PtrEqual(targetModul, row.IDCoreModules)
		if namaBerubah || modulBerubah {
			if err := s.assertNamaBebas(ctx, tx, nama, targetModul, row.ID); err != nil {
				return err
			}
		}
		keterangan := row.Keterangan
		if in.Keterangan.Set {
			keterangan = TrimOrNull(in.Keterangan.Value)
		}
		updated, err := repository.UpdateKategori(ctx, tx, row.ID, repository.KategoriUpdate{
			Nama:          potongRunes(nama, 100),
			Keterangan:    keterangan,
			IDCoreModules: targetModul,
			Version:       row.Version + 1,
		})
		if err != nil {
			return err
		}
		if _, err := s.appendAudit(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "iam_media_kategori",
				EntityID:   row.EntityID,
				Action:     "update",
				BeforeValue: audit.Snapshot{
					"nama":          row.Nama,
					"keterangan":    nilaiStrOrNull(row.Keterangan),
					"idCoreModules": nilaiOrNull(row.IDCoreModules),
					"version":       row.Version,
				},
				AfterValue: audit.Snapshot{
					"nama":          updated.Nama,
					"keterangan":    nilaiStrOrNull(updated.Keterangan),
					"idCoreModules": nilaiOrNull(updated.IDCoreModules),
					"version":       updated.Version,
				},
			},
			Actor: actor,
		}); err != nil {
			return err
		}
		jumlahFile, err := repository.CountLiveFilesInKategori(ctx, tx, row.ID)
		if err != nil {
			return err
		}
		view = ToKategoriView(*updated, jumlahFile)
		return nil
	})
	if err != nil {
		return MediaKategoriView{}, err
	}
	return view, nil
}

// RemoveKategori — hapus kategori = SOFT DELETE + DALAM tx yang sama file
// hidup terkait di-SET NULL (jadi "Tanpa kategori") — aset TIDAK pernah ikut
// terhapus (ddl/44). 404 bila tak ada / sudah terhapus.
func (s *MediaLibraryService) RemoveKategori(ctx context.Context, idRef string, actor audit.Actor) error {
	id, err := ParseNumericID(idRef, "id")
	if err != nil {
		return err
	}
	return s.db.Tx(ctx, func(tx pgx.Tx) error {
		row, err := repository.GetKategoriHidupForUpdate(ctx, tx, id)
		if err != nil {
			return err
		}
		if row == nil {
			return errkontrak.NotFound(fmt.Sprintf("Kategori %s tidak ditemukan.", idRef), "SYS-404")
		}
		if err := repository.SoftDeleteKategori(ctx, tx, row.ID, row.Version+1); err != nil {
			return err
		}
		if err := repository.DetachFilesFromKategori(ctx, tx, row.ID); err != nil {
			return err
		}
		_, err = s.appendAudit(ctx, tx, audit.AppendInput{
			EntryInput: audit.EntryInput{
				ModuleKey:  "system",
				EntityType: "iam_media_kategori",
				EntityID:   row.EntityID,
				Action:     "delete",
				BeforeValue: audit.Snapshot{
					"nama":          row.Nama,
					"idCoreModules": nilaiOrNull(row.IDCoreModules),
					"version":       row.Version,
				},
			},
			Actor: actor,
		})
		return err
	})
}

/* -------------------------------------------------------------- */
/* Internal                                                        */
/* -------------------------------------------------------------- */

// appendAudit — delegasi ke sink audit; sink belum dipasang = error eksplisit.
func (s *MediaLibraryService) appendAudit(ctx context.Context, tx pgx.Tx, e audit.AppendInput) (int64, error) {
	if s.audit == nil {
		return 0, errkontrak.Internal("audit belum dipasang (PasangAudit) — wiring bootstrap.", "SYS-001")
	}
	return s.audit.AppendOne(ctx, tx, e)
}

// assertModuleExists — modul harus ada bila FK diisi (ddl/44) — 404 SYS-404.
func (s *MediaLibraryService) assertModuleExists(ctx context.Context, exec repository.DBTX, id int64) error {
	ada, err := repository.ModuleIDExists(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ada {
		return errkontrak.NotFound(fmt.Sprintf("Modul %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// assertKategoriHidup — kategori harus ada & hidup (deleted_at IS NULL).
func (s *MediaLibraryService) assertKategoriHidup(ctx context.Context, exec repository.DBTX, id int64) error {
	ada, err := repository.KategoriHidupAda(ctx, exec, id)
	if err != nil {
		return err
	}
	if !ada {
		return errkontrak.NotFound(fmt.Sprintf("Kategori %d tidak ditemukan.", id), "SYS-404")
	}
	return nil
}

// assertNamaBebas — nama kategori belum dipakai kategori HIDUP lain dalam
// lingkup modul yang sama (NULL = lingkup global) — 409 NAMA_DIPAKAI.
func (s *MediaLibraryService) assertNamaBebas(ctx context.Context, exec repository.DBTX, nama string, idCoreModules *int64, excludeID int64) error {
	dipakai, err := repository.KategoriNamaDipakai(ctx, exec, nama, idCoreModules, excludeID)
	if err != nil {
		return err
	}
	if dipakai {
		return errkontrak.Conflict(
			fmt.Sprintf("Nama kategori %q sudah dipakai dalam lingkup modul yang sama.", nama),
			"NAMA_DIPAKAI",
		)
	}
	return nil
}

/* -------------------------------------------------------------- */
/* Helper kecil (pure)                                             */
/* -------------------------------------------------------------- */

// potongRunes — potong aman rune (padanan .slice(0, n) JS utk nama/mime).
func potongRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// nilaiOrNull — *int64 → nilai JSON (nil = null) untuk snapshot audit.
func nilaiOrNull(v *int64) any {
	if v == nil {
		return nil
	}
	return *v
}

// nilaiStrOrNull — *string → nilai JSON (nil = null) untuk snapshot audit.
func nilaiStrOrNull(v *string) any {
	if v == nil {
		return nil
	}
	return *v
}

// int64PtrEqual — pembanding pointer int64 (nil == nil).
func int64PtrEqual(a, b *int64) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
