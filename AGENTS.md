# AGENTS.md — nexierp-golang

Repo target migrasi strangler NestJS → Go. Satu PostgreSQL, dua runtime:
Go KONEK ke database yang sama dengan NestJS (`nexierp`); tabel, outbox,
audit, numbering, sesi, seed RBAC dipakai bersama. Cutover = memindahkan
ROUTE per modul, bukan memindahkan data. Disiplin ini disalin dari
`AGENTS.md` repo NestJS (`/Data/www/nexierp`) dan dikalibrasi ke Go.

## 1. Lapisan & arah import (turun saja: L3 → L2 → L1 → L0)

| Lapisan | Isi |
|---|---|
| L0 | Kontrak & fakta: `api/openapi/*.yaml`, `ddl/`, `db/queries/`, stdlib |
| L1 | `internal/core/*` — shared kernel (database, config, logger, auth, rbac, audit, outbox, numbering, moduleconfig, redis, asynq, storage, mailer, realtime, idempoten, ctxsistem) |
| L2 | `internal/modules/<m>/shared/` — lintas-fitur SE-MODUL |
| L3 | `internal/modules/<m>/{handler,service,domain,repository,types,job,integration}` |

- Import hanya turun lapisan. DILARANG import menyamping antar modul
  (`internal/modules/a` ↔ `internal/modules/b`) — kebutuhan lintas modul
  lewat kosakata event outbox + endpoint (kontrak publik), identik
  disiplin NestJS. Compiler Go menghalangi siklik.
- Arah wiring: `handler → service → {repository, domain}`;
  `repository` & `domain` dilarang mengimpor `service`/`handler`;
  `job`/`listener` delegasi ke `service`.
- Feature-local dulu: naik lapisan hanya dengan bukti pemakai
  (≥2 fitur satu modul → `shared/` L2; ≥2 modul → `internal/core` L1).

## 2. Scaffold kind-folder terkunci (satu pohon per modul)

```
internal/modules/<m>/
├── module.go                # Register(e, deps) + RegWorker(mux, deps) — wiring SATU file
├── handler/<fitur>.go       # permukaan HTTP murni (Echo): bind → validasi → delegasi → pemetaan error
├── service/<fitur>.go       # orkestrasi: domain → SATU pgx tx (repo+audit+outbox+numbering)
├── domain/<aturan>.go       # PURE: invariant/kalkulasi/transisi; errors.go pemetaan pesan
├── repository/<fitur>.go    # SATU-SATUNYA pengguna pgx+sqlc; row→View di sini
├── repository/gen/          # output sqlc — GENERATED, tidak pernah diedit tangan
├── types/<fitur>.go         # tipe modul + override kontrak (turunan eksplisit)
├── shared/                  # L2 se-modul
├── job/<fitur>-<nama>.go    # asynq handler / goroutine cron — delegasi service
└── integration/
    ├── listener/<sumber>-<event>.go   # konsumen outbox — idempoten
    └── adapter/<penyedia>.go          # klien vendor — struct tanpa state, TANPA DB
```

- Penamaan tanpa prefix modul (`ProdukHandler`, bukan `InvProdukHandler`)
  — identitas dibawa import path. Prefix modul hanya di string domain
  (`INV-xxx`, `CFG-INV-xx`) dan nama vendor adapter.
- Dilarang: pgx/SQL di luar `repository/`; echo di `service/`; framework
  apa pun di `domain/`+`types/`; handler mengimpor `repository/`/`domain/`
  langsung; tx baru di dalam blok tx (teruskan executor); outbox/audit/
  numbering keluar transaksi.

## 3. Kontrak kawat BEKU

Path HTTP, method, string izin RBAC `{modul}.{fitur}.{controller}.{action}`,
kode error domain (`INV-xxx`), bentuk JSON camelCase, envelope pagination &
error, header `If-Match`/`Idempotency-Key` — semua PERSIS NestJS. Selisih
apa pun = kekeliruan paritas (koreksi minimal, Mode K), BUKAN perubahan
kontrak. Kontrak baru hanya lahir di `api/openapi/<m>.yaml` + persetujuan
user; hasil `oapi-codegen` tidak diedit tangan.

## 4. Pola baku yang tidak boleh dobel bentuk

- **Service satu transaksi**: satu `pgx.BeginTx` + `defer rollback`
  membungkus repo + audit + outbox + numbering; outbox diterbitkan DI
  DALAM transaksi, tidak pernah post-commit.
- **Job pola siklus**: interval CFG (`core_module_configs`) dibaca ULANG
  tiap siklus (0 = mati, jeda tetap memeriksa), guard overlap wajib, satu
  siklus = SATU panggilan service dengan `ctxsistem.New(ctx)`, idempoten,
  tidak pernah throw ke kernel.
- **Listener idempoten**: validasi payload dengan JSON Schema kosakata
  yang sama dengan NestJS; event ulang = no-op aman; dilarang mengimpor
  modul penerbit.
- **Adapter vendor**: plain struct tanpa state, fakta vendor terkunci di
  komentar header, tanpa akses DB.
- **DDL beku**: dilarang mengubah `ddl/` di repo ini — perubahan skema
  hanya di repo NestJS, lalu di-port berurutan ke `db/migrations` (goose).

## 5. Guard otomatis & verifikasi

- Guard lapisan wajib 0 MERAH sebelum commit:
  `node <skill-dir>/scripts/periksa-batas-lapisan-go.mjs --strict`
  (skill `backend-go-scaffold-implementator`).
- Setiap langkah generate: `gofmt` bersih, `go vet ./...`,
  `go build ./... && go test ./...` hijau.

## 6. Disiplin git

- Setiap task selesai WAJIB commit lokal, TANPA push; pesan commit Bahasa
  Indonesia; verifikasi guard + build + test sebelum commit.
- Repo NestJS (`/Data/www/nexierp`) adalah READ-ONLY untuk migrasi ini —
  tidak pernah diubah dari repo ini.

## 7. Dokumen konstitusi

- `docs/ARSITEKTUR-BACKEND-GO.md` — konstitusi: stack terkunci, pola
  bisnis, fase migrasi §8. Selisih pemetaan = minta keputusan user, lalu
  ubah dokumen itu DULU, bukan skill eksekutor.
- `docs/MIGRASI-BACKEND-GO.md` — pelacak fase per modul; tiap fase selesai
  baris matriks di-update (✅ tanggal + path bukti) di sesi yang sama.
