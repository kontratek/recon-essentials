# Vulmon Recon Essentials

Free, self-hosted reconnaissance and monitoring for your external attack surface. Recon Essentials is the discovery and inventory part of [Vulmon Recon](https://recon.vulmon.com), packaged to run on your own machine with Docker. You add the domains and IP ranges you own. It then keeps discovering what is exposed — subdomains, IPs, open ports, websites, technologies, certificates — and shows changes as they happen.

Everything it finds stays in a PostgreSQL database on your machine. It never uploads your assets.

| | Unregistered | Registered (free) |
|---|---|---|
| Discovered assets (domains + IPs) | Unlimited | Unlimited |
| In-scope assets (domains + IPs) | 15 | 50 |
| Seeds | 45 | 150 |

Registering is optional and takes an e-mail address and an activation code — Settings → License.

## What you get

The six inventory lists (domains, IPs, websites, technologies, ports, certificates), each searchable, filterable and exportable to CSV. Scope review, so you decide which domains and IPs are yours and get monitored. Scan configuration with policies, and a scan activity log. Certificate and TLS findings. Reports you generate when you want them. Notes, tags and owners. Search across everything found. In-app notifications. Accounts with roles, and two-factor authentication.

## Requirements

- Docker Engine 24+ with Docker Compose v2 (Linux server, or Docker Desktop on macOS / Windows)
- 2 CPU cores and 4 GB RAM; 10 GB disk to start with
- Outbound access to the targets listed under **Network activity** below; one inbound port for the web UI

## Install

**Linux and macOS** — in a terminal (on Windows, Git Bash and WSL work too):

```bash
curl -fsSL https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.sh | bash
```

**Windows** — in PowerShell, with Docker Desktop running Linux containers (its default):

```powershell
irm https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.ps1 | iex
```

Both scripts do the same thing: they create a `recon-essentials` folder in the current directory, generate the database password, ask for the address people will open in the browser, pull the images and start everything. Then open `http://<your-address>:8080/setup` and create the first administrator.

Manual install: copy `docker-compose.yml` and `.env.example` into a folder, rename `.env.example` to `.env`, set `POSTGRES_PASSWORD` and `APP_URL` (`RECON_VERSION` already names the current release), then `docker compose up -d`.

## First steps

1. **Add seeds** — Scan configuration → Seeds: your domains, IPs or ranges. Discovery starts within minutes.
2. **Review scope** — Asset Review lists what was found; confirm what is yours. Only in-scope assets are monitored continuously and count towards the limit.
3. **Invite colleagues** — Settings → Users. Invitations are links you copy and send; the installation sends no e-mail.
4. **Register (optional)** — Settings → License, to raise the limits to 50 in-scope assets / 150 seeds.

## Network activity

The complete list of outbound connections the product makes. Your own assets are scanned from this machine's address. Give this table to your network team before installing; the same table is shown in the product under Scan configuration → Network activity, where the optional ones can be switched off.

<!-- egress:start -->
<!-- Generated from shared/essentials-egress.ts by `pnpm essentials:egress-readme` — do not edit by hand. -->

| Target | Ports | Purpose | From | Can be switched off |
|---|---|---|---|---|
| Your own assets (the seeds you add and what they resolve to) | all | Scanning: DNS, ports, HTTP(S), TLS certificates. Two of these can leave your own addresses without leaving your assets: a page's icon is fetched from the address the page itself gives, which may be a content delivery network, and an HTTP request follows redirects (up to ten), which may end on another domain. | Engine | No |
| Public DNS resolvers 1.1.1.1, 1.0.0.1 (Cloudflare), 8.8.8.8, 8.8.4.4 (Google), 9.9.9.9 (Quad9) | 53/udp, 53/tcp | DNS discovery: subdomains and MX/NS/TXT/CAA records. Public resolvers so results match what the internet sees and your own DNS server does not carry thousands of lookups. These providers see the names being resolved. If your network allows DNS only to its own resolver, these scans cannot run. | Engine | No |
| crt.sh | 5432, 443 | Certificate Transparency log search (subdomain discovery). The routine query uses the Postgres interface on 5432; if 5432 cannot be reached at all, it falls back to the HTTPS interface on 443 and asks only for the subdomains of the domain being scanned. Either way at most one request every two seconds, identifying itself as recon-essentials. Switching it off stops subdomain discovery from CT logs. | Engine | Yes — Scan configuration → Network activity |
| recon.vulmon.com (registered installations only) | 443 | License renewal (every day, registered installations only). It also reports how many domains and IP addresses are in scope, out of scope and pending, and how many seeds there are — numbers only, never names. A registered installation keeps working for 7 days without renewal, then scanning pauses until the license server is reachable again. | Engine | No |
| recon.vulmon.com | 443 | Registration with Vulmon — once, from Settings → License, made by the web server. No call is made unless you register. | Web server | Only if you register |
| recon.vulmon.com | 443 | Signed product manifest: revocation list, minimum supported versions, the latest release (for the update notice), announcements. Contains nothing about your installation. Tolerates short outages. | Engine | No |
| WHOIS servers (IANA, registries, registrars, whois.cymru.com) | 43/tcp | Domain and IP WHOIS records. whois.cymru.com tells which network (ASN) an IP address belongs to. Switching it off leaves the WHOIS fields as "not measured". | Engine | Yes — Scan configuration → Network activity |
| RDAP servers (rdap.db.ripe.net and the other registries) | 443 | RDAP lookups (the HTTPS successor of WHOIS). Switching it off leaves the RDAP-sourced fields as "not measured". | Engine | Yes — Scan configuration → Network activity |

**Inbound:** Only the web UI port you publish in docker-compose (default 8080).

<!-- egress:end -->

## Network privileges

For full scanning (SYN port scans, the full port range, ICMP reachability) the `pipeline` container needs raw sockets. The compose file grants `NET_RAW` and runs the engine as root inside its container — the Docker default; no `--privileged` is involved.

On a rootless runtime (rootless Docker, Podman rootless, a restricted Kubernetes profile) the engine still runs, detects the missing privilege at start, and scans with what it has: TCP connect scans of the common ports instead of SYN, and no full port range. UDP scanning does not need the privilege. The dashboard shows a persistent warning while that is the case. To enable full scanning, run the compose stack with a Docker daemon that allows the container root user and the `NET_RAW` capability.

The engine checks these privileges each time it starts, and Scan configuration → Scanning shows when it last checked. After changing them, restart it: `docker compose restart pipeline`.

**Endpoint security note.** The engine performs port scans and sends ICMP from this machine. Some EDR / IDS products flag that as reconnaissance. Add an exception for the `recon-essentials` containers (or this host) before enabling scanning of large ranges.

## Behind a reverse proxy

The web port serves plain HTTP. To put the installation behind HTTPS, terminate TLS in a reverse proxy (nginx, Caddy, Traefik), set `APP_URL` to the https address, and set `RECON_TRUST_PROXY=1` in `.env`, so the app takes the client address from the proxy's `X-Forwarded-For` / `X-Real-IP` headers for its sign-in limits. Leave that line unset when browsers reach the port directly: with it set, any client could choose the address those limits count.

## Registration and the license

Registering sends your e-mail address, the installation id and the product versions to Vulmon once, from the web container, when you complete Settings → License. Vulmon e-mails a 6-digit code; entering it stores a signed license document in your database. Afterwards the engine renews that document about once a day, and each renewal also reports how many domains and IP addresses are in scope, out of scope and pending, and how many seeds there are — numbers only, never names. If the license server is unreachable, everything keeps working for 7 days; after that scanning pauses (nothing is deleted) until the renewal succeeds. Vulmon uses the registration to count installations and to write to you about your license and about important changes to the product; the privacy policy has the details: https://recon.vulmon.com/pp

## Upgrade

Run from the installation folder (the installer leaves a copy of itself there).

Linux and macOS:

```bash
bash install.sh upgrade                        # the current release
RECON_VERSION=0.2.0 bash install.sh upgrade    # a specific release
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 upgrade                                  # the current release
$env:RECON_VERSION = '0.2.0'; powershell -ExecutionPolicy Bypass -File install.ps1 upgrade    # a specific release
```

Recon Essentials runs as two images, the web and the engine, and every release is one tested pair of them. `.env` names the release in one line, `RECON_VERSION`, and both images take that number, so they cannot come from different releases. A plain `docker compose pull` fetches the same release again; the upgrade moves `RECON_VERSION` to the new release, replaces `docker-compose.yml` if the release changed it (your previous copy is kept beside it), pulls the images and restarts. By hand: change `RECON_VERSION`, then run `docker compose pull` and `docker compose up -d`.

If the engine that runs is not the build this release was tested with, the dashboard says so; run the upgrade to put both images on the same release again.

The migrator container upgrades the database schema before the new web version starts. Releases are announced in this repository; downgrades are not supported.

## Backup, restore, direct access

Run from the installation folder. A backup is two files: the database dump and the generated secrets file. Two-factor secrets are encrypted with a key from that file, so a database restored next to freshly generated secrets locks every two-factor user out.

The commands below are the same in bash and in PowerShell. None of them sends the dump through the shell: the database writes it inside its container and `docker compose cp` copies it out, because Windows PowerShell re-encodes binary output that passes through `>` and the dump would be damaged without any warning.

```sh
# backup — keep the two files together; rename them with the date if you keep more than one
docker compose exec -T db pg_dump -U recon -Fc -f /tmp/recon.dump recon
docker compose cp db:/tmp/recon.dump recon.dump
docker compose exec -T db rm /tmp/recon.dump
docker compose cp web:/data/secrets.env recon.secrets.env
# SQL access
docker compose exec db psql -U recon -d recon
```

Restore into a fresh installation or into the one the backup came from, from its folder, with the two files in it:

```sh
docker compose stop web analyzer pipeline
# the secrets file goes back first; the web runs as uid 1001 and must be able to read it
docker compose cp recon.secrets.env web:/data/secrets.env
docker compose run --rm --no-deps --user root --entrypoint sh web -c "chown 1001:1001 /data/secrets.env && chmod 600 /data/secrets.env"
docker compose cp recon.dump db:/tmp/recon.dump
docker compose exec -T db pg_restore -U recon -d recon --clean --if-exists /tmp/recon.dump
docker compose exec -T db rm /tmp/recon.dump
docker compose up -d    # the migrator brings the restored schema to this release, then everything starts
```

Data lives in three Docker volumes: `pgdata` (the database), `media` (favicons and screenshots) and `webdata` (generated secrets and uploaded profile images).

## Logs

`docker compose logs` shows what the containers print. The same logs are also kept as files, so an upgrade does not delete them: the web's in the `weblogs` volume and the engine's in `enginelogs` (one debug and one error file per service and day). Old files are deleted automatically: after 14 days, except the web's access log, which is kept for 30. To read them directly, set `ESSENTIALS_LOG_DIR` and `ESSENTIALS_ENGINE_LOG_DIR` in `.env` to host folders and run `docker compose up -d`.

If the engine crashes, its trace is kept in the same volume as `crash-pipeline.log`, `crash-analyzer.log` or `crash-bootstrap.log`. These files are not swept after 14 days (they roll over at 4 MB), and each start writes the engine version first. Send the file with a support request: we can read a trace for the version it names. It can be copied out even while the service is down:

```bash
docker compose cp pipeline:/var/log/recon/crash-pipeline.log .
```

## Locked out?

An administrator can issue a one-time password reset link from Settings → Users. If the only administrator is locked out:

```bash
docker compose exec web cli user reset-password admin@example.com
```

prints a reset link valid for 60 minutes.

## Uninstall

Linux and macOS:

```bash
bash install.sh uninstall            # containers removed, data kept
PURGE=1 bash install.sh uninstall    # containers and data volumes removed
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 uninstall                         # containers removed, data kept
$env:PURGE = '1'; powershell -ExecutionPolicy Bypass -File install.ps1 uninstall       # containers and data volumes removed
```

## The hosted product

Vulmon Recon, the hosted product, adds a managed service and vulnerability intelligence:

- Vulnerability findings: CVE matching, severity scoring and issue tracking
- Cloud connectors for AWS, Azure, GCP and Cloudflare accounts
- Integrations: Jira, Slack, Teams, ServiceNow, GitHub, GitLab and Zapier
- The public API, single sign-on and scheduled email reports
- Nothing to install or maintain

Plans and prices: https://recon.vulmon.com/pricing

## Full documentation

The long-form guides live at **https://recon.vulmon.com/docs/essentials** — what is and is not included, the outbound connection list with the reasoning behind each entry, network privileges, access and transport, and where the data sits. This README is the short operational copy; keep it with your backups if the installation has no internet access.

## Support and terms

Questions and problems: the issue tracker of this repository.

Recon Essentials is not open source. Its use is governed by the Vulmon Recon Terms of Service (https://recon.vulmon.com/tos, see [`LICENSE.md`](LICENSE.md)) and the Privacy Policy (https://recon.vulmon.com/pp).

The open-source components the images contain are listed, with their licenses, in the third-party notices: `/app/THIRD_PARTY_NOTICES.txt` in the web image (also served at `/third-party-notices.txt`) and `/opt/recon/NOTICE` in the engine image.
