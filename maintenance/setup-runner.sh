#!/usr/bin/env bash
#
# setup-runner.sh — install & register a GitHub Actions self-hosted runner
# ON ROGUE, as a systemd service, with the labels the workflows expect.
#
# 1. Get a registration token (valid ~1 hour) from:
#      https://github.com/justice8096/homeLab/settings/actions/runners/new
# 2. Run as the user that should own maintenance jobs (NOT root):
#      ./maintenance/setup-runner.sh --token <TOKEN> \
#           [--homelab-dir /path/to/homeLab]   # live clone; default: this repo
#           [--dir ~/actions-runner]           # where to install the runner
#
# Also installs maintenance/sudoers.d/homelab-maintenance for this user so
# apt/smartctl run passwordless from workflows. Re-runnable (--replace).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_URL="https://github.com/justice8096/homeLab"
TOKEN="" RUNNER_DIR="$HOME/actions-runner" HOMELAB_DIR="$REPO_ROOT"

usage() { sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --token)       TOKEN="$2"; shift 2;;
    --dir)         RUNNER_DIR="$2"; shift 2;;
    --homelab-dir) HOMELAB_DIR="$2"; shift 2;;
    --repo-url)    REPO_URL="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$TOKEN" ] || die "missing --token (get one from $REPO_URL/settings/actions/runners/new)"
[ "$(id -u)" != "0" ] || die "run as a normal user, not root — the runner refuses to run as root"

case "$(uname -m)" in
  x86_64)          ARCH=x64;;
  aarch64|arm64)   ARCH=arm64;;
  *) die "unsupported architecture: $(uname -m)";;
esac

# --- 1. download the runner ------------------------------------------------
say "Fetching latest actions/runner release"
VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
      | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
[ -n "$VER" ] || die "could not determine latest runner version"
TARBALL="actions-runner-linux-${ARCH}-${VER}.tar.gz"

mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
if [ ! -f "./config.sh" ]; then
  say "Downloading $TARBALL"
  curl -fsSL -o "$TARBALL" "https://github.com/actions/runner/releases/download/v${VER}/${TARBALL}"
  tar xzf "$TARBALL" && rm -f "$TARBALL"
else
  say "Runner already present in $RUNNER_DIR — reconfiguring"
fi

# --- 2. register -----------------------------------------------------------
say "Registering with $REPO_URL (labels: self-hosted,rogue)"
./config.sh --url "$REPO_URL" --token "$TOKEN" \
            --name "rogue" --labels "rogue" --unattended --replace

# Workflows read HOMELAB_DIR to find the live compose clone + conf.
grep -q '^HOMELAB_DIR=' .env 2>/dev/null \
  && sed -i -E "s|^HOMELAB_DIR=.*|HOMELAB_DIR=$HOMELAB_DIR|" .env \
  || echo "HOMELAB_DIR=$HOMELAB_DIR" >> .env
say "HOMELAB_DIR=$HOMELAB_DIR written to runner .env"

# --- 3. run as a service ---------------------------------------------------
say "Installing systemd service"
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status || true

# --- 4. sudoers for maintenance commands -----------------------------------
say "Installing sudoers rules for $USER"
SUDOERS_SRC="$SCRIPT_DIR/sudoers.d/homelab-maintenance"
if [ -f "$SUDOERS_SRC" ]; then
  TMP=$(mktemp)
  sed "s/^runner /$USER /" "$SUDOERS_SRC" > "$TMP"
  if sudo visudo -c -f "$TMP" >/dev/null; then
    sudo install -m 440 "$TMP" /etc/sudoers.d/homelab-maintenance
    say "installed /etc/sudoers.d/homelab-maintenance"
  else
    warn "sudoers file failed validation — install it manually from $SUDOERS_SRC"
  fi
  rm -f "$TMP"
fi

if ! id -nG "$USER" | grep -qw docker; then
  warn "$USER is not in the docker group — run: sudo usermod -aG docker $USER (then restart the runner service)"
fi

echo
say "Done. The runner should now show green at $REPO_URL/settings/actions/runners"
say "Trigger a test from the Actions tab: 'Health check' → Run workflow."
