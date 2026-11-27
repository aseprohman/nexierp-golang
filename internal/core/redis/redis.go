// Package redis — pabrik koneksi go-redis/v9 (padanan koneksi-redis.ts).
// Opsi sepenuhnya dari URL (db index, password, dll) — tanpa DB index atau
// prefix tambahan; retry policy default go-redis. Redis mati = pemakaian
// berhenti SEMENTARA lalu pulih otomatis (keputusan pemilik 2026-11-25:
// kernel tetap hidup, log jelas).
//
// Catatan nama: paket ini bernama `redis` (wilayah kernel), import go-redis
// diberi alias `goredis` agar tidak bentrok — signature BuatKoneksi tetap
// mengembalikan *go-redis/v9.Client.
package redis

import (
	"context"
	"fmt"

	goredis "github.com/redis/go-redis/v9"
)

// BuatKoneksi membuat *redis.Client dari redisURL lalu Ping memastikan
// server terjangkau. Gagal = koneksi ditutup + error — caller memutuskan
// strategi coba-ulang (jangan crash).
func BuatKoneksi(ctx context.Context, redisURL string) (*goredis.Client, error) {
	opsi, err := goredis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("REDIS_URL tidak valid: %w", err)
	}
	klien := goredis.NewClient(opsi)
	if err := klien.Ping(ctx).Err(); err != nil {
		_ = klien.Close()
		return nil, fmt.Errorf("redis tidak terjangkau: %w", err)
	}
	return klien, nil
}
