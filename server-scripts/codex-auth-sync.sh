#!/bin/bash
# ============================================================
#  Codex auth sync — держит общий ChatGPT-токен валидным у всех.
#  coder = единственный, кто реально обновляет (refresh) токен;
#  всем остальным раскладывается его свежий auth.json, чтобы
#  при ротации refresh-токена никого не выбивало.
#  Запускается из cron каждые 6 часов (см. /etc/cron.d/codex-auth-sync).
#
#  Требования к пробе (важно для надёжности):
#   • проба токена ОГРАНИЧЕНА по времени (timeout) и со ЗАКРЫТЫМ stdin —
#     иначе `codex exec` может зависнуть на минуты и заклинить раздачу;
#   • если токен мёртв — НЕ раздаём (чтобы не затереть свежий токен,
#     который мог появиться у кого-то), а шлём алерт с командой лечения;
#   • лечение одной командой:  sudo codex-reauth.sh
#   • flock — чтобы не пересекаться с другим запуском / с codex-reauth.sh.
# ============================================================
set -u
LOG=/var/log/codex-auth-sync.log
TG=/usr/local/sbin/tg-send.sh
SRC=/home/coder/.codex/auth.json
LOCK=/var/lock/codex-auth-sync.lock
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# --- блокировка выдачи токена отдельным учёткам ---
EXCLUDE_CONF=/etc/codex-auth-exclude.conf
is_auth_excluded() {
  [ -f "$EXCLUDE_CONF" ] || return 1
  awk -v u="$1" '$0 !~ /^[[:space:]]*#/ && $1 == u { found = 1 } END { exit !found }' "$EXCLUDE_CONF"
}


# Не пересекаться с другим auth-sync / с codex-reauth.sh
exec 9>"$LOCK"
flock -n 9 || { echo "$(ts) skipped: lock held (другой auth-sync/reauth?)" >> "$LOG"; exit 0; }

# 1. РЕАЛЬНАЯ проба токена под coder. Bounded (timeout) + закрытый stdin —
#    иначе codex exec может зависнуть (websocket-retry / ожидание stdin).
#    Просим PONG — это даёт ПОЗИТИВНЫЙ признак живости, а не только поиск сигнатур отказа.
PROBE="$(timeout 90 sudo -u coder -H bash -lc 'codex exec --skip-git-repo-check "reply with exactly: PONG" </dev/null 2>&1' || true)"

# ВАЖНО — почему проба ищет ПОЗИТИВНЫЙ признак (PONG), а не сигнатуры отказа:
#   при рассинхроне версии CLI со схемой API клиент способен вывалить в stderr весь
#   ответ /models — сотни КБ системных инструкций, внутри которых встречаются фразы
#   вроде "already used".
#   Греп по сырому выводу принимал это за отказ refresh-токена → ALERT + skip distribute
#   при полностью живом токене (раздача молча стояла до ручного вмешательства).
# Поэтому: сигнатуры отказа ищем только в ОЧИЩЕННОМ выводе —
#   выбрасываем строки шумных логгеров и режем каждую строку до 500 символов
#   (настоящие сообщения об отказе короткие; дамп тела ответа — нет).
PROBE_CLEAN="$(printf '%s\n' "$PROBE" | grep -v -E 'codex_models_manager|failed to (refresh|decode) (available )?models' | cut -c1-500)"

# Живость: ответ реально получен (PONG). Приоритет — у позитивного признака.
ALIVE=0
printf '%s' "$PROBE" | grep -q 'PONG' && ALIVE=1

if [ "$ALIVE" -eq 0 ] && printf '%s' "$PROBE_CLEAN" | grep -qiE 'token_invalidated|refresh_token_invalidated|app_session_terminated|could not be refreshed|already used|revoked|session has ended|401 Unauthorized'; then
  # Режим отказа (для лога и алерта)
  MODE_DESC="сессия отозвана (веб-логаут / reuse-detection)"
  printf '%s' "$PROBE_CLEAN" | grep -qi 'already used' && MODE_DESC="refresh-токен 'already used' (гонка ротации общего токена)"
  # «Поджигатели»: запущенные codex app-server держат ревокнутый refresh-токен
  # и reuse-detection'ом ре-убивают любой свежий логин — их надо снять (это делает codex-reauth.sh).
  POISON="$(ps -eo user,cmd | grep -E 'codex app-server' | grep -v grep | awk '{print $1}' | sort -u | tr '\n' ' ')"
  echo "$(ts) ALERT: token of shared ChatGPT account is DEAD — $MODE_DESC" >> "$LOG"
  printf '%s\n' "$PROBE_CLEAN" | tail -n 6 | sed 's/^/    /' >> "$LOG"
  [ -n "$POISON" ] && echo "    poison app-server у: $POISON" >> "$LOG"
  echo "$(ts) skip distribute (token dead)" >> "$LOG"
  MSG="🚨 CloudCodexServer: общий Codex/ChatGPT-токен МЁРТВ — команда не может работать.
Режим: $MODE_DESC
ЛЕЧЕНИЕ одной командой:  sudo codex-reauth.sh
(снимет codex-клиенты, перелогинит — нужен браузерный шаг владельца под ОБЩИМ аккаунтом — раздаст всем и проверит PONG)"
  [ -n "$POISON" ] && MSG="$MSG
⚠️ Сейчас висят app-server у: ${POISON}— они ре-убивают любой свежий логин; codex-reauth.sh их снимет."
  [ -x "$TG" ] && "$TG" "$MSG" || true
  exit 0
fi

# 1b. Ни PONG, ни сигнатур отказа (сеть/таймаут/новый формат ошибки) — не молчим,
#     но и не объявляем смерть: раздаём как раньше и оставляем след в логе для разбора.
if [ "$ALIVE" -eq 0 ]; then
  echo "$(ts) warn: PONG не получен, но сигнатур отказа нет — раздаю (проверить вручную)" >> "$LOG"
  printf '%s\n' "$PROBE_CLEAN" | tail -n 6 | sed 's/^/    /' >> "$LOG"
fi

# 2. Токен жив — раскладываем свежий auth.json всем обычным пользователям (uid 1001..1999, кроме coder)
if [ ! -f "$SRC" ]; then
  echo "$(ts) ERROR: $SRC missing" >> "$LOG"
  exit 1
fi
COUNT=0
while IFS=: read -r name _ uid _ _ home _; do
  if [ "$uid" -ge 1001 ] && [ "$uid" -lt 2000 ] && [ -d "$home" ]; then
    if is_auth_excluded "$name"; then
      echo "$(ts) skip $name (заблокирован в $EXCLUDE_CONF)" >> "$LOG"
      continue
    fi
    install -d -m 700 -o "$name" -g "$name" "$home/.codex"
    install -o "$name" -g "$name" -m 600 "$SRC" "$home/.codex/auth.json"
    COUNT=$((COUNT+1))
  fi
done < <(getent passwd)

echo "$(ts) synced auth.json to $COUNT users" >> "$LOG"
