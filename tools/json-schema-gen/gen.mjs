// gen.mjs — generator JSON Schema dari kosakata zod `packages/schemas` repo
// NestJS (/Data/www/nexierp — READ-ONLY, tidak pernah ditulis).
//
// Pemakaian (dari folder ini):
//   npm install          # node_modules LOKAL di folder ini saja
//   npm run gen -- core  # modul argumen, mis. core → api/json-schema/core/*.json
//   node gen.mjs <modul> # setara langsung (via bin tsx)
//
// Sumber modul: $SCHEMAS_SRC/<modul>/index.ts — default "../nexierp/packages/
// schemas/src" (relatif terhadap cwd; fallback relatif folder script ini —
// cwd = repo nexierp-golang → /Data/www/nexierp/packages/schemas/src).
// Import .ts dijalankan via tsx (transpile on-the-fly; zod schema-nya diambil
// dari node_modules repo NestJS — hanya DIBACA, bukan di-install).
//
// Aturan ekstraksi: TIAP export berakhiran "Schema" yang punya `safeParse`
// (duck-typing zod — lintas-copy zod aman) → zod-to-json-schema → ditulis ke
// api/json-schema/<modul>/<nama>.json — NAMA FILE TANPA sufiks "Schema"
// (loginSchema → login.json). Output root = definisi bernama langsung
// (bukan pembungkus $ref); definisi sub-schema bernama lain ikut di bawah
// `definitions` bila ada.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { zodToJsonSchema } from "zod-to-json-schema";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const modul = process.argv[2];
if (!modul || modul.startsWith("-")) {
  console.error("pakai: node gen.mjs <modul>  (mis. core; atau: npm run gen -- core)");
  process.exit(1);
}

// --- resolusi sumber kosakata (SCHEMAS_SRC, default ../nexierp/packages/schemas/src)
const defPath = process.env.SCHEMAS_SRC ?? "../nexierp/packages/schemas/src";
const repoRoot = path.resolve(__dirname, "..", "..");
const kandidat = [
  path.resolve(process.cwd(), defPath), // cwd = root repo nexierp-golang
  path.resolve(repoRoot, defPath), // root repo → /Data/www/nexierp/…
  path.resolve(__dirname, defPath), // fallback: relatif folder tool
];
const srcRoot = kandidat.find((p) => fs.existsSync(p));
if (!srcRoot) {
  console.error(`SCHEMAS_SRC tidak ditemukan: ${defPath} (coba: ${kandidat.join(", ")})`);
  process.exit(1);
}
const indexTs = path.join(srcRoot, modul, "index.ts");
if (!fs.existsSync(indexTs)) {
  console.error(`modul '${modul}' tidak ada di ${srcRoot} (carinya: ${indexTs})`);
  process.exit(1);
}

// --- import modul TS via tsx (READ-ONLY terhadap repo NestJS)
const mod = await import(pathToFileURL(indexTs).href);

// --- konversi export berakhiran Schema → file JSON Schema
const outDir = path.resolve(__dirname, "..", "..", "api", "json-schema", modul);
fs.mkdirSync(outDir, { recursive: true });

let n = 0;
const terpakai = new Set();
for (const [name, value] of Object.entries(mod)) {
  if (!name.endsWith("Schema")) continue;
  // duck-typing zod (bukan instanceof — copy zod lokal vs NestJS bisa beda)
  if (!value || typeof value !== "object" || typeof value.safeParse !== "function") continue;

  const nama = name.slice(0, -"Schema".length);
  if (terpakai.has(nama)) {
    console.error(`  ! nama bentrok: ${nama} (skip duplikat)`);
    continue;
  }
  terpakai.add(nama);

  const doc = zodToJsonSchema(value, { name, target: "draft-7" });
  const defs = doc.definitions ?? {};
  const root = defs[name] ?? doc;
  const out = { $schema: "http://json-schema.org/draft-07/schema#", ...root };
  const lain = Object.keys(defs).filter((k) => k !== name);
  // Schema rekursif (z.lazy self-$ref) wajib mempertahankan definisi dirinya.
  if (JSON.stringify(root).includes(`#/definitions/${name}`)) {
    out.definitions = { ...defs };
  } else if (lain.length > 0) {
    out.definitions = Object.fromEntries(lain.map((k) => [k, defs[k]]));
  } else {
    delete out.definitions;
  }

  const file = path.join(outDir, `${nama}.json`);
  fs.writeFileSync(file, `${JSON.stringify(out, null, 2)}\n`);
  n++;
}

console.log(`${n} JSON Schema modul '${modul}' → ${outDir}`);
if (n === 0) {
  console.error("  ! tidak ada export berakhiran Schema yang valid");
  process.exit(1);
}
