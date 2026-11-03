# Pester 5. Fleet actions for SnapShackle against FleetAction 1.0.1.
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
        It 'registers every command except the reserved commands noun' {
            $actions = @(Get-FleetAction -App 'snapshackle')
            $expected = @($script:SnapShackleCommands | Where-Object { ([string]$_.name -split ' ')[0] -ne 'commands' })
            $actions.Count | Should -Be $expected.Count
            foreach ($command in $expected) {
                $parts = @([string]$command.name -split ' ')
                $found = @(Get-FleetAction -App 'snapshackle' -Noun $parts[0] -Verb $parts[1]) | Select-Object -First 1
                $found.id | Should -Be ('snapshackle.' + $parts[0] + '.' + $parts[1])
                $found.destructive | Should -Be ([bool]$command.destructive)
            }
        }

        It 'refuses a destructive action without -Confirmed' {
            $ran = Invoke-FleetAction -App 'snapshackle' -Noun 'library' -Verb 'delete' -Arguments @{ name = 'SnapShackle-x.png' }
            $ran.ok | Should -BeFalse
            $ran.error.code | Should -Be 'E_CONFIRM'
        }

        It 'dry-run returns a preview and does not call the handler' {
            $ran = Invoke-FleetAction -App 'snapshackle' -Noun 'evidence' -Verb 'run' -Arguments @{ manifest = 'no-such.json'; outdir = 'C:\missing' } -DryRun
            $ran.ok | Should -BeTrue
            $ran.result.dryRun | Should -BeTrue
            $ran.result.actionId | Should -Be 'snapshackle.evidence.run'
            $ran.result.confirmationRequired | Should -BeTrue
        }

        It 'rejects an unknown argument' {
            $ran = Invoke-FleetAction -App 'snapshackle' -Noun 'library' -Verb 'list' -Arguments @{ nope = 'x' }
            $ran.ok | Should -BeFalse
            $ran.error.code | Should -Be 'E_ARGS'
        }
    }

    Context 'JSON objects on Windows PowerShell 5.1' {
        It 'reads ConvertFrom-Json values through PSObject.Properties' {
            $parsed = '{"ok":true,"note":"value"}' | ConvertFrom-Json
            { $parsed.ContainsKey('ok') } | Should -Throw
            $found = $false
            foreach ($property in @($parsed.PSObject.Properties)) { if ($property.Name -eq 'ok') { $found = [bool]$property.Value } }
            $found | Should -BeTrue
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
                foreach ($call in $calls) { $call.Value | Should -Match '-Depth' }
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
            $ran = Invoke-FleetAction -App 'snapshackle' -Noun 'handoff' -Verb 'list' -Arguments @{ library = $script:Lib; tag = 'training'; includetext = $true }
            $ran.ok | Should -BeTrue -Because $(if ($ran.error) { [string]$ran.error.message } else { '' })
            $ran.result.schema | Should -Be 'snapshackle.handoff/1'
            @($ran.result.captures).Count | Should -Be 1
        }

        It 'exports a manifest and does not overwrite' {
            $out = Join-Path $script:Work 'course'
            $ran = Invoke-FleetAction -App 'snapshackle' -Noun 'handoff' -Verb 'export' -Arguments @{ library = $script:Lib; outdir = $out; includetext = $true }
            $ran.ok | Should -BeTrue -Because $(if ($ran.error) { [string]$ran.error.message } else { '' })
            $ran.result.copied | Should -Be 1
            Test-Path -LiteralPath (Join-Path $out 'handoff.json') | Should -BeTrue
            $again = Invoke-FleetAction -App 'snapshackle' -Noun 'handoff' -Verb 'export' -Arguments @{ library = $script:Lib; outdir = $out }
            $again.result.copied | Should -Be 0
            $again.result.skipped | Should -Be 1
        }
    }

    Context 'job files' {
        It 'rejects anything that is not a version 1 job' {
            $path = Join-Path ([IO.Path]::GetTempPath()) ('ss-job-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($path, '{"schema":"fleet.action.job/1"}')
            try {
                $ran = Invoke-FleetJob -Path $path
                $ran.ok | Should -BeFalse
                $ran.error.code | Should -Be 'E_ARGS'
            } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }

        It 'runs the version 1 training hand-off job' {
            $work = Join-Path ([IO.Path]::GetTempPath()) ('ss-jobdir-' + [guid]::NewGuid().ToString('N'))
            $lib = Join-Path $work 'Captures'
            $out = Join-Path $work 'out'
            [void][IO.Directory]::CreateDirectory($lib)
            $name = 'SnapShackle-20261103-010000-002-bbbbbbbb.png'
            [IO.File]::WriteAllBytes((Join-Path $lib $name), [byte[]](137, 80, 78, 71, 13, 10, 26, 10))
            $jobPath = Join-Path $work 'job.json'
            $job = @{
                version = 1
                steps = @(
                    @{ id = 'list'; app = 'snapshackle'; noun = 'handoff'; verb = 'list'; args = @{ library = $lib; tag = 'training' } }
                    @{ id = 'export'; app = 'snapshackle'; noun = 'handoff'; verb = 'export'; args = @{ library = $lib; outdir = $out; dryrun = $true } }
                )
            }
            [IO.File]::WriteAllText($jobPath, (ConvertTo-Json -InputObject $job -Depth 8))
            try {
                $ran = Invoke-FleetJob -Path $jobPath
                $ran.ok | Should -BeTrue -Because $(if ($ran.error) { [string]$ran.error.message } else { '' })
                @($ran.result.steps).Count | Should -Be 2
                $ran.result.steps[1].result.dryRun | Should -BeTrue
            } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'pins FleetAction v1.0.1' {
            $lock = Get-Content -LiteralPath (Join-Path $script:Root 'vendor/FleetAction/fleet-action.lock.json') -Raw | ConvertFrom-Json
            $lock.version | Should -Be 'v1.0.1'
            $lock.commit | Should -Be '07f147613c03fa571ed916d64d7e8929937d00f6'
            $lock.sha256 | Should -Be '8154C70544CFF424BB1BCEF3BF194EDC17C29A58AB0F37A29E751BEFD4B657C1'
        }
    }

    Context 'GUI and help parity' {
        It 'the studio page passes the Fleet GUI parity check' {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('ss-gui-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($dir)
            Copy-Item (Join-Path $script:Root 'index.html') (Join-Path $dir 'index.html')
            Copy-Item (Join-Path $script:Root 'assets/studio.js') (Join-Path $dir 'studio.js')
            Copy-Item (Join-Path $script:Root 'assets/styles.css') (Join-Path $dir 'styles.css')
            try {
                $gaps = @(Test-FleetGuiParity -Path $dir).Gaps
                $gaps.Count | Should -Be 0 -Because ($gaps -join '; ')
            } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        }

        It 'help --json and commands --json list every registered action' {
            $shell = Get-Command pwsh -ErrorAction SilentlyContinue
            if (-not $shell) { $shell = Get-Command powershell -ErrorAction SilentlyContinue }
            if (-not $shell) { Set-ItResult -Skipped -Because 'no PowerShell host'; return }
            foreach ($invocation in @('help --json', 'commands --json')) {
                $output = & $shell.Source -NoProfile -NonInteractive -File (Join-Path $script:Root 'snapshackle.ps1') @($invocation.Split(' '))
                $doc = $output | Out-String | ConvertFrom-Json
                $doc.schema | Should -Be 'snapshackle.commands/1'
                $listed = @()
                foreach ($command in @($doc.commands)) {
                    $id = $null
                    foreach ($property in @($command.PSObject.Properties)) { if ($property.Name -eq 'id') { $id = [string]$property.Value } }
                    $listed += $id
                }
                foreach ($action in @(Get-FleetAction -App 'snapshackle')) { $listed | Should -Contain $action.id }
            }
        }
    }
}
