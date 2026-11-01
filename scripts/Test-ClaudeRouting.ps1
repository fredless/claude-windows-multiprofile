<#
.SYNOPSIS
    Diagnoses the claude:// login-routing setup: what's installed, how the
    protocol is registered, whether an activation actually reaches the shim, and
    whether running instances kept their --user-data-dir intact.

.DESCRIPTION
    Read-only except for one deliberate probe: with -Ping (default) it fires
    Start-Process "claude://test/ping" and checks whether the shim wrote a fresh
    line to route.log. That probe exercises the WHOLE OS handler-resolution chain
    (UserChoice > MSIX manifest > classic key), which directly invoking the shim
    script does not. When the router handles it, the shim only logs the probe:
    no Claude window opens and an armed login stays armed. (If the probe opens a
    Claude window, the activation went to the app itself, not the router.)

    See docs/PROTOCOL-ROUTING.md for how to read the results (especially the
    route.log triage table).

.PARAMETER InstallDir
    Where the launcher scripts (bin\) were installed. Default:
    %USERPROFILE%\ClaudeProfiles.

.PARAMETER NoPing
    Skip the live claude://test/ping activation probe.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$NoPing
)

$binDir  = Join-Path $InstallDir 'bin'
$logFile = Join-Path $binDir 'route.log'

function Write-Section { param([string]$Title) Write-Host "`n=== $Title ===" -ForegroundColor Cyan }

# --- 1) Installed Claude flavours ------------------------------------------
Write-Section 'Installed Claude app(s)'
$pkgs = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
if ($pkgs) {
    foreach ($p in ($pkgs | Sort-Object Version -Descending)) {
        Write-Host ("  MSIX: {0}  {1}" -f $p.Version, $p.InstallLocation) -ForegroundColor Green
    }
} else {
    Write-Host "  MSIX: none found (Get-AppxPackage *Claude*)." -ForegroundColor Red
}
$squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
if (Test-Path $squirrel) {
    Write-Warning "Squirrel-era leftover present at $squirrel."
    Write-Host "    This old install can re-register a stale claude:// classic-key handler"
    Write-Host "    and cause login loops (see docs/PROTOCOL-ROUTING.md, 'Squirrel trap')."
    Write-Host "    Safe to delete once UserChoice owns the protocol."
} else {
    Write-Host "  Squirrel leftover: none (clean)." -ForegroundColor Green
}

# --- 2) Protocol registration state ----------------------------------------
Write-Section 'claude:// registration (HKCU)'

function Show-KeyDefault {
    param([string]$Label, [string]$Key)
    if (Test-Path $Key) {
        $val = (Get-Item $Key).GetValue('', '(no default value)')
        Write-Host ("  {0}:`n    {1}" -f $Label, $val)
    } else {
        Write-Host "  ${Label}: (not present)"
    }
}

Show-KeyDefault 'Classic key command' 'HKCU:\Software\Classes\claude\shell\open\command'
$classicCmdKey = 'HKCU:\Software\Classes\claude\shell\open\command'
if (Test-Path $classicCmdKey) {
    $bk = (Get-Item $classicCmdKey).GetValue('backup', $null)
    if ($bk) { Write-Host "    backup value: $bk" -ForegroundColor DarkGray }
}
Show-KeyDefault 'Router ProgId command' 'HKCU:\Software\Classes\ClaudeShim.claude\shell\open\command'

$regApps = 'HKCU:\Software\RegisteredApplications'
$hasApp = (Test-Path $regApps) -and ((Get-Item $regApps).GetValue('ClaudeShim', $null))
Write-Host ("  RegisteredApplications\ClaudeShim: {0}" -f $(if ($hasApp) { 'present' } else { 'absent' }))

# Where Windows stores the user's pick depends on the build:
#   * newer Windows 11 (seen on 24H2+/26H2): Shell\Associations\UrlAssociations\
#     claude\UserChoiceLatest, with the ProgId in a ProgId SUBKEY;
#   * earlier builds: Explorer\UrlAssociations\claude\UserChoice, ProgId value.
# Check the newer location first; report whichever holds a ProgId.
function Get-ClaudeUserChoice {
    $candidates = @(
        @{ Label = 'UserChoiceLatest'; Path = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude\UserChoiceLatest\ProgId' },
        @{ Label = 'UserChoice';       Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UrlAssociations\claude\UserChoice' }
    )
    foreach ($c in $candidates) {
        if (-not (Test-Path $c.Path)) { continue }
        $id = (Get-ItemProperty $c.Path -ErrorAction SilentlyContinue).ProgId
        if ($id) { return @{ Label = $c.Label; ProgId = $id } }
    }
    return $null
}

$choice = Get-ClaudeUserChoice
if ($choice) {
    $progId = $choice.ProgId
    $color = if ($progId -eq 'ClaudeShim.claude') { 'Green' } else { 'Yellow' }
    Write-Host "  $($choice.Label) ProgId: $progId" -ForegroundColor $color
    if ($progId -ne 'ClaudeShim.claude') {
        Write-Host "    (Not the router. Pick 'Console Window Host' in Settings > Default apps"
        Write-Host "     > Choose defaults by link type > claude.)"
    }
} else {
    Write-Host "  UserChoice: (not set)  <- the router is NOT active until you pick it in Settings." -ForegroundColor Yellow
}

# --- 3) Live activation probe ----------------------------------------------
if (-not $NoPing) {
    Write-Section 'Live activation probe (claude://test/ping)'
    $before = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { -1 }
    Start-Process 'claude://test/ping'
    Start-Sleep -Seconds 2
    $after = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { -1 }
    if ($after -gt $before) {
        $last = Get-Content $logFile -Tail 1
        Write-Host "  OK: shim logged a fresh line:" -ForegroundColor Green
        Write-Host "    $last"
        Write-Host "    (The probe launches nothing and leaves an armed login armed.)"
    } else {
        Write-Host "  NO new route.log line." -ForegroundColor Red
        Write-Host "    The activation never reached the shim -> the handler chain resolved"
        Write-Host "    somewhere else (UserChoice not set to the router, or set to the MSIX"
        Write-Host "    app / classic key). Fix the registration; see PROTOCOL-ROUTING.md."
    }
} else {
    Write-Section 'Live activation probe'
    Write-Host "  skipped (-NoPing)."
}

# --- 4) Running instances: did --user-data-dir survive quoting? ------------
Write-Section 'Running Claude.exe instances'
$procs = Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue
if ($procs) {
    foreach ($proc in $procs) {
        $cl = $proc.CommandLine
        Write-Host "  PID $($proc.ProcessId): $cl"
        if ($cl -match '--user-data-dir="([^"]+)"') {
            Write-Host "    user-data-dir (quoted, intact): $($Matches[1])" -ForegroundColor Green
        } elseif ($cl -match '--user-data-dir=(\S+)') {
            Write-Host "    user-data-dir: $($Matches[1])" -ForegroundColor Green
        } elseif ($cl -match '--user-data-dir') {
            Write-Host "    WARNING: --user-data-dir present but value looks split (quoting bug?)." -ForegroundColor Red
        } else {
            Write-Host "    (stock profile: no --user-data-dir)"
        }
    }
} else {
    Write-Host "  none running."
}

Write-Host ""
