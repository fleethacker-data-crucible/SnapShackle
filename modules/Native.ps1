# Windows native services. Loaded only on Windows; no installation or administrator rights required.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('SnipHero.Native' -as [type])) {
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;
namespace SnipHero {
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
try { [SnipHero.Native]::SetProcessDPIAware() | Out-Null } catch {}
function Get-SnipWindows { @([SnipHero.Native]::Windows() | Select-Object -First 250) }
function Get-SnipRect([Drawing.Rectangle]$rect) {
 if ($rect.Width -le 0 -or $rect.Height -le 0 -or ([long]$rect.Width * $rect.Height) -gt 120000000) { throw 'Invalid capture dimensions' }
 $bmp=[Drawing.Bitmap]::new($rect.Width,$rect.Height)
 $gfx=[Drawing.Graphics]::FromImage($bmp)
 try { $gfx.CopyFromScreen($rect.Left,$rect.Top,0,0,$bmp.Size);$mem=[IO.MemoryStream]::new();try {$bmp.Save($mem,[Drawing.Imaging.ImageFormat]::Png);return ,$mem.ToArray()}finally{$mem.Dispose()} }finally{$gfx.Dispose();$bmp.Dispose()}
}
function Get-SnipRegion {
 $virtual=[Windows.Forms.SystemInformation]::VirtualScreen
 $background=[Drawing.Bitmap]::new($virtual.Width,$virtual.Height)
 $gfx=[Drawing.Graphics]::FromImage($background)
 try {$gfx.CopyFromScreen($virtual.Left,$virtual.Top,0,0,$background.Size)}finally{$gfx.Dispose()}
 $overlay=[SnipHero.RegionOverlay]::new($virtual,$background)
 try {if($overlay.ShowDialog() -eq [Windows.Forms.DialogResult]::OK -and $overlay.Accepted){return Get-SnipRect $overlay.Selection};return $null}finally{$overlay.Dispose();$background.Dispose()}
}