#!/usr/bin/env bash
#
# mobile-remote-session.sh
#
# Spin up a headless plasma-mobile (KWin) or phosh (phoc) session and
# expose it over VNC or RDP. Auto-detects a GPU render node and prefers
# hardware rendering, falling back to CPU/software rendering only when
# no GPU is usable.
#
# ---------------------------------------------------------------------
# DEPENDENCIES (install what you need, package names vary by distro)
#
#   Debian/Ubuntu:
#     sudo apt install phoc phosh wayvnc xrdp mesa-utils vulkan-tools \
#                       pciutils wlr-randr kwin-wayland plasma-mobile
#   Fedora:
#     sudo dnf install phoc phosh wayvnc xrdp mesa-demos vulkan-tools \
#                       pciutils wlr-randr kwin plasma-mobile
#   Arch:
#     sudo pacman -S phoc phosh wayvnc xorgxrdp xrdp mesa-utils \
#                     vulkan-tools pciutils wlr-randr plasma-mobile
#
#   Package availability differs a lot by distro/version -- if a name
#   above 404s, search your package manager for "phoc", "phosh",
#   "wayvnc", "kwin", "plasma-mobile", "xrdp".
#
# NOTES ON THE TWO DESKTOPS
#   phosh   -> compositor is `phoc` (wlroots). Headless + GPU support is
#              solid via WLR_BACKENDS=headless + WLR_RENDERER=gles2, and
#              wayvnc talks to it natively (wlr-screencopy protocol).
#   plasma-mobile -> compositor is `kwin_wayland`. KWin's headless
#              ("virtual") backend flags and how well it uses a real GPU
#              render node have changed across Plasma releases. The
#              command built below is a best-effort default -- check
#              `kwin_wayland --help` and
#              /usr/share/wayland-sessions/plasma-mobile.desktop (its
#              Exec= line) on your system and adjust PLASMA_MOBILE_CMD
#              below if it doesn't start.
#
# RDP NOTE
#   Neither phoc nor KWin's virtual backend speaks RDP natively (KDE's
#   native RDP server, "krdp", is tied to a full KWin/Plasma session,
#   not a bare virtual backend). So for RDP this script runs wayvnc on
#   localhost and bridges it through xrdp's VNC-passthrough module
#   (lib=libvnc.so). This requires xrdp already installed; you may find
#   it simpler to add the [mobile-bridge] block shown below into your
#   system /etc/xrdp/xrdp.ini once, rather than re-templating it here.
# ---------------------------------------------------------------------

set -euo pipefail

### ---------------- defaults ----------------
DE=""                # phosh | plasma-mobile
PROTO=""              # vnc | rdp
WIDTH=412
HEIGHT=915
VNC_PORT=5900
RDP_PORT=3389
VNC_PASSWORD=""
LISTEN_ALL=0          # 0 = bind VNC/RDP to 127.0.0.1 only, unless a password is set
PLASMA_MOBILE_CMD="plasma-mobile"   # verify this matches your system, see note above
WEBGUI=""             # none | novnc | kasmvnc  -- browser front-end for the VNC stream
WEBGUI_PORT=6080
INSTALL_SELF=1        # 1 = also install this script as /usr/bin/pmos
AUTO_INSTALL=1        # 1 = automatically apt/dnf/pacman-install missing deps
RECONFIGURE=0         # 1 = ignore saved config and show the menus again
CONFIG_FILE="${PMOS_CONFIG:-$HOME/.config/pmos/config}"

WORKDIR="$(mktemp -d /tmp/mobile-remote.XXXXXX)"
LOGDIR="$WORKDIR/logs"
mkdir -p "$LOGDIR"
PIDS=()

### ---------------- saved-config (so `pmos` can auto-start) ----------------
# On a fresh install there's no config yet, so DE/PROTO/WEBGUI get asked
# interactively once, then saved. Every run after that, `pmos` with no
# arguments reuses the saved choices and starts straight away -- no menus.
# --reconfigure forces the menus again and overwrites the saved choices.
load_config() {
  [[ "$RECONFIGURE" -eq 1 ]] && return 0
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  DE="${DE:-${SAVED_DE:-}}"
  PROTO="${PROTO:-${SAVED_PROTO:-}}"
  WEBGUI="${WEBGUI:-${SAVED_WEBGUI:-}}"
}

save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || return 0
  cat > "$CONFIG_FILE" <<EOF
SAVED_DE="$DE"
SAVED_PROTO="$PROTO"
SAVED_WEBGUI="$WEBGUI"
EOF
}

### ---------------- usage ----------------
usage() {
  cat <<EOF
Usage: $0 [--de phosh|plasma-mobile] [--proto vnc|rdp] [options]

  --de PHONE_SHELL     phosh | plasma-mobile   (asked interactively if omitted)
  --proto PROTOCOL     vnc | rdp               (asked interactively if omitted)
  --width N            virtual screen width  (default: $WIDTH)
  --height N           virtual screen height (default: $HEIGHT)
  --vnc-port N         VNC port  (default: $VNC_PORT)
  --rdp-port N         RDP port  (default: $RDP_PORT)
  --password PASS      set a password and allow listening on all interfaces
  --listen-all         bind to 0.0.0.0 even without --password (NOT recommended)
  --webgui WHICH        none | novnc | kasmvnc  (asked interactively if omitted)
  --webgui-port N       HTTP port for the browser client (default: $WEBGUI_PORT)
  --no-install-self     don't (re)install this script as /usr/bin/pmos
  --no-auto-install     don't try to apt/dnf/pacman-install missing dependencies
  --reconfigure          show the de/proto/webgui menus again and re-save them
  -h, --help           show this help

Examples:
  $0 --de phosh --proto vnc --webgui novnc
  $0 --de plasma-mobile --proto rdp --password 'changeMe123' --webgui kasmvnc

After the first run, this script installs itself as /usr/bin/pmos and saves
your de/proto/webgui choice to ~/.config/pmos/config, so afterwards just
running "pmos" starts the same session with no prompts. Use --reconfigure
or pass explicit flags to change it.
EOF
  exit "${1:-0}"
}

### ---------------- arg parsing ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --de) DE="$2"; shift 2 ;;
    --proto) PROTO="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --vnc-port) VNC_PORT="$2"; shift 2 ;;
    --rdp-port) RDP_PORT="$2"; shift 2 ;;
    --password) VNC_PASSWORD="$2"; shift 2 ;;
    --listen-all) LISTEN_ALL=1; shift ;;
    --webgui) WEBGUI="$2"; shift 2 ;;
    --webgui-port) WEBGUI_PORT="$2"; shift 2 ;;
    --no-install-self) INSTALL_SELF=0; shift ;;
    --no-auto-install) AUTO_INSTALL=0; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

load_config

if [[ -z "$DE" ]]; then
  echo "Select desktop shell:"
  select opt in "phosh" "plasma-mobile"; do
    [[ -n "${opt:-}" ]] && DE="$opt" && break
  done
fi

if [[ -z "$PROTO" ]]; then
  echo "Select remote protocol:"
  select opt in "vnc" "rdp"; do
    [[ -n "${opt:-}" ]] && PROTO="$opt" && break
  done
fi

if [[ -z "$WEBGUI" ]]; then
  echo "Select a browser-based VNC client (served over HTTP), or none:"
  select opt in "none" "novnc" "kasmvnc"; do
    [[ -n "${opt:-}" ]] && WEBGUI="$opt" && break
  done
fi

save_config

### ---------------- self-install as /usr/bin/pmos ----------------
# Copies this script to /usr/bin/pmos (via sudo) so future sessions can
# just be started with: pmos [--de ...] [--proto ...] [--webgui ...]
self_install_as_pmos() {
  local target="/usr/bin/pmos"
  local src
  src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  [[ "$src" == "$target" ]] && return 0   # already running as the installed copy

  if [[ ! -e "$target" ]] || ! cmp -s "$src" "$target" 2>/dev/null; then
    echo "[i] Installing this script as $target (sudo password may be requested)"
    if sudo cp "$src" "$target" && sudo chmod 755 "$target"; then
      echo "[i] Done. Next time, just run: pmos"
    else
      echo "[!] Could not install to $target (no sudo / read-only fs?) -- continuing anyway" >&2
    fi
  fi
}
[[ "$INSTALL_SELF" -eq 1 ]] && self_install_as_pmos

BIND_ADDR="127.0.0.1"
if [[ -n "$VNC_PASSWORD" || "$LISTEN_ALL" -eq 1 ]]; then
  BIND_ADDR="0.0.0.0"
fi
if [[ "$PROTO" == "rdp" && -z "$VNC_PASSWORD" ]]; then
  # generate a random password rather than shipping a default one
  if command -v openssl &>/dev/null; then
    VNC_PASSWORD="$(openssl rand -base64 12)"
  else
    VNC_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16)"
  fi
  echo "[i] Generated a random RDP/VNC password: $VNC_PASSWORD"
  BIND_ADDR="0.0.0.0"
fi

### ---------------- package manager / auto-install ----------------
detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then echo apt; return; fi
  if command -v dnf &>/dev/null; then echo dnf; return; fi
  if command -v pacman &>/dev/null; then echo pacman; return; fi
  if command -v zypper &>/dev/null; then echo zypper; return; fi
  echo unknown
}
PKG_MGR="$(detect_pkg_manager)"
APT_UPDATED=0

pkg_install() {
  # usage: pkg_install pkg1 pkg2 ...  (already the right names for $PKG_MGR)
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  echo "[i] Installing package(s): ${pkgs[*]}"
  case "$PKG_MGR" in
    apt)
      if [[ "$APT_UPDATED" -eq 0 ]]; then sudo apt-get update -qq && APT_UPDATED=1; fi
      sudo apt-get install -y "${pkgs[@]}"
      ;;
    dnf)    sudo dnf install -y "${pkgs[@]}" ;;
    pacman) sudo pacman -Sy --noconfirm "${pkgs[@]}" ;;
    zypper) sudo zypper --non-interactive install "${pkgs[@]}" ;;
    *) echo "[x] Unknown package manager -- install manually: ${pkgs[*]}" >&2; return 1 ;;
  esac
}

# ensure_installed CMD APT_PKG DNF_PKG PACMAN_PKG [ZYPPER_PKG]
# tries to install CMD's providing package if CMD isn't already on PATH.
ensure_installed() {
  local cmd="$1" apt_pkg="$2" dnf_pkg="$3" pacman_pkg="$4" zypper_pkg="${5:-$2}"
  command -v "$cmd" &>/dev/null && return 0
  [[ "$AUTO_INSTALL" -eq 0 ]] && { echo "[!] '$cmd' missing and --no-auto-install set" >&2; return 1; }
  case "$PKG_MGR" in
    apt)    pkg_install "$apt_pkg" ;;
    dnf)    pkg_install "$dnf_pkg" ;;
    pacman) pkg_install "$pacman_pkg" ;;
    zypper) pkg_install "$zypper_pkg" ;;
    *) echo "[!] Can't auto-install '$cmd' -- unknown package manager, install manually" >&2 ;;
  esac
  command -v "$cmd" &>/dev/null
}

ensure_webgui_assets() {
  [[ "$WEBGUI" == "none" ]] && return 0

  # websockify is the actual browser<->RFB bridge for both noVNC and KasmVNC's web client
  if ! command -v websockify &>/dev/null && [[ "$AUTO_INSTALL" -eq 1 ]]; then
    case "$PKG_MGR" in
      apt)    pkg_install websockify ;;
      dnf)    pkg_install python3-websockify ;;
      pacman) command -v pip &>/dev/null && pip install --user --quiet websockify ;;
      zypper) pkg_install python3-websockify ;;
    esac
  fi

  if [[ "$WEBGUI" == "novnc" ]]; then
    if [[ ! -d /usr/share/novnc && ! -d /opt/novnc ]] && [[ "$AUTO_INSTALL" -eq 1 ]]; then
      case "$PKG_MGR" in
        apt) pkg_install novnc ;;
        dnf) pkg_install novnc ;;
      esac
      if [[ ! -d /usr/share/novnc && ! -d /opt/novnc ]]; then
        echo "[i] noVNC not packaged here -- cloning from GitHub instead"
        sudo git clone --depth=1 https://github.com/novnc/noVNC /opt/novnc 2>/dev/null \
          || echo "[!] Could not clone noVNC automatically; install it manually" >&2
      fi
    fi
  fi

  if [[ "$WEBGUI" == "kasmvnc" ]]; then
    local found=0
    for d in /usr/share/kasmvnc/www /usr/share/kasmvncserver/www; do
      [[ -d "$d" ]] && found=1
    done
    if [[ "$found" -eq 0 && "$AUTO_INSTALL" -eq 1 && "$PKG_MGR" == "apt" ]]; then
      echo "[i] KasmVNC isn't packaged in standard apt repos -- attempting to fetch"
      echo "    the latest .deb release from GitHub (best-effort, verify manually"
      echo "    if this fails: https://github.com/kasmtech/KasmVNC/releases)"
      local codename asset_url deb
      codename="$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}" )"
      asset_url="$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null \
        | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' | grep -i "$codename" | head -n1)"
      [[ -z "$asset_url" ]] && asset_url="$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest 2>/dev/null \
        | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' | head -n1)"
      if [[ -n "$asset_url" ]]; then
        deb="$WORKDIR/kasmvnc.deb"
        if curl -fsSL -o "$deb" "$asset_url"; then
          sudo apt-get install -y "$deb" || echo "[!] KasmVNC .deb install failed, falling back to noVNC" >&2
        fi
      else
        echo "[!] Could not auto-detect a KasmVNC release asset. Falling back to noVNC's" >&2
        echo "    web client for this run; install KasmVNC manually if you need it." >&2
      fi
    elif [[ "$found" -eq 0 && "$PKG_MGR" != "apt" ]]; then
      echo "[!] No automatic KasmVNC install path for this distro/package manager." >&2
      echo "    See https://github.com/kasmtech/KasmVNC/releases, or use --webgui novnc." >&2
    fi
    # Always make sure novnc assets exist too, as a guaranteed fallback
    if [[ ! -d /usr/share/novnc && ! -d /opt/novnc ]] && [[ "$AUTO_INSTALL" -eq 1 ]]; then
      case "$PKG_MGR" in apt|dnf) pkg_install novnc 2>/dev/null || true ;; esac
      [[ ! -d /usr/share/novnc && ! -d /opt/novnc ]] && \
        sudo git clone --depth=1 https://github.com/novnc/noVNC /opt/novnc 2>/dev/null || true
    fi
  fi
}

### ---------------- GPU detection ----------------
detect_gpu() {
  local render_node=""
  for n in /dev/dri/renderD*; do
    [[ -e "$n" ]] && render_node="$n" && break
  done
  [[ -z "$render_node" ]] && { echo "cpu"; return; }

  if command -v lspci &>/dev/null; then
    if lspci -nnk 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'nvidia'; then
      echo "[!] NVIDIA GPU detected: proprietary driver GBM/EGL support for" >&2
      echo "    headless wlroots rendering can be flaky on older driver" >&2
      echo "    versions. Trying hardware rendering anyway; if it fails," >&2
      echo "    re-run and force CPU mode by exporting WLR_RENDERER=pixman" >&2
      echo "    and LIBGL_ALWAYS_SOFTWARE=1 before launching this script." >&2
    fi
  fi
  echo "gpu"
}

GPU_MODE="$(detect_gpu)"

if [[ "$GPU_MODE" == "gpu" ]]; then
  echo "[i] GPU render node found -> using hardware rendering"
  export WLR_RENDERER=gles2
  unset LIBGL_ALWAYS_SOFTWARE 2>/dev/null || true
  unset GALLIUM_DRIVER 2>/dev/null || true
else
  echo "[!] No GPU render node found -> falling back to CPU/software rendering"
  export WLR_RENDERER=pixman
  export LIBGL_ALWAYS_SOFTWARE=1
  export GALLIUM_DRIVER=llvmpipe
  export QT_QUICK_BACKEND=software
fi

### ---------------- cleanup ----------------
cleanup() {
  echo
  echo "[i] Shutting down..."
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

### ---------------- dependency check / auto-install ----------------
check_deps() {
  local missing=()

  case "$DE" in
    phosh)
      ensure_installed phoc   phoc phoc phoc   || missing+=("phoc")
      ensure_installed phosh  phosh phosh phosh || missing+=("phosh")
      ;;
    plasma-mobile)
      ensure_installed kwin_wayland kwin-wayland kwin plasma-mobile || missing+=("kwin_wayland")
      ;;
  esac

  case "$PROTO" in
    vnc)
      ensure_installed wayvnc wayvnc wayvnc wayvnc || missing+=("wayvnc")
      ;;
    rdp)
      ensure_installed wayvnc wayvnc wayvnc wayvnc || missing+=("wayvnc")
      ensure_installed xrdp   xrdp  xrdp  xrdp     || missing+=("xrdp")
      ;;
  esac

  ensure_webgui_assets

  if ((${#missing[@]})); then
    echo "[x] Still missing after auto-install attempt: ${missing[*]}" >&2
    echo "    Install them manually (see the comment block at the top of this script)" >&2
    echo "    or re-run with --no-auto-install off (the default) once network/sudo works." >&2
    exit 1
  fi
}
check_deps

export XDG_RUNTIME_DIR="$WORKDIR/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY="wayland-mobile"

# require_alive PID NAME LOGFILE
# Bails out with the tail of NAME's log if it already died -- surfaces
# bad-flag / crash errors immediately instead of limping on to start a
# VNC/RDP server against a dead compositor.
require_alive() {
  local pid="$1" name="$2" logfile="$3"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[x] $name exited immediately. Last log lines ($logfile):" >&2
    tail -n 25 "$logfile" >&2 2>/dev/null || true
    exit 1
  fi
}

# detect_actual_wayland_socket TIMEOUT PID NAME LOGFILE
# Different kwin_wayland/phoc builds don't all honour the WAYLAND_DISPLAY
# env var (or an explicit --socket flag) the same way for naming the
# socket they create -- rather than assume our requested name ("wayland-
# mobile") was actually used, poll $XDG_RUNTIME_DIR for whatever socket
# appears and adopt its real name. This is what fixed the previous
# "Failed to connect to WAYLAND_DISPLAY=wayland-mobile" error: kwin had
# created a socket under a different name than the one we assumed.
detect_actual_wayland_socket() {
  local timeout="$1" pid="$2" name="$3" logfile="$4"
  local waited=0 f found=""
  while (( waited < timeout * 2 )); do
    for f in "$XDG_RUNTIME_DIR"/wayland-*; do
      [[ -S "$f" ]] || continue
      found="$f"
      break
    done
    if [[ -n "$found" ]]; then
      WAYLAND_DISPLAY="$(basename "$found")"
      export WAYLAND_DISPLAY
      echo "[i] $name is listening on Wayland socket: $WAYLAND_DISPLAY"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[x] $name exited before creating a Wayland socket. Last log lines ($logfile):" >&2
      tail -n 25 "$logfile" >&2 2>/dev/null || true
      exit 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
  echo "[x] $name is still running but never created a Wayland socket in" >&2
  echo "    $XDG_RUNTIME_DIR within ${timeout}s. Last log lines ($logfile):" >&2
  tail -n 25 "$logfile" >&2 2>/dev/null || true
  exit 1
}

### ---------------- start compositor ----------------
start_phosh() {
  export WLR_BACKENDS=headless
  export WLR_LIBINPUT_NO_DEVICES=1

  phoc -C /etc/phosh/phoc.ini >"$LOGDIR/phoc.log" 2>&1 &
  local phoc_pid=$!
  PIDS+=("$phoc_pid")
  detect_actual_wayland_socket 15 "$phoc_pid" "phoc" "$LOGDIR/phoc.log"

  if command -v wlr-randr &>/dev/null; then
    wlr-randr --output HEADLESS-1 --custom-mode "${WIDTH}x${HEIGHT}" 2>/dev/null || true
  fi

  phosh >"$LOGDIR/phosh.log" 2>&1 &
  local phosh_pid=$!
  PIDS+=("$phosh_pid")
  sleep 2
  require_alive "$phosh_pid" "phosh" "$LOGDIR/phosh.log"
}

# Different kwin_wayland versions select the headless backend differently:
# newer builds take `--backend virtual`, older ones take a bare `--virtual`
# flag instead (and some don't support --width/--height at all). Rather
# than hardcode one, ask the binary itself via --help.
build_kwin_backend_args() {
  local help_out
  help_out="$(kwin_wayland --help 2>&1 || true)"
  KWIN_BACKEND_ARGS=()

  if echo "$help_out" | grep -qE -- '--backend\b'; then
    KWIN_BACKEND_ARGS+=(--backend virtual)
  elif echo "$help_out" | grep -qE -- '--virtual\b'; then
    KWIN_BACKEND_ARGS+=(--virtual)
  else
    echo "[!] Neither --backend nor --virtual found in 'kwin_wayland --help' on" >&2
    echo "    this system -- trying --virtual anyway. Run 'kwin_wayland --help'" >&2
    echo "    yourself and adjust build_kwin_backend_args() if this fails." >&2
    KWIN_BACKEND_ARGS+=(--virtual)
  fi

  echo "$help_out" | grep -qE -- '--width\b'  && KWIN_BACKEND_ARGS+=(--width "$WIDTH")
  echo "$help_out" | grep -qE -- '--height\b' && KWIN_BACKEND_ARGS+=(--height "$HEIGHT")
  # best-effort hint; detect_actual_wayland_socket is the real safety net
  echo "$help_out" | grep -qE -- '--socket\b'  && KWIN_BACKEND_ARGS+=(--socket "$WAYLAND_DISPLAY")
}

start_plasma_mobile() {
  build_kwin_backend_args
  echo "[i] kwin_wayland ${KWIN_BACKEND_ARGS[*]} --exit-with-session=$PLASMA_MOBILE_CMD"
  kwin_wayland \
    "${KWIN_BACKEND_ARGS[@]}" \
    --exit-with-session="$PLASMA_MOBILE_CMD" \
    >"$LOGDIR/kwin.log" 2>&1 &
  local kwin_pid=$!
  PIDS+=("$kwin_pid")
  detect_actual_wayland_socket 20 "$kwin_pid" "kwin_wayland" "$LOGDIR/kwin.log"
}

case "$DE" in
  phosh) start_phosh ;;
  plasma-mobile) start_plasma_mobile ;;
esac

### ---------------- start remote access ----------------
start_vnc() {
  local cfg="$WORKDIR/wayvnc.cfg"
  {
    echo "address=$BIND_ADDR"
    echo "port=$VNC_PORT"
    if [[ -n "$VNC_PASSWORD" ]]; then
      echo "enable_auth=true"
      echo "username=mobile"
      echo "password=$VNC_PASSWORD"
    fi
  } > "$cfg"

  wayvnc -C "$cfg" >"$LOGDIR/wayvnc.log" 2>&1 &
  local wayvnc_pid=$!
  PIDS+=("$wayvnc_pid")
  sleep 1
  require_alive "$wayvnc_pid" "wayvnc" "$LOGDIR/wayvnc.log"
  echo "[i] VNC listening on $BIND_ADDR:$VNC_PORT"
}

start_rdp_via_vnc_bridge() {
  # wayvnc stays on loopback; xrdp is the only thing that may face the network
  local cfg="$WORKDIR/wayvnc.cfg"
  {
    echo "address=127.0.0.1"
    echo "port=$VNC_PORT"
    echo "enable_auth=true"
    echo "username=mobile"
    echo "password=$VNC_PASSWORD"
  } > "$cfg"

  wayvnc -C "$cfg" >"$LOGDIR/wayvnc.log" 2>&1 &
  local wayvnc_pid=$!
  PIDS+=("$wayvnc_pid")
  sleep 1
  require_alive "$wayvnc_pid" "wayvnc" "$LOGDIR/wayvnc.log"

  local xrdp_ini="$WORKDIR/xrdp.ini"
  cp /etc/xrdp/xrdp.ini "$xrdp_ini" 2>/dev/null || echo "[Globals]" > "$xrdp_ini"
  if grep -q '^port=' "$xrdp_ini"; then
    sed -i "s/^port=.*/port=$RDP_PORT/" "$xrdp_ini"
  else
    echo "port=$RDP_PORT" >> "$xrdp_ini"
  fi

  cat >> "$xrdp_ini" <<EOF

[mobile-bridge]
name=mobile-remote
lib=libvnc.so
ip=127.0.0.1
port=$VNC_PORT
username=mobile
password=$VNC_PASSWORD
EOF

  echo "[i] Wrote a bridge config to $xrdp_ini."
  echo "    If your xrdp binary refuses a --config flag, instead merge the"
  echo "    [mobile-bridge] block above into /etc/xrdp/xrdp.ini and run:"
  echo "      sudo systemctl restart xrdp"
  echo "    then connect the RDP client to this host and choose the"
  echo "    'mobile-bridge' session at the xrdp login screen."

  xrdp --config "$xrdp_ini" --nodaemon >"$LOGDIR/xrdp.log" 2>&1 &
  local xrdp_pid=$!
  PIDS+=("$xrdp_pid")
  sleep 1
  require_alive "$xrdp_pid" "xrdp" "$LOGDIR/xrdp.log"
  echo "[i] RDP listening on 0.0.0.0:$RDP_PORT (bridged to local VNC)"
}

case "$PROTO" in
  vnc) start_vnc ;;
  rdp) start_rdp_via_vnc_bridge ;;
esac

### ---------------- web GUI (noVNC / KasmVNC client) ----------------
start_webgui() {
  [[ "$WEBGUI" == "none" ]] && return 0

  local assets=""
  case "$WEBGUI" in
    novnc)
      for d in /usr/share/novnc /usr/share/webapps/novnc /opt/novnc; do
        [[ -d "$d" ]] && assets="$d" && break
      done
      ;;
    kasmvnc)
      for d in /usr/share/kasmvnc/www /usr/share/kasmvncserver/www /opt/kasmweb; do
        [[ -d "$d" ]] && assets="$d" && break
      done
      if [[ -z "$assets" ]]; then
        for d in /usr/share/novnc /opt/novnc; do
          [[ -d "$d" ]] && assets="$d" && break
        done
        [[ -n "$assets" ]] && echo "[!] KasmVNC web assets not found -- serving noVNC's client instead" >&2
      fi
      ;;
  esac

  if [[ -z "$assets" ]]; then
    echo "[x] No web client assets found for --webgui=$WEBGUI, skipping the browser GUI" >&2
    return 1
  fi
  if ! command -v websockify &>/dev/null; then
    echo "[x] websockify not found, cannot start the browser GUI" >&2
    return 1
  fi

  # websockify always points at the local RFB port wayvnc is already serving,
  # regardless of whether the overall session is in vnc or rdp mode.
  websockify --web="$assets" "$WEBGUI_PORT" "127.0.0.1:$VNC_PORT" \
    >"$LOGDIR/websockify.log" 2>&1 &
  PIDS+=($!)
  echo "[i] Web GUI ($WEBGUI) at: http://<host>:$WEBGUI_PORT/vnc.html"
}
start_webgui

### ---------------- summary ----------------
echo
echo "==================================================="
echo " Shell:      $DE"
echo " Protocol:   $PROTO"
echo " Rendering:  $([[ $GPU_MODE == gpu ]] && echo 'GPU (hardware)' || echo 'CPU (software / llvmpipe)')"
[[ "$PROTO" == vnc ]] && echo " Connect:    vnc://<host>:$VNC_PORT"
[[ "$PROTO" == rdp ]] && echo " Connect:    rdp://<host>:$RDP_PORT  (user: mobile)"
[[ "$WEBGUI" != "none" ]] && echo " Web GUI:    http://<host>:$WEBGUI_PORT/vnc.html  ($WEBGUI)"
[[ -n "$VNC_PASSWORD" ]] && echo " Password:   $VNC_PASSWORD"
echo " Logs:       $LOGDIR"
[[ "$INSTALL_SELF" -eq 1 ]] && echo " Launcher:   /usr/bin/pmos  (run this whole thing again with: pmos)"
echo "==================================================="
echo "Press Ctrl+C to stop the session and clean up."
echo

wait
