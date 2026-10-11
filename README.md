# claude-desktop-clone

Run **multiple isolated instances of the Claude Desktop app on Windows** — one
per account (e.g. *Work* and *Personal*) — side by side, each with its own
login, history, and settings.

The official Claude Desktop app (installed from the Microsoft Store / claude.ai)
only supports **one account at a time** and refuses to open a second window.
This repo works around that with a tiny, dependency-free launcher.

> 🇻🇳 Bản tóm tắt tiếng Việt ở [cuối README](#tiếng-việt--quickstart).

---

## How it works

The Claude Desktop app is an **Electron / Chromium** application. Chromium
accepts the standard `--user-data-dir` flag, and it keys its *single-instance
lock* on that directory. So:

> **Different `--user-data-dir` → different lock → a second instance runs,
> signed into a different account.**

The only Windows-specific wrinkle is that the app is shipped as an **MSIX
package**, so its executable lives under a versioned, permission-restricted
path:

```
C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\app\Claude.exe
```

The launcher resolves that path at runtime via `Get-AppxPackage` (so it survives
app updates) and starts it with a chosen data directory:

```powershell
Claude.exe --user-data-dir="C:\Users\<you>\ClaudeProfiles\personal"
```

That's the whole trick. No patching, no copying the app, no admin rights.

> **Credits:** the `--user-data-dir` technique for Claude, and the prior art for
> computing a valid Windows `UserChoice` hash (see the login router below), are
> both from [Zoltak-Dev/ai-multi-instance](https://github.com/Zoltak-Dev/ai-multi-instance).
> This repo began as a fork of
> [vodongha/claude-desktop-clone](https://github.com/vodongha/claude-desktop-clone)
> — a small, native (PowerShell + VBScript) reimplementation focused on Claude
> only, with desktop shortcuts and a one-command setup — and adds the `claude://`
> login router.

---

## Requirements

- Windows 10/11
- The official **Claude Desktop app** installed
  ([claude.ai/download](https://claude.ai/download) or Microsoft Store)
- No admin rights, no Python, no extra dependencies

---

## Quick start

```powershell
git clone https://github.com/fredless/claude-windows-multiprofile.git
cd claude-windows-multiprofile

# Create "Claude (Personal)" + "Claude (Work)" shortcuts on your Desktop.
# -DefaultProfile Personal keeps your already-signed-in account for Personal;
# every other profile gets its own isolated login.
powershell -ExecutionPolicy Bypass -Command "& .\scripts\Setup.ps1 -Profile Personal,Work -DefaultProfile Personal"
```

Then:

1. Double-click **Claude (Personal)** → your existing account (no re-login).
2. Double-click **Claude (Work)** → a fresh window; sign in to the other
   account.

Both windows now run at the same time, fully isolated.

> **Which profile owns the stock login?** `-DefaultProfile <name>` names the one
> profile that reuses the app's stock paths (`%APPDATA%\Claude` + the default
> `~\.claude`); everything else is isolated. Use `-DefaultProfile None` (the
> default) to isolate *every* profile. No assumption is baked in about which
> account is "primary."

### Custom profiles

```powershell
# Any names you like; each gets its own isolated login + shortcut.
powershell -ExecutionPolicy Bypass -Command "& .\scripts\Setup.ps1 -Profile Personal,ClientA,ClientB"
```

### Different install location

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Setup.ps1 -InstallDir "D:\ClaudeProfiles"
```

### Isolate Claude Code / Cowork memory per profile

By default, instances only isolate the **login** (Chromium `--user-data-dir`).
The embedded **Claude Code / Cowork** still uses the shared `~/.claude` config
(memory, settings). To give a profile its *own* memory store too, point its
`CLAUDE_CONFIG_DIR` at a dedicated directory via `-ConfigDir`:

```powershell
# NOTE: a real hashtable -> call the script directly (not via -File):
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
```

Now the **Personal** instance's Claude Code memory lives in
`~/.claude-personal\projects\<dir>\memory\`, fully separate from the work
account — and it's the same store the `claude-personal` CLI uses (if you set one
up). Manual equivalent for any launcher:

```text
wscript.exe launch.vbs "<profile-data-dir>" "<claude-config-dir>"
```

---

## Enterprise SSO / login routing

Browser-based SSO returns to the app through a `claude://` deep link. With two
profiles running, Windows delivers that callback to whichever profile owns the
protocol — so a **work** SSO token can land in the **personal** profile. Older
guides work around this by telling you to log in one account at a time with the
others closed.

This repo instead installs a small **login router**: a `claude://` handler that
sends the next callback to the profile you choose. The flow is **setup → one
Settings pick → arm → log in**:

1. **Setup** (from Quick start) registers the router. It then prints one manual
   step you do **once**:

   > Settings → Apps → Default apps → *Choose defaults by link type* → search
   > `claude` → select **Console Window Host**.

   (It's labelled "Console Window Host" because Windows names a handler after the
   first program in its command; it *is* the Claude login router. If `claude`
   doesn't appear, close and reopen Settings.)

2. **Arm** the profile you're about to log into, then log in:

   ```powershell
   # Route the NEXT claude:// login to the "Work" profile and open it:
   & "$env:USERPROFILE\ClaudeProfiles\bin\Arm-ClaudeLogin.ps1" -Profile Work -Launch
   ```

   Arming is a one-shot statement of intent: after the callback fires, the router
   resets to the safe default profile, so a later personal re-auth can't silently
   land in the work profile. (Add `-LoginShortcuts` to `Setup.ps1` to get a
   "Claude (\<name\>) - Sign in" desktop shortcut that arms + launches in one
   click.)

3. **Verify** anytime:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\Test-ClaudeRouting.ps1
   ```

Prefer to sequence logins manually instead? Run `Setup.ps1 -NoProtocolRouting`
and log in one account at a time.

**Full mechanics** — the UserChoice > MSIX-manifest > classic-key delivery
chain, the Squirrel-leftover login-loop trap, the arm/disarm model and
`route.log` triage — are documented in
**[docs/PROTOCOL-ROUTING.md](docs/PROTOCOL-ROUTING.md)**.

---

## What gets created

```
%USERPROFILE%\ClaudeProfiles\
└── bin\
    ├── Launch-Claude.ps1     # resolves the MSIX exe, launches with --user-data-dir
    ├── launch.vbs            # runs the .ps1 hidden (no console flash)
    ├── ClaudeOpenShim.ps1    # claude:// login router (reads target.txt)
    ├── Arm-ClaudeLogin.ps1   # arms the router for the next login
    ├── profiles.json         # profile → data/config dir map (shared by the scripts)
    ├── target.txt            # one-shot routing marker (created on first arm)
    ├── route.log             # routing tripwire log (created on first activation)
    └── claude.ico            # icon extracted to a STABLE path (survives updates)

%APPDATA%\                     # profile DATA lives here (required for Cowork VM)
├── Claude\                    # the stock login (used by -DefaultProfile <name>)
└── Claude-Work\               # isolated Chromium profile (login, history, cache, VM)

%USERPROFILE%\
└── .claude-work\              # isolated Claude Code config/memory for that profile

Desktop\
├── Claude (Personal).lnk
└── Claude (Work).lnk
```

The shortcuts point at the copied `bin\` scripts, so you can delete the cloned
repo afterwards and everything keeps working. Profile *data* lives under
`%APPDATA%\<name>` (not under `ClaudeProfiles\`) — this is required so Claude's
**Cowork** VM can start; see [Cowork limitations](#cowork-vm-limitations) below.

---

## Usage notes

- **Re-clicking a shortcut** focuses that profile's existing window instead of
  opening a duplicate — exactly the normal single-instance behaviour, but scoped
  per profile.
- **App updates** are handled automatically: the launcher re-resolves the exe
  path each time via `Get-AppxPackage`.
- **Shortcut icons survive updates.** `Setup.ps1` extracts the Claude icon once
  to `bin\claude.ico` (a stable path) and points every shortcut there. Pointing a
  shortcut straight at the versioned `WindowsApps\Claude_<version>\...\Claude.exe`
  would go blank after the next update deletes that folder — which is why the
  icon is copied out to a fixed location instead.
- **Switching the "main" app:** the regular Start-menu Claude icon still uses
  `%APPDATA%\Claude`, i.e. the same login as the profile you named with
  `-DefaultProfile`.
- **Enterprise SSO** returning to the wrong profile? See
  [Enterprise SSO / login routing](#enterprise-sso--login-routing) above and
  [docs/PROTOCOL-ROUTING.md](docs/PROTOCOL-ROUTING.md).

---

## Optional: build a real `.exe`

If you'd rather have a single executable than a `.vbs`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Build-Exe.ps1
# -> dist\ClaudeLauncher.exe  (takes -ProfileDir "<path>")
```

This uses [`ps2exe`](https://github.com/MScholtes/PS2EXE). Note that unsigned
ps2exe binaries can trip SmartScreen / antivirus heuristics — the `.vbs`
launcher created by `Setup.ps1` is the recommended, friction-free option.

---

## Uninstall

```powershell
# Remove the shortcuts only:
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1

# Remove shortcuts AND the isolated profile data (signs you out, clears history):
powershell -ExecutionPolicy Bypass -File scripts\Uninstall.ps1 -RemoveData
```

`Uninstall.ps1` also removes the `claude://` login router (registry entries +
`bin\` router files) and restores stock protocol handling — Windows falls back
to the Claude app's own registration automatically, and any Settings default-app
choice self-clears. Pass `-KeepRouting` to leave the router in place.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Claude Desktop app not found" | Install it from [claude.ai/download](https://claude.ai/download) and run `Setup.ps1` again. |
| Shortcut does nothing | Run `scripts\Launch-Claude.ps1 -ProfileDir <dir>` directly in PowerShell to see the error. |
| Second window won't open | Make sure the two shortcuts use **different** `--user-data-dir` paths (check shortcut *Target*). |
| Icon is blank or grey | Re-run `Setup.ps1` (current versions extract the icon to a stable `bin\claude.ico`, so it survives updates). If a stale thumbnail lingers, clear the icon cache: `ie4uinit.exe -show`, or `Stop-Process -Name explorer -Force; Start-Process explorer`. |
| **"Failed to start Claude's workspace" / `VHDX file not found`** in a cloned profile | The profile's data dir is **outside `%APPDATA%`**, so the Cowork VM service can't find `rootfs.vhdx`. Re-run `Setup.ps1` (current version puts profiles under `%APPDATA%`). To migrate an existing profile without re-login, move `ClaudeProfiles\<name>` → `%APPDATA%\<name>` and update the shortcut's first argument to `%APPDATA%\<name>`. Do **not** use a junction/symlink for `vm_bundles` — the VM service refuses to open reparse points. |
| **Cowork won't start in one profile while another is open** (`HYPERVISOR_SERVICE_ERROR`, *"a virtual machine … with the specified identifier already exists"*) | Expected — see [Cowork VM limitations](#cowork-vm-limitations). Only one profile can run the Cowork VM at a time; quit the other profile (or reboot to clear a stale VM) before launching. |

---

## Cowork VM limitations

Claude Desktop's **Cowork** feature (the agentic workspace, scheduled tasks, and
artifact storage) runs inside a per-machine **Hyper-V VM**, not just an Electron
window. Two consequences for multi-profile use:

1. **Profile data must live under `%APPDATA%`.** The native VM service resolves
   the VM image (`rootfs.vhdx`) at `%APPDATA%\<dir-name>\vm_bundles`,
   *ignoring* `--user-data-dir`. `Setup.ps1` therefore derives isolated profiles
   as `%APPDATA%\Claude-<name>` (and the `-DefaultProfile` profile uses the stock
   `%APPDATA%\Claude`, which is why it works out of the box). A data dir
   anywhere else makes Cowork fail with `VHDX file not found`.

2. **Only one Cowork VM can run at a time.** The Hyper-V compute system is *not*
   scoped per profile, so launching Cowork in a second profile while another's
   VM is running fails with `HYPERVISOR_SERVICE_ERROR` /
   *"identifier already exists"*. You can keep both **windows** open for chat, but
   the VM-backed workspace only runs in one profile at a time — quit (or stop the
   workspace of) the other profile first. The plain chat / login isolation that
   this tool provides is unaffected.

---

## How is this different from running the app twice?

The app enforces a single instance via the Chromium singleton lock, which is
tied to the data directory. Clicking the normal icon twice hits the same lock
and just focuses the open window. Giving each instance its own data directory
gives each its own lock — and its own account.

---

## Disclaimer

This is an unofficial community tool. It does not modify, repackage, or
redistribute the Claude app — it only launches the official, installed app with
a standard Chromium command-line flag. Use in accordance with Anthropic's terms.

---

## Tiếng Việt — Quickstart

Chạy **nhiều cửa sổ Claude Desktop cùng lúc trên Windows**, mỗi cái một tài
khoản (ví dụ *Công việc* và *Cá nhân*), đăng nhập/lịch sử/cài đặt tách biệt.

App chính thức chỉ cho 1 tài khoản và không mở cửa sổ thứ hai. Repo này lách
bằng cờ `--user-data-dir` của Chromium: mỗi thư mục dữ liệu khác nhau = một khoá
instance riêng = một cửa sổ + một tài khoản chạy song song.

```powershell
git clone https://github.com/fredless/claude-windows-multiprofile.git
cd claude-windows-multiprofile
powershell -ExecutionPolicy Bypass -Command "& .\scripts\Setup.ps1 -Profile Personal,Work -DefaultProfile Personal"
```

- Tạo 2 icon trên Desktop: **Claude (Personal)** và **Claude (Work)**.
- `-DefaultProfile Personal`: icon Personal dùng lại tài khoản đang đăng nhập
  (khỏi login lại). Icon Work mở cửa sổ mới để đăng nhập tài khoản còn lại.
- Bấm lại icon → focus đúng cửa sổ của tài khoản đó (không mở trùng).
- Đăng nhập SSO (doanh nghiệp) bị nhầm profile? Xem phần
  [Enterprise SSO / login routing](#enterprise-sso--login-routing) và
  [docs/PROTOCOL-ROUTING.md](docs/PROTOCOL-ROUTING.md).

Muốn tách riêng cả **bộ nhớ Claude Code / Cowork** cho từng profile (mặc định
chỉ tách login, còn `~/.claude` thì dùng chung), trỏ `CLAUDE_CONFIG_DIR` qua
`-ConfigDir`:

```powershell
& .\scripts\Setup.ps1 -ConfigDir @{ Personal = "$env:USERPROFILE\.claude-personal" }
```

Gỡ: `scripts\Uninstall.ps1` (thêm `-RemoveData` để xoá luôn dữ liệu/đăng nhập).

Yêu cầu: Windows 10/11 + đã cài app Claude Desktop. Không cần quyền admin,
không cần Python.

---

## Contributing

`develop` is the integration branch; `master` is the stable, published state. Branch `feature/*`
or `bug/*` off `develop` and PR into `develop`; branch `hotfix/*` off `master` for urgent fixes.
Merging `develop → master` releases, and `sync-develop.yml` merges `master` back into `develop`.
CI runs PSScriptAnalyzer on every PR. See [CLAUDE.md](CLAUDE.md#git-workflow) for details.

## License

[MIT](LICENSE)

---

## Built with

[Claude Code](https://claude.ai/code) by Anthropic. 🤖
