#!/bin/bash
# codex-usage-cron.sh — регенерация usage-дашборда по расписанию.
# Запуск от root (нужно читать ~/.codex всех). Права выставляются «только caddy».
set -euo pipefail

export USAGE_WEBROOT=/var/www/codex-usage
export USAGE_STATE=/var/lib/codex-usage

# USAGE_ADMIN берётся из общего env-файла, а НЕ прописывается здесь:
# этот скрипт лежит в /usr/local/sbin и перезаписывается при каждом обновлении,
# так что локальная правка молча вернулась бы к дефолту, а часовая регенерация
# начала бы отдавать обезличенный борд настоящему администратору.
ACCOUNT_ENV=/etc/codex-usage-account.env
if [ -r "$ACCOUNT_ENV" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$ACCOUNT_ENV"
	set +a
fi
: "${USAGE_ADMIN:?USAGE_ADMIN не задан — впишите его в $ACCOUNT_ENV}"

/usr/bin/python3 /usr/local/sbin/codex-usage-report.py >> /var/log/codex-usage.log 2>&1

# webroot читает ТОЛЬКО caddy (у сотрудников есть shell — мимо Caddy читать нельзя)
chown -R caddy:caddy "$USAGE_WEBROOT"
chmod -R u=rwX,g=,o= "$USAGE_WEBROOT"
# state — только root
chmod 700 "$USAGE_STATE" 2>/dev/null || true

echo "$(date -u +%FT%TZ) usage-report regenerated" >> /var/log/codex-usage.log
