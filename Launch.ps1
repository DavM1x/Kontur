param([switch]$Background, [switch]$CheckNode, [switch]$Logon)
$ErrorActionPreference = 'Stop'
$directory = $PSScriptRoot
$bridge = Join-Path $directory 'desktop.mjs'
$port = if ($env:KONTUR_PORT -match '^[0-9]{1,5}$') { [int]$env:KONTUR_PORT } else { 48371 }
$root = "http://127.0.0.1:$port"
$version = 'Kontur desktop bridge 9'

function Get-KonturStatus {
    try { (Invoke-WebRequest -UseBasicParsing -Uri "$root/status" -TimeoutSec 1).Content }
    catch { $null }
}

function Write-LogonResult([string]$Message) {
    if (-not $Logon) { return }
    try {
        $runtime = Join-Path $directory 'runtime'
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime 'startup.log'), ([DateTimeOffset]::Now.ToString('o') + ' ' + $Message))
    } catch {}
}

function Wait-LogonVideo {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        try { $playback = (Invoke-WebRequest -UseBasicParsing -Uri "$root/video-status" -TimeoutSec 2).Content }
        catch { $playback = 'unavailable' }
        if ($playback -ne 'starting') { return $playback }
        Start-Sleep -Milliseconds 350
    } while ([DateTime]::UtcNow -lt $deadline)
    return 'starting'
}

function Get-KonturNode {
    $bundled = Join-Path $directory 'runtime\node\node.exe'
    $installed = @(Get-Command node.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Source)
    $codex = @(Get-ChildItem 'C:\Program Files\WindowsApps\OpenAI.CodexPrimaryRuntime*' -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'dependencies\node\bin\node.exe' } |
        Where-Object { Test-Path -LiteralPath $_ })
    foreach ($candidate in @($bundled) + $installed + $codex) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $number = & $candidate --version 2>$null
            if ($number -match '^v([0-9]+)\.' -and [int]$Matches[1] -ge 22) { return $candidate }
        } catch {}
    }
}

if ($CheckNode) {
    if (Get-KonturNode) { exit 0 }
    exit 1
}

function Save-LegacyVideo($Owners) {
    $storage = Join-Path $directory 'runtime\active-video'
    $selection = Join-Path $storage 'selected.json'
    if (Test-Path -LiteralPath $selection) { return }
    $script = [regex]::Escape((Join-Path $directory 'ui\video-wallpaper.ps1'))
    $players = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ParentProcessId -in $Owners.ProcessId -and $_.CommandLine -match $script })
    if ($players.Count -ne 1) { return }
    $argument = [regex]::Match($players[0].CommandLine, '(?i)(?:^|\s)-Path\s+(?:"(?<file>[^"]+)"|(?<file>\S+))')
    if (-not $argument.Success) { return }
    $path = [IO.Path]::GetFullPath($argument.Groups['file'].Value)
    $temp = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar)
    $pattern = '^' + [regex]::Escape($temp) + '\\kontur-video-[^\\]+\\wallpaper\.(mp4|webm)$'
    if ($path -notmatch $pattern -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $file = [guid]::NewGuid().ToString() + [IO.Path]::GetExtension($path).ToLowerInvariant()
    $copy = Join-Path $storage $file
    $pending = Join-Path $storage ('selection-' + [guid]::NewGuid().ToString() + '.tmp')
    [IO.Directory]::CreateDirectory($storage) | Out-Null
    try {
        [IO.File]::Copy($path, $copy, $false)
        [IO.File]::WriteAllText($pending, (@{file=$file} | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($pending, $selection)
    } catch {
        [IO.File]::Delete($pending)
        [IO.File]::Delete($copy)
        throw
    }
}

function Start-KonturBridge {
    $current = Get-KonturStatus
    if ($current -eq $version) { return $true }
    $node = Get-KonturNode
    if (-not $node) { return $false }
    if ($current) {
        if ($current -notmatch '^Kontur desktop bridge(?: [2-8])?$') { return $false }
        $expected = '(?:^|\s|")' + [regex]::Escape($bridge) + '(?:"|\s|$)'
        $old = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object CommandLine -match $expected)
        if (-not $old.Count) { return $false }
        if ($current -eq 'Kontur desktop bridge 8') { Save-LegacyVideo $old }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$root/stop-video" -Method Post -Headers @{
                Origin = $root
                'X-Kontur-Action' = 'set-video'
            } -TimeoutSec 3 | Out-Null
        } catch { if ($current -eq 'Kontur desktop bridge 8') { return $false } }
        foreach ($process in $old) {
            Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
            Wait-Process -Id $process.ProcessId -Timeout 3 -ErrorAction SilentlyContinue
        }
    }
    Start-Process -FilePath $node -ArgumentList ('"' + $bridge + '"') -WindowStyle Hidden
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ((Get-KonturStatus) -eq $version) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

$mutex = [System.Threading.Mutex]::new($false, "Local\Kontur.Bridge.$port")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(20000) }
    catch [System.Threading.AbandonedMutexException] { $locked = $true }
    $available = $locked -and (Start-KonturBridge)
} catch {
    Write-LogonResult ('bridge-error ' + $_.Exception.Message)
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($Background) { return }
if ($Logon) {
    if (-not $available) { Write-LogonResult 'bridge-unavailable'; exit 1 }
    $video = Wait-LogonVideo
    if ($video -eq 'playing') { Write-LogonResult 'video-playing'; return }
    Write-LogonResult ('opening-window video=' + $video)
}

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) {
    $edge = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\EdgeCore" -Filter msedge.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
$url = if ($available) { "$root/ui/index.html" } else { ([uri](Join-Path $directory 'ui\index.html')).AbsoluteUri }
$launcher = Join-Path $directory 'Kontur.exe'
if ($edge -and (Test-Path -LiteralPath $launcher)) {
    Start-Process -FilePath $launcher -ArgumentList @('--window', ('"' + $edge + '"'), ('"' + $url + '"'))
}
elseif ($edge) { Start-Process $edge -ArgumentList "--app=$url", '--window-size=1280,850' }
else { Start-Process $url }
