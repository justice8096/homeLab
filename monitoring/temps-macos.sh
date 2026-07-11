#!/usr/bin/env bash
#
# temps-macos.sh — report CPU and hard-drive temperatures on a macOS host
# (the Mac Mini). Emits machine-readable lines so it can be run locally or
# streamed over SSH by homelab-health.sh.
#
# Output format (one record per line):
#   CPU|<label>|<celsius>
#   DRIVE|<device>|<model>|<celsius>
#   NOTE|<free text>            (informational, non-fatal)
#
# Temperature sources are tried in order of reliability/availability:
#   CPU    : istats  ->  osx-cpu-temp  ->  powermetrics (needs sudo)
#   DRIVES : smartctl (smartmontools)  ->  diskutil (no temp; enumerates only)
#
set -uo pipefail

emit() { printf '%s\n' "$*"; }

# --------------------------------------------------------------------------
# CPU temperature
# --------------------------------------------------------------------------
cpu_temp() {
  if command -v istats >/dev/null 2>&1; then
    # `istats cpu temp` -> "CPU temp: 41.2°C"
    local t
    t=$(istats cpu temp --value-only 2>/dev/null | tr -d '[:space:]')
    if [ -n "$t" ]; then emit "CPU|istats|$t"; return; fi
  fi

  if command -v osx-cpu-temp >/dev/null 2>&1; then
    # `osx-cpu-temp` -> "54.2°C"  (Intel Macs; Apple Silicon may print 0.0)
    local t
    t=$(osx-cpu-temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$t" ] && [ "$t" != "0.0" ]; then emit "CPU|osx-cpu-temp|$t"; return; fi
  fi

  if command -v powermetrics >/dev/null 2>&1; then
    # Requires root. Sample the SMC once and pull the CPU die temperature.
    local out t
    out=$(sudo -n powermetrics --samplers smc -n1 -i1 2>/dev/null)
    t=$(printf '%s\n' "$out" | grep -iE 'CPU die temperature' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$t" ]; then emit "CPU|powermetrics|$t"; return; fi
  fi

  emit "NOTE|No CPU temperature source available (install: brew install istats OR osx-cpu-temp, or allow passwordless sudo powermetrics)"
}

# --------------------------------------------------------------------------
# Drive temperatures
# --------------------------------------------------------------------------
drive_temps() {
  if ! command -v smartctl >/dev/null 2>&1; then
    emit "NOTE|smartctl not found — install with: brew install smartmontools"
    if command -v diskutil >/dev/null 2>&1; then
      diskutil list physical 2>/dev/null | grep -oE '/dev/disk[0-9]+' | sort -u \
        | while read -r d; do emit "NOTE|Detected $d (temperature unavailable without smartctl)"; done
    fi
    return
  fi

  # Enumerate physical disks.
  local disks
  disks=$(diskutil list physical 2>/dev/null | grep -oE '/dev/disk[0-9]+' | sort -u)
  [ -z "$disks" ] && disks=$(ls /dev/disk[0-9] 2>/dev/null)

  local d model temp
  for d in $disks; do
    model=$(smartctl -i "$d" 2>/dev/null | awk -F: '/Model|Product|Device Model/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
    [ -z "$model" ] && model="unknown"
    # Try the SMART temperature attribute (194) then the NVMe/SCSI style line.
    temp=$(smartctl -A "$d" 2>/dev/null | awk '
      /Temperature_Celsius/ {print $10; found=1; exit}
      /Current Drive Temperature/ {print $4; found=1; exit}
      /^Temperature:/ {print $2; found=1; exit}')
    if [ -n "$temp" ]; then
      emit "DRIVE|$d|$model|$temp"
    else
      emit "NOTE|$d ($model): SMART temperature not reported (may be a USB bridge without SAT passthrough)"
    fi
  done
}

emit "NOTE|host=$(scutil --get ComputerName 2>/dev/null || hostname) date=$(date '+%Y-%m-%d %H:%M:%S')"
cpu_temp
drive_temps
