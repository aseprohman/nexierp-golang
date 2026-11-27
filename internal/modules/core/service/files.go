// Package service — fitur FILES modul core: ADAPTER TIPIS endpoint
// /system/files di atas kernel storage.MediaLibraryService (padanan
// FilesService NestJS: modules/core/services/files/files.service.ts yang
// membungkus core/storage). SATU jalur eksekusi upload untuk semua modul
// tetap di kernel: validasi → S3/MinIO DULU → INSERT core_files + audit
// (satu transaksi). Modul lain mengunggah via kernel, TIDAK lewat sini.
//
// Validasi body/query di sini = padanan zod (packages/schemas/src/core/
// files.ts) + parseWith: pesan, urutan issue, dan semantik coerce PERSIS
// zod v3 — gagal → 400 VAL-400 detail "Data tidak valid." + issues.
// TANPA echo: permukaan HTTP tetap di handler; tx dimiliki kernel.
package service

import (
	"context"
	"fmt"
	"math"
	"net/url"
	"strconv"
	"strings"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/storage"
)

// FilesService — padanan FilesService NestJS; endpoint media library UI
// (MediaUploader/MediaViewer web) di atas MediaLibraryService.
type FilesService struct {
	Media *storage.MediaLibraryService
}

// NewFilesService — kernel media di-wiring bootstrap (internal/app).
func NewFilesService(media *storage.MediaLibraryService) *FilesService {
	return &FilesService{Media: media}
}

/* -------------------------------------------------------------- */
/* Operasi (delegasi tipis ke kernel)                              */
/* -------------------------------------------------------------- */

// Upload — unggah file (base64 JSON; boleh bawa idCoreModules/idKategori —
// ddl/44). Zod dulu (uploadFileSchema), lalu kernel: decode → assert
// modul/kategori (404 SEBELUM S3) → S3 put → tx INSERT + audit create.
func (s *FilesService) Upload(ctx context.Context, body map[string]any, actor audit.Actor) (storage.FileView, error) {
	in, issues := parseUploadBody(body)
	if len(issues) > 0 {
		return storage.FileView{}, errkontrak.Validation(issues)
	}
	return s.Media.Upload(ctx, in, actor)
}

// List — daftar file HIDUP (filter scope/search/modul/kategori, paginasi,
// terbaru dulu) — envelope Page {data, meta} persis controller NestJS
// (totalPages = max(1, ceil(total/limit))).
func (s *FilesService) List(ctx context.Context, q url.Values) (errkontrak.Page[storage.FileView], error) {
	req, issues := parseListQuery(q)
	if len(issues) > 0 {
		return errkontrak.Page[storage.FileView]{}, errkontrak.Validation(issues)
	}
	res, err := s.Media.List(ctx, req)
	if err != nil {
		return errkontrak.Page[storage.FileView]{}, err
	}
	totalPages := 1 // Math.max(1, ...) — daftar kosong tetap 1 halaman
	if tp := (res.Total + int64(res.Limit) - 1) / int64(res.Limit); tp > 1 {
		totalPages = int(tp)
	}
	return errkontrak.Page[storage.FileView]{
		Data: res.Data,
		Meta: errkontrak.PageMeta{
			Page:       res.Page,
			Limit:      res.Limit,
			Total:      int(res.Total),
			TotalPages: totalPages,
		},
	}, nil
}

// StreamRaw — stream object file HIDUP untuk endpoint /:id/raw — preview
// same-origin TANPA presigned URL. 404 SYS-404 bila tak ada / soft-deleted.
func (s *FilesService) StreamRaw(ctx context.Context, fileRef string) (*storage.FileStream, error) {
	fs, err := s.Media.StreamOf(ctx, fileRef)
	if err != nil {
		return nil, err
	}
	if fs == nil {
		return nil, errkontrak.NotFound(fmt.Sprintf("File %q tidak ditemukan.", fileRef), "SYS-404")
	}
	if fs.ContentType == "" {
		fs.ContentType = "application/octet-stream" // fallback persis NestJS
	}
	return fs, nil
}

// SignedURL — presigned URL GET (1 jam); inline untuk preview, default
// unduh. 404 SYS-404 bila file tak ada / sudah soft-deleted.
func (s *FilesService) SignedURL(ctx context.Context, fileRef string, inline bool) (storage.SignedURLView, error) {
	v, err := s.Media.SignedURLOf(ctx, fileRef, storage.SignedURLOpts{Inline: inline})
	if err != nil {
		return storage.SignedURLView{}, err
	}
	if v == nil {
		return storage.SignedURLView{}, errkontrak.NotFound(fmt.Sprintf("File %q tidak ditemukan.", fileRef), "SYS-404")
	}
	return *v, nil
}

// Remove — hapus file = SOFT DELETE registry + audit; object MinIO TIDAK
// dihapus di sini (sweep terpisah — deferred).
func (s *FilesService) Remove(ctx context.Context, fileRef string, actor audit.Actor) error {
	return s.Media.Remove(ctx, fileRef, actor)
}

// ListKategori — daftar kategori HIDUP + jumlah file hidup (badge FE).
func (s *FilesService) ListKategori(ctx context.Context, q url.Values) ([]storage.MediaKategoriView, error) {
	id, issues := parseKategoriListQuery(q)
	if len(issues) > 0 {
		return nil, errkontrak.Validation(issues)
	}
	return s.Media.ListKategori(ctx, id)
}

// CreateKategori — tambah kategori; NULL modul = kategori bersama. 409
// NAMA_DIPAKAI bila nama dipakai dalam lingkup modul yang sama.
func (s *FilesService) CreateKategori(ctx context.Context, body map[string]any, actor audit.Actor) (storage.MediaKategoriView, error) {
	in, issues := parseKategoriCreateBody(body)
	if len(issues) > 0 {
		return storage.MediaKategoriView{}, errkontrak.Validation(issues)
	}
	return s.Media.CreateKategori(ctx, in, actor)
}

// UpdateKategori — ubah kategori; optimistic lock version (409
// VERSI_BENTROK bila stale) — id rute = id numerik.
func (s *FilesService) UpdateKategori(ctx context.Context, idRef string, body map[string]any, actor audit.Actor) (storage.MediaKategoriView, error) {
	in, issues := parseKategoriUpdateBody(body)
	if len(issues) > 0 {
		return storage.MediaKategoriView{}, errkontrak.Validation(issues)
	}
	return s.Media.UpdateKategori(ctx, idRef, in, actor)
}

// RemoveKategori — hapus kategori (soft) + DALAM tx file terkait di-SET
// NULL (jadi "Tanpa kategori") — aset TIDAK pernah ikut terhapus.
func (s *FilesService) RemoveKategori(ctx context.Context, idRef string, actor audit.Actor) error {
	return s.Media.RemoveKategori(ctx, idRef, actor)
}

/* -------------------------------------------------------------- */
/* Validasi body — padanan zod v3 (pesan default verbatim)         */
/* -------------------------------------------------------------- */

// Pesan default zod v3 (verbatim — packages/schemas + locales/en.ts).
const (
	zMsgRequired = "Required"
	zMsgIntFloat = "Expected integer, received float"
	zMsgNumPos   = "Number must be greater than 0"

	// refine mediaKategoriUpdateSchema (issue path [] → field "(root)").
	zMsgRefineKategori = "Sertakan minimal satu perubahan selain version."

	// pesan kustom mediaKategoriCreateSchema.nama min(1).
	zMsgNamaKategoriWajib = "Nama kategori wajib."
)

func zMsgStrMin(n int) string { return fmt.Sprintf("String must contain at least %d character(s)", n) }
func zMsgStrMax(n int) string { return fmt.Sprintf("String must contain at most %d character(s)", n) }
func zMsgNumMin(n int64) string {
	return fmt.Sprintf("Number must be greater than or equal to %d", n)
}
func zMsgNumMax(n int64) string {
	return fmt.Sprintf("Number must be less than or equal to %d", n)
}

// zMsgExpected — padanan `Expected ${expected}, received ${received}`.
func zMsgExpected(expected, received string) string {
	return fmt.Sprintf("Expected %s, received %s", expected, received)
}

// namaTipeJSON — nama tipe zod untuk nilai JSON apa pun.
func namaTipeJSON(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case float64:
		return "number"
	case bool:
		return "boolean"
	case []any:
		return "array"
	default:
		return "object"
	}
}

// isInteger — padanan Number.isInteger (NaN/±Inf/pecahan → false).
func isInteger(f float64) bool {
	return !math.IsNaN(f) && !math.IsInf(f, 0) && f == math.Trunc(f)
}

// issue — pembungkus FieldIssue satu baris.
func issue(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

// zodString — satu field string: absent → present=false tanpa issue;
// null/tipe salah → issue invalid_type; string → nilai apa adanya.
// Check min/max dijalankan pemanggil SETELAH trim (zod .trim() berjalan
// sebelum check — urutan issue mengikuti definisi schema).
func zodString(m map[string]any, key string) (v string, present, oke bool, issues []errkontrak.FieldIssue) {
	x, ada := m[key]
	if !ada {
		return "", false, false, nil
	}
	if x == nil {
		return "", true, false, []errkontrak.FieldIssue{issue(key, zMsgExpected("string", "null"))}
	}
	s, isStr := x.(string)
	if !isStr {
		return "", true, false, []errkontrak.FieldIssue{issue(key, zMsgExpected("string", namaTipeJSON(x)))}
	}
	return s, true, true, nil
}

// zodStrCheck — check min/max string (keduanya independen — zod v3
// mengumpulkan semua issue per field).
func zodStrCheck(key, v string, min, max int) []errkontrak.FieldIssue {
	var issues []errkontrak.FieldIssue
	n := len([]rune(v))
	if n < min {
		issues = append(issues, issue(key, zMsgStrMin(min)))
	}
	if n > max {
		issues = append(issues, issue(key, zMsgStrMax(max)))
	}
	return issues
}

// zodNullableInt64 — z.number().int().positive().nullish(): absent → tidak
// dikirim (Set=false); null → Set=true Value=nil; number → check int+positif
// (masing-masing issue independen — zod v3), sukses → Set=true Value=&n.
func zodNullableInt64(m map[string]any, key string) (storage.NullableInt64, []errkontrak.FieldIssue) {
	x, ada := m[key]
	if !ada {
		return storage.NullableInt64{}, nil
	}
	if x == nil {
		return storage.NullableInt64{Set: true}, nil
	}
	f, isNum := x.(float64)
	if !isNum {
		return storage.NullableInt64{Set: true}, []errkontrak.FieldIssue{
			issue(key, zMsgExpected("number", namaTipeJSON(x))),
		}
	}
	var issues []errkontrak.FieldIssue
	if !isInteger(f) {
		issues = append(issues, issue(key, zMsgIntFloat))
	}
	if f <= 0 {
		issues = append(issues, issue(key, zMsgNumPos))
	}
	if len(issues) > 0 {
		return storage.NullableInt64{Set: true}, issues
	}
	n := int64(f)
	return storage.NullableInt64{Set: true, Value: &n}, nil
}

// zodTrimMaxNullable — z.string().trim().max(n).nullish() (keterangan
// kategori): absent/null → nil valid; string → trim dulu, baru check max.
func zodTrimMaxNullable(m map[string]any, key string, max int) (*string, []errkontrak.FieldIssue) {
	x, ada := m[key]
	if !ada || x == nil {
		return nil, nil
	}
	s, isStr := x.(string)
	if !isStr {
		return nil, []errkontrak.FieldIssue{issue(key, zMsgExpected("string", namaTipeJSON(x)))}
	}
	s = strings.TrimSpace(s) // .trim() SEBELUM check (zod)
	if len([]rune(s)) > max {
		return &s, []errkontrak.FieldIssue{issue(key, zMsgStrMax(max))}
	}
	return &s, nil
}

// parseUploadBody — padanan uploadFileSchema {scope min1 max48, fileName
// min1 max200, mimeType min3 max120, dataBase64 min1, idCoreModules int
// positive nullish, idKategori int positive nullish}; urutan issue = urutan
// key schema.
func parseUploadBody(m map[string]any) (storage.MediaUploadInput, []errkontrak.FieldIssue) {
	var in storage.MediaUploadInput
	var issues []errkontrak.FieldIssue

	// scope: z.string().min(1).max(48)
	if v, ada, oke, iss := zodString(m, "scope"); ada {
		issues = append(issues, iss...)
		if oke {
			in.Scope = v
			issues = append(issues, zodStrCheck("scope", v, 1, 48)...)
		}
	}
	// fileName: z.string().min(1).max(200)
	if v, ada, oke, iss := zodString(m, "fileName"); ada {
		issues = append(issues, iss...)
		if oke {
			in.FileName = v
			issues = append(issues, zodStrCheck("fileName", v, 1, 200)...)
		}
	}
	// mimeType: z.string().min(3).max(120)
	if v, ada, oke, iss := zodString(m, "mimeType"); ada {
		issues = append(issues, iss...)
		if oke {
			in.MimeType = v
			issues = append(issues, zodStrCheck("mimeType", v, 3, 120)...)
		}
	}
	// dataBase64: z.string().min(1)
	if v, ada, oke, iss := zodString(m, "dataBase64"); ada {
		issues = append(issues, iss...)
		if oke {
			in.DataBase64 = v
			issues = append(issues, zodStrCheck("dataBase64", v, 1, 0)...)
		}
	}

	// idCoreModules / idKategori: z.number().int().positive().nullish()
	modul, iss := zodNullableInt64(m, "idCoreModules")
	issues = append(issues, iss...)
	in.IDCoreModules = nilaiNullable(modul)
	kat, iss := zodNullableInt64(m, "idKategori")
	issues = append(issues, iss...)
	in.IDKategori = nilaiNullable(kat)
	return in, issues
}

// nilaiNullable — NullableInt64 → *int64 kernel (Set+nil = null = nil).
func nilaiNullable(n storage.NullableInt64) *int64 {
	if n.Set && n.Value != nil {
		return n.Value
	}
	return nil
}

// parseKategoriCreateBody — padanan mediaKategoriCreateSchema {nama trim
// min1 "Nama kategori wajib." max100, keterangan trim max200 nullish,
// idCoreModules int positive nullish}.
func parseKategoriCreateBody(m map[string]any) (storage.MediaKategoriCreateInput, []errkontrak.FieldIssue) {
	var in storage.MediaKategoriCreateInput
	var issues []errkontrak.FieldIssue

	// nama: z.string().trim().min(1, "Nama kategori wajib.").max(100)
	if v, ada, oke, iss := zodString(m, "nama"); ada {
		issues = append(issues, iss...)
		if oke {
			v = strings.TrimSpace(v) // .trim() SEBELUM check (zod)
			in.Nama = v
			if len([]rune(v)) < 1 {
				issues = append(issues, issue("nama", zMsgNamaKategoriWajib))
			}
			if len([]rune(v)) > 100 {
				issues = append(issues, issue("nama", zMsgStrMax(100)))
			}
		}
	}
	// keterangan: z.string().trim().max(200).nullish()
	ket, iss := zodTrimMaxNullable(m, "keterangan", 200)
	issues = append(issues, iss...)
	in.Keterangan = ket
	// idCoreModules: z.number().int().positive().nullish()
	modul, iss := zodNullableInt64(m, "idCoreModules")
	issues = append(issues, iss...)
	in.IDCoreModules = nilaiNullable(modul)
	return in, issues
}

// parseKategoriUpdateBody — padanan mediaKategoriUpdateSchema: {nama trim
// min1 max100 optional, keterangan trim max200 nullish, idCoreModules int
// positive nullish, version int min1 WAJIB} + refine "Sertakan minimal
// satu perubahan selain version." (refine hanya dijalankan bila inner
// parse sukses — issue path [] → field "(root)").
func parseKategoriUpdateBody(m map[string]any) (storage.MediaKategoriUpdateInput, []errkontrak.FieldIssue) {
	var in storage.MediaKategoriUpdateInput
	var issues []errkontrak.FieldIssue

	// nama: z.string().trim().min(1).max(100).optional() — null ditolak.
	if x, ada := m["nama"]; ada {
		s, oke := x.(string)
		if !oke {
			issues = append(issues, issue("nama", zMsgExpected("string", namaTipeJSON(x))))
		} else {
			s = strings.TrimSpace(s)
			in.Nama = storage.NullableString{Set: true, Value: &s}
			issues = append(issues, zodStrCheck("nama", s, 1, 100)...)
		}
	}
	// keterangan: z.string().trim().max(200).nullish() — tri-state.
	if x, ada := m["keterangan"]; ada {
		if x == nil {
			in.Keterangan = storage.NullableString{Set: true}
		} else if s, oke := x.(string); !oke {
			issues = append(issues, issue("keterangan", zMsgExpected("string", namaTipeJSON(x))))
		} else {
			s = strings.TrimSpace(s)
			in.Keterangan = storage.NullableString{Set: true, Value: &s}
			if len([]rune(s)) > 200 {
				issues = append(issues, issue("keterangan", zMsgStrMax(200)))
			}
		}
	}
	// idCoreModules: z.number().int().positive().nullish() — tri-state.
	modul, iss := zodNullableInt64(m, "idCoreModules")
	issues = append(issues, iss...)
	in.IDCoreModules = modul
	// version: z.number().int().min(1) — WAJIB (optimistic lock).
	if x, ada := m["version"]; !ada {
		issues = append(issues, issue("version", zMsgRequired))
	} else if f, oke := x.(float64); !oke {
		issues = append(issues, issue("version", zMsgExpected("number", namaTipeJSON(x))))
	} else {
		if !isInteger(f) {
			issues = append(issues, issue("version", zMsgIntFloat))
		}
		if f < 1 {
			issues = append(issues, issue("version", zMsgNumMin(1)))
		}
		if isInteger(f) && f >= 1 {
			in.Version = int32(f)
		}
	}

	// refine: inner sukses (tanpa issue) tapi TIDAK ada perubahan selain
	// version → satu issue di root.
	if len(issues) == 0 {
		_, adaNama := m["nama"]
		_, adaKet := m["keterangan"]
		_, adaModul := m["idCoreModules"]
		if !adaNama && !adaKet && !adaModul {
			issues = append(issues, issue("(root)", zMsgRefineKategori))
		}
	}
	return in, issues
}

/* -------------------------------------------------------------- */
/* Validasi query — padanan z.coerce.number (semantik JS Number)   */
/* -------------------------------------------------------------- */

// coerceNumber — padanan z.coerce.number / JS Number(value) utk string
// query: spasi tepi diabaikan; "" → 0; 0x/0b/0o → basis eksplisit;
// "Infinity" → ±Inf; selain itu ParseFloat; gagal → NaN.
func coerceNumber(raw string) float64 {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 0
	}
	tanda := ""
	if s[0] == '+' || s[0] == '-' {
		tanda = string(s[0])
		s = s[1:]
	}
	lower := strings.ToLower(s)
	switch {
	case lower == "infinity":
		if tanda == "-" {
			return math.Inf(-1)
		}
		return math.Inf(1)
	case strings.HasPrefix(lower, "0x"):
		return parseBasis(tanda, s[2:], 16)
	case strings.HasPrefix(lower, "0b"):
		return parseBasis(tanda, s[2:], 2)
	case strings.HasPrefix(lower, "0o"):
		return parseBasis(tanda, s[2:], 8)
	}
	if tanda != "" {
		s = tanda + s
	}
	s = strings.TrimSuffix(s, ".") // JS menerima "5." — strconv tidak
	// "inf"/"nan" gaya ParseFloat bukan angka di JS (Infinity eksplisit di atas).
	if strings.ContainsAny(lower, "inn") {
		return math.NaN()
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return math.NaN()
	}
	return f
}

// parseBasis — angka berprefix 0x/0b/0o (JS Number); tanpa digit → NaN.
func parseBasis(tanda, digits string, basis int) float64 {
	n, err := strconv.ParseInt(digits, basis, 64)
	if err != nil {
		return math.NaN()
	}
	if tanda == "-" {
		return float64(-n)
	}
	return float64(n)
}

// zodQueryNumber — z.coerce.number() pada satu param query: absent → tidak
// ada; ulang key (array Express) → "Expected number, received array";
// bukan angka (NaN) → "Expected number, received nan".
func zodQueryNumber(q url.Values, key string) (n float64, ada bool, issues []errkontrak.FieldIssue) {
	vals, ada := q[key]
	if !ada {
		return 0, false, nil
	}
	if len(vals) > 1 {
		return 0, true, []errkontrak.FieldIssue{issue(key, zMsgExpected("number", "array"))}
	}
	n = coerceNumber(vals[0])
	if math.IsNaN(n) {
		return 0, true, []errkontrak.FieldIssue{issue(key, zMsgExpected("number", "nan"))}
	}
	return n, true, nil
}

// zodNumIntCheck — check .int(): pecahan → invalid_type "float" (pesan zod).
func zodNumIntCheck(key string, f float64) *errkontrak.FieldIssue {
	if !isInteger(f) {
		iss := issue(key, zMsgIntFloat)
		return &iss
	}
	return nil
}

// zodQueryString — z.string().max(n).optional() pada param query: ulang
// key (array) → invalid_type; else check max (tanpa trim — schema polos).
func zodQueryString(q url.Values, key string, max int) (string, []errkontrak.FieldIssue) {
	vals, ada := q[key]
	if !ada {
		return "", nil
	}
	if len(vals) > 1 {
		return "", []errkontrak.FieldIssue{issue(key, zMsgExpected("string", "array"))}
	}
	v := vals[0]
	if len([]rune(v)) > max {
		return v, []errkontrak.FieldIssue{issue(key, zMsgStrMax(max))}
	}
	return v, nil
}

// parseListQuery — padanan filesListQuerySchema {scope max48 optional,
// search max120 optional, idCoreModules coerce int positive optional,
// idKategori coerce int min0 optional (0 = sentinel tanpa kategori),
// page coerce int min1 default1, limit coerce int min1 max200 default50}.
func parseListQuery(q url.Values) (storage.ListFilesReq, []errkontrak.FieldIssue) {
	var req storage.ListFilesReq
	var issues []errkontrak.FieldIssue

	// scope / search — string polos.
	scope, iss := zodQueryString(q, "scope", 48)
	issues = append(issues, iss...)
	req.Scope = scope
	search, iss := zodQueryString(q, "search", 120)
	issues = append(issues, iss...)
	req.Search = search

	// idCoreModules: coerce int positive — nil/0 = tanpa filter (kernel).
	if n, ada, iss := zodQueryNumber(q, "idCoreModules"); ada {
		issues = append(issues, iss...)
		if c := zodNumIntCheck("idCoreModules", n); c != nil {
			issues = append(issues, *c)
		}
		if n <= 0 {
			issues = append(issues, issue("idCoreModules", zMsgNumPos))
		}
		if len(iss) == 0 && isInteger(n) && n > 0 {
			v := int64(n)
			req.IDCoreModules = &v
		}
	}
	// idKategori: coerce int min0 — 0 = sentinel "tanpa kategori".
	if n, ada, iss := zodQueryNumber(q, "idKategori"); ada {
		issues = append(issues, iss...)
		if c := zodNumIntCheck("idKategori", n); c != nil {
			issues = append(issues, *c)
		}
		if n < 0 {
			issues = append(issues, issue("idKategori", zMsgNumMin(0)))
		}
		if len(iss) == 0 && isInteger(n) && n >= 0 {
			v := int64(n)
			req.IDKategori = &v
		}
	}
	// page: coerce int min1 default1.
	if n, ada, iss := zodQueryNumber(q, "page"); !ada {
		p := 1
		req.Page = &p
	} else {
		issues = append(issues, iss...)
		if c := zodNumIntCheck("page", n); c != nil {
			issues = append(issues, *c)
		}
		if n < 1 {
			issues = append(issues, issue("page", zMsgNumMin(1)))
		}
		if len(iss) == 0 && isInteger(n) && n >= 1 {
			p := int(n)
			req.Page = &p
		}
	}
	// limit: coerce int min1 max200 default50.
	if n, ada, iss := zodQueryNumber(q, "limit"); !ada {
		l := 50
		req.Limit = &l
	} else {
		issues = append(issues, iss...)
		if c := zodNumIntCheck("limit", n); c != nil {
			issues = append(issues, *c)
		}
		if n < 1 {
			issues = append(issues, issue("limit", zMsgNumMin(1)))
		}
		if n > 200 {
			issues = append(issues, issue("limit", zMsgNumMax(200)))
		}
		if len(iss) == 0 && isInteger(n) && n >= 1 && n <= 200 {
			l := int(n)
			req.Limit = &l
		}
	}
	return req, issues
}

// parseKategoriListQuery — padanan mediaKategoriListQuerySchema
// {idCoreModules coerce int positive optional}.
func parseKategoriListQuery(q url.Values) (*int64, []errkontrak.FieldIssue) {
	n, ada, issues := zodQueryNumber(q, "idCoreModules")
	if !ada {
		return nil, nil
	}
	if c := zodNumIntCheck("idCoreModules", n); c != nil {
		issues = append(issues, *c)
	}
	if n <= 0 {
		issues = append(issues, issue("idCoreModules", zMsgNumPos))
	}
	if len(issues) > 0 {
		return nil, issues
	}
	id := int64(n)
	return &id, nil
}
