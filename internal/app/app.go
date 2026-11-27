// Package app — penyusunan aplikasi HTTP (wiring manual eksplisit, tanpa
// magic DI): seluruh kernel service + router echo dibangun di Bangun yang
// SATU-satunya tempat wiring. Dipakai dua binary:
//   - cmd/api       → Bangun + Start + shutdown (server hidup).
//   - cmd/scanroute → Bangun TANPA Start; iterate e.Routes() → SQL merge-only
//     (pemindaian endpoint untuk sinkronisasi RBAC core_routes).
package app

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"regexp"

	"github.com/jackc/pgx/v5"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"

	"nexierp/internal/core/audit"
	"nexierp/internal/core/auth"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
	"nexierp/internal/core/errkontrak"
	"nexierp/internal/core/mailer"
	"nexierp/internal/core/moduleconfig"
	"nexierp/internal/core/numbering"
	"nexierp/internal/core/outbox"
	"nexierp/internal/core/pkcipher"
	"nexierp/internal/core/rbac"
	"nexierp/internal/core/realtime"
	"nexierp/internal/core/storage"
	docs "nexierp/internal/docs"
	"nexierp/internal/health"
	coremod "nexierp/internal/modules/core"
	coretypes "nexierp/internal/modules/core/types"
	invmod "nexierp/internal/modules/inv"
	invtypes "nexierp/internal/modules/inv/types"
)

// auditSinkAdapter — penyelarasan kontrak sink (auth/media: pgx.Tx;
// audit.Service: audit.DBTX — pgx.Tx memenuhi DBTX).
type auditSinkAdapter struct{ svc *audit.Service }

func (a auditSinkAdapter) AppendOne(ctx context.Context, tx pgx.Tx, e audit.AppendInput) (int64, error) {
	return a.svc.AppendOne(ctx, tx, e)
}

// Bangun — susun seluruh aplikasi: kernel service (audit/outbox/numbering/
// moduleconfig), RBAC, mailer+storage, auth, realtime hub, dan router echo
// (middleware + route). TIDAK menjalankan server (Start milik pemanggil) —
// hanya membangun objek; pemanggil memegang siklus hidup http.Server.
//
// Nilai kedua adalah func bersih-bersih resource infrastruktur (mailer) yang
// HARUS dipanggil setelah server berhenti (paritas mailerSvc.Tutup() lama).
func Bangun(cfg *config.Env, log *slog.Logger, db *database.DB) (*echo.Echo, func()) {
	// ---- kernel services (wiring manual, satu struct satu registrasi) ----
	auditSvc := audit.New(db)
	outboxSvc := outbox.New(db)
	numberingSvc := numbering.New(db)
	modCfgSvc := moduleconfig.New(db)
	_ = numberingSvc
	_ = modCfgSvc // dipakai modul bisnis; ikut wiring agar siap

	sink := auditSinkAdapter{svc: auditSvc}

	// ---- data-scope + pk-cipher (dipakai modul inv) ----
	scopeSvc := rbac.NewScope(db.Pool)
	cipherSvc, errCipher := pkcipher.New(cfg.PKCipherSecret)
	if errCipher != nil {
		log.Error("pk-cipher", "err", errCipher)
		os.Exit(1)
	}

	// ---- rbac ----
	registry := rbac.NewRouteRegistry(db.Pool, log)
	compiler := rbac.NewCompiler(db.Pool, log)
	guard := &rbac.PermissionsGuard{
		UserProvider: func(c echo.Context) (int64, string, int64, bool) {
			u := auth.From(c)
			if u == nil {
				return 0, "", 0, false
			}
			return u.ID, u.Username, u.SessionID, true
		},
		Reg:      registry,
		Compiler: compiler,
	}
	// guard dipasang per-group modul bisnis (modul core = G1 peringkat 1)

	// ---- mailer + storage + media library ----
	mailerSvc := mailer.New(cfg)
	mailerSvc.SetDB(db)
	storageSvc, err := storage.New(cfg)
	if err != nil {
		log.Error("storage", "err", err)
		panic(err) // wiring: konfigurasi storage wajib valid sejak konstruktor
	}
	media := storage.NewMediaLibraryService(db, storageSvc)
	media.PasangAudit(sink)
	if err := storageSvc.PastikanBucket(context.Background()); err != nil {
		log.Warn("storage bucket", "err", err) // MinIO mati tidak menghentikan API (parity NestJS: lazy)
	}

	// ---- auth service (kontrak lintas-paket di-wiring di sini) ----
	authSvc := auth.NewService(db, cfg, sink)
	authSvc.PermissionSet = compiler.PermissionSet
	authSvc.KirimAktivasi = func(c context.Context, p auth.MailAktivasiPayload) {
		hasil := mailer.KemasHtmlEmail(mailer.KemasHtmlEmailInput{
			Judul:  "Aktivasi Akun Member",
			Sapaan: "Halo " + p.NamaTujuan + ",",
			Paragraf: []string{
				"Terima kasih telah mendaftar di NEXIERP. Satu langkah lagi — aktivasi akun Anda agar bisa masuk dan mulai berbelanja.",
			},
			Tombol: &mailer.TombolEmail{Label: "Aktivasi Sekarang", URL: p.Tautan},
			Penutup: []string{
				"Tautan berlaku 24 jam dan hanya bisa dipakai satu kali.",
				"Bila Anda tidak merasa mendaftar, abaikan email ini.",
			},
		})
		// TIDAK pernah membalikkan registrasi — MailerService.Kirim juga
		// tidak pernah throw (status NONAKTIF/GAGAL tercatat core_mail_log).
		mailerSvc.Kirim(c, mailer.MailPayload{
			Kepada:      p.Kepada,
			NamaTujuan:  &p.NamaTujuan,
			Subjek:      "Aktivasi Akun Member NEXIERP",
			Jenis:       "AKTIVASI_MEMBER",
			HTML:        hasil.HTML,
			Teks:        &hasil.Teks,
			IDCoreUsers: &p.IDCoreUsers,
		})
	}

	// ---- realtime hub WS (/ws) + bridge invalidasi RBAC ----
	hub := realtime.NewHub(realtime.Deps{
		Pool:         db.Pool,
		AccessSecret: cfg.JWTAccessSecret,
		OriginAllow:  cfg.WebOrigin,
		Log:          log,
	})
	realtime.Bridge(compiler, hub)

	// ---- echo ----
	e := echo.New()
	e.HideBanner = true
	e.Logger.SetOutput(io.Discard) // log via slog
	e.Use(middleware.Recover())
	// CORS persis main.ts NestJS: allowlist WEB_ORIGIN, credentials, ETag.
	e.Use(middleware.CORSWithConfig(middleware.CORSConfig{
		AllowOrigins:     cfg.WebOrigin,
		AllowCredentials: true,
		AllowMethods:     []string{http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions},
		ExposeHeaders:    []string{"ETag"},
		MaxAge:           600,
	}))
	e.GET("/ws", echo.WrapHandler(hub)) // path root (padanan /socket.io NestJS)

	api := e.Group("/api") // prefix global persis setGlobalPrefix("api")
	health.Register(api)
	auth.Daftarkan(api, authSvc, cfg)

	// ---- modul inv — 114 endpoint, strangler peringkat 2 ----
	invmod.Register(api, invtypes.Deps{
		DB: db, Cfg: cfg, Log: log, Audit: auditSvc, Outbox: outboxSvc,
		Numbering: numberingSvc, ModCfg: modCfgSvc, Scope: scopeSvc, Cipher: cipherSvc,
		AuthGuard: auth.Guard(db, cfg),
		RbacGuard: guard.Middleware(),
	})

	// ---- modul core (system) — 130 endpoint, strangler peringkat 1 ----
	coremod.Register(api, coretypes.Deps{
		DB: db, Cfg: cfg, Log: log, Audit: auditSvc, Compiler: compiler, Registry: registry,
		Media: media, Store: storageSvc,
		AuthGuard: auth.Guard(db, cfg),
		RbacGuard: guard.Middleware(),
	})

	// ---- Swagger (publik, parity NestJS /api/docs) ----
	docs.Register(api, "api/openapi")

	// ---- 404 parity Nest: path tanpa controller → 404 problem+json
	// (Fastify 404 terjadi di router, SEBELUM guard; OPTIONS lewat preflight).
	type routePat struct {
		method string
		re     *regexp.Regexp
	}
	var routePats []routePat
	for _, r := range e.Routes() {
		// :param → [^/]+ (QuoteMeta dulu agar titik/regex aman).
		p := regexp.QuoteMeta(r.Path)
		p = regexp.MustCompile(`:[A-Za-z0-9_]+`).ReplaceAllString(p, "[^/]+")
		re, err := regexp.Compile("^" + p + "$")
		if err != nil {
			continue
		}
		routePats = append(routePats, routePat{method: r.Method, re: re})
	}
	e.Pre(func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			req := c.Request()
			if req.Method == http.MethodOptions {
				return next(c)
			}
			ada := false
			for _, rp := range routePats {
				if rp.method == req.Method && rp.re.MatchString(req.URL.Path) {
					ada = true
					break
				}
			}
			if !ada {
				return errkontrak.WriteProblem(c, http.StatusNotFound, errkontrak.CodeNotf404,
					"Cannot "+req.Method+" "+req.URL.RequestURI(), nil)
			}
			return next(c)
		}
	})

	// ---- bersih-bersih resource infrastruktur (dipanggil pemanggil) ----
	bersih := func() { mailerSvc.Tutup() }
	return e, bersih
}
