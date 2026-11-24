param(
    [ValidateSet('both','full','lite')][string]$Edition = 'both',
    [string]$MpvArchive,
    [Parameter(Mandatory)][string]$WebViewSdk,
    [string]$WebViewBootstrapper,
    [switch]$TestInstaller
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

function Write-LiteIcon([string]$Source, [string]$OutputPath) {
    $bytes = [IO.File]::ReadAllBytes($Source)
    $frames = for ($i = 0; $i -lt [BitConverter]::ToUInt16($bytes,4); $i++) {
        $entry = 6 + 16 * $i
        if ($bytes[$entry] -notin 64,128) {
            [pscustomobject]@{
                Header = $entry
                Size = [BitConverter]::ToUInt32($bytes,$entry + 8)
                Offset = [BitConverter]::ToUInt32($bytes,$entry + 12)
            }
        }
    }
    $writer = [IO.BinaryWriter]::new([IO.File]::Create($OutputPath))
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$frames.Count)
        $offset = [uint32](6 + 16 * $frames.Count)
        foreach ($frame in $frames) {
            $writer.Write($bytes,[int]$frame.Header,12)
            $writer.Write($offset)
            $offset = [uint32]($offset + $frame.Size)
        }
        foreach ($frame in $frames) { $writer.Write($bytes,[int]$frame.Offset,[int]$frame.Size) }
    } finally { $writer.Dispose() }
}

function Write-RustNotices([string]$Manifest, [string]$Path) {
    $hostTarget = (& rustc -vV | Where-Object { $_ -like 'host: *' }) -replace '^host: ',''
    $metadata = & cargo metadata --locked --format-version 1 --filter-platform $hostTarget --manifest-path $Manifest | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Rust dependency metadata could not be read.' }
    $active = [Collections.Generic.HashSet[string]]::new([string[]]$metadata.resolve.nodes.id)
    $licenseText = [Collections.Generic.HashSet[string]]::new()
    $outputText = [Text.StringBuilder]::new()
    foreach ($package in ($metadata.packages | Where-Object { $_.source -and $active.Contains($_.id) } | Sort-Object name)) {
        [void]$outputText.AppendLine("$($package.name) $($package.version) - $($package.license)")
        $directory = Split-Path -Parent $package.manifest_path
        $candidates = @(Get-ChildItem -LiteralPath $directory -File |
            Where-Object Name -Match '^(?:licen[sc]e|copying|notice|copyright)(?:[_.-]|$)' | Sort-Object Name)
        if ($package.license_file) { $candidates += Get-Item -LiteralPath (Join-Path $directory $package.license_file) }
        foreach ($file in $candidates) { [void]$licenseText.Add([IO.File]::ReadAllText($file.FullName)) }
    }
    foreach ($notice in $licenseText) { [void]$outputText.AppendLine().AppendLine($notice) }
    [IO.File]::WriteAllText($Path,$outputText.ToString())
}

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw '.NET Framework x64 C# compiler was not found.' }
if ((Get-FileHash -LiteralPath $WebViewSdk).Hash -ne '8DD696301D8E5AD8389F26B636329BBF35754B793974E82168B1F6DDA234EB07') {
    throw 'Expected the official Microsoft.Web.WebView2 1.0.3912.50 NuGet package.'
}
if ($Edition -ne 'lite') {
    if (-not $MpvArchive -or -not $WebViewBootstrapper) { throw 'The full edition requires libmpv and the WebView2 bootstrapper.' }
    $bootstrap = (Resolve-Path -LiteralPath $WebViewBootstrapper).Path
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw 'The WebView2 bootstrapper must have a valid Microsoft signature.'
    }
}

[IO.Directory]::CreateDirectory($output) | Out-Null
[IO.Directory]::CreateDirectory($obj) | Out-Null
$cargoDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $obj 'cargo' }
$manifest = Join-Path $repo 'rust/Cargo.toml'
$version = [regex]::Match([IO.File]::ReadAllText($manifest), '(?m)^version = "([0-9]+\.[0-9]+\.[0-9]+)"\r?$').Groups[1].Value
if (-not $version) { throw 'The Rust crate version could not be read.' }
$versionSource = Join-Path $obj 'AssemblyVersion.cs'
[IO.File]::WriteAllText($versionSource, '[assembly: System.Reflection.AssemblyVersion("' + $version + '.0")]')
& cargo build --release --locked --manifest-path $manifest --target-dir $cargoDir
if ($LASTEXITCODE -ne 0) { throw 'Rust core compilation failed.' }
$core = Join-Path $cargoDir 'release/kontur-core.exe'
$rustNotices = Join-Path $obj 'ThirdParty-Rust.txt'
Write-RustNotices $manifest $rustNotices
$layout = [IO.File]::ReadAllText((Join-Path $repo 'ui/index.html'))
$sourceIcon = Join-Path $repo 'assets/kontur.ico'
$encoding = [Text.UTF8Encoding]::new($true)
$editions = if ($Edition -eq 'both') { 'full','lite' } else { $Edition }
foreach ($kind in $editions) {
    $build = Join-Path $obj ($kind + '-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $build 'app'
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $common = 'Launch.ps1','Preview.cmd','assets/kontur-icon.png',
        'ui/ui.js','ui/online.js','ui/ui.css','ui/we-archives.js','ui/set-wallpaper.ps1','ui/web-wallpaper.ps1'
    foreach ($file in $common) { Copy-FileTo (Join-Path $repo $file) (Join-Path $stage $file) }
    Copy-FileTo $core (Join-Path $stage 'KonturCore.exe')
    $icon = Join-Path $stage 'assets/kontur.ico'
    if ($kind -eq 'lite') { Write-LiteIcon $sourceIcon $icon }
    else { Copy-FileTo $sourceIcon $icon }
    [IO.File]::WriteAllText((Join-Path $stage 'Autostart.ps1'), [IO.File]::ReadAllText((Join-Path $repo 'Autostart.ps1')), $encoding)
    [IO.File]::WriteAllText((Join-Path $stage 'Uninstall.ps1'), [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall.ps1')), $encoding)
    [IO.File]::WriteAllText((Join-Path $stage 'StopRuntime.ps1'), [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'StopRuntime.ps1')), $encoding)
    Copy-FileTo (Join-Path $repo 'docs/THIRD-PARTY.md') (Join-Path $stage 'ThirdParty.md')
    Copy-FileTo $rustNotices (Join-Path $stage 'ThirdParty-Rust.txt')
    Copy-ArchiveEntries $WebViewSdk @{
        'lib/net462/Microsoft.Web.WebView2.Core.dll'='runtime/webview2/Microsoft.Web.WebView2.Core.dll'
        'lib/net462/Microsoft.Web.WebView2.WinForms.dll'='runtime/webview2/Microsoft.Web.WebView2.WinForms.dll'
        'runtimes/win-x64/native/WebView2Loader.dll'='runtime/webview2/WebView2Loader.dll'
        'LICENSE.txt'='runtime/webview2/LICENSE.txt'; 'NOTICE.txt'='runtime/webview2/NOTICE.txt'
    } $stage
    if ($kind -eq 'full') {
        Copy-ArchiveEntries $MpvArchive @{
            'libmpv-2.dll'='runtime/mpv/libmpv-2.dll'; 'LICENSE.LGPL'='runtime/mpv/LICENSE.LGPL'
        } $stage
        $html = $layout -replace '(?m)^[ \t]*<!-- full:(?:begin|end) -->\r?\n',''
        $font = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo 'assets/PixelifySans.ttf')))
        $styles = [IO.File]::ReadAllText((Join-Path $repo 'ui/full.css')).Replace('__PIXELIFY_FONT__', $font)
        [IO.File]::WriteAllText((Join-Path $stage 'ui/full.css'),$styles)
        foreach ($file in 'ui/appearance.js','assets/day.wav','assets/night.wav','assets/theme-day.png','assets/theme-night.png','assets/PixelifySans-LICENSE.txt') {
            Copy-FileTo (Join-Path $repo $file) (Join-Path $stage $file)
        }
    } else {
        $html = $layout -replace '(?ms)^[ \t]*<!-- full:begin -->.*?^[ \t]*<!-- full:end -->\r?\n',''
    }
    [IO.File]::WriteAllText((Join-Path $stage 'ui/index.html'), $html)
    $application = Join-Path $stage 'Kontur.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/win32icon:$icon" "/out:$application" $versionSource (Join-Path $repo 'native/KonturLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Native launcher compilation failed.' }
    $uninstaller = Join-Path $stage 'Uninstall.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ /reference:System.Windows.Forms.dll "/out:$uninstaller" (Join-Path $PSScriptRoot 'UninstallLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Uninstall launcher compilation failed.' }
    $playerScript = [IO.File]::ReadAllText((Join-Path $repo 'ui/video-wallpaper.ps1'))
    $playerCode = [regex]::Match($playerScript,'(?s)-TypeDefinition @"\r?\n(.*?)\r?\n"@').Groups[1].Value
    if (-not $playerCode) { throw 'The Windows video host could not be found.' }
    $playerSource = Join-Path $build 'KonturVideo.cs'
    [IO.File]::WriteAllText($playerSource,$playerCode,$encoding)
    $player = Join-Path $stage 'KonturVideo.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /codepage:65001 /optimize+ /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.dll /reference:Microsoft.CSharp.dll "/out:$player" $playerSource (Join-Path $repo 'native/KonturVideoEntry.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Native video host compilation failed.' }

    $payload = Join-Path $build 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$payload,[IO.Compression.CompressionLevel]::Optimal,$false)
    $name = if ($kind -eq 'full') { 'KonturSetup.exe' } else { 'KonturSetup-Lite.exe' }
    if ($TestInstaller) { $name = $name.Replace('.exe','-test.exe') }
    $path = Join-Path $output $name
    $options = @(
        '/nologo','/target:winexe','/platform:x64','/optimize+','/codepage:65001',
        '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.IO.Compression.dll','/reference:Microsoft.CSharp.dll',
        "/win32manifest:$PSScriptRoot\Setup.manifest", "/win32icon:$icon", "/resource:$payload,Kontur.Payload",
        "/out:$path"
    )
    if ($kind -eq 'lite') { $options += '/define:LITE_EDITION' }
    else { $options += "/resource:$bootstrap,Kontur.WebViewBootstrapper" }
    if ($TestInstaller) { $options += '/define:SETUP_TEST' }
    & $compiler @options $versionSource (Join-Path $PSScriptRoot 'Setup.cs') (Join-Path $PSScriptRoot 'Installer.cs')
    if ($LASTEXITCODE -ne 0) { throw "The $kind installer compilation failed." }
    Get-Item -LiteralPath $path | Select-Object FullName,Length
}
