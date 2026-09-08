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
$runLeaf = 'moonhostabi-release-verify-' + [Guid]::NewGuid().ToString('N')
$runRoot = [IO.Path]::GetFullPath((Join-Path $hostTempRoot $runLeaf))
$releaseTestToken = [Guid]::NewGuid().ToString('N')
$releaseWorkPrefix = "moonhostabi-release-work-$releaseTestToken-"
$pathComparison = if ($IsWindows) {
  [StringComparison]::OrdinalIgnoreCase
} else {
  [StringComparison]::Ordinal
}
$runningProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

function Assert-ExactRunRoot {
  $item = Get-Item -LiteralPath $script:runRoot -Force
  if (
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    -not [String]::IsNullOrEmpty($item.LinkType)
  ) {
    throw 'Refusing to remove a linked release verifier root.'
  }
  $resolved = (Resolve-Path -LiteralPath $script:runRoot).ProviderPath
  $parent = (Resolve-Path -LiteralPath $script:hostTempRoot).ProviderPath
  $normalized = [IO.Path]::GetFullPath($resolved).TrimEnd('\', '/')
  $normalizedParent = [IO.Path]::GetFullPath($parent).TrimEnd('\', '/')
  if (
    -not $normalized.StartsWith(
      $normalizedParent + [IO.Path]::DirectorySeparatorChar,
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($normalized) -cne $script:runLeaf -or
    $script:runLeaf -cnotmatch '^moonhostabi-release-verify-[0-9a-f]{32}$'
  ) {
    throw "Refusing to remove unexpected release verifier root '$normalized'."
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

function Get-ModuleVersion {
  $lines = @(
    [IO.File]::ReadAllLines((Join-Path $script:repositoryRoot 'moon.mod')) |
      Where-Object { $_ -match '^\s*version\b' }
  )
  if ($lines.Count -ne 1 -or $lines[0] -cnotmatch '^version = "((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"$') {
    throw 'moon.mod must contain one strict MAJOR.MINOR.PATCH version.'
  }
  $Matches[1]
}

function Get-Sha256 {
  param([Parameter(Mandatory)] [string] $Path)

  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-UniqueJsonElement {
  param(
    [Parameter(Mandatory)] [Text.Json.JsonElement] $Element,
    [Parameter(Mandatory)] [string] $Path
  )

  if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
      if (-not $names.Add($property.Name)) {
        throw "Duplicate JSON key '$($property.Name)' at '$Path'."
      }
      Assert-UniqueJsonElement -Element $property.Value -Path "$Path.$($property.Name)"
    }
  } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
    $index = 0
    foreach ($item in $Element.EnumerateArray()) {
      Assert-UniqueJsonElement -Element $item -Path "$Path[$index]"
      $index += 1
    }
  }
}

function Assert-UniqueJsonKeys {
  param(
    [Parameter(Mandatory)] [string] $Text,
    [Parameter(Mandatory)] [string] $Description
  )

  $document = $null
  try {
    $document = [Text.Json.JsonDocument]::Parse($Text)
    Assert-UniqueJsonElement -Element $document.RootElement -Path $Description
  }
  finally {
    if ($null -ne $document) {
      $document.Dispose()
    }
  }
}

function Assert-ExactJsonFields {
  param(
    [Parameter(Mandatory)] $Value,
    [Parameter(Mandatory)] [string[]] $Expected,
    [Parameter(Mandatory)] [string] $Description
  )

  if ($Value -isnot [PSCustomObject]) {
    throw "$Description must be a JSON object."
  }
  $actual = @($Value.PSObject.Properties.Name)
  if ([String]::Join("`n", $actual) -cne [String]::Join("`n", $Expected)) {
    throw "$Description has unexpected fields/order."
  }
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

function Invoke-Package {
  param(
    [Parameter(Mandatory)] [string] $PowerShell,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Output,
    [Parameter(Mandatory)] [string] $Evidence,
    [string] $Fault
  )

  $environment = @{
    MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_TOKEN = $script:releaseTestToken
  }
  if (-not [String]::IsNullOrEmpty($Fault)) {
    $environment.MOONHOSTABI_INTERNAL_TEST_ONLY_RELEASE_FAULT = $Fault
  }
  Invoke-CapturedProcess -FilePath $PowerShell -Environment $environment -Arguments @(
    '-NoProfile',
    '-NonInteractive',
    '-File', (Join-Path $script:repositoryRoot 'scripts/package-release.ps1'),
    '-RepositoryRoot', $script:repositoryRoot,
    '-Version', $Version,
    '-Output', $Output,
    '-EvidenceOut', $Evidence
  )
}

function Assert-PackageEvidence {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $ExpectedPlatform,
    [Parameter(Mandatory)] [string] $ExpectedArchive,
    [Parameter(Mandatory)] [string] $ExpectedHash,
    [Parameter(Mandatory)] [Int64] $ExpectedSize,
    [Parameter(Mandatory)] [bool] $ExpectedSimulated
  )

  $bytes = [IO.File]::ReadAllBytes($Path)
  if (
    $bytes.Length -ge 3 -and
    $bytes[0] -eq 0xef -and
    $bytes[1] -eq 0xbb -and
    $bytes[2] -eq 0xbf
  ) {
    throw "Package evidence contains a UTF-8 BOM: '$Path'."
  }
  $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
  if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
    throw "Package evidence must use LF and end with LF: '$Path'."
  }
  Assert-UniqueJsonKeys -Text $text -Description 'Package evidence'
  $evidence = $text | ConvertFrom-Json -ErrorAction Stop
  Assert-ExactJsonFields `
    -Value $evidence `
    -Expected @(
      'schemaVersion',
      'releaseVersion',
      'platform',
      'architecture',
      'simulated',
      'sourceCommit',
      'sourceTreeClean',
      'archive',
      'smoke',
      'toolVersions'
    ) `
    -Description 'Package evidence'
  Assert-ExactJsonFields `
    -Value $evidence.archive `
    -Expected @('name', 'sha256', 'size') `
    -Description 'Package evidence archive'
  Assert-ExactJsonFields `
    -Value $evidence.smoke `
    -Expected @('version', 'help', 'verify') `
    -Description 'Package evidence smoke'
  Assert-ExactJsonFields `
    -Value $evidence.toolVersions `
    -Expected @('moonhostabi', 'moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime') `
    -Description 'Package evidence toolVersions'
  if (
    $evidence.schemaVersion -isnot [Int64] -or
    $evidence.schemaVersion -ne 1 -or
    $evidence.releaseVersion -isnot [string] -or
    $evidence.releaseVersion -cne $script:version -or
    $evidence.platform -isnot [string] -or
    $evidence.platform -cne $ExpectedPlatform -or
    $evidence.architecture -isnot [string] -or
    $evidence.architecture -cne 'x86_64' -or
    $evidence.simulated -isnot [bool] -or
    $evidence.simulated -ne $ExpectedSimulated -or
    $evidence.sourceCommit -isnot [string] -or
    $evidence.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $evidence.sourceTreeClean -isnot [bool] -or
    $evidence.archive.name -isnot [string] -or
    $evidence.archive.name -cne $ExpectedArchive -or
    $evidence.archive.sha256 -isnot [string] -or
    $evidence.archive.sha256 -cne $ExpectedHash -or
    $evidence.archive.size -isnot [Int64] -or
    [Int64]$evidence.archive.size -ne $ExpectedSize
  ) {
    throw "Package evidence identity mismatch: '$Path'."
  }
  foreach ($field in @('version', 'help', 'verify')) {
    if ($evidence.smoke.$field -isnot [bool]) {
      throw "Package evidence smoke '$field' must be boolean."
    }
  }
  if ($ExpectedSimulated) {
    if (
      $evidence.smoke.version -ne $false -or
      $evidence.smoke.help -ne $false -or
      $evidence.smoke.verify -ne $false
    ) {
      throw 'Simulated evidence must not claim executable smoke results.'
    }
  } elseif (
    $evidence.smoke.version -ne $true -or
    $evidence.smoke.help -ne $true -or
    $evidence.smoke.verify -ne $true
  ) {
    throw 'Real package evidence must record all unpacked smoke checks.'
  }
  foreach ($field in @(
    'moonhostabi', 'moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime'
  )) {
    if (
      $evidence.toolVersions.$field -isnot [string] -or
      [String]::IsNullOrWhiteSpace($evidence.toolVersions.$field)
    ) {
      throw "Package evidence tool version '$field' is empty."
    }
  }
  $evidence
}

function Write-SimulatedEvidence {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Platform,
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] $SourceEvidence
  )

  $hash = Get-Sha256 -Path $Archive
  $size = (Get-Item -LiteralPath $Archive).Length
  $document = [ordered]@{
    schemaVersion = 1
    releaseVersion = $script:version
    platform = $Platform
    architecture = 'x86_64'
    simulated = $true
    sourceCommit = $SourceEvidence.sourceCommit
    sourceTreeClean = $SourceEvidence.sourceTreeClean
    archive = [ordered]@{
      name = [IO.Path]::GetFileName($Archive)
      sha256 = $hash
      size = $size
    }
    smoke = [ordered]@{
      version = $false
      help = $false
      verify = $false
    }
    toolVersions = [ordered]@{
      moonhostabi = $SourceEvidence.toolVersions.moonhostabi
      moon = $SourceEvidence.toolVersions.moon
      moonc = $SourceEvidence.toolVersions.moonc
      moonrun = $SourceEvidence.toolVersions.moonrun
      powershell = $SourceEvidence.toolVersions.powershell
      dotnetRuntime = $SourceEvidence.toolVersions.dotnetRuntime
    }
  }
  $text = ConvertTo-Json -InputObject $document -Depth 8 -Compress
  [IO.File]::WriteAllText(
    $Path,
    $text + "`n",
    [Text.UTF8Encoding]::new($false, $true)
  )
}

function Copy-FlatDirectory {
  param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Destination
  )

  [IO.Directory]::CreateDirectory($Destination) | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Flat test input contains a non-regular item: '$($item.FullName)'."
    }
    [IO.File]::WriteAllBytes(
      (Join-Path $Destination $item.Name),
      [IO.File]::ReadAllBytes($item.FullName)
    )
  }
}

function Get-TreeFingerprint {
  param([Parameter(Mandatory)] [string] $Root)

  $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $records = [Collections.Generic.List[string]]::new()
  foreach ($item in Get-ChildItem -LiteralPath $rootPath -Force -Recurse) {
    $relative = $item.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
    $linkProperty = $item.PSObject.Properties['LinkType']
    $linkType = if ($null -eq $linkProperty) { '' } else { [string]$linkProperty.Value }
    if ($item.PSIsContainer) {
      [void]$records.Add("directory|$relative|$linkType")
    } else {
      [void]$records.Add(
        "file|$relative|$linkType|$($item.Length)|$(Get-Sha256 -Path $item.FullName)"
      )
    }
  }
  $values = $records.ToArray()
  [Array]::Sort($values, [StringComparer]::Ordinal)
  [String]::Join("`n", $values)
}

function Invoke-Aggregate {
  param(
    [Parameter(Mandatory)] [string] $PowerShell,
    [Parameter(Mandatory)] [string] $InputDirectory,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [bool] $AllowSimulatedEvidence = $true
  )

  $arguments = [Collections.Generic.List[string]]::new()
  foreach ($argument in @(
    '-NoProfile',
    '-NonInteractive',
    '-File', (Join-Path $script:repositoryRoot 'scripts/create-release-aggregate.ps1'),
    '-RepositoryRoot', $script:repositoryRoot,
    '-Version', $script:version,
    '-Input', $InputDirectory,
    '-Output', $OutputDirectory
  )) {
    [void]$arguments.Add($argument)
  }
  if ($AllowSimulatedEvidence) {
    [void]$arguments.Add('-AllowSimulatedEvidence')
  }
  Invoke-CapturedProcess -FilePath $PowerShell -Arguments $arguments.ToArray()
}

function Assert-AggregateFailure {
  param(
    [Parameter(Mandatory)] [string] $PowerShell,
    [Parameter(Mandatory)] [string] $InputDirectory,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [Parameter(Mandatory)] [string] $Description,
    [bool] $AllowSimulatedEvidence = $true
  )

  $outputParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputDirectory))
  $inputBefore = Get-TreeFingerprint -Root $InputDirectory
  $parentBefore = Get-TreeFingerprint -Root $outputParent
  $result = Invoke-Aggregate `
    -PowerShell $PowerShell `
    -InputDirectory $InputDirectory `
    -OutputDirectory $OutputDirectory `
    -AllowSimulatedEvidence $AllowSimulatedEvidence
  if (
    $result.ExitCode -eq 0 -or
    -not [String]::IsNullOrEmpty($result.Stdout) -or
    [String]::IsNullOrWhiteSpace($result.Stderr)
  ) {
    throw "$Description aggregate unexpectedly succeeded."
  }
  if (Test-Path -LiteralPath $OutputDirectory) {
    throw "$Description aggregate published an output directory."
  }
  if (
    (Get-TreeFingerprint -Root $InputDirectory) -cne $inputBefore -or
    (Get-TreeFingerprint -Root $outputParent) -cne $parentBefore
  ) {
    throw "$Description aggregate changed its input or left staging output."
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
  Assert-ExactRunRoot
  $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
  $version = Get-ModuleVersion
  $platform = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } else {
    throw 'Release packaging verifier supports Windows and Linux only.'
  }
  $extension = if ($IsWindows) { '.zip' } else { '.tar.gz' }
  $archiveName = "moonhostabi-v$version-$platform-x86_64$extension"
  $rootName = "moonhostabi-v$version-$platform-x86_64"
  $packageExecutableName = if ($IsWindows) { 'moonhostabi.exe' } else { 'moonhostabi' }
  $expectedFiles = [string[]]@(
    "$rootName/LICENSE",
    "$rootName/README.md",
    "$rootName/bin/$packageExecutableName",
    "$rootName/docs/report-schema.md",
    "$rootName/docs/validation.md",
    "$rootName/examples/artifact.wasm",
    "$rootName/examples/host-abi.lock.json",
    "$rootName/examples/moonhostabi.contract.json"
  )
  [Array]::Sort($expectedFiles, [StringComparer]::Ordinal)

  $outputA = Join-Path $runRoot 'package-a'
  $outputB = Join-Path $runRoot 'package-b'
  [IO.Directory]::CreateDirectory($outputA) | Out-Null
  [IO.Directory]::CreateDirectory($outputB) | Out-Null
  $evidenceA = Join-Path $runRoot 'package-a.evidence.json'
  $evidenceB = Join-Path $runRoot 'package-b.evidence.json'
  $resultA = Invoke-Package -PowerShell $pwsh -Version $version -Output $outputA -Evidence $evidenceA
  if ($resultA.ExitCode -ne 0 -or $resultA.Stderr -cne '') {
    throw "First package run failed. exit=$($resultA.ExitCode) stdout='$($resultA.Stdout)' stderr='$($resultA.Stderr)'"
  }
  $resultB = Invoke-Package -PowerShell $pwsh -Version $version -Output $outputB -Evidence $evidenceB
  if ($resultB.ExitCode -ne 0 -or $resultB.Stderr -cne '') {
    throw "Second package run failed. exit=$($resultB.ExitCode) stdout='$($resultB.Stdout)' stderr='$($resultB.Stderr)'"
  }
  $archiveA = Join-Path $outputA $archiveName
  $archiveB = Join-Path $outputB $archiveName
  $filesA = @(Get-ChildItem -LiteralPath $outputA -Force)
  $filesB = @(Get-ChildItem -LiteralPath $outputB -Force)
  if (
    $filesA.Count -ne 1 -or
    $filesB.Count -ne 1 -or
    $filesA[0].Name -cne $archiveName -or
    $filesB[0].Name -cne $archiveName
  ) {
    throw 'Each package output directory must contain exactly its versioned archive.'
  }
  Assert-BytesEqual -Left $archiveA -Right $archiveB -Description 'Independent platform archives'
  $hashA = Get-Sha256 -Path $archiveA
  $hashB = Get-Sha256 -Path $archiveB
  if ($hashA -cne $hashB) {
    throw "Independent platform archive hashes differ: $hashA versus $hashB."
  }
  foreach ($evidence in @($evidenceA, $evidenceB)) {
    if (-not (Test-Path -LiteralPath $evidence -PathType Leaf)) {
      throw "Package evidence is missing: '$evidence'."
    }
  }
  Assert-BytesEqual -Left $evidenceA -Right $evidenceB -Description 'Independent package evidence'
  $evidenceDocument = Assert-PackageEvidence `
    -Path $evidenceA `
    -ExpectedPlatform $platform `
    -ExpectedArchive $archiveName `
    -ExpectedHash $hashA `
    -ExpectedSize (Get-Item -LiteralPath $archiveA).Length `
    -ExpectedSimulated $false

  $python = @(Get-Command python -CommandType Application -ErrorAction Stop)[0].Source
  $extractRoot = Join-Path $runRoot 'independent-extract'
  $archiveCheck = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'validate',
    '--archive', $archiveA,
    '--platform', $platform,
    '--version', $version,
    '--extract', $extractRoot
  )
  if ($archiveCheck.ExitCode -ne 0 -or $archiveCheck.Stderr -cne '') {
    throw "Independent archive validation failed: '$($archiveCheck.Stderr)'."
  }
  $archiveDocument = $archiveCheck.Stdout | ConvertFrom-Json -ErrorAction Stop
  if (
    [String]::Join("`n", @($archiveDocument.files.path)) -cne
    [String]::Join("`n", $expectedFiles)
  ) {
    throw 'Independent archive validation returned an unexpected file layout.'
  }
  $executableName = if ($IsWindows) { 'moonhostabi.exe' } else { 'moonhostabi' }
  $extractedRoot = Join-Path $extractRoot $rootName
  $extractedCli = Join-Path $extractedRoot "bin/$executableName"
  $versionSmoke = Invoke-CapturedProcess -FilePath $extractedCli -Arguments @('--version')
  if (
    $versionSmoke.ExitCode -ne 0 -or
    $versionSmoke.Stderr -cne '' -or
    ($versionSmoke.Stdout -replace "`r`n?", "`n").TrimEnd("`n") -cne "moonhostabi $version"
  ) {
    throw 'Independent unpacked --version smoke failed.'
  }
  $helpSmoke = Invoke-CapturedProcess -FilePath $extractedCli -Arguments @('--help')
  if (
    $helpSmoke.ExitCode -ne 0 -or
    $helpSmoke.Stderr -cne '' -or
    -not $helpSmoke.Stdout.Contains('moonhostabi verify', [StringComparison]::Ordinal)
  ) {
    throw 'Independent unpacked --help smoke failed.'
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
  if ($verifySmoke.ExitCode -ne 0 -or $verifySmoke.Stderr -cne '') {
    throw 'Independent unpacked verify smoke failed.'
  }
  $verifyReport = $verifySmoke.Stdout | ConvertFrom-Json -ErrorAction Stop
  if ($verifyReport.outcome -cne 'compatible') {
    throw 'Independent unpacked verify smoke was not compatible.'
  }
  foreach ($file in $expectedFiles) {
    $relative = $file.Substring($rootName.Length + 1)
    if ($relative -ceq "bin/$packageExecutableName") { continue }
    $path = Join-Path $extractedRoot ([IO.Path]::Combine([string[]]$relative.Split('/')))
    $text = [Text.UTF8Encoding]::new($false, $false).GetString(
      [IO.File]::ReadAllBytes($path)
    )
    foreach ($forbidden in @(
      $repositoryRoot,
      $repositoryRoot.Replace('\', '/'),
      $runRoot,
      $runRoot.Replace('\', '/'),
      [Environment]::UserName
    )) {
      if (
        -not [String]::IsNullOrWhiteSpace($forbidden) -and
        $text.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)
      ) {
        throw "Release archive file '$file' leaked '$forbidden'."
      }
    }
    if (
      $text -match '(?i)(?:^|[\\/])\.codex(?:[\\/]|$)' -or
      $text -match '(?i)-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----' -or
      $text -match '(?i)Bearer\s+[A-Za-z0-9._~-]{16,}'
    ) {
      throw "Release archive file '$file' contains a sensitive marker."
    }
  }

  $otherPlatform = if ($IsWindows) { 'linux' } else { 'windows' }
  $otherExtension = if ($otherPlatform -ceq 'windows') { '.zip' } else { '.tar.gz' }
  $otherArchiveName = "moonhostabi-v$version-$otherPlatform-x86_64$otherExtension"
  $aggregateInput = Join-Path $runRoot 'aggregate-input'
  $aggregateOutput = Join-Path $runRoot 'aggregate-output'
  [IO.Directory]::CreateDirectory($aggregateInput) | Out-Null
  Copy-Item -LiteralPath $archiveA -Destination (Join-Path $aggregateInput $archiveName)
  Copy-Item `
    -LiteralPath $evidenceA `
    -Destination (Join-Path $aggregateInput "$platform.evidence.json")
  $otherArchive = Join-Path $aggregateInput $otherArchiveName
  $mock = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'create-mock',
    '--archive', $otherArchive,
    '--platform', $otherPlatform,
    '--version', $version,
    '--source-root', $extractedRoot
  )
  if ($mock.ExitCode -ne 0 -or $mock.Stderr -cne '') {
    throw "Simulated other-platform archive creation failed: '$($mock.Stderr)'."
  }
  $otherEvidencePath = Join-Path $aggregateInput "$otherPlatform.evidence.json"
  Write-SimulatedEvidence `
    -Path $otherEvidencePath `
    -Platform $otherPlatform `
    -Archive $otherArchive `
    -SourceEvidence $evidenceDocument
  $otherEvidenceDocument = Assert-PackageEvidence `
    -Path $otherEvidencePath `
    -ExpectedPlatform $otherPlatform `
    -ExpectedArchive $otherArchiveName `
    -ExpectedHash (Get-Sha256 -Path $otherArchive) `
    -ExpectedSize (Get-Item -LiteralPath $otherArchive).Length `
    -ExpectedSimulated $true

  $aggregate = Invoke-CapturedProcess -FilePath $pwsh -Arguments @(
    '-NoProfile',
    '-NonInteractive',
    '-File', (Join-Path $repositoryRoot 'scripts/create-release-aggregate.ps1'),
    '-RepositoryRoot', $repositoryRoot,
    '-Version', $version,
    '-Input', $aggregateInput,
    '-Output', $aggregateOutput,
    '-AllowSimulatedEvidence'
  )
  if ($aggregate.ExitCode -ne 0 -or $aggregate.Stderr -cne '') {
    throw "Release aggregate creation failed. exit=$($aggregate.ExitCode) stderr='$($aggregate.Stderr)'"
  }
  $aggregateOutputRepeat = Join-Path $runRoot 'aggregate-output-repeat'
  $aggregateRepeat = Invoke-Aggregate `
    -PowerShell $pwsh `
    -InputDirectory $aggregateInput `
    -OutputDirectory $aggregateOutputRepeat
  if ($aggregateRepeat.ExitCode -ne 0 -or $aggregateRepeat.Stderr -cne '') {
    throw "Repeated release aggregate creation failed: '$($aggregateRepeat.Stderr)'."
  }
  $aggregateNames = [string[]]@(
    Get-ChildItem -LiteralPath $aggregateOutput -Force |
      ForEach-Object Name
  )
  [Array]::Sort($aggregateNames, [StringComparer]::Ordinal)
  $expectedAggregateNames = [string[]]@(
    'SHA256SUMS',
    'provenance.json',
    $archiveName,
    $otherArchiveName
  )
  [Array]::Sort($expectedAggregateNames, [StringComparer]::Ordinal)
  if (
    [String]::Join("`n", $aggregateNames) -cne
    [String]::Join("`n", $expectedAggregateNames)
  ) {
    throw 'Release aggregate output set is not exact.'
  }
  foreach ($name in $expectedAggregateNames) {
    Assert-BytesEqual `
      -Left (Join-Path $aggregateOutput $name) `
      -Right (Join-Path $aggregateOutputRepeat $name) `
      -Description "Repeated aggregate file '$name'"
  }
  $sortedArchiveNames = [string[]]@($archiveName, $otherArchiveName)
  [Array]::Sort($sortedArchiveNames, [StringComparer]::Ordinal)
  $expectedSums = @(
    foreach ($name in $sortedArchiveNames) {
      "$(Get-Sha256 -Path (Join-Path $aggregateOutput $name))  $name"
    }
  ) -join "`n"
  $sumsText = [IO.File]::ReadAllText((Join-Path $aggregateOutput 'SHA256SUMS'))
  if ($sumsText -cne $expectedSums + "`n" -or $sumsText.Contains("`r")) {
    throw 'SHA256SUMS is not canonical or does not match both archives.'
  }
  $provenanceBytes = [IO.File]::ReadAllBytes(
    (Join-Path $aggregateOutput 'provenance.json')
  )
  if (
    $provenanceBytes.Length -ge 3 -and
    $provenanceBytes[0] -eq 0xef -and
    $provenanceBytes[1] -eq 0xbb -and
    $provenanceBytes[2] -eq 0xbf
  ) {
    throw 'provenance.json contains a UTF-8 BOM.'
  }
  $provenanceText = [Text.UTF8Encoding]::new($false, $true).GetString(
    $provenanceBytes
  )
  $provenance = $provenanceText | ConvertFrom-Json -ErrorAction Stop
  Assert-UniqueJsonKeys -Text $provenanceText -Description 'provenance.json'
  Assert-ExactJsonFields `
    -Value $provenance `
    -Expected @(
      'schemaVersion',
      'releaseVersion',
      'sourceCommit',
      'sourceTreeClean',
      'builds',
      'artifacts'
    ) `
    -Description 'provenance.json'
  if (
    $provenanceText.Contains("`r") -or
    -not $provenanceText.EndsWith("`n", [StringComparison]::Ordinal) -or
    $provenance.schemaVersion -isnot [Int64] -or
    $provenance.schemaVersion -ne 1 -or
    $provenance.releaseVersion -isnot [string] -or
    $provenance.releaseVersion -cne $version -or
    $provenance.sourceCommit -isnot [string] -or
    $provenance.sourceCommit -cne $evidenceDocument.sourceCommit -or
    $provenance.sourceTreeClean -isnot [bool] -or
    $provenance.sourceTreeClean -ne $evidenceDocument.sourceTreeClean -or
    @($provenance.builds).Count -ne 2 -or
    @($provenance.artifacts).Count -ne 2 -or
    @($provenance.builds | Where-Object simulated).Count -ne 1
  ) {
    throw 'provenance.json does not match the canonical simulated aggregate contract.'
  }
  $evidenceByPlatform = @{}
  $evidenceByPlatform[$platform] = $evidenceDocument
  $evidenceByPlatform[$otherPlatform] = $otherEvidenceDocument
  foreach ($index in 0..1) {
    $expectedPlatform = @('linux', 'windows')[$index]
    $expectedEvidence = $evidenceByPlatform[$expectedPlatform]
    $buildRecord = @($provenance.builds)[$index]
    Assert-ExactJsonFields `
      -Value $buildRecord `
      -Expected @('platform', 'architecture', 'simulated', 'toolVersions') `
      -Description "provenance build $expectedPlatform"
    Assert-ExactJsonFields `
      -Value $buildRecord.toolVersions `
      -Expected @('moonhostabi', 'moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime') `
      -Description "provenance build $expectedPlatform toolVersions"
    if (
      $buildRecord.platform -cne $expectedPlatform -or
      $buildRecord.architecture -cne 'x86_64' -or
      $buildRecord.simulated -isnot [bool] -or
      $buildRecord.simulated -ne $expectedEvidence.simulated
    ) {
      throw "provenance build '$expectedPlatform' identity mismatch."
    }
    foreach ($field in @(
      'moonhostabi', 'moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime'
    )) {
      if ($buildRecord.toolVersions.$field -cne $expectedEvidence.toolVersions.$field) {
        throw "provenance build '$expectedPlatform' tool version '$field' mismatch."
      }
    }

    $artifactRecord = @($provenance.artifacts)[$index]
    $expectedArtifactName = if ($expectedPlatform -ceq 'linux') {
      "moonhostabi-v$version-linux-x86_64.tar.gz"
    } else {
      "moonhostabi-v$version-windows-x86_64.zip"
    }
    $expectedArtifactPath = Join-Path $aggregateOutput $expectedArtifactName
    Assert-ExactJsonFields `
      -Value $artifactRecord `
      -Expected @('name', 'sha256', 'size') `
      -Description "provenance artifact $expectedPlatform"
    if (
      $artifactRecord.name -cne $expectedArtifactName -or
      $artifactRecord.sha256 -cne (Get-Sha256 -Path $expectedArtifactPath) -or
      $artifactRecord.size -isnot [Int64] -or
      $artifactRecord.size -ne (Get-Item -LiteralPath $expectedArtifactPath).Length
    ) {
      throw "provenance artifact '$expectedPlatform' identity/hash/size mismatch."
    }
  }
  foreach ($forbidden in @(
    $repositoryRoot,
    $repositoryRoot.Replace('\', '/'),
    $runRoot,
    $runRoot.Replace('\', '/'),
    [Environment]::UserName,
    '.codex'
  )) {
    if (
      -not [String]::IsNullOrWhiteSpace($forbidden) -and
      $provenanceText.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)
    ) {
      throw "provenance.json leaked forbidden content '$forbidden'."
    }
  }

  $negativeRoot = Join-Path $runRoot 'aggregate-negatives'
  [IO.Directory]::CreateDirectory($negativeRoot) | Out-Null
  $missingInput = Join-Path $negativeRoot 'missing-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $missingInput
  [IO.File]::Delete((Join-Path $missingInput $otherArchiveName))
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $missingInput `
    -OutputDirectory (Join-Path $negativeRoot 'missing-output') `
    -Description 'Missing archive'

  $extraInput = Join-Path $negativeRoot 'extra-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $extraInput
  [IO.File]::WriteAllText(
    (Join-Path $extraInput 'unexpected.txt'),
    'unexpected',
    [Text.UTF8Encoding]::new($false)
  )
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $extraInput `
    -OutputDirectory (Join-Path $negativeRoot 'extra-output') `
    -Description 'Extra artifact'

  $tamperedInput = Join-Path $negativeRoot 'tampered-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $tamperedInput
  $tamperedArchive = Join-Path $tamperedInput $archiveName
  $tamperedBytes = [IO.File]::ReadAllBytes($tamperedArchive)
  [IO.File]::WriteAllBytes($tamperedArchive, [byte[]]($tamperedBytes + 0))
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $tamperedInput `
    -OutputDirectory (Join-Path $negativeRoot 'tampered-output') `
    -Description 'Tampered archive'

  $tarTamperedInput = Join-Path $negativeRoot 'tar-trailing-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $tarTamperedInput
  $linuxArchiveName = if ($platform -ceq 'linux') { $archiveName } else { $otherArchiveName }
  $linuxArchive = Join-Path $tarTamperedInput $linuxArchiveName
  $linuxEvidence = Join-Path $tarTamperedInput 'linux.evidence.json'
  $linuxEvidenceTextBefore = [IO.File]::ReadAllText($linuxEvidence)
  $linuxHashBefore = Get-Sha256 -Path $linuxArchive
  $linuxSizeBefore = (Get-Item -LiteralPath $linuxArchive).Length
  $mutatedLinuxArchive = Join-Path $tarTamperedInput 'tar-trailing-mutated.tar.gz'
  $tarMutation = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'mutate-tar-trailing',
    '--archive', $linuxArchive,
    '--output', $mutatedLinuxArchive
  )
  if ($tarMutation.ExitCode -ne 0 -or $tarMutation.Stderr -cne '') {
    throw "Tar trailing mutation fixture failed: '$($tarMutation.Stderr)'."
  }
  $linuxHashAfter = Get-Sha256 -Path $mutatedLinuxArchive
  $linuxSizeAfter = (Get-Item -LiteralPath $mutatedLinuxArchive).Length
  [IO.File]::Delete($linuxArchive)
  [IO.File]::Move($mutatedLinuxArchive, $linuxArchive, $false)
  $linuxEvidenceTextAfter = $linuxEvidenceTextBefore.Replace(
    $linuxHashBefore,
    $linuxHashAfter
  ).Replace(
    '"size":' + $linuxSizeBefore.ToString([Globalization.CultureInfo]::InvariantCulture),
    '"size":' + $linuxSizeAfter.ToString([Globalization.CultureInfo]::InvariantCulture)
  )
  if ($linuxEvidenceTextAfter -cne $linuxEvidenceTextBefore) {
    [IO.File]::WriteAllText(
      $linuxEvidence,
      $linuxEvidenceTextAfter,
      [Text.UTF8Encoding]::new($false, $true)
    )
  } else {
    throw 'Tar trailing mutation could not update Linux evidence identity.'
  }
  $directTarMutation = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'validate',
    '--archive', $linuxArchive,
    '--platform', 'linux',
    '--version', $version
  )
  if ($directTarMutation.ExitCode -eq 0 -or [String]::IsNullOrWhiteSpace($directTarMutation.Stderr)) {
    throw 'Tar trailing nonzero bytes were accepted by the archive validator.'
  }
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $tarTamperedInput `
    -OutputDirectory (Join-Path $negativeRoot 'tar-trailing-output') `
    -Description 'Tar trailing nonzero bytes'

  $duplicateInput = Join-Path $negativeRoot 'duplicate-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $duplicateInput
  [IO.File]::WriteAllBytes(
    (Join-Path $duplicateInput 'linux.evidence.json'),
    [IO.File]::ReadAllBytes((Join-Path $duplicateInput 'windows.evidence.json'))
  )
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $duplicateInput `
    -OutputDirectory (Join-Path $negativeRoot 'duplicate-output') `
    -Description 'Duplicate platform evidence'

  $duplicateKeyInput = Join-Path $negativeRoot 'duplicate-key-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $duplicateKeyInput
  $duplicateKeyEvidence = Join-Path $duplicateKeyInput 'linux.evidence.json'
  $duplicateKeyText = [IO.File]::ReadAllText($duplicateKeyEvidence).Replace(
    '{"schemaVersion":1,',
    '{"schemaVersion":1,"schemaVersion":1,'
  )
  [IO.File]::WriteAllText(
    $duplicateKeyEvidence,
    $duplicateKeyText,
    [Text.UTF8Encoding]::new($false, $true)
  )
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $duplicateKeyInput `
    -OutputDirectory (Join-Path $negativeRoot 'duplicate-key-output') `
    -Description 'Duplicate JSON evidence key'

  $extraFieldInput = Join-Path $negativeRoot 'extra-field-input'
  Copy-FlatDirectory -Source $aggregateInput -Destination $extraFieldInput
  $extraFieldEvidence = Join-Path $extraFieldInput 'linux.evidence.json'
  $extraFieldText = [IO.File]::ReadAllText($extraFieldEvidence).Replace(
    '"archive":{"name":',
    '"archive":{"unexpected":true,"name":'
  )
  [IO.File]::WriteAllText(
    $extraFieldEvidence,
    $extraFieldText,
    [Text.UTF8Encoding]::new($false, $true)
  )
  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $extraFieldInput `
    -OutputDirectory (Join-Path $negativeRoot 'extra-field-output') `
    -Description 'Extra nested evidence field'

  Assert-AggregateFailure `
    -PowerShell $pwsh `
    -InputDirectory $aggregateInput `
    -OutputDirectory (Join-Path $negativeRoot 'production-simulated-output') `
    -Description 'Production simulated evidence' `
    -AllowSimulatedEvidence $false

  $aggregateBefore = Get-Sha256 -Path (Join-Path $aggregateOutput 'SHA256SUMS')
  $aggregateOverwrite = Invoke-Aggregate `
    -PowerShell $pwsh `
    -InputDirectory $aggregateInput `
    -OutputDirectory $aggregateOutput
  if (
    $aggregateOverwrite.ExitCode -eq 0 -or
    (Get-Sha256 -Path (Join-Path $aggregateOutput 'SHA256SUMS')) -cne $aggregateBefore
  ) {
    throw 'Aggregate no-overwrite contract failed.'
  }

  $versionParts = $version.Split('.')
  $versionMismatch = '{0}.{1}.{2}' -f `
    $versionParts[0],
    $versionParts[1],
    ([int]$versionParts[2] + 1)
  foreach ($case in @(
    @{ Version = '01.0.0'; Name = 'invalid-semver' },
    @{ Version = $versionMismatch; Name = 'version-mismatch' }
  )) {
    $negativeOutput = Join-Path $runRoot "package-$($case.Name)"
    [IO.Directory]::CreateDirectory($negativeOutput) | Out-Null
    $negativeEvidence = Join-Path $runRoot "$($case.Name).evidence.json"
    $negativeResult = Invoke-Package `
      -PowerShell $pwsh `
      -Version $case.Version `
      -Output $negativeOutput `
      -Evidence $negativeEvidence
    if (
      $negativeResult.ExitCode -eq 0 -or
      [String]::IsNullOrWhiteSpace($negativeResult.Stderr) -or
      -not [String]::IsNullOrEmpty($negativeResult.Stdout) -or
      @(Get-ChildItem -LiteralPath $negativeOutput -Force).Count -ne 0 -or
      (Test-Path -LiteralPath $negativeEvidence)
    ) {
      throw "Package negative '$($case.Name)' did not fail closed."
    }
  }

  $rollbackOutput = Join-Path $runRoot 'package-publish-rollback'
  [IO.Directory]::CreateDirectory($rollbackOutput) | Out-Null
  $rollbackEvidence = Join-Path $runRoot 'publish-rollback.evidence.json'
  $rollbackResult = Invoke-Package `
    -PowerShell $pwsh `
    -Version $version `
    -Output $rollbackOutput `
    -Evidence $rollbackEvidence `
    -Fault 'after-archive-publish'
  if (
    $rollbackResult.ExitCode -eq 0 -or
    $rollbackResult.Stderr -notmatch 'Injected release package failure' -or
    -not [String]::IsNullOrEmpty($rollbackResult.Stdout) -or
    @(Get-ChildItem -LiteralPath $rollbackOutput -Force).Count -ne 0 -or
    (Test-Path -LiteralPath $rollbackEvidence)
  ) {
    throw 'Release archive/evidence partial-publication rollback failed.'
  }

  $nonemptyOutput = Join-Path $runRoot 'package-nonempty'
  [IO.Directory]::CreateDirectory($nonemptyOutput) | Out-Null
  [IO.File]::WriteAllText((Join-Path $nonemptyOutput 'sentinel.txt'), 'preserve')
  $nonemptyEvidence = Join-Path $runRoot 'nonempty.evidence.json'
  $nonemptyResult = Invoke-Package `
    -PowerShell $pwsh `
    -Version $version `
    -Output $nonemptyOutput `
    -Evidence $nonemptyEvidence
  if (
    $nonemptyResult.ExitCode -eq 0 -or
    [String]::IsNullOrWhiteSpace($nonemptyResult.Stderr) -or
    -not [String]::IsNullOrEmpty($nonemptyResult.Stdout) -or
    [IO.File]::ReadAllText((Join-Path $nonemptyOutput 'sentinel.txt')) -cne 'preserve' -or
    @(Get-ChildItem -LiteralPath $nonemptyOutput -Force).Count -ne 1 -or
    (Test-Path -LiteralPath $nonemptyEvidence)
  ) {
    throw 'Nonempty package output was not rejected unchanged.'
  }

  $linkTarget = Join-Path $runRoot 'package-link-target'
  $linkPath = Join-Path $runRoot 'package-output-link'
  [IO.Directory]::CreateDirectory($linkTarget) | Out-Null
  $linkCreated = $false
  try {
    if ($IsWindows) {
      $null = New-Item -ItemType Junction -Path $linkPath -Target $linkTarget
    } else {
      $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $linkTarget
    }
    $linkCreated = $true
    $linkEvidence = Join-Path $runRoot 'link.evidence.json'
    $linkResult = Invoke-Package `
      -PowerShell $pwsh `
      -Version $version `
      -Output $linkPath `
      -Evidence $linkEvidence
    if (
      $linkResult.ExitCode -eq 0 -or
      $linkResult.Stderr -notmatch '(?i)(reparse point|symbolic link)' -or
      -not [String]::IsNullOrEmpty($linkResult.Stdout) -or
      @(Get-ChildItem -LiteralPath $linkTarget -Force).Count -ne 0 -or
      (Test-Path -LiteralPath $linkEvidence)
    ) {
      throw 'Linked package output was not rejected unchanged.'
    }
  }
  finally {
    if ($linkCreated) {
      Remove-DirectoryLink -Path $linkPath
    }
  }

  $packageSource = [IO.File]::ReadAllText(
    (Join-Path $repositoryRoot 'scripts/package-release.ps1')
  )
  foreach ($requiredLinuxContract in @(
    "'--sort=name'",
    "'--mtime=@0'",
    "'--owner=root'",
    "'--group=root'",
    "'--mode=u+rwX,go=rX'",
    "'--format=gnu'",
    "`$linuxGzipArguments = @('-n', '-9', `$tarPath)"
  )) {
    if (-not $packageSource.Contains($requiredLinuxContract, [StringComparison]::Ordinal)) {
      throw "Linux archive contract is missing '$requiredLinuxContract'."
    }
  }

  $archiveSelfTest = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/release_archive.py'),
    'self-test'
  )
  if ($archiveSelfTest.ExitCode -ne 0 -or $archiveSelfTest.Stderr -cne '') {
    throw "Release archive security self-test failed: '$($archiveSelfTest.Stderr)'."
  }

  $workflowValidation = Invoke-CapturedProcess -FilePath $python -Arguments @(
    (Join-Path $repositoryRoot 'scripts/validate_workflows.py'),
    '--repository', $repositoryRoot,
    '--self-test'
  )
  if ($workflowValidation.ExitCode -ne 0 -or $workflowValidation.Stderr -cne '') {
    throw "Workflow validation failed. exit=$($workflowValidation.ExitCode) stderr='$($workflowValidation.Stderr)'"
  }

  $stagingLeaks = @(
    Get-ChildItem -LiteralPath $runRoot -Force -Recurse |
      Where-Object {
        $_.Name -match '^\.moonhostabi-(?:release-stage|evidence-stage|release-aggregate-stage)-'
      }
  )
  if ($stagingLeaks.Count -ne 0) {
    throw "Release verification left staging paths: $($stagingLeaks.FullName -join ', ')."
  }

  Write-Output "MOONHOSTABI_PACKAGE_PLATFORM=$platform"
  Write-Output "MOONHOSTABI_PACKAGE_ARCHIVE=$archiveName"
  Write-Output "MOONHOSTABI_PACKAGE_SHA256=$hashA"
  Write-Output "MOONHOSTABI_PACKAGE_EXPECTED_FILES=$($expectedFiles -join ',')"
  Write-Output 'MOONHOSTABI_PACKAGE_UNPACKED_SMOKE=GO'
  Write-Output 'MOONHOSTABI_RELEASE_AGGREGATE=GO'
  Write-Output 'MOONHOSTABI_RELEASE_WORKFLOWS=GO'
  Write-Output 'MOONHOSTABI_PACKAGE_STATUS=GO'
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
  if (Test-Path -LiteralPath $runRoot) {
    try {
      Assert-ExactRunRoot
      Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  $releaseWorkLeaks = @(
    [IO.Directory]::GetDirectories(
      $hostTempRoot,
      "$releaseWorkPrefix*",
      [IO.SearchOption]::TopDirectoryOnly
    )
  )
  foreach ($leak in $releaseWorkLeaks) {
    try {
      $fullLeak = [IO.Path]::GetFullPath($leak)
      if (
        -not [String]::Equals(
          [IO.Path]::GetDirectoryName($fullLeak),
          [IO.Path]::GetFullPath($hostTempRoot),
          $pathComparison
        ) -or
        [IO.Path]::GetFileName($fullLeak) -cnotmatch
          ('^' + [regex]::Escape($releaseWorkPrefix) + '[0-9a-f]{32}$')
      ) {
        throw "Unexpected correlated release work path '$fullLeak'."
      }
      $item = Get-Item -LiteralPath $fullLeak -Force
      if (
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        -not [String]::IsNullOrEmpty($item.LinkType)
      ) {
        throw "Refusing to clean linked release work path '$fullLeak'."
      }
      Remove-Item -LiteralPath $fullLeak -Recurse -Force
      [void]$cleanupErrors.Add("Package work root leaked and was removed: '$fullLeak'.")
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if ($cleanupErrors.Count -ne 0) {
    throw "Release packaging verifier cleanup failed: $($cleanupErrors -join '; ')"
  }
}
