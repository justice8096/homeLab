# Homelab maintenance via GitHub Actions

Updates and maintenance for **Rogue** (the Linux Docker host) and the
**Mac Mini**, driven by GitHub Actions workflows that execute on a
self-hosted runner installed on Rogue. Once the runner is up, maintenance
can be triggered from the Actions tab — or by Claude, which can start the
workflows and read their logs remotely.

```
maintenance/
├── setup-runner.sh              # one-command runner install + register ON Rogue
├── update-rogue.sh              # apt upgrades + docker compose pull/build/up
├── update-macmini.sh            # Homebrew + macOS updates, over SSH from Rogue
├── sudoers.d/homelab-maintenance# passwordless commands for the runner user
└── README.md

.github/workflows/
├── maintenance.yml              # manual: update rogue / macmini / all, then health check
└── health-check.yml             # scheduled + manual: monitoring/homelab-health.sh
```

## One-time setup on Rogue

1. Get a runner **registration token** (valid ~1 hour):
   <https://github.com/justice8096/homeLab/settings/actions/runners/new>
   (copy just the token from the `--token XXXX` part of the configure step).

2. On Rogue, as your normal user (not root), from the live clone:

   ```bash
   cd /path/to/homeLab
   ./maintenance/setup-runner.sh --token <TOKEN>
   ```

   This downloads the latest runner, registers it with labels
   `self-hosted,rogue`, installs it as a systemd service, writes
   `HOMELAB_DIR` (the live clone path) into the runner's `.env` so workflows
   find the compose stack and `monitoring/homelab-health.conf`, and installs
   the sudoers rules from `sudoers.d/homelab-maintenance`.

3. Make sure the runner user can drive Docker:

   ```bash
   sudo usermod -aG docker $USER    # then: sudo ./svc.sh stop && sudo ./svc.sh start
   ```

4. Verify: the runner shows **Idle** under
   [Settings → Actions → Runners](https://github.com/justice8096/homeLab/settings/actions/runners),
   then run the **Health check** workflow from the Actions tab.

## One-time setup on the Mac Mini

The Mac is managed from Rogue over SSH — same path the health check already
uses (see [monitoring/README.md](../monitoring/README.md)):

- **Remote Login** enabled (System Settings → General → Sharing), key-based
  auth from Rogue's runner user: `ssh-copy-id admin@macmini.local`.
- `MACMINI_SSH` set in `monitoring/homelab-health.conf`.
- [Homebrew](https://brew.sh) installed for package updates.
- For unattended **macOS OS updates** (the workflow's `mac_os_updates`
  option), allow passwordless `softwareupdate` on the Mac:

  ```
  # /etc/sudoers.d/homelab-maintenance   (create with: sudo visudo -f ...)
  admin ALL=(root) NOPASSWD: /usr/sbin/softwareupdate
  ```

  Updates that need a restart are installed but the restart stays manual —
  nothing reboots the Mac unattended.

## Running maintenance

From the [Actions tab](https://github.com/justice8096/homeLab/actions):

| Workflow | What it does |
|----------|--------------|
| **Maintenance** → target `rogue` | `apt-get update/upgrade/autoremove` (reports, never performs, a needed reboot), `git pull` of the live clone, `docker compose pull/build/up -d`, image prune, container status |
| **Maintenance** → target `macmini` | `brew update/upgrade/cleanup`, lists macOS updates (installs them only with the `mac_os_updates` checkbox) |
| **Maintenance** → target `all` | Both of the above, then a full health check |
| **Health check** | `monitoring/homelab-health.sh` — also runs on a 6-hour schedule once merged to the default branch |

Both scripts are plain bash and can be run directly on Rogue too:

```bash
./maintenance/update-rogue.sh
./maintenance/update-macmini.sh --os-updates
```

## Security notes

- The runner executes workflow code from this repository — keep the repo
  private and be deliberate about who can push. Under
  Settings → Actions → General, require approval for outside collaborators.
- The sudoers grant is scoped to `apt-get`, `smartctl`, `hddtemp` on Rogue
  and `softwareupdate` on the Mac; nothing gets blanket root.
- Nothing in these workflows reboots a machine; a required reboot is
  surfaced as a warning in the job log instead.
