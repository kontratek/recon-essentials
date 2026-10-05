# Recon Essentials' script is now recon-essentials.ps1: it installs Recon Essentials, and starts it
# when it is installed.
#
#   irm https://raw.githubusercontent.com/kontratek/recon-essentials/main/recon-essentials.ps1 | iex
#
# This file stays so the first release's command and the folders it installed keep working: it runs
# recon-essentials.ps1 with the same arguments (install, upgrade, address, uninstall, -Purge,
# -Version, -Address, -Port). ASCII only, and no `exit` except when run as a file - the reasons are
# in recon-essentials.ps1.

param(
  [string]$Command = 'run',
  [switch]$Purge,
  [string]$Version = '',
  [string]$Address = '',
  [string]$Port = ''
)

$reconSource = if ($env:RECON_DIST_URL) { $env:RECON_DIST_URL.TrimEnd('/') } else { 'https://raw.githubusercontent.com/kontratek/recon-essentials/main' }
if ($PSCommandPath) {
  $ProgressPreference = 'SilentlyContinue'
  $reconHere = Split-Path -Parent $PSCommandPath
  $reconScript = Join-Path $reconHere 'recon-essentials.ps1'
  if (-not (Test-Path -LiteralPath $reconScript)) {
    # In an installation folder the new script is fetched next to this one, once; elsewhere it runs
    # from the temporary folder and finds the installation itself.
    if (-not (Test-Path -LiteralPath (Join-Path $reconHere '.env'))) { $reconScript = Join-Path ([IO.Path]::GetTempPath()) 'recon-essentials.ps1' }
    Invoke-WebRequest -UseBasicParsing -Uri "$reconSource/recon-essentials.ps1" -OutFile $reconScript
  }
  & $reconScript -Command $Command -Purge:$Purge -Version $Version -Address $Address -Port $Port
  exit $LASTEXITCODE
}
# The same call as the documented command (irm | iex): Invoke-WebRequest's Content is a byte array
# when a server names no text type, and Invoke-Expression would then parse a row of numbers.
Invoke-Expression (Invoke-RestMethod -Uri "$reconSource/recon-essentials.ps1")
Remove-Variable -Name reconSource, Command, Purge, Version, Address, Port -ErrorAction SilentlyContinue
