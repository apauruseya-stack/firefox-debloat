<#
.SYNOPSIS
    Layers Arkenfox (privacy) + Betterfox (performance/annoyances) onto a Firefox profile,
    preserving any firefox-debloat managed block.

.DESCRIPTION
    Downloads the latest Arkenfox user.js and Betterfox user.js, concatenates them (Arkenfox
    first, Betterfox second), then re-appends the firefox-debloat managed block so that the
    debloat prefs keep winning. Writes the result to the profile's user.js (backing up the
    previous file first).

    Run AFTER firefox-debloat has been applied at least once, so the managed block exists.

.PARAMETER Profile
    Path to a Firefox profile directory (must contain prefs.js). Defaults to the first
    profile found under %APPDATA%\Mozilla\Firefox\Profiles.

.PARAMETER ArkenfoxUrl
    Override the Arkenfox user.js download URL.

.PARAMETER BetterfoxUrl
    Override the Betterfox user.js download URL.

.EXAMPLE
    .\scripts\merge-arkenfox-betterfox.ps1
#>
[CmdletBinding()]
# Pinned upstream versions (update these deliberately, then refresh the checksums):
$ArkenfoxCommit = 'fb56d7bb4ed07898c9d94ca7ecc89697dd88cc3c'
$ArkenfoxSha256 = 'E4AB33C6914899175CF7035E0E57A2D7F08AC887D8F957F1199E7E49BBE7E33E'
$BetterfoxCommit = '067172a4b0dc90e78e5b8b94d9abfe6430c6a7be'
$BetterfoxSha256 = '38A971C7B15225987BAF26DD98B884BFB114531B4F6A8F2E0E281FB0352D5240'

param(
    [string]$Profile,
    [string]$ArkenfoxUrl = "https://raw.githubusercontent.com/arkenfox/user.js/$ArkenfoxCommit/user.js",
    [string]$BetterfoxUrl = "https://raw.githubusercontent.com/yokoffing/Betterfox/$BetterfoxCommit/user.js"
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $Profile) {
    $base = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    $candidates = Get-ChildItem -LiteralPath $base -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'prefs.js')
    } | Sort-Object Name
    if (-not $candidates) { throw "No Firefox profile with prefs.js found under $base" }
    $Profile = $candidates[0].FullName
}
if (-not (Test-Path -LiteralPath (Join-Path $Profile 'prefs.js'))) {
    throw "Not a valid profile (no prefs.js): $Profile"
}

$ark = Join-Path $env:TEMP 'arkenfox-user.js'
$bf  = Join-Path $env:TEMP 'betterfox-user.js'
Write-Host "Downloading Arkenfox (pinned $ArkenfoxCommit)..." -ForegroundColor Green
Invoke-WebRequest -Uri $ArkenfoxUrl -OutFile $ark
Write-Host "Downloading Betterfox (pinned $BetterfoxCommit)..." -ForegroundColor Green
Invoke-WebRequest -Uri $BetterfoxUrl -OutFile $bf

function Test-Checksum([string]$File, [string]$Expected, [string]$Name) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash
    if ($actual -ne $Expected) {
        throw "Checksum mismatch for $Name.`n  expected: $Expected`n  actual:   $actual`nUpstream may have changed. Review before proceeding."
    }
    Write-Host "  $Name checksum OK" -ForegroundColor Green
}
Test-Checksum $ark $ArkenfoxSha256 'Arkenfox'
Test-Checksum $bf  $BetterfoxSha256 'Betterfox'

# Preserve the existing firefox-debloat managed block (if any).
$markBegin = '// >>> firefox-debloat >>>'
$markEnd   = '// <<< firefox-debloat <<<'
$existing = if (Test-Path -LiteralPath (Join-Path $Profile 'user.js')) {
    [IO.File]::ReadAllText((Join-Path $Profile 'user.js'))
} else { '' }

$block = ''
$inBlock = $false
$blockLines = @()
foreach ($line in ($existing -split '\r?\n')) {
    if (-not $inBlock -and $line -ceq $markBegin) { $inBlock = $true }
    if ($inBlock) { $blockLines += $line }
    if ($inBlock -and $line -ceq $markEnd) { $inBlock = $false }
}
if ($blockLines.Count -gt 0) { $block = ($blockLines -join "`n") }

# Back up the current user.js.
$backup = Join-Path $Profile ("user.js.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (Test-Path -LiteralPath (Join-Path $Profile 'user.js')) {
    Copy-Item -LiteralPath (Join-Path $Profile 'user.js') -Destination $backup -Force
    Write-Host "Backed up previous user.js to $backup"
}

$arkContent = [IO.File]::ReadAllText($ark)
$bfContent  = [IO.File]::ReadAllText($bf)

$merged = $arkContent + "`n`n" +
          "/* ===== BETTERFOX ADDITIONS (Fastfox/Securefox/Peskyfox/Smoothfox) ===== */`n" +
          $bfContent + "`n`n"

if ($block) {
    $merged += "/* ===== firefox-debloat managed block (kept last so its prefs win) ===== */`n" + $block + "`n"
}

# Append optional personal overrides if present next to this script's repo.
$overrides = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'overrides\user-overrides.example.js'
# (Left as example; not auto-applied. Copy to user-overrides.js and append manually.)

[IO.File]::WriteAllText((Join-Path $Profile 'user.js'), $merged, $Utf8NoBom)
Write-Host "Merged user.js written to $Profile" -ForegroundColor Green
Write-Host "Review overrides in overrides\user-overrides.example.js and append if desired."
