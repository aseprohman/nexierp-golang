# Go Backend Architecture — NexiERP NestJS→Go Migration (nexierp-golang)

> Constitution of the `nexierp-golang` repo. `migrasi-backend-go-plan` derives
> its tracker from it (`docs/MIGRASI-BACKEND-GO.md`); `backend-go-scaffold-implementator`
> executes it per module. Mapping drift = ask the user for a decision, then
> change THIS document first.
> Source of facts: the NestJS repo `/Data/www/nexierp` (READ-ONLY), inventoried
> 2026-11-27; the Go repo was still empty when this document was created. Go toolchain:
> **1.24.2** (linux/amd64).
> Source of the module order: `/Data/www/nexierp/docs/peta-modul.md` — note:
> `docs/ARSITEKTUR-BACKEND-NESTJS.md` does NOT exist in the active repo; that
> document belongs to the first-generation repo `/Data/www/nexgeaa-erp` (11 modules, old set).
> The BEHAVIOR constitution = peta-modul.md + the NestJS `AGENTS.md` + the NestJS code.

## 0. Risk decisions — RATIFICATION STATUS

Ratified by the user 2026-11-27:

| Decision | Status | Chosen content |
|---|---|---|
| Realtime | ✅ RATIFIED | **Moved as of G0** — socket.io switched off at G0; Go WebSocket hub (`coder/websocket`) at `internal/core/realtime`; FE swaps in a 1-file client (`apps/web/src/lib/realtime.ts`). |
| FE↔BE schema contract | ✅ RATIFIED | `@nexierp/schemas` (zod) stays the FE source; a JSON Schema generator script (NEW, lives in the Go repo, reads the NestJS `packages/schemas` read-only) → `api/json-schema/*.json` for Go event/listener payload validation + parity tests; new wire contracts are born in `api/openapi/<m>.yaml` (OpenAPI-first) → `oapi-codegen` (BE) + `openapi-typescript` (FE, gradually per module). |
| Auth parity | ✅ RATIFIED | Secrets `JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET`, claims `{sub: number, username, sid}`, table `core_sessions`, dual-space cookies (`nexierp_at/rt`, `ecom_at/rt`), argon2 upgrade-on-login — ALL shared; **login is cut over to Go as of G0**. Reference for the `core_sessions` shape = the live DB schema; `ddl/core.sql` (live-sourced) now contains that shape intact. |
| Module order | ✅ RATIFIED | Map + AI moved up ("Peta + ai-naik"): `core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf` (see §8). |
| Route & permission pattern | ✅ RATIFIED | **NestJS = the single source of route patterns** — path, method, and `permission_code` in the live `core_routes` table are canonical; the Go `cmd/scanroute` = PARITY-SCANNER (1:1 verification + merge-only candidates for Go-only routes, NO DELETE/UPDATE of NestJS rows until G7). The FE never changes. |

## 1. Decision Summary

1. **One PostgreSQL, two runtimes** — Go connects to the SAME `nexierp`
   database as NestJS: tables, outbox, audit, numbering, sessions, RBAC seed
   are shared. Cutover = moving ROUTES per module (strangler via
   gateway/proxy), never moving data. Creating a NEW database is FORBIDDEN.
2. **FROZEN wire contract** — global prefix `/api`, paths & methods,
   route-centric RBAC permission codes `{modul}.{fitur}.{handler}`
   (module.feature.handler), domain error codes
   (`AUTH-401`, `ECOM-010`, `SHP-013`, `PGW-005`, `WA-017`, etc.), camelCase
   JSON shapes, envelope `{success, data?, error?}`, pagination envelope,
   headers `If-Match` / `Idempotency-Key` — all EXACTLY NestJS. The FE must
   never notice the runtime switch.
3. **Uniform business patterns** — catalog in §7: one NestJS pattern = one
   standard Go shape; one pattern with two shapes across modules is forbidden.
4. **NestJS remains the behavioral constitution** — business decisions (one
   transaction UoW, in-transaction outbox, approval, data-scope, race-free
   numbering) do not change; only their technical form changes.
5. Stack locked in §5; scaffold locked in §3; no technical decision outside
   this document without user ratification.

## 2. High-Level Architecture (strangler)

```
                     ┌────────────────────────── FE (apps/web + portal) ──────────────┐
                     │  REST via /api (cookie/Bearer)      WS: wss://…/ws (rbac.changed)│
                     └───────────────┬──────────────────────────────────┬────────────┘
                                     ▼                                  ▼
                          ┌── gateway / proxy (cutover per MODULE ROUTE) ──┐
                          │  route not yet cut over ──▶ NestJS :OLD_PORT   │
                          │  route already cut over ──▶ Go cmd/api         │
                          └───────┬──────────────────────────────┬────────┘
                                  ▼                              ▼
                            NestJS (Fastify)               Go (Echo v4)
                            in-process BullMQ worker       cmd/worker (asynq + cron goroutine)
                                  │                              │
                    ┌─────────────┴──────────────────────────────┴─────────────┐
                    │        PostgreSQL `nexierp` (ONE, shared by both)          │
                    │  live schema; Go ddl/ = live-sourced per module (regen)    │
                    │  Redis (BullMQ Nest ↔ asynq Go; rate-limit; cache)         │
                    │  MinIO/S3 (same presign)                                   │
                    └──────────────────────────────────────────────────────────┘
```

- Realtime: AS OF G0 the NestJS socket.io gateway is switched off; the Go WS
  hub (`internal/core/realtime`, path `/ws`) emits `rbac.changed` on
  permission invalidation (counterpart of the `PermissionCompilerService.onInvalidate` bridge).
  Handshake auth = JWT + validation against the same `core_sessions` (room `user:<id>`).
- During the transition, cross-runtime side effects stay correct because both
  runtimes write the same tables (outbox/audit/numbering) in the same patterns.
- Jobs: when a module's routes are cut over, that module's NestJS BullMQ job
  registration is switched off (and its in-process NestJS outbox consumer
  too); the Go worker takes over with the same CFG keys, topics, and idempotency.

## 3. Go Repo Layout (locked)

```
nexierp-golang/
├── go.mod                          # module nexierp — ONE go.mod (not multi-module)
├── AGENTS.md                       # repo discipline (already present)
├── cmd/
│   ├── api/main.go                 # middleware wiring + Register of all modules
│   └── worker/main.go              # asynq server + cron loop (RegWorker of all modules)
├── internal/
│   ├── core/                       # L1 shared kernel (counterpart of NestJS src/core):
│   │   ├── database/               #   pgx/v5 pool + Tx helper (executor forwarded)
│   │   ├── config/                 #   env config (NestJS zod-validation → struct + validation)
│   │   ├── auth/                   #   JWT access+refresh (same claims), argon2id,
│   │   │                           #   core_sessions sessions, dual-space cookies, lockout,
│   │   │                           #   login-audit, activation/change-password
│   │   ├── rbac/                   #   route-centric deny-by-default middleware:
│   │   │                           #   resolve(method,path) against core_routes + compiler
│   │   │                           #   multi-role union + per-user override + data-scope
│   │   ├── audit/                  #   core_audit_trail in-transaction
│   │   ├── outbox/                 #   core_outbox_events: enqueue (topic,key,payload)
│   │   │                           #   idempotent via uq_outbox_topic_key_pending, in-transaction
│   │   ├── numbering/              #   core_sequences UPDATE…RETURNING race-free
│   │   ├── moduleconfig/           #   core_module_configs / core_app_settings (CFG-xx)
│   │   ├── redis/                  #   go-redis/v9 pool
│   │   ├── queue/                  #   asynq mux + cycle pattern (counterpart of JobSiklusBullMQ)
│   │   ├── storage/                #   aws-sdk-go-v2 MinIO presign (counterpart of the kernel storage)
│   │   ├── mailer/                 #   wneessen/go-mail + core_mail_log
│   │   ├── realtime/               #   coder/websocket hub (path /ws) + invalidation bridge
│   │   ├── idempoten/              #   Idempotency-Key middleware + the same idempotency table
│   │   └── ctxsistem/              #   constant system actor for jobs (counterpart of CTX_SISTEM)
│   ├── modules/<m>/                # L3 one tree per module — see §4
│   └── health/                     # health/readiness handler (pg + redis check)
├── db/
│   ├── migrations/                 # goose — 001_core.sql + 002_inv.sql (live-sourced ddl/ content)
│   ├── schema.sql                  # sqlc source — filtered dump of a fresh DB produced by goose up
│   └── queries/<m>/<fitur>.sql     # sqlc sources
├── api/
│   ├── openapi/<m>.yaml            # wire contract per module (oapi-codegen source)
│   └── json-schema/*.json          # generator output from zod (event/listener validation + parity)
├── ddl/                            # live-sourced per module (core.sql, inv.sql) — regenerated from the live DB
├── tools/json-schema-gen/          # JSON Schema generator from packages/schemas (reads NestJS read-only)
└── scripts/                        # sqlc generate, goose, guards
```

Wiring direction: `handler → service → {repository, domain}`; `repository` &
`domain` are forbidden from importing `service`/`handler`; `job`/`listener`
delegate to `service`; direct cross-module imports are forbidden — contracts
go through the outbox event vocabulary + endpoints (identical to the NestJS
discipline). Type names carry no module prefix
(`ProdukHandler`, not `InvProdukHandler`).

## 4. internal/modules/<m> Structure (kinds locked)

```
internal/modules/<m>/
├── module.go                # Register(e, deps) + RegWorker(mux, deps) — wiring in ONE file
├── handler/<fitur>.go       # pure Echo: bind contract → tag validation → delegate → error mapping
├── service/<fitur>.go       # orchestration: domain → ONE pgx.BeginTx (repo+audit+outbox+numbering)
├── domain/<aturan>.go       # PURE — invariants/calculations/transitions; errors.go message mapping
├── repository/<fitur>.go    # sqlc wrapper; receives the executor; row→View happens here
├── repository/gen/          # sqlc output — GENERATED, never hand-edited
├── types/<fitur>.go         # module types + contract overrides (explicit derivation)
├── shared/                  # L2 cross-feature WITHIN the module
├── job/<fitur>-<nama>.go    # asynq handler / cron goroutine — delegates to service
└── integration/
    ├── listener/<sumber>-<event>.go   # outbox consumer (asynq task polling the topic) — idempotent
    └── adapter/<penyedia>.go          # vendor client — stateless struct, NO DB
```

Kind-by-kind prohibition details: see `AGENTS.md` §2 (same as the NestJS
L0–L3 discipline; the `periksa-batas-lapisan-go.mjs --strict` guard must be 0 RED).

## 5. Library Decisions — locked-stack mapping table

| Role | NestJS (nexierp) | Go (nexierp-golang) |
|---|---|---|
| HTTP framework | NestJS 11 + Fastify | **Echo v4** on top of `net/http` |
| DB driver + query | pg + Drizzle ORM | **pgx/v5 (pool) + sqlc** (SQL-first) |
| DDL migrations | drizzle-kit (source: NestJS ddl/) | **goose** over `db/migrations` (001_core + 002_inv) — content = `ddl/` live-sourced per module; schema changes still only land via the NestJS repo, then regenerate from the live DB |
| FE↔BE contract | `@nexierp/schemas` (zod) | **OpenAPI-first** `api/openapi/<m>.yaml` → `oapi-codegen` (BE) + `openapi-typescript` (FE) + zod JSON Schemas (`api/json-schema/`) for event/listener & parity |
| Input validation | nestjs-zod parse | oapi-codegen request structs + `go-playground/validator` |
| API documentation | zod-openapi helper | generated from the same OpenAPI |
| AuthN | custom JWT guard (@nestjs/jwt) + argon2 + `core_sessions` per-request | `golang-jwt/v5` + `alexedwards/argon2id` + the same session table (same claims & TTL) |
| AuthZ | PermissionsGuard route-centric + RouteRegistry `core_routes` + PermissionCompiler | Echo RBAC middleware: resolve(method,path) + union compiler — **permission codes exactly `{modul}.{fitur}.{handler}`** |
| Queue/worker | BullMQ + ioredis, in-process worker (`JobSiklusBullMQ`) | **asynq** + `go-redis/v9`, separate worker `cmd/worker` |
| Cron/loop jobs | BullMQ repeatable scheduler, CFG interval re-read per run | goroutine loop + `robfig/cron/v3`; CFG interval RE-READ every cycle; 0 = off (idle tick 60 s); overlap guard mandatory |
| Realtime | socket.io (gateway `rbac.gateway`, single event `rbac.changed`) | `coder/websocket` hub path `/ws` — RATIFIED to move at G0 |
| Rate limit | @nestjs/throttler opt-in per controller, in-memory | Redis rate-limit middleware |
| Logging | pino | `slog` JSON |
| Transaction UoW | `uow.withTransaction` | explicit `pgx.BeginTx` + `defer rollback` in the service; the `DBTX` executor forwarded to repo/audit/outbox/numbering |
| Audit | core/audit in-transaction | `internal/core/audit` (same `core_audit_trail` table) |
| Outbox | core/outbox in-transaction, consumption polls `FOR UPDATE SKIP LOCKED` | `internal/core/outbox` (same table + topic + `_key` idempotency); consumer = asynq task polling the topic |
| Numbering | core/numbering `UPDATE…RETURNING` | `internal/core/numbering` via sqlc (same `core_sequences` table) |
| Module config | ModuleConfigService CFG-xx | `internal/core/moduleconfig` (same table) |
| System context | system actor `{id:0, username:"system"}` | `context.Context` + constant system actor (`ctxsistem.New`) |
| File storage | aws-sdk v3 (MinIO/S3 presign) | `aws-sdk-go-v2` (same presign) |
| Mail | nodemailer + `core_mail_log` | `wneessen/go-mail` + same table |
| DI | Nest DI | **explicit manual wiring** — `module.go` per module + `cmd/api/main.go` |
| Testing | Jest + (Testcontainers) | `go test` + `testcontainers-go` |
| Monorepo | pnpm + Turborepo | one `go.mod` (not multi-module) |

Adding requirements beyond this table without user ratification is forbidden.

## 6. API Conventions — frozen contract (FACTS of the NestJS repo, not new decisions)

- **Global prefix** `/api` (`apps/api/src/main.ts:64`). All contract paths
  are written without the prefix (the `@Controller` path); the gateway inserts it.
- **Response envelope** (`packages/schemas/src/core/common.ts`):
  `{ success: boolean, data?, error? }`; error `{ code, message, details? }`
  (the NestJS RFC 7807 filter maps 1:1 to the Go `errkontrak` helpers).
- **Pagination**: query `page`, `limit` (max 200), `sort` (`-field`), filters;
  meta `pageMetaSchema`; the `Page<T>` shape is exactly the same.
- **Optimistic locking**: the `If-Match` header carries the `version` number;
  conflict → 409 with the same message. Used by 12 modules (acc 16 files, hr 27,
  sls 15, core 11, pgw 8, ai 5, fnb 5, shipment 5, wf 6, inv 4, ecom 3, wa 1;
  pos & purchasing 0).
- **Idempotency-Key**: header up to 200 chars on POST create — only
  acc (9 files), hr (14), purchasing (3), sls (11).
- **RBAC route-centric deny-by-default** (`core/rbac/guards/permissions.guard.ts`):
  1. PUBLIC_ALLOWLIST: `/health`, `/auth/login`, `/auth/register`,
     `/auth/refresh` + public parameterized patterns (`/wa/webhook/:token`;
     webhooks `pgw/webhook/:vendor`, `shipment/webhook/:vendor`, guest portal
     `ecom/portal/*` = controllers WITHOUT a guard).
  2. `req.user` from the JWT is mandatory (401 `AUTH-401`).
  3. An endpoint not registered in `core_routes` → 403 (zero orphan routes —
     the registry is generated by `podman/scanroutes.sh` rev.6: code
     `{modul}.{fitur}.{handler}`; SET permission = `{modul}.{fitur}` via
     `core_permissions_routes`).
  4. `PermissionCompilerService.has(user.id, code)` — multi-role union +
     per-user override; dynamic data-scope over 3 `core_scope_*` tables
     (fail-open without assignment, whitelist when present).
- **Auth**: access token TTL `JWT_ACCESS_TTL` default `15m`, claims
  `{sub: number, username, sid}`; separate refresh secret + `jti` claim,
  TTL = remaining session lifetime; per-request validation: the `core_sessions`
  row (`is_valid`, `revoked_at IS NULL`, `logout_at IS NULL`, `expires_at > now`,
  active user); dual-space httpOnly cookies (chosen from the `Origin` header vs
  `PORTAL_ORIGINS`): backoffice `nexierp_at`/`nexierp_rt`, portal
  `ecom_at`/`ecom_rt`; `HttpOnly; SameSite=Lax; Path=/`, `Secure` when
  `COOKIE_SECURE=true`, Max-Age access 900 / refresh 43200; argon2
  verification + upgrade-on-login of the plaintext seed; server-side lockout
  (`failed_login_attempts` + `locked_until`, default 60 minutes);
  `core_login_audit` append-only; login = ONE transaction (token pair + session
  per `device_key` + audit). POS cashier PIN = argon2id `core_users.pin`.
- **Vendor webhooks**: `rawBody` mandatory (Midtrans SHA512 dual-key signature
  verification, DOKU HMAC-SHA256 stringToSign 5 lines; Biteship without HMAC →
  anti-spoofing order RE-FETCH; WA Evolution without HMAC, path token). Status
  patterns: WA always 200 to defeat retry storms; pgw/shipment INVALID → 401
  (`PGW-005` / `SHP-013`).
- **Outbox**: publish `enqueue(tx, {topic, key?, payload})` INSIDE the
  transaction; idempotent via the partial unique `(topic, payload._key)`
  (`uq_outbox_topic_key_pending`); duplicate → skip insert, return the old id.
- **DDL note (live-sourced policy, 2026-11-27)**: `ddl/` is no longer a copy
  of the NestJS `ddl/` — it is now **live-sourced per module**: `ddl/core.sql`
  (core module + cross-read `hr_karyawan`) and `ddl/inv.sql` (inv module +
  cross-read `pur_penerimaan`/`pur_penerimaan_item`/`pur_pesanan`/
  `pur_pesanan_item`/`pur_pemasok`), produced from a schema-only dump of the
  live DB (`nexierp-postgres`) filtered per object name; FKs to tables outside
  the scope are intentionally dropped. `db/migrations` = 001_core.sql + 002_inv.sql
  (that ddl content + goose annotations); `db/schema.sql` (the sqlc source) =
  filtered dump of a fresh DB produced by goose up. To regenerate: re-dump the
  live DB → split per module → test goose on a fresh Postgres → filtered dump
  → `sqlc generate`.
  Schema changes STILL only originate in the NestJS repo; live-vs-code drift
  is recorded in the tracker Log, with minimal Mode K fixes on the Go side.

## 7. Catalog of NestJS → Go business patterns (one pattern, one shape)

| # | Pattern in NestJS (repo evidence) | Standard Go pattern |
|---|---|---|
| 1 | Master CRUD + optimistic locking `If-Match` (12 modules) | handler parse → service checks version → sqlc repo; 409 + same message |
| 2 | Transactional documents (header+detail, posting, state machine: acc journal, sls/pos/ecom orders, inv mutations) | transitions/validation = pure `domain/` functions; service = one `pgx.BeginTx` (repo+audit+outbox+numbering) |
| 3 | Threshold approval + SoD (submit/approve/decide in many modules; SoD warn-only in core) | pure domain + thresholds from the same config tables |
| 4 | BullMQ cycle jobs `JobSiklusBullMQ` (10 jobs, CFG interval re-read, 0 = off, overlap guard) | goroutine loop + asynq; read CFG per cycle + overlap guard; one cycle = ONE service delegation (`ctxsistem.New`); idempotent |
| 5 | Cross-module events (in-transaction outbox; consumers poll `SKIP LOCKED`: ecom M52/M56/M24, sls M07) | publish via `core/outbox` INSIDE the transaction; consumer = asynq task polling the topic, payload validated with the zod JSON Schema, idempotent per `_key` |
| 6 | Stateless vendor adapters (Midtrans, DOKU, Biteship, Evolution, LLM-WA, Anthropic, OpenAI-compat) | stateless struct + module registry; NO DB; same HTTP timeouts; vendor facts in header comments |
| 7 | Presign upload/media (core files + MinIO) | `core/storage` (aws-sdk-go-v2) |
| 8 | Async report export (audit-trail CSV etc.) | asynq task → core/storage → realtime notification |
| 9 | Idempotency-Key (acc/hr/purchasing/sls) | `core/idempoten` middleware + the same idempotency table |
| 10 | Multi-outlet/tenant data scope (3 `core_scope_*` tables) | filter in the repository via the core scope helper — same query result |
| 11 | Realtime notification (`rbac.changed` only) | `core/realtime` WS hub (ratification §0) |
| 12 | Health/readiness (`/health`, system/health) | `internal/health` handler (pg + redis check) |
| 13 | Incoming vendor webhooks (pgw/shipment/wa) | public rawBody handler + adapter signature verification + status pattern per §6 |
| 14 | Route & permission registry (`scanroutes.sh` → `core_routes`) | Go `cmd/scanroute` = parity-scanner: compare Echo routes vs live `core_routes` (NestJS canonical); merge-only candidates only for Go-only routes; no delete/update of NestJS rows until G7 |

## 8. Migration Strategy — phase table (source of the tracker)

- **G0 Foundation (ONCE, executor Mode F)** — §3 scaffold, go.mod, Echo,
  pg pool, config, slog, goose over `db/migrations` (live-sourced ddl/ content),
  complete `internal/core/*`
  (auth/rbac/audit/outbox/numbering/moduleconfig/redis/queue/storage/mailer/
  realtime/idempoten/ctxsistem), health, cmd/api + cmd/worker, the zod
  JSON Schema generator, sqlc+goose+scanroute scripts. The auth routes
  (`/api/auth/*`) are cut over to Go HERE (ratification §0); the NestJS
  socket.io gateway is switched off, the Go WS hub goes live, the FE swaps its client.
  **Mandatory evidence**: (a) a login via Go yields a JWT valid in NestJS & FE;
  (b) 403 RBAC parity (unregistered route / insufficient permission); (c) an
  outbox event published by Go is readable by the NestJS consumer; (d) the goose
  migration produces a schema identical to `ddl/`; (e) the FE receives
  `rbac.changed` from the Go WS hub.
- **G1–G6 per module** (order = ratification §0, upstream→downstream):
  - **G1 NestJS module audit (READ-ONLY)** — inventory of endpoints+permissions+contracts
    +errors+tx+If-Match/Idempotency-Key+job/listener/adapter+domain per feature.
  - **G2 OpenAPI contract** — `api/openapi/<m>.yaml` complete with all endpoints.
  - **G3 Go generation** — the §4 tree per feature WHOLE; `go build ./... && go test
    ./...` green per step; guard 0 RED.
  - **G4 Parity gate** — P1–P9 pass (P9 = FE smoke via regression-gate).
  - **G5 Route cutover** — the gateway redirects the module's routes to Go; the module's
    BullMQ jobs + in-process NestJS outbox consumers are switched off; the module's
    NestJS routes are disabled (NOT deleted).
  - **G6 Finalize** — delete the module's NestJS routes; tracker updated with evidence.
- **G7 Decommissioning (ONCE, after ALL modules are G6 ✅)** — the NestJS API &
  Node worker fully switched off, the FE fully through Go, the tracker closed.

**Module order (14, ratification 2026-11-27 — "Peta + ai-naik" / map + AI moved up)**:

| Rank | Module | Endpoints | Notes upstream→downstream |
|---|---|---|---|
| 1 | core (system) | 130 | RBAC/iam/security/files/tenants kernel — right after the G0 foundation |
| 2 | inv (inventory) | 114 | operational upstream (issuer of M02/M04/M16/M27) |
| 3 | sls (sales) | 83 | own outbox consumer (M07), invoice trigger |
| 4 | purchasing | 90 | receipt → inv; invoice → acc |
| 5 | pos | 69 | cashier (no If-Match/Idem); journal sink |
| 6 | fnb | 53 | consumes inv; production/KDS |
| 7 | ai | 30 | LLM provider — moved up ahead of its consumers (ecom, wa) |
| 8 | ecom | 95 | consumer of M52/M56/M24 (pgw/shp/sls); public portal |
| 9 | acc | 98 | journal SINK — after all issuers |
| 10 | hr | 150 | payroll → acc journal (already live) |
| 11 | pgw | 31 | Midtrans/DOKU adapter + webhook; ecom consumer |
| 12 | shipment | 26 | Biteship adapter + webhook; ecom consumer |
| 13 | wa | 55 | Evolution + LLM; public webhook; ai consumer |
| 14 | wf | 22 | workflow engine — last (not yet consumed by other modules) |

Order exceptions only with a user decision recorded in the tracker Log.

## 9. Testing & DevOps

- `go test ./...` + `testcontainers-go` (real Postgres + Redis for integration
  tests); clean `gofmt`, `go vet ./...` at every step.
- Layer guard `periksa-batas-lapisan-go.mjs --strict` must be 0 RED
  before commit (local commits, no push, Indonesian commit messages).
- Parity gates P1–P9 per module (P9 = FE smoke, `regression-gate`).
- Side-by-side deploy: the Go binary runs on its own port; the gateway/proxy
  redirects routes per module (`release-deploy`/`devops-runner`); rollback =
  restore the gateway routes.

## 10. NOT Used (banned from the repo)

- Any ORM (GORM/ent/sqlboiler) — only pgx + sqlc.
- Other HTTP frameworks (chi/gin/fiber), magic DI (wire/fx/dig).
- Multiple `go.mod` / go workspace.
- A new database or data migration; hand-editing `ddl/` in the Go repo
  (only regenerate from the live DB — the live-sourced policy §6).
- socket.io / socket.io-client (replaced by native WS since G0 — ratification §0).
- Changing the wire contract (paths/permissions/error codes/JSON shapes) — drift =
  a Mode K parity fix, never a contract change.
- Changing the NestJS repo `/Data/www/nexierp` from this repo (READ-ONLY).

## Appendix A — NestJS fact inventory (2026-11-27, 14 active modules)

| Module | Route prefix | Ctrl | Endpoints | If-Match (files) | Idem-Key (files) | Jobs | Adapters |
|---|---|---|---|---|---|---|---|
| core (system) | `system.*` | 19 | 130 | 11 | — | auth.token-sweep | — |
| inv | `inventory.*` | 20 | 114 | 4 | — | — | — |
| sls | `sls.*` | 13 | 83 | 15 | 11 | sls.faktur-pemicu | — |
| purchasing | `purchasing.*` | 13 | 90 | — | 3 | — | — |
| pos | `pos.*` | 10 | 69 | — | — | — | — |
| fnb | `fnb.*` | 8 | 53 | 5 | — | fnb.buka-86 | — |
| ai | `ai.*` | 5 | 30 | 5 | — | — | anthropic, openai-compatible |
| ecom | `ecom.*` | 19 | 95 | 3 | — | ecom.pesanan-sweep, ecom.pengiriman-status | — (SHP facade) |
| acc | `acc.*` | 21 | 98 | 16 | 9 | — | — |
| hr | `hr.*` | 23 | 150 | 27 | 14 | — | — |
| pgw | `pgw.*` | 7 | 31 | 8 | — | pgw.transaksi-sweep | midtrans, doku |
| shipment | `shipment.*` | 8 | 26 | 5 | — | shp.sweep | biteship |
| wa | `wa.*` | 13 | 55 | 1 | — | wa.pesan-kirim, wa.kampanye-sweep, wa.status-kirim | evolution, llm |
| wf | `wf.*` | 4 | 22 | 6 | — | — | — |
| **Total** | | **183 files / 189 classes** | **1,046** | | | **10 jobs** | **7 adapters** |

All jobs use the `JobSiklusBullMQ` pattern (`core/redis/job-siklus.ts`);
infrastructure constants: dead tick 60 s, minimum interval 1 s, kickoff 10 s,
Redis retry 60 s, attempts 1. Per-job interval configuration (verbatim): auth
`AUTH_TOKEN_SWEEP_INTERVAL_MS` (6 hours); ecom `CFG-ECOM-17`, `CFG-ECOM-SWEEP`;
fnb `CFG-FNB-14` (+ mode gate `CFG-FNB-03` = OTOMATIS); pgw
`CFG-PGW-SWEEP`; shp `CFG-SHP-05` (hours, 0.25 fractions valid); sls `CFG-SLS-14`
(MODULE_KEY_SLS = `sales`); wa `CFG-WA-10.backoff_detik`, `CFG-WA-11`
(MODULE_KEY_WA = `whatsapp-crm`).

**In-repo outbox consumers**: ecom ← `pgw.transaksi.status`, `shipment.order.status`,
`sls.so.status` (idempotent per `_key` + order status; M52 amount validation
`uangSama`); sls ← `sls.faktur.pemicu` (key `m07:<entityId>:reg|dp`, cap
20/cycle); wa ← local relay of the `wa_pesan` queue (not an outbox poll;
idempotency trace `uq_wa_pesan_event`). Other topics have NO in-repo consumer
yet (the `apps/worker` relay is planned, not present).

**Outbox event vocabulary (issuer → verbatim topic; 47 `.enqueue(` sites)**:

- acc: `acc.jurnal.posted`, `acc.faktur.pemasok.posted`, `acc.pembayaran.posted`
- hr: `hr.slip.terbit`, `hr.slip.pembalik`, `hr.jurnal.payroll`, `hr.pph21.masa`, `hr.batch.selesai`
- purchasing: `pur.rfq.kirim.wa`, `pur.retur.disetujui`, `pur.faktur.posted`, `pur.landed.teralokasi`, `pur.penerimaan.diterima`, `pur.dp.disetujui`, `pur.po.dibatalkan`, `pur.po.ditutup`, `pur.po.disetujui`, `pur.po.jadwal`, `pur.po.jasa`, `pur.po.dropship`
- inv: `inventory.move.completed`, `inventory.delivery.completed`, `inventory.receipt.completed`, `inventory.reorder.triggered`
- sls: `sls.so.dikonfirmasi`, `sls.faktur.pemicu`, `sls.so.status`, `sls.faktur.pos.status`, `sls.retur.gerakan`, `sls.retur.kredit`
- pos: `pos.pesanan.faktur`, `pos.sesi.ditutup`
- pgw: `pgw.pembayaran.posted`, `pgw.transaksi.status`, `pgw.tautan.bayar`
- shipment: `shipment.biaya.final`, `shipment.order.status`
- ecom: `acc.pembayaran.manual`
- wa: `wa.pesan.kirim`, `wa.notifikasi.sla`, `wa.notifikasi.kuota`

Topics are NOT enumerated in `packages/schemas` (`topic` = `z.string().min(1)`);
topic constants live in the issuer module's `types/` — the Go port follows the
same source (the Go module's `types/`).

**Realtime**: a single gateway `core/realtime/gateways/rbac.gateway.ts`
(path `/socket.io`), handshake auth `JwtAuthGuard.authenticate` (space
cookie/Bearer + `core_sessions` validation), room `user:<id>`, emits ONE event
`rbac.changed` `{reason:"rbac"}`, no `@SubscribeMessage`; bridge from
`PermissionCompilerService.onInvalidate`; CORS allowlist `WEB_ORIGIN`;
FE client is 1 file `apps/web/src/lib/realtime.ts`.

**Schemas**: `packages/schemas` 150 .ts files, 14 module folders; the
`tipe.ts`/`schemas.ts`/`views.ts`/`index.ts` pattern; naming `*BuatSchema` (76),
`*UbahSchema` (56), `*ViewSchema` (374), `*QuerySchema` (18); manifest
`satu-sumber.json` + guard `guard-satu-sumber.mjs`; core DB moduleKey =
`system` (folder name = `core`). No JSON Schema generator yet — built new in
`tools/json-schema-gen` (ratification §0).

**Fact errors CORRECTED from the first draft**: (a) the old modules
(fnb/inv/sls/pur/shp/pos/acc/wa) were NOT deleted — all 14 modules live in
`app.module.ts`; the tarballs under `/Data/www` are only partial feature archives;
(b) `@RequirePermission` = 0 usages (route-centric permission model via
`core_routes`); (c) there is no `integration/listener` folder — outbox
consumption = explicit polling; (d) the public checkouts `nexierp-github`/
`nexierp-porto*` are repo excerpts, not working repos.
