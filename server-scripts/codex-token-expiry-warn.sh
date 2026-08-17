#!/bin/bash
# ============================================================
#  codex-token-expiry-warn.sh — превентивное предупреждение о смерти
#  общего Codex-токена.
#
#  Зачем: access-токен живёт ограниченное время (порядка недели-полутора).
#  Без предупреждения о смерти узнают пост-фактум — auth-sync ловит её
#  раз в 6 часов, и всё это время команда простаивает.
#  Сторож читает реальный `exp` из JWT и предупреждает ЗАРАНЕЕ, чтобы
#  токен перевыпустили в удобное время, без простоя.
#
#  Ключевое свойство: дата НЕ захардкожена — берётся из auth.json.
#  После каждого `codex-reauth.sh` сторож сам начинает считать новый срок,
#  править его не нужно.
#
#  Запуск: cron раз в сутки (см. /etc/cron.d/codex-token-expiry-warn).
#          codex-token-expiry-warn.sh --test  — разовая проверка без
#          записи анти-спам-состояния (печатает, что бы отправил).
# ============================================================
set -u

SRC=/home/coder/.codex/auth.json
TG=/usr/local/sbin/tg-send.sh
LOG=/var/log/codex-monitor.log
STATE=/var/lib/codex/token-expiry-warned
WARN_HOURS=30          # предупреждать, когда до смерти <= 30ч (застаёт вечер накануне)

TEST=0
[ "${1:-}" = "--test" ] && TEST=1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { echo "$(ts) expiry-warn: $*" >> "$LOG"; }

[ -f "$SRC" ] || { logline "нет $SRC — пропуск"; exit 0; }

# Достаём exp из access-токена (JWT: header.payload.signature, payload — base64url)
EXP=$(python3 - "$SRC" <<'PY' 2>/dev/null
import json, base64, sys
try:
    d = json.load(open(sys.argv[1]))
    tok = d.get("tokens", {}).get("access_token")
    if not tok:
        sys.exit(1)
    p = tok.split(".")[1]
    p += "=" * (-len(p) % 4)
    print(json.loads(base64.urlsafe_b64decode(p))["exp"])
except Exception:
    sys.exit(1)
PY
)

if [ -z "${EXP:-}" ]; then
  logline "не смог разобрать exp из auth.json — пропуск"
  exit 0
fi

NOW=$(date -u +%s)
LEFT=$(( EXP - NOW ))
LEFT_H=$(( LEFT / 3600 ))
EXP_HUMAN=$(date -u -d "@$EXP" +"%Y-%m-%d %H:%MZ")

if [ "$TEST" -eq 1 ]; then
  echo "exp=$EXP_HUMAN, осталось ${LEFT_H}ч, порог ${WARN_HOURS}ч"
fi

# Уже мёртв — это зона ответственности auth-sync/monitor, не дублируем алерт
if [ "$LEFT" -le 0 ]; then
  [ "$TEST" -eq 1 ] && echo "→ токен уже истёк, молчу (это ловит auth-sync)"
  exit 0
fi

# Ещё рано
if [ "$LEFT_H" -gt "$WARN_HOURS" ]; then
  [ "$TEST" -eq 1 ] && echo "→ рано, молчу"
  exit 0
fi

# Анти-спам: одно предупреждение на один срок (после reauth exp меняется — предупредим снова)
mkdir -p "$(dirname "$STATE")"
PREV=$(cat "$STATE" 2>/dev/null || echo "")
if [ "$PREV" = "$EXP" ]; then
  [ "$TEST" -eq 1 ] && echo "→ по этому сроку уже предупреждали, молчу"
  exit 0
fi

MSG="⏳ CloudCodexServer: общий Codex-токен умрёт через ~${LEFT_H}ч (${EXP_HUMAN}).

Перевыпустите ЗАРАНЕЕ, в удобное время — иначе команда встанет:
  ssh <SERVER>
  sudo codex-reauth.sh

Нужен браузерный шаг под общим аккаунтом (~1 мин).
После — всем: Ctrl+Shift+P → Reload Window."

if [ "$TEST" -eq 1 ]; then
  echo "→ ОТПРАВИЛ БЫ:"
  echo "$MSG"
  exit 0
fi

if [ -x "$TG" ] && "$TG" "$MSG"; then
  echo "$EXP" > "$STATE"
  logline "предупреждение отправлено (осталось ${LEFT_H}ч, exp $EXP_HUMAN)"
else
  logline "ОШИБКА отправки предупреждения (exp $EXP_HUMAN) — повторю в следующий прогон"
fi
