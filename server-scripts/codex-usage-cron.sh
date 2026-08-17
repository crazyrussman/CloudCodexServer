#!/bin/bash
# codex-usage-cron.sh — регенерация usage-дашборда по расписанию.
# Запуск от root (нужно читать ~/.codex всех). Права выставляются «только caddy».
set -euo pipefail

export USAGE_WEBROOT=/var/www/codex-usage
export USAGE_STATE=/var/lib/codex-usage
# Логин администратора дашборда (видит имена сотрудников и клиентов).
# ОБЯЗАТЕЛЬНО заменить на свою учётку.
export USAGE_ADMIN=admin

/usr/bin/python3 /usr/local/sbin/codex-usage-report.py >> /var/log/codex-usage.log 2>&1

# webroot читает ТОЛЬКО caddy (у сотрудников есть shell — мимо Caddy читать нельзя)
chown -R caddy:caddy "$USAGE_WEBROOT"
chmod -R u=rwX,g=,o= "$USAGE_WEBROOT"
# state — только root
chmod 700 "$USAGE_STATE" 2>/dev/null || true

echo "$(date -u +%FT%TZ) usage-report regenerated" >> /var/log/codex-usage.log
