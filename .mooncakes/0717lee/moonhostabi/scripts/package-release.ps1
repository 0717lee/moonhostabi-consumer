[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [Alias('OutputDirectory')] [string] $Output,
  [string] $EvidenceOut,
  [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

if ($Version -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
  throw 'Version must be strict MAJOR.MINOR.PATCH without leading zeroes.'
}
if ([String]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$outputRoot = [IO.Path]::GetFullPath($Output)
$evidencePath = if ([String]::IsNullOrWhiteSpace($EvidenceOut)) {
  $null
} else {
  [IO.Path]::GetFullPath($EvidenceOut)
}
$hostTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath
$testToken = [Environment]::GetEnvironmentVariable(
  'MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_TOKEN'
)
$testFault = [Environment]::GetEnvironmentVariable(
  'MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_FAULT'
)
if (-not [String]::IsNullOrEmpty($testToken) -and $testToken -cnotmatch '^[0-9a-f]{32}$') {
  throw 'MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_TOKEN must be 32 lowercase hex characters.'
}
if (
  -not [String]::IsNullOrEmpty($testFault) -and
  $testFault -cne 'after-archive-publish'
) {
  throw 'Unknown MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_FAULT value.'
}
$workLeaf = if ([String]::IsNullOrEmpty($testToken)) {
  'moonhostabi-release-work-' + [Guid]::NewGuid().ToString('N')
} else {
  "moonhostabi-release-work-$testToken-$([Guid]::NewGuid().ToString('N'))"
}
$workLeafPattern = if ([String]::IsNullOrEmpty($testToken)) {
  '^moonhostabi-release-work-[0-9a-f]{32}$'
} else {
  '^moonhostabi-release-work-[0-9a-f]{32}-[0-9a-f]{32}$'
}
$workRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $workLeaf))
$platform = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } else {
  throw 'Release packaging supports Windows and Linux only.'
}
if (
  [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
  [Runtime.InteropServices.Architecture]::X64
) {
  throw 'Release packaging requires an x86_64 host architecture.'
}
$rootName = "moonhostabi-v$Version-$platform-x86_64"
$archiveName = if ($IsWindows) { "$rootName.zip" } else { "$rootName.tar.gz" }
$archivePath = [IO.Path]::GetFullPath((Join-Path $outputRoot $archiveName))
$stageLeaf = '.moonhostabi-release-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp'
$stagePath = [IO.Path]::GetFullPath((Join-Path $outputRoot $stageLeaf))
$evidenceStagePath = if ($null -eq $evidencePath) {
  $null
} else {
  [IO.Path]::Combine(
    [IO.Path]::GetDirectoryName($evidencePath),
    '.moonhostabi-evidence-stage-' + [Guid]::NewGuid().ToString('N') + '.tmp'
  )
}
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}
$utf8NoBom = [Text.UTF8Encoding]::new($false, $true)
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

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
    $trimmed = $cursor.TrimEnd('\', '/')
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

function Get-StrictDirectory {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Description
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer) {
    throw "$Description must be a directory: '$fullPath'."
  }
  Assert-UnlinkedPathChain -FullPath $fullPath -Description $Description
  $fullPath
}

function Get-StrictFile {
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
  $fullPath
}

function Assert-PathAbsent {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Description
  )

  $parent = Get-StrictDirectory -Path ([IO.Path]::GetDirectoryName($Path)) -Description "$Description parent"
  $leaf = [IO.Path]::GetFileName($Path)
  $matches = @(
    Get-ChildItem -LiteralPath $parent -Force |
      Where-Object { [String]::Equals($_.Name, $leaf, $script:pathComparison) }
  )
  if ($matches.Count -ne 0) {
    throw "$Description already exists; refusing overwrite: '$Path'."
  }
}

function Assert-ExactWorkRoot {
  $item = Get-Item -LiteralPath $script:workRoot -Force
  if (Test-IsLinkOrReparsePoint -Item $item) {
    throw 'Refusing to remove a linked release work root.'
  }
  $resolved = (Resolve-Path -LiteralPath $script:workRoot).ProviderPath
  $parent = (Resolve-Path -LiteralPath $script:hostTempRoot).ProviderPath
  $normalized = [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/')
  $normalizedParent = [IO.Path]::GetFullPath($parent).TrimEnd('\', '/')
  if (
    -not $normalized.StartsWith(
      $normalizedParent + [IO.Path]::DirectorySeparatorChar,
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($normalized) -cne $script:workLeaf -or
    $script:workLeaf -cnotmatch $script:workLeafPattern
  ) {
    throw "Refusing to remove unexpected release work root '$normalized'."
  }
}

function Assert-ExactStageFile {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $ExpectedParent,
    [Parameter(Mandatory)] [string] $Pattern
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  if (
    -not [String]::Equals(
      [IO.Path]::GetDirectoryName($fullPath),
      [IO.Path]::GetFullPath($ExpectedParent),
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($fullPath) -cnotmatch $Pattern
  ) {
    throw "Refusing unexpected release staging path '$fullPath'."
  }
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
  if ($null -ne $item -and (Test-IsLinkOrReparsePoint -Item $item)) {
    throw "Refusing linked release staging path '$fullPath'."
  }
}

function Invoke-CapturedProcess {
  param(
    [Parameter(Mandatory)] [string] $FilePath,
    [Parameter(Mandatory)] [string[]] $Arguments,
    [hashtable] $Environment = @{},
    [int] $TimeoutMilliseconds = 180000
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
  [void]$startInfo.Environment.Remove('MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_TOKEN')
  [void]$startInfo.Environment.Remove('MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_FAULT')
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

function Assert-ProcessSuccess {
  param(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)] [string] $Description,
    [switch] $RequireEmptyStderr
  )

  if ($Result.ExitCode -ne 0) {
    throw "$Description failed. exit=$($Result.ExitCode) stdout='$($Result.Stdout)' stderr='$($Result.Stderr)'"
  }
  if ($RequireEmptyStderr -and $Result.Stderr -cne '') {
    throw "$Description wrote unexpected stderr '$($Result.Stderr)'."
  }
}

function Get-StrictModuleVersion {
  $lines = @(
    [IO.File]::ReadAllLines((Join-Path $script:repositoryRoot 'moon.mod')) |
      Where-Object { $_ -match '^\s*version\b' }
  )
  if ($lines.Count -ne 1 -or $lines[0] -cnotmatch '^version = "((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"$') {
    throw 'moon.mod must contain one strict MAJOR.MINOR.PATCH version.'
  }
  $Matches[1]
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

function Copy-ReleaseFile {
  param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Destination,
    [switch] $Text
  )

  $sourcePath = Get-StrictFile -Path $Source -Description 'Release source'
  $bytes = [IO.File]::ReadAllBytes($sourcePath)
  if ($Text) {
    if (
      $bytes.Length -ge 3 -and
      $bytes[0] -eq 0xef -and
      $bytes[1] -eq 0xbb -and
      $bytes[2] -eq 0xbf
    ) {
      throw "Release text contains a UTF-8 BOM: '$Source'."
    }
    $decoded = $script:utf8NoBom.GetString($bytes)
    if ($decoded.Contains("`r") -and $decoded -notmatch "`r`n") {
      throw "Release text contains an invalid carriage return: '$Source'."
    }
    $bytes = $script:utf8NoBom.GetBytes($decoded.Replace("`r`n", "`n"))
  }
  [IO.File]::WriteAllBytes($Destination, $bytes)
}

function Get-Sha256 {
  param([Parameter(Mandatory)] [string] $Path)

  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

  ConvertTo-Json -InputObject $Value -Compress
}

function Write-DeterministicZip {
  param(
    [Parameter(Mandatory)] [string] $PackageRoot,
    [Parameter(Mandatory)] [string] $Archive
  )

  $relativeFiles = [string[]]@(
    'LICENSE',
    'README.md',
    'bin/moonhostabi.exe',
    'docs/report-schema.md',
    'docs/validation.md',
    'examples/artifact.wasm',
    'examples/host-abi.lock.json',
    'examples/moonhostabi.contract.json'
  )
  [Array]::Sort($relativeFiles, [StringComparer]::Ordinal)
  $stream = [IO.File]::Open(
    $Archive,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,
    [IO.FileShare]::None
  )
  $zip = $null
  try {
    $zip = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Create,
      $false,
      [Text.UTF8Encoding]::new($false, $true)
    )
    $timestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    foreach ($relative in $relativeFiles) {
      $entryName = "$script:rootName/$relative"
      $entry = $zip.CreateEntry(
        $entryName,
        [IO.Compression.CompressionLevel]::NoCompression
      )
      $entry.LastWriteTime = $timestamp
      $entry.ExternalAttributes = 0
      $input = [IO.File]::OpenRead(
        (Join-Path $PackageRoot ([IO.Path]::Combine([string[]]$relative.Split('/'))))
      )
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
    if ($null -ne $zip) {
      $zip.Dispose()
    }
    $stream.Dispose()
  }
}

function Write-ReleaseEvidence {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $ArchiveHash,
    [Parameter(Mandatory)] [Int64] $ArchiveSize,
    [Parameter(Mandatory)] [string] $SourceCommit,
    [Parameter(Mandatory)] [bool] $SourceTreeClean,
    [Parameter(Mandatory)] [bool] $VersionSmokePassed,
    [Parameter(Mandatory)] [bool] $HelpSmokePassed,
    [Parameter(Mandatory)] [bool] $VerifySmokePassed,
    [Parameter(Mandatory)] [string] $MoonVersion,
    [Parameter(Mandatory)] [string] $MooncVersion,
    [Parameter(Mandatory)] [string] $MoonrunVersion
  )

  $clean = if ($SourceTreeClean) { 'true' } else { 'false' }
  $versionSmokeValue = if ($VersionSmokePassed) { 'true' } else { 'false' }
  $helpSmokeValue = if ($HelpSmokePassed) { 'true' } else { 'false' }
  $verifySmokeValue = if ($VerifySmokePassed) { 'true' } else { 'false' }
  $size = $ArchiveSize.ToString([Globalization.CultureInfo]::InvariantCulture)
  $text = '{"schemaVersion":1,"releaseVersion":' +
    (ConvertTo-JsonString $Version) +
    ',"platform":' +
    (ConvertTo-JsonString $platform) +
    ',"architecture":"x86_64","simulated":false,"sourceCommit":' +
    (ConvertTo-JsonString $SourceCommit) +
    ',"sourceTreeClean":' +
    $clean +
    ',"archive":{"name":' +
    (ConvertTo-JsonString $archiveName) +
    ',"sha256":' +
    (ConvertTo-JsonString $ArchiveHash) +
    ',"size":' +
    $size +
    '},"smoke":{"version":' +
    $versionSmokeValue +
    ',"help":' +
    $helpSmokeValue +
    ',"verify":' +
    $verifySmokeValue +
    '},"toolVersions":{"moonhostabi":' +
    (ConvertTo-JsonString $Version) +
    ',"moon":' +
    (ConvertTo-JsonString $MoonVersion) +
    ',"moonc":' +
    (ConvertTo-JsonString $MooncVersion) +
    ',"moonrun":' +
    (ConvertTo-JsonString $MoonrunVersion) +
    ',"powershell":' +
    (ConvertTo-JsonString $PSVersionTable.PSVersion.ToString()) +
    ',"dotnetRuntime":' +
    (ConvertTo-JsonString ([Environment]::Version.ToString())) +
    '}}' +
    "`n"
  [IO.File]::WriteAllText($Path, $text, $script:utf8NoBom)
}

$archiveNeedsRollback = $false
$publishedArchiveHash = ''
[Int64] $publishedArchiveSize = 0
try {
  $repositoryRoot = Get-StrictDirectory -Path $repositoryRoot -Description 'Repository root'
  $outputRoot = Get-StrictDirectory -Path $outputRoot -Description 'Package output'
  if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -ne 0) {
    throw 'Package output directory must be empty.'
  }
  Assert-PathAbsent -Path $archivePath -Description 'Release archive'
  Assert-ExactStageFile `
    -Path $stagePath `
    -ExpectedParent $outputRoot `
    -Pattern '^\.moonhostabi-release-stage-[0-9a-f]{32}\.tmp$'
  if ($null -ne $evidencePath) {
    if ([String]::Equals(
      [IO.Path]::GetDirectoryName($evidencePath),
      $outputRoot,
      $pathComparison
    )) {
      throw 'EvidenceOut must be outside the archive-only output directory.'
    }
    Assert-PathAbsent -Path $evidencePath -Description 'Release evidence'
    Assert-ExactStageFile `
      -Path $evidenceStagePath `
      -ExpectedParent ([IO.Path]::GetDirectoryName($evidencePath)) `
      -Pattern '^\.moonhostabi-evidence-stage-[0-9a-f]{32}\.tmp$'
  }

  $moduleVersion = Get-StrictModuleVersion
  if ($Version -cne $moduleVersion) {
    throw "Requested version '$Version' does not match moon.mod '$moduleVersion'."
  }
  $generationManifestText = [IO.File]::ReadAllText(
    (Get-StrictFile `
      -Path (Join-Path $repositoryRoot 'runtime/generated/moonhostabi.manifest.json') `
      -Description 'Committed generation manifest')
  )
  if ([regex]::Matches($generationManifestText, '"generatorVersion":').Count -ne 1) {
    throw 'Committed generation manifest must contain one generatorVersion.'
  }
  $generationManifest = $generationManifestText | ConvertFrom-Json -ErrorAction Stop
  if ($generationManifest.generatorVersion -cne $Version) {
    throw 'Committed generation manifest version does not match requested release.'
  }

  [IO.Directory]::CreateDirectory($workRoot) | Out-Null
  Assert-ExactWorkRoot
  $packageRoot = Join-Path $workRoot $rootName
  foreach ($directory in @(
    $packageRoot,
    (Join-Path $packageRoot 'bin'),
    (Join-Path $packageRoot 'docs'),
    (Join-Path $packageRoot 'examples')
  )) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
  }

  $moon = @(Get-Command moon -CommandType Application -ErrorAction Stop)[0].Source
  $python = @(Get-Command python -CommandType Application -ErrorAction Stop)[0].Source
  $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
  $build = Invoke-CapturedProcess -FilePath $moon -Arguments @(
    '-C', $repositoryRoot, 'build', 'cmd/moonhostabi', '--target', 'native', '--release'
  )
  Assert-ProcessSuccess -Result $build -Description 'MoonHostABI native release build'
  $executableName = if ($IsWindows) { 'moonhostabi.exe' } else { 'moonhostabi' }
  $builtCandidates = @(
    (Join-Path $repositoryRoot '_build/native/release/build/cmd/moonhostabi/moonhostabi.exe'),
    (Join-Path $repositoryRoot '_build/native/release/build/cmd/moonhostabi/moonhostabi')
  )
  $existingBuilt = @($builtCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
  if ($existingBuilt.Count -ne 1) { throw "Expected exactly one built release executable candidate, found $($existingBuilt.Count)." }
  $builtExecutable = Get-StrictFile -Path $existingBuilt[0] -Description 'Built release executable'
  Copy-ReleaseFile `
    -Source $builtExecutable `
    -Destination (Join-Path $packageRoot "bin/$executableName")

  foreach ($copy in @(
    @('LICENSE', 'LICENSE'),
    @('README.md', 'README.md'),
    @('docs/validation.md', 'docs/validation.md'),
    @('docs/report-schema.md', 'docs/report-schema.md'),
    @('fixtures/artifacts/externref.wasm', 'examples/artifact.wasm'),
    @('fixtures/contracts/externref.contract.json', 'examples/moonhostabi.contract.json')
  )) {
    $isText = -not $copy[0].EndsWith('.wasm', [StringComparison]::Ordinal)
    Copy-ReleaseFile `
      -Source (Join-Path $repositoryRoot $copy[0]) `
      -Destination (Join-Path $packageRoot $copy[1]) `
      -Text:$isText
  }

  if ($IsLinux) {
    [IO.File]::SetUnixFileMode(
       (Join-Path $packageRoot "bin/$executableName"),
      [IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite -bor
        [IO.UnixFileMode]::UserExecute -bor
        [IO.UnixFileMode]::GroupRead -bor
        [IO.UnixFileMode]::GroupExecute -bor
        [IO.UnixFileMode]::OtherRead -bor
        [IO.UnixFileMode]::OtherExecute
    )
  }

  $packagedCli = Join-Path $packageRoot "bin/$executableName"
  $lock = Invoke-CapturedProcess -FilePath $packagedCli -Arguments @(
    'lock',
    (Join-Path $packageRoot 'examples/artifact.wasm'),
    '--out',
    (Join-Path $packageRoot 'examples/host-abi.lock.json')
  )
  Assert-ProcessSuccess -Result $lock -Description 'Packaged CLI lock preparation' -RequireEmptyStderr

  $moonVersions = Invoke-CapturedProcess -FilePath $moon -Arguments @('version', '--all')
  Assert-ProcessSuccess -Result $moonVersions -Description 'MoonBit version query'
  $moonVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moon ([^\s]+) \(' -Description 'moon'
  $mooncVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moonc ([^\s]+) \(' -Description 'moonc'
  $moonrunVersion = Get-UniqueCapturedVersion -Text $moonVersions.Stdout -Pattern '^moonrun ([^\s]+) \(' -Description 'moonrun'

  if ($IsWindows) {
    Write-DeterministicZip -PackageRoot $packageRoot -Archive $stagePath
  } else {
    $tar = @(Get-Command tar -CommandType Application -ErrorAction Stop)[0].Source
    $gzip = @(Get-Command gzip -CommandType Application -ErrorAction Stop)[0].Source
    $tarPath = Join-Path $workRoot 'release.tar'
    $linuxTarArguments = @(
      '--sort=name',
      '--mtime=@0',
      '--owner=root',
      '--group=root',
      '--mode=u+rwX,go=rX',
      '--format=gnu',
      '-cf', $tarPath,
      '-C', $workRoot,
      $rootName
    )
    $tarResult = Invoke-CapturedProcess `
      -FilePath $tar `
      -Arguments $linuxTarArguments `
      -Environment @{ LC_ALL = 'C'; TZ = 'UTC' }
    Assert-ProcessSuccess -Result $tarResult -Description 'Deterministic GNU tar creation' -RequireEmptyStderr
    $linuxGzipArguments = @('-n', '-9', $tarPath)
    $gzipResult = Invoke-CapturedProcess `
      -FilePath $gzip `
      -Arguments $linuxGzipArguments `
      -Environment @{ LC_ALL = 'C'; TZ = 'UTC' }
    Assert-ProcessSuccess -Result $gzipResult -Description 'Deterministic gzip creation' -RequireEmptyStderr
    $gzipPath = "$tarPath.gz"
    [IO.File]::WriteAllBytes($stagePath, [IO.File]::ReadAllBytes($gzipPath))
  }

  $stagedArchiveBytes = [IO.File]::ReadAllBytes($stagePath)
  $stagedArchiveHash = Get-Sha256 -Path $stagePath
  $stagedArchiveSize = $stagedArchiveBytes.Length
  $extractRoot = Join-Path $workRoot 'extracted'
  $archiveValidation = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'validate',
    '--archive', $stagePath,
    '--platform', $platform,
    '--version', $Version,
    '--extract', $extractRoot
  )
  Assert-ProcessSuccess -Result $archiveValidation -Description 'Release archive validation' -RequireEmptyStderr
  $extractedRoot = Join-Path $extractRoot $rootName
  $extractedCli = Join-Path $extractedRoot "bin/$executableName"
  $versionSmoke = Invoke-CapturedProcess -FilePath $extractedCli -Arguments @('--version')
  Assert-ProcessSuccess -Result $versionSmoke -Description 'Extracted CLI version smoke' -RequireEmptyStderr
  if (($versionSmoke.Stdout -replace "`r`n?", "`n").TrimEnd("`n") -cne "moonhostabi $Version") {
    throw 'Extracted CLI version does not match requested release.'
  }
  $helpSmoke = Invoke-CapturedProcess -FilePath $extractedCli -Arguments @('--help')
  Assert-ProcessSuccess -Result $helpSmoke -Description 'Extracted CLI help smoke' -RequireEmptyStderr
  if (-not $helpSmoke.Stdout.Contains('moonhostabi verify', [StringComparison]::Ordinal)) {
    throw 'Extracted CLI help is missing the verify command.'
  }
  $verifySmoke = Invoke-CapturedProcess -FilePath $extractedCli -Arguments @(
    'verify',
    (Join-Path $extractedRoot 'examples/artifact.wasm'),
    '--against',
    (Join-Path $extractedRoot 'examples/host-abi.lock.json'),
    '--contract',
    (Join-Path $extractedRoot 'examples/moonhostabi.contract.json'),
    '--format', 'json'
  )
  Assert-ProcessSuccess -Result $verifySmoke -Description 'Extracted CLI verify smoke' -RequireEmptyStderr
  $verifyReport = $verifySmoke.Stdout | ConvertFrom-Json -ErrorAction Stop
  if ($verifyReport.schemaVersion -ne 1 -or $verifyReport.outcome -cne 'compatible') {
    throw 'Extracted CLI verify smoke did not report compatible schema v1.'
  }

  $sourceCommitResult = Invoke-CapturedProcess -FilePath $git -Arguments @(
    '-C', $repositoryRoot, 'rev-parse', '--verify', 'HEAD'
  )
  Assert-ProcessSuccess -Result $sourceCommitResult -Description 'Git source commit query' -RequireEmptyStderr
  $sourceCommit = ($sourceCommitResult.Stdout -replace "`r`n?", "`n").TrimEnd("`n")
  if ($sourceCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Git source commit is not a full lowercase SHA-1.'
  }
  $sourceStatus = Invoke-CapturedProcess -FilePath $git -Arguments @(
    '-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=all'
  )
  Assert-ProcessSuccess -Result $sourceStatus -Description 'Git source tree query' -RequireEmptyStderr
  $sourceTreeClean = [String]::IsNullOrEmpty($sourceStatus.Stdout)

  $archiveHash = $stagedArchiveHash
  $archiveSize = $stagedArchiveSize
  if ($null -ne $evidencePath) {
    Write-ReleaseEvidence `
      -Path $evidenceStagePath `
      -ArchiveHash $archiveHash `
      -ArchiveSize $archiveSize `
      -SourceCommit $sourceCommit `
      -SourceTreeClean $sourceTreeClean `
      -VersionSmokePassed $true `
      -HelpSmokePassed $true `
      -VerifySmokePassed $true `
      -MoonVersion $moonVersion `
      -MooncVersion $mooncVersion `
      -MoonrunVersion $moonrunVersion
  }

  [IO.File]::WriteAllBytes($archivePath, $stagedArchiveBytes)
  if ((Get-Sha256 -Path $archivePath) -cne $archiveHash) {
    throw 'Published release archive bytes differ from the validated archive.'
  }
  if ($null -ne $evidencePath) {
    $publishedArchiveHash = $archiveHash
    $publishedArchiveSize = $archiveSize
    $archiveNeedsRollback = $true
    if ($testFault -ceq 'after-archive-publish') {
      throw 'Injected release package failure after archive publication.'
    }
    [IO.File]::Move($evidenceStagePath, $evidencePath, $false)
    $archiveNeedsRollback = $false
  }
  Write-Output "MOONHOSTABI_PACKAGE_NAME=$archiveName"
  Write-Output "MOONHOSTABI_PACKAGE_SHA256=$archiveHash"
  Write-Output 'MOONHOSTABI_PACKAGE_SMOKE=GO'
  Write-Output 'MOONHOSTABI_PACKAGE_STATUS=CREATED'
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
  if ($archiveNeedsRollback -and (Test-Path -LiteralPath $archivePath)) {
    try {
      $published = Get-Item -LiteralPath $archivePath -Force
      if (
        $published.PSIsContainer -or
        (Test-IsLinkOrReparsePoint -Item $published) -or
        -not [String]::Equals($published.FullName, $archivePath, $pathComparison) -or
        $published.Length -ne $publishedArchiveSize -or
        (Get-Sha256 -Path $archivePath) -cne $publishedArchiveHash
      ) {
        throw 'Refusing to roll back an archive that no longer matches this package run.'
      }
      [IO.File]::Delete($archivePath)
      $archiveNeedsRollback = $false
    }
    catch {
      [void]$cleanupErrors.Add("Published archive rollback failed: $($_.Exception.Message)")
    }
  }
  if (Test-Path -LiteralPath $stagePath) {
    try {
      Assert-ExactStageFile `
        -Path $stagePath `
        -ExpectedParent $outputRoot `
        -Pattern '^\.moonhostabi-release-stage-[0-9a-f]{32}\.tmp$'
      [IO.File]::Delete($stagePath)
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if ($null -ne $evidenceStagePath -and (Test-Path -LiteralPath $evidenceStagePath)) {
    try {
      Assert-ExactStageFile `
        -Path $evidenceStagePath `
        -ExpectedParent ([IO.Path]::GetDirectoryName($evidencePath)) `
        -Pattern '^\.moonhostabi-evidence-stage-[0-9a-f]{32}\.tmp$'
      [IO.File]::Delete($evidenceStagePath)
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if (Test-Path -LiteralPath $workRoot) {
    try {
      Assert-ExactWorkRoot
      Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if ($cleanupErrors.Count -ne 0) {
    throw "Release package cleanup failed: $($cleanupErrors -join '; ')"
  }
}
