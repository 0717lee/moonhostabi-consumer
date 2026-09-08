param(
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
$runLeaf = 'moonhostabi-repro-verify-' + [Guid]::NewGuid().ToString('N')
$runRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $runLeaf))
$creatorToken = [Guid]::NewGuid().ToString('N')
$sentinelToken = [Guid]::NewGuid().ToString('N')
$sentinelRunToken = [Guid]::NewGuid().ToString('N')
$sentinelLeaf = "moonhostabi-repro-work-$sentinelToken-$sentinelRunToken"
$sentinelPath = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $sentinelLeaf))
$sentinelCreated = $false
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}
$expectedArchiveEntries = @(
  'moonhostabi-reproduction/manifest.json',
  'moonhostabi-reproduction/validation.json',
  'moonhostabi-reproduction/host-abi.lock.json',
  'moonhostabi-reproduction/moonhostabi.contract.json',
  'moonhostabi-reproduction/adapter.ts',
  'moonhostabi-reproduction/artifact.wasm',
  'moonhostabi-reproduction/commands.txt'
)
$expectedPayloadPaths = @(
  'validation.json',
  'host-abi.lock.json',
  'moonhostabi.contract.json',
  'adapter.ts',
  'artifact.wasm',
  'commands.txt'
)
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

function Assert-ExactVerifierTemp {
  $item = Get-Item -LiteralPath $script:runRoot -Force
  if (
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not [String]::IsNullOrEmpty($item.LinkType)
  ) {
    throw 'Refusing to remove a linked reproduction verifier directory.'
  }
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
  $prefix = $normalizedParent + [IO.Path]::DirectorySeparatorChar
  if (
    -not $normalizedPath.StartsWith($prefix, $script:pathComparison) -or
    [IO.Path]::GetFileName($normalizedPath) -cne $script:runLeaf -or
    $script:runLeaf -notmatch '^moonhostabi-repro-verify-[0-9a-f]{32}$'
  ) {
    throw "Refusing to remove unexpected verifier path '$normalizedPath'."
  }
}

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory)] [string] $FilePath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [hashtable] $Environment = @{},
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
  [void]$startInfo.Environment.Remove('MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_FAULT')
  [void]$startInfo.Environment.Remove('MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_TOKEN')
  foreach ($name in $Environment.Keys) {
    $startInfo.Environment[$name] = [string]$Environment[$name]
  }
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

function Invoke-BundleCreation {
  param(
    [Parameter(Mandatory)] [string] $PowerShell,
    [Parameter(Mandatory)] [string] $Artifact,
    [Parameter(Mandatory)] [string] $Contract,
    [Parameter(Mandatory)] [string] $Out,
    [string] $CreationRepositoryRoot,
    [string] $CorrelationToken,
    [hashtable] $Environment = @{}
  )

  $creationRoot = if ([String]::IsNullOrWhiteSpace($CreationRepositoryRoot)) {
    $script:repositoryRoot
  } else {
    $CreationRepositoryRoot
  }
  $effectiveToken = if ([String]::IsNullOrEmpty($CorrelationToken)) {
    $script:creatorToken
  } else {
    $CorrelationToken
  }
  $childEnvironment = @{
    MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_TOKEN = $effectiveToken
  }
  foreach ($name in $Environment.Keys) {
    $childEnvironment[$name] = $Environment[$name]
  }
  Invoke-CapturedProcess `
    -FilePath $PowerShell `
    -Arguments @(
      '-NoProfile',
      '-NonInteractive',
      '-File', (Join-Path $script:repositoryRoot 'scripts/create-reproduction-bundle.ps1'),
      '-RepositoryRoot', $creationRoot,
      '-Artifact', $Artifact,
      '-Contract', $Contract,
      '-Out', $Out
    ) `
    -Environment $childEnvironment
}

function Assert-CreationSuccess {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [string] $Description
  )

  if ($Result.ExitCode -ne 0 -or $Result.Stderr -cne '') {
    throw "$Description failed. exit=$($Result.ExitCode) stdout='$($Result.Stdout)' stderr='$($Result.Stderr)'"
  }
  if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) {
    throw "$Description did not publish '$Archive'."
  }
}

function Assert-CreationFailure {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [string] $Description
  )

  if ($Result.ExitCode -eq 0) {
    throw "$Description unexpectedly succeeded. stdout='$($Result.Stdout)'"
  }
  if (Test-Path -LiteralPath $Archive) {
    throw "$Description left an output at '$Archive'."
  }
}

function Get-Sha256 {
  param([Parameter(Mandatory)] [string] $Path)

  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-BytesEqual {
  param(
    [Parameter(Mandatory)] [string] $Left,
    [Parameter(Mandatory)] [string] $Right,
    [Parameter(Mandatory)] [string] $Description
  )

  $leftBytes = [IO.File]::ReadAllBytes($Left)
  $rightBytes = [IO.File]::ReadAllBytes($Right)
  if (
    $leftBytes.LongLength -ne $rightBytes.LongLength -or
    [Convert]::ToBase64String($leftBytes) -cne [Convert]::ToBase64String($rightBytes)
  ) {
    throw "$Description differs byte-for-byte."
  }
}

function Assert-SafeEntryName {
  param([Parameter(Mandatory)] [string] $Name)

  if (
    [String]::IsNullOrEmpty($Name) -or
    $Name.Contains('\') -or
    $Name.StartsWith('/', [StringComparison]::Ordinal) -or
    $Name -match '^[A-Za-z]:' -or
    [IO.Path]::IsPathRooted($Name)
  ) {
    throw "Unsafe archive entry path '$Name'."
  }
  $segments = $Name.Split('/')
  if ($segments.Count -eq 0) {
    throw "Unsafe empty archive entry path '$Name'."
  }
  foreach ($segment in $segments) {
    if ([String]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..') {
      throw "Unsafe archive entry segment in '$Name'."
    }
  }
}

function Expand-ValidatedArchive {
  param(
    [Parameter(Mandatory)] [string] $ArchivePath,
    [Parameter(Mandatory)] [string] $Destination
  )

  if (Test-Path -LiteralPath $Destination) {
    throw "Extraction destination already exists: '$Destination'."
  }
  $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $archive = $null
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Read,
      $false,
      [Text.UTF8Encoding]::new($false, $true)
    )
    $entries = @($archive.Entries)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
      Assert-SafeEntryName -Name $entry.FullName
      if (-not $seen.Add($entry.FullName)) {
        throw "Duplicate archive entry '$($entry.FullName)'."
      }
      if ([String]::IsNullOrEmpty($entry.Name)) {
        throw "Directory archive entries are not allowed: '$($entry.FullName)'."
      }
      if (
        $entry.LastWriteTime.Year -ne 1980 -or
        $entry.LastWriteTime.Month -ne 1 -or
        $entry.LastWriteTime.Day -ne 1 -or
        $entry.LastWriteTime.Hour -ne 0 -or
        $entry.LastWriteTime.Minute -ne 0 -or
        $entry.LastWriteTime.Second -ne 0
      ) {
        throw "Archive entry '$($entry.FullName)' has a noncanonical timestamp."
      }
      if ($entry.ExternalAttributes -ne 0) {
        throw "Archive entry '$($entry.FullName)' has noncanonical external attributes."
      }
      if ($entry.CompressedLength -ne $entry.Length) {
        throw "Archive entry '$($entry.FullName)' is not stored without compression."
      }
    }
    $actualNames = @($entries | ForEach-Object FullName)
    if (
      [String]::Join("`n", $actualNames) -cne
      [String]::Join("`n", $script:expectedArchiveEntries)
    ) {
      throw "Archive entry set/order is not canonical: $($actualNames -join ', ')."
    }

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd(
      [IO.Path]::DirectorySeparatorChar,
      [IO.Path]::AltDirectorySeparatorChar
    )
    $destinationPrefix = $destinationFull + [IO.Path]::DirectorySeparatorChar
    $paths = [ordered]@{}
    foreach ($entry in $entries) {
      $relative = [IO.Path]::Combine([string[]]$entry.FullName.Split('/'))
      $target = [IO.Path]::GetFullPath((Join-Path $destinationFull $relative))
      if (-not $target.StartsWith($destinationPrefix, $script:pathComparison)) {
        throw "Archive entry escaped extraction root: '$($entry.FullName)'."
      }
      [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
      $input = $entry.Open()
      $output = $null
      try {
        $output = [IO.File]::Open(
          $target,
          [IO.FileMode]::CreateNew,
          [IO.FileAccess]::Write,
          [IO.FileShare]::None
        )
        $input.CopyTo($output)
      }
      finally {
        if ($null -ne $output) {
          $output.Dispose()
        }
        $input.Dispose()
      }
      $paths[$entry.FullName] = $target
    }
    [pscustomobject]@{ Root = $destinationFull; Paths = $paths }
  }
  finally {
    if ($null -ne $archive) {
      $archive.Dispose()
    }
    $stream.Dispose()
  }
}

function Assert-Utf8LfText {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Description,
    [switch] $RequireFinalLf
  )

  $bytes = [IO.File]::ReadAllBytes($Path)
  if (
    $bytes.Length -ge 3 -and
    $bytes[0] -eq 0xef -and
    $bytes[1] -eq 0xbb -and
    $bytes[2] -eq 0xbf
  ) {
    throw "$Description contains a UTF-8 BOM."
  }
  try {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  }
  catch {
    throw "$Description is not valid UTF-8."
  }
  if ($text.Contains("`r")) {
    throw "$Description contains a non-LF line ending."
  }
  if ($RequireFinalLf -and -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
    throw "$Description must end in LF."
  }
  $text
}

function Assert-ManifestIntegrity {
  param([Parameter(Mandatory)] [string] $ExtractedRoot)

  $bundleRoot = Join-Path $ExtractedRoot 'moonhostabi-reproduction'
  $manifestPath = Join-Path $bundleRoot 'manifest.json'
  $manifestText = Assert-Utf8LfText -Path $manifestPath -Description 'manifest.json' -RequireFinalLf
  if (($manifestText -split "`n").Count -ne 2) {
    throw 'manifest.json must be one canonical JSON line followed by LF.'
  }
  try {
    $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    throw "manifest.json is invalid JSON: $($_.Exception.Message)"
  }
  $topFields = @($manifest.PSObject.Properties.Name)
  if (
    [String]::Join("`n", $topFields) -cne
    [String]::Join("`n", @('schemaVersion', 'moonHostAbiVersion', 'toolVersions', 'files'))
  ) {
    throw "manifest.json has unexpected top-level fields/order: $($topFields -join ', ')."
  }
  if ($manifest.schemaVersion -ne 1) {
    throw "manifest.json schemaVersion must be 1."
  }
  $toolFields = @($manifest.toolVersions.PSObject.Properties.Name)
  if (
    [String]::Join("`n", $toolFields) -cne
    [String]::Join("`n", @('moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime'))
  ) {
    throw "manifest.json has unexpected tool version fields/order: $($toolFields -join ', ')."
  }
  if ([String]::IsNullOrWhiteSpace($manifest.moonHostAbiVersion)) {
    throw 'manifest.json moonHostAbiVersion is empty.'
  }
  $records = @($manifest.files)
  if ($records.Count -ne $script:expectedPayloadPaths.Count) {
    throw "manifest.json must bind exactly six payload files."
  }
  for ($index = 0; $index -lt $records.Count; $index += 1) {
    $record = $records[$index]
    $fields = @($record.PSObject.Properties.Name)
    if ([String]::Join("`n", $fields) -cne "path`nsha256`nsize") {
      throw "manifest.json file record $index has unexpected fields/order."
    }
    $expectedPath = $script:expectedPayloadPaths[$index]
    if ($record.path -cne $expectedPath) {
      throw "manifest.json file record $index expected '$expectedPath', received '$($record.path)'."
    }
    if ($record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw "manifest.json file record '$expectedPath' has an invalid SHA-256."
    }
    $payloadPath = Join-Path $bundleRoot $expectedPath
    $actualHash = Get-Sha256 -Path $payloadPath
    $actualSize = (Get-Item -LiteralPath $payloadPath).Length
    if ($record.sha256 -cne $actualHash -or [Int64]$record.size -ne $actualSize) {
      throw "manifest.json integrity mismatch for '$expectedPath'."
    }
  }

  $validationPath = Join-Path $bundleRoot 'validation.json'
  $validationText = Assert-Utf8LfText -Path $validationPath -Description 'validation.json' -RequireFinalLf
  $validation = $validationText | ConvertFrom-Json -ErrorAction Stop
  if (
    $validation.schemaVersion -ne 1 -or
    $validation.outcome -cne 'compatible' -or
    $validation.artifact.status -cne 'valid' -or
    $validation.baseline.status -cne 'valid' -or
    $validation.provenance.artifactMatchesBaseline -ne $true -or
    $validation.provenance.abiMatchesBaseline -ne $true -or
    $validation.compatibility.classification -cne 'compatible' -or
    $validation.contract.status -cne 'valid' -or
    $validation.generator.status -cne 'representable'
  ) {
    throw 'validation.json is not the expected real compatible verify report.'
  }

  $null = Assert-Utf8LfText -Path (Join-Path $bundleRoot 'host-abi.lock.json') -Description 'host-abi.lock.json'
  $null = Assert-Utf8LfText -Path (Join-Path $bundleRoot 'moonhostabi.contract.json') -Description 'moonhostabi.contract.json' -RequireFinalLf
  $null = Assert-Utf8LfText -Path (Join-Path $bundleRoot 'adapter.ts') -Description 'adapter.ts' -RequireFinalLf
  $commandsText = Assert-Utf8LfText -Path (Join-Path $bundleRoot 'commands.txt') -Description 'commands.txt' -RequireFinalLf
  if (
    $commandsText.Contains($script:repositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $commandsText.Contains($script:runRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $commandsText -match '(?i)(?:^|[\\/])\.codex(?:[\\/]|$)'
  ) {
    throw 'commands.txt contains a local or internal path.'
  }
  $manifest
}

function Assert-NoSensitiveArchiveContent {
  param([Parameter(Mandatory)] [string] $ExtractedRoot)

  $repoForms = @(
    $script:repositoryRoot,
    $script:repositoryRoot.Replace('\', '/'),
    $script:runRoot,
    $script:runRoot.Replace('\', '/')
  )
  $userName = [Environment]::UserName
  foreach ($entry in $script:expectedArchiveEntries) {
    $path = Join-Path $ExtractedRoot ([IO.Path]::Combine([string[]]$entry.Split('/')))
    $text = [Text.UTF8Encoding]::new($false, $false).GetString(
      [IO.File]::ReadAllBytes($path)
    )
    foreach ($literal in $repoForms) {
      if (-not [String]::IsNullOrEmpty($literal) -and $text.Contains($literal, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Archive entry '$entry' leaked local path '$literal'."
      }
    }
    if (
      -not [String]::IsNullOrWhiteSpace($userName) -and
      $userName.Length -ge 3 -and
      $text.Contains($userName, [StringComparison]::OrdinalIgnoreCase)
    ) {
      throw "Archive entry '$entry' leaked the local user name."
    }
    if (
      $text -match '(?i)-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----' -or
      $text -match '(?i)Bearer\s+[A-Za-z0-9._~-]{16,}' -or
      $text -match '(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*["'']?[A-Za-z0-9._~-]{12,}' -or
      $text -match '(?i)(?:^|[\\/])\.codex(?:[\\/]|$)'
    ) {
      throw "Archive entry '$entry' contains a high-confidence sensitive marker."
    }
  }
}

function New-TestArchive {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string[]] $Names
  )

  $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  $archive = $null
  try {
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    foreach ($name in $Names) {
      $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
      $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $entry.ExternalAttributes = 0
      $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
      try {
        $writer.Write('x')
      }
      finally {
        $writer.Dispose()
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

function Assert-ArchiveRejected {
  param(
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [string] $Destination,
    [Parameter(Mandatory)] [string] $Description
  )

  $rejected = $false
  try {
    $null = Expand-ValidatedArchive -ArchivePath $Archive -Destination $Destination
  }
  catch {
    $rejected = $true
  }
  if (-not $rejected) {
    throw "$Description archive was accepted."
  }
  if (Test-Path -LiteralPath $Destination) {
    $children = @(Get-ChildItem -LiteralPath $Destination -Force -Recurse)
    if ($children.Count -ne 0) {
      throw "$Description archive wrote files before rejection."
    }
  }
}

function Get-CorrelatedCreatorTempDirectories {
  $pattern = '^moonhostabi-repro-work-' +
    [regex]::Escape($script:creatorToken) +
    '-[0-9a-f]{32}$'
  @(
    Get-ChildItem -LiteralPath $script:hostTempRoot -Directory -Force |
      Where-Object { $_.Name -cmatch $pattern } |
      ForEach-Object FullName |
      Sort-Object
  )
}

function Assert-ExactUnrelatedSentinel {
  $item = Get-Item -LiteralPath $script:sentinelPath -Force
  if (
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not [String]::IsNullOrEmpty($item.LinkType)
  ) {
    throw 'Refusing to remove a linked concurrency sentinel.'
  }
  $resolvedPath = (Resolve-Path -LiteralPath $script:sentinelPath).ProviderPath
  $resolvedParent = (Resolve-Path -LiteralPath $script:hostTempRoot).ProviderPath
  $sentinelParent = [IO.Path]::GetDirectoryName(
    [IO.Path]::GetFullPath($resolvedPath)
  ).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  $normalizedParent = [IO.Path]::GetFullPath($resolvedParent).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
  )
  if (
    -not [String]::Equals(
      $sentinelParent,
      $normalizedParent,
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($resolvedPath) -cne $script:sentinelLeaf -or
    $script:sentinelLeaf -cnotmatch '^moonhostabi-repro-work-[0-9a-f]{32}-[0-9a-f]{32}$' -or
    $script:sentinelToken -ceq $script:creatorToken
  ) {
    throw "Refusing to remove unexpected concurrency sentinel '$resolvedPath'."
  }
}

function Remove-DirectoryLink {
  param([Parameter(Mandatory)] [string] $Path)

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -ne $item) {
    Remove-Item -LiteralPath $Path -Force
  }
  if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
    throw "Failed to remove directory link '$Path'."
  }
}

try {
  [IO.Directory]::CreateDirectory($runRoot) | Out-Null
  Assert-ExactVerifierTemp
  $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
  $creatorTempsBefore = @(Get-CorrelatedCreatorTempDirectories)
  if ($creatorTempsBefore.Count -ne 0) {
    throw 'Unique creator correlation token unexpectedly has preexisting work directories.'
  }
  [IO.Directory]::CreateDirectory($sentinelPath) | Out-Null
  $sentinelCreated = $true
  Assert-ExactUnrelatedSentinel

  $sourceArtifact = Join-Path $repositoryRoot 'fixtures/artifacts/externref.wasm'
  $sourceContract = Join-Path $repositoryRoot 'fixtures/contracts/externref.contract.json'
  $runA = Join-Path $runRoot 'run-a'
  $runB = Join-Path $runRoot 'run-b'
  $runMutation = Join-Path $runRoot 'run-mutation'
  foreach ($directory in @($runA, $runB, $runMutation)) {
    [IO.Directory]::CreateDirectory((Join-Path $directory 'input')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $directory 'output')) | Out-Null
  }
  $artifactA = Join-Path $runA 'input/artifact.wasm'
  $artifactB = Join-Path $runB 'input/artifact.wasm'
  $artifactMutation = Join-Path $runMutation 'input/artifact.wasm'
  $contractA = Join-Path $runA 'input/contract.json'
  $contractB = Join-Path $runB 'input/contract.json'
  $contractMutation = Join-Path $runMutation 'input/contract.json'
  foreach ($path in @($artifactA, $artifactB, $artifactMutation)) {
    Copy-Item -LiteralPath $sourceArtifact -Destination $path
  }
  foreach ($path in @($contractA, $contractB, $contractMutation)) {
    Copy-Item -LiteralPath $sourceContract -Destination $path
  }
  $mutationBytes = [IO.File]::ReadAllBytes($artifactMutation)
  [IO.File]::WriteAllBytes(
    $artifactMutation,
    [byte[]]($mutationBytes + [byte[]](0, 1, 0))
  )

  $archiveA = Join-Path $runA 'output/reproduction.zip'
  $archiveB = Join-Path $runB 'output/reproduction.zip'
  $archiveMutation = Join-Path $runMutation 'output/reproduction.zip'
  $resultA = Invoke-BundleCreation -PowerShell $pwsh -Artifact $artifactA -Contract $contractA -Out $archiveA
  Assert-CreationSuccess -Result $resultA -Archive $archiveA -Description 'First independent bundle creation'
  $resultB = Invoke-BundleCreation -PowerShell $pwsh -Artifact $artifactB -Contract $contractB -Out $archiveB
  Assert-CreationSuccess -Result $resultB -Archive $archiveB -Description 'Second independent bundle creation'
  $resultMutation = Invoke-BundleCreation -PowerShell $pwsh -Artifact $artifactMutation -Contract $contractMutation -Out $archiveMutation
  Assert-CreationSuccess -Result $resultMutation -Archive $archiveMutation -Description 'Mutated bundle creation'

  $archiveHashA = Get-Sha256 -Path $archiveA
  $archiveHashB = Get-Sha256 -Path $archiveB
  $archiveHashMutation = Get-Sha256 -Path $archiveMutation
  if ($archiveHashA -cne $archiveHashB) {
    throw "Independent archive SHA-256 values differ: $archiveHashA versus $archiveHashB."
  }
  if ($archiveHashA -ceq $archiveHashMutation) {
    throw 'Custom-section mutation did not change the final archive SHA-256.'
  }
  Assert-BytesEqual -Left $archiveA -Right $archiveB -Description 'Independent archives'

  $expandedA = Expand-ValidatedArchive -ArchivePath $archiveA -Destination (Join-Path $runA 'expanded')
  $expandedB = Expand-ValidatedArchive -ArchivePath $archiveB -Destination (Join-Path $runB 'expanded')
  $expandedMutation = Expand-ValidatedArchive -ArchivePath $archiveMutation -Destination (Join-Path $runMutation 'expanded')
  foreach ($entry in $expectedArchiveEntries) {
    Assert-BytesEqual -Left $expandedA.Paths[$entry] -Right $expandedB.Paths[$entry] -Description "Independent unpacked entry '$entry'"
  }
  $manifestA = Assert-ManifestIntegrity -ExtractedRoot $expandedA.Root
  $manifestB = Assert-ManifestIntegrity -ExtractedRoot $expandedB.Root
  $manifestMutation = Assert-ManifestIntegrity -ExtractedRoot $expandedMutation.Root
  if (
    $manifestA.moonHostAbiVersion -cne $manifestB.moonHostAbiVersion -or
    $manifestA.moonHostAbiVersion -cne $manifestMutation.moonHostAbiVersion
  ) {
    throw 'Bundle tool versions drifted between independent runs.'
  }
  $validationA = [IO.File]::ReadAllText(
    $expandedA.Paths['moonhostabi-reproduction/validation.json']
  ) | ConvertFrom-Json
  $validationMutation = [IO.File]::ReadAllText(
    $expandedMutation.Paths['moonhostabi-reproduction/validation.json']
  ) | ConvertFrom-Json
  if (
    $validationA.artifact.sha256 -ceq $validationMutation.artifact.sha256 -or
    $validationA.artifact.abiSha256 -cne $validationMutation.artifact.abiSha256 -or
    $validationA.baseline.artifactSha256 -ceq $validationMutation.baseline.artifactSha256 -or
    $validationA.baseline.abiSha256 -cne $validationMutation.baseline.abiSha256 -or
    $validationMutation.provenance.artifactMatchesBaseline -ne $true -or
    $validationMutation.provenance.abiMatchesBaseline -ne $true -or
    $validationMutation.compatibility.classification -cne 'compatible'
  ) {
    throw 'Custom-section mutation changed ABI identity or failed to change exact artifact provenance.'
  }
  $lockA = [IO.File]::ReadAllText(
    $expandedA.Paths['moonhostabi-reproduction/host-abi.lock.json']
  ) | ConvertFrom-Json
  $lockMutation = [IO.File]::ReadAllText(
    $expandedMutation.Paths['moonhostabi-reproduction/host-abi.lock.json']
  ) | ConvertFrom-Json
  if (
    $lockA.artifactSha256 -ceq $lockMutation.artifactSha256 -or
    $lockA.abiSha256 -cne $lockMutation.abiSha256
  ) {
    throw 'Custom-section mutation did not isolate artifact and ABI lock fingerprints.'
  }
  Assert-NoSensitiveArchiveContent -ExtractedRoot $expandedA.Root
  Assert-NoSensitiveArchiveContent -ExtractedRoot $expandedMutation.Root

  $changedEntries = @(
    'moonhostabi-reproduction/manifest.json',
    'moonhostabi-reproduction/validation.json',
    'moonhostabi-reproduction/host-abi.lock.json',
    'moonhostabi-reproduction/artifact.wasm'
  )
  $unchangedEntries = @(
    'moonhostabi-reproduction/moonhostabi.contract.json',
    'moonhostabi-reproduction/adapter.ts',
    'moonhostabi-reproduction/commands.txt'
  )
  foreach ($entry in $expectedArchiveEntries) {
    $same = [Convert]::ToBase64String([IO.File]::ReadAllBytes($expandedA.Paths[$entry])) -ceq
      [Convert]::ToBase64String([IO.File]::ReadAllBytes($expandedMutation.Paths[$entry]))
    if ($changedEntries -ccontains $entry -and $same) {
      throw "Mutation unexpectedly left '$entry' unchanged."
    }
    if ($unchangedEntries -ccontains $entry -and -not $same) {
      throw "Mutation unexpectedly changed '$entry'."
    }
  }

  $archiveABeforeOverwrite = Get-Sha256 -Path $archiveA
  $overwrite = Invoke-BundleCreation -PowerShell $pwsh -Artifact $artifactA -Contract $contractA -Out $archiveA
  if ($overwrite.ExitCode -eq 0) {
    throw 'Existing archive overwrite unexpectedly succeeded.'
  }
  if ((Get-Sha256 -Path $archiveA) -cne $archiveABeforeOverwrite) {
    throw 'No-overwrite failure changed the existing archive.'
  }

  $faultArchive = Join-Path $runA 'output/fault.zip'
  $fault = Invoke-BundleCreation `
    -PowerShell $pwsh `
    -Artifact $artifactA `
    -Contract $contractA `
    -Out $faultArchive `
    -Environment @{ MOONHOSTABI_INTERNAL_TEST_ONLY_BUNDLE_FAULT = 'before-publish' }
  Assert-CreationFailure -Result $fault -Archive $faultArchive -Description 'Before-publish fault'

  $invalidTokenArchive = Join-Path $runA 'output/invalid-token.zip'
  $invalidToken = Invoke-BundleCreation `
    -PowerShell $pwsh `
    -Artifact $artifactA `
    -Contract $contractA `
    -Out $invalidTokenArchive `
    -CorrelationToken 'INVALID'
  Assert-CreationFailure `
    -Result $invalidToken `
    -Archive $invalidTokenArchive `
    -Description 'Invalid correlation token'

  $linkTarget = Join-Path $runRoot 'link-target'
  $linkPath = Join-Path $runRoot 'artifact-link-parent'
  [IO.Directory]::CreateDirectory($linkTarget) | Out-Null
  Copy-Item -LiteralPath $sourceArtifact -Destination (Join-Path $linkTarget 'artifact.wasm')
  $linkCreated = $false
  try {
    if ($IsWindows) {
      $null = New-Item -ItemType Junction -Path $linkPath -Target $linkTarget
    } else {
      $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget
    }
    $linkCreated = $true
    $linkArchive = Join-Path $runB 'output/linked-input.zip'
    $linked = Invoke-BundleCreation `
      -PowerShell $pwsh `
      -Artifact (Join-Path $linkPath 'artifact.wasm') `
      -Contract $contractB `
      -Out $linkArchive
    Assert-CreationFailure -Result $linked -Archive $linkArchive -Description 'Linked artifact input'
    if ($linked.Stderr -notmatch '(?i)(reparse point|symbolic link)') {
      throw "Linked artifact rejection lacked an explicit link diagnostic: '$($linked.Stderr)'."
    }
    $linkedOutputArchive = Join-Path $linkPath 'output.zip'
    $linkedOutput = Invoke-BundleCreation `
      -PowerShell $pwsh `
      -Artifact $artifactB `
      -Contract $contractB `
      -Out $linkedOutputArchive
    Assert-CreationFailure `
      -Result $linkedOutput `
      -Archive $linkedOutputArchive `
      -Description 'Linked output parent'
    if (
      $linkedOutput.Stderr -notmatch '(?i)(reparse point|symbolic link)' -or
      (Test-Path -LiteralPath (Join-Path $linkTarget 'output.zip'))
    ) {
      throw 'Linked output parent was not rejected without publication.'
    }
  }
  finally {
    if ($linkCreated) {
      Remove-DirectoryLink -Path $linkPath
    }
  }

  $repositoryLink = Join-Path $runRoot 'repository-root-link'
  $repositoryLinkCreated = $false
  try {
    if ($IsWindows) {
      $null = New-Item -ItemType Junction -Path $repositoryLink -Target $repositoryRoot
    } else {
      $null = New-Item -ItemType SymbolicLink -Path $repositoryLink -Target $repositoryRoot
    }
    $repositoryLinkCreated = $true
    $repositoryLinkArchive = Join-Path $runB 'output/linked-repository.zip'
    $linkedRepository = Invoke-BundleCreation `
      -PowerShell $pwsh `
      -Artifact $artifactB `
      -Contract $contractB `
      -Out $repositoryLinkArchive `
      -CreationRepositoryRoot $repositoryLink
    Assert-CreationFailure `
      -Result $linkedRepository `
      -Archive $repositoryLinkArchive `
      -Description 'Linked repository root'
    if ($linkedRepository.Stderr -notmatch '(?i)(reparse point|symbolic link)') {
      throw 'Linked repository root rejection lacked an explicit link diagnostic.'
    }
  }
  finally {
    if ($repositoryLinkCreated) {
      Remove-DirectoryLink -Path $repositoryLink
    }
  }

  $maliciousRoot = Join-Path $runRoot 'malicious'
  [IO.Directory]::CreateDirectory($maliciousRoot) | Out-Null
  $maliciousCases = [ordered]@{
    traversal = @('../escape.txt')
    absolute = @('/absolute.txt')
    drive = @('C:/absolute.txt')
    duplicate = @(
      'moonhostabi-reproduction/manifest.json',
      'moonhostabi-reproduction/manifest.json'
    )
    caseFoldCollision = @(
      'moonhostabi-reproduction/manifest.json',
      'moonhostabi-reproduction/Manifest.json'
    )
    backslash = @('moonhostabi-reproduction\..\escape.txt')
    unc = @('\\server\share\escape.txt')
    unexpected = @('moonhostabi-reproduction/unexpected.txt')
  }
  foreach ($case in $maliciousCases.GetEnumerator()) {
    $maliciousArchive = Join-Path $maliciousRoot "$($case.Key).zip"
    New-TestArchive -Path $maliciousArchive -Names $case.Value
    Assert-ArchiveRejected `
      -Archive $maliciousArchive `
      -Destination (Join-Path $maliciousRoot "$($case.Key)-expanded") `
      -Description $case.Key
  }
  if (Test-Path -LiteralPath (Join-Path $runRoot 'escape.txt')) {
    throw 'Zip Slip test wrote outside its extraction root.'
  }

  $reportSchemaPath = Join-Path $repositoryRoot 'docs/report-schema.md'
  if (-not (Test-Path -LiteralPath $reportSchemaPath -PathType Leaf)) {
    throw 'docs/report-schema.md is missing.'
  }
  $reportSchema = [IO.File]::ReadAllText($reportSchemaPath)
  $exampleMatch = [regex]::Match(
    $reportSchema,
    '(?s)<!-- BEGIN VERIFIED REPORT EXAMPLE -->\s*```json\s*(\{[^\r\n]+\})\s*```\s*<!-- END VERIFIED REPORT EXAMPLE -->',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
  )
  if (-not $exampleMatch.Success) {
    throw 'docs/report-schema.md lacks one machine-checkable verified report example.'
  }
  $validationExample = [IO.File]::ReadAllText(
    $expandedA.Paths['moonhostabi-reproduction/validation.json']
  ).TrimEnd("`n")
  if ($exampleMatch.Groups[1].Value -cne $validationExample) {
    throw 'docs/report-schema.md example drifted from the real bundled verify output.'
  }

  $creatorTempsAfter = @(Get-CorrelatedCreatorTempDirectories)
  if ($creatorTempsAfter.Count -ne 0) {
    throw 'Bundle creation left a current-token work directory behind.'
  }
  if (-not (Test-Path -LiteralPath $sentinelPath -PathType Container)) {
    throw 'Current verifier removed an unrelated creator sentinel.'
  }
  $stageResiduals = @(
    Get-ChildItem -LiteralPath $runRoot -File -Force -Recurse |
      Where-Object { $_.Name -match '^\.moonhostabi-bundle-stage-[0-9a-f]{32}\.tmp$' }
  )
  if ($stageResiduals.Count -ne 0) {
    throw "Bundle creation left staging files: $($stageResiduals.FullName -join ', ')."
  }

  Write-Output "MOONHOSTABI_BUNDLE_SHA256=$archiveHashA"
  Write-Output 'MOONHOSTABI_BUNDLE_UNPACKED_BYTES=IDENTICAL'
  Write-Output "MOONHOSTABI_BUNDLE_MUTATION_CHANGED=$($changedEntries -join ',')"
  Write-Output "MOONHOSTABI_BUNDLE_MUTATION_UNCHANGED=$($unchangedEntries -join ',')"
  Write-Output 'MOONHOSTABI_BUNDLE_PATH_SAFETY=GO'
  Write-Output 'MOONHOSTABI_BUNDLE_STATUS=GO'
}
finally {
  $cleanupErrors = [Collections.Generic.List[string]]::new()
  foreach ($process in $runningProcesses) {
    try {
      if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit()
      }
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
    finally {
      $process.Dispose()
    }
  }
  if ($sentinelCreated -and (Test-Path -LiteralPath $sentinelPath)) {
    try {
      Assert-ExactUnrelatedSentinel
      [IO.Directory]::Delete($sentinelPath, $false)
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if (Test-Path -LiteralPath $runRoot) {
    try {
      Assert-ExactVerifierTemp
      Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if ($cleanupErrors.Count -ne 0) {
    throw "Reproduction verifier cleanup failed: $($cleanupErrors -join '; ')"
  }
}
