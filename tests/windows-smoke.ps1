# Smoke tests for windows\firefox-debloat.ps1. They run with -PolicyDir, -RegistryPath under HKCU
# and temporary APPDATA/LOCALAPPDATA, without administrator rights and without Firefox installed.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests\windows-smoke.ps1   (or pwsh -File ...)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$OnWindows = $env:OS -eq 'Windows_NT'
$Root = Split-Path -Parent $PSScriptRoot
$Script = Join-Path (Join-Path $Root 'windows') 'firefox-debloat.ps1'
$ConfigPolicies = Join-Path (Join-Path $Root 'config') 'policies.json'
$HostExe = (Get-Process -Id $PID).Path
$MarkBegin = '// >>> firefox-debloat >>>'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Fails = 0

function Assert-True([string]$Description, [bool]$Condition) {
    if ($Condition) {
        Write-Output "ok   $Description"
    } else {
        Write-Output "FAIL $Description"
        $script:Fails++
    }
}

# Runs the script in a separate process, as a user would, and returns the exit code.
function Invoke-Debloat([string[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-PolicyDir', $script:PolicyDir) + $Arguments
    & $HostExe @all *> $null
    return $LASTEXITCODE
}

function Invoke-DebloatRegistry([string[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-RegistryPath', $script:RegKey) + $Arguments
    & $HostExe @all *> $null
    return $LASTEXITCODE
}

function Write-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Read-File([string]$Path) { [IO.File]::ReadAllText($Path) }
function Read-Json([string]$Path) { Read-File $Path | ConvertFrom-Json }

function Get-BlockCount([string]$Path) {
    @((Read-File $Path) -split '\r?\n' | Where-Object { $_ -ceq $MarkBegin }).Count
}

function Test-SameContent([string]$A, [string]$B) {
    $x = [IO.File]::ReadAllBytes($A); $y = [IO.File]::ReadAllBytes($B)
    return ($x.Length -eq $y.Length) -and (-not (Compare-Object $x $y -SyncWindow 0))
}

# Canonical JSON (sorted keys) to compare content regardless of formatting.
function ConvertTo-Canonical($Value) {
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($name in ($Value.PSObject.Properties.Name | Sort-Object)) { $o[$name] = ConvertTo-Canonical $Value.$name }
        return $o
    }
    if ($Value -is [array]) { return , @($Value | ForEach-Object { ConvertTo-Canonical $_ }) }
    return $Value
}
function Get-CanonicalJson($Value) { ConvertTo-Json -InputObject (ConvertTo-Canonical $Value) -Depth 10 -Compress }

function Initialize-Env {
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('ffdb-' + [Guid]::NewGuid().ToString('N'))
    $env:APPDATA = Join-Path $script:Work 'appdata'
    $env:LOCALAPPDATA = Join-Path $script:Work 'localappdata'
    $script:PolicyDir = Join-Path $script:Work 'policies'
    $script:Pol = Join-Path $script:PolicyDir 'policies.json'
    $base = Join-Path (Join-Path $env:APPDATA 'Mozilla') 'Firefox'
    $script:P1 = Join-Path (Join-Path $base 'Profiles') 'abc.default-release'
    $script:P2 = Join-Path (Join-Path $script:Work 'custom') 'my-profile'
    Write-File (Join-Path $script:P1 'prefs.js') "user_pref(`"browser.startup.page`", 3);`n"
    Write-File (Join-Path $script:P2 'prefs.js') "user_pref(`"browser.startup.page`", 3);`n"
    Write-File (Join-Path $base 'profiles.ini') ("[General]`r`nStartWithLastProfile=1`r`n`r`n" +
        "[Profile0]`r`nName=default-release`r`nIsRelative=1`r`nPath=Profiles/abc.default-release`r`n`r`n" +
        "[Profile1]`r`nName=mine`r`nIsRelative=0`r`nPath=$($script:P2)`r`n")
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
}

function Clear-Env { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

# Fake process named "firefox" to test the running-Firefox detection.
function Invoke-FakeFirefox {
    if ($OnWindows) {
        $exe = Join-Path $script:Work 'firefox.exe'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination $exe
        return Start-Process -FilePath $exe -ArgumentList '-n', '120', '127.0.0.1' -WindowStyle Hidden -PassThru
    }
    $exe = Join-Path $script:Work 'firefox'
    Copy-Item -LiteralPath (Get-Command sleep).Source -Destination $exe
    return Start-Process -FilePath $exe -ArgumentList '120' -PassThru
}

$savedAppData = $env:APPDATA
$savedLocalAppData = $env:LOCALAPPDATA
$expected = Read-Json $ConfigPolicies
Add-Member -InputObject $expected.policies -MemberType NoteProperty -Name DisableDefaultBrowserAgent -Value $true

try {
    Write-Output '# apply without a previous policies.json'
    Initialize-Env
    Invoke-Debloat @() | Out-Null
    $j = Read-Json $Pol
    Assert-True 'policies.json = config/ + DisableDefaultBrowserAgent' ((Get-CanonicalJson $j) -eq (Get-CanonicalJson $expected))
    Assert-True 'empty .debloat-orig sentinel' ((Test-Path "$Pol.debloat-orig") -and (Get-Item "$Pol.debloat-orig").Length -eq 0)
    Assert-True 'policies.json without BOM' ([IO.File]::ReadAllBytes($Pol)[0] -ne 0xEF)
    Assert-True 'block in the Profiles\ profile' ((Get-BlockCount (Join-Path $P1 'user.js')) -eq 1)
    Assert-True 'block in the profiles.ini profile (IsRelative=0)' ((Get-BlockCount (Join-Path $P2 'user.js')) -eq 1)
    Assert-True 'user.js without BOM' ([IO.File]::ReadAllBytes((Join-Path $P1 'user.js'))[0] -ne 0xEF)
    Assert-True 'DisableAccounts applied' ($j.policies.DisableAccounts -eq $true)
    Assert-True 'account pref in the block' ((Read-File (Join-Path $P1 'user.js')).Contains('user_pref("identity.fxaccounts.enabled",'))
    Assert-True 'translation available by default' ($j.policies.AIControls.Translations.Value -eq 'available')
    Assert-True 'Locked false by default' ($j.policies.FirefoxHome.Locked -eq $false)
    Clear-Env

    Write-Output '# apply with a previous policies.json'
    Initialize-Env
    Write-File $Pol '{"policies":{"DisableAppUpdate":true,"FirefoxHome":{"Search":false},"Preferences":{"browser.foo":{"Value":1,"Status":"user"}}}}'
    Copy-Item $Pol (Join-Path $Work 'prev.json')
    Invoke-Debloat @() | Out-Null
    $j = Read-Json $Pol
    Assert-True 'previous top-level key preserved' ($j.policies.DisableAppUpdate -eq $true)
    Assert-True 'previous subkey preserved by the merge' ($j.policies.FirefoxHome.Search -eq $false)
    Assert-True 'new subkey added' ($j.policies.FirefoxHome.Stories -eq $false)
    Assert-True 'previous Preferences preserved' ($j.policies.Preferences.'browser.foo'.Value -eq 1)
    Assert-True 'original saved byte for byte' (Test-SameContent (Join-Path $Work 'prev.json') "$Pol.debloat-orig")
    Clear-Env

    Write-Output '# apply twice'
    Initialize-Env
    $u1 = Join-Path $P1 'user.js'
    Write-File $u1 "user_pref(`"my.pref`", true);`r`n// comment"   # CRLF, no trailing newline
    Invoke-Debloat @() | Out-Null
    Copy-Item $Pol (Join-Path $Work '1.json'); Copy-Item $u1 (Join-Path $Work '1.js')
    Invoke-Debloat @() | Out-Null
    Assert-True 'a single block' ((Get-BlockCount $u1) -eq 1)
    Assert-True 'identical policies.json' (Test-SameContent (Join-Path $Work '1.json') $Pol)
    Assert-True 'identical user.js' (Test-SameContent (Join-Path $Work '1.js') $u1)
    $lines = (Read-File $u1) -split "`r`n"
    Assert-True 'previous user.js without newline preserved' ($lines[0] -eq 'user_pref("my.pref", true);' -and $lines[1] -eq '// comment')
    Assert-True 'marker on its own line' ($lines[2] -ceq $MarkBegin)
    Assert-True 'CRLF kept across the whole file' (-not ((Read-File $u1) -match '[^\r]\n'))
    Clear-Env

    Write-Output '# -Lock'
    Initialize-Env
    Invoke-Debloat @('-Lock') | Out-Null
    $text = Read-File $Pol
    Assert-True 'no Locked false left' ($text -notmatch '"Locked":\s*false')
    $j = Read-Json $Pol
    Assert-True 'Locked true in FirefoxHome and AIControls' ($j.policies.FirefoxHome.Locked -and $j.policies.AIControls.Default.Locked -and $j.policies.AIControls.Translations.Locked)
    Assert-True 'Preferences with Status locked' (@($j.policies.Preferences.PSObject.Properties | Where-Object { $_.Value.Status -ne 'locked' }).Count -eq 0)
    Clear-Env

    Write-Output '# -BlockTranslations'
    Initialize-Env
    Invoke-Debloat @('-BlockTranslations') | Out-Null
    Assert-True 'AIControls.Translations blocked' ((Read-Json $Pol).policies.AIControls.Translations.Value -eq 'blocked')
    Assert-True 'translation pref in the block' ((Read-File (Join-Path $P1 'user.js')).Contains('user_pref("browser.ai.control.translations", "blocked");'))
    Clear-Env

    Write-Output '# -KeepSync'
    Initialize-Env
    Invoke-Debloat @() | Out-Null
    Invoke-Debloat @('-KeepSync') | Out-Null
    Assert-True 'DisableAccounts removed when run again' ($null -eq (Read-Json $Pol).policies.PSObject.Properties['DisableAccounts'])
    Assert-True 'account pref out of the block' (-not (Read-File (Join-Path $P1 'user.js')).Contains('identity.fxaccounts.enabled'))
    Clear-Env

    Write-Output '# pref that leaves the block is cleared from prefs.js'
    Initialize-Env
    $prefs1 = Join-Path $P1 'prefs.js'
    Invoke-Debloat @('-BlockTranslations') | Out-Null
    [IO.File]::AppendAllText($prefs1, "user_pref(`"identity.fxaccounts.enabled`", false);`nuser_pref(`"browser.ai.control.translations`", `"blocked`");`n", $Utf8NoBom)
    Invoke-Debloat @('-KeepSync') | Out-Null
    Assert-True '-KeepSync clears the account pref from prefs.js' (-not (Read-File $prefs1).Contains('identity.fxaccounts.enabled'))
    Assert-True 'without -BlockTranslations the translation pref is cleared' (-not (Read-File $prefs1).Contains('browser.ai.control.translations'))
    Assert-True 'other prefs.js prefs untouched' ((Read-File $prefs1).Contains('browser.startup.page'))
    Clear-Env

    Write-Output '# -UserOnly and -SystemOnly'
    Initialize-Env
    Invoke-Debloat @('-UserOnly') | Out-Null
    Assert-True '-UserOnly does not write policies.json' (-not (Test-Path $Pol))
    Assert-True '-UserOnly writes user.js' (Test-Path (Join-Path $P1 'user.js'))
    Clear-Env
    Initialize-Env
    Invoke-Debloat @('-SystemOnly') | Out-Null
    Assert-True '-SystemOnly writes policies.json' (Test-Path $Pol)
    Assert-True '-SystemOnly does not write user.js' (-not (Test-Path (Join-Path $P1 'user.js')))
    Assert-True '-UserOnly with -SystemOnly fails' ((Invoke-Debloat @('-UserOnly', '-SystemOnly')) -ne 0)
    Clear-Env

    Write-Output '# revert'
    Initialize-Env
    Write-File $Pol "{`"policies`":{`"DisableAppUpdate`":true}}`n"
    Copy-Item $Pol (Join-Path $Work 'prev.json')
    $u1 = Join-Path $P1 'user.js'; $prefs1 = Join-Path $P1 'prefs.js'
    Write-File $u1 "user_pref(`"my.pref`", true);`n"
    Copy-Item $u1 (Join-Path $Work 'prev.js'); Copy-Item $prefs1 (Join-Path $Work 'prev-prefs.js')
    Invoke-Debloat @('-BlockTranslations') | Out-Null
    # Simulates Firefox copying the user.js values into prefs.js.
    $copied = (Read-File $u1) -split '\r?\n' | Where-Object { $_ -like 'user_pref(*' -and $_ -notlike '*my.pref*' }
    [IO.File]::AppendAllText($prefs1, (($copied -join "`n") + "`n"), $Utf8NoBom)
    $fake = Invoke-FakeFirefox
    try {
        Assert-True 'revert aborts with Firefox running' ((Invoke-Debloat @('-Revert')) -ne 0)
    } finally {
        Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
        $fake.WaitForExit()
    }
    Assert-True 'nothing changed on abort' ((Get-BlockCount $u1) -eq 1)
    Invoke-Debloat @('-Revert') | Out-Null
    Assert-True 'policies.json restored' (Test-SameContent (Join-Path $Work 'prev.json') $Pol)
    Assert-True '.debloat-orig removed' (-not (Test-Path "$Pol.debloat-orig"))
    Assert-True 'user.js restored' (Test-SameContent (Join-Path $Work 'prev.js') $u1)
    Assert-True 'prefs.js restored' (Test-SameContent (Join-Path $Work 'prev-prefs.js') $prefs1)
    Assert-True 'user.js with only the block is deleted' (-not (Test-Path (Join-Path $P2 'user.js')))
    Clear-Env

    Initialize-Env
    Invoke-Debloat @() | Out-Null
    Invoke-Debloat @('-Revert') | Out-Null
    Assert-True 'policies.json that did not exist before is removed' (-not (Test-Path $Pol) -and -not (Test-Path "$Pol.debloat-orig"))
    Clear-Env

    Write-Output '# revert after editing config/ (clears what was applied)'
    Initialize-Env
    Invoke-Debloat @() | Out-Null
    $u1 = Join-Path $P1 'user.js'; $prefs1 = Join-Path $P1 'prefs.js'
    [IO.File]::AppendAllText($prefs1, "user_pref(`"pref.applied.before`", false);`n", $Utf8NoBom)
    $t = (Read-File $u1).Replace("$MarkBegin`n", "$MarkBegin`nuser_pref(`"pref.applied.before`", false);`n")
    Write-File $u1 $t
    Invoke-Debloat @('-Revert') | Out-Null
    Assert-True 'old block pref removed from prefs.js' (-not (Read-File $prefs1).Contains('pref.applied.before'))
    Clear-Env

    if ($OnWindows) {
        Write-Output '# registry (-RegistryPath under HKCU)'
        $testRoot = 'HKCU:\Software\firefox-debloat-test'
        $script:RegKey = "$testRoot\Mozilla\Firefox"
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue

        Initialize-Env
        New-Item -Path "$RegKey\FirefoxHome" -Force | Out-Null
        New-ItemProperty -LiteralPath "$RegKey\FirefoxHome" -Name Search -PropertyType DWord -Value 0 | Out-Null
        New-ItemProperty -LiteralPath $RegKey -Name DisableAppUpdate -PropertyType DWord -Value 1 | Out-Null
        Invoke-DebloatRegistry @() | Out-Null
        $key = Get-Item -LiteralPath $RegKey
        Assert-True 'policy written as REG_MULTI_SZ' ($key.GetValueKind('DisableTelemetry') -eq 'MultiString')
        Assert-True 'value is JSON' (($key.GetValue('DisableTelemetry') -join "`n") -eq 'true')
        $fxHome = ($key.GetValue('FirefoxHome') -join "`n") | ConvertFrom-Json
        Assert-True 'object policy as JSON' ($fxHome.Stories -eq $false -and $fxHome.Locked -eq $false)
        Assert-True 'subkey with the same name replaced' (-not (Test-Path "$RegKey\FirefoxHome"))
        Assert-True 'previous policy preserved' ($key.GetValue('DisableAppUpdate') -eq 1)
        Assert-True 'DisableDefaultBrowserAgent written' (($key.GetValue('DisableDefaultBrowserAgent') -join '') -eq 'true')
        Invoke-DebloatRegistry @('-KeepSync') | Out-Null
        $key = Get-Item -LiteralPath $RegKey
        Assert-True 'DisableAccounts removed with -KeepSync' ($null -eq $key.GetValue('DisableAccounts'))
        Invoke-DebloatRegistry @('-Revert') | Out-Null
        $key = Get-Item -LiteralPath $RegKey
        Assert-True 'revert restores the original subkey' ((Get-ItemProperty -LiteralPath "$RegKey\FirefoxHome").Search -eq 0)
        Assert-True 'revert removes the script policies' ($null -eq $key.GetValue('DisableTelemetry'))
        Assert-True 'revert keeps the previous policy' ($key.GetValue('DisableAppUpdate') -eq 1)
        Remove-Item -LiteralPath $testRoot -Recurse -Force
        Clear-Env

        Initialize-Env
        New-Item -Path $testRoot -Force | Out-Null
        Invoke-DebloatRegistry @() | Out-Null
        Assert-True 'key created' (Test-Path $RegKey)
        Invoke-DebloatRegistry @('-Revert') | Out-Null
        Assert-True 'revert removes a key that did not exist' (-not (Test-Path $RegKey))
        Assert-True 'revert removes the empty Mozilla key' (-not (Test-Path "$testRoot\Mozilla"))
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        Clear-Env
    } else {
        Write-Output '# registry: skipped (Windows only)'
    }

    # Writes to the real Firefox install; only runs on a throwaway CI VM, as administrator.
    if ($OnWindows -and $env:CI -eq 'true') {
        Write-Output '# install detection (CI)'
        Initialize-Env
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-SystemOnly')
        $out = & $HostExe @common *>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Output ($out.Trim() -replace '(?m)^', '     ')
        if ($out -match 'Firefox installation not found') {
            Write-Output '     (Firefox not installed on this runner; scenario skipped)'
        } else {
            Assert-True 'applies to the detected install' ($code -eq 0 -and $out -match 'Policies (installed at|written to)')
            $out = & $HostExe @($common + '-Revert') *>&1 | Out-String
            Assert-True 'reverts the detected install' ($LASTEXITCODE -eq 0 -and $out -match '(restored|removed)')
        }
        Clear-Env
    }
} finally {
    $env:APPDATA = $savedAppData
    $env:LOCALAPPDATA = $savedLocalAppData
}

Write-Output ''
if ($script:Fails -gt 0) {
    Write-Output "$($script:Fails) failure(s)"
    exit 1
}
Write-Output 'all tests passed'
