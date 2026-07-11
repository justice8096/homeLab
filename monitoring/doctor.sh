#!/usr/bin/env bash
#
# doctor.sh — readiness self-check for the homelab health toolkit.
#
# Verifies that everything homelab-health.sh needs is actually in place on
# Rogue: dependencies installed, drives readable, MQTT broker reachable, and
# (optionally) the Mac Mini answering over SSH. Run it after install.sh, or
# any time the entities aren't showing up in Home Assistant.
#
#     ./monitoring/doctor.sh
#
# Exit status: 0 = ready, 1 = warnings, 2 = something required is broken.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults mirror homelab-health.sh; the conf overrides them.
MQTT_ENABLED=0 MQTT_HOST="" MQTT_PORT=1883 MQTT_USER="" MQTT_PASS=""
MQTT_BASE="homelab" MQTT_DISCOVERY="homeassistant"
MACMINI_SSH="" HAPROXY_STATS_URL="http://localhost:8404/"
[ -f "$SCRIPT_DIR/homelab-health.conf" ] && . "$SCRIPT_DIR/homelab-health.conf"

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; Y=""; R=""; B=""; Z=""; fi

warns=0 fails=0
pass() { printf '  %s[ PASS ]%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s[ WARN ]%s %s\n' "$Y" "$Z" "$*"; warns=$((warns+1)); }
fail() { printf '  %s[ FAIL ]%s %s\n' "$R" "$Z" "$*"; fails=$((fails+1)); }
head() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z"; }

have() { command -v "$1" >/dev/null 2>&1; }

head "Dependencies"
have docker        && pass "docker present"          || warn "docker not found (container checks will report CRIT)"
have curl          && pass "curl present"            || warn "curl not found (haproxy probe skipped)"
have sensors       && pass "lm-sensors present"      || warn "lm-sensors not found (falls back to /sys/class/thermal)"
have smartctl      && pass "smartmontools present"   || warn "smartctl not found (drive temps/health unavailable)"
if [ "$MQTT_ENABLED" = "1" ]; then
  have mosquitto_pub && pass "mosquitto-clients present" || fail "mosquitto_pub not found — MQTT can't publish (apt install mosquitto-clients)"
fi

head "Privileges"
if have smartctl; then
  if sudo -n smartctl --version >/dev/null 2>&1; then
    pass "passwordless 'sudo smartctl' works"
  else
    warn "sudo needs a password for smartctl — run the whole script with sudo, or add a sudoers rule (see README)"
  fi
fi

head "Drives visible to SMART"
if have smartctl && have lsblk; then
  disks=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}')
  if [ -z "$disks" ]; then
    warn "no physical disks enumerated"
  else
    for d in $disks; do
      if sudo -n smartctl -i "$d" >/dev/null 2>&1 || sudo -n smartctl -i -d sat "$d" >/dev/null 2>&1; then
        pass "$d responds to smartctl"
      else
        warn "$d does not respond to smartctl (enclosure without SAT passthrough?)"
      fi
    done
  fi
fi

head "Home Assistant MQTT broker"
if [ "$MQTT_ENABLED" != "1" ]; then
  warn "MQTT_ENABLED is not 1 — set it in homelab-health.conf to publish to Home Assistant"
elif [ -z "$MQTT_HOST" ]; then
  fail "MQTT_HOST is empty — set your broker address in homelab-health.conf"
elif ! have mosquitto_pub; then
  fail "cannot test broker without mosquitto-clients"
else
  args=(-h "$MQTT_HOST" -p "$MQTT_PORT")
  [ -n "$MQTT_USER" ] && args+=(-u "$MQTT_USER")
  [ -n "$MQTT_PASS" ] && args+=(-P "$MQTT_PASS")
  # Publish a probe and try to read it back (needs mosquitto_sub too).
  if mosquitto_pub "${args[@]}" -t "$MQTT_BASE/doctor" -m "ok" 2>/dev/null; then
    pass "published to broker $MQTT_HOST:$MQTT_PORT"
    if have mosquitto_sub; then
      got=$(mosquitto_sub "${args[@]}" -t "$MQTT_BASE/doctor" -C 1 -W 4 2>/dev/null)
      [ "$got" = "ok" ] && pass "round-trip publish/subscribe confirmed" \
                        || warn "published but couldn't read the probe back within 4s"
    else
      warn "mosquitto_sub not installed — can't confirm round-trip (publish succeeded though)"
    fi
    printf '  %s[ INFO ]%s in HA: Settings → Devices & Services → MQTT should list Rogue / Mac Mini / Homelab Docker after a run\n' "$B" "$Z"
  else
    fail "cannot reach broker $MQTT_HOST:$MQTT_PORT (check address, credentials, and that the broker is running)"
  fi
fi

if [ -n "$MACMINI_SSH" ]; then
  head "Mac Mini SSH"
  if ssh -o BatchMode=yes -o ConnectTimeout=6 "$MACMINI_SSH" true 2>/dev/null; then
    pass "key-based SSH to $MACMINI_SSH works"
  else
    warn "cannot SSH to $MACMINI_SSH without a password (enable Remote Login + ssh-copy-id)"
  fi
fi

head "Result"
if   [ "$fails" -gt 0 ]; then printf '  %s%d failure(s), %d warning(s) — fix failures before the sensors will appear%s\n' "$R" "$fails" "$warns" "$Z"; exit 2
elif [ "$warns" -gt 0 ]; then printf '  %s%d warning(s) — will work, but some data may be missing%s\n' "$Y" "$warns" "$Z"; exit 1
else printf '  %sall checks passed — run ./monitoring/homelab-health.sh --mqtt%s\n' "$G" "$Z"; exit 0; fi
