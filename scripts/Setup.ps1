<#
.SYNOPSIS
    Installs "clones" of the Claude Desktop app: one isolated profile + one
    desktop shortcut per account, and (optionally) a claude:// login router so
    browser-SSO callbacks land in the profile you intend.

.DESCRIPTION
    For each profile name you pass, this script:
      * binds it to a data directory (and optional Claude Code config dir):
          - the profile named by -DefaultProfile (if any) reuses the STOCK paths
            (%APPDATA%\Claude + the default ~\.claude), i.e. the account the
            normally-installed app is already signed into;
          - every other profile gets a fresh, isolated %APPDATA%\Claude-<name>
            data dir (kept under %APPDATA% so the Cowork VM works -- see the note
            in the loop below) and a ~\.claude-<name> config dir.
        Both are overridable per profile via -DataDir / -ConfigDir hashtables.
      * copies the launcher + router scripts into -InstallDir\bin (so the
        shortcuts keep working even if you delete this repo),
      * writes profiles.json into bin\ so Arm-ClaudeLogin.ps1 and
        Test-ClaudeRouting.ps1 know each profile's directories,
      * creates a "Claude (<Name>)" shortcut on your Desktop that opens the app
        with that profile, using the real Claude icon,
      * unless -NoProtocolRouting: registers a chooseable claude:// handler (the
        shim), then prints the ONE manual Settings step needed to activate it.

    No baked-in assumption about which profile owns the stock paths: pass
    -DefaultProfile None (the default) and every profile is isolated, or name any
    profile to bind it to the stock login.

.PARAMETER Profile
    One or more profile names. Default: Work, Personal.

.PARAMETER DefaultProfile
    Which declared profile (if any) binds to the STOCK paths (%APPDATA%\Claude +
    default ~\.claude). Use 'None' (default) for no such binding -- every profile
    gets its own isolated dirs. Example: -DefaultProfile Personal makes Personal
    reuse the already-signed-in account and isolates the rest.

.PARAMETER ReuseDefaultForWork
    DEPRECATED compatibility alias for -DefaultProfile Work. Ignored if
    -DefaultProfile is given explicitly.

.PARAMETER InstallDir
    Where the launcher scripts (bin\) live. Default: %USERPROFILE%\ClaudeProfiles.
    NOTE: profile *data* always lives under %APPDATA%\<...>, not here -- this is
    required for the Cowork VM to start (the native VM service resolves rootfs.vhdx
    under %APPDATA% regardless of --user-data-dir).

.PARAMETER ConfigDir
    Optional hashtable mapping a profile name to a Claude Code / Cowork config
    directory (CLAUDE_CONFIG_DIR), overriding the derived ~\.claude-<name>.

.PARAMETER DataDir
    Optional hashtable mapping a profile name to a data directory, overriding the
    derived %APPDATA%\Claude-<name>. MUST stay directly under %APPDATA% or Cowork
    breaks (see the Cowork note below).

.PARAMETER NoProtocolRouting
    Skip installing/registering the claude:// login router. Use this if you
    prefer to sequence logins manually (log in one account at a time with the
    others closed).

.PARAMETER LoginShortcuts
    Also create a "Claude (<name>) - Sign in" desktop shortcut per profile that
    arms the router for that profile and opens it, ready for a browser login.

.EXAMPLE
    .\Setup.ps1
    # Creates "Claude (Work)" and "Claude (Personal)"; no stock binding.

.EXAMPLE
    .\Setup.ps1 -Profile Personal,Work -DefaultProfile Personal
    # Personal reuses the stock login; Work is isolated (data + config).

.EXAMPLE
    .\Setup.ps1 -Profile Personal,Client -DefaultProfile Personal `
        -ConfigDir @{ Client = "$env:USERPROFILE\.claude-client" }
#>
[CmdletBinding()]
param(
    [string[]]$Profile = @('Work', 'Personal'),
    [string]$DefaultProfile = 'None',
    [switch]$ReuseDefaultForWork,
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'ClaudeProfiles'),
    [hashtable]$ConfigDir = @{},
    [hashtable]$DataDir = @{},
    [switch]$NoProtocolRouting,
    [switch]$LoginShortcuts
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- resolve the effective "default" (stock-paths) profile -----------------
# -DefaultProfile wins; -ReuseDefaultForWork is a deprecated alias for 'Work'.
if (-not $PSBoundParameters.ContainsKey('DefaultProfile') -and $ReuseDefaultForWork) {
    $DefaultProfile = 'Work'
    Write-Warning "-ReuseDefaultForWork is deprecated; treating it as -DefaultProfile Work."
} elseif ($PSBoundParameters.ContainsKey('DefaultProfile') -and $ReuseDefaultForWork) {
    Write-Warning "-ReuseDefaultForWork ignored because -DefaultProfile was given explicitly."
}
if ($DefaultProfile -ne 'None' -and $Profile -notcontains $DefaultProfile) {
    # Case-insensitive tolerance: normalise to the declared spelling if it matches.
    $hit = $Profile | Where-Object { $_ -ieq $DefaultProfile } | Select-Object -First 1
    if ($hit) { $DefaultProfile = $hit }
    else { throw "-DefaultProfile '$DefaultProfile' is not in -Profile ($($Profile -join ', '))." }
}

# Extracts the highest-resolution icon out of an .exe into a standalone .ico.
# This is what makes shortcut icons survive app updates: the Claude .exe lives
# under C:\Program Files\WindowsApps\Claude_<version>__...\app\Claude.exe, and
# that <version> folder is DELETED whenever Claude auto-updates. A shortcut whose
# IconLocation points straight at that versioned path goes blank after the next
# update + icon-cache rebuild (typically noticed after a reboot). Copying the
# icon once to a stable file under bin\ and pointing every shortcut there avoids
# the dangling path entirely.
function Export-AppIcon {
    param([string]$ExePath, [string]$IcoPath, [int]$Size = 256)
    Add-Type -AssemblyName System.Drawing
    $sig = @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
[DllImport("user32.dll")]
public static extern bool DestroyIcon(IntPtr hIcon);
'@
    $api = Add-Type -MemberDefinition $sig -Name 'IconExtract' -Namespace 'Win32Native' -PassThru

    # Writes a 32-bit, full-colour, PNG-compressed .ico (Vista+ format) from a
    # Bitmap. We deliberately do NOT use Icon.Save(): saving an Icon created from
    # an HICON drops the colour plane and writes only the 1-bit AND mask, which is
    # why the icon came out grey. Rendering to a Bitmap and packing the PNG
    # ourselves preserves colour and alpha.
    function Write-IcoFromBitmap {
        param([System.Drawing.Bitmap]$Bmp, [string]$Path)
        $ms = New-Object System.IO.MemoryStream
        $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $ms.ToArray(); $ms.Dispose()
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([uint16]0)            # reserved
        $bw.Write([uint16]1)            # type = icon
        $bw.Write([uint16]1)            # image count
        $dim = if ($Bmp.Width -ge 256) { 0 } else { [byte]$Bmp.Width }   # 0 means 256
        $bw.Write([byte]$dim)           # width
        $bw.Write([byte]$dim)           # height
        $bw.Write([byte]0)              # palette count
        $bw.Write([byte]0)              # reserved
        $bw.Write([uint16]1)            # colour planes
        $bw.Write([uint16]32)           # bits per pixel
        $bw.Write([uint32]$png.Length)  # image size
        $bw.Write([uint32]22)           # offset = 6 (dir) + 16 (entry)
        $bw.Write($png)
        $bw.Flush(); $bw.Close()
    }

    $h = New-Object IntPtr[] 1
    $id = New-Object int[] 1
    try {
        $n = $api::PrivateExtractIcons($ExePath, 0, $Size, $Size, $h, $id, 1, 0)
        if ($n -gt 0 -and $h[0] -ne [IntPtr]::Zero) {
            $ico = [System.Drawing.Icon]::FromHandle($h[0])
            $bmp = $ico.ToBitmap()       # full 32bpp colour + alpha
            Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
            $bmp.Dispose(); $ico.Dispose()
            return $true
        }
    } catch {
    } finally {
        if ($h[0] -ne [IntPtr]::Zero) { $api::DestroyIcon($h[0]) | Out-Null }
    }
    # Fallback: managed helper (lower-res, but still full colour and a stable file).
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        $bmp = $ico.ToBitmap()
        Write-IcoFromBitmap -Bmp $bmp -Path $IcoPath
        $bmp.Dispose(); $ico.Dispose()
        return $true
    } catch { return $false }
}

# --- Verify the Claude Desktop app is installed and find its icon ---------
$pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) {
    throw "Claude Desktop app not found. Install it from https://claude.ai/download (or the Microsoft Store) first."
}
$iconExe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
Write-Host "Found Claude $($pkg.Version) at $($pkg.InstallLocation)" -ForegroundColor Green

# --- Copy launcher + router scripts to a stable location -------------------
$binDir = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
foreach ($f in 'Launch-Claude.ps1', 'launch.vbs', 'ClaudeOpenShim.ps1', 'Arm-ClaudeLogin.ps1') {
    Copy-Item (Join-Path $scriptRoot $f) $binDir -Force
}
$vbs         = Join-Path $binDir 'launch.vbs'
$shimPath    = Join-Path $binDir 'ClaudeOpenShim.ps1'
$armPath     = Join-Path $binDir 'Arm-ClaudeLogin.ps1'
$profilesJson = Join-Path $binDir 'profiles.json'

# --- Extract the Claude icon to a STABLE path (survives app updates) -------
# See Export-AppIcon above for why pointing IconLocation at the versioned
# WindowsApps .exe makes icons disappear after updates/reboots.
$icoPath = Join-Path $binDir 'claude.ico'
if (Export-AppIcon -ExePath $iconExe -IcoPath $icoPath) {
    $iconLocation = "$icoPath,0"
    Write-Host "Extracted stable icon to $icoPath" -ForegroundColor Green
} else {
    # Last resort: fall back to the versioned exe (may go blank after an update).
    $iconLocation = "$iconExe,0"
    Write-Warning "Could not extract a standalone icon; falling back to the app exe (icon may break after updates)."
}

# --- Create a profile + desktop shortcut for each name --------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
$profileMap = [ordered]@{}

foreach ($name in $Profile) {
    $isDefault = ($DefaultProfile -ne 'None' -and $name -ieq $DefaultProfile)

    if ($isDefault) {
        $resolvedDataDir   = Join-Path $env:APPDATA 'Claude'
        $resolvedConfigDir = ''   # stock ~\.claude; do NOT set CLAUDE_CONFIG_DIR
        Write-Host "  [$name] reuses the stock login at $resolvedDataDir"
    } else {
        # IMPORTANT: isolated profiles must live directly under %APPDATA% (NOT an
        # arbitrary folder such as -InstallDir). Claude Desktop's "Cowork" feature
        # runs its agent inside a Hyper-V VM, and the native VM service resolves
        # the VM image (rootfs.vhdx) at %APPDATA%\<dir-name>\vm_bundles -- it
        # ignores --user-data-dir. If the data dir lives elsewhere, Electron
        # provisions the VM under the data dir but the VM service looks under
        # %APPDATA% and dies with "VHDX file not found". Deriving
        # %APPDATA%\Claude-<name> satisfies this by construction.
        $resolvedDataDir   = Join-Path $env:APPDATA "Claude-$name"
        $resolvedConfigDir = Join-Path $env:USERPROFILE (".claude-" + $name.ToLower())
        Write-Host "  [$name] isolated profile at $resolvedDataDir"
    }

    # Per-profile overrides.
    if ($DataDir.ContainsKey($name))   { $resolvedDataDir   = $DataDir[$name] }
    if ($ConfigDir.ContainsKey($name)) { $resolvedConfigDir = $ConfigDir[$name] }

    New-Item -ItemType Directory -Force -Path $resolvedDataDir | Out-Null
    if ($resolvedConfigDir) {
        New-Item -ItemType Directory -Force -Path $resolvedConfigDir | Out-Null
        Write-Host "      memory/config dir: $resolvedConfigDir"
    }

    $profileMap[$name] = [ordered]@{
        dataDir   = $resolvedDataDir
        configDir = $resolvedConfigDir
        isDefault = [bool]$isDefault
    }

    # Main launch shortcut.
    $lnkPath = Join-Path $desktop "Claude ($name).lnk"
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ($resolvedConfigDir) {
        $sc.Arguments = '"{0}" "{1}" "{2}"' -f $vbs, $resolvedDataDir, $resolvedConfigDir
    } else {
        $sc.Arguments = '"{0}" "{1}"' -f $vbs, $resolvedDataDir
    }
    $sc.IconLocation = $iconLocation
    $sc.Description = "Claude Desktop - $name profile"
    $sc.WorkingDirectory = $binDir
    $sc.Save()
    Write-Host "  -> created shortcut: $lnkPath" -ForegroundColor Cyan

    # Optional "Sign in" shortcut: arm the router for this profile, then launch.
    if ($LoginShortcuts -and -not $NoProtocolRouting) {
        $signLnk = Join-Path $desktop "Claude ($name) - Sign in.lnk"
        $ssc = $wsh.CreateShortcut($signLnk)
        $ssc.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $ssc.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Profile "{1}" -Launch' -f $armPath, $name
        $ssc.IconLocation = $iconLocation
        $ssc.Description = "Arm the claude:// router for the $name profile, then open it to sign in"
        $ssc.WorkingDirectory = $binDir
        $ssc.Save()
        Write-Host "  -> created sign-in shortcut: $signLnk" -ForegroundColor Cyan
    }
}

# --- Write profiles.json (shared contract for Arm/Test scripts) ------------
$profilesObj = [ordered]@{
    defaultProfile = $DefaultProfile
    generated      = (Get-Date -Format s)
    profiles       = $profileMap
}
$profilesObj | ConvertTo-Json -Depth 5 | Set-Content $profilesJson -Encoding UTF8
Write-Host "Wrote profile map: $profilesJson"

# --- Register the claude:// login router (unless opted out) ----------------
if ($NoProtocolRouting) {
    Write-Host ""
    Write-Host "Protocol routing skipped (-NoProtocolRouting). Sequence logins manually:" -ForegroundColor Yellow
    Write-Host "  log into one account at a time with the other profiles closed."
} else {
    # Command that Windows will run for a claude:// activation. It MUST embed a
    # LITERAL expanded path -- Set-ItemProperty writes REG_SZ, which does not
    # expand %USERPROFILE%-style variables.
    $cmd = "conhost --headless powershell -NoProfile -ExecutionPolicy Bypass -File `"$shimPath`" -Url `"%1`""

    # Back up any pre-existing classic-key command ONCE, before it can be
    # overwritten later by Arm-ClaudeLogin.ps1. This preserves (e.g.) a leftover
    # Squirrel registration so Uninstall.ps1 can restore it. Idempotent: only
    # writes 'backup' if it isn't already present.
    $classicCmdKey = 'HKCU:\Software\Classes\claude\shell\open\command'
    if (Test-Path $classicCmdKey) {
        # '' names the key's default value; 'backup' is our named backup slot.
        $existing  = (Get-Item $classicCmdKey).GetValue('', $null)
        $hasBackup = (Get-Item $classicCmdKey).GetValue('backup', $null)
        if ($existing -and -not $hasBackup -and $existing -ne $cmd) {
            Set-ItemProperty $classicCmdKey 'backup' $existing
            Write-Host "Backed up existing claude:// classic-key command to its 'backup' value."
        }
    }

    # ProgId the chooser will point at.
    New-Item 'HKCU:\Software\Classes\ClaudeShim.claude\shell\open\command' -Force | Out-Null
    Set-ItemProperty 'HKCU:\Software\Classes\ClaudeShim.claude' '(Default)' 'URL:Claude Protocol'
    Set-ItemProperty 'HKCU:\Software\Classes\ClaudeShim.claude' 'URL Protocol' ''
    Set-ItemProperty 'HKCU:\Software\Classes\ClaudeShim.claude\shell\open\command' '(Default)' $cmd

    # Register an "application" exposing the claude protocol (Default Apps eligibility).
    New-Item 'HKCU:\Software\ClaudeShim\Capabilities\URLAssociations' -Force | Out-Null
    Set-ItemProperty 'HKCU:\Software\ClaudeShim\Capabilities' 'ApplicationName' 'Claude Login Router'
    Set-ItemProperty 'HKCU:\Software\ClaudeShim\Capabilities' 'ApplicationDescription' 'Routes claude:// logins to the chosen profile'
    Set-ItemProperty 'HKCU:\Software\ClaudeShim\Capabilities\URLAssociations' 'claude' 'ClaudeShim.claude'
    New-Item 'HKCU:\Software\RegisteredApplications' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty 'HKCU:\Software\RegisteredApplications' 'ClaudeShim' 'Software\ClaudeShim\Capabilities'

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " ONE MANUAL STEP to activate claude:// login routing" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " Windows only lets a user (not a script) pick the default"
    Write-Host " handler for a protocol. Do this once:"
    Write-Host ""
    Write-Host "   Settings > Apps > Default apps >"
    Write-Host "     'Choose defaults by link type' > search 'claude' >"
    Write-Host "     select 'Console Window Host'."
    Write-Host ""
    Write-Host " Why 'Console Window Host'? Settings labels a handler after the"
    Write-Host " first exe in its command (here 'conhost'), not our app name."
    Write-Host " This is cosmetic -- it is still the Claude login router."
    Write-Host ""
    Write-Host " If 'claude' doesn't appear, close and reopen Settings"
    Write-Host " (it caches the registered-applications list)."
    Write-Host ""
    Write-Host " Then verify with:  scripts\Test-ClaudeRouting.ps1" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " To route a login:  bin\Arm-ClaudeLogin.ps1 -Profile <name> -Launch"
}

Write-Host ""
Write-Host "Done. Open each shortcut and sign in to the matching account." -ForegroundColor Green
Write-Host "Tip: clicking a shortcut again just focuses that profile's window (single instance per profile)."
