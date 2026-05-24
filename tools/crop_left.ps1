Add-Type -AssemblyName System.Drawing
$src = 'C:\Users\rafie\AppData\Local\Temp\bridge_shot_20260525_013802.png'
$orig = [System.Drawing.Image]::FromFile($src)
$hw = [int]($orig.Width / 2)
$bmp = New-Object System.Drawing.Bitmap($hw, $orig.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$srcRect = New-Object System.Drawing.Rectangle(0, 0, $hw, $orig.Height)
$dstRect = New-Object System.Drawing.Rectangle(0, 0, $hw, $orig.Height)
$g.DrawImage($orig, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$orig.Dispose()
$dst = 'C:\Users\rafie\OneDrive\Documents\bridge\files\left_20260525_013802.png'
$bmp.Save($dst)
$bmp.Dispose()
Write-Output $dst
