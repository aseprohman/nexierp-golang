// bukti403 — bukti parity RBAC G0 (b): compiler + guard Go sungguhan
// terhadap core_routes live; hasil dibandingkan dengan 403 NestJS.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"

	"github.com/joho/godotenv"
	"github.com/labstack/echo/v4"

	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/rbac"
)

func main() {
	_ = godotenv.Load()
	_ = os.Setenv("NODE_ENV", "development")
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

	// user bukti by username
	var uid int64
	if err := db.Pool.QueryRow(ctx, "SELECT id FROM core_users WHERE username='g0_bukti'").Scan(&uid); err != nil {
		panic(err)
	}

	log := slogNop()
	comp := rbac.NewCompiler(db.Pool, log)
	reg := rbac.NewRouteRegistry(db.Pool, log)

	// 1) compiler.Has untuk kode yang diharapkan NestJS 403
	has, err := comp.Has(ctx, uid, "system.rbac.stats")
	if err != nil {
		panic(err)
	}
	fmt.Printf("compiler.Has(g0_bukti, system.rbac.stats) = %v (harapan: false)\n", has)

	// 2) guard penuh via httptest — jalur resolve registry live + compiler
	g := &rbac.PermissionsGuard{
		UserProvider: func(c echo.Context) (int64, string, int64, bool) {
			return uid, "g0_bukti", 0, true
		},
		Reg:      reg,
		Compiler: comp,
	}
	e := echo.New()
	e.GET("/system/overview", func(c echo.Context) error { return c.JSON(200, map[string]string{"ok": "1"}) }, g.Middleware())
	req := httptest.NewRequest(http.MethodGet, "/system/overview", nil)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	fmt.Printf("guard Go: status=%d body=%s\n", rec.Code, rec.Body.String())
	fmt.Println("harapan NestJS: status=403 body={...code FORB-403, detail \"permission 'system.rbac.stats' diperlukan\"}")
}

func slogNop() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
