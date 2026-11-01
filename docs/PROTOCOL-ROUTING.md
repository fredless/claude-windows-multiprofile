# claude:// login routing on Windows

How the Claude Desktop app receives `claude://` deep links on Windows, why
browser-SSO callbacks land in the wrong profile when you run more than one
instance, and how this repo's login router fixes it.

Written for a technically capable Windows admin. Everything below was verified
empirically against a real multi-profile setup; where behaviour is inferred
rather than observed, it says so.

> **Scope note.** This is built on *undocumented* Windows + app behaviour. A
> future Claude Desktop release (or native multi-account support) can change or
> obsolete all of it at any time. See [Obsolescence](#obsolescence) at the end.

---

## The problem in one paragraph

Browser login — enterprise SSO **and** consumer *Continue with Google* alike —
happens in your browser and returns to the app through a `claude://…` deep link
(for Google: `claude://login/google-auth?code=…`). Windows delivers that link to **whichever single
application currently owns the `claude://` protocol** — not to the instance that
started the login. With two profiles running (say *Personal* and a work
profile), the callback repeatedly lands in the default profile, so the **work**
token ends up in the **personal** profile. Most multi-instance guides work
around this by telling you to "close everything and log in one account at a
time." This repo instead routes the callback to a profile you choose.

---

## 1. The claude:// delivery chain

When something activates `claude://…`, Windows resolves the handler in this
priority order (highest wins):

| # | Layer | Where | Notes |
|---|-------|-------|-------|
| 1 | **UserChoice** | Newer Windows 11 (observed on 26H2): `HKCU\…\Windows\Shell\Associations\UrlAssociations\claude\UserChoiceLatest`, ProgId in its `ProgId` subkey. Older builds: `HKCU\…\Explorer\UrlAssociations\claude\UserChoice`, ProgId value. | Wins over everything when present. Hash-protected: can only be set legitimately by the user picking a default app in Settings. `Test-ClaudeRouting.ps1` checks both locations. |
| 2 | **MSIX package manifest** | the installed Claude package's `AppxManifest.xml` | When no UserChoice exists, activation goes here and **completely bypasses** the classic registry key below. Delivery goes to the running package process if one exists. |
| 3 | **Classic key** | `HKCU\Software\Classes\claude\shell\open\command` | Only consulted when neither of the above applies. Frequently a **leftover** from an older Squirrel-style install (see §2). |

The counter-intuitive part is layer 2 **bypassing** layer 3. Registering a
custom handler in the classic key does *nothing* while the MSIX manifest
registration is in force — which it is, out of the box, on any machine with the
Store/`claude.ai` app installed.

### How to prove which layer is handling your activations

The router logs every activation to `route.log` (`<install>\bin\route.log`).
Use it as a tripwire together with process inspection:

```powershell
# 1) Fire a real OS-level activation (exercises the whole chain — not the same
#    as invoking the shim script directly):
Start-Process "claude://test/ping"

# 2) Did the shim get it?
Get-Content "$env:USERPROFILE\ClaudeProfiles\bin\route.log" -Tail 3

# 3) What actually launched, and with which profile? (When the router handles
#    the probe it launches nothing -- see §4 -- so a NEW Claude process here
#    means the app itself took the activation.)
Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" |
    Select-Object ProcessId, CommandLine
```

- **A fresh `route.log` line** ⇒ your activation reached the shim ⇒ UserChoice
  points at the router (layer 1). Good.
- **No new line, but Claude opened** ⇒ the activation resolved at layer 2 or 3
  (MSIX manifest / classic key), never touching the router ⇒ the router is not
  the chosen handler. Fix the registration (re-pick in Settings, see §5).

`scripts\Test-ClaudeRouting.ps1` automates all three checks.

**Empirical proof of the layer-2 bypass:** with the router registered only in
the classic key, *all* instances closed, and the router "armed," a `claude://`
activation still launched the default MSIX profile and never touched the shim
(no log line, marker file unconsumed). Only after registering the router as a
*chooseable application* and selecting it in Settings — which creates a valid
UserChoice — did activations start reaching it.

---

## 2. The Squirrel-leftover trap

Older Claude installs used a **Squirrel** installer under
`%LOCALAPPDATA%\AnthropicClaude\` (e.g. `app-1.x.y\claude.exe`, plus
`Update.exe`). Migrating to the MSIX/Store build does **not** always remove it,
and it leaves two hazards behind:

1. **A stale classic-key registration** (`HKCU\Software\Classes\claude\…command`)
   pointing at a versioned `…\AnthropicClaude\app-<old>\claude.exe` path that no
   longer exists.
2. **A `claude.exe` stub + `Update.exe`** that can *re-register* protocol
   handlers if ever run (e.g. by a leftover scheduled task or shortcut).

### The failure it causes

When the classic key is the layer that resolves (no UserChoice, and depending on
how the app registered the manifest), a `claude://` login callback is handed to
a **dead or downgrade-era exe**, producing a login loop: SSO completes in the
browser, the callback fires, nothing usable receives it, the app re-prompts.
This is not multi-profile-specific — single-account users hit it too. See
[`anthropics/claude-code#31476`](https://github.com/anthropics/claude-code/issues/31476),
which documents exactly this classic-key/MSIX interaction causing login loops.

### Detect and clean

```powershell
# Detect:
Test-Path "$env:LOCALAPPDATA\AnthropicClaude"      # $true = leftover present
Get-Item "HKCU:\Software\Classes\claude\shell\open\command" |
    ForEach-Object { $_.GetValue('') }              # inspect the classic command

# Clean (safe once UserChoice owns the protocol, i.e. the router is chosen):
Remove-Item "$env:LOCALAPPDATA\AnthropicClaude" -Recurse -Force
```

`Test-ClaudeRouting.ps1` reports the leftover automatically.

> **Uninstall-order caveat.** If you uninstall the *old* Squirrel app through
> Windows, its uninstaller may delete the **shared** classic `claude` key —
> including a router command you put there. Re-run the router registration
> (`Setup.ps1`) afterwards, or re-arm (`Arm-ClaudeLogin.ps1` reasserts the
> classic key). Because UserChoice (layer 1) is the operative registration once
> chosen, this is usually cosmetic — but reassert to keep the state coherent.

---

## 3. The PowerShell 5.1 quoting trap

Windows PowerShell 5.1's `Start-Process -ArgumentList` joins array elements with
spaces **but does not quote them**. A profile path with spaces therefore
splinters into several argv entries; Chromium reads `--user-data-dir` as ending
at the first space and silently creates a profile at the *truncated* path — so
the token lands in a **third** profile nobody intended.

```powershell
# BROKEN — array elements are space-joined, unquoted:
Start-Process $exe -ArgumentList @("--user-data-dir=$target", $Url)
#   target = C:\Users\John Doe\…\Claude-Client A
#   -> Chromium sees --user-data-dir=C:\Users\John   (truncated at first space!)

# FIXED — build ONE pre-quoted string yourself:
$argStr = "--user-data-dir=`"$target`" `"$Url`""
Start-Process $exe -ArgumentList $argStr
#   -> --user-data-dir="C:\Users\John Doe\…\Claude-Client A" "claude://…"
```

This repo factors the builder into `Get-ClaudeLaunchArgString`
(in `ClaudeOpenShim.ps1`) and unit-tests it in `tests\Test-ArgBuilder.ps1`,
including the spaces-in-path case, so a regression fails CI-style locally rather
than silently misrouting a token. Any code in this repo that launches Claude
with a path must use the same single-pre-quoted-string pattern.

---

## 4. The arm / disarm model

The router reads a one-line marker file, `target.txt`:

- `default` → launch with **no** `--user-data-dir` (the stock `%APPDATA%\Claude`
  profile).
- any path → launch with `--user-data-dir="<path>"`.

You set it with `Arm-ClaudeLogin.ps1 -Profile <name>` **immediately before** a
login. After the shim fires once, it **resets the marker to `default`**.

### Why explicit one-shot arming (not "last-launched")

Zoltak's prior art (see §8) routes callbacks to the *last-launched* profile —
implicit and zero-touch. This repo deliberately chooses **explicit, one-shot**
arming instead:

- **Last-launched misroutes a real case.** Launch work, then later re-auth your
  *personal* account: the personal callback routes to *work* because work was
  launched more recently. Explicit arming states intent per login.
- **The resting state must be safe.** The dangerous failure mode is a *sticky*
  marker: a personal re-auth landing in the work profile weeks later
  "succeeds," so it's invisible. Resetting to `default` after every fire makes
  the safe (stock/personal) profile the resting state — an un-armed activation
  can only ever land somewhere harmless.

### Two exceptions that keep one-shot arming usable

Observed in a real Google sign-in: one-shot arming alone misroutes in two
ordinary situations, so the shim special-cases them without making the marker
sticky.

- **Re-delivered callbacks.** The browser asks "Open Console Window Host?" and
  a user who clicks **Open** again (or whose first click seemed to do nothing)
  re-fires the **identical** `claude://` URL. The first delivery already reset
  the marker, so every repeat used to open the default profile — an extra
  "please sign in" window per click. The shim now remembers the first delivery
  in `last-route.txt` (`<utc ticks>|<sha256 of the URL>|<target>`; only the hash
  is stored, never the URL) and sends an identical URL arriving within
  **5 minutes** to the same target. It applies only while the marker is unarmed
  (a re-delivery always arrives after the reset), and `Arm-ClaudeLogin.ps1`
  clears `last-route.txt` — so an armed login always follows the marker, even
  for a bare deep link that carries no per-login nonce and repeats verbatim.
- **The diagnostic probe.** `Test-ClaudeRouting.ps1` fires `claude://test/ping`.
  It used to go through the normal path: it launched Claude and **consumed an
  armed marker**, so running the diagnostic right after arming silently disarmed
  the next real login. The shim now only logs the probe (`probe (armed: …; not
  launched, marker kept)`).

OAuth codes and tokens in callback URLs are masked (`code=<redacted>`) before
anything is written to `route.log`.

### route.log triage table

`route.log` lines look like: `2026-07-23T09:15:04  <target> <- <url>`, with
`  (repeat of the previous callback)` appended for a re-delivery.

| Symptom during a login | Meaning | Fix |
|---|---|---|
| **No new line at all** | Activation never reached the shim → handler chain resolved at MSIX manifest / classic key. Registration problem. | Re-pick the router in Settings (§5); verify with `Test-ClaudeRouting.ps1`. |
| **Line with the *wrong* target** | Shim ran, but the marker held the wrong profile. Arming-state problem. | You forgot to arm, or armed the wrong profile. Re-arm before retrying. |
| **Several lines with the same URL, the first to the right profile** | The browser re-delivered the callback. Lines marked `(repeat …)` followed the first one, as intended. | Nothing to fix. (Without the repeat note, you're running a pre-fix shim: re-run `Setup.ps1`.) |
| **`probe (armed: …)` line** | `Test-ClaudeRouting.ps1` reached the shim. Nothing was launched and the marker was left as shown. | Nothing to fix. |
| **Line with the right target, but token still wrong** | Delivery reached the right profile dir, but Chromium may have received a truncated path. | Check the running process's `--user-data-dir` (§3 quoting). |
| **Line reads `ERROR: Claude.exe not found`** | MSIX package not resolvable. | Confirm the app is installed (`Get-AppxPackage *Claude*`). |

---

## 5. Operational realities

- **"Console Window Host" in Settings.** The Settings link-type picker labels a
  candidate handler after the **first executable in its registered command**,
  not after its Capabilities `ApplicationName`. The router's command begins with
  `conhost --headless …`, so it appears as **"Console Window Host."** This is
  cosmetic. It is *not* fixed (the fix — a renamed copy of `powershell.exe` — has
  EDR/SmartScreen/servicing downsides). Pick "Console Window Host"; that is the
  router.
- **Windows occasionally resets UserChoice.** Feature updates and app
  re-registration can clear your choice (usually surfaced as a dismissable "how
  do you want to open this?" toast). The fix is simply to re-pick the router in
  **Settings → Apps → Default apps → Choose defaults by link type → `claude`**,
  then re-run the ping check. If the entry doesn't appear, close and reopen
  Settings (it caches the registered-applications list).
- **The router is now in the critical path for ALL `claude://` activations.** A
  broken router = silently dead deep links (logins, "open in app" links). The
  tell is **absence** of a `route.log` line. If routing ever misbehaves and you
  need stock behaviour back immediately, run `Uninstall.ps1` (or
  `Uninstall.ps1 -KeepRouting:$false`) — Windows falls back to the MSIX manifest
  registration automatically.
- **Registry values must be literal expanded paths.** `Set-ItemProperty` writes
  `REG_SZ`, which does **not** expand `%USERPROFILE%`-style variables. The setup
  scripts always write fully-resolved paths.

---

## 6. Cowork VM constraints

Claude Desktop's **Cowork** feature (agentic workspace, scheduled tasks,
artifact storage) runs inside a per-machine **Hyper-V VM**, not just an Electron
window. Two consequences for multi-profile use:

1. **Profile data must live directly under `%APPDATA%`.** The native VM service
   resolves the VM image (`rootfs.vhdx`) at `%APPDATA%\<dir-name>\vm_bundles`,
   **ignoring** `--user-data-dir`. `Setup.ps1` therefore derives isolated
   profiles as `%APPDATA%\Claude-<name>`. A data dir anywhere else makes Cowork
   fail with **"VHDX file not found."**
   - **No junctions/symlinks** for `vm_bundles` — the VM service refuses to open
     reparse points.
2. **Only one Cowork VM can run at a time.** The Hyper-V compute system is *not*
   scoped per profile, so launching Cowork in a second profile while another's
   VM is running fails with `HYPERVISOR_SERVICE_ERROR` / *"a virtual machine …
   with the specified identifier already exists."* You can keep both chat
   windows open; the VM-backed workspace only runs in one profile at a time.

---

## 7. Anti-patterns

### Cloud-synced profile locations (OneDrive / Dropbox / etc.)

**Don't** put a profile data dir inside a cloud-synced folder.

- Electron profiles are constantly churning **LevelDB and lock-file** state;
  sync engines produce conflict copies and Files-On-Demand *dehydration*
  silently breaks a live profile.
- OAuth tokens are **DPAPI-encrypted and machine-bound**, so syncing them buys
  nothing — they won't decrypt on another machine.
- Worst case, a work account's `.credentials.json` ends up in cloud **version
  history**, and two machines refreshing the same token invalidate each other.

**Correct pattern:** keep profile *data* local; if you want to share anything,
selectively sync only `skills/`, `agents/`, and `CLAUDE.md`.

### Shared HOME + `CLAUDE_CONFIG_DIR`

`CLAUDE_CONFIG_DIR` isolates a profile's Claude Code config/memory store. But two
Claude Code instances sharing one real `HOME` may still collide on
`~\.claude.json` (global state that lives *outside* the config dir). This was
reported (Josh Grossman, Feb 2026) and may since be fixed — **verify on your
build** before relying on full isolation. It does not affect Claude Desktop login
isolation (that's the `--user-data-dir` layer).

---

## 8. Alternatives & prior art

| Project / approach | What it does | When to prefer it |
|---|---|---|
| **[Zoltak-Dev/ai-multi-instance](https://github.com/Zoltak-Dev/ai-multi-instance)** (MIT) | Python TUI profile manager for Claude + Codex. Its "OAuth login patch" registers itself under `UrlAssociations` **with a computed valid UserChoice hash**, routing callbacks to the **last-launched** profile. | If you want a full TUI manager and implicit last-launched routing, and don't mind Python. **Also the source of the `--user-data-dir` technique this repo builds on**, and the prior art for the deferred UserChoice-hash automation (§ Future work). |
| **[sypnose-cloud/claude-desktop-multi](https://github.com/sypnose-cloud/claude-desktop-multi)** | Portable-copy approach: robocopies the app out of `WindowsApps`; SSO handled by **sequencing** only. | When in-place MSIX activation is undesirable and you're OK copying the app. |
| **Surface split (browser profile)** | Do the enterprise account entirely in a **browser profile** (claude.ai in a dedicated Chrome/Edge profile); keep the desktop app for the personal account. | The **zero-maintenance baseline**. No protocol hacking, survives every app update. Worth recommending to anyone who doesn't need the *desktop* app for both accounts. |

**Design difference vs. Zoltak (worth internalising):** last-launched routing is
frictionless but misroutes the "personal re-auth while work was launched more
recently" case; explicit one-shot arming trades a small manual step for a safe
resting state. See §4.

---

## Future work

**Automate the UserChoice pick (currently the one manual step).** Windows lets
only a *user* set a protocol default, protected by a per-user hash on the
`UserChoice` key. Zoltak's `_userchoice.py` computes a valid hash and writes
`UserChoice` directly. Porting that algorithm to PowerShell would let `Setup.ps1`
register the router with **no** Settings visit, and re-assert it automatically
after Windows resets it. Requirements when this is done:

- Port from the MIT-licensed source with credit retained.
- Verify **UCPD** (User Choice Protection Driver) does not guard custom schemes
  like `claude` — it protects `http`/`https` and some file types; custom
  protocols appeared writable-with-valid-hash in Zoltak's working implementation,
  but confirm on a current Windows build.

Until then, the one Settings pick (§5) is the only manual step.

---

## Obsolescence

This tool relies on undocumented interactions between Windows protocol handling
and the Claude Desktop MSIX package. Any of the following can obsolete it:

- Native multi-account support in Claude Desktop.
- Changes to how the app registers/handles `claude://` (see `#31476` — Anthropic
  is actively touching this area).
- Windows hardening of `UserChoice` / protocol activation.

It's an **unofficial community tool**. It does not modify, repackage, or
redistribute the Claude app — it only launches the officially installed app with
a standard Chromium flag and registers an HKCU protocol handler. Use in
accordance with Anthropic's terms.
