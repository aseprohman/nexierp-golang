# nexierp-golang — Backend Go NexiERP

Repo target **migrasi strangler NestJS → Go**. Satu PostgreSQL, dua runtime:
Go KONEK ke database yang sama dengan NestJS (`nexierp`) — tabel, outbox,
audit, numbering, sesi, seed RBAC dipakai bersama. Cutover = memindahkan
ROUTE per modul, bukan memindahkan data.

> Konstitusi: `docs/ARSITEKTUR-BACKEND-GO.md` · Pelacak fase:
> `docs/MIGRASI-BACKEND-GO.md` · Disiplin repo: `AGENTS.md` ·
> Repo NestJS sumber: `/Data/www/nexierp` (READ-ONLY untuk migrasi).

## Status migrasi (per modul, G1 audit → G4 parity → G5 cutover → G6 finalize)

| Modul | G1–G4 | Catatan |
|---|---|---|
| fondasi (G0, kernel) | ✅ | kernel lengkap + bukti parity: login lintas-runtime, 403 RBAC, outbox, schema ≡ live, WS `rbac.changed` |
| **core (system)** — 130 ep | ✅ | parity hidup 36/38 + 2 artefak dist Nest basi |
| **inv (inventory)** — 114 ep | ✅ | master/operasi/stok/dashboard+laporan; 3 keputusan ratifikasi tercatat |
| G5 cutover fisik | ⏸ | menunggu keputusan gateway produksi (FE dev sudah bisa mode Go via `--goversion`) |
| sls, purchasing, pos, fnb, ai, ecom, acc, hr, pgw, shipment, wa, wf | ⬜ | urutan ratifikasi: core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf |

## Stack (terkunci konstitusi)

| Peran | Pilihan |
|---|---|
| HTTP | Echo v4 di atas `net/http` |
| DB | pgx/v5 (pool) + sqlc (SQL-first; `db/queries/**` → `repository/gen`) |
| Migrasi | goose atas salinan `ddl/*.sql` NestJS (porting 1:1 + rekonsiliasi bentuk-live) |
| AuthN | golang-jwt HS256 + argon2id + tabel `core_sessions` (shared secret, klaim `{sub, username, sid}`) |
| AuthZ | middleware RBAC route-centric — resolve `(method, path)` ke `core_routes` live + compiler union multi-role/override (deny menang) + data-scope 3-mode |
| Queue/cron | asynq + go-redis (pola siklus: interval CFG dibaca ulang per eksekusi, 0 = mati) |
| Realtime | WebSocket native `coder/websocket` di `/ws` (event `rbac.changed`; pengganti socket.io sejak G0) |
| Storage | aws-sdk-go-v2 (MinIO/S3, presign GET) |
| Mail | go-mail + `core_mail_log` |
| Kontrak API | OpenAPI-first `api/openapi/<modul>.yaml` (+ JSON Schema zod di `api/json-schema/`) |

Dilarang masuk: ORM (GORM dll.), framework HTTP lain, multi `go.mod`, DB baru, perubahan `ddl/` di repo ini.

## Struktur

```
cmd/
  api/          binary HTTP (wiring via internal/app.Bangun)
  worker/       asynq + siklus cron (job per modul: RegWorker)
  scanroute/    parity-scanner route Go vs core_routes live (merge-only s/d G7)
internal/
  core/         kernel L1: database, config, logging, errkontrak (problem+json),
                auth, rbac, audit, outbox, numbering, moduleconfig, redis,
                queue, storage, mailer, realtime, idempoten, ctxsistem, pkcipher
  modules/core/ modul system (130 ep) — iam, rbac, security, tenants, files, …
  modules/inv/  modul inventory (114 ep) — master, operasi, stok, dashboard+laporan
  app/          Bangun(): satu tempat wiring semua modul
  docs/         Swagger: gabungan api/openapi/*.yaml
api/openapi/    kontrak kawat per modul (auth, system, inventory)
api/json-schema/ JSON Schema hasil generator dari packages/schemas NestJS
db/migrations/  goose (porting ddl/ 1:1 + rekonsiliasi bentuk-live)
db/queries/     sumber sqlc per paket
tools/          json-schema-gen (baca packages/schemas NestJS read-only)
scripts/        hashgen, bukti parity (bukti403/buktioutbox/buktiws), parity.py
ddl/            salinan 1:1 ddl/ NestJS (SUMBER migrations — beku)
docs/           konstitusi, pelacak, bukti gerbang (docs/bukti-g0/)
```

## Menjalankan (dev)

Prasyarat: Go ≥ 1.24, podman (stack dev), repo NestJS bersebelahan (`../nexierp`).

```bash
# .env dari contoh (nilai dev = sama dengan apps/api/.env NestJS)
cp .env.example .env   # lalu isi sesuai apps/api/.env

# backend Go saja
cd ../nexierp && ./rundev.sh start goapi --goversion   # build bila perlu + health-wait :3101

# FE web :3000 mengarah ke backend Go (REST + WS) — auto-nyalakan goapi
cd ../nexierp && ./rundev.sh restart web --goversion
```

- API Go: `http://localhost:3101` (health `/api/health`)
- **Swagger UI**: `http://localhost:3101/api/docs` · JSON: `/api/docs-json`
- NestJS tetap berdampingan di `:3001` (modul yang belum dicutover)
- Stop: `./rundev.sh stop goapi --goversion` · tanpa `--goversion` = perilaku lama (api :3001)

### Build & verifikasi manual

```bash
go build ./... && go vet ./... && go test ./...
gofmt -l internal cmd                      # harus kosong
sqlc generate                              # setelah mengubah db/queries/**
goose -dir db/migrations up                # migrasi (DATABASE_URL dari .env)
node ../.agents/skills/backend-go-scaffold-implementator/scripts/periksa-batas-lapisan-go.mjs \
  --root internal/modules --strict         # guard lapisan: 0 MERAH
```

## Konvensi singkat (detail: AGENTS.md)

- Lapisan turun saja L3 → L2 → L1 → L0; dilarang import lintas modul.
- Satu pohon per modul: `handler` (HTTP murni) → `service` (satu tx: repo +
  audit + outbox + numbering) → `domain` (pure) / `repository` (satu-satunya
  pengguna pgx+sqlc) / `types` / `shared` / `job` / `integration`.
- **Kontrak kawat beku**: path, kode izin RBAC (route-centric `core_routes`
  live = sumber pola), kode error domain, envelope `{data, meta?}` + problem+json
  RFC 7807, `If-Match`/`Idempotency-Key` — PERSIS NestJS. Selisih = koreksi
  paritas (Mode K), bukan perubahan kontrak.
- Commit lokal per task (Bahasa Indonesia), TANPA push; guard 0 MERAH sebelum commit.
