// cmd/worker — runtime worker Go (padanan "worker in-process" BullMQ
// NestJS): Mux loop siklus + wiring registrasi job per modul.
// Bootstrap fail-fast (config/database); Redis best-effort — worker tetap
// hidup walau Redis mati (padanan keputusan pemilik di koneksi-redis.ts).
// SIGTERM/SIGINT → shutdown rapi: Berhenti (tunggu siklus) → tutup pool.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"

	"nexierp/internal/core/auth"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/logging"
	"nexierp/internal/core/queue"
	"nexierp/internal/core/redis"
)

func main() {
	// .env best-effort — produksi memakai env asli (godotenv tidak menimpa
	// env yang sudah ada).
	_ = godotenv.Load()

	env, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "worker: config gagal:", err)
		os.Exit(1)
	}
	log := logging.New(env.IsProd())

	ctx := context.Background()

	// Database fail-fast — semua siklus membutuhkan DB.
	db, err := database.Open(ctx, env.DatabaseURL, 0)
	if err != nil {
		log.Error("worker: database gagal dibuka", "err", err.Error())
		os.Exit(1)
	}

	// Redis best-effort: gagal = log warn + lanjut (worker tidak crash;
	// koneksi dipakai task antar-runtime nanti, siklus loop tidak butuh).
	ctxPing, batalkanPing := context.WithTimeout(ctx, 5*time.Second)
	klienRedis, errRedis := redis.BuatKoneksi(ctxPing, env.RedisURL)
	batalkanPing()
	if errRedis != nil {
		log.Warn("redis belum siap — worker tetap jalan, antrean menunggu pulih", "err", errRedis.Error())
		klienRedis = nil
	} else {
		log.Info("redis tersambung", "url", env.RedisURL)
	}

	// Mux job siklus (padanan RegistWorker) + wiring registrasi per modul.
	mux := queue.NewMux(env.RedisURL, log)

	// core/auth — sweep token kedaluwarsa (queue "nexierp.auth", job
	// "auth.token-sweep", interval env.AuthTokenSweepIntervalMs dibaca ulang
	// tiap siklus). AuditSink nil aman: sweep tidak menulis audit (service
	// nil-guard); AppendOne di-wiring penuh di cmd/api.
	layananAuth := auth.NewService(db, env, nil)
	layananAuth.SetLogger(log)
	layananAuth.RegistrasiSiklusSweep(mux)

	mux.Mulai(ctx)

	// Tunggu SIGTERM/SIGINT → shutdown rapi.
	sinyal := make(chan os.Signal, 1)
	signal.Notify(sinyal, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sinyal
	log.Info("worker: sinyal berhenti diterima", "signal", sig.String())

	mux.Berhenti() // cancel context + tunggu eksekusi berjalan selesai
	if klienRedis != nil {
		_ = klienRedis.Close()
	}
	db.Close()
	log.Info("worker: berhenti")
}
