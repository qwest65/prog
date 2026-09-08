#!/usr/bin/env bash
set -Eeuo pipefail

# One-command WARP-in-WARP -> INCY QR generator.
# Run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/qwest65/prog/main/warp-incy-qr.sh)
#
# It downloads the current warp-incy.sh generator, runs it, extracts the two
# generated INCY deep links, and displays QR codes directly in the terminal.

BASE_URL="https://raw.githubusercontent.com/qwest65/prog/main/warp-incy.sh"
TMP="${TMPDIR:-/tmp}/warp-incy-qr.$$.txt"
trap 'rm -f "$TMP"' EXIT

if ! command -v qrencode >/dev/null 2>&1; then
  if [ -f /etc/apt/sources.list ]; then
    sed -i '/bullseye-security/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
  fi
  apt update
  apt install -y qrencode
fi

command -v curl >/dev/null 2>&1 || {
  apt update && apt install -y curl
}

# Execute the generator and capture its output. The generator itself creates
# fresh Cloudflare WARP registrations/private keys and fresh I1 values.
curl -fsSL "$BASE_URL" | bash | tee "$TMP"

# Extract complete INCY import deep links. The base64 payload is one line.
mapfile -t LINKS < <(grep -E '^incy://import/' "$TMP" || true)

if [ "${#LINKS[@]}" -lt 2 ]; then
  echo
  echo "ERROR: Не найдено две INCY-ссылки в выводе генератора."
  echo "Покажи этот вывод — проверим формат импорта."
  exit 1
fi

# Force terminal-friendly rendering. ANSIUTF8 works in the h2.nexus browser
# terminal and can be scanned from a phone camera.
show_qr() {
  local title="$1"
  local data="$2"
  echo
  echo "============================================================"
  echo "$title"
  echo "============================================================"
  qrencode -t ANSIUTF8 -m 1 -l L "$data"
  echo "============================================================"
}

show_qr "QR 1 — WARPNEW" "${LINKS[0]}"
show_qr "QR 2 — WARPNEW in WARP" "${LINKS[1]}"

echo

echo "Сканируй QR-коды камерой/сканером INCY."
echo "Каждый запуск создаёт новые WARP private keys, reserved и новые I1."
echo
