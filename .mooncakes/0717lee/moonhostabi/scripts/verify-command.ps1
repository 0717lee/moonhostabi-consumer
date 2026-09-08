param(
  [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([String]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$hostTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$runLeaf = 'moonhostabi-verify-' + [Guid]::NewGuid().ToString('N')
$runRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $runLeaf))
$fixtureRoot = Join-Path $runRoot '中文 路径'
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}

function Assert-ExactVerificationTemp {
  $resolvedPath = (Resolve-Path -LiteralPath $script:runRoot).ProviderPath
  $resolvedParent = (Resolve-Path -LiteralPath $script:hostTempRoot).ProviderPath
  $normalizedPath = [IO.Path]::GetFullPath($resolvedPath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $normalizedParent = [IO.Path]::GetFullPath($resolvedParent).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $expectedPrefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar
  if (
    -not $normalizedPath.StartsWith($expectedPrefix, $script:pathComparison) -or
    [IO.Path]::GetFileName($normalizedPath) -cne $script:runLeaf -or
    $script:runLeaf -notmatch '^moonhostabi-verify-[0-9a-f]{32}$'
  ) {
    throw "Refusing to remove unexpected verification path '$normalizedPath'."
  }
}

function Invoke-MoonHostAbi {
  param(
    [Parameter(Mandatory)] [string] $CliPath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [int] $TimeoutMilliseconds = 45000
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $CliPath
  $startInfo.WorkingDirectory = $script:repositoryRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) {
      throw 'Failed to start the MoonHostABI command verifier process.'
    }
    [void]$script:runningProcesses.Add($process)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "MoonHostABI process timed out after $TimeoutMilliseconds ms. stdout='$($stdout.GetAwaiter().GetResult())' stderr='$($stderr.GetAwaiter().GetResult())'"
    }
    $process.WaitForExit()
    [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdout.GetAwaiter().GetResult()
      Stderr = $stderr.GetAwaiter().GetResult()
    }
  }
  catch {
    if ($started -and -not $process.HasExited) {
      $process.Kill($true)
      $process.WaitForExit()
    }
    if (-not $started) {
      $process.Dispose()
    }
    throw
  }
}

function Normalize-Output {
  param([AllowEmptyString()] [string] $Text)

  ($Text -replace "`r`n?", "`n").TrimEnd("`n")
}

function Get-StrictModuleVersion {
  param([Parameter(Mandatory)] [string] $Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Module manifest was not found at '$Path'."
  }
  $versionLines = @(
    [IO.File]::ReadAllLines($Path) |
      Where-Object { $_ -match '^\s*version\b' }
  )
  if ($versionLines.Count -ne 1) {
    throw "Module manifest must contain exactly one version field; found $($versionLines.Count)."
  }
  $versionMatch = [regex]::Match(
    $versionLines[0],
    '^version = "([0-9]+\.[0-9]+\.[0-9]+)"$',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
  )
  if (-not $versionMatch.Success) {
    throw 'Module manifest version must use the exact form version = "MAJOR.MINOR.PATCH".'
  }
  $versionMatch.Groups[1].Value
}

function Assert-ModuleVersionParserRejects {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
    [Parameter(Mandatory)] [string] $Description
  )

  [IO.File]::WriteAllText($Path, $Content)
  $rejected = $false
  try {
    $null = Get-StrictModuleVersion -Path $Path
  }
  catch {
    $rejected = $true
  }
  if (-not $rejected) {
    throw "$Description was accepted by the strict module version parser."
  }
}

function Assert-ExitAndStreams {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [int] $ExitCode,
    [Parameter(Mandatory)] [string] $Description,
    [switch] $AllowStdout,
    [switch] $AllowStderr
  )

  if ($Result.ExitCode -ne $ExitCode) {
    throw "$Description must exit $ExitCode; received $($Result.ExitCode). stdout='$($Result.Stdout)' stderr='$($Result.Stderr)'"
  }
  if (-not $AllowStdout -and $Result.Stdout -cne '') {
    throw "$Description must keep stdout empty; received '$($Result.Stdout)'."
  }
  if (-not $AllowStderr -and $Result.Stderr -cne '') {
    throw "$Description must keep stderr empty; received '$($Result.Stderr)'."
  }
}

function Assert-VerificationReport {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [int] $ExitCode,
    [Parameter(Mandatory)] [string] $Outcome,
    [Parameter(Mandatory)] [string] $Description
  )

  Assert-ExitAndStreams -Result $Result -ExitCode $ExitCode -Description $Description -AllowStdout
  $report = $Result.Stdout | ConvertFrom-Json
  $expectedFields = @(
    'schemaVersion',
    'outcome',
    'artifact',
    'baseline',
    'provenance',
    'compatibility',
    'contract',
    'generator'
  )
  $actualFields = @($report.PSObject.Properties.Name)
  if (
    [String]::Join("`n", $actualFields) -cne
    [String]::Join("`n", $expectedFields)
  ) {
    throw "$Description emitted an unexpected canonical top-level field order: $($actualFields -join ', ')."
  }
  if ($report.schemaVersion -ne 1 -or $report.outcome -cne $Outcome) {
    throw "$Description emitted schemaVersion '$($report.schemaVersion)' and outcome '$($report.outcome)'."
  }
  $report
}

function Assert-ExactProcessRepeat {
  param(
    [Parameter(Mandatory)] $First,
    [Parameter(Mandatory)] $Second,
    [Parameter(Mandatory)] [string] $Description
  )

  if (
    $First.ExitCode -ne $Second.ExitCode -or
    $First.Stdout -cne $Second.Stdout -or
    $First.Stderr -cne $Second.Stderr
  ) {
    throw "$Description was not byte-for-byte stable across real process runs."
  }
}

function Invoke-Lock {
  param(
    [Parameter(Mandatory)] [string] $CliPath,
    [Parameter(Mandatory)] [string] $Artifact,
    [Parameter(Mandatory)] [string] $Output
  )

  $result = Invoke-MoonHostAbi -CliPath $CliPath -Arguments @(
    'lock', $Artifact, '--out', $Output
  )
  Assert-ExitAndStreams -Result $result -ExitCode 0 -Description "lock '$Artifact'" -AllowStdout
  if (-not (Test-Path -LiteralPath $Output -PathType Leaf)) {
    throw "Lock command did not create '$Output'."
  }
}

try {
  [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
  Assert-ExactVerificationTemp

  $moon = @(Get-Command moon -CommandType Application -ErrorAction Stop)[0].Source
  & $moon -C $repositoryRoot build cmd/moonhostabi --target native
  if ($LASTEXITCODE -ne 0) {
    throw "MoonHostABI build failed with exit code $LASTEXITCODE."
  }
  $cliCandidates = @(
    (Join-Path $repositoryRoot '_build/native/debug/build/cmd/moonhostabi/moonhostabi.exe'),
    (Join-Path $repositoryRoot '_build/native/debug/build/cmd/moonhostabi/moonhostabi')
  )
  $existingCli = @($cliCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
  if ($existingCli.Count -ne 1) {
    throw "Expected exactly one MoonHostABI executable candidate, found $($existingCli.Count)."
  }
  $cliPath = $existingCli[0]

  $moduleManifestPath = Join-Path $repositoryRoot 'moon.mod'
  $moduleVersion = Get-StrictModuleVersion -Path $moduleManifestPath
  $invalidVersionPath = Join-Path $runRoot 'invalid-version.moon.mod'
  Assert-ModuleVersionParserRejects `
    -Path $invalidVersionPath `
    -Content 'name = "missing/version"' `
    -Description 'Missing module version'
  Assert-ModuleVersionParserRejects `
    -Path $invalidVersionPath `
    -Content "version = `"$moduleVersion`"`nversion = `"$moduleVersion`"" `
    -Description 'Duplicate module version'
  Assert-ModuleVersionParserRejects `
    -Path $invalidVersionPath `
    -Content "version=`"$moduleVersion`"" `
    -Description 'Unexpected module version format'

  $committedManifestPath = Join-Path $repositoryRoot 'runtime/generated/moonhostabi.manifest.json'
  $committedManifestText = [IO.File]::ReadAllText($committedManifestPath)
  if ([regex]::Matches(
    $committedManifestText,
    '"generatorVersion":',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
  ).Count -ne 1) {
    throw 'Committed generation manifest must contain exactly one generatorVersion field.'
  }
  try {
    $committedManifest = $committedManifestText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "Committed generation manifest is invalid JSON: $($_.Exception.Message)"
  }
  if ($committedManifest.generatorVersion -cne $moduleVersion) {
    throw "Committed generator version '$($committedManifest.generatorVersion)' does not match module version '$moduleVersion'."
  }

  $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
  $timeoutObserved = $false
  try {
    $null = Invoke-MoonHostAbi `
      -CliPath $pwsh `
      -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') `
      -TimeoutMilliseconds 500
  }
  catch {
    if (-not $_.Exception.Message.StartsWith(
      'MoonHostABI process timed out after 500 ms.',
      [StringComparison]::Ordinal
    )) {
      throw
    }
    $timeoutObserved = $true
  }
  if (-not $timeoutObserved) {
    throw 'MoonHostABI process timeout/kill verification did not fire.'
  }

  $helpText = @(
    'usage:',
    '  moonhostabi inspect <artifact.wasm> --format json',
    '  moonhostabi lock <artifact.wasm> --out <lock.json>',
    '  moonhostabi check <artifact.wasm> --against <lock.json>',
    '  moonhostabi verify <artifact.wasm> --against <lock.json> [--contract <contract.json>] --format json',
    '  moonhostabi generate <artifact.wasm> --out <directory> [--update | --dry-run]',
    '  moonhostabi generate <artifact.wasm> --contract <contract.json> --out <directory>',
    '  moonhostabi --help',
    '  moonhostabi --version'
  ) -join "`n"
  $help = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @('--help')
  Assert-ExitAndStreams -Result $help -ExitCode 0 -Description '--help' -AllowStdout
  if ((Normalize-Output $help.Stdout) -cne $helpText) {
    throw '--help did not emit the exact documented command grammar.'
  }
  $version = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @('--version')
  Assert-ExitAndStreams -Result $version -ExitCode 0 -Description '--version' -AllowStdout
  if ((Normalize-Output $version.Stdout) -cne "moonhostabi $moduleVersion") {
    throw "--version emitted '$($version.Stdout)'."
  }
  $badOrder = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', 'artifact.wasm', '--format', 'json', '--against', 'baseline.json'
  )
  Assert-ExitAndStreams -Result $badOrder -ExitCode 1 -Description 'wrong-order verify' -AllowStderr
  if ((Normalize-Output $badOrder.Stderr) -cne $helpText) {
    throw 'Wrong-order verify did not emit the exact usage contract on stderr.'
  }

  $externref = Join-Path $fixtureRoot '外部引用 模块.wasm'
  $contract = Join-Path $fixtureRoot '宿主 契约.json'
  $externrefLock = Join-Path $fixtureRoot '外部引用 基线.lock.json'
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'fixtures/artifacts/externref.wasm') -Destination $externref
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'fixtures/contracts/externref.contract.json') -Destination $contract
  Invoke-Lock -CliPath $cliPath -Artifact $externref -Output $externrefLock
  $compatibleArguments = @(
    'verify', $externref, '--against', $externrefLock,
    '--contract', $contract, '--format', 'json'
  )
  $compatible = Invoke-MoonHostAbi -CliPath $cliPath -Arguments $compatibleArguments
  $compatibleRepeat = Invoke-MoonHostAbi -CliPath $cliPath -Arguments $compatibleArguments
  $compatibleReport = Assert-VerificationReport -Result $compatible -ExitCode 0 -Outcome 'compatible' -Description 'compatible contract verification'
  $null = Assert-VerificationReport -Result $compatibleRepeat -ExitCode 0 -Outcome 'compatible' -Description 'repeated compatible contract verification'
  Assert-ExactProcessRepeat -First $compatible -Second $compatibleRepeat -Description 'Compatible canonical report'
  if (
    $compatibleReport.artifact.status -cne 'valid' -or
    $compatibleReport.baseline.status -cne 'valid' -or
    $compatibleReport.provenance.artifactMatchesBaseline -ne $true -or
    $compatibleReport.provenance.abiMatchesBaseline -ne $true -or
    $compatibleReport.compatibility.classification -cne 'compatible' -or
    $compatibleReport.contract.status -cne 'valid' -or
    $compatibleReport.generator.status -cne 'representable'
  ) {
    throw 'Compatible verification did not populate all six sections consistently.'
  }

  $breakingV1 = Join-Path $fixtureRoot '破坏 基线.wasm'
  $breakingV2 = Join-Path $fixtureRoot '破坏 当前.wasm'
  $breakingLock = Join-Path $fixtureRoot '破坏 基线.lock.json'
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'fixtures/artifacts/breaking_v1.wasm') -Destination $breakingV1
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'fixtures/artifacts/breaking_v2.wasm') -Destination $breakingV2
  Invoke-Lock -CliPath $cliPath -Artifact $breakingV1 -Output $breakingLock
  $breakingArguments = @(
    'verify', $breakingV2, '--against', $breakingLock, '--format', 'json'
  )
  $breaking = Invoke-MoonHostAbi -CliPath $cliPath -Arguments $breakingArguments
  $breakingRepeat = Invoke-MoonHostAbi -CliPath $cliPath -Arguments $breakingArguments
  $breakingReport = Assert-VerificationReport -Result $breaking -ExitCode 2 -Outcome 'breaking' -Description 'breaking verification'
  $null = Assert-VerificationReport -Result $breakingRepeat -ExitCode 2 -Outcome 'breaking' -Description 'repeated breaking verification'
  Assert-ExactProcessRepeat -First $breaking -Second $breakingRepeat -Description 'Breaking canonical report'
  if (-not (@($breakingReport.compatibility.changes) | Where-Object {
    $_.code -ceq 'MHA_SIGNATURE_CHANGED' -and $_.path -ceq 'exports[add].params'
  })) {
    throw 'Breaking verification omitted the expected signature change.'
  }

  $invalidLock = Join-Path $fixtureRoot '无效 基线.lock.json'
  [IO.File]::WriteAllText($invalidLock, '{')
  $invalid = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', $breakingV1, '--against', $invalidLock, '--format', 'json'
  )
  $invalidReport = Assert-VerificationReport -Result $invalid -ExitCode 3 -Outcome 'invalid' -Description 'invalid baseline verification'
  if (
    $invalidReport.baseline.status -cne 'invalid' -or
    $invalidReport.baseline.diagnostic.code -cne 'MHA_LOCKFILE_INVALID'
  ) {
    throw 'Readable invalid baseline was not represented in the canonical report.'
  }

  $unknown = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', (Join-Path $repositoryRoot 'fixtures/artifacts/recursive.wasm'),
    '--against', $breakingLock, '--format', 'json'
  )
  $unknownReport = Assert-VerificationReport -Result $unknown -ExitCode 3 -Outcome 'unknown' -Description 'unsupported artifact verification'
  if (-not (@($unknownReport.artifact.diagnostics) | Where-Object {
    $_.code -ceq 'MHA_PROJECT_UNREPRESENTABLE'
  })) {
    throw 'Unsupported artifact verification omitted its projection diagnostic.'
  }

  $adapterMismatchArtifact = Join-Path $fixtureRoot '适配器 不匹配.wasm'
  $adapterMismatchLock = Join-Path $fixtureRoot '适配器 不匹配.lock.json'
  [IO.File]::WriteAllBytes(
    $adapterMismatchArtifact,
    [Convert]::FromBase64String('AGFzbQEAAAABBgFgAX8BfwIcAQttb29uYml0OmZmaQxtYWtlX2Nsb3N1cmUAAA==')
  )
  Invoke-Lock -CliPath $cliPath -Artifact $adapterMismatchArtifact -Output $adapterMismatchLock
  $adapterMismatch = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', $adapterMismatchArtifact, '--against', $adapterMismatchLock,
    '--format', 'json'
  )
  $adapterReport = Assert-VerificationReport -Result $adapterMismatch -ExitCode 4 -Outcome 'adapterMismatch' -Description 'adapter mismatch verification'
  if (
    $adapterReport.contract.status -cne 'notProvided' -or
    $adapterReport.generator.status -cne 'unrepresentable' -or
    $adapterReport.generator.diagnostics[0].code -cne 'MHA_ADAPTER_MISMATCH'
  ) {
    throw 'Adapter mismatch verification did not report the generator boundary.'
  }

  $scalar = Join-Path $fixtureRoot '相同 ABI 原件.wasm'
  $sameAbi = Join-Path $fixtureRoot '相同 ABI 不同字节.wasm'
  $scalarLock = Join-Path $fixtureRoot '相同 ABI 基线.lock.json'
  Copy-Item -LiteralPath (Join-Path $repositoryRoot 'fixtures/artifacts/scalar.wasm') -Destination $scalar
  $scalarBytes = [IO.File]::ReadAllBytes($scalar)
  [IO.File]::WriteAllBytes($sameAbi, [byte[]]($scalarBytes + [byte[]](0, 1, 0)))
  Invoke-Lock -CliPath $cliPath -Artifact $scalar -Output $scalarLock
  $sameAbiResult = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', $sameAbi, '--against', $scalarLock, '--format', 'json'
  )
  $sameAbiReport = Assert-VerificationReport -Result $sameAbiResult -ExitCode 0 -Outcome 'compatible' -Description 'same ABI different artifact verification'
  if (
    $sameAbiReport.provenance.artifactMatchesBaseline -ne $false -or
    $sameAbiReport.provenance.abiMatchesBaseline -ne $true
  ) {
    throw 'Same-ABI verification conflated artifact provenance with semantic compatibility.'
  }

  $trapArtifact = Join-Path $fixtureRoot '启动即陷阱 但不执行.wasm'
  $trapLock = Join-Path $fixtureRoot '启动即陷阱 基线.lock.json'
  [IO.File]::WriteAllBytes(
    $trapArtifact,
    [Convert]::FromBase64String('AGFzbQEAAAABBAFgAAADAgEACAEACgUBAwAACw==')
  )
  Invoke-Lock -CliPath $cliPath -Artifact $trapArtifact -Output $trapLock
  $trapResult = Invoke-MoonHostAbi -CliPath $cliPath -Arguments @(
    'verify', $trapArtifact, '--against', $trapLock, '--format', 'json'
  )
  $null = Assert-VerificationReport -Result $trapResult -ExitCode 0 -Outcome 'compatible' -Description 'non-executing trap artifact verification'

  Write-Output 'MOONHOSTABI_VERIFY_HELP_VERSION=GO'
  Write-Output 'MOONHOSTABI_VERIFY_VERSION_SOURCE=GO'
  Write-Output 'MOONHOSTABI_VERIFY_TIMEOUT_KILL=GO'
  Write-Output 'MOONHOSTABI_VERIFY_EXIT_CODES=0,2,3,4'
  Write-Output 'MOONHOSTABI_VERIFY_CANONICAL_REPORT=GO'
  Write-Output 'MOONHOSTABI_VERIFY_UNICODE_SPACE_PATH=GO'
  Write-Output 'MOONHOSTABI_VERIFY_NO_HOST_EXECUTION=GO'
  Write-Output 'MOONHOSTABI_VERIFY_STATUS=GO'
}
finally {
  $processCleanupErrors = [Collections.Generic.List[string]]::new()
  foreach ($process in $runningProcesses) {
    try {
      if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
      }
    }
    catch {
      [void]$processCleanupErrors.Add($_.Exception.Message)
    }
    finally {
      $process.Dispose()
    }
  }
  if (Test-Path -LiteralPath $runRoot) {
    Assert-ExactVerificationTemp
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  }
  if ($processCleanupErrors.Count -ne 0) {
    throw "Failed to terminate verification process trees: $($processCleanupErrors -join '; ')"
  }
}
