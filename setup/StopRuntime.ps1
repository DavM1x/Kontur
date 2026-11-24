param([Parameter(Mandatory)][string]$InstallDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$exe = Join-Path $root 'Kontur.exe'
if (Get-Process -Name Kontur -ErrorAction SilentlyContinue | Where-Object Path -eq $exe) {
    throw 'Закройте окно «Контура» и повторите попытку.'
}

$core = Join-Path $root 'KonturCore.exe'
$video = Join-Path $root 'KonturVideo.exe'
$portable = @(Get-Process -Name KonturCore,KonturVideo -ErrorAction SilentlyContinue)
$bridges = @($portable | Where-Object Path -eq $core)
$players = @($portable | Where-Object Path -eq $video)
$legacyPath = Join-Path $root 'desktop.mjs'
$mediaPath = Join-Path $root 'ui'
if ((Test-Path -LiteralPath $legacyPath -PathType Leaf) -or $bridges.Count) {
    $bridgePattern = '(?:^|\s|")' + [regex]::Escape($legacyPath) + '(?:"|\s|$)'
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        $legacy = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
            Where-Object CommandLine -match $bridgePattern)
        $bridges += $legacy | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    }
    $mediaPattern = '(?:^|\s|")' + [regex]::Escape($mediaPath) + '\\(?:video|web)-wallpaper\.ps1(?:"|\s|$)'
    $owners = @($bridges | ForEach-Object Id)
    $players += Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ParentProcessId -in $owners -and $_.CommandLine -match $mediaPattern } |
        ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}
foreach ($process in @($bridges) + @($players)) {
    if ($process.HasExited) { continue }
    Stop-Process -InputObject $process -ErrorAction SilentlyContinue
    if (-not $process.WaitForExit(4000)) { throw 'Не удалось остановить фоновый процесс «Контура».' }
}
