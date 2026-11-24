param(
    [ValidateSet('both','full','lite')][string]$Edition = 'both',
    [Parameter(Mandatory)][string]$MpvArchive,
    [Parameter(Mandatory)][string]$WebViewSdk,
    [Parameter(Mandatory)][string]$WebViewBootstrapper,
    [string]$NodeArchive
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$output = Join-Path $repo 'dist'
$obj = Join-Path $repo 'obj'
$compiler = Join-Path $env:windir 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Copy-FileTo([string]$InputPath, [string]$OutputPath) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
    Copy-Item -LiteralPath $InputPath -Destination $OutputPath
}

function Copy-ArchiveEntries([string]$ArchivePath, [hashtable]$Entries, [string]$Destination) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
    try {
        foreach ($entryName in $Entries.Keys) {
            $entry = $archive.GetEntry($entryName)
            if (-not $entry) { throw "Missing entry '$entryName' in $ArchivePath" }
            $destinationPath = Join-Path $Destination $Entries[$entryName]
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destinationPath)
        }
    } finally { $archive.Dispose() }
}

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '.NET Framework x64 C# compiler was not found.' }
if ((Get-FileHash -LiteralPath $WebViewSdk).Hash -ne '8DD696301D8E5AD8389F26B636329BBF35754B793974E82168B1F6DDA234EB07') {
    throw 'Expected the official Microsoft.Web.WebView2 1.0.3912.50 NuGet package.'
}
$bootstrap = (Resolve-Path -LiteralPath $WebViewBootstrapper).Path
$signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
    throw 'The WebView2 bootstrapper must have a valid Microsoft signature.'
}
if ($Edition -ne 'lite' -and (-not $NodeArchive -or
    (Get-FileHash -LiteralPath $NodeArchive).Hash -ne 'E612AF99F626AB415EA225AF6BCE5C971FEB448CB5CAE250BB1C3FA50C5F7D9F')) {
    throw 'The full edition requires the official Node.js v24.22.3 Windows x64 ZIP.'
}

[IO.Directory]::CreateDirectory($output) | Out-Null
[IO.Directory]::CreateDirectory($obj) | Out-Null
$layout = [IO.File]::ReadAllText((Join-Path $repo 'ui/index.html'))
$icon = Join-Path $repo 'assets/kontur.ico'
$encoding = [Text.UTF8Encoding]::new($true)
$editions = if ($Edition -eq 'both') { 'full','lite' } else { $Edition }
foreach ($kind in $editions) {
    $build = Join-Path $obj ($kind + '-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $build 'app'
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $common = 'desktop.mjs','web-library.mjs','Launch.ps1','Preview.cmd','assets/kontur-icon.png','assets/kontur.ico',
        'ui/ui.js','ui/ui.css','ui/we-archives.js','ui/set-wallpaper.ps1','ui/video-wallpaper.ps1','ui/web-wallpaper.ps1'
    foreach ($file in $common) { Copy-FileTo (Join-Path $repo $file) (Join-Path $stage $file) }
    [IO.File]::WriteAllText((Join-Path $stage 'Autostart.ps1'), [IO.File]::ReadAllText((Join-Path $repo 'Autostart.ps1')), $encoding)
    [IO.File]::WriteAllText((Join-Path $stage 'Uninstall.ps1'), [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall.ps1')), $encoding)
    Copy-FileTo (Join-Path $repo 'docs/THIRD-PARTY.md') (Join-Path $stage 'ThirdParty.md')
    Copy-ArchiveEntries $MpvArchive @{
        'libmpv-2.dll'='runtime/mpv/libmpv-2.dll'; 'LICENSE.LGPL'='runtime/mpv/LICENSE.LGPL'
    } $stage
    Copy-ArchiveEntries $WebViewSdk @{
        'lib/net462/Microsoft.Web.WebView2.Core.dll'='runtime/webview2/Microsoft.Web.WebView2.Core.dll'
        'lib/net462/Microsoft.Web.WebView2.WinForms.dll'='runtime/webview2/Microsoft.Web.WebView2.WinForms.dll'
        'runtimes/win-x64/native/WebView2Loader.dll'='runtime/webview2/WebView2Loader.dll'
        'LICENSE.txt'='runtime/webview2/LICENSE.txt'; 'NOTICE.txt'='runtime/webview2/NOTICE.txt'
    } $stage
    if ($kind -eq 'full') {
        $html = $layout -replace '(?m)^[ \t]*<!-- full:(?:begin|end) -->\r?\n',''
        $font = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo 'assets/PixelifySans.ttf')))
        $styles = [IO.File]::ReadAllText((Join-Path $repo 'ui/full.css')).Replace('__PIXELIFY_FONT__', $font)
        [IO.File]::WriteAllText((Join-Path $stage 'ui/full.css'),$styles)
        foreach ($file in 'ui/appearance.js','assets/day.wav','assets/night.wav','assets/theme-day.png','assets/theme-night.png','assets/PixelifySans-LICENSE.txt') {
            Copy-FileTo (Join-Path $repo $file) (Join-Path $stage $file)
        }
        Copy-ArchiveEntries $NodeArchive @{
            'node-v24.22.3-win-x64/node.exe'='runtime/node/node.exe'; 'node-v24.22.3-win-x64/LICENSE'='runtime/node/LICENSE.txt'
        } $stage
    } else {
        $html = $layout -replace '(?ms)^[ \t]*<!-- full:begin -->.*?^[ \t]*<!-- full:end -->\r?\n',''
    }
    [IO.File]::WriteAllText((Join-Path $stage 'ui/index.html'), $html)
    $application = Join-Path $stage 'Kontur.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/win32icon:$icon" "/out:$application" (Join-Path $repo 'native/KonturLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Native launcher compilation failed.' }

    $payload = Join-Path $build 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$payload,[IO.Compression.CompressionLevel]::Optimal,$false)
    $name = if ($kind -eq 'full') { 'KonturSetup.exe' } else { 'KonturSetup-Lite.exe' }
    $path = Join-Path $output $name
    $options = @(
        '/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',
        '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.IO.Compression.dll','/reference:Microsoft.CSharp.dll',
        "/win32manifest:$PSScriptRoot\Setup.manifest", "/win32icon:$icon", "/resource:$payload,Kontur.Payload",
        "/resource:$bootstrap,Kontur.WebViewBootstrapper", "/out:$path"
    )
    if ($kind -eq 'lite') { $options += '/define:LITE_EDITION' }
    & $compiler @options (Join-Path $PSScriptRoot 'Setup.cs') (Join-Path $PSScriptRoot 'Installer.cs')
    if ($LASTEXITCODE -ne 0) { throw "The $kind installer compilation failed." }
    Get-Item -LiteralPath $path | Select-Object FullName,Length
}
