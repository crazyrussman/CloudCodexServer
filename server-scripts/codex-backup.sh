#!/bin/bash
# ============================================================
#  codex-backup.sh — резервная копия данных пользователей в S3-совместимое
#  хранилище через restic. Шифрование + дедупликация + инкрементальные
#  снапшоты. Запускается из cron.
#
#  Что бэкапится:
#    - ~/projects всех пользователей (код)
#    - docker-тома rootless-докера ~/.local/share/docker/volumes
#      (БД/данные приложений, напр. sqlite)
#    - кастом агента: ~/.codex/skills, ~/.codex/config.toml
#    - выученная память: ~/.codex/{memories,goals,state}_*.sqlite,
#      ~/.agentmemory/data (накопленные знания; логи Codex НЕ берём)
#    - dotfiles: ~/.config (кроме браузерных профилей), ~/.bashrc
#
#  Использование:
#    codex-backup.sh           # инкрементальный бэкап + ретеншн (ночью)
#    codex-backup.sh prune     # реальная очистка места (раз в неделю)
# ============================================================
set -u
ENVFILE=/etc/restic/env
EXCLUDES=/etc/restic/excludes.txt
LOG=/var/log/codex-backup.log
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

[ -f "$ENVFILE" ] || { echo "$(ts) ERROR: нет $ENVFILE" >> "$LOG"; exit 1; }
# shellcheck disable=SC1090
source "$ENVFILE"

MODE="${1:-backup}"

if [ "$MODE" = "prune" ]; then
  echo "$(ts) prune start" >> "$LOG"
  restic prune --max-unused 10% >> "$LOG" 2>&1
  echo "$(ts) prune done (rc=$?)" >> "$LOG"
  exit 0
fi

# Собрать пути всех пользователей: код + данные + кастом Codex + dotfiles
PATHS=()
for d in /home/*/projects; do [ -d "$d" ] && PATHS+=("$d"); done
for d in /home/*/.local/share/docker/volumes; do [ -d "$d" ] && PATHS+=("$d"); done
for d in /home/*/.codex/skills; do [ -d "$d" ] && PATHS+=("$d"); done
for d in /home/*/.agentmemory/data; do [ -d "$d" ] && PATHS+=("$d"); done
for d in /home/*/.config; do [ -d "$d" ] && PATHS+=("$d"); done
# ledger истории расхода Codex (переживает чистку сессий) + конфиг дашборда
[ -d /var/lib/codex-usage ] && PATHS+=("/var/lib/codex-usage")
# выученная память Codex (memories/goals/state); логи (logs_*) намеренно НЕ берём — регенерируемые и крупные
for f in /home/*/.codex/config.toml /home/*/.bashrc \
         /home/*/.codex/memories_*.sqlite* /home/*/.codex/goals_*.sqlite* /home/*/.codex/state_*.sqlite*; do
  [ -f "$f" ] && PATHS+=("$f")
done
if [ ${#PATHS[@]} -eq 0 ]; then echo "$(ts) нет папок для бэкапа" >> "$LOG"; exit 0; fi

echo "$(ts) backup start: ${PATHS[*]}" >> "$LOG"
restic backup "${PATHS[@]}" --exclude-file="$EXCLUDES" --tag nightly >> "$LOG" 2>&1
RC=$?
echo "$(ts) backup done (rc=$RC)" >> "$LOG"

# Ретеншн. --group-by host: все снимки хоста считаются ОДНОЙ группой
# независимо от набора путей (иначе при добавлении юзеров/путей меняется
# состав группы и старые снимки перестают подчищаться).
restic forget --group-by host --keep-daily 14 --keep-weekly 8 --keep-monthly 6 >> "$LOG" 2>&1
echo "$(ts) forget done (rc=$?)" >> "$LOG"
exit $RC
