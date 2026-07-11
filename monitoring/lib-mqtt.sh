#!/usr/bin/env bash
#
# lib-mqtt.sh — Home Assistant MQTT-discovery publishing for homelab-health.sh.
#
# Sourced by homelab-health.sh when MQTT_ENABLED=1 (via --mqtt or the conf).
# Publishes retained discovery configs so Home Assistant auto-creates entities,
# then publishes state. Entities are grouped under HA "devices":
#   Rogue, Mac Mini, Homelab Docker.
#
# Requires the mosquitto clients:  apt install mosquitto-clients
#
# Nothing here changes the human-readable output or exit codes of the caller;
# every function is a no-op unless MQTT_ENABLED=1.

# --- MQTT defaults (overridable in homelab-health.conf) --------------------
: "${MQTT_ENABLED:=0}"
: "${MQTT_HOST:=}"
: "${MQTT_PORT:=1883}"
: "${MQTT_USER:=}"
: "${MQTT_PASS:=}"
: "${MQTT_BASE:=homelab}"            # state topic root
: "${MQTT_DISCOVERY:=homeassistant}" # HA discovery prefix
: "${MQTT_NODE:=homelab}"            # unique_id / node namespace
# If no update arrives within this many seconds, HA marks the entity
# unavailable. Set to a bit more than your cron interval (0 disables).
: "${MQTT_EXPIRE:=1800}"

MQTT_AVAIL_TOPIC="$MQTT_BASE/availability"

# --- low-level publish -----------------------------------------------------
_mqtt_pub() {  # _mqtt_pub <topic> <payload> [retain:1]
  [ "$MQTT_ENABLED" = "1" ] || return 0
  local topic="$1" payload="$2" retain="${3:-0}"
  local args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -m "$payload")
  [ -n "$MQTT_USER" ] && args+=(-u "$MQTT_USER")
  [ -n "$MQTT_PASS" ] && args+=(-P "$MQTT_PASS")
  [ "$retain" = "1" ] && args+=(-r)
  mosquitto_pub "${args[@]}" 2>/dev/null \
    || printf '  [mqtt] publish failed: %s\n' "$topic" >&2
}

# Lowercase + collapse anything non-alphanumeric to a single underscore.
_mqtt_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g'
}

# JSON-escape a value for embedding in a discovery payload.
_mqtt_json() { printf '%s' "$1" | sed -E 's/\\/\\\\/g; s/"/\\"/g'; }

# --- HA discovery + state --------------------------------------------------
# Announce availability once per run (retained).
mqtt_online()  { _mqtt_pub "$MQTT_AVAIL_TOPIC" "online"  1; }

# publish_temp <object_id> <friendly> <device_id> <device_name> <celsius>
publish_temp() {
  [ "$MQTT_ENABLED" = "1" ] || return 0
  local oid; oid=$(_mqtt_slug "$1")
  local name="$2" dev; dev=$(_mqtt_slug "$3")
  local devname="$4" value="$5"
  local state_topic="$MQTT_BASE/$oid/state"
  local expire=""; [ "$MQTT_EXPIRE" -gt 0 ] 2>/dev/null && expire=",\"expire_after\":$MQTT_EXPIRE"
  local cfg
  cfg="{\"name\":\"$(_mqtt_json "$name")\",\"unique_id\":\"${MQTT_NODE}_${oid}\",\"object_id\":\"${MQTT_NODE}_${oid}\",\"state_topic\":\"$state_topic\",\"availability_topic\":\"$MQTT_AVAIL_TOPIC\",\"device_class\":\"temperature\",\"unit_of_measurement\":\"°C\",\"state_class\":\"measurement\"${expire},\"device\":{\"identifiers\":[\"${MQTT_NODE}_${dev}\"],\"name\":\"$(_mqtt_json "$devname")\",\"manufacturer\":\"homelab-health\"}}"
  _mqtt_pub "$MQTT_DISCOVERY/sensor/$MQTT_NODE/$oid/config" "$cfg" 1
  _mqtt_pub "$state_topic" "$value" 1
}

# publish_problem <object_id> <friendly> <device_id> <device_name> <ON|OFF> [detail]
publish_problem() {
  [ "$MQTT_ENABLED" = "1" ] || return 0
  local oid; oid=$(_mqtt_slug "$1")
  local name="$2" dev; dev=$(_mqtt_slug "$3")
  local devname="$4" onoff="$5" detail="${6:-}"
  local state_topic="$MQTT_BASE/$oid/state"
  local attr_topic="$MQTT_BASE/$oid/attr"
  local expire=""; [ "$MQTT_EXPIRE" -gt 0 ] 2>/dev/null && expire=",\"expire_after\":$MQTT_EXPIRE"
  local cfg
  cfg="{\"name\":\"$(_mqtt_json "$name")\",\"unique_id\":\"${MQTT_NODE}_${oid}\",\"object_id\":\"${MQTT_NODE}_${oid}\",\"state_topic\":\"$state_topic\",\"availability_topic\":\"$MQTT_AVAIL_TOPIC\",\"json_attributes_topic\":\"$attr_topic\",\"device_class\":\"problem\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"${expire},\"device\":{\"identifiers\":[\"${MQTT_NODE}_${dev}\"],\"name\":\"$(_mqtt_json "$devname")\",\"manufacturer\":\"homelab-health\"}}"
  _mqtt_pub "$MQTT_DISCOVERY/binary_sensor/$MQTT_NODE/$oid/config" "$cfg" 1
  _mqtt_pub "$attr_topic" "{\"detail\":\"$(_mqtt_json "$detail")\"}" 1
  _mqtt_pub "$state_topic" "$onoff" 1
}

# publish_status <ok> <warn> <crit>  — overall rollup sensor (value OK/WARN/CRIT)
publish_status() {
  [ "$MQTT_ENABLED" = "1" ] || return 0
  local ok="$1" warn="$2" crit="$3" value
  if   [ "$crit" -gt 0 ]; then value="CRIT"
  elif [ "$warn" -gt 0 ]; then value="WARN"
  else value="OK"; fi
  local oid="status" state_topic="$MQTT_BASE/status/state" attr_topic="$MQTT_BASE/status/attr"
  local expire=""; [ "$MQTT_EXPIRE" -gt 0 ] 2>/dev/null && expire=",\"expire_after\":$MQTT_EXPIRE"
  local cfg
  cfg="{\"name\":\"Homelab status\",\"unique_id\":\"${MQTT_NODE}_status\",\"object_id\":\"${MQTT_NODE}_status\",\"state_topic\":\"$state_topic\",\"availability_topic\":\"$MQTT_AVAIL_TOPIC\",\"icon\":\"mdi:server\",\"json_attributes_topic\":\"$attr_topic\"${expire},\"device\":{\"identifiers\":[\"${MQTT_NODE}_docker\"],\"name\":\"Homelab Docker\",\"manufacturer\":\"homelab-health\"}}"
  _mqtt_pub "$MQTT_DISCOVERY/sensor/$MQTT_NODE/$oid/config" "$cfg" 1
  _mqtt_pub "$attr_topic" "{\"ok\":$ok,\"warn\":$warn,\"crit\":$crit}" 1
  _mqtt_pub "$state_topic" "$value" 1
}
