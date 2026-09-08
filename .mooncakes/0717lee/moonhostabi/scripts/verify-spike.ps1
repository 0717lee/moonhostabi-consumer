param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'runtime'))
$hostTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$runLeaf = 'moonhostabi-' + [Guid]::NewGuid().ToString('N')
$runRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $runLeaf))
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}
$pushedLocation = $false

function Assert-ExactTempChild {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Parent,
    [Parameter(Mandatory)] [string] $ExpectedLeaf
  )

  $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
  $resolvedParent = (Resolve-Path -LiteralPath $Parent).ProviderPath
  $normalizedPath = [IO.Path]::GetFullPath($resolvedPath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $normalizedParent = [IO.Path]::GetFullPath($resolvedParent).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $prefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar
  if (
    $normalizedPath -eq $normalizedParent -or
    -not $normalizedPath.StartsWith($prefix, $script:pathComparison) -or
    [IO.Path]::GetFileName($normalizedPath) -cne $ExpectedLeaf -or
    $ExpectedLeaf -notmatch '^moonhostabi-[0-9a-f]{32}$'
  ) {
    throw "Refusing to remove unexpected temporary path '$normalizedPath'."
  }
}

function Invoke-Checked {
  param(
    [Parameter(Mandatory)] [string] $FilePath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [Parameter(Mandatory)] [string] $Description,
    [int[]] $AllowedExitCodes = @(0)
  )

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE
  if ($AllowedExitCodes -notcontains $exitCode) {
    throw "$Description failed with exit code $exitCode."
  }
}

function Resolve-Application {
  param([Parameter(Mandatory)] [string] $Name)

  $commands = @(Get-Command $Name -CommandType Application -ErrorAction Stop)
  if ($commands.Count -eq 0) {
    throw "Required executable '$Name' was not found."
  }
  return $commands[0].Source
}

function Invoke-UnsupportedInspect {
  param(
    [Parameter(Mandatory)] [string] $MoonExecutable,
    [Parameter(Mandatory)] [string] $Artifact,
    [Parameter(Mandatory)] [string] $Label
  )

  $stdoutPath = Join-Path $script:runRoot "$Label.stdout.json"
  $stderrPath = Join-Path $script:runRoot "$Label.stderr.json"
  & $MoonExecutable run cmd/moonhostabi --target native inspect $Artifact --format json `
    1> $stdoutPath 2> $stderrPath
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 3) {
    throw "$Label inspect must fail closed with exit code 3, received $exitCode."
  }

  $stdout = [IO.File]::ReadAllText($stdoutPath)
  $stderr = [IO.File]::ReadAllText($stderrPath)
  $abi = $stdout | ConvertFrom-Json
  $diagnosticDocument = $stderr | ConvertFrom-Json
  $diagnostics = @($diagnosticDocument.diagnostics)
  if (
    $diagnostics.Count -eq 0 -or
    -not ($diagnostics | Where-Object { $_.code -eq 'MHA_PROJECT_UNREPRESENTABLE' })
  ) {
    throw "$Label inspect did not emit MHA_PROJECT_UNREPRESENTABLE."
  }

  [pscustomobject]@{
    Abi = $abi
    Diagnostics = $diagnostics
    Stdout = $stdout
    StdoutPath = $stdoutPath
  }
}

function Resolve-WasmTools {
  $bundledRoot = Join-Path $script:repositoryRoot '.tools/wasm-tools'
  $bundled = @()
  if (Test-Path -LiteralPath $bundledRoot -PathType Container) {
    $expectedName = if ($IsWindows) { 'wasm-tools.exe' } else { 'wasm-tools' }
    $bundled = @(
      Get-ChildItem -LiteralPath $bundledRoot -Recurse -File |
        Where-Object { $_.Name -ceq $expectedName }
    )
  }
  if ($bundled.Count -gt 1) {
    throw "Expected at most one bundled wasm-tools executable, found $($bundled.Count)."
  }
  if ($bundled.Count -eq 1) {
    return $bundled[0].FullName
  }
  return Resolve-Application -Name 'wasm-tools'
}

[IO.Directory]::CreateDirectory($runRoot) | Out-Null
Assert-ExactTempChild -Path $runRoot -Parent $hostTempRoot -ExpectedLeaf $runLeaf

try {
  Push-Location $repositoryRoot
  $pushedLocation = $true

  $moonExecutable = Resolve-Application -Name 'moon'
  $nodeExecutable = Resolve-Application -Name 'node'
  $pwshExecutable = Resolve-Application -Name 'pwsh'
  $npmExecutable = if ($IsWindows) {
    Resolve-Application -Name 'npm.cmd'
  } else {
    Resolve-Application -Name 'npm'
  }
  $wasmToolsExecutable = Resolve-WasmTools

  $moonVersionLines = & $moonExecutable version --all
  $moonVersionExit = $LASTEXITCODE
  if ($moonVersionExit -ne 0) {
    throw "moon version --all failed with exit code $moonVersionExit."
  }
  $moonVersionText = $moonVersionLines -join "`n"
  $moonVersionLines | Write-Output
  if ($moonVersionText -notmatch '(?m)^moon 0\.1\.20260827 \(d0aaa07 2026-08-27\)') {
    throw 'Expected moon 0.1.20260827 (d0aaa07).'
  }
  if ($moonVersionText -notmatch '(?m)^moonc v0\.10\.11\+6ff76a5f9 \(2026-08-28\)') {
    throw 'Expected moonc v0.10.11+6ff76a5f9.'
  }

  $nodeVersion = (& $nodeExecutable --version) -join "`n"
  $nodeVersionExit = $LASTEXITCODE
  Write-Output $nodeVersion
  if ($nodeVersionExit -ne 0 -or $nodeVersion -cne 'v24.12.0') {
    throw "Expected Node.js v24.12.0, received '$nodeVersion'."
  }
  $npmVersionLines = & $npmExecutable --version
  $npmVersionExit = $LASTEXITCODE
  $npmVersion = $npmVersionLines -join "`n"
  $npmVersionLines | Write-Output
  if ($npmVersionExit -ne 0 -or $npmVersion -cne '11.6.2') {
    throw "Expected npm 11.6.2, received '$npmVersion'."
  }

  $wasmToolsVersion = (& $wasmToolsExecutable --version) -join "`n"
  $wasmToolsVersionExit = $LASTEXITCODE
  Write-Output $wasmToolsVersion
  if ($wasmToolsVersionExit -ne 0 -or $wasmToolsVersion -notmatch '^wasm-tools 1\.258\.0(?:\s|$)') {
    throw "Expected wasm-tools 1.258.0, received '$wasmToolsVersion'."
  }

  Invoke-Checked -FilePath $moonExecutable -Arguments @('update') -Description 'moon update'
  Invoke-Checked -FilePath $moonExecutable -Arguments @('check') -Description 'moon check (dependency resolution)'
  Invoke-Checked `
    -FilePath $pwshExecutable `
    -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/apply-wasm-core-patch.ps1')) `
    -Description 'wasm_core patch application'
  Invoke-Checked -FilePath $moonExecutable -Arguments @('fmt', '--check') -Description 'moon fmt --check'
  Invoke-Checked -FilePath $moonExecutable -Arguments @('check') -Description 'moon check'
  Invoke-Checked -FilePath $moonExecutable -Arguments @('test', '--target', 'native') -Description 'moon test'
  Invoke-Checked -FilePath $pwshExecutable -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/verify-command.ps1'), '-RepositoryRoot', $repositoryRoot) -Description 'one-command Host ABI verification'
  Invoke-Checked -FilePath $pwshExecutable -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/verify-reproduction-bundle.ps1'), '-RepositoryRoot', $repositoryRoot) -Description 'deterministic reproduction bundle verification'
  Invoke-Checked -FilePath $pwshExecutable -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/verify-release-packaging.ps1'), '-RepositoryRoot', $repositoryRoot) -Description 'release packaging and workflow verification'
  Invoke-Checked -FilePath $pwshExecutable -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/verify-generate-transactions.ps1'), '-RepositoryRoot', $repositoryRoot) -Description 'transactional generate concurrency verification'
  Invoke-Checked `
    -FilePath $pwshExecutable `
    -Arguments @('-NoProfile', '-File', (Join-Path $repositoryRoot 'scripts/build-fixtures.ps1')) `
    -Description 'fixture rebuild and validation'

  $expectedArtifactHashes = [ordered]@{
    'breaking_v1.wasm' = '8b5ab1fb29df82f4183412accb55c6baaa969126fd08ec67c46c9c99f3fa1a8e'
    'breaking_v2.wasm' = '317eebbf2a61bafa96b2ad5be8c20a9fe82e0c31b75806ac156ebc8aa25e9d5c'
    'externref.wasm' = 'a748ac44370fd11670fc00d3a1a540809823b2370bc734518cbfc849a88da057'
    'rec-a.wasm' = '885ebd2fa3c5f4cadb67905569e1566ef84a53bc9a9b6a4cea77a7187fe873cc'
    'rec-reindexed.wasm' = 'c860e7e7fbdb91b8558a20bc5bc94f3a4fcbe71dd5036b3c6d32ac96a878cda5'
    'recursive.wasm' = 'd50b38d7d2aaae48688c94f35344fd78a4b831473750095806957e5743b99b3c'
    'scalar.wasm' = '04904560d0bd1289fe93858d96c4692a4865ba138e4f4db335478f3263cdcfbd'
  }
  foreach ($entry in $expectedArtifactHashes.GetEnumerator()) {
    $artifactPath = Join-Path $repositoryRoot "fixtures/artifacts/$($entry.Key)"
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
    if ($actualHash -cne $entry.Value) {
      throw "Fixture hash mismatch for $($entry.Key): $actualHash"
    }
    Write-Output "FIXTURE_SHA256 $($entry.Key)=$actualHash"
  }

  $recursiveArtifact = Join-Path $repositoryRoot 'fixtures/artifacts/recursive.wasm'
  $recursive = Invoke-UnsupportedInspect `
    -MoonExecutable $moonExecutable `
    -Artifact $recursiveArtifact `
    -Label 'recursive'
  $recursiveExports = @($recursive.Abi.exports)
  $recursiveTypes = @($recursive.Abi.types)
  if (
    $recursive.Abi.schemaVersion -ne 1 -or
    $recursiveExports.Count -ne 2 -or
    @($recursiveExports.name) -notcontains 'new_node' -or
    @($recursiveExports.name) -notcontains 'node_value' -or
    $recursiveTypes.Count -ne 1 -or
    $recursiveTypes[0].kind -cne 'struct' -or
    @($recursiveTypes[0].fields).Count -ne 2 -or
    $recursiveTypes[0].fields[0].storage -cne 'i32' -or
    $recursiveTypes[0].fields[1].storage -cne 'ref null type[0]' -or
    $recursiveTypes[0].fields[1].mutable -ne $true
  ) {
    throw 'Recursive fixture did not project the expected host-reachable graph.'
  }
  $recursiveAbiHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $recursive.StdoutPath).Hash.ToLowerInvariant()
  Write-Output "RECURSIVE_ABI_JSON_SHA256=$recursiveAbiHash"

  $recA = Invoke-UnsupportedInspect `
    -MoonExecutable $moonExecutable `
    -Artifact (Join-Path $repositoryRoot 'fixtures/artifacts/rec-a.wasm') `
    -Label 'rec-a'
  $recReindexed = Invoke-UnsupportedInspect `
    -MoonExecutable $moonExecutable `
    -Artifact (Join-Path $repositoryRoot 'fixtures/artifacts/rec-reindexed.wasm') `
    -Label 'rec-reindexed'
  if (-not [String]::Equals($recA.Stdout, $recReindexed.Stdout, [StringComparison]::Ordinal)) {
    throw 'Canonical ABI changed after raw recursive type reindexing.'
  }
  $reindexedAbiHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $recA.StdoutPath).Hash.ToLowerInvariant()
  Write-Output "REINDEXED_ABI_JSON_SHA256=$reindexedAbiHash"

  $freshGeneratedRoot = Join-Path $runRoot 'generated'
  Invoke-Checked `
    -FilePath $moonExecutable `
    -Arguments @(
      'run', 'cmd/moonhostabi', '--target', 'native', 'generate',
      (Join-Path $repositoryRoot 'fixtures/artifacts/externref.wasm'),
      '--contract', (Join-Path $repositoryRoot 'fixtures/contracts/externref.contract.json'),
      '--out', $freshGeneratedRoot
    ) `
    -Description 'fresh TypeScript adapter generation'
  foreach ($generatedName in @(
    'adapter.ts',
    'moonhostabi.contract.json',
    'moonhostabi.manifest.json'
  )) {
    $trackedPath = Join-Path $runtimeRoot "generated/$generatedName"
    $freshPath = Join-Path $freshGeneratedRoot $generatedName
    $trackedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $trackedPath).Hash.ToLowerInvariant()
    $freshHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshPath).Hash.ToLowerInvariant()
    if ($trackedHash -cne $freshHash) {
      throw "Tracked $generatedName differs from fresh generator output."
    }
    Write-Output "GENERATED_SHA256 $generatedName=$trackedHash"
  }

  $breakingV1 = Join-Path $repositoryRoot 'fixtures/artifacts/breaking_v1.wasm'
  $breakingV2 = Join-Path $repositoryRoot 'fixtures/artifacts/breaking_v2.wasm'
  $lockA = Join-Path $runRoot 'breaking-v1-a.lock.json'
  $lockB = Join-Path $runRoot 'breaking-v1-b.lock.json'
  Invoke-Checked `
    -FilePath $moonExecutable `
    -Arguments @('run', 'cmd/moonhostabi', '--target', 'native', 'lock', $breakingV1, '--out', $lockA) `
    -Description 'first breaking_v1 lock'
  Invoke-Checked `
    -FilePath $moonExecutable `
    -Arguments @('run', 'cmd/moonhostabi', '--target', 'native', 'lock', $breakingV1, '--out', $lockB) `
    -Description 'second breaking_v1 lock'
  $lockHashA = (Get-FileHash -Algorithm SHA256 -LiteralPath $lockA).Hash.ToLowerInvariant()
  $lockHashB = (Get-FileHash -Algorithm SHA256 -LiteralPath $lockB).Hash.ToLowerInvariant()
  if ($lockHashA -cne $lockHashB) {
    throw "Repeated lockfiles differ: $lockHashA versus $lockHashB."
  }
  Write-Output "LOCKFILE_SHA256=$lockHashA"

  Invoke-Checked `
    -FilePath $moonExecutable `
    -Arguments @('run', 'cmd/moonhostabi', '--target', 'native', 'check', $breakingV1, '--against', $lockA) `
    -Description 'compatible baseline check'

  $breakingStdoutPath = Join-Path $runRoot 'breaking-check.stdout.json'
  $breakingStderrPath = Join-Path $runRoot 'breaking-check.stderr.txt'
  & $moonExecutable run cmd/moonhostabi --target native check $breakingV2 --against $lockA `
    1> $breakingStdoutPath 2> $breakingStderrPath
  $breakingExit = $LASTEXITCODE
  if ($breakingExit -ne 2) {
    throw "Breaking check must return exit code 2, received $breakingExit."
  }
  $breakingStderr = [IO.File]::ReadAllText($breakingStderrPath)
  if (-not [String]::IsNullOrWhiteSpace($breakingStderr)) {
    throw "Breaking check wrote unexpected stderr: $breakingStderr"
  }
  $breakingText = [IO.File]::ReadAllText($breakingStdoutPath)
  $breakingReport = $breakingText | ConvertFrom-Json
  $breakingChanges = @($breakingReport.changes)
  if (
    $breakingReport.classification -cne 'breaking' -or
    -not ($breakingChanges | Where-Object {
      $_.code -eq 'MHA_SIGNATURE_CHANGED' -and $_.path -eq 'exports[add].params'
    })
  ) {
    throw 'Breaking check did not report MHA_SIGNATURE_CHANGED at exports[add].params.'
  }
  Write-Output $breakingText.Trim()

  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'ci') `
    -Description 'npm ci'
  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'exec', '--', 'playwright', 'install', 'chromium') `
    -Description 'Playwright Chromium installation'
  $typescriptVersionLines = & $npmExecutable --prefix $runtimeRoot exec -- tsc --version
  $typescriptVersionExit = $LASTEXITCODE
  $typescriptVersion = $typescriptVersionLines -join "`n"
  $typescriptVersionLines | Write-Output
  if ($typescriptVersionExit -ne 0 -or $typescriptVersion -cne 'Version 7.0.2') {
    throw "Expected TypeScript 7.0.2, received '$typescriptVersion'."
  }
  $playwrightVersionLines = & $npmExecutable --prefix $runtimeRoot exec -- playwright --version
  $playwrightVersionExit = $LASTEXITCODE
  $playwrightVersion = $playwrightVersionLines -join "`n"
  $playwrightVersionLines | Write-Output
  if ($playwrightVersionExit -ne 0 -or $playwrightVersion -cne 'Version 1.62.1') {
    throw "Expected Playwright 1.62.1, received '$playwrightVersion'."
  }
  $untypedMatches = @(
    Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'generated') -Filter '*.ts' -File |
      Select-String -Pattern '\bany\b'
  )
  if ($untypedMatches.Count -ne 0) {
    throw 'Generated TypeScript contains an any escape hatch.'
  }
  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'run', 'typecheck') `
    -Description 'TypeScript checking'
  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'run', 'build') `
    -Description 'TypeScript build'
  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'run', 'test:node') `
    -Description 'Node runtime verification'
  Invoke-Checked `
    -FilePath $npmExecutable `
    -Arguments @('--prefix', $runtimeRoot, 'run', 'test:browser') `
    -Description 'Chromium runtime verification'

  Write-Output 'MOONHOSTABI_SPIKE_STATUS=GO'
}
finally {
  if ($pushedLocation) {
    Pop-Location
  }
  if (Test-Path -LiteralPath $runRoot) {
    Assert-ExactTempChild -Path $runRoot -Parent $hostTempRoot -ExpectedLeaf $runLeaf
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  }
}
