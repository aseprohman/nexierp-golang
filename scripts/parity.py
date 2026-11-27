#!/usr/bin/env python3
# parity.py — bukti G4 P2/P5/P6: bandingkan respons nyata NestJS vs Go
# (status + JSON sama persis; keduanya atas DB live yang sama).
import json, sys, urllib.request, urllib.error

NEST, GO, TOK = sys.argv[1], sys.argv[2], sys.argv[3]
HDR = {"Authorization": "Bearer " + TOK, "Content-Type": "application/json"}

def call(base, method, path, body=None, raw=False):
    req = urllib.request.Request(base + path, data=(json.dumps(body).encode() if body is not None else None), headers=HDR, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=15)
        data = r.read()
        return r.status, dict(r.headers), data
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

def norm(status, headers, data):
    if (headers.get("Content-Type") or "").startswith("text/csv"):
        lines = data.decode().split("\r\n")
        return ("csv", lines[0], "csv-ok")  # jumlah baris melebihi cakupan: tiap panggilan menambah baris audit-ekspor (self-mutation)
    try:
        return (status, json.loads(data))
    except Exception:
        return (status, data.decode()[:200])

CASES = [
    ("GET", "/api/system/health", None),
    ("GET", "/api/system/overview", None),
    ("GET", "/api/system/overview/audit", None),
    ("GET", "/api/system/users?page=1&limit=2", None),
    ("GET", "/api/system/users/1", None),
    ("GET", "/api/system/roles", None),
    ("GET", "/api/system/roles/1/permissions", None),
    ("GET", "/api/system/modules", None),
    ("GET", "/api/system/routes?page=1&limit=2", None),
    ("GET", "/api/system/routes/map", None),
    ("GET", "/api/system/permissions?page=1&limit=2", None),
    ("GET", "/api/system/menus", None),
    ("GET", "/api/system/menus?tree=1", None),
    ("GET", "/api/system/features", None),
    ("GET", "/api/system/user-overrides?userId=1", None),
    ("GET", "/api/system/security/sessions?page=1&limit=2", None),
    ("GET", "/api/system/security/login-audit?page=1&limit=2", None),
    ("GET", "/api/system/security/mfa?limit=2", None),
    ("GET", "/api/system/security/password-history?limit=2", None),
    ("GET", "/api/system/security/ip-allowlist", None),
    ("GET", "/api/system/audit-trail?page=1&limit=2", None),
    ("GET", "/api/system/audit-trail/actions", None),
    ("GET", "/api/system/audit-trail/export", None),
    ("GET", "/api/system/environment", None),
    ("GET", "/api/system/tenants", None),
    ("GET", "/api/system/tenants/context", None),
    ("GET", "/api/system/files?page=1&limit=2", None),
    ("GET", "/api/system/files/kategori", None),
    ("GET", "/api/system/wilayah/provinsi?page=1&limit=2", None),
    ("GET", "/api/system/wilayah/kota?filter%5BidProvinsi%5D=1&limit=2", None),
    ("GET", "/api/system/wilayah/kodepos/10110?page=1&limit=2", None),
    ("GET", "/api/system/cluster?page=1&limit=2", None),
    ("GET", "/api/system/cluster/modul-options", None),
    ("GET", "/api/system/agama", None),
    ("GET", "/api/system/agama/999999", None),           # 404 parity
    ("GET", "/api/system/datascope/definitions", None),
    ("POST", "/api/system/agama", {"code": "G0TEST", "nama": "Uji Parity G0", "urutan": 999}),  # 201 parity
    ("POST", "/api/system/agama", {"code": "", "nama": ""}),                                    # 400 zod parity
]

npass = nfail = 0
fails = []
for method, path, body in CASES:
    a = norm(*call(NEST, method, path, body))
    b = norm(*call(GO, method, path, body))
    if a == b:
        npass += 1
        print(f"PASS {method} {path}")
    else:
        nfail += 1
        sa = json.dumps(a, sort_keys=True)[:300] if not isinstance(a[1], str) else a[1][:300]
        sb = json.dumps(b, sort_keys=True)[:300] if not isinstance(b[1], str) else b[1][:300]
        print(f"FAIL {method} {path}\n  NEST: {sa}\n  GO  : {sb}")
        fails.append(path)

# siklus hidup agama (create→patch salah versi 409→delete) per runtime, bandingkan BENTUK
print("--- lifecycle agama ---")
for label, base in (("NEST", NEST), ("GO", GO)):
    st, h, d = call(base, "POST", "/api/system/agama", {"code": "G0LIFE", "nama": "Siklus", "urutan": 1})
    row = json.loads(d)["data"] if st in (200, 201) else {}
    cid, ver = row.get("id"), row.get("version")
    st2, _, d2 = call(base, "PATCH", f"/api/system/agama/{cid}", {"nama": "Siklus2", "version": ver + 999})
    st3, _, d3 = call(base, "DELETE", f"/api/system/agama/{cid}", {"version": ver + 1})
    print(f"{label}: create={st} id={cid} patch-salah-versi={st2} {json.loads(d2).get('detail', json.loads(d2).get('message',''))[:80]} delete={st3}")
    call(base, "DELETE", f"/api/system/agama/{cid}", {"version": ver + 1})

print(f"RINGKAS: PASS={npass} FAIL={nfail} dari {len(CASES)} kasus")
if fails:
    print("GAGAL:", ", ".join(fails))
