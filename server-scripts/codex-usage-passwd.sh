#!/bin/bash
# codex-usage-passwd.sh — логины и пароли веб-дашборда расхода.
# Запуск от root:
#   codex-usage-passwd <логин> [пароль|--stdin]           — сменить пароль существующему
#   codex-usage-passwd <логин> --create [пароль|--stdin]  — ЗАВЕСТИ новый логин
#   codex-usage-passwd list                               — перечислить логины
#
#   --stdin — пароль со стандартного ввода (не виден в `ps aux`)
#   Без пароля — сгенерирует случайный.
#
# Логины живут в блоке basic_auth файла /etc/caddy/Caddyfile; остальные секции
# генерирует codex-usage-caddyfile.py, и он сохраняет этот блок как есть.
# Маршруты дашборда обезличены (`{http.auth.user.id}`, regex `/admin/u/*`) —
# после заведения логина перегенерировать Caddyfile НЕ нужно.
set -euo pipefail
CF=/etc/caddy/Caddyfile
CRED=/root/codex-usage-credentials.txt

# режим списка логинов (для сервиса «Аккаунт»)
if [ "${1:-}" = "list" ]; then
	grep -oE '^[[:space:]]+[a-z0-9_-]+[[:space:]]+\$2' "$CF" | awk '{print $1}'
	exit 0
fi

usage() {
	echo "Использование:"
	echo "  codex-usage-passwd <логин> [пароль|--stdin]           сменить пароль"
	echo "  codex-usage-passwd <логин> --create [пароль|--stdin]  завести новый логин"
	echo "Логины:"
	grep -oE '^[[:space:]]+[a-z0-9_-]+[[:space:]]+\$2' "$CF" | awk '{print "  "$1}'
}

U=""; CREATE=0; PWARG=""
for a in "$@"; do
	case "$a" in
		--create) CREATE=1 ;;
		--stdin)  PWARG="--stdin" ;;
		--*)      echo "Неизвестный флаг: $a"; usage; exit 1 ;;
		*)        if [ -z "$U" ]; then U="$a"; else PWARG="$a"; fi ;;
	esac
done
[ -n "$U" ] || { usage; exit 1; }

# есть ли такой логин в блоке basic_auth
has_login() { grep -qE "^[[:space:]]+${1}[[:space:]]+\\\$2" "$CF"; }

# Откат правки Caddyfile: он содержит пароли всех логинов и токен сервиса,
# испорченный файл кладёт дашборд целиком.
#
# Имя бэкапа УНИКАЛЬНОЕ (mktemp), а не фиксированное, и ловушка взводится только
# после того, как бэкап реально снят. Иначе получается ловушка на пустом месте:
# при фиксированном имени снимок, оставшийся от прерванного прошлого запуска,
# подхватывается следующим — падение `caddy hash-password` или `openssl` (обе
# идут ДО создания бэкапа) уложило бы поверх живого файла чужой устаревший
# снимок, молча потеряв заведённые с тех пор логины. С уникальным именем чужой
# файл подобрать нечем, а собственный ещё не существует.
BAK=""
restore() { [ -n "$BAK" ] && [ -s "$BAK" ] && mv -f "$BAK" "$CF"; }
on_signal() { restore; echo; echo "Прервано — Caddyfile возвращён как был"; exit 130; }

if [ "$CREATE" = "1" ]; then
	# Логин ОБЯЗАН быть системной учёткой: дашборд сопоставляет его с
	# /home/<логин> (страница /me) и с cgroup-слайсом. Логин без учётки даёт
	# пустую страницу «Мой расход» и отсутствие в отчётах — молча.
	[[ "$U" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "Недопустимый логин: $U (ожидается ^[a-z][a-z0-9_-]{0,31}\$)"; exit 1; }
	id "$U" >/dev/null 2>&1 || { echo "В системе нет учётки «$U» — заведите её сначала: codex-add-user.sh $U"; exit 1; }
	if has_login "$U"; then echo "Логин «$U» в дашборде уже есть — смените пароль без --create"; exit 1; fi
else
	has_login "$U" || { echo "Нет такого логина в дашборде: $U"; echo "Завести новый: codex-usage-passwd $U --create"; exit 1; }
fi

if [ "$PWARG" = "--stdin" ]; then
	# Пароль читается со стандартного ввода: аргумент командной строки виден
	# соседям по машине в `ps aux`.
	IFS= read -r PW || true   # без || true `set -e` оборвёт скрипт на EOF раньше проверки
	[ -n "$PW" ] || { echo "Пустой пароль на stdin"; exit 1; }
elif [ -n "$PWARG" ]; then
	PW="$PWARG"
else
	RAW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')"; PW="${RAW:0:14}"
fi
H="$(caddy hash-password --plaintext "$PW")"

# С этого места и до успешного reload любой обрыв обязан вернуть файл как был.
# Ловушки взводятся ПОСЛЕ снятия бэкапа — раньше откатывать нечего.
BAK="$(mktemp "$CF.bak-passwd.XXXXXX")"
cp -a "$CF" "$BAK"
trap restore ERR
trap on_signal INT TERM HUP

python3 - "$CF" "$U" "$H" "$CREATE" <<'PY'
import sys, re
cf, u, h, create = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
lines = open(cf, encoding='utf-8').read().split('\n')
out, done = [], False
for ln in lines:
    if re.match(rf'^\s+{re.escape(u)}\s+\$2', ln):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(f'{indent}{u} {h}'); done = True
    else:
        out.append(ln)

if create and not done:
    # Вставляем строку в блок basic_auth перед его закрывающей скобкой.
    # Отступ берём у соседней записи, иначе — таб-таб, как в шаблоне.
    start = next((i for i, ln in enumerate(out) if re.match(r'^\s*basic_auth\s*\{', ln)), None)
    if start is None:
        sys.exit(3)   # блока нет — молча не трогаем
    end = next((i for i in range(start + 1, len(out)) if re.match(r'^\s*\}\s*$', out[i])), None)
    if end is None:
        sys.exit(3)
    indent = '\t\t'
    for i in range(start + 1, end):
        m = re.match(r'^(\s+)\S+\s+\$2', out[i])
        if m:
            indent = m.group(1); break
    out.insert(end, f'{indent}{u} {h}'); done = True

open(cf, 'w', encoding='utf-8').write('\n'.join(out))
sys.exit(0 if done else 2)
PY

if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then
	restore
	echo "ОШИБКА: Caddyfile стал невалидным — правка отменена, файл возвращён как был"
	exit 1
fi
# Бэкап снимаем ТОЛЬКО после успешного reload. Конфиг, лежащий на диске, но не
# перечитанный Caddy, — это пароль, который «уже сменён», а войти с ним нельзя.
if ! systemctl reload caddy; then
	restore
	echo "ОШИБКА: Caddy не перечитал конфиг — правка отменена, файл возвращён как был."
	echo "  Диагностика: systemctl status caddy"
	echo "  Частая причина: удалён каталог /tmp/systemd-private-*-caddy.service-*"
	echo "  (обычно ручной чисткой /tmp) — в журнале status=226/NAMESPACE."
	echo "  Лечится: systemctl restart caddy"
	exit 1
fi
# Правка принята и применена — откатывать больше нечего.
rm -f "$BAK"; BAK=""; trap - ERR INT TERM HUP

# обновить учётку в creds-файле (root-600)
touch "$CRED"; chmod 600 "$CRED"
sed -i "/^${U}[[:space:]]/d" "$CRED" 2>/dev/null || true
printf "%-11s %s\n" "$U" "$PW" >> "$CRED"

if [ "$CREATE" = "1" ]; then
	echo "Логин заведён:"
else
	echo "Пароль обновлён и применён:"
fi
echo "  логин:  $U"
echo "  пароль: $PW"
echo "(передай сотруднику защищённым каналом; запись также в $CRED)"
if [ "$CREATE" = "1" ]; then
	echo "Персональная страница «Мой расход» появится после ближайшей регенерации"
	echo "(ежечасный крон) либо сразу: /usr/local/sbin/codex-usage-cron.sh"
fi
