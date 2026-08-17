#!/bin/bash
# ============================================================
#  codex-autoreboot.sh — умная авто-перезагрузка для применения
#  обновлений (unattended-upgrades ставит патчи; ядро/libc требуют
#  перезагрузки). Перезагружает ТОЛЬКО если никто не работает.
#  Иначе откладывает на следующую ночь и шлёт уведомление в Telegram.
#  Запуск из cron в окне 04:00–05:00 Мск (01:00 UTC).
# ============================================================
set -u
LOG=/var/log/codex-autoreboot.log
STATE=/var/lib/codex-autoreboot.defercount
TG=/usr/local/sbin/tg-send.sh
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
notify() { [ -x "$TG" ] && "$TG" "$1" || true; }

# Нужна ли перезагрузка?
if [ ! -f /var/run/reboot-required ]; then
  rm -f "$STATE"
  echo "$(ts) перезагрузка не требуется" >> "$LOG"
  exit 0
fi
PKGS=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)

# Кто сейчас работает?
REASONS=()
# 1. Активные SSH-сессии (каждое подключение, в т.ч. VSCode Remote-SSH = "sshd: user@...")
SESSIONS=$(ps -eo args 2>/dev/null | grep -E 'sshd(-session)?: [^ ]+@' | grep -v grep | wc -l)
[ "$SESSIONS" -gt 0 ] && REASONS+=("активных SSH-сессий: $SESSIONS")
# 2. Запущенные серверы VS Code (кто-то подключён из VSCode)
VSCODE=$(pgrep -fc 'vscode-server' 2>/dev/null || echo 0)
[ "$VSCODE" -gt 0 ] && REASONS+=("VS Code активен: $VSCODE")
# 3. Запущенные процессы codex (идёт работа агента)
CODEXP=$(ps -eo args 2>/dev/null | grep -E '(^|/)codex( |$)' | grep -vE 'codex-(monitor|backup|auth-sync|add-user|token-check|autoreboot)' | grep -v grep | wc -l)
[ "$CODEXP" -gt 0 ] && REASONS+=("codex-процессов: $CODEXP")

if [ ${#REASONS[@]} -gt 0 ]; then
  # кто-то работает -> откладываем
  N=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$N" > "$STATE"
  echo "$(ts) отложено (день $N): ${REASONS[*]}" >> "$LOG"
  if [ "$N" -ge 5 ]; then
    notify "⚠️ CloudCodexServer: перезагрузка откладывается уже $N-й день — обновления (ядро/libc) не применены, т.к. кто-то постоянно подключён (${REASONS[*]}). Перезагрузите вручную в удобное время: sudo reboot. Ждут пакеты: ${PKGS}"
  else
    notify "🔁 CloudCodexServer: нужна перезагрузка для обновлений (${PKGS}), но идёт работа (${REASONS[*]}) — отложил на следующую ночь (попытка $N)."
  fi
  exit 0
fi

# Никто не работает -> перезагружаемся
rm -f "$STATE"
echo "$(ts) ПЕРЕЗАГРУЗКА (никто не подключён), пакеты: ${PKGS}" >> "$LOG"
notify "🔄 CloudCodexServer: применяю обновления безопасности и перезагружаюсь (никто не работает). Пакеты: ${PKGS}. Сервер вернётся через ~1 минуту."
sleep 5
/sbin/reboot
