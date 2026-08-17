#!/bin/bash
# ============================================================
#  codex-reauth.sh — аварийное восстановление общего Codex/ChatGPT-токена.
#  Порядок важен: простой `codex login --device-auth` не держится, если
#  на машине остались клиенты со старым (отозванным) refresh-токеном —
#  они ре-убивают свежий логин. Поэтому:
#   1) снять ВСЕ codex-клиенты (app-server/exec/login) у всех пользователей;
#   2) отодвинуть все auth.json (нет ревокнутого RT = нет reuse-detection);
#   3) интерактивный `codex login --device-auth` под coder
#      (браузерный шаг администратора под аккаунтом провайдера);
#   4) проверить живость реальным `codex exec` (ждём PONG);
#   5) раздать свежий auth.json всем; проверить под обычным юзером;
#   6) убрать .poison-бэкапы; напомнить про Reload Window в VSCode.
#
#  Запуск:  sudo codex-reauth.sh        # спросит подтверждение
#           sudo codex-reauth.sh -y     # без подтверждения
# ============================================================
set -u
LOG=/var/log/codex-auth-sync.log
TG=/usr/local/sbin/tg-send.sh
SRC=/home/coder/.codex/auth.json
LOCK=/var/lock/codex-auth-sync.lock
# --- блокировка выдачи токена отдельным учёткам ---
EXCLUDE_CONF=/etc/codex-auth-exclude.conf
is_auth_excluded() {
  [ -f "$EXCLUDE_CONF" ] || return 1
  awk -v u="$1" '$0 !~ /^[[:space:]]*#/ && $1 == u { found = 1 } END { exit !found }' "$EXCLUDE_CONF"
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[codex-reauth] $*"; }
logline() { echo "$(ts) reauth: $*" >> "$LOG"; }

[ "$(id -u)" -eq 0 ] || { echo "Запускать от root:  sudo codex-reauth.sh"; exit 1; }

YES=0
case "${1:-}" in -y|--yes) YES=1;; esac

if [ "$YES" -ne 1 ]; then
  echo "Это СНИМЕТ все codex-сессии у всех пользователей и перелогинит ОБЩИЙ аккаунт."
  echo "Понадобится браузерный шаг администратора. Продолжить?"
  read -r -p "[y/N] " ans
  case "$ans" in y|Y|yes|YES|да|ДА) ;; *) echo "Отменено."; exit 1;; esac
fi

# Не пересекаться с cron auth-sync
exec 9>"$LOCK"
flock -w 30 9 || { echo "Не удалось взять лок $LOCK (auth-sync работает?). Повторите через минуту."; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
logline "START (operator)"

say "1/6 Снимаю все codex-клиенты (app-server/exec/login) у всех…"
pkill -TERM -f 'codex app-server' 2>/dev/null || true
pkill -TERM -f 'codex exec --skip-git-repo-check ok' 2>/dev/null || true
sleep 2
pkill -KILL -f 'codex app-server' 2>/dev/null || true
pkill -KILL -f 'codex exec --skip-git-repo-check ok' 2>/dev/null || true
pkill -KILL -u coder -f 'codex login' 2>/dev/null || true
REMAIN=$(pgrep -f 'codex app-server' | wc -l)
say "    осталось app-server: $REMAIN"

say "2/6 Отодвигаю старые auth.json (.poison-$STAMP) — убираю «яд»…"
while IFS=: read -r name _ uid _ _ home _; do
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 2000 ] && [ -f "$home/.codex/auth.json" ]; then
    if is_auth_excluded "$name"; then say "    $name: пропущен (заблокирован)"; continue; fi
    mv -f "$home/.codex/auth.json" "$home/.codex/auth.json.poison-$STAMP" && say "    $name: отодвинут"
  fi
done < <(getent passwd)

say "3/6 Интерактивный device-auth под coder."
say "    -> Открой показанный URL, введи код, залогинься под ОБЩИМ аккаунтом."
echo "------------------------------------------------------------"
sudo -u coder -H bash -lc 'codex login --device-auth'
RC=$?
echo "------------------------------------------------------------"
if [ "$RC" -ne 0 ] || [ ! -f "$SRC" ]; then
  say "device-auth не удался (rc=$RC) или нет $SRC. Прерываю. Бэкапы лежат как *.poison-$STAMP"
  logline "device-auth FAILED rc=$RC"
  exit 1
fi

say "4/6 Проверяю живость нового токена (реальный codex exec)…"
PROBE="$(timeout 90 sudo -u coder -H bash -lc 'cd /home/coder && codex exec --skip-git-repo-check "reply with exactly: PONG" </dev/null 2>&1' || true)"
if ! printf '%s' "$PROBE" | grep -q 'PONG'; then
  say "Токен НЕ ожил (нет PONG) — возможно, ещё висят поджигатели или аккаунт во временной блокировке. Не раздаю. Хвост:"
  printf '%s\n' "$PROBE" | tail -n 6 | sed 's/^/    /'
  logline "post-login probe FAILED (no PONG)"
  exit 1
fi
say "    coder: PONG ✓"

say "5/6 Раздаю свежий auth.json всем (uid 1001..1999)…"
COUNT=0
while IFS=: read -r name _ uid _ _ home _; do
  if [ "$uid" -ge 1001 ] && [ "$uid" -lt 2000 ] && [ -d "$home" ]; then
    if is_auth_excluded "$name"; then say "    $name: ПРОПУЩЕН (заблокирован в $EXCLUDE_CONF)"; continue; fi
    install -d -m 700 -o "$name" -g "$name" "$home/.codex"
    install -o "$name" -g "$name" -m 600 "$SRC" "$home/.codex/auth.json"
    COUNT=$((COUNT+1))
  fi
done < <(getent passwd)
say "    роздано: $COUNT"

VUSER=$(getent passwd | awk -F: '$3>=1001 && $3<2000 {print $1; exit}')
if [ -n "$VUSER" ]; then
  say "    проверка под $VUSER…"
  VP="$(timeout 90 sudo -u "$VUSER" -H bash -lc 'cd ~ && codex exec --skip-git-repo-check "reply with exactly: PONG" </dev/null 2>&1' || true)"
  printf '%s' "$VP" | grep -q 'PONG' && say "    $VUSER: PONG ✓" || say "    $VUSER: PONG НЕ получен — проверь вручную"
fi

say "6/6 Убираю .poison-бэкапы…"
rm -f /home/*/.codex/auth.json.poison-"$STAMP"

logline "OK distributed to $COUNT users"
# Маркер для codex-monitor.sh: он считает свежесть раздачи грепом 'synced auth.json'
# по этому логу, а строку 'reauth: OK distributed' не знает — без этой строки 🔑-алерт
# продолжал лететь ежечасно до ближайшего планового auth-sync (до 6ч) уже ПОСЛЕ лечения.
echo "$(ts) synced auth.json to $COUNT users (via reauth)" >> "$LOG"
[ -x "$TG" ] && "$TG" "✅ CloudCodexServer: токен восстановлен (codex-reauth.sh) — роздан $COUNT польз., PONG ок. Кому открыт VSCode → Reload Window." || true

say "ГОТОВО — токен жив и роздан."
say "ВСЕМ с открытым VSCode: Ctrl+Shift+P → Reload Window (чтобы Codex поднялся со свежим токеном)."
