// Unit test murni argon2id — tanpa DB/framework.
package auth

import (
	"strings"
	"testing"
)

func TestHashVerifyRoundTrip(t *testing.T) {
	hash := HashPassword("rahasia-123")
	if !strings.HasPrefix(hash, "$argon2id$v=19$m=19456,t=2,p=1$") {
		t.Fatalf("parameter default salah: %s", hash)
	}
	ok, err := VerifyPassword(hash, "rahasia-123")
	if err != nil || !ok {
		t.Fatalf("verifikasi benar gagal: ok=%v err=%v", ok, err)
	}
	ok, err = VerifyPassword(hash, "salah")
	if err != nil || ok {
		t.Fatalf("verifikasi salah harus false: ok=%v err=%v", ok, err)
	}
}

func TestHashSaltUnik(t *testing.T) {
	// dua hash sandi sama = salt berbeda.
	if HashPassword("sama") == HashPassword("sama") {
		t.Fatal("salt harus acak per panggilan")
	}
}

func TestVerifyPlaintextSeed(t *testing.T) {
	// seed plaintext (tanpa prefix $argon2) → kompare langsung.
	ok, err := VerifyPassword("admin123", "admin123")
	if err != nil || !ok {
		t.Fatalf("plaintext cocok harus true: ok=%v err=%v", ok, err)
	}
	ok, err = VerifyPassword("admin123", "lain")
	if err != nil || ok {
		t.Fatalf("plaintext beda harus false: ok=%v err=%v", ok, err)
	}
}

func TestVerifyArgon2i(t *testing.T) {
	// argon2i (tipe lain) tetap terverifikasi — flexi-verify.
	// salt = "saltsaltsaltsalt" (16 byte), key = "abcdefghijklmnop" (16 byte).
	hash := "$argon2i$v=19$m=19456,t=2,p=1$" +
		"c2FsdHNhbHRzYWx0c2FsdA$" + "YWJjZGVmZ2hpamtsbW5vcA"
	// hash palsu di atas: signature salah → false tanpa error format.
	ok, err := VerifyArgon2(hash, "x")
	if err != nil {
		t.Fatalf("argon2i tidak boleh error format: %v", err)
	}
	if ok {
		t.Fatal("key palsu tidak boleh lolos")
	}
}

func TestVerifyFormatRusak(t *testing.T) {
	if _, err := VerifyArgon2("bukan-hash", "x"); err == nil {
		t.Fatal("hash rusak harus error format")
	}
	// hash v=16 (versi tak didukung x/crypto) → false aman.
	v16 := "$argon2id$v=16$m=19456,t=2,p=1$c2FsdA$c2FsdA"
	ok, err := VerifyArgon2(v16, "x")
	if err != nil || ok {
		t.Fatalf("v=16 harus false aman: ok=%v err=%v", ok, err)
	}
}
