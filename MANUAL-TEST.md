# Manual test checklist

Automated tests can't exercise Windows protocol activation, MSIX, or the
Settings UI, so run this on a real machine after changing the setup/router
scripts. Parameterised on purpose — substitute your own values:

| Placeholder | Meaning | Example |
|---|---|---|
| `<INSTALL_DIR>` | `-InstallDir` (bin lives at `<INSTALL_DIR>\bin`) | `%USERPROFILE%\ClaudeProfiles` |
| `<DEFAULT>` | profile bound to the stock paths | `Personal` |
| `<ISOLATED>` | an isolated profile | `Work` |
| `<ISOLATED_DIR>` | its data dir | `%APPDATA%\Claude-Work` |

`<BIN>` below means `<INSTALL_DIR>\bin`.

---

## 0. Prerequisite

- [ ] Only the **MSIX** Claude app is installed
      (`Get-AppxPackage *Claude*` returns a package;
      `Test-Path "$env:LOCALAPPDATA\AnthropicClaude"` is `$false`, or you accept
      the Squirrel-leftover warning).

## 1. Fresh setup (acceptance #1)

- [ ] `powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -Profile <DEFAULT>,<ISOLATED> -DefaultProfile <DEFAULT>`
      completes with no errors.
- [ ] Desktop has **Claude (\<DEFAULT>)** and **Claude (\<ISOLATED>)** shortcuts.
- [ ] `<BIN>` contains `ClaudeOpenShim.ps1`, `Arm-ClaudeLogin.ps1`,
      `profiles.json`, `claude.ico`, `Launch-Claude.ps1`, `launch.vbs`.
- [ ] `profiles.json` shows `<DEFAULT>` with `"isDefault": true` and stock
      `%APPDATA%\Claude`; `<ISOLATED>` with `%APPDATA%\Claude-<ISOLATED>`.
- [ ] Setup printed the **one manual step** block (Settings → Default apps →
      link type → `claude` → **Console Window Host**).
- [ ] Do the Settings pick.
- [ ] `powershell -ExecutionPolicy Bypass -File scripts\Test-ClaudeRouting.ps1`
      → **UserChoice (or UserChoiceLatest) ProgId = ClaudeShim.claude**, and the
      `claude://test/ping` probe shows a **fresh `route.log` line**.

## 2. Armed routing with both instances running (acceptance #2)

- [ ] Launch **both** profiles (both windows open).
- [ ] `& "<BIN>\Arm-ClaudeLogin.ps1" -Profile <ISOLATED>` prints
      `Armed: … [<ISOLATED>] (target: <ISOLATED_DIR>)`.
- [ ] Start a browser login for the `<ISOLATED>` account; complete SSO.
- [ ] The callback lands in the **`<ISOLATED>`** window (token/account correct).
- [ ] `Get-Content "<BIN>\target.txt"` now reads `default`.
- [ ] `route.log` last line shows `<ISOLATED_DIR> <- claude://…` with the OAuth
      `code=` value shown as `<redacted>`.

### 2b. Repeated "Open" clicks and the probe

- [ ] Repeat §2, but click **Open** on the browser's handler prompt two or
      three times. Every extra `route.log` line for that URL reads
      `<ISOLATED_DIR> <- … (repeat of the previous callback)`, and **no** extra
      window of the default profile appears.
- [ ] Arm `<ISOLATED>`, run `Test-ClaudeRouting.ps1`, then
      `Get-Content "<BIN>\target.txt"` still reads `<ISOLATED_DIR>`; the probe
      line reads `probe (armed: <ISOLATED_DIR>; not launched, marker kept)` and
      no Claude window opened. Disarm with `Arm-ClaudeLogin.ps1 -Profile default`.

## 3. Unarmed = safe resting state (acceptance #3)

- [ ] Without arming, fire `Start-Process "claude://manual-test/unarmed"`.
- [ ] `route.log` shows `default <- claude://manual-test/unarmed` (routes to
      the stock profile, not an isolated one).

## 4. Spaces in path survive quoting (acceptance #4)

- [ ] Set up a profile whose data dir contains a space (e.g.
      `-DataDir @{ ClientA = "$env:APPDATA\Claude-Client A" }`).
- [ ] Arm + launch it.
- [ ] `Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" | Select CommandLine`
      shows `--user-data-dir="…\Claude-Client A"` as **one quoted value** (not
      truncated at the space). `Test-ClaudeRouting.ps1` reports it intact.
- [ ] `powershell -ExecutionPolicy Bypass -File tests\Test-ArgBuilder.ps1` passes.
- [ ] `powershell -ExecutionPolicy Bypass -File tests\Test-ShimRouting.ps1` passes.

## 5. Uninstall symmetry (acceptance #5)

- [ ] `powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1` (no
      `-RemoveData`) removes shortcuts + router files + registry entries.
- [ ] Profile **data dirs still exist** (no data loss without `-RemoveData`).
- [ ] Registry: `HKCU:\Software\Classes\ClaudeShim.claude`,
      `HKCU:\Software\ClaudeShim`, and
      `RegisteredApplications\ClaudeShim` are **gone**; the classic `claude` key
      is restored from backup or removed.
- [ ] A normal `claude://` login now works via the app's own MSIX registration.
- [ ] `Uninstall.ps1 -RemoveData` additionally deletes `<ISOLATED_DIR>` and its
      config dir, but **never** `%APPDATA%\Claude` / the default `~\.claude`.

## 6. Hygiene (acceptance #6, #8)

- [ ] No admin prompt appeared during any step.
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` is clean.
- [ ] `git check-ignore HANDOFF-claude-desktop-clone-fork.md LOCAL-NOTES.local.md`
      lists both (they're excluded).
- [ ] `git grep -nEi "<your-username>|<employer-name>" -- ':!*.local.md' ':!HANDOFF*'`
      finds nothing machine-specific in tracked, pushable files.

## 7. Recovery: "Windows reset my UserChoice"

- [ ] Re-pick the router in Settings (link type `claude` → Console Window Host).
- [ ] Re-run `Test-ClaudeRouting.ps1`; the ping probe logs a fresh line again.
