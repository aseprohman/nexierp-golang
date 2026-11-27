// media-types — padanan types/media-types.ts: kosakata tipe & konstanta
// area storage/media library kernel. MURNI tipe: tanpa pgx, tanpa AWS SDK.
package storage

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/storage/repository"
)

// normNFKD — dekomposisi NFKD (padanan .normalize("NFKD") JS).
func normNFKD(s string) string { return norm.NFKD.String(s) }

// MAX_FILE_BYTES — batas ukuran file mentah (sebelum base64) — 8 MB.
const MAX_FILE_BYTES = 8 * 1024 * 1024

// MediaKind — jenis media untuk preview (padanan MediaKind NestJS/web).
type MediaKind string

const (
	MediaKindImage MediaKind = "image"
	MediaKindPDF   MediaKind = "pdf"
	MediaKindVideo MediaKind = "video"
	MediaKindAudio MediaKind = "audio"
	MediaKindFile  MediaKind = "file"
)

// MediaKindOf — klasifikasi jenis media dari mime (sumber tunggal preview
// backend+web — padanan mediaKindOf).
func MediaKindOf(mimeType string) MediaKind {
	mime := strings.ToLower(mimeType)
	switch {
	case strings.HasPrefix(mime, "image/"):
		return MediaKindImage
	case mime == "application/pdf":
		return MediaKindPDF
	case strings.HasPrefix(mime, "video/"):
		return MediaKindVideo
	case strings.HasPrefix(mime, "audio/"):
		return MediaKindAudio
	default:
		return MediaKindFile
	}
}

// FileView — view API (tanpa object_key internal; url hanya lewat sign).
type FileView struct {
	ID             string    `json:"id"` // entity_id — dipakai endpoint sign/delete
	FileID         int64     `json:"fileId"`
	FileName       string    `json:"fileName"`
	MimeType       string    `json:"mimeType"`
	Kind           MediaKind `json:"kind"`
	SizeBytes      int64     `json:"sizeBytes"`
	Scope          string    `json:"scope"`
	ChecksumSha256 *string   `json:"checksumSha256"`
	UploadedBy     *string   `json:"uploadedBy"`
	IDCoreModules  *int64    `json:"idCoreModules"`
	IDKategori     *int64    `json:"idKategori"`
	CreatedAt      string    `json:"createdAt"` // ISO 8601 (toISOString persis NestJS)
	UpdatedAt      string    `json:"updatedAt"`
}

// ToFileView — mapper baris repo → view API (padanan toView FilesRepository).
func ToFileView(b repository.FileBaris, uploader *string) FileView {
	return FileView{
		ID:             b.EntityID,
		FileID:         b.ID,
		FileName:       b.OriginalName,
		MimeType:       b.MimeType,
		Kind:           MediaKindOf(b.MimeType),
		SizeBytes:      b.SizeBytes,
		Scope:          b.Scope,
		ChecksumSha256: b.ChecksumSha256,
		UploadedBy:     uploader,
		IDCoreModules:  b.IDCoreModules,
		IDKategori:     b.IDCoreMediaCategories,
		CreatedAt:      isoTime(b.CreatedAt),
		UpdatedAt:      isoTime(b.UpdatedAt),
	}
}

// MediaKategoriView — view satu kategori library (ddl/44).
type MediaKategoriView struct {
	ID            int64   `json:"id"`
	IDCoreModules *int64  `json:"idCoreModules"` // nil = kategori bersama lintas modul
	Nama          string  `json:"nama"`
	Keterangan    *string `json:"keterangan"`
	JumlahFile    int64   `json:"jumlahFile"` // jumlah file HIDUP (hitung server — badge FE)
	Version       int32   `json:"version"`
	CreatedAt     string  `json:"createdAt"`
	UpdatedAt     string  `json:"updatedAt"`
}

// ToKategoriView — mapper baris → view kategori (padanan toKategoriView).
func ToKategoriView(b repository.KategoriBaris, jumlahFile int64) MediaKategoriView {
	return MediaKategoriView{
		ID:            b.ID,
		IDCoreModules: b.IDCoreModules,
		Nama:          b.Nama,
		Keterangan:    b.Keterangan,
		JumlahFile:    jumlahFile,
		Version:       b.Version,
		CreatedAt:     isoTime(b.CreatedAt),
		UpdatedAt:     isoTime(b.UpdatedAt),
	}
}

// isoTime — padanan toISOString(): UTC, milidetik 3 digit, akhiran Z.
func isoTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

// MediaUploadInput — input upload; data base64 murni ATAU buffer internal.
type MediaUploadInput struct {
	Scope         string
	FileName      string
	MimeType      string
	DataBase64    string // base64 murni (tanpa prefix data:) — wajib bila Buffer kosong
	Buffer        []byte // alternatif inline untuk pemanggil internal
	IDCoreModules *int64 // modul pemilik unggahan (FK core_modules) — opsional
	IDKategori    *int64 // kategori library (FK core_media_categories) — opsional
}

// MediaKategoriCreateInput — input tambah; IDCoreModules nil = kategori bersama.
type MediaKategoriCreateInput struct {
	Nama          string
	Keterangan    *string
	IDCoreModules *int64
}

// NullableInt64 — tri-state persis NestJS (absen / null / ada nilai) untuk
// update parsial: Set=false = field tidak dikirim; Set=true Value=nil = null.
type NullableInt64 struct {
	Set   bool
	Value *int64
}

// NullableString — tri-state string (padanan `string | null | undefined`).
type NullableString struct {
	Set   bool
	Value *string
}

// MediaKategoriUpdateInput — input ubah; optimistic lock `version`
// (409 VERSI_BENTROK).
type MediaKategoriUpdateInput struct {
	Nama          NullableString
	Keterangan    NullableString
	IDCoreModules NullableInt64
	Version       int32
}

/* -------------------------------------------------------------- */
/* Klasifikasi & sanitasi (pure — dipakai service + test)          */
/* -------------------------------------------------------------- */

// reScope — format prefix modul `<modul>-<keperluan>` lowercase (persis NestJS).
var reScope = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// reSegmen — karakter di luar [A-Za-z0-9_.-] jadi "-", padanan /[^\w.\-]+/g
// (JS \w ASCII-only — Go \w identik).
var reSegmen = regexp.MustCompile(`[^\w.\-]+`)

// reDash — padanan /-+/g.
var reDash = regexp.MustCompile(`-+`)

// ScopeValid — scope lolos pola modul?
func ScopeValid(scope string) bool { return reScope.MatchString(scope) }

// SanitizeName — sanitasi nama file jadi segmen object key yang aman
// (persis sanitizeName NestJS: NFKD → ganti non-segmen → rapikan dash →
// potong 80 → fallback "file").
func SanitizeName(name string) string {
	out := normNFKD(name)
	out = reSegmen.ReplaceAllString(out, "-")
	out = reDash.ReplaceAllString(out, "-")
	out = strings.Trim(out, "-")
	r := []rune(out)
	if len(r) > 80 {
		out = string(r[:80])
	}
	if out == "" {
		out = "file"
	}
	return out
}

// TrimOrNull — trim keterangan; string kosong jadi NULL (bucket 200).
func TrimOrNull(v *string) *string {
	if v == nil {
		return nil
	}
	s := strings.TrimSpace(*v)
	if s == "" {
		return nil
	}
	r := []rune(s)
	if len(r) > 200 {
		s = string(r[:200])
	}
	return &s
}

// ParseNumericID — ref id harus integer positif (route `:id` string → angka).
func ParseNumericID(ref string, field string) (int64, error) {
	n, err := strconv.ParseInt(ref, 10, 64)
	if err != nil || n <= 0 {
		return 0, errValidationId(ref, field)
	}
	return n, nil
}

func errValidationId(ref, field string) error {
	return errkontrak.Validation(
		[]errkontrak.FieldIssue{{Field: field, Message: fmt.Sprintf("Id %q tidak valid.", ref)}},
	)
}
