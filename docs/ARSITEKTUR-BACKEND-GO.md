# ARSITEKTUR BACKEND GO — Konstitusi Migrasi NestJS → Go (nexierp-golang)

> Konstitusi repo `nexierp-golang`. `migrasi-backend-go-plan` menurunkan
> pelacaknya (`docs/MIGRASI-BACKEND-GO.md`); `backend-go-scaffold-implementator`
> mengeksekusi per modulnya. Selisih pemetaan = minta keputusan user, lalu
> ubah dokumen INI dulu.
> Sumber fakta: repo NestJS `/Data/www/nexierp` (READ-ONLY), diinventarisasi
> 2026-11-27; repo Go masih kosong saat dokumen ini dibuat. Toolchain Go:
> **1.24.2** (linux/amd64).
> Sumber urutan modul: `/Data/www/nexierp/docs/peta-modul.md` — catatan:
> `docs/ARSITEKTUR-BACKEND-NESTJS.md` TIDAK ada di repo aktif; dokumen itu
> milik repo generasi pertama `/Data/www/nexgeaa-erp` (11 modul, set lama).
> Konstitusi PERILAKU = peta-modul.md + `AGENTS.md` NestJS + kode NestJS.

## 0. Keputusan risiko — STATUS RATIFIKASI

Diratifikasi user 2026-11-27:

| Keputusan | Status | Isi yang dipilih |
|---|---|---|
| Realtime | ✅ RATIFIKASI | **Pindah sejak G0** — socket.io dimatikan di G0; Go hub WebSocket (`coder/websocket`) di `internal/core/realtime`; FE ganti client 1 file (`apps/web/src/lib/realtime.ts`). |
| Kontrak skema FE↔BE | ✅ RATIFIKASI | `@nexierp/schemas` (zod) tetap sumber FE; script generator JSON Schema (BARU, hidup di repo Go, baca `packages/schemas` NestJS read-only) → `api/json-schema/*.json` untuk validasi payload event/listener Go + parity test; kontrak kawat baru lahir di `api/openapi/<m>.yaml` (OpenAPI-first) → `oapi-codegen` (BE) + `openapi-typescript` (FE bertahap per modul). |
| Auth parity | ✅ RATIFIKASI | Secret `JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET`, klaim `{sub: number, username, sid}`, tabel `core_sessions`, cookie dua ruang (`nexierp_at/rt`, `ecom_at/rt`), argon2 upgrade-on-login — SEMUA dipakai bersama; **login dicutover ke Go sejak G0**. Acuan bentuk `core_sessions` = skema Drizzle live (`apps/api/src/core/database/schema/core.ts`), BUKAN `ddl/01-core.sql` versi lama yang tidak sinkron. |
| Urutan modul | ✅ RATIFIKASI | Peta + ai-naik: `core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf` (lihat §8). |
| Pola route & permission | ✅ RATIFIKASI | **NestJS = sumber pola tunggal** — path, method, dan `permission_code` di `core_routes` live adalah kanonik; `cmd/scanroute` Go = PARITY-SCANNER (verifikasi 1:1 + kandidat merge-only untuk route Go-only, TANPA DELETE/UPDATE baris NestJS sampai G7). FE tidak pernah berubah. |

## 1. Ringkasan Keputusan

1. **Satu PostgreSQL, dua runtime** — Go konek ke database `nexierp` yang
   SAMA dengan NestJS: tabel, outbox, audit, numbering, sesi, seed RBAC
   dipakai bersama. Cutover = memindahkan ROUTE per modul (strangler via
   gateway/proxy), bukan memindahkan data. DILARANG membuat DB baru.
2. **Kontrak kawat BEKU** — prefix global `/api`, path & method, kode izin
   RBAC route-centric `{modul}.{fitur}.{handler}`, kode error domain
   (`AUTH-401`, `ECOM-010`, `SHP-013`, `PGW-005`, `WA-017`, dst.), bentuk
   JSON camelCase, envelope `{success, data?, error?}`, envelope pagination,
   header `If-Match` / `Idempotency-Key` — semua PERSIS NestJS. FE tidak
   boleh sadar pindah runtime.
3. **Pola bisnis seragam** — katalog §7: satu pola NestJS = satu bentuk Go
   baku; dilarang satu pola dua bentuk antar modul.
4. **Konstitusi perilaku tetap NestJS** — keputusan bisnis (UoW satu
   transaksi, outbox in-transaction, approval, data-scope, numbering
   anti-race) tidak berubah; yang berubah hanya bentuk teknisnya.
5. Stack terkunci §5; scaffold terkunci §3; tidak ada keputusan teknis di
   luar dokumen ini tanpa ratifikasi user.

## 2. Arsitektur Tingkat Tinggi (strangler)

```
                     ┌────────────────────────── FE (apps/web + portal) ──────────────┐
                     │  REST via /api (cookie/Bearer)      WS: wss://…/ws (rbac.changed)│
                     └───────────────┬──────────────────────────────────┬────────────┘
                                     ▼                                  ▼
                          ┌── gateway / proxy (cutover per ROUTE modul) ──┐
                          │  route belum dicutover ──▶ NestJS :PORT_LAMA  │
                          │  route sudah dicutover ──▶ Go cmd/api         │
                          └───────┬──────────────────────────────┬────────┘
                                  ▼                              ▼
                            NestJS (Fastify)               Go (Echo v4)
                            worker in-process BullMQ       cmd/worker (asynq + cron goroutine)
                                  │                              │
                    ┌─────────────┴──────────────────────────────┴─────────────┐
                    │        PostgreSQL `nexierp` (SATU, dipakai bersama)       │
                    │  ddl/*.sql — core_*, inv_*, acc_*, … (TIDAK diubah)       │
                    │  Redis (BullMQ Nest ↔ asynq Go; rate-limit; cache)        │
                    │  MinIO/S3 (presign sama)                                  │
                    └──────────────────────────────────────────────────────────┘
```

- Realtime: SEJAK G0 gateway socket.io NestJS dimatikan; hub WS Go
  (`internal/core/realtime`, path `/ws`) memancarkan `rbac.changed` saat
  invalidasi izin (padanan bridge `PermissionCompilerService.onInvalidate`).
  Auth handshake = JWT + validasi `core_sessions` yang sama (room `user:<id>`).
- Selama transisi, efek samping lintas-runtime tetap benar karena keduanya
  menulis tabel yang sama (outbox/audit/numbering) dalam pola yang sama.
- Job: saat route modul dicutover, registrasi job BullMQ NestJS modul itu
  dimatikan (dan konsumen outbox in-process NestJS-nya juga); Go worker
  mengambil alih dengan CFG key, topik, dan idempotensi yang sama.

## 3. Layout Repo Go (terkunci)

```
nexierp-golang/
├── go.mod                          # module nexierp — SATU go.mod (bukan multi-module)
├── AGENTS.md                       # disiplin repo (sudah ada)
├── cmd/
│   ├── api/main.go                 # wiring middleware + Register semua modul
│   └── worker/main.go              # asynq server + loop cron (RegWorker semua modul)
├── internal/
│   ├── core/                       # L1 shared kernel (padanan src/core NestJS):
│   │   ├── database/               #   pool pgx/v5 + Tx helper (executor diteruskan)
│   │   ├── config/                 #   env config (zod-validasi NestJS → struct + validasi)
│   │   ├── auth/                   #   JWT access+refresh (klaim sama), argon2id,
│   │   │                           #   sesi core_sessions, cookie dua ruang, lockout,
│   │   │                           #   login-audit, aktivasi/change-password
│   │   ├── rbac/                   #   middleware route-centric deny-by-default:
│   │   │                           #   resolve(method,path) ke core_routes + compiler
│   │   │                           #   union multi-role + override per-user + data-scope
│   │   ├── audit/                  #   core_audit_trail in-transaction
│   │   ├── outbox/                 #   core_outbox_events: enqueue (topic,key,payload)
│   │   │                           #   idempoten uq_outbox_topic_key_pending, in-transaction
│   │   ├── numbering/              #   core_sequences UPDATE…RETURNING anti-race
│   │   ├── moduleconfig/           #   core_module_configs / core_app_settings (CFG-xx)
│   │   ├── redis/                  #   go-redis/v9 pool
│   │   ├── queue/                  #   asynq mux + pola siklus (padanan JobSiklusBullMQ)
│   │   ├── storage/                #   aws-sdk-go-v2 presign MinIO (padanan kernel storage)
│   │   ├── mailer/                 #   wneessen/go-mail + core_mail_log
│   │   ├── realtime/               #   hub coder/websocket (path /ws) + bridge invalidasi
│   │   ├── idempoten/              #   middleware Idempotency-Key + tabel idempoten sama
│   │   └── ctxsistem/              #   aktor sistem konstan untuk job (padanan CTX_SISTEM)
│   ├── modules/<m>/                # L3 satu pohon per modul — lihat §4
│   └── health/                     # handler health/readiness (pg + redis check)
├── db/
│   ├── migrations/                 # goose — porting BERURUTAN ddl/*.sql NestJS (nama & urutan file sama)
│   └── queries/<m>/<fitur>.sql     # sumber sqlc
├── api/
│   ├── openapi/<m>.yaml            # kontrak kawat per modul (sumber oapi-codegen)
│   └── json-schema/*.json          # hasil generator dari zod (validasi event/listener + parity)
├── ddl/                            # salinan 1:1 ddl/ NestJS (SUMBER migrations; tidak pernah diedit)
├── tools/json-schema-gen/          # generator JSON Schema dari packages/schemas (baca NestJS read-only)
└── scripts/                        # sqlc generate, goose, guard
```

Arah wiring: `handler → service → {repository, domain}`; `repository` &
`domain` dilarang mengimpor `service`/`handler`; `job`/`listener` delegasi ke
`service`; lintas modul dilarang impor langsung — kontrak via kosakata event
outbox + endpoint (identik disiplin NestJS). Nama type tanpa prefix modul
(`ProdukHandler`, bukan `InvProdukHandler`).

## 4. Struktur internal/modules/<m> (kind terkunci)

```
internal/modules/<m>/
├── module.go                # Register(e, deps) + RegWorker(mux, deps) — wiring SATU file
├── handler/<fitur>.go       # Echo murni: bind kontrak → validasi tag → delegasi → pemetaan error
├── service/<fitur>.go       # orkestrasi: domain → SATU pgx.BeginTx (repo+audit+outbox+numbering)
├── domain/<aturan>.go       # PURE — invariant/kalkulasi/transisi; errors.go pemetaan pesan
├── repository/<fitur>.go    # wrapper sqlc; terima executor; row→View di sini
├── repository/gen/          # output sqlc — GENERATED, tidak pernah diedit
├── types/<fitur>.go         # tipe modul + override kontrak (turunan eksplisit)
├── shared/                  # L2 lintas-fitur SE-MODUL
├── job/<fitur>-<nama>.go    # asynq handler / goroutine cron — delegasi service
└── integration/
    ├── listener/<sumber>-<event>.go   # konsumen outbox (task asynq poll topik) — idempoten
    └── adapter/<penyedia>.go          # klien vendor — struct tanpa state, TANPA DB
```

Rincian larangan per kind: lihat `AGENTS.md` §2 (sama dengan disiplin NestJS
L0–L3, guard `periksa-batas-lapisan-go.mjs --strict` wajib 0 MERAH).

## 5. Keputusan Library — tabel pemetaan stack terkunci

| Peran | NestJS (nexierp) | Go (nexierp-golang) |
|---|---|---|
| Framework HTTP | NestJS 11 + Fastify | **Echo v4** di atas `net/http` |
| DB driver + query | pg + Drizzle ORM | **pgx/v5 (pool) + sqlc** (SQL-first) |
| Migrasi DDL | drizzle-kit atas `ddl/*.sql` | **goose** atas file `ddl/*.sql` yang sama (porting berurutan; bentuk live = acuan Drizzle, catatan core_sessions §6) |
| Kontrak FE↔BE | `@nexierp/schemas` (zod) | **OpenAPI-first** `api/openapi/<m>.yaml` → `oapi-codegen` (BE) + `openapi-typescript` (FE) + JSON Schema zod (`api/json-schema/`) untuk event/listener & parity |
| Validasi input | nestjs-zod parse | struct request oapi-codegen + `go-playground/validator` |
| Dokumentasi API | zod-openapi helper | dihasilkan dari OpenAPI yang sama |
| AuthN | custom JWT guard (@nestjs/jwt) + argon2 + `core_sessions` per-request | `golang-jwt/v5` + `alexedwards/argon2id` + tabel sesi yang sama (klaim & TTL sama) |
| AuthZ | PermissionsGuard route-centric + RouteRegistry `core_routes` + PermissionCompiler | middleware RBAC Echo: resolve(method,path) + compiler union — **kode izin persis `{modul}.{fitur}.{handler}`** |
| Queue/worker | BullMQ + ioredis, worker in-process (`JobSiklusBullMQ`) | **asynq** + `go-redis/v9`, worker terpisah `cmd/worker` |
| Cron/loop job | repeatable scheduler BullMQ, interval CFG dibaca ulang per eksekusi | goroutine loop + `robfig/cron/v3`; interval CFG dibaca ULANG per siklus; 0 = mati (tick dorman 60 dtk); guard overlap wajib |
| Realtime | socket.io (gateway `rbac.gateway`, event `rbac.changed` saja) | `coder/websocket` hub path `/ws` — DIRATIFKASI pindah G0 |
| Rate limit | @nestjs/throttler opt-in per controller, in-memory | middleware rate-limit Redis |
| Log | pino | `slog` JSON |
| UoW transaksi | `uow.withTransaction` | `pgx.BeginTx` eksplisit + `defer rollback` di service; executor `DBTX` diteruskan ke repo/audit/outbox/numbering |
| Audit | core/audit in-transaction | `internal/core/audit` (tabel `core_audit_trail` sama) |
| Outbox | core/outbox in-transaction, konsumsi poll `FOR UPDATE SKIP LOCKED` | `internal/core/outbox` (tabel + topic + `_key` idempoten sama); konsumen = task asynq poll topik |
| Numbering | core/numbering `UPDATE…RETURNING` | `internal/core/numbering` via sqlc (tabel `core_sequences` sama) |
| Module config | ModuleConfigService CFG-xx | `internal/core/moduleconfig` (tabel sama) |
| Konteks sistem | aktor sistem `{id:0, username:"system"}` | `context.Context` + aktor sistem konstan (`ctxsistem.New`) |
| Storage file | aws-sdk v3 (MinIO/S3 presign) | `aws-sdk-go-v2` (presign sama) |
| Mail | nodemailer + `core_mail_log` | `wneessen/go-mail` + tabel sama |
| DI | Nest DI | **wiring manual eksplisit** — `module.go` per modul + `cmd/api/main.go` |
| Test | Jest + (Testcontainers) | `go test` + `testcontainers-go` |
| Monorepo | pnpm + Turborepo | satu `go.mod` (bukan multi-module) |

Dilarang menambah kebutuhan di luar tabel ini tanpa ratifikasi user.

## 6. Konvensi API — kontrak beku (FAKTA repo NestJS, bukan keputusan baru)

- **Prefix global** `/api` (`apps/api/src/main.ts:64`). Semua path kontrak
  ditulis tanpa prefix (path `@Controller`), gateway yang menyisipkan.
- **Envelope respons** (`packages/schemas/src/core/common.ts`):
  `{ success: boolean, data?, error? }`; error `{ code, message, details? }`
  (RFC 7807 filter NestJS dipetakan 1:1 ke helper `errkontrak` Go).
- **Pagination**: query `page`, `limit` (maks 200), `sort` (`-field`), filter;
  meta `pageMetaSchema`; bentuk `Page<T>` sama persis.
- **Optimistic locking**: header `If-Match` membawa nomor `version`; bentrok
  → 409 dengan pesan sama. Dipakai 12 modul (acc 16 file, hr 27, sls 15,
  core 11, pgw 8, ai 5, fnb 5, shipment 5, wf 6, inv 4, ecom 3, wa 1;
  pos & purchasing 0).
- **Idempotency-Key**: header maks 200 char pada POST create — hanya
  acc (9 file), hr (14), purchasing (3), sls (11).
- **RBAC route-centric deny-by-default** (`core/rbac/guards/permissions.guard.ts`):
  1. PUBLIC_ALLOWLIST: `/health`, `/auth/login`, `/auth/register`,
     `/auth/refresh` + pola ber-parameter publik (`/wa/webhook/:token`;
     webhook `pgw/webhook/:vendor`, `shipment/webhook/:vendor`, portal tamu
     `ecom/portal/*` = controller TANPA guard).
  2. Wajib `req.user` dari JWT (401 `AUTH-401`).
  3. Tanpa endpoint terdaftar di `core_routes` → 403 (nol rute yatim —
     registry digenerate `podman/scanroutes.sh` rev.6: kode
     `{modul}.{fitur}.{handler}`; SET izin = `{modul}.{fitur}` via
     `core_permissions_routes`).
  4. `PermissionCompilerService.has(user.id, kode)` — union multi-role +
     override per-user; data-scope dinamis 3 tabel `core_scope_*`
     (fail-open tanpa assignment, whitelist bila ada).
- **Auth**: access token TTL `JWT_ACCESS_TTL` default `15m`, klaim
  `{sub: number, username, sid}`; refresh secret terpisah + klaim `jti`,
  TTL = sisa umur sesi; validasi per request: baris `core_sessions`
  (`is_valid`, `revoked_at IS NULL`, `logout_at IS NULL`, `expires_at > now`,
  user aktif); cookie httpOnly dua ruang (pilih dari header `Origin` vs
  `PORTAL_ORIGINS`): backoffice `nexierp_at`/`nexierp_rt`, portal
  `ecom_at`/`ecom_rt`; `HttpOnly; SameSite=Lax; Path=/`, `Secure` bila
  `COOKIE_SECURE=true`, Max-Age access 900 / refresh 43200; argon2
  verifikasi + upgrade-on-login seed plaintext; lockout server-side
  (`failed_login_attempts` + `locked_until`, default 60 menit);
  `core_login_audit` append-only; login = SATU transaksi (token pair + sesi
  per `device_key` + audit). PIN kasir POS = argon2id `core_users.pin`.
- **Webhook vendor**: `rawBody` wajib (verifikasi signature Midtrans SHA512
  dual-key, DOKU HMAC-SHA256 stringToSign 5 baris; Biteship tanpa HMAC →
  anti-spoof RE-FETCH order; WA Evolution tanpa HMAC, token path). Pola
  status: WA selalu 200 anti retry-storm; pgw/shipment INVALID → 401
  (`PGW-005` / `SHP-013`).
- **Outbox**: publish `enqueue(tx, {topic, key?, payload})` DI DALAM
  transaksi; idempoten `(topic, payload._key)` unik parsial
  (`uq_outbox_topic_key_pending`); duplikat → skip insert, kembalikan id lama.
- **Catatan DDL**: `ddl/01-core.sql` memuat bentuk LAMA `core_sessions`
  (token hash varchar(300)); bentuk live = skema Drizzle. Migrations goose
  tetap porting berurutan `ddl/`; bentuk live `core_sessions` mengikuti
  Drizzle (sesi diratifikasi §0) — selisih lain ddl-vs-live dicatat di Log
  pelacak saat ditemukan, TIDAK diperbaiki lewat ddl Go.

## 7. Katalog pola bisnis NestJS → Go (satu pola satu bentuk)

| # | Pola di NestJS (bukti repo) | Pola Go baku |
|---|---|---|
| 1 | CRUD master + optimistic locking `If-Match` (12 modul) | handler parse → service cek version → repo sqlc; 409 + pesan sama |
| 2 | Dokumen transaksi (header+detail, posting, state machine: jurnal acc, pesanan sls/pos/ecom, mutasi inv) | transisi/validasi = fungsi pure `domain/`; service = satu `pgx.BeginTx` (repo+audit+outbox+numbering) |
| 3 | Approval ambang + SoD (keputusan/ajukan/keputusan di banyak modul; SoD warn-only core) | domain pure + ambang dari tabel config yang sama |
| 4 | Job siklus BullMQ `JobSiklusBullMQ` (10 job, interval CFG reread, 0 = mati, guard overlap) | goroutine loop + asynq; baca CFG per siklus + guard overlap; satu siklus = SATU delegasi service (`ctxsistem.New`); idempoten |
| 5 | Event lintas modul (outbox in-transaction; konsumen = poll `SKIP LOCKED`: ecom M52/M56/M24, sls M07) | publish via `core/outbox` DI DALAM transaksi; konsumen = task asynq poll topik, validasi payload JSON Schema zod, idempoten per `_key` |
| 6 | Adapter vendor tanpa state (Midtrans, DOKU, Biteship, Evolution, LLM-WA, Anthropic, OpenAI-compat) | struct tanpa state + registry modul; TANPA DB; timeout HTTP sama; fakta vendor di komentar header |
| 7 | Upload/media presign (core files + MinIO) | `core/storage` (aws-sdk-go-v2) |
| 8 | Ekspor laporan async (audit-trail CSV dsb.) | task asynq → core/storage → notif realtime |
| 9 | Idempotency-Key (acc/hr/purchasing/sls) | middleware `core/idempoten` + tabel idempoten sama |
| 10 | Scope data multi-outlet/tenant (3 tabel `core_scope_*`) | filter di repository via helper scope core — hasil query sama |
| 11 | Notifikasi realtime (`rbac.changed` saja) | `core/realtime` hub WS (ratifikasi §0) |
| 12 | Health/readiness (`/health`, system/health) | `internal/health` handler (pg + redis check) |
| 13 | Webhook vendor masuk (pgw/shipment/wa) | handler publik rawBody + verifikasi signature adapter + pola status per §6 |
| 14 | Registry route & permission (`scanroutes.sh` → `core_routes`) | `cmd/scanroute` Go = parity-scanner: bandingkan route Echo vs `core_routes` live (kanonik NestJS); kandidat merge-only hanya untuk route Go-only; tanpa delete/update baris NestJS sampai G7 |

## 8. Strategi Migrasi — tabel fase (sumber pelacak)

- **G0 Fondasi (SEKALI, eksekutor Mode F)** — scaffold §3, go.mod, Echo,
  pool pg, config, slog, goose atas `ddl/`, `internal/core/*` lengkap
  (auth/rbac/audit/outbox/numbering/moduleconfig/redis/queue/storage/mailer/
  realtime/idempoten/ctxsistem), health, cmd/api + cmd/worker, generator
  JSON Schema zod, scripts sqlc+goose+scanroute. Route auth
  (`/api/auth/*`) dicutover ke Go DI SINI (ratifikasi §0); gateway socket.io
  NestJS dimatikan, hub WS Go hidup, FE ganti client.
  **Bukti wajib**: (a) login via Go menghasilkan JWT yang sah di NestJS & FE;
  (b) 403 RBAC parity (rute tak terdaftar/izin kurang); (c) event outbox
  yang diterbitkan Go terbaca konsumen NestJS; (d) migrasi goose menghasilkan
  schema identik `ddl/`; (e) FE menerima `rbac.changed` dari hub WS Go.
- **G1–G6 per modul** (urutan = ratifikasi §0, hulu→hilir):
  - **G1 Audit modul NestJS (READ-ONLY)** — inventaris endpoint+izin+kontrak
    +error+tx+If-Match/Idempotency-Key+job/listener/adapter+domain per fitur.
  - **G2 Kontrak OpenAPI** — `api/openapi/<m>.yaml` lengkap semua endpoint.
  - **G3 Generate Go** — pohon §4 per fitur UTUH; `go build ./... && go test
    ./...` hijau per langkah; guard 0 MERAH.
  - **G4 Gerbang parity** — P1–P9 lolos (P9 smoke FE via regression-gate).
  - **G5 Cutover route** — gateway alihkan route modul ke Go; job BullMQ +
    konsumen outbox in-process NestJS modul itu dimatikan; route NestJS
    modul dimatikan (TIDAK dihapus).
  - **G6 Finalize** — hapus route NestJS modul; tracker diperbarui bukti.
- **G7 Dekomisioning (SEKALI, setelah SEMUA modul G6 ✅)** — NestJS API &
  worker Node dimatikan penuh, FE penuh lewat Go, tracker ditutup.

**Urutan modul (14, ratifikasi 2026-11-27 — "Peta + ai-naik")**:

| Peringkat | Modul | Endpoint | Catatan hulu→hilir |
|---|---|---|---|
| 1 | core (system) | 130 | kernel RBAC/iam/security/files/tenants — setelah G0 fondasi |
| 2 | inv (inventory) | 114 | hulu operasional (penerbit M02/M04/M16/M27) |
| 3 | sls (sales) | 83 | konsumen outbox sendiri (M07), pemicu faktur |
| 4 | purchasing | 90 | penerimaan → inv; faktur → acc |
| 5 | pos | 69 | kasir (tanpa If-Match/Idem); muara jurnal |
| 6 | fnb | 53 | konsumsi inv; produksi/KDS |
| 7 | ai | 30 | provider LLM — dinaikkan sebelum konsumennya (ecom, wa) |
| 8 | ecom | 95 | konsumen M52/M56/M24 (pgw/shp/sls); portal publik |
| 9 | acc | 98 | MUARA jurnal — setelah semua penerbit |
| 10 | hr | 150 | payroll → jurnal acc (sudah hidup) |
| 11 | pgw | 31 | adapter Midtrans/DOKU + webhook; konsumen ecom |
| 12 | shipment | 26 | adapter Biteship + webhook; konsumen ecom |
| 13 | wa | 55 | Evolution + LLM; webhook publik; konsumen ai |
| 14 | wf | 22 | workflow engine — terakhir (belum dikonsumsi modul lain) |

Pengecualian urutan hanya dengan keputusan user yang dicatat di Log pelacak.

## 9. Testing & DevOps

- `go test ./...` + `testcontainers-go` (Postgres + Redis nyata untuk test
  integrasi); `gofmt` bersih, `go vet ./...` tiap langkah.
- Guard lapisan `periksa-batas-lapisan-go.mjs --strict` wajib 0 MERAH
  sebelum commit (commit lokal, tanpa push, pesan Bahasa Indonesia).
- Gerbang parity P1–P9 per modul (P9 = smoke FE, `regression-gate`).
- Deploy berdampingan: binary Go jalan di port sendiri; gateway/proxy
  mengalihkan route per modul (`release-deploy`/`devops-runner`); rollback =
  kembalikan route gateway.

## 10. Yang TIDAK Dipakai (dilarang masuk repo)

- ORM apa pun (GORM/ent/sqlboiler) — hanya pgx + sqlc.
- Framework HTTP lain (chi/gin/fiber), magic DI (wire/fx/dig).
- Multi `go.mod` / go workspace.
- DB baru, migrasi data, atau mengubah `ddl/` di repo Go.
- socket.io / socket.io-client (diganti WS native sejak G0 — ratifikasi §0).
- Mengubah kontrak kawat (path/izin/kode error/bentuk JSON) — selisih =
  koreksi paritas Mode K, bukan perubahan kontrak.
- Mengubah repo NestJS `/Data/www/nexierp` dari repo ini (READ-ONLY).

## Lampiran A — Inventaris fakta NestJS (2026-11-27, 14 modul aktif)

| Modul | Prefix route | Ctrl | Endpoint | If-Match (file) | Idem-Key (file) | Job | Adapter |
|---|---|---|---|---|---|---|---|
| core (system) | `system.*` | 19 | 130 | 11 | — | auth.token-sweep | — |
| inv | `inventory.*` | 20 | 114 | 4 | — | — | — |
| sls | `sls.*` | 13 | 83 | 15 | 11 | sls.faktur-pemicu | — |
| purchasing | `purchasing.*` | 13 | 90 | — | 3 | — | — |
| pos | `pos.*` | 10 | 69 | — | — | — | — |
| fnb | `fnb.*` | 8 | 53 | 5 | — | fnb.buka-86 | — |
| ai | `ai.*` | 5 | 30 | 5 | — | — | anthropic, openai-compatible |
| ecom | `ecom.*` | 19 | 95 | 3 | — | ecom.pesanan-sweep, ecom.pengiriman-status | — (fasad SHP) |
| acc | `acc.*` | 21 | 98 | 16 | 9 | — | — |
| hr | `hr.*` | 23 | 150 | 27 | 14 | — | — |
| pgw | `pgw.*` | 7 | 31 | 8 | — | pgw.transaksi-sweep | midtrans, doku |
| shipment | `shipment.*` | 8 | 26 | 5 | — | shp.sweep | biteship |
| wa | `wa.*` | 13 | 55 | 1 | — | wa.pesan-kirim, wa.kampanye-sweep, wa.status-kirim | evolution, llm |
| wf | `wf.*` | 4 | 22 | 6 | — | — | — |
| **Total** | | **183 file / 189 kelas** | **1.046** | | | **10 job** | **7 adapter** |

Semua job = pola `JobSiklusBullMQ` (`core/redis/job-siklus.ts`); konstanta
infra: tick mati 60 dtk, interval minimal 1 dtk, kickoff 10 dtk, retry Redis
60 dtk, attempts 1. Konfigurasi interval per job (verbatim): auth
`AUTH_TOKEN_SWEEP_INTERVAL_MS` (6 jam); ecom `CFG-ECOM-17`, `CFG-ECOM-SWEEP`;
fnb `CFG-FNB-14` (+gerbang mode `CFG-FNB-03` = OTOMATIS); pgw
`CFG-PGW-SWEEP`; shp `CFG-SHP-05` (jam, pecahan 0.25 sah); sls `CFG-SLS-14`
(MODULE_KEY_SLS = `sales`); wa `CFG-WA-10.backoff_detik`, `CFG-WA-11`
(MODULE_KEY_WA = `whatsapp-crm`).

**Konsumen outbox in-repo**: ecom ← `pgw.transaksi.status`, `shipment.order.status`,
`sls.so.status` (idempoten per `_key` + status pesanan; validasi nominal M52
`uangSama`); sls ← `sls.faktur.pemicu` (key `m07:<entityId>:reg|dp`, batas
20/siklus); wa ← relay lokal antrian `wa_pesan` (bukan poll outbox; jejak
idempoten `uq_wa_pesan_event`). Topik lain BELUM punya konsumen in-repo
(relay `apps/worker` direncanakan, belum ada).

**Kosakata event outbox (penerbit → topic verbatim; 47 titik `.enqueue(`)**:

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

Topic TIDAK dienum di `packages/schemas` (`topic` = `z.string().min(1)`);
konstanta topic hidup di `types/` modul penerbit — port Go mengikuti sumber
yang sama (`types/` modul Go).

**Realtime**: satu gateway `core/realtime/gateways/rbac.gateway.ts`
(path `/socket.io`), auth handshake `JwtAuthGuard.authenticate` (cookie
ruang/Bearer + validasi `core_sessions`), room `user:<id>`, emit SATU event
`rbac.changed` `{reason:"rbac"}`, tanpa `@SubscribeMessage`; bridge dari
`PermissionCompilerService.onInvalidate`; CORS allowlist `WEB_ORIGIN`;
FE client 1 file `apps/web/src/lib/realtime.ts`.

**Schemas**: `packages/schemas` 150 file .ts, 14 folder modul; pola
`tipe.ts`/`schemas.ts`/`views.ts`/`index.ts`; penamaan `*BuatSchema` (76),
`*UbahSchema` (56), `*ViewSchema` (374), `*QuerySchema` (18); manifest
`satu-sumber.json` + guard `guard-satu-sumber.mjs`; moduleKey DB core =
`system` (nama folder = `core`). Belum ada generator JSON Schema — dibuat
baru di `tools/json-schema-gen` (ratifikasi §0).

**Kesalahan fakta yang DIKOREKSI dari draf awal**: (a) modul lama
(fnb/inv/sls/pur/shp/pos/acc/wa) TIDAK dihapus — 14 modul lengkap hidup di
`app.module.ts`; tarball di `/Data/www` hanya arsip parsial fitur;
(b) `@RequirePermission` = 0 pemakaian (model izin route-centric via
`core_routes`); (c) tidak ada folder `integration/listener` — konsumsi
outbox = polling eksplisit; (d) checkout publik `nexierp-github`/
`nexierp-porto*` adalah repo excerpt, bukan repo kerja.
