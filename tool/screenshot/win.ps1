# Screenshot helper for Windows (#1311). ASCII only (PowerShell 5.1 reads
# BOM-less UTF-8 as ANSI). Run with: powershell -ExecutionPolicy Bypass -File win.ps1 <cmd> ...
# Shots go to $env:SHOT_DIR\shots (default %USERPROFILE%\.cache\capsicum-screenshot\shots).
# Window regex '@app' means the capsicum process window (VS Code also has a window titled "capsicum").
#   win.ps1 shot <name> [x y w h]     capture (full screen if no rect) to shots\<name>.png
#   win.ps1 click <x> <y>             left click at screen pixel
#   win.ps1 rclick <x> <y>
#   win.ps1 scroll <x> <y> <delta>    wheel (positive = up)
#   win.ps1 hscroll <x> <y> <delta>   horizontal wheel (positive = right)
#   win.ps1 drag <x1> <y1> <x2> <y2>  left-button drag
#   win.ps1 key <keys>                SendKeys syntax, e.g. {ENTER} {BS 50}  (Ctrl+A / Ctrl+Home do NOT work in capsicum)
#   win.ps1 vk <code>                 virtual key, e.g. 176 = media next track
#   win.ps1 type <utf8-file>          type text via SendInput KEYEVENTF_UNICODE (Japanese works)
#   win.ps1 typesecret <KEY>          type KEY's value from secrets.env without printing it
#   win.ps1 place <titleRegex> <x> <y> <w> <h>   move/resize so the VISIBLE frame is exactly that rect
#   win.ps1 front <titleRegex>
#   win.ps1 closeat <titleRegex> <x> <y>   send WM_CLOSE to windows at that visible top-left
#   win.ps1 list                      list top-level windows with visible rects
#   win.ps1 blur <png> <x> <y> <w> <h>  pixelate a rect in place (opaque; nothing of the original shows)
param([Parameter(Position=0)][string]$Cmd, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, int d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk; public ushort scan; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit, Size=40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int s);
  public static void TypeChar(char c) {
    INPUT[] a = new INPUT[2];
    a[0].type = 1; a[0].ki.scan = c; a[0].ki.flags = 4;
    a[1].type = 1; a[1].ki.scan = c; a[1].ki.flags = 4 | 2;
    SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static RECT Visible(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r); return r; }
}
"@
[W]::SetProcessDPIAware() | Out-Null
$shotDir = if ($env:SHOT_DIR) { $env:SHOT_DIR } else { Join-Path $env:USERPROFILE '.cache\capsicum-screenshot' }
$shots = Join-Path $shotDir 'shots'
if (-not (Test-Path $shots)) { New-Item -ItemType Directory -Force $shots | Out-Null }

function Find-Win([string]$re) {
  if ($re -eq '@app') {
    $p = Get-Process capsicum -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    return @($p.MainWindowHandle, $p.MainWindowTitle)
  }
  $script:found = @()
  $cb = [W+EnumProc]{ param($h, $l)
    if ([W]::IsWindowVisible($h)) {
      $sb = New-Object System.Text.StringBuilder 256
      [W]::GetWindowText($h, $sb, 256) | Out-Null
      $t = $sb.ToString()
      if ($t -and $t -match $re) { $script:found += ,@($h, $t) }
    }
    $true }
  [W]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  if ($script:found.Count -eq 0) { throw "no window matches $re" }
  return $script:found[0]
}

switch ($Cmd) {
  'shot' {
    $out = Join-Path $shots ($Rest[0] + '.png')
    if ($Rest.Count -ge 5) { $x=[int]$Rest[1]; $y=[int]$Rest[2]; $w=[int]$Rest[3]; $h=[int]$Rest[4] }
    else { $vs=[System.Windows.Forms.SystemInformation]::VirtualScreen; $x=$vs.X; $y=$vs.Y; $w=$vs.Width; $h=$vs.Height }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    Write-Output "$out ${w}x${h}"
  }
  'click' { [W]::SetCursorPos([int]$Rest[0], [int]$Rest[1]) | Out-Null; Start-Sleep -Milliseconds 80; [W]::mouse_event(2,0,0,0,[IntPtr]::Zero); Start-Sleep -Milliseconds 50; [W]::mouse_event(4,0,0,0,[IntPtr]::Zero) }
  'rclick' { [W]::SetCursorPos([int]$Rest[0], [int]$Rest[1]) | Out-Null; Start-Sleep -Milliseconds 80; [W]::mouse_event(8,0,0,0,[IntPtr]::Zero); Start-Sleep -Milliseconds 50; [W]::mouse_event(16,0,0,0,[IntPtr]::Zero) }
  'scroll' { [W]::SetCursorPos([int]$Rest[0], [int]$Rest[1]) | Out-Null; Start-Sleep -Milliseconds 80; [W]::mouse_event(0x800,0,0,[int]$Rest[2],[IntPtr]::Zero) }
  'drag' {
    $x1=[int]$Rest[0]; $y1=[int]$Rest[1]; $x2=[int]$Rest[2]; $y2=[int]$Rest[3]
    [W]::SetCursorPos($x1, $y1) | Out-Null; Start-Sleep -Milliseconds 100; [W]::mouse_event(2,0,0,0,[IntPtr]::Zero)
    for ($i = 1; $i -le 20; $i++) { [W]::SetCursorPos($x1 + ($x2-$x1)*$i/20, $y1 + ($y2-$y1)*$i/20) | Out-Null; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 100; [W]::mouse_event(4,0,0,0,[IntPtr]::Zero)
  }
  'vk' { $v = [byte][int]$Rest[0]; Add-Type -Namespace X -Name K -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);'; [X.K]::keybd_event($v, 0, 1, [UIntPtr]::Zero); Start-Sleep -Milliseconds 50; [X.K]::keybd_event($v, 0, 3, [UIntPtr]::Zero) }
  'hscroll' { [W]::SetCursorPos([int]$Rest[0], [int]$Rest[1]) | Out-Null; Start-Sleep -Milliseconds 80; [W]::mouse_event(0x1000,0,0,[int]$Rest[2],[IntPtr]::Zero) }
  'key' { [System.Windows.Forms.SendKeys]::SendWait($Rest[0]) }
  'type' {
    $text = [System.IO.File]::ReadAllText($Rest[0], [System.Text.Encoding]::UTF8).TrimEnd("`r", "`n")
    foreach ($c in $text.ToCharArray()) { [W]::TypeChar($c); Start-Sleep -Milliseconds 15 }
  }
  'typesecret' {
    # type the value of KEY from secrets.env without printing it
    $line = Get-Content (Join-Path $env:USERPROFILE '.config\capsicum\secrets.env') | Where-Object { $_ -match ('^\s*(export\s+)?' + $Rest[0] + '=') } | Select-Object -First 1
    if (-not $line) { throw "no $($Rest[0]) in secrets.env" }
    $v = ($line -replace ('^\s*(export\s+)?' + $Rest[0] + '='), '').Trim()
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) { $v = $v.Substring(1, $v.Length - 2) }
    foreach ($c in $v.ToCharArray()) { [W]::TypeChar($c); Start-Sleep -Milliseconds 15 }
    Write-Output ("typed {0} chars" -f $v.Length)
  }
  'front' { $f = Find-Win $Rest[0]; if ([W]::IsIconic($f[0])) { [W]::ShowWindow($f[0], 9) | Out-Null }; [W]::SetForegroundWindow($f[0]) | Out-Null; Write-Output $f[1] }
  'place' {
    $f = Find-Win $Rest[0]; $h = $f[0]
    [W]::ShowWindow($h, 9) | Out-Null
    $x=[int]$Rest[1]; $y=[int]$Rest[2]; $w=[int]$Rest[3]; $hh=[int]$Rest[4]
    [W]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $w, $hh, 0x44) | Out-Null
    Start-Sleep -Milliseconds 300
    $o = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$o) | Out-Null
    $v = [W]::Visible($h)
    $dl = $v.L - $o.L; $dt = $v.T - $o.T; $dr = $o.R - $v.R; $db = $o.B - $v.B
    [W]::SetWindowPos($h, [IntPtr]::Zero, $x - $dl, $y - $dt, $w + $dl + $dr, $hh + $dt + $db, 0x44) | Out-Null
    Start-Sleep -Milliseconds 300
    $v = [W]::Visible($h)
    Write-Output ("{0}: visible {1},{2} {3}x{4}" -f $f[1], $v.L, $v.T, ($v.R-$v.L), ($v.B-$v.T))
  }
  'closeat' {
    # close visible windows whose title matches regex AND whose visible top-left is exactly x,y
    Add-Type -Namespace X -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
    $re = $Rest[0]; $px = [int]$Rest[1]; $py = [int]$Rest[2]; $script:hits = @()
    $cb = [W+EnumProc]{ param($h, $l)
      if ([W]::IsWindowVisible($h)) { $sb = New-Object System.Text.StringBuilder 256; [W]::GetWindowText($h, $sb, 256) | Out-Null
        $v = [W]::Visible($h); if ($sb.ToString() -match $re -and $v.L -eq $px -and $v.T -eq $py) { $script:hits += $h } }
      $true }
    [W]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    foreach ($h in $script:hits) { [X.U]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
    Write-Output ("closed {0}" -f $script:hits.Count)
  }
  'list' {
    $script:all = @()
    $cb = [W+EnumProc]{ param($h, $l)
      if ([W]::IsWindowVisible($h)) { $sb = New-Object System.Text.StringBuilder 256; [W]::GetWindowText($h, $sb, 256) | Out-Null
        if ($sb.Length -gt 0) { $v = [W]::Visible($h); $script:all += ("{0},{1} {2}x{3}  {4}" -f $v.L,$v.T,($v.R-$v.L),($v.B-$v.T),$sb.ToString()) } }
      $true }
    [W]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $script:all
  }
  'blur' {
    $png = $Rest[0]; $x=[int]$Rest[1]; $y=[int]$Rest[2]; $w=[int]$Rest[3]; $h=[int]$Rest[4]
    $src = [System.Drawing.Image]::FromFile($png); $bmp = New-Object System.Drawing.Bitmap $src; $src.Dispose()
    $rect = New-Object System.Drawing.Rectangle $x, $y, $w, $h
    $part = $bmp.Clone($rect, $bmp.PixelFormat)
    $sw = [Math]::Max(1, [int]($w / 40)); $sh = [Math]::Max(1, [int]($h / 40))
    $small = New-Object System.Drawing.Bitmap $sw, $sh
    $gs = [System.Drawing.Graphics]::FromImage($small); $gs.InterpolationMode = 'HighQualityBicubic'; $gs.DrawImage($part, 0, 0, $sw, $sh); $gs.Dispose()
    $big = New-Object System.Drawing.Bitmap $w, $h
    $gb = [System.Drawing.Graphics]::FromImage($big); $gb.InterpolationMode = 'HighQualityBicubic'; $gb.PixelOffsetMode = 'Half'
    $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $gb.DrawImage($small, (New-Object System.Drawing.Rectangle 0, 0, $w, $h), 0, 0, $sw, $sh, [System.Drawing.GraphicsUnit]::Pixel, $ia); $gb.Dispose()
    # force opaque: anything semi-transparent at the edges must not let the original show through
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CompositingMode = 'SourceCopy'
    $g.DrawImageUnscaled($big, $x, $y); $g.Dispose(); $part.Dispose(); $small.Dispose(); $big.Dispose()
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Output "blurred $png"
  }
  default { Get-Content $PSCommandPath -TotalCount 12 }
}
