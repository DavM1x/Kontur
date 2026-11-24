param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$index = Join-Path $root '.kontur-files.txt'
$shortcutName = 'Контур.lnk'
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Kontur'
$null = Add-Type -AssemblyName System.Windows.Forms

function Show-Result([string]$Message, [System.Windows.Forms.MessageBoxIcon]$Icon) {
    if ($Quiet) { Write-Output $Message; return }
    $null = [System.Windows.Forms.MessageBox]::Show($Message, 'Контур', 'OK', $Icon)
}

try {
    if (-not (Test-Path -LiteralPath $index -PathType Leaf)) { throw 'Список файлов установки не найден.' }
    if (-not $Quiet) {
        $answer = [System.Windows.Forms.MessageBox]::Show('Удалить «Контур» с этого компьютера?', 'Удаление «Контура»', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
    }

    $exe = Join-Path $root 'Kontur.exe'
    $auto = Join-Path $root 'Autostart.ps1'
    if (Test-Path -LiteralPath $auto -PathType Leaf) { . $auto }
    if (Get-Process -Name Kontur -ErrorAction SilentlyContinue | Where-Object Path -eq $exe) {
        throw 'Закройте окно «Контура» и повторите удаление.'
    }
    $owned = @(Get-Content -LiteralPath $index -Encoding UTF8) + '.kontur-files.txt'
    $files = foreach ($name in $owned) {
        if ($name -notmatch '^(?:[a-z0-9_.-]+|(?:assets|ui|runtime\\(?:mpv|webview2|node))\\[a-z0-9_.-]+)$' -or
            $name.Split('\') -contains '..' -or $name.Split('\') -contains '.') { throw 'Список файлов установки повреждён.' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $name))
        if (-not $path.StartsWith(($root.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Путь файла выходит за пределы установки.' }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $folder = Get-Item -LiteralPath (Split-Path -Parent $path)
            while ($folder) {
                if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Папка «Контура» содержит перенаправление.' }
                if ($folder.FullName -eq $root) { break }
                $folder = $folder.Parent
            }
            $path
        }
    }

    $bridge = Join-Path $root 'desktop.mjs'
    $pattern = '(?:^|\s|")' + [regex]::Escape($bridge) + '(?:"|\s|$)'
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object CommandLine -match $pattern)
    if ($processes.Count) {
        try {
            $origin = 'http://127.0.0.1:48371'
            Invoke-WebRequest -UseBasicParsing -Uri "$origin/stop-video" -Headers @{Origin=$origin; 'X-Kontur-Action'='set-video'} -Method Post -TimeoutSec 3 | Out-Null
        } catch {}
        foreach ($process in $processes) { Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue }
    }

    $holding = Join-Path $root ('.kontur-uninstall-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($holding) | Out-Null
    $moved = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($path in $files) {
            $saved = Join-Path $holding ([string]$moved.Count)
            [IO.File]::Move($path, $saved)
            $moved.Add(@{Source=$path; Saved=$saved})
        }
    } catch {
        for ($i=$moved.Count-1; $i -ge 0; $i--) { [IO.File]::Move($moved[$i].Saved, $moved[$i].Source) }
        [IO.Directory]::Delete($holding)
        throw 'Не удалось освободить файлы. Закройте «Контур» и повторите удаление.'
    }
    foreach ($item in $moved) { [IO.File]::Delete($item.Saved) }
    [IO.Directory]::Delete($holding)

    if (Get-Command Set-KonturAutostart -ErrorAction SilentlyContinue) { Set-KonturAutostart -Mode Disable -InstallDirectory $root }
    [IO.File]::Delete((Join-Path $root 'runtime/startup.log'))

    foreach ($dir in 'runtime/node','runtime/mpv','runtime/webview2','runtime','assets','ui') {
        $folder = Join-Path $root $dir
        if ((Test-Path -LiteralPath $folder -PathType Container) -and -not (Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1)) {
            [IO.Directory]::Delete($folder)
        }
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($location in [Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Startup')) {
        if (-not $location) { continue }
        $link = Join-Path $location $shortcutName
        if ((Test-Path -LiteralPath $link) -and $shell.CreateShortcut($link).TargetPath -eq $exe) {
            Remove-Item -LiteralPath $link
        }
    }
    if (Test-Path -LiteralPath $key) {
        if ((Get-ItemProperty -LiteralPath $key).InstallLocation -eq $root) { Remove-Item -LiteralPath $key }
    }
    if (-not (Get-ChildItem -LiteralPath $root -Force | Select-Object -First 1)) { [IO.Directory]::Delete($root) }
    Show-Result 'Программа удалена.' Information
} catch {
    if ($Quiet) { throw }
    Show-Result $_.Exception.Message Error
    exit 1
}
