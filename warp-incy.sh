#!/usr/bin/env bash
set -Eeuo pipefail

# WARP in WARP -> AmneziaWG/INCY helper
#
# One command on a temporary Debian host:
#   bash <(curl -fsSL https://raw.githubusercontent.com/qwest65/prog/main/warp-incy.sh)
#
# The script:
#   - runs the author's WARP-in-WARP generator;
#   - uses the two fresh Cloudflare WARP registrations/private keys it returns;
#   - generates a fresh I1 for each generated profile;
#   - writes two AmneziaWG .conf files;
#   - prints direct download URLs using the same download endpoint used by the
#     author's generator.
#
# IMPORTANT: each .conf is one AmneziaWG profile. The original author's
# detour chain (second -> first) cannot be represented by a raw WireGuard .conf.

AUTHOR_SCRIPT_URL="https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh"
DOWNLOAD_API="https://immalware.vercel.app/download"

WORK="${TMPDIR:-/tmp}/warp-incy.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

log "Checking dependencies"
missing=()
for c in wg jq wget curl base64 python3; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done

if ((${#missing[@]})); then
    # h2.nexus / old Debian 11 may contain an expired bullseye-security entry.
    sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
    apt update
    apt install -y wireguard-tools jq wget curl coreutils python3
fi

log "Downloading author's generator"
wget -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh

log "Generating two fresh WARP registrations"
bash ./warp_in_warp.sh

# The author script normally creates WARP.conf. Be tolerant if the filename differs.
WARP_CONF="$(find . -maxdepth 1 -type f -name '*.conf' -print -quit)"
[ -n "$WARP_CONF" ] || die "WARP.conf was not produced by the generator"

cp "$WARP_CONF" author-WARP.conf

log "Validating generated WARP data"
python3 - <<'PY'
import json
from pathlib import Path

d = json.loads(Path("author-WARP.conf").read_text())
out = d.get("outbounds", [])
if len(out) < 2:
    raise SystemExit("Generator returned fewer than two outbounds")
for n, o in enumerate(out[:2], 1):
    for k in ("private_key", "local_address", "peer_public_key", "reserved", "server", "server_port"):
        if not o.get(k):
            raise SystemExit(f"WARP #{n}: missing {k}")
    if len(o["local_address"]) < 2:
        raise SystemExit(f"WARP #{n}: missing IPv6 address")
print("WARP data: OK")
PY

log "Generating fresh I1 values"
python3 - <<'PY'
from pathlib import Path
import secrets

# Generate a new CPS I1 for every run, separately for each leg.
# The prefix keeps the value in the same CPS/hex presentation used by
# AmneziaWG configs; the remainder is fresh random data.
for n in (1, 2):
    i1 = "<b 0xc300000001" + secrets.token_hex(48) + ">"
    Path(f"I1-{n}.txt").write_text(i1 + "\n")
PY

log "Building AmneziaWG configs"
python3 - <<'PY'
from pathlib import Path
import json

D = json.loads(Path("author-WARP.conf").read_text())
o1, o2 = D["outbounds"][:2]
i1_1 = Path("I1-1.txt").read_text().strip()
i1_2 = Path("I1-2.txt").read_text().strip()

def ip4(o): return o["local_address"][0].split("/",1)[0]
def ip6(o): return o["local_address"][1].split("/",1)[0]
def rsv(o): return ",".join(str(x) for x in o["reserved"])

def render(o, i1, mtu, title):
    return f'''# {title}\n# Fresh Cloudflare WARP registration + fresh AmneziaWG I1\n\n[Interface]\nPrivateKey = {o["private_key"]}\nAddress = {ip4(o)}/32, {ip6(o)}/128\nMTU = {mtu}\n\n# AmneziaWG obfuscation\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = {i1}\n\n[Peer]\nPublicKey = {o["peer_public_key"]}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = {o["server"]}:{o["server_port"]}\nPersistentKeepalive = 15\nReserved = {rsv(o)}\n'''

Path("WARPNEW-INCY.conf").write_text(render(o1, i1_1, 1420, "WARPNEW"))
Path("WARPNEW-SECOND-INCY.conf").write_text(render(o2, i1_2, 1280, "WARPNEW in WARP - second leg"))
PY

make_url() {
    local file="$1"
    local name="$2"
    local b64
    b64="$(base64 -w0 "$file")"
    printf '%s?filename=%s&content=%s' \
        "$DOWNLOAD_API" \
        "$name" \
        "$b64"
}

URL1="$(make_url WARPNEW-INCY.conf WARPNEW-INCY.conf)"
URL2="$(make_url WARPNEW-SECOND-INCY.conf WARPNEW-SECOND-INCY.conf)"

cp WARPNEW-INCY.conf "$OLDPWD/WARPNEW-INCY.conf" 2>/dev/null || true
cp WARPNEW-SECOND-INCY.conf "$OLDPWD/WARPNEW-SECOND-INCY.conf" 2>/dev/null || true

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' 'ГОТОВО'
printf '%s\n' '============================================================'
printf '%s\n' '1) WARPNEW (первый, обфусцированный):'
printf '%s\n' "$URL1"
printf '\n'
printf '%s\n' '2) WARPNEW-SECOND (второй):'
printf '%s\n' "$URL2"
printf '\n'
printf '%s\n' 'Локально также созданы:'
printf '%s\n' "  $OLDPWD/WARPNEW-INCY.conf"
printf '%s\n' "  $OLDPWD/WARPNEW-SECOND-INCY.conf"
printf '\n'
printf '%s\n' 'Каждый запуск получает новые Cloudflare private keys/reserved и новые I1.'
printf '%s\n' '============================================================'
