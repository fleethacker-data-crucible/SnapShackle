<#
  Lasso lifecycle: the studio tab owns the local server.
  - Presence: the studio sends POST /api/heartbeat every 5 s and a "leaving" beacon on pagehide.
    The server stops itself 20 s after the last heartbeat, or 5 s after a leaving signal with no
    new heartbeat. Each tab has its own id, so Lasso stops only when no tab is alive.
    A tab whose last heartbeat said it was hidden gets 75 s: Chrome slows timers in a tab hidden
    for 5 minutes to about one a minute, and a hidden studio is normal while capturing by hotkey.
    Closing the tab still stops Lasso 5 s later through the leaving signal.
  - Never mid-write: no stop while a hotkey capture (save, clipboard, OCR index) is running.
  - Runtime files: logs\lasso-server-<pid>.json (pid, port, url, startedAt; never the session token)
    under %LOCALAPPDATA%\Lasso, where Lasso already keeps captures and settings.
  - Stop-Lasso.ps1 and the launcher use Get-LassoProcesses / Stop-LassoProcesses: runtime files
    first, then any PowerShell whose command line runs Start-Lasso.ps1. A running server is asked
    to stop through a named event (it then removes its tray icon and hotkeys itself); only a
    server that does not answer is force-stopped.
  Pure functions take the time as a parameter so tests can simulate it.
#>

$script:LassoHeartbeatTimeout = 20   # seconds without a heartbeat before Lasso stops
$script:LassoLeavingGrace = 5        # seconds after a leaving signal; a reload heartbeats well inside it
$script:LassoHiddenTimeout = 75     # seconds for a tab that reported itself hidden (throttled timers)
$script:LassoFirstContactTimeout = 120  # seconds for the opened browser to connect at all

function New-LassoPresence([Nullable[datetime]]$FirstContactBy = $null) {
    return @{ Tabs = @{}; Seen = $false; FirstContactBy = $FirstContactBy; LastTick = $null
        HeartbeatTimeout = $script:LassoHeartbeatTimeout; LeavingGrace = $script:LassoLeavingGrace
        HiddenTimeout = $script:LassoHiddenTimeout }
}

# Records a heartbeat (or, with -Leaving, the tab's unload signal) from one studio tab.
function Register-LassoPresence($Presence, [string]$Tab, [bool]$Leaving, [datetime]$Now, [bool]$Hidden = $false) {
    if ($Tab -notmatch '^[A-Za-z0-9-]{1,64}$') { $Tab = 'default' }
    $Presence.Seen = $true
    $entry = $Presence.Tabs[$Tab]
    if ($null -eq $entry) {
        # Bounded: forget dead tabs first, then the oldest.
        if ($Presence.Tabs.Count -ge 32) { Remove-LassoDeadTabs $Presence $Now }
        while ($Presence.Tabs.Count -ge 32) {
            $oldest = @($Presence.Tabs.Keys | Sort-Object { $Presence.Tabs[$_].Last })[0]
            $Presence.Tabs.Remove($oldest)
        }
        $entry = @{ Last = $Now; LeavingAt = $null; Hidden = $false }
        $Presence.Tabs[$Tab] = $entry
    }
    if ($Leaving) { $entry.LeavingAt = $Now; return }
    # Closing a tab sends a "hidden" heartbeat and the leaving beacon at nearly the same moment, in either
    # order. Only a visible tab cancels a leaving signal (a reload is a new page with a new tab id anyway).
    if ($Hidden -and $null -ne $entry.LeavingAt) { return }
    $entry.Last = $Now; $entry.LeavingAt = $null; $entry.Hidden = $Hidden
}

function Test-LassoTabAlive($Presence, $Entry, [datetime]$Now) {
    if ($null -ne $Entry.LeavingAt) { return (($Now - $Entry.LeavingAt).TotalSeconds -lt $Presence.LeavingGrace) }
    $limit = $Presence.HeartbeatTimeout
    if ($Entry.Hidden) { $limit = $Presence.HiddenTimeout }
    return (($Now - $Entry.Last).TotalSeconds -lt $limit)
}

# Called on every server tick. If the process itself was not running for a while (the PC slept),
# the tabs could not heartbeat either: give them a fresh grace period instead of stopping at once.
function Step-LassoPresenceClock($Presence, [datetime]$Now, [int]$GapSeconds = 10) {
    $last = $Presence.LastTick
    $Presence.LastTick = $Now
    if ($null -eq $last -or ($Now - $last).TotalSeconds -lt $GapSeconds) { return $false }
    foreach ($entry in @($Presence.Tabs.Values)) { if ($null -eq $entry.LeavingAt) { $entry.Last = $Now } }
    if ($null -ne $Presence.FirstContactBy) { $Presence.FirstContactBy = $Now.AddSeconds($script:LassoFirstContactTimeout) }
    return $true
}

function Remove-LassoDeadTabs($Presence, [datetime]$Now) {
    foreach ($key in @($Presence.Tabs.Keys)) {
        if (-not (Test-LassoTabAlive $Presence $Presence.Tabs[$key] $Now)) { $Presence.Tabs.Remove($key) }
    }
}

# Returns why Lasso should stop now, or $null to keep running.
function Get-LassoStopReason($Presence, [datetime]$Now, [bool]$Busy, [bool]$AutoStop) {
    if (-not $AutoStop -or $Busy) { return $null }
    if (-not $Presence.Seen) {
        if ($null -ne $Presence.FirstContactBy -and $Now -ge $Presence.FirstContactBy) {
            return 'The studio never connected; Lasso stopped.'
        }
        return $null
    }
    foreach ($entry in @($Presence.Tabs.Values)) { if (Test-LassoTabAlive $Presence $entry $Now) { return $null } }
    return 'The studio tab was closed; Lasso stopped.'
}

# LASSO_AUTO_STOP=0 (or false/off/no) keeps Lasso running after the tab closes.
function Test-LassoAutoStopEnv([string]$Value) {
    return (-not (([string]$Value).Trim() -match '^(0|false|off|no)$'))
}

# Parses a heartbeat body: {"tab":"...","leaving":true,"hidden":false,"session":"..."}.
# Returns $null when invalid. The body is never logged (it may carry the session token).
function ConvertFrom-LassoHeartbeat([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Tab = 'default'; Leaving = $false; Hidden = $false; Session = '' } }
    try { $value = $Text | ConvertFrom-Json } catch { return $null }
    # Only a JSON object is valid (not a string, number, boolean or array).
    if ($null -eq $value -or $value -is [string] -or $value -is [ValueType] -or $value -is [Array]) { return $null }
    return @{ Tab = [string]$value.tab; Leaving = ($value.leaving -eq $true); Hidden = ($value.hidden -eq $true); Session = [string]$value.session }
}

# Constant-time string comparison for the session token.
function Test-LassoSecretEquals([string]$A, [string]$B) {
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B) -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($diff -eq 0)
}

# Launcher options in the .bat style (--stay, --replace, --no-browser, --no-tray), for arguments that
# PowerShell did not bind to a parameter. Returns the switches found and anything unknown.
function Read-LassoLaunchOptions([string[]]$Arguments) {
    $options = @{ Stay = $false; Replace = $false; NoBrowser = $false; NoTray = $false; Unknown = @() }
    foreach ($a in @($Arguments)) {
        if (-not $a) { continue }
        switch -Regex ($a) {
            '^--?stay$' { $options.Stay = $true; continue }
            '^--?replace$' { $options.Replace = $true; continue }
            '^--?no-?browser$' { $options.NoBrowser = $true; continue }
            '^--?no-?tray$' { $options.NoTray = $true; continue }
            default { $options.Unknown += $a }
        }
    }
    return $options
}

# ---- runtime files and finding running instances ----

# %LOCALAPPDATA%\Lasso\logs (next to Captures and settings.json), or logs\ beside the app.
function Get-LassoRuntimeDir([string]$Root) {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'Lasso\logs') }
    return (Join-Path $Root 'logs')
}

function Get-LassoStopEventName([int]$ProcessId) { 'Local\Lasso-Stop-' + $ProcessId }

function Write-LassoRuntimeFile([string]$Dir, [int]$ProcessId, [int]$Port, [string]$Url, [bool]$Stay) {
    [void][IO.Directory]::CreateDirectory($Dir)
    $path = Join-Path $Dir ('lasso-server-' + $ProcessId + '.json')
    $info = [ordered]@{ pid = $ProcessId; port = $Port; url = $Url; startedAt = (Get-Date).ToString('o'); stay = $Stay }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $info -Compress), [Text.UTF8Encoding]::new($false))
    return $path
}

function Remove-LassoRuntimeFile([string]$Path) {
    if ($Path) { try { [IO.File]::Delete($Path) } catch {} }
}

# Running Lasso servers other than this process: Pid, Port, Url, Started, RuntimeFile.
# Runtime files whose pid is dead (or now another program) are deleted on sight.
# -RuntimeFilesOnly skips the process scan (tests, so they never touch a real Lasso).
function Get-LassoProcesses([string]$RuntimeDir, [switch]$RuntimeFilesOnly) {
    $found = @{}
    if ($RuntimeDir -and [IO.Directory]::Exists($RuntimeDir)) {
        foreach ($file in [IO.DirectoryInfo]::new($RuntimeDir).GetFiles('lasso-server-*.json')) {
            $keep = $false
            try {
                $info = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                $id = [int]$info.pid
                $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
                # A reused pid belongs to a process that started after this file was written.
                $reused = $false
                try { if ($proc -and $info.startedAt -and $proc.StartTime.ToUniversalTime() -gt ([datetime]$info.startedAt).ToUniversalTime().AddSeconds(1)) { $reused = $true } } catch { }
                if ($proc -and -not $reused -and $proc.ProcessName -match '^(powershell|pwsh)$') {
                    $keep = $true
                    if ($id -ne $PID) {
                        $found[$id] = [pscustomobject]@{ Pid = $id; Port = $info.port; Url = [string]$info.url; Started = $info.startedAt; RuntimeFile = $file.FullName }
                    }
                }
            } catch { $keep = $false }
            if (-not $keep) { Remove-LassoRuntimeFile $file.FullName }
        }
    }
    # Instances without a runtime file (older builds, or a file deleted by hand).
    if ($RuntimeFilesOnly) { return @($found.Values | Sort-Object Pid) }
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match 'Start-Lasso\.ps1' } |
            ForEach-Object {
                $id = [int]$_.ProcessId
                if (-not $found.ContainsKey($id)) {
                    $found[$id] = [pscustomobject]@{ Pid = $id; Port = $null; Url = $null; Started = $_.CreationDate; RuntimeFile = $null }
                }
            }
    } catch { }
    return @($found.Values | Sort-Object Pid)
}

# Asks each running server to stop (it removes its own tray icon, hotkeys and runtime file),
# waits for it, and force-stops only those that do not exit. Returns the PIDs that stopped.
function Stop-LassoProcesses([string]$RuntimeDir, [int]$WaitSeconds = 10, [switch]$RuntimeFilesOnly) {
    $stopped = [Collections.Generic.List[int]]::new()
    foreach ($p in Get-LassoProcesses $RuntimeDir -RuntimeFilesOnly:$RuntimeFilesOnly) {
        $proc = Get-Process -Id $p.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { Remove-LassoRuntimeFile $p.RuntimeFile; continue }
        $signal = $null
        try {
            if ([Threading.EventWaitHandle]::TryOpenExisting((Get-LassoStopEventName $p.Pid), [ref]$signal)) { [void]$signal.Set() }
        } catch { $signal = $null }
        $exited = $false
        if ($null -ne $signal) {
            try { $exited = $proc.WaitForExit($WaitSeconds * 1000) } catch { $exited = $false }
            $signal.Dispose()
        }
        if (-not $exited) {
            try {
                Stop-Process -Id $p.Pid -Force -ErrorAction Stop
                $exited = $true
            } catch {
                Write-Warning ('Could not stop Lasso PID ' + $p.Pid + ': ' + $_.Exception.Message)
            }
        }
        if ($exited) {
            $stopped.Add($p.Pid)
            Remove-LassoRuntimeFile $p.RuntimeFile
        }
    }
    return $stopped.ToArray()
}
