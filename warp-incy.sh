#!/usr/bin/env bash
set -Eeuo pipefail

# WARP -> INCY (AmneziaWG)
# One command:
# bash <(curl -fsSL 'https://raw.githubusercontent.com/qwest65/prog/main/warp-incy.sh')
#
# Output:
#   - one real AmneziaWG .conf for INCY
#   - one incy://import/... link
#   - a plain-ASCII QR rendered directly in the terminal
#
# The WARP credentials come from the author's generator. I1 is a valid CPS
# packet using the documented DNS signature and a small per-run random tag.

AUTHOR_SCRIPT_URL='https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh'
WORK="${TMPDIR:-/tmp}/warp-incy.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# The I1 base below is a real DNS-style CPS signature documented by Amnezia.
# We vary only the <r N> prefix; the protocol snapshot itself stays valid.
DNS_CPS='<b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>'

# ---------------- dependencies ----------------
missing=''
for c in wget jq wg base64 python3 qrencode; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  if [ -f /etc/apt/sources.list ]; then
    sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
  fi
  log "Устанавливаю зависимости:$missing"
  apt update
  apt install -y wget jq wireguard-tools coreutils python3 qrencode
fi

# ---------------- author's generator ----------------
log "Запускаю авторский WARP-in-WARP generator"
wget --inet4-only -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh

bash ./warp_in_warp.sh 2>&1 | tee generator.log

# The author prints the complete WARP.conf as base64 in a URL.
GEN_URL="$(grep -oE 'https://immalware\.vercel\.app/download\?filename=WARP\.conf&content=[A-Za-z0-9+/=_-]+' generator.log | tail -n1 || true)"
[ -n "$GEN_URL" ] || die "Не нашёл ссылку WARP.conf в выводе авторского генератора"

# Decode the content directly; do not perform another HTTP request.
CONTENT_B64="${GEN_URL#*content=}"
CONTENT_B64="$(printf '%s' "$CONTENT_B64" | sed 's/%3D/=/g; s/%2B/+/g; s/%2F/\//g')"
printf '%s' "$CONTENT_B64" | tr '_-' '/+' | base64 -d > WARP.json 2>/dev/null || {
  die "Не удалось декодировать content= из URL генератора"
}

[ -s WARP.json ] || die "После декодирования WARP.json пустой"

# ---------------- validate WARP data ----------------
log "Проверяю Cloudflare WARP данные"
python3 - <<'PY'
import json
from pathlib import Path
D=json.loads(Path('WARP.json').read_text())
O=D.get('outbounds',[])
if len(O)<2:
    raise SystemExit('Нет двух WARP outbounds')
for n,o in enumerate(O[:2],1):
    for k in ('private_key','local_address','peer_public_key','reserved','server','server_port'):
        if not o.get(k):
            raise SystemExit(f'WARP #{n}: отсутствует {k}')
    if len(o['local_address']) < 2:
        raise SystemExit(f'WARP #{n}: отсутствует IPv6')
print('WARP.json: OK')
PY

# ---------------- fresh I1 ----------------
# One I1 per run, using a fresh random-length CPS random prefix.
R1="$(python3 - <<'PY'
import secrets
print(secrets.randbelow(7)+2)
PY
)"
I1="<r ${R1}>${DNS_CPS}"

# ---------------- build one INCY-ready profile ----------------
log "Создаю настоящий AmneziaWG .conf"
python3 - "$I1" <<'PY'
from pathlib import Path
import json, sys

i1 = sys.argv[1]
D=json.loads(Path('WARP.json').read_text())
o=D['outbounds'][0]  # outer/primary WARP from author's pair

ip4=o['local_address'][0].split('/',1)[0]
ip6=o['local_address'][1].split('/',1)[0]
reserved=','.join(str(x) for x in o['reserved'])

conf=f'''[Interface]\nPrivateKey = {o["private_key"]}\nAddress = {ip4}/32, {ip6}/128\nMTU = 1280\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = {i1}\n\n[Peer]\nPublicKey = {o["peer_public_key"]}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = {o["server"]}:{o["server_port"]}\nPersistentKeepalive = 15\nReserved = {reserved}\n'''

Path('WARP-INCY.conf').write_text(conf, encoding='utf-8')
PY

# ---------------- validate final .conf ----------------
grep -q '^\[Interface\]$' WARP-INCY.conf || die 'Нет [Interface]'
grep -q '^PrivateKey = ' WARP-INCY.conf || die 'Нет PrivateKey'
grep -q '^Address = ' WARP-INCY.conf || die 'Нет Address'
grep -q '^\[Peer\]$' WARP-INCY.conf || die 'Нет [Peer]'
grep -q '^PublicKey = ' WARP-INCY.conf || die 'Нет PublicKey'
grep -q '^Endpoint = ' WARP-INCY.conf || die 'Нет Endpoint'
grep -q '^Reserved = ' WARP-INCY.conf || die 'Нет Reserved'
grep -q '^I1 = ' WARP-INCY.conf || die 'Нет I1'

# ---------------- INCY deep link ----------------
B64="$(base64 -w0 WARP-INCY.conf | tr '+/' '-_' | tr -d '=')"
LINK="incy://import/${B64}"

# ---------------- plain ASCII QR ----------------
# Do NOT use ANSIUTF8 here: browser-based terminals often corrupt ANSI/block
# characters. Plain ASCII survives h2.nexus terminal rendering.
printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' ' ГОТОВО — СКАНИРУЙ ЭТОТ QR В INCY'
printf '%s\n' '============================================================'
printf '\n'
qrencode -t ASCII -m 2 -l M "$LINK"
printf '\n%s\n' '============================================================'
printf '%s\n' 'Файл: WARP-INCY.conf'
printf '%s\n' 'Каждый запуск создаёт новый WARP private key, reserved и I1.'
printf '%s\n' '============================================================'

# Save the actual conf and link next to where the command was launched.
cp WARP-INCY.conf "$OLDPWD/WARP-INCY.conf" 2>/dev/null || true
printf '\nINCY link:\n%s\n' "$LINK"
