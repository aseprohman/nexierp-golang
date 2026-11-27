// Unit test murni helper domain — tanpa DB/framework.
package auth

import (
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

func TestMaskedHash(t *testing.T) {
	got := MaskedHash("abcd123456")
	want := "abcd" + strings.Repeat("•", 12)
	if got != want {
		t.Fatalf("masked salah: %q (want %q)", got, want)
	}
	// sandi < 4 karakter = apa adanya + bullet.
	if got := MaskedHash("ab"); got != "ab"+strings.Repeat("•", 12) {
		t.Fatalf("masked pendek salah: %q", got)
	}
}

func TestFormatJamMenit(t *testing.T) {
	// 2 digit jam:menit (port toLocaleTimeString id-ID 2-digit).
	tt := time.Date(2026, 11, 27, 9, 5, 0, 0, time.UTC)
	if got := formatJamMenit(tt); got != "09.05" {
		t.Fatalf("format jam salah: %q", got)
	}
	tt = time.Date(2026, 11, 27, 14, 30, 0, 0, time.UTC)
	if got := formatJamMenit(tt); got != "14.30" {
		t.Fatalf("format jam salah: %q", got)
	}
}

func TestSHA256Hex(t *testing.T) {
	// vektor resmi NIST untuk "abc".
	if got := SHA256Hex("abc"); got != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("sha256 salah: %s", got)
	}
}

func TestBuatTokenAktivasi(t *testing.T) {
	now := time.Now()
	tok := BuatTokenAktivasi(now)
	if len(tok.Mentah) != 64 {
		t.Fatalf("token mentah harus 64-hex, dapat %d", len(tok.Mentah))
	}
	if _, err := hex.DecodeString(tok.Mentah); err != nil {
		t.Fatalf("token mentah bukan hex: %v", err)
	}
	if tok.Hash != SHA256Hex(tok.Mentah) {
		t.Fatalf("hash bukan SHA-256 mentah: %s", tok.Hash)
	}
	if !tok.BerlakuHingga.Equal(now.Add(24 * time.Hour)) {
		t.Fatalf("TTL aktivasi harus 24 jam: %v", tok.BerlakuHingga)
	}
	// dua token = dua nilai acak berbeda.
	if tok.Mentah == BuatTokenAktivasi(now).Mentah {
		t.Fatal("token harus acak")
	}
}

func TestParseSecuritySettings(t *testing.T) {
	// nilai sah.
	got := parseSecuritySettings([]byte(`{"maxFailedAttempts":3,"lockoutMinutes":30,"sessionTtlHours":8}`))
	if got != (SecuritySettings{3, 30, 8}) {
		t.Fatalf("settings salah: %+v", got)
	}
	// baris hilang/JSON rusak → default.
	if got := parseSecuritySettings(nil); got != DefaultSecuritySettings {
		t.Fatalf("default salah: %+v", got)
	}
	if got := parseSecuritySettings([]byte(`{rusak`)); got != DefaultSecuritySettings {
		t.Fatalf("default rusak salah: %+v", got)
	}
	// nilai 0/negatif/bukan-angka → default per field (port numberOf).
	got = parseSecuritySettings([]byte(`{"maxFailedAttempts":0,"lockoutMinutes":-5,"sessionTtlHours":"tujuh"}`))
	if got != DefaultSecuritySettings {
		t.Fatalf("fallback default salah: %+v", got)
	}
}

func TestNumberOf(t *testing.T) {
	if numberOf(float64(5), 9) != 5 {
		t.Fatal("angka sah harus dipakai")
	}
	if numberOf(float64(0), 9) != 9 || numberOf(float64(-1), 9) != 9 {
		t.Fatal("angka <= 0 harus fallback")
	}
	if numberOf("x", 9) != 9 || numberOf(nil, 9) != 9 {
		t.Fatal("bukan angka harus fallback")
	}
}

func TestRandomUUID(t *testing.T) {
	u := RandomUUID()
	if len(u) != 36 || strings.Count(u, "-") != 4 {
		t.Fatalf("format uuid salah: %q", u)
	}
	// versi 4 + varian RFC 4122.
	if u[14] != '4' {
		t.Fatalf("bukan versi 4: %q", u)
	}
	b, ok := ParseUUIDHex(u)
	if !ok || (b[8]&0xc0) != 0x80 {
		t.Fatalf("varian uuid salah: %q", u)
	}
	// dua uuid berbeda.
	if u == RandomUUID() {
		t.Fatal("uuid harus acak")
	}
	// ParseUUIDHex menerima hex polos & kanonis.
	if _, ok := ParseUUIDHex(strings.ReplaceAll(u, "-", "")); !ok {
		t.Fatal("hex polos harus bisa diparse")
	}
	if _, ok := ParseUUIDHex("zz"); ok {
		t.Fatal("string pendek harus gagal")
	}
}

func TestRandomHex(t *testing.T) {
	if len(RandomHex(32)) != 64 {
		t.Fatal("32 byte = 64 hex")
	}
	if len(RandomHex(48)) != 96 {
		t.Fatal("48 byte = 96 hex")
	}
}

func TestIsoOf(t *testing.T) {
	// persis toISOString(): 3 digit milidetik + Z.
	tt := time.Date(2026, 11, 27, 6, 2, 3, 4_000_000, time.UTC)
	if got := isoOf(tt); got != "2026-11-27T06:02:03.004Z" {
		t.Fatalf("iso salah: %s", got)
	}
}
