#!/usr/bin/env bash
#
# install.sh — one-command setup for the homelab health toolkit ON ROGUE.
#
# Installs dependencies, initialises lm-sensors, writes homelab-health.conf
# from the values you pass, sets up a schedule (cron by default), and runs the
# doctor self-check. Re-runnable: existing config keys are updated in place.
#
# Examples:
#   sudo ./monitoring/install.sh \
#        --broker 192.168.1.10 --broker-user homelab --broker-pass 's3cret' \
#        --macmini admin@macmini.local
#
#   sudo ./monitoring/install.sh --schedule systemd --interval 10
#   ./monitoring/install.sh --no-install --schedule none   # just write conf + test
#
# The one thing this cannot do for you: adding the MQTT integration inside the
# Home Assistant UI (Settings → Devices & Services → Add Integration → MQTT).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/homelab-health.conf"
EXAMPLE="$SCRIPT_DIR/homelab-health.conf.example"
HEALTH="$SCRIPT_DIR/homelab-health.sh"

# --- options ---------------------------------------------------------------
BROKER="" BUSER="" BPASS="" MACMINI="" SCHEDULE="cron" INTERVAL=15
DO_INSTALL=1 ASSUME_YES=0

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --broker)      BROKER="$2"; shift 2;;
    --broker-user) BUSER="$2"; shift 2;;
    --broker-pass) BPASS="$2"; shift 2;;
    --macmini)     MACMINI="$2"; shift 2;;
    --schedule)    SCHEDULE="$2"; shift 2;;
    --interval)    INTERVAL="$2"; shift 2;;
    --no-install)  DO_INSTALL=0; shift;;
    --yes|-y)      ASSUME_YES=1; shift;;
    -h|--help)     usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# --- 1. dependencies -------------------------------------------------------
if [ "$DO_INSTALL" = "1" ]; then
  say "Installing dependencies"
  PKGS="mosquitto-clients lm-sensors smartmontools curl"
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y $PKGS
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y mosquitto lm_sensors smartmontools curl
  elif command -v pacman  >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm mosquitto lm_sensors smartmontools curl
  else warn "no supported package manager found — install manually: $PKGS"; fi

  if command -v sensors-detect >/dev/null 2>&1 && command -v sensors >/dev/null 2>&1; then
    if ! sensors 2>/dev/null | grep -q '°C'; then
      say "Initialising lm-sensors (sensors-detect --auto)"
      $SUDO sensors-detect --auto >/dev/null 2>&1 || warn "sensors-detect did not complete; you may need to run it interactively"
    fi
  fi
else
  say "Skipping dependency install (--no-install)"
fi

# --- 2. config -------------------------------------------------------------
say "Writing configuration ($CONF)"
[ -f "$EXAMPLE" ] || die "missing $EXAMPLE"
if [ ! -f "$CONF" ]; then cp "$EXAMPLE" "$CONF"; say "created conf from example"; fi

set_conf() {  # set_conf KEY VALUE
  local key="$1" val="$2" esc
  esc=$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')
  if grep -qE "^${key}=" "$CONF"; then
    sed -i -E "s|^${key}=.*|${key}=\"${esc}\"|" "$CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CONF"
  fi
}

# Interactive prompts for anything not provided (only when attached to a TTY).
if [ -z "$BROKER" ] && [ "$ASSUME_YES" = "0" ] && [ -t 0 ]; then
  read -r -p "MQTT broker host (blank = leave existing conf value): " BROKER
  if [ -n "$BROKER" ]; then
    read -r -p "  broker username (blank for anonymous): " BUSER
    read -r -s -p "  broker password (blank for none): " BPASS; echo
  fi
fi
if [ -z "$MACMINI" ] && [ "$ASSUME_YES" = "0" ] && [ -t 0 ]; then
  read -r -p "Mac Mini SSH target (user@host, blank to skip): " MACMINI
fi

if [ -n "$BROKER" ]; then
  set_conf MQTT_ENABLED 1
  set_conf MQTT_HOST "$BROKER"
  [ -n "$BUSER" ] && set_conf MQTT_USER "$BUSER"
  [ -n "$BPASS" ] && set_conf MQTT_PASS "$BPASS"
fi
[ -n "$MACMINI" ] && set_conf MACMINI_SSH "$MACMINI"
chmod 600 "$CONF" 2>/dev/null || true   # conf may hold broker credentials

# --- 3. schedule -----------------------------------------------------------
LOG="/var/log/homelab-health.log"
case "$SCHEDULE" in
  cron)
    say "Installing cron job (every ${INTERVAL} min)"
    LINE="*/${INTERVAL} * * * * $HEALTH --mqtt >> $LOG 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'homelab-health.sh'; echo "$LINE" ) | crontab - \
      && say "cron installed — view with: crontab -l" \
      || warn "could not install crontab (no cron? try --schedule systemd)"
    ;;
  systemd)
    say "Installing systemd service + timer (every ${INTERVAL} min)"
    UNIT_DIR="/etc/systemd/system"
    $SUDO tee "$UNIT_DIR/homelab-health.service" >/dev/null <<EOF
[Unit]
Description=Homelab health check + Home Assistant MQTT publish
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$HEALTH --mqtt
EOF
    $SUDO tee "$UNIT_DIR/homelab-health.timer" >/dev/null <<EOF
[Unit]
Description=Run homelab-health every ${INTERVAL} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now homelab-health.timer \
      && say "timer enabled — status: systemctl status homelab-health.timer; logs: journalctl -u homelab-health.service" \
      || warn "could not enable timer"
    ;;
  none)
    say "No schedule installed (--schedule none) — run manually with: $HEALTH --mqtt"
    ;;
  *) die "unknown --schedule '$SCHEDULE' (use cron|systemd|none)";;
esac

# --- 4. verify -------------------------------------------------------------
say "Running readiness self-check (doctor.sh)"
chmod +x "$HEALTH" "$SCRIPT_DIR"/*.sh 2>/dev/null || true
"$SCRIPT_DIR/doctor.sh" || true

echo
say "Done. Remaining manual step: in Home Assistant add the MQTT integration"
say "(Settings → Devices & Services → Add Integration → MQTT) pointed at your broker."
say "Then the Rogue / Mac Mini / Homelab Docker devices appear under MQTT."
