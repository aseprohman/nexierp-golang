// operasi.go — konteks & helper bersama fitur OPERASI-LAIN modul inv
// (mutasi, penyesuaian, picking, jadwal hitung): konteks mutasi (aktor audit
// dari JWT dibangun handler + userId utk evaluasi data-scope), resolusi
// param `:id` (token pk-cipher dulu, fallback angka positif — pesan 400
// VERBATIM `Param id '...' tidak sah.` padanan parseIdPositif inv.views.ts),
// helper aktor ketat/longgar (semantik sengaja BERBEDA — verbatim
// inv.views.ts: actorId menolak id 0; actorIdLonggar meneruskan apa pun),
// dan konversi pgtype kecil (prefix `op` — pengaman kolisi nama antar file
// fitur di package service yang sama).
package service

import (
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/pkcipher"
)

// Kode error INV yang hanya dipakai fitur operasi-lain (string verbatim
// KODE_ERROR_INV tipe.ts — kosakata domain/errors.go milik master sengaja
// tidak diubah agar bebas konflik antar agent).
const (
	opKodeInvSodDilanggar          = "INV-004"
	opKodeInvKonfigurasiTidakSah   = "INV-006"
	opKodeInvGerakanFinal          = "INV-012"
	opKodeInvKombinasiTidakLengkap = "INV-016"
	opKodeInvLangkahBelumSelesai   = "INV-019"
	opKodeInvJenisOperasiTidakSah  = "INV-020"
	opKodeInvGrTidakEligibel       = "INV-022"
)

// CtxMutasi — konteks mutasi operasi (padanan MutationContext): aktor audit
// WAJIB dari JWT (handler membangunnya), UserID utk keputusan data-scope
// 'storages' (0 = tidak diketahui → fail-open SEMUA).
type CtxMutasi struct {
	Actor  audit.Actor
	UserID int64
}

// opActorIDLonggar — id user aktor LONGGAR (tanpa guard `> 0`): meneruskan
// apa pun (`?? null`) — dipakai fitur mutasi (verbatim actorIdLonggar).
func opActorIDLonggar(c CtxMutasi) *int64 {
	return c.Actor.IDCoreUsers
}

// opActorID — id user aktor KETAT — menolak id 0 (null = sistem); dipakai
// fitur penyesuaian & jadwal (verbatim actorId).
func opActorID(c CtxMutasi) *int64 {
	if c.Actor.IDCoreUsers != nil && *c.Actor.IDCoreUsers > 0 {
		return c.Actor.IDCoreUsers
	}
	return nil
}

// opResolusiID — param `:id` baca: token pk-cipher dulu, fallback angka
// positif; token rusak/angka tidak sah → 400 `Param id '...' tidak sah.`
func opResolusiID(cipher *pkcipher.Cipher, raw string) (int64, error) {
	if id := cipher.TryDecryptID(raw); id != nil {
		return *id, nil
	}
	return opParseIDPositif(raw)
}

// opParseIDPositif — fallback angka positif setelah cipher.tryDecryptId;
// Number(raw) bukan integer > 0 → 400 badRequest `Param id '${raw}' tidak
// sah.` (verbatim parseIdPositif — bukan VAL-400 field).
func opParseIDPositif(raw string) (int64, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || id <= 0 {
		return 0, errkontrak.BadRequest(fmt.Sprintf("Param id '%s' tidak sah.", raw))
	}
	return id, nil
}

/* ------------------------------------------------------------------ */
/* Konversi pgtype kecil (prefix op — tidak bertabrakan antar fitur)    */
/* ------------------------------------------------------------------ */

// opIso — timestamptz NOT NULL → ISO-8601 toISOString().
func opIso(t pgtype.Timestamptz) string {
	return t.Time.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}

// opIsoP — time.Time → ISO-8601.
func opIsoP(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

// opWaktu — time.Time → pgtype.Timestamptz.
func opWaktu(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: true} }

// opTxt — pgtype.Text → *string (NULL → nil).
func opTxt(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

// opTeks — *string → pgtype.Text (nil = NULL).
func opTeks(v *string) pgtype.Text {
	if v == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *v, Valid: true}
}

// opI8 — pgtype.Int8 → *int64.
func opI8(v pgtype.Int8) *int64 {
	if !v.Valid {
		return nil
	}
	x := v.Int64
	return &x
}

// opI8N — *int64 → pgtype.Int8 (nil = NULL).
func opI8N(v *int64) pgtype.Int8 {
	if v == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *v, Valid: true}
}

// opI4 — pgtype.Int4 → *int32.
func opI4(v pgtype.Int4) *int32 {
	if !v.Valid {
		return nil
	}
	x := v.Int32
	return &x
}

// opAngka — pgtype.Numeric → float64 (fallback 0 — padanan angka0).
func opAngka(n pgtype.Numeric) float64 {
	f8, err := n.Float64Value()
	if err != nil || !f8.Valid {
		return 0
	}
	return f8.Float64
}

// opAngkaPtr — pgtype.Numeric → *float64 (NULL → nil — padanan angka).
func opAngkaPtr(n pgtype.Numeric) *float64 {
	f8, err := n.Float64Value()
	if err != nil || !f8.Valid {
		return nil
	}
	f := f8.Float64
	return &f
}

// opUuid — pgtype.UUID → string uuid standar ber-hubung.
func opUuid(u pgtype.UUID) string {
	b := make([]byte, 36)
	hex.Encode(b[0:8], u.Bytes[0:4])
	b[8] = '-'
	hex.Encode(b[9:13], u.Bytes[4:6])
	b[13] = '-'
	hex.Encode(b[14:18], u.Bytes[6:8])
	b[18] = '-'
	hex.Encode(b[19:23], u.Bytes[8:10])
	b[23] = '-'
	hex.Encode(b[24:36], u.Bytes[10:16])
	return string(b)
}

// opNumJS — float → string gaya JS Number (2 → "2"; 1.5 → "1.5").
func opNumJS(f float64) string {
	if f == float64(int64(f)) {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// opWaktuSekarang — now (dipisah agar mudah ditaut di test).
func opWaktuSekarang() time.Time { return time.Now() }

// opWaktuParse — tanggalDokumen ISO string → time (semantik `new Date(str)`):
// terima RFC3339 / date-only / datetime-lokal; gagal → 400 pesan verbatim
// gaya param.
func opWaktuParse(s string) (time.Time, error) {
	coba := []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02"}
	for _, layout := range coba {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, errkontrak.BadRequest(fmt.Sprintf("Tanggal tidak valid: %s.", s))
}

// opSnap — *string → nilai snapshot audit (string | nil).
func opSnap(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

// opNumN — float64 → pgtype.Numeric (toFixed(4) semantik — presisi penuh
// via format eksponensial).
func opNumN(f float64) pgtype.Numeric {
	var n pgtype.Numeric
	_ = n.ScanScientific(strconv.FormatFloat(f, 'e', -1, 64))
	return n
}

// opNumNp — *float64 → pgtype.Numeric (nil = NULL).
func opNumNp(f *float64) pgtype.Numeric {
	if f == nil {
		return pgtype.Numeric{}
	}
	return opNumN(*f)
}

// opI4N — *int32 → pgtype.Int4 (nil = NULL).
func opI4N(v *int32) pgtype.Int4 {
	if v == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *v, Valid: true}
}

// opFilterVal — nilai filter `?k=v` / `?filter[k]=v`; kosong → nil.
func opFilterVal(pr *errkontrak.PageRequest, key string) *string {
	if pr == nil {
		return nil
	}
	if v := pr.Filters[key]; v != "" {
		return &v
	}
	return nil
}
