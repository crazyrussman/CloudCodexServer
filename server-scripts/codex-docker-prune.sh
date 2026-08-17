#!/bin/bash
# ============================================================
#  codex-docker-prune.sh — еженедельная очистка неиспользуемых
#  docker-данных (образы без контейнеров, остановленные контейнеры,
#  build-кэш). Системный docker (root) + rootless у каждого пользователя.
#  Запускается из cron раз в неделю.
# ============================================================
set -u
LOG=/var/log/codex-docker-prune.log
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "$(ts) prune start" >> "$LOG"

# Системный docker (им пользуются coder, администраторы и root)
if command -v docker >/dev/null 2>&1; then
  docker system prune -f >> "$LOG" 2>&1 || true
fi

# Rootless docker у каждого изолированного пользователя (uid>=1001)
while IFS=: read -r uname _ uid _ _ uhome _; do
  if [ "$uid" -ge 1001 ] && [ "$uid" -lt 2000 ] && [ -S "/run/user/$uid/docker.sock" ]; then
    sudo -u "$uname" env \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
      docker system prune -f >> "$LOG" 2>&1 || true
  fi
done < <(getent passwd)

echo "$(ts) prune done" >> "$LOG"
