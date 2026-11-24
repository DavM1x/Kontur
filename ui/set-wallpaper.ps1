[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ImagePath,
    [string] $WallpaperPath,
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$inputFile = Get-Item -LiteralPath $ImagePath
if ($inputFile -isnot [IO.FileInfo] -or $inputFile.Length -gt 64MB) {
    throw 'Wallpaper must be an image file no larger than 64 MB.'
}

$source = [Drawing.Image]::FromFile($inputFile.FullName, $false)
try {
    $supportedFormats = @(
        [Drawing.Imaging.ImageFormat]::Png.Guid
        [Drawing.Imaging.ImageFormat]::Jpeg.Guid
        [Drawing.Imaging.ImageFormat]::Bmp.Guid
    )
    if ($source.RawFormat.Guid -notin $supportedFormats) {
        throw 'Wallpaper must be a PNG, JPEG, or BMP image.'
    }
    if ([long] $source.Width * $source.Height -gt 40000000) {
        throw 'Wallpaper exceeds the 40-megapixel limit.'
    }

    $bitmap = [Drawing.Bitmap]::new($source.Width, $source.Height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Black)
            $graphics.DrawImage($source, 0, 0, $bitmap.Width, $bitmap.Height)
        }
        finally {
            $graphics.Dispose()
        }

        if ($ValidateOnly) {
            Write-Output ('{0}x{1}' -f $bitmap.Width, $bitmap.Height)
            return
        }

        if (-not $WallpaperPath) {
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            $sha = (Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $WallpaperPath = [IO.Path]::Combine($localAppData, 'Kontur', 'wallpapers', "$sha.bmp")
        }
        $targetFile = [IO.Path]::GetFullPath($WallpaperPath)
        if ([IO.Path]::GetExtension($targetFile) -ine '.bmp' -or $targetFile -ieq $inputFile.FullName) {
            throw 'The wallpaper output must be a distinct BMP path.'
        }
        $targetFolder = [IO.Path]::GetDirectoryName($targetFile)
        [void] [IO.Directory]::CreateDirectory($targetFolder)
        $temporaryPath = [IO.Path]::Combine($targetFolder, [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $bitmap.Save($temporaryPath, [Drawing.Imaging.ImageFormat]::Bmp)
            if ([IO.File]::Exists($targetFile)) {
                [IO.File]::Replace($temporaryPath, $targetFile, [System.Management.Automation.Language.NullString]::Value)
            }
            else {
                [IO.File]::Move($temporaryPath, $targetFile)
            }
        }
        finally {
            [IO.File]::Delete($temporaryPath)
        }
    }
    finally {
        $bitmap.Dispose()
    }
}
finally {
    $source.Dispose()
}

Add-Type -TypeDefinition @"
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class KonturWallpaper
{
    private const uint SetDesktopWallpaper = 0x0014;
    private const uint UpdateProfile = 0x0001;
    private const uint SendChange = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, string path, uint flags);

    public static void Apply(string path)
    {
        if (!SystemParametersInfo(SetDesktopWallpaper, 0, path, UpdateProfile | SendChange))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
[KonturWallpaper]::Apply($targetFile)
