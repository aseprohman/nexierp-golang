// Package database — pool pgx/v5 + helper transaksi (padanan DrizzleModule +
// UnitOfWork NestJS). Kontrak luas kernel: semua method repo/service menerima
// executor DBTX (pool | tx) sebagai parameter pertama, sehingga audit/outbox/
// numbering dapat disisipkan DI DALAM transaksi bisnis yang sama.
package database

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// DefaultMaxConns — NestJS memakai default pg.Pool (max 10); Go eksplisit.
const DefaultMaxConns = 10

// DB membungkus pool. *pgxpool.Pool memenuhi interface DBTX hasil sqlc.
type DB struct {
	Pool *pgxpool.Pool
}

// Open membuat pool. maxConns <= 0 → DefaultMaxConns.
func Open(ctx context.Context, url string, maxConns int32) (*DB, error) {
	if maxConns <= 0 {
		maxConns = DefaultMaxConns
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("DATABASE_URL tidak valid: %w", err)
	}
	cfg.MaxConns = maxConns
	cfg.MaxConnLifetime = time.Hour
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres tidak terjangkau: %w", err)
	}
	return &DB{Pool: pool}, nil
}

// Close menutup pool (padanan PgPoolLifecycle.onModuleDestroy).
func (d *DB) Close() { d.Pool.Close() }

// Tx menjalankan fn dalam SATU transaksi; panic/error apa pun = rollback
// (semantik db.transaction Drizzle). Transaksi tidak pernah lahir di dalam
// blok Tx lain — teruskan executor tx ke repo/audit/outbox/numbering.
func (d *DB) Tx(ctx context.Context, fn func(tx pgx.Tx) error) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(ctx)
			panic(p)
		}
	}()
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}
