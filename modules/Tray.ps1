<#
  Global hotkeys and the tray icon. They run on their own STA thread with a WinForms message loop,
  so a capture starts from the keyboard and never includes the studio window.
  After a hotkey capture the image is copied to the clipboard, saved to the library, and announced
  to the studio through /api/events.
  Shutdown: when the host sets $Shared.Quit (tab closed, End session, Exit, Stop-Lasso.ps1, Ctrl+C)
  a timer leaves the message loop; the finally block unregisters every hotkey on this thread (the
  thread that registered them) and disposes the NotifyIcon, which removes it from the tray, so no
  ghost icon is left behind.
#>
if (-not ('Lasso.HotkeyWindow' -as [type])) {
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace Lasso {
 public sealed class HotkeyWindow : NativeWindow, IDisposable {
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  const int WM_HOTKEY=0x0312; const uint MOD_NOREPEAT=0x4000;
  public event Action<int> Pressed;
  readonly List<int> ids=new List<int>();
  public HotkeyWindow(){ CreateHandle(new CreateParams()); }
  public bool Register(int id, uint modifiers, uint key){
   if(RegisterHotKey(Handle,id,modifiers|MOD_NOREPEAT,key)){ids.Add(id);return true;}
   return false;
  }
  protected override void WndProc(ref Message m){
   if(m.Msg==WM_HOTKEY){var handler=Pressed;if(handler!=null)handler(m.WParam.ToInt32());return;}
   base.WndProc(ref m);
  }
  public void Dispose(){
   if(Handle==IntPtr.Zero)return;
   foreach(int id in ids)UnregisterHotKey(Handle,id);
   ids.Clear();DestroyHandle();
  }
 }
 public static class TrayArt {
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
  // A small dashed red loop with a rope tail, drawn at runtime so no icon file ships.
  public static Icon Make(){
   using(var bmp=new Bitmap(32,32)){
    using(var g=Graphics.FromImage(bmp)){
     g.SmoothingMode=SmoothingMode.AntiAlias;g.Clear(Color.Transparent);
     using(var loop=new Pen(Color.FromArgb(255,73,98),3.4f)){loop.DashPattern=new float[]{2.2f,1.2f};g.DrawEllipse(loop,4,3,24,16);}
     using(var rope=new Pen(Color.FromArgb(235,235,240),2.6f)){rope.StartCap=LineCap.Round;rope.EndCap=LineCap.Round;g.DrawBezier(rope,11,18,6,25,13,29,18,30);}
     using(var knot=new SolidBrush(Color.FromArgb(255,73,98)))g.FillEllipse(knot,9,16,5,5);
    }
    IntPtr h=bmp.GetHicon();
    try{using(var tmp=Icon.FromHandle(h))return (Icon)tmp.Clone();}finally{DestroyIcon(h);}
   }
  }
 }
}
'@
}

# One entry per action: the preferred chord, then a fallback if another app (or Windows'
# Print Screen -> Snipping Tool setting) already owns it.
$script:LassoHotkeyPlan = @(
    @{ Id = 1; Action = 'region'; Chords = @(@{ Mods = 0; Key = 0x2C; Label = 'PrtScn' }, @{ Mods = 3; Key = 0x53; Label = 'Ctrl+Alt+S' }) },
    @{ Id = 2; Action = 'window'; Chords = @(@{ Mods = 1; Key = 0x2C; Label = 'Alt+PrtScn' }, @{ Mods = 3; Key = 0x57; Label = 'Ctrl+Alt+W' }) },
    @{ Id = 3; Action = 'screen'; Chords = @(@{ Mods = 4; Key = 0x2C; Label = 'Shift+PrtScn' }, @{ Mods = 3; Key = 0x46; Label = 'Ctrl+Alt+F' }) }
)

$script:LassoTrayScript = {
    param($Root, $Library, $Shared, $Plan)
    $ErrorActionPreference = 'Stop'
    try {
        # Types are already loaded in this process; these dot-sources add the functions and
        # set per-monitor DPI awareness for this thread.
        . (Join-Path $Root 'modules/Native.ps1')
        . (Join-Path $Root 'modules/Library.ps1')
        . (Join-Path $Root 'modules/Ocr.ps1')
        . (Join-Path $Root 'modules/Tray.ps1')

        $tray = [Windows.Forms.NotifyIcon]::new()
        $tray.Icon = [Lasso.TrayArt]::Make()
        $tray.Text = 'Lasso'
        $hotkeys = [Lasso.HotkeyWindow]::new()
        $labels = @{}
        foreach ($entry in $Plan) {
            foreach ($chord in $entry.Chords) {
                if ($hotkeys.Register($entry.Id, [uint32]$chord.Mods, [uint32]$chord.Key)) { $labels[$entry.Action] = $chord.Label; break }
            }
        }
        $Shared.Hotkeys = @($Plan | ForEach-Object { @{ action = $_.Action; keys = [string]$labels[$_.Action] } })

        $addEvent = {
            param($Type, $Data)
            $Shared.NextId++
            $item = @{ id = $Shared.NextId; type = $Type; at = (Get-Date).ToString('o') } + $Data
            [void]$Shared.Events.Add($item)
            while ($Shared.Events.Count -gt 50) { $Shared.Events.RemoveAt(0) }
        }
        $openStudio = {
            if (-not [Lasso.Native]::ActivateByTitle('Lasso Studio')) {
                $url = $Shared.BaseUrl
                if ($Shared.LastName) { $url += '#open=' + $Shared.LastName }
                Start-Process $url
            }
        }
        $capture = {
            param([string]$Action)
            if ($Shared.Busy) { return }
            $Shared.Busy = $true
            try {
                $png = $null
                switch ($Action) {
                    'region' { $png = Get-LassoRegion }
                    'window' { $png = Get-LassoWindowCapture ([Lasso.Native]::Foreground()) }
                    'screen' { $png = Get-LassoRect ([Windows.Forms.Screen]::FromPoint([Windows.Forms.Control]::MousePosition).Bounds) }
                }
                if ($null -eq $png) { return }
                $name = Save-LassoCapture $Library $png
                $Shared.LastName = $name
                $stream = [IO.MemoryStream]::new($png, $false)
                $image = [Drawing.Image]::FromStream($stream)
                try {
                    # Bitmap for every app, plus the original PNG bytes for apps that read "PNG".
                    $data = [Windows.Forms.DataObject]::new()
                    $data.SetImage($image)
                    $data.SetData('PNG', $false, [IO.MemoryStream]::new($png, $false))
                    [Windows.Forms.Clipboard]::SetDataObject($data, $true)
                } finally { $image.Dispose(); $stream.Dispose() }
                & $addEvent 'capture' @{ name = $name; source = $Action }
                $tray.ShowBalloonTip(2500, 'Copied to clipboard', 'Saved to your Lasso library. Click to edit.', [Windows.Forms.ToolTipIcon]::None)
                # Index the text in the image for library search (this thread, so the server never waits).
                $null = Update-LassoOcrIndex $Library $name $png
            } catch {
                $Shared.LastError = $_.Exception.Message
                $tray.ShowBalloonTip(4000, 'Lasso could not capture', $_.Exception.Message, [Windows.Forms.ToolTipIcon]::Warning)
            } finally { $Shared.Busy = $false }
        }

        $hotkeys.add_Pressed([Action[int]]{
            param($id)
            $entry = $Plan | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($entry) { & $capture $entry.Action }
        })

        $menu = [Windows.Forms.ContextMenuStrip]::new()
        $regionLabel = 'Capture region' + $(if ($labels['region']) { "`t" + $labels['region'] } else { '' })
        $screenLabel = 'Capture screen' + $(if ($labels['screen']) { "`t" + $labels['screen'] } else { '' })
        [void]$menu.Items.Add($regionLabel, $null, { & $capture 'region' })
        [void]$menu.Items.Add($screenLabel, $null, { & $capture 'screen' })
        [void]$menu.Items.Add('Open studio', $null, { & $openStudio })
        [void]$menu.Items.Add('-')
        # Exit stops everything: server, hotkeys and this icon. The host's loop sees Quit within half a second.
        [void]$menu.Items.Add('Exit', $null, {
            $Shared.StopReason = 'Exit in the tray menu.'
            $Shared.Quit = $true
        })
        $tray.ContextMenuStrip = $menu
        $tray.add_BalloonTipClicked({ & $openStudio })
        $tray.add_MouseClick({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { & $openStudio } })
        $tray.Visible = $true

        # Leave the message loop when the host stops (Ctrl+C, Quit, or an error).
        $timer = [Windows.Forms.Timer]::new()
        $timer.Interval = 400
        $timer.add_Tick({ if ($Shared.Quit) { $timer.Stop(); [Windows.Forms.Application]::ExitThread() } })
        $timer.Start()
        $Shared.TrayIcon = $tray
        $Shared.TrayReady = $true
        if ($Shared.Stay) {
            $tray.Text = 'Lasso (stays in the tray; right-click to exit)'
            $tray.ShowBalloonTip(3000, 'Lasso is in the tray', 'Hotkeys stay on after the studio closes. Right-click this icon and choose Exit to stop Lasso.', [Windows.Forms.ToolTipIcon]::None)
        }
        [Windows.Forms.Application]::Run()
    } catch {
        $Shared.TrayError = $_.Exception.Message
    } finally {
        if ($timer) { try { $timer.Stop(); $timer.Dispose() } catch {} }
        if ($hotkeys) { try { $hotkeys.Dispose() } catch {} }
        if ($tray) { try { $tray.Visible = $false; $tray.Dispose() } catch {} }
        if ($menu) { try { $menu.Dispose() } catch {} }
        $Shared.TrayIcon = $null
        $Shared.TrayReady = $false
        $Shared.TrayStopped = $true
    }
}

# Starts the tray thread. Returns a handle for Stop-LassoTray.
function Start-LassoTray([string]$Root, [string]$Library, $Shared) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:LassoTrayScript).AddArgument($Root).AddArgument($Library).AddArgument($Shared).AddArgument($script:LassoHotkeyPlan)
    $async = $ps.BeginInvoke()
    return @{ PowerShell = $ps; Runspace = $runspace; Async = $async }
}
# Returns $true when the tray thread finished cleanly, $false when it had to be abandoned.
function Stop-LassoTray($Handle, $Shared) {
    if ($null -eq $Handle) { return $true }
    $Shared.Quit = $true
    # The tray thread leaves its message loop on the next timer tick (400 ms), then cleans up itself.
    $done = $false
    try { $done = $Handle.Async.AsyncWaitHandle.WaitOne(5000) } catch {}
    if (-not $done -or -not $Shared.TrayStopped) {
        # Last resort if the thread is stuck (for example inside a capture): remove the icon from here,
        # so Windows does not keep a ghost icon. Hotkeys are released when the process exits.
        $icon = $Shared.TrayIcon
        if ($null -ne $icon) { try { $icon.Visible = $false; $icon.Dispose() } catch {} }
        # Do not wait on (or dispose) a stuck pipeline: that can block. The caller ends the process.
        try { [void]$Handle.PowerShell.BeginStop($null, $null) } catch {}
        return $false
    }
    try { $Handle.PowerShell.Dispose(); $Handle.Runspace.Dispose() } catch {}
    return $true
}
