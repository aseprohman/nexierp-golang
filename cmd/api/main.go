// cmd/api — binary HTTP Go (padanan apps/api NestJS): Bangun (wiring di
// internal/app) + Start + shutdown bersih. Prefix global /api diberlakukan
// di dalam Bangun; berdampingan NestJS (strangler — port berbeda, DB sama).
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"

	"nexierp/internal/app"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
)

func main() {
	_ = godotenv.Load() // dev convenience; produksi env dari proses
	cfg, err := config.Load()
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	log := logging(cfg.IsProd())
	slog.SetDefault(log)

	ctx := context.Background()
	db, err := database.Open(ctx, cfg.DatabaseURL, 10)
	if err != nil {
		log.Error("database", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	// ---- bangun aplikasi (seluruh wiring di internal/app.Bangun) ----
	e, bersih := app.Bangun(cfg, log, db)

	// ---- shutdown: matikan bersih (infrastruktur; tidak mengubah kontrak) ----
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		shCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = e.Shutdown(shCtx)
	}()

	log.Info("api go hidup", "port", cfg.Port)
	if err := e.Start(":" + itoa(cfg.Port)); err != nil && err != http.ErrServerClosed {
		log.Error("http", "err", err)
		os.Exit(1)
	}
	bersih() // resource infrastruktur (mailer) — paritas mailerSvc.Tutup() lama
}

func logging(isProd bool) *slog.Logger {
	lvl := slog.LevelDebug
	if isProd {
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
