#!/usr/bin/env bash
set -Eeuo pipefail

AUTHOR_SCRIPT_URL="https://raw.githubusercontent.com/DikozImpact/bash-warp-generator/refs/heads/patch-1/warp_in_warp.sh"
WORK="${TMPDIR:-/tmp}/warp-incy.$(date +%s).$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

log(){ printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Old Debian 11 / h2.nexus can have an expired bullseye-security entry.
sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true

log "Проверяю зависимости"
missing=()
for c in wg jq wget curl base64 python3; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if ((${#missing[@]})); then
    apt update
    apt install -y wireguard-tools jq wget curl coreutils python3
fi

log "Запускаю авторский генератор WARP in WARP"
wget --inet4-only -qO warp_in_warp.sh "$AUTHOR_SCRIPT_URL"
chmod +x warp_in_warp.sh
bash ./warp_in_warp.sh

WARP_CONF="$(find . -maxdepth 1 -type f -name '*.conf' -print -quit)"
[ -n "$WARP_CONF" ] || die "Авторский генератор не создал WARP.conf"
cp "$WARP_CONF" author-WARP.conf

log "Проверяю генерацию"
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

# Fresh I1 on EVERY run, separately for each leg.
# Format: AmneziaWG CPS hex block.
log "Генерирую новые I1"
python3 - <<'PY'
from pathlib import Path
import secrets
for n in (1,2):
    Path(f'I1-{n}.txt').write_text('<b 0xc300000001'+secrets.token_hex(48)+'>\n')
PY

log "Формирую готовые AmneziaWG .conf для INCY"
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
Path('WARPNEW-SECOND-INCY.conf').write_text(render(o2,Path('I1-2.txt').read_text().strip(),1280,'WARPNEW in WARP'))
PY

# INCY supports incy://import/{base64-conf}. URL-safe Base64 is accepted.
B64_1="$(base64 -w0 WARPNEW-INCY.conf | tr '+/' '-_' | tr -d '=')"
B64_2="$(base64 -w0 WARPNEW-SECOND-INCY.conf | tr '+/' '-_' | tr -d '=')"

# One combined import: two AmneziaWG profiles in one base64 subscription body.
LINE1="amneziawg://${B64_1}#WARPNEW"
LINE2="amneziawg://${B64_2}#WARPNEW-SECOND"
COMBINED_B64="$(printf '%s\n%s\n' "$LINE1" "$LINE2" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

# Also provide a direct HTTPS download URL via the same public endpoint as the author.
DOWNLOAD_API='https://immalware.vercel.app/download'
DL1="${DOWNLOAD_API}?filename=WARPNEW-INCY.conf&content=${B64_1}"
DL2="${DOWNLOAD_API}?filename=WARPNEW-SECOND-INCY.conf&content=${B64_2}"

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' 'ГОТОВО — INCY'
printf '%s\n' '============================================================'
printf '%s\n' 'Готовая ссылка INCY для первого WARP:'
printf '%s\n' "incy://import/${B64_1}"
printf '\n%s\n' 'Готовая ссылка INCY для второго WARP:'
printf '%s\n' "incy://import/${B64_2}"
printf '\n%s\n' 'ОДНА ссылка с двумя AmneziaWG-профилями:'
printf '%s\n' "incy://import/${COMBINED_B64}"
printf '\n%s\n' 'Прямые HTTPS-ссылки на .conf:'
printf '%s\n' "$DL1"
printf '%s\n' "$DL2"
printf '\n%s\n' 'Файлы также сохранены в текущем каталоге:'
printf '%s\n' '  WARPNEW-INCY.conf'
printf '%s\n' '  WARPNEW-SECOND-INCY.conf'
printf '%s\n' '============================================================'
printf '%s\n' 'Важно: raw .conf = один профиль. Сам detour WARP-in-WARP внутри'
printf '%s\n' 'одного AmneziaWG .conf не задаётся; комбинированная ссылка импортирует'
printf '%s\n' 'два отдельных профиля.'
printf '%s\n' '============================================================'
