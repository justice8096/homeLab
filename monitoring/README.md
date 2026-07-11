# Homelab health & temperature monitoring

Health-checks the docker-compose stack and reports CPU + hard-drive
temperatures for **Rogue** (the Linux Docker host) and the **Mac Mini**.

```
monitoring/
├── homelab-health.sh          # run this ON Rogue — the orchestrator
├── temps-macos.sh             # temperature reporter for the Mac Mini
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

## Scheduling

Run every 15 minutes and log, alerting only on non-zero exit:

```cron
*/15 * * * * /path/to/homeLab/monitoring/homelab-health.sh > /var/log/homelab-health.log 2>&1 || echo "homelab health degraded" | mail -s "Homelab alert" you@example.com
```

Set `NO_COLOR=1` in the conf (or environment) for clean log output.
