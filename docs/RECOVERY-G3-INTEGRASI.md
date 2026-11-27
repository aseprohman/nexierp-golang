STATUS: COMPLETED — historical record, kept for reference.

# RECOVERY — core module G3 integration (status 2026-11-27, session in progress)

## Condition
- `types/deps.go` = the last known-good VERSION (typed contract, guard-exception
  comments already embedded). DO NOT change it again.
- `internal/modules/core/handler/{files,iam,rbac,security,tenants,wilayah}.go`
  BROKEN locally by a double automatic patch (an inserted `db := ...` landed
  in the wrong position + a rename `d.DB`→`db` that overwrote text inside
  signatures).
  Error message: `expected '(', found DaftarkanX` + cascade.
- OTHER files healthy: `go build ./...` passes for service/repository/domain/
  types/gen (proven while the errors were only in the handlers). 8 test packages ok.
- `internal/app/app.go` IS wired to `coremod.Register` (it compiled ok before
  the handler breakage? — re-verify once the handlers are fixed).
- `internal/core/errkontrak/pagination.go` = already verbatim (Harus bilangan
  bulat >= 1 (diterima: %q). — in Indonesian) — leave it alone.
- `shared/views.go` = already refactored to *http.Request (+ new auth.FromReq
  in guard.go). Correct handler calls: `shared.ActorOf(c.Request())`,
  `shared.IfMatchVersion(c.Request())` — the sed `ActorOf(c)`→`ActorOf(c.Request())`
  WAS run and succeeded (no old form remains).
- `repository/iam_datascope_views.go` = datascope helpers (isoPg/DefinitionToView/
  BuildInsertDefinitionParams/BuildInsertAssignmentParams) — healthy.
- `service/iam_datascope.go` = call sites already redirected to the repository
  helper — healthy.

## Handler recovery steps (in order)
1. For each of the 6 files, open the area of the first error (e.g. files.go:40-50,
   iam.go:25-35, rbac.go:44-52, security.go:48-55, tenants.go:28-36,
   wilayah.go:32-38). Look for the broken line: usually a missing `func` / a
   stray `db := d.DB...authGuard...rbacGuard...` text insert before `func`.
2. Fix: make sure the `func DaftarkanX(api *echo.Group, d types.Deps) {` form
   is intact; remove leftover stray inserts; restore the renames `db.` → `d.DB.`,
   `authGuard.` → `d.AuthGuard.`, `rbacGuard.` → `d.RbacGuard.` ONLY where that
   was the original (check the context; legitimate local variables must NOT
   be changed).
3. `gofmt -w internal/modules/core/handler/` → `go build ./...` green.
4. `go vet ./...` (must be 0; previously clean except IPv6, already fixed
   via net.JoinHostPort).
5. `go test ./...` (8+ packages ok), guard --strict = 2 RED on the
   `types/deps.go` contract (echo+database) — DOCUMENTED EXCEPTION (see the
   file comments + the tracker Log), not a layer violation.
6. Wiring `internal/app/app.go`: make sure the `coremod.Register(api,
   coretypes.Deps{...})` block exists (created before the breakage; check
   with grep coremod).
7. Commit: "modul core G3 integrasi: wiring app + perbaikan guard + pesan
   pagination verbatim" (in Indonesian) — then update `docs/MIGRASI-BACKEND-GO.md`
   (core module row: G1 ✅ G2 ✅ G3 ✅ + ratified-decision Log:
   argon2id-create, 23505→409, physical cutover POSTPONED, deps.go guard
   exception, OpenAPI system.yaml 130 ops 1:1) → G4 parity P1–P9 (NestJS 3001
   alive; Go 3101; evidence user g0_bukti/G0Bukti2026!; the dev admin password
   was changed by its owner; P2 checks the tenants sub-resource envelope via
   live curl).

## Canon facts already verified by the agent (do not re-interpret)
- Canonical routes: `/tmp/g1/system-routes.txt` (130; cluster 8, tenants 20,
  wilayah group 34, rbac 21, iam 30, security 10+3+3, files 9).
- G0 live scanroute test: MATCH 1 / GO-ONLY 0 / LIVE-ONLY 1045 / DIFF 8
  (label `auth.auth.controllers.*` canonical).
- Ratified decisions: argon2id on create/reset (plaintext in the response
  only once), 23505→409 verbatim message, physical cutover POSTPONED.
