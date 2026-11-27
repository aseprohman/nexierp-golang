// Helper murni area auth — hash SHA-256, token aktivasi, UUID acak,
// masked hash password, format jam:menit, parse settings core_meta.
// Semua TANPA DB/framework (unit-testable).
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"
)

// TTL token aktivasi — 24 jam (ddl/81; kirim-ulang mengganti token).
const ttlAktivasi = 24 * time.Hour

// SHA256Hex — benturan token_hash core_auth_tokens.
func SHA256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// TokenAktivasi — pasangan token mentah + hash + masa berlaku.
type TokenAktivasi struct {
	Mentah        string // 64-hex (32 byte acak) — hanya hidup di email
	Hash          string // SHA-256 hex — yang disimpan DB
	BerlakuHingga time.Time
}

// BuatTokenAktivasi — port buatTokenAktivasi: mentah 32-byte hex,
// DB simpan SHA-256, TTL 24 jam.
func BuatTokenAktivasi(now time.Time) TokenAktivasi {
	mentah := RandomHex(32)
	return TokenAktivasi{
		Mentah:        mentah,
		Hash:          SHA256Hex(mentah),
		BerlakuHingga: now.Add(ttlAktivasi),
	}
}

// MaskedHash — core_password_history.masked_hash: 4 karakter pertama
// sandi + 12 titik-tengah "•" (port `${slice(0,4)}${"•".repeat(12)}`).
func MaskedHash(sandi string) string {
	awalan := []rune(sandi)
	if len(awalan) > 4 {
		awalan = awalan[:4]
	}
	return string(awalan) + strings.Repeat("•", 12)
}

// RandomHex — n byte acak → hex (mis. 32 byte = jti/token 64-hex).
func RandomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand gagal = keadaan sistem rusak — panic seperti Node.
		panic("crypto/rand gagal: " + err.Error())
	}
	return hex.EncodeToString(b)
}

// formatJamMenit — padanan toLocaleTimeString("id-ID", {hour:"2-digit",
// minute:"2-digit"}) untuk pesan lockout: jam.menit 2 digit (id-ID memakai
// pemisah TITIK, mis. "15.04").
func formatJamMenit(t time.Time) string {
	return t.Format("15.04")
}

// numberOf — port numberOf NestJS: angka berhingga > 0 dipakai,
// selain itu fallback default.
func numberOf(v any, def int) int {
	f, ok := v.(float64)
	if !ok || math.IsNaN(f) || math.IsInf(f, 0) || f <= 0 {
		return def
	}
	return int(f)
}

// parseSecuritySettings — nilai jsonb core_meta 'security' → settings;
// baris hilang / JSON rusak / field tak sah = fallback default.
func parseSecuritySettings(raw []byte) SecuritySettings {
	out := DefaultSecuritySettings
	if len(raw) == 0 {
		return out
	}
	var v map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		return out
	}
	out.MaxFailedAttempts = numberOf(v["maxFailedAttempts"], out.MaxFailedAttempts)
	out.LockoutMinutes = numberOf(v["lockoutMinutes"], out.LockoutMinutes)
	out.SessionTtlHours = numberOf(v["sessionTtlHours"], out.SessionTtlHours)
	return out
}

// ---------------------------------------------------------------------
// UUID v4 acak — tanpa dependensi eksternal (padanan randomUUID()).
// ---------------------------------------------------------------------

// RandomUUID — uuid v4 format kanonis 8-4-4-4-12.
func RandomUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("crypto/rand gagal: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40 // versi 4
	b[8] = (b[8] & 0x3f) | 0x80 // varian RFC 4122
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ParseUUIDHex — string uuid (kanonis atau hex polos) → 16 byte.
func ParseUUIDHex(s string) ([16]byte, bool) {
	var out [16]byte
	clean := strings.NewReplacer("-", "").Replace(s)
	if len(clean) != 32 {
		return out, false
	}
	b, err := hex.DecodeString(clean)
	if err != nil {
		return out, false
	}
	copy(out[:], b)
	return out, true
}
