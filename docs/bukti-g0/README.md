# G0 Gate Evidence — Go Foundation (2026-11-27)

The five mandatory Mode F evidence items, all tested against the same live
dev DB (podman `nexierp-postgres` 127.0.0.1:15433) with the NestJS API alive
at 3001 and the Go API at 3101 (side by side):

| Evidence | File | Result |
|---|---|---|
| (a) login via Go = JWT valid in NestJS & FE | `a-login-lintas-runtime.txt` | ✅ both directions: the Go token validated by the NestJS `/auth/me` (`g0_bukti`), the NestJS token validated by the Go `/auth/me` — claims `{sub,username,sid}` + the same `core_sessions` row |
| (b) 403 RBAC parity | `b-rbac-403.txt` | ✅ NestJS: `FORB-403` "permission 'system.rbac.stats' diperlukan" (in Indonesian); the Go guard (registry + compiler against live `core_routes`): byte-for-byte identical problem+json |
| (c) Go outbox read by the NestJS side | `c-outbox.txt` | ✅ Go `enqueue` id=445; republishing the same key → same id (idempotent `uq_outbox_topic_key_pending`); the NestJS-side consumer (poll `SKIP LOCKED` + `tandaiDelivered`) pending→delivered |
| (d) goose schema ≡ live | `d-schema.txt` | ✅ all 47 live `core_*` tables present in `db/schema.sql` (91 ported by goose + 11 reconciliations to the live shape); `core_sessions`/`core_routes` columns = live shape |
| (e) FE receives `rbac.changed` from the Go WS | `e-ws.txt` + the `apps/web/src/lib/realtime.ts` change | ✅ the `{"event":"rbac.changed","data":{"reason":"rbac"}}` frame received through a real session-cookie handshake (room `user:<id>`, invalidation bridge); FE client swapped to native WS (1 file, identical public API) |

Evidence tools (each a small Go program, repeatable):
`scripts/bukti403`, `scripts/buktioutbox`, `scripts/buktiws`, `scripts/hashgen`.

## Honest notes

- The test login uses the dedicated evidence user `g0_bukti` (argon2id
  generated from Go code) — the dev `admin` password was already changed by
  its owner and was not touched.
- The production trigger of `InvalidateUser` is the core module's
  override/assignRoles endpoint (rank 1, G1–G6) — at G0 the bridge path was
  proven via a direct `compiler.InvalidateUser` call (the evidence program),
  identical wiring in `internal/app`.
- The PHYSICAL cutover of the `/api/auth/*` routes via gateway/proxy +
  decommissioning of the NestJS socket.io gateway = side-by-side deployment
  steps (`release-deploy`/`devops-runner`), not code changes: in dev both
  stay alive (3001/3101), with the FE pointing through `NEXT_PUBLIC_WS_URL`
  when using the Go hub.
- FE: the `apps/web/src/lib/realtime.ts` change has not yet been put through
  a full typecheck/smoke (it joins the core module's P9 smoke).
