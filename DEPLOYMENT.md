# Развёртывание сервера Codex с нуля

Пошаговый runbook: как поднять аналогичный сервер для командной работы с
**OpenAI Codex CLI** (или Claude Code / другим CLI-агентом) через VSCode Remote-SSH.
Все команды — для **Ubuntu 24.04** (root). Подставляйте свой IP/логины.

> Подойдёт и для Claude Code: вместо шага 3 поставьте `npm i -g @anthropic-ai/claude-code`
> и авторизуйте через `claude`. Остальное идентично.

---

## 0. Что нужно заранее
- VPS с Ubuntu 24.04 (≥ 2 ГБ RAM; комфортно — 4 ГБ+), root-доступ.
- Аккаунт ChatGPT (Plus/Pro) **или** OpenAI API-ключ для Codex.
- Локально: VSCode + расширение Remote-SSH, OpenSSH-клиент.

---

## 1. Доступ по ключу и базовая безопасность

На локальной машине создайте ключ и положите публичную часть на сервер:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/codex_server -N ""
ssh-copy-id -i ~/.ssh/codex_server.pub root@SERVER_IP   # или вручную в authorized_keys
```

На сервере отключите вход по паролю (вход по ключу уже проверьте, что работает!):
```bash
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
sshd -t && systemctl reload ssh
```

Локально в `~/.ssh/config` (`codex-server-root` — произвольное имя, дальше по
тексту оно обозначено как `<SERVER>`):
```
Host codex-server-root
    HostName <SERVER_IP>
    User root
    IdentityFile ~/.ssh/codex_server
    IdentitiesOnly yes
```

---

## 2. Базовый софт

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Docker + Compose
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# PHP + Composer
apt-get install -y php-cli php-mbstring php-xml php-curl php-zip php-intl \
  php-bcmath php-gd php-mysql php-sqlite3 unzip
curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer

# PHPUnit (под PHP 8.3 — ветка 11) и PHPStan
curl -fsSL https://phar.phpunit.de/phpunit-11.phar -o /usr/local/bin/phpunit
curl -fsSL https://github.com/phpstan/phpstan/releases/latest/download/phpstan.phar -o /usr/local/bin/phpstan
chmod +x /usr/local/bin/phpunit /usr/local/bin/phpstan

# Python venv/pip и пререквизиты rootless Docker
apt-get install -y python3-venv python3-pip python3-full \
  uidmap dbus-user-session slirp4netns fuse-overlayfs docker-ce-rootless-extras \
  bubblewrap tmux git restic
```

**Swap** (важно при малом RAM на нескольких разработчиков — без него OOM-киллы):
```bash
fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' > /etc/sysctl.d/99-codex-swap.conf
sysctl -p /etc/sysctl.d/99-codex-swap.conf
```

---

## 3. Codex CLI + авторизация

```bash
npm install -g @openai/codex
codex --version
```

Создайте «эталонного» владельца `coder` и авторизуйте Codex под ним
(он будет единственным, кто обновляет токен):
```bash
useradd -m -s /bin/bash coder
usermod -aG sudo,docker coder
echo 'coder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/coder ; chmod 440 /etc/sudoers.d/coder
install -d -m700 -o coder -g coder /home/coder/.ssh
echo 'ВАШ_ПУБЛИЧНЫЙ_КЛЮЧ' > /home/coder/.ssh/authorized_keys
chmod 600 /home/coder/.ssh/authorized_keys ; chown coder:coder /home/coder/.ssh/authorized_keys

# авторизация агента под coder:
sudo -u coder -H codex login --device-auth
# откройте показанную ссылку, введите код, войдите в аккаунт провайдера
sudo -u coder codex login status
```
Вариант с API-ключом: `printf 'sk-...' | sudo -u coder codex login --with-api-key`.

### Выберите способ авторизации — от него зависит набор скриптов

**А. Персональная (рекомендуется).** Каждый сотрудник логинится сам — своей
учёткой или своим API-ключом. Раздавать нечего: **не ставьте**
`codex-auth-sync.sh`, `codex-reauth.sh`, `codex-token-expiry-warn.sh` и их
cron-задачи (§4, §4.6). Расход, ротация и блокировка одного человека не задевают
остальных. Всё остальное в этом runbook'е работает без изменений.

**Б. Общий аккаунт на команду.** Тогда перечисленные скрипты нужны: один
пользователь обновляет токен, остальным он раскладывается по cron.
⚠️ Прежде чем выбрать этот путь, прочитайте раздел «Ограничения» в
[README](README.md) — общий лимит, общая смерть токена и риск блокировки
аккаунта там описаны по факту, а не теоретически.

---

## 4. Серверные скрипты

Скопируйте все скрипты из репозитория [`server-scripts/`](server-scripts/) на сервер:
```bash
# Копируем каталог ЦЕЛИКОМ: кроме скриптов там systemd-юнит, sudoers,
# шаблон Caddyfile и conf-файлы — они понадобятся в §4.4 и §4.5.
scp -r server-scripts <SERVER>:/tmp/
ssh <SERVER> 'install -m755 /tmp/server-scripts/*.sh /tmp/server-scripts/*.py /usr/local/sbin/'
ssh <SERVER> 'mv /usr/local/sbin/codex-usage-passwd.sh /usr/local/sbin/codex-usage-passwd'
```
Базовый набор: `codex-add-user.sh`, `codex-backup.sh`, `codex-monitor.sh`,
`codex-autoreboot.sh`, `codex-docker-prune.sh`, `codex-hungjob-reaper.sh`, `tg-send.sh`.
Дашборд расхода — `codex-usage-*.py/sh` (§4.5).

**Только для общего аккаунта** (вариант Б из §3) — `codex-auth-sync.sh`,
`codex-reauth.sh`, `codex-token-expiry-warn.sh`, `codex-block-watch.sh` и cron:
```bash
cat > /etc/cron.d/codex-auth-sync <<'EOF'
0 */6 * * * root /usr/local/sbin/codex-auth-sync.sh
EOF
touch /var/log/codex-auth-sync.log
```

### 4.1. Бэкап `~/projects` в S3 (restic)

Создайте **приватный** бакет в любом S3-совместимом хранилище («холодный» класс
дешевле и для ночных бэкапов подходит). Подставьте свои endpoint и регион:
```bash
install -d -m700 /etc/restic
mv /tmp/server-scripts/restic-excludes.txt /etc/restic/excludes.txt ; chmod 600 /etc/restic/excludes.txt
cat > /etc/restic/env <<EOF
export AWS_ACCESS_KEY_ID="<S3_ACCESS_KEY>"
export AWS_SECRET_ACCESS_KEY="<S3_SECRET_KEY>"
export AWS_DEFAULT_REGION="<REGION>"
export RESTIC_REPOSITORY="s3:https://<S3_ENDPOINT>/<BUCKET>"
export RESTIC_PASSWORD="$(openssl rand -hex 24)"      # СОХРАНИТЕ этот пароль!
EOF
chmod 600 /etc/restic/env
source /etc/restic/env && restic init        # создать репозиторий
cat > /etc/cron.d/codex-backup <<'EOF'
0 3 * * * root /usr/local/sbin/codex-backup.sh
0 4 * * 0 root /usr/local/sbin/codex-backup.sh prune
EOF
touch /var/log/codex-backup.log
```
> ⚠️ `RESTIC_PASSWORD` сохраните **отдельно от сервера** (менеджер паролей) — без
> него копии не восстановить. Восстановление:
> `source /etc/restic/env && restic restore latest --target /tmp/r`.
>
> ✅ **Прогоните демо-восстановление сразу после настройки.** Бэкап, который ни
> разу не разворачивали, — это не бэкап, а надежда.

### 4.2. Мониторинг + алерты в Telegram

Создайте бота через **@BotFather**, узнайте `chat_id`
(`curl "https://api.telegram.org/bot<TOKEN>/getUpdates"` после сообщения боту):
```bash
install -d -m700 /etc/telegram
cat > /etc/telegram/env <<EOF
export TELEGRAM_BOT_TOKEN="<TOKEN>"
export TELEGRAM_CHAT_ID="<CHAT_ID>"
EOF
chmod 600 /etc/telegram/env
cat > /etc/cron.d/codex-monitor <<'EOF'
0 * * * * root /usr/local/sbin/codex-monitor.sh
0 9 * * * root /usr/local/sbin/codex-monitor.sh daily
EOF
touch /var/log/codex-monitor.log
# еженедельная очистка docker (мягкий контроль диска)
cat > /etc/cron.d/codex-docker-prune <<'EOF'
30 4 * * 0 root /usr/local/sbin/codex-docker-prune.sh
EOF
touch /var/log/codex-docker-prune.log
/usr/local/sbin/tg-send.sh "тест"      # проверка
```
Проверяет: заполнение диска, диск по пользователям, размер `/tmp`, свежесть бэкапа,
OOM, службы, флаг «нужна перезагрузка» и **нагрузку** — `load1` относительно числа
ядер, занятость swap, залипание на IO. Пороги задаются переменными в начале
`codex-monitor.sh`; подгоните под своё железо. Суточная сводка показывает занятое
место каждым пользователем.

⚠️ Добавляя свою проверку, вызывайте `add_problem КЛЮЧ ТЕКСТ`, где ключ **не
содержит живых значений**. Анти-спам ключуется на класс проблемы: если в ключ
попадёт меняющийся процент, алерт полетит каждый час вместо раза в 6 часов.

### 4.2b. Лимиты памяти на пользователя + протухание `/tmp`

Без лимитов один тяжёлый джоб выедает всю RAM, и глобальный OOM-killer убивает
процессы **других** пользователей — их контейнеры, базы, сессии. Потолок делает OOM
локальным. Лимит свопа и потолок CPU так же обязательны, как лимит памяти:
обоснование — в [DOCUMENTATION.md](DOCUMENTATION.md).

```bash
mkdir -p /etc/systemd/system/user-.slice.d /etc/systemd/system/user-0.slice.d
# память + swap (значения — под машину с 8 ГБ RAM; подберите свои, см. ниже)
cat > /etc/systemd/system/user-.slice.d/50-memory.conf <<'EOF'
[Slice]
MemoryAccounting=yes
MemoryHigh=3.5G
MemoryMax=5G
MemorySwapMax=3G
EOF
cat > /etc/systemd/system/user-0.slice.d/50-memory.conf <<'EOF'
[Slice]
MemoryHigh=infinity
MemoryMax=infinity
MemorySwapMax=infinity
EOF
# потолок CPU (250% = 2.5 ядра; берите ~60-70% от общего числа ядер)
cat > /etc/systemd/system/user-.slice.d/60-cpu.conf <<'EOF'
[Slice]
CPUAccounting=yes
CPUQuota=250%
EOF
cat > /etc/systemd/system/user-0.slice.d/60-cpu.conf <<'EOF'
[Slice]
CPUQuota=infinity
EOF
systemctl daemon-reload
# /tmp: протухание 30д -> 10д (имя файла совпадает с системным = замена)
cat > /etc/tmpfiles.d/tmp.conf <<'EOF'
D /tmp 1777 root root 10d
EOF
```

`daemon-reload` подхватывает лимиты и живыми слайсами — перезапускать сессии
пользователей не нужно.

**Проверка обязательна** (файл может лежать, а лимита не быть):
```bash
systemctl show user-<uid>.slice -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec
```
⚠️ Невалидное значение (классика — `CPUQuota=250%%` с двойным процентом) systemd
принимает молча.

**Пороги подбирайте по факту**, а не на глаз:
```bash
cat /sys/fs/cgroup/user.slice/user-*.slice/memory.peak
```
Снимите пики за неделю нормальной работы и берите потолок с запасом над
легитимным максимумом — заниженный лимит душит обычную работу.

### 4.3. Автообновления безопасности + умная перезагрузка

```bash
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/52codex-noreboot.conf
cat > /etc/cron.d/codex-autoreboot <<'EOF'
0 1 * * * root /usr/local/sbin/codex-autoreboot.sh
EOF
touch /var/log/codex-autoreboot.log
```
`codex-autoreboot.sh` перезагружает в окне 01:00 UTC (04:00 Мск), **только если никто
не работает** (нет SSH-сессий, VS Code, codex-процессов); иначе откладывает и шлёт в
Telegram, эскалирует после 5 откладываний.

### 4.4. Жнец зависших браузерных джобов

Браузерная автоматика, запущенная агентом, умеет зависать и удерживать гигабайты
памяти неограниченно долго. Жнец снимает такие процессы деревом.

```bash
cp /tmp/server-scripts/codex-hungjob-blocklist.conf /etc/codex-hungjob-blocklist.conf
chmod 644 /etc/codex-hungjob-blocklist.conf     # по умолчанию запретов нет
cat > /etc/cron.d/codex-hungjob-reaper <<'EOF'
*/2 * * * * root /usr/local/sbin/codex-hungjob-reaper.sh
EOF
touch /var/log/codex-hungjob-reaper.log
DRY_RUN=1 /usr/local/sbin/codex-hungjob-reaper.sh   # прогон вхолостую
```

Две ветки: **гигиена браузеров** (любой headless-браузер старше порога) работает
сразу и обычно достаточна; **blocklist** — точечный запрет конкретных команд,
заполняется по мере надобности. Начните с пустого blocklist.

⚠️ Всегда прогоняйте `DRY_RUN=1` перед боевым включением: убедитесь, что среди
целей нет VSCode-сервера и хоста агента.

### 4.5. Веб-дашборд расхода (опционально)

Показывает, кто сколько потребляет, с разбивкой по проектам. Нужен домен,
указывающий на сервер.

**1. Пакет, учётка, каталоги.**
```bash
apt-get install -y caddy
useradd -r -s /usr/sbin/nologin codexacct
install -d -m700 -o codexacct -g codexacct /var/lib/codex-usage
install -d -m700 -o caddy -g caddy /var/www/codex-usage
```
⚠️ **Webroot закрыт намеренно** (`drwx------ caddy`): у сотрудников есть shell,
и при открытых правах они прочитают чужие страницы файлом мимо Caddy.

**2. Окружение сервиса «Аккаунт».** Генератор добавит роут `/account`, только
если этот файл существует. `USAGE_ADMIN` обязателен именно здесь — сервис читает
его отсюда; без него администратором будет считаться логин `admin`, форма сброса
паролей не покажется, а `/api/usage?view=admin` вернёт 403 настоящему админу.

`USAGE_ADMIN` — это **системная учётка**, а не отдельный веб-логин: дашборд
сопоставляет её с `/home/<логин>` и с cgroup-слайсом. На этом шаге в системе
существует только `coder` (заведён в §3) — постоянный администратор появится
позже, в §5 (`codex-add-user.sh <логин> admin`). Поэтому либо оставьте `coder`
и смените переменную после §5, либо разверните дашборд целиком после §5.

⚠️ Впишите логин **значением переменной**, а не угловыми скобками. Файл читают
два разных парсера: systemd принимает любую строку буквально (сервис поднимется
с логином `<логин_админа>` и приёмка пройдёт), а разбор в `codex-usage-cron.sh`
на заготовке остановится с ошибкой — почасовая регенерация встанет молча:
```bash
umask 077
ADMIN_LOGIN=coder        # <-- системная учётка администратора дашборда
cat > /etc/codex-usage-account.env <<EOF
X_AUTH_TOKEN=$(openssl rand -hex 24)
ACCOUNT_PORT=8781
USAGE_ADMIN=$ADMIN_LOGIN
EOF
chmod 600 /etc/codex-usage-account.env
grep -v '^X_AUTH_TOKEN=' /etc/codex-usage-account.env   # проверьте, что логин подставился
```

**3. Стартовый Caddyfile.** Генератор не создаёт конфиг с нуля — он *правит*
существующий, сохраняя логины и хеши, и откажется работать, если не найдёт ни
одной строки `basic_auth` с bcrypt-хешем. Поэтому первый логин заводится вручную:
```bash
sed 's/codex\.example\.com/<ВАШ_ДОМЕН>/' /tmp/server-scripts/Caddyfile.codex-usage \
  > /etc/caddy/Caddyfile
sed -i 's|__ACME_EMAIL__|<ПОЧТА_ДЛЯ_ACME>|' /etc/caddy/Caddyfile
# первый логин = тот же, что в USAGE_ADMIN (по умолчанию coder)
caddy hash-password --plaintext '<ПАРОЛЬ_АДМИНА>'      # скопировать вывод
sed -i 's|__HASH_coder__|<ВСТАВИТЬ_ХЕШ>|' /etc/caddy/Caddyfile
sed -i '/__HASH_/d' /etc/caddy/Caddyfile                # убрать оставшиеся заготовки
```

🔴 **Права на Caddyfile — обязательно.** В него пишется `X-Auth-Token` открытым
текстом и bcrypt-хеши всех логинов. При дефолтных `0644` любой сотрудник (а shell
у них есть по дизайну) читает токен и обращается к сервису напрямую в обход
basic-auth — это полный захват админки дашборда и сброс любого пароля:
```bash
chown root:caddy /etc/caddy/Caddyfile && chmod 640 /etc/caddy/Caddyfile
```

**4. Сервис «Аккаунт» и его права.**
```bash
install -m644 /tmp/server-scripts/codex-usage-account.service /etc/systemd/system/
# sudoers ставить только через visudo-проверку: ошибка ломает sudo на всей машине
visudo -c -f /tmp/server-scripts/sudoers-codex-usage-account
install -m0440 -o root -g root /tmp/server-scripts/sudoers-codex-usage-account \
        /etc/sudoers.d/codex-usage-account
systemctl daemon-reload && systemctl enable --now codex-usage-account
systemctl is-active codex-usage-account       # active
```

**5. Генерация конфига и расписание.**
```bash
USAGE_DOMAIN=<ВАШ_ДОМЕН> ACME_EMAIL=<почта_для_ACME> USAGE_ADMIN=<логин_админа> \
  python3 /usr/local/sbin/codex-usage-caddyfile.py
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy

cat > /etc/cron.d/codex-usage <<'EOF'
50 * * * * root /usr/local/sbin/codex-usage-snapshot.py
0  * * * * root /usr/local/sbin/codex-usage-cron.sh
EOF
```

Домен и ACME-почта задаются окружением — без них генератор откажется работать,
чтобы не прописать заведомо нерабочий контакт (`example.com` зарезервирован
RFC 2606 и отвергается ZeroSSL, запасным удостоверяющим центром Caddy).
`USAGE_ADMIN` задаётся **в одном месте** — env-файле сервиса (шаг 2): оттуда его
читают и сам сервис, и `codex-usage-cron.sh`. В скрипт его вписывать не нужно и
вредно: он лежит в `/usr/local/sbin` и будет перезаписан при обновлении. Администратор — только он видит имена и проекты, остальным общий борд
отдаётся обезличенным. Логины заводятся командой `codex-usage-passwd <логин>`;
пароль можно передать через stdin (`codex-usage-passwd ivan --stdin`), чтобы он не
светился в `ps aux`.

**Приёмка:**
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<ВАШ_ДОМЕН>/     # 401 — basic-auth жив
curl -s -u <логин>:<пароль> https://<ВАШ_ДОМЕН>/ | head -5         # HTML борда
sudo -u <любой_сотрудник> test -r /etc/caddy/Caddyfile && echo 'ОПАСНО: читает' || echo 'ок'
/usr/local/sbin/codex-usage-cron.sh && echo 'регенерация прошла'   # ловит незаданный USAGE_ADMIN

# админ дашборда обязан быть существующей системной учёткой
A=$(sed -n 's/^USAGE_ADMIN=//p' /etc/codex-usage-account.env)
if id "$A" >/dev/null 2>&1; then echo "админ дашборда: $A — учётка есть"
else echo "ВНИМАНИЕ: учётки '$A' нет. Заведите её в §5 и обновите USAGE_ADMIN"; fi
```

⚠️ Дашборд — **прокси по логам, а не биллинг**, и проект определяется по рабочему
каталогу сессии. Ограничения описаны в [DOCUMENTATION.md](DOCUMENTATION.md).

### 4.6. Сторож срока токена — только для общего аккаунта

Предупреждает заранее, что access-токен скоро истечёт, чтобы перевыпустить его в
удобное время, а не по факту простоя. При персональной авторизации (вариант А
из §3) не нужен.

```bash
cat > /etc/cron.d/codex-token-expiry-warn <<'EOF'
0 8,18 * * * root /usr/local/sbin/codex-token-expiry-warn.sh
EOF
/usr/local/sbin/codex-token-expiry-warn.sh --test   # проверка без записи состояния
```
Дата не хардкодится — берётся из `auth.json`, после каждого перевыпуска сторож сам
начинает считать новый срок.

---

## 5. Сотрудники

Каждый создаётся одной командой (скрипт всё делает: пользователь, ключ, Codex-auth,
rootless Docker, окружение, изоляция):
```bash
codex-add-user.sh ivan          # обычный изолированный
codex-add-user.sh petr admin    # второй админ (sudo + root-доступ)
```
Скрипт напечатает **приватный ключ** — отдайте его сотруднику.

Что делает скрипт (если нужно вручную/понять логику):
- `useradd -m`; ключ в `~/.ssh/authorized_keys`; копия `auth.json` в `~/.codex`;
- `~/projects`, алиас `tm`, `~/.npmrc` (npm prefix), PATH/DOCKER_HOST в `~/.bashrc`;
- `chmod 700 ~` (изоляция); subuid/subgid;
- `loginctl enable-linger` + `dockerd-rootless-setuptool.sh install` + enable/start;
- для `admin`: группы `sudo,docker`, sudoers NOPASSWD, ключ в `/root/.ssh/authorized_keys`.

---

## 6. Клиентские комплекты (раздать сотрудникам)

Для каждого сотрудника соберите папку (образцы — в [`setup-new-pc/`](setup-new-pc/)):
- положите его приватный ключ `codex_<логин>_ed25519`;
- скрипт автонастройки (`setup-windows.ps1` + `УСТАНОВКА.bat` для Windows, либо
  `setup-mac.sh` + `УСТАНОВКА.command` для Mac) с подставленным логином и именем ключа;
- README с пошаговой инструкцией.

Генерация папок из шаблонов — см. `setup-new-pc/_templates/` (плейсхолдеры
`__USER__`, `__KEYNAME__`, `__DISP__`).

> ⚠️ **Критичные нюансы кодировки клиентских файлов:**
> - **`.ps1`** — UTF-8 **с BOM** (иначе PowerShell 5.1 ломается на кириллице).
> - **`.bat`** — **ASCII + CRLF**. LF-окончания ломают `cmd.exe` (строки выполняются
>   как команды, `'X' is not recognized`). Кириллицу в `.bat` не класть — весь текст
>   печатает `.ps1`. `.bat` должен лишь вызывать `powershell -File ...setup-windows.ps1`.
> - **`.sh` / `.command`** — без BOM, окончания **LF**.

> 💡 **Панель Codex в VSCode (удобнее терминала):** на удалённой стороне поставить
> расширение `code --install-extension openai.chatgpt`, затем Reload Window. Даёт
> чат-панель, использует ту же ChatGPT-авторизацию.

---

## 7. Проверка «из коробки» (под обычным пользователем)

```bash
ssh -i ключ ivan@SERVER_IP
codex login status                       # Logged in
bash -ic 'echo $DOCKER_HOST'             # сокет rootless
npm install -g cowsay && cowsay ok       # npm -g без root
python3 -m venv /tmp/v && /tmp/v/bin/pip install pytest   # venv+pip
docker run --rm hello-world              # rootless docker
ls /home/ДРУГОЙ_ПОЛЬЗОВАТЕЛЬ             # Permission denied — изоляция
sudo -n true                             # запрещено — OK
```

---

## 8. Обслуживание

- **Токен выбило у всех (только общий аккаунт):** `sudo codex-reauth.sh` — снимает
  клиентов, перелогинивает эталонного пользователя через device-auth (нужен
  браузерный шаг администратора), раздаёт всем и проверяет живость. ⚠️ Прямой
  `codex login --device-auth` + `codex-auth-sync.sh` может НЕ удержаться: фоновые
  `codex app-server` со старым отозванным токеном ре-убивают свежий логин — для
  этого и нужен отдельный скрипт.
- **Обновить CLI агента:** `npm update -g @openai/codex`. ⚠️ При строгом `UMASK`
  установка из-под root разложит пакет без прав для остальных, и у всех будет
  `command not found` — при том, что под root всё выглядит исправно. Ставьте как
  `umask 022 npm i -g …` и делайте приёмку **под обычным пользователем**:
  `sudo -u <логин> codex --version`.
- **Восстановить код из бэкапа:** `source /etc/restic/env && restic snapshots`,
  затем `restic restore latest --target /tmp/r`.
- **Проверить алерты/логи:** `/var/log/codex-{backup,monitor,auth-sync,autoreboot}.log`.
- **Перезагрузка откладывается долго (эскалация в Telegram):** `sudo reboot` вручную
  в удобное время.
- **Мониторинг места:** `df -h`; `docker system prune` (rootless — под каждым
  пользователем, системный — под root).
- **Ротация секретов:** S3-ключ — новый в панели S3 + обновить `/etc/restic/env`;
  SSH-ключ сотрудника — `deluser --remove-home` и завести заново.

---

## 9. Резюме файлов конфигурации (что бэкапить/переносить)

| Путь | Что |
|---|---|
| `/usr/local/sbin/codex-*.sh`, `tg-send.sh` | все серверные скрипты |
| `/etc/restic/env`, `/etc/restic/excludes.txt` | бэкап (ключи S3 + пароль шифрования) |
| `/etc/telegram/env` | токен/chat_id Telegram |
| `/etc/cron.d/codex-*` | расписания (backup, monitor, autoreboot, reaper, usage, auth-sync) |
| `/etc/systemd/system/user-*.slice.d/` | лимиты памяти, свопа и CPU |
| `/etc/tmpfiles.d/tmp.conf`, `/etc/login.defs` | политика `/tmp` и umask |
| `/etc/caddy/Caddyfile` (**640 root:caddy**), `/etc/codex-usage-account.env`, `/root/codex-usage-credentials.txt` | дашборд: конфиг и креды (**внесите в бэкап**) |
| `/etc/systemd/system/codex-usage-account.service`, `/etc/sudoers.d/codex-usage-account` | сервис «Аккаунт» дашборда |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52codex-noreboot.conf` | автообновления |
| `/etc/ssh/sshd_config.d/00-hardening.conf` | безопасность SSH |
| `/etc/sudoers.d/*`, `/etc/sysctl.d/99-codex-swap.conf` | sudo, swap |
| `/home/*/projects` | **код пользователей** (бэкапится в S3) |

Полная документация проекта — [`DOCUMENTATION.md`](DOCUMENTATION.md).
