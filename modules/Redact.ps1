# Smart redaction for scripts (tools/evidence-capture.ps1). Mirrors assets/redact.js so the studio and the
# scripted pass find the same things: OCR lines in, boxes out, then solid boxes drawn into the PNG.
# Input shape (from Invoke-SnapShackleOcr): @{ text; words = @(@{ text; x; y; w; h }) } per line.
# Pixelation and blur are not used: only opaque boxes are secure.
Add-Type -AssemblyName System.Drawing

function Test-SnapShackleLuhn([string]$Digits) {
    $sum = 0; $odd = $false
    for ($i = $Digits.Length - 1; $i -ge 0; $i--) {
        $d = [int][string]$Digits[$i]
        if ($odd) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d; $odd = -not $odd
    }
    return ($sum % 10 -eq 0)
}
# Order matters: an earlier kind wins when two matches overlap (an SSN is not also a phone number).
$script:SnapShackleRedactKinds = @(
    @{ kind = 'email'; label = 'Email'; pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' },
    @{ kind = 'ssn'; label = 'SSN'; pattern = '(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)' },
    @{ kind = 'card'; label = 'Card number'; pattern = '(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)'
       check = { param($m) $d = $m -replace '\D', ''; $d.Length -ge 13 -and $d.Length -le 19 -and (Test-SnapShackleLuhn $d) } },
    @{ kind = 'dodid'; label = 'DoD ID'; pattern = '(?<!\d)\d{10}(?!\d)' },
    @{ kind = 'phone'; label = 'Phone'; pattern = '(?<![\d-])(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\d-])' },
    @{ kind = 'ip'; label = 'IP address'; pattern = '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])'
       check = { param($m) @($m.Split('.') | Where-Object { [int]$_ -gt 255 }).Count -eq 0 } }
)
# Joins a line's words with single spaces and remembers where each word sits in that string.
function Get-SnapShackleLineLayout($Line) {
    $words = @($Line.words | Where-Object { $null -ne $_ -and $null -ne $_.text })
    if ($words.Count -eq 0 -and $Line.text) { $words = @(@{ text = [string]$Line.text; x = $Line.x; y = $Line.y; w = $Line.w; h = $Line.h }) }
    $text = ''; $spans = [Collections.Generic.List[object]]::new()
    foreach ($w in $words) {
        if ($text.Length -gt 0) { $text += ' ' }
        $spans.Add(@{ start = $text.Length; end = $text.Length + ([string]$w.text).Length; word = $w })
        $text += [string]$w.text
    }
    return @{ text = $text; spans = $spans }
}
function Get-SnapShackleSpanBox($Spans, [int]$Start, [int]$End, [int]$Pad) {
    $x0 = [double]::PositiveInfinity; $y0 = $x0; $x1 = [double]::NegativeInfinity; $y1 = $x1
    foreach ($s in $Spans) {
        if ($s.start -lt $End -and $s.end -gt $Start -and $null -ne $s.word.x) {
            $w = $s.word
            $x0 = [Math]::Min($x0, [double]$w.x); $y0 = [Math]::Min($y0, [double]$w.y)
            $x1 = [Math]::Max($x1, [double]$w.x + [double]$w.w); $y1 = [Math]::Max($y1, [double]$w.y + [double]$w.h)
        }
    }
    if ([double]::IsInfinity($x0)) { return $null }
    return @{ x = [int][Math]::Floor($x0 - $Pad); y = [int][Math]::Floor($y0 - $Pad); x2 = [int][Math]::Ceiling($x1 + $Pad); y2 = [int][Math]::Ceiling($y1 + $Pad) }
}
function Find-SnapShackleMatches($Lines, $Patterns, [int]$Pad) {
    $found = [Collections.Generic.List[object]]::new()
    foreach ($line in @($Lines)) {
        $layout = Get-SnapShackleLineLayout $line
        $taken = [Collections.Generic.List[object]]::new()
        foreach ($p in $Patterns) {
            foreach ($m in [regex]::Matches($layout.text, $p.pattern, 'IgnoreCase')) {
                if ($m.Length -eq 0) { continue }
                $start = $m.Index; $end = $m.Index + $m.Length
                if ($p.check -and -not (& $p.check $m.Value)) { continue }
                if (@($taken | Where-Object { $_.start -lt $end -and $_.end -gt $start }).Count -gt 0) { continue }
                $box = Get-SnapShackleSpanBox $layout.spans $start $end $Pad
                if ($null -eq $box) { continue }
                $taken.Add(@{ start = $start; end = $end })
                $found.Add(@{ kind = $p.kind; label = $p.label; text = $m.Value; box = $box })
            }
        }
    }
    return $found.ToArray()
}
# Every built-in kind of sensitive text in the OCR result.
function Find-SnapShackleSensitive($Lines, [int]$Pad = 3) { return (Find-SnapShackleMatches $Lines $script:SnapShackleRedactKinds $Pad) }
# Every occurrence of a word or phrase, ignoring case.
function Find-SnapShackleTerm($Lines, [string]$Term, [int]$Pad = 3) {
    $t = $Term.Trim()
    if ($t.Length -eq 0) { return @() }
    $pattern = ([regex]::Escape($t)) -replace '(\\ )+', '\s+'
    return (Find-SnapShackleMatches $Lines @(@{ kind = 'term'; label = ('"' + $t + '"'); pattern = $pattern }) $Pad)
}
# Draws opaque black boxes over the given boxes ({x,y,x2,y2}, clamped to the image) and returns the new PNG bytes.
function Add-SnapShackleRedactionBoxes([byte[]]$Png, $Boxes) {
    $in = [IO.MemoryStream]::new($Png, $false)
    try {
        $src = [Drawing.Bitmap]::new($in)
        try {
            $bmp = [Drawing.Bitmap]::new($src.Width, $src.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $gfx = [Drawing.Graphics]::FromImage($bmp)
            try {
                $gfx.DrawImageUnscaled($src, 0, 0)
                foreach ($b in @($Boxes)) {
                    $x = [Math]::Max(0, [int]$b.x); $y = [Math]::Max(0, [int]$b.y)
                    $w = [Math]::Min($bmp.Width, [int]$b.x2) - $x; $h = [Math]::Min($bmp.Height, [int]$b.y2) - $y
                    if ($w -gt 0 -and $h -gt 0) { $gfx.FillRectangle([Drawing.Brushes]::Black, $x, $y, $w, $h) }
                }
                $out = [IO.MemoryStream]::new()
                try { $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png); return ,$out.ToArray() } finally { $out.Dispose() }
            } finally { $gfx.Dispose(); $bmp.Dispose() }
        } finally { $src.Dispose() }
    } finally { $in.Dispose() }
}
