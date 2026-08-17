#!/bin/bash
# ============================================================
#  tg-send.sh — отправка сообщения в Telegram.
#  Использование: tg-send.sh "текст сообщения"
#  Конфиг: /etc/telegram/env (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
# ============================================================
set -u
ENV=/etc/telegram/env
[ -f "$ENV" ] || { echo "tg-send: нет $ENV (Telegram не настроен)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
TEXT="${1:-}"
[ -z "$TEXT" ] && exit 0
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && { echo "tg-send: нет токена"; exit 1; }
[ -z "${TELEGRAM_CHAT_ID:-}" ]  && { echo "tg-send: нет chat_id"; exit 1; }

curl -s --max-time 20 \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode text="${TEXT}" \
  -d disable_web_page_preview=true \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
