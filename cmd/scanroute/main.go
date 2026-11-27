// cmd/scanroute — PARITY-SCANNER route API Go ↔ core_routes (RBAC rev.6):
// load env/config/db → app.Bangun (router utuh) → bandingkan e.Routes() Go
// dengan baris KANONIK dari tabel core_routes (READ-ONLY) → laporan parity
// ke STDOUT.
//
// SUMBER KANONIK permission_code = core_routes LIVE (DB) — SATU-SATUNYA
// kebenaran (pola/URL/kode NestJS ↔ Go wajib 1:1; FE tidak boleh berubah).
// Tool ini TIDAK PERNAH menulis/mengubah core_routes untuk route yang sudah
// ada di live (milik NestJS / hasil kurasi) — termasuk bila kodenya "beda"
// dari turunan rev.6.
//
// Klasifikasi (kunci = method + uri_pattern, uri TANPA prefix /api):
//
//	MATCH      route ada di Go DAN live, kode live == turunan rev.6 → hijau.
//	DIFF       path/method sama, kode beda → MERAH. KANONIK = kode live;
//	           Go yang harus disesuaikan bila memang ada selisih (umumnya
//	           TIDAK perlu — guard RBAC Go membaca kode dari DB live, bukan
//	           dari nama handler). SQL TIDAK menyentuh baris ini.
//	GO-ONLY    route Go belum ada baris live-nya → laporan + SQL KANDIDAT
//	           merge-only (INSERT … ON CONFLICT DO NOTHING; code rev.6
//	           {modul}.{fitur}.{handler} dari NAMA HANDLER GO — komentar
//	           "kandidat, tidak ada acuan NestJS"). TIDAK dieksekusi di sini.
//	LIVE-ONLY  baris live belum ada route Go-nya → laporan (belum dicutover
//	           — normal selama strangler).
//
// Pemakaian:
//
//	go run ./cmd/scanroute            # laporan parity (stdout)
//	go run ./cmd/scanroute --sql      # HANYA SQL kandidat GO-ONLY (stdout,
//	                                  # piped manual ke psql; laporan → stderr)
//	  | podman exec -i nexierp-postgres psql -U nexierp -d nexierp -v ON_ERROR_STOP=1 -q
//
// SQL kandidat = pola rev.6 (podman/scanroutes.sh NestJS) MINUS semuanya
// yang menghapus/mengubah milik NestJS: TANPA DELETE (route yatim, junction
// stale, SET kosong), TANPA UPDATE baris existing (ON CONFLICT DO NOTHING),
// TANPA bootstrap admin grant ulang, TANPA sentuh core_modules_features /
// kolom core_routes.id_core_modules_features.
//
// Route /ws BUKAN REST — endpoint websocket realtime (padanan /socket.io
// NestJS, guard JWT handshake sendiri) → EXCLUDE dari pemindaian.
//
// Konvensi kode turunan rev.6 (HANYA untuk kandidat GO-ONLY & hint laporan):
//   - modul  = SEGMENT-1 URI (fallback "root").
//   - fitur  = untuk core Go: FOLDER PAKET handler (auth → "auth",
//     health → "health" — padanan folder controller NestJS). Folder kind
//     ("handler", padanan "controllers"/"api" NestJS) = TRANSPARAN →
//     fallback rev.6: SEGMENT-2 URI (identitas bisnis); bila URI hanya 1
//     segmen → fitur = SEGMENT-1. Contoh: /health → modul "health"
//     (segmen-1); controller health NestJS flat di src/health → fitur
//     fallback segmen-2 URI, /health hanya 1 segmen → fitur = segmen-1
//     "health" → `health.health.check` (paritas HealthController.check —
//     handler Go sengaja fungsi bernama `check` agar terbaca di Routes()).
//   - action = nama method handler LOWERCASE — echo Routes() memberi nama
//     runtime "nexierp/internal/core/auth.(*Handler).login-fm" → ekstrak
//     nama method terakhir ("login"); closure anonim ("func1") tidak
//     stabil — gunakan fungsi bernama di handler.
//   - segmen ":param" dipertahankan apa adanya.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strings"

	"github.com/joho/godotenv"
	"github.com/labstack/echo/v4"

	"nexierp/internal/app"
	"nexierp/internal/core/config"
	"nexierp/internal/core/database"
)

// verbaRest — kata kerja REST yang dipindai (padanan ALLOWED_VERBS rev.6).
var verbaRest = map[string]bool{
	http.MethodGet:    true,
	http.MethodPost:   true,
	http.MethodPut:    true,
	http.MethodPatch:  true,
	http.MethodDelete: true,
}

// Status klasifikasi parity.
const (
	statusMatch    = "MATCH"
	statusDiff     = "DIFF"
	statusGoOnly   = "GO-ONLY"
	statusLiveOnly = "LIVE-ONLY"
)

// ruteGo — satu route REST hasil scan echo.
type ruteGo struct {
	Method string // lowercase ("get","post",…)
	URI    string // tanpa prefix /api
	Nama   string // nama runtime handler (Routes().Name)
}

// barisLive — baris KANONIK core_routes dari DB live.
type barisLive struct {
	Method string
	URI    string
	Kode   string
}

// barisLaporan — satu baris hasil klasifikasi parity.
type barisLaporan struct {
	Status   string
	Method   string
	URI      string
	KodeLive string // kanonik (kosong untuk GO-ONLY)
	KodeGo   string // turunan rev.6 dari nama handler — HINT, bukan kanonik
}

func main() {
	sqlOnly := flag.Bool("sql", false,
		"tulis HANYA SQL kandidat GO-ONLY ke stdout (laporan parity pindah ke stderr)")
	flag.Parse()

	_ = godotenv.Load() // dev convenience; produksi env dari proses
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	// Log ke STDERR — stdout khusus laporan/SQL (bisa dipiped ke psql).
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	ctx := context.Background()
	// DB WAJIB: baris core_routes live = sumber kanonik perbandingan.
	db, err := database.Open(ctx, cfg.DatabaseURL, 2)
	if err != nil {
		log.Error("database", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	e, bersih := app.Bangun(cfg, log, db)
	defer bersih()

	goRute := scanEcho(e)
	live, err := muatLive(ctx, db)
	if err != nil {
		log.Error("core_routes", "err", err)
		os.Exit(1)
	}

	laporan := klasifikasi(goRute, live)

	if *sqlOnly {
		// Laporan pindah ke stderr; stdout = SQL kandidat GO-ONLY saja.
		tulisLaporan(os.Stderr, laporan, false)
		tulisSQL(os.Stdout, pilih(laporan, statusGoOnly))
		log.Info(fmt.Sprintf("kandidat GO-ONLY: %d route", len(pilih(laporan, statusGoOnly))))
		return
	}
	tulisLaporan(os.Stdout, laporan, isTTY(os.Stdout))
	log.Info(fmt.Sprintf("Go: %d route REST ter-scan | live: %d baris core_routes", len(goRute), len(live)))
}

// scanEcho — iterasi e.Routes() → route REST Go (sorted by uri, method).
func scanEcho(e *echo.Echo) []ruteGo {
	var out []ruteGo
	for _, r := range e.Routes() {
		if !verbaRest[r.Method] {
			continue
		}
		// /ws BUKAN REST (websocket realtime) — exclude (lihat komentar header).
		if r.Path == "/ws" {
			continue
		}
		// uri_pattern TANPA prefix global /api — persis rev.6.
		uri, ok := strings.CutPrefix(r.Path, "/api")
		if !ok || uri == "" {
			continue // di luar prefix API (defensive — bukan endpoint REST /api)
		}
		out = append(out, ruteGo{Method: strings.ToLower(r.Method), URI: uri, Nama: r.Name})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].URI != out[j].URI {
			return out[i].URI < out[j].URI
		}
		return out[i].Method < out[j].Method
	})
	return out
}

// muatLive — baca baris KANONIK core_routes (READ-ONLY; tidak pernah ditulis).
func muatLive(ctx context.Context, db *database.DB) ([]barisLive, error) {
	rows, err := db.Pool.Query(ctx,
		"SELECT method::text, uri_pattern, permission_code FROM core_routes")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []barisLive
	for rows.Next() {
		var b barisLive
		if err := rows.Scan(&b.Method, &b.URI, &b.Kode); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// kunci — kunci pembanding parity: method lowercase + spasi + uri_pattern.
func kunci(method, uri string) string { return strings.ToLower(method) + " " + uri }

// klasifikasi — bandingkan route Go dengan baris kanonik live (kunci =
// method + uri_pattern; kode live = kanonik; kode rev.6 Go = hint laporan).
func klasifikasi(goRute []ruteGo, live []barisLive) []barisLaporan {
	liveIdx := make(map[string]barisLive, len(live))
	for _, b := range live {
		liveIdx[kunci(b.Method, b.URI)] = b
	}
	goIdx := make(map[string]bool, len(goRute))
	for _, r := range goRute {
		goIdx[kunci(r.Method, r.URI)] = true
	}

	var out []barisLaporan
	for _, r := range goRute {
		kodeGo, _ := kodeRev6(r.URI, r.Nama)
		b := barisLaporan{Method: r.Method, URI: r.URI, KodeGo: kodeGo}
		if lv, ada := liveIdx[kunci(r.Method, r.URI)]; ada {
			b.KodeLive = lv.Kode
			if lv.Kode == kodeGo {
				b.Status = statusMatch
			} else {
				// KANONIK = kode live; selisih dilaporkan MERAH, DB tidak
				// disentuh (lihat komentar header).
				b.Status = statusDiff
			}
		} else {
			// Belum ada baris live → kandidat INSERT merge-only (rev.6).
			b.Status = statusGoOnly
		}
		out = append(out, b)
	}
	for _, b := range live {
		if !goIdx[kunci(b.Method, b.URI)] {
			out = append(out, barisLaporan{
				Status: statusLiveOnly, Method: b.Method, URI: b.URI, KodeLive: b.Kode,
			})
		}
	}

	rank := map[string]int{statusMatch: 0, statusDiff: 1, statusGoOnly: 2, statusLiveOnly: 3}
	sort.Slice(out, func(i, j int) bool {
		if rank[out[i].Status] != rank[out[j].Status] {
			return rank[out[i].Status] < rank[out[j].Status]
		}
		if out[i].URI != out[j].URI {
			return out[i].URI < out[j].URI
		}
		return out[i].Method < out[j].Method
	})
	return out
}

// segmen — potong URI jadi segmen non-kosong.
func segmen(uri string) []string {
	var out []string
	for _, s := range strings.Split(strings.Trim(uri, "/"), "/") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// namaHandler — parse nama runtime handler dari echo Routes() (hasil
// HandlerFunc.Name()):
//
//	nexierp/internal/core/auth.(*Handler).login-fm → "auth", "login"
//	nexierp/internal/health.check                  → "health", "check"
//
// fitur = folder paket (segmen sebelum "("); action = nama method terakhir,
// lowercase, sufiks wrapper method-value "-fm" dibuang. Closure anonim
// menghasilkan action "funcN" (tidak stabil) — gunakan fungsi bernama.
func namaHandler(name string) (fitur, action string) {
	seg := name
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		seg = name[i+1:] // buang import path — "auth.(*Handler).login-fm"
	}
	if i := strings.IndexByte(seg, '('); i >= 0 { // method value: pkg.(*T).m-fm
		fitur = strings.TrimSuffix(seg[:i], ".") // "auth." → "auth"
		sisa := seg[i:]
		if j := strings.IndexByte(sisa, ')'); j >= 0 && j+1 < len(sisa) && sisa[j+1] == '.' {
			action = sisa[j+2:]
		} else {
			action = "handler"
		}
	} else { // fungsi paket: pkg.func / pkg.Pembungkus.funcN (closure)
		parts := strings.Split(seg, ".")
		fitur = parts[0]
		action = parts[len(parts)-1]
	}
	action = strings.TrimSuffix(action, "-fm")
	return strings.ToLower(fitur), strings.ToLower(action)
}

// kodeRev6 — kode turunan rev.6 "{modul}.{fitur}.{action}" dari URI + nama
// handler Go. BUKAN kanonik — hanya untuk (a) kandidat SQL GO-ONLY dan
// (b) hint perbandingan laporan (lihat komentar header).
func kodeRev6(uri, namaHandlerRuntime string) (string, bool) {
	fiturPaket, action := namaHandler(namaHandlerRuntime)
	segs := segmen(uri)
	if action == "" || len(segs) == 0 {
		return "", false
	}
	modul := segs[0]
	fitur := fiturPaket
	// Folder kind "handler" = TRANSPARAN (padanan "controllers"/"api"
	// rev.6) → fallback SEGMENT-2 URI; URI 1 segmen → SEGMENT-1.
	if fitur == "" || fitur == "handler" {
		switch {
		case len(segs) >= 2:
			fitur = segs[1]
		default:
			fitur = modul
		}
	}
	return modul + "." + fitur + "." + action, true
}

// pilih — saring baris laporan ber-status tertentu.
func pilih(l []barisLaporan, status string) []barisLaporan {
	var out []barisLaporan
	for _, b := range l {
		if b.Status == status {
			out = append(out, b)
		}
	}
	return out
}

// isTTY — true bila f adalah terminal (warna ANSI hanya untuk manusia).
func isTTY(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// tulisLaporan — laporan parity ke w (stdout manusia, atau stderr mode --sql).
func tulisLaporan(w io.Writer, l []barisLaporan, warna bool) {
	hijau := func(s string) string { return s }
	merah := func(s string) string { return s }
	if warna {
		hijau = func(s string) string { return "\033[32m" + s + "\033[0m" }
		merah = func(s string) string { return "\033[31m" + s + "\033[0m" }
	}

	hitung := map[string]int{}
	for _, b := range l {
		hitung[b.Status]++
	}

	fmt.Fprintln(w, "== PARITY core_routes ↔ e.Routes() Go (KANONIK = DB live) ==")
	fmt.Fprintf(w, "MATCH %d | DIFF %d | GO-ONLY %d | LIVE-ONLY %d\n",
		hitung[statusMatch], hitung[statusDiff], hitung[statusGoOnly], hitung[statusLiveOnly])
	fmt.Fprintln(w, strings.Repeat("-", 100))

	for _, b := range l {
		switch b.Status {
		case statusMatch:
			fmt.Fprintf(w, "%s %-6s %-46s %s\n",
				hijau("MATCH   "), b.Method, b.URI, b.KodeLive)
		case statusDiff:
			// Kanonik = live; kode rev.6 Go hanya hint diagnostic.
			fmt.Fprintf(w, "%s %-6s %-46s live=%s  go(rev.6,hint)=%s\n",
				merah("DIFF    "), b.Method, b.URI, b.KodeLive, b.KodeGo)
		case statusGoOnly:
			fmt.Fprintf(w, "%s %-6s %-46s kandidat=%s (rev.6 dari nama handler Go — tidak ada acuan NestJS)\n",
				"GO-ONLY ", b.Method, b.URI, b.KodeGo)
		default:
			fmt.Fprintf(w, "%s %-6s %-46s %s (belum dicutover — normal strangler)\n",
				"LIVE-ONLY", b.Method, b.URI, b.KodeLive)
		}
	}
	if len(l) == 0 {
		fmt.Fprintln(w, "(tidak ada baris)")
	}
}

// sqlLit — literal SQL NULL-safe untuk string ter-scan (escape kutip tunggal).
func sqlLit(v string) string {
	return "'" + strings.ReplaceAll(v, "'", "''") + "'"
}

// tulisSQL — SQL KANDIDAT merge-only untuk route GO-ONLY ke w (stdout).
// Pola rev.6 podman/scanroutes.sh NestJS, MINUS semua yang menghapus/mengubah
// baris milik NestJS: INSERT ON CONFLICT DO NOTHING (TANPA UPDATE), TANPA
// DELETE, TANPA admin bootstrap. Eksekusi manual oleh user (piped) — tool ini
// TIDAK pernah mengeksekusi SQL.
func tulisSQL(w io.Writer, kandidat []barisLaporan) {
	if len(kandidat) == 0 {
		fmt.Fprintln(w, "-- tidak ada kandidat GO-ONLY — tidak ada SQL yang dihasilkan.")
		return
	}
	fmt.Fprintln(w, `-- generated by cmd/scanroute (nexierp-golang) — SQL KANDIDAT MERGE-ONLY GO-ONLY
-- Hanya route Go yang BELUM ada baris core_routes live-nya (komentar rev.6:
-- "kandidat — tidak ada acuan NestJS"; code = {modul}.{fitur}.{handler} dari
-- nama handler Go). TANPA DELETE apa pun; TANPA UPDATE baris existing milik
-- NestJS (ON CONFLICT DO NOTHING); TANPA admin bootstrap; core_modules_features
-- & core_routes.id_core_modules_features tidak disentuh. Jalankan manual:
--   go run ./cmd/scanroute --sql | podman exec -i nexierp-postgres psql -U nexierp -d nexierp -v ON_ERROR_STOP=1 -q`)

	fmt.Fprintln(w, "BEGIN;")
	fmt.Fprintln(w, `CREATE TEMP TABLE _scan_routes (method text, uri_pattern text, permission_code text) ON COMMIT DROP;`)

	fmt.Fprintln(w, "INSERT INTO _scan_routes (method, uri_pattern, permission_code) VALUES")
	vals := make([]string, 0, len(kandidat))
	for _, b := range kandidat {
		vals = append(vals, fmt.Sprintf("    (%s, %s, %s)", sqlLit(b.Method), sqlLit(b.URI), sqlLit(b.KodeGo)))
	}
	fmt.Fprintln(w, strings.Join(vals, ",\n")+";")

	fmt.Fprint(w, `
-- ==== kandidat — tidak ada acuan NestJS: INSERT route baru (DO NOTHING —
-- bila baris muncul bersamaan dari sisi lain, biarkan yang ada menang) ====
INSERT INTO core_routes (method, uri_pattern, permission_code)
SELECT s.method::core_http_method, s.uri_pattern, s.permission_code
FROM _scan_routes s
ON CONFLICT (method, uri_pattern) DO NOTHING;

-- ==== MODEL SET (ddl/21) — SET permission "{modul}.{fitur}" dari permission
-- code kandidat (scope kandidat GO-ONLY saja); dibuat bila belum ada;
-- id_core_modules di-resolve dari segmen-1 (alias prefix URI ≠ key enum, ddl/43).
INSERT INTO core_permissions (name, id_core_modules, status, is_system)
SELECT DISTINCT
    split_part(rt.permission_code, '.', 1) || '.' ||
      split_part(rt.permission_code, '.', 2)          AS name,
    m.id                                              AS id_core_modules,
    'active'::core_permission_status                  AS status,
    true                                              AS is_system
FROM _scan_routes s
JOIN core_routes rt
  ON rt.method::text = s.method AND rt.uri_pattern = s.uri_pattern
LEFT JOIN core_modules m ON m.key::text = CASE split_part(rt.permission_code, '.', 1)
  WHEN 'acc' THEN 'accounting'
  WHEN 'sls' THEN 'sales'
  WHEN 'pgw' THEN 'payment-gateway'
  WHEN 'wa' THEN 'whatsapp-crm'
  WHEN 'ai' THEN 'ai-llm'
  ELSE split_part(rt.permission_code, '.', 1) END
WHERE NOT EXISTS (
  SELECT 1 FROM core_permissions p
  WHERE p.name = split_part(rt.permission_code, '.', 1) || '.' || split_part(rt.permission_code, '.', 2)
    AND p.id_core_modules IS NOT DISTINCT FROM m.id
);

-- ==== junction SET ↔ route kandidat (pasangan unik, idempoten; junction
-- milik NestJS / kurasi manual tidak disentuh) ====
INSERT INTO core_permissions_routes (id_core_routes, id_core_permissions)
SELECT rt.id, p.id
FROM _scan_routes s
JOIN core_routes rt
  ON rt.method::text = s.method AND rt.uri_pattern = s.uri_pattern
LEFT JOIN core_modules m ON m.key::text = CASE split_part(rt.permission_code, '.', 1)
  WHEN 'acc' THEN 'accounting'
  WHEN 'sls' THEN 'sales'
  WHEN 'pgw' THEN 'payment-gateway'
  WHEN 'wa' THEN 'whatsapp-crm'
  WHEN 'ai' THEN 'ai-llm'
  ELSE split_part(rt.permission_code, '.', 1) END
JOIN core_permissions p
  ON p.name = split_part(rt.permission_code, '.', 1) || '.' || split_part(rt.permission_code, '.', 2)
 AND p.id_core_modules IS NOT DISTINCT FROM m.id
ON CONFLICT (id_core_routes, id_core_permissions) DO NOTHING;

COMMIT;`)
}
