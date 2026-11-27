# nexierp-golang — NexiERP Go Backend

Target repo of the **NestJS → Go strangler migration**. One PostgreSQL, two
runtimes: Go connects to the SAME database as NestJS (`nexierp`) — tables,
outbox, audit, numbering, sessions and RBAC seed are shared. Cutover =
moving ROUTES per module, never moving data.

> Constitution: `docs/ARSITEKTUR-BACKEND-GO.md` (Bahasa Indonesia) · Phase
> tracker: `docs/MIGRASI-BACKEND-GO.md` · Repo discipline: `AGENTS.md` ·
> Source NestJS repo: `/Data/www/nexierp` (READ-ONLY during migration).
> Indonesian version of this file: `README.md`.

## Migration status (per module: G1 audit → G4 parity → G5 cutover → G6 finalize)

| Module | G1–G4 | Notes |
|---|---|---|
| foundation (G0, kernel) | ✅ | full kernel + parity evidence: cross-runtime login, 403 RBAC, outbox, schema ≡ live, WS `rbac.changed` |
| **core (system)** — 130 endpoints | ✅ | live parity 36/38 + 2 artifacts from a stale Nest dist |
| **inv (inventory)** — 114 endpoints | ✅ | master, operations, stock, dashboard+reports; 3 ratified decisions on record |
| G5 physical cutover | ⏸ | awaiting production gateway decision (FE dev can already run against Go via `--goversion`) |
| sls, purchasing, pos, fnb, ai, ecom, acc, hr, pgw, shipment, wa, wf | ⬜ | ratified order: core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf |

## Locked stack

| Role | Choice |
|---|---|
| HTTP | Echo v4 on top of `net/http` |
| DB | pgx/v5 (pool) + sqlc (SQL-first; `db/queries/**` → `repository/gen`) |
| Migrations | goose over 1:1 copies of the NestJS `ddl/*.sql` (+ live-shape reconciliation) |
| AuthN | golang-jwt HS256 + argon2id + shared `core_sessions` table (same secret, claims `{sub, username, sid}`) |
| AuthZ | route-centric RBAC middleware — resolves `(method, path)` against the LIVE `core_routes` table + multi-role union compiler with per-user overrides (deny wins) + 3-mode data-scope |
| Queue/cron | asynq + go-redis (cycle pattern: interval re-read from CFG on every run, 0 = off) |
| Realtime | native WebSocket `coder/websocket` at `/ws` (`rbac.changed`; replaces socket.io since G0) |
| Storage | aws-sdk-go-v2 (MinIO/S3, GET presign) |
| Mail | go-mail + `core_mail_log` |
| API contract | OpenAPI-first `api/openapi/<module>.yaml` (+ zod-derived JSON Schemas in `api/json-schema/`) |

Banned: ORMs (GORM etc.), other HTTP frameworks, multiple `go.mod`, a new
database, editing `ddl/` inside this repo.

## Layout

```
cmd/
  api/          HTTP binary (wiring via internal/app.Bangun)
  worker/       asynq + cron cycles (per-module jobs: RegWorker)
  scanroute/    parity scanner: Go routes vs live core_routes (merge-only until G7)
internal/
  core/         L1 kernel: database, config, logging, errkontrak (problem+json),
                auth, rbac, audit, outbox, numbering, moduleconfig, redis,
                queue, storage, mailer, realtime, idempoten, ctxsistem, pkcipher
  modules/core/ system module (130 ep) — iam, rbac, security, tenants, files, …
  modules/inv/  inventory module (114 ep) — master, operations, stock, dashboard+reports
  app/          Bangun(): single place wiring every module
  docs/         Swagger: merges api/openapi/*.yaml
api/openapi/    wire contracts per module (auth, system, inventory)
api/json-schema/ JSON Schemas generated from the NestJS packages/schemas
db/migrations/  goose (1:1 ddl/ port + live-shape reconciliation)
db/queries/     sqlc sources per package
tools/          json-schema-gen (reads NestJS packages/schemas read-only)
scripts/        hashgen, parity evidence (bukti403/buktioutbox/buktiws), parity.py
ddl/            1:1 copy of NestJS ddl/ (SOURCE of migrations — frozen)
docs/           constitution, tracker, gate evidence (docs/bukti-g0/)
```

## Running (development)

Prerequisites: Go ≥ 1.24, podman (dev stack), the NestJS repo next door
(`../nexierp`).

```bash
# .env from the example (dev values = same as NestJS apps/api/.env)
cp .env.example .env   # then fill in to match apps/api/.env

# Go backend only
cd ../nexierp && ./rundev.sh start goapi --goversion   # builds if needed + health-waits :3101

# FE web :3000 pointed at the Go backend (REST + WS) — auto-starts goapi
./rundev.sh restart web --goversion
```

- Go API: `http://localhost:3101` (health at `/api/health`)
- **Swagger UI**: `http://localhost:3101/api/docs` · JSON: `/api/docs-json`
- NestJS keeps running alongside at `:3001` (modules not yet cut over)
- Stop: `./rundev.sh stop goapi --goversion` · without `--goversion` = legacy behavior (api :3001)

### Build & manual verification

```bash
go build ./... && go vet ./... && go test ./...
gofmt -l internal cmd                      # must be empty
sqlc generate                              # after changing db/queries/**
goose -dir db/migrations up                # migrations (DATABASE_URL from .env)
node ../.agents/skills/backend-go-scaffold-implementator/scripts/periksa-batas-lapisan-go.mjs \
  --root internal/modules --strict         # layer guard: 0 RED
```

## Conventions in brief (details: AGENTS.md, Bahasa Indonesia)

- Layers go DOWN only: L3 → L2 → L1 → L0; no cross-module imports.
- One tree per module: `handler` (pure HTTP) → `service` (one tx: repo +
  audit + outbox + numbering) → `domain` (pure) / `repository` (only pgx+sqlc
  user) / `types` / `shared` / `job` / `integration`.
- **Frozen wire contract**: paths, RBAC permission codes (route-centric, live
  `core_routes` = source of truth), domain error codes, `{data, meta?}`
  envelope + RFC 7807 problem+json, `If-Match`/`Idempotency-Key` — EXACTLY
  like NestJS. Any drift = parity fix (Mode K), never a contract change.
- Local commit per task (Indonesian messages), NO push; guard 0 RED before commit.
