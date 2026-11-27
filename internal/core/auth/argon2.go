// Verifikasi & hash password argon2id — padanan paket `argon2` NestJS.
// Hash seed plaintext diupgrade-on-login; hash produksi berformat PHC
// `$argon2id$v=19$m=…,t=…,p=…$salt$key` dan tetap terverifikasi apa pun
// parameternya (flexi-verify).
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Default parameter argon2id — persis default paket npm `argon2`
// (OWASP): memori 19456 KiB, waktu 2, thread 1, panjang kunci 32, salt 16.
const (
	argon2Memory  uint32 = 19456
	argon2Time    uint32 = 2
	argon2Threads uint8  = 1
	argon2KeyLen  uint32 = 32
	argon2SaltLen        = 16
)

var errArgon2Format = errors.New("hash argon2 tidak valid")

var reArgon2 = regexp.MustCompile(`^\$(argon2id|argon2i|argon2d)\$v=(\d+)\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$`)

// HashPassword — hash argon2id default (register & upgrade-on-login &
// ganti password). Salt acak 16 byte per panggilan.
func HashPassword(password string) string {
	salt := make([]byte, argon2SaltLen)
	if _, err := rand.Read(salt); err != nil {
		panic("crypto/rand gagal: " + err.Error())
	}
	key := argon2.IDKey([]byte(password), salt, argon2Time, argon2Memory, argon2Threads, argon2KeyLen)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argon2Memory, argon2Time, argon2Threads,
		b64.EncodeToString(salt), b64.EncodeToString(key))
}

// VerifyArgon2 — verifikasi PHC apa pun tipe/parameternya (port
// argon2.verify): parse param → hitung ulang → banding konstan-waktu.
func VerifyArgon2(hash, password string) (bool, error) {
	m := reArgon2.FindStringSubmatch(hash)
	if m == nil {
		return false, errArgon2Format
	}
	version, _ := strconv.Atoi(m[2])
	if version != argon2.Version {
		// x/crypto hanya menghitung v=19; hash v=16 (argon2 pra-1.2) tidak
		// bisa dihitung ulang — perlakukan gagal aman (Node menulis v=19).
		return false, nil
	}
	mem, _ := strconv.ParseUint(m[3], 10, 32)
	timeCost, _ := strconv.ParseUint(m[4], 10, 32)
	threads, _ := strconv.ParseUint(m[5], 10, 8)
	b64 := base64.RawStdEncoding
	salt, err := b64.DecodeString(m[6])
	if err != nil {
		return false, errArgon2Format
	}
	want, err := b64.DecodeString(m[7])
	if err != nil {
		return false, errArgon2Format
	}
	// Argon2i produksi lama tetap sah — tipe diikuti.
	var key []byte
	switch m[1] {
	case "argon2id":
		key = argon2.IDKey([]byte(password), salt, uint32(timeCost), uint32(mem), uint8(threads), uint32(len(want)))
	case "argon2i":
		key = argon2.Key([]byte(password), salt, uint32(timeCost), uint32(mem), uint8(threads), uint32(len(want)))
	default: // argon2d tidak disediakan x/crypto — perlakukan gagal aman
		return false, nil
	}
	return subtle.ConstantTimeCompare(key, want) == 1, nil
}

// VerifyPassword — port verifyPassword service:
//   - hash "$argon2…" → verifikasi argon2 (jalur produksi);
//   - selain itu = seed plaintext → kompare langsung (caller meng-upgrade).
func VerifyPassword(passwordHash, password string) (bool, error) {
	if strings.HasPrefix(passwordHash, "$argon2") {
		return VerifyArgon2(passwordHash, password)
	}
	return subtle.ConstantTimeCompare([]byte(passwordHash), []byte(password)) == 1, nil
}
