#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/vbox-networks.sh   (Linux / macOS)
#
# Create the three VirtualBox NAT networks the range runs on, via VBoxManage.
# Names and subnets are read from segments.conf (columns: key iface net subnet
# gw hostip def), so this stays the single source of truth:
#
#     KAGE-DOJO-DMZ   192.168.80.0/24
#     KAGE-DOJO-INT   172.16.80.0/24
#     KAGE-DOJO-WAN   10.0.8.0/24
#
# Each is an L2 segment with an outbound-NAT gateway at .1; DHCP is off (the
# host VM and every lab container use static addresses). Attach a Kali box to
# KAGE-DOJO-WAN to play the campaign.
#
# Usage:
#   ./scripts/vbox-networks.sh [create]     # create/refresh (default)
#   ./scripts/vbox-networks.sh remove       # delete the three networks
#   ./scripts/vbox-networks.sh list         # show VirtualBox NAT networks
#   ./scripts/vbox-networks.sh --dry-run    # print actions, change nothing
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/segments.conf"

ACTION="create"
DRY=0
for a in "$@"; do
  case "$a" in
    create|remove|list) ACTION="$a" ;;
    --dry-run)          DRY=1 ;;
    -h|--help)          sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

log()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY )); then echo "DRY-RUN: $*"; else "$@"; fi; }

command -v VBoxManage >/dev/null 2>&1 || die "VBoxManage not found in PATH (is VirtualBox installed?)"
[[ -f "$CONF" ]] || die "segments.conf not found next to this repository"

net_exists() { VBoxManage natnetwork list 2>/dev/null | awk '/^Name:/{print $2}' | grep -qx "$1"; }

if [[ "$ACTION" == "list" ]]; then
  VBoxManage natnetwork list
  exit 0
fi

# iterate the segment table
while read -r key iface net subnet gw hostip def; do
  [[ -z "${key:-}" || "$key" == \#* ]] && continue
  [[ -z "${net:-}" || -z "${subnet:-}" ]] && continue

  if [[ "$ACTION" == "remove" ]]; then
    if net_exists "$net"; then
      run VBoxManage natnetwork remove --netname "$net"
      ok "removed $net"
    else
      warn "$net does not exist - nothing to remove"
    fi
    continue
  fi

  # create / refresh
  if net_exists "$net"; then
    run VBoxManage natnetwork modify --netname "$net" --network "$subnet" --enable --dhcp off --ipv6 off
    ok "refreshed $net ($subnet)"
  else
    run VBoxManage natnetwork add --netname "$net" --network "$subnet" --enable --dhcp off --ipv6 off
    ok "created  $net ($subnet)"
  fi
done < "$CONF"

echo
log "VirtualBox NAT networks now defined:"
VBoxManage natnetwork list 2>/dev/null | awk '/^Name:/{n=$2} /^Network:/{printf "    %-16s %s\n", n, $2}'
