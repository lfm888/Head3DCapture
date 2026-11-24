# Generate Sources/Assets.xcassets/AppIcon.appiconset/*.png from docs/logo.jpg
# (actool requires square, opaque PNGs — App Store icon is 1024x1024.)
param(
  [string]$Src = "docs/logo.jpg",
  [string]$OutDir = "Sources/Assets.xcassets/AppIcon.appiconset",
  [double]$Margin = 0.06
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$srcPath = Join-Path $root $Src
$outPath = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $outPath | Out-Null

# pt -> @2x/@3x pixel sizes used by iOS (iPhone only, TARGETED_DEVICE_FAMILY = 1) + marketing icon.
$targets = @(
  @{ Name = 'AppIcon-20@2x.png';    Size = 40 },
  @{ Name = 'AppIcon-20@3x.png';    Size = 60 },
  @{ Name = 'AppIcon-29@2x.png';    Size = 58 },
  @{ Name = 'AppIcon-29@3x.png';    Size = 87 },
  @{ Name = 'AppIcon-40@2x.png';    Size = 80 },
  @{ Name = 'AppIcon-40@3x.png';    Size = 120 },
  @{ Name = 'AppIcon-60@2x.png';    Size = 120 },
  @{ Name = 'AppIcon-60@3x.png';    Size = 180 },
  @{ Name = 'AppIcon-1024.png';     Size = 1024 }
)

$img = [System.Drawing.Image]::FromFile($srcPath)
try {
  foreach ($t in $targets) {
    $size = [int]$t.Size
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      # Opaque background: App Store icons must not have an alpha channel.
      $g.Clear([System.Drawing.Color]::White)
      $box = $size * (1.0 - 2.0 * $Margin)
      $scale = [Math]::Min($box / $img.Width, $box / $img.Height)
      $w = [Math]::Max(1, [int][Math]::Round($img.Width * $scale))
      $h = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
      $x = [int](($size - $w) / 2)
      $y = [int](($size - $h) / 2)
      $g.DrawImage($img, (New-Object System.Drawing.Rectangle($x, $y, $w, $h)))
    } finally { $g.Dispose() }
    $bmp.Save((Join-Path $outPath $t.Name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("{0,-22} {1}x{1}" -f $t.Name, $size)
  }
} finally { $img.Dispose() }

Write-Host "app icon set written to $outPath"
