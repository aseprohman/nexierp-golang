// Unit test murni template email (padanan shared/mail-template.ts).
package mailer

import (
	"strings"
	"testing"
)

func TestKemasHtmlEmailLengkap(t *testing.T) {
	hasil := KemasHtmlEmail(KemasHtmlEmailInput{
		Judul:    "Aktivasi Akun Member",
		Sapaan:   "Halo Budi,",
		Paragraf: []string{"Terima kasih telah mendaftar.", "Klik tombol berikut."},
		Tombol:   &TombolEmail{Label: "Aktifkan Akun", URL: "https://portal.example/aktivasi?t=abc"},
		Penutup:  []string{"Tautan kedaluwarsa 24 jam."},
	})

	// HTML memuat seluruh teks input + struktur inti.
	harusAda := []string{
		"<!DOCTYPE html>",
		`<html lang="id">`,
		"NEXIERP",
		"Aktivasi Akun Member",
		"Halo Budi,",
		"Terima kasih telah mendaftar.",
		"Klik tombol berikut.",
		`href="https://portal.example/aktivasi?t=abc"`,
		"Aktifkan Akun",
		"Bila tombol tidak berfungsi, salin tautan berikut ke peramban:",
		"Tautan kedaluwarsa 24 jam.",
		"Email otomatis dari NEXIERP — jangan balas email ini.",
		`<h1 style="margin:0 0 16px;font-size:20px;color:#0f172a">`,
		`<p style="margin:0 0 12px;font-size:14px;line-height:1.6;color:#334155">Terima kasih telah mendaftar.</p>`,
		`max-width:520px;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #e2e8f0`,
		`background:#4f46e5;color:#ffffff;text-decoration:none;`,
	}
	for _, potongan := range harusAda {
		if !strings.Contains(hasil.HTML, potongan) {
			t.Fatalf("HTML tidak memuat %q\nHTML:\n%s", potongan, hasil.HTML)
		}
	}

	// Teks polos — susunan baris persis padanan TS.
	mauTeks := strings.Join([]string{
		"NEXIERP",
		"",
		"Aktivasi Akun Member",
		"",
		"Halo Budi,",
		"",
		"Terima kasih telah mendaftar.",
		"Klik tombol berikut.",
		"",
		"Aktifkan Akun:",
		"https://portal.example/aktivasi?t=abc",
		"",
		"Tautan kedaluwarsa 24 jam.",
	}, "\n")
	if hasil.Teks != mauTeks {
		t.Fatalf("Teks tidak cocok:\ndapat:\n%s\nmau:\n%s", hasil.Teks, mauTeks)
	}
}

func TestKemasHtmlEmailMinimal(t *testing.T) {
	hasil := KemasHtmlEmail(KemasHtmlEmailInput{
		Judul:    "Reset Kata Sandi",
		Paragraf: []string{"Paragraf tunggal."},
	})
	if strings.Contains(hasil.HTML, `font-weight:700`) {
		t.Fatal("tanpa sapaan tidak boleh ada blok sapaan")
	}
	if strings.Contains(hasil.HTML, `<a href=`) {
		t.Fatal("tanpa tombol tidak boleh ada <a>")
	}
	if !strings.Contains(hasil.HTML, "<h1") || !strings.Contains(hasil.HTML, "Reset Kata Sandi") {
		t.Fatal("judul wajib ada di HTML")
	}
	if !strings.Contains(hasil.Teks, "NEXIERP\n\nReset Kata Sandi\n\nParagraf tunggal.") {
		t.Fatalf("Teks minimal salah:\n%s", hasil.Teks)
	}
	if strings.HasSuffix(hasil.Teks, "\n") {
		t.Fatal("teks tidak berakhir baris kosong")
	}
}
