<#
.SYNOPSIS
    Removes the desktop shortcuts and claude:// login router created by
    Setup.ps1, returning the machine to stock protocol handling. Optionally
    deletes the profile data (logins/history) too.

.DESCRIPTION
    Undoes Setup.ps1 symmetrically:
      * removes the "Claude (<name>)" and "Claude (<name>) - Sign in" shortcuts,
      * removes the router registry entries (ProgId, RegisteredApplications
        entry, Capabilities), and either restores the classic claude:// key's
        previous value from the backup Setup saved, or deletes the key,
      * removes only the router files Setup installed into bin\
        (ClaudeOpenShim.ps1, Arm-ClaudeLogin.ps1, target.txt, route.log,
        profiles.json) -- never touches artifacts it did not create.

    After cleanup, Windows falls back to the Claude MSIX package's own manifest
    registration for claude:// (stock behaviour returns automatically), and the
    Settings default-app choice self-clears once the ProgId is gone.

.PARAMETER Profile
    Profile names to remove. Default: read from profiles.json, else Work, Personal.

.PARAMETER InstallDir
    Where the launcher scripts (bin\) were installed. Default:
    %USERPROFILE%\ClaudeProfiles.

.PARAMETER RemoveData
    Also delete each profile's isolated data dir (%APPDATA%\Claude-<name>) and
    config dir (~\.claude-<name>). Signs you out and erases local history. The
    stock %APPDATA%\Claude / default ~\.claude paths are never deleted.

.PARAMETER KeepRouting
    Leave the claude:// router registration and files in place; only remove
    shortcuts (and data, if -RemoveData).
#>
[CmdletBinding()]
param(
    [string[]]$Profile,
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [switch]$RemoveData,
    [switch]$KeepRouting
)

$desktop      = [Environment]::GetFolderPath('Desktop')
$binDir       = Join-Path $InstallDir 'bin'
$profilesJson = Join-Path $binDir 'profiles.json'

# --- figure out which profiles + directories to act on ---------------------
$profileInfo = @{}
if (Test-Path $profilesJson) {
    try {
        $cfg = Get-Content $profilesJson -Raw | ConvertFrom-Json
        foreach ($p in $cfg.profiles.PSObject.Properties) {
            $profileInfo[$p.Name] = $p.Value
        }
    } catch {
        Write-Warning "Could not parse $profilesJson; falling back to name-based defaults."
    }
}
if (-not $Profile) {
    $Profile = if ($profileInfo.Count) { @($profileInfo.Keys) } else { @('Work', 'Personal') }
}

foreach ($name in $Profile) {
    foreach ($suffix in '', ' - Sign in') {
        $lnk = Join-Path $desktop "Claude ($name)$suffix.lnk"
        if (Test-Path $lnk) {
            Remove-Item $lnk -Force
            Write-Host "Removed shortcut: $lnk" -ForegroundColor Yellow
        }
    }

    if ($RemoveData) {
        # Prefer the recorded dirs; else derive the Setup.ps1 convention.
        if ($profileInfo.ContainsKey($name)) {
            $info      = $profileInfo[$name]
            $dataDir   = $info.dataDir
            $configDir = $info.configDir
            $isDefault = [bool]$info.isDefault
        } else {
            $dataDir   = Join-Path $env:APPDATA "Claude-$name"
            $configDir = Join-Path $env:USERPROFILE (".claude-" + $name.ToLower())
            $isDefault = $false
        }

        $stockData = Join-Path $env:APPDATA 'Claude'
        if ($isDefault -or $dataDir -ieq $stockData) {
            Write-Host "Skipping data removal for '$name' (stock/shared main login)." -ForegroundColor DarkYellow
        } else {
            if ($dataDir -and (Test-Path $dataDir)) {
                Remove-Item $dataDir -Recurse -Force
                Write-Host "Removed profile data: $dataDir" -ForegroundColor Yellow
            }
            if ($configDir -and (Test-Path $configDir)) {
                Remove-Item $configDir -Recurse -Force
                Write-Host "Removed config dir:   $configDir" -ForegroundColor Yellow
            }
        }
    }
}

# --- remove the claude:// router (registry + files) ------------------------
if (-not $KeepRouting) {
    # ProgId + application registration.
    Remove-Item 'HKCU:\Software\Classes\ClaudeShim.claude' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'HKCU:\Software\ClaudeShim' -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path 'HKCU:\Software\RegisteredApplications') {
        Remove-ItemProperty 'HKCU:\Software\RegisteredApplications' 'ClaudeShim' -ErrorAction SilentlyContinue
    }

    # Classic claude:// key: restore the backed-up command, or delete the key.
    $classicKey    = 'HKCU:\Software\Classes\claude'
    $classicCmdKey = "$classicKey\shell\open\command"
    if (Test-Path $classicCmdKey) {
        $backup = (Get-Item $classicCmdKey).GetValue('backup', $null)
        if ($backup) {
            Set-ItemProperty $classicCmdKey '(Default)' $backup
            Remove-ItemProperty $classicCmdKey 'backup' -ErrorAction SilentlyContinue
            Write-Host "Restored the classic claude:// command from its backup value." -ForegroundColor Yellow
        } else {
            Remove-Item $classicKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Removed the classic claude:// registration." -ForegroundColor Yellow
        }
    }

    # Router files Setup installed into bin\ (only these known names).
    foreach ($f in 'ClaudeOpenShim.ps1', 'Arm-ClaudeLogin.ps1', 'target.txt', 'last-route.txt', 'route.log', 'profiles.json') {
        $path = Join-Path $binDir $f
        if (Test-Path $path) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            Write-Host "Removed router file: $path" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "claude:// routing removed. Windows will now fall back to the Claude" -ForegroundColor Green
    Write-Host "MSIX app's own protocol registration (stock behaviour). If you had"
    Write-Host "picked the router in Settings, that choice self-clears now that its"
    Write-Host "ProgId is gone."
}

Write-Host "Done."
