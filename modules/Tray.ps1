<#
  Global hotkeys and the tray icon. They run on their own STA thread with a WinForms message loop,
  so a capture starts from the keyboard and never includes the studio window.
  After a hotkey capture the image is copied to the clipboard, saved to the library, and announced
  to the studio through /api/events.
  The tray icon comes from the shared FleetHacker tray kit (vendor/fleet-tray): an S tile drawn at
  the tray's real size for this display, so it is crisp instead of a 32 px drawing shrunk to 16.
  Shutdown: when the host sets $Shared.Quit (tab closed, End session, Exit, Stop-SnapShackle.ps1, Ctrl+C)
  a timer leaves the message loop; the finally block unregisters every hotkey on this thread (the
  thread that registered them) and disposes the NotifyIcon, which removes it from the tray, so no
  ghost icon is left behind.
#>
# Get-FleetTrayIcon compiles FleetTrayArt.cs once per process (the tray thread reuses the type).
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'vendor/fleet-tray/FleetTray.ps1')

# SnapShackle's tray icon at the tray's size. If C# cannot be compiled for the kit, the shipped
# favicon is used at the same size.
function Get-SnapShackleTrayIcon([string]$Root) {
    Get-FleetTrayIcon -App snapshackle -FallbackPath (Join-Path $Root 'assets/ui/favicon.ico')
}

if (-not ('SnapShackle.HotkeyWindow' -as [type])) {
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace SnapShackle {
 public sealed class HotkeyWindow : NativeWindow, IDisposable {
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterWindowMessage(string lpString);
  const int WM_HOTKEY=0x0312; const uint MOD_NOREPEAT=0x4000;
  public event Action<int> Pressed;
  public event Action ExplorerRestarted;
  readonly List<int> ids=new List<int>();
  readonly int taskbarCreated;
  public HotkeyWindow(){
   // Default CreateParams is a top-level window, so it receives the TaskbarCreated broadcast.
   CreateHandle(new CreateParams());
   taskbarCreated=(int)RegisterWindowMessage("TaskbarCreated");
  }
  public bool Register(int id, uint modifiers, uint key){
   if(RegisterHotKey(Handle,id,modifiers|MOD_NOREPEAT,key)){ids.Add(id);return true;}
   return false;
  }
  protected override void WndProc(ref Message m){
   if(m.Msg==WM_HOTKEY){var handler=Pressed;if(handler!=null)handler(m.WParam.ToInt32());return;}
   if(taskbarCreated!=0 && m.Msg==taskbarCreated){var restarted=ExplorerRestarted;if(restarted!=null)restarted();}
   base.WndProc(ref m);
  }
  public void Dispose(){
   if(Handle==IntPtr.Zero)return;
   foreach(int id in ids)UnregisterHotKey(Handle,id);
   ids.Clear();DestroyHandle();
  }
 }
}
'@
}

# One entry per action: the preferred chord, then a fallback if another app (or Windows'
# Print Screen -> Snipping Tool setting) already owns it.
$script:SnapShackleHotkeyPlan = @(
    @{ Id = 1; Action = 'region'; Chords = @(@{ Mods = 0; Key = 0x2C; Label = 'PrtScn' }, @{ Mods = 3; Key = 0x53; Label = 'Ctrl+Alt+S' }) },
    @{ Id = 2; Action = 'window'; Chords = @(@{ Mods = 1; Key = 0x2C; Label = 'Alt+PrtScn' }, @{ Mods = 3; Key = 0x57; Label = 'Ctrl+Alt+W' }) },
    @{ Id = 3; Action = 'screen'; Chords = @(@{ Mods = 4; Key = 0x2C; Label = 'Shift+PrtScn' }, @{ Mods = 3; Key = 0x46; Label = 'Ctrl+Alt+F' }) }
)

$script:SnapShackleTrayScript = {
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
        $tray.Icon = Get-SnapShackleTrayIcon $Root
        $tray.Text = 'SnapShackle'
        $hotkeys = [SnapShackle.HotkeyWindow]::new()
        # Explorer drops tray icons when it restarts. Put this one back on TaskbarCreated.
        $hotkeys.add_ExplorerRestarted([Action]{
            try {
                $tray.Visible = $false
                $previous = $tray.Icon
                $tray.Icon = Get-SnapShackleTrayIcon $Root
                $tray.Visible = $true
                if ($previous) { $previous.Dispose() }
            } catch {}
        })
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
            # Match only this session's window title. A stale tab from the previous server does not match.
            $title = [string]$Shared.StudioTitle
            $focused = $false
            if ($title) { $focused = [SnapShackle.Native]::ActivateByTitle($title) }
            if (-not $focused) {
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
                    'region' { $png = Get-SnapShackleRegion }
                    'window' { $png = Get-SnapShackleWindowCapture ([SnapShackle.Native]::Foreground()) }
                    'screen' { $png = Get-SnapShackleRect ([Windows.Forms.Screen]::FromPoint([Windows.Forms.Control]::MousePosition).Bounds) }
                }
                if ($null -eq $png) { return }
                $name = Save-SnapShackleCapture $Library $png
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
                $tray.ShowBalloonTip(2500, 'Copied to clipboard', 'Saved to your SnapShackle library. Click to edit.', [Windows.Forms.ToolTipIcon]::None)
                # Index the text in the image for library search (this thread, so the server never waits).
                $null = Update-SnapShackleOcrIndex $Library $name $png
            } catch {
                $Shared.LastError = $_.Exception.Message
                $tray.ShowBalloonTip(4000, 'SnapShackle could not capture', $_.Exception.Message, [Windows.Forms.ToolTipIcon]::Warning)
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
            $tray.Text = 'SnapShackle (stays in the tray; right-click to exit)'
            $tray.ShowBalloonTip(3000, 'SnapShackle is in the tray', 'Hotkeys stay on after the studio closes. Right-click this icon and choose Exit to stop SnapShackle.', [Windows.Forms.ToolTipIcon]::None)
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

# Starts the tray thread. Returns a handle for Stop-SnapShackleTray.
function Start-SnapShackleTray([string]$Root, [string]$Library, $Shared) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:SnapShackleTrayScript).AddArgument($Root).AddArgument($Library).AddArgument($Shared).AddArgument($script:SnapShackleHotkeyPlan)
    $async = $ps.BeginInvoke()
    return @{ PowerShell = $ps; Runspace = $runspace; Async = $async }
}
# Returns $true when the tray thread finished cleanly, $false when it had to be abandoned.
function Stop-SnapShackleTray($Handle, $Shared) {
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
