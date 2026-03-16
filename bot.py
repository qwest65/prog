import json
import logging
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Set
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("miner_bot")

# Пользователь попросил вставить токен прямо в код.
TELEGRAM_TOKEN = os.environ.get(
    "TELEGRAM_TOKEN",
    "8257901403:AAF-ggYv3hkB6N-L9UDq_dGoNt-dydKZlOM",
)
MINER_BASE_URL = os.environ.get("MINER_BASE_URL", "https://vbypbaf7.shirin.keenetic.pro")
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))
REQUEST_TIMEOUT_SECONDS = int(os.environ.get("REQUEST_TIMEOUT_SECONDS", "10"))
ALERT_COOLDOWN_MINUTES = int(os.environ.get("ALERT_COOLDOWN_MINUTES", "10"))
ALLOWED_CHAT_IDS_RAW = os.environ.get("ALLOWED_CHAT_IDS", "")
ALLOWED_CHAT_IDS = {
    int(x.strip()) for x in ALLOWED_CHAT_IDS_RAW.split(",") if x.strip().isdigit()
}


@dataclass
class MinerStatus:
    online: bool
    hashrate: Optional[float]
    hashrate_unit: str
    temperature: Optional[float]
    temperature_unit: str
    errors: List[str]


class HttpClient:
    @staticmethod
    def get_json(url: str, timeout: int = 10) -> Any:
        request = Request(url, method="GET")
        with urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", errors="ignore"))

    @staticmethod
    def get_text(url: str, timeout: int = 10) -> str:
        request = Request(url, method="GET")
        with urlopen(request, timeout=timeout) as response:
            return response.read().decode("utf-8", errors="ignore")

    @staticmethod
    def post_json(url: str, payload: Dict[str, Any], timeout: int = 10) -> Any:
        encoded = urlencode(
            {k: json.dumps(v) if isinstance(v, (dict, list)) else v for k, v in payload.items()}
        ).encode("utf-8")
        request = Request(url, data=encoded, method="POST")
        with urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", errors="ignore"))


class MinerClient:
    def __init__(self, base_url: str, timeout: int = 10):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def get_status(self) -> MinerStatus:
        status = self._try_json_endpoints()
        if status:
            return status
        return self._try_html_fallback()

    def _try_json_endpoints(self) -> Optional[MinerStatus]:
        endpoints = [
            "/api/status",
            "/status",
            "/api/v1/status",
            "/summary",
            "/api/summary",
            "/cgi-bin/stats.cgi",
        ]
        for endpoint in endpoints:
            try:
                payload = HttpClient.get_json(f"{self.base_url}{endpoint}", timeout=self.timeout)
                return self._parse_payload(payload)
            except Exception:
                continue
        return None

    def _parse_payload(self, payload: Any) -> MinerStatus:
        flat = flatten_json(payload)
        hashrate = find_first_number(flat, ["hashrate", "ghs", "mhs", "khs", "hash_rate", "speed", "rate"])
        temperature = find_first_number(flat, ["temp", "temperature", "chip_temp", "board_temp"])
        errors = find_errors(flat)
        return MinerStatus(
            online=True,
            hashrate=hashrate,
            hashrate_unit=detect_hashrate_unit(flat),
            temperature=temperature,
            temperature_unit="°C",
            errors=errors,
        )

    def _try_html_fallback(self) -> MinerStatus:
        try:
            text = HttpClient.get_text(self.base_url, timeout=self.timeout)
            hashrate = extract_number_from_text(
                text,
                [
                    r"hashrate[^\d]*(\d+(?:[\.,]\d+)?)",
                    r"gh/s[^\d]*(\d+(?:[\.,]\d+)?)",
                    r"mhs[^\d]*(\d+(?:[\.,]\d+)?)",
                ],
            )
            temperature = extract_number_from_text(
                text,
                [r"temp(?:erature)?[^\d]*(\d+(?:[\.,]\d+)?)", r"°c[^\d]*(\d+(?:[\.,]\d+)?)"],
            )
            errors = []
            if re.search(r"error|fault|failed|critical", text, flags=re.IGNORECASE):
                errors.append("Обнаружены сообщения об ошибках на веб-странице")
            return MinerStatus(True, hashrate, "MH/s", temperature, "°C", errors)
        except Exception as exc:
            return MinerStatus(False, None, "MH/s", None, "°C", [f"Не удалось получить статус: {exc}"])


class TelegramBot:
    def __init__(self, token: str, miner_client: MinerClient):
        self.base_api = f"https://api.telegram.org/bot{token}"
        self.miner_client = miner_client
        self.offset = 0
        self.seen_chat_ids: Set[int] = set()
        self.last_zero_hashrate_alert: Optional[datetime] = None

    def run(self) -> None:
        logger.info("Bot started")
        last_check = datetime.min
        while True:
            try:
                updates = self.get_updates()
                for upd in updates:
                    self.handle_update(upd)
            except Exception as exc:
                logger.warning("Update loop error: %s", exc)

            now = datetime.utcnow()
            if (now - last_check).total_seconds() >= POLL_INTERVAL_SECONDS:
                self.monitor_hashrate()
                last_check = now

            time.sleep(1)

    def get_updates(self) -> List[Dict[str, Any]]:
        response = HttpClient.post_json(
            f"{self.base_api}/getUpdates",
            {"timeout": 25, "offset": self.offset},
            timeout=30,
        )
        if not response.get("ok"):
            return []
        result = response.get("result", [])
        if result:
            self.offset = result[-1]["update_id"] + 1
        return result

    def handle_update(self, update: Dict[str, Any]) -> None:
        if "message" in update:
            msg = update["message"]
            chat_id = msg.get("chat", {}).get("id")
            text = msg.get("text", "")
            if not chat_id:
                return
            self.seen_chat_ids.add(chat_id)
            if not is_allowed_chat(chat_id):
                return

            if text.startswith("/start"):
                self.send_message(chat_id, "Бот запущен. Нажмите кнопку для полного статуса.", keyboard())
            elif text.startswith("/status"):
                self.send_message(chat_id, format_status(self.miner_client.get_status()), keyboard())

        if "callback_query" in update:
            cb = update["callback_query"]
            cb_id = cb.get("id")
            chat_id = cb.get("message", {}).get("chat", {}).get("id")
            data = cb.get("data", "")

            if cb_id:
                self.answer_callback(cb_id)
            if not chat_id:
                return
            self.seen_chat_ids.add(chat_id)
            if not is_allowed_chat(chat_id):
                return

            if data == "status":
                self.send_message(chat_id, format_status(self.miner_client.get_status()), keyboard())

    def answer_callback(self, callback_query_id: str) -> None:
        try:
            HttpClient.post_json(
                f"{self.base_api}/answerCallbackQuery",
                {"callback_query_id": callback_query_id},
                timeout=10,
            )
        except Exception:
            pass

    def send_message(self, chat_id: int, text: str, reply_markup: Optional[Dict[str, Any]] = None) -> None:
        payload: Dict[str, Any] = {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "Markdown",
        }
        if reply_markup:
            payload["reply_markup"] = reply_markup

        try:
            HttpClient.post_json(f"{self.base_api}/sendMessage", payload, timeout=15)
        except (HTTPError, URLError) as exc:
            logger.warning("Failed to send message to %s: %s", chat_id, exc)

    def monitor_hashrate(self) -> None:
        status = self.miner_client.get_status()
        should_alert = status.online and status.hashrate is not None and status.hashrate <= 0
        cooldown_ok = (
            not self.last_zero_hashrate_alert
            or datetime.utcnow() - self.last_zero_hashrate_alert
            > timedelta(minutes=ALERT_COOLDOWN_MINUTES)
        )
        if should_alert and cooldown_ok:
            self.last_zero_hashrate_alert = datetime.utcnow()
            chats = ALLOWED_CHAT_IDS or self.seen_chat_ids
            for chat_id in chats:
                self.send_message(chat_id, "🚨 ВНИМАНИЕ: хешрейт майнера упал до 0!")


def keyboard() -> Dict[str, Any]:
    return {"inline_keyboard": [[{"text": "📊 Статус", "callback_data": "status"}]]}


def format_status(status: MinerStatus) -> str:
    if not status.online:
        return "🔴 Майнер недоступен"

    hashrate = "неизвестно" if status.hashrate is None else f"{status.hashrate:.2f} {status.hashrate_unit}"
    temperature = "неизвестно" if status.temperature is None else f"{status.temperature:.1f}{status.temperature_unit}"
    errors = "нет" if not status.errors else "\n".join(f"• {e}" for e in status.errors)

    return (
        "🟢 *Состояние майнера*\n"
        f"• Хешрейт: *{hashrate}*\n"
        f"• Температура: *{temperature}*\n"
        f"• Ошибки: {errors}"
    )


def is_allowed_chat(chat_id: int) -> bool:
    return not ALLOWED_CHAT_IDS or chat_id in ALLOWED_CHAT_IDS


def flatten_json(data: Any, prefix: str = "") -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if isinstance(data, dict):
        for key, value in data.items():
            new_prefix = f"{prefix}.{key}" if prefix else str(key)
            out.update(flatten_json(value, new_prefix))
    elif isinstance(data, list):
        for idx, value in enumerate(data):
            out.update(flatten_json(value, f"{prefix}[{idx}]"))
    else:
        out[prefix] = data
    return out


def find_first_number(flat: Dict[str, Any], keywords: List[str]) -> Optional[float]:
    for key, value in flat.items():
        if any(k in key.lower() for k in keywords):
            n = to_float(value)
            if n is not None:
                return n
    return None


def detect_hashrate_unit(flat: Dict[str, Any]) -> str:
    for key in flat.keys():
        key_low = key.lower()
        if "gh" in key_low:
            return "GH/s"
        if "mh" in key_low:
            return "MH/s"
        if "kh" in key_low:
            return "KH/s"
    return "MH/s"


def find_errors(flat: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    for key, value in flat.items():
        key_low = key.lower()
        if "error" in key_low or "fault" in key_low or "alarm" in key_low:
            if value not in (None, "", 0, "0", False, "ok", "OK"):
                errors.append(f"{key}: {value}")
    return errors[:10]


def to_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        match = re.search(r"-?\d+(?:[\.,]\d+)?", value.strip())
        if match:
            try:
                return float(match.group(0).replace(",", "."))
            except ValueError:
                return None
    return None


def extract_number_from_text(text: str, patterns: List[str]) -> Optional[float]:
    for pattern in patterns:
        m = re.search(pattern, text, flags=re.IGNORECASE)
        if m:
            return to_float(m.group(1))
    return None


def main() -> None:
    miner = MinerClient(MINER_BASE_URL, timeout=REQUEST_TIMEOUT_SECONDS)
    TelegramBot(TELEGRAM_TOKEN, miner).run()


if __name__ == "__main__":
    main()
