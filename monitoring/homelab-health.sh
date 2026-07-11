#!/usr/bin/env bash
#
# homelab-health.sh — health check for the docker-compose stack plus CPU and
# hard-drive temperatures for Rogue (the local Linux Docker host) and the
# Mac Mini (collected over SSH).
#
# Run this ON Rogue:
#     ./monitoring/homelab-health.sh
#
# Exit status: 0 = all OK, 1 = warnings present, 2 = critical problems.
#
# Configuration lives in monitoring/homelab-health.conf (see .conf.example).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --------------------------------------------------------------------------
# Defaults (overridable via homelab-health.conf)
# --------------------------------------------------------------------------
COMPOSE_DIR=""
EXPECTED_CONTAINERS="haproxy mongo n8n elasticSearch obsidian calibre webdav"
HAPROXY_STATS_URL="http://localhost:8404/"
ROGUE_NAME="Rogue"
MACMINI_SSH=""
MACMINI_SCRIPT_PATH="~/homelab/monitoring/temps-macos.sh"
CPU_WARN=70
CPU_CRIT=85
DRIVE_WARN=45
DRIVE_CRIT=55
NO_COLOR=0

[ -f "$SCRIPT_DIR/homelab-health.conf" ] && . "$SCRIPT_DIR/homelab-health.conf"
[ -z "$COMPOSE_DIR" ] && COMPOSE_DIR="$REPO_ROOT"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [ "$NO_COLOR" = "1" ] || [ ! -t 1 ]; then
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_DIM=""
else
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
fi

OK_COUNT=0; WARN_COUNT=0; CRIT_COUNT=0

status_line() {  # status_line <OK|WARN|CRIT> <message>
  local s="$1"; shift
  case "$s" in
    OK)   printf '  %s[ OK ]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; OK_COUNT=$((OK_COUNT+1));;
    WARN) printf '  %s[WARN]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; WARN_COUNT=$((WARN_COUNT+1));;
    CRIT) printf '  %s[CRIT]%s %s\n'   "$C_RED"    "$C_RESET" "$*"; CRIT_COUNT=$((CRIT_COUNT+1));;
    INFO) printf '  %s[info]%s %s\n'   "$C_DIM"    "$C_RESET" "$*";;
  esac
}

header() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Classify an integer-ish temperature against warn/crit thresholds.
temp_status() {  # temp_status <celsius> <warn> <crit>
  local t="$1" w="$2" c="$3"
  # strip decimals for comparison
  local ti=${t%%.*}
  [ -z "$ti" ] && { echo "INFO"; return; }
  if   [ "$ti" -ge "$c" ] 2>/dev/null; then echo "CRIT"
  elif [ "$ti" -ge "$w" ] 2>/dev/null; then echo "WARN"
  else echo "OK"; fi
}

# --------------------------------------------------------------------------
# 1. Docker component health
# --------------------------------------------------------------------------
check_docker() {
  header "Docker components ($COMPOSE_DIR)"

  if ! command -v docker >/dev/null 2>&1; then
    status_line CRIT "docker CLI not found"
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    status_line CRIT "cannot reach the Docker daemon (is it running? permissions?)"
    return
  fi

  local name state health restarts
  for name in $EXPECTED_CONTAINERS; do
    if ! docker inspect "$name" >/dev/null 2>&1; then
      status_line CRIT "$name: container does not exist"
      continue
    fi
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)
    restarts=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null)

    if [ "$state" != "running" ]; then
      status_line CRIT "$name: state=$state"
    elif [ "$health" = "unhealthy" ]; then
      status_line CRIT "$name: running but healthcheck=unhealthy (restarts=$restarts)"
    elif [ "$health" = "starting" ]; then
      status_line WARN "$name: healthcheck still starting"
    elif [ "${restarts:-0}" -gt 3 ] 2>/dev/null; then
      status_line WARN "$name: running (health=$health) but restarted $restarts times"
    else
      status_line OK "$name: running (health=$health, restarts=$restarts)"
    fi
  done

  # End-to-end probe: haproxy stats page should answer.
  if command -v curl >/dev/null 2>&1; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HAPROXY_STATS_URL" 2>/dev/null)
    if [ "$code" = "200" ]; then
      status_line OK "haproxy stats reachable ($HAPROXY_STATS_URL -> 200)"
    else
      status_line WARN "haproxy stats probe returned '$code' ($HAPROXY_STATS_URL)"
    fi
  fi
}

# --------------------------------------------------------------------------
# 2. Rogue (local Linux) temperatures
# --------------------------------------------------------------------------
check_rogue_cpu() {
  header "$ROGUE_NAME — CPU / system temperatures"

  if command -v sensors >/dev/null 2>&1; then
    # Pull every temperature reading lm-sensors exposes and grade the hottest.
    local hottest=0 line label val st
    while IFS= read -r line; do
      label=$(printf '%s' "$line" | sed -E 's/:.*//' | xargs)
      val=$(printf '%s' "$line" | grep -oE '\+[0-9]+\.[0-9]+°C' | head -1 | grep -oE '[0-9]+\.[0-9]+')
      [ -z "$val" ] && continue
      st=$(temp_status "$val" "$CPU_WARN" "$CPU_CRIT")
      status_line "$st" "$(printf '%-20s %s°C' "$label" "$val")"
      [ "${val%%.*}" -gt "$hottest" ] 2>/dev/null && hottest=${val%%.*}
    done < <(sensors 2>/dev/null | grep -E '°C')
    [ "$hottest" = "0" ] && status_line INFO "sensors produced no temperature lines (run 'sudo sensors-detect' once)"
  elif [ -d /sys/class/thermal ] && ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1; then
    # Fallback: read thermal zones directly from sysfs.
    local z type mC val st
    for z in /sys/class/thermal/thermal_zone*/; do
      [ -f "$z/temp" ] || continue
      type=$(cat "$z/type" 2>/dev/null)
      mC=$(cat "$z/temp" 2>/dev/null)
      val=$(awk "BEGIN{printf \"%.1f\", $mC/1000}")
      st=$(temp_status "$val" "$CPU_WARN" "$CPU_CRIT")
      status_line "$st" "$(printf '%-20s %s°C' "$type" "$val")"
    done
  else
    status_line INFO "no temperature source (install lm-sensors: apt install lm-sensors && sudo sensors-detect)"
  fi
}

# --------------------------------------------------------------------------
# 3. Drive temperatures (local Linux, via smartctl)
# --------------------------------------------------------------------------
check_rogue_drives() {
  header "$ROGUE_NAME — attached hard drives"

  if ! command -v smartctl >/dev/null 2>&1; then
    status_line INFO "smartctl not found (apt install smartmontools) — trying hddtemp"
    if command -v hddtemp >/dev/null 2>&1; then
      local d out temp st
      for d in /dev/sd?; do
        [ -e "$d" ] || continue
        out=$(sudo -n hddtemp -n "$d" 2>/dev/null)
        [ -z "$out" ] && continue
        st=$(temp_status "$out" "$DRIVE_WARN" "$DRIVE_CRIT")
        status_line "$st" "$(printf '%-12s %s°C' "$d" "$out")"
      done
    fi
    return
  fi

  # Enumerate physical block devices (disks, not partitions/loop/rom).
  local disks d model temp st
  if command -v lsblk >/dev/null 2>&1; then
    disks=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}')
  else
    disks=$(ls /dev/sd? /dev/nvme?n? 2>/dev/null)
  fi

  if [ -z "$disks" ]; then
    status_line INFO "no block devices enumerated"
    return
  fi

  for d in $disks; do
    model=$(sudo -n smartctl -i "$d" 2>/dev/null | awk -F: '/Device Model|Model Number|Product/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
    [ -z "$model" ] && model="?"
    temp=$(sudo -n smartctl -A "$d" 2>/dev/null | awk '
      /Temperature_Celsius/ {print $10; exit}
      /Current Drive Temperature/ {print $4; exit}
      /^Temperature:/ {print $2; exit}')
    if [ -z "$temp" ]; then
      status_line INFO "$(printf '%-12s %-24s temp not reported (USB bridge? needs -d sat)' "$d" "$model")"
      continue
    fi
    st=$(temp_status "$temp" "$DRIVE_WARN" "$DRIVE_CRIT")
    status_line "$st" "$(printf '%-12s %-24s %s°C' "$d" "$model" "$temp")"
  done
}

# --------------------------------------------------------------------------
# 4. Mac Mini temperatures (over SSH)
# --------------------------------------------------------------------------
check_macmini() {
  header "Mac Mini — CPU & drive temperatures (via SSH)"

  if [ -z "$MACMINI_SSH" ]; then
    status_line INFO "MACMINI_SSH not set in homelab-health.conf — skipping Mac Mini"
    return
  fi

  # Prefer the script already installed on the Mac; otherwise stream ours over.
  local out
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$MACMINI_SSH" \
        "bash $MACMINI_SCRIPT_PATH" 2>/dev/null)
  if [ -z "$out" ]; then
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$MACMINI_SSH" 'bash -s' \
          < "$SCRIPT_DIR/temps-macos.sh" 2>/dev/null)
  fi

  if [ -z "$out" ]; then
    status_line WARN "no response from $MACMINI_SSH (check SSH key auth / host reachable)"
    return
  fi

  local kind a b c st
  while IFS='|' read -r kind a b c; do
    case "$kind" in
      CPU)
        st=$(temp_status "$b" "$CPU_WARN" "$CPU_CRIT")
        status_line "$st" "$(printf 'CPU (%-12s) %s°C' "$a" "$b")";;
      DRIVE)
        st=$(temp_status "$c" "$DRIVE_WARN" "$DRIVE_CRIT")
        status_line "$st" "$(printf '%-12s %-24s %s°C' "$a" "$b" "$c")";;
      NOTE)
        status_line INFO "$a";;
    esac
  done <<< "$out"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
printf '%s%s Homelab health check — %s %s%s\n' \
  "$C_BOLD" "================" "$(date '+%Y-%m-%d %H:%M:%S')" "================" "$C_RESET"

check_docker
check_rogue_cpu
check_rogue_drives
check_macmini

header "Summary"
printf '  %sOK: %d%s   %sWARN: %d%s   %sCRIT: %d%s\n' \
  "$C_GREEN" "$OK_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
  "$C_RED" "$CRIT_COUNT" "$C_RESET"

if   [ "$CRIT_COUNT" -gt 0 ]; then exit 2
elif [ "$WARN_COUNT" -gt 0 ]; then exit 1
else exit 0; fi
