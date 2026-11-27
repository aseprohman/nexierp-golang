// buktiws — bukti G0 (e): hub WS Go (handshake JWT + core_sessions) +
// bridge invalidasi RBAC → frame {"event":"rbac.changed","data":{"reason":"rbac"}}
// diterima klien yang join room user:<id>.
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"github.com/joho/godotenv"

	"nexierp/internal/core/auth"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/rbac"
	"nexierp/internal/core/realtime"
)

func main() {
	_ = godotenvLoad()
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
	var uid int64
	if err := db.Pool.QueryRow(ctx, "SELECT id FROM core_users WHERE username='g0_bukti'").Scan(&uid); err != nil {
		panic(err)
	}

	// login via Go untuk cookie sesi nyata
	body := fmt.Sprintf(`{"username":"g0_bukti","password":"G0Bukti2026!"}`)
	req, _ := http.NewRequest(http.MethodPost, "http://127.0.0.1:3101/api/auth/login", strReader(body))
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		panic(err)
	}
	buf := make([]byte, 4096)
	n, _ := res.Body.Read(buf)
	loginRaw := string(buf[:n])
	// ekstrak cookie nexierp_at dari header Set-Cookie
	var atCookie string
	for _, c := range res.Cookies() {
		if c.Name == "nexierp_at" {
			atCookie = c.Name + "=" + c.Value
		}
	}
	if atCookie == "" {
		panic("cookie nexierp_at tidak diterima dari login Go: " + loginRaw)
	}

	// hub + compiler + bridge (wiring sama dengan internal/app)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := realtime.NewHub(realtime.Deps{Pool: db.Pool, AccessSecret: cfg.JWTAccessSecret, OriginAllow: cfg.WebOrigin, Log: log})
	comp := rbac.NewCompiler(db.Pool, log)
	realtime.Bridge(comp, hub)

	mux := http.NewServeMux()
	mux.Handle("/ws", hub)
	srv := &http.Server{Addr: "127.0.0.1:31299", Handler: mux}
	go func() { _ = srv.ListenAndServe() }()
	defer func() { _ = srv.Shutdown(context.Background()) }()
	time.Sleep(200 * time.Millisecond)

	// klien WS dengan cookie sesi
	hdr := http.Header{}
	hdr.Set("Cookie", atCookie)
	c, _, err := websocket.Dial(ctx, "ws://127.0.0.1:31299/ws", &websocket.DialOptions{HTTPHeader: hdr})
	if err != nil {
		panic("handshake WS gagal: " + err.Error())
	}
	defer c.Close(websocket.StatusNormalClosure, "")

	// picu invalidasi (jalur produksi: override/assignRoles → InvalidateUser)
	go func() {
		time.Sleep(300 * time.Millisecond)
		comp.InvalidateUser(uid)
	}()

	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, raw, err := c.Read(cctx)
	if err != nil {
		panic("tidak menerima frame: " + err.Error())
	}
	fmt.Printf("frame diterima: %s\n", raw)
	fmt.Printf("harapan: {\"event\":\"rbac.changed\",\"data\":{\"reason\":\"rbac\"}} untuk room user:%d\n", uid)
	_ = auth.From // (kontrak guard terpakai di jalur HTTP; bukti ini jalur WS)
}

func strReader(s string) *sr { return &sr{s: s} }

type sr struct{ s string }

func (r *sr) Read(p []byte) (int, error) {
	if r.s == "" {
		return 0, io.EOF
	}
	n := copy(p, r.s)
	r.s = ""
	return n, nil
}

func godotenvLoad() error {
	_ = godotenv.Load()
	// godotenv:
	return nil
}
