#!/usr/bin/env python3
# codex-usage-report.py — генератор usage-дашборда CloudCodexServer.
# Режимы:
#   (без аргументов)  — статическая генерация всех страниц (cron), окно по умолчанию = последние 7 дней
#   --fragment --as U --view {shared|me|admin} --from ISO --to ISO
#                     — READ-ONLY: печатает HTML-фрагмент карточек за произвольный период (для /api/usage)
# СТРОГО метаданные: события/инструменты/тайминги/имя проекта (basename). Без текста промптов/файлов/секретов.
import json, os, glob, html, sys, argparse, sqlite3
from datetime import datetime, timezone, timedelta

OUT    = os.environ.get("USAGE_WEBROOT", "/var/www/codex-usage")
STATE  = os.environ.get("USAGE_STATE", "/var/lib/codex-usage")
ADMIN  = os.environ.get("USAGE_ADMIN", "admin")
HOME_ROOT = os.environ.get("USAGE_HOME_ROOT", "/home")
HISTORY_DB = os.path.join(STATE, "history.db")   # ledger, пишет codex-usage-snapshot.py
PERIOD = timedelta(days=7)
MSK    = timezone(timedelta(hours=3))
STAMP = ""; WIN_LABEL = ""

def now_utc(): return datetime.now(timezone.utc)
def window():  n = now_utc(); return n - PERIOD, n
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception: return None
def project_of(cwd, base):
    if cwd and cwd.startswith(base):
        rel = cwd[len(base):].strip("/").split("/"); return "/".join(rel[:2]) if rel and rel[0] else "(projects-root)"
    return "(other)" if cwd else "(unknown)"

def _merge(agg, u, proj, events, tools, first, last):
    d = agg.setdefault(u, {}).setdefault(proj, {"events": 0, "tools": 0, "first": None, "last": None})
    d["events"] += events; d["tools"] += tools
    if first and (d["first"] is None or first < d["first"]): d["first"] = first
    if last  and (d["last"]  is None or last  > d["last"]):  d["last"] = last

def ledger_read(win_start, win_end):
    """История из ledger (codex-usage-snapshot.py) — переживает удаление файлов сессий.
    Возвращает (agg, users, covered_until): до covered_until данные взяты из ledger,
    остаток периода дочитывается из живых файлов. Гранулярность — час, поэтому левый
    край округляется вниз до начала часа (погрешность ≤59 мин, дашборд — не биллинг).
    Ledger нет (не развёрнут/пустой) → ({}, [], win_start): поведение как раньше."""
    if not os.path.isfile(HISTORY_DB): return {}, [], win_start
    try:
        cx = sqlite3.connect(f"file:{HISTORY_DB}?mode=ro", uri=True)
    except sqlite3.Error:
        return {}, [], win_start
    try:
        row = cx.execute("SELECT value FROM meta WHERE key='sealed_through'").fetchone()
        sealed = parse_ts(row[0]) if row else None
        if not sealed: return {}, [], win_start
        covered = min(sealed, win_end)
        if covered <= win_start: return {}, [], win_start
        h_from = win_start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
        h_to   = covered.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
        agg = {}; users = set()
        for u, p, ev, tl, f_ts, l_ts in cx.execute(
                "SELECT user, project, events, tools, first_ts, last_ts FROM usage_hour "
                "WHERE hour >= ? AND hour < ?", (h_from, h_to)):
            users.add(u)
            _merge(agg, u, p, ev, tl, parse_ts(f_ts), parse_ts(l_ts))
        return agg, sorted(users), covered
    except sqlite3.Error:
        return {}, [], win_start
    finally:
        cx.close()

def collect_live(win_start, win_end):
    """Живой обход файлов сессий — источник за незапечатанный хвост периода."""
    users = sorted(u for u in os.listdir(HOME_ROOT) if os.path.isdir(f"{HOME_ROOT}/{u}/.codex/sessions"))
    agg = {}
    if win_end <= win_start: return users, agg
    for u in users:
        base = f"{HOME_ROOT}/{u}/projects/"
        for f in glob.glob(f"{HOME_ROOT}/{u}/.codex/sessions/**/*.jsonl", recursive=True):
            try:
                if os.path.getmtime(f) < win_start.timestamp(): continue
            except OSError:
                continue
            proj = "(unknown)"
            try:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    o = json.loads(fh.readline())
                cwd = (o.get("payload", {}) or {}).get("cwd") or o.get("cwd") or ""
                proj = project_of(cwd, base)
            except Exception:
                pass
            d = agg.setdefault(u, {}).setdefault(proj, {"events": 0, "tools": 0, "first": None, "last": None})
            for line in open(f, encoding="utf-8", errors="replace"):
                try: o = json.loads(line)
                except Exception: continue
                ts = parse_ts(o.get("timestamp", ""))
                if not ts or ts < win_start or ts >= win_end: continue
                d["events"] += 1
                if d["first"] is None or ts < d["first"]: d["first"] = ts
                if d["last"]  is None or ts > d["last"]:  d["last"] = ts
                pl = o.get("payload", o); t = pl.get("type") or o.get("type")
                if t in ("function_call", "local_shell_call", "custom_tool_call", "tool_call"): d["tools"] += 1
    return users, agg

def collect(win_start, win_end):
    """Ledger (запечатанные часы) + живые файлы (хвост). Без двойного счёта:
    периоды не пересекаются — граница covered_until."""
    hist, hist_users, covered = ledger_read(win_start, win_end)
    live_users, live = collect_live(max(win_start, covered), win_end)
    agg = {}
    for src in (hist, live):
        for u, projs in src.items():
            for p, d in projs.items():
                _merge(agg, u, p, d["events"], d["tools"], d["first"], d["last"])
    # юзер мог уволиться/лишиться папки сессий, но его история в ledger остаётся
    return sorted(set(live_users) | set(hist_users)), agg

def compute(win_start, win_end):
    users, agg = collect(win_start, win_end)
    per_user = {u: sum(p["events"] for p in projs.values()) for u, projs in agg.items()}
    total = sum(per_user.values()) or 1
    return users, agg, per_user, total

def audit_configs(users):
    rows = []
    for u in users:
        c = f"/home/{u}/.codex/config.toml"
        r = {"user": u, "model": "—", "effort": "—", "sandbox": "default", "mcp": 0, "secret": False}
        if os.path.isfile(c):
            txt = open(c, encoding="utf-8", errors="replace").read(); mcp = set()
            for ln in txt.splitlines():
                s = ln.strip()
                if s.startswith("model =") or s.startswith("model="): r["model"] = s.split("=", 1)[1].strip().strip('"')
                if "reasoning_effort" in s: r["effort"] = s.split("=", 1)[1].strip().strip('"')
                if "sandbox_mode" in s: r["sandbox"] = s.split("=", 1)[1].strip().strip('"')
                if s.startswith("[mcp_servers."): mcp.add(s.split(".")[1].split("]")[0].split(".")[0])
                low = s.lower()
                if ("api_key" in low or "password" in low or low.startswith("secret") or low.startswith("token =")) and "=" in s:
                    r["secret"] = True
            r["mcp"] = len(mcp)
        rows.append(r)
    return rows

CSS = """
:root{--bg:#F1F3F6;--surf:#fff;--surf2:#F7F8FA;--ink:#151A21;--mut:#5D6875;--fai:#8A94A1;--line:#E3E7ED;
--acc:#2F6DB0;--accd:#1C3F63;--accs:#EAF1F9;--crit:#C43B3B;--warn:#C77C1E;--good:#2F8A63;--track:#E7EBF1;
--mono:ui-monospace,"Cascadia Code","Consolas",monospace;--sans:system-ui,"Segoe UI",Roboto,Arial,sans-serif}
@media(prefers-color-scheme:dark){:root{--bg:#0F1216;--surf:#171B21;--surf2:#1C222A;--ink:#E7EBF0;--mut:#9AA5B2;--fai:#6C7784;
--line:#252C35;--acc:#5B97D8;--accd:#8FBAE6;--accs:#1A2632;--crit:#E36B6B;--warn:#E0A44E;--good:#5FBF93;--track:#232A33}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);
line-height:1.5;-webkit-font-smoothing:antialiased;padding:clamp(16px,4vw,40px)}
.wrap{max-width:920px;margin:0 auto;display:flex;flex-direction:column;gap:20px}
header{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-end;gap:12px;border-bottom:2px solid var(--ink);padding-bottom:14px}
h1{font-size:clamp(20px,3vw,27px);margin:0;font-weight:700;letter-spacing:-.01em}
.eyebrow{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--acc);margin:0 0 6px}
.stamp{font-family:var(--mono);font-size:12px;color:var(--mut);text-align:right}
nav{display:flex;gap:8px;flex-wrap:wrap}
nav a{font-family:var(--mono);font-size:12px;text-decoration:none;color:var(--acc);border:1px solid var(--line);padding:5px 11px;border-radius:20px}
nav a.lo{margin-left:auto;color:var(--crit);border-color:color-mix(in srgb,var(--crit) 35%,var(--line))}
.periods{display:flex;flex-wrap:wrap;align-items:center;gap:8px}
.periods button{font-family:var(--mono);font-size:12px;padding:6px 12px;border:1px solid var(--line);border-radius:20px;background:var(--surf);color:var(--ink);cursor:pointer}
.periods button.active{background:var(--acc);color:#fff;border-color:var(--acc)}
.periods button.apply{background:var(--accd);color:#fff;border-color:var(--accd)}
.periods .sep{font-family:var(--mono);font-size:11px;color:var(--fai);margin-left:8px}
.periods input[type=date]{font-family:var(--mono);font-size:12px;padding:5px 8px;border:1px solid var(--line);border-radius:8px;background:var(--surf);color:var(--ink)}
.periods .plabel{font-family:var(--mono);font-size:11px;color:var(--acc);margin-left:4px}
.card{background:var(--surf);border:1px solid var(--line);border-radius:13px;padding:clamp(15px,2.5vw,24px);box-shadow:0 1px 2px rgba(20,30,45,.05),0 8px 24px rgba(20,30,45,.04)}
.ct{font-family:var(--mono);font-size:12px;letter-spacing:.07em;text-transform:uppercase;color:var(--mut);margin:0 0 14px}
.row{display:grid;grid-template-columns:150px 1fr 62px;align-items:center;gap:13px;padding:11px 2px;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:none}
@media(max-width:560px){.row{grid-template-columns:1fr 54px}.row .tc{grid-column:1/-1;order:3}}
.nm{font-weight:600;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.nm.w{white-space:normal;overflow:visible;text-overflow:clip;word-break:break-word}
.mt{font-family:var(--mono);font-size:11px;color:var(--fai);margin-top:2px}
.track{height:22px;background:var(--track);border-radius:6px;overflow:hidden;position:relative}
.track>span{position:absolute;left:0;top:0;bottom:0;border-radius:6px;background:linear-gradient(90deg,var(--accd),var(--acc));min-width:3px}
.track.top>span{background:linear-gradient(90deg,#9a3b12,var(--warn))}
.pct{font-family:var(--mono);font-weight:700;font-size:15px;text-align:right;font-variant-numeric:tabular-nums}
.pct small{display:block;font-size:10px;font-weight:500;color:var(--fai)}
.lrow{display:grid;grid-template-columns:180px 1fr 76px;align-items:center;gap:13px;padding:12px 10px;border-bottom:1px solid var(--line);text-decoration:none;color:inherit;border-radius:9px;transition:background .12s}
.lrow:last-child{border-bottom:none}.lrow:hover{background:var(--accs)}
.lrow .chev{color:var(--acc);font-weight:700;font-family:var(--mono)}
@media(max-width:560px){.lrow{grid-template-columns:1fr 62px}.lrow .tc{grid-column:1/-1;order:3}}
.kv{display:flex;justify-content:space-between;gap:12px;padding:9px 0;border-bottom:1px dashed var(--line);font-size:14px}
.kv:last-child{border-bottom:none}.kv .kk{color:var(--mut)}.kv .vv{font-family:var(--mono);font-weight:600}
.badge{display:inline-block;font-family:var(--mono);font-size:11px;padding:2px 9px;border-radius:20px}
.badge.r{background:color-mix(in srgb,var(--crit) 18%,transparent);color:var(--crit)}
.badge.y{background:color-mix(in srgb,var(--warn) 20%,transparent);color:var(--warn)}
.badge.g{background:color-mix(in srgb,var(--good) 18%,transparent);color:var(--good)}
.note{font-size:12.5px;color:var(--mut);line-height:1.6}.note b{color:var(--ink)}
#cards{display:flex;flex-direction:column;gap:20px;transition:opacity .15s}
.foot{font-family:var(--mono);font-size:11px;color:var(--fai);text-align:center;padding-top:2px}
"""

JS = """<script>(function(){
var V=window.__VIEW; if(!V) return;
function qs(s){return document.querySelector(s)}
function setActive(el){document.querySelectorAll('.periods button[data-days]').forEach(function(b){b.classList.toggle('active',b===el)})}
function load(from,to,lbl){var c=document.getElementById('cards'); if(!c)return; c.style.opacity=.45;
 fetch('/api/usage?view='+V+'&from='+encodeURIComponent(from)+'&to='+encodeURIComponent(to))
 .then(function(r){if(!r.ok)throw 0; return r.text()})
 .then(function(h){c.innerHTML=h; c.style.opacity=1; var p=qs('#plabel'); if(p&&lbl)p.textContent=lbl})
 .catch(function(){c.style.opacity=1; c.innerHTML='<div class="card note">Не удалось загрузить период. Попробуй ещё раз.</div>'})}
document.querySelectorAll('.periods button[data-days]').forEach(function(b){b.addEventListener('click',function(){
 var days=+b.dataset.days, to=new Date(), from=new Date(to.getTime()-days*864e5);
 setActive(b); load(from.toISOString(),to.toISOString(), days===1?'за 24 часа':'за '+days+' дней')})})
var ap=qs('#applyRange'); if(ap)ap.addEventListener('click',function(){
 var f=qs('#pfrom').value, t=qs('#pto').value; if(!f||!t){alert('Выбери обе даты');return}
 var from=new Date(f+'T00:00:00'), to=new Date(t+'T23:59:59');
 if(from>=to){alert('Начало должно быть раньше конца');return}
 setActive(null); load(from.toISOString(),to.toISOString(), f+' → '+t)})
})();</script>"""

def esc(s): return html.escape(str(s))
def fmt(n): return f"{n:,}".replace(",", " ")
def msk(dt): return dt.astimezone(MSK).strftime("%d.%m %H:%M") if dt else "—"

def page(title, body, nav=""):
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)}</title><style>{CSS}</style></head><body><div class="wrap">
<header><div><p class="eyebrow">CloudCodexServer · codex-server</p><h1>{esc(title)}</h1></div>
<div class="stamp">{STAMP}</div></header>
{f'<nav>{nav}</nav>' if nav else ''}
{body}
<p class="foot">Оценка по объёму логов сессий Codex (события за период), НЕ биллинг ChatGPT. Только метаданные — без текста промптов и данных клиентов.</p>
</div>{JS}</body></html>"""

def CTRL(view):
    return (f'<script>window.__VIEW="{view}"</script>'
            '<div class="periods">'
            '<button data-days="1">24 часа</button>'
            '<button data-days="7" class="active">7 дней</button>'
            '<button data-days="30">30 дней</button>'
            '<span class="sep">свой период:</span>'
            '<input type="date" id="pfrom"><span>—</span><input type="date" id="pto">'
            '<button id="applyRange" class="apply">Применить</button>'
            '<span id="plabel" class="plabel">за 7 дней</span>'
            '</div>')

def board_page(title, view, cards, nav):
    return page(title, CTRL(view) + f'<div id="cards">{cards}</div>', nav)

def bars(items, top_flag_first=False, wrap=False):
    mx = max((v for _, _, v, _ in items), default=1) or 1
    nmcls = "nm w" if wrap else "nm"
    out = []
    for i, (name, meta, val, pct) in enumerate(items):
        cls = " top" if (top_flag_first and i == 0) else ""
        w = max(3, round(100 * val / mx))
        out.append(f'<div class="row"><div><div class="{nmcls}">{esc(name)}</div><div class="mt">{esc(meta)}</div></div>'
                   f'<div class="tc"><div class="track{cls}"><span style="width:{w}%"></span></div></div>'
                   f'<div class="pct">{pct:.1f}%<small>за период</small></div></div>')
    return "".join(out)

def render_shared(agg, per_user, total):
    # Обезличенный лидерборд: имена коллег скрыты (позиция «Сотрудник N» по убыванию доли).
    # Реальные имена видит только админ (render_admin). Своя детализация — на /me.
    ranked = sorted(per_user.items(), key=lambda kv: -kv[1])
    active = [(u, ev) for u, ev in ranked if ev > 0]
    items = [(f"Сотрудник {i+1}", f"{len([p for p, d in agg.get(u, {}).items() if d['events']>0])} проект(ов)", ev, 100*ev/total)
             for i, (u, ev) in enumerate(active)]
    inner = bars(items, top_flag_first=True) if items else '<div class="note">За выбранный период активности Codex не было.</div>'
    return (f'<div class="card"><p class="ct">Доли расхода по команде за период · обезличенно</p>{inner}</div>'
            '<div class="card note"><b>Как читать:</b> распределение расхода Codex по команде за период (по числу событий в логах), обезличенно — имена коллег скрыты. Своя разбивка по проектам — вкладка «Мой расход». Имена участников и клиентов видит только администратор.</div>')

def render_admin(agg, per_user, total, users):
    ranked = sorted(per_user.items(), key=lambda kv: -kv[1])
    mx = max(per_user.values(), default=1) or 1
    lead = ""
    for i, (u, ev) in enumerate(ranked):
        if ev <= 0: continue
        nproj = len([p for p, d in agg.get(u, {}).items() if d["events"] > 0])
        w = max(3, round(100*ev/mx)); top = " top" if i == 0 else ""
        lead += (f'<a class="lrow" href="/admin/u/{esc(u)}"><div><div class="nm">{esc(u)} <span class="chev">→</span></div>'
                 f'<div class="mt">{nproj} проект(ов) · {fmt(ev)} событий</div></div>'
                 f'<div class="tc"><div class="track{top}"><span style="width:{w}%"></span></div></div>'
                 f'<div class="pct">{100*ev/total:.1f}%<small>команды</small></div></a>')
    for u in users:
        if per_user.get(u, 0) > 0: continue
        lead += (f'<a class="lrow" href="/admin/u/{esc(u)}"><div><div class="nm">{esc(u)} <span class="chev">→</span></div>'
                 f'<div class="mt">нет активности за период</div></div><div class="tc"></div>'
                 f'<div class="pct">0.0%<small>команды</small></div></a>')
    if not lead: lead = '<div class="note">За выбранный период активности нет.</div>'
    return (f'<div class="card"><p class="ct">Кто сколько израсходовал · вся команда — кликни для деталей</p>{lead}</div>'
            '<div class="card note"><b>Админ-вид:</b> клик по сотруднику → его проекты и конфиг Codex. Доли — оценка по логам, не биллинг.</div>')

def render_me(agg, per_user, u):
    projs = agg.get(u, {}); tot_u = per_user.get(u, 0) or 1
    rows = sorted(projs.items(), key=lambda kv: -kv[1]["events"])
    items = [(p, f'{fmt(d["events"])} событий · {fmt(d["tools"])} инстр. · {msk(d["first"])}→{msk(d["last"])}',
              d["events"], 100*d["events"]/tot_u) for p, d in rows if d["events"] > 0]
    inner = bars(items, top_flag_first=True, wrap=True) if items else '<div class="note">За выбранный период активности Codex не было.</div>'
    return (f'<div class="card"><p class="ct">Мои проекты за период — доля моего расхода</p>{inner}</div>'
            '<div class="card note">Разбивка твоего расхода по проектам за выбранный период.</div>')

def flag_of(r):
    if r["effort"] == "xhigh" and (r["mcp"] > 0 or r["secret"] or "danger" in r["sandbox"]): return ("r", "🔴 всё разом")
    if r["effort"] == "xhigh": return ("y", "🟡 reasoning")
    return ("g", "ок")

def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f: f.write(content)

def main():
    global STAMP, WIN_LABEL
    win_start, win_end = window()
    STAMP = "снимок " + now_utc().astimezone(MSK).strftime("%d.%m.%Y %H:%M МСК")
    users, agg, per_user, total = compute(win_start, win_end)
    NAV = '<a href="/">Общий</a><a href="/me">Мой расход</a><a href="/account">Аккаунт</a><a href="/logout" class="lo">Выйти</a>'

    pub = board_page("Общий расход Codex", "shared", render_shared(agg, per_user, total), NAV)
    write(f"{OUT}/private/pub/index.html", pub); write(f"{OUT}/index.html", pub)
    write(f"{OUT}/private/admin/index.html", board_page("Общий расход Codex · админ", "admin", render_admin(agg, per_user, total, users), NAV))

    for u in users:
        write(f"{OUT}/private/u/{u}/index.html", board_page(f"Мой расход · {u}", "me", render_me(agg, per_user, u), NAV))

    cfg = {r["user"]: r for r in audit_configs(users)}
    for u in users:
        r = cfg[u]; cls, lbl = flag_of(r)
        cfgcard = f"""<div class="card"><p class="ct">Конфиг Codex — «ручки» расхода</p>
<div class="kv"><span class="kk">Модель</span><span class="vv">{esc(r['model'])}</span></div>
<div class="kv"><span class="kk">Reasoning</span><span class="vv">{esc(r['effort'])}</span></div>
<div class="kv"><span class="kk">Sandbox</span><span class="vv">{esc(r['sandbox'])}</span></div>
<div class="kv"><span class="kk">MCP-серверов</span><span class="vv">{r['mcp']}</span></div>
<div class="kv"><span class="kk">Секрет в конфиге</span><span class="vv">{"да" if r['secret'] else "нет"}</span></div>
<div class="kv"><span class="kk">Оценка</span><span class="vv"><span class="badge {cls}">{lbl}</span></span></div></div>"""
        body = f"""<div class="card"><p class="ct">{esc(u)} — доля команды {100*per_user.get(u,0)/total:.1f}% · {fmt(per_user.get(u,0))} событий</p>{render_me(agg, per_user, u)}</div>{cfgcard}"""
        write(f"{OUT}/private/admin/u/{u}.html", page(f"Сотрудник · {u}", body,
              nav='<a href="/">← К списку</a><a href="/me">Мой расход</a><a href="/account">Аккаунт</a><a href="/logout" class="lo">Выйти</a>'))

    os.makedirs(STATE, exist_ok=True)
    write(f"{STATE}/latest.json", json.dumps({"generated": now_utc().isoformat(), "window_start": win_start.isoformat(),
          "window_end": win_end.isoformat(), "total_events": total, "per_user": per_user}, ensure_ascii=False, indent=2))
    print(f"OK users={len(users)} total_events={total} window=7d")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--fragment", action="store_true")
    ap.add_argument("--as", dest="as_user", default="")
    ap.add_argument("--view", default="shared")
    ap.add_argument("--from", dest="frm", default="")
    ap.add_argument("--to", dest="to", default="")
    a = ap.parse_args()
    if a.fragment:
        ws, we = parse_ts(a.frm), parse_ts(a.to)
        if not ws or not we or ws >= we:
            print('<div class="card note">Некорректный период.</div>'); sys.exit(0)
        if we - ws > timedelta(days=92): ws = we - timedelta(days=92)
        users, agg, per_user, total = compute(ws, we)
        v, who = a.view, a.as_user
        if v == "admin":
            if who != ADMIN: print(""); sys.exit(0)
            print(render_admin(agg, per_user, total, users))
        elif v == "me":
            print(render_me(agg, per_user, who))
        else:
            print(render_shared(agg, per_user, total))
        sys.exit(0)
    main()
