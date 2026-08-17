#!/bin/bash
# codex-usage-passwd.sh - сменить пароль логина веб-дашборда расхода.
# Запуск от root:  codex-usage-passwd <логин> [пароль|--stdin]
#   --stdin - пароль со стандартного ввода (не виден в `ps aux`)
# Без [пароль] — сгенерирует случайный. Меняет хеш в Caddyfile, валидирует, перезагружает Caddy.
set -euo pipefail
CF=/etc/caddy/Caddyfile
CRED=/root/codex-usage-credentials.txt

# режим списка логинов (для сервиса «Аккаунт»)
if [ "${1:-}" = "list" ]; then
	grep -oE '^[[:space:]]+[a-z0-9_-]+[[:space:]]+\$2' "$CF" | awk '{print $1}'
	exit 0
fi

U="${1:-}"
[ -n "$U" ] || { echo "Использование: codex-usage-passwd <логин> [пароль]"; echo "Логины:"; grep -oE '^\s+[a-z0-9_-]+\s+\$2' "$CF" | awk '{print "  "$1}'; exit 1; }
grep -qE "^[[:space:]]+${U}[[:space:]]+\\\$2" "$CF" || { echo "Нет такого логина в дашборде: $U"; exit 1; }

if [ "${2:-}" = "--stdin" ]; then
	# Пароль читается со стандартного ввода: аргумент командной строки виден
	# соседям по машине в `ps aux`.
	IFS= read -r PW || true   # без || true `set -e` оборвёт скрипт на EOF раньше проверки
	[ -n "$PW" ] || { echo "Пустой пароль на stdin"; exit 1; }
elif [ -n "${2:-}" ]; then
	PW="$2"
else
	RAW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"; PW="${RAW:0:14}"
fi
H="$(caddy hash-password --plaintext "$PW")"

python3 - "$CF" "$U" "$H" <<'PY'
import sys, re
cf, u, h = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(cf, encoding='utf-8').read().split('\n')
out, done = [], False
for ln in lines:
    if re.match(rf'^\s+{re.escape(u)}\s+\$2', ln):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(f'{indent}{u} {h}'); done = True
    else:
        out.append(ln)
open(cf, 'w', encoding='utf-8').write('\n'.join(out))
sys.exit(0 if done else 2)
PY

caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1 || { echo "ОШИБКА: Caddyfile стал невалидным, пароль НЕ применён"; exit 1; }
systemctl reload caddy

# обновить учётку в creds-файле (root-600)
touch "$CRED"; chmod 600 "$CRED"
sed -i "/^${U}[[:space:]]/d" "$CRED" 2>/dev/null || true
printf "%-11s %s\n" "$U" "$PW" >> "$CRED"

echo "Пароль обновлён и применён:"
echo "  логин:  $U"
echo "  пароль: $PW"
echo "(передай сотруднику защищённым каналом; запись также в $CRED)"
