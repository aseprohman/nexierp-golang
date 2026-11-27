// Unit test murni JWT HS256 — tanpa DB/framework.
package auth

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestSignParseRoundTrip(t *testing.T) {
	secret := "rahasia-access-test"
	tok := SignAccessToken(secret, 42, "andi", 7, 15*time.Minute)
	claims, err := ParseAccessToken(secret, tok)
	if err != nil {
		t.Fatalf("parse gagal: %v", err)
	}
	if claims.Sub != 42 || claims.Username != "andi" || claims.SID != 7 {
		t.Fatalf("klaim tidak cocok: %+v", claims)
	}
	if claims.JTI != "" {
		t.Fatalf("access token tidak boleh punya jti: %q", claims.JTI)
	}
	if claims.Exp <= time.Now().Unix() {
		t.Fatalf("exp harus di masa depan: %d", claims.Exp)
	}
}

func TestParseExpiredToken(t *testing.T) {
	secret := "rahasia-access-test"
	tok := SignAccessToken(secret, 1, "budi", 2, -time.Second)
	_, err := ParseAccessToken(secret, tok)
	if !errors.Is(err, ErrTokenKedaluwarsa) {
		t.Fatalf("harus ErrTokenKedaluwarsa, dapat: %v", err)
	}
}

func TestParseWrongSecret(t *testing.T) {
	tok := SignAccessToken("secret-a", 1, "budi", 2, time.Minute)
	if _, err := ParseAccessToken("secret-b", tok); !errors.Is(err, ErrTokenTidakValid) {
		t.Fatalf("harus ErrTokenTidakValid, dapat: %v", err)
	}
}

func TestParseTamperedPayload(t *testing.T) {
	secret := "secret-a"
	tok := SignAccessToken(secret, 1, "budi", 2, time.Minute)
	parts := strings.Split(tok, ".")
	// ganti sub → signature tidak cocok lagi
	parts[1] = strings.TrimRight(
		b64Token.EncodeToString([]byte(`{"sub":99,"username":"budi","sid":2}`)), "=")
	tampered := strings.Join(parts, ".")
	if _, err := ParseAccessToken(secret, tampered); !errors.Is(err, ErrTokenTidakValid) {
		t.Fatalf("token manipulasi harus ditolak, dapat: %v", err)
	}
}

func TestParseMalformed(t *testing.T) {
	for _, raw := range []string{"", "abc", "a.b.c.d", "x.y.z", "....", ".."} {
		if _, err := ParseAccessToken("s", raw); !errors.Is(err, ErrTokenTidakValid) {
			t.Fatalf("raw %q harus ditolak, dapat: %v", raw, err)
		}
	}
}

func TestRefreshTokenJti(t *testing.T) {
	secret := "rahasia-refresh-test"
	jti := RandomHex(32)
	tok := SignRefreshToken(secret, 5, "cici", 9, 3600, jti)
	if len(jti) != 64 {
		t.Fatalf("jti harus 32 byte hex (64 char), dapat %d", len(jti))
	}
	claims, err := ParseAccessToken(secret, tok)
	if err != nil {
		t.Fatalf("parse refresh gagal: %v", err)
	}
	if claims.JTI != jti || claims.SID != 9 || claims.Sub != 5 {
		t.Fatalf("klaim refresh tidak cocok: %+v", claims)
	}
}

func TestRefreshExpiredMinTTL(t *testing.T) {
	secret := "rahasia-refresh-test"
	tok := SignRefreshToken(secret, 5, "cici", 9, -1, RandomHex(32))
	if _, err := ParseAccessToken(secret, tok); !errors.Is(err, ErrTokenKedaluwarsa) {
		t.Fatalf("refresh kedaluwarsa harus ditolak: %v", err)
	}
}
