<#
  SnapShackle lifecycle: the studio tab owns the local server.
  - Presence: the studio sends POST /api/heartbeat every 5 s and a "leaving" beacon on pagehide.
    The server stops itself 20 s after the last heartbeat, or 5 s after a leaving signal with no
    new heartbeat. Each tab has its own id, so SnapShackle stops only when no tab is alive.
    A tab whose last heartbeat said it was hidden gets 75 s: Chrome slows timers in a tab hidden
    for 5 minutes to about one a minute, and a hidden studio is normal while capturing by hotkey.
    Closing the tab still stops SnapShackle 5 s later through the leaving signal.
  - Never mid-write: no stop while a hotkey capture (save, clipboard, OCR index) is running.
  - Runtime files: logs\snapshackle-server-<pid>.json (pid, port, url, startedAt; never the session token)
    under %LOCALAPPDATA%\SnapShackle, where SnapShackle already keeps captures and settings.
  - Stop-SnapShackle.ps1 and the launcher use Get-SnapShackleProcesses / Stop-SnapShackleProcesses: runtime files
    first (SnapShackle's, and logs\cuttermk-server-<pid>.json under %LOCALAPPDATA%\CutterMk from builds
    before the rename), then any PowerShell whose command line runs Start-SnapShackle.ps1 (or the older
    Start-CutterMk.ps1 / Start-Lasso.ps1). A running server is asked to stop through a named event
    (it then removes its tray icon and hotkeys itself); only a server that does not answer is force-stopped.
  Pure functions take the time as a parameter so tests can simulate it.
#>

$script:SnapShackleHeartbeatTimeout = 20   # seconds without a heartbeat before SnapShackle stops
$script:SnapShackleLeavingGrace = 5        # seconds after a leaving signal; a reload heartbeats well inside it
$script:SnapShackleHiddenTimeout = 75     # seconds for a tab that reported itself hidden (throttled timers)
$script:SnapShackleFirstContactTimeout = 120  # seconds for the opened browser to connect at all

function New-SnapShacklePresence([Nullable[datetime]]$FirstContactBy = $null) {
    return @{ Tabs = @{}; Seen = $false; FirstContactBy = $FirstContactBy; LastTick = $null
        HeartbeatTimeout = $script:SnapShackleHeartbeatTimeout; LeavingGrace = $script:SnapShackleLeavingGrace
        HiddenTimeout = $script:SnapShackleHiddenTimeout }
}

# Records a heartbeat (or, with -Leaving, the tab's unload signal) from one studio tab.
function Register-SnapShacklePresence($Presence, [string]$Tab, [bool]$Leaving, [datetime]$Now, [bool]$Hidden = $false) {
    if ($Tab -notmatch '^[A-Za-z0-9-]{1,64}$') { $Tab = 'default' }
    $Presence.Seen = $true
    $entry = $Presence.Tabs[$Tab]
    if ($null -eq $entry) {
        # Bounded: forget dead tabs first, then the oldest.
        if ($Presence.Tabs.Count -ge 32) { Remove-SnapShackleDeadTabs $Presence $Now }
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

function Test-SnapShackleTabAlive($Presence, $Entry, [datetime]$Now) {
    if ($null -ne $Entry.LeavingAt) { return (($Now - $Entry.LeavingAt).TotalSeconds -lt $Presence.LeavingGrace) }
    $limit = $Presence.HeartbeatTimeout
    if ($Entry.Hidden) { $limit = $Presence.HiddenTimeout }
    return (($Now - $Entry.Last).TotalSeconds -lt $limit)
}

# Called on every server tick. If the process itself was not running for a while (the PC slept),
# the tabs could not heartbeat either: give them a fresh grace period instead of stopping at once.
function Step-SnapShacklePresenceClock($Presence, [datetime]$Now, [int]$GapSeconds = 10) {
    $last = $Presence.LastTick
    $Presence.LastTick = $Now
    if ($null -eq $last -or ($Now - $last).TotalSeconds -lt $GapSeconds) { return $false }
    foreach ($entry in @($Presence.Tabs.Values)) { if ($null -eq $entry.LeavingAt) { $entry.Last = $Now } }
    if ($null -ne $Presence.FirstContactBy) { $Presence.FirstContactBy = $Now.AddSeconds($script:SnapShackleFirstContactTimeout) }
    return $true
}

function Remove-SnapShackleDeadTabs($Presence, [datetime]$Now) {
    foreach ($key in @($Presence.Tabs.Keys)) {
        if (-not (Test-SnapShackleTabAlive $Presence $Presence.Tabs[$key] $Now)) { $Presence.Tabs.Remove($key) }
    }
}

# Returns why SnapShackle should stop now, or $null to keep running.
function Get-SnapShackleStopReason($Presence, [datetime]$Now, [bool]$Busy, [bool]$AutoStop) {
    if (-not $AutoStop -or $Busy) { return $null }
    if (-not $Presence.Seen) {
        if ($null -ne $Presence.FirstContactBy -and $Now -ge $Presence.FirstContactBy) {
            return 'The studio never connected; SnapShackle stopped.'
        }
        return $null
    }
    foreach ($entry in @($Presence.Tabs.Values)) { if (Test-SnapShackleTabAlive $Presence $entry $Now) { return $null } }
    return 'The studio tab was closed; SnapShackle stopped.'
}

# SNAPSHACKLE_AUTO_STOP=0 (or false/off/no) keeps SnapShackle running after the tab closes.
function Test-SnapShackleAutoStopEnv([string]$Value) {
    return (-not (([string]$Value).Trim() -match '^(0|false|off|no)$'))
}

# Reads SNAPSHACKLE_<Name>, falling back to the pre-rename CUTTERMK_<Name> when the new one is unset.
function Get-SnapShackleEnv([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_' + $Name)
    if ($null -eq $value -or $value -eq '') { $value = [Environment]::GetEnvironmentVariable('CUTTERMK_' + $Name) }
    return $value
}

# Parses a heartbeat body: {"tab":"...","leaving":true,"hidden":false,"session":"..."}.
# Returns $null when invalid. The body is never logged (it may carry the session token).
function ConvertFrom-SnapShackleHeartbeat([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Tab = 'default'; Leaving = $false; Hidden = $false; Session = '' } }
    try { $value = $Text | ConvertFrom-Json } catch { return $null }
    # Only a JSON object is valid (not a string, number, boolean or array).
    if ($null -eq $value -or $value -is [string] -or $value -is [ValueType] -or $value -is [Array]) { return $null }
    return @{ Tab = [string]$value.tab; Leaving = ($value.leaving -eq $true); Hidden = ($value.hidden -eq $true); Session = [string]$value.session }
}

# Constant-time string comparison for the session token.
function Test-SnapShackleSecretEquals([string]$A, [string]$B) {
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B) -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($diff -eq 0)
}

# Launcher options in the .bat style (--stay, --replace, --no-browser, --no-tray), for arguments that
# PowerShell did not bind to a parameter. Returns the switches found and anything unknown.
function Read-SnapShackleLaunchOptions([string[]]$Arguments) {
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

# %LOCALAPPDATA%\SnapShackle\logs (next to Captures and settings.json), or logs\ beside the app.
function Get-SnapShackleRuntimeDir([string]$Root) {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'SnapShackle\logs') }
    return (Join-Path $Root 'logs')
}
# Where a CutterMk build (before the SnapShackle rename) writes its runtime files, so a new
# launch or Stop-SnapShackle.ps1 still finds and stops it. $null when there is no LOCALAPPDATA.
function Get-SnapShackleLegacyRuntimeDir {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'CutterMk\logs') }
    return $null
}
# Runtime file names: this build's, then the CutterMk one.
$script:SnapShackleRuntimePatterns = @('snapshackle-server-*.json', 'cuttermk-server-*.json')

function Get-SnapShackleStopEventName([int]$ProcessId) { 'Local\SnapShackle-Stop-' + $ProcessId }
# The same signal under the app's earlier names, so a still-running CutterMk or Lasso build can be stopped cleanly.
function Get-SnapShackleLegacyStopEventNames([int]$ProcessId) { @(('Local\CutterMk-Stop-' + $ProcessId), ('Local\Lasso-Stop-' + $ProcessId)) }

function Write-SnapShackleRuntimeFile([string]$Dir, [int]$ProcessId, [int]$Port, [string]$Url, [bool]$Stay) {
    [void][IO.Directory]::CreateDirectory($Dir)
    $path = Join-Path $Dir ('snapshackle-server-' + $ProcessId + '.json')
    $info = [ordered]@{ pid = $ProcessId; port = $Port; url = $Url; startedAt = (Get-Date).ToString('o'); stay = $Stay }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $info -Compress), [Text.UTF8Encoding]::new($false))
    return $path
}

function Remove-SnapShackleRuntimeFile([string]$Path) {
    if ($Path) { try { [IO.File]::Delete($Path) } catch {} }
}

# Running SnapShackle servers other than this process: Pid, Port, Url, Started, RuntimeFile.
# Runtime files whose pid is dead (or now another program) are deleted on sight.
# $RuntimeDir may be several folders (SnapShackle's and the pre-rename CutterMk one); each is
# searched for both runtime file names.
# -RuntimeFilesOnly skips the process scan (tests, so they never touch a real SnapShackle).
function Get-SnapShackleProcesses([string[]]$RuntimeDir, [switch]$RuntimeFilesOnly) {
    $found = @{}
    $files = @(foreach ($dir in @($RuntimeDir | Where-Object { $_ } | Select-Object -Unique)) {
        if ([IO.Directory]::Exists($dir)) {
            foreach ($pattern in $script:SnapShackleRuntimePatterns) { [IO.DirectoryInfo]::new($dir).GetFiles($pattern) }
        }
    })
    if ($files.Count -gt 0) {
        foreach ($file in $files) {
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
            if (-not $keep) { Remove-SnapShackleRuntimeFile $file.FullName }
        }
    }
    # Instances without a runtime file (older builds, or a file deleted by hand).
    if ($RuntimeFilesOnly) { return @($found.Values | Sort-Object Pid) }
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match 'Start-(?:SnapShackle|CutterMk|Lasso)\.ps1' } |
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
function Stop-SnapShackleProcesses([string[]]$RuntimeDir, [int]$WaitSeconds = 10, [switch]$RuntimeFilesOnly) {
    $stopped = [Collections.Generic.List[int]]::new()
    foreach ($p in Get-SnapShackleProcesses $RuntimeDir -RuntimeFilesOnly:$RuntimeFilesOnly) {
        $proc = Get-Process -Id $p.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { Remove-SnapShackleRuntimeFile $p.RuntimeFile; continue }
        $signal = $null
        try {
            foreach ($eventName in @(@(Get-SnapShackleStopEventName $p.Pid) + @(Get-SnapShackleLegacyStopEventNames $p.Pid))) {
                if ([Threading.EventWaitHandle]::TryOpenExisting($eventName, [ref]$signal)) { [void]$signal.Set(); break }
                $signal = $null
            }
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
                Write-Warning ('Could not stop SnapShackle PID ' + $p.Pid + ': ' + $_.Exception.Message)
            }
        }
        if ($exited) {
            $stopped.Add($p.Pid)
            Remove-SnapShackleRuntimeFile $p.RuntimeFile
        }
    }
    return $stopped.ToArray()
}
