#!/usr/bin/env bash
set -Eeuo pipefail

# WARP in WARP -> AmneziaWG/INCY helper
# One command:
#   bash <(curl -fsSL https://raw.githubusercontent.com/qwest65/prog/main/warp-incy.sh)
#
# The author's generator PRINTS a download URL instead of saving WARP.conf.
# This script captures that URL, extracts its base64 content, then creates
# INCY-ready AmneziaWG profiles and QR codes.

AUTHOR_SCRIPT_URL="https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh"
WORK="${TMPDIR:-/tmp}/warp-incy.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

log "Проверяю зависимости"
missing=()
for c in wg jq wget curl base64 python3 qrencode; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if ((${#missing[@]})); then
    sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
    apt update
    apt install -y wireguard-tools jq wget curl coreutils python3 qrencode
fi

log "Скачиваю авторский генератор"
wget --inet4-only -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh

# IMPORTANT: author script prints the generated WARP.conf as a download URL.
log "Генерирую новые WARP"
if ! bash ./warp_in_warp.sh >author-output.txt 2>&1; then
    cat author-output.txt
    die "Авторский генератор завершился с ошибкой"
fi

# Show the author's output for diagnostics, but parse the URL from the captured file.
cat author-output.txt

AUTHOR_URL="$(grep -oE 'https://immalware\.vercel\.app/download\?filename=[^[:space:]]+' author-output.txt | tail -n1 || true)"
[ -n "$AUTHOR_URL" ] || die "Не нашёл ссылку на сгенерированный WARP.conf в выводе автора"

log "Извлекаю WARP.conf из URL автора"
AUTHOR_URL="$AUTHOR_URL" python3 - <<'PY'
import os, urllib.parse, base64
from pathlib import Path

u = os.environ["AUTHOR_URL"]
q = urllib.parse.urlparse(u).query
params = urllib.parse.parse_qs(q, keep_blank_values=True)
content = params.get("content", [""])[0]
if not content:
    raise SystemExit("В URL автора нет параметра content")

# The author uses standard base64. Be tolerant of URL quoting.
content = urllib.parse.unquote(content)
content += "=" * ((4 - len(content) % 4) % 4)
try:
    raw = base64.b64decode(content, validate=False)
except Exception as e:
    raise SystemExit(f"Не удалось декодировать content: {e}")

Path("author-WARP.conf").write_bytes(raw)
print("author-WARP.conf extracted")
PY

log "Проверяю две свежие WARP-регистрации"
python3 - <<'PY'
import json
from pathlib import Path
D=json.loads(Path('author-WARP.conf').read_text())
O=D.get('outbounds',[])
if len(O)<2: raise SystemExit('Нет двух WARP outbounds')
for i,o in enumerate(O[:2],1):
    for k in ('private_key','local_address','peer_public_key','reserved','server','server_port'):
        if not o.get(k): raise SystemExit(f'WARP #{i}: нет {k}')
    if len(o['local_address'])<2: raise SystemExit(f'WARP #{i}: нет IPv6')
print('WARP OK')
PY

log "Генерирую НОВЫЕ I1"
python3 - <<'PY'
from pathlib import Path
import secrets
for n in (1,2):
    # Fresh CPS packet every run, independent for both profiles.
    Path(f'I1-{n}.txt').write_text('<b 0xc300000001'+secrets.token_hex(48)+'>\n')
PY

log "Формирую INCY-ready AmneziaWG .conf"
python3 - <<'PY'
from pathlib import Path
import json
D=json.loads(Path('author-WARP.conf').read_text())
o1,o2=D['outbounds'][:2]

def ip(o,n): return o['local_address'][n].split('/',1)[0]
def r(o): return ','.join(map(str,o['reserved']))
def render(o,i1,mtu,name):
    return f'''# {name}\n[Interface]\nPrivateKey = {o["private_key"]}\nAddress = {ip(o,0)}/32, {ip(o,1)}/128\nMTU = {mtu}\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\nS3 = 0\nS4 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = {i1}\n\n[Peer]\nPublicKey = {o["peer_public_key"]}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = {o["server"]}:{o["server_port"]}\nPersistentKeepalive = 15\nReserved = {r(o)}\n'''
Path('WARPNEW-INCY.conf').write_text(render(o1,Path('I1-1.txt').read_text().strip(),1420,'WARPNEW'))
Path('WARPNEW-SECOND-INCY.conf').write_text(render(o2,Path('I1-2.txt').read_text().strip(),1280,'WARPNEW-SECOND'))
PY

# INCY accepts amneziawg://<base64url-conf>#Name and incy://import/<base64-conf>.
# Use the canonical amneziawg:// form in QR.
B64_1="$(base64 -w0 WARPNEW-INCY.conf | tr '+/' '-_' | tr -d '=')"
B64_2="$(base64 -w0 WARPNEW-SECOND-INCY.conf | tr '+/' '-_' | tr -d '=')"
LINK1="amneziawg://${B64_1}#WARPNEW"
LINK2="amneziawg://${B64_2}#WARPNEW-SECOND"

print_qr() {
    local title="$1"
    local link="$2"
    printf '\n%s\n' "==================== ${title} ===================="
    if ! qrencode -t UTF8 -m 1 "$link"; then
        echo "QR не удалось вывести. Ссылка ниже:"
        printf '%s\n' "$link"
    fi
    printf '%s\n' "============================================================"
}

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' 'ГОТОВО — СКАНИРУЙ QR В INCY'
printf '%s\n' '============================================================'
print_qr '1) WARPNEW' "$LINK1"
print_qr '2) WARPNEW-SECOND' "$LINK2"
printf '\n%s\n' 'Файлы сохранены в текущем каталоге:'
printf '%s\n' '  WARPNEW-INCY.conf'
printf '%s\n' '  WARPNEW-SECOND-INCY.conf'
printf '\n%s\n' 'Каждый запуск создаёт новые private key, reserved и I1.'
printf '%s\n' '============================================================'
