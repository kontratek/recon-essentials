#!/usr/bin/env bash
# Recon Essentials' script is now recon-essentials.sh: it installs Recon Essentials, and starts it when
# it is installed.
#
#   curl -fsSL https://raw.githubusercontent.com/kontratek/recon-essentials/main/recon-essentials.sh | bash
#
# This file stays so the first release's command and the folders it installed keep working: it runs
# recon-essentials.sh with the same arguments (install, upgrade, address, uninstall).
set -euo pipefail

REPO_RAW="${RECON_DIST_URL:-https://raw.githubusercontent.com/kontratek/recon-essentials/main}"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # In an installation folder the new script is fetched next to this one, once, and runs from there.
  if [ ! -f "$here/recon-essentials.sh" ] && [ -f "$here/.env" ]; then
    curl -fsSL "$REPO_RAW/recon-essentials.sh" -o "$here/recon-essentials.sh"
  fi
  if [ -f "$here/recon-essentials.sh" ]; then exec bash "$here/recon-essentials.sh" "$@"; fi
fi
curl -fsSL "$REPO_RAW/recon-essentials.sh" | bash -s -- "$@"
