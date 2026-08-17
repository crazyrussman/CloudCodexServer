#!/bin/bash
# ============================================================
#  codex-block-watch.sh — принудительное соблюдение блокировки Codex.
#  Зачем: изъятия auth.json мало. Обходные пути, которые закрывает сторож:
#    • CODEX_HOME=~/.codex2 + codex login под личной учёткой ChatGPT;
#    • свой npm-установленный codex;
#    • переустановка VSCode-расширения (новая папка = новый бинарь).
#  Работает по принципу жнеца (codex-hungjob-reaper.sh): крон + TERM + Telegram.
#
#  Кого блокировать — /etc/codex-auth-exclude.conf (тот же файл, что у auth-sync).
#  Снять: убрать учётку из конфига (сторож перечитывает на каждом прогоне).
#  Откат целиком: rm -f /etc/cron.d/codex-block-watch
# ============================================================
set -u
CONF=/etc/codex-auth-exclude.conf
LOG=/var/log/codex-block-watch.log
TG=/usr/local/sbin/tg-send.sh
STATE=/var/lib/codex-block-watch.state
SPAM_MIN=60          # не чаще одного алерта в час на одну сигнатуру
DRY_RUN="${DRY_RUN:-0}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >> "$LOG"; }

[ -f "$CONF" ] || exit 0
USERS=$(awk '$0 !~ /^[[:space:]]*#/ && NF { print $1 }' "$CONF")
[ -n "$USERS" ] || exit 0

install -d -m 755 "$(dirname "$STATE")"
touch "$STATE"

notify() {  # $1 = ключ сигнатуры, $2 = текст
  local key="$1" text="$2" now last
  now=$(date -u +%s)
  last=$(awk -v k="$key" '$1 == k { print $2 }' "$STATE" | tail -1)
  if [ -n "${last:-}" ] && [ $(( (now - last) / 60 )) -lt "$SPAM_MIN" ]; then return 0; fi
  grep -v "^$key " "$STATE" > "$STATE.tmp" 2>/dev/null || true
  echo "$key $now" >> "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
  [ -x "$TG" ] && "$TG" "$text" >/dev/null 2>&1 || true
}

for u in $USERS; do
  id "$u" >/dev/null 2>&1 || continue

  HOME_DIR=$(getent passwd "$u" | cut -d: -f6)
  [ -d "$HOME_DIR" ] || continue

  # 1) Живые codex-процессы. ВАЖНО: процесс расширения БЕЗ токена инертен —
  #    он не может сделать ни одного вызова к API, и убивать его каждые 2 минуты
  #    бессмысленно (мгновенно перезапускается). Снимаем только реальные обходы:
  #      а) codex с уведённым CODEX_HOME (мимо заблокированной заглушки);
  #      б) попытку `codex login` (иначе доведёт device-auth под личной учёткой).
  PIDS=$(pgrep -u "$u" -f 'codex(-code-mode-host|-linux-sandbox)?( |$)|/codex exec|codex app-server|codex login' 2>/dev/null || true)
  for pid in $PIDS; do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-160)
    [ -n "$cmd" ] || continue
    case "$cmd" in
      *".vscode-server/bin/"*|*"/node "*"server-main.js"*) continue ;;   # сам VSCode не трогаем
    esac

    reason=""
    ch=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CODEX_HOME=//p' | head -1)
    if [ -n "${ch:-}" ] && [ "$ch" != "$HOME_DIR/.codex" ]; then
      reason="CODEX_HOME=$ch (мимо заблокированного пути)"
    fi
    case "$cmd" in
      *"codex login"*|*"login --device-auth"*) reason="попытка codex login" ;;
    esac
    [ -n "$reason" ] || continue    # инертный процесс без токена — оставляем

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY: снял бы pid=$pid user=$u [$reason] cmd=$cmd"
    else
      kill -TERM "$pid" 2>/dev/null || true
      log "TERM pid=$pid user=$u [$reason] cmd=$cmd"
      notify "proc-$u" "🚫 Codex-блокировка: у $u снят обход — $reason (pid $pid)."
    fi
  done

  # 1b) Заглушка потеряла неизменяемый флаг = блокировка снята не по процедуре.
  PH="$HOME_DIR/.codex/auth.json"
  if [ -e "$PH" ] && ! lsattr -d "$PH" 2>/dev/null | cut -d' ' -f1 | grep -q 'i'; then
    log "WARN user=$u: с заглушки $PH снят флаг +i"
    notify "immutable-$u" "⚠️ Codex-блокировка: у $u с заглушки auth.json снят флаг неизменяемости. Проверить, кто и зачем."
  fi

  # 2) Появившиеся auth.json мимо заблокированной заглушки (альтернативный CODEX_HOME).
  FOUND=$(find "$HOME_DIR" -maxdepth 3 -name 'auth.json' ! -path "$HOME_DIR/.codex/auth.json" 2>/dev/null | head -5)
  if [ -n "$FOUND" ]; then
    log "ALT-AUTH user=$u: $(echo "$FOUND" | tr '\n' ' ')"
    notify "auth-$u" "🚫 Codex-блокировка: у $u найден auth.json вне заблокированного пути — похоже на обход через CODEX_HOME:
$FOUND"
  fi
done

exit 0
