<#
    KAGE-MAN.DOJO :: scripts/vbox-networks.ps1   (Windows / PowerShell)

    Create the three VirtualBox NAT networks the range runs on, via VBoxManage.
    Names and subnets are read from segments.conf (columns:
    key iface net subnet gw hostip def), so it stays the single source of truth:

        KAGE-DOJO-DMZ   192.168.80.0/24
        KAGE-DOJO-INT   172.16.80.0/24
        KAGE-DOJO-WAN   10.0.8.0/24

    Each is an L2 segment with an outbound-NAT gateway at .1; DHCP is off (the
    host VM and every lab container use static addresses). Attach a Kali box to
    KAGE-DOJO-WAN to play the campaign.

    Usage (from the repo root):
        powershell -ExecutionPolicy Bypass -File scripts\vbox-networks.ps1 create
        powershell -ExecutionPolicy Bypass -File scripts\vbox-networks.ps1 remove
        powershell -ExecutionPolicy Bypass -File scripts\vbox-networks.ps1 list
        ... -File scripts\vbox-networks.ps1 create -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('create', 'remove', 'list')]
    [string]$Action = 'create',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Info { param($m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "[x] $m" -ForegroundColor Red }

# locate VBoxManage (PATH, then the default install location)
$vbox = (Get-Command VBoxManage.exe -ErrorAction SilentlyContinue).Source
if (-not $vbox) {
    $guess = Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe'
    if ($env:VBOX_MSI_INSTALL_PATH -and (Test-Path $guess)) { $vbox = $guess }
    elseif (Test-Path 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe') {
        $vbox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    }
}
if (-not $vbox) { Write-Err 'VBoxManage.exe not found (is VirtualBox installed?)'; exit 1 }

$root = Split-Path -Parent $PSScriptRoot
$conf = Join-Path $root 'segments.conf'
if (-not (Test-Path $conf)) { Write-Err 'segments.conf not found next to this repository'; exit 1 }

function Invoke-VBox {
    param([string[]]$VBoxArgs)
    if ($DryRun) { Write-Host "DRY-RUN: VBoxManage $($VBoxArgs -join ' ')"; return }
    & $vbox @VBoxArgs
}

function Get-NatNetworks {
    (& $vbox natnetwork list) 2>$null |
        Where-Object { $_ -match '^Name:\s+(.+?)\s*$' } |
        ForEach-Object { ($_ -split '\s+', 2)[1].Trim() }
}

if ($Action -eq 'list') { & $vbox natnetwork list; exit 0 }

# parse segments.conf -> [ @{ Net=...; Subnet=... } ]
$segments = Get-Content $conf | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $cols = $line -split '\s+'
    if ($cols.Count -lt 4) { return }
    [pscustomobject]@{ Net = $cols[2]; Subnet = $cols[3] }
} | Where-Object { $_ }

$existing = Get-NatNetworks

foreach ($s in $segments) {
    $have = $existing -contains $s.Net
    switch ($Action) {
        'remove' {
            if ($have) { Invoke-VBox @('natnetwork', 'remove', '--netname', $s.Net); Write-Ok "removed $($s.Net)" }
            else       { Write-Warn "$($s.Net) does not exist - nothing to remove" }
        }
        'create' {
            if ($have) {
                Invoke-VBox @('natnetwork', 'modify', '--netname', $s.Net, '--network', $s.Subnet, '--enable', '--dhcp', 'off', '--ipv6', 'off')
                Write-Ok "refreshed $($s.Net) ($($s.Subnet))"
            } else {
                Invoke-VBox @('natnetwork', 'add', '--netname', $s.Net, '--network', $s.Subnet, '--enable', '--dhcp', 'off', '--ipv6', 'off')
                Write-Ok "created  $($s.Net) ($($s.Subnet))"
            }
        }
    }
}

if ($Action -eq 'create') {
    Write-Host ''
    Write-Info 'VirtualBox NAT networks now defined:'
    & $vbox natnetwork list
}
