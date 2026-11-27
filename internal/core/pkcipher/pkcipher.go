// Package pkcipher — padanan core/common/pk-cipher NestJS: enkripsi primary
// key autoincrement jadi token opak base64url untuk FE.
//
//	token = base64url( iv(12B) || authTag(16B) || ciphertext )
//	AES-256-GCM; kunci = SHA-256("nexierp:pk-cipher:v1:" + PK_CIPHER_SECRET)
//	(fallback JWT_ACCESS_SECRET). Hanya id numerik >= 1.
package pkcipher

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
)

var ErrTokenTidakSah = errors.New("pk-cipher: token tidak sah")

type Cipher struct{ gcm cipher.AEAD }

// New — secret = PK_CIPHER_SECRET (fallback JWT_ACCESS_SECRET, persis NestJS).
func New(secret string) (*Cipher, error) {
	sum := sha256.Sum256([]byte("nexierp:pk-cipher:v1:" + secret))
	block, err := aes.NewCipher(sum[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Cipher{gcm: gcm}, nil
}

// EncryptID — token BERBEDA setiap pemanggilan (IV acak), persis NestJS.
func (c *Cipher) EncryptID(id int64) (string, error) {
	if id < 1 {
		return "", ErrTokenTidakSah
	}
	iv := make([]byte, 12)
	if _, err := rand.Read(iv); err != nil {
		return "", err
	}
	ct := c.gcm.Seal(nil, iv, []byte(strconv.FormatInt(id, 10)), nil)
	out := append(append([]byte{}, iv...), ct...) // ct = ciphertext||tag (GCM)
	return base64.RawURLEncoding.EncodeToString(out), nil
}

// TryDecryptID — null bila token rusak/id < 1 (padanan tryDecryptId).
func (c *Cipher) TryDecryptID(token string) *int64 {
	id, err := c.DecryptID(token)
	if err != nil {
		return nil
	}
	return &id
}

// DecryptID — throw padanan decryptId (PkCipherError).
func (c *Cipher) DecryptID(token string) (int64, error) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) < 12+16 {
		return 0, ErrTokenTidakSah
	}
	iv, ct := raw[:12], raw[12:]
	plain, err := c.gcm.Open(nil, iv, ct, nil)
	if err != nil {
		return 0, ErrTokenTidakSah
	}
	id, err := strconv.ParseInt(string(plain), 10, 64)
	if err != nil || id < 1 || id > (1<<53) { // max Number.MAX_SAFE_INTEGER
		return 0, fmt.Errorf("%w: id di luar jangkauan", ErrTokenTidakSah)
	}
	return id, nil
}
