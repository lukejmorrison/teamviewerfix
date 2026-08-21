# Incoming TeamViewer on Omarchy / Hyprland

Status as of 2026-08-21. Host investigated: **OmarchyT430s** (this repo's machine).
Controller that fails: **YTOmarchy1**.

The deploy script (`teamviewer_deploy_wayland.sh`) makes the GUI and daemon usable
(outgoing, ID online, ffmpeg, XWayland). It does **not** make incoming remote
control work on Hyprland.

## Symptom on YTOmarchy1

YTOmarchy1 reports:

> connection type is not allowed on this machine

Treat that as **two possible causes**. Check YTOmarchy1 logs first:

```bash
rg -n "CommercialBlocker|CommercialBlockerOffender|connection type|not allowed|BLOCKED|AuthenticationTimeout" \
  ~/.local/share/teamviewer15/logfiles/TeamViewer15_Logfile.log \
  /var/log/teamviewer15/TeamViewer15_Logfile.log
```

1. **License/policy (controller-side).** TeamViewer Free may log `BLOCKED` with
   `CommercialBlockerOffender=ActiveSide`. That is an account flag, not a
   firewall. Another client (OmarchyT430s) can still reach the same partner
   while YTOmarchy1 cannot. Cooldown / another account / personal license.
   This script cannot clear it.

2. **Host cannot offer Wayland remote control.** On OmarchyT430s the same
   attempt is a successful router handshake, then `TeamViewer_Desktop` dies
   and `AuthenticationTimeout`. Details below.

Do not treat this as "the daemon is down" or "the ID is blank". `teamviewer info`
as a normal user prints an empty ID because `/etc/teamviewer/global.conf` is
root-only; trust the GUI.

## IDs (from host logs)

| Role | Hostname | TeamViewer ID |
| --- | --- | --- |
| Host being controlled | OmarchyT430s | `1214731265` |
| Controller | YTOmarchy1 | `809843398` |

Confirm on YTOmarchy1 GUI (not `teamviewer info` as a normal user; `/etc/teamviewer/global.conf` is root-only and `teamviewer info` prints an empty ID).

## What the host logs show (OmarchyT430s)

Every incoming attempt from `809843398`:

1. `CommandHandlerRouting::CreatePassiveSession(): incoming session via …router.teamviewer.com`
2. TLS handshake **succeeds** (`1214731265 <- 809843398: session handshake succeeded`)
3. Daemon tries to start capture:

```
DesktopProcessStarterLinux::StartSystemProcessInSession(..., /opt/teamviewer/tv_bin/TeamViewer_Desktop)
LaunchDesktopProcess: session bus not found
CreateProcess '/opt/teamviewer/tv_bin/TeamViewer_Desktop' as user luke
```

4. `TeamViewer_Desktop` starts, then:

```
SysSessionInfoManager::GetOwnProcessSession: No session found!
Own session could not be resolved, unable to startup
```

   Process exits ~5s later, `exit code 1`.

5. Session ends:

```
Session to 809843398 terminated because of authentication timeout!
Session termination reason AuthenticationTimeout
```

Logs:

- Daemon: `/var/log/teamviewer15/TeamViewer15_Logfile.log`
- GUI / Desktop: `~/.local/share/teamviewer15/logfiles/TeamViewer15_Logfile.log`

Grep:

```bash
rg -n "incoming session|session bus not found|Own session could not|AuthenticationTimeout|ScreenPlatformInterface|RemoteDesktop|LAN only|whitelist" \
  /var/log/teamviewer15/TeamViewer15_Logfile.log \
  ~/.local/share/teamviewer15/logfiles/TeamViewer15_Logfile.log
```

## Two stacked host failures

### A. `TeamViewer_Desktop` is spawned outside the Hyprland session

`teamviewerd` is `system.slice/teamviewerd.service` (root). On incoming control it
forks `/opt/teamviewer/tv_bin/TeamViewer_Desktop` as the desktop user **without**
the graphical session:

- no `DBUS_SESSION_BUS_ADDRESS`
- process cgroup stays under `teamviewerd.service`, not `user@UID.service`
- logind session for the Hyprland seat has empty `Display=` (normal on Wayland)

UWSM/Omarchy layout on the host:

- logind session 1: `sddm-autologin`, type `wayland`, class `user`, leader `sddm-helper`
- logind session 2: `systemd-user`, class `manager` (TeamViewer marks this unreliable)
- Hyprland lives in `user@1000.service/session.slice/wayland-wm@hyprland.desktop.service`

Even if you re-exec `TeamViewer_Desktop` with the GUI process environment
(`XDG_SESSION_ID=1`, `WAYLAND_DISPLAY=wayland-1`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/UID/bus`),
session matching can succeed (`own session cache set to '…'`) and it **still**
cannot get a screen interface (see B).

### B. Hyprland has no `RemoteDesktop` portal

TeamViewer Wayland capture/control uses:

- `org.freedesktop.portal.ScreenCast`
- `org.freedesktop.portal.RemoteDesktop`

OmarchyT430s packages:

- `xdg-desktop-portal 1.22.1-2`
- `xdg-desktop-portal-hyprland 1.4.1-1`
- `xdg-desktop-portal-gtk 1.15.3-1`

`/usr/share/xdg-desktop-portal/portals/hyprland.portal` interfaces:

```
Screenshot; ScreenCast; GlobalShortcuts; InputCapture
```

**No `RemoteDesktop`.** `busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.RemoteDesktop` is empty.

In `TeamViewer_Desktop` logs this looks like:

```
DesktopMainLin: no session bus connection
tvdesktop::ScreenPlatformInterfaceFactory::InitSPI: Can not get ScreenPlatformInterface
```

Arch wiki portal table: hyprland has ScreenCast, not RemoteDesktop.
TeamViewer’s own Wayland note: required portals are implemented for **GNOME and KDE** attended sessions, not Hyprland.
Upstream: https://github.com/hyprwm/xdg-desktop-portal-hyprland/issues/252

So wrapping `TeamViewer_Desktop` into the user session is **not sufficient**. Incoming control still needs a portal backend that implements `org.freedesktop.impl.portal.RemoteDesktop` (for example `xdg-desktop-portal-luminous` as a fallback next to hyprland). Do not replace hyprland’s ScreenCast backend.

`~/.config/hypr/xdph.conf` on the host has `screencopy { allow_token_by_default = true }` — that only helps ScreenCast tokens, not RemoteDesktop.

## What YTOmarchy1 should collect

Run on **YTOmarchy1** (the machine that shows "connection type is not allowed"):

```bash
hostnamectl
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
pacman -Q teamviewer ffmpeg4.4 xdg-desktop-portal xdg-desktop-portal-hyprland
systemctl is-active teamviewerd
systemctl --user is-active xdg-desktop-portal xdg-desktop-portal-hyprland

# GUI, not `teamviewer info` (empty ID as non-root is normal)
rg -n "CommercialBlocker|connection type|not allowed|Wayland|RemoteDesktop|incoming|AuthenticationTimeout|LAN only|whitelist" \
  ~/.local/share/teamviewer15/logfiles/TeamViewer15_Logfile.log \
  ~/.local/share/teamviewer15/logfiles/gui.log \
  /var/log/teamviewer15/TeamViewer15_Logfile.log

busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop \
  | rg 'ScreenCast|RemoteDesktop|InputCapture'
```

Check in the YTOmarchy1 GUI:

- Extras → Options → Security: incoming connections allowed; personal password set if unattended
- Extras → Options → Advanced / incoming LAN connections: **not** "LAN only" (host briefly logged `LAN only is active` during testing)
- Computers & Contacts: host ID `1214731265` is not blocked; host had `usewhitelist = 1`
- Connecting to **remote control**, not file transfer / meeting only
- Commercial-use / license dialogs. Prefer the `CommercialBlockerOffender` grep above over guessing.

If YTOmarchy1 is also Omarchy/Hyprland, it has the same portal gap when **it** is the host. The current failure is YTOmarchy1 as **controller** of OmarchyT430s as **host**.

## What the deploy script does vs does not

Does: daemon, `QT_QPA_PLATFORM=xcb`, ffmpeg 4.4, opaque Hyprland window rules, and a `TeamViewer_Desktop` wrapper that injects the Hyprland session env (pacman hook re-applies it).

Does not: install a RemoteDesktop portal, set a personal password, clear a commercial-use block, or disable whitelist/LAN-only.

Outgoing from OmarchyT430s (this PC controlling another) can work. Incoming control of this Hyprland desktop cannot until B is fixed (and A is already partially addressed by the wrapper).

## Next experiments (do not do blindly)

1. On the **host**, install a RemoteDesktop-capable portal as a fallback, e.g. `xdg-desktop-portal-luminous`, and point only `org.freedesktop.impl.portal.RemoteDesktop` at it. Keep hyprland for ScreenCast. Restart user portals (`systemctl --user restart xdg-desktop-portal xdg-desktop-portal-hyprland`).
2. The deploy script already wraps `TeamViewer_Desktop` with session env. If YTOmarchy1 still fails after a host re-deploy, look at (1) and at `CommercialBlockerOffender`.
3. If YTOmarchy1 can remote-control a Windows/macOS box but not OmarchyT430s, the block is host-side (portal). If it cannot remote-control anyone, grep for `CommercialBlockerOffender=ActiveSide`.

Do not switch Omarchy to Xorg as a "fix" without the user asking. Do not edit `/usr/share/omarchy/`.
