<#
  Tests tools/handoff.ps1 on a synthetic capture folder in a temporary location: list (table, JSON, filters, OCR text
  only on request), export (files and manifest, hashes, no overwrite, dry run, refusing an output folder inside the
  library) and the exit codes. Nothing is captured from the screen and no SnapShackle needs to run.
  Usage: powershell -NoProfile -File tests/handoff_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=handoff_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-handoff-' + [guid]::NewGuid().ToString('N'))
$lib = Join-Path $work 'Captures'; [void][IO.Directory]::CreateDirectory($lib)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Invoke-Handoff([string[]]$Arguments) {
    $quoted = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = [Diagnostics.ProcessStartInfo]::new($psExe)
    $psi.Arguments = '-NoProfile -NoLogo -ExecutionPolicy Bypass -File "' + (Join-Path $root 'tools\handoff.ps1') + '" ' + $quoted
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    $json = $null; try { $json = $o.Result | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Exit = $p.ExitCode; Text = $o.Result; Err = $e.Result; Json = $json }
}
function Get-Sha([string]$Path) { $s = [Security.Cryptography.SHA256]::Create(); try { return (($s.ComputeHash([IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $s.Dispose() } }
function New-Png([string]$Path, [int]$Shade) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [Drawing.Bitmap]::new(40, 30); $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb($Shade, 60, 90)); $g.Dispose()
    $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$utf8 = [Text.UTF8Encoding]::new($false)
# Three captures: with the current sidecar, with an older sidecar (no schema), and with none; plus things to ignore.
$a = 'SnapShackle-20261031-100000-001-aaaaaaaa.png'; $b = 'SnapShackle-20261031-110000-002-bbbbbbbb.png'; $c = 'SnapShackle-20261031-120000-003-cccccccc.png'
New-Png (Join-Path $lib $a) 20; New-Png (Join-Path $lib $b) 120; New-Png (Join-Path $lib $c) 220
[IO.File]::WriteAllText((Join-Path $lib ($a + '.meta.json')), '{"schema":"snapshackle.capture/1","tags":["ops","q3"],"note":"first","ocr":"Quarterly readiness report"}', $utf8)
[IO.File]::WriteAllText((Join-Path $lib ($b + '.meta.json')), '{"tags":["ops"],"note":"","ocr":"Budget sheet"}', $utf8)
[IO.File]::WriteAllText((Join-Path $lib 'notes.txt'), 'not a capture', $utf8)
New-Png (Join-Path $lib 'holiday.png') 50
[IO.File]::WriteAllText((Join-Path $lib 'SnapShackle-20250101-000000-000-dddddddd.png.meta.json'), '{ broken', $utf8)
(Get-Item (Join-Path $lib $a)).LastWriteTime = [datetime]'2026-10-31 10:00'; (Get-Item (Join-Path $lib $b)).LastWriteTime = [datetime]'2026-10-31 11:00'; (Get-Item (Join-Path $lib $c)).LastWriteTime = [datetime]'2026-10-31 12:00'
try {
    Test-Case 'list shows only captures, newest first, with tags, notes and the text length but not the text' {
        $r = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.schema -eq 'snapshackle.handoff/1' -and $r.Json.count -eq 3) ('list: ' + $r.Text + $r.Err)
        $names = @($r.Json.captures | ForEach-Object { $_.name })
        Assert-True (($names -join ',') -eq "$c,$b,$a") ('order or contents: ' + ($names -join ','))
        $first = $r.Json.captures | Where-Object { $_.name -eq $a }
        Assert-True ((@($first.tags) -join ',') -eq 'ops,q3' -and $first.note -eq 'first' -and $first.ocrChars -eq 26 -and $first.sidecar -eq $true) ('entry a: ' + ($first | ConvertTo-Json -Compress))
        Assert-True ($first.sha256 -eq (Get-Sha (Join-Path $lib $a)) -and $null -eq $first.ocr) 'hash wrong or the text leaked without -IncludeText'
        $none = $r.Json.captures | Where-Object { $_.name -eq $c }
        Assert-True ($none.sidecar -eq $false -and $none.ocrChars -eq 0 -and @($none.tags).Count -eq 0) 'a capture with no sidecar should list as empty'
    }
    Test-Case 'filters: tag, text search, name, date, and -IncludeText' {
        $t = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Tag', 'q3')
        Assert-True ($t.Json.count -eq 1 -and $t.Json.captures[0].name -eq $a) 'tag filter'
        $q = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Query', 'budget', '-IncludeText')
        Assert-True ($q.Json.count -eq 1 -and $q.Json.captures[0].name -eq $b -and $q.Json.captures[0].ocr -eq 'Budget sheet') ('text search: ' + $q.Text)
        $n = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Name', $c)
        Assert-True ($n.Json.count -eq 1 -and $n.Json.captures[0].name -eq $c) 'name filter'
        $s = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Since', '2026-10-31 10:30')
        Assert-True ($s.Json.count -eq 2) ('since filter: ' + $s.Json.count)
        $m = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Max', '1')
        Assert-True ($m.Json.count -eq 1 -and $m.Json.captures[0].name -eq $c) '-Max'
        $table = Invoke-Handoff @('-Mode', 'list', '-Library', $lib)
        Assert-True ($table.Exit -eq 0 -and $table.Text.Contains($a) -and $table.Text.Contains('tags: ops,q3')) 'table output'
    }
    Test-Case 'export copies the PNGs and sidecars unchanged and writes a manifest whose hashes match' {
        $out = Join-Path $work 'out1'
        $r = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $out, '-IncludeText', '-Json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.copied -eq 3 -and $r.Json.skipped -eq 0) ('export: ' + $r.Text + $r.Err)
        foreach ($n in $a, $b, $c) { Assert-True ((Get-Sha (Join-Path $out $n)) -eq (Get-Sha (Join-Path $lib $n))) ("$n differs from the original") }
        Assert-True ((Get-Sha (Join-Path $out ($a + '.meta.json'))) -eq (Get-Sha (Join-Path $lib ($a + '.meta.json')))) 'sidecar copy differs'
        Assert-True (-not [IO.File]::Exists((Join-Path $out ($c + '.meta.json')))) 'a sidecar was invented for a capture without one'
        Assert-True (-not [IO.File]::Exists((Join-Path $out 'holiday.png')) -and -not [IO.File]::Exists((Join-Path $out 'notes.txt'))) 'a non-capture was copied'
        $raw = [IO.File]::ReadAllBytes((Join-Path $out 'handoff.json'))
        Assert-True (-not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB)) 'the manifest has a byte-order mark'
        $m = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
        Assert-True ($m.schema -eq 'snapshackle.handoff/1' -and $m.count -eq 3 -and $m.source -eq 'SnapShackle') 'manifest header'
        foreach ($e in $m.captures) { Assert-True ($e.sha256 -eq (Get-Sha (Join-Path $out $e.file))) ("manifest hash wrong for " + $e.file) }
        Assert-True (($m.captures | Where-Object { $_.name -eq $a }).ocr -eq 'Quarterly readiness report') 'text missing from the manifest with -IncludeText'
        Assert-True (-not (ConvertTo-Json $m).Contains($work)) 'the manifest leaks the library path'
    }
    Test-Case 'a second export never overwrites, and a dry run writes nothing' {
        $out = Join-Path $work 'out1'
        [IO.File]::WriteAllText((Join-Path $out $a), 'changed by someone else', $utf8)
        $r = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $out, '-Json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.copied -eq 0 -and $r.Json.skipped -eq 3) ('second export: ' + $r.Text)
        Assert-True ([IO.File]::ReadAllText((Join-Path $out $a)) -eq 'changed by someone else') 'an existing file was overwritten'
        $kept = [IO.File]::ReadAllText((Join-Path $out 'handoff.json')) | ConvertFrom-Json
        Assert-True ($kept.count -eq 3 -and @($kept.captures).Count -eq 3) ('the first run''s manifest entries were lost: ' + $kept.count)
        Assert-True (($kept.captures | Where-Object { $_.name -eq $a }).ocr -eq 'Quarterly readiness report') 'the first run''s text was lost from the manifest'
        Assert-True (@($kept.skipped).Count -eq 3) 'the second run should report what it skipped'
        $dry = Join-Path $work 'out2'
        $d = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $dry, '-DryRun', '-Json')
        Assert-True ($d.Exit -eq 0 -and $d.Json.dryRun -eq $true -and $d.Json.copied -eq 3 -and -not [IO.Directory]::Exists($dry)) ('dry run wrote something: ' + $d.Text)
    }
    Test-Case 'a later export adds to the manifest, lists a skipped file once, and an unreadable manifest stops it' {
        $out = Join-Path $work 'out3'
        $r1 = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $out, '-Name', $a, '-IncludeText', '-Json')
        Assert-True ($r1.Exit -eq 0 -and $r1.Json.copied -eq 1) ('first partial export: ' + $r1.Text + $r1.Err)
        $r2 = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $out, '-Json')
        Assert-True ($r2.Exit -eq 0 -and $r2.Json.copied -eq 2 -and $r2.Json.skipped -eq 1) ('second export: ' + $r2.Text + $r2.Err)
        $m = [IO.File]::ReadAllText((Join-Path $out 'handoff.json')) | ConvertFrom-Json
        Assert-True ($m.count -eq 3 -and @($m.captures).Count -eq 3) ('manifest should list all three captures: ' + $m.count)
        Assert-True (@($m.captures | Where-Object { $_.name -eq $a }).Count -eq 1) 'a skipped file was listed twice'
        Assert-True (($m.captures | Where-Object { $_.name -eq $a }).ocr -eq 'Quarterly readiness report') 'the earlier entry lost its text'
        foreach ($e in $m.captures) { Assert-True ($e.sha256 -eq (Get-Sha (Join-Path $out $e.file))) ('manifest hash wrong for ' + $e.file) }
        Assert-True (-not [IO.File]::Exists((Join-Path $out 'handoff.json.tmp'))) 'a temporary manifest was left behind'
        $bad = Join-Path $work 'out4'
        [void][IO.Directory]::CreateDirectory($bad)
        [IO.File]::WriteAllText((Join-Path $bad 'handoff.json'), 'not json', $utf8)
        $r3 = Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $bad, '-Json')
        Assert-True ($r3.Exit -eq 1 -and -not [IO.File]::Exists((Join-Path $bad $a))) ('an unreadable manifest should stop the export before copying: ' + $r3.Exit)
        Assert-True ([IO.File]::ReadAllText((Join-Path $bad 'handoff.json')) -eq 'not json') 'the unreadable manifest was replaced'
    }
    Test-Case 'a comma list of names works as one -Name argument' {
        $r = Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Json', '-Name', ($a + ',' + $b))
        Assert-True ($r.Exit -eq 0 -and $r.Json.count -eq 2) ('comma list: ' + $r.Text + $r.Err)
    }
    Test-Case 'bad arguments and a missing library exit with the documented codes' {
        Assert-True ((Invoke-Handoff @('-Mode', 'export', '-Library', $lib)).Exit -eq 2) 'export without -OutDir'
        Assert-True ((Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', (Join-Path $lib 'inside'))).Exit -eq 2) 'output inside the library'
        Assert-True ((Invoke-Handoff @('-Mode', 'export', '-Library', $lib, '-OutDir', $lib)).Exit -eq 2) 'output is the library'
        Assert-True ((Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Name', '..\..\evil.png')).Exit -eq 2) 'a path as a name'
        Assert-True ((Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Since', 'yesterday-ish')).Exit -eq 2) 'a bad date'
        Assert-True ((Invoke-Handoff @('-Mode', 'list', '-Library', $lib, '-Max', '0')).Exit -eq 2) 'a bad -Max'
        Assert-True ((Invoke-Handoff @('-Mode', 'list', '-Library', (Join-Path $work 'nowhere'))).Exit -eq 1) 'a missing library'
        Assert-True (@(Get-ChildItem -LiteralPath $lib -Recurse -File).Count -eq 8) 'the capture folder was changed'
    }
} finally { try { [IO.Directory]::Delete($work, $true) } catch {} }
if ($script:failures -gt 0) { Write-Failure "$($script:failures) hand-off test(s) failed"; exit 1 }
Write-Host 'All hand-off tests passed.' -ForegroundColor Green
