#!/usr/bin/env python3
# codex-usage-snapshot.py — ledger (история) расхода Codex для дашборда codex.example.com.
#
# ЗАЧЕМ. Дашборд (codex-usage-report.py) считает расход, читая файлы сессий
# ~/.codex/sessions/**/*.jsonl. Пока файл жив — событие видно, удалили файл —
# история схлопнулась: обычная чистка старых сессий одним сотрудником способна
# обнулить сотни тысяч событий, и окно «7 дней» начинает показывать один день.
# Этот скрипт заранее складывает ПОЧАСОВЫЕ агрегаты в отдельное хранилище,
# которое от файлов сессий больше не зависит.
#
# КЛЮЧЕВОЕ ПРАВИЛО — запись только «вверх» (max). Пересчёт часа может увидеть
# столько же или МЕНЬШЕ событий (файлы удаляют, но не воскрешают), поэтому
# ledger берёт максимум из старого и нового значения. Итог: чистка сессий
# физически не может уменьшить историю.
#
# ПРИВАТНОСТЬ — строго метаданные: час, юзер, имя проекта (basename), счётчики.
# Ни текста промптов, ни путей файлов, ни данных клиентов. Тот же уровень,
# что и у дашборда.
#
# Запуск: ежечасно из cron, ПЕРЕД регенерацией дашборда (/etc/cron.d/codex-usage).
#   codex-usage-snapshot.py [--lookback-hours N] [--verbose]
#
# Хранилище: /var/lib/codex-usage/history.db (SQLite) + history.jsonl (плоский
# экспорт того же — человекочитаемый, удобен для бэкапа и переноса).
import argparse
import glob
import json
import os
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone

STATE = os.environ.get("USAGE_STATE", "/var/lib/codex-usage")
HOME_ROOT = os.environ.get("USAGE_HOME_ROOT", "/home")
DB = os.path.join(STATE, "history.db")
EXPORT = os.path.join(STATE, "history.jsonl")
DEFAULT_LOOKBACK = 72  # часов пересчёта; всё, что старше, уже запечатано и не трогается

TOOL_TYPES = ("function_call", "local_shell_call", "custom_tool_call", "tool_call")


def now_utc():
    return datetime.now(timezone.utc)


def parse_ts(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except Exception:
        return None


def hour_key(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")


def project_of(cwd, base):
    # То же правило, что в codex-usage-report.py: два верхних уровня внутри ~/projects.
    if cwd and cwd.startswith(base):
        rel = cwd[len(base):].strip("/").split("/")
        return "/".join(rel[:2]) if rel and rel[0] else "(projects-root)"
    return "(other)" if cwd else "(unknown)"


def ensure_db(cx):
    cx.executescript("""
        CREATE TABLE IF NOT EXISTS usage_hour(
            hour     TEXT NOT NULL,           -- 'YYYY-MM-DDTHH' UTC
            user     TEXT NOT NULL,
            project  TEXT NOT NULL,
            events   INTEGER NOT NULL DEFAULT 0,
            tools    INTEGER NOT NULL DEFAULT 0,
            first_ts TEXT,
            last_ts  TEXT,
            PRIMARY KEY(hour, user, project));
        CREATE INDEX IF NOT EXISTS idx_usage_hour ON usage_hour(hour);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    """)


def scan(win_start, win_end):
    """Агрегирует события сессий в почасовые корзины: (hour, user, project) -> счётчики."""
    buckets = {}
    try:
        users = sorted(u for u in os.listdir(HOME_ROOT)
                       if os.path.isdir(f"{HOME_ROOT}/{u}/.codex/sessions"))
    except OSError:
        return buckets, []
    for u in users:
        base = f"{HOME_ROOT}/{u}/projects/"
        for f in glob.glob(f"{HOME_ROOT}/{u}/.codex/sessions/**/*.jsonl", recursive=True):
            try:
                if os.path.getmtime(f) < win_start.timestamp():
                    continue
            except OSError:
                continue
            proj = "(unknown)"
            try:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    head = json.loads(fh.readline())
                cwd = (head.get("payload", {}) or {}).get("cwd") or head.get("cwd") or ""
                proj = project_of(cwd, base)
            except Exception:
                pass
            try:
                fh = open(f, encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    ts = parse_ts(o.get("timestamp", ""))
                    if not ts or ts < win_start or ts >= win_end:
                        continue
                    k = (hour_key(ts), u, proj)
                    b = buckets.get(k)
                    if b is None:
                        b = buckets[k] = [0, 0, None, None]
                    b[0] += 1
                    pl = o.get("payload", o)
                    if (pl.get("type") or o.get("type")) in TOOL_TYPES:
                        b[1] += 1
                    iso = ts.astimezone(timezone.utc).isoformat()
                    if b[2] is None or iso < b[2]:
                        b[2] = iso
                    if b[3] is None or iso > b[3]:
                        b[3] = iso
    return buckets, users


def upsert(cx, buckets):
    """Пишет корзины по правилу max() — историю можно только нарастить, не уменьшить."""
    rows = [(h, u, p, b[0], b[1], b[2], b[3]) for (h, u, p), b in buckets.items()]
    cx.executemany("""
        INSERT INTO usage_hour(hour, user, project, events, tools, first_ts, last_ts)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(hour, user, project) DO UPDATE SET
            events   = MAX(usage_hour.events, excluded.events),
            tools    = MAX(usage_hour.tools,  excluded.tools),
            first_ts = MIN(COALESCE(usage_hour.first_ts, excluded.first_ts), COALESCE(excluded.first_ts, usage_hour.first_ts)),
            last_ts  = MAX(COALESCE(usage_hour.last_ts,  excluded.last_ts),  COALESCE(excluded.last_ts,  usage_hour.last_ts))
    """, rows)
    return len(rows)


def export_jsonl(cx):
    """Плоский экспорт ledger — читаемый глазами, удобен для бэкапа/переноса."""
    tmp = None
    try:
        d = os.path.dirname(EXPORT) or "."
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".history-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for r in cx.execute("SELECT hour, user, project, events, tools, first_ts, last_ts "
                                "FROM usage_hour ORDER BY hour, user, project"):
                fh.write(json.dumps({"hour": r[0], "user": r[1], "project": r[2],
                                     "events": r[3], "tools": r[4],
                                     "first_ts": r[5], "last_ts": r[6]}, ensure_ascii=False) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, EXPORT)
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lookback-hours", type=int, default=DEFAULT_LOOKBACK)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    end = now_utc()
    start = end - timedelta(hours=max(1, a.lookback_hours))

    os.makedirs(STATE, exist_ok=True)
    buckets, users = scan(start, end)

    cx = sqlite3.connect(DB)
    try:
        ensure_db(cx)
        before = cx.execute("SELECT COALESCE(SUM(events),0) FROM usage_hour").fetchone()[0]
        n = upsert(cx, buckets)
        # Запечатано всё, что строго раньше текущего часа: этот час ещё пишется.
        sealed = end.replace(minute=0, second=0, microsecond=0)
        cx.execute("INSERT INTO meta(key,value) VALUES('sealed_through',?) "
                   "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (sealed.isoformat(),))
        cx.execute("INSERT INTO meta(key,value) VALUES('last_run',?) "
                   "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (end.isoformat(),))
        cx.commit()
        after, hours, span = cx.execute(
            "SELECT COALESCE(SUM(events),0), COUNT(DISTINCT hour), COALESCE(MIN(hour),'—')||'..'||COALESCE(MAX(hour),'—') "
            "FROM usage_hour").fetchone()
        export_jsonl(cx)
    finally:
        cx.close()
    os.chmod(DB, 0o600)

    print(f"snapshot OK users={len(users)} buckets={n} events_total={after} (+{after - before}) "
          f"hours={hours} span={span} sealed_through={sealed.isoformat()}")
    if a.verbose:
        for (h, u, p), b in sorted(buckets.items()):
            print(f"  {h} {u:12} {p:28} events={b[0]:6} tools={b[1]:5}")


if __name__ == "__main__":
    main()
