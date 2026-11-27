# Bukti Gerbang G0 — Fondasi Go (2026-11-27)

Kelima bukti wajib Mode F, semuanya diuji terhadap DB dev live yang sama
(podman `nexierp-postgres` 127.0.0.1:15433) dengan NestJS API hidup di 3001
dan Go API di 3101 (berdampingan):

| Bukti | File | Hasil |
|---|---|---|
| (a) login via Go = JWT sah di NestJS & FE | `a-login-lintas-runtime.txt` | ✅ dua arah: token Go divalidasi `/auth/me` NestJS (`g0_bukti`), token NestJS divalidasi `/auth/me` Go — klaim `{sub,username,sid}` + baris `core_sessions` yang sama |
| (b) 403 RBAC parity | `b-rbac-403.txt` | ✅ NestJS: `FORB-403` "permission 'system.rbac.stats' diperlukan"; guard Go (registry + compiler terhadap `core_routes` live): problem+json identik byte-per-byte |
| (c) outbox Go terbaca sisi NestJS | `c-outbox.txt` | ✅ `enqueue` Go id=445; publish ulang key sama → id sama (idempoten `uq_outbox_topic_key_pending`); konsumen sisi NestJS (poll `SKIP LOCKED` + `tandaiDelivered`) pending→delivered |
| (d) schema goose ≡ live | `d-schema.txt` | ✅ 47 tabel `core_*` live semuanya ada di `db/schema.sql` (goose 91 porting + 11 rekonsiliasi bentuk-live); kolom `core_sessions`/`core_routes` = bentuk live |
| (e) FE menerima `rbac.changed` dari WS Go | `e-ws.txt` + perubahan `apps/web/src/lib/realtime.ts` | ✅ frame `{"event":"rbac.changed","data":{"reason":"rbac"}}` diterima lewat handshake cookie sesi nyata (room `user:<id>`, bridge invalidasi); FE client diganti WS native (1 file, API publik identik) |

Alat bukti (masing-masing program Go kecil, bisa diulang):
`scripts/bukti403`, `scripts/buktioutbox`, `scripts/buktiws`, `scripts/hashgen`.

## Catatan jujur

- Login uji memakai user bukti khusus `g0_bukti` (argon2id digenerate dari
  kode Go) — password `admin` dev sudah diubah pemiliknya, tidak diutak-atik.
- Pemicu `InvalidateUser` di produksi adalah endpoint override/assignRoles
  modul core (peringkat 1, G1–G6) — di G0 jalur bridge dibuktikan via pemanggilan
  langsung `compiler.InvalidateUser` (program bukti), wiring identik `internal/app`.
- Cutover FISIK route `/api/auth/*` via gateway/proxy + penonaktifan gateway
  socket.io NestJS = langkah deploy berdampingan (`release-deploy`/`devops-runner`),
  bukan perubahan kode: di dev keduanya hidup (3001/3101), FE mengarah lewat
  `NEXT_PUBLIC_WS_URL` saat memakai hub Go.
- FE: perubahan `apps/web/src/lib/realtime.ts` belum dikenakan typecheck/smoke
  penuh (ikut P9 smoke modul core).
