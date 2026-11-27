package main

import (
	"context"
	"fmt"

	"github.com/joho/godotenv"

	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/rbac"
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
	sc := rbac.NewScope(db.Pool)
	var mID int64 = 1 // id core_modules 'inventory' (diverifikasi psql)
	d, err := sc.Values(context.Background(), db.Pool, 1, "storages", &mID)
	if err != nil {
		panic(err)
	}
	fmt.Printf("admin(1) storages modul=%d → mode=%s ids=%v\n", mID, d.Mode, d.IDs)
}
