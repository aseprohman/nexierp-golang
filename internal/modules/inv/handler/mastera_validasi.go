// mastera_validasi.go — helper permukaan HTTP MASTER-A: decode body + pesan
// & urutan issue zod v3 PERSIS packages/schemas (verbatim default message
// zod 3.25 locales/en + pesan berkode custom schemas.ts). Empat mode field
// zod: wajib / nullish / default / opsional (partial). SEMUA simbol ber-
// prefix `ma` (paket handler diisi paralel antar agent — anti bentrok).
// DaftarkanMasterA tetap satu pintu (mastera.go).
package handler

import (
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"

	"github.com/labstack/echo/v4"

	"nexierp/internal/core/errkontrak"
	"nexierp/internal/modules/inv/shared"
)

/* ================================================================== */
/* Pesan default zod v3 (verbatim locales/en.js)                       */
/* ================================================================== */

const maMsgRequired = "Required"

func maMsgMinString(n int) string {
	return "String must contain at least " + strconv.Itoa(n) + " character(s)"
}
func maMsgMaxString(n int) string {
	return "String must contain at most " + strconv.Itoa(n) + " character(s)"
}
func maMsgMinNumber(n int64) string {
	return "Number must be greater than or equal to " + strconv.FormatInt(n, 10)
}
func maMsgMaxNumber(n int64) string {
	return "Number must be less than or equal to " + strconv.FormatInt(n, 10)
}
func maMsgMinArray(n int) string {
	return "Array must contain at least " + strconv.Itoa(n) + " element(s)"
}
func maMsgMaxArray(n int) string {
	return "Array must contain at most " + strconv.Itoa(n) + " element(s)"
}
func maMsgBukan(expected, received string) string {
	return "Expected " + expected + ", received " + received
}
func maMsgEnumNilai(options []string, received string) string {
	return "Invalid enum value. Expected " + strings.Join(maQuoted(options), " | ") + ", received '" + received + "'"
}

func maQuoted(xs []string) []string {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		out = append(out, "'"+x+"'")
	}
	return out
}

// maNamaTipeJSON — getParsedType zod utk nilai JSON apa pun.
func maNamaTipeJSON(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case string:
		return "string"
	case bool:
		return "boolean"
	case float64:
		return "number"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return "unknown"
	}
}

// maIssue — issue field+message singkat.
func maIssue(field, message string) errkontrak.FieldIssue {
	return errkontrak.FieldIssue{Field: field, Message: message}
}

/* ================================================================== */
/* Mode field zod                                                     */
/* ================================================================== */

type maZodMode uint8

const (
	maModeWajib    maZodMode = iota // required — absent ATAU null → issue
	maModeNullish                   // .nullish() — absent/null → lolos tanpa nilai
	maModeDefault                   // .default(v) — absent → default; null → issue
	maModeOpsional                  // .partial() — absent → lolos; null → issue
)

// maAdaKey — key hadir di body (tri-state: undefined vs null vs nilai)?
func maAdaKey(m map[string]any, key string) bool {
	_, ada := m[key]
	return ada
}

// maGagalValidasi — padanan parseWith gagal: 400 VAL-400 detail "Data tidak
// valid." (problem+json ditulis langsung).
func maGagalValidasi(c echo.Context, issues []errkontrak.FieldIssue) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Data tidak valid.", issues)
}

// maGagalBody — body JSON rusak → 400 VAL-400 "Body tidak valid".
func maGagalBody(c echo.Context) error {
	return errkontrak.WriteProblem(c, http.StatusBadRequest, errkontrak.CodeVal400, "Body tidak valid",
		[]errkontrak.FieldIssue{{Field: "", Message: "Body tidak valid"}})
}

// maDecodeBody — baca body request → map JSON; ok=false bila rusak.
func maDecodeBody(c echo.Context) (map[string]any, bool) {
	body, err := io.ReadAll(c.Request().Body)
	if err != nil {
		return nil, false
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		// body kosong = objek kosong → issue "Required" per field (zod).
		return map[string]any{}, true
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, false
	}
	return m, true
}

/* ================================================================== */
/* Primitif zod — string / number / enum / boolean                    */
/* ================================================================== */

// maZodString — z.string().trim()?[min,max][regex] sesuai mode; nilai
// kembali TER-TRIM bila trim.
func maZodString(m map[string]any, key string, min, max int, pesanMin, pesanRegex string, re *regexp.Regexp, trim bool, mode maZodMode, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	switch {
	case !ada:
		if mode == maModeWajib {
			*issues = append(*issues, maIssue(key, maMsgRequired))
			return "", false
		}
		return "", false
	case v == nil:
		if mode == maModeNullish {
			return "", false
		}
		*issues = append(*issues, maIssue(key, maMsgBukan("string", "null")))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, maIssue(key, maMsgBukan("string", maNamaTipeJSON(v))))
		return "", false
	}
	if trim {
		s = strings.TrimSpace(s) // z.string().trim() — transform pertama
	}
	if len([]rune(s)) < min {
		pesan := pesanMin
		if pesan == "" {
			pesan = maMsgMinString(min)
		}
		*issues = append(*issues, maIssue(key, pesan))
	}
	if len([]rune(s)) > max {
		*issues = append(*issues, maIssue(key, maMsgMaxString(max)))
	}
	if re != nil && !re.MatchString(s) {
		*issues = append(*issues, maIssue(key, pesanRegex))
	}
	return s, true
}

// maZodNum — z.number() dasar sesuai mode: (nilai, hadir?).
func maZodNum(m map[string]any, key string, mode maZodMode, issues *[]errkontrak.FieldIssue) (float64, bool) {
	v, ada := m[key]
	switch {
	case !ada:
		if mode == maModeWajib {
			*issues = append(*issues, maIssue(key, maMsgRequired))
			return 0, false
		}
		return 0, false
	case v == nil:
		if mode == maModeNullish {
			return 0, false
		}
		*issues = append(*issues, maIssue(key, maMsgBukan("number", "null")))
		return 0, false
	}
	f, ok := v.(float64)
	if !ok {
		*issues = append(*issues, maIssue(key, maMsgBukan("number", maNamaTipeJSON(v))))
		return 0, false
	}
	return f, true
}

// maZodBool — z.boolean() sesuai mode: (nilai, hadir?).
func maZodBool(m map[string]any, key string, mode maZodMode, issues *[]errkontrak.FieldIssue) (bool, bool) {
	v, ada := m[key]
	switch {
	case !ada:
		if mode == maModeWajib {
			*issues = append(*issues, maIssue(key, maMsgRequired))
			return false, false
		}
		return false, false
	case v == nil:
		if mode == maModeNullish {
			return false, false
		}
		*issues = append(*issues, maIssue(key, maMsgBukan("boolean", "null")))
		return false, false
	}
	b, ok := v.(bool)
	if !ok {
		*issues = append(*issues, maIssue(key, maMsgBukan("boolean", maNamaTipeJSON(v))))
		return false, false
	}
	return b, true
}

// maZodEnum — z.enum(options) sesuai mode: non-string → invalid_type
// ("Expected string, received X" — persis ZodEnum); anggota luar →
// invalid_enum_value.
func maZodEnum(m map[string]any, key string, options []string, mode maZodMode, issues *[]errkontrak.FieldIssue) (string, bool) {
	v, ada := m[key]
	switch {
	case !ada:
		if mode == maModeWajib {
			*issues = append(*issues, maIssue(key, maMsgRequired))
			return "", false
		}
		return "", false
	case v == nil:
		if mode == maModeNullish {
			return "", false
		}
		*issues = append(*issues, maIssue(key, maMsgBukan("string", "null")))
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		*issues = append(*issues, maIssue(key, maMsgBukan("string", maNamaTipeJSON(v))))
		return "", false
	}
	for _, o := range options {
		if s == o {
			return s, true
		}
	}
	*issues = append(*issues, maIssue(key, maMsgEnumNilai(options, s)))
	return "", false
}

/* ================================================================== */
/* Komposit skema inv (money / qty / idRef / version / rasio)          */
/* ================================================================== */

// maZodMoney — moneySchema z.number().min(0).max(999999999999).finite().
func maZodMoney(m map[string]any, key string, mode maZodMode, issues *[]errkontrak.FieldIssue) (float64, bool) {
	f, ada := maZodNum(m, key, mode, issues)
	if !ada {
		return 0, false
	}
	if f < 0 {
		*issues = append(*issues, maIssue(key, maMsgMinNumber(0)))
	}
	if f > 999_999_999_999 {
		*issues = append(*issues, maIssue(key, maMsgMaxNumber(999_999_999_999)))
	}
	return f, true
}

// maZodQtyInt — qtySchema z.number().int() [.min(0)] [.positive(pesan)].
func maZodQtyInt(m map[string]any, key string, min *int64, pesanPositive string, mode maZodMode, issues *[]errkontrak.FieldIssue) (float64, bool) {
	f, ada := maZodNum(m, key, mode, issues)
	if !ada {
		return 0, false
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, maIssue(key, maMsgBukan("integer", "float")))
	}
	if pesanPositive != "" && f <= 0 {
		*issues = append(*issues, maIssue(key, pesanPositive))
	}
	if min != nil && f < float64(*min) {
		*issues = append(*issues, maIssue(key, maMsgMinNumber(*min)))
	}
	return f, true
}

// maZodIDRef — idRefSchema z.number().int().positive("Pilih salah satu opsi.")
func maZodIDRef(m map[string]any, key string, mode maZodMode, issues *[]errkontrak.FieldIssue) (int64, bool) {
	f, ada := maZodNum(m, key, mode, issues)
	if !ada {
		return 0, false
	}
	if f != float64(int64(f)) {
		*issues = append(*issues, maIssue(key, maMsgBukan("integer", "float")))
	}
	if f <= 0 {
		*issues = append(*issues, maIssue(key, "Pilih salah satu opsi."))
	}
	return int64(f), true
}

// maZodVersion — version wajib: z.number().int().min(1).
func maZodVersion(m map[string]any, issues *[]errkontrak.FieldIssue) int32 {
	f, _ := maZodNum(m, "version", maModeWajib, issues)
	if f != float64(int64(f)) {
		*issues = append(*issues, maIssue("version", maMsgBukan("integer", "float")))
	}
	if f < 1 {
		*issues = append(*issues, maIssue("version", maMsgMinNumber(1)))
	}
	return int32(f)
}

// maZodRasio — rasioSchema z.number().positive("Rasio harus > 0").
func maZodRasio(m map[string]any, key string, mode maZodMode, issues *[]errkontrak.FieldIssue) (float64, bool) {
	f, ada := maZodNum(m, key, mode, issues)
	if !ada {
		return 0, false
	}
	if f <= 0 {
		*issues = append(*issues, maIssue(key, "Rasio harus > 0"))
	}
	return f, true
}

/* ================================================================== */
/* Kosakata enum inv (persis tipe.ts)                                 */
/* ================================================================== */

var (
	maEnumStatusAktif   = []string{"AKTIF", "NONAKTIF"}
	maEnumTipeProduk    = []string{"BARANG", "JASA", "BAHAN"}
	maEnumMetodeValuasi = []string{"STANDAR", "AVCO", "FIFO"}
	maEnumSistemValuasi = []string{"PERPETUAL", "PERIODIK"}
	maEnumPelacakan     = []string{"TANPA", "LOT", "SERIAL"}
)

// maReKodeKode — regex `[A-Za-z0-9_.-]+` bersama (SKU/kode).
var maReKodeKode = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

// maPesanKode — pesan regex kode bersama.
const maPesanKode = "Kode: huruf/angka/. _ -"

// maPageReq — PageRequest persis Nest (default 1/20, clamp 200).
func maPageReq(c echo.Context) (*errkontrak.PageRequest, error) {
	return errkontrak.ParsePageRequest(c.Request().URL.Query())
}

// maParseID — padanan :id param (parseIdParam pesan verbatim).
func maParseID(c echo.Context) (int64, error) {
	return shared.ParseIDParam(c.Param("id"), "id")
}

// maFirstQuery — nilai query pertama atau "".
func maFirstQuery(q map[string][]string, key string) string {
	vs, ada := q[key]
	if !ada || len(vs) == 0 {
		return ""
	}
	return vs[0]
}

// maNumStr — Number(limit) query: ""/absen/NaN → nil.
func maNumStr(raw string) *float64 {
	if raw == "" {
		return nil
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil {
		return nil // NaN — Number.isFinite gagal → undefined (default)
	}
	return &f
}
