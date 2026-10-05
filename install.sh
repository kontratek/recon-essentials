#!/usr/bin/env bash
# Vulmon Recon Essentials — installer / upgrader.
#
#   curl -fsSL https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.sh | bash
#   bash install.sh                 # same, from a checkout of the distribution repository
#   bash install.sh upgrade         # move to the current release and restart (data is kept)
#   bash install.sh uninstall       # stop and remove the containers; volumes are kept unless PURGE=1
#
# What it does: checks Docker + Compose v2, creates ./recon-essentials (or INSTALL_DIR), fetches
# docker-compose.yml + .env.example (and itself, for later upgrades), generates the database
# password, asks which address and port people will use to open it, pulls the images and starts
# everything. It writes nothing outside that folder.
#
# RECON_VERSION=x.y.z pins that release instead of the current one, for install and upgrade.
# It is the same number .env carries: one release number for both images, the web and the engine.
set -euo pipefail

REPO_RAW="${RECON_DIST_URL:-https://raw.githubusercontent.com/kontratek/recon-essentials/main}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/recon-essentials}"
VERSION="${RECON_VERSION:-latest}"
case "$VERSION" in
  latest | [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf '\n✗ RECON_VERSION must be a release number such as 0.1.4 (got %s)\n' "$VERSION" >&2; exit 2 ;;
esac

say()  { printf '\n▸ %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed. See https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the 'docker compose' command)."
  docker info >/dev/null 2>&1 || fail "Docker is installed but not reachable — is the daemon running, and can this user access it?"
}

fetch() {
  # $1 = file name; keeps an existing file (the customer may have edited compose or .env)
  if [ -f "$1" ]; then return; fi
  if [ -f "$SCRIPT_DIR/$1" ]; then cp "$SCRIPT_DIR/$1" "$1"; return; fi
  curl -fsSL "$REPO_RAW/$1" -o "$1" || fail "Could not download $1 from $REPO_RAW"
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24; else head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# `hostname -I` is GNU only. On macOS and BusyBox it fails, and under `set -e -o pipefail` that
# failure ended the whole install silently, right after .env was written — so it must never fail.
lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

# Splits what was typed into ADDRESS and ADDRESS_PORT, forgiving the forms people actually type: a
# scheme, a path, a port glued on. 2026-10-05: "127.0.0.1:8080" without http:// went into APP_URL
# as it was, and every sign-in then failed with a 500 (Invalid base URL).
parse_address() {
  local value
  value="$(printf '%s' "${1:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s#^[Hh][Tt][Tt][Pp][Ss]?://##')"
  value="${value%%/*}"
  ADDRESS="${value%%:*}"
  if [ "$value" != "$ADDRESS" ]; then ADDRESS_PORT="${value#*:}"; else ADDRESS_PORT=""; fi
}
valid_host() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'; }
valid_port() { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# Sets KEY=value in .env, appending the line when it is missing. `-i.bak` keeps BSD sed (macOS) happy.
set_env() {
  if grep -q "^$1=" .env; then sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}

# .env pins the release an installation runs (RECON_VERSION — both images take it), so pulling
# alone would fetch the same release again. Upgrading moves that one line: to RECON_VERSION when it
# is set, otherwise to the release the distribution repository names now (every release pins its
# .env.example).
pin_release() {
  local target current
  if [ "$VERSION" != "latest" ]; then
    target="$VERSION"
  else
    current="$(curl -fsSL "$REPO_RAW/.env.example")" || fail "Could not download .env.example from $REPO_RAW"
    target="$(printf '%s\n' "$current" | sed -n 's/^RECON_VERSION=//p')"
    [ -n "$target" ] || fail "The .env.example at $REPO_RAW names no release."
  fi
  set_env RECON_VERSION "$target"
  # Before 0.1.2 each image had its own line. The release line replaces both, so an old pair can
  # never be left behind to override it.
  sed -i.bak '/^WEB_IMAGE=/d; /^ENGINE_IMAGE=/d' .env && rm -f .env.bak
  echo "release: $target"
}

# A release can change the compose file as well. The current one replaces the local copy and the
# old copy stays beside it, so a hand edit is never lost silently. Skipped for a pinned
# RECON_VERSION, because the repository's compose file belongs to the current release — unless the
# local file predates the release line (it names no RECON_VERSION), which no release can run.
refresh_compose() {
  if [ "$VERSION" != "latest" ] && grep -q 'RECON_VERSION' docker-compose.yml; then return 0; fi
  curl -fsSL "$REPO_RAW/docker-compose.yml" -o docker-compose.yml.new || { rm -f docker-compose.yml.new; fail "Could not download docker-compose.yml from $REPO_RAW"; }
  if cmp -s docker-compose.yml.new docker-compose.yml; then rm -f docker-compose.yml.new; return 0; fi
  local kept
  kept="docker-compose.yml.$(date +%Y%m%d%H%M%S).bak"
  mv docker-compose.yml "$kept" && mv docker-compose.yml.new docker-compose.yml
  echo "docker-compose.yml changed in this release; your previous copy is $kept"
}

# Under `curl … | bash` there is no script file: BASH_SOURCE is unset and $0 is "bash", which used
# to make SCRIPT_DIR the caller's current directory — fetch() then took a docker-compose.yml or
# .env.example lying there over the distribution's, silently, and `upgrade` / `uninstall` acted on
# whatever compose project that directory held. A checkout keeps the sibling-file behaviour.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=/nonexistent
fi
cmd="${1:-install}"

case "$cmd" in
  install)
    need_docker
    say "Installing into $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    fetch docker-compose.yml
    fetch .env.example
    fetch install.sh

    if [ ! -f .env ]; then
      cp .env.example .env
      sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(random_hex)/" .env && rm -f .env.bak
      host="$(lan_ip)"; [ -n "$host" ] || host=localhost
      port="${WEB_PORT:-8080}"; valid_port "$port" || port=8080
      # Under `curl … | bash` stdin is the script itself, so the questions go to the terminal.
      # With no terminal at all (CI, a provisioning tool) the defaults stand; both are in .env.
      if (: </dev/tty) 2>/dev/null; then
        printf '\nWhich address will people use to open Recon Essentials?\n' >/dev/tty
        printf '  - the IP address or host name of this computer, so other computers can reach it\n' >/dev/tty
        printf '  - localhost, if you will only use it on this computer\n' >/dev/tty
        while :; do
          printf 'Address [%s]: ' "$host" >/dev/tty
          read -r answer </dev/tty || answer=""
          [ -n "$answer" ] || break
          parse_address "$answer"
          if valid_host "$ADDRESS"; then
            host="$ADDRESS"
            if valid_port "$ADDRESS_PORT"; then port="$ADDRESS_PORT"; fi
            break
          fi
          printf '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local, localhost\n' >/dev/tty
        done
        while :; do
          printf 'Port [%s]: ' "$port" >/dev/tty
          read -r answer </dev/tty || answer=""
          answer="$(printf '%s' "$answer" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          [ -n "$answer" ] || break
          if valid_port "$answer"; then port="$answer"; break; fi
          printf '  The port is a number from 1 to 65535.\n' >/dev/tty
        done
      fi
      # APP_URL is always built here, never copied from the answer, and WEB_PORT follows it: the
      # published port and the address in APP_URL must be the same port.
      app_url="http://$host:$port"
      sed -i.bak "s#^APP_URL=.*#APP_URL=$app_url#" .env && rm -f .env.bak
      set_env WEB_PORT "$port"
      if [ "$VERSION" != "latest" ]; then
        set_env RECON_VERSION "$VERSION"
      fi
      echo "created .env (database password generated; APP_URL=$app_url)"
    else
      echo "keeping the existing .env"
    fi

    say "Pulling images"
    docker compose pull
    say "Starting (database → migrator → engine bootstrap → web + engine)"
    docker compose up -d

    app_url="$(grep -E '^APP_URL=' .env | cut -d= -f2-)"
    say "Waiting for the web UI"
    healthy=0
    for _ in $(seq 1 60); do
      # `{{.Health}}` prints "healthy" or "unhealthy" — whole word, so the latter does not pass.
      if docker compose ps --format '{{.Service}} {{.Health}}' web 2>/dev/null | grep -qw healthy; then healthy=1; break; fi
      sleep 3
    done
    if [ "$healthy" = 1 ]; then
      printf '\n✅ Recon Essentials is up. Open %s/setup to create the first administrator.\n' "$app_url"
      printf '   Logs: docker compose logs -f     Upgrade: bash install.sh upgrade\n'
    else
      printf '\n✗ The web UI did not report healthy within 3 minutes.\n' >&2
      printf '  Check: docker compose ps     then: docker compose logs web-migrator web\n' >&2
      exit 1
    fi
    ;;

  upgrade)
    need_docker
    cd "$INSTALL_DIR" 2>/dev/null || cd "$SCRIPT_DIR" 2>/dev/null || fail "Run this from the installation folder (or set INSTALL_DIR)."
    [ -f docker-compose.yml ] && [ -f .env ] || fail "No docker-compose.yml and .env here — is this the installation folder?"
    say "Moving to the release"
    pin_release
    refresh_compose
    say "Pulling images"
    docker compose pull
    say "Restarting — the migrator upgrades the database schema before the web starts"
    docker compose up -d
    printf '\n✅ Upgraded. Check: docker compose ps\n'
    ;;

  uninstall)
    need_docker
    cd "$INSTALL_DIR" 2>/dev/null || cd "$SCRIPT_DIR" 2>/dev/null || fail "Run this from the installation folder (or set INSTALL_DIR)."
    if [ "${PURGE:-0}" = "1" ]; then
      say "Removing containers AND data volumes (PURGE=1)"
      docker compose down -v --remove-orphans
    else
      say "Removing containers; data volumes are kept (set PURGE=1 to delete them)"
      docker compose down --remove-orphans
    fi
    ;;

  *)
    echo "usage: install.sh [install|upgrade|uninstall]" >&2
    exit 2
    ;;
esac
