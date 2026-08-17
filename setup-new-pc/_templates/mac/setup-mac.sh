#!/usr/bin/env bash
# ============================================================
#  Настройка ПК (macOS / Linux) для подключения к серверу Codex
#  Пользователь: __USER__
#  Запуск:  bash setup-mac.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="$HOME/.ssh"
KEY_NAME="__KEYNAME__"
KEY_SRC="$SCRIPT_DIR/$KEY_NAME"
KEY_DST="$SSH_DIR/$KEY_NAME"
CONFIG="$SSH_DIR/config"

echo "== Настройка доступа к серверу Codex (пользователь __USER__) =="

# 0. Проверяем, что ключ лежит рядом со скриптом
if [ ! -f "$KEY_SRC" ]; then
    echo "ОШИБКА: рядом со скриптом не найден файл ключа '$KEY_NAME'."
    echo "Запускайте setup-mac.sh из вашей папки со всеми файлами."
    exit 1
fi

# 1. Папка ~/.ssh
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 2. Копируем ключи и снимаем «карантин» macOS (если был)
cp "$KEY_SRC" "$KEY_DST"
cp "$KEY_SRC.pub" "$KEY_DST.pub"
chmod 600 "$KEY_DST"
chmod 644 "$KEY_DST.pub"
xattr -d com.apple.quarantine "$KEY_DST" 2>/dev/null || true
echo "Ключ скопирован в $KEY_DST"

# 3. Дописываем хост в config (если его ещё нет)
if ! grep -qE "Host[[:space:]]+codex-server" "$CONFIG" 2>/dev/null; then
cat >> "$CONFIG" <<'EOF'

Host codex-server
    HostName <SERVER_IP>
    User __USER__
    IdentityFile ~/.ssh/__KEYNAME__
    IdentitiesOnly yes
    ServerAliveInterval 30
EOF
    chmod 600 "$CONFIG"
    echo "Хост добавлен в $CONFIG"
else
    echo "Хост codex-server уже есть в config — пропускаю"
fi

# 4. Расширение VSCode Remote-SSH (если команда code доступна)
if command -v code >/dev/null 2>&1; then
    echo "Устанавливаю расширение Remote-SSH..."
    code --install-extension ms-vscode-remote.remote-ssh || true
else
    echo "Команда 'code' недоступна — поставьте расширение Remote-SSH вручную в VSCode"
    echo "(значок Extensions слева -> поиск 'Remote - SSH' -> Install)."
fi

# 5. Отпечаток сервера. Если он положен в комплект (known_host.txt), первое
#    подключение проверяется по нему, а не принимается на веру.
STRICT="accept-new"
if [ -f "$SCRIPT_DIR/known_host.txt" ]; then
    LINE="$(tr -d '\r' < "$SCRIPT_DIR/known_host.txt" | sed '/^[[:space:]]*$/d')"
    touch "$SSH_DIR/known_hosts"; chmod 600 "$SSH_DIR/known_hosts"
    grep -qxF "$LINE" "$SSH_DIR/known_hosts" 2>/dev/null || echo "$LINE" >> "$SSH_DIR/known_hosts"
    STRICT="yes"
    echo "Отпечаток сервера взят из комплекта (known_host.txt)"
else
    echo "В комплекте нет known_host.txt — сервер принимается на доверии при первом подключении"
fi

# 6. Проверка подключения (не прерываем скрипт при ошибке)
echo
echo "== Проверяю подключение =="
set +e
ssh -o StrictHostKeyChecking="$STRICT" -o ConnectTimeout=15 codex-server "echo OK_CONNECTED as __USER__"
RESULT=$?
set -e
echo
if [ $RESULT -eq 0 ]; then
    echo "Готово! В VSCode: F1 (или Cmd+Shift+P) -> Remote-SSH: Connect to Host -> codex-server"
    echo
    echo "ТЕПЕРЬ УДАЛИТЕ ЭТУ ПАПКУ."
    echo "Ключ уже скопирован в $KEY_DST. Оставшийся комплект — это второй экземпляр"
    echo "пароля от сервера: в почте, в Загрузках, на флешке."
else
    echo "Подключиться не удалось (код возврата $RESULT). Проверьте интернет и повторите запуск."
    echo "Если просит пароль — выполните: chmod 600 ~/.ssh/__KEYNAME__  и запустите снова."
    exit $RESULT
fi
