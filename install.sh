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

WORKDIR="$(mktemp -d /tmp/mobile-remote.XXXXXX)"
LOGDIR="$WORKDIR/logs"
mkdir -p "$LOGDIR"
PIDS=()

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
  -h, --help           show this help

Examples:
  $0 --de phosh --proto vnc
  $0 --de plasma-mobile --proto rdp --password 'changeMe123'
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
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

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

### ---------------- dependency check ----------------
check_deps() {
  local missing=()
  case "$DE" in
    phosh) for c in phoc phosh; do command -v "$c" &>/dev/null || missing+=("$c"); done ;;
    plasma-mobile) command -v kwin_wayland &>/dev/null || missing+=("kwin_wayland") ;;
  esac
  case "$PROTO" in
    vnc) command -v wayvnc &>/dev/null || missing+=("wayvnc") ;;
    rdp) command -v wayvnc &>/dev/null || missing+=("wayvnc")
         command -v xrdp   &>/dev/null || missing+=("xrdp") ;;
  esac
  if ((${#missing[@]})); then
    echo "[x] Missing required tools: ${missing[*]}" >&2
    echo "    See the install hints in the comment block at the top of this script." >&2
    exit 1
  fi
}
check_deps

export XDG_RUNTIME_DIR="$WORKDIR/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY="wayland-mobile"

### ---------------- start compositor ----------------
start_phosh() {
  export WLR_BACKENDS=headless
  export WLR_LIBINPUT_NO_DEVICES=1

  phoc -C /etc/phosh/phoc.ini >"$LOGDIR/phoc.log" 2>&1 &
  PIDS+=($!)
  sleep 2

  if command -v wlr-randr &>/dev/null; then
    wlr-randr --output HEADLESS-1 --custom-mode "${WIDTH}x${HEIGHT}" 2>/dev/null || true
  fi

  phosh >"$LOGDIR/phosh.log" 2>&1 &
  PIDS+=($!)
  sleep 2
}

start_plasma_mobile() {
  # Best-effort invocation -- verify flags against `kwin_wayland --help`
  # on your system and the Exec= line in
  # /usr/share/wayland-sessions/plasma-mobile.desktop if this fails.
  kwin_wayland \
    --backend virtual \
    --width "$WIDTH" --height "$HEIGHT" \
    --exit-with-session="$PLASMA_MOBILE_CMD" \
    >"$LOGDIR/kwin.log" 2>&1 &
  PIDS+=($!)
  sleep 3
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
  PIDS+=($!)
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
  PIDS+=($!)
  sleep 1

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
  PIDS+=($!)
  echo "[i] RDP listening on 0.0.0.0:$RDP_PORT (bridged to local VNC)"
}

case "$PROTO" in
  vnc) start_vnc ;;
  rdp) start_rdp_via_vnc_bridge ;;
esac

### ---------------- summary ----------------
echo
echo "==================================================="
echo " Shell:      $DE"
echo " Protocol:   $PROTO"
echo " Rendering:  $([[ $GPU_MODE == gpu ]] && echo 'GPU (hardware)' || echo 'CPU (software / llvmpipe)')"
[[ "$PROTO" == vnc ]] && echo " Connect:    vnc://<host>:$VNC_PORT"
[[ "$PROTO" == rdp ]] && echo " Connect:    rdp://<host>:$RDP_PORT  (user: mobile)"
[[ -n "$VNC_PASSWORD" ]] && echo " Password:   $VNC_PASSWORD"
echo " Logs:       $LOGDIR"
echo "==================================================="
echo "Press Ctrl+C to stop the session and clean up."
echo

wait
