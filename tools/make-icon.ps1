# Erzeugt das App-Icon (1024x1024, ohne Alphakanal) unter
# BroviRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png
# Aufruf: powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1

Add-Type -AssemblyName System.Drawing

$size = 1024
$out = Join-Path $PSScriptRoot "..\BroviRemote\Assets.xcassets\AppIcon.appiconset\AppIcon.png"

$bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

# Hintergrund: diagonaler Verlauf Nachtblau -> Blau
$rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
# Verlaufsfläche etwas größer als das Bild, sonst entsteht am Rand eine Linie
$gradRect = New-Object System.Drawing.Rectangle -4, -4, ($size + 8), ($size + 8)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $gradRect,
    ([System.Drawing.Color]::FromArgb(255, 9, 22, 56)),
    ([System.Drawing.Color]::FromArgb(255, 20, 101, 192)), 45.0
$g.FillRectangle($bg, $gradRect)

# Weicher Lichtschein hinter der Antenne
$glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$glowPath.AddEllipse(152, 60, 720, 720)
$glow = New-Object System.Drawing.Drawing2D.PathGradientBrush $glowPath
$glow.CenterColor = [System.Drawing.Color]::FromArgb(90, 79, 195, 247)
$glow.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 79, 195, 247))
$g.FillPath($glow, $glowPath)

$cx = 512
$cy = 400

# Funkwellen links und rechts
$radii = @(115, 195, 275)
$alphas = @(255, 200, 140)
for ($i = 0; $i -lt $radii.Count; $i++) {
    $r = $radii[$i]
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($alphas[$i], 255, 255, 255)), 38
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcRect = New-Object System.Drawing.RectangleF ($cx - $r), ($cy - $r), (2 * $r), (2 * $r)
    $g.DrawArc($pen, $arcRect, -38, 76)
    $g.DrawArc($pen, $arcRect, 142, 76)
    $pen.Dispose()
}

# Antennenmast
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$mast = New-Object System.Drawing.Drawing2D.GraphicsPath
$mast.AddPolygon(@(
    (New-Object System.Drawing.PointF ($cx - 16), ($cy + 20)),
    (New-Object System.Drawing.PointF ($cx + 16), ($cy + 20)),
    (New-Object System.Drawing.PointF ($cx + 78), 650),
    (New-Object System.Drawing.PointF ($cx - 78), 650)
))
$g.FillPath($white, $mast)
$g.FillEllipse($white, ($cx - 44), ($cy - 44), 88, 88)

# Schriftzug 5G
$font = New-Object System.Drawing.Font "Segoe UI", 200, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$format = New-Object System.Drawing.StringFormat
$format.Alignment = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
$textRect = New-Object System.Drawing.RectangleF 0, 650, $size, 300
$cyan = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 129, 212, 250))
$g.DrawString("5G", $font, $cyan, $textRect, $format)

New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output "Icon gespeichert: $out"
