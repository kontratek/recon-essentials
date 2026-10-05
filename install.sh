#!/usr/bin/env bash
# Vulmon Recon Essentials — installer / upgrader for Linux and macOS (Git Bash and WSL work too).
#
#   curl -fsSL https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.sh | bash
#   bash install.sh                 # same, from a checkout of the distribution repository
#   bash install.sh upgrade         # in the installation folder: move to the current release and restart (data is kept)
#   bash install.sh address         # in the installation folder: change the address or the port people open
#   bash install.sh uninstall       # stop and remove the containers; the data is kept unless PURGE=1
#
# What it does: checks Docker + Compose v2, creates ./recon-essentials (or INSTALL_DIR), fetches
# docker-compose.yml + .env.example (and both installers, for later upgrades), generates the
# database password, asks which address and port people will use to open it, pulls the images and
# starts everything. It writes nothing outside that folder.
#
# Without a terminal (CI, a provisioning tool) give the answers in advance, or accept the defaults
# (localhost, 8080) with RECON_NONINTERACTIVE=1:
#   RECON_ADDRESS=192.168.1.20 RECON_PORT=8080 bash install.sh
# RECON_VERSION=x.y.z pins that release instead of the current one, for install and upgrade.
# It is the same number .env carries: one release number for both images, the web and the engine.
set -euo pipefail

REPO_RAW="${RECON_DIST_URL:-https://raw.githubusercontent.com/kontratek/recon-essentials/main}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/recon-essentials}"
VERSION="${RECON_VERSION:-latest}"
PROJECT="${COMPOSE_PROJECT_NAME:-recon-essentials}"
case "$VERSION" in
  latest | [0-9]*.[0-9]*.[0-9]*) ;;
  *) printf '\n✗ RECON_VERSION must be a release number such as 1.0.0 (got %s)\n' "$VERSION" >&2; exit 2 ;;
esac

say()  { printf '\n▸ %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# Git Bash, MSYS and Cygwin run on Windows; WSL is Linux but reaches Docker Desktop too.
windows_shell() { case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; *) return 1 ;; esac; }
docker_desktop() { windows_shell || [ "$(uname -s 2>/dev/null)" = Darwin ] || grep -qi microsoft /proc/version 2>/dev/null; }

need_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed. See https://docs.docker.com/engine/install/ (Docker Desktop on Windows and macOS)."
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the 'docker compose' command)."
  if ! docker info >/dev/null 2>&1; then
    # Docker Desktop can stay open with its engine gone ("Internal Server Error"), which reads as
    # "Docker is running" to the person at the keyboard (2026-10-05) — so the message says both.
    if docker_desktop; then
      fail "Docker Desktop does not answer. If it is open, restart it (Quit Docker Desktop, then start it again); if it is closed, start it. Wait until it shows that the engine is running, then run this again."
    fi
    fail "The Docker daemon does not answer. Is it running (sudo systemctl start docker), and can this user use it (sudo usermod -aG docker \$USER, then sign in again)?"
  fi
  [ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = linux ] || fail "Docker runs Windows containers. Switch Docker Desktop to Linux containers and run this again."
}

fetch() {
  # $1 = file name; keeps an existing file (the customer may have edited compose or .env)
  if [ -f "$1" ]; then return; fi
  if [ -f "$SCRIPT_DIR/$1" ]; then cp "$SCRIPT_DIR/$1" "$1"; return; fi
  curl -fsSL "$REPO_RAW/$1" -o "$1" || fail "Could not download $1 from $REPO_RAW"
}

# Replaces one of OUR files (an installer) with the current one, through a new file and a rename:
# bash reads a running script as it goes and must keep reading the file it opened. Best effort —
# an upgrade never fails because an installer could not be refreshed.
refresh_file() {
  if curl -fsSL "$REPO_RAW/$1" -o "$1.new" 2>/dev/null && mv -f "$1.new" "$1" 2>/dev/null; then return 0; fi
  rm -f "$1.new"
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24; else head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# The address this machine uses towards the internet — a hint in the address question, never the
# default (the default is localhost). The route is asked first: `hostname -I` is GNU only and can
# list a Docker bridge first. Every probe may fail; none may end the install under `set -e`.
lan_ip() {
  local ip="" iface=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || ip=""
  fi
  if [ -z "$ip" ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')" || iface=""
    if [ -n "$iface" ]; then ip="$(ipconfig getifaddr "$iface" 2>/dev/null)" || ip=""; fi
  fi
  if [ -z "$ip" ] && ! windows_shell; then ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || ip=""; fi
  printf '%s' "$ip"
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
env_value() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Asks for the address and the port, or takes RECON_ADDRESS / RECON_PORT, into ANSWER_HOST and
# ANSWER_PORT. Enter keeps the current value — on a new installation localhost, which means only
# this computer can open it (founder, 2026-10-05).
ask_address() {
  local hint answer
  ANSWER_HOST="$1"; ANSWER_PORT="$2"
  if [ -n "${RECON_ADDRESS:-}" ] || [ -n "${RECON_PORT:-}" ]; then
    if [ -n "${RECON_ADDRESS:-}" ]; then
      parse_address "$RECON_ADDRESS"
      valid_host "$ADDRESS" || fail "RECON_ADDRESS must be an IP address or a host name (got $RECON_ADDRESS)."
      ANSWER_HOST="$ADDRESS"
      if valid_port "$ADDRESS_PORT"; then ANSWER_PORT="$ADDRESS_PORT"; fi
    fi
    if [ -n "${RECON_PORT:-}" ]; then
      valid_port "$RECON_PORT" || fail "RECON_PORT must be a number from 1 to 65535 (got $RECON_PORT)."
      ANSWER_PORT="$RECON_PORT"
    fi
    return 0
  fi
  # Under `curl … | bash` stdin is the script itself, so the questions go to the terminal. With no
  # terminal at all — or RECON_NONINTERACTIVE=1 — the defaults stand.
  [ "${RECON_NONINTERACTIVE:-0}" != 1 ] || return 0
  (: </dev/tty) 2>/dev/null || return 0
  hint="$(lan_ip)"
  {
    printf '\nWhich address will people type in the browser to open Recon Essentials?\n'
    printf '  - Press Enter to keep %s.' "$ANSWER_HOST"
    if [ "$ANSWER_HOST" = localhost ]; then printf ' Then only this computer can open it.'; fi
    printf '\n'
    printf "  - Type this computer's IP address or host name to open it from other computers too.\n"
    if [ -n "$hint" ]; then printf "    This computer's IP address appears to be %s.\n" "$hint"; fi
    printf '  Invitation and password-reset links use this address, so a fixed IP address or a host name works best.\n'
  } >/dev/tty
  while :; do
    printf 'Address [%s]: ' "$ANSWER_HOST" >/dev/tty
    read -r answer </dev/tty || answer=""
    [ -n "$answer" ] || break
    parse_address "$answer"
    if valid_host "$ADDRESS"; then
      ANSWER_HOST="$ADDRESS"
      if valid_port "$ADDRESS_PORT"; then ANSWER_PORT="$ADDRESS_PORT"; fi
      break
    fi
    printf '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local, localhost\n' >/dev/tty
  done
  while :; do
    printf 'Port [%s]: ' "$ANSWER_PORT" >/dev/tty
    read -r answer </dev/tty || answer=""
    answer="$(printf '%s' "$answer" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$answer" ] || break
    if valid_port "$answer"; then ANSWER_PORT="$answer"; break; fi
    printf '  The port is a number from 1 to 65535.\n' >/dev/tty
  done
}

# APP_URL is always built here, never copied from an answer, and WEB_PORT follows it: the published
# port and the port in APP_URL must be the same port.
write_address() {
  set_env APP_URL "http://$1:$2"
  set_env WEB_PORT "$2"
}

# A second folder must never take over an installation that exists: the data lives in Docker
# volumes named after the compose project, and a new .env would bring a new database password to an
# old database. The database refuses it, and the first installation's containers are recreated with
# the wrong settings (2026-10-05). Runs before anything is written.
guard_existing() {
  docker volume inspect "${PROJECT}_pgdata" >/dev/null 2>&1 || return 0
  local folder
  folder="$(docker compose ls -a --format json 2>/dev/null | tr '{' '\n' | grep -F "\"Name\":\"$PROJECT\"" | sed -n 's/.*"ConfigFiles":"\([^",]*\).*/\1/p' | head -1 | sed 's#\\\\#\\#g')" || folder=""
  folder="${folder%docker-compose.yml}"; folder="${folder%[/\\]}"
  if [ -n "$folder" ]; then
    fail "Recon Essentials is already installed on this computer, in $folder
  To start it:  cd \"$folder\" && docker compose up -d
  To install a second, separate copy, give it its own name and port:
    COMPOSE_PROJECT_NAME=recon-essentials-2 RECON_PORT=8081 bash install.sh"
  fi
  fail "Data of an earlier Recon Essentials installation is still on this computer (Docker volume ${PROJECT}_pgdata).
  Run this again in that installation's folder: its .env holds the database password for that data.
  To start over and DELETE that data: docker volume rm ${PROJECT}_pgdata ${PROJECT}_webdata ${PROJECT}_media ${PROJECT}_weblogs ${PROJECT}_enginelogs"
}

# A file to double-click that starts Recon Essentials if it is stopped and opens it in the browser,
# where people expect one: Windows (Git Bash) and macOS. It reads the address from .env each time,
# so changing the address never leaves it behind.
make_opener() {
  if windows_shell; then
    printf '%s\r\n' \
      '@echo off' \
      'rem Starts Recon Essentials if it is stopped, then opens it in the browser.' \
      'setlocal' \
      'cd /d "%~dp0"' \
      'docker compose up -d >nul 2>&1' \
      'if errorlevel 1 (' \
      '  echo Recon Essentials did not start. Is Docker Desktop running?' \
      '  pause' \
      '  exit /b 1' \
      ')' \
      'for /f "usebackq tokens=1,* delims==" %%a in (".env") do if "%%a"=="APP_URL" set "APP_URL=%%b"' \
      'set /a tries=0' \
      ':wait' \
      'docker compose ps --format "{{.Service}} {{.Health}}" web 2>nul | findstr /x /c:"web healthy" >nul && goto open' \
      'set /a tries+=1' \
      'if %tries% geq 60 goto open' \
      'timeout /t 2 /nobreak >nul' \
      'goto wait' \
      ':open' \
      'start "" "%APP_URL%"' > 'Open Recon Essentials.cmd'
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    cat > 'Open Recon Essentials.command' <<'OPENER'
#!/bin/bash
# Starts Recon Essentials if it is stopped, then opens it in the browser.
cd "$(dirname "$0")" || exit 1
if ! docker compose up -d >/dev/null 2>&1; then
  echo "Recon Essentials did not start. Is Docker Desktop running?"
  read -r -p "Press Enter to close. "
  exit 1
fi
url="$(grep -E '^APP_URL=' .env | cut -d= -f2-)"
for _ in $(seq 1 60); do docker compose ps --format '{{.Service}} {{.Health}}' web 2>/dev/null | grep -qx 'web healthy' && break; sleep 2; done
open "$url"
OPENER
    chmod +x 'Open Recon Essentials.command'
  fi
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

# A release can add a setting. .env keeps every value the customer has; a key the current
# .env.example has and .env lacks is added with the example's value (2026-10-05).
merge_env() {
  local example key line
  example="$(curl -fsSL "$REPO_RAW/.env.example" 2>/dev/null)" || return 0
  if [ -n "$(tail -c 1 .env)" ]; then printf '\n' >> .env; fi
  while IFS= read -r line; do
    key="${line%%=*}"
    if ! grep -q "^$key=" .env; then printf '%s\n' "$line" >> .env; echo "added $key to .env"; fi
  done < <(printf '%s\n' "$example" | grep -E '^[A-Z_][A-Z0-9_]*=' || true)
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

# upgrade / address / uninstall act on an existing installation: INSTALL_DIR when it exists, else
# the folder this script lives in (the installer leaves a copy of itself there).
cd_installation() {
  cd "$INSTALL_DIR" 2>/dev/null || cd "$SCRIPT_DIR" 2>/dev/null || fail "Run this in the installation folder (or set INSTALL_DIR)."
  [ -f docker-compose.yml ] && [ -f .env ] || fail "No docker-compose.yml and .env here — is this the installation folder?"
}

wait_healthy() {
  for _ in $(seq 1 60); do
    # `{{.Health}}` prints "healthy" or "unhealthy" — whole word, so the latter does not pass.
    if docker compose ps --format '{{.Service}} {{.Health}}' web 2>/dev/null | grep -qw healthy; then return 0; fi
    sleep 3
  done
  return 1
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
    if [ ! -f "$INSTALL_DIR/.env" ]; then guard_existing; fi
    say "Installing into $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    fetch docker-compose.yml
    fetch .env.example
    fetch install.sh
    fetch install.ps1

    if [ ! -f .env ]; then
      # The answers come first: a wrong RECON_ADDRESS must not leave a half-written .env behind,
      # which the next run would keep.
      default_port="${WEB_PORT:-8080}"; valid_port "$default_port" || default_port=8080
      ask_address localhost "$default_port"
      cp .env.example .env
      sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(random_hex)/" .env && rm -f .env.bak
      write_address "$ANSWER_HOST" "$ANSWER_PORT"
      # The folder owns its project name, so every later `docker compose` in it reaches these
      # containers and volumes, whatever the shell's environment says.
      set_env COMPOSE_PROJECT_NAME "$PROJECT"
      if [ "$VERSION" != "latest" ]; then
        set_env RECON_VERSION "$VERSION"
      fi
      echo "created .env (database password generated; APP_URL=http://$ANSWER_HOST:$ANSWER_PORT)"
    else
      echo "keeping the existing .env"
    fi

    say "Pulling images"
    docker compose pull
    say "Starting (database → migrator → engine bootstrap → web + engine)"
    docker compose up -d
    make_opener

    app_url="$(env_value APP_URL)"
    say "Waiting for the web UI"
    if wait_healthy; then
      printf '\n✅ Recon Essentials is up. Open %s/setup to create the first administrator.\n' "$app_url"
      printf '   Installed in %s\n' "$INSTALL_DIR"
      printf '   It starts again on its own whenever Docker starts. In that folder:\n'
      printf '     docker compose stop       stop it\n'
      printf '     docker compose up -d      start it again\n'
      printf '     bash install.sh upgrade   move to a new release\n'
      printf '     bash install.sh address   change the address or the port\n'
    else
      printf '\n✗ The web UI did not report healthy within 3 minutes.\n' >&2
      printf '  In %s check: docker compose ps     then: docker compose logs web-migrator web\n' "$INSTALL_DIR" >&2
      exit 1
    fi
    ;;

  upgrade)
    need_docker
    cd_installation
    say "Moving to the release"
    pin_release
    refresh_compose
    merge_env
    # The installers themselves, so the next upgrade runs the current ones.
    refresh_file install.sh
    refresh_file install.ps1
    say "Pulling images"
    docker compose pull
    say "Restarting — the migrator upgrades the database schema before the web starts"
    docker compose up -d
    printf '\n✅ Upgraded. Check: docker compose ps\n'
    ;;

  address)
    need_docker
    cd_installation
    current="$(env_value APP_URL)"
    case "$current" in
      https://*) fail "APP_URL is an https address ($current), so a reverse proxy serves this installation. Change APP_URL in .env by hand, then run: docker compose up -d" ;;
    esac
    parse_address "$current"
    host="$ADDRESS"; valid_host "$host" || host=localhost
    port="$(env_value WEB_PORT)"; valid_port "$port" || port=8080
    ask_address "$host" "$port"
    write_address "$ANSWER_HOST" "$ANSWER_PORT"
    say "Restarting the web with the new address"
    docker compose up -d
    printf '\n✅ Recon Essentials now opens at http://%s:%s\n' "$ANSWER_HOST" "$ANSWER_PORT"
    ;;

  uninstall)
    need_docker
    cd_installation
    if [ "${PURGE:-0}" = "1" ]; then
      say "Removing containers AND data volumes (PURGE=1)"
      docker compose down -v --remove-orphans
    else
      say "Removing containers; data volumes are kept (set PURGE=1 to delete them)"
      docker compose down --remove-orphans
    fi
    ;;

  *)
    echo "usage: install.sh [install|upgrade|address|uninstall]" >&2
    exit 2
    ;;
esac
