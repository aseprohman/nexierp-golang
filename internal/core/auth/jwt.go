// JWT HS256 mandiri (stdlib) — padanan @nestjs/jwt (jsonwebtoken) untuk
// kebutuhan kernel auth: sign/verify access + refresh token, cek exp.
// Tanpa dependensi baru: header/payload JSON + HMAC-SHA256 + base64url.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// ErrTokenTidakValid — signature/format/klaim tidak sah.
var ErrTokenTidakValid = errors.New("token tidak valid")

// ErrTokenKedaluwarsa — exp sudah lewat (verifikasi jsonwebtoken default).
var ErrTokenKedaluwarsa = errors.New("token kedaluwarsa")

var b64Token = base64.RawURLEncoding

// headerHS256 — {"alg":"HS256","typ":"JWT"} bentuk biner tetap (field
// terurut persis jsonwebtoken).
var headerHS256 = []byte(`{"alg":"HS256","typ":"JWT"}`)

// signHS256 — tanda tangan payload klaim dengan secret.
func signHS256(secret string, claims Claims) string {
	payload, err := json.Marshal(claims)
	if err != nil {
		panic("klaim JWT tidak dapat di-marshal: " + err.Error())
	}
	input := b64Token.EncodeToString(headerHS256) + "." + b64Token.EncodeToString(payload)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(input))
	return input + "." + b64Token.EncodeToString(mac.Sum(nil))
}

// SignAccessToken — {sub, username, sid} + exp = iat + ttl (padanan
// jwt.signAsync dengan secret access).
func SignAccessToken(secret string, userID int64, username string, sessionID int64, ttl time.Duration) string {
	now := time.Now()
	return signHS256(secret, Claims{
		Sub:      userID,
		Username: username,
		SID:      sessionID,
		Exp:      now.Add(ttl).Unix(),
		Iat:      now.Unix(),
	})
}

// SignRefreshToken — token refresh secret terpisah + jti acak; ttl detik
// = sisa umur sesi (min 60 dtk — dihitung caller).
func SignRefreshToken(secret string, userID int64, username string, sessionID int64, ttlSec int64, jti string) string {
	now := time.Now()
	return signHS256(secret, Claims{
		Sub:      userID,
		Username: username,
		SID:      sessionID,
		JTI:      jti,
		Exp:      now.Unix() + ttlSec,
		Iat:      now.Unix(),
	})
}

// ParseAccessToken — verifikasi signature HS256 + exp (kontrak export
// untuk modul lain). Signature salah/format rusak → ErrTokenTidakValid;
// exp <= now → ErrTokenKedaluwarsa.
func ParseAccessToken(secret, raw string) (*Claims, error) {
	// token = header.payload.signature (3 segmen base64url tanpa padding)
	var parts [3]int
	segmen := 0
	for i := 0; i < len(raw) && segmen < 3; i++ {
		if raw[i] == '.' {
			parts[segmen] = i
			segmen++
		}
	}
	if segmen != 2 || parts[0] == 0 || parts[1] == parts[0]+1 || parts[1] == len(raw)-1 {
		return nil, ErrTokenTidakValid
	}
	input := raw[:parts[1]]
	sig, err := b64Token.DecodeString(raw[parts[1]+1:])
	if err != nil {
		return nil, ErrTokenTidakValid
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(input))
	if !hmac.Equal(mac.Sum(nil), sig) {
		return nil, ErrTokenTidakValid
	}
	payload, err := b64Token.DecodeString(raw[parts[0]+1 : parts[1]])
	if err != nil {
		return nil, ErrTokenTidakValid
	}
	var claims Claims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, ErrTokenTidakValid
	}
	if claims.Exp != 0 && time.Now().Unix() >= claims.Exp {
		return nil, fmt.Errorf("%w (exp %d)", ErrTokenKedaluwarsa, claims.Exp)
	}
	return &claims, nil
}
