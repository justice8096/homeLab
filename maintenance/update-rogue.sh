#!/usr/bin/env bash
#
# update-rogue.sh — routine maintenance for Rogue (the Linux Docker host).
#
# Run ON Rogue (directly, or via the GitHub Actions "Maintenance" workflow):
#     ./maintenance/update-rogue.sh              # OS packages + containers
#     ./maintenance/update-rogue.sh --no-apt     # skip OS packages
#     ./maintenance/update-rogue.sh --no-docker  # skip container updates
#
# Fully non-interactive: apt runs via `sudo -n` (grant the commands in
# maintenance/sudoers.d/homelab-maintenance) and never prompts. A pending
# reboot is REPORTED, never performed.
#
# HOMELAB_DIR selects the live compose clone to update and redeploy
# (defaults to the repo this script lives in).
#
# Exit status: 0 = success, 1 = completed with warnings, 2 = a step failed.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB_DIR="${HOMELAB_DIR:-$REPO_ROOT}"

DO_APT=1 DO_DOCKER=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-apt)    DO_APT=0; shift;;
    --no-docker) DO_DOCKER=0; shift;;
    -h|--help)   sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\033[31m[fail]\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
WARNINGS=0 FAILURES=0

SUDO="sudo -n"
[ "$(id -u)" = "0" ] && SUDO=""

# --- 1. OS packages --------------------------------------------------------
if [ "$DO_APT" = "1" ]; then
  say "Updating OS packages (apt)"
  export DEBIAN_FRONTEND=noninteractive
  APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  if $SUDO apt-get update -qq; then
    $SUDO apt-get "${APT_OPTS[@]}" upgrade        || fail "apt-get upgrade failed"
    $SUDO apt-get "${APT_OPTS[@]}" autoremove --purge >/dev/null \
                                                  || warn "apt-get autoremove failed"
  else
    fail "apt-get update failed (is passwordless sudo set up? see maintenance/sudoers.d/)"
  fi
  if [ -f /var/run/reboot-required ]; then
    warn "REBOOT REQUIRED to finish these updates: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || echo 'see /var/run/reboot-required')"
  fi
else
  say "Skipping OS packages (--no-apt)"
fi

# --- 2. Containers ---------------------------------------------------------
if [ "$DO_DOCKER" = "1" ]; then
  say "Updating containers in $HOMELAB_DIR"

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    COMPOSE=()
    fail "neither 'docker compose' nor 'docker-compose' found"
  fi

  if [ ${#COMPOSE[@]} -gt 0 ] && [ -f "$HOMELAB_DIR/docker-compose.yml" ]; then
    # Keep the live clone current so merged compose/config changes deploy too.
    if [ -d "$HOMELAB_DIR/.git" ]; then
      git -C "$HOMELAB_DIR" pull --ff-only 2>/dev/null \
        || warn "could not fast-forward $HOMELAB_DIR (local changes or diverged branch) — deploying as-is"
    fi
    cd "$HOMELAB_DIR" || fail "cannot cd to $HOMELAB_DIR"
    "${COMPOSE[@]}" pull --quiet       || warn "compose pull reported errors (built-only services are expected to skip)"
    "${COMPOSE[@]}" build --pull       || fail "compose build failed"
    "${COMPOSE[@]}" up -d --remove-orphans || fail "compose up failed"
    docker image prune -f >/dev/null   || warn "image prune failed"

    say "Container status after update"
    sleep 10
    BAD=0
    for c in haproxy mongo n8n elasticSearch obsidian calibre webdav; do
      state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
      # compose v1 names the built haproxy service differently; look it up loosely
      if [ "$state" = "missing" ]; then
        cid=$("${COMPOSE[@]}" ps -q "$c" 2>/dev/null | head -1)
        [ -n "$cid" ] && state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "missing")
      fi
      printf '    %-14s %s\n' "$c" "$state"
      [ "$state" = "running" ] || BAD=$((BAD+1))
    done
    [ "$BAD" -gt 0 ] && fail "$BAD container(s) not running after update"
  elif [ ${#COMPOSE[@]} -gt 0 ]; then
    fail "no docker-compose.yml in $HOMELAB_DIR (set HOMELAB_DIR to the live clone)"
  fi
else
  say "Skipping containers (--no-docker)"
fi

# --- summary ---------------------------------------------------------------
echo
if   [ "$FAILURES" -gt 0 ]; then say "Done with $FAILURES failure(s), $WARNINGS warning(s)"; exit 2
elif [ "$WARNINGS" -gt 0 ]; then say "Done with $WARNINGS warning(s)"; exit 1
else                             say "Done — Rogue is up to date"; exit 0; fi
