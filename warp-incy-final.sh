#!/usr/bin/env bash
set -Eeuo pipefail

# WARP -> INCY (AmneziaWG)
# One command:
# bash <(curl -fsSL 'https://raw.githubusercontent.com/qwest65/prog/main/warp-incy-final.sh')
#
# Produces ONE real, importable AmneziaWG .conf for INCY and prints a QR.
# The author's generated JSON is converted to the raw [Interface]/[Peer]
# format expected by INCY.

AUTHOR_SCRIPT_URL='https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh'
WORK="${TMPDIR:-/tmp}/warp-incy-final.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

if [ -f /etc/apt/sources.list ]; then
  # h2.nexus / old Debian 11 may have an expired bullseye-security entry.
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

log "Скачиваю авторский генератор"
wget --inet4-only -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh

log "Генерирую новую WARP-регистрацию"
set +e
bash ./warp_in_warp.sh >generator.log 2>&1
RC=$?
set -e
cat generator.log

# Авторский скрипт печатает URL вида:
# https://immalware.vercel.app/download?filename=WARP.conf&content=BASE64
# Берём BASE64 непосредственно из URL — локальный WARP.conf ему не нужен.
GEN_URL="$(grep -oE 'https://immalware\.vercel\.app/download\?filename=WARP\.conf&content=[A-Za-z0-9+/=_-]+' generator.log | tail -n1 || true)"
[ -n "$GEN_URL" ] || die "Не удалось получить URL WARP.conf из генератора (exit=$RC)"

CONTENT_B64="${GEN_URL#*content=}"
printf '%s' "$CONTENT_B64" | base64 -d > WARP.json 2>/dev/null || die "Ошибка декодирования WARP.conf из content="

log "Проверяю WARP.json"
python3 - <<'PY'
import json
from pathlib import Path
D=json.loads(Path('WARP.json').read_text())
O=D.get('outbounds',[])
if not O:
    raise SystemExit('Нет outbounds')
o=O[0]
for k in ('private_key','local_address','peer_public_key','reserved','server','server_port'):
    if not o.get(k):
        raise SystemExit(f'Нет {k}')
if len(o['local_address']) < 2:
    raise SystemExit('Нет IPv6')
print('WARP.json OK')
PY

# Valid CPS I1 based on the DNS signature documented by Amnezia.
# <r N> is generated anew on every run, so the actual I1 packet is randomized
# and the text of the generated configuration also changes.
RCOUNT="$(python3 - <<'PY'
import secrets
print(secrets.randbelow(7)+2)
PY
)"
export I1="<r ${RCOUNT}><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>"

log "Создаю настоящий AmneziaWG .conf"
python3 - <<'PY'
from pathlib import Path
import json, os

D=json.loads(Path('WARP.json').read_text())
o=D['outbounds'][0]
i1=os.environ['I1']

def ip(o,n): return o['local_address'][n].split('/',1)[0]
reserved=','.join(map(str,o['reserved']))

conf=f'''# WARP / AmneziaWG / INCY

[Interface]
PrivateKey = {o['private_key']}
Address = {ip(o,0)}/32, {ip(o,1)}/128
MTU = 1420

Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = {i1}

[Peer]
PublicKey = {o['peer_public_key']}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {o['server']}:{o['server_port']}
PersistentKeepalive = 15
Reserved = {reserved}
'''

Path('WARP-INCY.conf').write_text(conf, encoding='utf-8')
PY

# Validate the actual result before making QR.
python3 - <<'PY'
from pathlib import Path
import base64
p=Path('WARP-INCY.conf')
t=p.read_text()
for marker in ('[Interface]','[Peer]','PrivateKey = ','Address = ','PublicKey = ','Endpoint = ','Reserved = ','I1 = '):
    if marker not in t:
        raise SystemExit(f'Нет обязательного поля: {marker}')
key=t.split('PrivateKey = ',1)[1].split('\n',1)[0].strip()
if len(key) != 44:
    raise SystemExit(f'Неверная длина PrivateKey: {len(key)}')
try:
    base64.b64decode(key, validate=True)
except Exception:
    raise SystemExit('PrivateKey не является корректным base64')
print('INCY .conf validation OK')
PY

# INCY documented deep-link: incy://import/{base64-conf}.
B64="$(base64 -w0 WARP-INCY.conf | tr '+/' '-_' | tr -d '=')"
LINK="incy://import/${B64}"

log "Вывожу QR"
printf '\n############################################################\n'
printf '# Готовый AmneziaWG конфиг для INCY\n'
printf '# Сканируй этот QR в INCY\n'
printf '############################################################\n\n'
qrencode -t ANSIUTF8 -l M -m 1 "$LINK"

printf '\n============================================================\n'
printf 'Файл: %s/WARP-INCY.conf\n' "$WORK"
printf 'Также копия: %s/WARP-INCY.conf\n' "$OLDPWD"
printf 'Каждый запуск: новый WARP private key + новый reserved + новый I1.\n'
printf '============================================================\n'
printf 'INCY link (текстом, если QR не сканируется):\n%s\n' "$LINK"

cp WARP-INCY.conf "$OLDPWD/WARP-INCY.conf" 2>/dev/null || true
