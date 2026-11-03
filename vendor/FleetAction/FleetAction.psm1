<#
  Fleet action framework for Windows PowerShell 5.1.
  Register an action as <app> <noun> <verb> (id app.noun.verb), validate a JSON-Schema subset,
  and call one scriptblock from the CLI, the API and the GUI adapter.
  Job files are JSON only. Destructive actions do nothing unless -Confirmed is passed.
  Secrets are redacted before anything is written to a log line.

  This copy is vendored. See fleet-action.lock.json for the pin and the source it should
  be replaced with when fleet-action-baseline v1.0.0 is readable.
#>

$script:FleetActions = @{}
$script:FleetJsonDepth = 12

function ConvertTo-FleetJson($Value, [int]$Depth = 12) {
    if ($Depth -lt 1) { $Depth = 1 }
    return (ConvertTo-Json -InputObject $Value -Depth $Depth)
}

function Get-FleetPropertyNames($Object) {
    if ($null -eq $Object) { return @() }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.Specialized.OrderedDictionary]) {
        return @($Object.Keys)
    }
    # ConvertFrom-Json yields a PSCustomObject. Never call ContainsKey on it.
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-FleetJsonProperty($Object, [string]$Name) {
    if ($null -eq $Object -or -not $Name) { return $false }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.Specialized.OrderedDictionary]) {
        return $Object.Contains($Name)
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($property.Name -eq $Name) { return $true }
    }
    return $false
}

function Get-FleetJsonProperty($Object, [string]$Name) {
    if (-not (Test-FleetJsonProperty $Object $Name)) { return $null }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.Specialized.OrderedDictionary]) {
        return $Object[$Name]
    }
    foreach ($property in @($Object.PSObject.Properties)) {
        if ($property.Name -eq $Name) { return $property.Value }
    }
    return $null
}

function Protect-FleetLogText([string]$Text) {
    if (-not $Text) { return '' }
    $clean = $Text
    $clean = $clean -replace '(?i)(authorization\s*[:=]\s*bearer\s+)\S+', '$1[redacted]'
    $clean = $clean -replace '(?i)(bearer\s+)\S+', '$1[redacted]'
    $clean = $clean -replace '(?i)((?:token|password|secret|api[-_]?key)["''\s:=]+)[^\s"'',}]+', '$1[redacted]'
    $clean = $clean -replace '\b[0-9a-fA-F]{32,}\b', '[redacted]'
    return $clean
}

function Clear-FleetActionRegistry {
    $script:FleetActions = @{}
}

function Register-FleetAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$Noun,
        [Parameter(Mandatory = $true)][string]$Verb,
        [Parameter(Mandatory = $true)][string]$Summary,
        [Parameter(Mandatory = $true)]$ArgsSchema,
        [Parameter(Mandatory = $true)][scriptblock]$Handler,
        [switch]$Destructive,
        [bool]$Local = $false,
        [string]$Method = '',
        [string]$Route = ''
    )
    if ($Id -cne ($App + '.' + $Noun + '.' + $Verb)) { throw ('Action id must be app.noun.verb (got ' + $Id + ')') }
    if ($Noun -notmatch '^[a-z][a-z0-9]*$' -or $Verb -notmatch '^[a-z][a-z0-9]*$' -or $App -notmatch '^[a-z][a-z0-9]*$') {
        throw ('Action id must be lowercase app.noun.verb (got ' + $Id + ')')
    }
    $script:FleetActions[$Id] = [ordered]@{
        id = $Id; app = $App; noun = $Noun; verb = $Verb; name = ($Noun + ' ' + $Verb)
        summary = $Summary; argsSchema = $ArgsSchema; handler = $Handler
        destructive = [bool]$Destructive; local = [bool]$Local; method = $Method; route = $Route
    }
}

function Get-FleetAction([string]$Id) {
    if (-not $script:FleetActions.Contains($Id)) { return $null }
    return $script:FleetActions[$Id]
}

function Get-FleetActionList {
    return @($script:FleetActions.Values | Sort-Object { $_.id })
}

function Get-FleetActionDocument {
    $actions = foreach ($action in (Get-FleetActionList)) {
        [ordered]@{
            id = $action.id; app = $action.app; noun = $action.noun; verb = $action.verb
            name = $action.name; summary = $action.summary; destructive = [bool]$action.destructive
            local = [bool]$action.local; method = $action.method; route = $action.route
            argsSchema = $action.argsSchema
        }
    }
    return [ordered]@{ schema = 'fleet.action.commands/1'; discovery = 'commands --json'; actions = @($actions) }
}

function ConvertTo-FleetArgumentTable($Value) {
    $table = @{}
    if ($null -eq $Value) { return $table }
    if ($Value -is [hashtable]) {
        foreach ($key in @($Value.Keys)) { $table[[string]$key] = $Value[$key] }
        return $table
    }
    foreach ($property in @($Value.PSObject.Properties)) { $table[$property.Name] = $property.Value }
    return $table
}

function Test-FleetSchemaValue($Value, $Schema, [string]$Path) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Schema) { return @() }
    $type = [string](Get-FleetJsonProperty $Schema 'type')
    $enum = Get-FleetJsonProperty $Schema 'enum'
    if ($null -ne $enum) {
        $allowed = @($enum)
        $matched = $false
        foreach ($item in $allowed) {
            if ($item -ceq $Value -or ([string]$item -ceq [string]$Value -and $null -ne $Value)) { $matched = $true; break }
        }
        if (-not $matched) { $errors.Add($Path + ' must be one of: ' + ($allowed -join ', ')); return @($errors) }
    }
    switch ($type) {
        'object' {
            if ($null -eq $Value) { $Value = @{} }
            $names = @(Get-FleetPropertyNames $Value)
            $properties = Get-FleetJsonProperty $Schema 'properties'
            $required = @()
            $requiredRaw = Get-FleetJsonProperty $Schema 'required'
            if ($null -ne $requiredRaw) { $required = @($requiredRaw | ForEach-Object { [string]$_ }) }
            foreach ($need in $required) {
                if ($names -notcontains $need) { $errors.Add('Missing ' + $(if ($Path) { $Path + '.' } else { '' }) + $need) }
            }
            $additional = Get-FleetJsonProperty $Schema 'additionalProperties'
            $allowExtra = $true
            if ($null -ne $additional -and $additional -eq $false) { $allowExtra = $false }
            foreach ($name in $names) {
                $childSchema = $null
                if ($null -ne $properties) { $childSchema = Get-FleetJsonProperty $properties $name }
                if ($null -eq $childSchema) {
                    if (-not $allowExtra) { $errors.Add('Unknown argument ' + $name) }
                    continue
                }
                $childPath = $(if ($Path) { $Path + '.' + $name } else { $name })
                foreach ($message in @(Test-FleetSchemaValue (Get-FleetJsonProperty $Value $name) $childSchema $childPath)) { $errors.Add($message) }
            }
        }
        'string' {
            if ($Value -isnot [string]) { $errors.Add($Path + ' must be a string'); break }
            $min = Get-FleetJsonProperty $Schema 'minLength'
            $max = Get-FleetJsonProperty $Schema 'maxLength'
            if ($null -ne $min -and $Value.Length -lt [int]$min) { $errors.Add($Path + ' is too short') }
            if ($null -ne $max -and $Value.Length -gt [int]$max) { $errors.Add($Path + ' is too long') }
            $pattern = Get-FleetJsonProperty $Schema 'pattern'
            if ($pattern -and -not [regex]::IsMatch($Value, [string]$pattern)) { $errors.Add($Path + ' is not in the expected form') }
        }
        'integer' {
            $number = 0
            $ok = $false
            if ($Value -is [int] -or $Value -is [long]) { $number = [int]$Value; $ok = $true }
            elseif ($Value -is [double] -or $Value -is [decimal]) { $ok = ([double]$Value -eq [Math]::Truncate([double]$Value)); $number = [int]$Value }
            elseif ($Value -is [string] -and $Value -match '^-?\d{1,9}$') { $number = [int]$Value; $ok = $true }
            if (-not $ok) { $errors.Add($Path + ' must be a whole number'); break }
            $min = Get-FleetJsonProperty $Schema 'minimum'
            $max = Get-FleetJsonProperty $Schema 'maximum'
            if ($null -ne $min -and $number -lt [int]$min) { $errors.Add($Path + ' is below ' + $min) }
            if ($null -ne $max -and $number -gt [int]$max) { $errors.Add($Path + ' is above ' + $max) }
        }
        'boolean' {
            if ($Value -isnot [bool]) { $errors.Add($Path + ' must be true or false') }
        }
        'array' {
            if ($null -eq $Value) { $errors.Add($Path + ' must be a list'); break }
            $items = @($Value)
            $itemSchema = Get-FleetJsonProperty $Schema 'items'
            if ($null -ne $itemSchema) {
                for ($i = 0; $i -lt $items.Count; $i++) {
                    foreach ($message in @(Test-FleetSchemaValue $items[$i] $itemSchema ($Path + '[' + $i + ']'))) { $errors.Add($message) }
                }
            }
        }
        default { if ($type) { $errors.Add($Path + ' has an unsupported schema type ' + $type) } }
    }
    return @($errors)
}

function Test-FleetActionArguments([string]$Id, $Arguments) {
    $action = Get-FleetAction $Id
    if ($null -eq $action) { return @('Unknown action ' + $Id) }
    $table = ConvertTo-FleetArgumentTable $Arguments
    return @(Test-FleetSchemaValue $table $action.argsSchema '')
}

function Invoke-FleetAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        $Arguments,
        [switch]$Confirmed,
        [switch]$DryRun,
        $Context
    )
    $action = Get-FleetAction $Id
    if ($null -eq $action) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = ('Unknown action "' + $Id + '"'); ErrorType = 'usage'; Exit = 2 }
    }
    $table = ConvertTo-FleetArgumentTable $Arguments
    $problems = @(Test-FleetSchemaValue $table $action.argsSchema '')
    if ($problems.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = ($problems -join '; '); ErrorType = 'usage'; Exit = 2 }
    }
    if ($action.destructive -and -not $DryRun -and -not $Confirmed) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = ('"' + $action.name + '" is destructive: pass -Confirmed (CLI: --yes)'); ErrorType = 'usage'; Exit = 2 }
    }
    if ($DryRun) {
        $preview = [ordered]@{
            action = $action.id; command = $action.name; method = $action.method; route = $action.route
            destructive = [bool]$action.destructive; arguments = $table; dryRun = $true
        }
        return [pscustomobject]@{ Ok = $true; Result = $preview; Error = $null; ErrorType = $null; Exit = 0 }
    }
    $callContext = @{}
    if ($Context -is [hashtable]) {
        foreach ($key in @($Context.Keys)) { $callContext[[string]$key] = $Context[$key] }
    } elseif ($null -ne $Context) {
        foreach ($property in @(Get-FleetPropertyNames $Context)) { $callContext[[string]$property] = (Get-FleetJsonProperty $Context $property) }
    }
    $callContext['ActionId'] = $action.id
    $callContext['Confirmed'] = [bool]$Confirmed
    $callContext['DryRun'] = [bool]$DryRun
    try {
        $value = & $action.handler $table $callContext
        # A handler may return @{ __fleet = $true; Ok; Result; Error; ErrorType; Exit } to keep a non-zero exit
        # (for example "not running") without the module treating the call as a thrown failure.
        if ($value -is [hashtable] -and $value.Contains('__fleet') -and $value['__fleet']) {
            return [pscustomobject]@{ Ok = [bool]$value.Ok; Result = $value.Result; Error = [string]$value.Error; ErrorType = [string]$value.ErrorType; Exit = [int]$value.Exit }
        }
        return [pscustomobject]@{ Ok = $true; Result = $value; Error = $null; ErrorType = $null; Exit = 0 }
    } catch {
        $message = Protect-FleetLogText ([string]$_.Exception.Message)
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = $message; ErrorType = 'failed'; Exit = 1 }
    }
}

function Read-FleetJobFile([string]$Path) {
    if (-not $Path) { return @{ Ok = $false; Error = 'A job file path is required'; Exit = 2 } }
    $extension = [IO.Path]::GetExtension($Path)
    if ($extension -and $extension -ne '.json') { return @{ Ok = $false; Error = 'Job files are JSON only (.json)'; Exit = 2 } }
    if (-not [IO.File]::Exists($Path)) { return @{ Ok = $false; Error = ('Job file not found: ' + $Path); Exit = 2 } }
    $raw = [IO.File]::ReadAllText($Path)
    if ($raw.TrimStart().StartsWith('<') -or $raw -match '(?m)^\s*(function |param\()') {
        return @{ Ok = $false; Error = 'Job files are JSON only'; Exit = 2 }
    }
    try { $job = $raw | ConvertFrom-Json } catch { return @{ Ok = $false; Error = 'The job file is not JSON'; Exit = 2 } }
    $schema = [string](Get-FleetJsonProperty $job 'schema')
    if ($schema -ne 'fleet.action.job/1') { return @{ Ok = $false; Error = 'Job schema must be fleet.action.job/1'; Exit = 2 } }
    $steps = Get-FleetJsonProperty $job 'steps'
    if ($null -eq $steps) {
        $one = Get-FleetJsonProperty $job 'action'
        if (-not $one) { return @{ Ok = $false; Error = 'A job needs steps or one action'; Exit = 2 } }
        $steps = @($job)
    }
    return @{ Ok = $true; Job = $job; Steps = @($steps) }
}

function Invoke-FleetActionJob {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Context,
        [switch]$Confirmed,
        [switch]$DryRun
    )
    $loaded = Read-FleetJobFile $Path
    if (-not $loaded.Ok) {
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = $loaded.Error; ErrorType = 'usage'; Exit = $loaded.Exit }
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($step in @($loaded.Steps)) {
        $id = [string](Get-FleetJsonProperty $step 'action')
        if (-not $id) {
            return [pscustomobject]@{ Ok = $false; Result = $null; Error = 'A job step needs an action id'; ErrorType = 'usage'; Exit = 2 }
        }
        $args = ConvertTo-FleetArgumentTable (Get-FleetJsonProperty $step 'args')
        $stepConfirmed = $Confirmed -or ((Get-FleetJsonProperty $step 'confirmed') -eq $true)
        $stepDry = $DryRun -or ((Get-FleetJsonProperty $step 'dryRun') -eq $true)
        $ran = Invoke-FleetAction -Id $id -Arguments $args -Context $Context -Confirmed:$stepConfirmed -DryRun:$stepDry
        $results.Add([ordered]@{ action = $id; ok = [bool]$ran.Ok; exit = [int]$ran.Exit; result = $ran.Result; error = $ran.Error })
        if (-not $ran.Ok) {
            return [pscustomobject]@{ Ok = $false; Result = @{ schema = 'fleet.action.job.result/1'; steps = $results.ToArray() }; Error = $ran.Error; ErrorType = $ran.ErrorType; Exit = $ran.Exit }
        }
    }
    return [pscustomobject]@{ Ok = $true; Result = @{ schema = 'fleet.action.job.result/1'; steps = $results.ToArray() }; Error = $null; ErrorType = $null; Exit = 0 }
}

# Loopback listener for an app that has none of its own. SnapShackle does not call this:
# it already binds http://127.0.0.1:<port>/ and dispatches /api/actions itself.
# The listener is started only when the caller asks, and it binds 127.0.0.1 exactly.
function Start-FleetActionListener {
    param([int]$Port = 0)
    $address = [Net.IPAddress]::Parse('127.0.0.1')
    $tcp = [Net.Sockets.TcpListener]::new($address, $Port)
    $tcp.Start()
    $bound = [int]([Net.IPEndPoint]$tcp.LocalEndpoint).Port
    $state = @{ Listener = $tcp; Port = $bound; Stop = $false }
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('FleetListenerState', $state)
    $runspace.SessionStateProxy.SetVariable('FleetModule', $PSCommandPath)
    $powershell = [PowerShell]::Create()
    $powershell.Runspace = $runspace
    [void]$powershell.AddScript({
        Import-Module -Name $FleetModule -Force -DisableNameChecking
        while (-not $FleetListenerState.Stop) {
            if (-not $FleetListenerState.Listener.Pending()) { Start-Sleep -Milliseconds 40; continue }
            $client = $null
            try {
                $client = $FleetListenerState.Listener.AcceptTcpClient()
                $remote = [Net.IPEndPoint]$client.Client.RemoteEndPoint
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $buffer = New-Object byte[] 8192
                $read = $stream.Read($buffer, 0, $buffer.Length)
                $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                $first = ($text -split "`r`n", 2)[0]
                $status = 404; $body = '{"error":"Route not found"}'
                if ($remote.Address.ToString() -ne '127.0.0.1') { $status = 403; $body = '{"error":"Local clients only"}' }
                elseif ($first -match '^GET /api/actions ') {
                    $status = 200
                    $body = ConvertTo-FleetJson (Get-FleetActionDocument) 12
                } elseif ($first -match '^POST /api/actions/([a-z0-9.]+) ') {
                    $id = $Matches[1]
                    $status = 200
                    $payload = '{}'
                    $split = $text -split "`r`n`r`n", 2
                    if ($split.Count -gt 1) { $payload = $split[1] }
                    $args = $null
                    try { $args = $payload | ConvertFrom-Json } catch { $args = @{} }
                    $confirmed = $text -match '(?i)X-SnapShackle-Confirm:\s*yes'
                    $ran = Invoke-FleetAction -Id $id -Arguments $args -Confirmed:$confirmed
                    if (-not $ran.Ok) { $status = $(if ($ran.Exit -eq 2) { 400 } else { 500 }); $body = ConvertTo-FleetJson @{ error = [string]$ran.Error } 8 }
                    else { $body = ConvertTo-FleetJson $ran.Result 12 }
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $head = 'HTTP/1.1 ' + $status + " OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: " + $bytes.Length + "`r`nConnection: close`r`n`r`n"
                $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            } catch {} finally { if ($null -ne $client) { $client.Close() } }
        }
    })
    $handle = $powershell.BeginInvoke()
    return [pscustomobject]@{
        Port = $bound
        BaseUrl = ('http://127.0.0.1:' + $bound + '/')
        Stop = {
            $state.Stop = $true
            try { $tcp.Stop() } catch {}
            try { $powershell.Stop() } catch {}
            try { $powershell.Dispose() } catch {}
            try { $runspace.Close(); $runspace.Dispose() } catch {}
        }.GetNewClosure()
    }
}

# No Export-ModuleMember: importing the file exports every function, and dot-sourcing it
# (what SnapShackle does) leaves them in the caller's scope so action scriptblocks can see them.
