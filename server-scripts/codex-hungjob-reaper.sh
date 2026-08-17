#!/usr/bin/env bash
# codex-hungjob-reaper.sh — жнец зависших/запрещённых браузерных джобов.
#
# Зачем: браузерная автоматизация (headless Chrome, Playwright), запущенная
# агентом, умеет зависать и удерживать гигабайты памяти неограниченно долго.
# Перезапускает такой джоб обычно не человек, а АГЕНТ в открытой сессии —
# поэтому правило в его инструкциях не действует, пока сессия не закрыта.
# Жнец закрывает окно между «правило написано» и «сессия перезапущена».
#
# Две независимые ветки:
#   1. BLOCKLIST — команды, которым на сервере быть не должно (regex в конфиге).
#      Снимаются при каждом появлении, как только прожили BLOCK_GRACE_MIN.
#   2. Гигиена браузеров — chrome-headless-shell / chrome / chromium / Xvfb,
#      прожившие дольше BROWSER_MAX_MIN. Забытые браузеры живут неделями
#      и жгут CPU впустую — на глаз это не заметно, счётчик показывает.
#
# Что НИКОГДА не трогает: процессы root, VSCode-сервер, codex app-server
# расширения (иначе убьём живую сессию сотрудника), pid 1.
# Сигнал только TERM: дерево снимается корректно, SIGKILL не нужен.
#
# Откат: rm -f /etc/cron.d/codex-hungjob-reaper
# Проверка вхолостую: DRY_RUN=1 /usr/local/sbin/codex-hungjob-reaper.sh

set -uo pipefail

LOG=/var/log/codex-hungjob-reaper.log
TG=/usr/local/sbin/tg-send.sh
BLOCKLIST_FILE=/etc/codex-hungjob-blocklist.conf

BLOCK_GRACE_MIN=${BLOCK_GRACE_MIN:-5}     # сколько дать запрещённому джобу до снятия
BROWSER_MAX_MIN=${BROWSER_MAX_MIN:-60}    # предел жизни headless-браузера
DRY_RUN=${DRY_RUN:-0}

TS() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(TS) $*" >>"$LOG"; }

# --- защита: кого не трогаем ни при каких условиях -------------------------
is_protected() {
  local pid="$1" args uid
  [ -z "$pid" ] && return 0
  [ "$pid" -le 1 ] 2>/dev/null && return 0
  uid=$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$uid" ] && return 0          # процесс уже ушёл — считаем защищённым
  [ "$uid" = "0" ] && return 0       # root не трогаем
  args=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
  case "$args" in
    *".vscode-server/cli/servers"*)  return 0 ;;  # сам VSCode-сервер
    *"bin/linux-x86_64/codex"*)      return 0 ;;  # codex app-server расширения
    *"/usr/local/sbin/"*)            return 0 ;;  # наши же скрипты
  esac
  return 1
}

# --- возраст процесса в секундах -------------------------------------------
etime_sec() { ps -o etimes= -p "$1" 2>/dev/null | tr -d ' '; }

# --- все потомки pid (рекурсивно) ------------------------------------------
descendants() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    echo "$kid"
    descendants "$kid"
  done
}

# --- обёртки-предки, которые надо снять вместе с джобом ---------------------
# ВАЖНО: --die-with-parent у bwrap смотрит на обёртку песочницы, которую pkill
# по имени скрипта не трогает → снимать надо всю цепочку предков вверх
# до первого «настоящего» родителя (codex app-server / VSCode / shell сессии).
wrapper_ancestors() {
  local pid="$1" parent args
  while :; do
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] && break
    is_protected "$parent" && break
    args=$(tr '\0' ' ' <"/proc/$parent/cmdline" 2>/dev/null)
    case "$args" in
      *bwrap*|*codex-linux-sandbox*|*"bash -lc"*|*"sh -c"*|*"npm exec"*)
        echo "$parent"; pid="$parent" ;;
      *) break ;;
    esac
  done
}

# --- сбор мишеней ----------------------------------------------------------
declare -A KILL=()      # pid -> причина
add_target() {
  local pid="$1" reason="$2" p
  is_protected "$pid" && return
  KILL["$pid"]="$reason"
  for p in $(descendants "$pid"); do
    is_protected "$p" || KILL["$p"]="$reason (потомок $pid)"
  done
  for p in $(wrapper_ancestors "$pid"); do
    KILL["$p"]="$reason (обёртка $pid)"
  done
}

# 1. Запрещённые команды
if [ -r "$BLOCKLIST_FILE" ]; then
  while IFS= read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    for pid in $(pgrep -f "$pattern" 2>/dev/null); do
      age=$(etime_sec "$pid"); [ -z "$age" ] && continue
      [ "$age" -lt $((BLOCK_GRACE_MIN * 60)) ] && continue
      add_target "$pid" "blocklist:${pattern}"
    done
  done <"$BLOCKLIST_FILE"
fi

# 2. Долгоживущие headless-браузеры
for pid in $(pgrep -f 'chrome-headless-shell|chrome_crashpad|/chromium|Xvfb' 2>/dev/null); do
  age=$(etime_sec "$pid"); [ -z "$age" ] && continue
  [ "$age" -lt $((BROWSER_MAX_MIN * 60)) ] && continue
  add_target "$pid" "browser>${BROWSER_MAX_MIN}min"
done

# --- снятие ----------------------------------------------------------------
if [ ${#KILL[@]} -eq 0 ]; then
  exit 0
fi

killed=0
declare -A VICTIMS=()
for pid in "${!KILL[@]}"; do
  owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
  cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-90)
  [ -z "$owner" ] && continue
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN would TERM pid=$pid user=$owner reason=${KILL[$pid]} cmd=$cmd"
  else
    kill -TERM "$pid" 2>/dev/null && {
      log "TERM pid=$pid user=$owner reason=${KILL[$pid]} cmd=$cmd"
      killed=$((killed + 1))
      VICTIMS["$owner"]=1
    }
  fi
done

if [ "$DRY_RUN" != "1" ] && [ "$killed" -gt 0 ]; then
  who="${!VICTIMS[*]}"
  log "summary: снято процессов=$killed, юзеры=$who"
  [ -x "$TG" ] && "$TG" "🧹 Жнец: снято $killed зависших/запрещённых процессов (${who}). Подробности: $LOG" || true
fi

exit 0
