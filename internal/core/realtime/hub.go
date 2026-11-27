// Package realtime — hub WebSocket NATIVE (coder/websocket) path /ws,
// padanan core/realtime NestJS (Socket.IO dimatikan sejak G0 — ratifikasi
// arsitektur). Paritas perilaku rbac.gateway + realtime.service:
//   - handshake deny-by-default: JWT access + validasi core_sessions;
//   - sukses → join room `user:<sub>`;
//   - TANPA handler pesan client (baca dibuang sampai close);
//   - SATU event emit: `rbac.changed` {reason:"rbac"} (tanpa SubscribeMessage).
//
// Native WS tidak punya nama event seperti Socket.IO, maka event dibungkus
// amplop JSON {"event":..,"data":..} — bentuk kawat tetap eksplisit.
package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

// EventRbacChanged — satu-satunya event yang di-emit hub (kontrak kawat).
// Klien memuat ulang /auth/me saat menerima; payload bukan sumber data.
const EventRbacChanged = "rbac.changed"

// TimeoutTulisWS — batas waktu satu frame keluar (anti koneksi zombie).
const TimeoutTulisWS = 5 * time.Second

// RoomUser — nama room per-user (padanan userRoom()).
func RoomUser(userID int64) string {
	return "user:" + strconv.FormatInt(userID, 10)
}

// Deps — kebutuhan hub (padanan constructor NestJS).
type Deps struct {
	Pool         *pgxpool.Pool // validasi core_sessions di handshake
	AccessSecret string        // JWT access secret (JWT_ACCESS_SECRET)
	OriginAllow  []string      // allowlist origin (WEB_ORIGIN), kosong = tidak dibatasi
	Log          *slog.Logger
}

// pesanWS — amplop kawat native WS (pengganti nama event Socket.IO).
type pesanWS struct {
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

// koneksiWS — satu koneksi ter-auth. coder/websocket melarang penulis
// serentak → satu mutex per koneksi.
type koneksiWS struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

// kirim menulis frame teks dengan timeout; false = koneksi bermasalah
// (loop baca pemiliknya yang membersihkan — di sini hanya no-op aman).
func (k *koneksiWS) kirim(data []byte) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	ctx, batalkan := context.WithTimeout(context.Background(), TimeoutTulisWS)
	defer batalkan()
	return k.conn.Write(ctx, websocket.MessageText, data) == nil
}

// Hub — registry koneksi per room + emit terpusat (padanan RealtimeService).
type Hub struct {
	deps Deps
	log  *slog.Logger

	mu      sync.Mutex
	semua   map[*koneksiWS]struct{}
	ruangan map[string]map[*koneksiWS]struct{}
}

// NewHub membuat hub. Pasang ServeHTTP-nya di mux path `/ws`.
func NewHub(deps Deps) *Hub {
	if deps.Log == nil {
		deps.Log = slog.Default()
	}
	return &Hub{
		deps:    deps,
		log:     deps.Log,
		semua:   make(map[*koneksiWS]struct{}),
		ruangan: make(map[string]map[*koneksiWS]struct{}),
	}
}

// daftarkan memasukkan koneksi ke room `user:<id>` (setelah auth sukses).
func (h *Hub) daftarkan(room string, k *koneksiWS) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.semua[k] = struct{}{}
	set, ada := h.ruangan[room]
	if !ada {
		set = make(map[*koneksiWS]struct{})
		h.ruangan[room] = set
	}
	set[k] = struct{}{}
}

// lepas mengeluarkan koneksi dari semua room (koneksi putus).
func (h *Hub) lepas(k *koneksiWS) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.semua, k)
	for room, set := range h.ruangan {
		delete(set, k)
		if len(set) == 0 {
			delete(h.ruangan, room)
		}
	}
}

// EmitToUsers — marshal payload SEKALI lalu kirim ke semua koneksi room
// terkait. No-op aman bila tidak ada koneksi; TIDAK pernah throw (padanan
// realtime.service.emitToUsers).
func (h *Hub) EmitToUsers(userIDs []int64, event string, payload any) {
	data, err := marshalPesan(event, payload)
	if err != nil {
		h.log.Warn("Emit realtime gagal marshal", "event", event, "err", err.Error())
		return
	}
	h.mu.Lock()
	var target []*koneksiWS
	for _, id := range userIDs {
		for k := range h.ruangan[RoomUser(id)] {
			target = append(target, k)
		}
	}
	h.mu.Unlock()
	for _, k := range target {
		k.kirim(data)
	}
}

// emitSemua — kirim ke SEMUA koneksi aktif (padanan compiler.invalidateAll).
func (h *Hub) emitSemua(event string, payload any) {
	data, err := marshalPesan(event, payload)
	if err != nil {
		h.log.Warn("Emit realtime gagal marshal", "event", event, "err", err.Error())
		return
	}
	h.mu.Lock()
	target := make([]*koneksiWS, 0, len(h.semua))
	for k := range h.semua {
		target = append(target, k)
	}
	h.mu.Unlock()
	for _, k := range target {
		k.kirim(data)
	}
}

// marshalPesan membungkus payload menjadi amplop {"event":..,"data":..};
// payload di-marshal sekali (bukan per koneksi).
func marshalPesan(event string, payload any) ([]byte, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return json.Marshal(pesanWS{Event: event, Data: raw})
}
