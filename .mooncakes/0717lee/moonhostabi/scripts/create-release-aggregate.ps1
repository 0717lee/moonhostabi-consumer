[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Version,
  [Parameter(Mandatory)] [Alias('Input')] [string] $InputDirectory,
  [Parameter(Mandatory)] [Alias('OutputDirectory')] [string] $Output,
  [switch] $AllowSimulatedEvidence,
  [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
  throw 'Version must be strict MAJOR.MINOR.PATCH without leading zeroes.'
}
if ([String]::IsNullOrWhiteSpace($RepositoryRoot)) {
  $RepositoryRoot = Join-Path $PSScriptRoot '..'
}
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$inputRoot = [IO.Path]::GetFullPath($InputDirectory)
$outputRoot = [IO.Path]::GetFullPath($Output)
$outputParent = [IO.Path]::GetDirectoryName($outputRoot)
$stageLeaf = '.moonhostabi-release-aggregate-stage-' + [Guid]::NewGuid().ToString('N')
$stageRoot = [IO.Path]::GetFullPath((Join-Path $outputParent $stageLeaf))
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

function Assert-OutputAbsent {
  $parent = Get-StrictDirectory -Path $script:outputParent -Description 'Aggregate output parent'
  $leaf = [IO.Path]::GetFileName($script:outputRoot)
  $matches = @(
    Get-ChildItem -LiteralPath $parent -Force |
      Where-Object { [String]::Equals($_.Name, $leaf, $script:pathComparison) }
  )
  if ($matches.Count -ne 0) {
    throw "Aggregate output already exists; refusing overwrite: '$script:outputRoot'."
  }
}

function Assert-ExactStageRoot {
  $item = Get-Item -LiteralPath $script:stageRoot -Force -ErrorAction SilentlyContinue
  if ($null -ne $item -and (Test-IsLinkOrReparsePoint -Item $item)) {
    throw 'Refusing a linked aggregate staging root.'
  }
  if (
    -not [String]::Equals(
      [IO.Path]::GetDirectoryName($script:stageRoot),
      [IO.Path]::GetFullPath($script:outputParent),
      $script:pathComparison
    ) -or
    [IO.Path]::GetFileName($script:stageRoot) -cne $script:stageLeaf -or
    $script:stageLeaf -cnotmatch '^\.moonhostabi-release-aggregate-stage-[0-9a-f]{32}$'
  ) {
    throw "Refusing unexpected aggregate staging root '$script:stageRoot'."
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

function Get-Sha256 {
  param([Parameter(Mandatory)] [string] $Path)

  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-JsonString {
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

  ConvertTo-Json -InputObject $Value -Compress
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

function Read-Evidence {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Platform,
    [Parameter(Mandatory)] [string] $ArchiveName
  )

  $evidencePath = Get-StrictFile -Path $Path -Description "$Platform evidence"
  $bytes = [IO.File]::ReadAllBytes($evidencePath)
  if (
    $bytes.Length -ge 3 -and
    $bytes[0] -eq 0xef -and
    $bytes[1] -eq 0xbb -and
    $bytes[2] -eq 0xbf
  ) {
    throw "$Platform evidence contains a UTF-8 BOM."
  }
  $text = $script:utf8NoBom.GetString($bytes)
  if (
    $text.Contains("`r") -or
    -not $text.EndsWith("`n", [StringComparison]::Ordinal) -or
    ($text -split "`n").Count -ne 2
  ) {
    throw "$Platform evidence must be one canonical JSON line followed by LF."
  }
  Assert-UniqueJsonKeys -Text $text -Description "$Platform evidence"
  $evidence = $text | ConvertFrom-Json -ErrorAction Stop
  $expectedFields = @(
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
  )
  Assert-ExactJsonFields `
    -Value $evidence `
    -Expected $expectedFields `
    -Description "$Platform evidence"
  Assert-ExactJsonFields `
    -Value $evidence.archive `
    -Expected @('name', 'sha256', 'size') `
    -Description "$Platform evidence archive"
  Assert-ExactJsonFields `
    -Value $evidence.smoke `
    -Expected @('version', 'help', 'verify') `
    -Description "$Platform evidence smoke"
  if (
    $evidence.schemaVersion -isnot [Int64] -or
    $evidence.schemaVersion -ne 1 -or
    $evidence.releaseVersion -isnot [string] -or
    $evidence.releaseVersion -cne $Version -or
    $evidence.platform -isnot [string] -or
    $evidence.platform -cne $Platform -or
    $evidence.architecture -isnot [string] -or
    $evidence.architecture -cne 'x86_64' -or
    $evidence.simulated -isnot [bool] -or
    $evidence.sourceCommit -isnot [string] -or
    $evidence.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $evidence.sourceTreeClean -isnot [bool] -or
    $evidence.archive.name -isnot [string] -or
    $evidence.archive.name -cne $ArchiveName -or
    $evidence.archive.sha256 -isnot [string] -or
    $evidence.archive.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $evidence.archive.size -isnot [Int64] -or
    [Int64]$evidence.archive.size -lt 1
  ) {
    throw "$Platform evidence identity is invalid."
  }
  foreach ($field in @('version', 'help', 'verify')) {
    if ($evidence.smoke.$field -isnot [bool]) {
      throw "$Platform evidence smoke '$field' must be boolean."
    }
  }
  if ($evidence.simulated) {
    if (-not $AllowSimulatedEvidence) {
      throw "$Platform evidence is simulated, which production aggregation forbids."
    }
    if (
      $evidence.smoke.version -ne $false -or
      $evidence.smoke.help -ne $false -or
      $evidence.smoke.verify -ne $false
    ) {
      throw "$Platform simulated evidence claims executable smoke results."
    }
  } elseif (
    $evidence.smoke.version -ne $true -or
    $evidence.smoke.help -ne $true -or
    $evidence.smoke.verify -ne $true
  ) {
    throw "$Platform real evidence lacks unpacked smoke results."
  }
  $expectedToolFields = @(
    'moonhostabi', 'moon', 'moonc', 'moonrun', 'powershell', 'dotnetRuntime'
  )
  Assert-ExactJsonFields `
    -Value $evidence.toolVersions `
    -Expected $expectedToolFields `
    -Description "$Platform evidence toolVersions"
  if ($evidence.toolVersions.moonhostabi -cne $Version) {
    throw "$Platform evidence tool versions are invalid."
  }
  foreach ($field in $expectedToolFields) {
    if (
      $evidence.toolVersions.$field -isnot [string] -or
      [String]::IsNullOrWhiteSpace($evidence.toolVersions.$field)
    ) {
      throw "$Platform evidence tool version '$field' is empty."
    }
  }
  $evidence
}

function ToolVersionsJson {
  param([Parameter(Mandatory)] $Evidence)

  '{"moonhostabi":' +
    (ConvertTo-JsonString $Evidence.toolVersions.moonhostabi) +
    ',"moon":' +
    (ConvertTo-JsonString $Evidence.toolVersions.moon) +
    ',"moonc":' +
    (ConvertTo-JsonString $Evidence.toolVersions.moonc) +
    ',"moonrun":' +
    (ConvertTo-JsonString $Evidence.toolVersions.moonrun) +
    ',"powershell":' +
    (ConvertTo-JsonString $Evidence.toolVersions.powershell) +
    ',"dotnetRuntime":' +
    (ConvertTo-JsonString $Evidence.toolVersions.dotnetRuntime) +
    '}'
}

function ArtifactJson {
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Hash,
    [Parameter(Mandatory)] [Int64] $Size
  )

  '{"name":' +
    (ConvertTo-JsonString $Name) +
    ',"sha256":' +
    (ConvertTo-JsonString $Hash) +
    ',"size":' +
    $Size.ToString([Globalization.CultureInfo]::InvariantCulture) +
    '}'
}

try {
  if (
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
    [Runtime.InteropServices.Architecture]::X64
  ) {
    throw 'Release aggregation requires an x86_64 host architecture.'
  }
  $repositoryRoot = Get-StrictDirectory -Path $repositoryRoot -Description 'Repository root'
  $inputRoot = Get-StrictDirectory -Path $inputRoot -Description 'Aggregate input'
  $outputParent = Get-StrictDirectory -Path $outputParent -Description 'Aggregate output parent'
  Assert-OutputAbsent
  Assert-ExactStageRoot

  $moduleLines = @(
    [IO.File]::ReadAllLines((Join-Path $repositoryRoot 'moon.mod')) |
      Where-Object { $_ -match '^\s*version\b' }
  )
  if (
    $moduleLines.Count -ne 1 -or
    $moduleLines[0] -cnotmatch '^version = "((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"$' -or
    $Matches[1] -cne $Version
  ) {
    throw 'Aggregate version does not match the strict moon.mod version.'
  }

  $platforms = @('linux', 'windows')
  $archiveNames = [ordered]@{
    linux = "moonhostabi-v$Version-linux-x86_64.tar.gz"
    windows = "moonhostabi-v$Version-windows-x86_64.zip"
  }
  $expectedInputs = [string[]]@(
    $archiveNames.linux,
    'linux.evidence.json',
    $archiveNames.windows,
    'windows.evidence.json'
  )
  [Array]::Sort($expectedInputs, [StringComparer]::Ordinal)
  $actualInputs = [string[]]@(
    Get-ChildItem -LiteralPath $inputRoot -Force |
      ForEach-Object Name
  )
  [Array]::Sort($actualInputs, [StringComparer]::Ordinal)
  if ([String]::Join("`n", $actualInputs) -cne [String]::Join("`n", $expectedInputs)) {
    throw "Aggregate input set is not exact: $($actualInputs -join ', ')."
  }

  $python = @(Get-Command python -CommandType Application -ErrorAction Stop)[0].Source
  $evidenceByPlatform = @{}
  $hashByPlatform = @{}
  $sizeByPlatform = @{}
  $simulatedCount = 0
  foreach ($platform in $platforms) {
    $archiveName = $archiveNames[$platform]
    $archivePath = Get-StrictFile `
      -Path (Join-Path $inputRoot $archiveName) `
      -Description "$platform release archive"
    $evidencePath = Join-Path $inputRoot "$platform.evidence.json"
    $evidence = Read-Evidence `
      -Path $evidencePath `
      -Platform $platform `
      -ArchiveName $archiveName
    if ($evidence.simulated) {
      $simulatedCount += 1
    }
    $hash = Get-Sha256 -Path $archivePath
    $size = (Get-Item -LiteralPath $archivePath).Length
    if ($hash -cne $evidence.archive.sha256 -or $size -ne [Int64]$evidence.archive.size) {
      throw "$platform archive hash/size does not match its evidence."
    }
    $archiveArguments = @(
      (Join-Path $repositoryRoot 'scripts/release_archive.py'),
      'validate',
      '--archive', $archivePath,
      '--platform', $platform,
      '--version', $Version
    )
    if ($evidence.simulated -and $platform -ceq 'windows') {
      $archiveArguments += '--allow-simulated-metadata'
    }
    $archiveValidation = Invoke-CapturedProcess `
      -FilePath $python `
      -Arguments $archiveArguments
    if ($archiveValidation.ExitCode -ne 0 -or $archiveValidation.Stderr -cne '') {
      throw "$platform archive layout validation failed: '$($archiveValidation.Stderr)'."
    }
    $evidenceByPlatform[$platform] = $evidence
    $hashByPlatform[$platform] = $hash
    $sizeByPlatform[$platform] = $size
  }
  if ($AllowSimulatedEvidence) {
    if ($simulatedCount -ne 1) {
      throw 'Test aggregation requires exactly one simulated platform evidence file.'
    }
  } elseif ($simulatedCount -ne 0) {
    throw 'Production aggregation forbids simulated evidence.'
  }
  if (
    $evidenceByPlatform.linux.sourceCommit -cne
      $evidenceByPlatform.windows.sourceCommit -or
    $evidenceByPlatform.linux.sourceTreeClean -ne
      $evidenceByPlatform.windows.sourceTreeClean
  ) {
    throw 'Platform evidence does not describe one source commit/tree state.'
  }

  [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
  Assert-ExactStageRoot
  foreach ($platform in $platforms) {
    $name = $archiveNames[$platform]
    [IO.File]::WriteAllBytes(
      (Join-Path $stageRoot $name),
      [IO.File]::ReadAllBytes((Join-Path $inputRoot $name))
    )
  }
  $sums = @(
    "$(Get-Sha256 -Path (Join-Path $stageRoot $archiveNames.linux))  $($archiveNames.linux)",
    "$(Get-Sha256 -Path (Join-Path $stageRoot $archiveNames.windows))  $($archiveNames.windows)"
  ) -join "`n"
  [IO.File]::WriteAllText(
    (Join-Path $stageRoot 'SHA256SUMS'),
    $sums + "`n",
    $utf8NoBom
  )

  $linuxEvidence = $evidenceByPlatform.linux
  $windowsEvidence = $evidenceByPlatform.windows
  $provenance = '{"schemaVersion":1,"releaseVersion":' +
    (ConvertTo-JsonString $Version) +
    ',"sourceCommit":' +
    (ConvertTo-JsonString $linuxEvidence.sourceCommit) +
    ',"sourceTreeClean":' +
    $(if ($linuxEvidence.sourceTreeClean) { 'true' } else { 'false' }) +
    ',"builds":[{"platform":"linux","architecture":"x86_64","simulated":' +
    $(if ($linuxEvidence.simulated) { 'true' } else { 'false' }) +
    ',"toolVersions":' +
    (ToolVersionsJson $linuxEvidence) +
    '},{"platform":"windows","architecture":"x86_64","simulated":' +
    $(if ($windowsEvidence.simulated) { 'true' } else { 'false' }) +
    ',"toolVersions":' +
    (ToolVersionsJson $windowsEvidence) +
    '}],"artifacts":[' +
    (ArtifactJson $archiveNames.linux $hashByPlatform.linux $sizeByPlatform.linux) +
    ',' +
    (ArtifactJson $archiveNames.windows $hashByPlatform.windows $sizeByPlatform.windows) +
    ']}' +
    "`n"
  [IO.File]::WriteAllText(
    (Join-Path $stageRoot 'provenance.json'),
    $provenance,
    $utf8NoBom
  )
  $outputNames = [string[]]@(
    Get-ChildItem -LiteralPath $stageRoot -Force |
      ForEach-Object Name
  )
  [Array]::Sort($outputNames, [StringComparer]::Ordinal)
  $expectedOutputs = [string[]]@(
    $archiveNames.linux,
    $archiveNames.windows,
    'SHA256SUMS',
    'provenance.json'
  )
  [Array]::Sort($expectedOutputs, [StringComparer]::Ordinal)
  if ([String]::Join("`n", $outputNames) -cne [String]::Join("`n", $expectedOutputs)) {
    throw 'Aggregate staging output set is not exact.'
  }
  $decodedProvenance = $provenance | ConvertFrom-Json -ErrorAction Stop
  if (
    $decodedProvenance.schemaVersion -ne 1 -or
    @($decodedProvenance.artifacts).Count -ne 2 -or
    @($decodedProvenance.builds).Count -ne 2
  ) {
    throw 'Generated provenance failed its own schema check.'
  }

  Assert-OutputAbsent
  [IO.Directory]::Move($stageRoot, $outputRoot)
  Write-Output "MOONHOSTABI_RELEASE_LINUX_SHA256=$($hashByPlatform.linux)"
  Write-Output "MOONHOSTABI_RELEASE_WINDOWS_SHA256=$($hashByPlatform.windows)"
  Write-Output 'MOONHOSTABI_RELEASE_AGGREGATE_STATUS=CREATED'
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
  if (Test-Path -LiteralPath $stageRoot) {
    try {
      Assert-ExactStageRoot
      Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    catch {
      [void]$cleanupErrors.Add($_.Exception.Message)
    }
  }
  if ($cleanupErrors.Count -ne 0) {
    throw "Release aggregate cleanup failed: $($cleanupErrors -join '; ')"
  }
}
