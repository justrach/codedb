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
$releasePublicKey = if ($env:CODEDB_RELEASE_PUBKEY) { $env:CODEDB_RELEASE_PUBKEY } else { "1aaec9bc8ba799a3dc0129e3fde949567bc8493b9534aa60f0bf1a32cc921f20" }
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
  $downloadedChecksumsSig = Join-Path $downloadDir "checksums.sha256.sig"
  Invoke-WebRequest -UseBasicParsing `
    -Headers @{ "User-Agent" = "codedb-installer" } `
    "$releaseUrl/checksums.sha256.sig" `
    -OutFile $downloadedChecksumsSig

  $python = Get-Command python3 -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $python) {
    throw "python3 is required to verify the Ed25519 release signature"
  }
  $verifyScript = Join-Path $PSScriptRoot "..\scripts\ed25519_pure.py"
  if (-not (Test-Path -LiteralPath $verifyScript)) {
    $verifyScript = Join-Path $PSScriptRoot "ed25519_pure.py"
  }
  if (Test-Path -LiteralPath $verifyScript) {
    & $python.Source $verifyScript verify $releasePublicKey $downloadedChecksums $downloadedChecksumsSig
    if ($LASTEXITCODE -ne 0) {
      throw "Release signature verification failed"
    }
  } else {
    $inline = @'
import hashlib, sys
b=256; q=2**255-19; l=2**252+27742317777372353535851937790883648493
def inv(x): return pow(x,q-2,q)
d=-121665*inv(121666)%q; I=pow(2,(q-1)//4,q)
def xrecover(y):
    xx=(y*y-1)*inv(d*y*y+1); x=pow(xx,(q+3)//8,q)
    if (x*x-xx)%q!=0: x=(x*I)%q
    if x%2: x=q-x
    return x
By=4*inv(5); Bx=xrecover(By); B=(Bx%q,By%q,1,(Bx*By)%q)
def add(p1,p2):
    x1,y1,z1,t1=p1; x2,y2,z2,t2=p2
    a=(y1-x1)*(y2-x2)%q; bb=(y1+x1)*(y2+x2)%q; c=t1*2*d*t2%q; dd=z1*2*z2%q
    e,f,g,h=bb-a,dd-c,dd+c,bb+a
    return (e*f%q,g*h%q,f*g%q,e*h%q)
def smul(p1,s):
    q1=(0,1,1,0)
    while s:
        if s&1: q1=add(q1,p1)
        p1=add(p1,p1); s>>=1
    return q1
def enc(p1):
    x,y,z,_=p1; zi=inv(z); x,y=(x*zi)%q,(y*zi)%q
    bits=bytearray(y.to_bytes(32,"little")); bits[31]^=(x&1)<<7; return bytes(bits)
def oncurve(p1):
    x,y,z,t=p1
    return z%q!=0 and (x*y-z*t)%q==0 and (y*y-x*x-z*z-d*t*t)%q==0
def dec(s):
    y=int.from_bytes(s,"little")&((1<<255)-1); x=xrecover(y)
    if (x&1)!=(s[31]>>7): x=q-x
    p1=(x,y,1,x*y%q)
    if not oncurve(p1): raise ValueError("invalid point")
    return p1
pk=bytes.fromhex(sys.argv[1]); msg=open(sys.argv[2],"rb").read(); sig=open(sys.argv[3],"rb").read()
if len(sig)==128:
    sig=bytes.fromhex(sig.decode().strip())
if len(sig)!=64 or len(pk)!=32: sys.exit(1)
r=dec(sig[:32]); a=dec(pk); s=int.from_bytes(sig[32:],"little")
if s>=l: sys.exit(1)
h=int.from_bytes(hashlib.sha512(sig[:32]+pk+msg).digest(),"little")
sys.exit(0 if enc(smul(B,s))==enc(add(smul(a,h),r)) else 1)
'@
    $inlinePath = Join-Path $downloadDir "verify.py"
    Set-Content -LiteralPath $inlinePath -Value $inline -Encoding ascii
    & $python.Source $inlinePath $releasePublicKey $downloadedChecksums $downloadedChecksumsSig
    if ($LASTEXITCODE -ne 0) {
      throw "Release signature verification failed"
    }
  }
  Write-Host "  verify    Ed25519 signature OK"

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
    # HKCU\Environment\Path is REG_EXPAND_SZ by default and normally holds
    # %USERPROFILE%-style references. [Environment]::GetEnvironmentVariable
    # expands those, and SetEnvironmentVariable writes the result back as
    # REG_SZ — permanently flattening the user's PATH and downgrading its
    # value kind on every install/update. Read and write the registry
    # directly instead, preserving both the unexpanded text and the kind.
    $envKey = "HKCU:\Environment"
    $rawUserPath = ""
    $pathKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try {
      $envItem = Get-Item -LiteralPath $envKey -ErrorAction Stop
      $rawUserPath = [string]$envItem.GetValue(
        "Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      try {
        $existingKind = $envItem.GetValueKind("Path")
        if ($existingKind -eq [Microsoft.Win32.RegistryValueKind]::String) {
          $pathKind = [Microsoft.Win32.RegistryValueKind]::String
        }
      } catch {
        # No user Path value yet — create it as REG_EXPAND_SZ.
      }
    } catch {
      $rawUserPath = [string][Environment]::GetEnvironmentVariable("Path", "User")
    }

    $pathEntries = @($rawUserPath -split ';' | Where-Object { $_ })
    $alreadyOnPath = $false
    foreach ($entry in $pathEntries) {
      $expanded = [Environment]::ExpandEnvironmentVariables($entry)
      if ($expanded.TrimEnd("\") -ieq $InstallDir.TrimEnd("\")) {
        $alreadyOnPath = $true
        break
      }
    }
    if (-not $alreadyOnPath) {
      $newUserPath = if ($rawUserPath) {
        $rawUserPath.TrimEnd(';') + ';' + $InstallDir
      } else {
        $InstallDir
      }
      Set-ItemProperty -LiteralPath $envKey -Name "Path" -Value $newUserPath -Type $pathKind
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
