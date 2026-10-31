<#
  Repeatable evidence screenshots: draws a list of named SYNTHETIC windows, captures each one with PrintWindow,
  finds sensitive text with Windows OCR, covers it with opaque boxes, re-reads the result to prove nothing is left,
  and writes the PNGs plus evidence-index.json. It never captures the real desktop or any window it did not draw.

  Usage (Windows PowerShell 5.1, STA, no admin):
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\evidence-capture.ps1 -Manifest tools\evidence-manifest.sample.json -OutDir evidence-out

  -Manifest     JSON file, see tools\evidence-manifest.sample.json and docs\EVIDENCE-CAPTURE.md
  -OutDir       where PNGs and evidence-index.json go (created; existing files with the same names are replaced)
  -KeepRaw      also keep NAME-raw.png (the unredacted synthetic window). Off by default.
  -SkipRedact   capture only (no OCR needed). The index says redacted=false for every file.
  -Json         print the index as JSON on stdout instead of the summary

  Exit codes: 0 all good; 1 a problem (OCR missing when redaction is on, an expected finding missing, text left after
  redaction, bad manifest). Nothing is written to a real repo or service.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [switch]$KeepRaw,
    [switch]$SkipRedact,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'modules/Native.ps1')
. (Join-Path $project 'modules/Ocr.ps1')
. (Join-Path $project 'modules/Redact.ps1')

function Read-SnapShackleEvidenceManifest([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { throw ('Manifest not found: ' + $Path) }
    $data = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $windows = @($data.windows)
    if ($windows.Count -eq 0) { throw 'The manifest has no windows' }
    if ($windows.Count -gt 40) { throw 'At most 40 windows per manifest' }
    $seen = @{}
    $clean = foreach ($w in $windows) {
        $name = [string]$w.name
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$') { throw ('Window name must be letters, digits, dot, dash or underscore: "' + $name + '"') }
        if ($seen.ContainsKey($name.ToLowerInvariant())) { throw ('Duplicate window name: ' + $name) }
        $seen[$name.ToLowerInvariant()] = $true
        $width = if ($w.width) { [int]$w.width } else { 760 }
        $height = if ($w.height) { [int]$w.height } else { 420 }
        if ($width -lt 200 -or $width -gt 1800 -or $height -lt 120 -or $height -gt 1200) { throw ('Window size out of range for ' + $name + ' (200-1800 x 120-1200)') }
        [pscustomobject]@{
            name = $name
            title = $(if ($w.title) { [string]$w.title } else { 'Fleet Demo - ' + $name })
            width = $width; height = $height
            fontSize = $(if ($w.fontSize) { [Math]::Max(12, [Math]::Min(48, [int]$w.fontSize)) } else { 20 })
            lines = @($w.lines | ForEach-Object { [string]$_ })
            expect = @($w.expect | Where-Object { $_ } | ForEach-Object { [string]$_ })
            redactTerms = @($w.redactTerms | Where-Object { $_ } | ForEach-Object { [string]$_ })
            # Fixed boxes in captured-image pixels (title bar included), for text OCR is known to miss.
            boxes = @($w.boxes | Where-Object { $_ } | ForEach-Object {
                if ([int]$_.w -le 0 -or [int]$_.h -le 0) { throw ('Box with no size in ' + $name) }
                @{ x = [int]$_.x; y = [int]$_.y; x2 = [int]$_.x + [int]$_.w; y2 = [int]$_.y + [int]$_.h } })
        }
    }
    $terms = @($data.redactTerms | Where-Object { $_ } | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ windows = @($clean); redactTerms = $terms }
}

# One synthetic window: white page, dark text, drawn by this script, on screen just long enough to capture.
function New-SnapShackleSyntheticWindow($Spec) {
    $form = [Windows.Forms.Form]::new()
    $form.Text = $Spec.title
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = [Drawing.Point]::new(40, 40)
    $form.ClientSize = [Drawing.Size]::new($Spec.width, $Spec.height)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.ShowInTaskbar = $false
    $form.BackColor = [Drawing.Color]::White
    $label = [Windows.Forms.Label]::new()
    $label.AutoSize = $false; $label.Dock = [Windows.Forms.DockStyle]::Fill
    $label.Padding = [Windows.Forms.Padding]::new(24, 20, 24, 20)
    $label.ForeColor = [Drawing.Color]::FromArgb(20, 24, 32)
    $label.Font = [Drawing.Font]::new('Arial', [single]$Spec.fontSize, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $label.Text = ($Spec.lines -join "`r`n`r`n")
    $form.Controls.Add($label)
    return $form
}
function Wait-SnapShackleUi([int]$Milliseconds) {
    $end = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
}
function Get-SnapShackleSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
function Get-SnapShackleKindCounts($Findings) {
    $counts = [ordered]@{}
    foreach ($f in @($Findings)) { if ($counts.Contains($f.kind)) { $counts[$f.kind]++ } else { $counts[$f.kind] = 1 } }
    return $counts
}

$spec = Read-SnapShackleEvidenceManifest $Manifest
if (-not $SkipRedact -and -not (Test-SnapShackleOcr)) {
    throw 'Windows OCR is not available here, so the redaction pass cannot run. Use Windows PowerShell 5.1 with an OCR language pack, or pass -SkipRedact to capture without redacting (the index will say so).'
}
[void][IO.Directory]::CreateDirectory($OutDir)
$entries = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
[Windows.Forms.Application]::EnableVisualStyles()

foreach ($w in $spec.windows) {
    $form = New-SnapShackleSyntheticWindow $w
    $raw = $null
    try {
        $form.Show()
        Wait-SnapShackleUi 600
        $method = $null
        $bitmap = [SnapShackle.Native]::CaptureWindow([long]$form.Handle, [ref]$method)
        try { $raw = Convert-SnapShackleBitmapToPng $bitmap } finally { $bitmap.Dispose() }
    } finally { $form.Close(); $form.Dispose() }

    $png = $raw; $findings = @(); $redacted = $false; $residual = 0; $engine = ''
    if (-not $SkipRedact) {
        $ocr = Invoke-SnapShackleOcr $raw
        $engine = 'Windows.Media.Ocr'
        $findings = @(Find-SnapShackleSensitive $ocr.lines)
        foreach ($term in @($spec.redactTerms) + @($w.redactTerms)) { $findings += @(Find-SnapShackleTerm $ocr.lines $term) }
        foreach ($kind in $w.expect) {
            if (@($findings | Where-Object { $_.kind -eq $kind }).Count -eq 0) { $problems.Add($w.name + ': expected to find "' + $kind + '" but OCR did not') }
        }
        $png = Add-SnapShackleRedactionBoxes $raw (@($findings | ForEach-Object { $_.box }) + @($w.boxes))
        $redacted = $true
        # Prove it: read the redacted image again; no built-in kind and no listed term may remain.
        $again = Invoke-SnapShackleOcr $png
        $left = @(Find-SnapShackleSensitive $again.lines)
        foreach ($term in @($spec.redactTerms) + @($w.redactTerms)) { $left += @(Find-SnapShackleTerm $again.lines $term) }
        $residual = $left.Count
        if ($residual -gt 0) { $problems.Add($w.name + ': ' + $residual + ' sensitive item(s) still readable after redaction (' + ((@($left | ForEach-Object { $_.kind }) | Sort-Object -Unique) -join ', ') + ')') }
    }
    $file = $w.name + '.png'
    [IO.File]::WriteAllBytes((Join-Path $OutDir $file), $png)
    if ($KeepRaw) { [IO.File]::WriteAllBytes((Join-Path $OutDir ($w.name + '-raw.png')), $raw) }
    $size = [Drawing.Image]::FromStream([IO.MemoryStream]::new($png))
    $entry = [ordered]@{
        name = $w.name; file = $file; title = $w.title; width = $size.Width; height = $size.Height; sha256 = (Get-SnapShackleSha256 $png)
        captureMethod = [string]$method; redacted = $redacted; ocrEngine = $engine
        # Counts per kind only: the matched text itself is never written to the index.
        findings = (Get-SnapShackleKindCounts $findings); fixedBoxes = @($w.boxes).Count; residualAfterRedaction = $residual
    }
    $size.Dispose()
    $entries.Add($entry)
}
$index = [ordered]@{ schema = 1; generated = (Get-Date).ToUniversalTime().ToString('o'); synthetic = $true; redactionPass = (-not $SkipRedact); ok = ($problems.Count -eq 0); problems = @($problems); items = @($entries) }
$jsonText = ConvertTo-Json -InputObject $index -Depth 6
[IO.File]::WriteAllText((Join-Path $OutDir 'evidence-index.json'), $jsonText, [Text.UTF8Encoding]::new($false))
if ($Json) { Write-Output $jsonText }
else {
    foreach ($e in $entries) {
        $f = if ($e.findings.Count) { ($e.findings.GetEnumerator() | ForEach-Object { $_.Key + 'x' + $_.Value }) -join ' ' } else { 'none' }
        Write-Host ('{0,-24} {1}x{2}  redacted={3}  found: {4}' -f $e.file, $e.width, $e.height, $e.redacted, $f)
    }
    Write-Host ('Wrote ' + $entries.Count + ' file(s) and evidence-index.json to ' + (Resolve-Path $OutDir))
}
if ($problems.Count -gt 0) { foreach ($p in $problems) { Write-Host ('PROBLEM: ' + $p) -ForegroundColor Red }; exit 1 }
