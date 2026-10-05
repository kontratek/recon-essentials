# Vulmon Recon Essentials - install it, or start it when it is installed (Windows PowerShell).
#
#   irm https://raw.githubusercontent.com/kontratek/recon-essentials/main/recon-essentials.ps1 | iex
#
# Run it in the folder where the installation should go: it creates a recon-essentials folder there
# (INSTALL_DIR chooses another; in a system or temporary folder it uses the home folder instead),
# fetches docker-compose.yml + .env.example and both scripts, generates the database password, asks
# one question - who will use it - and takes port 8080, or the next free one when 8080 is in use.
# It writes nothing outside that folder, where it also leaves recon-essentials.cmd: that file starts
# Recon Essentials later (double-click it) and takes the same commands. It never upgrades without
# asking and never deletes data, so it is safe to run whenever Recon Essentials does not open:
#   .\recon-essentials.cmd                       start it and open it in the browser
#   .\recon-essentials.cmd stop                  stop it
#   .\recon-essentials.cmd upgrade               move to the current release (data is kept)
#   .\recon-essentials.cmd upgrade -Version 1.2.0
#   .\recon-essentials.cmd address               change who can open it, or the address
#   .\recon-essentials.cmd uninstall             remove the containers; the data is kept
#   .\recon-essentials.cmd uninstall -Purge      ... and delete the data
#
# The Windows twin of recon-essentials.sh: the same steps, the same files and the same .env. It needs
# Docker Desktop running Linux containers (Docker Compose v2 ships with it) and starts Docker Desktop
# when it is closed. The install command does the same as the first line when it runs in the
# installation folder (or the one above it), or anywhere while Docker knows the installation.
#
# Without a console (a provisioning tool) give the answer in advance: -Address / -Port, or
# $env:RECON_ADDRESS / $env:RECON_PORT; $env:RECON_NONINTERACTIVE = '1' accepts the defaults. -Version
# (or $env:RECON_VERSION) pins a release. Parameters are preferred to environment variables: a
# variable set in a window stays set for every later command in it, and a forgotten PURGE deletes data.
#
# Two rules this file keeps, both about Windows PowerShell 5.1:
#   - ASCII only. 5.1 reads a script FILE without a byte-order mark in the ANSI code page, so a
#     single typographic character would garble the messages or break the parse.
#   - No `exit` except the final guard, and only when run as a file. Under `irm | iex` this text
#     runs inside the caller's own session, where `exit` would close their window.

param(
  [string]$Command = 'run',
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
  $ScriptName = 'recon-essentials.ps1'
  $Project = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { 'recon-essentials' }
  if ($Project -cnotmatch '^[a-z0-9][a-z0-9_-]*$') { throw "COMPOSE_PROJECT_NAME may hold only lowercase letters, digits, - and _ (got $Project)." }
  $Version = $Options.Version
  if ($Version -ne 'latest' -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw "The release must be a number such as 1.0.0 (got $Version)" }
  $HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { (Get-Location).Path }
  $DockerDesktopExe = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe' } else { '' }
  $InstallDir = ''
  $UpgradeCommand = '.\recon-essentials.cmd upgrade'
  $TargetNote = ''

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

  # Every compose call names the project: a COMPOSE_PROJECT_NAME left in the window would otherwise
  # win over the one in the installation's .env and point the call at another installation.
  function Invoke-Compose { Invoke-Docker compose -p $Project @args }

  # A person at the console can be asked; a provisioning tool, a -NonInteractive session, redirected
  # input or RECON_NONINTERACTIVE=1 cannot.
  function Test-CanAsk {
    if ($env:RECON_NONINTERACTIVE -eq '1') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    return $true
  }

  # ------------------------------------------------------------------------------------------ docker

  function Test-DockerAnswers { return (Test-Native { docker info }) }

  function Wait-Docker {
    for ($waited = 0; $waited -lt 180; $waited += 3) {
      if (Test-DockerAnswers) { return $true }
      Start-Sleep -Seconds 3
    }
    return $false
  }

  function Test-DesktopRunning { return [bool](Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) }
  function Start-DockerDesktop { Start-Process -FilePath $DockerDesktopExe }

  # What brought back a Docker Desktop whose engine had stopped answering (2026-10-02): every Docker
  # process stopped, then only Docker Desktop's own WSL distributions. `wsl --shutdown` would stop
  # every other distribution too.
  function Restart-DockerDesktop {
    foreach ($name in @('Docker Desktop', 'com.docker.backend', 'com.docker.build', 'com.docker.extensions', 'com.docker.dev-envs', 'vpnkit')) {
      Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    foreach ($distribution in @('docker-desktop', 'docker-desktop-data')) { $null = Test-Native { wsl.exe --terminate $distribution } }
    Start-Sleep -Seconds 2
    Start-DockerDesktop
  }

  # Docker Desktop can stay open with its engine gone ("Internal Server Error"), which reads as
  # "Docker is running" to the person at the keyboard (2026-10-05). With a person there, a closed
  # Docker Desktop is started, and one that does not answer is restarted after asking. Otherwise
  # the message says which.
  function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      throw 'Docker is not installed. Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/'
    }
    if (-not (Test-Native { docker compose version })) { throw "Docker Compose v2 is required (the 'docker compose' command)." }
    if (-not (Test-DockerAnswers)) {
      $running = Test-DesktopRunning
      if ((Test-CanAsk) -and $DockerDesktopExe -and (Test-Path -LiteralPath $DockerDesktopExe)) {
        if (-not $running) {
          Say 'Starting Docker Desktop'
          Start-DockerDesktop
        }
        else {
          Write-Host ''
          Write-Host 'Docker Desktop is open, but its engine does not answer.'
          $typed = Read-Host 'Restart Docker Desktop now? Every container stops until it is back. [Y/n]'
          if ($typed -and $typed.Trim() -and $typed.Trim() -notmatch '^[Yy]') {
            throw 'Restart Docker Desktop yourself: right-click the Docker icon in the taskbar -> Quit Docker Desktop, start it again, wait until the engine runs, then run this again.'
          }
          Say 'Restarting Docker Desktop'
          Restart-DockerDesktop
        }
        Write-Host 'waiting for the Docker engine (up to 3 minutes)'
        if (-not (Wait-Docker)) { throw 'Docker Desktop did not answer within 3 minutes. Wait until it shows that the engine is running, then run this again.' }
      }
      elseif ($running) {
        throw 'Docker Desktop is open, but its engine does not answer. Restart it: right-click the Docker icon in the taskbar -> Quit Docker Desktop, start Docker Desktop again, wait until it shows that the engine is running, then run this again.'
      }
      else {
        throw 'Docker Desktop is not running. Start Docker Desktop, wait until it shows that the engine is running, then run this again.'
      }
    }
    if ((Read-Native { docker info --format '{{.OSType}}' }).Trim() -ne 'linux') {
      throw 'Docker Desktop is running Windows containers. Switch it to Linux containers (Docker icon in the taskbar -> Switch to Linux containers) and run this again.'
    }
  }

  function Wait-Healthy {
    for ($i = 0; $i -lt 60; $i++) {
      # "healthy" as a whole word, so "unhealthy" does not pass.
      if ((Read-Native { docker compose -p $Project ps --format '{{.Service}} {{.Health}}' web }) -match '(^|\s)healthy(\s|$)') { return $true }
      Start-Sleep -Seconds 3
    }
    return $false
  }

  # ------------------------------------------------------------------------------------------- files

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

  # Replaces one of OUR files (a script) with the current one. Best effort: an upgrade never fails
  # because a script could not be refreshed.
  function Update-InstallFile([string]$Name) {
    $target = Join-Path $InstallDir $Name
    try { Get-DistFile $Name "$target.new"; Move-Item -LiteralPath "$target.new" -Destination $target -Force }
    catch { Remove-Item -LiteralPath "$target.new" -ErrorAction SilentlyContinue }
  }

  function Test-EnvLine([string]$Key) {
    return [regex]::IsMatch((Read-Text (Join-Path $InstallDir '.env')), "(?m)^$([regex]::Escape($Key))=")
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

  # ------------------------------------------------------------------------------ who opens it, where

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
  function Test-LocalHost([string]$Name) { return ($Name -eq 'localhost' -or $Name -eq '127.0.0.1') }

  # The address of the adapter that holds the default route, '' when there is none: the suggestion
  # when other computers should open it.
  function Get-LanIp {
    try {
      $config = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
      if ($config) { return [string](($config.IPv4Address | Select-Object -First 1).IPAddress) }
    }
    catch { }
    return ''
  }

  # Something on this computer already listens on that port: another program, or another container.
  function Test-PortInUse([int]$Number) {
    try { return [bool]([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Number }) }
    catch { return $false }
  }

  # "Who will use it?" Only this computer (the default) is localhost, and the port then listens on
  # 127.0.0.1 alone, so nothing else on the network can reach it. Other computers too is the address
  # they will type. -Address answers in advance (founder, 2026-10-05). Returns the host, and a port
  # when one was typed with the address.
  function Request-Access([string]$CurrentHost) {
    $answer = @{ Host = $CurrentHost; Port = '' }
    if ($Options.Address) {
      $split = Split-Address $Options.Address
      if (-not (Test-HostName $split.Address)) { throw "The address must be an IP address or a host name (got $($Options.Address))." }
      $answer.Host = $split.Address
      if (Test-Port $split.Port) { $answer.Port = $split.Port }
      return $answer
    }
    if (-not (Test-CanAsk)) { return $answer }
    try {
      Write-Host ''
      Write-Host 'Who will use Recon Essentials?'
      Write-Host '  1  Only this computer (local access: the port listens on 127.0.0.1)'
      Write-Host '  2  Other computers on the network too (remote access: the port listens on 0.0.0.0)'
      $default = if (Test-LocalHost $CurrentHost) { '1' } else { '2' }
      while ($true) {
        $typed = Read-Host "Choose 1 or 2 [$default]"
        $choice = if ($typed -and $typed.Trim()) { $typed.Trim() } else { $default }
        if ($choice -eq '1') { $answer.Host = 'localhost'; return $answer }
        if ($choice -eq '2') { break }
        Write-Host '  Type 1 or 2.'
      }
      $suggestion = if (Test-LocalHost $CurrentHost) { Get-LanIp } else { $CurrentHost }
      Write-Host ''
      Write-Host "Which address will the other computers open? Type this computer's IP address or host name, for example 192.168.1.20 or recon.example.local."
      Write-Host '  Invitation and password-reset links use it, so a fixed IP address or a host name works best.'
      while ($true) {
        $prompt = if ($suggestion) { "Address [$suggestion]" } else { 'Address' }
        $typed = Read-Host $prompt
        $value = if ($typed -and $typed.Trim()) { $typed } else { $suggestion }
        if ($value) {
          $split = Split-Address $value
          if (Test-HostName $split.Address) {
            $answer.Host = $split.Address
            if (Test-Port $split.Port) { $answer.Port = $split.Port }
            return $answer
          }
        }
        Write-Host '  That is not an IP address or a host name. Examples: 192.168.1.20, recon.example.local'
      }
    }
    catch { }
    return @{ Host = $CurrentHost; Port = '' }
  }

  # Port 8080, or the next free one when 8080 is in use; -Port (or a port typed with the address)
  # chooses it outright.
  function Select-Port([string]$Wanted) {
    if ($Wanted) {
      if (-not (Test-Port $Wanted)) { throw "The port must be a number from 1 to 65535 (got $Wanted)." }
      if (Test-PortInUse ([int]$Wanted)) { throw "Port $Wanted is in use on this computer. Choose another with -Port and run this again." }
      return $Wanted
    }
    for ($number = 8080; $number -le 8099; $number++) {
      if (-not (Test-PortInUse $number)) {
        if ($number -ne 8080) { Write-Host "port 8080 is in use on this computer; using $number" }
        return [string]$number
      }
    }
    throw 'Ports 8080 to 8099 are all in use on this computer. Choose one with -Port and run this again.'
  }

  # APP_URL is always built here, never copied from an answer. WEB_PORT is the same port, and
  # WEB_BIND keeps "only this computer" true: the compose file publishes the port on that address.
  function Write-Access([string]$HostName, [string]$PortNumber) {
    $appUrl = "http://${HostName}:$PortNumber"
    Set-EnvLine 'APP_URL' $appUrl
    Set-EnvLine 'WEB_PORT' $PortNumber
    if (Test-LocalHost $HostName) { Set-EnvLine 'WEB_BIND' '127.0.0.1' } else { Set-EnvLine 'WEB_BIND' '0.0.0.0' }
    return $appUrl
  }

  function Open-Browser([string]$Url) {
    if (-not (Test-CanAsk)) { return }
    try { Start-Process $Url } catch { }
  }

  # ------------------------------------------------------------------------------ which installation

  # A folder holds an installation when its .env belongs to Recon Essentials: OUR compose file next
  # to it (it names the recon-essentials images), or a release line in it when the compose file is
  # gone. Another project's docker-compose.yml + .env is never one - this script would run `up` in it.
  function Test-Installation([string]$Dir) {
    if (-not $Dir) { return $false }
    $envPath = Join-Path $Dir '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { return $false }
    $compose = Join-Path $Dir 'docker-compose.yml'
    if ((Test-Path -LiteralPath $compose -PathType Leaf) -and (Read-Text $compose).Contains('recon-essentials')) { return $true }
    return [regex]::IsMatch((Read-Text $envPath), '(?m)^RECON_VERSION=')
  }

  # A system or temporary folder never receives an installation: PowerShell run as administrator
  # starts in C:\Windows\System32, and a temporary folder gets cleaned - and with it .env, which
  # holds the database password for the data.
  function Test-UnsafeFolder([string]$Dir) {
    $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Dir)).TrimEnd('\', '/')
    if ($full -eq $root) { return $true }
    $system = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, [IO.Path]::GetTempPath())
    # Linux and macOS (pwsh): the same folders recon-essentials.sh refuses.
    if (-not $env:windir) { $system += @('/tmp', '/var/tmp', '/private/tmp', '/var/folders', '/private/var/folders', '/usr', '/bin', '/sbin', '/etc', '/proc', '/sys', '/dev', '/boot', '/System') }
    foreach ($folder in ($system | Where-Object { $_ })) {
      $prefix = [IO.Path]::GetFullPath($folder).TrimEnd('\', '/')
      if ($full -eq $prefix -or $full.StartsWith("$prefix\", [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
  }

  # The folder of the installation Docker knows under this project name (its containers exist,
  # running or not); '' when there is none.
  function Get-KnownFolder {
    $listing = Read-Native { docker compose ls -a --format json }
    if (-not $listing) { return '' }
    try {
      # 5.1's ConvertFrom-Json emits a JSON array as ONE object; ForEach-Object unrolls it.
      $entry = @(($listing | ConvertFrom-Json) | ForEach-Object { $_ }) | Where-Object { $_.Name -eq $Project } | Select-Object -First 1
      # The folder by text, not Split-Path: on another platform Split-Path would not split a
      # Windows path, and this is tested on Linux too.
      if ($entry -and $entry.ConfigFiles) { return ((($entry.ConfigFiles -split ',')[0]) -replace '[\\/][^\\/]*$', '') }
    }
    catch { }
    return ''
  }

  # Which installation this run is about: INSTALL_DIR; else the folder this script lives in; else
  # the current folder, or its recon-essentials folder; else the installation Docker knows (its
  # containers exist, running or not). Otherwise a new one goes into .\recon-essentials - the folder
  # the person chose by running the command there (founder, 2026-10-05) - or into the home folder
  # when the current one is a system or temporary folder ($TargetNote says so).
  function Resolve-Target {
    if ($env:INSTALL_DIR) { return $env:INSTALL_DIR }
    if (Test-Installation $ScriptDir) { return $ScriptDir }
    $here = (Get-Location -PSProvider FileSystem).Path
    if (Test-Installation $here) { return $here }
    $child = Join-Path $here $Project
    if (Test-Installation $child) { return $child }
    $known = Get-KnownFolder
    if ($known -and (Test-Path -LiteralPath (Join-Path $known '.env'))) { return $known }
    if (Test-UnsafeFolder $here) {
      $instead = Join-Path $HomeDir $Project
      Set-Variable -Name TargetNote -Value "$here is a system or temporary folder, so Recon Essentials goes into your home folder instead: $instead" -Scope 1
      return $instead
    }
    return $child
  }

  # Windows opens a .ps1 in Notepad on a double-click and refuses to run one under the default
  # execution policy, so the folder gets a .cmd that runs recon-essentials.ps1 with the same
  # arguments (double-click to start; `recon-essentials.cmd stop` and the rest work too). CRLF:
  # cmd.exe can misread a batch file with LF line endings. recon-essentials.sh writes the same bytes.
  function New-Launcher {
    $lines = @(
      '@echo off',
      'rem Recon Essentials: starts it and opens it, or runs a command: stop, upgrade, address, uninstall.',
      'rem It runs recon-essentials.ps1 next to it, whatever the execution policy of this computer is.',
      'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0recon-essentials.ps1" %*',
      'if errorlevel 1 pause'
    )
    Write-Text (Join-Path $InstallDir 'recon-essentials.cmd') (($lines -join "`r`n") + "`r`n")
  }

  function Get-VolumeList { return (@('pgdata', 'webdata', 'media', 'weblogs', 'enginelogs') | ForEach-Object { "${Project}_$_" }) -join ' ' }

  # A new installation must never take over the data of another one: the data lives in Docker
  # volumes named after the project, and a new .env would bring a new database password to an old
  # database. The database refuses it, and the first installation's containers are recreated with
  # the wrong settings (2026-10-05). Runs before anything is written.
  function Assert-NewInstall {
    if (-not (Test-Native { docker volume inspect "${Project}_pgdata" })) { return }
    $folder = Get-KnownFolder
    if ($folder -and (Test-Path -LiteralPath (Join-Path $folder '.env'))) {
      throw ("Recon Essentials is already installed on this computer, in $folder`n" +
        "  To start it, run recon-essentials.cmd in that folder.`n" +
        "  To install a second, separate copy, give it its own name:`n" +
        "    `$env:COMPOSE_PROJECT_NAME = 'recon-essentials-2'; irm $RepoRaw/$ScriptName | iex")
    }
    if ($folder) {
      throw ("The installation in $folder has lost its .env file, which holds the database password for its data.`n" +
        "  Put .env back from a backup, then run this again.`n" +
        "  To start over and DELETE that data: docker volume rm $(Get-VolumeList)")
    }
    throw ("Data of an earlier Recon Essentials installation is still on this computer (Docker volume ${Project}_pgdata).`n" +
      "  Start that installation from its folder: recon-essentials.cmd. Its .env holds the database password for the data.`n" +
      "  To start over and DELETE that data: docker volume rm $(Get-VolumeList)")
  }

  # ----------------------------------------------------------------------------------------- upgrade

  # A release can add a setting. .env keeps every value the customer has; a key the release's
  # .env.example has and .env lacks is added with the example's value (2026-10-05).
  function Add-NewSettings([string]$ExamplePath) {
    $path = Join-Path $InstallDir '.env'
    $text = Read-Text $path
    $added = @()
    foreach ($line in ((Read-Text $ExamplePath) -split "`r?`n")) {
      if ($line -notmatch '^([A-Z_][A-Z0-9_]*)=') { continue }
      $key = $Matches[1]
      if ([regex]::IsMatch($text, "(?m)^$([regex]::Escape($key))=")) { continue }
      if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
      $text += "$line`n"
      $added += $key
    }
    if ($added.Count -gt 0) { Write-Text $path $text; foreach ($key in $added) { Write-Host "added $key to .env" } }
  }

  # Moves the installation to -Version, or to the release the distribution repository names now
  # (every release pins its .env.example). Nothing changes on this computer until the new images
  # are here, so a failed download leaves the installed release as it was.
  function Invoke-Upgrade {
    $examplePath = Join-Path $InstallDir '.env.example'
    $composePath = Join-Path $InstallDir 'docker-compose.yml'
    $freshExample = "$examplePath.new"
    $freshCompose = "$composePath.new"
    Remove-Item -LiteralPath $freshExample, $freshCompose -ErrorAction SilentlyContinue
    try {
      Get-DistFile '.env.example' $freshExample
      $target = $Version
      if ($Version -eq 'latest') {
        $match = [regex]::Match((Read-Text $freshExample), '(?m)^RECON_VERSION=(\d+\.\d+\.\d+)')
        if (-not $match.Success) { throw "The .env.example at $RepoRaw names no release." }
        $target = $match.Groups[1].Value
      }
      # The current release's compose file, unless a pinned release keeps the one it has (the
      # repository's file belongs to the current release) - or the local one predates the release
      # line (it names no RECON_VERSION), which no release can run.
      $composeFile = 'docker-compose.yml'
      if ($Version -eq 'latest' -or -not (Read-Text $composePath).Contains('RECON_VERSION')) {
        Get-DistFile 'docker-compose.yml' $freshCompose
        $composeFile = 'docker-compose.yml.new'
      }
      Say "Downloading release $target"
      $previous = $env:RECON_VERSION
      $env:RECON_VERSION = $target
      try { Invoke-Docker compose -p $Project -f $composeFile pull }
      catch { throw "Could not download release $target. Nothing was changed." }
      finally { $env:RECON_VERSION = $previous }
    }
    catch {
      Remove-Item -LiteralPath $freshExample, $freshCompose -ErrorAction SilentlyContinue
      throw
    }
    Move-Item -LiteralPath $freshExample -Destination $examplePath -Force
    $kept = ''
    if (Test-Path -LiteralPath $freshCompose) {
      if ((Get-FileHash -LiteralPath $freshCompose).Hash -eq (Get-FileHash -LiteralPath $composePath).Hash) { Remove-Item -LiteralPath $freshCompose }
      else {
        $kept = "docker-compose.yml.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
        Move-Item -LiteralPath $composePath -Destination (Join-Path $InstallDir $kept)
        Move-Item -LiteralPath $freshCompose -Destination $composePath
      }
    }
    # An installation from before WEB_BIND published its port to the whole network. It keeps doing so.
    if (-not (Test-EnvLine 'WEB_BIND')) { Set-EnvLine 'WEB_BIND' '0.0.0.0' }
    Add-NewSettings $examplePath
    Set-EnvLine 'RECON_VERSION' $target
    # Before 0.1.2 each image had its own line. The release line replaces both, so an old pair can
    # never be left behind to override it.
    $envPath = Join-Path $InstallDir '.env'
    Write-Text $envPath ([regex]::Replace((Read-Text $envPath), '(?m)^(WEB_IMAGE|ENGINE_IMAGE)=.*(\r?\n)?', ''))
    Write-Host "release: $target"
    if ($kept) { Write-Host "docker-compose.yml changed in this release; your previous copy is $kept" }
    # The scripts themselves, so the next run uses the current ones - under the first release's
    # names too, while an installation still has them.
    Update-InstallFile 'recon-essentials.ps1'
    Update-InstallFile 'recon-essentials.sh'
    foreach ($old in @('install.ps1', 'install.sh')) { if (Test-Path -LiteralPath (Join-Path $InstallDir $old)) { Update-InstallFile $old } }
    New-Launcher
    Say 'Restarting - the migrator upgrades the database schema before the web starts'
    Invoke-Compose up -d
    if (-not (Wait-Healthy)) { throw 'The web UI did not report healthy within 3 minutes. Check: docker compose logs web-migrator web' }
    Write-Host ''
    Write-Host "OK  Upgraded to $target."
  }

  function Test-NewerRelease([string]$Candidate, [string]$Current) {
    try { return ([version]$Candidate -gt [version]$Current) } catch { return [bool]($Candidate -and -not $Current) }
  }

  # "latest|minimum", as the engine copied them from the signed manifest into app_meta, so asking
  # costs no connection beyond the ones the product makes anyway. minimum_engine_version is there
  # only while this engine is below the supported floor. The psql arguments carry no double quote:
  # Windows PowerShell 5.1 would pass it to docker unescaped.
  function Get-ReleaseStatus {
    $sql = "select coalesce(value->>'latest_version', '') || '|' || coalesce(value->>'minimum_engine_version', '') from app_meta where key = 'license_status';"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = ($sql | & docker compose -p $Project exec -T db sh -c 'psql -X -q -At -U $POSTGRES_USER -d $POSTGRES_DB' 2>$null) -join "`n" }
    catch { return '' }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($output -split "`n")[0]).Trim()
  }

  function Invoke-UpgradeOrGoOn {
    try { Invoke-Upgrade }
    catch {
      Write-Host "x $($_.Exception.Message)" -ForegroundColor Red
      Write-Host 'The upgrade did not finish; starting the installed release.'
    }
  }

  # Before it starts: a release below the supported floor is upgraded first, a newer one is offered.
  # Neither keeps the installed release from starting when the upgrade cannot finish: the founder's
  # rule (2026-10-02) is that an old engine is warned, never stopped.
  function Invoke-ReleaseCheck {
    $status = Get-ReleaseStatus
    if ($status -notmatch '\|') { return }
    $latest, $minimum = $status -split '\|', 2
    $current = Get-EnvValue 'RECON_VERSION'
    $shown = if ($current) { $current } else { 'an older release' }
    if ($minimum) {
      Say "Release $shown is no longer supported; upgrading before it starts"
      Invoke-UpgradeOrGoOn
      return
    }
    if (-not ($latest -and (Test-NewerRelease $latest $current))) { return }
    if (Test-CanAsk) {
      Write-Host ''
      $typed = Read-Host "Recon Essentials $latest is available; this installation runs $shown. Upgrade now? [Y/n]"
      if (-not $typed -or -not $typed.Trim() -or $typed.Trim() -match '^[Yy]') { Invoke-UpgradeOrGoOn }
      else { Write-Host "Upgrade later with: $UpgradeCommand (in $InstallDir)" }
    }
    else { Write-Host "Recon Essentials $latest is available (this installation runs $shown). Upgrade with: $UpgradeCommand (in $InstallDir)" }
  }

  # ---------------------------------------------------------------------------------------- commands

  function Write-Commands {
    Write-Host "    To start it later, or to stop or upgrade it, run in ${InstallDir}:"
    Write-Host '      .\recon-essentials.cmd            start it and open it (or double-click it)'
    Write-Host '      .\recon-essentials.cmd stop       stop it'
    Write-Host '      .\recon-essentials.cmd upgrade    move to a new release'
    Write-Host '      .\recon-essentials.cmd address    change who can open it'
  }

  function Install-New {
    Assert-NewInstall
    # The answers come first: a wrong -Address or -Port must not leave a half-written .env behind.
    $access = Request-Access 'localhost'
    $wanted = if ($Options.Port) { $Options.Port } else { $access.Port }
    $portNumber = Select-Port $wanted
    if ($TargetNote) { Write-Host $TargetNote }
    Say "Installing into $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Get-InstallFile 'docker-compose.yml'
    Get-InstallFile '.env.example'
    Get-InstallFile 'recon-essentials.ps1'
    Get-InstallFile 'recon-essentials.sh'
    New-Launcher
    $envPath = Join-Path $InstallDir '.env'
    Write-Text $envPath (Read-Text (Join-Path $InstallDir '.env.example'))
    Set-EnvLine 'POSTGRES_PASSWORD' (New-Password)
    $appUrl = Write-Access $access.Host $portNumber
    # The folder owns its project name, so a plain `docker compose` in it reaches these containers.
    Set-EnvLine 'COMPOSE_PROJECT_NAME' $Project
    if ($Version -ne 'latest') { Set-EnvLine 'RECON_VERSION' $Version }
    Write-Host "created .env (database password generated; APP_URL=$appUrl)"
    Push-Location -LiteralPath $InstallDir
    try {
      Say 'Downloading the images'
      Invoke-Compose pull
      Say 'Starting (database -> migrator -> engine bootstrap -> web + engine)'
      Invoke-Compose up -d
      Say 'Waiting for the web UI'
      if (-not (Wait-Healthy)) {
        throw "The web UI did not report healthy within 3 minutes. In $InstallDir check: docker compose ps   then: docker compose logs web-migrator web"
      }
    }
    finally { Pop-Location }
    Write-Host ''
    Write-Host "OK  Recon Essentials is installed in $InstallDir and runs at $appUrl"
    Write-Host "    Create the first administrator at $appUrl/setup"
    if (-not (Test-LocalHost $access.Host)) { Write-Host '    Do it now: until then, anyone on the network who opens this address can.' }
    Write-Host '    It runs in the background and starts again whenever Docker Desktop starts.'
    Write-Host '    When it does not open, run recon-essentials.cmd in its folder. It starts Recon Essentials and never deletes data.'
    Write-Commands
    Open-Browser "$appUrl/setup"
  }

  function Start-Installed {
    Say "Starting Recon Essentials ($InstallDir)"
    # An installation from before the launcher (or the first release) gets one.
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'recon-essentials.cmd'))) { New-Launcher }
    Push-Location -LiteralPath $InstallDir
    try {
      # The database first: the release check reads it, and an upgrade it calls for runs before
      # the web starts. No pull: a present image is used as it is and only a missing one is
      # downloaded (Compose's default pull_policy), so this is fast, and needs no internet when
      # nothing is missing.
      try { Invoke-Compose up -d --wait db } catch { }
      Invoke-ReleaseCheck
      try { Invoke-Compose up -d }
      catch { throw "Recon Essentials did not start. When an image had to be downloaded, check the internet connection. In ${InstallDir}: docker compose logs" }
      if (-not (Wait-Healthy)) {
        throw "The web UI did not report healthy within 3 minutes. In $InstallDir check: docker compose ps   then: docker compose logs web-migrator web"
      }
    }
    finally { Pop-Location }
    $appUrl = Get-EnvValue 'APP_URL'
    Write-Host ''
    Write-Host "OK  Recon Essentials runs at $appUrl"
    Open-Browser $appUrl
  }

  function Set-Address {
    $current = Get-EnvValue 'APP_URL'
    if ($current -match '^https://') {
      throw "APP_URL is an https address ($current), so a reverse proxy serves this installation. Change APP_URL in .env by hand, then run: docker compose up -d"
    }
    $split = Split-Address $current
    $currentHost = if (Test-HostName $split.Address) { $split.Address } else { 'localhost' }
    $access = Request-Access $currentHost
    $portNumber = Get-EnvValue 'WEB_PORT'
    if (-not (Test-Port $portNumber)) { $portNumber = '8080' }
    $wanted = if ($Options.Port) { $Options.Port } else { $access.Port }
    if ($wanted) {
      if (-not (Test-Port $wanted)) { throw "The port must be a number from 1 to 65535 (got $wanted)." }
      if ($wanted -ne $portNumber -and (Test-PortInUse ([int]$wanted))) { throw "Port $wanted is in use on this computer. Choose another with -Port and run this again." }
      $portNumber = $wanted
    }
    $appUrl = Write-Access $access.Host $portNumber
    Push-Location -LiteralPath $InstallDir
    try {
      Say 'Restarting the web with the new address'
      Invoke-Compose up -d
    }
    finally { Pop-Location }
    Write-Host ''
    Write-Host "OK  Recon Essentials now opens at $appUrl"
    if (Test-LocalHost $access.Host) { Write-Host '    Only this computer can open it.' }
  }

  # The project an installation runs is the one its .env names; a compose file deleted by hand
  # comes back.
  function Enter-Installation {
    $named = Get-EnvValue 'COMPOSE_PROJECT_NAME'
    if ($named) { Set-Variable -Name Project -Value $named -Scope 1 }
    Get-InstallFile 'docker-compose.yml'
  }

  $InstallDir = $null
  switch ($Command) {
    { $_ -in @('run', 'install', 'start') } {
      Assert-Docker
      $InstallDir = Resolve-Target
      if (Test-Installation $InstallDir) {
        Enter-Installation
        Start-Installed
      }
      elseif (Test-Path -LiteralPath (Join-Path $InstallDir '.env')) {
        throw "$InstallDir already has an .env file that does not belong to Recon Essentials. Choose another folder with INSTALL_DIR."
      }
      else { Install-New }
      break
    }

    { $_ -in @('stop', 'upgrade', 'address', 'uninstall') } {
      Assert-Docker
      $InstallDir = Resolve-Target
      if (-not (Test-Installation $InstallDir)) {
        throw "No installation in $InstallDir. Run this in the installation folder, or set INSTALL_DIR."
      }
      Enter-Installation
      switch ($Command) {
        'stop' {
          Push-Location -LiteralPath $InstallDir
          try { Say 'Stopping Recon Essentials'; Invoke-Compose stop } finally { Pop-Location }
          Write-Host ''
          Write-Host 'OK  Stopped. It stays stopped, also after a restart, until recon-essentials.cmd starts it again.'
        }
        'upgrade' {
          Push-Location -LiteralPath $InstallDir
          try { Invoke-Upgrade } finally { Pop-Location }
        }
        'address' { Set-Address }
        'uninstall' {
          Push-Location -LiteralPath $InstallDir
          try {
            if ($Options.Purge) {
              Say 'Removing containers AND data volumes (-Purge)'
              Invoke-Compose down -v --remove-orphans
            }
            else {
              Say 'Removing containers; data volumes are kept (add -Purge to delete them)'
              Invoke-Compose down --remove-orphans
            }
          }
          finally { Pop-Location }
        }
      }
      break
    }

    default { throw "usage: $ScriptName [stop|upgrade|address|uninstall] [-Version x.y.z] [-Address host] [-Port n] [-Purge]   (no command: install it, or start it)" }
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
# Under `irm | iex` the param block above set these in the caller's own session.
Remove-Variable -Name reconBody, reconScriptDir, reconOptions, reconExitCode, Command, Purge, Version, Address, Port -ErrorAction SilentlyContinue
