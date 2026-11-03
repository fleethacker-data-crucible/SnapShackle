# Pester 5. Fleet actions for SnapShackle. Windows PowerShell 5.1 syntax (no &&, ??, or ternary).
# One Describe so the action scriptblock and its functions stay in scope for every test.
$ErrorActionPreference = 'Stop'

Describe 'SnapShackle fleet actions' {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:Root 'modules/Cli.ps1')
        . (Join-Path $script:Root 'modules/Lifecycle.ps1')
        . (Join-Path $script:Root 'modules/Actions.ps1')
    }

    Context 'Fleet action registry' {

    It 'registers one action id app.noun.verb for every command' {
        $actions = @(Get-FleetActionList)
        $actions.Count | Should -Be @($script:SnapShackleCommands).Count
        foreach ($command in @($script:SnapShackleCommands)) {
            $parts = @([string]$command.name -split ' ')
            $id = 'snapshackle.' + $parts[0] + '.' + $parts[1]
            $action = Get-FleetAction $id
            $action | Should -Not -BeNullOrEmpty
            $action.destructive | Should -Be ([bool]$command.destructive)
            $action.id | Should -Be $id
        }
    }

    It 'marks delete, stop and evidence run as destructive' {
        (Get-FleetAction 'snapshackle.library.delete').destructive | Should -BeTrue
        (Get-FleetAction 'snapshackle.session.stop').destructive | Should -BeTrue
        (Get-FleetAction 'snapshackle.evidence.run').destructive | Should -BeTrue
        (Get-FleetAction 'snapshackle.handoff.export').destructive | Should -BeFalse
    }

    It 'refuses a destructive action without -Confirmed' {
        $ran = Invoke-FleetAction -Id 'snapshackle.library.delete' -Arguments @{ name = 'SnapShackle-x.png' } -Context @{ Transport = 'host' }
        $ran.Ok | Should -BeFalse
        $ran.Exit | Should -Be 2
        $ran.Error | Should -Match 'Confirmed'
    }

    It 'dry-run returns a preview and does not call the handler' {
        $ran = Invoke-FleetAction -Id 'snapshackle.evidence.run' -Arguments @{ manifest = 'no-such.json'; outdir = 'C:\missing' } -DryRun -Context @{ Transport = 'host' }
        $ran.Ok | Should -BeTrue
        $ran.Result.dryRun | Should -BeTrue
        $ran.Result.action | Should -Be 'snapshackle.evidence.run'
    }

    It 'rejects an unknown argument' {
        $ran = Invoke-FleetAction -Id 'snapshackle.library.list' -Arguments @{ nope = 'x' } -Context @{ Transport = 'host' }
        $ran.Ok | Should -BeFalse
        $ran.Exit | Should -Be 2
        $ran.Error | Should -Match 'Unknown argument'
    }

    It 'rejects a share kind outside the enum' {
        $ran = Invoke-FleetAction -Id 'snapshackle.share.send' -Arguments @{ capture = 'SnapShackle-a.png'; kind = 'upload' } -Context @{ Transport = 'host' }
        $ran.Ok | Should -BeFalse
        $ran.Error | Should -Match 'one of'
    }
}

    Context 'JSON objects on Windows PowerShell 5.1' {
    It 'reads ConvertFrom-Json values through PSObject.Properties' {
        $parsed = '{"ok":true,"token":"secret-value"}' | ConvertFrom-Json
        { $parsed.ContainsKey('ok') } | Should -Throw
        (Get-FleetJsonProperty $parsed 'ok') | Should -BeTrue
        (Test-FleetJsonProperty $parsed 'missing') | Should -BeFalse
    }

    It 'redacts secrets before they can be logged' {
        $line = Protect-FleetLogText 'Authorization: Bearer example-value'
        $line | Should -Not -Match 'example-value'
        $line | Should -Match 'redacted'
    }

    It 'passes -Depth on every ConvertTo-Json in the action files' {
        $files = @(
            'vendor/FleetAction/FleetAction.psm1',
            'modules/Actions.ps1',
            'modules/Handoff.ps1',
            'modules/CliClient.ps1',
            'snapshackle.ps1'
        )
        foreach ($relative in $files) {
            $text = [IO.File]::ReadAllText((Join-Path $script:Root $relative))
            $calls = [regex]::Matches($text, 'ConvertTo-Json\b[^\r\n]*')
            foreach ($call in $calls) {
                $call.Value | Should -Match '-Depth'
            }
        }
    }
}

    Context 'handoff action' {
    BeforeAll {
        $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('ss-fleet-' + [guid]::NewGuid().ToString('N'))
        $script:Lib = Join-Path $script:Work 'Captures'
        [void][IO.Directory]::CreateDirectory($script:Lib)
        $script:Name = 'SnapShackle-20261103-000000-001-aaaaaaaa.png'
        [IO.File]::WriteAllBytes((Join-Path $script:Lib $script:Name), [byte[]](137, 80, 78, 71, 13, 10, 26, 10))
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $script:Lib ($script:Name + '.meta.json')), '{"schema":"snapshackle.capture/1","tags":["training"],"note":"course slide","ocr":"Capstan lesson"}', $utf8)
    }
    AfterAll {
        if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
    }

    It 'lists a training capture without a running SnapShackle' {
        $ran = Invoke-FleetAction -Id 'snapshackle.handoff.list' -Arguments @{ library = $script:Lib; tag = 'training'; includetext = $true } -Context @{ Transport = 'host'; Root = $script:Root }
        $ran.Ok | Should -BeTrue -Because $ran.Error
        $ran.Result.schema | Should -Be 'snapshackle.handoff/1'
        @($ran.Result.captures).Count | Should -Be 1
        $ran.Result.captures[0].note | Should -Be 'course slide'
    }

    It 'exports a manifest and does not overwrite' {
        $out = Join-Path $script:Work 'course'
        $ran = Invoke-FleetAction -Id 'snapshackle.handoff.export' -Arguments @{ library = $script:Lib; outdir = $out; includetext = $true } -Context @{ Transport = 'host'; Root = $script:Root }
        $ran.Ok | Should -BeTrue -Because $ran.Error
        $ran.Result.copied | Should -Be 1
        Test-Path -LiteralPath (Join-Path $out 'handoff.json') | Should -BeTrue
        $again = Invoke-FleetAction -Id 'snapshackle.handoff.export' -Arguments @{ library = $script:Lib; outdir = $out } -Context @{ Transport = 'host'; Root = $script:Root }
        $again.Result.copied | Should -Be 0
        $again.Result.skipped | Should -Be 1
    }

    It 'honours dryrun on the export arguments and writes nothing new' {
        $out = Join-Path $script:Work 'preview'
        $ran = Invoke-FleetAction -Id 'snapshackle.handoff.export' -Arguments @{ library = $script:Lib; outdir = $out; dryrun = $true } -Context @{ Transport = 'host'; Root = $script:Root }
        $ran.Ok | Should -BeTrue -Because $ran.Error
        $ran.Result.dryRun | Should -BeTrue
        Test-Path -LiteralPath $out | Should -BeFalse
    }
}

    Context 'job files' {
    It 'rejects anything that is not JSON' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('ss-job-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($path, 'not json')
        try {
            $ran = Invoke-FleetActionJob -Path $path -Context @{ Transport = 'host'; Root = $script:Root }
            $ran.Ok | Should -BeFalse
            $ran.Exit | Should -Be 2
        } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'runs a JSON job for the training hand-off' {
        $work = Join-Path ([IO.Path]::GetTempPath()) ('ss-jobdir-' + [guid]::NewGuid().ToString('N'))
        $lib = Join-Path $work 'Captures'
        $out = Join-Path $work 'out'
        [void][IO.Directory]::CreateDirectory($lib)
        $name = 'SnapShackle-20261103-010000-002-bbbbbbbb.png'
        [IO.File]::WriteAllBytes((Join-Path $lib $name), [byte[]](137, 80, 78, 71, 13, 10, 26, 10))
        $jobPath = Join-Path $work 'job.json'
        $job = [ordered]@{
            schema = 'fleet.action.job/1'
            steps = @(
                [ordered]@{ action = 'snapshackle.handoff.list'; args = [ordered]@{ library = $lib; tag = 'training' } },
                [ordered]@{ action = 'snapshackle.handoff.export'; args = [ordered]@{ library = $lib; outdir = $out; dryrun = $true } }
            )
        }
        [IO.File]::WriteAllText($jobPath, (ConvertTo-Json -InputObject $job -Depth 8))
        try {
            $ran = Invoke-FleetActionJob -Path $jobPath -Context @{ Transport = 'host'; Root = $script:Root }
            $ran.Ok | Should -BeTrue -Because $ran.Error
            @($ran.Result.steps).Count | Should -Be 2
            $ran.Result.steps[1].result.dryRun | Should -BeTrue
        } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the example job is JSON and names registered actions' {
        $path = Join-Path $script:Root 'examples/training-course-handoff.json'
        $loaded = Read-FleetJobFile $path
        $loaded.Ok | Should -BeTrue
        foreach ($step in @($loaded.Steps)) {
            $id = [string](Get-FleetJsonProperty $step 'action')
            Get-FleetAction $id | Should -Not -BeNullOrEmpty
        }
    }
}

    Context 'GUI and help parity' {
    It 'every data-action maps to a registered action and the token is not in the markup' {
        $html = [IO.File]::ReadAllText((Join-Path $script:Root 'index.html'))
        $studio = [IO.File]::ReadAllText((Join-Path $script:Root 'assets/studio.js'))
        $html | Should -Not -Match 'X-SnapShackle-Token'
        $html | Should -Not -Match '\b[0-9a-f]{64}\b'
        $found = @([regex]::Matches($html + "`n" + $studio, 'data-action="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $found.Count | Should -BeGreaterThan 10
        foreach ($id in $found) {
            (Get-FleetAction $id) | Should -Not -BeNullOrEmpty
            $id | Should -Not -Match 'token'
        }
        $html | Should -Match 'role="status"'
        $html | Should -Match 'role="alert"'
        $html | Should -Match 'id="confirmCancel"'
        $studio | Should -Match 'aria-busy'
        $studio | Should -Match 'aria-disabled'
        $studio | Should -Match 'confirmCancel'
    }

    It 'help --json and commands --json list every registered action' {
        $shell = Get-Command pwsh -ErrorAction SilentlyContinue
        if (-not $shell) { $shell = Get-Command powershell -ErrorAction SilentlyContinue }
        if (-not $shell) { Set-ItResult -Skipped -Because 'no PowerShell host to launch snapshackle.ps1'; return }
        foreach ($invocation in @('help --json', 'commands --json')) {
            $output = & $shell.Source -NoProfile -NonInteractive -File (Join-Path $script:Root 'snapshackle.ps1') @($invocation.Split(' '))
            $doc = $output | Out-String | ConvertFrom-Json
            $doc.schema | Should -Be 'snapshackle.commands/1'
            $listed = @($doc.commands | ForEach-Object { [string](Get-FleetJsonProperty $_ 'id') })
            foreach ($action in @(Get-FleetActionList)) {
                $listed | Should -Contain $action.id
            }
        }
    }
}

    Context 'loopback listener' {
    It 'binds 127.0.0.1 and serves the action catalog' {
        $listener = Start-FleetActionListener -Port 0
        try {
            $listener.BaseUrl | Should -Be ('http://127.0.0.1:' + $listener.Port + '/')
            $client = New-Object System.Net.Sockets.TcpClient
            $connected = $false
            for ($try = 0; $try -lt 20 -and -not $connected; $try++) {
                try { $client.Connect('127.0.0.1', [int]$listener.Port); $connected = $true } catch { Start-Sleep -Milliseconds 50 }
            }
            $connected | Should -BeTrue
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $request = [Text.Encoding]::ASCII.GetBytes("GET /api/actions HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
            $stream.Write($request, 0, $request.Length)
            $buffer = New-Object byte[] 8192
            $builder = New-Object System.Text.StringBuilder
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $read))
            }
            $text = $builder.ToString()
            $client.Close()
            $text | Should -Match 'fleet.action.commands/1'
        } finally {
            if ($listener -and $listener.Stop) { & $listener.Stop }
        }
    }
    }
}
