# Windows native services. Loaded only on Windows; no installation or administrator rights required.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CutterMk.Native' -as [type])) {
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;
namespace CutterMk {
 public struct RECT { public int Left,Top,Right,Bottom; public int Width {get{return Right-Left;}} public int Height {get{return Bottom-Top;}} }
 public struct POINT { public int X,Y; }
 public static class Native {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr data);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
  [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int value);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  const int DWMWA_EXTENDED_FRAME_BOUNDS=9, DWMWA_CLOAKED=14, GWL_EXSTYLE=-20;
  const int WS_EX_TOOLWINDOW=0x80, WS_EX_TRANSPARENT=0x20;
  static readonly IntPtr PER_MONITOR_AWARE_V2=new IntPtr(-4);

  // Per-monitor DPI v2 so captures and the overlay line up on mixed-DPI setups. The process call fails
  // when the host's manifest already set an awareness; the thread call still applies to this thread.
  public static string EnableDpiAwareness(){
   string mode="unaware";
   try { if(SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)) mode="per-monitor-v2 (process)"; } catch(EntryPointNotFoundException) {
    try { if(SetProcessDpiAwareness(2)==0) mode="per-monitor (process)"; } catch(DllNotFoundException) { if(SetProcessDPIAware()) mode="system"; } catch(EntryPointNotFoundException) { if(SetProcessDPIAware()) mode="system"; }
   }
   try { if(SetThreadDpiAwarenessContext(PER_MONITOR_AWARE_V2)!=IntPtr.Zero) mode=mode.StartsWith("per-monitor-v2")?mode:"per-monitor-v2 (thread)"; } catch(EntryPointNotFoundException) {}
   return mode;
  }
  public static bool IsCloaked(IntPtr h){int v;try{return DwmGetWindowAttribute(h,DWMWA_CLOAKED,out v,4)==0&&v!=0;}catch(DllNotFoundException){return false;}}
  // Visible frame without the invisible resize borders that GetWindowRect includes on Windows 10/11.
  public static RECT FrameBounds(IntPtr h){RECT r;try{if(DwmGetWindowAttribute(h,DWMWA_EXTENDED_FRAME_BOUNDS,out r,Marshal.SizeOf(typeof(RECT)))==0&&r.Width>0&&r.Height>0)return r;}catch(DllNotFoundException){}GetWindowRect(h,out r);return r;}
  static bool Capturable(IntPtr h){
   if(!IsWindowVisible(h)||IsIconic(h)||IsCloaked(h))return false;
   int ex=GetWindowLong(h,GWL_EXSTYLE);
   return (ex&WS_EX_TOOLWINDOW)==0&&(ex&WS_EX_TRANSPARENT)==0;
  }
  static string Title(IntPtr h){var s=new StringBuilder(512);GetWindowText(h,s,s.Capacity);return s.ToString();}
  public static List<Win> Windows() {
   var result=new List<Win>();
   EnumWindows((h,d)=>{if(!Capturable(h))return true;string t=Title(h);RECT r=FrameBounds(h);if(t.Length>0&&r.Width>100&&r.Height>60)result.Add(new Win{Id=h.ToInt64(),Title=t,X=r.Left,Y=r.Top,Width=r.Width,Height=r.Height});return true;},IntPtr.Zero);
   return result;
  }
  // Frames of capturable top-level windows, top of the z-order first, for overlay snapping.
  public static Rectangle[] SnapRects(){
   var result=new List<Rectangle>();
   EnumWindows((h,d)=>{if(!Capturable(h)||Title(h).Length==0)return true;RECT r=FrameBounds(h);if(r.Width>20&&r.Height>20)result.Add(Rectangle.FromLTRB(r.Left,r.Top,r.Right,r.Bottom));return true;},IntPtr.Zero);
   return result.ToArray();
  }
  public static Win Window(long id){var h=new IntPtr(id);if(!IsWindowVisible(h))throw new Exception("Window unavailable");RECT r=FrameBounds(h);if(r.Width<1||r.Height<1)throw new Exception("Window unavailable");return new Win{Id=id,Title=Title(h),X=r.Left,Y=r.Top,Width=r.Width,Height=r.Height};}
  public static long Foreground(){return GetForegroundWindow().ToInt64();}
  // Captures a window's own content even when other windows cover it (PrintWindow with
  // PW_RENDERFULLCONTENT). Falls back to the screen pixels when the app renders nothing.
  public static Bitmap CaptureWindow(long id, out string method){
   var h=new IntPtr(id);
   if(!IsWindowVisible(h))throw new Exception("Window unavailable");
   if(IsIconic(h))throw new Exception("That window is minimized. Restore it, then capture again.");
   RECT outer;GetWindowRect(h,out outer);RECT frame=FrameBounds(h);
   if(outer.Width<1||outer.Height<1||(long)outer.Width*outer.Height>120000000L)throw new Exception("Invalid window size");
   // 32bppRgb: GDI leaves alpha at 0, which would make an ARGB result transparent.
   var full=new Bitmap(outer.Width,outer.Height,PixelFormat.Format32bppRgb);
   bool printed;
   using(var g=Graphics.FromImage(full)){IntPtr hdc=g.GetHdc();try{printed=PrintWindow(h,hdc,2);}finally{g.ReleaseHdc(hdc);}}
   var crop=Rectangle.Intersect(new Rectangle(frame.Left-outer.Left,frame.Top-outer.Top,frame.Width,frame.Height),new Rectangle(0,0,outer.Width,outer.Height));
   if(printed&&crop.Width>0&&crop.Height>0&&!IsBlank(full,crop)){
    method="PrintWindow";
    try{return full.Clone(crop,PixelFormat.Format32bppRgb);}finally{full.Dispose();}
   }
   full.Dispose();
   method="screen";
   var shot=new Bitmap(frame.Width,frame.Height,PixelFormat.Format32bppArgb);
   using(var g=Graphics.FromImage(shot)){g.CopyFromScreen(frame.Left,frame.Top,0,0,shot.Size,CopyPixelOperation.SourceCopy);}
   return shot;
  }
  // Some GPU-rendered apps answer PrintWindow with an all-black image.
  static bool IsBlank(Bitmap b, Rectangle area){
   for(int iy=0;iy<16;iy++)for(int ix=0;ix<16;ix++){
    var c=b.GetPixel(area.X+(area.Width-1)*ix/15,area.Y+(area.Height-1)*iy/15);
    if((c.R|c.G|c.B)!=0)return false;
   }
   return true;
  }
  // Brings an existing window whose title contains the text to the front. Returns false if none.
  public static bool ActivateByTitle(string contains){
   IntPtr found=IntPtr.Zero;
   EnumWindows((h,d)=>{if(IsWindowVisible(h)&&Title(h).IndexOf(contains,StringComparison.OrdinalIgnoreCase)>=0){found=h;return false;}return true;},IntPtr.Zero);
   if(found==IntPtr.Zero)return false;
   if(IsIconic(found))ShowWindow(found,9);
   return SetForegroundWindow(found);
  }
 }
 public class Win {public long Id{get;set;}public string Title{get;set;}public int X{get;set;}public int Y{get;set;}public int Width{get;set;}public int Height{get;set;}}

 // Frozen-desktop selection: hover snaps to a window, click takes it, drag draws a region.
 // Shift keeps a square, Esc cancels. A loupe shows the pixels, coordinates and colour under the cursor.
 public class RegionOverlay:Form {
  readonly Bitmap shot, dim; readonly Rectangle[] snaps;
  Point start, cursor; bool down, dragging; Rectangle hover=Rectangle.Empty, lastDrawn=Rectangle.Empty, lastLoupe=Rectangle.Empty;
  public Rectangle Selection{get;private set;} public bool Accepted{get;private set;} public bool SnappedToWindow{get;private set;}
  const int LoupeCells=15, LoupeZoom=8, LoupeSize=LoupeCells*LoupeZoom;
  public RegionOverlay(Rectangle bounds, Bitmap screenshot, Rectangle[] snapRects){
   StartPosition=FormStartPosition.Manual;Bounds=bounds;FormBorderStyle=FormBorderStyle.None;TopMost=true;ShowInTaskbar=false;
   KeyPreview=true;Cursor=Cursors.Cross;
   SetStyle(ControlStyles.AllPaintingInWmPaint|ControlStyles.UserPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.Opaque,true);
   shot=screenshot;
   var list=new List<Rectangle>();
   foreach(var r in snapRects??new Rectangle[0]){var local=Rectangle.Intersect(new Rectangle(r.X-bounds.X,r.Y-bounds.Y,r.Width,r.Height),new Rectangle(0,0,bounds.Width,bounds.Height));if(local.Width>0&&local.Height>0)list.Add(local);}
   snaps=list.ToArray();
   // Pre-darken once so painting only copies pixels.
   dim=new Bitmap(shot.Width,shot.Height,PixelFormat.Format32bppPArgb);
   using(var g=Graphics.FromImage(dim)){g.DrawImageUnscaled(shot,0,0);using(var b=new SolidBrush(Color.FromArgb(120,4,6,14)))g.FillRectangle(b,0,0,dim.Width,dim.Height);}
  }
  protected override void OnShown(EventArgs e){base.OnShown(e);Activate();Focus();cursor=PointToClient(Control.MousePosition);UpdateHover();Invalidate();}
  protected override void WndProc(ref Message m){
   // Keep the frozen frame at physical size if it spans monitors with different DPI.
   if(m.Msg==0x02E0||m.Msg==0x02E4)return;
   base.WndProc(ref m);
  }
  Rectangle Current(){
   if(dragging){
    int x2=cursor.X,y2=cursor.Y;
    if((ModifierKeys&Keys.Shift)!=0){int side=Math.Max(Math.Abs(x2-start.X),Math.Abs(y2-start.Y));x2=start.X+Math.Sign(x2-start.X)*side;y2=start.Y+Math.Sign(y2-start.Y)*side;}
    return Rectangle.Intersect(Rectangle.FromLTRB(Math.Min(start.X,x2),Math.Min(start.Y,y2),Math.Max(start.X,x2),Math.Max(start.Y,y2)),ClientRectangle);
   }
   return hover;
  }
  void UpdateHover(){hover=Rectangle.Empty;foreach(var r in snaps)if(r.Contains(cursor)){hover=r;break;}}
  Rectangle LoupeRect(){
   int x=cursor.X+24,y=cursor.Y+24;
   if(x+LoupeSize+2>ClientSize.Width)x=cursor.X-24-LoupeSize;
   if(y+LoupeSize+44>ClientSize.Height)y=cursor.Y-24-LoupeSize-44;
   return new Rectangle(x,y,LoupeSize+2,LoupeSize+44);
  }
  void Repaint(){
   var sel=Current();var loupe=LoupeRect();
   var damage=Rectangle.Union(Rectangle.Union(Grow(lastDrawn),Grow(sel)),Rectangle.Union(lastLoupe,loupe));
   lastDrawn=sel;lastLoupe=loupe;Invalidate(damage);
  }
  static Rectangle Grow(Rectangle r){if(r.IsEmpty)return r;r.Inflate(64,40);return r;}
  protected override void OnMouseMove(MouseEventArgs e){
   base.OnMouseMove(e);cursor=e.Location;
   if(down&&!dragging&&(Math.Abs(cursor.X-start.X)>4||Math.Abs(cursor.Y-start.Y)>4))dragging=true;
   if(!dragging)UpdateHover();
   Repaint();
  }
  protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);if(e.Button==MouseButtons.Left){down=true;start=e.Location;cursor=start;}else if(e.Button==MouseButtons.Right){Finish(false);}}
  protected override void OnMouseUp(MouseEventArgs e){
   base.OnMouseUp(e);if(!down||e.Button!=MouseButtons.Left)return;down=false;cursor=e.Location;
   var r=Current();SnappedToWindow=!dragging&&!hover.IsEmpty;dragging=false;
   if(r.Width>3&&r.Height>3){Selection=new Rectangle(r.X+Left,r.Y+Top,r.Width,r.Height);Finish(true);}
   else Repaint();
  }
  protected override void OnKeyDown(KeyEventArgs e){
   if(e.KeyCode==Keys.Escape){Finish(false);return;}
   if(e.KeyCode==Keys.ShiftKey&&dragging)Repaint();
   base.OnKeyDown(e);
  }
  protected override void OnKeyUp(KeyEventArgs e){if(e.KeyCode==Keys.ShiftKey&&dragging)Repaint();base.OnKeyUp(e);}
  void Finish(bool ok){Accepted=ok;DialogResult=ok?DialogResult.OK:DialogResult.Cancel;Close();}
  protected override void OnPaint(PaintEventArgs e){
   var g=e.Graphics;var clip=e.ClipRectangle;
   g.DrawImage(dim,clip,clip,GraphicsUnit.Pixel);
   var sel=Current();
   if(!sel.IsEmpty){
    g.DrawImage(shot,sel,sel,GraphicsUnit.Pixel);
    using(var pen=new Pen(Color.FromArgb(139,125,255),2)){g.DrawRectangle(pen,sel.X,sel.Y,sel.Width-1,sel.Height-1);}
    string label=sel.Width+" \u00D7 "+sel.Height+(dragging?"":"  \u00B7  click to capture window");
    DrawTag(g,label,new Point(sel.X,Math.Max(0,sel.Y-26)));
   }
   DrawLoupe(g);
  }
  void DrawTag(Graphics g,string text,Point at){
   using(var font=new Font("Segoe UI",9f,FontStyle.Bold)){
    var size=g.MeasureString(text,font);var box=new RectangleF(at.X,at.Y,size.Width+12,size.Height+6);
    using(var b=new SolidBrush(Color.FromArgb(235,26,32,51)))g.FillRectangle(b,box);
    g.DrawString(text,font,Brushes.White,at.X+6,at.Y+3);
   }
  }
  void DrawLoupe(Graphics g){
   var box=LoupeRect();var img=new Rectangle(box.X+1,box.Y+1,LoupeSize,LoupeSize);
   var src=new Rectangle(cursor.X-LoupeCells/2,cursor.Y-LoupeCells/2,LoupeCells,LoupeCells);
   g.FillRectangle(Brushes.Black,box);
   g.InterpolationMode=InterpolationMode.NearestNeighbor;g.PixelOffsetMode=PixelOffsetMode.Half;
   g.DrawImage(shot,img,src,GraphicsUnit.Pixel);
   g.InterpolationMode=InterpolationMode.Default;g.PixelOffsetMode=PixelOffsetMode.Default;
   using(var pen=new Pen(Color.FromArgb(139,125,255),1)){g.DrawRectangle(pen,img.X+(LoupeCells/2)*LoupeZoom,img.Y+(LoupeCells/2)*LoupeZoom,LoupeZoom,LoupeZoom);g.DrawRectangle(pen,box.X,box.Y,box.Width-1,box.Height-1);}
   string hex="-";
   if(cursor.X>=0&&cursor.Y>=0&&cursor.X<shot.Width&&cursor.Y<shot.Height){var c=shot.GetPixel(cursor.X,cursor.Y);hex="#"+c.R.ToString("X2")+c.G.ToString("X2")+c.B.ToString("X2");}
   using(var font=new Font("Segoe UI",8.5f)){
    g.DrawString((cursor.X+Left)+", "+(cursor.Y+Top),font,Brushes.White,box.X+6,box.Y+LoupeSize+5);
    g.DrawString(hex,font,Brushes.White,box.X+6,box.Y+LoupeSize+22);
   }
  }
  protected override void Dispose(bool disposing){if(disposing)dim.Dispose();base.Dispose(disposing);}
 }
}
'@
}
$script:CutterMkDpiMode = try { [CutterMk.Native]::EnableDpiAwareness() } catch { 'unknown' }
function Get-CutterMkWindows { @([CutterMk.Native]::Windows() | Select-Object -First 250) }
# Timings describe capture/encoding only. Region selection time is recorded separately.
$script:CutterMkCaptureStats = @{ acquireMs=0; encodeMs=0; selectionMs=0 }
function Convert-CutterMkBitmapToPng([Drawing.Bitmap]$Bitmap, [double]$AcquisitionMs=0, [double]$SelectionMs=0) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $memory=[IO.MemoryStream]::new()
    try {
        $Bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
        $result=$memory.ToArray()
        $timer.Stop()
        $script:CutterMkCaptureStats=@{ acquireMs=[math]::Round($AcquisitionMs,1); encodeMs=[math]::Round($timer.Elapsed.TotalMilliseconds,1); selectionMs=[math]::Round($SelectionMs,1) }
        return ,$result
    } finally { $memory.Dispose() }
}
# Waits before capturing so menus and hover states can be opened. Bounded to 0-10 seconds.
function Wait-CutterMkDelay([int]$Seconds) {
    if ($Seconds -gt 0) { Start-Sleep -Seconds ([Math]::Min(10, $Seconds)) }
}
function Get-CutterMkRect([Drawing.Rectangle]$rect) {
    if ($rect.Width -le 0 -or $rect.Height -le 0 -or ([long]$rect.Width * $rect.Height) -gt 120000000) {
        throw 'Invalid capture dimensions'
    }
    $bmp=[Drawing.Bitmap]::new($rect.Width,$rect.Height)
    $gfx=[Drawing.Graphics]::FromImage($bmp)
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $gfx.CopyFromScreen($rect.Left,$rect.Top,0,0,$bmp.Size,[Drawing.CopyPixelOperation]::SourceCopy)
        $timer.Stop()
        return Convert-CutterMkBitmapToPng $bmp $timer.Elapsed.TotalMilliseconds
    } finally { $gfx.Dispose();$bmp.Dispose() }
}
# Window capture that ignores whatever covers the window (including the CutterMk studio itself).
function Get-CutterMkWindowCapture([long]$Id) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $method=$null
    $bmp=[CutterMk.Native]::CaptureWindow($Id,[ref]$method)
    $timer.Stop()
    try {
        $script:CutterMkLastWindowMethod=$method
        return Convert-CutterMkBitmapToPng $bmp $timer.Elapsed.TotalMilliseconds
    } finally { $bmp.Dispose() }
}
function Copy-CutterMkBitmapArea([Drawing.Bitmap]$Original,[Drawing.Rectangle]$Area) {
    if ($Area.Width -le 0 -or $Area.Height -le 0 -or ([long]$Area.Width*$Area.Height) -gt 120000000 -or
        $Area.X -lt 0 -or $Area.Y -lt 0 -or $Area.Right -gt $Original.Width -or $Area.Bottom -gt $Original.Height) {
        throw 'Selection outside captured image'
    }
    # GDI+ rectangle clone is a lossless pixel copy and avoids resampling.
    return $Original.Clone($Area,$Original.PixelFormat)
}
function Get-CutterMkRegion {
    $virtual=[Windows.Forms.SystemInformation]::VirtualScreen
    if ($virtual.Width -le 0 -or $virtual.Height -le 0 -or ([long]$virtual.Width*$virtual.Height) -gt 120000000) { throw 'Desktop exceeds capture limits' }
    # Window frames are read before the freeze, so hover snapping matches what is on screen.
    $snaps=[CutterMk.Native]::SnapRects()
    $background=[Drawing.Bitmap]::new($virtual.Width,$virtual.Height)
    $gfx=[Drawing.Graphics]::FromImage($background)
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $gfx.CopyFromScreen($virtual.Left,$virtual.Top,0,0,$background.Size,[Drawing.CopyPixelOperation]::SourceCopy)
        $timer.Stop()
        $acquireMs=$timer.Elapsed.TotalMilliseconds
    } finally { $gfx.Dispose() }
    try {
        $overlay=[CutterMk.RegionOverlay]::new($virtual,$background,$snaps)
        $timer=[Diagnostics.Stopwatch]::StartNew()
        try {
            # Do not re-capture the display after selection. Crop the original snapshot;
            # it avoids a second full-screen BitBlt and cannot capture the overlay.
            if ($overlay.ShowDialog() -ne [Windows.Forms.DialogResult]::OK -or -not $overlay.Accepted) { return $null }
            $selected=$overlay.Selection
        } finally { $timer.Stop();$overlay.Dispose() }
        $region=[Drawing.Rectangle]::new($selected.X-$virtual.Left,$selected.Y-$virtual.Top,$selected.Width,$selected.Height)
        $cropped=Copy-CutterMkBitmapArea $background $region
        try { return Convert-CutterMkBitmapToPng $cropped $acquireMs $timer.Elapsed.TotalMilliseconds }
        finally { $cropped.Dispose() }
    } finally { $background.Dispose() }
}
