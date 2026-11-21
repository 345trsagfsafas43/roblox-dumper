param([string]$Luau = '', [string]$Analyzer = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Luau) { $Luau = Join-Path $projectRoot '.tools/luau-0.748/luau.exe' }
if (-not $Analyzer) { $Analyzer = Join-Path (Split-Path -Parent $Luau) 'luau-analyze.exe' }
if (-not (Test-Path -LiteralPath $Luau -PathType Leaf)) { throw 'Luau 0.748 runtime required; pass -Luau with its path.' }
$dumperSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'dumper.lua'))
$harnessSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'harness.luau'))
if ($dumperSource.Contains(']====]')) { throw 'Source collides with regression string delimiter.' }
$generated = Join-Path $projectRoot '.tools/regression.generated.luau'
[IO.Directory]::CreateDirectory((Split-Path -Parent $generated)) | Out-Null
[IO.File]::WriteAllText($generated, "local SOURCE = [====[`n" + $dumperSource + "`n]====]`n" + $harnessSource)
Push-Location -LiteralPath $projectRoot
try {
    & $Analyzer 'dumper.lua'
    if ($LASTEXITCODE -ne 0) { throw "Luau analyzer failed: $LASTEXITCODE" }
    & $Luau $generated
    if ($LASTEXITCODE -ne 0) { throw "Regression tests failed: $LASTEXITCODE" }
} finally { Pop-Location }
