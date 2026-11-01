<#
.SYNOPSIS
    Unit tests for ClaudeOpenShim.ps1's routing helpers.

.DESCRIPTION
    Covers the behaviour that keeps one-shot arming usable in a real browser
    login:
      * Resolve-ClaudeRouteTarget -- a re-delivered callback (same URL, inside
        the repeat window) follows the first delivery instead of the reset
        marker; anything else follows the marker.
      * Test-ClaudeProbeUrl -- only the diagnostic URL is treated as a probe.
      * Get-ClaudeLogSafeUrl -- OAuth codes/tokens never reach route.log.

    Dot-sources the shim (which only defines its functions when dot-sourced).
    No Pester dependency; runs on Windows PowerShell 5.1. Exits non-zero if any
    case fails.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ShimRouting.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$shim = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ClaudeOpenShim.ps1'
if (-not (Test-Path $shim)) { throw "Shim not found at $shim" }

. $shim

$failures = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:failures++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        expected: $Expected"
        Write-Host "        actual:   $Actual"
    }
}

$now  = [datetime]::new(2026, 11, 1, 15, 0, 0, [System.DateTimeKind]::Utc)
$alt  = 'C:\Users\me\AppData\Roaming\Claude-Alt'
$hash = Get-ClaudeUrlHash 'claude://login/google-auth?code=abc&hop_nonce=n1'
$fresh = "$($now.AddSeconds(-30).Ticks)|$hash|$alt"

Write-Host "Resolve-ClaudeRouteTarget"
$r = Resolve-ClaudeRouteTarget -Marker $alt -UrlHash $hash -LastRoute $null -NowUtc $now
Assert-Equal 'no history -> follows the armed marker' $alt $r.Target
Assert-Equal 'no history -> not a repeat' $false $r.IsRepeat

$r = Resolve-ClaudeRouteTarget -Marker 'default' -UrlHash $hash -LastRoute $fresh -NowUtc $now
Assert-Equal 'same URL 30s later -> follows the first delivery, not the reset marker' $alt $r.Target
Assert-Equal 'same URL 30s later -> flagged as repeat' $true $r.IsRepeat

$other = Get-ClaudeUrlHash 'claude://login/google-auth?code=xyz&hop_nonce=n2'
$r = Resolve-ClaudeRouteTarget -Marker 'default' -UrlHash $other -LastRoute $fresh -NowUtc $now
Assert-Equal 'different URL -> follows the marker' 'default' $r.Target

$stale = "$($now.AddSeconds(-301).Ticks)|$hash|$alt"
$r = Resolve-ClaudeRouteTarget -Marker 'default' -UrlHash $hash -LastRoute $stale -NowUtc $now -WindowSeconds 300
Assert-Equal 'same URL after the window -> follows the marker' 'default' $r.Target

$future = "$($now.AddSeconds(60).Ticks)|$hash|$alt"
$r = Resolve-ClaudeRouteTarget -Marker 'default' -UrlHash $hash -LastRoute $future -NowUtc $now
Assert-Equal 'timestamp in the future (clock change) -> follows the marker' 'default' $r.Target

$work = 'C:\Users\me\AppData\Roaming\Claude-Work'
$r = Resolve-ClaudeRouteTarget -Marker $work -UrlHash $hash -LastRoute $fresh -NowUtc $now
Assert-Equal 'armed marker beats matching history (bare link re-armed elsewhere)' $work $r.Target
Assert-Equal 'armed marker beats matching history -> not a repeat' $false $r.IsRepeat

foreach ($bad in 'garbage', "notanumber|$hash|$alt", "$($now.Ticks)|$hash|", "-5|$hash|$alt", "$([long]::MaxValue)|$hash|$alt") {
    $r = Resolve-ClaudeRouteTarget -Marker 'default' -UrlHash $hash -LastRoute $bad -NowUtc $now
    Assert-Equal "malformed history '$bad' -> follows the marker" 'default' $r.Target
}

$r = Resolve-ClaudeRouteTarget -Marker '' -UrlHash $hash -LastRoute $null -NowUtc $now
Assert-Equal 'empty marker -> default' 'default' $r.Target

Write-Host "Test-ClaudeProbeUrl"
Assert-Equal 'diagnostic URL is a probe' $true (Test-ClaudeProbeUrl 'claude://test/ping')
Assert-Equal 'diagnostic URL with trailing slash is a probe' $true (Test-ClaudeProbeUrl 'claude://test/ping/')
Assert-Equal 'login callback is not a probe' $false (Test-ClaudeProbeUrl 'claude://login/google-auth?code=abc')
Assert-Equal 'look-alike path is not a probe' $false (Test-ClaudeProbeUrl 'claude://test/ping-me')

Write-Host "Get-ClaudeLogSafeUrl"
Assert-Equal 'masks the OAuth code, keeps other params' `
    'claude://login/google-auth?code=<redacted>&anon_id=a1&hop_nonce=n1' `
    (Get-ClaudeLogSafeUrl 'claude://login/google-auth?code=SECRET123&anon_id=a1&hop_nonce=n1')
Assert-Equal 'masks token and state anywhere in the query' `
    'claude://oauth/callback?x=1&state=<redacted>&access_token=<redacted>' `
    (Get-ClaudeLogSafeUrl 'claude://oauth/callback?x=1&state=s3&access_token=t0k')
Assert-Equal 'masks fragment-style credentials' `
    'claude://cb#access_token=<redacted>&x=1' `
    (Get-ClaudeLogSafeUrl 'claude://cb#access_token=t0k&x=1')
Assert-Equal 'masks refresh_token and sessionKey' `
    'claude://cb?refresh_token=<redacted>&sessionKey=<redacted>&hop_nonce=n1' `
    (Get-ClaudeLogSafeUrl 'claude://cb?refresh_token=r1&sessionKey=s1&hop_nonce=n1')
Assert-Equal 'URL without secrets is unchanged' 'claude://test/ping' (Get-ClaudeLogSafeUrl 'claude://test/ping')

Write-Host ""
if ($failures -gt 0) {
    Write-Error "$failures test(s) failed."
    exit 1
}
Write-Host "All shim routing tests passed." -ForegroundColor Green
