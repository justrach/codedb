param(
    [Parameter(Mandatory = $true)]
    [string]$Binary,

    [string]$LegacyBinary = ""
)

$ErrorActionPreference = "Stop"
$root = Join-Path $env:TEMP ("codedb-windows-smoke-" + [guid]::NewGuid().ToString("N"))
$fresh = Join-Path $root "fresh"
$legacy = Join-Path $root "legacy"

function Invoke-CodeDB {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "codedb exited with $LASTEXITCODE`: $Executable $($Arguments -join ' ')"
    }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $fresh "src") | Out-Null
    Set-Content -NoNewline -Path (Join-Path $fresh "src/main.zig") -Value "pub fn greet() void {}"

    Invoke-CodeDB $Binary "--version"
    Invoke-CodeDB $Binary "--help"
    Invoke-CodeDB $Binary $fresh "reindex"
    Invoke-CodeDB $Binary $fresh "context" "--local" "find" "greet"

    if ($LegacyBinary) {
        New-Item -ItemType Directory -Force -Path (Join-Path $legacy "src") | Out-Null
        Set-Content -NoNewline -Path (Join-Path $legacy "src/main.zig") -Value "pub fn legacy_greet() void {}"
        Invoke-CodeDB $LegacyBinary $legacy "index"
        Invoke-CodeDB $Binary $legacy "status"
        Invoke-CodeDB $Binary $legacy "context" "--local" "find" "legacy_greet"
        Invoke-CodeDB $Binary $legacy "reindex"
    }

    Write-Host "Windows runtime smoke passed"
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $root
}
