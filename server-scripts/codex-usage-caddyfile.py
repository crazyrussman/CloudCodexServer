#!/usr/bin/env python3
# Регенерирует /etc/caddy/Caddyfile для codex.example.com, СОХРАНЯЯ логины/хеши basic_auth.
# Секрет для сервиса «Аккаунт» берёт из /etc/codex-usage-account.env (если есть — добавляет роут /account).
import re, os
CF = "/etc/caddy/Caddyfile"
ENV = "/etc/codex-usage-account.env"
ACCPORT = "8781"

def read_env(key):
    try:
        for ln in open(ENV):
            if ln.startswith(key + "="):
                return ln.strip().split("=", 1)[1]
    except FileNotFoundError:
        pass
    return ""

SECRET = read_env("X_AUTH_TOKEN")
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
\temail admin@example.com
}}

codex.example.com {{
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
