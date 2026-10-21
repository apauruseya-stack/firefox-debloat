<#
.SYNOPSIS
    Disables telemetry, ads, recommendations, AI features and Firefox Account/Sync in Firefox.

.DESCRIPTION
    Works in two layers:

      1. Policies (system-wide): policies.json in the distribution folder of the Firefox install
         or, for the Microsoft Store version, values under HKLM:\SOFTWARE\Policies\Mozilla\Firefox.
         They apply to all profiles and show up in about:policies. Elevation (UAC) is requested
         only for this step.
      2. user.js (per profile): prefs that policies can't reach, inside a delimited block. User
         content outside the block is preserved.

    The content of both layers comes from config\policies.json and config\user.js. Edit those
    files to customize and run the script again.

    Run as your regular user: profiles live in that user's %APPDATA%.

.PARAMETER UserOnly
    Only the user.js step (no elevation).

.PARAMETER SystemOnly
    Only the policies step.

.PARAMETER Lock
    Locks the policies: they can't be changed from the UI.

.PARAMETER BlockTranslations
    Also blocks local (on-device) translation.

.PARAMETER KeepSync
    Keeps Firefox Account and Sync working.

.PARAMETER Revert
    Undoes what the script applied. Close Firefox first.

.PARAMETER Registry
    Writes the policies to the registry (HKLM:\SOFTWARE\Policies\Mozilla\Firefox) instead of
    policies.json. This mode is used automatically for the Microsoft Store version.

.PARAMETER PolicyDir
    Folder to write policies.json to, instead of the Firefox distribution folder. Useful for
    testing.

.PARAMETER Help
    Shows this help.

.PARAMETER RegistryPath
    Internal use (tests): alternative registry key, like HKCU:\Software\test\Mozilla\Firefox.

.PARAMETER LogPath
    Internal use: file where the elevated instance writes its output for the original one to show.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\windows\firefox-debloat.ps1

.EXAMPLE
    .\windows\firefox-debloat.ps1 -Lock -BlockTranslations

.EXAMPLE
    .\windows\firefox-debloat.ps1 -Revert
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Colored output for the user; the script does not emit objects.')]
# The parameters are read inside functions (script scope), which the rule does not see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Parameters used by the functions through script scope.')]
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$UserOnly,
    [switch]$SystemOnly,
    [switch]$Lock,
    [switch]$BlockTranslations,
    [switch]$KeepSync,
    [switch]$Revert,
    [switch]$Registry,
    [string]$PolicyDir,
    [switch]$Help,
    [Parameter(DontShow)][string]$RegistryPath,
    [Parameter(DontShow)][string]$LogPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$OnWindows = $env:OS -eq 'Windows_NT'
$ConfigDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'config'
$ConfigPolicies = Join-Path $ConfigDir 'policies.json'
$ConfigUserJs = Join-Path $ConfigDir 'user.js'
$MarkBegin = '// >>> firefox-debloat >>>'
$MarkEnd = '// <<< firefox-debloat <<<'
$DefaultRegistryPath = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$PrefPattern = '^\s*user_pref\("([^"]*)"'

# Optional prefs that revert always clears, even if the matching flag was not used.
$OptionalPrefs = @('browser.ai.control.translations', 'identity.fxaccounts.enabled')

# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------
function Write-LogLine([string]$Text) {
    if ($LogPath) { [IO.File]::AppendAllText($LogPath, "$Text`n", $Utf8NoBom) }
}

function Write-Step([string]$Text) {
    Write-Host '==> ' -ForegroundColor Green -NoNewline
    Write-Host $Text
    Write-LogLine "==> $Text"
}

function Write-Warn([string]$Text) {
    Write-Host '!! ' -ForegroundColor Yellow -NoNewline
    Write-Host $Text
    Write-LogLine "!! $Text"
}

function Exit-WithError([string]$Text) {
    Write-Host 'xx ' -ForegroundColor Red -NoNewline
    Write-Host $Text
    Write-LogLine "xx $Text"
    exit 1
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
function Test-Admin {
    if (-not $OnWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-FirefoxRunning {
    return $null -ne (Get-Process -Name firefox -ErrorAction SilentlyContinue)
}

function Write-Utf8File([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

# Reads a text file as lines, keeping the line ending it uses (CRLF or LF).
function Read-TextLine([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @()
    if ($text.Length -gt 0) {
        $lines = @($text -split '\r?\n')
        if ($lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    }
    return @{ Lines = $lines; Eol = $eol }
}

function Write-TextLine([string]$Path, [string[]]$Lines, [string]$Eol) {
    $text = ''
    if ($Lines.Count -gt 0) { $text = ($Lines -join $Eol) + $Eol }
    Write-Utf8File $Path $text
}

function Test-JsonObject($Value) {
    return $Value -is [System.Management.Automation.PSCustomObject]
}

function Read-JsonFile([string]$Path) {
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function ConvertTo-JsonText($Value) {
    return (ConvertTo-Json -InputObject $Value -Depth 10) + "`n"
}

# Adds or replaces a property of an object parsed from JSON.
function Add-JsonMember($Object, [string]$Name, $Value) {
    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Get-JsonChild($Object, [string]$Name) {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or -not (Test-JsonObject $prop.Value)) {
        Add-JsonMember $Object $Name (New-Object PSObject)
    }
    return $Object.PSObject.Properties[$Name].Value
}

# Deep merge with the same semantics as jq's "a * b": objects are merged, everything else is
# replaced by the value from $Overlay.
function Merge-JsonObject($Base, $Overlay) {
    foreach ($prop in $Overlay.PSObject.Properties) {
        $existing = $Base.PSObject.Properties[$prop.Name]
        if ($null -ne $existing -and (Test-JsonObject $existing.Value) -and (Test-JsonObject $prop.Value)) {
            Merge-JsonObject $existing.Value $prop.Value | Out-Null
        } else {
            Add-JsonMember $Base $prop.Name $prop.Value
        }
    }
    return $Base
}

# -Lock: "Locked": true in every object that has Locked.
function Invoke-LockWalk($Node) {
    if (Test-JsonObject $Node) {
        if ($null -ne $Node.PSObject.Properties['Locked']) { $Node.Locked = $true }
        foreach ($prop in $Node.PSObject.Properties) { Invoke-LockWalk $prop.Value }
    } elseif ($Node -is [array]) {
        foreach ($item in $Node) { Invoke-LockWalk $item }
    }
}

function Get-PrefName([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match $PrefPattern) { $Matches[1] }
    }
}

# Drops the managed block (from the begin marker to the end marker, inclusive), like the Linux sed.
function Get-LineOutsideBlock([string[]]$Lines) {
    $inBlock = $false
    foreach ($line in $Lines) {
        if (-not $inBlock -and $line -ceq $MarkBegin) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -ceq $MarkEnd) { $inBlock = $false }
            continue
        }
        $line
    }
}

function Get-BlockLine([string[]]$Lines) {
    $inBlock = $false
    foreach ($line in $Lines) {
        if (-not $inBlock -and $line -ceq $MarkBegin) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -ceq $MarkEnd) { $inBlock = $false; continue }
            $line
        }
    }
}

# ---------------------------------------------------------------------------------------------
# config/ data with the flag transformations
# ---------------------------------------------------------------------------------------------
function Get-DesiredPolicy {
    $doc = Read-JsonFile $ConfigPolicies
    $policies = $doc.policies
    if ($Lock) {
        Invoke-LockWalk $doc
        $prefs = $policies.PSObject.Properties['Preferences']
        if ($null -ne $prefs -and (Test-JsonObject $prefs.Value)) {
            foreach ($p in $prefs.Value.PSObject.Properties) {
                if (Test-JsonObject $p.Value) { Add-JsonMember $p.Value 'Status' 'locked' }
            }
        }
    }
    if ($BlockTranslations) {
        $translations = Get-JsonChild (Get-JsonChild $policies 'AIControls') 'Translations'
        Add-JsonMember $translations 'Value' 'blocked'
    }
    if ($KeepSync) { $policies.PSObject.Properties.Remove('DisableAccounts') }
    # Windows-only policy: turns off the agent that reports the default browser.
    Add-JsonMember $policies 'DisableDefaultBrowserAgent' $true
    return $doc
}

function Get-UserJsBlock {
    $config = (Read-TextLine $ConfigUserJs).Lines
    if ($KeepSync) {
        $config = @($config | Where-Object { $_ -notmatch '^\s*user_pref\("identity\.fxaccounts\.enabled",' })
    }
    $block = @(
        $MarkBegin
        '// Generated by firefox-debloat from config/user.js. This block is rewritten on every run:'
        '// put your personal prefs outside of it.'
        ''
    ) + $config
    if ($BlockTranslations) {
        $block += @(
            ''
            '// Blocks local translation (-BlockTranslations).'
            'user_pref("browser.ai.control.translations", "blocked");'
        )
    }
    return $block + $MarkEnd
}

# ---------------------------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------------------------
function Get-FirefoxProfile {
    $bases = @()
    if ($env:APPDATA) { $bases += Join-Path (Join-Path $env:APPDATA 'Mozilla') 'Firefox' }
    # Microsoft Store version: the package %APPDATA% lives in LocalCache\Roaming.
    if ($OnWindows -and $env:LOCALAPPDATA) {
        $packages = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $packages) {
            foreach ($pkg in Get-ChildItem -LiteralPath $packages -Directory -Filter 'Mozilla.Firefox_*') {
                $bases += Join-Path $pkg.FullName 'LocalCache\Roaming\Mozilla\Firefox'
            }
        }
    }

    $comparer = if ($OnWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ($comparer)
    $candidates = @()
    foreach ($base in $bases) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $profilesDir = Join-Path $base 'Profiles'
        if (Test-Path -LiteralPath $profilesDir -PathType Container) {
            $candidates += @(Get-ChildItem -LiteralPath $profilesDir -Directory | ForEach-Object { $_.FullName })
        }
        # Profiles in custom locations only show up in profiles.ini.
        $ini = Join-Path $base 'profiles.ini'
        if (Test-Path -LiteralPath $ini -PathType Leaf) { $candidates += @(Get-ProfilesIniPath $base $ini) }
    }
    $result = @()
    foreach ($dir in $candidates) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'prefs.js') -PathType Leaf)) { continue }
        $full = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
        if ($seen.Add($full)) { $result += $full }
    }
    return $result | Sort-Object
}

# Paths of the [Profile*] sections in profiles.ini; IsRelative=0 means an absolute path.
function Get-ProfilesIniPath([string]$Base, [string]$Ini) {
    $inProfile = $false; $path = $null; $relative = '1'
    $sep = [IO.Path]::DirectorySeparatorChar
    foreach ($line in (Read-TextLine $Ini).Lines + '[end]') {
        $line = $line.Trim()
        if ($line -match '^\[(.*)\]$') {
            if ($inProfile -and $path) {
                $p = $path.Replace('/', $sep).Replace('\', $sep)
                if ($relative -eq '0') { $p } else { Join-Path $Base $p }
            }
            $inProfile = $Matches[1] -match '^Profile[0-9]+$'; $path = $null; $relative = '1'
        } elseif ($inProfile -and $line -match '^Path=(.*)$') {
            $path = $Matches[1]
        } elseif ($inProfile -and $line -match '^IsRelative=(.*)$') {
            $relative = $Matches[1]
        }
    }
}

# ---------------------------------------------------------------------------------------------
# User step: user.js
# ---------------------------------------------------------------------------------------------
# Elevated with another admin account, %APPDATA% would be that account's, not the user's.
function Assert-UserContext {
    if (-not (Test-Admin)) { return }
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $console = $null
    try { $console = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName } catch { $console = $null }
    if (-not $console) {
        Write-Warn "Running as administrator. Reading the profiles of $current ($env:APPDATA)."
    } elseif ($console -ne $current) {
        Exit-WithError ("Running as $current, but the session belongs to $console. Run without " +
            'elevation, as your regular user: the script asks for elevation only for the policies step.')
    }
}

# Deletes the given prefs from prefs.js. Firefox copies user.js values into prefs.js; without this
# they would stay active.
function Clear-Pref([string]$PrefsFile, [string[]]$Names) {
    if ($Names.Count -eq 0 -or -not (Test-Path -LiteralPath $PrefsFile)) { return }
    $prefixes = @($Names | Sort-Object -Unique | ForEach-Object { "user_pref(`"$_`"," })
    $prefs = Read-TextLine $PrefsFile
    $kept = @($prefs.Lines | Where-Object {
            $line = $_
            -not ($prefixes | Where-Object { $line.StartsWith($_, [StringComparison]::Ordinal) })
        })
    Write-TextLine $PrefsFile $kept $prefs.Eol
}

function Invoke-UserApply {
    $userProfiles = @(Get-FirefoxProfile)
    if ($userProfiles.Count -eq 0) {
        Write-Warn 'No Firefox profile found. Open Firefox once and run again.'
        return
    }
    $running = Test-FirefoxRunning
    if ($running) { Write-Warn 'Firefox is running: user.js is only read on the next start.' }
    $block = Get-UserJsBlock
    $newNames = @(Get-PrefName $block)
    foreach ($p in $userProfiles) {
        $file = Join-Path $p 'user.js'
        $kept = @(); $eol = "`n"; $removed = @()
        if (Test-Path -LiteralPath $file) {
            $current = Read-TextLine $file
            # Prefs that were in the block and left it (config/ edited or -KeepSync): the old value
            # would stay in prefs.js, so it is deleted and the pref goes back to its default.
            $removed = @(Get-PrefName @(Get-BlockLine $current.Lines) | Sort-Object -Unique |
                    Where-Object { $newNames -notcontains $_ })
            $kept = @(Get-LineOutsideBlock $current.Lines)
            $eol = $current.Eol
        }
        Write-TextLine $file ($kept + $block) $eol
        if ($removed.Count -gt 0) {
            if ($running) {
                Write-Warn ('Close Firefox and reset in about:config the prefs that left the block: ' +
                    ($removed -join ', '))
            } else {
                Clear-Pref (Join-Path $p 'prefs.js') $removed
                Write-Step ('Prefs that left the block were reset to default: ' + ($removed -join ', '))
            }
        }
        Write-Step "user.js updated: $p"
    }
}

function Invoke-UserRevert {
    if (Test-FirefoxRunning) { Exit-WithError 'Close Firefox before reverting (it rewrites prefs.js on exit).' }
    $configNames = @(Get-PrefName (Read-TextLine $ConfigUserJs).Lines) + $OptionalPrefs
    foreach ($p in @(Get-FirefoxProfile)) {
        $file = Join-Path $p 'user.js'
        $names = $configNames
        if (Test-Path -LiteralPath $file) {
            $current = Read-TextLine $file
            # Clears what is in config/ today and what was applied, in case config/ has changed.
            $names += @(Get-PrefName @(Get-BlockLine $current.Lines))
            $kept = @(Get-LineOutsideBlock $current.Lines)
            if (@($kept | Where-Object { $_ -match '\S' }).Count -eq 0) {
                Remove-Item -LiteralPath $file -Force
            } else {
                Write-TextLine $file $kept $current.Eol
            }
        }
        Clear-Pref (Join-Path $p 'prefs.js') $names
        Write-Step "Reverted: $p"
    }
    Write-Warn 'The block prefs were reset to default, including any you had changed by hand before.'
}

# ---------------------------------------------------------------------------------------------
# System step: where to write the policies
# ---------------------------------------------------------------------------------------------
# Registry value or $null, without an error if the key or value is missing (StrictMode would complain).
function Get-RegistryValue([string]$KeyPath, [string]$Name) {
    $item = Get-ItemProperty -LiteralPath $KeyPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $null -eq $item.PSObject.Properties[$Name]) { return $null }
    return $item.PSObject.Properties[$Name].Value
}

function Get-FirefoxInstallDir {
    $roots = @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox'
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox'
        'HKCU:\SOFTWARE\Mozilla\Mozilla Firefox'
    )
    foreach ($root in $roots) {
        $version = Get-RegistryValue $root 'CurrentVersion'
        if (-not $version) { continue }
        $dir = Get-RegistryValue "$root\$version\Main" 'Install Directory'
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'firefox.exe'))) { return $dir }
    }
    $fallbacks = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Mozilla Firefox' }
    foreach ($dir in $fallbacks) {
        if (Test-Path -LiteralPath (Join-Path $dir 'firefox.exe')) { return $dir }
    }
    return $null
}

function Test-StoreFirefox {
    if (-not $env:LOCALAPPDATA) { return $false }
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    return [bool](Get-ChildItem -LiteralPath $packages -Directory -Filter 'Mozilla.Firefox_*' -ErrorAction SilentlyContinue)
}

# Picks the destination: @{ Kind = 'json'|'registry'; Path = ... } or $null if there is no Firefox.
function Get-PolicyTarget {
    if ($RegistryPath) { return @{ Kind = 'registry'; Path = $RegistryPath } }
    if ($Registry) { return @{ Kind = 'registry'; Path = $DefaultRegistryPath } }
    if ($PolicyDir) { return @{ Kind = 'json'; Path = $PolicyDir } }
    if (-not $OnWindows) { return $null }
    $installDir = Get-FirefoxInstallDir
    if ($installDir -and $installDir -notmatch '\\WindowsApps\\') {
        return @{ Kind = 'json'; Path = (Join-Path $installDir 'distribution') }
    }
    if ($installDir -or (Test-StoreFirefox)) {
        Write-Warn ('Microsoft Store Firefox detected. Its install folder is read-only, so the ' +
            "policies go to the registry at $DefaultRegistryPath.")
        return @{ Kind = 'registry'; Path = $DefaultRegistryPath }
    }
    return $null
}

function Test-Writable([string]$Path) {
    $dir = $Path
    while ($dir -and -not (Test-Path -LiteralPath $dir)) { $dir = Split-Path -Parent $dir }
    if (-not $dir) { return $false }
    $probe = Join-Path $dir ('.firefox-debloat-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
    } catch {
        return $false
    }
    $file = Join-Path $Path 'policies.json'
    if (Test-Path -LiteralPath $file) {
        try { [IO.File]::Open($file, 'Open', 'ReadWrite').Dispose() } catch { return $false }
    }
    return $true
}

function Test-NeedsElevation($Target) {
    if (Test-Admin) { return $false }
    if ($Target.Kind -eq 'registry') { return $Target.Path -notmatch '^HKCU:' }
    return -not (Test-Writable $Target.Path)
}

# Relaunches only the system step elevated and waits for it. Its output comes back through a log file.
function Invoke-ElevatedSystemStep($Target) {
    $log = [IO.Path]::GetTempFileName()
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-SystemOnly',
        '-LogPath', "`"$log`"")
    if ($Target.Kind -eq 'registry') {
        $arguments += @('-RegistryPath', "`"$($Target.Path)`"")
    } else {
        $arguments += @('-PolicyDir', "`"$($Target.Path)`"")
    }
    if ($Lock) { $arguments += '-Lock' }
    if ($BlockTranslations) { $arguments += '-BlockTranslations' }
    if ($KeepSync) { $arguments += '-KeepSync' }
    if ($Revert) { $arguments += '-Revert' }

    Write-Step 'Requesting elevation (UAC) to write the policies...'
    $hostExe = (Get-Process -Id $PID).Path
    try {
        $proc = Start-Process -FilePath $hostExe -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru
    } catch {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        Exit-WithError "Elevation cancelled or denied: $($_.Exception.Message)"
    }
    $output = [IO.File]::ReadAllText($log)
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    foreach ($line in ($output -split '\r?\n' | Where-Object { $_ })) { Write-Host "   $line" }
    if ($proc.ExitCode -ne 0) { Exit-WithError "The policies step failed (exit code $($proc.ExitCode))." }
}

function Invoke-SystemStep {
    $target = Get-PolicyTarget
    if ($null -eq $target) {
        Write-Warn ('Firefox installation not found; policies step skipped. Use -PolicyDir to point ' +
            'to the distribution folder or -Registry to write to the registry.')
        return
    }
    if (Test-NeedsElevation $target) {
        Invoke-ElevatedSystemStep $target
        return
    }
    if ($target.Kind -eq 'json') {
        if ($Revert) { Invoke-JsonRevert $target.Path } else { Invoke-JsonApply $target.Path }
    } else {
        if ($Revert) { Invoke-RegistryRevert $target.Path } else { Invoke-RegistryApply $target.Path }
    }
}

# ---------------------------------------------------------------------------------------------
# Policies in policies.json
# ---------------------------------------------------------------------------------------------
# Firefox merges the registry and policies.json per top-level policy; the registry one wins.
function Write-RegistryConflict($Desired) {
    if (-not $OnWindows) { return }
    foreach ($root in @('HKLM:\SOFTWARE\Policies\Mozilla\Firefox', 'HKCU:\SOFTWARE\Policies\Mozilla\Firefox')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $key = Get-Item -LiteralPath $root
        $names = @($key.GetValueNames()) + @($key.GetSubKeyNames() | ForEach-Object { $_ })
        $conflicts = @($Desired.policies.PSObject.Properties.Name | Where-Object { $names -contains $_ })
        Write-Warn ("There are registry policies at $root. Firefox combines the registry and policies.json, " +
            'but when the same policy is in both, the registry one applies in full and the policies.json one is ignored.')
        if ($conflicts.Count -gt 0) { Write-Warn ('Affected policies: ' + ($conflicts -join ', ')) }
    }
}

function Invoke-JsonApply([string]$Dir) {
    $file = Join-Path $Dir 'policies.json'
    $orig = "$file.debloat-orig"   # copy of the original; empty file = there was none
    $desired = Get-DesiredPolicy
    Write-RegistryConflict $desired

    # Saves the original state only on the first run, so -Revert knows what to restore.
    if (-not (Test-Path -LiteralPath $orig)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        if (Test-Path -LiteralPath $file) {
            Copy-Item -LiteralPath $file -Destination $orig
        } else {
            Write-Utf8File $orig ''
        }
    }

    # The merge always starts from the original, not the current file: this way a policy removed
    # from config/ (or turned off by a flag, like -KeepSync) disappears on the next run.
    $result = $desired
    if ((Get-Item -LiteralPath $orig).Length -gt 0) {
        try {
            $base = Read-JsonFile $orig
            if (-not (Test-JsonObject $base)) { throw 'root is not an object' }
            $result = Merge-JsonObject $base $desired
            Write-Step 'Original policies.json merged with the firefox-debloat policies.'
        } catch {
            Write-Warn "Original policies.json is invalid; it will be replaced (copy at $orig)."
            $result = $desired
        }
    }
    Write-Utf8File $file (ConvertTo-JsonText $result)
    Write-Step "Policies installed at $file"
}

function Invoke-JsonRevert([string]$Dir) {
    $file = Join-Path $Dir 'policies.json'
    $orig = "$file.debloat-orig"
    if (-not (Test-Path -LiteralPath $orig)) {
        Write-Warn "Nothing to revert in $Dir (the script was not applied there)."
        return
    }
    if ((Get-Item -LiteralPath $orig).Length -gt 0) {
        Move-Item -LiteralPath $orig -Destination $file -Force
        Write-Step 'Original policies.json restored.'
    } else {
        Remove-Item -LiteralPath $file, $orig -Force -ErrorAction SilentlyContinue
        Write-Step 'policies.json removed (it did not exist before).'
    }
}

# ---------------------------------------------------------------------------------------------
# Policies in the registry (Microsoft Store version or -Registry)
# ---------------------------------------------------------------------------------------------
# Each top-level policy becomes a REG_MULTI_SZ value holding its JSON, a format Firefox reads from
# the registry the same way it reads policies.json.
function Get-RegistryBackupPath([string]$KeyPath) {
    $dir = if ($KeyPath -match '^HKCU:') { $env:LOCALAPPDATA } else { $env:ProgramData }
    return Join-Path (Join-Path $dir 'firefox-debloat') 'registry.debloat-orig.reg'
}

function ConvertTo-RegExePath([string]$KeyPath) {
    if ($KeyPath -notmatch '^(HKLM|HKCU):\\(.+)$') { Exit-WithError "Invalid registry key: $KeyPath" }
    return "$($Matches[1])\$($Matches[2])"
}

function Invoke-RegExe([string[]]$Arguments) {
    # reg.exe writes to stderr; in Windows PowerShell 5.1 that would become an exception under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $out = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Exit-WithError "reg.exe $($Arguments -join ' ') failed: $out" }
}

# Puts the key back in the state saved in the backup.
function Restore-RegistryKey([string]$KeyPath, [string]$Backup) {
    if (Test-Path -LiteralPath $KeyPath) { Remove-Item -LiteralPath $KeyPath -Recurse -Force }
    if ((Get-Item -LiteralPath $Backup).Length -gt 0) { Invoke-RegExe @('import', $Backup) }
}

function Invoke-RegistryApply([string]$KeyPath) {
    $backup = Get-RegistryBackupPath $KeyPath
    $native = ConvertTo-RegExePath $KeyPath
    if (-not (Test-Path -LiteralPath $backup)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        if (Test-Path -LiteralPath $KeyPath) {
            Invoke-RegExe @('export', $native, $backup, '/y')
        } else {
            Write-Utf8File $backup ''
        }
    }

    # Always starts from the original, for the same reason as policies.json.
    Restore-RegistryKey $KeyPath $backup
    if (-not (Test-Path -LiteralPath $KeyPath)) { New-Item -Path $KeyPath -Force | Out-Null }

    $replaced = @()
    foreach ($prop in (Get-DesiredPolicy).policies.PSObject.Properties) {
        $sub = Join-Path $KeyPath $prop.Name
        if (Test-Path -LiteralPath $sub) {
            Remove-Item -LiteralPath $sub -Recurse -Force
            $replaced += $prop.Name
        } elseif ($null -ne (Get-ItemProperty -LiteralPath $KeyPath -Name $prop.Name -ErrorAction SilentlyContinue)) {
            $replaced += $prop.Name
        }
        $json = ConvertTo-Json -InputObject $prop.Value -Depth 10 -Compress
        New-ItemProperty -LiteralPath $KeyPath -Name $prop.Name -PropertyType MultiString -Value @($json) -Force |
            Out-Null
    }
    if ($replaced.Count -gt 0) {
        Write-Warn ('Policies that already existed in the registry were replaced (-Revert restores them): ' +
            ($replaced -join ', '))
    }
    Write-Warn 'Registry policies apply to every Firefox on this machine, not just the Store one.'
    Write-Step "Policies written to $KeyPath (backup at $backup)"
}

function Invoke-RegistryRevert([string]$KeyPath) {
    $backup = Get-RegistryBackupPath $KeyPath
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-Warn "Nothing to revert in $KeyPath (the script was not applied there)."
        return
    }
    $existed = (Get-Item -LiteralPath $backup).Length -gt 0
    Restore-RegistryKey $KeyPath $backup
    Remove-Item -LiteralPath $backup -Force
    if ($existed) {
        Write-Step "Key $KeyPath restored."
    } else {
        # Removes the empty Mozilla key the script created.
        $parent = Split-Path -Parent $KeyPath
        if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent).Count -eq 0 -and
            @((Get-Item -LiteralPath $parent).GetValueNames()).Count -eq 0) {
            Remove-Item -LiteralPath $parent -Force
        }
        Write-Step "Key $KeyPath removed (it did not exist before)."
    }
}

# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------
if ($Help) {
    Get-Help -Detailed $PSCommandPath
    exit 0
}

try {
    if ($UserOnly -and $SystemOnly) { Exit-WithError 'Use -UserOnly or -SystemOnly, not both.' }
    foreach ($f in @($ConfigPolicies, $ConfigUserJs)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Exit-WithError "Config file not found: $f" }
    }
    try {
        $check = Read-JsonFile $ConfigPolicies
        if (-not (Test-JsonObject $check.policies)) { throw 'no policies object' }
    } catch {
        Exit-WithError "$ConfigPolicies is invalid (it must be JSON with a `"policies`" object)."
    }

    $doUser = -not $SystemOnly
    $doSystem = -not $UserOnly
    if ($doUser) { Assert-UserContext }

    if ($Revert) {
        if ($doUser) { Invoke-UserRevert }
        if ($doSystem) { Invoke-SystemStep }
        Write-Step 'Done. Open Firefox again to load the original state.'
    } else {
        if ($doSystem) { Invoke-SystemStep }
        if ($doUser) { Invoke-UserApply }
        Write-Step 'Done. Restart Firefox and check about:policies and about:config.'
    }
} catch {
    Exit-WithError "Unexpected error: $($_.Exception.Message) ($($_.InvocationInfo.PositionMessage))"
}
