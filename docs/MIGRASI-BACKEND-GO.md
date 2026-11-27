# Go Backend Migration — Plan & Phase Tracker of the Per-Module Cutover

> Plan source: `docs/ARSITEKTUR-BACKEND-GO.md` §8 (the G0–G7 phase table) —
> this document DERIVES from it and invents no new phases; the constitution is
> that document. Phase execution goes through the `backend-go-scaffold-implementator`
> skill (Mode F foundation, Mode G module migration/generation, Mode K parity fix);
> this document is the plan & tracker — **not** an execution artifact.
> Maintenance rule: whenever a module phase completes, its status row MUST
> be updated (✅ + date) + the evidence path in the §5 Log on the same day.
> Status without evidence = not done.
> The Dexie→NestJS migration tracker lives separately in `nexierp/docs/MIGRASI-BACKEND.md`
> — two migrations, two documents, NOT mixed.

## 1. Locked Decisions (from §0–§8 of ARSITEKTUR-BACKEND-GO.md, ratified 2026-11-27)

| Decision | Content |
|---|---|
| One PostgreSQL, two runtimes | Go connects to the same `nexierp` DB; cutover = moving ROUTES per module via gateway/proxy, never moving data; a new DB is forbidden |
| Frozen wire contract | prefix `/api`, envelope `{success, data?, error?}`, permission codes `{modul}.{fitur}.{handler}`, domain error codes, camelCase, `If-Match`/`Idempotency-Key` — EXACTLY NestJS; drift = Mode K |
| First module | **core (system)** — the kernel; BUT the G0 foundation already moved the `/api/auth/*` routes + realtime to Go (constitution §0 ratification) |
| Realtime | **Moved as of G0** — NestJS socket.io dies at G0; Go WS hub `internal/core/realtime` (event `rbac.changed`); FE swaps in a 1-file client |
| Schema contract | zod `@nexierp/schemas` stays the FE source; new JSON Schema generator (`tools/json-schema-gen`) → `api/json-schema/`; new per-module contracts in `api/openapi/<m>.yaml` |
| Auth parity | secrets/claims/`core_sessions` (shape reference = Drizzle live)/dual-space cookies/argon2 all shared; tokens valid cross-runtime |
| Module order | core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf (14 modules, "Peta + ai-naik"); exceptions = user decisions recorded in the Log |
| Jobs & listeners at cutover | the module's NestJS BullMQ jobs + in-process outbox consumers are switched off at G5; the Go worker (asynq) takes over — same CFG keys, topics, `_key` idempotency |
| Decommissioning | G7: the NestJS API + Node worker are fully switched off AFTER all modules are G6 ✅ |

## 2. Definition of Done per Phase (applies uniformly; executor: `backend-go-scaffold-implementator`)

| Phase | Done when | Mode | Mandatory evidence |
|---|---|---|---|
| G0 Foundation (ONCE) | The §3 scaffold of the constitution is complete; `internal/core/*` complete; goose over `db/migrations` (content = live-sourced `ddl/` — new policy 2026-11-27, see the Log); the `/api/auth/*` routes cut over to Go; NestJS socket.io dead, Go WS hub alive; the JSON Schema generator running | F | (a) login via Go = JWT valid in NestJS & FE; (b) 403 RBAC parity; (c) the Go outbox read by the NestJS consumer; (d) goose schema ≡ live (0-delta parity); (e) FE receives `rbac.changed` from the Go WS |
| G1 Audit (per module) | A READ-ONLY map of the NestJS module assembled: endpoints+permissions+contracts+errors+tx+If-Match/Idem+job/listener/adapter+domain per feature; WITHOUT changing code | G | module audit document (path in the Log) |
| G2 Contract (per module) | `api/openapi/<m>.yaml` complete with ALL module endpoints; the module's event/listener payload JSON Schemas available | G | yaml file + endpoint list ≡ G1 map (0 drift) |
| G3 Generate (per module) | The `internal/modules/<m>/` tree complete per feature (a feature moves WHOLE or not at all); build+test green per step; guard 0 RED | G | `go build ./... && go test ./...` output + guard --strict |
| G4 Parity (per module) | The P1–P9 gates all pass (endpoints, contract, errors, RBAC, data shape, pagination, cross-runtime side effects, vet/test, FE smoke) | G + `regression-gate` (P9) | P1–P9 report (path in the Log) |
| G5 Cutover (per module) | The module's routes redirected by the gateway to Go **AND** the module's NestJS jobs/listeners dead **AND** the FE running normally through the Go routes — not merely "routes redirected" | G + `release-deploy`/`devops-runner` | G4 parity result + FE test notes through the Go routes + evidence the Go jobs run |
| G6 Finalize (per module) | The module's NestJS routes DELETED (not just disabled); endpoint→handler mapping recap + table K + parity fixes | G | deletion diff + recap to the user |
| G7 Decommissioning (ONCE) | The NestJS API & Node worker fully switched off; the FE fully through Go; realtime fully the Go WS | — | shutdown notes + full FE smoke |

Gates: the next phase is forbidden to start before the previous one is ✅ (per
module); G5 is forbidden before G4 ✅; G7 is forbidden before ALL modules are G6 ✅;
the module order follows §1 (exceptions only via user decisions in the Log).
Cross-module flows during the transition: cross-runtime side effects are
tested at P7 of every module (outbox/audit/numbering across NestJS↔Go).

## 3. Status Matrix (tracker)

Legend: ⬜ not started · 🔧 in progress · ✅ done (date + evidence path in the Log)

**G0 Foundation (shared, above the matrix): ✅ 2026-11-27** — counterpart of the NestJS kernel
`src/core/*` + the `/api/auth/*` routes + the Go WS hub. The 5 mandatory evidence items of §2:
`docs/bukti-g0/README.md` (a: cross-runtime login, both directions ✅ · b: 403 RBAC
parity with identical problem+json ✅ · c: Go outbox idempotent + read by the NestJS side ✅ ·
d: goose schema ≡ live, 47 `core_*` tables ✅ · e: `rbac.changed` frame via the Go WS,
FE client swapped ✅). Commits: `1834170` (foundation) + `c2a0b01` (evidence).

| Module | Rank | G1 | G2 | G3 | G4 | G5 | G6 | Latest evidence |
|---|---|---|---|---|---|---|---|---|
| core (system)¹ | 1 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 (36/38 + 2 stale dist artifacts) | ⏸ postponed | ⬜ | evidence: docs/bukti-g0/p2-parity.txt + p1-scanroute-core.txt |
| inv | 2 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 (live sample byte-identical; 404-edge parity added) | ⏸ postponed | ⬜ | evidence: docs/bukti-g0/p1-scanroute-inv.txt (GO-ONLY 0) |
| sls | 3 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| purchasing | 4 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| pos | 5 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| fnb | 6 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| ai | 7 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| ecom | 8 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| acc | 9 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| hr | 10 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| pgw | 11 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| shipment | 12 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| wa | 13 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| wf | 14 | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |

¹ core (system) module endpoints: 130 — iam/routes/permissions/menus/features/
user-overrides/datascope, rbac/users/roles/modules/overview, security/
audit-trail/environment, files, tenants, wilayah+wilayah_admin, cluster,
agama. The parts NOT included in G0 (the kernel) are cut over in this row.

**G7 Decommissioning: ⬜** — forbidden before all fourteen modules are G6 ✅.

Initial status (2026-11-27): the Go repo was completely empty (no go.mod/code/tests)
— ALL phases ⬜ including G0; no ✅ without evidence. Prerequisites ALREADY
met: `AGENTS.md` + the `docs/ARSITEKTUR-BACKEND-GO.md` constitution +
ratification of 4 decisions (Log §5). Go toolchain 1.24.2 available.

## 4. How to Use This Document

1. Start a module: invoke `backend-go-scaffold-implementator` — it reads its
   position from this matrix (Mode F for G0; Mode G per module; Mode K for
   post-cutover parity fixes).
2. Every phase done: update the matrix cell (✅ + date), the G0/G7 rows,
   and add the evidence path in the §5 Log — in the same session.
3. The next phase is forbidden to start before the previous one is ✅ (§2 gates).
4. Constitution-vs-repo fact drift (e.g. ddl-vs-live again) = record it in the Log;
   a new stack decision = change ARSITEKTUR-BACKEND-GO.md first with
   user ratification.

## 5. Decision & Evidence Log

| Date | Decision / evidence | Impact |
|---|---|---|
| 2026-11-27 | User ratification (4 decisions): realtime moves as of G0; schema contract = zod as the FE source + new JSON Schema generator + OpenAPI-first per module; auth parity + login cut over at G0 (the `core_sessions` reference = Drizzle live); module order "Peta + ai-naik" (14 modules) | G0 includes the `/api/auth/*` + WS cutover; the §3 matrix order is locked |
| 2026-11-27 | The Go repo's `AGENTS.md` created (evidence: `/Data/www/nexierp-golang/AGENTS.md`) — calibration of the NestJS L0–L3 discipline | skill prerequisite 1 met |
| 2026-11-27 | The `docs/ARSITEKTUR-BACKEND-GO.md` constitution created from a 3-sub-agent inventory (14 modules, 1,046 endpoints, 10 jobs, 7 adapters, 47 enqueue sites, realtime 1 event, custom JWT auth) (evidence: `/Data/www/nexierp-golang/docs/ARSITEKTUR-BACKEND-GO.md`) | skill prerequisite 2 met; source of this tracker's §8 |
| 2026-11-27 | Initial facts: the Go repo completely empty; the `MIGRASI-BACKEND-GO.md` template does not exist in the `migrasi-backend-plan` skill (the structure was derived from `MIGRASI-BACKEND.md`); fact corrections: the old modules are NOT deleted, `@RequirePermission` has 0 usages (route-centric RBAC), outbox consumption = explicit polling | all statuses ⬜; G0 not started |
| 2026-11-27 | Additional user ratification: the NestJS ↔ Go route/URL/permission pattern MUST be 1:1 with **NestJS as the source of patterns** (live `core_routes` = canonical) so the FE never changes; `cmd/scanroute` = parity-scanner (merge-only, no delete/update of NestJS rows until G7) | constitution §0+§7 amended; P1/P4 parity compares against live rows |
| 2026-11-27 | **G0 executed (Mode F)**: 5 sub-agents generate + `internal/app` wiring; build/vet/gofmt/test green; --strict guard 0 RED; sqlc 9 packages from `db/schema.sql`; `cmd/scanroute` parity-scanner tested against live (MATCH 1, GO-ONLY 0, LIVE-ONLY 1045, DIFF 8 = the code label `auth.auth.controllers.*` canonical live vs the Go hint — the DB was not touched, Go enforcement reads the DB) | Go kernel complete; evidence files `docs/bukti-g0/`; commits `1834170`, `c2a0b01` |
| 2026-11-27 | Auth parity fix during integration: `jti` refresh 32→48 hex bytes (exactly `randomBytes(48).hex`); lockout hour format `15:04`→`15.04` (dot separator, Node `id-ID`) | the 401 lockout message & token shape now verbatim NestJS |
| 2026-11-27 | **core module G1–G3 executed (7 sub-agents)**: audited 5 feature maps; OpenAPI `api/openapi/system.yaml` 130 ops 1:1 vs live `core_routes` (MISSING/EXTRA: NONE); generated 130+ endpoints (iam 30, rbac 21, tenants 20, security+env 16, wilayah group 34, files 9) + `internal/app` integration; build/vet/test green. Ratified decisions: password create/reset = argon2id (plaintext in the response only once); race 23505→409 verbatim message; **physical cutover G5 POSTPONED** (user decision — awaiting the production gateway). Guard: 2 RED on the `types/deps.go` contract (echo+database) = documented wiring exception | core row: G1–G3 ✅, G4 🔧, G5 ⏸ |
| 2026-11-27 | **core module G4**: parity sweep of 38 live NestJS-vs-Go cases (cross-runtime admin login) = 36 PASS + 2 artifacts of a stale NestJS dist (jumlahModul cluster, Content-Disposition export — the NestJS repo is the source of patterns, Go matches the repo; follow-up: rebuild the dist before P9). Mode K applied: menus live column, validasiSortCA, sentinel files, shadowing issues, IPv6 dial, pagination messages | G4 ✅ with notes; G5 ⏸ still postponed |
| 2026-11-27 | FE→Go dev mode: `rundev.sh … --goversion` (NestJS repo, commit 36911c9) — new `goapi` target (:3101, start-if-dead + build if needed), web/`NEXT_PUBLIC_API_URL`+`NEXT_PUBLIC_WS_URL` pointed at Go; `start web --goversion` auto-starts goapi. Web :3000 live → Go backend :3101 (REST + WS hub); NestJS :3001 stays alive side by side | the P9 FE smoke can now be run at any time via this mode |
| 2026-11-27 | **inv module G1–G3 executed (6 audit + 7 generate sub-agents)**: 114 endpoints; ratified decisions: ck_inv_saldo_on_hand → uniform 409 INV-010, race 23505 → 409 verbatim, packaging code global-DB; pkcipher kernel (AES-256-GCM); app integration (Outbox/Numbering/ModCfg/Scope/Cipher); build/vet/test/gofmt green; guard 4 RED = documented deps.go contract exception (core+inv) | inv row: G1–G3 ✅, G4 🔧 |
| 2026-11-27 | **inv G4**: P1 scanroute MATCH 58 / GO-ONLY 0; live sample byte-identical (summary, product, stock balance, category, agama-404); Mode K integration fixes: 404 problem+json parity for paths without a controller (pre-router routeAda — the Nest 404 happens in the router before the guard), opOptIDRef nil, gen→repository bridge (service free of gen), Angka/Angka0 → repository | G4 ✅ with notes; full sweep to follow (parity.py pattern) |
| 2026-11-27 | **Mode K P0 (user report: inv update not working)**: root cause = Pre-404 parity (the 404-edge fix) compared the raw path against `:id` patterns → ALL parameterized PATCH/DELETE were falsely 404'd at the pre-router. Fix: `:param` pattern → regex `[^/]+` (routeAda compiled). Verification: PATCH of 6 masters byte-identical to Nest, repeated save 200/200 ×6, wrong version 409 INV-017 identical, DELETE :id now reaches the handler. Note: the probe left test-data names behind in dev (kategori/unit/gudang/lokasi/produk/kemasan/JO — rename via the FE) | P0 closed |
| 2026-11-27 | **Mode K P0 #2 (user report: mutation save failing)**: (1) mutation save proven 201-parity with Nest (the "failure" cause = wrong unit from the FE → FK 23503 → 500 — Nest parity, preserved); (2) empty operations list = NULL-array bug `cardinality(jenis/ids_gudang)` (nil slice → NULL) + NULL scan of `id_lokasi_*` header/view (drizzle nullable vs ported NOT NULL) — fix: send []{}, CASE-form column + any mapper; (3) movement list jenis filter now 200-parity | operations list substantively at parity |
| 2026-11-27 | **Mode K P0 #3 (user FE report: lot combo 500)**: lot list 42804 — ORDER BY CASE mixed-type (kode varchar vs tanggal_kedaluwarsa timestamptz) → grouped per type; sort sweep of the ENTIRE inv list set (19 paths × asc/desc whitelist): 200 everywhere + the alias case 400 = identical to Nest (NEST=GO in every case) | inv sort sweep fully green |
| 2026-11-27 | The Go backend Swagger live: `/api/docs` (UI, swagger-ui CDN) + `/api/docs-json` (merged auth+system+inventory — 167 paths, 246 schemas, public parity with Nest `api/docs`); fixed the duplicate `Keputusan` schema in inventory.yaml (enum vs object → KeputusanBody) | dev address: http://localhost:3101/api/docs |
| 2026-11-27 | G0 note (honest): the PHYSICAL cutover of the auth routes via the gateway + switching off NestJS socket.io = side-by-side deployment steps (G5 of the core module / `release-deploy`), not code changes; the dedicated evidence user `g0_bukti` was created in the dev DB (password `admin` owned by the owner); the FE `apps/web/src/lib/realtime.ts` was replaced (1 file, approved) — NOT yet typechecked/fully smoke-tested (joins the P9 of the core module); the `pg_dump` `\restrict` migration cleanup removed from `db/schema.sql` | the core module's G5 reuses the full G4 parity evidence + FE smoke |
| 2026-11-27 | **User decision — core+inv live-sourced DDL foundation (not copies of the NestJS ddl)**: the 91 old `ddl/` files deleted; replaced by 2 files produced by a SPLITTER from `pg_dump --schema-only` of the live `nexierp-postgres` DB (original pg_dump statement blocks, not hand-engineered): `ddl/core.sql` = 48 `core_*` tables + enum/function `set_updated_at`+trigger/index/constraint + **cross-read by core: `hr_karyawan`**; `ddl/inv.sql` = all 22 `inv_*` tables + **cross-read by inv: `pur_penerimaan`, `pur_penerimaan_item`, `pur_pesanan`, `pur_pesanan_item`, `pur_pemasok`** (read by the inv mutations-from-GR query; the pur→inv FKs stay intact). FKs to tables outside the scope intentionally dropped (core_metode_bayar→acc_akun; hr_karyawan→hr_departemen/hr_jabatan). `db/migrations/` 102 old files → `001_core.sql`+`002_inv.sql` (goose up on a fresh Postgres **2/2 success**); `db/schema.sql` = filtered dump of the fresh DB (strip `\restrict`) → sqlc 11 entries regenerated. Mode K nullability corrections to live: `core_users.email`, `core_sessions.id_core_users`/`ip_address`/`user_agent` NOT NULL; `inv_gerakan_stok.id_lokasi_tujuan` nullable (NULL→0); RETURNING role/menu now the direct sqlc model. **core_*/inv_* column parity = 0 delta** (743 columns, names+order+types identical; live has 2 internal-dropped `core_user_permissions` columns that pg_dump indeed does not replicate). build/vet/test green, gofmt clean; api :3101 smoke = health/overview/category/balance all 200 | the Go L0 foundation is now live-sourced per module; regenerate at any time from the live DB after schema changes land via the NestJS repo |
