// Unit test murni service mailer: status/aktif/pengirim/potong300/uuid.
package mailer

import (
	"regexp"
	"strings"
	"testing"

	"nexierp/internal/core/config"
)

func envMail() *config.Env {
	return &config.Env{
		MailHost:        "smtp.example.com",
		MailPort:        587,
		MailUsername:    "noreply@example.com",
		MailPassword:    "rahasia",
		MailEncryption:  "tls",
		MailFromAddress: "noreply@example.com",
		MailFromName:    "NEXIERP Notifikasi",
	}
}

func TestAktif(t *testing.T) {
	s := New(envMail())
	if !s.Aktif() {
		t.Fatal("MailHost terisi harus aktif")
	}
	matikan := envMail()
	matikan.MailHost = ""
	if New(matikan).Aktif() {
		t.Fatal("MailHost kosong harus nonaktif")
	}
}

func TestKirimNonaktifTetapSuksesTanpaDB(t *testing.T) {
	e := envMail()
	e.MailHost = ""
	s := New(e) // db belum dipasang — catat hanya peringatan
	res := s.Kirim(t.Context(), MailPayload{Kepada: "budi@example.com", Subjek: "s", Jenis: "TES", HTML: "<p>h</p>"})
	if res.Terkirim || res.Status != MailStatusNonaktif || res.Error != nil {
		t.Fatalf("hasil nonaktif salah: %+v", res)
	}
}

func TestKirimTanpaPengirimGagalTanpaPanic(t *testing.T) {
	e := envMail()
	e.MailFromAddress = ""
	e.MailUsername = ""
	s := New(e)
	res := s.Kirim(t.Context(), MailPayload{Kepada: "budi@example.com", Subjek: "s", Jenis: "TES", HTML: "<p>h</p>"})
	if res.Terkirim || res.Status != MailStatusGagal {
		t.Fatalf("hasil gagal-pengirim salah: %+v", res)
	}
	if res.Error == nil || !strings.Contains(*res.Error, "MAIL_FROM_ADDRESS/MAIL_USERNAME kosong") {
		t.Fatalf("pesan error pengirim salah: %v", res.Error)
	}
}

func TestPengirimDefault(t *testing.T) {
	s := New(envMail())
	if got, mau := s.PengirimDefault(), `"NEXIERP Notifikasi" <noreply@example.com>`; got != mau {
		t.Fatalf("PengirimDefault() = %q, mau %q", got, mau)
	}
	tanpaNama := envMail()
	tanpaNama.MailFromName = ""
	if got := New(tanpaNama).PengirimDefault(); got != "noreply@example.com" {
		t.Fatalf("tanpa nama = %q, mau alamat polos", got)
	}
	// Fallback MAIL_USERNAME.
	fallback := envMail()
	fallback.MailFromAddress = ""
	if got := New(fallback).PengirimDefault(); got != `"NEXIERP Notifikasi" <noreply@example.com>` {
		t.Fatalf("fallback username = %q", got)
	}
	if got := New(&config.Env{}).PengirimDefault(); got != "" {
		t.Fatalf("kosong = %q, mau \"\"", got)
	}
}

func TestPotong300(t *testing.T) {
	if got := potong300(strings.Repeat("a", 300)); len(got) != 300 {
		t.Fatalf("300 persis tidak boleh terpotong: %d", len(got))
	}
	got := potong300(strings.Repeat("a", 400))
	if got != strings.Repeat("a", 297)+"…" {
		t.Fatalf("potong300 isi salah: %q", got)
	}
	if n := len([]rune(got)); n != 298 {
		t.Fatalf("potong300 panjang = %d rune, mau 298", n)
	}
	// Rune multi-byte tidak dipotong di tengah karakter.
	got = potong300(strings.Repeat("é", 400))
	if !strings.HasSuffix(got, "…") {
		t.Fatal("harus berakhir ellipsis")
	}
}

func TestUUIDV4(t *testing.T) {
	re := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	for i := 0; i < 50; i++ {
		if !re.MatchString(uuidV4()) {
			t.Fatalf("uuidV4 format salah: %q", uuidV4())
		}
	}
	if uuidV4() == uuidV4() {
		t.Fatal("dua uuid berturut tidak boleh sama")
	}
}
