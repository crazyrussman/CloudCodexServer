#!/usr/bin/env python3
# codex-usage-account.py - мини-сервис «Аккаунт» для веб-дашборда расхода.
# Слушает 127.0.0.1, за Caddy. Личность приходит в X-User (проставляет Caddy после basic_auth),
# X-Auth-Token защищает от прямого обращения локальных пользователей. Смену пароля применяет
# проверенный скрипт codex-usage-passwd через узкое sudo. Только stdlib.
import os, re, html, subprocess, urllib.parse, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN  = os.environ.get("X_AUTH_TOKEN", "")
ADMIN  = os.environ.get("USAGE_ADMIN", "admin")
PORT   = int(os.environ.get("ACCOUNT_PORT", "8781"))
PASSWD = "/usr/local/sbin/codex-usage-passwd"

USER_RE = re.compile(r'^[a-z][a-z0-9_-]{0,31}$')
PW_RE   = re.compile(r'^[A-Za-z0-9!@#%^&*()_+=.,-]{8,64}$')

CSS = """
:root{--bg:#F1F3F6;--surf:#fff;--ink:#151A21;--mut:#5D6875;--line:#E3E7ED;--acc:#2F6DB0;--accd:#1C3F63;
--good:#2F8A63;--goods:#E2F0E9;--crit:#C43B3B;--crits:#F6E6E4;--mono:ui-monospace,"Consolas",monospace;
--sans:system-ui,"Segoe UI",Roboto,Arial,sans-serif}
@media(prefers-color-scheme:dark){:root{--bg:#0F1216;--surf:#171B21;--ink:#E7EBF0;--mut:#9AA5B2;--line:#252C35;
--acc:#5B97D8;--accd:#8FBAE6;--good:#5FBF93;--goods:#14261D;--crit:#E36B6B;--crits:#2C1B1A}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);
line-height:1.5;padding:clamp(16px,4vw,40px)}.wrap{max-width:520px;margin:0 auto;display:flex;flex-direction:column;gap:20px}
header{border-bottom:2px solid var(--ink);padding-bottom:12px}
h1{font-size:22px;margin:0;font-weight:700}.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;
text-transform:uppercase;color:var(--acc);margin:0 0 6px}
nav{display:flex;gap:8px;margin-top:10px}nav a{font-family:var(--mono);font-size:12px;text-decoration:none;color:var(--acc);
border:1px solid var(--line);padding:5px 11px;border-radius:20px}
.card{background:var(--surf);border:1px solid var(--line);border-radius:13px;padding:22px;box-shadow:0 1px 2px rgba(20,30,45,.05)}
.ct{font-family:var(--mono);font-size:12px;letter-spacing:.07em;text-transform:uppercase;color:var(--mut);margin:0 0 16px}
label{display:block;font-size:13px;color:var(--mut);margin:12px 0 5px}
input,select{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:9px;background:var(--bg);
color:var(--ink);font-size:15px;font-family:var(--sans)}
button{margin-top:16px;width:100%;padding:11px;border:none;border-radius:9px;background:var(--acc);color:#fff;
font-size:15px;font-weight:600;cursor:pointer}button:hover{background:var(--accd)}
.msg{padding:11px 14px;border-radius:9px;font-size:14px;margin-bottom:4px}
.msg.ok{background:var(--goods);color:var(--good)}.msg.err{background:var(--crits);color:var(--crit)}
.hint{font-size:12px;color:var(--mut);margin-top:6px}
</style>"""

def list_users():
    try:
        r = subprocess.run(["sudo", "-n", PASSWD, "list"], capture_output=True, text=True, timeout=10)
        return [u for u in r.stdout.split() if USER_RE.match(u)]
    except Exception:
        return []

def set_password(user, pw):
    if not USER_RE.match(user or ""):
        return False, "Неверный логин."
    if not PW_RE.match(pw or ""):
        return False, "Пароль: 8–64 символа (буквы, цифры, спецсимволы)."
    try:
        # Пароль уходит через stdin, а не аргументом: аргументы видны соседям в `ps aux`.
        r = subprocess.run(["sudo", "-n", PASSWD, user, "--stdin"], input=pw + "\n",
                           capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return True, f"Пароль для «{user}» изменён. Войди заново с новым паролем."
        return False, "Ошибка применения: " + ((r.stderr or r.stdout).strip()[:200] or "unknown")
    except Exception as e:
        return False, "Ошибка: " + str(e)[:200]

def esc(s): return html.escape(str(s))

def render(u, msg="", ok=False):
    is_admin = (u == ADMIN)
    m = f'<div class="msg {"ok" if ok else "err"}">{esc(msg)}</div>' if msg else ""
    self_form = f"""<div class="card"><p class="ct">Сменить свой пароль ({esc(u)})</p>
<form method="post" action="/account/change">
<label>Новый пароль</label><input type="password" name="newpw" autocomplete="new-password" required>
<label>Повтори новый пароль</label><input type="password" name="newpw2" autocomplete="new-password" required>
<button type="submit">Сменить мой пароль</button>
<div class="hint">8–64 символа. После смены нужно войти заново.</div></form></div>"""
    admin_form = ""
    if is_admin:
        opts = "".join(f'<option value="{esc(x)}">{esc(x)}</option>' for x in list_users())
        admin_form = f"""<div class="card"><p class="ct">Админ · сбросить пароль сотруднику</p>
<form method="post" action="/account/admin">
<label>Сотрудник</label><select name="user" required>{opts}</select>
<label>Новый пароль</label><input type="text" name="newpw" required>
<button type="submit">Сбросить пароль сотруднику</button>
<div class="hint">Передай новый пароль сотруднику защищённым каналом.</div></form></div>"""
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Аккаунт · {esc(u)}</title><style>{CSS}</head>
<body><div class="wrap"><header><p class="eyebrow">CloudCodexServer · аккаунт</p><h1>Пароль и доступ</h1>
<nav><a href="/">← Дашборд</a><a href="/logout">Выйти</a></nav></header>
{m}{self_form}{admin_form}</div></body></html>"""

class H(BaseHTTPRequestHandler):
    def _auth(self):
        if not TOKEN or self.headers.get("X-Auth-Token") != TOKEN:
            self.send_error(403, "forbidden"); return None
        u = self.headers.get("X-User", "")
        if not USER_RE.match(u):
            self.send_error(403, "no user"); return None
        return u

    def _html(self, body, code=200):
        b = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def _api(self, u, q):
        view = q.get("view", ["shared"])[0]
        if view not in ("shared", "me", "admin"):
            return self._html('<div class="card note">Неверный вид.</div>', 400)
        if view == "admin" and u != ADMIN:
            return self._html('<div class="card note">Только администратор.</div>', 403)
        def pdt(s):
            try: return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
            except Exception: return None
        frm, to = pdt(q.get("from", [""])[0]), pdt(q.get("to", [""])[0])
        if not frm or not to or frm >= to:
            return self._html('<div class="card note">Неверный период.</div>', 400)
        if (to - frm).days > 92:
            frm = to - datetime.timedelta(days=92)
        try:
            r = subprocess.run(["sudo", "-n", "/usr/local/sbin/codex-usage-report.py", "--fragment",
                                "--as", u, "--view", view, "--from", frm.isoformat(), "--to", to.isoformat()],
                               capture_output=True, text=True, timeout=120)
            body = r.stdout if r.returncode == 0 else '<div class="card note">Ошибка расчёта периода.</div>'
        except Exception:
            body = '<div class="card note">Слишком долго. Попробуй меньший период.</div>'
        self._html(body)

    def do_GET(self):
        u = self._auth()
        if not u: return
        p = urllib.parse.urlparse(self.path)
        if p.path == "/api/usage":
            return self._api(u, urllib.parse.parse_qs(p.query))
        self._html(render(u))

    def do_POST(self):
        u = self._auth()
        if not u: return
        n = int(self.headers.get("Content-Length", "0") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        g = lambda k: form.get(k, [""])[0]
        if self.path.startswith("/account/change"):
            if g("newpw") != g("newpw2"):
                return self._html(render(u, "Пароли не совпадают.", False))
            ok, msg = set_password(u, g("newpw"))          # цель = сам, из доверенного X-User
            return self._html(render(u, msg, ok))
        if self.path.startswith("/account/admin"):
            if u != ADMIN:
                return self._html(render(u, "Только администратор.", False))
            ok, msg = set_password(g("user"), g("newpw"))
            return self._html(render(u, msg, ok))
        self.send_error(404)

    def log_message(self, *a): pass

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
