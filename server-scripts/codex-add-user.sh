#!/bin/bash
# ============================================================
#  codex-add-user.sh — завести нового сотрудника на сервере Codex.
#  Создаёт пользователя, SSH-ключ, копирует Codex-авторизацию,
#  настраивает rootless Docker, окружение и папку проектов.
#
#  Использование (от root):
#     sudo codex-add-user.sh <логин> [admin]
#  Примеры:
#     sudo codex-add-user.sh ivan          # обычный изолированный пользователь
#     sudo codex-add-user.sh petr admin    # второй админ (sudo + root-доступ)
#
#  В конце печатает приватный ключ — отдайте его сотруднику
#  (положите в его персональную папку как codex_<логин>_ed25519).
# ============================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "Запускайте через sudo / от root."; exit 1; fi
U="${1:-}"; MODE="${2:-normal}"
if [ -z "$U" ]; then echo "Укажите логин: codex-add-user.sh <логин> [admin]"; exit 1; fi
if id "$U" >/dev/null 2>&1; then echo "Пользователь '$U' уже существует."; exit 1; fi
if ! echo "$U" | grep -qE '^[a-z][a-z0-9_-]{1,31}$'; then echo "Логин: строчные буквы/цифры, начинать с буквы."; exit 1; fi

echo ">> Создаю пользователя $U (режим: $MODE)"
useradd -m -s /bin/bash "$U"
UIDN=$(id -u "$U")

# --- SSH ключ ---
install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
TMPK=$(mktemp -d)
ssh-keygen -t ed25519 -f "$TMPK/key" -N "" -C "codex-server-$U" >/dev/null
cat "$TMPK/key.pub" > "/home/$U/.ssh/authorized_keys"
chmod 600 "/home/$U/.ssh/authorized_keys"; chown "$U:$U" "/home/$U/.ssh/authorized_keys"

# --- Codex-авторизация (общий аккаунт) ---
install -d -m 700 -o "$U" -g "$U" "/home/$U/.codex"
cp /home/coder/.codex/auth.json "/home/$U/.codex/auth.json"
chown "$U:$U" "/home/$U/.codex/auth.json"; chmod 600 "/home/$U/.codex/auth.json"

# --- Папка проектов + tmux ---
install -d -m 755 -o "$U" -g "$U" "/home/$U/projects"
grep -q 'alias tm=' "/home/$U/.bashrc" 2>/dev/null || \
  printf 'alias tm="tmux attach -t codex || tmux new -s codex"\n' >> "/home/$U/.bashrc"

# --- subuid/subgid для rootless docker ---
grep -q "^$U:" /etc/subuid || usermod --add-subuids 100000-165535 "$U"
grep -q "^$U:" /etc/subgid || usermod --add-subgids 100000-165535 "$U"

# --- npm префикс ---
printf 'prefix=/home/%s/.npm-global\n' "$U" > "/home/$U/.npmrc"
chown "$U:$U" "/home/$U/.npmrc"

# --- Окружение в .bashrc ---
if ! grep -q 'CODEX-ENV' "/home/$U/.bashrc" 2>/dev/null; then
  {
    echo ''
    echo '# === CODEX-ENV (персональное окружение) ==='
    echo 'export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.config/composer/vendor/bin:$PATH"'
    if [ "$MODE" != "admin" ]; then
      echo "export DOCKER_HOST=\"unix:///run/user/$UIDN/docker.sock\""
    fi
  } >> "/home/$U/.bashrc"
fi
chown "$U:$U" "/home/$U/.bashrc"

if [ "$MODE" = "admin" ]; then
  echo ">> Режим admin: sudo + системный docker + прямой root-доступ"
  usermod -aG sudo,docker "$U"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > "/etc/sudoers.d/$U"
  chmod 440 "/etc/sudoers.d/$U"; visudo -c -f "/etc/sudoers.d/$U" >/dev/null
  install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  grep -qF "codex-server-$U" /root/.ssh/authorized_keys || cat "$TMPK/key.pub" >> /root/.ssh/authorized_keys
else
  echo ">> Режим normal: изоляция + персональный rootless Docker"
  loginctl enable-linger "$U"
  for i in $(seq 1 15); do [ -d "/run/user/$UIDN" ] && break; sleep 1; done
  RUNENV="XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus PATH=/usr/bin:/bin:/usr/sbin:/sbin"
  sudo -u "$U" env $RUNENV dockerd-rootless-setuptool.sh install --force >/dev/null 2>&1 || echo "   (rootless docker: проверьте вручную)"
  sudo -u "$U" env $RUNENV systemctl --user enable docker >/dev/null 2>&1 || true
  sudo -u "$U" env $RUNENV systemctl --user start docker >/dev/null 2>&1 || true
fi

chmod 700 "/home/$U"

echo ""
echo "============================================================"
echo " Готово. Пользователь: $U   (логин на сервере)"
echo " Хост для VSCode: codex-server  (User $U)"
echo "============================================================"
echo " ПРИВАТНЫЙ КЛЮЧ (отдайте сотруднику, сохраните как"
echo " codex_${U}_ed25519 в его папке подключения):"
echo "------------------------------------------------------------"
cat "$TMPK/key"
echo "------------------------------------------------------------"
echo " Публичный ключ:"
cat "$TMPK/key.pub"
echo "============================================================"
rm -rf "$TMPK"
