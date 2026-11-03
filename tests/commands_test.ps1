<#
  CLI/API parity check (Fleet CLI parity requirement 8). Offline, no host started, no screen touched.
  Fails if a host route has no command (or a listed reason), a command names a route the host does not have,
  a studio button has no command (or a listed reason), or the lockdown rules are weakened.
  Usage: powershell -NoProfile -File tests/commands_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=commands_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'modules/Cli.ps1')
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$host1 = [IO.File]::ReadAllText((Join-Path $root 'Start-SnapShackle.ps1'))
$html = [IO.File]::ReadAllText((Join-Path $root 'index.html'))
$studio = [IO.File]::ReadAllText((Join-Path $root 'assets/studio.js'))
$commands = @($script:SnapShackleCommands)
# Routes the studio itself uses that are not user actions, each with the reason.
$internal = @{
    '/api/heartbeat' = 'tab lifecycle: the studio tab owns the server'
    '/api/events' = 'hotkey captures handed to the open studio'
    '/api/thumb' = 'thumbnails for the studio library list'
    '/api/region' = 'interactive selection overlay, needs a person; capture rect is the headless form'
    '/api/actions' = 'Fleet action catalog; the same functions as the named routes'
    '/api/actions/(snapshackle\.[a-z]+\.[a-z]+)$' = 'Fleet action dispatch; calls the registered function for that id'
}
function ConvertTo-RouteKey([string]$Route) {
    $r = ($Route -replace '\?.*$', '').TrimStart('^')
    if ($r -eq '/api/library/(' -or $r -eq '/api/library/{name}') { return '/api/library/{name}' }
    return $r.TrimEnd('(', '/')
}
$hostRoutes = @([regex]::Matches($host1, '\$path\s+-(?:eq|match)\s+\(?''(\^?/api/[^'']*)''') | ForEach-Object { ConvertTo-RouteKey $_.Groups[1].Value } | Sort-Object -Unique)

Test-Case 'the host answers a route for every command, and every host route is a command or has a reason' {
    $cmdRoutes = @($commands | Where-Object { $_.route } | ForEach-Object { ConvertTo-RouteKey $_.route } | Sort-Object -Unique)
    Assert-True ($hostRoutes.Count -ge 12) ('route scan found only ' + $hostRoutes.Count + ': ' + ($hostRoutes -join ' '))
    $missingHost = @($cmdRoutes | Where-Object { $hostRoutes -notcontains $_ })
    Assert-True ($missingHost.Count -eq 0) ('commands for routes the host does not have: ' + ($missingHost -join ', '))
    $noCommand = @($hostRoutes | Where-Object { $cmdRoutes -notcontains $_ -and -not $internal.ContainsKey($_) })
    Assert-True ($noCommand.Count -eq 0) ('host routes with no command (add one to modules/Cli.ps1 or an internal reason here): ' + ($noCommand -join ', '))
    $stale = @($internal.Keys | Where-Object { $hostRoutes -notcontains $_ })
    Assert-True ($stale.Count -eq 0) ('internal routes the host no longer has: ' + ($stale -join ', '))
}
Test-Case 'every studio button is a command action or has a listed reason, and nothing refers to a missing control' {
    $ids = @([regex]::Matches($html, '<button[^>]*\sid="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($ids.Count -ge 35) ('button scan found only ' + $ids.Count)
    $allIds = @([regex]::Matches($html, '\sid="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    $mapped = @($commands | ForEach-Object { $_.gui } | ForEach-Object { $_ })
    $uncovered = @($ids | Where-Object { $mapped -notcontains $_ -and -not $script:SnapShackleGuiOnly.Contains($_) })
    Assert-True ($uncovered.Count -eq 0) ('studio buttons with no command (add the command in the same change, or a GUI-only reason): ' + ($uncovered -join ', '))
    $ghost = @(($mapped + @($script:SnapShackleGuiOnly.Keys)) | Where-Object { $allIds -notcontains $_ })
    Assert-True ($ghost.Count -eq 0) ('commands or reasons name controls that are not in index.html: ' + ($ghost -join ', '))
    $both = @($script:SnapShackleGuiOnly.Keys | Where-Object { $mapped -contains $_ })
    Assert-True ($both.Count -eq 0) ('listed as both a command action and GUI-only: ' + ($both -join ', '))
    foreach ($k in $script:SnapShackleGuiOnly.Keys) { Assert-True ([string]$script:SnapShackleGuiOnly[$k]).Length -gt 5 "empty reason for $k" }
}
Test-Case 'the registry is well formed: unique <noun> <verb> names, known kinds, options typed' {
    $names = @($commands | ForEach-Object { $_.name })
    Assert-True (($names | Sort-Object -Unique).Count -eq $names.Count) 'duplicate command names'
    foreach ($c in $commands) {
        Assert-True ($c.name -match '^[a-z]+ [a-z]+$') ("name is not '<noun> <verb>': " + $c.name)
        Assert-True ($c.summary.Length -gt 10) ('no summary: ' + $c.name)
        Assert-True ($c.kind -in @('api', 'local')) ('kind: ' + $c.name)
        Assert-True ($c.method -in @('', 'GET', 'POST', 'PUT', 'DELETE')) ('method: ' + $c.name)
        Assert-True ($c.kind -eq 'local' -or $c.route) ('api command without a route: ' + $c.name)
        foreach ($o in @($c.options)) {
            Assert-True ($o.type -in @('string', 'int', 'file', 'bool')) ("option type: $($c.name) --$($o.name)")
            Assert-True ($o.in -in @('query', 'path', 'body', 'local')) ("option location: $($c.name) --$($o.name)")
            Assert-True ($o.name -notmatch 'token|password|secret|key$' -or $o.name -eq 'key') ("an option that looks like a secret: --$($o.name)")
        }
        foreach ($m in [regex]::Matches([string]$c.route, '\{(\w+)\}')) { Assert-True (@($c.options | Where-Object { $_.name -eq $m.Groups[1].Value -and $_.in -eq 'path' }).Count -eq 1) ("route parameter without a path option: $($c.name) {$($m.Groups[1].Value)}") }
        if ($c.response -eq 'png') { Assert-True (@($c.options | Where-Object { $_.name -eq 'out' -and $_.required }).Count -eq 1) ('a PNG command must require --out: ' + $c.name) }
    }
    $doc = Get-SnapShackleCommandsDocument
    Assert-True ($doc.schema -eq 'snapshackle.commands/1' -and @($doc.commands).Count -eq $commands.Count) 'commands document'
    $roundTrip = ConvertTo-Json -InputObject $doc -Depth 8 | ConvertFrom-Json
    Assert-True (@($roundTrip.commands).Count -eq $commands.Count) 'registry does not survive JSON'
}
Test-Case 'every destructive route needs an explicit confirmation, in the host and in the studio' {
    $destructive = @($commands | Where-Object { $_.destructive })
    Assert-True (@($destructive | ForEach-Object { $_.name }) -contains 'library delete' -and @($destructive | ForEach-Object { $_.name }) -contains 'session stop') 'destructive set changed'
    Assert-True ($host1.Contains("X-SnapShackle-Confirm") -and $host1.Contains("Confirmation required")) 'library delete must demand X-SnapShackle-Confirm'
    Assert-True ($host1.Contains("X-SnapShackle-Intent") -and $host1.Contains("end-session")) 'session stop must demand its intent header'
    Assert-True ($studio.Contains("method:'DELETE',headers:{'X-SnapShackle-Confirm':'yes'}")) 'the studio delete must send the confirmation (after its own confirm box)'
    Assert-True ($host1.Contains("Write-SnapShackleAudit")) 'destructive actions must be logged'
}
Test-Case 'the API stays locked to this user: token required, Host and Origin checked, no CORS, token file protected' {
    Assert-True ($host1.Contains("X-SnapShackle-Token") -and $host1.Contains("Invalid session")) 'token check'
    Assert-True ($host1.Contains("Invalid host") -and $host1.Contains("Origin is not authorized")) 'Host/Origin checks'
    Assert-True ($host1 -notmatch 'Access-Control-Allow') 'the host must send no CORS headers'
    Assert-True ($host1.Contains('Write-SnapShackleSessionFile') -and $host1.Contains('Remove-SnapShackleSessionFile')) 'session file written and removed'
    $cli = [IO.File]::ReadAllText((Join-Path $root 'modules/Cli.ps1'))
    Assert-True ($cli.Contains('SetAccessRuleProtection($true, $false)') -and $cli.Contains('FileSystemAccessRule')) 'token file must carry an explicit current-user ACL'
    $runtimeWriter = [IO.File]::ReadAllText((Join-Path $root 'modules/Lifecycle.ps1'))
    Assert-True ($runtimeWriter -notmatch '\$info\s*=\s*\[ordered\]@\{[^}]*token') 'the runtime file in logs must never hold the token'
}
Test-Case 'the CLI takes no secret on the command line and ships in the release zip' {
    $cliScript = [IO.File]::ReadAllText((Join-Path $root 'snapshackle.ps1'))
    Assert-True ($cliScript -notmatch "(?i)Write-(Host|Output)[^\r\n]*\`$token") 'the CLI must never print the token'
    $release = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml'))
    Assert-True ($release.Contains('snapshackle.ps1') -and $release.Contains('SnapShackle-CLI.bat')) 'release zip must include the CLI'
    Assert-True ([IO.File]::Exists((Join-Path $root 'SnapShackle-CLI.bat'))) 'launcher missing'
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) parity test(s) failed"; exit 1 }
Write-Host 'All CLI/API parity tests passed.' -ForegroundColor Green
