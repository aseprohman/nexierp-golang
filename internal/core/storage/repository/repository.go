// Package repository — SATU-SATUNYA pengguna schema `core_files` (ddl/01c+
// ddl/44) dan `core_media_categories` (ddl/44) di area storage kernel.
// Query sqlc dibungkus fungsi dengan executor eksplisit (pool pgx | pgx.Tx):
// operasi tulis selalu dipanggil service dengan tx, baca non-transaksi pakai
// pool. Baris pgtype dipetakan ke tipe Go polos di sini; row→View API ada di
// package storage (induk) — arah import turun saja.
package repository

import (
	"context"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/storage/repository/gen"
	"nexierp/internal/core/storage/repository/genfiles"
)

// DBTX — alias executor sqlc (pool maupun tx memenuhi).
type DBTX = genfiles.DBTX

// pgxErrNoRows — sentinel baris kosong (:one) dari pgx.
var pgxErrNoRows = pgx.ErrNoRows

// FileBaris — baris core_files mentah dengan tipe Go polos (padanan FileRow).
type FileBaris struct {
	ID                    int64
	EntityID              string
	Bucket                string
	ObjectKey             string
	OriginalName          string
	MimeType              string
	SizeBytes             int64
	ChecksumSha256        *string
	Scope                 string
	IDCoreUsers           *int64
	IDCoreModules         *int64
	IDCoreMediaCategories *int64
	Version               int32
	CreatedAt             time.Time
	UpdatedAt             time.Time
	DeletedAt             *time.Time
}

// KategoriBaris — baris core_media_categories mentah (padanan KategoriRow).
type KategoriBaris struct {
	ID            int64
	EntityID      string
	IDCoreModules *int64
	Nama          string
	Keterangan    *string
	Version       int32
	CreatedAt     time.Time
	UpdatedAt     time.Time
	DeletedAt     *time.Time
}

// FileDenganUploader — baris file + nama pengunggah (hasil join core_users).
type FileDenganUploader struct {
	Baris    FileBaris
	Uploader *string
}

// KategoriDenganJumlah — baris kategori + jumlah file hidup (badge FE).
type KategoriDenganJumlah struct {
	Baris      KategoriBaris
	JumlahFile int64
}

/* -------------------------------------------------------------- */
/* core_files                                                      */
/* -------------------------------------------------------------- */

// FileInsert — nilai INSERT core_files (dibangun service, dieksekusi repo).
type FileInsert struct {
	EntityID              string
	Bucket                string
	ObjectKey             string
	OriginalName          string
	MimeType              string
	SizeBytes             int64
	ChecksumSha256        *string
	Scope                 string
	IDCoreUsers           *int64
	IDCoreModules         *int64
	IDCoreMediaCategories *int64
}

// InsertFile — simpan baris registry file (SELALU dalam tx upload).
func InsertFile(ctx context.Context, exec DBTX, v FileInsert) (FileBaris, error) {
	row, err := genfiles.New(exec).InsertFile(ctx, genfiles.InsertFileParams{
		EntityID:              uuidParam(v.EntityID),
		Bucket:                v.Bucket,
		ObjectKey:             v.ObjectKey,
		OriginalName:          v.OriginalName,
		MimeType:              v.MimeType,
		SizeBytes:             v.SizeBytes,
		ChecksumSha256:        textNullable(v.ChecksumSha256),
		Scope:                 v.Scope,
		IDCoreUsers:           int8Nullable(v.IDCoreUsers),
		IDCoreModules:         int8Nullable(v.IDCoreModules),
		IDCoreMediaCategories: int8Nullable(v.IDCoreMediaCategories),
	})
	if err != nil {
		return FileBaris{}, err
	}
	return fileBaris(row), nil
}

// FileFilter — filter daftar file (padanan req list NestJS).
type FileFilter struct {
	Scope         string // "" = tanpa filter
	Search        string // "" = tanpa filter (ILIKE nama)
	IDCoreModules *int64 // nil/0 = tanpa filter
	IDKategori    *int64 // nil = tanpa filter; 0 = "tanpa kategori"; >0 = kategori itu
	Limit         int32
	Offset        int32
}

// ListFiles — daftar file HIDUP + nama pengunggah (paginasi manual,
// terbaru dulu) + total untuk paginasi.
func ListFiles(ctx context.Context, exec DBTX, f FileFilter) ([]FileDenganUploader, int64, error) {
	q := genfiles.New(exec)
	rows, err := q.ListFiles(ctx, genfiles.ListFilesParams{
		Scope:         textFilter(f.Scope),
		Search:        textFilter(f.Search),
		IDCoreModules: int8Filter(f.IDCoreModules),
		IDKategori:    int8Nullable(f.IDKategori),
		Limit:         f.Limit,
		Offset:        f.Offset,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := q.CountFiles(ctx, genfiles.CountFilesParams{
		Scope:         textFilter(f.Scope),
		Search:        textFilter(f.Search),
		IDCoreModules: int8Filter(f.IDCoreModules),
		IDKategori:    int8Nullable(f.IDKategori),
	})
	if err != nil {
		return nil, 0, err
	}
	out := make([]FileDenganUploader, 0, len(rows))
	for _, r := range rows {
		out = append(out, FileDenganUploader{
			Baris: fileBarisJoin(r.ID, r.EntityID, r.Bucket, r.ObjectKey, r.OriginalName,
				r.MimeType, r.SizeBytes, r.ChecksumSha256, r.Scope, r.IDCoreUsers,
				r.IDCoreModules, r.IDCoreMediaCategories, r.Version, r.CreatedAt,
				r.UpdatedAt, r.DeletedAt),
			Uploader: textPtr(r.UploaderName),
		})
	}
	return out, total, nil
}

// FindByRef — satu view registry HIDUP by id numerik ATAU entity_id uuid
// (padanan findByRef — numerik > 0 dianggap id); tidak ada → (nil, nil, nil).
func FindByRef(ctx context.Context, exec DBTX, fileRef string) (*FileBaris, *string, error) {
	q := genfiles.New(exec)
	id, byID := refIDLonggar(fileRef)
	var (
		b   FileBaris
		up  *string
		err error
	)
	if byID {
		var r genfiles.GetFileViewByIDRow
		r, err = q.GetFileViewByID(ctx, id)
		if err == nil {
			b = fileBarisJoin(r.ID, r.EntityID, r.Bucket, r.ObjectKey, r.OriginalName,
				r.MimeType, r.SizeBytes, r.ChecksumSha256, r.Scope, r.IDCoreUsers,
				r.IDCoreModules, r.IDCoreMediaCategories, r.Version, r.CreatedAt,
				r.UpdatedAt, r.DeletedAt)
			up = textPtr(r.UploaderName)
		}
	} else {
		var r genfiles.GetFileViewByEntityIDRow
		r, err = q.GetFileViewByEntityID(ctx, uuidParam(fileRef))
		if err == nil {
			b = fileBarisJoin(r.ID, r.EntityID, r.Bucket, r.ObjectKey, r.OriginalName,
				r.MimeType, r.SizeBytes, r.ChecksumSha256, r.Scope, r.IDCoreUsers,
				r.IDCoreModules, r.IDCoreMediaCategories, r.Version, r.CreatedAt,
				r.UpdatedAt, r.DeletedAt)
			up = textPtr(r.UploaderName)
		}
	}
	if err != nil {
		if err == pgxErrNoRows {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	return &b, up, nil
}

// GetRaw — baris mentah registry HIDUP by id/entity_id (untuk sign/stream);
// ref ketat: string numerik > 0 persis → id, selain itu entity_id.
func GetRaw(ctx context.Context, exec DBTX, fileRef string) (*FileBaris, error) {
	return getRawBy(ctx, exec, fileRef, false)
}

// GetRawForUpdate — baris mentah HIDUP + kunci baris FOR UPDATE (hapus).
func GetRawForUpdate(ctx context.Context, exec DBTX, fileRef string) (*FileBaris, error) {
	return getRawBy(ctx, exec, fileRef, true)
}

// SoftDeleteFile — SOFT DELETE (ddl/44): deleted_at=now(), version+1;
// kembalikan version baru.
func SoftDeleteFile(ctx context.Context, exec DBTX, id int64, nextVersion int32) (*int32, error) {
	v, err := genfiles.New(exec).SoftDeleteFile(ctx, genfiles.SoftDeleteFileParams{
		ID:      id,
		Version: nextVersion,
	})
	if err != nil {
		return nil, err
	}
	return &v, nil
}

// ModuleIDExists — lookup FK pemilik modul (ddl/44): id core_modules ada?
func ModuleIDExists(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := genfiles.New(exec).ModuleIDExists(ctx, id)
	if err != nil {
		if err == pgxErrNoRows {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

/* -------------------------------------------------------------- */
/* core_media_categories                                           */
/* -------------------------------------------------------------- */

// KategoriInsert — nilai INSERT core_media_categories.
type KategoriInsert struct {
	EntityID      string
	IDCoreModules *int64
	Nama          string
	Keterangan    *string
}

// ListKategori — daftar kategori HIDUP + jumlah file hidup per kategori;
// idCoreModules nil = semua (global NULL + milik modul apa pun).
func ListKategori(ctx context.Context, exec DBTX, idCoreModules *int64) ([]KategoriDenganJumlah, error) {
	rows, err := gen.New(exec).ListKategori(ctx, int8Nullable(idCoreModules))
	if err != nil {
		return nil, err
	}
	out := make([]KategoriDenganJumlah, 0, len(rows))
	for _, r := range rows {
		out = append(out, KategoriDenganJumlah{
			Baris: kategoriBarisJoin(r.ID, r.EntityID, r.IDCoreModules, r.Nama,
				r.Keterangan, r.Version, r.CreatedAt, r.UpdatedAt, r.DeletedAt),
			JumlahFile: int64(r.JumlahFile),
		})
	}
	return out, nil
}

// InsertKategori — simpan kategori baru (SELALU dalam tx create).
func InsertKategori(ctx context.Context, exec DBTX, v KategoriInsert) (KategoriBaris, error) {
	row, err := gen.New(exec).InsertKategori(ctx, gen.InsertKategoriParams{
		EntityID:      uuidParam(v.EntityID),
		IDCoreModules: int8Nullable(v.IDCoreModules),
		Nama:          v.Nama,
		Keterangan:    textNullable(v.Keterangan),
	})
	if err != nil {
		return KategoriBaris{}, err
	}
	return kategoriBaris(row), nil
}

// GetKategoriHidupForUpdate — kategori HIDUP + kunci baris FOR UPDATE;
// tidak ada → (nil, nil).
func GetKategoriHidupForUpdate(ctx context.Context, exec DBTX, id int64) (*KategoriBaris, error) {
	row, err := gen.New(exec).GetKategoriHidupForUpdate(ctx, id)
	if err != nil {
		if err == pgxErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	b := kategoriBaris(row)
	return &b, nil
}

// KategoriUpdate — nilai ubah kategori (dibangun service, optimistic lock).
type KategoriUpdate struct {
	Nama          string
	Keterangan    *string
	IDCoreModules *int64
	Version       int32
}

// UpdateKategori — eksekusi ubah kategori; kembalikan baris terbaru.
func UpdateKategori(ctx context.Context, exec DBTX, id int64, v KategoriUpdate) (*KategoriBaris, error) {
	row, err := gen.New(exec).UpdateKategori(ctx, gen.UpdateKategoriParams{
		ID:            id,
		Nama:          v.Nama,
		Keterangan:    textNullable(v.Keterangan),
		IDCoreModules: int8Nullable(v.IDCoreModules),
		Version:       v.Version,
	})
	if err != nil {
		return nil, err
	}
	b := kategoriBaris(row)
	return &b, nil
}

// SoftDeleteKategori — SOFT DELETE kategori: deleted_at=now(), version+1.
func SoftDeleteKategori(ctx context.Context, exec DBTX, id int64, nextVersion int32) error {
	return gen.New(exec).SoftDeleteKategori(ctx, gen.SoftDeleteKategoriParams{
		ID:      id,
		Version: nextVersion,
	})
}

// DetachFilesFromKategori — core_files terkait di-SET NULL → "Tanpa
// kategori"; aset TIDAK pernah ikut terhapus (ddl/44).
func DetachFilesFromKategori(ctx context.Context, exec DBTX, idKategori int64) error {
	return gen.New(exec).DetachFilesFromKategori(ctx, int8Value(idKategori))
}

// KategoriHidupAda — kategori ada & HIDUP (deleted_at IS NULL)?
func KategoriHidupAda(ctx context.Context, exec DBTX, id int64) (bool, error) {
	_, err := gen.New(exec).KategoriHidupAda(ctx, id)
	if err != nil {
		if err == pgxErrNoRows {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// KategoriNamaDipakai — nama sudah dipakai kategori HIDUP lain dalam
// lingkup modul yang sama (NULL modul = global)? excludeID 0 = tanpa exclude.
func KategoriNamaDipakai(ctx context.Context, exec DBTX, nama string, idCoreModules *int64, excludeID int64) (bool, error) {
	_, err := gen.New(exec).KategoriNamaDipakai(ctx, gen.KategoriNamaDipakaiParams{
		Nama:          nama,
		IDCoreModules: int8Nullable(idCoreModules),
		ExcludeID:     excludeID,
	})
	if err != nil {
		if err == pgxErrNoRows {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// CountLiveFilesInKategori — jumlah file HIDUP dalam satu kategori.
func CountLiveFilesInKategori(ctx context.Context, exec DBTX, idKategori int64) (int64, error) {
	n, err := gen.New(exec).CountLiveFilesInKategori(ctx, int8Value(idKategori))
	if err != nil {
		return 0, err
	}
	return int64(n), nil
}

/* -------------------------------------------------------------- */
/* Internal helpers                                                */
/* -------------------------------------------------------------- */

// refIDLonggar — padanan findByRef: numerik > 0 → by id (longgar).
func refIDLonggar(ref string) (int64, bool) {
	n, err := strconv.ParseInt(ref, 10, 64)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// refIDKetat — padanan getRaw/getRawForUpdate: numerik > 0 DAN representasi
// string identik (guard "007" → entity_id).
func refIDKetat(ref string) (int64, bool) {
	n, ok := refIDLonggar(ref)
	if !ok || strconv.FormatInt(n, 10) != ref {
		return 0, false
	}
	return n, true
}

func getRawBy(ctx context.Context, exec DBTX, fileRef string, forUpdate bool) (*FileBaris, error) {
	id, byID := refIDKetat(fileRef)
	q := genfiles.New(exec)
	var (
		row genfiles.CoreFile
		err error
	)
	switch {
	case forUpdate && byID:
		row, err = q.GetFileRawForUpdateByID(ctx, id)
	case forUpdate:
		row, err = q.GetFileRawForUpdateByEntityID(ctx, uuidParam(fileRef))
	case byID:
		row, err = q.GetFileRawByID(ctx, id)
	default:
		row, err = q.GetFileRawByEntityID(ctx, uuidParam(fileRef))
	}
	if err != nil {
		if err == pgxErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	b := fileBaris(row)
	return &b, nil
}

func fileBaris(r genfiles.CoreFile) FileBaris {
	return FileBaris{
		ID:                    r.ID,
		EntityID:              uuidVal(r.EntityID),
		Bucket:                r.Bucket,
		ObjectKey:             r.ObjectKey,
		OriginalName:          r.OriginalName,
		MimeType:              r.MimeType,
		SizeBytes:             r.SizeBytes,
		ChecksumSha256:        textPtr(r.ChecksumSha256),
		Scope:                 r.Scope,
		IDCoreUsers:           int8Ptr(r.IDCoreUsers),
		IDCoreModules:         int8Ptr(r.IDCoreModules),
		IDCoreMediaCategories: int8Ptr(r.IDCoreMediaCategories),
		Version:               r.Version,
		CreatedAt:             timeVal(r.CreatedAt),
		UpdatedAt:             timeVal(r.UpdatedAt),
		DeletedAt:             timePtr(r.DeletedAt),
	}
}

// fileBarisJoin — mapper baris join (kolom core_files + uploader flat).
func fileBarisJoin(
	id int64, entityID pgtype.UUID, bucket, objectKey, originalName, mimeType string,
	sizeBytes int64, checksum pgtype.Text, scope string,
	idUsers, idModules, idKategori pgtype.Int8, version int32,
	createdAt, updatedAt, deletedAt pgtype.Timestamptz,
) FileBaris {
	return FileBaris{
		ID:                    id,
		EntityID:              uuidVal(entityID),
		Bucket:                bucket,
		ObjectKey:             objectKey,
		OriginalName:          originalName,
		MimeType:              mimeType,
		SizeBytes:             sizeBytes,
		ChecksumSha256:        textPtr(checksum),
		Scope:                 scope,
		IDCoreUsers:           int8Ptr(idUsers),
		IDCoreModules:         int8Ptr(idModules),
		IDCoreMediaCategories: int8Ptr(idKategori),
		Version:               version,
		CreatedAt:             timeVal(createdAt),
		UpdatedAt:             timeVal(updatedAt),
		DeletedAt:             timePtr(deletedAt),
	}
}

func kategoriBaris(r gen.CoreMediaCategory) KategoriBaris {
	return KategoriBaris{
		ID:            r.ID,
		EntityID:      uuidVal(r.EntityID),
		IDCoreModules: int8Ptr(r.IDCoreModules),
		Nama:          r.Nama,
		Keterangan:    textPtr(r.Keterangan),
		Version:       r.Version,
		CreatedAt:     timeVal(r.CreatedAt),
		UpdatedAt:     timeVal(r.UpdatedAt),
		DeletedAt:     timePtr(r.DeletedAt),
	}
}

// kategoriBarisJoin — mapper row join ListKategori (kolom + jumlah file).
func kategoriBarisJoin(
	id int64, entityID pgtype.UUID, idModules pgtype.Int8, nama string,
	keterangan pgtype.Text, version int32,
	createdAt, updatedAt, deletedAt pgtype.Timestamptz,
) KategoriBaris {
	return KategoriBaris{
		ID:            id,
		EntityID:      uuidVal(entityID),
		IDCoreModules: int8Ptr(idModules),
		Nama:          nama,
		Keterangan:    textPtr(keterangan),
		Version:       version,
		CreatedAt:     timeVal(createdAt),
		UpdatedAt:     timeVal(updatedAt),
		DeletedAt:     timePtr(deletedAt),
	}
}

func textFilter(s string) pgtype.Text {
	if s == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: s, Valid: true}
}

func int8Filter(v *int64) pgtype.Int8 {
	if v == nil || *v == 0 {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

func int8Nullable(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

func int8Value(v int64) pgtype.Int8 {
	return pgtype.Int8{Int64: v, Valid: true}
}

func textNullable(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}

func textPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

func int8Ptr(t pgtype.Int8) *int64 {
	if !t.Valid {
		return nil
	}
	v := t.Int64
	return &v
}

func uuidParam(s string) pgtype.UUID {
	var u pgtype.UUID
	_ = u.Scan(s) // parse teks UUID; gagal = invalid (kolom uuid menolak)
	return u
}

func uuidVal(u pgtype.UUID) string {
	if !u.Valid {
		return ""
	}
	return u.String()
}

func timeVal(t pgtype.Timestamptz) time.Time {
	if !t.Valid {
		return time.Time{}
	}
	return t.Time
}

func timePtr(t pgtype.Timestamptz) *time.Time {
	if !t.Valid {
		return nil
	}
	v := t.Time
	return &v
}
