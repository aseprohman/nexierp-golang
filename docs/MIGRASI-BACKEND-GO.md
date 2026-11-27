# Migrasi Backend Go — Rencana & Pelacak Fase Cutover per Modul

> Sumber rencana: `docs/ARSITEKTUR-BACKEND-GO.md` §8 (tabel fase G0–G7) —
> dokumen ini MENURUNKANNYA, tidak mengarang fase baru; konstitusi = dokumen
> itu. Eksekusi per fase lewat skill `backend-go-scaffold-implementator`
> (Mode F fondasi, Mode G migrasi/generate modul, Mode K koreksi paritas);
> dokumen ini rencana & pelacak — **bukan** artefak eksekusi.
> Aturan pemeliharaan: setiap fase modul selesai, baris statusnya WAJIB
> diperbarui (✅ + tanggal) + path bukti di §5 Log pada hari yang sama.
> Status tanpa bukti = belum selesai.
> Pelacak migrasi Dexie→NestJS ada terpisah di `nexierp/docs/MIGRASI-BACKEND.md`
> — dua migrasi, dua dokumen, TIDAK dicampur.

## 1. Keputusan Terkunci (dari §0–§8 ARSITEKTUR-BACKEND-GO.md, diratifikasi 2026-11-27)

| Keputusan | Isi |
|---|---|
| Satu PostgreSQL dua runtime | Go konek DB `nexierp` yang sama; cutover = pindah ROUTE per modul via gateway/proxy, bukan pindah data; dilarang DB baru |
| Kontrak kawat beku | prefix `/api`, envelope `{success, data?, error?}`, kode izin `{modul}.{fitur}.{handler}`, kode error domain, camelCase, `If-Match`/`Idempotency-Key` — PERSIS NestJS; selisih = Mode K |
| Modul pertama | **core (system)** — kernel; TAPI fondasi G0 sudah memindahkan route `/api/auth/*` + realtime ke Go (ratifikasi §0 konstitusi) |
| Realtime | **Pindah sejak G0** — socket.io NestJS mati di G0; hub WS Go `internal/core/realtime` (event `rbac.changed`); FE ganti client 1 file |
| Kontrak skema | zod `@nexierp/schemas` tetap sumber FE; generator JSON Schema baru (`tools/json-schema-gen`) → `api/json-schema/`; kontrak baru per modul `api/openapi/<m>.yaml` |
| Auth parity | secret/klaim/`core_sessions` (acuan bentuk = Drizzle live)/cookie dua ruang/argon2 dipakai bersama; token lintas-runtime sah |
| Urutan modul | core → inv → sls → purchasing → pos → fnb → ai → ecom → acc → hr → pgw → shipment → wa → wf (14 modul, "Peta + ai-naik"); pengecualian = keputusan user dicatat di Log |
| Job & listener saat cutover | job BullMQ NestJS + konsumen outbox in-process modul tsb dimatikan di G5; Go worker (asynq) ambil alih — CFG key, topik, `_key` idempoten sama |
| Dekomisioning | G7: NestJS API + worker Node dimatikan penuh SETELAH semua modul G6 ✅ |

## 2. Definisi Selesai per Fase (berlaku seragam; eksekutor: `backend-go-scaffold-implementator`)

| Fase | Selesai bila | Mode | Bukti wajib |
|---|---|---|---|
| G0 Fondasi (SEKALI) | Scaffold §3 konstitusi utuh; `internal/core/*` lengkap; goose atas `ddl/` identik; route `/api/auth/*` dicutover ke Go; socket.io NestJS mati, hub WS Go hidup; generator JSON Schema jalan | F | (a) login via Go = JWT sah di NestJS & FE; (b) 403 RBAC parity; (c) outbox Go terbaca konsumen NestJS; (d) schema goose ≡ `ddl/`; (e) FE terima `rbac.changed` dari WS Go |
| G1 Audit (per modul) | Peta READ-ONLY modul NestJS tersusun: endpoint+izin+kontrak+error+tx+If-Match/Idem+job/listener/adapter+domain per fitur; TANPA mengubah kode | G | dokumen audit modul (path di Log) |
| G2 Kontrak (per modul) | `api/openapi/<m>.yaml` lengkap SEMUA endpoint modul; JSON Schema payload event/listener modul tersedia | G | file yaml + daftar endpoint ≡ peta G1 (0 selisih) |
| G3 Generate (per modul) | Pohon `internal/modules/<m>/` utuh per fitur (fitur pindah UTUH atau belum); build+test hijau per langkah; guard 0 MERAH | G | output `go build ./... && go test ./...` + guard --strict |
| G4 Parity (per modul) | Gerbang P1–P9 lolos semua (endpoint, kontrak, error, RBAC, bentuk data, pagination, efek samping lintas-runtime, vet/test, smoke FE) | G + `regression-gate` (P9) | laporan P1–P9 (path di Log) |
| G5 Cutover (per modul) | Route modul dialihkan gateway ke Go **DAN** job/listener NestJS modul mati **DAN** FE jalan normal lewat route Go — bukan sekadar "route sudah dialihkan" | G + `release-deploy`/`devops-runner` | hasil parity G4 + catatan uji FE lewat route Go + bukti job Go jalan |
| G6 Finalize (per modul) | Route NestJS modul DIHAPUS (bukan hanya dimatikan); rekap pemetaan endpoint→handler + tabel K + koreksi paritas | G | diff penghapusan + rekap ke user |
| G7 Dekomisioning (SEKALI) | NestJS API & worker Node dimatikan penuh; FE penuh lewat Go; realtime penuh WS Go | — | catatan shutdown + smoke FE penuh |

Gerbang: fase berikutnya dilarang mulai sebelum fase sebelumnya ✅ (per
modul); G5 dilarang sebelum G4 ✅; G7 dilarang sebelum SEMUA modul G6 ✅;
urutan modul mengikuti §1 (pengecualian hanya keputusan user di Log).
Alur lintas-modul selama transisi: efek samping lintas-runtime diuji di P7
tiap modul (outbox/audit/numbering lintas NestJS↔Go).

## 3. Matriks Status (pelacak)

Legenda: ⬜ belum mulai · 🔧 berjalan · ✅ selesai (tanggal + path bukti di Log)

**G0 Fondasi (bersama, di atas matriks): ✅ 2026-11-27** — padanan kernel NestJS
`src/core/*` + route `/api/auth/*` + hub WS Go. Bukti wajib 5 butir §2:
`docs/bukti-g0/README.md` (a: login lintas-runtime 2 arah ✅ · b: 403 RBAC
parity problem+json identik ✅ · c: outbox Go idempoten + terbaca sisi NestJS ✅ ·
d: schema goose ≡ live, 47 tabel core_* ✅ · e: frame `rbac.changed` via WS Go,
FE client diganti ✅). Commit: `1834170` (fondasi) + `c2a0b01` (bukti).

| Modul | Peringkat | G1 | G2 | G3 | G4 | G5 | G6 | Bukti terakhir |
|---|---|---|---|---|---|---|---|---|
| core (system)¹ | 1 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 (36/38+2 artefak dist basi) | ⏸ ditunda | ⬜ | bukti: docs/bukti-g0/p2-parity.txt + p1-scanroute-core.txt |
| inv | 2 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 | ✅ 27-11 (sampel live byte-identical; 404-edge parity ditambah) | ⏸ ditunda | ⬜ | bukti: docs/bukti-g0/p1-scanroute-inv.txt (GO-ONLY 0) |
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

¹ Endpoint modul core (system): 130 — iam/routes/permissions/menus/features/
user-overrides/datascope, rbac/users/roles/modules/overview, security/
audit-trail/environment, files, tenants, wilayah+wilayah_admin, cluster,
agama. Bagian yang TIDAK termasuk G0 (kernel) dicutover di baris ini.

**G7 Dekomisioning: ⬜** — dilarang sebelum keempat belas modul G6 ✅.

Status awal (2026-11-27): repo Go kosong total (tidak ada go.mod/kode/test)
— SEMUA fase ⬜ termasuk G0; tidak ada ✅ tanpa bukti. Prasyarat yang SUDAH
terjadi: `AGENTS.md` + konstitusi `docs/ARSITEKTUR-BACKEND-GO.md` +
ratifikasi 4 keputusan (Log §5). Toolchain Go 1.24.2 tersedia.

## 4. Cara Memakai Dokumen Ini

1. Mulai modul: sebut `backend-go-scaffold-implementator` — ia membaca
   posisi dari matriks ini (Mode F untuk G0; Mode G per modul; Mode K untuk
   koreksi paritas pasca-cutover).
2. Setiap fase selesai: perbarui sel matriks (✅ + tanggal), baris G0/G7,
   dan tambahkan path bukti di §5 Log — di sesi yang sama.
3. Fase berikutnya dilarang mulai sebelum fase sebelumnya ✅ (gerbang §2).
4. Selisih fakta konstitusi vs repo (mis. ddl-vs-live lagi) = catat di Log,
   keputusan stack baru = ubah ARSITEKTUR-BACKEND-GO.md dulu dengan
   ratifikasi user.

## 5. Log Keputusan & Bukti

| Tanggal | Keputusan / bukti | Dampak |
|---|---|---|
| 2026-11-27 | Ratifikasi user (4 keputusan): realtime pindah sejak G0; kontrak skema = zod sumber FE + JSON Schema generator baru + OpenAPI-first per modul; auth parity + login dicutover G0 (acuan `core_sessions` = Drizzle live); urutan modul "Peta + ai-naik" (14 modul) | G0 memuat cutover `/api/auth/*` + WS; urutan matriks §3 terkunci |
| 2026-11-27 | `AGENTS.md` repo Go dibuat (bukti: `/Data/www/nexierp-golang/AGENTS.md`) — kalibrasi disiplin NestJS L0–L3 | prasyarat 1 skill terpenuhi |
| 2026-11-27 | Konstitusi `docs/ARSITEKTUR-BACKEND-GO.md` dibuat dari inventaris 3 sub-agent (14 modul, 1.046 endpoint, 10 job, 7 adapter, 47 titik enqueue, realtime 1 event, auth custom JWT) (bukti: `/Data/www/nexierp-golang/docs/ARSITEKTUR-BACKEND-GO.md`) | prasyarat 2 skill terpenuhi; sumber §8 pelacak ini |
| 2026-11-27 | Fakta awal: repo Go kosong total; template `MIGRASI-BACKEND-GO.md` tidak ada di skill `migrasi-backend-plan` (struktur diturunkan dari `MIGRASI-BACKEND.md`); koreksi fakta: modul lama TIDAK dihapus, `@RequirePermission` 0 pemakai (RBAC route-centric), konsumsi outbox = polling eksplisit | semua status ⬜; G0 belum mulai |
| 2026-11-27 | Ratifikasi tambahan dari user: pola route/URL/permission NestJS ↔ Go WAJIB 1:1 dengan **NestJS sebagai sumber pola** (`core_routes` live = kanonik) agar FE tidak berubah; `cmd/scanroute` = parity-scanner (merge-only, tanpa delete/update baris NestJS sampai G7) | konstitusi §0+§7 diamandemen; P1/P4 parity membandingkan ke baris live |
| 2026-11-27 | **G0 dieksekusi (Mode F)**: 5 sub-agent generate + wiring `internal/app`; build/vet/gofmt/test hijau; guard `--strict` 0 MERAH; sqlc 9 package dari `db/schema.sql`; `cmd/scanroute` parity-scanner diuji ke live (MATCH 1, GO-ONLY 0, LIVE-ONLY 1045, DIFF 8 = label kode `auth.auth.controllers.*` kanonik live vs hint Go — DB tidak disentuh, enforcement Go baca DB) | kernel Go lengkap; berkas bukti `docs/bukti-g0/`; commit `1834170`, `c2a0b01` |
| 2026-11-27 | Koreksi parity auth saat integrasi: `jti` refresh 32→48 byte hex (persis `randomBytes(48).hex`); format jam lockout `15:04`→`15.04` (pemisah titik `id-ID` Node) | pesan 401 lockout & bentuk token kini verbatim NestJS |
| 2026-11-27 | **Modul core G1–G3 dieksekusi (7 sub-agent)**: audit 5 peta fitur; OpenAPI `api/openapi/system.yaml` 130 op 1:1 `core_routes` live (MISSING/EXTRA: NONE); generate 130+ endpoint (iam 30, rbac 21, tenants 20, security+env 16, wilayah-grup 34, files 9) + integrasi `internal/app`; build/vet/test hijau. Keputusan ratifikasi: password create/reset = argon2id (plaintext hanya di respons sekali); race 23505→409 pesan verbatim; **cutover fisik G5 DITUNDA** (keputusan user — menunggu gateway produksi). Guard: 2 MERAH kontrak `types/deps.go` (echo+database) = pengecualian wiring terdokumentasi | baris core: G1–G3 ✅, G4 🔧, G5 ⏸ |
| 2026-11-27 | **G4 modul core**: sweep parity 38 kasus NestJS-vs-Go live (admin login lintas-runtime) = 36 PASS + 2 artefak dist NestJS basi (jumlahModul cluster, Content-Disposition export — repo NestJS = sumber pola, Go sesuai repo; tindak lanjut: rebuild dist sebelum P9). Mode K diterapkan: menus kolom live, validasiSortCA, sentinel files, shadowing issues, dial IPv6, pesan pagination | G4 ✅ dengan catatan; G5 ⏸ tetap ditunda |
| 2026-11-27 | Dev mode FE→Go: `rundev.sh … --goversion` (repo NestJS, commit 36911c9) — target baru `goapi` (:3101, start-bila-mati + build bila perlu), web/`NEXT_PUBLIC_API_URL`+`NEXT_PUBLIC_WS_URL` mengarah ke Go; `start web --goversion` otomatis nyalakan goapi. Web :3000 live → backend Go :3101 (REST + WS hub); NestJS :3001 tetap hidup berdampingan | P9 smoke FE kini bisa dijalankan kapan pun lewat mode ini |
| 2026-11-27 | **Modul inv G1–G3 dieksekusi (6 audit + 7 generate sub-agent)**: 114 endpoint; keputusan ratifikasi: ck_inv_saldo_on_hand → 409 INV-010 seragam, race 23505 → 409 verbatim, kode kemasan global-DB; kernel pkcipher (AES-256-GCM); integrasi app (Outbox/Numbering/ModCfg/Scope/Cipher); build/vet/test/gofmt hijau; guard 4 MERAH = pengecualian kontrak deps.go (core+inv) terdokumentasi | baris inv: G1–G3 ✅, G4 🔧 |
| 2026-11-27 | **Inv G4**: P1 scanroute MATCH 58 / GO-ONLY 0; sampel live byte-identical (ringkasan, produk, stok saldo, kategori, agama-404); perbaikan Mode K integrasi: 404 problem+json parity untuk path tanpa controller (pre-router routeAda — Nest 404 di router sebelum guard), opOptIDRef nil, bridge gen→repository (service bebas gen), Angka/Angka0 → repository | G4 ✅ dengan catatan; sweep penuh menyusul (pola parity.py) |
| 2026-11-27 | **Mode K P0 (laporan user: update inv tidak berfungsi)**: akar = Pre-404 parity (404-edge fix) membandingkan path mentah vs pola `:id` → SEMUA PATCH/DELETE ber-parameter ter-404 palsu di pre-router. Fix: pola `:param` → regex `[^/]+` (routeAda compiled). Verifikasi: PATCH 6 master byte-identical Nest, simpan-berulang 200/200 ×6, versi salah 409 INV-017 identik, DELETE :id kini mencapai handler. Catatan: probe menyisakan nama data uji di dev (kategori/unit/gudang/lokasi/produk/kemasan/JO — rename via FE) | P0 ditutup |
| 2026-11-27 | **Mode K P0 #2 (laporan user: simpan mutasi gagal)**: (1) simpan mutasi terbukti 201 parity Nest (penyebab "gagal" = unit salah dari FE → FK 23503 → 500 — parity Nest, dijaga); (2) list operasi kosong = bug NULL-array `cardinality(jenis/ids_gudang)` (nil slice → NULL) + scan NULL `id_lokasi_*` header/view (drizzle nullable vs porting NOT NULL) — fix: kirim []{}, CASE-form kolom + mapper any; (3) gerakan list jenis filter kini 200 parity | list operasi parity substantif |
| 2026-11-27 | **Mode K P0 #3 (laporan user FE: combo lot 500)**: list lot 42804 — ORDER BY CASE mixed-type (kode varchar vs tanggal_kedaluwarsa timestamptz) → dikelompokkan per tipe; sweep sort SELURUH list inv (19 path × whitelist asc/desc): 200 semua + kasus alias 400 = identik Nest (NEST=GO tiap kasus) | sweep sort inv hijau penuh |
| 2026-11-27 | Swagger backend Go hidup: `/api/docs` (UI, CDN swagger-ui) + `/api/docs-json` (gabungan auth+system+inventory — 167 path, 246 schema, publik parity Nest `api/docs`); fix duplikat schema `Keputusan` di inventory.yaml (enum vs object → KeputusanBody) | alamat dev: http://localhost:3101/api/docs |
| 2026-11-27 | Catatan G0 (jujur): cutover FISIK route auth via gateway + mati-kan socket.io NestJS = langkah deploy berdampingan (G5 modul core / `release-deploy`), bukan perubahan kode; user bukti khusus `g0_bukti` dibuat di DB dev (password `admin` milik pemilik); FE `apps/web/src/lib/realtime.ts` diganti (1 file, disetujui) — BELUM typecheck/smoke penuh (ikut P9 modul core); perbaikan migrasi berdampak `pg_dump` `\restrict` dibersihkan dari `db/schema.sql` | G5 modul core memakai bukti G4 parity penuh + smoke FE |
