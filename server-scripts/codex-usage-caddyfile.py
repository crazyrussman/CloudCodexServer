#!/usr/bin/env python3
# Регенерирует /etc/caddy/Caddyfile, СОХРАНЯЯ логины и хеши basic_auth.
# Домен, ACME-почта и админ берутся из окружения (USAGE_DOMAIN, ACME_EMAIL, USAGE_ADMIN).
# Секрет для сервиса «Аккаунт» берёт из /etc/codex-usage-account.env (если есть — добавляет роут /account).
import re, os
CF = "/etc/caddy/Caddyfile"
# Домен и ACME-контакт НЕ хардкодятся: example.com зарезервирован RFC 2606,
# и ZeroSSL (запасной УЦ Caddy при отказе Let's Encrypt) такой контакт отвергает.
DOMAIN = os.environ.get("USAGE_DOMAIN", "")
ACME_EMAIL = os.environ.get("ACME_EMAIL", "")
ENV = "/etc/codex-usage-account.env"
# Порт берётся из того же env-файла, что читает сам сервис, иначе правка порта
# в env даёт reverse_proxy в никуда и 502 на /account.
ACCPORT = ""  # заполняется ниже, после чтения env
# Логин администратора дашборда: только он видит имена и проекты.
ADMIN = os.environ.get("USAGE_ADMIN", "admin")

def read_env(key):
    try:
        for ln in open(ENV):
            if ln.startswith(key + "="):
                return ln.strip().split("=", 1)[1]
    except FileNotFoundError:
        pass
    return ""

if not DOMAIN or not ACME_EMAIL:
    raise SystemExit(
        "Задайте окружение перед запуском:\n"
        "  USAGE_DOMAIN=codex.вашдомен.ru ACME_EMAIL=admin@вашдомен.ru \\\n"
        "  USAGE_ADMIN=<логин_админа> python3 codex-usage-caddyfile.py\n"
        "Почта на example.com не подойдёт: домен зарезервирован RFC 2606."
    )

SECRET = read_env("X_AUTH_TOKEN")
ACCPORT = read_env("ACCOUNT_PORT") or "8781"
txt = open(CF, encoding="utf-8").read()
auth = [(m.group(1), m.group(2)) for ln in txt.split("\n")
        for m in [re.match(r"^\s+(\S+)\s+(\$2\S+)\s*$", ln)] if m]
assert auth, "не нашёл строки basic_auth — отмена, чтобы не снести пароли"
ab = "".join(f"\t\t{u} {h}\n" for u, h in auth)

acc = (f"""\t@account path /account /account/* /api/*
\thandle @account {{
\t\treverse_proxy 127.0.0.1:{ACCPORT} {{
\t\t\theader_up X-User {{http.auth.user.id}}
\t\t\theader_up X-Auth-Token {SECRET}
\t\t}}
\t}}
""" if SECRET else "")

new = f"""{{
\temail {ACME_EMAIL}
}}

{DOMAIN} {{
\troot * /var/www/codex-usage
\tencode gzip
\tlog {{
\t\toutput file /var/log/caddy/codex-usage.log
\t}}
\theader {{
\t\tStrict-Transport-Security "max-age=31536000"
\t\tX-Content-Type-Options "nosniff"
\t\tX-Frame-Options "DENY"
\t\tReferrer-Policy "no-referrer"
\t\tCache-Control "no-store"
\t\t-Server
\t}}
\tbasic_auth {{
{ab}\t}}
\t@home path / /index.html
\thandle @home {{
\t\troute {{
\t\t\t@adm expression {{http.auth.user.id}} == "{ADMIN}"
\t\t\trewrite @adm /private/admin/index.html
\t\t\t@nadm expression {{http.auth.user.id}} != "{ADMIN}"
\t\t\trewrite @nadm /private/pub/index.html
\t\t\tfile_server
\t\t}}
\t}}
\t@me path /me /me/
\thandle @me {{
\t\troute {{
\t\t\trewrite * /private/u/{{http.auth.user.id}}/index.html
\t\t\tfile_server
\t\t}}
\t}}
\t@adminu path /admin/u/*
\thandle @adminu {{
\t\troute {{
\t\t\t@denied expression {{http.auth.user.id}} != "{ADMIN}"
\t\t\trespond @denied "403 - dostup tolko u administratora" 403
\t\t\t@au path_regexp au ^/admin/u/([a-zA-Z0-9_-]+)/?$
\t\t\trewrite @au /private/admin/u/{{re.au.1}}.html
\t\t\tfile_server
\t\t}}
\t}}
{acc}\t@logout path /logout
\thandle @logout {{
\t\trespond "Vy vyshli. Zakroyte vkladku ili nazhmite Otmena v okne logina." 401
\t}}
\t@private path /private/*
\thandle @private {{
\t\trespond "403 Forbidden" 403
\t}}
\thandle {{
\t\tfile_server
\t}}
}}
"""
open(CF, "w", encoding="utf-8").write(new)
print("Caddyfile regenerated. users:", [u for u, _ in auth], "| account route:", bool(SECRET))
