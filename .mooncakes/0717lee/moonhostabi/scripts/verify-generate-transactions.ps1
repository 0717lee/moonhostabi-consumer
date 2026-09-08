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
$runLeaf = 'moonhostabi-txn-' + [Guid]::NewGuid().ToString('N')
$runRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $runLeaf))
$outputLeaf = 'concurrent-output'
$outputRoot = Join-Path $runRoot $outputLeaf
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}

function Assert-ExactTransactionTemp {
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
    $script:runLeaf -notmatch '^moonhostabi-txn-[0-9a-f]{32}$'
  ) {
    throw "Refusing to remove unexpected transaction path '$normalizedPath'."
  }
}

function Start-CliProcess {
  param(
    [Parameter(Mandatory)] [string] $CliPath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [string] $Fault
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $CliPath
  $startInfo.WorkingDirectory = $script:repositoryRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  if ([String]::IsNullOrWhiteSpace($Fault)) {
    [void]$startInfo.Environment.Remove('MOONHOSTABI_INTERNAL_TEST_ONLY_FAULT')
  } else {
    $startInfo.Environment['MOONHOSTABI_INTERNAL_TEST_ONLY_FAULT'] = $Fault
  }
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    $started = $process.Start()
  }
  catch {
    $process.Dispose()
    throw
  }
  if (-not $started) {
    $process.Dispose()
    throw 'Failed to start MoonHostABI transaction verifier process.'
  }
  [void]$script:runningProcesses.Add($process)
  [pscustomobject]@{
    Process = $process
    Stdout = $process.StandardOutput.ReadToEndAsync()
    Stderr = $process.StandardError.ReadToEndAsync()
  }
}

function Complete-CliProcess {
  param(
    [Parameter(Mandatory)] $Running,
    [int] $TimeoutMilliseconds = 45000
  )

  if (-not $Running.Process.WaitForExit($TimeoutMilliseconds)) {
    $Running.Process.Kill($true)
    $Running.Process.WaitForExit()
    $timedOutStdout = $Running.Stdout.GetAwaiter().GetResult()
    $timedOutStderr = $Running.Stderr.GetAwaiter().GetResult()
    throw "MoonHostABI process timed out after $TimeoutMilliseconds ms. stdout='$timedOutStdout' stderr='$timedOutStderr'"
  }
  $Running.Process.WaitForExit()
  [pscustomobject]@{
    ExitCode = $Running.Process.ExitCode
    Stdout = $Running.Stdout.GetAwaiter().GetResult()
    Stderr = $Running.Stderr.GetAwaiter().GetResult()
  }
}

function Assert-FailureResult {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string[]] $ExpectedCodes,
    [Parameter(Mandatory)] [string] $Description
  )

  if ($Result.ExitCode -ne 3) {
    throw "$Description must exit 3; received $($Result.ExitCode)."
  }
  if ($Result.Stdout -cne '') {
    throw "$Description must keep stdout strictly empty; received '$($Result.Stdout)'."
  }
  $failure = $Result.Stderr | ConvertFrom-Json
  if ($ExpectedCodes -cnotcontains $failure.code) {
    throw "$Description reported unexpected code '$($failure.code)'; expected $($ExpectedCodes -join ', ')."
  }
  $failure
}

function Assert-SuccessResult {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string] $ExpectedAbiSha256,
    [Parameter(Mandatory)] [string[]] $ExpectedFiles,
    [Parameter(Mandatory)] [string] $Description
  )

  if ($Result.ExitCode -ne 0) {
    throw "$Description must exit 0; received $($Result.ExitCode), stderr='$($Result.Stderr)'."
  }
  if ($Result.Stderr -cne '') {
    throw "$Description must keep stderr strictly empty; received '$($Result.Stderr)'."
  }
  $success = $Result.Stdout | ConvertFrom-Json
  if ($success.abiSha256 -cne $ExpectedAbiSha256) {
    throw "$Description reported unexpected ABI SHA-256 '$($success.abiSha256)'."
  }
  if (
    [String]::Join([Environment]::NewLine, @($success.files)) -cne
    [String]::Join([Environment]::NewLine, $ExpectedFiles)
  ) {
    throw "$Description reported an unexpected output file list: $(@($success.files) -join ', ')."
  }
}

function Get-TransactionResiduals {
  param([Parameter(Mandatory)] [string] $OutputLeaf)

  @(
    Get-ChildItem -LiteralPath $script:runRoot -Force |
      Where-Object {
        $_.Name.StartsWith(
          "$OutputLeaf.moonhostabi-stage-",
          [StringComparison]::Ordinal
        ) -or $_.Name.StartsWith(
          "$OutputLeaf.moonhostabi-backup-",
          [StringComparison]::Ordinal
        )
      }
  )
}

function Get-GenerationFingerprint {
  param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string[]] $Names
  )

  @(
    foreach ($name in $Names) {
      $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Directory $name)).Hash
      "$name=$($hash.ToLowerInvariant())"
    }
  )
}

function Assert-FingerprintEqual {
  param(
    [Parameter(Mandatory)] [string[]] $Expected,
    [Parameter(Mandatory)] [string[]] $Actual,
    [Parameter(Mandatory)] [string] $Description
  )

  if (
    [String]::Join([Environment]::NewLine, $Expected) -cne
    [String]::Join([Environment]::NewLine, $Actual)
  ) {
    throw "$Description changed the prior complete output."
  }
}

function Assert-CompleteGeneration {
  param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string[]] $ExpectedFiles
  )

  $actualFiles = @(
    Get-ChildItem -LiteralPath $Directory -Force |
      Sort-Object Name |
      ForEach-Object Name
  )
  if (
    [String]::Join([Environment]::NewLine, $actualFiles) -cne
    [String]::Join([Environment]::NewLine, $ExpectedFiles)
  ) {
    throw "Published output has an unexpected file set: $($actualFiles -join ', ')."
  }
  $manifestPath = Join-Path $Directory 'moonhostabi.manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if (
    $manifest.schemaVersion -ne 1 -or
    [String]::IsNullOrWhiteSpace($manifest.generatorVersion) -or
    [String]::IsNullOrWhiteSpace($manifest.abiSha256) -or
    [String]::IsNullOrWhiteSpace($manifest.files.'adapter.ts') -or
    [String]::IsNullOrWhiteSpace($manifest.files.'moonhostabi.contract.json')
  ) {
    throw 'Published generation manifest is incomplete.'
  }
  $adapterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Directory 'adapter.ts')).Hash.ToLowerInvariant()
  $contractHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Directory 'moonhostabi.contract.json')).Hash.ToLowerInvariant()
  if (
    $manifest.files.'adapter.ts' -cne $adapterHash -or
    $manifest.files.'moonhostabi.contract.json' -cne $contractHash -or
    $manifest.contractSha256 -cne $contractHash
  ) {
    throw 'Published generation manifest hashes do not match output bytes.'
  }
  $manifest
}

function Remove-DirectoryLink {
  param([Parameter(Mandatory)] [string] $Path)

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -ne $item) {
    Remove-Item -LiteralPath $Path -Force
  }
  if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
    throw "Failed to remove directory link '$Path' without traversing it."
  }
}

[IO.Directory]::CreateDirectory($runRoot) | Out-Null
Assert-ExactTransactionTemp

try {
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
  if ($existingCli.Count -ne 1) { throw "Expected exactly one MoonHostABI executable candidate, found $($existingCli.Count)." }
  $cliPath = $existingCli[0]

  $artifact = Join-Path $repositoryRoot 'fixtures/artifacts/externref.wasm'
  $contract = Join-Path $repositoryRoot 'fixtures/contracts/externref.contract.json'
  $expectedFiles = @(
    'adapter.ts',
    'moonhostabi.contract.json',
    'moonhostabi.manifest.json'
  )
  $freshArguments = @(
    'generate', $artifact, '--contract', $contract, '--out', $outputRoot
  )
  $first = Start-CliProcess -CliPath $cliPath -Arguments $freshArguments
  $second = Start-CliProcess -CliPath $cliPath -Arguments $freshArguments
  $results = @(
    (Complete-CliProcess -Running $first),
    (Complete-CliProcess -Running $second)
  )
  $exitCodes = @($results.ExitCode | Sort-Object)
  if ($exitCodes.Count -ne 2 -or $exitCodes[0] -ne 0 -or $exitCodes[1] -ne 3) {
    throw "Concurrent generate exit codes must be 0 and 3; received $($exitCodes -join ', ')."
  }
  $loser = @($results | Where-Object ExitCode -eq 3)
  if ($loser.Count -ne 1) {
    throw 'Expected exactly one losing concurrent writer.'
  }
  $winner = @($results | Where-Object ExitCode -eq 0)
  if ($winner.Count -ne 1) {
    throw 'Expected exactly one successful concurrent writer.'
  }
  $manifest = Assert-CompleteGeneration -Directory $outputRoot -ExpectedFiles $expectedFiles
  Assert-SuccessResult -Result $winner[0] -ExpectedAbiSha256 $manifest.abiSha256 -ExpectedFiles $expectedFiles -Description 'Successful concurrent fresh writer'
  $null = Assert-FailureResult -Result $loser[0] -ExpectedCodes @('MHA_OUTPUT_EXISTS') -Description 'Losing concurrent fresh writer'
  $freshResiduals = @(Get-TransactionResiduals -OutputLeaf $outputLeaf)
  if ($freshResiduals.Count -ne 0) {
    throw "Concurrent fresh retained unexpected transaction paths: $($freshResiduals.Name -join ', ')."
  }

  $beforeFaults = Get-GenerationFingerprint -Directory $outputRoot -Names $expectedFiles
  $updateArguments = @(
    'generate', $artifact, '--out', $outputRoot, '--update'
  )
  $firstUpdate = Start-CliProcess -CliPath $cliPath -Arguments $updateArguments
  $secondUpdate = Start-CliProcess -CliPath $cliPath -Arguments $updateArguments
  $updateResults = @(
    (Complete-CliProcess -Running $firstUpdate),
    (Complete-CliProcess -Running $secondUpdate)
  )
  $successfulUpdates = @($updateResults | Where-Object ExitCode -eq 0)
  if ($successfulUpdates.Count -lt 1) {
    throw "Concurrent update requires at least one successful writer; received $($updateResults.ExitCode -join ', ')."
  }
  foreach ($success in $successfulUpdates) {
    Assert-SuccessResult -Result $success -ExpectedAbiSha256 $manifest.abiSha256 -ExpectedFiles $expectedFiles -Description 'Successful concurrent update writer'
  }
  foreach ($failed in @($updateResults | Where-Object ExitCode -ne 0)) {
    $null = Assert-FailureResult -Result $failed -ExpectedCodes @('MHA_OUTPUT_IO', 'MHA_OUTPUT_UNOWNED', 'MHA_OUTPUT_EXISTS') -Description 'Losing concurrent update writer'
  }
  $null = Assert-CompleteGeneration -Directory $outputRoot -ExpectedFiles $expectedFiles
  Assert-FingerprintEqual -Expected $beforeFaults -Actual (Get-GenerationFingerprint -Directory $outputRoot -Names $expectedFiles) -Description 'Concurrent update'
  $updateResiduals = @(Get-TransactionResiduals -OutputLeaf $outputLeaf)
  if ($updateResiduals.Count -ne 0) {
    throw "Concurrent update retained unexpected transaction paths: $($updateResiduals.Name -join ', ')."
  }

  foreach ($fault in @('second-write', 'after-backup')) {
    $faultRun = Start-CliProcess -CliPath $cliPath -Arguments $updateArguments -Fault $fault
    $faultResult = Complete-CliProcess -Running $faultRun
    $null = Assert-FailureResult -Result $faultResult -ExpectedCodes @('MHA_OUTPUT_IO') -Description "Fault '$fault'"
    $afterFault = Get-GenerationFingerprint -Directory $outputRoot -Names $expectedFiles
    Assert-FingerprintEqual -Expected $beforeFaults -Actual $afterFault -Description "Fault '$fault'"
    $faultResiduals = @(Get-TransactionResiduals -OutputLeaf $outputLeaf)
    if ($faultResiduals.Count -ne 0) {
      throw "Fault '$fault' retained unexpected transaction paths: $($faultResiduals.Name -join ', ')."
    }
  }

  $externalLeaf = 'external-owned-output'
  $externalOutput = Join-Path $runRoot $externalLeaf
  $externalArguments = @(
    'generate', $artifact, '--contract', $contract, '--out', $externalOutput
  )
  $externalResult = Complete-CliProcess -Running (Start-CliProcess -CliPath $cliPath -Arguments $externalArguments)
  Assert-SuccessResult -Result $externalResult -ExpectedAbiSha256 $manifest.abiSha256 -ExpectedFiles $expectedFiles -Description 'External link target setup'
  $externalBefore = Get-GenerationFingerprint -Directory $externalOutput -Names $expectedFiles
  $linkedLeaf = 'linked-output'
  $linkedOutput = Join-Path $runRoot $linkedLeaf
  $linkCreated = $false
  try {
    if ($IsWindows) {
      $null = New-Item -ItemType Junction -Path $linkedOutput -Target $externalOutput
    } else {
      $null = New-Item -ItemType SymbolicLink -Path $linkedOutput -Target $externalOutput
    }
    $linkCreated = $true
    $linkedArguments = @(
      'generate', $artifact, '--out', $linkedOutput, '--update'
    )
    $linkedResult = Complete-CliProcess -Running (Start-CliProcess -CliPath $cliPath -Arguments $linkedArguments)
    $null = Assert-FailureResult -Result $linkedResult -ExpectedCodes @('MHA_OUTPUT_UNOWNED') -Description 'Directory-link update'
    $linkedItemAfter = Get-Item -LiteralPath $linkedOutput -Force
    if (-not ($linkedItemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Directory-link update committed a new output over the link path.'
    }
    Assert-FingerprintEqual -Expected $externalBefore -Actual (Get-GenerationFingerprint -Directory $externalOutput -Names $expectedFiles) -Description 'Directory-link update'
    $linkedResiduals = @(Get-TransactionResiduals -OutputLeaf $linkedLeaf)
    if ($linkedResiduals.Count -ne 0) {
      throw "Directory-link update retained unexpected transaction paths: $($linkedResiduals.Name -join ', ')."
    }
  }
  finally {
    if ($linkCreated) {
      $linkItem = Get-Item -LiteralPath $linkedOutput -Force -ErrorAction SilentlyContinue
      if ($null -ne $linkItem -and ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-DirectoryLink -Path $linkedOutput
      }
    }
  }

  $danglingTarget = Join-Path $runRoot 'dangling-target'
  $danglingLeaf = 'dangling-link-output'
  $danglingOutput = Join-Path $runRoot $danglingLeaf
  $danglingCreated = $false
  try {
    if ($IsWindows) {
      try {
        $null = New-Item -ItemType SymbolicLink -Path $danglingOutput -Target $danglingTarget
      }
      catch {
        [IO.Directory]::CreateDirectory($danglingTarget) | Out-Null
        $null = New-Item -ItemType Junction -Path $danglingOutput -Target $danglingTarget
        [IO.Directory]::Delete($danglingTarget)
        Write-Warning 'Directory symlink creation was unavailable; exercised a dangling junction instead.'
      }
    } else {
      $null = New-Item -ItemType SymbolicLink -Path $danglingOutput -Target $danglingTarget
    }
    $danglingCreated = $true
    $danglingArguments = @(
      'generate', $artifact, '--contract', $contract, '--out', $danglingOutput
    )
    $danglingResult = Complete-CliProcess -Running (Start-CliProcess -CliPath $cliPath -Arguments $danglingArguments)
    $null = Assert-FailureResult -Result $danglingResult -ExpectedCodes @('MHA_OUTPUT_EXISTS') -Description 'Dangling directory-link fresh generation'
    $danglingItem = Get-Item -LiteralPath $danglingOutput -Force
    if (-not ($danglingItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Fresh generation replaced a dangling directory link.'
    }
    $danglingResiduals = @(Get-TransactionResiduals -OutputLeaf $danglingLeaf)
    if ($danglingResiduals.Count -ne 0) {
      throw "Dangling directory-link generation retained unexpected transaction paths: $($danglingResiduals.Name -join ', ')."
    }
  }
  finally {
    if ($danglingCreated) {
      Remove-DirectoryLink -Path $danglingOutput
    }
  }

  $replacementRun = Start-CliProcess -CliPath $cliPath -Arguments $updateArguments -Fault 'replace-before-claim'
  $replacementResult = Complete-CliProcess -Running $replacementRun
  $null = Assert-FailureResult -Result $replacementResult -ExpectedCodes @('MHA_OUTPUT_UNOWNED') -Description 'Post-validation replacement fault'
  $replacementFingerprint = Get-GenerationFingerprint -Directory $outputRoot -Names $expectedFiles
  if (
    $replacementFingerprint[0] -ceq $beforeFaults[0] -or
    $replacementFingerprint[1] -cne $beforeFaults[1] -or
    $replacementFingerprint[2] -ceq $beforeFaults[2]
  ) {
    throw 'Post-validation replacement bytes were not restored as one complete claimed snapshot.'
  }
  $null = Assert-CompleteGeneration -Directory $outputRoot -ExpectedFiles $expectedFiles
  $replacementResiduals = @(Get-TransactionResiduals -OutputLeaf $outputLeaf)
  if ($replacementResiduals.Count -ne 0) {
    throw "Post-validation replacement retained unexpected transaction paths: $($replacementResiduals.Name -join ', ')."
  }
  $recoveryRun = Start-CliProcess -CliPath $cliPath -Arguments $updateArguments
  $recoveryResult = Complete-CliProcess -Running $recoveryRun
  Assert-SuccessResult -Result $recoveryResult -ExpectedAbiSha256 $manifest.abiSha256 -ExpectedFiles $expectedFiles -Description 'Replacement recovery update'
  Assert-FingerprintEqual -Expected $beforeFaults -Actual (Get-GenerationFingerprint -Directory $outputRoot -Names $expectedFiles) -Description 'Replacement recovery update'

  $retainedLeaf = 'retained-output'
  $retainedOutput = Join-Path $runRoot $retainedLeaf
  $retainedArguments = @(
    'generate', $artifact, '--contract', $contract, '--out', $retainedOutput
  )
  $retainedRun = Start-CliProcess -CliPath $cliPath -Arguments $retainedArguments -Fault 'retain-staging'
  $retainedResult = Complete-CliProcess -Running $retainedRun
  if (Test-Path -LiteralPath $retainedOutput) {
    throw 'Retained-staging fault must fail before publishing the target.'
  }
  $retainedFailure = Assert-FailureResult -Result $retainedResult -ExpectedCodes @('MHA_OUTPUT_IO') -Description 'Retained-staging fault'
  if (
    $retainedFailure.message -notmatch 'retained staging path: (?<path>.+)$'
  ) {
    throw 'Retained-staging fault did not report its retained path.'
  }
  $reportedPath = [IO.Path]::GetFullPath($Matches.path)
  $retainedResiduals = @(Get-TransactionResiduals -OutputLeaf $retainedLeaf)
  if (
    $retainedResiduals.Count -ne 1 -or
    -not $retainedResiduals[0].Name.StartsWith(
      "$retainedLeaf.moonhostabi-stage-",
      [StringComparison]::Ordinal
    ) -or
    [IO.Path]::GetFullPath($retainedResiduals[0].FullName) -cne $reportedPath -or
    -not (Test-Path -LiteralPath (Join-Path $reportedPath 'interruption.marker') -PathType Leaf)
  ) {
    throw 'Reported staging path does not match the safely retained directory.'
  }
  Write-Output 'MOONHOSTABI_TRANSACTION_STATUS=GO'
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
    Assert-ExactTransactionTemp
    Remove-Item -LiteralPath $runRoot -Recurse -Force
  }
  if ($processCleanupErrors.Count -ne 0) {
    throw "Failed to terminate transaction verifier process trees: $($processCleanupErrors -join '; ')"
  }
}
