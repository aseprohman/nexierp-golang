// Package config — padanan ValidatedConfigModule/EnvService NestJS.
// Fail-fast di bootstrap: variabel wajib kosong = error saat Load().
// Tiga variabel (WEB_ORIGIN, PORTAL_ORIGINS, COOKIE_SECURE) dibaca RAW tanpa
// validasi — persis NestJS (dibaca langsung process.env di main.ts/cookies).
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Env struct {
	DatabaseURL         string
	RedisURL            string
	JWTAccessSecret     string
	JWTRefreshSecret    string
	JWTAccessTTL        time.Duration // raw, default 15m — parser TTL persis NestJS
	Port                int
	NodeEnv             string // development|test|production
	MinioEndpoint       string
	MinioAccessKey      string
	MinioSecretKey      string
	MinioBucket         string
	MinioPublicEndpoint string // kosong = fallback MinioEndpoint
	PKCipherSecret      string // raw, fallback JWT_ACCESS_SECRET (pk-cipher)

	MailHost        string // kosong = mailer NONAKTIF
	MailPort        int
	MailUsername    string
	MailPassword    string
	MailEncryption  string // tls|ssl|none
	MailFromAddress string
	MailFromName    string

	WAWebhookURLPublik string
	WAWebhookToken     string
	WAEvolutionBaseURL string
	WAEvolutionAPIKey  string
	WALLMBaseURL       string
	WALLMAPIKey        string

	EcomPortalURL            string
	AuthTokenSweepIntervalMs int // 0 = job mati
	WAStatusKirimIntervalMs  int

	// Raw (tanpa validasi — dibaca langsung, persis NestJS)
	WebOrigin     []string // CORS allowlist, default localhost:3000,3100,3200
	PortalOrigins []string // ruang cookie portal, default localhost:3200
	CookieSecure  bool     // aktif hanya jika persis "true"
}

func (e *Env) IsProd() bool { return e.NodeEnv == "production" }

// parseTTL meniru ttlToSeconds NestJS: /^(\d+)\s*(ms|s|m|h|d)?$/i, default
// satuan menit, tidak cocok → 900 detik (15 menit).
func parseTTL(raw string) time.Duration {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 15 * time.Minute
	}
	unit := time.Minute
	num := s
	switch {
	case strings.HasSuffix(s, "ms"):
		unit, num = time.Millisecond, s[:len(s)-2]
	case strings.HasSuffix(s, "s"):
		unit, num = time.Second, s[:len(s)-1]
	case strings.HasSuffix(s, "m"):
		unit, num = time.Minute, s[:len(s)-1]
	case strings.HasSuffix(s, "h"):
		unit, num = time.Hour, s[:len(s)-1]
	case strings.HasSuffix(s, "d"):
		unit, num = 24*time.Hour, s[:len(s)-1]
	}
	n, err := strconv.Atoi(strings.TrimSpace(num))
	if err != nil || n < 0 {
		return 15 * time.Minute
	}
	return time.Duration(n) * unit
}

func splitList(raw, def string) []string {
	src := raw
	if strings.TrimSpace(src) == "" {
		src = def
	}
	var out []string
	for _, p := range strings.Split(src, ",") {
		p = strings.TrimRight(strings.TrimSpace(p), "/")
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func req(key string) (string, error) {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return "", fmt.Errorf("environment %s tidak diset", key)
	}
	return v, nil
}

func opt(key string) string { return os.Getenv(key) }

func optInt(key string, def int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return def
	}
	return n
}

// Load membangun Env fail-fast (padanan loadEnv zod + getter).
func Load() (*Env, error) {
	dbURL, err := req("DATABASE_URL")
	if err != nil {
		return nil, err
	}
	acc, err := req("JWT_ACCESS_SECRET")
	if err != nil {
		return nil, err
	}
	ref, err := req("JWT_REFRESH_SECRET")
	if err != nil {
		return nil, err
	}
	minioEp, err := req("MINIO_ENDPOINT")
	if err != nil {
		return nil, err
	}
	minioAk, err := req("MINIO_ACCESS_KEY")
	if err != nil {
		return nil, err
	}
	minioSk, err := req("MINIO_SECRET_KEY")
	if err != nil {
		return nil, err
	}

	redisURL := opt("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://nexierp-redis:6379"
	}
	nodeEnv := opt("NODE_ENV")
	if nodeEnv == "" {
		nodeEnv = "development"
	}
	mailEnc := opt("MAIL_ENCRYPTION")
	if mailEnc == "" {
		mailEnc = "tls"
	}
	ecomPortal := opt("ECOM_PORTAL_URL")
	if ecomPortal == "" {
		ecomPortal = "http://localhost:3200"
	}

	e := &Env{
		DatabaseURL:              dbURL,
		RedisURL:                 redisURL,
		JWTAccessSecret:          acc,
		JWTRefreshSecret:         ref,
		JWTAccessTTL:             parseTTL(opt("JWT_ACCESS_TTL")),
		Port:                     optInt("PORT", 3001),
		NodeEnv:                  nodeEnv,
		MinioEndpoint:            minioEp,
		MinioAccessKey:           minioAk,
		MinioSecretKey:           minioSk,
		MinioBucket:              opt("MINIO_BUCKET"),
		MinioPublicEndpoint:      opt("MINIO_PUBLIC_ENDPOINT"),
		PKCipherSecret:           opt("PK_CIPHER_SECRET"),
		MailHost:                 opt("MAIL_HOST"),
		MailPort:                 optInt("MAIL_PORT", 587),
		MailUsername:             opt("MAIL_USERNAME"),
		MailPassword:             opt("MAIL_PASSWORD"),
		MailEncryption:           mailEnc,
		MailFromAddress:          opt("MAIL_FROM_ADDRESS"),
		MailFromName:             opt("MAIL_FROM_NAME"),
		WAWebhookURLPublik:       opt("WA_WEBHOOK_URL_PUBLIK"),
		WAWebhookToken:           opt("WA_WEBHOOK_TOKEN"),
		WAEvolutionBaseURL:       opt("WA_EVOLUTION_BASE_URL"),
		WAEvolutionAPIKey:        opt("WA_EVOLUTION_APIKEY"),
		WALLMBaseURL:             opt("WA_LLM_BASE_URL"),
		WALLMAPIKey:              opt("WA_LLM_APIKEY"),
		EcomPortalURL:            ecomPortal,
		AuthTokenSweepIntervalMs: optInt("AUTH_TOKEN_SWEEP_INTERVAL_MS", 21_600_000),
		WAStatusKirimIntervalMs:  optInt("WA_STATUS_KIRIM_INTERVAL_MS", 10_000),
		WebOrigin:                splitList(opt("WEB_ORIGIN"), "http://localhost:3000,http://localhost:3100,http://localhost:3200"),
		PortalOrigins:            splitList(opt("PORTAL_ORIGINS"), "http://localhost:3200"),
		CookieSecure:             os.Getenv("COOKIE_SECURE") == "true",
	}
	if e.MinioBucket == "" {
		e.MinioBucket = "nexierp"
	}
	return e, nil
}
