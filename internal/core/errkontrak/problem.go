package errkontrak

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/labstack/echo/v4"
)

// Problem — dokumen RFC 7807 persis ProblemExceptionFilter NestJS.
type Problem struct {
	Type     string       `json:"type"`
	Title    string       `json:"title"`
	Status   int          `json:"status"`
	Detail   string       `json:"detail"`
	Instance string       `json:"instance"`
	Code     string       `json:"code"`
	Errors   []FieldIssue `json:"errors,omitempty"`
}

const problemTypeURN = "urn:nexierp:problem"

// statusToCode — padanan STATUS_TO_CODE filter NestJS.
func statusToCode(status int) string {
	switch status {
	case 400:
		return CodeVal400
	case 401:
		return CodeAuth401
	case 403:
		return CodeForb403
	case 404:
		return CodeNotf404
	case 409:
		return CodeConf409
	case 422:
		return CodeVal422
	case 429:
		return CodeRate429
	}
	return "ERR-" + strconv.Itoa(status)
}

// IsUniqueViolation — padanan deteksi 23505 (termasuk rantai cause).
func IsUniqueViolation(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		return pe.Code == "23505"
	}
	return false
}

// WriteProblem menulis problem+json — satu pintu bentuk error HTTP.
// instance = request URI apa adanya (padanan request.url NestJS).
func WriteProblem(c echo.Context, status int, code, detail string, errs []FieldIssue) error {
	if code == "" {
		code = statusToCode(status)
	}
	if status >= 500 && detail == "" {
		code = CodeSys000
		detail = DetailSystem
	}
	if detail == "" {
		detail = defaultDetailByStatus(status)
	}
	p := Problem{
		Type:     problemTypeURN + ":" + code,
		Title:    http.StatusText(status),
		Status:   status,
		Detail:   detail,
		Instance: c.Request().URL.RequestURI(),
		Code:     code,
		Errors:   errs,
	}
	return c.JSON(status, p)
}

// Map — pemetaan error apa pun → problem+json persis NestJS:
// DomainError → kode & statusnya; unique violation → 409 CONF-409
// ("Data dengan nilai unik yang sama sudah ada."); lainnya → 500 SYS-000
// dengan detail generik (internal tidak bocor).
func Map(c echo.Context, err error) error {
	if de, ok := AsDomain(err); ok {
		return WriteProblem(c, de.Status, de.Code, de.Detail, de.Errors)
	}
	if IsUniqueViolation(err) {
		return WriteProblem(c, 409, CodeConf409, "Data dengan nilai unik yang sama sudah ada.", nil)
	}
	if IsUniqueViolation(err) {
		return WriteProblem(c, 409, CodeConf409, "Data dengan nilai unik yang sama sudah ada.", nil)
	}
	// parity infra: NestJS pino mencatat 5xx — Go log error aslinya (detail tidak bocor ke klien).
	if slog.Default().Enabled(context.Background(), slog.LevelError) {
		slog.Default().Error("500", "err", err.Error(), "path", c.Request().URL.RequestURI())
	}
	return WriteProblem(c, 500, "", "", nil)
}

// OK — envelope sukses `{data}` (pembungkus manual, persis controller NestJS).
func OK(c echo.Context, data any) error {
	return c.JSON(http.StatusOK, map[string]any{"data": data})
}

// Created — envelope sukses 201 `{data}`.
func Created(c echo.Context, data any) error {
	return c.JSON(http.StatusCreated, map[string]any{"data": data})
}
