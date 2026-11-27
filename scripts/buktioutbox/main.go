// buktioutbox — bukti G0 (c): event outbox yang diterbitkan Go (service
// outbox portingan) masuk core_outbox_events dengan idempotensi _key persis
// NestJS, sehingga konsumen NestJS (poll SKIP LOCKED, tandaiDelivered)
// dapat mengonsumsinya — disimulasikan lewat SQL NestJS yang sama.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/joho/godotenv"

	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/outbox"
)

func main() {
	_ = godotenv.Load()
	cfg, err := config.Load()
	if err != nil {
		panic(err)
	}
	db, err := database.Open(context.Background(), cfg.DatabaseURL, 2)
	if err != nil {
		panic(err)
	}
	defer db.Close()
	ctx := context.Background()
	ob := outbox.New(db)

	// 1) publish via service Go (exec = pool; di modul bisnis: dalam Tx)
	var id1, id2 int64
	id1, err = ob.Enqueue(ctx, db.Pool, outbox.EventInput{
		Topic:   "g0.bukti.cutover",
		Key:     ptr("g0-bukti-1"),
		Payload: map[string]any{"pesan": "diterbitkan dari Go (G0)", "runtime": "go"},
	})
	must(err)
	// 2) publish ulang key sama → idempoten (return id lama, tanpa duplikat)
	id2, err = ob.Enqueue(ctx, db.Pool, outbox.EventInput{
		Topic:   "g0.bukti.cutover",
		Key:     ptr("g0-bukti-1"),
		Payload: map[string]any{"pesan": "diterbitkan dari Go (G0)", "runtime": "go"},
	})
	must(err)
	fmt.Printf("enqueue#1 id=%d | enqueue ulang key sama id=%d | idempoten=%v\n", id1, id2, id1 == id2)
}

func ptr(s string) *string { return &s }

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "ERR:", err)
		os.Exit(1)
	}
}
