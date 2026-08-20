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
curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/main/teamviewer_deploy_wayland.sh | bash
```

Launch the GUI when it finishes:

```bash
curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/main/teamviewer_deploy_wayland.sh | bash -s -- --launch
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

TeamViewer 15 ships Qt **5.15** and still speaks X11. On Hyprland it must run through **XWayland**. The GUI can fall back to `xcb` on its own, but launcher/environment races are common. Pin it:

```bash
env QT_QPA_PLATFORM=xcb teamviewer
```

Do **not** export `QT_QPA_PLATFORM=xcb` for the whole session — that breaks native Wayland Qt apps. Only the TeamViewer desktop file and a `~/.local/bin/teamviewer` wrapper set it.

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

## What the script does

1. Install `ffmpeg4.4` (Arch extra) if missing.
2. Install `teamviewer` from the AUR if missing (`omarchy pkg aur add`, else `yay` / `paru`).
3. `teamviewer daemon enable` + `systemctl enable --now teamviewerd`.
4. Write `~/.local/share/applications/com.teamviewer.TeamViewer.desktop` with `QT_QPA_PLATFORM=xcb`.
5. Write `~/.local/bin/teamviewer` (same `xcb` pin) so a terminal launch matches the app launcher.
6. Append the Hyprland opacity rules to `~/.config/hypr/hyprland.lua` if that file exists.
7. `hyprctl reload` when Hyprland is running.
8. Print daemon / package status.

If you run the script with `sudo`, it still writes desktop/Hyprland files as the **desktop user** (`$SUDO_USER`), not root.

## After deploy

1. Open **TeamViewer** and accept the license agreement.
2. Confirm **Your ID** is populated (not blank). `teamviewer info` as a normal user may still print an empty ID because `/etc/teamviewer/global.conf` is root-only; trust the GUI.
3. For unattended access: **Extras → Options → Security** → set a personal password. The daemon already starts at boot; the GUI does not need to stay open.
4. Incoming control of a Wayland session uses `xdg-desktop-portal-hyprland`. If the remote side sees a **black screen**, approve the share/portal prompt on the Omarchy box.

Outgoing connections (this PC controlling another) work through XWayland and do not depend on the portal.

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
# desktop file + wrapper: see teamviewer_deploy_wayland.sh
# append the two o.window(...) lines to ~/.config/hypr/hyprland.lua
hyprctl reload
env QT_QPA_PLATFORM=xcb teamviewer
```

Edit **user** config only (`~/.config/hypr/`, `~/.local/`). Never edit `/usr/share/omarchy/` — Omarchy overwrites that on update.

## Limitations

- TeamViewer 15 on Linux is still an X11/Qt5 client. This is a working Wayland *host* setup, not native Wayland.
- Incoming desktop capture quality depends on the portal stack (`xdg-desktop-portal`, `xdg-desktop-portal-hyprland`, PipeWire). Those are stock on Omarchy.
- This does not log you into a TeamViewer account or set an unattended password.

## License

MIT. TeamViewer itself remains under TeamViewer’s own license; this repo only covers the Linux/Wayland glue.
