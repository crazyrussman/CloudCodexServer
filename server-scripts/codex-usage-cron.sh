#!/bin/bash
# codex-usage-cron.sh — регенерация usage-дашборда по расписанию.
# Запуск от root (нужно читать ~/.codex всех). Права выставляются «только caddy».
set -euo pipefail

export USAGE_WEBROOT=/var/www/codex-usage
export USAGE_STATE=/var/lib/codex-usage

# USAGE_ADMIN берётся из общего env-файла, а НЕ прописывается здесь:
# этот скрипт лежит в /usr/local/sbin и перезаписывается при обновлении, так что
# локальная правка молча вернулась бы к дефолту, а часовая регенерация начала бы
# отдавать обезличенный борд настоящему администратору.
#
# ВАЖНО: файл читается разбором, а НЕ через `source`. Формат у него systemd'шный,
# не shell: значение вроде <логин_админа> или пароль со спецсимволами уронит
# sourcing синтаксической ошибкой, причём ДО любых наших проверок — и скрипт
# умрёт молча, а все приёмочные проверки останутся зелёными.
ACCOUNT_ENV=/etc/codex-usage-account.env

read_env() {   # read_env КЛЮЧ — значение из systemd-совместимого env-файла
	[ -r "$ACCOUNT_ENV" ] || return 0
	sed -n "s/^[[:space:]]*$1=//p" "$ACCOUNT_ENV" | tail -n1 \
		| sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

USAGE_ADMIN="${USAGE_ADMIN:-$(read_env USAGE_ADMIN)}"
export USAGE_ADMIN

# Логин, а не заготовка: ловит незаменённый плейсхолдер вида <логин_админа>.
case "$USAGE_ADMIN" in
	[a-z_]*) : ;;
	*) echo "USAGE_ADMIN в $ACCOUNT_ENV не похож на логин: '${USAGE_ADMIN:-<пусто>}'" >&2
	   echo "Впишите туда реальную учётку администратора дашборда." >&2
	   exit 1 ;;
esac
case "$USAGE_ADMIN" in
	*[!a-z0-9_-]*) echo "USAGE_ADMIN содержит недопустимые символы: '$USAGE_ADMIN'" >&2; exit 1 ;;
esac

/usr/bin/python3 /usr/local/sbin/codex-usage-report.py >> /var/log/codex-usage.log 2>&1

# webroot читает ТОЛЬКО caddy (у сотрудников есть shell — мимо Caddy читать нельзя)
chown -R caddy:caddy "$USAGE_WEBROOT"
chmod -R u=rwX,g=,o= "$USAGE_WEBROOT"
# state — только root
chmod 700 "$USAGE_STATE" 2>/dev/null || true

echo "$(date -u +%FT%TZ) usage-report regenerated" >> /var/log/codex-usage.log
