# Vulmon Recon Essentials - installer / upgrader for Windows (PowerShell).
#
#   irm https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File install.ps1 upgrade     # from the installation folder: move to the current release and restart (data is kept)
#   powershell -ExecutionPolicy Bypass -File install.ps1 uninstall   # stop and remove the containers; volumes are kept unless PURGE=1
#
# The Windows twin of install.sh: the same steps, the same files and the same .env. It needs Docker
# Desktop running Linux containers (Docker Compose v2 ships with it). What it does: checks Docker,
# creates .\recon-essentials (or INSTALL_DIR), fetches docker-compose.yml + .env.example (and itself,
# for later upgrades), generates the database password, asks which address and port people will
# use to open it, pulls the images and starts everything. It writes nothing outside that folder.
#
# $env:RECON_VERSION = 'x.y.z' pins that release instead of the current one, for install and upgrade.
# It is the same number .env carries: one release number for both images, the web and the engine.
#
# Two rules this file keeps, both about Windows PowerShell 5.1:
#   - ASCII only. 5.1 reads a script FILE without a byte-order mark in the ANSI code page, so a
#     single typographic character would garble the messages or break the parse.
#   - No `exit` except the final guard, and only when run as a file. Under `irm | iex` this text
#     runs inside the caller's own session, where `exit` would close their window.

param([string]$Command = 'install')

$reconScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }

# Everything below runs in a child scope: under `irm | iex` a preference or a function set at the
# top level would stay behind in the caller's session.
$reconBody = {
  param([string]$Command, [string]$ScriptDir)

  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar slows 5.1 downloads to a crawl
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  $RepoRaw = if ($env:RECON_DIST_URL) { $env:RECON_DIST_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/kontratek/recon-essentials/main' }
  $InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path (Get-Location).Path 'recon-essentials' }
  $Version = if ($env:RECON_VERSION) { $env:RECON_VERSION } else { 'latest' }
  if ($Version -ne 'latest' -and $Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "RECON_VERSION must be a release number such as 1.0.0 (got $Version)"
  }

  # .env and the compose file are read by Docker Compose: written without a byte-order mark and with
  # the LF line endings the distribution ships, never through Set-Content (5.1 writes a BOM).
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false

  function Say([string]$Text) { Write-Host ''; Write-Host "-> $Text" }

  # Quiet probe of a native command. Windows PowerShell turns a redirected stderr line into an
  # error record, and under ErrorActionPreference=Stop that would throw, so the probe relaxes it.
  function Test-Native([scriptblock]$Block) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Block *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false } finally { $ErrorActionPreference = $previous }
  }

  # docker prints its progress on stderr. Some hosts (a CI runner, any caller that captures this
  # session's output) make Windows PowerShell wrap those lines into error records, which under
  # Stop would end the install halfway through a pull - so the call runs under Continue and the
  # exit code is the only verdict.
  function Invoke-Docker {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker @args } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed (exit code $LASTEXITCODE)." }
  }

  function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      throw 'Docker is not installed. Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/'
    }
    if (-not (Test-Native { docker compose version })) { throw "Docker Compose v2 is required (the 'docker compose' command)." }
    if (-not (Test-Native { docker info })) { throw 'Docker is installed but not reachable - is Docker Desktop running?' }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $osType = (& docker info --format '{{.OSType}}' 2>$null) -join ''
    $ErrorActionPreference = $previous
    if ($osType.Trim() -ne 'linux') {
      throw 'Docker Desktop is running Windows containers. Switch it to Linux containers (Docker icon in the taskbar -> Switch to Linux containers) and run this again.'
    }
  }

  function Read-Text([string]$Path) { return [System.IO.File]::ReadAllText($Path) }
  function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom) }

  function Get-DistFile([string]$Name, [string]$Destination) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/$Name" -OutFile $Destination }
    catch { throw "Could not download $Name from $RepoRaw" }
  }

  # Keeps an existing file (the customer may have edited compose or .env); takes a sibling file when
  # run from a checkout of the distribution repository; downloads otherwise.
  function Get-InstallFile([string]$Name) {
    $target = Join-Path $InstallDir $Name
    if (Test-Path -LiteralPath $target) { return }
    if ($ScriptDir -and (Test-Path -LiteralPath (Join-Path $ScriptDir $Name))) { Copy-Item -LiteralPath (Join-Path $ScriptDir $Name) -Destination $target; return }
    Get-DistFile $Name $target
  }

  # Sets KEY=value in .env, appending the line when it is missing.
  function Set-EnvLine([string]$Key, [string]$Value) {
    $path = Join-Path $InstallDir '.env'
    $text = Read-Text $path
    $pattern = "(?m)^$([regex]::Escape($Key))=.*$"
    if ([regex]::IsMatch($text, $pattern)) {
      $text = [regex]::Replace($text, $pattern, "$Key=$($Value.Replace('$', '$$'))")
    }
    else {
      if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
      $text += "$Key=$Value`n"
    }
    Write-Text $path $text
  }

  function New-Password {
    $bytes = New-Object byte[] 24
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
  }

  # Splits what was typed into an address and an optional port, forgiving the forms people actually
  # type: a scheme, a path, a port glued on. 2026-10-05: "127.0.0.1:8080" without http:// went into
  # APP_URL as it was, and every sign-in then failed with a 500 (Invalid base URL).
  function Split-Address([string]$Text) {
    $value = ($Text.Trim()) -replace '^https?://', ''
    $value = ($value -split '/', 2)[0]
    $parts = $value -split ':', 2
    $port = ''
    if ($parts.Count -gt 1) { $port = $parts[1] }
    return @{ Address = $parts[0]; Port = $port }
  }
  function Test-HostName([string]$Name) { return ($Name -match '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') }
  function Test-Port([string]$Value) {
    if ($Value -notmatch '^\d{1,5}$') { return $false }
    $number = [int]$Value
    return ($number -ge 1 -and $number -le 65535)
  }

  # The address of the adapter that holds the default route; empty when there is none.
  function Get-LanIp {
    try {
      $config = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
      if ($config) { return [string](($config.IPv4Address | Select-Object -First 1).IPAddress) }
    }
    catch { }
    return ''
  }

  # .env pins the release an installation runs (RECON_VERSION - both images take it), so pulling
  # alone would fetch the same release again. Upgrading moves that one line: to RECON_VERSION when
  # it is set, otherwise to the release the distribution repository names now.
  function Set-Release {
    if ($Version -ne 'latest') {
      $target = $Version
    }
    else {
      try { $current = (Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/.env.example").Content }
      catch { throw "Could not download .env.example from $RepoRaw" }
      $match = [regex]::Match([string]$current, '(?m)^RECON_VERSION=(\S+)')
      if (-not $match.Success) { throw "The .env.example at $RepoRaw names no release." }
      $target = $match.Groups[1].Value
    }
    Set-EnvLine 'RECON_VERSION' $target
    # Before 0.1.2 each image had its own line. The release line replaces both, so an old pair can
    # never be left behind to override it.
    $path = Join-Path $InstallDir '.env'
    Write-Text $path ([regex]::Replace((Read-Text $path), '(?m)^(WEB_IMAGE|ENGINE_IMAGE)=.*(\r?\n)?', ''))
    Write-Host "release: $target"
  }

  # A release can change the compose file as well. The current one replaces the local copy and the
  # old copy stays beside it, so a hand edit is never lost silently. Skipped for a pinned
  # RECON_VERSION, because the repository's compose file belongs to the current release.
  function Update-Compose {
    $compose = Join-Path $InstallDir 'docker-compose.yml'
    if ($Version -ne 'latest' -and (Read-Text $compose).Contains('RECON_VERSION')) { return }
    $fresh = "$compose.new"
    Get-DistFile 'docker-compose.yml' $fresh
    if ((Get-FileHash -LiteralPath $fresh).Hash -eq (Get-FileHash -LiteralPath $compose).Hash) { Remove-Item -LiteralPath $fresh; return }
    $kept = "docker-compose.yml.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
    Move-Item -LiteralPath $compose -Destination (Join-Path $InstallDir $kept)
    Move-Item -LiteralPath $fresh -Destination $compose
    Write-Host "docker-compose.yml changed in this release; your previous copy is $kept"
  }

  # upgrade / uninstall act on an existing installation: INSTALL_DIR when it exists, else the folder
  # this script was started from (the installer leaves a copy of itself there).
  function Resolve-Installation {
    if (Test-Path -LiteralPath $InstallDir) { return }
    if ($ScriptDir -and (Test-Path -LiteralPath (Join-Path $ScriptDir 'docker-compose.yml'))) { Set-Variable -Name InstallDir -Value $ScriptDir -Scope 1; return }
    throw 'Run this from the installation folder (or set INSTALL_DIR).'
  }

  switch ($Command) {
    'install' {
      Assert-Docker
      Say "Installing into $InstallDir"
      New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
      Get-InstallFile 'docker-compose.yml'
      Get-InstallFile '.env.example'
      Get-InstallFile 'install.ps1'

      $envPath = Join-Path $InstallDir '.env'
      if (-not (Test-Path -LiteralPath $envPath)) {
        Write-Text $envPath (Read-Text (Join-Path $InstallDir '.env.example'))
        Set-EnvLine 'POSTGRES_PASSWORD' (New-Password)
        $address = Get-LanIp
        if (-not $address) { $address = 'localhost' }
        $port = '8080'
        if ($env:WEB_PORT -and (Test-Port $env:WEB_PORT)) { $port = $env:WEB_PORT }
        # With no console at all (a provisioning tool, -NonInteractive) Read-Host throws and the
        # defaults stand; both are in .env.
        try {
          Write-Host ''
          Write-Host 'Which address will people use to open Recon Essentials?'
          Write-Host '  - the IP address or host name of this computer, so other computers can reach it'
          Write-Host '  - localhost, if you will only use it on this computer'
          while ($true) {
            $answer = Read-Host "Address [$address]"
            if (-not $answer -or -not $answer.Trim()) { break }
            $split = Split-Address $answer
            if (Test-HostName $split.Address) {
              $address = $split.Address
              if (Test-Port $split.Port) { $port = $split.Port }
              break
            }
            Write-Host '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local, localhost'
          }
          while ($true) {
            $answer = Read-Host "Port [$port]"
            if (-not $answer -or -not $answer.Trim()) { break }
            if (Test-Port $answer.Trim()) { $port = $answer.Trim(); break }
            Write-Host '  The port is a number from 1 to 65535.'
          }
        }
        catch { }
        # APP_URL is always built here, never copied from the answer, and WEB_PORT follows it: the
        # published port and the address in APP_URL must be the same port.
        $appUrl = "http://${address}:$port"
        Set-EnvLine 'APP_URL' $appUrl
        Set-EnvLine 'WEB_PORT' $port
        if ($Version -ne 'latest') { Set-EnvLine 'RECON_VERSION' $Version }
        Write-Host "created .env (database password generated; APP_URL=$appUrl)"
      }
      else {
        Write-Host 'keeping the existing .env'
      }

      Push-Location -LiteralPath $InstallDir
      try {
        Say 'Pulling images'
        Invoke-Docker compose pull
        Say 'Starting (database -> migrator -> engine bootstrap -> web + engine)'
        Invoke-Docker compose up -d

        $appUrl = ([regex]::Match((Read-Text $envPath), '(?m)^APP_URL=(.*)$')).Groups[1].Value.Trim()
        Say 'Waiting for the web UI'
        $healthy = $false
        for ($i = 0; $i -lt 60; $i++) {
          $previous = $ErrorActionPreference
          $ErrorActionPreference = 'Continue'
          $status = (& docker compose ps --format '{{.Service}} {{.Health}}' web 2>$null) -join "`n"
          $ErrorActionPreference = $previous
          # "healthy" as a whole word, so "unhealthy" does not pass.
          if ($status -match '(^|\s)healthy(\s|$)') { $healthy = $true; break }
          Start-Sleep -Seconds 3
        }
        if (-not $healthy) {
          throw "The web UI did not report healthy within 3 minutes. Check: docker compose ps   then: docker compose logs web-migrator web   (in $InstallDir)"
        }
        Write-Host ''
        Write-Host "OK  Recon Essentials is up. Open $appUrl/setup to create the first administrator."
        Write-Host "    Installed in $InstallDir"
        Write-Host '    Logs: docker compose logs -f     Upgrade: powershell -ExecutionPolicy Bypass -File install.ps1 upgrade'
      }
      finally { Pop-Location }
    }

    'upgrade' {
      Assert-Docker
      Resolve-Installation
      if (-not ((Test-Path -LiteralPath (Join-Path $InstallDir 'docker-compose.yml')) -and (Test-Path -LiteralPath (Join-Path $InstallDir '.env')))) {
        throw 'No docker-compose.yml and .env here - is this the installation folder?'
      }
      Push-Location -LiteralPath $InstallDir
      try {
        Say 'Moving to the release'
        Set-Release
        Update-Compose
        Say 'Pulling images'
        Invoke-Docker compose pull
        Say 'Restarting - the migrator upgrades the database schema before the web starts'
        Invoke-Docker compose up -d
        Write-Host ''
        Write-Host 'OK  Upgraded. Check: docker compose ps'
      }
      finally { Pop-Location }
    }

    'uninstall' {
      Assert-Docker
      Resolve-Installation
      Push-Location -LiteralPath $InstallDir
      try {
        if ($env:PURGE -eq '1') {
          Say 'Removing containers AND data volumes (PURGE=1)'
          Invoke-Docker compose down -v --remove-orphans
        }
        else {
          Say 'Removing containers; data volumes are kept (set PURGE=1 to delete them)'
          Invoke-Docker compose down --remove-orphans
        }
      }
      finally { Pop-Location }
    }

    default { throw 'usage: install.ps1 [install|upgrade|uninstall]' }
  }
}

$reconExitCode = 0
try {
  & $reconBody $Command $reconScriptDir
}
catch {
  Write-Host ''
  Write-Host "x $($_.Exception.Message)" -ForegroundColor Red
  $reconExitCode = 1
}
if ($PSCommandPath) { exit $reconExitCode }
Remove-Variable -Name reconBody, reconScriptDir, reconExitCode -ErrorAction SilentlyContinue
