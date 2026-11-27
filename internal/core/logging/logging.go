// Package logging — padanan pino.module NestJS: slog JSON, level debug di
// luar produksi, info di produksi. Redact header authorization/cookie dilakukan
// di middleware access-log (nilai tidak pernah masuk field log).
package logging

import (
	"log/slog"
	"os"
)

// New membuat logger JSON. isProd → level info, selain itu debug.
func New(isProd bool) *slog.Logger {
	lvl := slog.LevelDebug
	if isProd {
		lvl = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	return slog.New(h)
}
