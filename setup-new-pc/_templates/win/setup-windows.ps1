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

# 6. Отпечаток сервера. Если он положен в комплект (known_host.txt), первое
#    подключение проверяется по нему, а не принимается на веру.
$KnownSrc  = Join-Path $ScriptDir "known_host.txt"
$KnownDst  = Join-Path $SshDir "known_hosts"
$StrictArg = "accept-new"
if (Test-Path $KnownSrc) {
    $line = ((Get-Content $KnownSrc -Raw) -replace "`r", "").Trim()
    $have = $false
    if (Test-Path $KnownDst) {
        if ((Get-Content $KnownDst -Raw) -match [regex]::Escape($line)) { $have = $true }
    }
    if (-not $have) { Add-Content -Path $KnownDst -Value $line -Encoding ascii }
    $StrictArg = "yes"
    Write-Host "Отпечаток сервера взят из комплекта (known_host.txt)"
} else {
    Write-Host "В комплекте нет known_host.txt - сервер принимается на доверии при первом подключении" -ForegroundColor Yellow
}

# 7. Проверка подключения
Write-Host ""
Write-Host "== Проверяю подключение ==" -ForegroundColor Cyan
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host "В системе нет команды ssh. Включите компонент: Параметры -> Приложения ->" -ForegroundColor Red
    Write-Host "Дополнительные компоненты -> Клиент OpenSSH, затем запустите установку заново." -ForegroundColor Red
    exit 1
}
ssh -o StrictHostKeyChecking=$StrictArg -o ConnectTimeout=15 codex-server "echo OK_CONNECTED as __USER__"
$rc = $LASTEXITCODE      # PowerShell НЕ бросает исключение на ненулевой код нативной команды

Write-Host ""
if ($rc -eq 0) {
    Write-Host "Готово. В VSCode: F1 -> Remote-SSH: Connect to Host -> codex-server" -ForegroundColor Green
    Write-Host ""
    Write-Host "ТЕПЕРЬ УДАЛИТЕ ЭТУ ПАПКУ." -ForegroundColor Yellow
    Write-Host "Ключ уже скопирован в $KeyDst. Оставшийся комплект - это второй экземпляр" -ForegroundColor Yellow
    Write-Host "пароля от сервера: во Входящих, в Загрузках, на флешке." -ForegroundColor Yellow
} else {
    Write-Host "Подключиться не удалось (код возврата $rc)." -ForegroundColor Red
    Write-Host "Что проверить: интернет; что ключ отдали именно вам; что имя пользователя верное." -ForegroundColor Red
    Write-Host "Если просит пароль - ключ не принят: покажите этот вывод администратору." -ForegroundColor Red
    exit $rc
}
