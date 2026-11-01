<#
.SYNOPSIS
    claude:// protocol handler that routes deep links (e.g. browser SSO
    callbacks) to a chosen Claude Desktop profile.

.DESCRIPTION
    Windows hands every claude:// activation to a single registered handler.
    When multiple isolated Claude Desktop profiles are running (see
    Setup.ps1 / Launch-Claude.ps1), the OS would otherwise deliver the SSO
    callback to whichever profile owns the protocol -- typically the default
    one -- so a work login can silently land in the personal profile.

    This shim is registered as that handler. On each activation it reads a
    one-line marker file (target.txt) that names the profile data directory the
    NEXT login should go to, launches Claude with the matching --user-data-dir,
    logs the routing decision to route.log, then resets the marker back to
    'default' so an unrelated later login can't silently land in the wrong
    profile.

    Two exceptions keep that one-shot model from misfiring in practice:
      * a re-delivery of the SAME callback URL within a few minutes (the user
        clicked "Open" on the browser's handler prompt again) follows the first
        delivery's target instead of the already-reset marker (last-route.txt);
      * the diagnostic URL claude://test/ping is logged only -- it neither
        launches Claude nor consumes an armed marker.
    OAuth codes/tokens are masked before anything is written to route.log.

    Arm the desired target with Arm-ClaudeLogin.ps1 before starting a login.

    See docs/PROTOCOL-ROUTING.md for the full delivery-chain model and the
    route.log triage table.

.PARAMETER Url
    The claude:// URL Windows passes on activation (the handler command
    registers this as "%1"). Not marked Mandatory on purpose: the OS always
    supplies it, and a Mandatory parameter with no value would PROMPT -- which,
    under the headless conhost host this runs in, would hang the activation
    invisibly. Instead a missing URL is logged as an error and the shim exits.

.NOTES
    Runs under Windows PowerShell 5.1. Keep it self-contained: it is in the
    critical path for ALL claude:// activations, so it must not depend on
    sibling scripts being present or importable at activation time.
#>
param([string]$Url)

$Base          = $PSScriptRoot
$TargetFile    = Join-Path $Base 'target.txt'
$LogFile       = Join-Path $Base 'route.log'
$LastRouteFile = Join-Path $Base 'last-route.txt'

# How long a re-delivered callback (same URL) keeps following the first one.
# Browsers re-fire the identical claude:// URL when the user clicks "Open" on
# the handler prompt more than once; without this, every click after the first
# finds the marker already reset to 'default' and opens the stock profile.
$RepeatWindowSeconds = 300

# True for the diagnostic URL Test-ClaudeRouting.ps1 fires. The probe must
# prove the handler chain reaches the shim WITHOUT side effects: it must not
# launch Claude and must not consume an armed marker (otherwise running the
# diagnostic right after Arm-ClaudeLogin.ps1 silently disarms the next login).
function Test-ClaudeProbeUrl {
    param([string]$Url)
    return $Url -match '^claude://test/ping/?$'
}

# Masks credential-bearing query values so route.log never stores a live OAuth
# code. The routing decision and the URL shape stay readable for triage.
function Get-ClaudeLogSafeUrl {
    param([string]$Url)
    # Any query or fragment key that looks like a credential (code, *token*,
    # state, *session*, *key*, *secret*), e.g. refresh_token, sessionKey.
    return $Url -replace '(?i)([?&#][\w-]*(code|token|state|session|key|secret)[\w-]*=)[^&#]*', '$1<redacted>'
}

function Get-ClaudeUrlHash {
    param([string]$Url)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url))
        return -join ($bytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

# Decides where this activation goes. Normally that is the marker; but if the
# same URL was routed less than $WindowSeconds ago, it is a re-delivery of that
# callback and follows the earlier decision instead of the (already reset)
# marker. $LastRoute is the content of last-route.txt: "<utc ticks>|<sha256>|<target>".
# Pure function (no I/O) so it can be unit-tested (see tests/Test-ShimRouting.ps1).
function Resolve-ClaudeRouteTarget {
    param(
        [string]$Marker,
        [string]$UrlHash,
        [string]$LastRoute,
        [datetime]$NowUtc,
        [int]$WindowSeconds = 300
    )
    $target = if ($Marker) { $Marker } else { 'default' }
    $result = @{ Target = $target; IsRepeat = $false }
    # An armed marker always wins: a genuine re-delivery only ever arrives after
    # the first delivery reset the marker to 'default'. Without this, a bare deep
    # link with no per-login nonce (same URL every time) could drag a freshly
    # armed login back to an earlier profile.
    if ($target -ne 'default') { return $result }
    if (-not $LastRoute) { return $result }

    $parts = $LastRoute.Split('|', 3)
    if ($parts.Count -ne 3 -or $parts[1] -ne $UrlHash -or -not $parts[2]) { return $result }

    $ticks = 0L
    if (-not [long]::TryParse($parts[0], [ref]$ticks)) { return $result }
    # Out-of-range ticks would make [datetime]::new throw and lose the login.
    if ($ticks -lt 0 -or $ticks -gt [datetime]::MaxValue.Ticks) { return $result }
    $age = ($NowUtc - [datetime]::new($ticks, [System.DateTimeKind]::Utc)).TotalSeconds
    if ($age -lt 0 -or $age -gt $WindowSeconds) { return $result }

    return @{ Target = $parts[2]; IsRepeat = $true }
}

# Builds the single, pre-quoted argument string handed to Start-Process.
#
# CRITICAL (PowerShell 5.1): Start-Process -ArgumentList joins array elements
# with spaces but does NOT quote them. A profile path containing spaces would
# therefore splinter into several argv entries; Chromium reads --user-data-dir
# as ending at the first space and silently creates a profile at the truncated
# path -- so the token lands in a THIRD profile nobody intended. Building one
# pre-quoted string ourselves keeps the path intact. This is factored out so it
# can be unit-tested (see tests/Test-ArgBuilder.ps1).
function Get-ClaudeLaunchArgString {
    param(
        [string]$Target,
        [string]$Url
    )
    if ($Target -eq 'default') {
        # No --user-data-dir => Chromium uses the stock %APPDATA%\Claude profile.
        return "`"$Url`""
    }
    return "--user-data-dir=`"$Target`" `"$Url`""
}

function Invoke-ClaudeShim {
    param([string]$Url)

    if (-not $Url) {
        Add-Content $LogFile "$(Get-Date -Format s)  ERROR: no URL supplied on activation"
        exit 1
    }

    # --- read routing target (default = stock profile, the personal-safe rest state) ---
    $target = 'default'
    if (Test-Path $TargetFile) {
        $t = (Get-Content $TargetFile -First 1).Trim()
        if ($t) { $target = $t }
    }
    $safeUrl = Get-ClaudeLogSafeUrl $Url

    # --- diagnostic probe: prove delivery, touch nothing else ------------------
    if (Test-ClaudeProbeUrl $Url) {
        Add-Content $LogFile "$(Get-Date -Format s)  probe (armed: $target; not launched, marker kept) <- $safeUrl"
        return
    }

    # --- a re-delivered callback follows the earlier decision -----------------
    $urlHash   = Get-ClaudeUrlHash $Url
    $lastRoute = if (Test-Path $LastRouteFile) { Get-Content $LastRouteFile -First 1 } else { $null }
    $route     = Resolve-ClaudeRouteTarget -Marker $target -UrlHash $urlHash -LastRoute $lastRoute `
        -NowUtc ([datetime]::UtcNow) -WindowSeconds $RepeatWindowSeconds
    $target    = $route.Target

    # --- resolve Claude.exe from the installed MSIX package -----------------
    # MSIX-only on purpose: there is deliberately NO fallback to an old
    # Squirrel-era claude.exe. Launching a stale exe into a current-era profile
    # is a downgrade-corruption risk, not a graceful fallback -- fail loudly.
    $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    $exe = if ($pkg) { Join-Path $pkg.InstallLocation 'app\Claude.exe' }
    if (-not $exe -or -not (Test-Path $exe)) {
        Add-Content $LogFile "$(Get-Date -Format s)  ERROR: Claude.exe not found (url: $safeUrl)"
        exit 1
    }

    # --- build a single pre-quoted argument string (see Get-ClaudeLaunchArgString) ---
    $argStr = Get-ClaudeLaunchArgString -Target $target -Url $Url

    # route.log is the primary debugging tripwire (see docs/PROTOCOL-ROUTING.md):
    #   * no new line during a login  => the handler chain failed BEFORE the shim
    #                                     (registration/UserChoice problem)
    #   * a line with the wrong target => arming-state problem
    $note = if ($route.IsRepeat) { '  (repeat of the previous callback)' } else { '' }
    Add-Content $LogFile "$(Get-Date -Format s)  $target <- $safeUrl$note"
    Start-Process -FilePath $exe -ArgumentList $argStr

    # Remember the first delivery of this URL so re-deliveries can follow it.
    if (-not $route.IsRepeat) {
        Set-Content $LastRouteFile "$([datetime]::UtcNow.Ticks)|$urlHash|$target" -Encoding ASCII
    }

    # --- one-shot reset so a later login doesn't silently land in the wrong profile ---
    # The dangerous failure mode is a sticky marker: a personal re-auth landing
    # in the work profile weeks later "succeeds" and is therefore invisible.
    # Resetting to 'default' after every fire makes the safe profile the resting state.
    Set-Content $TargetFile 'default' -Encoding ASCII
}

# Run only when invoked normally. When dot-sourced (InvocationName '.') -- as the
# unit test does -- just define the functions above without executing, so the
# builder can be tested in isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ClaudeShim -Url $Url
}
