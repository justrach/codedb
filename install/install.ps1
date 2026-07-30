[CmdletBinding()]
param(
  [string]$Version = $env:CODEDB_VERSION,
  [string]$InstallDir = $env:CODEDB_DIR,
  [switch]$NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = "justrach/codedb"
$assetName = "codedb-windows-x86_64.exe"
$baseUrl = if ($env:CODEDB_URL) { $env:CODEDB_URL.TrimEnd("/") } else { "https://codedb.codegraff.com" }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw "This installer is for native Windows. Use install.sh on macOS or Linux."
}

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($architecture -ne "X64") {
  throw "Unsupported Windows architecture: $architecture (x86_64 is required)"
}

if (-not $InstallDir) {
  $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\codedb"
}
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if ($env:CODEDB_NO_PATH) {
  $NoPath = $true
}

# Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
  # TLS 1.2 is already enabled.
} else {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

if (-not $Version) {
  try {
    $release = Invoke-RestMethod `
      -Headers @{ "User-Agent" = "codedb-installer" } `
      "https://api.github.com/repos/$repo/releases/latest"
    $Version = $release.tag_name
  } catch {
    $latest = Invoke-RestMethod `
      -Headers @{ "User-Agent" = "codedb-installer" } `
      "$baseUrl/latest.json"
    $Version = $latest.version
  }
}
$Version = $Version.TrimStart("v", "V")
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
  throw "Invalid codedb version: $Version"
}

$releaseUrl = "https://github.com/$repo/releases/download/v$Version"
$downloadDir = Join-Path ([IO.Path]::GetTempPath()) ("codedb-install-" + [guid]::NewGuid().ToString("N"))
$targetPath = Join-Path $InstallDir "codedb.exe"
$stagedPath = Join-Path $InstallDir ("codedb.exe.new." + $PID)
$previousPath = $null

try {
  New-Item -ItemType Directory -Force -Path $downloadDir, $InstallDir | Out-Null
  Get-ChildItem -LiteralPath $InstallDir -Filter "codedb.exe.old.*" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

  $downloadedBinary = Join-Path $downloadDir $assetName
  $downloadedChecksums = Join-Path $downloadDir "checksums.sha256"

  Write-Host "codedb installer"
  Write-Host "  version   v$Version"
  Write-Host "  install   $InstallDir"
  Write-Host "  download  $assetName"

  Invoke-WebRequest -UseBasicParsing `
    -Headers @{ "User-Agent" = "codedb-installer" } `
    "$releaseUrl/$assetName" `
    -OutFile $downloadedBinary
  Invoke-WebRequest -UseBasicParsing `
    -Headers @{ "User-Agent" = "codedb-installer" } `
    "$releaseUrl/checksums.sha256" `
    -OutFile $downloadedChecksums

  $checksumLine = Get-Content -LiteralPath $downloadedChecksums |
    Where-Object { $_ -match "\s\*?$([regex]::Escape($assetName))$" } |
    Select-Object -First 1
  if (-not $checksumLine) {
    throw "Release v$Version has no checksum for $assetName"
  }

  $expectedHash = ($checksumLine -split '\s+')[0]
  if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Release v$Version contains an invalid checksum for $assetName"
  }

  $actualHash = (Get-FileHash -LiteralPath $downloadedBinary -Algorithm SHA256).Hash
  if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
    throw "SHA256 mismatch for $assetName"
  }
  Write-Host "  verify    SHA256 OK"

  Copy-Item -LiteralPath $downloadedBinary -Destination $stagedPath -Force
  Unblock-File -LiteralPath $stagedPath -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    $previousPath = Join-Path $InstallDir ("codedb.exe.old." + [guid]::NewGuid().ToString("N"))
    Move-Item -LiteralPath $targetPath -Destination $previousPath
  }
  try {
    Move-Item -LiteralPath $stagedPath -Destination $targetPath -Force
    & $targetPath --version
    if ($LASTEXITCODE -ne 0) {
      throw "Installed codedb failed its version check"
    }
  } catch {
    Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    if ($previousPath -and
        (Test-Path -LiteralPath $previousPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $targetPath)) {
      Move-Item -LiteralPath $previousPath -Destination $targetPath
      $previousPath = $null
    }
    throw
  }
  if ($previousPath) {
    Remove-Item -LiteralPath $previousPath -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $previousPath)) {
      $previousPath = $null
    }
  }

  if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathEntries = @($userPath -split ';' | Where-Object { $_ })
    $alreadyOnPath = $false
    foreach ($entry in $pathEntries) {
      if ($entry.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")) {
        $alreadyOnPath = $true
        break
      }
    }
    if (-not $alreadyOnPath) {
      $newUserPath = if ($userPath) {
        $userPath.TrimEnd(';') + ';' + $InstallDir
      } else {
        $InstallDir
      }
      [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
      Write-Host "  PATH      added for future terminals"
    }
  }

  if (-not (($env:PATH -split ';') | Where-Object { $_.TrimEnd("\") -ieq $InstallDir.TrimEnd("\") })) {
    $env:PATH = "$InstallDir;$env:PATH"
  }

  Write-Host ""
  Write-Host "Installed: $targetPath"
  Write-Host "MCP command: $targetPath mcp"
} finally {
  Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
