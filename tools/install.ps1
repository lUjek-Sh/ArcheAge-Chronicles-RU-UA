param(
    [ValidateSet('Menu','Install','Remove','Status')][string]$Action = 'Menu',
    [ValidateSet('','ru','uk')][string]$Language = '',
    [string]$GameRoot = '',
    [string]$PackageRoot = '',
    [string]$SettingsPath = '',
    [string]$SteamRoot = '',
    [string]$ManifestUrl = '',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
trap { Write-Host ("Ошибка / Помилка: " + $_.Exception.Message) -ForegroundColor Red; exit 1 }
if (-not $PackageRoot) { $PackageRoot = Split-Path $PSScriptRoot -Parent }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config.json')) | ConvertFrom-Json
if ($config.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Некорректный адрес репозитория в config.json.' }
$script:Repository = [string]$config.repository

function Test-Game([string]$Path) {
    if (-not $Path) { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $Path 'X5\Content\Paks') -PathType Container) } catch { return $false }
}
function Find-Game {
    foreach ($candidate in @($GameRoot, $PackageRoot, (Split-Path $PackageRoot -Parent))) {
        if (Test-Game $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    $steam = $SteamRoot
    if (-not $steam) { try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath } catch { } }
    if ($steam) {
        $libraries = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $libraries += [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.Replace('\\','\') }
        }
        foreach ($library in ($libraries | Select-Object -Unique)) {
            foreach ($id in $config.steam_app_ids) {
                try {
                    $manifest = Join-Path $library "steamapps\appmanifest_$id.acf"
                    if (-not (Test-Path -LiteralPath $manifest)) { continue }
                    $match = [regex]::Match([IO.File]::ReadAllText($manifest), '"installdir"\s+"([^"]+)"')
                    if (-not $match.Success) { continue }
                    $candidate = Join-Path $library ('steamapps\common\' + $match.Groups[1].Value)
                    if (Test-Game $candidate) { return [IO.Path]::GetFullPath($candidate) }
                } catch { continue }
            }
        }
    }
    if ($Action -eq 'Menu' -or $Action -eq 'Remove') {
        $candidate = (Read-Host 'Укажите папку игры / Вкажіть папку гри').Trim().Trim('"')
        if (Test-Game $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Игра не найдена. Положите комплект в папку игры или передайте -GameRoot "путь".'
}
function Get-Build([string]$Game) {
    $steamapps = Split-Path (Split-Path $Game -Parent) -Parent
    foreach ($id in $config.steam_app_ids) {
        $path = Join-Path $steamapps "appmanifest_$id.acf"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $text = [IO.File]::ReadAllText($path)
        $folder = [regex]::Match($text, '"installdir"\s+"([^"]+)"').Groups[1].Value
        if ($folder -ine (Split-Path $Game -Leaf)) { continue }
        $match = [regex]::Match($text, '"buildid"\s+"(\d+)"')
        if ($match.Success) { return [long]$match.Groups[1].Value }
    }
    return 0L
}
function Assert-GameClosed {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'ArcheAgeChronicles' -or $_.ProcessName -eq 'X5-Win64-Shipping' -or $_.ProcessName -like 'xldr_ArcheageChronicles*' })
    if ($running.Count -gt 0) { throw 'Закройте игру и лаунчер / Закрийте гру та лаунчер.' }
}
function Get-Sha([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Dispose() }
}
function Read-Snapshot([string]$Path) {
    $exists = [IO.File]::Exists($Path)
    [byte[]]$bytes = @()
    if ($exists) { $bytes = [IO.File]::ReadAllBytes($Path) }
    return [pscustomobject]@{ Exists = $exists; Bytes = $bytes }
}
function Write-Atomic([string]$Path, [byte[]]$Bytes) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.aac-tmp'
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Change([string]$Path, [byte[]]$Bytes, [bool]$Delete = $false) { return [pscustomobject]@{ Path = $Path; Bytes = $Bytes; Delete = $Delete } }
function Commit-Changes([object[]]$Changes) {
    $snapshots = @{}
    foreach ($change in $Changes) { $snapshots[$change.Path] = Read-Snapshot $change.Path }
    $committed = [Collections.Generic.List[string]]::new()
    try {
        foreach ($change in $Changes) {
            if ($change.Delete) { if ([IO.File]::Exists($change.Path)) { [IO.File]::Delete($change.Path) } }
            else { Write-Atomic $change.Path $change.Bytes }
            $committed.Add($change.Path)
        }
    } catch {
        $reason = $_.Exception.Message
        $rollbackFailed = $false
        for ($i = $committed.Count - 1; $i -ge 0; $i--) {
            $path = $committed[$i]; $before = $snapshots[$path]
            try {
                if ($before.Exists) { Write-Atomic $path $before.Bytes }
                elseif ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            } catch { $rollbackFailed = $true }
        }
        if ($rollbackFailed) { throw "Операция прервана. Используйте резервные копии из $script:StateDir. Причина: $reason" }
        throw "Операция отменена, изменённые файлы восстановлены. $reason Если доступ запрещён, запустите батник от имени администратора."
    }
}
function Get-CultureBytes([string]$Path, [string]$Culture) {
    $snapshot = Read-Snapshot $Path
    [byte[]]$raw = $snapshot.Bytes
    $bom = 0; $encoding = [Text.UTF8Encoding]::new($false, $true)
    if ($raw.Length -ge 3 -and $raw[0] -eq 239 -and $raw[1] -eq 187 -and $raw[2] -eq 191) { $bom = 3 }
    elseif ($raw.Length -ge 2 -and $raw[0] -eq 255 -and $raw[1] -eq 254) { $encoding = [Text.UnicodeEncoding]::new($false, $false, $true); $bom = 2 }
    elseif ($raw.Length -ge 2 -and $raw[0] -eq 254 -and $raw[1] -eq 255) { $encoding = [Text.UnicodeEncoding]::new($true, $false, $true); $bom = 2 }
    elseif ($raw -contains 0) { throw 'Неизвестная кодировка GameUserSettings.ini; изменения отменены.' }
    $text = $encoding.GetString($raw, $bom, $raw.Length - $bom)
    $newline = if ($text.Length -eq 0 -or $text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in $text.Replace("`r`n", "`n").Split("`n")) { $lines.Add($line) }
    $section = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq '[Internationalization]') { $section = $i; break } }
    if ($section -lt 0) { if ($lines[$lines.Count - 1].Length -gt 0) { $lines.Add('') }; $lines.Add('[Internationalization]'); $lines.Add("Culture=$Culture") }
    else {
        $end = $lines.Count
        for ($i = $section + 1; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimStart().StartsWith('[')) { $end = $i; break } }
        for ($i = $end - 1; $i -gt $section; $i--) { if ($lines[$i] -imatch '^\s*Culture\s*=') { $lines.RemoveAt($i) } }
        $lines.Insert($section + 1, "Culture=$Culture")
    }
    [byte[]]$prefix = @(); if ($bom -gt 0) { $prefix = $raw[0..($bom - 1)] }
    [byte[]]$result = $prefix + $encoding.GetBytes(($lines -join $newline))
    return ,$result
}
function Get-State {
    if (-not [IO.File]::Exists($script:StatePath)) { return $null }
    $state = [IO.File]::ReadAllText($script:StatePath) | ConvertFrom-Json
    if ($state.schema_version -ne 1) { throw 'Неизвестный формат состояния установщика.' }
    $seen = @{}
    foreach ($entry in @($state.files)) {
        if ($entry.language -notin @('ru','uk') -or $seen.ContainsKey([string]$entry.language) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Некорректное состояние установщика; удаление отменено.' }
        $seen[[string]$entry.language] = $true
    }
    return $state
}
function Translation-Path([string]$Code) {
    if ($Code -notin @('ru','uk')) { throw 'Неизвестный язык.' }
    return Join-Path $script:Game "X5\Content\Localization\String\$Code\String.locres"
}
function Backup-Path([string]$Code) { return Join-Path $script:StateDir "before-$Code.locres" }
function Get-Manifest([string]$Url) {
    $uri = [uri]$Url
    if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) { throw 'Для манифеста требуется HTTPS.' }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('aac-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-WebRequest -Uri $uri -OutFile $temporary -UseBasicParsing -TimeoutSec 25
        if ((Get-Item -LiteralPath $temporary).Length -gt 524288) { throw 'Слишком большой манифест.' }
        return [IO.File]::ReadAllText($temporary) | ConvertFrom-Json
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Validate-Manifest($Manifest) {
    $version = $null
    if ($Manifest.schema_version -ne 1 -or -not [version]::TryParse([string]$Manifest.version, [ref]$version) -or [long]$Manifest.game_build -le 0) { throw 'Некорректный манифест релиза.' }
    foreach ($code in @('ru','uk')) {
        $property = $Manifest.languages.PSObject.Properties[$code]
        if (-not $property -or -not $property.Value.available) { continue }
        $entry = $property.Value
        if ($entry.asset -cne "String-$code.locres" -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$entry.size -lt 17 -or [long]$entry.size -gt 134217728) { throw "Некорректное описание языка $code." }
    }
}
function Install-Language([string]$Code) {
    Assert-GameClosed
    $remote = $null; $remoteError = ''
    $url = $ManifestUrl
    if (-not $url) { $url = "https://github.com/$script:Repository/releases/latest/download/manifest.json" }
    if (-not $Offline) {
        Write-Host 'Проверяю последний GitHub Release / Перевіряю останній GitHub Release...'
        try { $remote = Get-Manifest $url; Validate-Manifest $remote } catch { $remoteError = $_.Exception.Message; $remote = $null }
    }
    $local = $null; $localPath = Join-Path $PackageRoot 'manifest.json'
    if ([IO.File]::Exists($localPath)) { $local = [IO.File]::ReadAllText($localPath) | ConvertFrom-Json; Validate-Manifest $local }
    $manifest = $remote; $source = 'remote'
    if ($local -and (-not $remote -or [version]$local.version -gt [version]$remote.version)) { $manifest = $local; $source = 'local' }
    if (-not $manifest) { throw "Нет опубликованного релиза или локального комплекта перевода. $remoteError" }
    if (-not $remote -and -not $Offline) { Write-Host "Проверка GitHub не удалась; использую файлы из архива. $remoteError" -ForegroundColor Yellow }
    $property = $manifest.languages.PSObject.Properties[$Code]
    if (-not $property -or -not $property.Value.available) {
        if ($Code -eq 'uk') { throw 'Український переклад ще не опублікований у цьому релізі.' }
        throw 'Русский перевод ещё не опубликован в этом релизе.'
    }
    $entry = $property.Value
    $name = if ($Code -eq 'uk') { 'Українська' } else { 'Русский' }
    Write-Host "Язык / Мова: $name. Версия / Версія: $($manifest.version)."
    $build = Get-Build $script:Game
    if ($build -gt 0 -and $build -ne [long]$manifest.game_build) { Write-Host "Внимание / Увага: перевод для сборки $($manifest.game_build), установлена $build. Изменённые строки могут остаться в оригинале." -ForegroundColor Yellow }
    $target = Translation-Path $Code
    $state = Get-State
    $files = @(); if ($state) { $files = @($state.files) }
    $oldEntry = @($files | Where-Object { $_.language -eq $Code }) | Select-Object -First 1
    $want = ([string]$entry.sha256).ToLowerInvariant()
    $exists = [IO.File]::Exists($target)
    $installedHash = if ($exists) { Get-Sha $target } else { '' }
    if ($oldEntry -and $exists -and $installedHash -ne $oldEntry.sha256 -and $installedHash -ne $want) { throw 'Установленный файл изменён после установки. Сохраните свои правки перед обновлением.' }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('aac-translation-' + [guid]::NewGuid().ToString('N') + '.locres')
    try {
        $data = $null
        if ($installedHash -ne $want) {
            if ($source -eq 'remote') {
                $base = $url.Substring(0, $url.LastIndexOf('/') + 1)
                Write-Host "Скачиваю / Завантажую $($entry.asset)..."
                Invoke-WebRequest -Uri ($base + $entry.asset) -OutFile $temporary -UseBasicParsing -TimeoutSec 120
            } else {
                $localFile = Join-Path $PackageRoot ([string]$entry.asset)
                if (-not [IO.File]::Exists($localFile)) { throw "В архиве нет $($entry.asset). Распакуйте весь комплект." }
                [IO.File]::Copy($localFile, $temporary, $true)
            }
            if ((Get-Item -LiteralPath $temporary).Length -ne [long]$entry.size -or (Get-Sha $temporary) -ne $want) { throw 'Размер или SHA256 скачанного файла не совпал. Игра не изменена.' }
            $data = [IO.File]::ReadAllBytes($temporary)
            $magic = [byte[]]@(14,20,116,117,103,74,3,252,74,21,144,157,195,55,127,27)
            for ($i = 0; $i -lt 16; $i++) { if ($data[$i] -ne $magic[$i]) { throw 'Файл не является locres. Игра не изменена.' } }
        } else { Write-Host 'Уже установлен актуальный файл; повторное скачивание не требуется.' }
        $changes = [Collections.Generic.List[object]]::new()
        if (-not $oldEntry) {
            if ([IO.File]::Exists((Backup-Path $Code))) { throw 'Найдена резервная копия без состояния установщика. Сохраните её перед новой установкой.' }
            if ($exists) { $changes.Add((Change (Backup-Path $Code) ([IO.File]::ReadAllBytes($target)))) }
            $oldEntry = [pscustomobject]@{ language = $Code; had_original = $exists; sha256 = $want }
            $files += $oldEntry
        }
        $oldEntry.sha256 = $want
        if ($null -ne $data) { $changes.Add((Change $target $data)) }
        $changes.Add((Change $script:IniPath (Get-CultureBytes $script:IniPath $Code)))
        $newState = [ordered]@{ schema_version = 1; repository = $script:Repository; language = $Code; version = [string]$manifest.version; game_build = [long]$manifest.game_build; installed_utc = (Get-Date).ToUniversalTime().ToString('o'); files = @($files) }
        $changes.Add((Change $script:StatePath ([Text.UTF8Encoding]::new($false).GetBytes(($newState | ConvertTo-Json -Depth 8)))))
        Commit-Changes @($changes.ToArray())
        if ((Get-Sha $target) -ne $want) { throw 'Контрольная сумма установленного файла не совпала.' }
        Write-Host "Готово / Готово! Установлен / Встановлено: $name, $($manifest.version)." -ForegroundColor Green
        if ($entry.coverage) { Write-Host "Переведено: $($entry.coverage.translated) / $($entry.coverage.total)." }
        Write-Host 'Если язык не изменился, проверьте параметры запуска Steam: они могут переопределять Culture.'
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Remove-Translation {
    Assert-GameClosed
    $state = Get-State
    $changes = [Collections.Generic.List[object]]::new()
    if ($state) {
        foreach ($entry in @($state.files)) {
            $target = Translation-Path $entry.language
            if ([IO.File]::Exists($target) -and (Get-Sha $target) -ne $entry.sha256) { throw 'Файл перевода изменён после установки. Сначала сохраните свои изменения; автоматическое удаление отменено.' }
            $backup = Backup-Path $entry.language
            if ($entry.had_original) {
                if (-not [IO.File]::Exists($backup)) { throw "Не найдена резервная копия $backup; удаление отменено." }
                $changes.Add((Change $target ([IO.File]::ReadAllBytes($backup))))
                $changes.Add((Change $backup @() $true))
            } else { $changes.Add((Change $target @() $true)) }
        }
        $changes.Add((Change $script:StatePath @() $true))
    }
    $changes.Add((Change $script:IniPath (Get-CultureBytes $script:IniPath 'en')))
    Commit-Changes @($changes.ToArray())
    Write-Host 'Перевод удалён, выбран английский / Переклад видалено, вибрано англійську.' -ForegroundColor Green
    if (-not $state) { Write-Host 'Файлы других установщиков не удалялись.' }
}

$script:Game = Find-Game
$script:StateDir = Join-Path $script:Game 'X5\Localization-RU-UA'
$script:StatePath = Join-Path $script:StateDir 'state.json'
$script:IniPath = $SettingsPath
if (-not $script:IniPath) { $script:IniPath = Join-Path $env:LOCALAPPDATA 'X5\Saved\Config\Windows\GameUserSettings.ini' }
Write-Host "ArcheAge Chronicles — RU / UA`n$script:Game"
if ($Action -eq 'Menu') {
    $state = Get-State
    if ($state) { Write-Host "Установлено / Встановлено: $($state.language), $($state.version)" }
    Write-Host '1 — Русский: установить / обновить'
    Write-Host '2 — Українська: встановити / оновити'
    Write-Host '3 — Удалить перевод / Видалити переклад'
    Write-Host '0 — Выход / Вихід'
    $answer = Read-Host 'Выберите / Виберіть'
    switch ($answer.Trim()) {
        '1' { $Action = 'Install'; $Language = 'ru' }
        '2' { $Action = 'Install'; $Language = 'uk' }
        '3' { $Action = 'Remove' }
        '0' { return }
        default { throw 'Выберите 0, 1, 2 или 3 / Виберіть 0, 1, 2 або 3.' }
    }
}
switch ($Action) {
    'Install' { if (-not $Language) { throw 'Укажите -Language ru или uk.' }; Install-Language $Language }
    'Remove' { Remove-Translation }
    'Status' { $state = Get-State; if ($state) { Write-Host ($state | ConvertTo-Json -Depth 8) } else { Write-Host 'Перевод не установлен / Переклад не встановлено.' } }
}
