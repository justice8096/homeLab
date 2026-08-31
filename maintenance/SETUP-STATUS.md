# Runner setup — where we left off

*Paused 2026-08-31: Tailscale SSH latency to Rogue made interactive setup
painful. This is the pickup checklist; full docs in [README.md](README.md).*

## Already done

- [x] Maintenance toolkit + workflows merged to master
  ([PR #2](https://github.com/justice8096/homeLab/pull/2))
- [x] `claude` user created on Rogue

## ⚠️ Before anything else

- [ ] **Rotate the `claude` user's password** — it was shared in a chat
      session, so treat it as burned: `sudo passwd claude`

## Remaining steps on Rogue

- [ ] (Optional, fixes the root-only SSH) In the
      [Tailscale admin console → Access Controls](https://login.tailscale.com/admin/acls),
      allow non-root logins in the `ssh` section:
      `"users": ["autogroup:nonroot", "root"]`
- [ ] As root: `usermod -aG docker,sudo claude`
- [ ] `su - claude` (or `ssh claude@rogue` once the ACL allows it)
- [ ] Get the repo:
  - existing clone (the one with `docker-compose.yml` the stack runs from —
    `crontab -l | grep homelab-health` reveals its path):
    `cd /path/to/homeLab && git pull origin master`
  - or fresh: `git clone https://github.com/justice8096/homeLab.git && cd homeLab`
- [ ] Grab a runner registration token (expires ~1 hour):
      <https://github.com/justice8096/homeLab/settings/actions/runners/new>
- [ ] `./maintenance/setup-runner.sh --token <TOKEN>`
      — add `--homelab-dir /path/to/live/clone` if running from a fresh clone
      while the docker stack lives in a different one
- [ ] Confirm the runner shows **Idle**:
      <https://github.com/justice8096/homeLab/settings/actions/runners>
- [ ] Tell Claude — it will dispatch a test **Health check** workflow and
      read the logs; from then on maintenance runs on request

## Mac Mini

Nothing new needed (Remote Login + key auth from Rogue + Homebrew, per
[monitoring/README.md](../monitoring/README.md)). Optional, for unattended
macOS updates: passwordless `sudo softwareupdate` (see README.md here).
