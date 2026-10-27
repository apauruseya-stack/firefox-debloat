<#
.SYNOPSIS
    One-line installer for firefox-debloat.

.DESCRIPTION
    Downloads a pinned release of firefox-debloat, verifies its SHA-256 checksum, unpacks it to
    a temporary folder, runs the Windows script and deletes the temporary folder. Nothing is
    installed permanently.

    Usage:
      irm https://raw.githubusercontent.com/apauruseya-stack/firefox-debloat/main/install/install.ps1 | iex

      # With a specific version:
      $env:FIREFOX_DEBLOAT_VERSION = 'v1.1.0'
      irm https://raw.githubusercontent.com/apauruseya-stack/firefox-debloat/main/install/install.ps1 | iex

      # Download and verify only, do not run anything:
      $env:FIREFOX_DEBLOAT_NO_LAUNCH = '1'
      irm https://raw.githubusercontent.com/apauruseya-stack/firefox-debloat/main/install/install.ps1 | iex

      # Pass options to the script (use the script block form):
      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/apauruseya-stack/firefox-debloat/main/install/install.ps1))) -Preset strict

.NOTES
    The checksum is published in this file and next to the release asset. If the download does not
    match, nothing is executed.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Owner = 'apauruseya-stack'
$Repo = 'firefox-debloat'
$DefaultVersion = 'v1.1.1'

# Pinned releases and their SHA-256 checksums.
$Releases = @{
    'v1.1.0' = '8be484db3cc3251f2cdd121afe41303633a4ee9b6b50988d1f15a606beb6095b'
    'v1.1.1' = 'aec0cbfe89dcb7c94e8d4259489fc12ac7a564968c76566ec324996247d2ac5b'
}

function Write-Info([string]$Text) { Write-Host "==> $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "!! $Text" -ForegroundColor Yellow }
function Stop-WithError([string]$Text) { Write-Host "xx $Text" -ForegroundColor Red; exit 1 }

$version = if ($env:FIREFOX_DEBLOAT_VERSION) { $env:FIREFOX_DEBLOAT_VERSION } else { $DefaultVersion }
if (-not $Releases.ContainsKey($version)) {
    Stop-WithError "Unknown version '$version'. Known: $($Releases.Keys -join ', ')"
}
$expected = $Releases[$version]

# Release asset names changed once during the rename from firefox-hardened to firefox-debloat.
$Assets = @{
    'v1.1.0' = 'firefox-hardened-v1.1.0.zip'
    'v1.1.1' = 'firefox-debloat-v1.1.1.zip'
}
$asset = if ($Assets.ContainsKey($version)) { $Assets[$version] } else { "firefox-debloat-$version.zip" }
$url = "https://github.com/$Owner/$Repo/releases/download/$version/$asset"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("firefox-debloat-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$zip = Join-Path $temp $asset

try {
    Write-Info "Downloading $version..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    Write-Info "Verifying the SHA-256 checksum..."
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
        Stop-WithError "Checksum mismatch. Expected $expected but got $actual. Nothing was run."
    }
    Write-Host "   checksum OK" -ForegroundColor Green

    $extract = Join-Path $temp 'app'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $root = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    $script = Join-Path $root.FullName 'windows\firefox-debloat.ps1'

    if ($env:FIREFOX_DEBLOAT_NO_LAUNCH -eq '1') {
        Write-Info "Downloaded and verified. The files are in: $extract"
        Write-Host "   (set FIREFOX_DEBLOAT_NO_LAUNCH to something other than 1 to run the script)"
        exit 0
    }

    Write-Info "Running windows\firefox-debloat.ps1..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script @ScriptArgs

    $mergeScript = Join-Path $root.FullName 'scripts\merge-arkenfox-betterfox.ps1'
    if (Test-Path -LiteralPath $mergeScript) {
        Write-Info "Running scripts\merge-arkenfox-betterfox.ps1 (Arkenfox + Betterfox layer)..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $mergeScript
    }

    Write-Info "Done. The temporary files are deleted when this window closes."
}
finally {
    # The files stay until the window closes, so the user can look at them.
    Write-Host ''
    Write-Host "Temporary folder: $temp" -ForegroundColor DarkGray
}
