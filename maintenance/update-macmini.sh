#!/usr/bin/env bash
#
# update-macmini.sh — update the Mac Mini over SSH. Run this FROM Rogue.
#
#     ./maintenance/update-macmini.sh                   # Homebrew + list OS updates
#     ./maintenance/update-macmini.sh --os-updates      # also install macOS updates
#     ./maintenance/update-macmini.sh --target admin@macmini.local
#
# The SSH target comes from --target, the MACMINI_SSH environment variable,
# or monitoring/homelab-health.conf — the same key the health check uses.
# Key-based auth is required (ssh runs in BatchMode; see monitoring/README.md).
#
# macOS software updates are LISTED by default; --os-updates installs them via
# passwordless `sudo softwareupdate` on the Mac. Updates that need a restart
# are staged but the restart is left to you.
#
# Exit status: 0 = success, 1 = completed with warnings, 2 = a step failed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB_DIR="${HOMELAB_DIR:-$REPO_ROOT}"

OS_UPDATES=0
TARGET="${MACMINI_SSH:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --os-updates) OS_UPDATES=1; shift;;
    --target)     TARGET="$2"; shift 2;;
    -h|--help)    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\033[31m[fail]\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 2; }
WARNINGS=0 FAILURES=0

# Fall back to the health-check conf for the SSH target.
if [ -z "$TARGET" ]; then
  for conf in "$HOMELAB_DIR/monitoring/homelab-health.conf" "$REPO_ROOT/monitoring/homelab-health.conf"; do
    if [ -f "$conf" ]; then
      TARGET="$(. "$conf" >/dev/null 2>&1; printf '%s' "${MACMINI_SSH:-}")"
      [ -n "$TARGET" ] && break
    fi
  done
fi
[ -n "$TARGET" ] || die "no Mac Mini SSH target — use --target user@host, set MACMINI_SSH, or fill in monitoring/homelab-health.conf"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
run_mac() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# --- 1. reachability + vitals ----------------------------------------------
say "Checking $TARGET"
if ! INFO=$(run_mac 'sw_vers -productVersion 2>/dev/null; uptime; df -h / | tail -1'); then
  die "cannot reach $TARGET over SSH (BatchMode) — check Remote Login + key auth (monitoring/README.md)"
fi
printf '%s\n' "$INFO" | sed 's/^/    /'

# --- 2. Homebrew -----------------------------------------------------------
say "Updating Homebrew packages"
BREW=$(run_mac 'command -v brew || ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1' | head -1)
if [ -n "$BREW" ]; then
  run_mac "$BREW update"              || fail "brew update failed"
  run_mac "$BREW upgrade"             || fail "brew upgrade failed"
  run_mac "$BREW upgrade --cask" 2>/dev/null || warn "brew cask upgrade reported errors (casks needing a password are expected to fail)"
  run_mac "$BREW cleanup --prune=30" >/dev/null || warn "brew cleanup failed"
  run_mac "$BREW --version | head -1"
else
  warn "Homebrew not found on the Mac — skipping package updates (install: https://brew.sh)"
fi

# --- 3. macOS software updates ---------------------------------------------
say "macOS software updates"
UPDATES=$(run_mac 'softwareupdate -l 2>&1') || true
if printf '%s' "$UPDATES" | grep -qi 'No new software available'; then
  echo "    macOS is up to date"
elif printf '%s' "$UPDATES" | grep -q '^\s*\*'; then
  printf '%s\n' "$UPDATES" | grep -A1 '^\s*\*' | sed 's/^/    /'
  if [ "$OS_UPDATES" = "1" ]; then
    say "Installing macOS updates (this can take a while)"
    if run_mac 'sudo -n softwareupdate -i -a'; then
      warn "updates installed — if any required a restart, restart the Mac to finish"
    else
      fail "softwareupdate install failed — is passwordless sudo for softwareupdate configured? (see maintenance/README.md)"
    fi
  else
    warn "updates available but not installed — re-run with --os-updates to install"
  fi
else
  warn "could not read update list: $(printf '%s' "$UPDATES" | head -1)"
fi

# --- summary ---------------------------------------------------------------
echo
if   [ "$FAILURES" -gt 0 ]; then say "Done with $FAILURES failure(s), $WARNINGS warning(s)"; exit 2
elif [ "$WARNINGS" -gt 0 ]; then say "Done with $WARNINGS warning(s)"; exit 1
else                             say "Done — Mac Mini is up to date"; exit 0; fi
