<#
Обработчик ссылок cloudcli-open: для Windows - «Показать в проводнике» из CloudCLI.

Что делает. Регистрирует для текущего пользователя схему ссылок cloudcli-open:
(HKCU, без прав администратора) и кладёт рядом маленький скрипт. По клику в
CloudCLI браузер спрашивает «Открыть приложение?», и скрипт переводит путь
на сервере в папку на этом компьютере (обычно синхронизируемую папку Nextcloud)
и выделяет файл в проводнике. Файлы только выделяются, не запускаются.
Фоновых процессов и автозагрузки нет: скрипт живёт ровно на время клика.

Запуск: правый клик по файлу -> «Выполнить с помощью PowerShell», или
  powershell -ExecutionPolicy Bypass -File install-windows.ps1 [-From /home/me/work/ -To D:\Nextcloud\work]
  powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Place ae00     # раскладка места Свода
  powershell -ExecutionPolicy Bypass -File install-windows.ps1 -Uninstall

Повторный запуск обновляет скрипт, а config.json (соответствие папок) оставляет.
Соответствие папок правится в %LOCALAPPDATA%\CloudcliOpen\config.json.
#>
param(
    [string]$From = '',
    [string]$To = '',
    [string]$Place = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$Scheme     = 'cloudcli-open'
$Dir        = Join-Path $env:LOCALAPPDATA 'CloudcliOpen'
$ConfigPath = Join-Path $Dir 'config.json'
$Script     = Join-Path $Dir 'reveal.ps1'
$ClassKey   = "HKCU:\Software\Classes\$Scheme"
$PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Utf8Bom    = New-Object Text.UTF8Encoding $true

function Done([string]$text) {
    Write-Host ''
    Write-Host $text
    if (-not $env:CLOUDCLI_OPEN_NO_PAUSE) { Read-Host 'Enter - закрыть' | Out-Null }
}

if ($Uninstall) {
    Remove-Item -LiteralPath $ClassKey -Recurse -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Dir -Recurse -ErrorAction SilentlyContinue
    Done 'Удалено.'
    return
}

# Папки синхронизации из настроек клиента Nextcloud. Qt-клиент пишет не-латиницу
# в ini как \xNNNN, поэтому раскодируем.
function Find-NextcloudDirs {
    $cfg = Join-Path $env:APPDATA 'Nextcloud\nextcloud.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { return }
    foreach ($line in Get-Content -LiteralPath $cfg -Encoding UTF8) {
        if ($line -match '\\localPath=(.+)$') {
            $path = [regex]::Replace($Matches[1], '\\x([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
            ($path -replace '/', '\').TrimEnd('\')
        }
    }
}

function Read-Folder([string]$prompt, [string]$default) {
    $answer = Read-Host "$prompt [$default]"
    $value = if ($answer) { $answer.Trim('"', ' ') } else { $default }
    $value = $value.TrimEnd('\')
    if (-not $value -or -not (Test-Path -LiteralPath $value -PathType Container)) { throw "Папки нет: '$value'" }
    $value
}

$reveal = @'
<#
Обработчик ссылок cloudcli-open: - вызывается браузером по клику «Показать в проводнике».
Ставится install-windows.ps1 из CloudCLI. Настройки - config.json рядом, журнал - log.txt.
#>
param([string]$Url = '')

$ErrorActionPreference = 'Stop'

$LogPath = Join-Path $PSScriptRoot 'log.txt'
$Config  = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# Длинный префикс первым: /home/x/nextcloud/work/ должен победить /home/x/nextcloud/.
$Map     = @($Config.map | Sort-Object { $_.from.Length } -Descending)

# Синк может отставать от агента на пару минут, так что клик может обогнать файл.
# Немного ждём, потом открываем папку, куда он придёт.
$WaitForFileSec = 5

function Write-Log([string]$line) {
    try {
        if ([IO.File]::Exists($LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) { Remove-Item -LiteralPath $LogPath }
        Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 's'), $line) -Encoding UTF8
    } catch {}
}

function Show-Message([string]$text) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($text, 'Показать в проводнике')
}

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Foreground {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    // Windows не даёт фоновому процессу выводить окна наверх - проводник открылся бы
    // за браузером. Пока наш поток приклеен к вводу активного окна, это разрешено.
    public static void Raise(IntPtr hWnd) {
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint me = GetCurrentThreadId();
        bool attached = fg != 0 && fg != me && AttachThreadInput(me, fg, true);
        try {
            if (IsIconic(hWnd)) ShowWindow(hWnd, 9); // SW_RESTORE
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
        } finally {
            if (attached) AttachThreadInput(me, fg, false);
        }
    }
}
"@

$Shell = New-Object -ComObject Shell.Application

function Test-Exists([string]$path) { [IO.File]::Exists($path) -or [IO.Directory]::Exists($path) }

# Путь на сервере -> путь на этом компьютере. $null, если путь не из настроенных
# папок или пытается выйти за их корень.
function Resolve-LocalPath([string]$remote) {
    if (($remote -split '/') -contains '..') { return $null }
    foreach ($m in $Map) {
        $from = ([string]$m.from).TrimEnd('/')
        if ($remote -cne $from -and -not $remote.StartsWith("$from/", [StringComparison]::Ordinal)) { continue }

        $root = [IO.Path]::GetFullPath([string]$m.to).TrimEnd('\')
        $rest = $remote.Substring($from.Length).TrimStart('/') -replace '/', '\'
        # Имена с символами, запрещёнными в Windows (например ':'), сюда не синкаются.
        try { $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rest)).TrimEnd('\') } catch { return $null }

        if ($full -ieq $root -or $full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
            return @{ Full = $full; Root = $root }
        }
        return $null
    }
    return $null
}

function Get-ExistingAncestor([string]$path, [string]$root) {
    $dir = [IO.Path]::GetDirectoryName($path)
    while ($dir -and -not [IO.Directory]::Exists($dir)) { $dir = [IO.Path]::GetDirectoryName($dir) }
    if ($dir -and ($dir -ieq $root -or $dir.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase))) { return $dir }
    return $null
}

# Окна проводника парами "hwnd|папка": новая вкладка в старом окне тоже даёт новую пару.
function Get-ExplorerWindows {
    foreach ($w in $Shell.Windows()) {
        try { [pscustomobject]@{ Hwnd = [long]$w.HWND; Path = ([string]$w.Document.Folder.Self.Path).TrimEnd('\') } } catch {}
    }
}

function Set-ExplorerForeground([string]$folder, [string[]]$before) {
    $target = $folder.TrimEnd('\')
    $match = @()
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 200
        $match = @(Get-ExplorerWindows | Where-Object { $_.Path -ieq $target })
        $fresh = @($match | Where-Object { $before -notcontains "$($_.Hwnd)|$($_.Path)" })
        if ($fresh.Count) { [Foreground]::Raise([IntPtr]$fresh[-1].Hwnd); return }
    } while ([DateTime]::UtcNow -lt $deadline)
    # Проводник мог показать папку в окне, которое уже было открыто.
    if ($match.Count) { [Foreground]::Raise([IntPtr]$match[-1].Hwnd) }
}

function Show-InExplorer([string]$path) {
    $isFile = [IO.File]::Exists($path)
    $folder = if ($isFile) { [IO.Path]::GetDirectoryName($path) } else { $path }
    $before = @(Get-ExplorerWindows | ForEach-Object { "$($_.Hwnd)|$($_.Path)" })

    # Файл только выделяем, не открываем: explorer.exe с путём к файлу запустил бы его.
    if ($isFile) { Start-Process explorer.exe -ArgumentList "/select,`"$path`"" }
    else         { Start-Process explorer.exe -ArgumentList "`"$path`"" }

    try { Set-ExplorerForeground $folder $before } catch { Write-Log "raise failed: $_" }
}

try {
    # Браузер отдаёт ссылку целиком: cloudcli-open:%2Fhome%2F...
    $encoded = $Url -replace '^cloudcli-open:(//)?', ''
    $remote = [Uri]::UnescapeDataString($encoded)
    if (-not $remote.StartsWith('/')) {
        Write-Log "bad url $Url"
        Show-Message "Не понял ссылку: $Url"
        exit 1
    }

    $loc = Resolve-LocalPath $remote
    if (-not $loc) {
        Write-Log "reject $remote"
        Show-Message "Этот путь не настроен на этом компьютере:`n$remote`n`nСоответствие папок - в $PSScriptRoot\config.json"
        exit 1
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitForFileSec)
    while (-not (Test-Exists $loc.Full) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }

    if (Test-Exists $loc.Full) {
        Show-InExplorer $loc.Full
        Write-Log "open $remote"
        exit 0
    }

    $folder = Get-ExistingAncestor $loc.Full $loc.Root
    if ($folder) {
        Show-InExplorer $folder
        Write-Log "pending $remote"
        exit 0
    }

    Write-Log "no root $($loc.Root)"
    Show-Message "Папки нет на этом компьютере: $($loc.Root)`nПроверь, что синхронизация запущена."
    exit 1
} catch {
    Write-Log "error: $_"
    Show-Message "Ошибка: $_"
    exit 1
}
'@

New-Item -ItemType Directory -Force -Path $Dir | Out-Null

if (Test-Path -LiteralPath $ConfigPath) {
    Write-Host "config.json уже есть, оставляю: $ConfigPath"
} else {
    if ($Place) {
        # Раскладка места Свода: work/ места лежит в папке work внутри Nextcloud,
        # nextcloud/ места - это корень Nextcloud.
        $found = @(Find-NextcloudDirs | Select-Object -Unique)
        if ($found.Count) { Write-Host "Найдены папки Nextcloud: $($found -join '; ')" }
        $nc = if ($To) { $To.TrimEnd('\') } else { Read-Folder 'Папка Nextcloud на этом компьютере' $(if ($found.Count) { $found[0] } else { '' }) }
        $map = @(
            [ordered]@{ from = "/home/$Place/work/";      to = (Join-Path $nc 'work') }
            [ordered]@{ from = "/home/$Place/nextcloud/"; to = $nc }
        )
    } else {
        if (-not $From) {
            Write-Host 'Какая папка на сервере соответствует какой папке на этом компьютере.'
            Write-Host 'Путь на сервере - как его показывает CloudCLI, например /home/me/work/'
            $From = (Read-Host 'Папка на сервере').Trim()
        }
        if (-not $From.StartsWith('/')) { throw "Путь на сервере должен начинаться с '/': '$From'" }
        if (-not $To) {
            $found = @(Find-NextcloudDirs | Select-Object -Unique)
            $To = Read-Folder 'Папка на этом компьютере' $(if ($found.Count) { $found[0] } else { '' })
        }
        $map = @([ordered]@{ from = ($From.TrimEnd('/') + '/'); to = $To.TrimEnd('\') })
    }
    $config = [ordered]@{ map = $map }
    [IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-Host "Записан $ConfigPath"
}

[IO.File]::WriteAllText($Script, $reveal, $Utf8Bom)

# Схема ссылок для текущего пользователя. Аргумент - ссылка целиком: она
# процентно закодирована, так что пробелов и кавычек в ней нет.
New-Item -Path "$ClassKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -LiteralPath $ClassKey -Name '(default)' -Value 'URL:CloudCLI - показать в проводнике'
Set-ItemProperty -LiteralPath $ClassKey -Name 'URL Protocol' -Value ''
Set-ItemProperty -LiteralPath "$ClassKey\shell\open\command" -Name '(default)' `
    -Value "`"$PsExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`" `"%1`""

Done @"
Готово. Дальше:
1. В CloudCLI: Настройки -> Внешний вид -> «Показать в проводнике» - включить.
2. На ссылке на файл в чате - значок папки; в файловом дереве - правый клик.
3. Первый клик браузер спросит «Открыть приложение?» - поставь галочку «Всегда» и открой.
"@
