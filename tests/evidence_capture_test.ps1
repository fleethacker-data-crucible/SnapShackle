<#
  End-to-end test of tools/evidence-capture.ps1 on real Windows: draws synthetic windows, captures them with
  PrintWindow, reads them with Windows OCR, redacts and verifies. Only windows the script itself draws are captured;
  the real desktop is never captured. Skips (exit 0, says so) where OCR is missing; -RequireOcr fails instead.
  Usage: powershell -NoProfile -STA -File tests/evidence_capture_test.ps1
#>
param([switch]$RequireOcr)
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=evidence_capture_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tool = Join-Path $root 'tools\evidence-capture.ps1'
. (Join-Path $root 'modules/Native.ps1')
. (Join-Path $root 'modules/Ocr.ps1')
Add-Type -AssemblyName System.Drawing
if (-not (Test-SnapShackleOcr)) {
    $why = 'Windows native OCR is not available here, so the evidence redaction pass cannot be tested.'
    if ($RequireOcr) { Write-Failure ('FAIL  ' + $why); exit 1 }
    Write-Host ('SKIP  ' + $why) -ForegroundColor Yellow; exit 0
}
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-evidence-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Tool([string]$ManifestPath, [string]$OutDir, [string[]]$Extra = @()) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ErrorActionPreference = 'Continue'
    $out = & $psExe -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File $tool -Manifest $ManifestPath -OutDir $OutDir @Extra 2>&1
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out | Out-String) }
}
function Write-Manifest([string]$Name, $Object) {
    $path = Join-Path $work $Name
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Object -Depth 8), [Text.UTF8Encoding]::new($false))
    return $path
}
try {
    $good = Write-Manifest 'good.json' @{
        redactTerms = @('Starling')
        windows = @(
            @{ name = 'sign-in'; width = 820; height = 360; fontSize = 24; lines = @('Sign in', 'Email: jane.doe@example.com', 'Project: Starling'); expect = @('email') },
            @{ name = 'contact'; width = 820; height = 400; fontSize = 24; lines = @('Phone: 757-555-0142', 'SSN: 123-45-6789', 'Host 10.20.30.40'); expect = @('phone', 'ssn', 'ip') },
            @{ name = 'fixed-box'; width = 600; height = 260; fontSize = 24; lines = @('Nothing for OCR to find here'); boxes = @(@{ x = 20; y = 60; w = 120; h = 30 }) })
    }
    $out1 = Join-Path $work 'out1'
    $run = Invoke-Tool $good $out1 @('-KeepRaw')
    Test-Case 'a manifest of synthetic windows produces redacted PNGs and an index' {
        Assert-True ($run.Exit -eq 0) ('exit ' + $run.Exit + ': ' + $run.Text)
        foreach ($n in 'sign-in', 'contact', 'fixed-box') { Assert-True ([IO.File]::Exists((Join-Path $out1 ($n + '.png')))) "missing $n.png"; Assert-True ([IO.File]::Exists((Join-Path $out1 ($n + '-raw.png')))) "missing $n-raw.png" }
        $index = [IO.File]::ReadAllText((Join-Path $out1 'evidence-index.json')) | ConvertFrom-Json
        Assert-True ($index.schema -eq 1 -and $index.synthetic -eq $true -and $index.ok -eq $true -and $index.items.Count -eq 3) 'index header'
        $by = @{}; foreach ($i in $index.items) { $by[$i.name] = $i }
        Assert-True ($by['sign-in'].findings.email -eq 1 -and $by['sign-in'].findings.term -eq 1) 'sign-in findings'
        Assert-True ($by['contact'].findings.phone -eq 1 -and $by['contact'].findings.ssn -eq 1 -and $by['contact'].findings.ip -eq 1) 'contact findings'
        Assert-True ($by['fixed-box'].fixedBoxes -eq 1) 'fixed box not counted'
        foreach ($i in $index.items) { Assert-True ($i.redacted -eq $true -and $i.residualAfterRedaction -eq 0) ($i.name + ' left text behind') }
    }
    Test-Case 'the index never contains the redacted text, and its hashes match the files' {
        $text = [IO.File]::ReadAllText((Join-Path $out1 'evidence-index.json'))
        foreach ($secret in 'jane.doe', '757-555', '123-45', 'Starling', '10.20.30') { Assert-True (-not $text.Contains($secret)) "index leaks $secret" }
        $index = $text | ConvertFrom-Json
        foreach ($i in $index.items) {
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = (($sha.ComputeHash([IO.File]::ReadAllBytes((Join-Path $out1 $i.file))) | ForEach-Object { $_.ToString('x2') }) -join '')
            Assert-True ($hash -eq $i.sha256) ($i.file + ' hash differs from the index')
        }
    }
    Test-Case 'redaction changes pixels and a fixed box is solid black' {
        $raw = [Drawing.Bitmap]::new((Join-Path $out1 'sign-in-raw.png')); $red = [Drawing.Bitmap]::new((Join-Path $out1 'sign-in.png'))
        $box = [Drawing.Bitmap]::new((Join-Path $out1 'fixed-box.png'))
        try {
            Assert-True ($raw.Width -eq $red.Width -and $raw.Height -eq $red.Height) 'redaction changed the size'
            $black = 0; for ($y = 0; $y -lt $red.Height; $y += 2) { for ($x = 0; $x -lt $red.Width; $x += 2) { $p = $red.GetPixel($x, $y); if ($p.R -eq 0 -and $p.G -eq 0 -and $p.B -eq 0) { $black++ } } }
            Assert-True ($black -gt 200) "expected solid black boxes, found $black sampled black pixels"
            foreach ($pt in @(@(30, 70), @(130, 85), @(80, 75))) { $p = $box.GetPixel($pt[0], $pt[1]); Assert-True ($p.R -eq 0 -and $p.G -eq 0 -and $p.B -eq 0) ('fixed box pixel not black at ' + ($pt -join ',')) }
        } finally { $raw.Dispose(); $red.Dispose(); $box.Dispose() }
    }
    Test-Case 'the redacted windows are all gone from the screen afterwards' {
        $titles = @([SnapShackle.Native]::Windows() | ForEach-Object { $_.Title })
        Assert-True (@($titles | Where-Object { $_ -like 'Fleet Demo - *' }).Count -eq 0) 'a synthetic window was left open'
    }
    Test-Case 'an expected finding that OCR does not make fails the run (no false confidence)' {
        $bad = Write-Manifest 'expect.json' @{ windows = @(@{ name = 'no-ssn'; width = 600; height = 260; lines = @('Just some words'); expect = @('ssn') }) }
        $r = Invoke-Tool $bad (Join-Path $work 'out2')
        Assert-True ($r.Exit -eq 1 -and $r.Text -match 'expected to find "ssn"') ('exit ' + $r.Exit + ': ' + $r.Text)
        $idx = [IO.File]::ReadAllText((Join-Path $work 'out2\evidence-index.json')) | ConvertFrom-Json
        Assert-True ($idx.ok -eq $false -and $idx.problems.Count -eq 1) 'index should say ok=false'
    }
    Test-Case 'bad manifests are refused before any window opens' {
        $cases = @{
            'dup' = @{ windows = @(@{ name = 'a'; lines = @('x') }, @{ name = 'A'; lines = @('y') }) }
            'name' = @{ windows = @(@{ name = '..\evil'; lines = @('x') }) }
            'size' = @{ windows = @(@{ name = 'big'; width = 99999; lines = @('x') }) }
            'empty' = @{ windows = @() }
        }
        foreach ($k in $cases.Keys) {
            $r = Invoke-Tool (Write-Manifest ($k + '.json') $cases[$k]) (Join-Path $work ('out-' + $k))
            Assert-True ($r.Exit -ne 0) ("manifest '$k' was accepted")
            Assert-True (-not [IO.Directory]::Exists((Join-Path $work ('out-' + $k)))) ("manifest '$k' created an output folder")
        }
    }
    Test-Case '-SkipRedact captures without OCR and the index says nothing was redacted' {
        $r = Invoke-Tool $good (Join-Path $work 'out3') @('-SkipRedact')
        Assert-True ($r.Exit -eq 0) $r.Text
        $idx = [IO.File]::ReadAllText((Join-Path $work 'out3\evidence-index.json')) | ConvertFrom-Json
        Assert-True ($idx.redactionPass -eq $false -and (@($idx.items | Where-Object { $_.redacted }).Count -eq 0)) 'index should say redacted=false'
    }
} finally { try { [IO.Directory]::Delete($work, $true) } catch {} }
if ($script:failures -gt 0) { Write-Failure "$($script:failures) evidence test(s) failed"; exit 1 }
Write-Host 'All evidence capture tests passed.' -ForegroundColor Green
