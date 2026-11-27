// Package errkontrak — padanan DomainError + ProblemExceptionFilter NestJS.
// KONTRAK BEKU: bentuk error HTTP PERSIS NestJS (problem+json RFC 7807).
package errkontrak

import "fmt"

// FieldIssue — padanan {field, message} zod issues.
type FieldIssue struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

// DomainError — padanan core/common/errors/domain.error.ts.
type DomainError struct {
	Code   string
	Status int
	Detail string
	Errors []FieldIssue
}

func (e *DomainError) Error() string { return e.Detail }

func of(code string, status int, detail string, errs []FieldIssue) *DomainError {
	if detail == "" {
		detail = defaultDetailByStatus(status)
	}
	return &DomainError{Code: code, Status: status, Detail: detail, Errors: errs}
}

// defaultDetailByStatus — padanan DEFAULT_DETAIL_BY_STATUS (verbatim).
func defaultDetailByStatus(status int) string {
	switch status {
	case 400:
		return "Permintaan tidak valid."
	case 401:
		return "Autentikasi diperlukan."
	case 403:
		return "Akses ditolak."
	case 404:
		return "Resource tidak ditemukan."
	case 409:
		return "Konflik dengan data/status saat ini."
	case 422:
		return "Data tidak dapat diproses."
	case 500:
		return "Terjadi kesalahan internal pada server."
	}
	return fmt.Sprintf("HTTP %d.", status)
}

// Kode fallback baku — persis STATUS_TO_CODE NestJS.
const (
	CodeVal400   = "VAL-400"
	CodeAuth401  = "AUTH-401"
	CodeForb403  = "FORB-403"
	CodeNotf404  = "NOTF-404"
	CodeConf409  = "CONF-409"
	CodeVal422   = "VAL-422"
	CodeRate429  = "RATE-429"
	CodeSys000   = "SYS-000"
	CodeSys001   = "SYS-001"
	DetailSystem = "Terjadi kesalahan internal pada server."
)

func Validation(errs []FieldIssue, detail ...string) *DomainError {
	d := "Data tidak valid."
	if len(detail) > 0 && detail[0] != "" {
		d = detail[0]
	}
	return &DomainError{Code: CodeVal400, Status: 400, Detail: d, Errors: errs}
}

func BadRequest(detail string, code ...string) *DomainError {
	return of(pick(CodeVal400, code), 400, detail, nil)
}

func Unauthorized(detail string, code ...string) *DomainError {
	return of(pick(CodeAuth401, code), 401, detail, nil)
}

func Forbidden(detail string, code ...string) *DomainError {
	return of(pick(CodeForb403, code), 403, detail, nil)
}

func NotFound(detail string, code ...string) *DomainError {
	return of(pick(CodeNotf404, code), 404, detail, nil)
}

func Conflict(detail string, code ...string) *DomainError {
	return of(pick(CodeConf409, code), 409, detail, nil)
}

func Unprocessable(detail string, code ...string) *DomainError {
	return of(pick(CodeVal422, code), 422, detail, nil)
}

func Internal(detail string, code ...string) *DomainError {
	return of(pick(CodeSys001, code), 500, detail, nil)
}

func pick(def string, codes []string) string {
	if len(codes) > 0 && codes[0] != "" {
		return codes[0]
	}
	return def
}

// AsDomain mengekstrak *DomainError dari error apa pun (nil bila bukan).
func AsDomain(err error) (*DomainError, bool) {
	de, ok := err.(*DomainError)
	return de, ok
}
