# ============================================================
#  Настройка ПК (Windows) для подключения к серверу Codex
#  Пользователь: __USER__
#  Обычно запускается двойным кликом по файлу УСТАНОВКА.bat
# ============================================================

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SshDir     = Join-Path $env:USERPROFILE ".ssh"
$KeyName    = "__KEYNAME__"
$KeySrc     = Join-Path $ScriptDir $KeyName
$KeyDst     = Join-Path $SshDir $KeyName
$ConfigFile = Join-Path $SshDir "config"

Write-Host "== Настройка доступа к серверу Codex (пользователь __USER__) ==" -ForegroundColor Cyan

# 1. Папка ~/.ssh
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir | Out-Null
    Write-Host "Создана папка $SshDir"
}

# 2. Копируем приватный и публичный ключ
Copy-Item $KeySrc $KeyDst -Force
Copy-Item ($KeySrc + ".pub") ($KeyDst + ".pub") -Force
Write-Host "Ключ скопирован в $KeyDst"

# 3. Права на ключ: только текущий пользователь Windows
$me = $env:USERDOMAIN + "\" + $env:USERNAME
icacls $KeyDst /inheritance:r /grant:r ($me + ":F") | Out-Null
Write-Host "Права на ключ ограничены (только вы)"

# 4. Дописываем хост в ~/.ssh/config (если его ещё нет)
$Block = @'

Host codex-server
    HostName <SERVER_IP>
    User __USER__
    IdentityFile ~/.ssh/__KEYNAME__
    IdentitiesOnly yes
    ServerAliveInterval 30
'@

$hasHost = $false
if (Test-Path $ConfigFile) {
    if ((Get-Content $ConfigFile -Raw) -match "Host\s+codex-server") { $hasHost = $true }
}
if ($hasHost) {
    Write-Host "Хост codex-server уже есть в config - пропускаю"
} else {
    Add-Content -Path $ConfigFile -Value $Block -Encoding ascii
    Write-Host "Хост добавлен в $ConfigFile"
}

# 5. Расширение VSCode Remote-SSH (если найдём VSCode)
$codeCmd = $null
$g = Get-Command code -ErrorAction SilentlyContinue
if ($g) { $codeCmd = $g.Source }
if (-not $codeCmd) {
    $pf   = [Environment]::GetEnvironmentVariable("ProgramFiles")
    $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $cands = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
        (Join-Path $pf   "Microsoft VS Code\bin\code.cmd"),
        (Join-Path $pf86 "Microsoft VS Code\bin\code.cmd")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $codeCmd = $c; break } }
}
if ($codeCmd) {
    Write-Host "Устанавливаю расширение Remote-SSH..."
    # code.cmd пишет в stderr предупреждения Node — при EAP=Stop это рвёт скрипт.
    # Делаем шаг неблокирующим: расширение некритично, его можно поставить и вручную.
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $codeCmd --install-extension ms-vscode-remote.remote-ssh 2>&1 | Out-Null
    } catch {
        Write-Host "Расширение не поставилось автоматически — поставьте вручную: Extensions -> Remote - SSH -> Install." -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $eap
    }
} else {
    Write-Host "VSCode не найден - поставьте расширение Remote-SSH вручную из VSCode." -ForegroundColor Yellow
}

# 6. Проверка подключения
Write-Host ""
Write-Host "== Проверяю подключение ==" -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 codex-server "echo OK_CONNECTED as __USER__"

Write-Host ""
Write-Host "Готово. В VSCode: F1 -> Remote-SSH: Connect to Host -> codex-server" -ForegroundColor Green
