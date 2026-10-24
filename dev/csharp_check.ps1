<#
  Compiles every inline C# block (Add-Type -TypeDefinition @' ... '@) in the repo with Roslyn,
  as C# 5 against .NET Framework 4.8 reference assemblies - the same language level Windows
  PowerShell 5.1 uses. Lets you catch compile errors on a machine without Windows.
  Usage (PowerShell 7): pwsh dev/csharp_check.ps1 -ReferenceDir <folder with mscorlib.dll, System.dll,
  System.Core.dll, System.Drawing.dll, System.Windows.Forms.dll for v4.8>
  Reference assemblies: https://github.com/mono/reference-assemblies (folder v4.8).
#>
param([Parameter(Mandatory)][string]$ReferenceDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshDir = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Add-Type -Path (Join-Path $pwshDir 'Microsoft.CodeAnalysis.dll')
Add-Type -Path (Join-Path $pwshDir 'Microsoft.CodeAnalysis.CSharp.dll')
[Microsoft.CodeAnalysis.MetadataReference[]]$refs = 'mscorlib','System','System.Core','System.Drawing','System.Windows.Forms' | ForEach-Object {
    [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $ReferenceDir "$_.dll"))
}
$parse = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::new([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$failed = 0
Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName)
    $blocks = [regex]::Matches($text, "(?s)-TypeDefinition\s+@'\r?\n(.*?)\r?\n'@")
    $i = 0
    foreach ($block in $blocks) {
        $i++
        $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($block.Groups[1].Value, $parse)
        $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create("check$i", [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $refs, $options)
        $stream = [IO.MemoryStream]::new()
        $emit = $compilation.Emit($stream)
        $problems = @($emit.Diagnostics | Where-Object { $_.Severity -ge [Microsoft.CodeAnalysis.DiagnosticSeverity]::Warning })
        if ($emit.Success -and $problems.Count -eq 0) { Write-Host "OK    $($_.Name) block $i" }
        else {
            if (-not $emit.Success) { $failed++ }
            Write-Host "$(if ($emit.Success) {'WARN'} else {'FAIL'})  $($_.Name) block $i"
            $problems | ForEach-Object { Write-Host ('      ' + $_.ToString()) }
        }
    }
}
if ($failed) { exit 1 }
