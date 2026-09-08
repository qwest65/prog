#!/usr/bin/env bash
set -Eeuo pipefail

# WARP -> INCY (AmneziaWG)
# One command:
# bash <(curl -fsSL 'https://raw.githubusercontent.com/qwest65/prog/main/warp-incy-final.sh')
#
# This intentionally produces ONE real, importable AmneziaWG .conf for INCY.
# The Cloudflare data is taken from the author's generator; the old JSON
# wrapper is not passed to INCY because INCY expects [Interface]/[Peer].

AUTHOR_SCRIPT_URL='https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh'
WORK="${TMPDIR:-/tmp}/warp-incy-final.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Old Debian 11 / h2.nexus often has an expired bullseye-security entry.
if [ -f /etc/apt/sources.list ]; then
  sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
fi

missing=''
for c in wget curl jq wg base64 python3 qrencode; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  log "Устанавливаю зависимости:$missing"
  apt update
  apt install -y wget curl jq wireguard-tools coreutils python3 qrencode
fi

log "Запускаю авторский генератор"
wget --inet4-only -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh

# Capture exactly what the generator prints. It prints a download URL containing
# the complete WARP.conf as base64 in the content= query parameter.
set +e
bash ./warp_in_warp.sh >generator.log 2>&1
rc=$?
set -e
cat generator.log

GEN_URL="$(grep -oE 'https://immalware\.vercel\.app/download\?filename=WARP\.conf&content=[A-Za-z0-9+/=_-]+' generator.log | tail -n1 || true)"
[ -n "$GEN_URL" ] || die "Не найден URL WARP.conf в выводе генератора (exit=$rc)"

CONTENT_B64="${GEN_URL#*content=}"
printf '%s' "$CONTENT_B64" | base64 -d > WARP.json 2>/dev/null || die "Не удалось декодировать content="

log "Проверяю данные Cloudflare WARP"
python3 - <<'PY'
import json
from pathlib import Path
D=json.loads(Path('WARP.json').read_text())
O=D.get('outbounds',[])
if not O:
    raise SystemExit('WARP.json: нет outbounds')
o=O[0]
for k in ('private_key','local_address','peer_public_key','reserved','server','server_port'):
    if not o.get(k):
        raise SystemExit(f'WARP.json: нет {k}')
if len(o['local_address']) < 2:
    raise SystemExit('WARP.json: нет IPv6')
print('Cloudflare WARP data: OK')
PY

# Official AmneziaWG documentation gives a known-good DNS-like CPS signature.
# <r N> makes the I1 packet differ at runtime on every handshake; N is also
# varied on every script run so the text in the generated .conf changes too.
RCOUNT="$(python3 - <<'PY'
import secrets
print(secrets.randbelow(7)+2)
PY
)"
I1="<r ${RCOUNT}><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>"

log "Создаю настоящий AmneziaWG .conf для INCY"
python3 - <<'PY'
from pathlib import Path
import json, os
D=json.loads(Path('WARP.json').read_text())
o=D['outbounds'][0]
i1=os.environ['I1']

ip4=o['local_address'][0].split('/',1)[0]
ip6=o['local_address'][1].split('/',1)[0]
reserved=','.join(map(str,o['reserved']))

conf=f'''# WARP / AmneziaWG / INCY\n\n[Interface]\nPrivateKey = {o['private_key']}\nAddress = {ip4}/32, {ip6}/128\nMTU = 1420\n\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = {i1}\n\n[Peer]\nPublicKey = {o['peer_public_key']}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = {o['server']}:{o['server_port']}\nPersistentKeepalive = 15\nReserved = {reserved}\n'''
Path('WARP-INCY.conf').write_text(conf)
PY

# incy://import/<base64url .conf> is the direct INCY import form.
B64="$(base64 -w0 WARP-INCY.conf | tr '+/' '-_' | tr -d '=')"
LINK="incy://import/${B64}"

# Make QR. Prefer ANSI UTF-8 output for the terminal.
log "Формирую QR"

printf '\n'
printf '%s\n' '############################################################'
printf '%s\n' '# ГОТОВО — СКАНИРУЙ QR В INCY'
printf '%s\n' '############################################################'
printf '\n'
qrencode -t ANSIUTF8 -l M -m 1 "$LINK"

printf '\n%s\n' '============================================================'
printf '%s\n' 'Это ОДИН полноценный AmneziaWG .conf с учётными данными.'
printf '%s\n' 'Файл: WARP-INCY.conf'
printf '%s\n' 'I1 генерируется заново при каждом запуске.'
printf '%s\n' 'PrivateKey/reserved берутся из новой WARP-регистрации.'
printf '%s\n' '============================================================'

# Save a copy where the user launched the command.
cp WARP-INCY.conf "$OLDPWD/WARP-INCY.conf" 2>/dev/null || true

printf '\nINCY deep-link (если понадобится):\n%s\n' "$LINK"
