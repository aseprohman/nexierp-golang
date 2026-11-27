// pure.go — fungsi murni penomoran dokumen (padanan renderPrefix /
// formatCode / newEntityId yang diekspor NumberingService NestJS).
package numbering

import (
	crand "crypto/rand"
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// RenderPrefix — render `{MMyy}`/`{mmyy}`/`{yyyy}` pada prefix (basis UTC) —
// mis. `TRF/{MMyy}` → `TRF/1026`, `JV-{yyyy}` → `JV-2026`.
func RenderPrefix(prefix string, now time.Time) string {
	t := now.UTC()
	bulan := fmt.Sprintf("%02d", int(t.Month()))
	tahun := fmt.Sprintf("%02d", t.Year()%100) // padanan slice(-2)
	out := strings.ReplaceAll(prefix, "{MMyy}", bulan+tahun)
	out = strings.ReplaceAll(out, "{mmyy}", bulan+tahun)
	out = strings.ReplaceAll(out, "{yyyy}", strconv.Itoa(t.Year()))
	return out
}

// FormatCode — susun kode final dari alokasi — murni (unit-testable).
// Joiner default: "/" bila prefix mengandung "{" atau "/" (gaya
// `TRF/1026/0001`), "-" untuk prefix polos (gaya `MV-00001`).
func FormatCode(a Allocation, opt Options) string {
	now := time.Now()
	if opt.Now != nil {
		now = *opt.Now
	}
	rendered := RenderPrefix(a.Prefix, now)
	joiner := opt.Joiner
	if joiner == "" {
		if strings.Contains(a.Prefix, "{") || strings.Contains(a.Prefix, "/") {
			joiner = "/"
		} else {
			joiner = "-"
		}
	}
	padded := fmt.Sprintf("%0*d", a.Padding, a.Seq)
	return rendered + joiner + padded
}

// NewEntityID — id entity natural baru (kolom `entity_id` NOT NULL UNIQUE
// semua tabel): UUID v4 dari crypto/rand (google/uuid tidak ada di go.mod).
func NewEntityID() string {
	var b [16]byte
	if _, err := crand.Read(b[:]); err != nil {
		// crypto/rand praktis tak pernah gagal; fallback waktu tetap cukup unik
		now := uint64(time.Now().UnixNano())
		binary.BigEndian.PutUint64(b[0:8], now)
		binary.BigEndian.PutUint64(b[8:16], now^0x9E3779B97F4A7C15)
	}
	b[6] = (b[6] & 0x0f) | 0x40 // versi 4
	b[8] = (b[8] & 0x3f) | 0x80 // varian RFC 4122
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
