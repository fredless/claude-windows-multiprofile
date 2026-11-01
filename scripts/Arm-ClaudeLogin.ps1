<#
.SYNOPSIS
    Arms the claude:// shim so the NEXT login routes to a chosen profile, and
    reasserts the protocol handler registration.

.DESCRIPTION
    Browser SSO returns to the app through a claude:// deep link. With several
    isolated profiles running, Windows would deliver that callback to whichever
    profile owns the protocol -- not necessarily the one you started logging
    into. Run this immediately BEFORE a login to state your intent:

        .\Arm-ClaudeLogin.ps1 -Profile Work         # next login -> the Work profile
        .\Arm-ClaudeLogin.ps1 -Profile Personal     # next login -> the default profile

    Arming is a deliberate, one-shot statement about the next login -- the shim
    resets to 'default' after it fires (see ClaudeOpenShim.ps1). This is on
    purpose: a "last-launched" heuristic misroutes the "personal re-auth while
    work was launched more recently" case, and a sticky marker silently lands
    tokens in the wrong profile weeks later.

    The profile set and its data/config directories come from profiles.json,
    which Setup.ps1 writes next to this script -- nothing here is hardcoded.

.PARAMETER Profile
    Name of a profile declared at setup (case-insensitive). The literal name
    'default' always disarms (routes to the stock profile); a profile bound to
    the stock paths at setup also disarms (its target is 'default').

.PARAMETER Launch
    After arming, also launch that profile's Claude window (via Launch-Claude.ps1)
    so the sign-in button is right there. Without this, arming only sets the
    marker + handler; trigger the login yourself from an already-open window.

.EXAMPLE
    .\Arm-ClaudeLogin.ps1 -Profile Work -Launch

.NOTES
    Windows PowerShell 5.1. HKCU only -- no admin. Lives in the install bin\
    alongside ClaudeOpenShim.ps1, Launch-Claude.ps1, and profiles.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Profile,

    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$Base         = $PSScriptRoot
$Shim         = Join-Path $Base 'ClaudeOpenShim.ps1'
$TargetFile   = Join-Path $Base 'target.txt'
$ProfilesFile = Join-Path $Base 'profiles.json'

if (-not (Test-Path $ProfilesFile)) {
    throw "profiles.json not found next to this script ($ProfilesFile). Run Setup.ps1 first."
}
if (-not (Test-Path $Shim)) {
    throw "ClaudeOpenShim.ps1 not found next to this script ($Shim). Re-run Setup.ps1."
}

$cfg      = Get-Content $ProfilesFile -Raw | ConvertFrom-Json
$profiles = $cfg.profiles

# --- resolve the requested profile -> (target for the marker, dataDir, configDir) ---
# The literal 'default' is always the disarm case (route to the stock profile).
if ($Profile -ieq 'default') {
    $target    = 'default'
    $dataDir   = Join-Path $env:APPDATA 'Claude'
    $configDir = ''
    $resolved  = 'default'
} else {
    # Case-insensitive match against declared profile names.
    $match = $profiles.PSObject.Properties | Where-Object { $_.Name -ieq $Profile } | Select-Object -First 1
    if (-not $match) {
        $known = ($profiles.PSObject.Properties.Name -join ', ')
        throw "Unknown profile '$Profile'. Known profiles: $known (or 'default' to disarm)."
    }
    $resolved  = $match.Name
    $entry     = $match.Value
    $dataDir   = $entry.dataDir
    $configDir = $entry.configDir
    # A profile bound to the stock paths routes as 'default' (no --user-data-dir).
    $target    = if ($entry.isDefault) { 'default' } else { $entry.dataDir }
}

# --- reassert the classic protocol handler (idempotent) -----------------------
# UserChoice is the operative registration once the user has picked this handler
# in Settings (see docs/PROTOCOL-ROUTING.md); reasserting the classic key here is
# harmless and keeps the registration coherent if the ProgId command ever drifts.
# The command MUST embed a literal expanded shim path (REG_SZ does not expand
# environment variables).
$cmd = "conhost --headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$Shim`" -Url `"%1`""
New-Item 'HKCU:\Software\Classes\claude\shell\open\command' -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty 'HKCU:\Software\Classes\claude' '(Default)' 'URL:Claude Protocol'
Set-ItemProperty 'HKCU:\Software\Classes\claude' 'URL Protocol' ''
Set-ItemProperty 'HKCU:\Software\Classes\claude\shell\open\command' '(Default)' $cmd

# --- set the routing target (ASCII avoids a BOM the shim would have to strip) ---
Set-Content $TargetFile $target -Encoding ASCII

# A new arming starts a new login: forget the previous callback so a
# re-delivery window from an earlier login can't apply to this one.
Remove-Item (Join-Path $Base 'last-route.txt') -Force -ErrorAction SilentlyContinue

Write-Host "Armed: next claude:// login routes to [$resolved] (target: $target)" -ForegroundColor Green

# --- optionally launch the profile so the sign-in button is right there -------
if ($Launch) {
    $launcher = Join-Path $Base 'Launch-Claude.ps1'
    if (-not (Test-Path $launcher)) {
        Write-Warning "Launch-Claude.ps1 not found ($launcher); armed but not launched."
        return
    }
    if ($configDir) {
        & $launcher -ProfileDir $dataDir -ConfigDir $configDir
    } else {
        & $launcher -ProfileDir $dataDir
    }
    Write-Host "Launched [$resolved]. Start the login now; the callback will route here." -ForegroundColor Cyan
}
