// Parse body + validasi padanan zod — pesan & urutan issue PERSIS skema
// auth (parseBody shared + loginBodySchema, registerSchema packages/
// schemas, aktivasiBodySchema, kirimUlangAktivasiBodySchema,
// refreshBodySchema, changePasswordBodySchema). Gagal → 400 VAL-400
// detail "Body tidak valid" + issues [{field, message}] (field = path titik).
package auth

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"

	"nexierp/internal/core/errkontrak"
)

// Pesan default zod v3 (verbatim).
const (
	msgRequired     = "Required"
	msgInvalidEmail = "Invalid email" // default zod v3 (kirim-ulang)
)

// emailTidakValid — pesan kustom registerSchema.
const emailTidakValid = "Email tidak valid"

func msgMin(n int) string { return fmt.Sprintf("String must contain at least %d character(s)", n) }
func msgMax(n int) string { return fmt.Sprintf("String must contain at most %d character(s)", n) }
func msgBukanString(received string) string {
	return fmt.Sprintf("Expected string, received %s", received)
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

// decodeJSONBody — baca body request → map JSON; ok=false bila rusak/
// bukan objek (padankan safeParse gagal → detail "Body tidak valid").
func decodeJSONBody(c io.Reader) (map[string]any, bool) {
	body, err := io.ReadAll(c)
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

// strField — ambil field string: (nilai, ada issue?).
func strField(m map[string]any, key string) (string, *errkontrak.FieldIssue) {
	v, ada := m[key]
	if !ada {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgRequired}
	}
	if v == nil {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgBukanString("null")}
	}
	s, ok := v.(string)
	if !ok {
		return "", &errkontrak.FieldIssue{Field: key, Message: msgBukanString(namaTipeJSON(v))}
	}
	return s, nil
}

// validasiLogin — loginBodySchema {username min1, password min1}.
func validasiLogin(m map[string]any) (LoginInput, []errkontrak.FieldIssue) {
	var in LoginInput
	var issues []errkontrak.FieldIssue
	if v, iss := strField(m, "username"); iss != nil {
		issues = append(issues, *iss)
	} else {
		in.Username = v
		if len([]rune(v)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "username", Message: msgMin(1)})
		}
	}
	if v, iss := strField(m, "password"); iss != nil {
		issues = append(issues, *iss)
	} else {
		in.Password = v
		if len([]rune(v)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "password", Message: msgMin(1)})
		}
	}
	return in, issues
}

// reEmail — regex email default zod v3 (verbatim).
var reEmail = regexp.MustCompile(`^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$`)

// validasiEmail — satu field email dengan pesan kustom bila diminta
// (register: "Email tidak valid"; kirim-ulang: default "Invalid email").
func validasiEmail(m map[string]any, key, pesanKustom string, maks int) (string, []errkontrak.FieldIssue) {
	issues := []errkontrak.FieldIssue{}
	v, iss := strField(m, key)
	if iss != nil {
		issues = append(issues, *iss)
		return "", issues
	}
	v = strings.TrimSpace(v) // z.string().trim()
	// zod menjalankan semua check lalu mengumpulkan seluruh issue.
	if !reEmail.MatchString(v) {
		pesan := msgInvalidEmail
		if pesanKustom != "" {
			pesan = pesanKustom
		}
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: pesan})
	}
	if len([]rune(v)) > maks {
		issues = append(issues, errkontrak.FieldIssue{Field: key, Message: msgMax(maks)})
	}
	return v, issues
}

// validasiRegister — registerSchema packages/schemas (D-16 + ddl/81):
// {email trim email("Email tidak valid") max150, nama trim min1
// "Nama wajib diisi" max100, telepon trim max50 optional, sandi min8
// "Sandi minimal 8 karakter" max72}.
func validasiRegister(m map[string]any) (RegisterInput, []errkontrak.FieldIssue) {
	var in RegisterInput
	var issues []errkontrak.FieldIssue
	email, iss := validasiEmail(m, "email", emailTidakValid, 150)
	in.Email = email
	issues = append(issues, iss...)

	if v, f := strField(m, "nama"); f != nil {
		issues = append(issues, *f)
	} else {
		v = strings.TrimSpace(v)
		in.Nama = v
		if len([]rune(v)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: "Nama wajib diisi"})
		}
		if len([]rune(v)) > 100 {
			issues = append(issues, errkontrak.FieldIssue{Field: "nama", Message: msgMax(100)})
		}
	}

	// telepon: optional — absent valid; ada → string trim max50.
	if v, ada := m["telepon"]; ada && v != nil {
		s, ok := v.(string)
		if !ok {
			issues = append(issues, errkontrak.FieldIssue{Field: "telepon", Message: msgBukanString(namaTipeJSON(v))})
		} else {
			s = strings.TrimSpace(s)
			in.Telepon = s
			if len([]rune(s)) > 50 {
				issues = append(issues, errkontrak.FieldIssue{Field: "telepon", Message: msgMax(50)})
			}
		}
	}

	if v, f := strField(m, "sandi"); f != nil {
		issues = append(issues, *f)
	} else {
		in.Sandi = v
		if len([]rune(v)) < 8 {
			issues = append(issues, errkontrak.FieldIssue{Field: "sandi", Message: "Sandi minimal 8 karakter"})
		}
		if len([]rune(v)) > 72 {
			issues = append(issues, errkontrak.FieldIssue{Field: "sandi", Message: msgMax(72)})
		}
	}
	return in, issues
}

// validasiAktivasi — aktivasiBodySchema {token min10 "Token tidak valid" max200}.
func validasiAktivasi(m map[string]any) (AktivasiInput, []errkontrak.FieldIssue) {
	var in AktivasiInput
	var issues []errkontrak.FieldIssue
	if v, iss := strField(m, "token"); iss != nil {
		issues = append(issues, *iss)
	} else {
		in.Token = v
		if len([]rune(v)) < 10 {
			issues = append(issues, errkontrak.FieldIssue{Field: "token", Message: "Token tidak valid"})
		}
		if len([]rune(v)) > 200 {
			issues = append(issues, errkontrak.FieldIssue{Field: "token", Message: msgMax(200)})
		}
	}
	return in, issues
}

// validasiKirimUlang — kirimUlangAktivasiBodySchema {email trim email max150}.
func validasiKirimUlang(m map[string]any) (KirimUlangInput, []errkontrak.FieldIssue) {
	var in KirimUlangInput
	email, issues := validasiEmail(m, "email", "", 150)
	in.Email = email
	return in, issues
}

// validasiChangePassword — changePasswordBodySchema {currentPassword min1,
// newPassword min6} (untuk pre-parse handler; cek pesan spesifik ada di
// service — urutan & pesan persis NestJS).
func validasiChangePassword(m map[string]any) (ChangePasswordInput, []errkontrak.FieldIssue) {
	var in ChangePasswordInput
	var issues []errkontrak.FieldIssue
	if v, iss := strField(m, "currentPassword"); iss != nil {
		issues = append(issues, *iss)
	} else {
		in.CurrentPassword = v
		if len([]rune(v)) < 1 {
			issues = append(issues, errkontrak.FieldIssue{Field: "currentPassword", Message: msgMin(1)})
		}
	}
	if v, iss := strField(m, "newPassword"); iss != nil {
		issues = append(issues, *iss)
	} else {
		in.NewPassword = v
		if len([]rune(v)) < 6 {
			issues = append(issues, errkontrak.FieldIssue{Field: "newPassword", Message: msgMin(6)})
		}
	}
	return in, issues
}

// refreshFromBody — refreshBodySchema {refreshToken min1} safeParse:
// sukses → token; gagal (bentuk salah/kosong) → "" = fallback cookie.
func refreshFromBody(m map[string]any) string {
	v, ada := m["refreshToken"]
	if !ada || v == nil {
		return ""
	}
	s, ok := v.(string)
	if !ok || len([]rune(s)) < 1 {
		return ""
	}
	return s
}
