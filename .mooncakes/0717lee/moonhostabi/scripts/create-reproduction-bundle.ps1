[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Artifact,
  [string] $Contract,
  [Parameter(Mandatory)] [string] $Out,
  [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

if ([String]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$hostTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$correlationToken = [Environment]::GetEnvironmentVariable(
  'MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_TOKEN'
)
if (
  -not [String]::IsNullOrEmpty($correlationToken) -and
  $correlationToken -cnotmatch '^[0-9a-f]{32}$'
) {
  throw 'Internal bundle correlation token must be exactly 32 lowercase hex characters.'
}
$workRunToken = [Guid]::NewGuid().ToString('N')
$workLeaf = if ([String]::IsNullOrEmpty($correlationToken)) {
  'moonhostabi-repro-work-' + $workRunToken
} else {
  'moonhostabi-repro-work-' + $correlationToken + '-' + $workRunToken
}
$workRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $workLeaf))
$outputPath = [IO.Path]::GetFullPath($Out)
$outputParent = [IO.Path]::GetDirectoryName($outputPath)
$outputParentIdentity = $null
$stageLeaf = '.moonhostabi-bundle-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp'
$stagePath = [IO.Path]::GetFullPath((Join-Path $outputParent $stageLeaf))
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$utf8NoBom = [Text.UTF8Encoding]::new($false, $true)

function Test-IsLinkOrReparsePoint {
  param([Parameter(Mandatory)] $Item)

  $linkProperty = $Item.PSObject.Properties['LinkType']
  $linkType = if ($null -eq $linkProperty) { $null } else { $linkProperty.Value }
  ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not [String]::IsNullOrEmpty([string]$linkType)
}

function Assert-UnlinkedPathChain {
  param(
    [Parameter(Mandatory)] [string] $FullPath,
    [Parameter(Mandatory)] [string] $Description
  )

  $cursor = [IO.Path]::GetFullPath($FullPath)
  while (-not [String]::IsNullOrEmpty($cursor)) {
    $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (Test-IsLinkOrReparsePoint -Item $item) {
      throw "$Description traverses a reparse point or symbolic link at '$cursor'."
    }
    $trimmed = $cursor.TrimEnd(
      [IO.Path]::DirectorySeparatorChar,
      [IO.Path]::AltDirectorySeparatorChar
    )
    if ([String]::IsNullOrEmpty($trimmed)) {
      break
    }
    $parent = [IO.Path]::GetDirectoryName($trimmed)
    if (
      [String]::IsNullOrEmpty($parent) -or
      [String]::Equals($parent, $cursor, $script:pathComparison)
    ) {
      break
    }
    $cursor = $parent
  }
}

function Get-StrictInputSnapshot {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Description
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if ($item.PSIsContainer) {
    throw "$Description must be a regular file: '$fullPath'."
  }
  Assert-UnlinkedPathChain -FullPath $fullPath -Description $Description
  $input = [IO.File]::Open(
    $fullPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $memory = [IO.MemoryStream]::new()
  try {
    $input.CopyTo($memory)
    Assert-UnlinkedPathChain -FullPath $fullPath -Description $Description
    [pscustomobject]@{
      Bytes = $memory.ToArray()
    }
  }
  finally {
    $memory.Dispose()
    $input.Dispose()
  }
}

function Get-StrictOutputParent {
  param([Parameter(Mandatory)] [string] $Path)

  if ([String]::IsNullOrEmpty($Path)) {
    throw 'Output archive must have a parent directory.'
  }
  $fullPath = [IO.Path]::GetFullPath($Path)
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer) {
    throw "Output parent must be a directory: '$fullPath'."
  }
  Assert-UnlinkedPathChain -FullPath $fullPath -Description 'Output parent'
  $fullPath
}

function Assert-OutputParentIdentity {
  $rechecked = Get-StrictOutputParent -Path $script:outputParent
  $resolved = (Resolve-Path -LiteralPath $rechecked).ProviderPath
  if (
    -not [String]::Equals(
      $rechecked,
      $script:outputParent,
      $script:pathComparison
    ) -or
    [String]::IsNullOrEmpty($script:outputParentIdentity) -or
    -not [String]::Equals(
      [IO.Path]::GetFullPath($resolved),
      [IO.Path]::GetFullPath($script:outputParentIdentity),
      $script:pathComparison
    )
  ) {
    throw 'Output parent identity changed during bundle creation.'
  }
}

function Assert-OutputAbsent {
  param(
    [Parameter(Mandatory)] [string] $Parent,
    [Parameter(Mandatory)] [string] $Leaf
  )

  $matches = @(
    Get-ChildItem -LiteralPath $Parent -Force |
      Where-Object {
        [String]::Equals($_.Name, $Leaf, $script:pathComparison)
      }
  )
  if ($matches.Count -ne 0) {
    throw "Output archive already exists; refusing to overwrite '$outputPath'."
  }
}

function Assert-ExactWorkRoot {
  $item = Get-Item -LiteralPath $script:workRoot -Force
  if (Test-IsLinkOrReparsePoint -Item $item) {
    throw 'Refusing to remove a linked reproduction work directory.'
  }
  $resolvedPath = (Resolve-Path -LiteralPath $script:workRoot).ProviderPath
  $resolvedParent = (Resolve-Path -LiteralPath $script:hostTempRoot).ProviderPath
  $normalizedPath = [IO.Path]::GetFullPath($resolvedPath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $normalizedParent = [IO.Path]::GetFullPath($resolvedParent).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $prefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar
  $normalLeaf = [String]::IsNullOrEmpty($script:correlationToken) -and
    $script:workLeaf -cmatch '^moonhostabi-repro-work-[0-9a-f]{32}$'
  $correlatedLeaf = -not [String]::IsNullOrEmpty($script:correlationToken) -and
    $script:workLeaf -cmatch (
      '^moonhostabi-repro-work-' +
      [regex]::Escape($script:correlationToken) +
      '-[0-9a-f]{32}$'
    )
  if (
    -not $normalizedPath.StartsWith($prefix, $script:pathComparison) -or
    [IO.Path]::GetFileName($normalizedPath) -cne $script:workLeaf -or
    -not ($normalLeaf -or $correlatedLeaf)
  ) {
    throw "Refusing to remove unexpected work path '$normalizedPath'."
  }
}

function Assert-ExactStagePath {
  $normalizedStage = [IO.Path]::GetFullPath($script:stagePath)
  $normalizedParent = [IO.Path]::GetFullPath($script:outputParent)
  if (
    -not [String]::Equals(
      [IO.Path]::GetDirectoryName($normalizedStage),
      $normalizedParent,
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($normalizedStage) -cne $script:stageLeaf -or
    $script:stageLeaf -notmatch '^\.moonhostabi-bundle-stage-[0-9a-f]{32}\.tmp$'
  ) {
    throw "Refusing to remove unexpected archive staging path '$normalizedStage'."
  }
  $item = Get-Item -LiteralPath $normalizedStage -Force -ErrorAction SilentlyContinue
  if ($null -ne $item -and (Test-IsLinkOrReparsePoint -Item $item)) {
    throw 'Refusing to remove a linked archive staging path.'
  }
  if ($null -ne $item) {
    $resolvedStage = (Resolve-Path -LiteralPath $normalizedStage).ProviderPath
    if (
      [String]::IsNullOrEmpty($script:outputParentIdentity) -or
      -not [String]::Equals(
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($resolvedStage)),
        [IO.Path]::GetFullPath($script:outputParentIdentity),
        $script:pathComparison
      )
    ) {
      throw 'Archive staging file resolved outside the validated output parent.'
    }
  }
}

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory)] [string] $FilePath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [int] $TimeoutMilliseconds = 120000
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.WorkingDirectory = $script:repositoryRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  foreach ($argument in $Arguments) {
    $startInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) {
      throw "Failed to start '$FilePath'."
    }
    [void]$script:runningProcesses.Add($process)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Process timed out after $TimeoutMilliseconds ms. stdout='$($stdout.GetAwaiter().GetResult())' stderr='$($stderr.GetAwaiter().GetResult())'"
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

function Assert-ProcessSuccess {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string] $Description,
    [switch] $RequireEmptyStderr
  )

  if ($Result.ExitCode -ne 0) {
    throw "$Description failed with exit $($Result.ExitCode). stdout='$($Result.Stdout)' stderr='$($Result.Stderr)'"
  }
  if ($RequireEmptyStderr -and $Result.Stderr -cne '') {
    throw "$Description wrote unexpected stderr '$($Result.Stderr)'."
  }
}

function Get-UniqueCapturedVersion {
  param(
    [Parameter(Mandatory)] [string] $Text,
    [Parameter(Mandatory)] [string] $Pattern,
    [Parameter(Mandatory)] [string] $Description
  )

  $matches = [regex]::Matches(
    $Text,
    $Pattern,
    [Text.RegularExpressions.RegexOptions]::Multiline -bor
      [Text.RegularExpressions.RegexOptions]::CultureInvariant
  )
  if ($matches.Count -ne 1) {
    throw "$Description version output was missing, duplicated, or malformed."
  }
  $matches[0].Groups[1].Value
}

function Write-Utf8Text {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
  )

  if ($Text.Contains("`r")) {
    throw "Refusing to write non-LF text to '$Path'."
  }
  [IO.File]::WriteAllText($Path, $Text, $script:utf8NoBom)
}

function Copy-ExactFile {
  param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Destination
  )

  [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source))
}

function Get-Sha256 {
  param([Parameter(Mandatory)] [string] $Path)

  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

  ConvertTo-Json -InputObject $Value -Compress
}

function New-BundleManifest {
  param(
    [Parameter(Mandatory)] [string] $ContentRoot,
    [Parameter(Mandatory)] [string] $MoonHostAbiVersion,
    [Parameter(Mandatory)] [string] $MoonVersion,
    [Parameter(Mandatory)] [string] $MooncVersion,
    [Parameter(Mandatory)] [string] $MoonrunVersion
  )

  $payloadPaths = @(
    'validation.json',
    'host-abi.lock.json',
    'moonhostabi.contract.json',
    'adapter.ts',
    'artifact.wasm',
    'commands.txt'
  )
  $records = @(
    foreach ($relativePath in $payloadPaths) {
      $path = Join-Path $ContentRoot $relativePath
      $sha256 = Get-Sha256 -Path $path
      $size = (Get-Item -LiteralPath $path).Length
      $sizeText = $size.ToString([Globalization.CultureInfo]::InvariantCulture)
      '{"path":' + (ConvertTo-JsonString $relativePath) +
        ',"sha256":' + (ConvertTo-JsonString $sha256) +
        ',"size":' + $sizeText + '}'
    }
  )
  '{"schemaVersion":1,"moonHostAbiVersion":' +
    (ConvertTo-JsonString $MoonHostAbiVersion) +
    ',"toolVersions":{"moon":' +
    (ConvertTo-JsonString $MoonVersion) +
    ',"moonc":' +
    (ConvertTo-JsonString $MooncVersion) +
    ',"moonrun":' +
    (ConvertTo-JsonString $MoonrunVersion) +
    ',"powershell":' +
    (ConvertTo-JsonString $PSVersionTable.PSVersion.ToString()) +
    ',"dotnetRuntime":' +
    (ConvertTo-JsonString ([Environment]::Version.ToString())) +
    '},"files":[' +
    ($records -join ',') +
    ']}' +
    "`n"
}

function Write-DeterministicArchive {
  param(
    [Parameter(Mandatory)] [string] $ContentRoot,
    [Parameter(Mandatory)] [string] $ArchivePath
  )

  $entrySources = [ordered]@{
    'moonhostabi-reproduction/manifest.json' = Join-Path $ContentRoot 'manifest.json'
    'moonhostabi-reproduction/validation.json' = Join-Path $ContentRoot 'validation.json'
    'moonhostabi-reproduction/host-abi.lock.json' = Join-Path $ContentRoot 'host-abi.lock.json'
    'moonhostabi-reproduction/moonhostabi.contract.json' = Join-Path $ContentRoot 'moonhostabi.contract.json'
    'moonhostabi-reproduction/adapter.ts' = Join-Path $ContentRoot 'adapter.ts'
    'moonhostabi-reproduction/artifact.wasm' = Join-Path $ContentRoot 'artifact.wasm'
    'moonhostabi-reproduction/commands.txt' = Join-Path $ContentRoot 'commands.txt'
  }
  $stream = [IO.File]::Open(
    $ArchivePath,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,
    [IO.FileShare]::None
  )
  $archive = $null
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Create,
      $false,
      [Text.UTF8Encoding]::new($false, $true)
    )
    $timestamp = [DateTimeOffset]::new(
      1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero
    )
    foreach ($entryName in $entrySources.Keys) {
      $entry = $archive.CreateEntry(
        $entryName,
        [IO.Compression.CompressionLevel]::NoCompression
      )
      $entry.LastWriteTime = $timestamp
      $entry.ExternalAttributes = 0
      $input = [IO.File]::OpenRead($entrySources[$entryName])
      $output = $entry.Open()
      try {
        $input.CopyTo($output)
      }
      finally {
        $output.Dispose()
        $input.Dispose()
      }
    }
  }
  finally {
    if ($null -ne $archive) {
      $archive.Dispose()
    }
    $stream.Dispose()
  }
}

$artifactInput = $null
$contractInput = $null
$contractPath = $null
try {
  if (-not [String]::Equals(
    [IO.Path]::GetExtension($outputPath),
    '.zip',
    [StringComparison]::OrdinalIgnoreCase
  )) {
    throw 'Output archive must use the .zip extension.'
  }
  $repositoryItem = Get-Item -LiteralPath $repositoryRoot -Force -ErrorAction Stop
  if (-not $repositoryItem.PSIsContainer) {
    throw "Repository root must be a directory: '$repositoryRoot'."
  }
  Assert-UnlinkedPathChain -FullPath $repositoryRoot -Description 'Repository root'
  $artifactInput = Get-StrictInputSnapshot -Path $Artifact -Description 'Artifact input'
  if (-not [String]::IsNullOrWhiteSpace($Contract)) {
    $contractInput = Get-StrictInputSnapshot -Path $Contract -Description 'Contract input'
  }
  $outputParent = Get-StrictOutputParent -Path $outputParent
  $outputParentIdentity = (Resolve-Path -LiteralPath $outputParent).ProviderPath
  Assert-OutputAbsent -Parent $outputParent -Leaf ([IO.Path]::GetFileName($outputPath))
  Assert-ExactStagePath

  $fault = [Environment]::GetEnvironmentVariable(
    'MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_FAULT'
  )
  if (-not [String]::IsNullOrEmpty($fault) -and $fault -cne 'before-publish') {
    throw 'Unsupported internal bundle fault.'
  }

  [IO.Directory]::CreateDirectory($workRoot) | Out-Null
  Assert-ExactWorkRoot
  $contentRoot = Join-Path $workRoot 'moonhostabi-reproduction'
  [IO.Directory]::CreateDirectory($contentRoot) | Out-Null
  $bundleArtifact = Join-Path $contentRoot 'artifact.wasm'
  [IO.File]::WriteAllBytes($bundleArtifact, $artifactInput.Bytes)
  if ($null -ne $contractInput) {
    $contractPath = Join-Path $workRoot 'input.contract.json'
    [IO.File]::WriteAllBytes($contractPath, $contractInput.Bytes)
  }

  $moon = @(Get-Command moon -CommandType Application -ErrorAction Stop)[0].Source
  $build = Invoke-CapturedProcess -FilePath $moon -Arguments @(
    '-C', $repositoryRoot, 'build', 'cmd/moonhostabi', '--target', 'native'
  )
  Assert-ProcessSuccess -Result $build -Description 'MoonHostABI native build'
  $cliCandidates = @(
    (Join-Path $repositoryRoot '_build/native/debug/build/cmd/moonhostabi/moonhostabi.exe'),
    (Join-Path $repositoryRoot '_build/native/debug/build/cmd/moonhostabi/moonhostabi')
  )
  $existingCli = @($cliCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
  if ($existingCli.Count -ne 1) { throw "Expected exactly one MoonHostABI executable candidate, found $($existingCli.Count)." }
  $cliPath = $existingCli[0]

  $moonVersions = Invoke-CapturedProcess -FilePath $moon -Arguments @('version', '--all')
  Assert-ProcessSuccess -Result $moonVersions -Description 'MoonBit version query'
  $moonVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moon ([^\s]+) \(' -Description 'moon'
  $mooncVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moonc ([^\s]+) \(' -Description 'moonc'
  $moonrunVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moonrun ([^\s]+) \(' -Description 'moonrun'
  $cliVersionResult = Invoke-CapturedProcess -FilePath $cliPath -Arguments @('--version')
  Assert-ProcessSuccess -Result $cliVersionResult -Description 'MoonHostABI version query' -RequireEmptyStderr
  $cliVersionText = ($cliVersionResult.Stdout -replace "`r`n?", "`n").TrimEnd("`n")
  if ($cliVersionText -cnotmatch '^moonhostabi ([0-9]+\.[0-9]+\.[0-9]+)$') {
    throw "MoonHostABI version output was malformed: '$($cliVersionResult.Stdout)'."
  }
  $moonHostAbiVersion = $Matches[1]

  $lockPath = Join-Path $contentRoot 'host-abi.lock.json'
  $lock = Invoke-CapturedProcess -FilePath $cliPath -Arguments @(
    'lock', $bundleArtifact, '--out', $lockPath
  )
  Assert-ProcessSuccess -Result $lock -Description 'Public lock command' -RequireEmptyStderr

  $generatedRoot = Join-Path $workRoot 'generated'
  $generateArguments = if ($null -eq $contractPath) {
    @('generate', $bundleArtifact, '--out', $generatedRoot)
  } else {
    @(
      'generate', $bundleArtifact, '--contract', $contractPath,
      '--out', $generatedRoot
    )
  }
  $generate = Invoke-CapturedProcess -FilePath $cliPath -Arguments $generateArguments
  Assert-ProcessSuccess -Result $generate -Description 'Public generate command' -RequireEmptyStderr
  $generatedNames = @(
    Get-ChildItem -LiteralPath $generatedRoot -Force |
      Sort-Object Name |
      ForEach-Object Name
  )
  if (
    [String]::Join("`n", $generatedNames) -cne
    [String]::Join("`n", @(
      'adapter.ts',
      'moonhostabi.contract.json',
      'moonhostabi.manifest.json'
    ))
  ) {
    throw "Public generate command emitted an unexpected file set: $($generatedNames -join ', ')."
  }
  Copy-ExactFile `
    -Source (Join-Path $generatedRoot 'moonhostabi.contract.json') `
    -Destination (Join-Path $contentRoot 'moonhostabi.contract.json')
  Copy-ExactFile `
    -Source (Join-Path $generatedRoot 'adapter.ts') `
    -Destination (Join-Path $contentRoot 'adapter.ts')

  $validation = Invoke-CapturedProcess -FilePath $cliPath -Arguments @(
    'verify', $bundleArtifact,
    '--against', $lockPath,
    '--contract', (Join-Path $contentRoot 'moonhostabi.contract.json'),
    '--format', 'json'
  )
  Assert-ProcessSuccess -Result $validation -Description 'Public verify command' -RequireEmptyStderr
  $validationText = ($validation.Stdout -replace "`r`n?", "`n").TrimEnd("`n")
  if ($validationText.Contains("`n")) {
    throw 'Public verify command emitted more than one JSON line.'
  }
  try {
    $validationReport = $validationText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "Public verify command emitted invalid JSON: $($_.Exception.Message)"
  }
  if ($validationReport.schemaVersion -ne 1 -or $validationReport.outcome -cne 'compatible') {
    throw 'Public verify command did not produce a compatible schema-v1 report.'
  }
  Write-Utf8Text `
    -Path (Join-Path $contentRoot 'validation.json') `
    -Text ($validationText + "`n")

  $commands = @(
    'moonhostabi lock artifact.wasm --out reproduced.lock.json',
    'moonhostabi verify artifact.wasm --against host-abi.lock.json --contract moonhostabi.contract.json --format json',
    'moonhostabi generate artifact.wasm --contract moonhostabi.contract.json --out regenerated'
  ) -join "`n"
  Write-Utf8Text `
    -Path (Join-Path $contentRoot 'commands.txt') `
    -Text ($commands + "`n")

  $manifest = New-BundleManifest `
    -ContentRoot $contentRoot `
    -MoonHostAbiVersion $moonHostAbiVersion `
    -MoonVersion $moonVersion `
    -MooncVersion $mooncVersion `
    -MoonrunVersion $moonrunVersion
  Write-Utf8Text -Path (Join-Path $contentRoot 'manifest.json') -Text $manifest

  Assert-OutputParentIdentity
  Write-DeterministicArchive -ContentRoot $contentRoot -ArchivePath $stagePath
  Assert-ExactStagePath
  if ($fault -ceq 'before-publish') {
    throw 'Injected bundle failure before publication.'
  }
  Assert-OutputParentIdentity
  try {
    [IO.File]::Move($stagePath, $outputPath, $false)
  }
  catch [IO.IOException] {
    throw "Failed to publish archive without overwrite: $($_.Exception.Message)"
  }
  Write-Output "MOONHOSTABI_BUNDLE_SHA256=$(Get-Sha256 -Path $outputPath)"
  Write-Output 'MOONHOSTABI_BUNDLE_STATUS=CREATED'
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
  if (Test-Path -LiteralPath $stagePath) {
    Assert-ExactStagePath
    [IO.File]::Delete($stagePath)
  }
  if (Test-Path -LiteralPath $workRoot) {
    Assert-ExactWorkRoot
    Remove-Item -LiteralPath $workRoot -Recurse -Force
  }
  if ($processCleanupErrors.Count -ne 0) {
    throw "Failed to terminate bundle child processes: $($processCleanupErrors -join '; ')"
  }
}
