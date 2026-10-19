#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/src/deps"
OUT="$DEPS/bundled"
VER=$(sed -n 's/^version=//p' "$ROOT/src/module.prop")
REF="${SPECTER_REF:-$ROOT/../specter-v${VER}}"

mkdir -p "$DEPS" "$OUT"

if [ -d "$REF/deps" ]; then
  for f in classes.dex inotifyd32 inotifyd64 inotifyd_x86 inotifyd_x86_64; do
    if [ ! -f "$DEPS/$f" ] && [ -f "$REF/deps/$f" ]; then
      cp "$REF/deps/$f" "$DEPS/$f"
    fi
  done
fi

gh_zip() {
  repo="$1"
  dest="$2"
  json=$(curl -fsSL -H "User-Agent: Specter" "https://api.github.com/repos/${repo}/releases/latest")
  url=$(printf '%s' "$json" | python3 -c 'import json,sys
r=json.load(sys.stdin)
url=""
dbg=""
for a in r.get("assets",[]):
    u=a.get("browser_download_url","")
    if not u.endswith(".zip"):
        continue
    if "Debug" in u or "debug" in u:
        dbg = dbg or u
        continue
    url=u
    break
print(url or dbg)')
  [ -n "$url" ] || { echo "no release zip for $repo" >&2; exit 1; }
  echo "$repo"
  curl -fL --retry 3 -o "$dest" "$url"
  [ "$(wc -c < "$dest")" -gt 1000 ]
}

gh_zip beakthoven/TrickyStoreOSS "$OUT/tricky_store.zip"
gh_zip KOWX712/PlayIntegrityFix "$OUT/playintegrityfix.zip"

python3 - "$OUT" <<'PY'
import base64, json, re, sys, urllib.request
from pathlib import Path

out = Path(sys.argv[1])
ua = {"User-Agent": "Specter"}
std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
shuf = "1dgWnocayqxU3r6vA5lCIPYfHmkV08b4tz+KMsp2NQ9LRXihODwSj7BEFJ/ZuGTe"
trans = str.maketrans(shuf, std)

def get(url):
    req = urllib.request.Request(url, headers=ua)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

html = get("https://source.android.com/docs/security/bulletin/pixel").decode("utf-8", "replace")
m = re.search(r"<td>(\d{4}-\d{2}-\d{2})</td>", html) or re.search(r"\d{4}-\d{2}-\d{2}", html)
if not m:
    raise SystemExit("security patch not found")
patch = m.group(1) if m.lastindex else m.group(0)
(out / "security_patch.txt").write_text(patch + "\n")
print("security patch", patch)

revoked = set(json.loads(get("https://android.googleapis.com/attestation/status?encrypted=0")).get("entries", {}))

def is_revoked(serial):
    serial = (serial or "").strip().lower()
    if not serial:
        return False
    try:
        return str(int(serial, 16)) in revoked
    except ValueError:
        return False

def decode_blob(raw):
    text = raw.decode("utf-8", "replace").translate(trans)
    return base64.b64decode(text)

def valid_xml(xml):
    s = xml.decode("utf-8", "replace")
    has_key = 'algorithm="ecdsa"' in s or 'algorithm="rsa"' in s
    has_id = "<serial>" in s or "DeviceID" in s
    return has_key and has_id and xml.startswith(b"<?xml") or (has_key and has_id and b"<AndroidAttestation>" in xml)

catalog = json.loads(get("https://rawbin.dpejoh.com/catalog"))
entries = [e for e in catalog.get("entries", []) if not e.get("revoked")]
active = [e for e in entries if not e.get("softbanned")]
ordered = active + [e for e in entries if e.get("softbanned")]
pairs = [(e.get("source"), str(e.get("version"))) for e in ordered if e.get("source") and e.get("version")]
pairs.append(("Yuri", "8"))

seen = set()
for source, version in pairs:
    key = (source, version)
    if key in seen:
        continue
    seen.add(key)
    hit = next((e for e in ordered if e.get("source") == source and str(e.get("version")) == version), None)
    if hit and is_revoked(hit.get("serial")):
        continue
    try:
        blob = get(f"https://rawbin.dpejoh.com/key/{source}/{version}")
        xml = decode_blob(blob)
    except Exception:
        continue
    if not valid_xml(xml):
        continue
    serial = (hit or {}).get("serial") or ""
    if is_revoked(serial):
        continue
    (out / "keybox.xml").write_bytes(xml)
    print("keybox", source, version)
    break
else:
    raise SystemExit("no working keybox")
PY

cd "$ROOT"
npm run build
