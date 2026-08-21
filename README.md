# teamviewerfix

One-shot TeamViewer setup for **Omarchy** (Arch Linux + Hyprland on Wayland).

On a fresh install, opening TeamViewer shows:

> **The TeamViewer daemon is not running!**
>
> Please start the daemon (needs root permissions) before running TeamViewer:
> `teamviewer --daemon start`

That dialog is only the first problem. This repo records the full fix that made TeamViewer usable on Omarchy, and a single script that applies it on another machine.

## Quick deploy

On the other Omarchy PC, in a terminal (so `sudo` can prompt):

```bash
curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/wizwam/teamviewer_deploy_wayland.sh | bash
```

Launch the GUI when it finishes:

```bash
curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/wizwam/teamviewer_deploy_wayland.sh | bash -s -- --launch
```

Or clone and run:

```bash
git clone https://github.com/lukejmorrison/teamviewerfix.git
cd teamviewerfix
chmod +x teamviewer_deploy_wayland.sh
./teamviewer_deploy_wayland.sh --launch
```

The script is idempotent. Re-run it after a TeamViewer reinstall or an Omarchy refresh of Hyprland config.

| Flag | Effect |
| --- | --- |
| `--launch` | Start the TeamViewer GUI when setup succeeds |
| `--skip-install` | Only fix daemon / desktop / Hyprland (packages must already be present) |
| `--help` | Usage |

## What was broken

Verified on Omarchy with TeamViewer **15.79.4**, Hyprland, session type `wayland`.

### 1. Daemon packaged, never enabled

The AUR `teamviewer` package installs `/usr/lib/systemd/system/teamviewerd.service` with **`disabled`** (preset: disabled). The GUI talks to the daemon over `127.0.0.1:5939`. If that service is dead you get the dialog in the screenshot, and `teamviewer info` reports an empty ID.

Fix:

```bash
sudo teamviewer daemon enable
sudo teamviewer daemon start
# equivalent:
sudo systemctl enable --now teamviewerd
```

Use `teamviewer daemon enable` at least once so TeamViewer owns the systemd symlink. Then keep the unit enabled so it comes back after reboot.

### 2. Bundled Qt5 has no Wayland plugin

`~/.local/share/teamviewer15/logfiles/gui.log`:

```
qt.qpa.plugin: Could not find the Qt platform plugin "wayland" in ""
```

TeamViewer 15 ships Qt **5.15** and still speaks X11. On Hyprland it must run through **XWayland**. The GUI can fall back to `xcb` on its own, but Omarchy sets `QT_QPA_PLATFORM=wayland;xcb` for the session, so Qt tries Wayland first and logs `Could not find the Qt platform plugin "wayland"`. Pin TeamViewer only:

```bash
env QT_QPA_PLATFORM=xcb teamviewer
```

Do **not** export `QT_QPA_PLATFORM=xcb` for the whole session — that breaks native Wayland Qt apps. Only the TeamViewer desktop file and a `~/.local/bin/teamviewer` wrapper set it, and they **force** `xcb` rather than defaulting only when the variable is unset.

### 3. Session video needs ffmpeg 4.x SONAMEs

Arch current ffmpeg is 7.x (`libavcodec.so.63`). TeamViewer late-binds the 4.4 names:

```
LateBinding [libavcodec.so.58]: Could not open library ...
LateBinding [libavutil.so.56]: Could not open library ...
LateBinding [libswscale.so.5]: Could not open library ...
```

`extra/ffmpeg4.4` provides those libraries. After install, a GUI restart logs:

```
tvvideocodec::FFMpeg::LibAVCodec::LibAVCodec: library loaded v58.134.100
tvvideocodec::FFMpeg::LibAVUtil::LibAVUtil: library loaded v56.70.100
tvvideocodec::FFMpeg::SwScale::SwScale: library loaded v5.9.100
```

### 4. Hyprland default opacity

Omarchy tags most windows `default-opacity`. TeamViewer is a remote-control surface; keep it fully opaque:

```lua
-- ~/.config/hypr/hyprland.lua (user file, never /usr/share/omarchy)
o.window("TeamViewer", { tag = "-default-opacity" })
o.window("TeamViewer", { opacity = "1 1" })
```

The deploy script wraps this in `-- teamviewerfix:begin` / `-- teamviewerfix:end` so a second run does not duplicate the rules.

### 5. `teamviewer license accept` crashes

`teamviewer license` launches `teamviewer-config`, which SIGSEGV'd on this setup (`teamviewer-config_FI_*.stack` in the user log dir). Accept the EULA in the GUI instead. Do not automate `teamviewer license accept`.

### 6. Incoming capture process has no session (uwsm)

Controlling this Omarchy box from another TeamViewer client reaches the daemon, then `TeamViewer_Desktop` often dies with:

```
LaunchDesktopProcess: session bus not found
CreateProcess '/opt/teamviewer/tv_bin/TeamViewer_Desktop' as user luke (1000)
SysSessionInfoManager::GetOwnProcessSession: No session found!
!!!Own session could not be resolved, unable to startup
```

Omarchy runs Hyprland under **uwsm**. The logind session leader is `sddm-helper` (no user D-Bus). `teamviewerd` is a system unit, so it cannot see `/run/user/1000/bus` and falls back to `su`, which starts `TeamViewer_Desktop` with no `WAYLAND_DISPLAY`. Outgoing control of Windows/macOS does not need this helper.

The deploy script replaces `/opt/teamviewer/tv_bin/TeamViewer_Desktop` with a wrapper that imports `XDG_RUNTIME_DIR`, the user D-Bus, `WAYLAND_DISPLAY`, and `DISPLAY=:0`, then `exec`s the real ELF (`TeamViewer_Desktop.real`). A pacman hook restores the wrapper after `teamviewer` upgrades.

That wrapper is **necessary but not sufficient** on Hyprland. See [INCOMING.md](INCOMING.md): TeamViewer’s Wayland path also needs `org.freedesktop.portal.RemoteDesktop`, which `xdg-desktop-portal-hyprland` does not implement.

## What the script does

1. Install `ffmpeg4.4` (Arch extra) if missing.
2. Install `teamviewer` from the AUR if missing (`omarchy pkg aur add`, else `yay` / `paru`).
3. `teamviewer daemon enable` + `systemctl enable --now teamviewerd`.
4. Write `~/.local/bin/teamviewer` with an unconditional `QT_QPA_PLATFORM=xcb` pin.
5. Write `~/.local/share/applications/com.teamviewer.TeamViewer.desktop` so the app launcher runs that wrapper (`DBusActivatable=false`).
6. Override `~/.local/share/dbus-1/services/com.teamviewer.TeamViewer.service` so uwsm/gtk-launch D-Bus activation also hits the wrapper (stock Exec is `/opt/teamviewer/tv_bin/TeamViewer` and ignores the desktop file).
7. Wrap `/opt/teamviewer/tv_bin/TeamViewer_Desktop` so incoming capture runs with the Hyprland session environment (`WAYLAND_DISPLAY`, user D-Bus). A pacman hook re-applies this after a TeamViewer upgrade.
8. Override `com.teamviewer.TeamViewer.Desktop` D-Bus activation the same way.
9. Append the Hyprland opacity rules to `~/.config/hypr/hyprland.lua` if that file exists.
10. `hyprctl reload` when Hyprland is running.
11. Print daemon / package status.

If you run the script with `sudo`, it still writes desktop/Hyprland files as the **desktop user** (`$SUDO_USER`), not root.

## After deploy

1. Open **TeamViewer** and accept the license agreement.
2. Confirm **Your ID** is populated (not blank). `teamviewer info` as a normal user may still print an empty ID because `/etc/teamviewer/global.conf` is root-only; trust the GUI.
3. For unattended access: **Extras → Options → Security** → set a personal password. The daemon starts at boot. Incoming capture still needs a logged-in Hyprland session (the wrapper talks to that session; it cannot create one).
4. Incoming Hyprland control is still incomplete without a RemoteDesktop portal. See [INCOMING.md](INCOMING.md). If the **controller** (YTOmarchy1) shows **"connection type is not allowed on this machine"**, check both that note and the Free/commercial block below.

Outgoing connections (this PC controlling Windows or macOS) work through XWayland and do not depend on the portal.

## Incoming control (YTOmarchy1 → OmarchyT430s)

Full evidence and YTOmarchy1 log checklist: [INCOMING.md](INCOMING.md).

Host ID `1214731265` (OmarchyT430s), controller ID `809843398` (YTOmarchy1). Handshake to TeamViewer routers succeeds. Then either:

- Host `TeamViewer_Desktop` dies / `AuthenticationTimeout` (session spawn + missing `RemoteDesktop` portal), or
- The controller is TeamViewer **Free** and returns `Connection type not allowed` / `BLOCKED` with `CommercialBlockerOffender=ActiveSide`.

Grep on YTOmarchy1:

```bash
rg -n "CommercialBlocker|connection type|not allowed|BLOCKED|AuthenticationTimeout|Own session" \
  ~/.local/share/teamviewer15/logfiles/TeamViewer15_Logfile.log \
  /var/log/teamviewer15/TeamViewer15_Logfile.log
```

## Verify

```bash
systemctl is-enabled teamviewerd    # enabled
systemctl is-active teamviewerd     # active
ss -tlnp | grep 5939                # daemon IPC
ls /usr/lib/libavcodec.so.58 /usr/lib/libavutil.so.56 /usr/lib/libswscale.so.5
```

Logs:

- Daemon: `/var/log/teamviewer15/TeamViewer15_Logfile.log`
- GUI: `~/.local/share/teamviewer15/logfiles/`

A healthy GUI log includes `XClient: opened XCB connection successfully` and `TeamViewer-Onlinestate changed to online`.

## Manual equivalent

If you would rather not run the script:

```bash
omarchy pkg add ffmpeg4.4
omarchy pkg aur add teamviewer          # skip if already installed

sudo teamviewer daemon enable
sudo systemctl enable --now teamviewerd

mkdir -p ~/.local/share/applications ~/.local/bin
# desktop file + wrappers: see teamviewer_deploy_wayland.sh
# append the two o.window(...) lines to ~/.config/hypr/hyprland.lua
hyprctl reload
env QT_QPA_PLATFORM=xcb teamviewer
```

Edit **user** config only (`~/.config/hypr/`, `~/.local/`). Never edit `/usr/share/omarchy/` — Omarchy overwrites that on update.

## Limitations

- TeamViewer 15 on Linux is still an X11/Qt5 client. The deploy script is daemon/ffmpeg/XWayland glue plus a Desktop-process session wrapper, not full native Wayland incoming control.
- Incoming remote control on Hyprland needs `org.freedesktop.portal.RemoteDesktop`. `xdg-desktop-portal-hyprland` does not implement it (see [INCOMING.md](INCOMING.md)).
- This does not log you into a TeamViewer account or set an unattended password.
- TeamViewer **Free** may return `Connection type not allowed` or `BLOCKED` with `CommercialBlockerOffender=ActiveSide` on a machine TeamViewer has flagged for commercial use. That is an account/license decision, not a Linux firewall. A different client (for example the T430s) can still reach the same Mac while the flagged PC cannot. Waiting out the cooldown, using another TeamViewer account, or a personal license is the fix — not this script.

## License

MIT. TeamViewer itself remains under TeamViewer’s own license; this repo only covers the Linux/Wayland glue.
