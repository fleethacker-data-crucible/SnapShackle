# Windows native services. Loaded only on Windows; no installation or administrator rights required.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('Lasso.Native' -as [type])) {
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;
namespace Lasso {
 public struct RECT { public int Left,Top,Right,Bottom; public int Width {get{return Right-Left;}} public int Height {get{return Bottom-Top;}} }
 public static class Native {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr data);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  public static List<Win> Windows() {var result=new List<Win>();EnumWindows((h,d)=>{if(!IsWindowVisible(h))return true;var s=new StringBuilder(512);GetWindowText(h,s,s.Capacity);RECT r;if(s.Length>0&&GetWindowRect(h,out r)&&r.Width>100&&r.Height>60)result.Add(new Win{Id=h.ToInt64(),Title=s.ToString(),X=r.Left,Y=r.Top,Width=r.Width,Height=r.Height});return true;},IntPtr.Zero);return result;}
  public static Win Window(long id){RECT r;var h=new IntPtr(id);if(!IsWindowVisible(h)||!GetWindowRect(h,out r)||r.Width<1||r.Height<1)throw new Exception("Window unavailable");return new Win{Id=id,X=r.Left,Y=r.Top,Width=r.Width,Height=r.Height};}
 }
 public class Win {public long Id{get;set;}public string Title{get;set;}public int X{get;set;}public int Y{get;set;}public int Width{get;set;}public int Height{get;set;}}
 public class RegionOverlay:Form {
  Point start, end;bool dragging; public Rectangle Selection{get;private set;} public bool Accepted{get;private set;}
  public RegionOverlay(Rectangle bounds, Bitmap screenshot){StartPosition=FormStartPosition.Manual;Bounds=bounds;FormBorderStyle=FormBorderStyle.None;TopMost=true;ShowInTaskbar=false;DoubleBuffered=true;Cursor=Cursors.Cross;BackgroundImage=screenshot;BackgroundImageLayout=ImageLayout.None;KeyPreview=true;Opacity=.90;}
  protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);if(e.Button==MouseButtons.Left){start=e.Location;end=start;dragging=true;Invalidate();}}
  protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);if(dragging){end=e.Location;Invalidate();}}
  protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);if(!dragging)return;dragging=false;end=e.Location;var r=Rectangle.FromLTRB(Math.Min(start.X,end.X),Math.Min(start.Y,end.Y),Math.Max(start.X,end.X),Math.Max(start.Y,end.Y));if(r.Width>3&&r.Height>3){Selection=new Rectangle(r.X+Left,r.Y+Top,r.Width,r.Height);Accepted=true;DialogResult=DialogResult.OK;Close();}}
  protected override void OnKeyDown(KeyEventArgs e){if(e.KeyCode==Keys.Escape){DialogResult=DialogResult.Cancel;Close();}base.OnKeyDown(e);}
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);if(dragging){var r=Rectangle.FromLTRB(Math.Min(start.X,end.X),Math.Min(start.Y,end.Y),Math.Max(start.X,end.X),Math.Max(start.Y,end.Y));using(var pen=new Pen(Color.Red,2)){e.Graphics.DrawRectangle(pen,r);}using(var brush=new SolidBrush(Color.FromArgb(50,255,60,80))){e.Graphics.FillRectangle(brush,r);}}}
 }
}
'@
}
try { [Lasso.Native]::SetProcessDPIAware() | Out-Null } catch {}
function Get-LassoWindows { @([Lasso.Native]::Windows() | Select-Object -First 250) }
# Timings describe capture/encoding only. Region selection time is recorded separately.
$script:LassoCaptureStats = @{ acquireMs=0; encodeMs=0; selectionMs=0 }
function Convert-LassoBitmapToPng([Drawing.Bitmap]$Bitmap, [double]$AcquisitionMs=0, [double]$SelectionMs=0) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $memory=[IO.MemoryStream]::new()
    try {
        $Bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
        $result=$memory.ToArray()
        $timer.Stop()
        $script:LassoCaptureStats=@{ acquireMs=[math]::Round($AcquisitionMs,1); encodeMs=[math]::Round($timer.Elapsed.TotalMilliseconds,1); selectionMs=[math]::Round($SelectionMs,1) }
        return ,$result
    } finally { $memory.Dispose() }
}
function Get-LassoRect([Drawing.Rectangle]$rect) {
    if ($rect.Width -le 0 -or $rect.Height -le 0 -or ([long]$rect.Width * $rect.Height) -gt 120000000) {
        throw 'Invalid capture dimensions'
    }
    $bmp=[Drawing.Bitmap]::new($rect.Width,$rect.Height)
    $gfx=[Drawing.Graphics]::FromImage($bmp)
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $gfx.CopyFromScreen($rect.Left,$rect.Top,0,0,$bmp.Size,[Drawing.CopyPixelOperation]::SourceCopy)
        $timer.Stop()
        return Convert-LassoBitmapToPng $bmp $timer.Elapsed.TotalMilliseconds
    } finally { $gfx.Dispose();$bmp.Dispose() }
}
function Copy-LassoBitmapArea([Drawing.Bitmap]$Original,[Drawing.Rectangle]$Area) {
    if ($Area.Width -le 0 -or $Area.Height -le 0 -or ([long]$Area.Width*$Area.Height) -gt 120000000 -or
        $Area.X -lt 0 -or $Area.Y -lt 0 -or $Area.Right -gt $Original.Width -or $Area.Bottom -gt $Original.Height) {
        throw 'Selection outside captured image'
    }
    # GDI+ rectangle clone is a lossless pixel copy and avoids resampling.
    return $Original.Clone($Area,$Original.PixelFormat)
}
function Get-LassoRegion {
    $virtual=[Windows.Forms.SystemInformation]::VirtualScreen
    if ($virtual.Width -le 0 -or $virtual.Height -le 0 -or ([long]$virtual.Width*$virtual.Height) -gt 120000000) { throw 'Desktop exceeds capture limits' }
    $background=[Drawing.Bitmap]::new($virtual.Width,$virtual.Height)
    $gfx=[Drawing.Graphics]::FromImage($background)
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $gfx.CopyFromScreen($virtual.Left,$virtual.Top,0,0,$background.Size,[Drawing.CopyPixelOperation]::SourceCopy)
        $timer.Stop()
        $acquireMs=$timer.Elapsed.TotalMilliseconds
    } finally { $gfx.Dispose() }
    try {
        $overlay=[Lasso.RegionOverlay]::new($virtual,$background)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try {
            # Do not re-capture the display after selection. Crop the original snapshot;
            # it avoids a second full-screen BitBlt and cannot capture the overlay.
            if ($overlay.ShowDialog() -ne [Windows.Forms.DialogResult]::OK -or -not $overlay.Accepted) { return $null }
            $selected=$overlay.Selection
        } finally { $timer.Stop();$overlay.Dispose() }
        $region=[Drawing.Rectangle]::new($selected.X-$virtual.Left,$selected.Y-$virtual.Top,$selected.Width,$selected.Height)
        $cropped=Copy-LassoBitmapArea $background $region
        try { return Convert-LassoBitmapToPng $cropped $acquireMs $timer.Elapsed.TotalMilliseconds }
        finally { $cropped.Dispose() }
    } finally { $background.Dispose() }
}