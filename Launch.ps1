param([switch]$Background, [switch]$Logon)
$ErrorActionPreference = 'Stop'
$directory = $PSScriptRoot
$bridge = Join-Path $directory 'desktop.mjs'
$port = if ($env:KONTUR_PORT -match '^[0-9]{1,5}$') { [int]$env:KONTUR_PORT } else { 48371 }
$root = "http://127.0.0.1:$port"
$version = 'Kontur desktop bridge 11'

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

function Start-KonturBridge {
    $current = Get-KonturStatus
    if ($current -eq $version) { return $true }
    $core = Join-Path $directory 'KonturCore.exe'
    if ($current -or -not (Test-Path -LiteralPath $core -PathType Leaf)) { return $false }

    $process = Start-Process -FilePath $core -WorkingDirectory $directory -WindowStyle Hidden -PassThru
    try {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ((Get-KonturStatus) -eq $version) { return $true }
            if ($process.HasExited) { return $false }
            Start-Sleep -Milliseconds 150
        }
    } finally { $process.Dispose() }
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
