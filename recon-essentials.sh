#!/usr/bin/env bash
# Vulmon Recon Essentials — install it, or start it when it is installed (Linux and macOS; Git Bash and
# WSL on Windows work too).
#
#   curl -fsSL https://raw.githubusercontent.com/kontratek/recon-essentials/main/recon-essentials.sh | bash
#
# Run it in the folder where the installation should go: it creates a recon-essentials folder there
# (INSTALL_DIR chooses another; in a system or temporary folder it uses the home folder instead),
# fetches docker-compose.yml + .env.example and both scripts, generates the database password, asks
# one question — who will use it — and takes port 8080, or the next free one when 8080 is in use. It
# writes nothing outside that folder. The script it leaves there starts Recon Essentials later; it
# never upgrades without asking and never deletes data, so it is safe to run whenever Recon
# Essentials does not open. In the installation folder (Windows: recon-essentials.cmd):
#
#   ./recon-essentials.sh             start it and open it in the browser
#   ./recon-essentials.sh stop        stop it (it stays stopped until it is started again)
#   ./recon-essentials.sh upgrade     move to the current release (the data is kept)
#   ./recon-essentials.sh address     change who can open it, or the address
#   ./recon-essentials.sh uninstall   remove the containers; the data is kept unless PURGE=1
#
# The install command does the same as the first line when it runs in that folder (or the one
# above it), or anywhere while Docker knows the installation. Without a terminal, give the answer in
# advance (RECON_ADDRESS=192.168.1.20, RECON_PORT=8080) or accept the defaults with
# RECON_NONINTERACTIVE=1. RECON_VERSION=x.y.z pins a release for install and upgrade: one release
# number for both images, the web and the engine. COMPOSE_PROJECT_NAME=name installs a second,
# separate copy, in ./name.
set -euo pipefail

REPO_RAW="${RECON_DIST_URL:-https://raw.githubusercontent.com/kontratek/recon-essentials/main}"
VERSION="${RECON_VERSION:-latest}"
SCRIPT_NAME=recon-essentials.sh
PROJECT="${COMPOSE_PROJECT_NAME:-recon-essentials}"
DOCKER_DESKTOP_WINDOWS='C:\Program Files\Docker\Docker\Docker Desktop.exe'

say()  { printf '\n▸ %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

case "$VERSION" in
  latest | [0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "RECON_VERSION must be a release number such as 1.0.0 (got $VERSION)" ;;
esac
printf '%s' "$PROJECT" | grep -Eq '^[a-z0-9][a-z0-9_-]*$' || fail "COMPOSE_PROJECT_NAME may hold only lowercase letters, digits, - and _ (got $PROJECT)."

# Git Bash, MSYS and Cygwin run on Windows; WSL is Linux but reaches Docker Desktop too.
windows_shell() { case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; *) return 1 ;; esac; }
in_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
on_macos() { [ "$(uname -s 2>/dev/null)" = Darwin ]; }

# A person at a terminal can be asked; a provisioning tool, CI or RECON_NONINTERACTIVE=1 cannot. Under
# `curl … | bash` stdin is the script itself, so questions go to /dev/tty.
can_ask() { [ "${RECON_NONINTERACTIVE:-0}" != 1 ] && (: </dev/tty) 2>/dev/null; }
ask() {
  local answer=""
  printf '%s' "$1" >/dev/tty
  read -r answer </dev/tty || answer=""
  printf '%s' "$answer"
}

# ---------------------------------------------------------------------------------------------- docker

docker_answers() { docker info >/dev/null 2>&1; }
wait_for_docker() {
  local waited=0
  while [ "$waited" -lt 180 ]; do
    if docker_answers; then return 0; fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# Docker Desktop, on the two systems where this script can start it.
desktop_installed() {
  if on_macos; then [ -d /Applications/Docker.app ]; elif windows_shell; then [ -f "$DOCKER_DESKTOP_WINDOWS" ]; else return 1; fi
}
desktop_running() {
  if on_macos; then pgrep -f 'Docker.app/Contents/MacOS' >/dev/null 2>&1; else tasklist 2>/dev/null | grep -qi '^Docker Desktop\.exe'; fi
}
start_desktop() {
  if on_macos; then open -a Docker; else cmd //c start "" "$DOCKER_DESKTOP_WINDOWS" >/dev/null 2>&1; fi
}
# What brought back a Docker Desktop whose engine had stopped answering (2026-10-02): every Docker
# process stopped, then only Docker Desktop's own WSL distributions. `wsl --shutdown` would stop
# every other distribution too.
restart_desktop() {
  local name
  if on_macos; then
    osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
    sleep 5
  else
    for name in 'Docker Desktop.exe' com.docker.backend.exe com.docker.build.exe com.docker.extensions.exe com.docker.dev-envs.exe vpnkit.exe; do
      taskkill //F //IM "$name" >/dev/null 2>&1 || true
    done
    wsl.exe --terminate docker-desktop >/dev/null 2>&1 || true
    wsl.exe --terminate docker-desktop-data >/dev/null 2>&1 || true
    sleep 2
  fi
  start_desktop
}

# Docker Desktop can stay open with its engine gone ("Internal Server Error"), which reads as "Docker
# is running" to the person at the keyboard (2026-10-05). With a person there, a closed Docker Desktop
# is started, and one that does not answer is restarted after asking. Otherwise the message says which.
ensure_docker() {
  local answer
  command -v docker >/dev/null 2>&1 || fail "Docker is not installed. See https://docs.docker.com/engine/install/ (Docker Desktop on Windows and macOS)."
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the 'docker compose' command)."
  if ! docker_answers; then
    if desktop_installed && can_ask; then
      if ! desktop_running; then
        say "Starting Docker Desktop"
        start_desktop
      else
        printf '\nDocker Desktop is open, but its engine does not answer.\n' >/dev/tty
        answer="$(ask 'Restart Docker Desktop now? Every container stops until it is back. [Y/n]: ')"
        case "$answer" in
          '' | [Yy]*) say "Restarting Docker Desktop"; restart_desktop ;;
          *) fail "Restart Docker Desktop yourself (Quit Docker Desktop, then start it again), wait until the engine runs, then run this again." ;;
        esac
      fi
      echo "waiting for the Docker engine (up to 3 minutes)"
      wait_for_docker || fail "Docker Desktop did not answer within 3 minutes. Wait until it shows that the engine is running, then run this again."
    elif on_macos || windows_shell || in_wsl; then
      fail "Docker Desktop does not answer. If it is open, restart it (Quit Docker Desktop, then start it again); if it is closed, start it. Wait until it shows that the engine is running, then run this again."
    else
      fail "The Docker daemon does not answer. Is it running (sudo systemctl start docker), and can this user use it (sudo usermod -aG docker \$USER, then sign in again)?"
    fi
  fi
  [ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = linux ] || fail "Docker runs Windows containers. Switch Docker Desktop to Linux containers and run this again."
}

# Every compose call names the project: a COMPOSE_PROJECT_NAME left in the shell would otherwise win
# over the one in the installation's .env and point the call at another installation.
compose() { docker compose -p "$PROJECT" "$@"; }

wait_healthy() {
  for _ in $(seq 1 60); do
    # `{{.Health}}` prints "healthy" or "unhealthy" — whole word, so the latter does not pass.
    if compose ps --format '{{.Service}} {{.Health}}' web 2>/dev/null | grep -qw healthy; then return 0; fi
    sleep 3
  done
  return 1
}

# ----------------------------------------------------------------------------------------------- files

fetch() {
  # $1 = file name; keeps an existing file (the customer may have edited compose or .env)
  if [ -f "$1" ]; then return; fi
  if [ -f "$SCRIPT_DIR/$1" ]; then cp "$SCRIPT_DIR/$1" "$1"; return; fi
  curl -fsSL "$REPO_RAW/$1" -o "$1" || fail "Could not download $1 from $REPO_RAW"
}

# Replaces one of OUR files (a script) with the current one, through a new file and a rename: bash
# reads a running script as it goes and must keep reading the file it opened. Best effort — an
# upgrade never fails because a script could not be refreshed.
refresh_file() {
  if curl -fsSL "$REPO_RAW/$1" -o "$1.new" 2>/dev/null && mv -f "$1.new" "$1" 2>/dev/null; then return 0; fi
  rm -f "$1.new"
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24; else head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# Sets KEY=value in .env, appending the line when it is missing. `-i.bak` keeps BSD sed (macOS) happy.
set_env() {
  if grep -q "^$1=" .env; then sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
env_value() { grep -E "^$1=" .env 2>/dev/null | head -n 1 | cut -d= -f2- || true; }
has_env() { grep -q "^$1=" .env; }

# --------------------------------------------------------------------------------- who opens it, where

# The address this machine uses towards the internet — a suggestion when other computers should
# open it. The route is asked first: `hostname -I` is GNU only and can list a Docker bridge first.
# Every probe may fail; none may end the script under `set -e`.
lan_ip() {
  local ip="" iface=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || ip=""
  fi
  if [ -z "$ip" ] && on_macos; then
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
local_host() { case "$1" in localhost | 127.0.0.1) return 0 ;; *) return 1 ;; esac; }

# Something on this computer already listens on that port: another program, or another container.
# Windows answers a connection to a closed port only after about 2 seconds, so there netstat is asked
# instead. A listening row is the one whose remote end is 0.0.0.0:0 or [::]:0, in every language
# Windows speaks (the state word itself is translated).
port_in_use() {
  if windows_shell; then
    netstat -an 2>/dev/null | awk -v port="$1" '$1 == "TCP" && ($3 == "0.0.0.0:0" || $3 == "[::]:0") && $2 ~ (":" port "$") { found = 1 } END { exit found ? 0 : 1 }'
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# "Who will use it?" — into ACCESS_HOST. Only this computer (the default) is localhost, and the port
# then listens on 127.0.0.1 alone, so nothing else on the network can reach it. Other computers too is
# the address they will type. RECON_ADDRESS answers in advance (founder, 2026-10-05).
choose_access() {
  local current="$1" default=1 answer suggestion
  ACCESS_HOST="$current"
  if [ -n "${RECON_ADDRESS:-}" ]; then
    parse_address "$RECON_ADDRESS"
    valid_host "$ADDRESS" || fail "RECON_ADDRESS must be an IP address or a host name (got $RECON_ADDRESS)."
    ACCESS_HOST="$ADDRESS"
    if [ -z "${RECON_PORT:-}" ] && valid_port "$ADDRESS_PORT"; then RECON_PORT="$ADDRESS_PORT"; fi
    return 0
  fi
  can_ask || return 0
  local_host "$current" || default=2
  printf '\nWho will use Recon Essentials?\n  1  Only this computer (local access: the port listens on 127.0.0.1)\n  2  Other computers on the network too (remote access: the port listens on 0.0.0.0)\n' >/dev/tty
  while :; do
    answer="$(ask "Choose 1 or 2 [$default]: ")"
    case "${answer:-$default}" in
      1) ACCESS_HOST=localhost; return 0 ;;
      2) break ;;
      *) printf '  Type 1 or 2.\n' >/dev/tty ;;
    esac
  done
  if local_host "$current"; then suggestion="$(lan_ip)"; else suggestion="$current"; fi
  printf "\nWhich address will the other computers open? Type this computer's IP address or host name, for example 192.168.1.20 or recon.example.local.\n" >/dev/tty
  printf '  Invitation and password-reset links use it, so a fixed IP address or a host name works best.\n' >/dev/tty
  while :; do
    if [ -n "$suggestion" ]; then answer="$(ask "Address [$suggestion]: ")"; else answer="$(ask 'Address: ')"; fi
    parse_address "${answer:-$suggestion}"
    if [ -n "$ADDRESS" ] && valid_host "$ADDRESS"; then
      ACCESS_HOST="$ADDRESS"
      if [ -z "${RECON_PORT:-}" ] && valid_port "$ADDRESS_PORT"; then RECON_PORT="$ADDRESS_PORT"; fi
      return 0
    fi
    printf '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local\n' >/dev/tty
  done
}

# Port 8080, or the next free one when 8080 is in use; RECON_PORT chooses it outright. Into PORT.
choose_port() {
  if [ -n "${RECON_PORT:-}" ]; then
    valid_port "$RECON_PORT" || fail "The port must be a number from 1 to 65535 (got $RECON_PORT)."
    if port_in_use "$RECON_PORT"; then fail "Port $RECON_PORT is in use on this computer. Choose another with RECON_PORT and run this again."; fi
    PORT="$RECON_PORT"
    return 0
  fi
  PORT=8080
  while port_in_use "$PORT"; do
    PORT=$((PORT + 1))
    if [ "$PORT" -gt 8099 ]; then fail "Ports 8080 to 8099 are all in use on this computer. Choose one with RECON_PORT and run this again."; fi
  done
  if [ "$PORT" != 8080 ]; then echo "port 8080 is in use on this computer; using $PORT"; fi
}

# APP_URL is always built here, never copied from an answer. WEB_PORT is the same port, and WEB_BIND
# keeps "only this computer" true: the compose file publishes the port on that address.
write_access() {
  set_env APP_URL "http://$1:$2"
  set_env WEB_PORT "$2"
  if local_host "$1"; then set_env WEB_BIND 127.0.0.1; else set_env WEB_BIND 0.0.0.0; fi
}

open_browser() {
  can_ask || return 0
  if on_macos; then open "$1" >/dev/null 2>&1 || true
  elif windows_shell; then cmd //c start "" "$1" >/dev/null 2>&1 || true
  elif in_wsl; then cmd.exe /c start "" "$1" >/dev/null 2>&1 || true
  elif [ "$(id -u)" != 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then (xdg-open "$1" >/dev/null 2>&1 &) || true
  fi
}

# ------------------------------------------------------------------------------- which installation

# The folder of the installation Docker knows under this project name (its containers exist, running
# or not); empty when there is none.
known_folder() {
  local folder
  folder="$(docker compose ls -a --format json 2>/dev/null | tr '{' '\n' | grep -F "\"Name\":\"$PROJECT\"" | sed -n 's/.*"ConfigFiles":"\([^",]*\).*/\1/p' | head -n 1 | sed 's#\\\\#\\#g')" || folder=""
  folder="${folder%docker-compose.yml}"
  folder="${folder%[/\\]}"
  printf '%s' "$folder"
}

# A folder holds an installation when its .env belongs to Recon Essentials: OUR compose file next to
# it (it names the recon-essentials images), or a release line in it when the compose file is gone.
# Another project's docker-compose.yml + .env is never one — this script would run `up` in it.
is_installation() {
  [ -f "$1/.env" ] || return 1
  grep -qs 'recon-essentials' "$1/docker-compose.yml" || grep -qs '^RECON_VERSION=' "$1/.env"
}

# A system or temporary folder never receives an installation: PowerShell run as administrator
# starts in C:\Windows\System32, and a temporary folder gets cleaned — and with it .env, which holds
# the database password for the data.
unsafe_folder() {
  local dir="${1%/}" lower
  [ -n "$dir" ] || return 0
  case "$dir" in
    /tmp | /tmp/* | /var/tmp | /var/tmp/* | /private/tmp | /private/tmp/* | /var/folders/* | /private/var/folders/* | \
    /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /etc | /etc/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | \
    /boot | /boot/* | /System | /System/*) return 0 ;;
  esac
  if windows_shell || in_wsl; then
    lower="$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      /[a-z] | /[a-z]/windows | /[a-z]/windows/* | /[a-z]/program\ files* | /[a-z]/programdata | /[a-z]/programdata/* | \
      */appdata/local/temp | */appdata/local/temp/* | \
      /mnt/[a-z] | /mnt/[a-z]/windows | /mnt/[a-z]/windows/* | /mnt/[a-z]/program\ files*) return 0 ;;
    esac
  fi
  return 1
}

# Which installation this run is about, into TARGET: INSTALL_DIR; else the folder this script lives
# in; else the current folder, or its recon-essentials folder; else the installation Docker knows
# (its containers exist, running or not). Otherwise a new one goes into ./recon-essentials — the
# folder the person chose by running the command there (founder, 2026-10-05) — or into the home
# folder when the current one is a system or temporary folder (TARGET_NOTE says so).
resolve_target() {
  local known
  TARGET_NOTE=""
  if [ -n "${INSTALL_DIR:-}" ]; then TARGET="$INSTALL_DIR"; return 0; fi
  if is_installation "$SCRIPT_DIR"; then TARGET="$SCRIPT_DIR"; return 0; fi
  if is_installation "$PWD"; then TARGET="$PWD"; return 0; fi
  if is_installation "$PWD/$PROJECT"; then TARGET="$PWD/$PROJECT"; return 0; fi
  known="$(known_folder)"
  if [ -n "$known" ] && [ -f "$known/.env" ]; then TARGET="$known"; return 0; fi
  if unsafe_folder "$PWD"; then
    TARGET="${HOME:-/root}/$PROJECT"
    TARGET_NOTE="$PWD is a system or temporary folder, so Recon Essentials goes into your home folder instead: $TARGET"
  else
    TARGET="$PWD/$PROJECT"
  fi
}

# The project an installation runs is the one its .env names; a compose file deleted by hand comes back.
enter_installation() {
  local named
  cd "$TARGET"
  named="$(env_value COMPOSE_PROJECT_NAME)"
  if [ -n "$named" ]; then PROJECT="$named"; fi
  fetch docker-compose.yml
}

# Windows opens a .ps1 in Notepad on a double-click and refuses to run one under the default
# execution policy, so the folder gets a .cmd that runs recon-essentials.ps1 with the same arguments
# (double-click to start; `recon-essentials.cmd stop` and the rest work too). CRLF: cmd.exe can
# misread a batch file with LF line endings. recon-essentials.ps1 writes the same bytes.
make_launcher() {
  windows_shell || return 0
  printf '%s\r\n' \
    '@echo off' \
    'rem Recon Essentials: starts it and opens it, or runs a command: stop, upgrade, address, uninstall.' \
    'rem It runs recon-essentials.ps1 next to it, whatever the execution policy of this computer is.' \
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0recon-essentials.ps1" %*' \
    'if errorlevel 1 pause' > recon-essentials.cmd
}

volumes() { printf '%s_pgdata %s_webdata %s_media %s_weblogs %s_enginelogs' "$PROJECT" "$PROJECT" "$PROJECT" "$PROJECT" "$PROJECT"; }

# A new installation must never take over the data of another one: the data lives in Docker volumes
# named after the project, and a new .env would bring a new database password to an old database.
# The database refuses it, and the first installation's containers are recreated with the wrong
# settings (2026-10-05). Runs before anything is written.
guard_new_install() {
  local folder
  docker volume inspect "${PROJECT}_pgdata" >/dev/null 2>&1 || return 0
  folder="$(known_folder)"
  if [ -n "$folder" ] && [ -f "$folder/.env" ]; then
    fail "Recon Essentials is already installed on this computer, in $folder
  To start it, run ./$SCRIPT_NAME in that folder (Windows: recon-essentials.cmd).
  To install a second, separate copy, give it its own name:
    curl -fsSL $REPO_RAW/$SCRIPT_NAME | COMPOSE_PROJECT_NAME=recon-essentials-2 bash"
  fi
  if [ -n "$folder" ]; then
    fail "The installation in $folder has lost its .env file, which holds the database password for its data.
  Put .env back from a backup, then run this again.
  To start over and DELETE that data: docker volume rm $(volumes)"
  fi
  fail "Data of an earlier Recon Essentials installation is still on this computer (Docker volume ${PROJECT}_pgdata).
  Start that installation from its folder: ./$SCRIPT_NAME (Windows: recon-essentials.cmd). Its .env holds the database password for the data.
  To start over and DELETE that data: docker volume rm $(volumes)"
}

# ------------------------------------------------------------------------------------------- upgrade

# A release can add a setting. .env keeps every value the customer has; a key the release's
# .env.example has and .env lacks is added with the example's value (2026-10-05).
merge_env() {
  local key line
  if [ -s .env ] && [ -n "$(tail -c 1 .env)" ]; then printf '\n' >> .env; fi
  while IFS= read -r line; do
    line="${line%$'\r'}"
    key="${line%%=*}"
    if ! has_env "$key"; then printf '%s\n' "$line" >> .env; echo "added $key to .env"; fi
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$1" || true)
}

# Moves the installation to RECON_VERSION, or to the release the distribution repository names now
# (every release pins its .env.example). Nothing changes on this computer until the new images are
# here, so a failed download leaves the installed release as it was. Every step is checked by hand:
# this also runs where `set -e` does not apply (after `||`, in a subshell).
do_upgrade() {
  local target compose_file=docker-compose.yml kept="" script
  rm -f .env.example.new docker-compose.yml.new
  if ! curl -fsSL "$REPO_RAW/.env.example" -o .env.example.new 2>/dev/null; then
    rm -f .env.example.new
    printf '\n✗ Could not download .env.example from %s\n' "$REPO_RAW" >&2
    return 1
  fi
  if [ "$VERSION" != latest ]; then target="$VERSION"; else target="$(sed -n 's/^RECON_VERSION=//p' .env.example.new | head -n 1 | tr -d '\r')"; fi
  case "$target" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) rm -f .env.example.new; printf '\n✗ The .env.example at %s names no release.\n' "$REPO_RAW" >&2; return 1 ;;
  esac
  # The current release's compose file, unless a pinned release keeps the one it has (the
  # repository's file belongs to the current release) — or the local one predates the release line
  # (it names no RECON_VERSION), which no release can run.
  if [ "$VERSION" = latest ] || ! grep -q 'RECON_VERSION' docker-compose.yml; then
    if ! curl -fsSL "$REPO_RAW/docker-compose.yml" -o docker-compose.yml.new 2>/dev/null; then
      rm -f .env.example.new docker-compose.yml.new
      printf '\n✗ Could not download docker-compose.yml from %s\n' "$REPO_RAW" >&2
      return 1
    fi
    compose_file=docker-compose.yml.new
  fi
  say "Downloading release $target"
  if ! RECON_VERSION="$target" docker compose -p "$PROJECT" -f "$compose_file" pull; then
    rm -f .env.example.new docker-compose.yml.new
    printf '\n✗ Could not download release %s. Nothing was changed.\n' "$target" >&2
    return 1
  fi
  mv -f .env.example.new .env.example
  if [ -f docker-compose.yml.new ]; then
    if cmp -s docker-compose.yml.new docker-compose.yml; then
      rm -f docker-compose.yml.new
    else
      kept="docker-compose.yml.$(date +%Y%m%d%H%M%S).bak"
      mv docker-compose.yml "$kept" && mv docker-compose.yml.new docker-compose.yml || return 1
    fi
  fi
  # An installation from before WEB_BIND published its port to the whole network. It keeps doing so.
  has_env WEB_BIND || set_env WEB_BIND 0.0.0.0
  merge_env .env.example
  set_env RECON_VERSION "$target"
  # Before 0.1.2 each image had its own line. The release line replaces both, so an old pair can
  # never be left behind to override it.
  sed -i.bak '/^WEB_IMAGE=/d; /^ENGINE_IMAGE=/d' .env && rm -f .env.bak
  echo "release: $target"
  if [ -n "$kept" ]; then echo "docker-compose.yml changed in this release; your previous copy is $kept"; fi
  # The scripts themselves, so the next run uses the current ones — under the first release's names
  # too, while an installation still has them.
  for script in recon-essentials.sh recon-essentials.ps1 install.sh install.ps1; do
    case "$script" in install.*) [ -f "$script" ] || continue ;; esac
    refresh_file "$script"
  done
  chmod +x recon-essentials.sh 2>/dev/null || true
  make_launcher
  say "Restarting — the migrator upgrades the database schema before the web starts"
  compose up -d || return 1
  if ! wait_healthy; then
    printf '\n✗ The web UI did not report healthy within 3 minutes. Check: docker compose logs web-migrator web\n' >&2
    return 1
  fi
  printf '\n✅ Upgraded to %s.\n' "$target"
}

# 0 when $1 is a newer x.y.z than $2.
newer_than() {
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    if [ "${a[i]:-0}" -gt "${b[i]:-0}" ] 2>/dev/null; then return 0; fi
    if [ "${a[i]:-0}" -lt "${b[i]:-0}" ] 2>/dev/null; then return 1; fi
  done
  return 1
}

# "latest|minimum", as the engine copied them from the signed manifest into app_meta, so asking costs
# no connection beyond the ones the product makes anyway. minimum_engine_version is there only while
# this engine is below the supported floor.
release_status() {
  printf '%s\n' "select coalesce(value->>'latest_version', '') || '|' || coalesce(value->>'minimum_engine_version', '') from app_meta where key = 'license_status';" \
    | compose exec -T db sh -c 'psql -X -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' 2>/dev/null | tr -d '\r' | head -n 1
}

# Before it starts: a release below the supported floor is upgraded first, a newer one is offered.
# Neither keeps the installed release from starting when the upgrade cannot finish: the founder's
# rule (2026-10-02) is that an old engine is warned, never stopped.
check_release() {
  local status latest minimum current answer
  status="$(release_status || true)"
  case "$status" in *'|'*) ;; *) return 0 ;; esac
  latest="${status%%|*}"
  minimum="${status#*|}"
  current="$(env_value RECON_VERSION)"
  if [ -n "$minimum" ]; then
    say "Release ${current:-of this installation} is no longer supported; upgrading before it starts"
    ( do_upgrade ) || echo "The upgrade did not finish; starting the installed release."
    return 0
  fi
  newer_than "$latest" "$current" || return 0
  if can_ask; then
    answer="$(ask "
Recon Essentials $latest is available; this installation runs ${current:-an older release}. Upgrade now? [Y/n]: ")"
    case "$answer" in
      '' | [Yy]*) ( do_upgrade ) || echo "The upgrade did not finish; starting the installed release." ;;
      *) echo "Upgrade later with: ./$SCRIPT_NAME upgrade (in $TARGET)" ;;
    esac
  else
    echo "Recon Essentials $latest is available (this installation runs ${current:-an older release}). Upgrade with: ./$SCRIPT_NAME upgrade (in $TARGET)"
  fi
}

# ------------------------------------------------------------------------------------------ commands

print_commands() {
  printf '   To start it later, or to stop or upgrade it, run in %s:\n' "$TARGET"
  printf '     ./%s            start it and open it\n' "$SCRIPT_NAME"
  printf '     ./%s stop       stop it\n' "$SCRIPT_NAME"
  printf '     ./%s upgrade    move to a new release\n' "$SCRIPT_NAME"
  printf '     ./%s address    change who can open it\n' "$SCRIPT_NAME"
  if windows_shell; then printf '   On Windows, recon-essentials.cmd in that folder does the same; double-click it to start.\n'; fi
}

install_new() {
  local url
  guard_new_install
  # The answers come first: a wrong RECON_ADDRESS or RECON_PORT must not leave a half-written .env.
  choose_access localhost
  choose_port
  if [ -n "$TARGET_NOTE" ]; then echo "$TARGET_NOTE"; fi
  say "Installing into $TARGET"
  mkdir -p "$TARGET"
  cd "$TARGET"
  fetch docker-compose.yml
  fetch .env.example
  fetch recon-essentials.sh
  fetch recon-essentials.ps1
  chmod +x recon-essentials.sh 2>/dev/null || true
  make_launcher
  cp .env.example .env
  sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(random_hex)/" .env && rm -f .env.bak
  write_access "$ACCESS_HOST" "$PORT"
  # The folder owns its project name, so a plain `docker compose` in it reaches these containers.
  set_env COMPOSE_PROJECT_NAME "$PROJECT"
  if [ "$VERSION" != latest ]; then set_env RECON_VERSION "$VERSION"; fi
  echo "created .env (database password generated; APP_URL=http://$ACCESS_HOST:$PORT)"
  say "Downloading the images"
  compose pull
  say "Starting (database → migrator → engine bootstrap → web + engine)"
  compose up -d
  say "Waiting for the web UI"
  wait_healthy || fail "The web UI did not report healthy within 3 minutes. In $TARGET check: docker compose ps     then: docker compose logs web-migrator web"
  url="$(env_value APP_URL)"
  printf '\n✅ Recon Essentials is installed in %s and runs at %s\n' "$TARGET" "$url"
  printf '   Create the first administrator at %s/setup\n' "$url"
  if ! local_host "$ACCESS_HOST"; then printf '   Do it now: until then, anyone on the network who opens this address can.\n'; fi
  printf '   It runs in the background and starts again whenever Docker starts.\n'
  printf '   When it does not open, run ./%s in its folder. It starts Recon Essentials and never deletes data.\n' "$SCRIPT_NAME"
  print_commands
  open_browser "$url/setup"
}

run_installed() {
  local url
  enter_installation
  say "Starting Recon Essentials ($TARGET)"
  # An installation from before the launcher (or the first release) gets one.
  if [ ! -f recon-essentials.cmd ]; then make_launcher; fi
  # The database first: the release check reads it, and an upgrade it calls for runs before the web
  # starts. No pull: a present image is used as it is and only a missing one is downloaded (Compose's
  # default pull_policy), so this is fast, and needs no internet when nothing is missing.
  compose up -d --wait db || true
  check_release
  compose up -d || fail "Recon Essentials did not start. When an image had to be downloaded, check the internet connection. In $TARGET: docker compose logs"
  wait_healthy || fail "The web UI did not report healthy within 3 minutes. In $TARGET check: docker compose ps     then: docker compose logs web-migrator web"
  url="$(env_value APP_URL)"
  printf '\n✅ Recon Essentials runs at %s\n' "$url"
  open_browser "$url"
}

change_address() {
  local current host port
  current="$(env_value APP_URL)"
  case "$current" in
    https://*) fail "APP_URL is an https address ($current), so a reverse proxy serves this installation. Change APP_URL in .env by hand, then run: docker compose up -d" ;;
  esac
  parse_address "$current"
  host="$ADDRESS"
  valid_host "$host" || host=localhost
  choose_access "$host"
  port="$(env_value WEB_PORT)"
  valid_port "$port" || port=8080
  if [ -n "${RECON_PORT:-}" ]; then
    valid_port "$RECON_PORT" || fail "The port must be a number from 1 to 65535 (got $RECON_PORT)."
    if [ "$RECON_PORT" != "$port" ] && port_in_use "$RECON_PORT"; then fail "Port $RECON_PORT is in use on this computer. Choose another with RECON_PORT and run this again."; fi
    port="$RECON_PORT"
  fi
  write_access "$ACCESS_HOST" "$port"
  say "Restarting the web with the new address"
  compose up -d
  printf '\n✅ Recon Essentials now opens at http://%s:%s\n' "$ACCESS_HOST" "$port"
  if local_host "$ACCESS_HOST"; then printf '   Only this computer can open it.\n'; fi
}

# Under `curl … | bash` there is no script file: BASH_SOURCE is unset and $0 is "bash", which used to
# make SCRIPT_DIR the caller's current directory — fetch() then took a docker-compose.yml or
# .env.example lying there over the distribution's, silently. A checkout keeps the sibling-file behaviour.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=/nonexistent
fi

case "${1:-run}" in
  run | install | start)
    ensure_docker
    resolve_target
    if is_installation "$TARGET"; then
      run_installed
    elif [ -e "$TARGET/.env" ]; then
      fail "$TARGET already has an .env file that does not belong to Recon Essentials. Choose another folder with INSTALL_DIR."
    else
      install_new
    fi
    ;;

  stop | upgrade | address | uninstall)
    ensure_docker
    resolve_target
    is_installation "$TARGET" || fail "No installation in $TARGET. Run this in the installation folder, or set INSTALL_DIR."
    enter_installation
    case "$1" in
      stop)
        say "Stopping Recon Essentials"
        compose stop
        printf '\n✅ Stopped. It stays stopped, also after a restart, until ./%s starts it again.\n' "$SCRIPT_NAME"
        ;;
      upgrade) do_upgrade || exit 1 ;;
      address) change_address ;;
      uninstall)
        if [ "${PURGE:-0}" = "1" ]; then
          say "Removing containers AND data volumes (PURGE=1)"
          compose down -v --remove-orphans
        else
          say "Removing containers; data volumes are kept (set PURGE=1 to delete them)"
          compose down --remove-orphans
        fi
        ;;
    esac
    ;;

  *)
    echo "usage: ./$SCRIPT_NAME [stop|upgrade|address|uninstall]   (no argument: start it, or install it)" >&2
    exit 2
    ;;
esac
