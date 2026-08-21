#!/usr/bin/env bash
# teamviewer_deploy_wayland.sh
# Deploy / repair TeamViewer on Omarchy (Arch Linux + Hyprland / Wayland).
#
# Fixes:
#   1. teamviewerd not enabled/running  ->  "The TeamViewer daemon is not running!"
#   2. Qt5 has no Wayland plugin       ->  force QT_QPA_PLATFORM=xcb (XWayland)
#   3. Missing ffmpeg 4.x SONAMEs      ->  install extra/ffmpeg4.4 for session video
#   4. Hyprland default window opacity ->  keep TeamViewer fully opaque
#
# Usage:
#   ./teamviewer_deploy_wayland.sh
#   ./teamviewer_deploy_wayland.sh --launch
#   curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/wizwam/teamviewer_deploy_wayland.sh | bash
#
# Optional flags:
#   --launch        Start the TeamViewer GUI when setup succeeds
#   --skip-install  Do not install packages (only daemon + desktop + Hyprland)
#   --help          Show this help
set -euo pipefail

DO_LAUNCH=0
SKIP_INSTALL=0

HYPR_MARKER_BEGIN="-- teamviewerfix:begin"
HYPR_MARKER_END="-- teamviewerfix:end"
DESKTOP_ID="com.teamviewer.TeamViewer.desktop"
TEAMVIEWER_BIN="/opt/teamviewer/tv_bin/script/teamviewer"

usage() {
  cat <<'EOF'
teamviewer_deploy_wayland.sh
Deploy / repair TeamViewer on Omarchy (Arch Linux + Hyprland / Wayland).

Usage:
  ./teamviewer_deploy_wayland.sh
  ./teamviewer_deploy_wayland.sh --launch
  curl -fsSL https://raw.githubusercontent.com/lukejmorrison/teamviewerfix/wizwam/teamviewer_deploy_wayland.sh | bash

Optional flags:
  --launch        Start the TeamViewer GUI when setup succeeds
  --skip-install  Do not install packages (only daemon + desktop + Hyprland)
  --help          Show this help
EOF
}

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '    [ok] %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }
die()  { printf '    [fail] %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --launch) DO_LAUNCH=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $arg (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Target user: never write Hyprland / desktop files into /root when invoked
# via sudo. Prefer the sudo caller, then the owner of the graphical session.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
  TARGET_USER="${SUDO_USER:-}"
  if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
    TARGET_USER="$(loginctl list-sessions --no-legend 2>/dev/null \
      | awk '$3 != "root" { print $3; exit }' || true)"
  fi
  [[ -n "${TARGET_USER}" ]] || die "Run this as your desktop user (not a root login)."
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="${HOME}"
fi

[[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]] || die "Could not resolve home for ${TARGET_USER}"

as_user() {
  if [[ "$(id -un)" == "${TARGET_USER}" ]]; then
    "$@"
  else
    sudo -u "${TARGET_USER}" -H "$@"
  fi
}

need_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Need root for: $*"
  fi
}

have_pkg() {
  pacman -Q "$1" >/dev/null 2>&1
}

install_pkg() {
  local pkg="$1"
  if have_pkg "${pkg}"; then
    ok "package already installed: ${pkg} ($(pacman -Q "${pkg}"))"
    return 0
  fi

  log "Installing ${pkg}"
  if command -v omarchy >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
      # omarchy pkg helpers expect to sudo themselves; run as the desktop user.
      as_user omarchy pkg add "${pkg}" || need_root pacman -S --needed --noconfirm "${pkg}"
    else
      omarchy pkg add "${pkg}" || need_root pacman -S --needed --noconfirm "${pkg}"
    fi
  else
    need_root pacman -S --needed --noconfirm "${pkg}"
  fi
  have_pkg "${pkg}" || die "Failed to install ${pkg}"
}

install_aur_pkg() {
  local pkg="$1"
  if have_pkg "${pkg}"; then
    ok "package already installed: ${pkg} ($(pacman -Q "${pkg}"))"
    return 0
  fi

  log "Installing AUR package ${pkg}"
  if command -v omarchy >/dev/null 2>&1; then
    if [[ "${EUID}" -eq 0 ]]; then
      as_user omarchy pkg aur add "${pkg}"
    else
      omarchy pkg aur add "${pkg}"
    fi
  elif command -v yay >/dev/null 2>&1; then
    as_user yay -S --needed --noconfirm "${pkg}"
  elif command -v paru >/dev/null 2>&1; then
    as_user paru -S --needed --noconfirm "${pkg}"
  else
    die "TeamViewer is an AUR package. Install 'yay' or 'paru', or run: omarchy pkg aur add teamviewer"
  fi
  have_pkg "${pkg}" || die "Failed to install ${pkg}"
}

require_arch() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    arch:*|omarchy:*|*:arch*|endeavouros:*|manjaro:*) ;;
    *)
      warn "This script is written for Arch / Omarchy (detected ID=${ID:-unknown}). Continuing anyway."
      ;;
  esac
}

# ---------------------------------------------------------------------------
require_arch
log "Target user: ${TARGET_USER} (${TARGET_HOME})"

if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  install_pkg ffmpeg4.4
  install_aur_pkg teamviewer
else
  have_pkg ffmpeg4.4 || warn "ffmpeg4.4 is not installed (--skip-install)"
  have_pkg teamviewer || die "teamviewer is not installed (--skip-install)"
fi

[[ -x "${TEAMVIEWER_BIN}" ]] || die "TeamViewer binary missing at ${TEAMVIEWER_BIN}"

# ffmpeg 4.4 SONAMEs TeamViewer 15 late-binds for session video
for so in libavcodec.so.58 libavutil.so.56 libswscale.so.5; do
  if [[ -e "/usr/lib/${so}" ]]; then
    ok "found /usr/lib/${so}"
  else
    warn "missing /usr/lib/${so} (session video may fail)"
  fi
done

# ---------------------------------------------------------------------------
log "Enabling and starting teamviewerd"
# Prefer TeamViewer's own helper so it owns the systemd unit symlink.
if [[ -x /usr/bin/teamviewer ]]; then
  need_root /usr/bin/teamviewer daemon enable >/dev/null
  need_root /usr/bin/teamviewer daemon start >/dev/null || true
else
  need_root systemctl enable --now teamviewerd.service
fi

# daemon enable is not always enough if the unit was already present but dead
need_root systemctl enable --now teamviewerd.service >/dev/null

if systemctl is-active --quiet teamviewerd; then
  ok "teamviewerd is active ($(systemctl is-enabled teamviewerd 2>/dev/null || echo unknown))"
else
  systemctl --no-pager --full status teamviewerd >&2 || true
  die "teamviewerd failed to start"
fi

# ---------------------------------------------------------------------------
log "Installing XWayland desktop launcher override"
DESKTOP_DIR="${TARGET_HOME}/.local/share/applications"
as_user mkdir -p "${DESKTOP_DIR}"
DESKTOP_PATH="${DESKTOP_DIR}/${DESKTOP_ID}"

as_user tee "${DESKTOP_PATH}" >/dev/null <<'EOF'
[Desktop Entry]
Version=1.0
Encoding=UTF-8
Type=Application
Categories=Network;
Name=TeamViewer
Comment=Remote control solution (XWayland).
Exec=env QT_QPA_PLATFORM=xcb /opt/teamviewer/tv_bin/script/teamviewer
StartupWMClass=TeamViewer
Icon=TeamViewer
EOF
as_user chmod 644 "${DESKTOP_PATH}"
ok "wrote ${DESKTOP_PATH}"

if command -v update-desktop-database >/dev/null 2>&1; then
  as_user update-desktop-database "${DESKTOP_DIR}" >/dev/null 2>&1 || true
fi

# Terminal launches: ~/.local/bin is on PATH ahead of /usr/bin on Omarchy.
log "Installing ~/.local/bin/teamviewer wrapper (forces xcb)"
BIN_DIR="${TARGET_HOME}/.local/bin"
as_user mkdir -p "${BIN_DIR}"
as_user tee "${BIN_DIR}/teamviewer" >/dev/null <<'EOF'
#!/usr/bin/env bash
# Force Qt5 TeamViewer onto XWayland. The bundled Qt has no wayland plugin.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
exec /opt/teamviewer/tv_bin/script/teamviewer "$@"
EOF
as_user chmod 755 "${BIN_DIR}/teamviewer"
ok "wrote ${BIN_DIR}/teamviewer"

# ---------------------------------------------------------------------------
HYPR_LUA="${TARGET_HOME}/.config/hypr/hyprland.lua"
if [[ -f "${HYPR_LUA}" ]]; then
  log "Patching Hyprland window rules in ${HYPR_LUA}"
  # Lua comments start with "--"; GNU grep treats that as an option unless
  # the pattern is passed with -e and option parsing is stopped with --.
  if grep -qF -e "${HYPR_MARKER_BEGIN}" -- "${HYPR_LUA}" \
     || grep -qF -e 'o.window("TeamViewer"' -- "${HYPR_LUA}"; then
    ok "TeamViewer window rules already present"
  else
    as_user tee -a "${HYPR_LUA}" >/dev/null <<EOF

${HYPR_MARKER_BEGIN}
-- TeamViewer is a Qt5 XWayland app. Keep remote-control windows fully opaque.
o.window("TeamViewer", { tag = "-default-opacity" })
o.window("TeamViewer", { opacity = "1 1" })
${HYPR_MARKER_END}
EOF
    ok "appended TeamViewer window rules"
  fi

  if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" || -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
    as_user hyprctl reload >/dev/null 2>&1 && ok "hyprctl reload" || warn "hyprctl reload failed (log out/in if rules do not apply)"
  fi
else
  warn "No ${HYPR_LUA}; skipped window rules (not an Omarchy Lua Hyprland config?)"
fi

# ---------------------------------------------------------------------------
log "Checking Wayland screen-share portals (incoming sessions)"
if systemctl --user --quiet is-active xdg-desktop-portal-hyprland 2>/dev/null \
   || as_user systemctl --user --quiet is-active xdg-desktop-portal-hyprland 2>/dev/null; then
  ok "xdg-desktop-portal-hyprland is active"
else
  warn "xdg-desktop-portal-hyprland is not active; incoming screen share may be a black frame"
fi

# ---------------------------------------------------------------------------
log "Summary"
printf '    user:          %s\n' "${TARGET_USER}"
printf '    teamviewer:    %s\n' "$(pacman -Q teamviewer 2>/dev/null || echo missing)"
printf '    ffmpeg4.4:     %s\n' "$(pacman -Q ffmpeg4.4 2>/dev/null || echo missing)"
printf '    daemon:        %s (%s)\n' \
  "$(systemctl is-active teamviewerd 2>/dev/null || echo unknown)" \
  "$(systemctl is-enabled teamviewerd 2>/dev/null || echo unknown)"
printf '    desktop file:  %s\n' "${DESKTOP_PATH}"
printf '    cli wrapper:   %s\n' "${BIN_DIR}/teamviewer"

if [[ "${DO_LAUNCH}" -eq 1 ]]; then
  log "Launching TeamViewer GUI"
  as_user env QT_QPA_PLATFORM=xcb gtk-launch "${DESKTOP_ID%.desktop}" >/dev/null 2>&1 \
    || as_user env QT_QPA_PLATFORM=xcb "${TEAMVIEWER_BIN}" >/dev/null 2>&1 &
  ok "launch requested"
else
  log "Done. Launch with:  teamviewer"
  log "Or from the app launcher (TeamViewer)."
fi

log "First-run: accept the EULA in the GUI. For unattended access, set a personal password under Extras → Options → Security."
log "Incoming Wayland control uses the desktop portal — approve the share prompt if the remote sees a black screen."
