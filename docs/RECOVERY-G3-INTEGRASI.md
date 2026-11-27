# RECOVERY — Integrasi G3 modul core (status 2026-11-27, sesi berjalan)

## Kondisi
- `types/deps.go` = VERSI BAIK terakhir (typed contract, komentar guard
  pengecualian sudah tertanam). JANGAN diubah lagi.
- `internal/modules/core/handler/{files,iam,rbac,security,tenants,wilayah}.go`
  RUSAK secara lokal oleh patch otomatis ganda (sisipan `db := ...` mendarat
  di posisi salah + rename `d.DB`→`db` yang menimpa teks di dalam signature).
  Galaxy error: `expected '(', found DaftarkanX` + cascade.
- File LAIN sehat: `go build ./...` lulus untuk service/repository/domain/
  types/gen (terbukti saat error hanya di handler). 8 paket test ok.
- `internal/app/app.go` SUDAH di-wiring ke `coremod.Register` (kompile ok
  sebelum kerusakan handler? — verifikasi ulang setelah handler beres).
- `internal/core/errkontrak/pagination.go` = sudah verbatim (Harus bilangan
  bulat >= 1 (diterima: %q).) — biarkan.
- `shared/views.go` = sudah refactor ke *http.Request (+ auth.FromReq baru di
  guard.go). Panggilan handler yang benar: `shared.ActorOf(c.Request())`,
  `shared.IfMatchVersion(c.Request())` — sed `ActorOf(c)`→`ActorOf(c.Request())`
  SUDAH dijalankan dan berhasil (tidak tersisa bentuk lama).
- `repository/iam_datascope_views.go` = helper datascope (isoPg/DefinitionToView/
  BuildInsertDefinitionParams/BuildInsertAssignmentParams) — sehat.
- `service/iam_datascope.go` = call site sudah diarahkan ke repository helper —
  sehat.

## Langkah pemulihan handler (urut)
1. Untuk tiap 6 file, buka area error pertama (mis. files.go:40-50,
   iam.go:25-35, rbac.go:44-52, security.go:48-55, tenants.go:28-36,
   wilayah.go:32-38). Cari baris rusak: biasanya `func` hilang / sisipan
   teks `db := d.DB...authGuard...rbacGuard...` nyasar sebelum `func`.
2. Perbaiki: pastikan bentuk `func DaftarkanX(api *echo.Group, d types.Deps) {`
   utuh; hapus sisa sisipan nyasar; kembalikan rename `db.` → `d.DB.`,
   `authGuard.` → `d.AuthGuard.`, `rbacGuard.` → `d.RbacGuard.` HANYA bila
   asalnya memang itu (cek konteks; variabel lokal sah JANGAN diubah).
3. `gofmt -w internal/modules/core/handler/` → `go build ./...` hijau.
4. `go vet ./...` (harus 0; sebelumnya bersih kecuali IPv6 yang sudah
   diperbaiki via net.JoinHostPort).
5. `go test ./...` (8+ paket ok), guard --strict = 2 MERAH kontrak
   `types/deps.go` (echo+database) — PENGGECUALIAN TERDOKUMENTASI (lihat
   komentar file + Log pelacak), bukan pelanggaran lapisan.
6. Wiring `internal/app/app.go`: pastikan blok `coremod.Register(api,
   coretypes.Deps{...})` ada (dibuat sebelum kerusakan; cek grep coremod).
7. Commit: "modul core G3 integrasi: wiring app + perbaikan guard + pesan
   pagination verbatim" — lalu update `docs/MIGRASI-BACKEND-GO.md`
   (baris modul core: G1 ✅ G2 ✅ G3 ✅ + Log keputusan ratifikasi:
   argon2id-create, 23505→409, cutover fisik DITUNDA, pengecualian guard
   deps.go, OpenAPI system.yaml 130 op 1:1) → G4 parity P1–P9 (NestJS 3001
   hidup; Go 3101; user bukti g0_bukti/G0Bukti2026!; admin dev password
   diganti pemilik; P2 cek envelope tenants sub-resource via curl live).

## Fakta kanonik yang sudah terverifikasi agen (jangan ditafsir ulang)
- Route kanonik: `/tmp/g1/system-routes.txt` (130; cluster 8, tenants 20,
  wilayah grup 34, rbac 21, iam 30, security 10+3+3, files 9).
- Scanroute live test G0: MATCH 1 / GO-ONLY 0 / LIVE-ONLY 1045 / DIFF 8
  (label `auth.auth.controllers.*` kanonik).
- Keputusan ratifikasi: argon2id saat create/reset (plaintext hanya di
  respons sekali), 23505→409 pesan verbatim, cutover fisik DITUNDA.
