<#
    KAGE-MAN.DOJO :: install.ps1   (run this on your Windows HOST, not in the VM)

    One command to build the whole range. It checks the host has Vagrant +
    VirtualBox, then runs `vagrant up`, which:
      1. creates the three VirtualBox NAT networks (KAGE-DOJO-DMZ/INT/WAN)
      2. boots the Ubuntu 20.04 VM "KAGE-MAN.DOJO"
      3. installs Docker + builds the macvlan segments + generates composes
      4. builds AND starts every lab + the WAN DNS (restart=unless-stopped)

    Usage (from the repo root, in PowerShell):
      .\install.ps1                 # full build + start everything
      .\install.ps1 -NoStart        # provision only (don't start the ~27 labs)
      .\install.ps1 -Gui            # open the VM console window (shows the logo)
      .\install.ps1 -Provision      # re-run provisioning on an existing VM
      .\install.ps1 -Destroy        # tear the VM down

    Tunables pass straight through as environment variables, e.g.:
      $env:KAGE_MEMORY=12288; $env:KAGE_CPUS=6; .\install.ps1
      (see the Vagrantfile header for KAGE_MEMORY/CPUS/BOX/DISK/START/GUI)

    If scripts are blocked, launch with:
      powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoStart,
    [switch]$Gui,
    [switch]$Provision,
    [switch]$Destroy
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Set-Location -LiteralPath $PSScriptRoot

function Write-Red { param($m) Write-Host $m -ForegroundColor Red }
function Die       { param($m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Find-VBoxManage {
    $c = (Get-Command VBoxManage.exe -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    if ($env:VBOX_MSI_INSTALL_PATH) {
        $guess = Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe'
        if (Test-Path $guess) { return $guess }
    }
    $pf = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path $pf) { return $pf }
    return $null
}

function Install-Hint {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return 'winget install HashiCorp.Vagrant Oracle.VirtualBox' }
    if (Get-Command choco  -ErrorAction SilentlyContinue) { return 'choco install -y vagrant virtualbox' }
    if (Get-Command scoop  -ErrorAction SilentlyContinue) { return 'scoop install vagrant; scoop install virtualbox' }
    return 'install Vagrant (https://developer.hashicorp.com/vagrant/downloads) and VirtualBox (https://www.virtualbox.org)'
}

# ---- banner ---------------------------------------------------------------
$py = $null
foreach ($cand in 'python', 'python3', 'py') {
    if (Get-Command $cand -ErrorAction SilentlyContinue) { $py = $cand; break }
}
if ($py) {
    & $py setup.py --banner
} elseif (Test-Path 'assets\banner.ans') {
    Write-Host ''
    Get-Content -Raw 'assets\banner.ans' | Write-Host
    Write-Host ''
}

# ---- destroy shortcut -----------------------------------------------------
if ($Destroy) {
    if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) { Die 'vagrant not found' }
    vagrant destroy -f
    exit $LASTEXITCODE
}

# ---- host prerequisites ---------------------------------------------------
$missing = $false
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    Write-Host '[x] Vagrant not found' -ForegroundColor Red; $missing = $true
}
if (-not (Find-VBoxManage)) {
    Write-Host '[x] VirtualBox (VBoxManage) not found' -ForegroundColor Red; $missing = $true
}
if ($missing) {
    Write-Host ''
    Write-Host 'Install the host prerequisites, then re-run .\install.ps1 :'
    Write-Host "    $(Install-Hint)"
    exit 1
}

# ---- run ------------------------------------------------------------------
if ($NoStart) { $env:KAGE_START = 'none' }
if ($Gui)     { $env:KAGE_GUI   = '1' }

$action    = if ($Provision) { 'provision' } else { 'up' }
$startMsg  = if ($env:KAGE_START) { $env:KAGE_START } else { 'up' }
$guiMsg    = if ($env:KAGE_GUI) { ', GUI' } else { '' }
Write-Red ">> vagrant $action (KAGE_START=$startMsg$guiMsg)"

if ($Provision) { vagrant provision } else { vagrant up }
if ($LASTEXITCODE -ne 0) { Die "vagrant $action failed (exit $LASTEXITCODE)" }

# ---- next steps -----------------------------------------------------------
@"

------------------------------------------------------------------------
KAGE-MAN.DOJO is up.

  Enter the VM:        vagrant ssh      (then: cd /opt/kage-man)
  What's running:      vagrant ssh -c 'sudo docker ps'
  Health / probes:     make health   |   make smoke   (inside the VM)
  Start/stop a lab:    make up LAB=<name>   |   make down LAB=<name>

  Attacker (Kali): attach it to the KAGE-DOJO-WAN NAT network, static
  10.0.8.x, DNS 10.0.8.53  ->  curl http://www.shopizer-online.com/
------------------------------------------------------------------------
"@ | Write-Host
