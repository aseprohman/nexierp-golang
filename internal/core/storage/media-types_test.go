// Unit test murni tipe media: mediaKindOf, scope regex, sanitasi nama,
// trim keterangan, parse id, potong rune.
package storage

import (
	"strings"
	"testing"
)

func TestMediaKindOf(t *testing.T) {
	kasus := map[string]MediaKind{
		"image/png":                MediaKindImage,
		"IMAGE/JPEG":               MediaKindImage,
		"application/pdf":          MediaKindPDF,
		"video/mp4":                MediaKindVideo,
		"audio/mpeg":               MediaKindAudio,
		"application/octet-stream": MediaKindFile,
		"":                         MediaKindFile,
		"application/vnd.openxml…": MediaKindFile,
	}
	for mime, mau := range kasus {
		if got := MediaKindOf(mime); got != mau {
			t.Fatalf("MediaKindOf(%q) = %q, mau %q", mime, got, mau)
		}
	}
}

func TestScopeValid(t *testing.T) {
	valid := []string{"general", "po-attachment", "hr-employee-photo", "a", "abc-123-x"}
	invalid := []string{"", "PO", "-awal", "akhir-", "do--bel", "ada spasi", "slASH", "titik.dot", "garis_bawah"}
	for _, s := range valid {
		if !ScopeValid(s) {
			t.Fatalf("ScopeValid(%q) = false, mau true", s)
		}
	}
	for _, s := range invalid {
		if ScopeValid(s) {
			t.Fatalf("ScopeValid(%q) = true, mau false", s)
		}
	}
}

func TestSanitizeName(t *testing.T) {
	kasus := []struct {
		in  string
		mau string
	}{
		{"laporan keuangan.pdf", "laporan-keuangan.pdf"},
		{"garis__ganda--minus.txt", "garis__ganda-minus.txt"}, // \w = huruf/angka/garis bawah — underscore dipertahankan
		{"  spasi  ", "spasi"},
		{"", "file"},
		{"---", "file"},
		{"sfç, café.png", "sfc-cafe-.png"}, // NFKD: ç→c+◌̧ — [◌̧,", "] satu run → satu dash
		{"kütü.q1.pdf", "ku-tu-.q1.pdf"},   // NFKD: kedua ü→u+◌̈ → dash (juga sebelum titik)
	}
	for _, k := range kasus {
		if got := SanitizeName(k.in); got != k.mau {
			t.Fatalf("SanitizeName(%q) = %q, mau %q", k.in, got, k.mau)
		}
	}
	// Nama sangat panjang dipotong 80 rune.
	panjang := SanitizeName(strings.Repeat("a", 200) + ".pdf")
	if len([]rune(panjang)) != 80 {
		t.Fatalf("SanitizeName panjang = %d rune, mau 80", len([]rune(panjang)))
	}
	if panjang != strings.Repeat("a", 80) {
		t.Fatalf("SanitizeName panjang isi salah: %q", panjang)
	}
}

func TestTrimOrNull(t *testing.T) {
	kosong := ""
	if got := TrimOrNull(nil); got != nil {
		t.Fatal("TrimOrNull(nil) harus nil")
	}
	if got := TrimOrNull(&kosong); got != nil {
		t.Fatal("TrimOrNull(\"\") harus nil")
	}
	spasi := "  catatan  "
	got := TrimOrNull(&spasi)
	if got == nil || *got != "catatan" {
		t.Fatalf("TrimOrNull spasi = %v, mau catatan", got)
	}
	panjang := strings.Repeat("x", 300)
	got = TrimOrNull(&panjang)
	if got == nil || len([]rune(*got)) != 200 {
		t.Fatalf("TrimOrNull panjang = %d, mau 200", len([]rune(*got)))
	}
}

func TestParseNumericID(t *testing.T) {
	if n, err := ParseNumericID("12", "id"); err != nil || n != 12 {
		t.Fatalf("ParseNumericID(12) = %d, %v", n, err)
	}
	for _, ref := range []string{"", "0", "-3", "abc", "12.5", " 7"} {
		if _, err := ParseNumericID(ref, "id"); err == nil {
			t.Fatalf("ParseNumericID(%q) harus error", ref)
		}
	}
}

func TestPotongRunes(t *testing.T) {
	if got := potongRunes("abc", 10); got != "abc" {
		t.Fatalf("potongRunes pendek salah: %q", got)
	}
	got := potongRunes(strings.Repeat("é", 150), 120)
	if len([]rune(got)) != 120 {
		t.Fatalf("potongRunes = %d rune, mau 120", len([]rune(got)))
	}
}
