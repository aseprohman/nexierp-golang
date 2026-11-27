// Helper id entity — padanan newEntityId() NestJS (randomUUID) untuk kolom
// entity_id NOT NULL UNIQUE (core_files, core_media_categories).
package storage

import (
	"crypto/rand"
	"fmt"
)

// uuidV4 — bangun UUID v4 acak (format kanonik 8-4-4-4-12 hex).
func uuidV4() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // crypto/rand: gagal sistemik — fallback byte nol
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
