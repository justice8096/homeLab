# Homelab health & temperature monitoring

Health-checks the docker-compose stack and reports CPU + hard-drive
temperatures for **Rogue** (the Linux Docker host) and the **Mac Mini**.

```
monitoring/
├── homelab-health.sh          # run this ON Rogue — the orchestrator
├── temps-macos.sh             # temperature reporter for the Mac Mini
├── lib-mqtt.sh                # Home Assistant MQTT-discovery publisher
├── homelab-health.conf.example# copy → homelab-health.conf and edit
└── README.md
```

## What it checks

| Section | Source | Notes |
|---------|--------|-------|
| Docker components | `docker inspect` | State, healthcheck status and restart count for every container in the compose file (`haproxy mongo n8n elasticSearch obsidian calibre webdav`), plus an HTTP probe of the haproxy stats page |
| Rogue CPU/system temps | `lm-sensors`, falls back to `/sys/class/thermal` | Grades every reading against `CPU_WARN`/`CPU_CRIT` |
| Rogue drive temps | `smartctl` (SMART attr 194 / NVMe), falls back to `hddtemp` | Enumerates physical disks via `lsblk` |
| Mac Mini CPU temp | `istats` → `osx-cpu-temp` → `powermetrics` | Collected over SSH |
| Mac Mini drive temps | `smartctl` | Collected over SSH |

Every line is graded **[ OK ] / [WARN] / [CRIT]**. Exit code is
`0` (all OK), `1` (warnings), or `2` (critical) so it drops straight into
cron, a systemd timer, or a CI check.

## Quick start (on Rogue)

```bash
cd /path/to/homeLab
cp monitoring/homelab-health.conf.example monitoring/homelab-health.conf
$EDITOR monitoring/homelab-health.conf      # set MACMINI_SSH, thresholds, etc.
./monitoring/homelab-health.sh
```

### Prerequisites on Rogue (Debian/Ubuntu)

```bash
sudo apt install lm-sensors smartmontools curl
sudo sensors-detect       # answer YES to the safe defaults, once
```

`smartctl` and `hddtemp` need root to read drives. Either run the whole
script with `sudo`, or grant passwordless access to just those commands via
`sudoers` (the script already calls them with `sudo -n`):

```
# /etc/sudoers.d/homelab-health
rogueuser ALL=(root) NOPASSWD: /usr/sbin/smartctl, /usr/sbin/hddtemp
```

## Mac Mini setup

The orchestrator reaches the Mac over SSH. Enable **Remote Login**
(System Settings → General → Sharing) and set up key-based auth so no
password prompt is needed:

```bash
ssh-copy-id admin@macmini.local        # from Rogue
```

Then in `homelab-health.conf`:

```bash
MACMINI_SSH="admin@macmini.local"
```

Install a temperature source on the Mac (any one works):

```bash
brew install smartmontools             # drive temps
brew install --cask istats || gem install iStats   # CPU temp (Apple Silicon-friendly)
# or:  brew install osx-cpu-temp       # Intel Macs
```

`temps-macos.sh` is streamed to the Mac over the SSH pipe automatically, so
you don't strictly need to copy it there — but if you set
`MACMINI_SCRIPT_PATH` to a copy that lives on the Mac it will use that first.

> **Apple Silicon note:** `osx-cpu-temp` often reports `0.0` on M-series
> chips; prefer `istats`, or allow passwordless `sudo powermetrics` and the
> script will read the CPU die temperature from the SMC.

## Thresholds

Defaults (Celsius), overridable in the conf file:

| | Warn | Crit |
|--|--|--|
| CPU | 70 | 85 |
| Drive | 45 | 55 |

Spinning disks should idle well under 45 °C; NVMe can run hotter but 55 °C
sustained is worth a look.

## Home Assistant (MQTT discovery)

The same run can push everything into Home Assistant. Rogue publishes to your
MQTT broker and HA **auto-creates** the entities — no YAML on the HA side.

Entities created (grouped under HA devices **Rogue**, **Mac Mini**, and
**Homelab Docker**):

| Entity | Type | Notes |
|--------|------|-------|
| `sensor.homelab_rogue_cpu` | temperature (°C) | hottest CPU/system reading on Rogue |
| `sensor.homelab_rogue_cpu_*` | temperature (°C) | per-core / per-zone reading (Core 0, Package, …) |
| `sensor.homelab_rogue_drive_*` | temperature (°C) | one per attached drive, incl. external/USB (via `-d sat`) |
| `binary_sensor.homelab_rogue_drive_*_health` | problem (on/off) | SMART overall-health per drive; `on` = failing |
| `sensor.homelab_macmini_cpu` | temperature (°C) | Mac Mini CPU |
| `sensor.homelab_macmini_drive_*` | temperature (°C) | one per Mac Mini drive, incl. external |
| `binary_sensor.homelab_macmini_drive_*_health` | problem (on/off) | SMART health per Mac drive |
| `binary_sensor.homelab_macmini_online` | connectivity | `on` = Mac answered over SSH on the last run |
| `binary_sensor.homelab_docker_*` | problem (on/off) | one per container; `on` = not running / unhealthy |
| `binary_sensor.homelab_haproxy_online` | connectivity | `on` = haproxy stats page answered 200 |
| `sensor.homelab_rogue_updated` / `sensor.homelab_macmini_updated` | timestamp | last successful run per host (alert if stale) |
| `sensor.homelab_status` | OK / WARN / CRIT | rollup, with ok/warn/crit counts as attributes |

Temperature entities carry `device_class: temperature` and
`state_class: measurement`, so HA gives you history graphs for free, and
`expire_after` marks an entity **unavailable** if the publisher stops.

### Setup

1. Install the broker client on Rogue and make sure HA talks to the same
   broker (the **Mosquitto** add-on is the usual choice):

   ```bash
   sudo apt install mosquitto-clients
   ```

2. Fill in the MQTT block in `homelab-health.conf`:

   ```bash
   MQTT_ENABLED=1
   MQTT_HOST="homeassistant.local"   # or your broker's address
   MQTT_USER="homelab"               # broker credentials (blank = anonymous)
   MQTT_PASS="••••••"
   MQTT_EXPIRE=1800                  # a bit above your cron interval
   ```

3. Run it (or let cron run it). `--mqtt` / `--no-mqtt` override the conf
   per-run:

   ```bash
   ./monitoring/homelab-health.sh --mqtt
   ```

Entities appear automatically under **Settings → Devices & Services → MQTT**.
From there, wire an automation off `sensor.homelab_status` (e.g. *is `CRIT` →
notify*) or off any individual temperature sensor. Discovery and state messages
are published **retained**, so HA repopulates them after a restart.

> If `mosquitto_pub` isn't installed the script prints a notice and continues
> with normal console output — MQTT never blocks the health check.

## Scheduling

Run every 15 minutes and log, alerting only on non-zero exit:

```cron
*/15 * * * * /path/to/homeLab/monitoring/homelab-health.sh > /var/log/homelab-health.log 2>&1 || echo "homelab health degraded" | mail -s "Homelab alert" you@example.com
```

With MQTT enabled, the same schedule keeps Home Assistant fed:

```cron
*/15 * * * * /path/to/homeLab/monitoring/homelab-health.sh --mqtt >> /var/log/homelab-health.log 2>&1
```

Set `NO_COLOR=1` in the conf (or environment) for clean log output.
