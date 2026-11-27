// Handshake koneksi — padanan rbac.gateway.ts + realtime-io.adapter.ts:
// Origin diperiksa seperti CORS adapter (WEB_ORIGIN), kredensial dibaca dari
// header HTTP yang sama dengan REST (cookie ruang web `nexierp_at`, ruang
// portal `ecom_at`, ATAU `Authorization: Bearer`), lalu JwtAuthGuard-paritas:
// auth.ParseAccessToken → auth.CekSesiAktif (isValid/revoked/expiry/user
// aktif). Gagal = tolak koneksi (deny-by-default).
package realtime

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/coder/websocket"

	"nexierp/internal/core/auth"
)

// ServeHTTP — pasang di mux path `/ws` (mis. `mux.Handle("/ws", hub)`).
// Semua pemeriksaan dilakukan SEBELUM Accept: penolakan berupa HTTP error
// biasa (403 origin / 401 unauthenticated) — koneksi tak pernah terbuka.
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !h.originBoleh(r) {
		h.log.Warn("Koneksi realtime ditolak — origin tak dikenal", "origin", r.Header.Get("Origin"))
		http.Error(w, "origin tidak diizinkan", http.StatusForbidden)
		return
	}
	klaim, err := h.autentikasi(r)
	if err != nil {
		h.log.Warn("Koneksi realtime ditolak (unauthenticated)", "err", err.Error())
		http.Error(w, "unauthenticated", http.StatusUnauthorized)
		return
	}
	// Origin sudah divalidasi sendiri di atas → skip cek origin bawaan lib.
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return // client membatalkan handshake — tidak ada yang bisa dilakukan
	}
	k := &koneksiWS{conn: conn}
	h.daftarkan(RoomUser(klaim.Sub), k)
	h.log.Debug("Realtime connect", "user", klaim.Sub, "username", klaim.Username)
	// Tidak ada handler pesan client — baca dibuang sampai close;
	// selesai = koneksi putus → keluar room.
	h.loopBaca(k, r.Context())
	h.lepas(k)
}

// loopBaca membuang semua pesan client sampai koneksi tutup (baca error
// apa pun = koneksi berakhir).
func (h *Hub) loopBaca(k *koneksiWS, ctx context.Context) {
	defer k.conn.Close(websocket.StatusNormalClosure, "")
	for {
		if _, _, err := k.conn.Read(ctx); err != nil {
			return
		}
	}
}

// originBoleh — padanan CORS adapter: origin kosong (non-browser) lolos;
// allowlist kosong = tidak dibatasi; selain itu origin HARUS ada di daftar
// (pembandingan persis, nilai Env sudah bersih dari trailing slash).
func (h *Hub) originBoleh(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" || len(h.deps.OriginAllow) == 0 {
		return true
	}
	for _, boleh := range h.deps.OriginAllow {
		if boleh == origin {
			return true
		}
	}
	return false
}

// autentikasi mencoba tiap kandidat token (cookie web → cookie portal →
// Bearer): yang pertama lolos ParseAccessToken + CekSesiAktif menang.
// Semua gagal / tidak ada kandidat → error (tolak).
func (h *Hub) autentikasi(r *http.Request) (*auth.Claims, error) {
	if h.deps.Pool == nil {
		return nil, fmt.Errorf("pool database tidak tersedia")
	}
	kandidat := kandidatToken(r)
	if len(kandidat) == 0 {
		return nil, fmt.Errorf("token tidak ada")
	}
	var gagalTerakhir error
	for _, raw := range kandidat {
		klaim, err := auth.ParseAccessToken(h.deps.AccessSecret, raw)
		if err != nil {
			gagalTerakhir = err
			continue // kandidat berikutnya
		}
		if err := auth.CekSesiAktif(r.Context(), h.deps.Pool, klaim.SID, klaim.Sub); err != nil {
			gagalTerakhir = err
			continue
		}
		return klaim, nil
	}
	return nil, fmt.Errorf("token tidak valid: %w", gagalTerakhir)
}

// kandidatToken mengumpulkan token dari cookie `nexierp_at`, `ecom_at`
// (dua ruang cookie — dukung keduanya) dan header Authorization Bearer.
func kandidatToken(r *http.Request) []string {
	var kandidat []string
	for _, nama := range []string{"nexierp_at", "ecom_at"} {
		if c, err := r.Cookie(nama); err == nil && c.Value != "" {
			kandidat = append(kandidat, c.Value)
		}
	}
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		if t := strings.TrimSpace(strings.TrimPrefix(h, "Bearer ")); t != "" {
			kandidat = append(kandidat, t)
		}
	}
	return kandidat
}
