// Unit test murni validasi body — pesan & urutan issue PERSIS skema zod.
package auth

import (
	"strings"
	"testing"

	"nexierp/internal/core/errkontrak"
)

// helper ambil issue berdasar field.
func issueOf(t *testing.T, issues []errkontrak.FieldIssue, field string) string {
	t.Helper()
	for _, is := range issues {
		if is.Field == field {
			return is.Message
		}
	}
	t.Fatalf("issue field %q tidak ada di %v", field, issues)
	return ""
}

func TestValidasiLoginRequired(t *testing.T) {
	in, issues := validasiLogin(map[string]any{})
	if len(issues) != 2 {
		t.Fatalf("harus 2 issue, dapat %d: %v", len(issues), issues)
	}
	if got := issueOf(t, issues, "username"); got != "Required" {
		t.Fatalf("pesan username salah: %q", got)
	}
	if got := issueOf(t, issues, "password"); got != "Required" {
		t.Fatalf("pesan password salah: %q", got)
	}
	_ = in
}

func TestValidasiLoginTipeSalah(t *testing.T) {
	_, issues := validasiLogin(map[string]any{"username": float64(1), "password": nil})
	if got := issueOf(t, issues, "username"); got != "Expected string, received number" {
		t.Fatalf("pesan tipe salah: %q", got)
	}
	if got := issueOf(t, issues, "password"); got != "Expected string, received null" {
		t.Fatalf("pesan null salah: %q", got)
	}
}

func TestValidasiRegisterPesanKustom(t *testing.T) {
	_, issues := validasiRegister(map[string]any{
		"email": "bukan-email",
		"nama":  "  ",
		"sandi": "pendek",
	})
	if got := issueOf(t, issues, "email"); got != "Email tidak valid" {
		t.Fatalf("pesan email salah: %q", got)
	}
	if got := issueOf(t, issues, "nama"); got != "Nama wajib diisi" {
		t.Fatalf("pesan nama salah: %q", got)
	}
	if got := issueOf(t, issues, "sandi"); got != "Sandi minimal 8 karakter" {
		t.Fatalf("pesan sandi salah: %q", got)
	}
}

func TestValidasiRegisterSuksesTrim(t *testing.T) {
	in, issues := validasiRegister(map[string]any{
		"email":   "  user@example.com  ",
		"nama":    " Andi ",
		"telepon": " 0812 ",
		"sandi":   "sandi-panjang",
	})
	if len(issues) != 0 {
		t.Fatalf("input sah tidak boleh ada issue: %v", issues)
	}
	if in.Email != "user@example.com" || in.Nama != "Andi" || in.Telepon != "0812" {
		t.Fatalf("trim tidak bekerja: %+v", in)
	}
}

func TestValidasiRegisterEmailMax(t *testing.T) {
	panjang := strings.Repeat("a", 150) + "@example.com" // valid tapi >150
	_, issues := validasiRegister(map[string]any{
		"email": panjang,
		"nama":  "Andi",
		"sandi": "sandi-panjang",
	})
	// email valid tapi >150 → issue max 150 (check kedua tetap dilaporkan).
	if got := issueOf(t, issues, "email"); got != "String must contain at most 150 character(s)" {
		t.Fatalf("pesan max email salah: %q (%v)", got, issues)
	}
}

func TestValidasiAktivasi(t *testing.T) {
	_, issues := validasiAktivasi(map[string]any{"token": "pendek"})
	if got := issueOf(t, issues, "token"); got != "Token tidak valid" {
		t.Fatalf("pesan token salah: %q", got)
	}
	_, issues = validasiAktivasi(map[string]any{"token": strings.Repeat("x", 201)})
	if got := issueOf(t, issues, "token"); got != "String must contain at most 200 character(s)" {
		t.Fatalf("pesan max token salah: %q", got)
	}
}

func TestValidasiKirimUlangEmailDefault(t *testing.T) {
	_, issues := validasiKirimUlang(map[string]any{"email": "rusak"})
	if got := issueOf(t, issues, "email"); got != "Invalid email" {
		t.Fatalf("pesan email default salah: %q", got)
	}
}

func TestValidasiChangePasswordUrutan(t *testing.T) {
	// string kosong → min issue (map kosong = Required).
	_, issues := validasiChangePassword(map[string]any{"currentPassword": "", "newPassword": ""})
	if len(issues) != 2 || issues[0].Field != "currentPassword" || issues[1].Field != "newPassword" {
		t.Fatalf("urutan issue salah: %v", issues)
	}
	if issues[0].Message != "String must contain at least 1 character(s)" {
		t.Fatalf("pesan current salah: %q", issues[0].Message)
	}
	if issues[1].Message != "String must contain at least 6 character(s)" {
		t.Fatalf("pesan new salah: %q", issues[1].Message)
	}
}

func TestRefreshFromBodyOpsional(t *testing.T) {
	if got := refreshFromBody(map[string]any{}); got != "" {
		t.Fatalf("tanpa body harus kosong: %q", got)
	}
	if got := refreshFromBody(map[string]any{"refreshToken": "tok"}); got != "tok" {
		t.Fatalf("token dari body salah: %q", got)
	}
	// refreshToken kosong → safeParse gagal → kosong (fallback cookie).
	if got := refreshFromBody(map[string]any{"refreshToken": ""}); got != "" {
		t.Fatalf("token kosong harus fallback: %q", got)
	}
	// refreshToken tipe salah → fallback cookie.
	if got := refreshFromBody(map[string]any{"refreshToken": float64(9)}); got != "" {
		t.Fatalf("token tipe salah harus fallback: %q", got)
	}
}
