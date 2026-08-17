#!/bin/bash
# ============================================================
#  codex-monitor.sh — мониторинг сервера CloudCodexServer.
#  Проверяет диск, свежесть бэкапа, синхронизацию Codex-токена,
#  OOM, службы и НАГРУЗКУ (load / swap / залипание на IO).
#  При проблеме шлёт алерт в Telegram (tg-send.sh) и НАЗЫВАЕТ ВИНОВНИКА.
#
#    codex-monitor.sh          # проверка (алерт только при проблеме)
#    codex-monitor.sh daily    # ежедневная сводка (heartbeat, даже если всё ок)
#
#  Запускается из cron (ежечасно + ежедневная сводка).
#
#  Два неочевидных требования, без которых монитор бесполезен:
#   • Следить не только за диском. Машина может стать полностью недоступной
#     при свободном диске — своп-тромб, высокий load, процессы в D-state.
#     Секция 6 (load / swap / IO-pressure) закрывает именно этот класс.
#   • Анти-спам должен ключеваться на КЛАСС проблемы, а не на её текст.
#     Иначе меняющийся процент («диск 87%» → «диск 90%») даёт новую
#     сигнатуру, и алерт летит каждый час вместо раза в 6 часов.
# ============================================================
set -u
TG=/usr/local/sbin/tg-send.sh
LOG=/var/log/codex-monitor.log
STATE=/var/lib/codex-monitor.state
DISK_THRESHOLD=80
USER_GB_THRESHOLD=20
TMP_GB_THRESHOLD=4    # общая свалка /tmp (лежит на том же разделе, что и /)
# Персональные пороги (ГБ) — перекрывают USER_GB_THRESHOLD для указанных юзеров.
declare -A USER_GB_OVERRIDE=( )   # пример: ( [ivan]=35 [petr]=50 )
# Пороги нагрузки (секция 6)
LOAD_MULT=4             # алерт при load1 >= CORES * LOAD_MULT (4 ядра → 16)
SWAP_PCT_THRESHOLD=70   # алерт при занятости swap >= N%
IO_STALL_THRESHOLD=50   # алерт при /proc/pressure/io some avg60 >= N% (процессы стоят в D-state)
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
MODE="${1:-check}"

# возраст в часах от строки лога с timestamp ISO в начале (последнее совпадение по шаблону)
age_h_from_log() {  # $1=файл $2=grep-шаблон
  local last; last=$(grep -E "$2" "$1" 2>/dev/null | tail -1 | grep -oE '^[0-9T:-]+Z' | head -1)
  [ -z "$last" ] && { echo 9999; return; }
  python3 - "$last" <<'PY' 2>/dev/null || echo 9999
import sys,datetime
t=datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()//3600))
PY
}

PROBLEMS=()
PKEYS=()
# add_problem КЛЮЧ ТЕКСТ — ключ идёт в сигнатуру анти-спама (стабилен), текст к владельцу (с цифрами)
add_problem() { PKEYS+=("$1"); PROBLEMS+=("$2"); }

# --- «кто виноват»: вызывается только когда проблема уже зафиксирована ---

# Топ-3 пользователя по (RAM + swap) их cgroup-слайса. Именно слайс, а не процесс:
# сразу видно ЧЕЛОВЕКА, а не безымянный java/chrome.
top_users_mem() {
  local s uid n cur sw
  for s in /sys/fs/cgroup/user.slice/user-*.slice; do
    [ -d "$s" ] || continue
    uid=$(basename "$s"); uid=${uid#user-}; uid=${uid%.slice}
    n=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1); [ -z "$n" ] && n="uid${uid}"
    cur=$(cat "$s/memory.current" 2>/dev/null); cur=${cur:-0}
    sw=$(cat "$s/memory.swap.current" 2>/dev/null); sw=${sw:-0}
    echo "$(( (cur + sw) / 1048576 )) $n"
  done | sort -rn | head -3 | awk '{printf "%s%s %sМБ", (NR>1 ? ", " : ""), $2, $1} END{print ""}'
}

# Топ-3 процесса по CPU (для перегрузки по load)
top_cpu() {
  ps -eo user:12,comm,pcpu --no-headers --sort=-pcpu 2>/dev/null | head -3 \
    | awk '{printf "%s%s/%s %s%%", (NR>1 ? ", " : ""), $1, $2, $3} END{print ""}'
}

SUMMARY=()

# 1. Диск (весь раздел) — сама проблема формируется ниже (1d), после подсчёта «кто занял»
USEP=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9'); USEP=${USEP:-0}
SUMMARY+=("Диск /: ${USEP}%")

# 1b. Использование диска по пользователям (мягкий контроль, порог USER_GB_THRESHOLD)
USERLINES=()
USERGB=()
while IFS=: read -r uname _ uid _ _ uhome _; do
  if [ "$uid" -ge 1000 ] && [ "$uid" -lt 2000 ] && [ -d "$uhome" ]; then
    ukb=$(du -sx "$uhome" 2>/dev/null | awk '{print $1}'); ukb=${ukb:-0}
    ugb=$(( ukb / 1024 / 1024 ))
    USERLINES+=("${uname}:${ugb}ГБ")
    USERGB+=("${ugb} ${uname}")
    uthr=${USER_GB_OVERRIDE[$uname]:-$USER_GB_THRESHOLD}
    [ "$ugb" -ge "$uthr" ] && add_problem "disk_user_${uname}" "📦 ${uname} занимает ${ugb}ГБ (порог ${uthr}ГБ) — почистите docker-образы/данные"
  fi
done < <(getent passwd)
[ ${#USERLINES[@]} -gt 0 ] && SUMMARY+=("По польз.: ${USERLINES[*]}")

# 1c. Размер общей свалки /tmp (тот же раздел, что /; протухание — 10д, /etc/tmpfiles.d/tmp.conf)
TMPKB=$(du -sx /tmp 2>/dev/null | cut -f1); TMPKB=${TMPKB:-0}
TMPGB=$(( TMPKB / 1024 / 1024 ))
SUMMARY+=("/tmp: ${TMPGB}ГБ")
[ "$TMPGB" -ge "$TMP_GB_THRESHOLD" ] && add_problem "tmp_size" "🧹 /tmp занимает ${TMPGB}ГБ (порог ${TMP_GB_THRESHOLD}ГБ) — общая свалка на разделе /; кто занял: du -xh --max-depth=1 /tmp | sort -h | tail"

# 1d. Алерт по диску — с указанием, чьи дома крупнейшие (данные уже посчитаны в 1b, лишнего du нет)
if [ "$USEP" -ge "$DISK_THRESHOLD" ]; then
  DISK_WHO=""
  [ ${#USERGB[@]} -gt 0 ] && DISK_WHO=$(printf '%s\n' "${USERGB[@]}" | sort -rn | head -2 | awk '{printf "%s%s %sГБ", (NR>1 ? ", " : ""), $2, $1} END{print ""}')
  add_problem "disk" "💾 Диск / заполнен на ${USEP}% (порог ${DISK_THRESHOLD}%). Крупнейшие дома: ${DISK_WHO:-н/д}; /tmp ${TMPGB}ГБ"
fi

# 2. Свежесть бэкапа (последний успешный < 26ч)
BAGE=$(age_h_from_log /var/log/codex-backup.log 'backup done \(rc=0\)')
SUMMARY+=("Бэкап: ${BAGE}ч назад")
[ "$BAGE" -gt 26 ] && add_problem "backup" "🗄️ Бэкап не проходил ${BAGE}ч (норма ≤24ч) — проверьте /var/log/codex-backup.log"

# 3. Синхронизация Codex-токена (последняя < 8ч)
SAGE=$(age_h_from_log /var/log/codex-auth-sync.log 'synced auth.json')
SUMMARY+=("Auth-sync: ${SAGE}ч назад")
[ "$SAGE" -gt 8 ] && add_problem "authsync" "🔑 Codex auth-sync не работал ${SAGE}ч (норма ≤6ч)"

# 4. OOM за последний час
if journalctl -k --since "1 hour ago" 2>/dev/null | grep -qiE 'Out of memory|oom-kill'; then
  add_problem "oom" "🧠 Зафиксирован OOM (нехватка памяти) за последний час. Топ по памяти+swap: $(top_users_mem)"
fi

# 5. Службы
for svc in cron docker; do
  systemctl is-active --quiet "$svc" || add_problem "svc_${svc}" "⚙️ Служба $svc неактивна"
done

# 6. НАГРУЗКА: load / swap / залипание на IO. Машина может стать недоступной
#    при полностью свободном диске — эта секция ловит именно такой случай.
CORES=$(nproc 2>/dev/null || echo 1)
LOAD_THRESHOLD=$(( CORES * LOAD_MULT ))
LOAD1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null); LOAD1=${LOAD1:-0}
LOAD1_INT=${LOAD1%%.*}; LOAD1_INT=${LOAD1_INT:-0}

read -r SWTOT SWUSED SWAP_PCT < <(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{u=t-f; printf "%d %d %d", t, u, (t>0 ? u*100/t : 0)}' /proc/meminfo 2>/dev/null)
SWAP_PCT=${SWAP_PCT:-0}

# «some avg60» из PSI: доля времени, когда хоть один процесс стоял в ожидании ресурса
psi_avg60() {  # $1=io|memory|cpu
  awk '/^some/{for(i=2;i<=NF;i++){split($i,a,"="); if(a[1]=="avg60"){printf "%d", a[2]+0; exit}}}' "/proc/pressure/$1" 2>/dev/null
}
IO_STALL=$(psi_avg60 io);   IO_STALL=${IO_STALL:-0}
MEM_STALL=$(psi_avg60 memory); MEM_STALL=${MEM_STALL:-0}

SUMMARY+=("Нагрузка: load1 ${LOAD1} (${CORES} ядра), swap ${SWAP_PCT}%, IO-залипание ${IO_STALL}%, mem-залипание ${MEM_STALL}%")

if [ "$LOAD1_INT" -ge "$LOAD_THRESHOLD" ]; then
  add_problem "load" "🔥 Перегрузка: load1 ${LOAD1} на ${CORES} ядрах (порог ${LOAD_THRESHOLD}). Топ CPU: $(top_cpu)"
fi
if [ "$SWAP_PCT" -ge "$SWAP_PCT_THRESHOLD" ]; then
  add_problem "swap" "🌀 Swap занят на ${SWAP_PCT}% ($(( SWUSED / 1024 ))МБ, порог ${SWAP_PCT_THRESHOLD}%) — при 100% машина залипает целиком. Топ по памяти+swap: $(top_users_mem)"
fi
if [ "$IO_STALL" -ge "$IO_STALL_THRESHOLD" ]; then
  add_problem "iostall" "🐌 Залипание на IO: pressure/io some avg60=${IO_STALL}% (порог ${IO_STALL_THRESHOLD}%) — процессы стоят в D-state, сервер «не отвечает». Топ по памяти+swap: $(top_users_mem)"
fi

# RAM/swap для сводки
MEM=$(free -m | awk '/Mem:/{printf "%d/%dМБ", $3, $2} /Swap:/{printf " swap %d/%dМБ", $3, $2}')
SUMMARY+=("Память: ${MEM}")

# Требуется ли перезагрузка для применения обновлений
[ -f /var/run/reboot-required ] && SUMMARY+=("⚠️ Требуется перезагрузка (обновления) — применится ночью или вручную")

HOST=$(hostname)
echo "$(ts) check: problems=${#PROBLEMS[@]} disk=${USEP}% load=${LOAD1} swap=${SWAP_PCT}% iostall=${IO_STALL}% backup=${BAGE}h sync=${SAGE}h" >> "$LOG"

# Ежедневная сводка (heartbeat)
if [ "$MODE" = "daily" ]; then
  MSG="✅ CloudCodexServer — суточная сводка ($HOST)"$'\n'
  for s in "${SUMMARY[@]}"; do MSG+="• $s"$'\n'; done
  if [ ${#PROBLEMS[@]} -gt 0 ]; then
    MSG+=$'\n'"⚠️ Проблемы:"$'\n'
    for p in "${PROBLEMS[@]}"; do MSG+="• $p"$'\n'; done
  fi
  [ -x "$TG" ] && "$TG" "$MSG" || true
  exit 0
fi

# Режим проверки: алерт только при проблеме, с защитой от спама (не чаще раза в 6ч на ту же проблему).
# Сигнатура считается по КЛЮЧАМ проблем, а не по тексту: иначе меняющаяся цифра
# («диск 87%» → «диск 90%») давала новую сигнатуру и алерт летел каждый час.
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  echo "ok" > "$STATE"
  exit 0
fi

SIG=$(printf '%s\n' "${PKEYS[@]}" | sort | md5sum | cut -d' ' -f1)
NOW=$(date +%s)
LASTSIG=""; LASTSENT=0
[ -f "$STATE" ] && { LASTSIG=$(sed -n 1p "$STATE"); LASTSENT=$(sed -n 2p "$STATE"); }
LASTSENT=${LASTSENT:-0}

if [ "$SIG" != "$LASTSIG" ] || [ $((NOW - LASTSENT)) -gt 21600 ]; then
  MSG="🚨 CloudCodexServer ($HOST) — проблемы:"$'\n'
  for p in "${PROBLEMS[@]}"; do MSG+="• $p"$'\n'; done
  [ -x "$TG" ] && "$TG" "$MSG" || true
  printf '%s\n%s\n' "$SIG" "$NOW" > "$STATE"
  echo "$(ts) ALERT sent" >> "$LOG"
fi
