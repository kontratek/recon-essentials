# Vulmon Recon Essentials - installer / upgrader for Windows (PowerShell).
#
#   irm https://raw.githubusercontent.com/kontratek/recon-essentials/main/install.ps1 | iex
#
# In the installation folder (the installer leaves a copy of itself there):
#   powershell -ExecutionPolicy Bypass -File install.ps1 upgrade               # move to the current release and restart (data is kept)
#   powershell -ExecutionPolicy Bypass -File install.ps1 upgrade -Version 1.2.0
#   powershell -ExecutionPolicy Bypass -File install.ps1 address               # change the address or the port people open
#   powershell -ExecutionPolicy Bypass -File install.ps1 uninstall             # stop and remove the containers; the data is kept
#   powershell -ExecutionPolicy Bypass -File install.ps1 uninstall -Purge      # ... and delete the data
#
# The Windows twin of install.sh: the same steps, the same files and the same .env. It needs Docker
# Desktop running Linux containers (Docker Compose v2 ships with it). What it does: checks Docker,
# creates .\recon-essentials (or INSTALL_DIR), fetches docker-compose.yml + .env.example (and both
# installers, for later upgrades), generates the database password, asks which address and port
# people will use to open it, pulls the images and starts everything. It writes nothing outside
# that folder, where it also leaves "Open Recon Essentials.cmd" to double-click.
#
# Without a console (a provisioning tool) give the answers in advance: -Address / -Port, or
# $env:RECON_ADDRESS / $env:RECON_PORT; $env:RECON_NONINTERACTIVE = '1' accepts the defaults. -Version (or $env:RECON_VERSION) pins a release instead of
# the current one. Parameters are preferred to environment variables: a variable set in a window
# stays set for every later command in it, and a forgotten PURGE deletes data.
#
# Two rules this file keeps, both about Windows PowerShell 5.1:
#   - ASCII only. 5.1 reads a script FILE without a byte-order mark in the ANSI code page, so a
#     single typographic character would garble the messages or break the parse.
#   - No `exit` except the final guard, and only when run as a file. Under `irm | iex` this text
#     runs inside the caller's own session, where `exit` would close their window.

param(
  [string]$Command = 'install',
  [switch]$Purge,
  [string]$Version = '',
  [string]$Address = '',
  [string]$Port = ''
)

$reconScriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
$reconOptions = @{
  Purge = ($Purge.IsPresent -or $env:PURGE -eq '1')
  Version = $(if ($Version) { $Version } elseif ($env:RECON_VERSION) { $env:RECON_VERSION } else { 'latest' })
  Address = $(if ($Address) { $Address } else { [string]$env:RECON_ADDRESS })
  Port = $(if ($Port) { $Port } else { [string]$env:RECON_PORT })
}

# Everything below runs in a child scope: under `irm | iex` a preference or a function set at the
# top level would stay behind in the caller's session.
$reconBody = {
  param([string]$Command, [string]$ScriptDir, [hashtable]$Options)

  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar slows 5.1 downloads to a crawl
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  $RepoRaw = if ($env:RECON_DIST_URL) { $env:RECON_DIST_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/kontratek/recon-essentials/main' }
  $InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path (Get-Location).Path 'recon-essentials' }
  $Project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { 'recon-essentials' }
  $Version = $Options.Version
  if ($Version -ne 'latest' -and $Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "The release must be a number such as 1.0.0 (got $Version)"
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

  # Output of a native command as text, '' when it fails, with the same relaxed preference.
  function Read-Native([scriptblock]$Block) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Block 2>$null) -join "`n") } catch { return '' } finally { $ErrorActionPreference = $previous }
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
    if (-not (Test-Native { docker info })) {
      # Docker Desktop can stay open with its engine gone ("Internal Server Error"), which reads as
      # "Docker is running" to the person at the keyboard (2026-10-05) - so the message says which.
      if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
        throw 'Docker Desktop is open, but its engine does not answer. Restart it: right-click the Docker icon in the taskbar -> Quit Docker Desktop, start Docker Desktop again, wait until it shows that the engine is running, then run this again.'
      }
      throw 'Docker Desktop is not running. Start Docker Desktop, wait until it shows that the engine is running, then run this again.'
    }
    if ((Read-Native { docker info --format '{{.OSType}}' }).Trim() -ne 'linux') {
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

  # Replaces one of OUR files (an installer) with the current one. Best effort: an upgrade never
  # fails because an installer could not be refreshed.
  function Update-InstallFile([string]$Name) {
    $target = Join-Path $InstallDir $Name
    try { Get-DistFile $Name "$target.new"; Move-Item -LiteralPath "$target.new" -Destination $target -Force }
    catch { Remove-Item -LiteralPath "$target.new" -ErrorAction SilentlyContinue }
  }

  function Get-EnvValue([string]$Key) {
    $match = [regex]::Match((Read-Text (Join-Path $InstallDir '.env')), "(?m)^$([regex]::Escape($Key))=(.*)$")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
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

  # The address of the adapter that holds the default route, '' when there is none: a hint in the
  # address question, never the default (the default is localhost).
  function Get-LanIp {
    try {
      $config = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
      if ($config) { return [string](($config.IPv4Address | Select-Object -First 1).IPAddress) }
    }
    catch { }
    return ''
  }

  # Asks for the address and the port, or takes -Address / -Port (RECON_ADDRESS / RECON_PORT).
  # Enter keeps the current value - on a new installation localhost, which means only this computer
  # can open it (founder, 2026-10-05).
  function Request-Address([string]$CurrentAddress, [string]$CurrentPort) {
    $answer = @{ Address = $CurrentAddress; Port = $CurrentPort }
    if ($Options.Address -or $Options.Port) {
      if ($Options.Address) {
        $split = Split-Address $Options.Address
        if (-not (Test-HostName $split.Address)) { throw "The address must be an IP address or a host name (got $($Options.Address))." }
        $answer.Address = $split.Address
        if (Test-Port $split.Port) { $answer.Port = $split.Port }
      }
      if ($Options.Port) {
        if (-not (Test-Port $Options.Port)) { throw "The port must be a number from 1 to 65535 (got $($Options.Port))." }
        $answer.Port = $Options.Port
      }
      return $answer
    }
    # With no console at all (-NonInteractive, a provisioning tool) Read-Host throws and the
    # current values stand; RECON_NONINTERACTIVE=1 skips the questions on purpose.
    if ($env:RECON_NONINTERACTIVE -eq '1') { return $answer }
    try {
      $hint = Get-LanIp
      Write-Host ''
      Write-Host 'Which address will people type in the browser to open Recon Essentials?'
      if ($answer.Address -eq 'localhost') { Write-Host '  - Press Enter to keep localhost. Then only this computer can open it.' }
      else { Write-Host "  - Press Enter to keep $($answer.Address)." }
      Write-Host "  - Type this computer's IP address or host name to open it from other computers too."
      if ($hint) { Write-Host "    This computer's IP address appears to be $hint." }
      Write-Host '  Invitation and password-reset links use this address, so a fixed IP address or a host name works best.'
      while ($true) {
        $typed = Read-Host "Address [$($answer.Address)]"
        if (-not $typed -or -not $typed.Trim()) { break }
        $split = Split-Address $typed
        if (Test-HostName $split.Address) {
          $answer.Address = $split.Address
          if (Test-Port $split.Port) { $answer.Port = $split.Port }
          break
        }
        Write-Host '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local, localhost'
      }
      while ($true) {
        $typed = Read-Host "Port [$($answer.Port)]"
        if (-not $typed -or -not $typed.Trim()) { break }
        if (Test-Port $typed.Trim()) { $answer.Port = $typed.Trim(); break }
        Write-Host '  The port is a number from 1 to 65535.'
      }
    }
    catch { }
    return $answer
  }

  # APP_URL is always built here, never copied from an answer, and WEB_PORT follows it: the
  # published port and the port in APP_URL must be the same port.
  function Write-Address([string]$Address, [string]$Port) {
    $appUrl = "http://${Address}:$Port"
    Set-EnvLine 'APP_URL' $appUrl
    Set-EnvLine 'WEB_PORT' $Port
    return $appUrl
  }

  # A second folder must never take over an installation that exists: the data lives in Docker
  # volumes named after the compose project, and a new .env would bring a new database password to
  # an old database. The database refuses it, and the first installation's containers are recreated
  # with the wrong settings (2026-10-05). Runs before anything is written.
  function Assert-NoOtherInstallation {
    if (-not (Test-Native { docker volume inspect "${Project}_pgdata" })) { return }
    $folder = ''
    $listing = Read-Native { docker compose ls -a --format json }
    if ($listing) {
      try {
        # 5.1's ConvertFrom-Json emits a JSON array as ONE object; ForEach-Object unrolls it.
        $entry = @(($listing | ConvertFrom-Json) | ForEach-Object { $_ }) | Where-Object { $_.Name -eq $Project } | Select-Object -First 1
        # The folder by text, not Split-Path: on another platform Split-Path would not split a
        # Windows path, and this guard is tested on Linux too.
        if ($entry -and $entry.ConfigFiles) { $folder = (($entry.ConfigFiles -split ',')[0]) -replace '[\\/][^\\/]*$', '' }
      }
      catch { }
    }
    if ($folder) {
      throw ("Recon Essentials is already installed on this computer, in $folder`n" +
        "  To start it:  cd '$folder'; docker compose up -d`n" +
        "  To install a second, separate copy, give it its own name and port:`n" +
        "    `$env:COMPOSE_PROJECT_NAME = 'recon-essentials-2'; `$env:RECON_PORT = '8081'; irm $RepoRaw/install.ps1 | iex")
    }
    throw ("Data of an earlier Recon Essentials installation is still on this computer (Docker volume ${Project}_pgdata).`n" +
      "  Run this again in that installation's folder: its .env holds the database password for that data.`n" +
      "  To start over and DELETE that data: docker volume rm ${Project}_pgdata ${Project}_webdata ${Project}_media ${Project}_weblogs ${Project}_enginelogs")
  }

  # The file to double-click: starts Recon Essentials if it is stopped, then opens it in the browser.
  # It reads the address from .env each time, so changing the address never leaves it behind. CRLF:
  # cmd.exe can miss a label in a batch file with LF line endings.
  function New-Opener {
    $lines = @(
      '@echo off',
      'rem Starts Recon Essentials if it is stopped, then opens it in the browser.',
      'setlocal',
      'cd /d "%~dp0"',
      'docker compose up -d >nul 2>&1',
      'if errorlevel 1 (',
      '  echo Recon Essentials did not start. Is Docker Desktop running?',
      '  pause',
      '  exit /b 1',
      ')',
      'for /f "usebackq tokens=1,* delims==" %%a in (".env") do if "%%a"=="APP_URL" set "APP_URL=%%b"',
      'set /a tries=0',
      ':wait',
      'docker compose ps --format "{{.Service}} {{.Health}}" web 2>nul | findstr /x /c:"web healthy" >nul && goto open',
      'set /a tries+=1',
      'if %tries% geq 60 goto open',
      'timeout /t 2 /nobreak >nul',
      'goto wait',
      ':open',
      'start "" "%APP_URL%"'
    )
    Write-Text (Join-Path $InstallDir 'Open Recon Essentials.cmd') (($lines -join "`r`n") + "`r`n")
  }

  # .env pins the release an installation runs (RECON_VERSION - both images take it), so pulling
  # alone would fetch the same release again. Upgrading moves that one line: to -Version when it
  # is given, otherwise to the release the distribution repository names now.
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

  # A release can add a setting. .env keeps every value the customer has; a key the current
  # .env.example has and .env lacks is added with the example's value (2026-10-05).
  function Add-NewSettings {
    try { $example = [string](Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/.env.example").Content } catch { return }
    $path = Join-Path $InstallDir '.env'
    $text = Read-Text $path
    $added = @()
    foreach ($line in ($example -split "`r?`n")) {
      if ($line -notmatch '^([A-Z_][A-Z0-9_]*)=') { continue }
      $key = $Matches[1]
      if ([regex]::IsMatch($text, "(?m)^$([regex]::Escape($key))=")) { continue }
      if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
      $text += "$line`n"
      $added += $key
    }
    if ($added.Count -gt 0) { Write-Text $path $text; foreach ($key in $added) { Write-Host "added $key to .env" } }
  }

  # A release can change the compose file as well. The current one replaces the local copy and the
  # old copy stays beside it, so a hand edit is never lost silently. Skipped for a pinned release,
  # because the repository's compose file belongs to the current release.
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

  # upgrade / address / uninstall act on an existing installation: INSTALL_DIR when it exists, else
  # the folder this script was started from (the installer leaves a copy of itself there).
  function Resolve-Installation {
    if (-not (Test-Path -LiteralPath $InstallDir) -and $ScriptDir -and (Test-Path -LiteralPath (Join-Path $ScriptDir 'docker-compose.yml'))) {
      Set-Variable -Name InstallDir -Value $ScriptDir -Scope 1
    }
    if (-not ((Test-Path -LiteralPath (Join-Path $InstallDir 'docker-compose.yml')) -and (Test-Path -LiteralPath (Join-Path $InstallDir '.env')))) {
      throw 'Run this in the installation folder (or set INSTALL_DIR): no docker-compose.yml and .env here.'
    }
  }

  function Wait-Healthy {
    for ($i = 0; $i -lt 60; $i++) {
      # "healthy" as a whole word, so "unhealthy" does not pass.
      if ((Read-Native { docker compose ps --format '{{.Service}} {{.Health}}' web }) -match '(^|\s)healthy(\s|$)') { return $true }
      Start-Sleep -Seconds 3
    }
    return $false
  }

  switch ($Command) {
    'install' {
      Assert-Docker
      $envPath = Join-Path $InstallDir '.env'
      if (-not (Test-Path -LiteralPath $envPath)) { Assert-NoOtherInstallation }
      Say "Installing into $InstallDir"
      New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
      Get-InstallFile 'docker-compose.yml'
      Get-InstallFile '.env.example'
      Get-InstallFile 'install.ps1'
      Get-InstallFile 'install.sh'

      if (-not (Test-Path -LiteralPath $envPath)) {
        # The answers come first: a wrong -Address must not leave a half-written .env behind,
        # which the next run would keep.
        $defaultPort = '8080'
        if ($env:WEB_PORT -and (Test-Port $env:WEB_PORT)) { $defaultPort = $env:WEB_PORT }
        $answer = Request-Address 'localhost' $defaultPort
        Write-Text $envPath (Read-Text (Join-Path $InstallDir '.env.example'))
        Set-EnvLine 'POSTGRES_PASSWORD' (New-Password)
        $appUrl = Write-Address $answer.Address $answer.Port
        # The folder owns its project name, so every later `docker compose` in it reaches these
        # containers and volumes, whatever the shell's environment says.
        Set-EnvLine 'COMPOSE_PROJECT_NAME' $Project
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
        New-Opener

        $appUrl = Get-EnvValue 'APP_URL'
        Say 'Waiting for the web UI'
        if (-not (Wait-Healthy)) {
          throw "The web UI did not report healthy within 3 minutes. In $InstallDir check: docker compose ps   then: docker compose logs web-migrator web"
        }
        Write-Host ''
        Write-Host "OK  Recon Essentials is up. Open $appUrl/setup to create the first administrator."
        Write-Host "    Installed in $InstallDir"
        Write-Host '    It starts again on its own whenever Docker Desktop starts. To open it later, double-click'
        Write-Host '    "Open Recon Essentials.cmd" in that folder. In that folder:'
        Write-Host '      docker compose stop                                               stop it'
        Write-Host '      docker compose up -d                                              start it again'
        Write-Host '      powershell -ExecutionPolicy Bypass -File install.ps1 upgrade      move to a new release'
        Write-Host '      powershell -ExecutionPolicy Bypass -File install.ps1 address      change the address or the port'
      }
      finally { Pop-Location }
    }

    'upgrade' {
      Assert-Docker
      Resolve-Installation
      Push-Location -LiteralPath $InstallDir
      try {
        Say 'Moving to the release'
        Set-Release
        Update-Compose
        Add-NewSettings
        # The installers themselves, so the next upgrade runs the current ones.
        Update-InstallFile 'install.ps1'
        Update-InstallFile 'install.sh'
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Open Recon Essentials.cmd'))) { New-Opener }
        Say 'Pulling images'
        Invoke-Docker compose pull
        Say 'Restarting - the migrator upgrades the database schema before the web starts'
        Invoke-Docker compose up -d
        Write-Host ''
        Write-Host 'OK  Upgraded. Check: docker compose ps'
      }
      finally { Pop-Location }
    }

    'address' {
      Assert-Docker
      Resolve-Installation
      $current = Get-EnvValue 'APP_URL'
      if ($current -match '^https://') {
        throw "APP_URL is an https address ($current), so a reverse proxy serves this installation. Change APP_URL in .env by hand, then run: docker compose up -d"
      }
      $split = Split-Address $current
      $currentAddress = if (Test-HostName $split.Address) { $split.Address } else { 'localhost' }
      $currentPort = Get-EnvValue 'WEB_PORT'
      if (-not (Test-Port $currentPort)) { $currentPort = '8080' }
      $answer = Request-Address $currentAddress $currentPort
      $appUrl = Write-Address $answer.Address $answer.Port
      Push-Location -LiteralPath $InstallDir
      try {
        Say 'Restarting the web with the new address'
        Invoke-Docker compose up -d
        Write-Host ''
        Write-Host "OK  Recon Essentials now opens at $appUrl"
      }
      finally { Pop-Location }
    }

    'uninstall' {
      Assert-Docker
      Resolve-Installation
      Push-Location -LiteralPath $InstallDir
      try {
        if ($Options.Purge) {
          Say 'Removing containers AND data volumes (-Purge)'
          Invoke-Docker compose down -v --remove-orphans
        }
        else {
          Say 'Removing containers; data volumes are kept (add -Purge to delete them)'
          Invoke-Docker compose down --remove-orphans
        }
      }
      finally { Pop-Location }
    }

    default { throw 'usage: install.ps1 [install|upgrade|address|uninstall] [-Version x.y.z] [-Address host] [-Port n] [-Purge]' }
  }
}

$reconExitCode = 0
try {
  & $reconBody $Command $reconScriptDir $reconOptions
}
catch {
  Write-Host ''
  Write-Host "x $($_.Exception.Message)" -ForegroundColor Red
  $reconExitCode = 1
}
if ($PSCommandPath) { exit $reconExitCode }
Remove-Variable -Name reconBody, reconScriptDir, reconOptions, reconExitCode -ErrorAction SilentlyContinue
