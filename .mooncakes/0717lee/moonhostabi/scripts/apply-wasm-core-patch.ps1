$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleRoot = [IO.Path]::GetFullPath(
  (Join-Path $repoRoot '.mooncakes/Milky2018/wasm_core')
)
$patchPath = [IO.Path]::GetFullPath(
  (Join-Path $repoRoot 'patches/wasm_core-0.14.0-singleton-rec.patch')
)
$moduleDirectory = '.mooncakes/Milky2018/wasm_core'
$versionPath = Join-Path $moduleRoot 'moon.mod'
$targetPath = Join-Path $moduleRoot 'parser/rec_group_types.mbt'
$baselineSha256 = 'd2d70401532ce13ed844ce2e70f64702ff6591bd9188848f85b8ea2115807417'
$patchedSha256 = 'a835b9e5a47587c4f5d1e6792313f59b2ebfc149156de5b388903007662397d0'

if (-not (Test-Path -LiteralPath $versionPath)) {
  throw "Missing wasm_core dependency at '$moduleRoot'. Run 'moon update' first."
}
if (-not (Test-Path -LiteralPath $patchPath)) {
  throw "Missing dependency patch at '$patchPath'."
}
if (-not (Test-Path -LiteralPath $targetPath)) {
  throw "Missing wasm_core parser source at '$targetPath'."
}
$moduleConfig = [IO.File]::ReadAllText($versionPath)
if ($moduleConfig -notmatch '(?m)^version\s*=\s*"0\.14\.0"\s*$') {
  throw 'The local wasm_core version is not 0.14.0; refusing to apply a stale patch.'
}

function Get-NormalizedSourceSha256 {
  param([Parameter(Mandatory)] [string] $Path)
  $source = [IO.File]::ReadAllText($Path).
    Replace("`r`n", "`n").
    Replace("`r", "`n").
    TrimEnd() + "`n"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($source)
  $digest = [Security.Cryptography.SHA256]::HashData($bytes)
  -join ($digest | ForEach-Object { $_.ToString('x2') })
}

$sourceSha256 = Get-NormalizedSourceSha256 -Path $targetPath
if ($sourceSha256 -eq $patchedSha256) {
  Write-Output 'wasm_core 0.14.0 singleton-rec patch is already applied.'
  return
}
if ($sourceSha256 -ne $baselineSha256) {
  throw "Unexpected wasm_core parser source SHA-256 '$sourceSha256'; refusing to patch."
}

$gitCommand = Get-Command git -ErrorAction Stop
Push-Location $repoRoot
try {
  & $gitCommand.Source apply --check --ignore-whitespace --directory=$moduleDirectory $patchPath
  if ($LASTEXITCODE -ne 0) {
    throw "wasm_core patch preflight failed with exit code $LASTEXITCODE"
  }
  & $gitCommand.Source apply --ignore-whitespace --directory=$moduleDirectory $patchPath
  if ($LASTEXITCODE -ne 0) {
    throw "wasm_core patch application failed with exit code $LASTEXITCODE"
  }
  $resultSha256 = Get-NormalizedSourceSha256 -Path $targetPath
  if ($resultSha256 -ne $patchedSha256) {
    throw "wasm_core patch postcondition failed: unexpected SHA-256 '$resultSha256'."
  }
  Write-Output 'Applied wasm_core 0.14.0 singleton-rec parser patch.'
} finally {
  Pop-Location
}
