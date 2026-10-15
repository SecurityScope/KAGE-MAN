#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/vagrant-provision.sh
#
# Runs once (as root) during `vagrant up` to turn a stock Ubuntu 20.04 box
# into the full range host. Idempotent -- `vagrant provision` re-runs it safely.
#
# Steps:
#   1. copy the synced repo off the VirtualBox shared folder to a local path
#      (docker bind-mounts, which the vulhub labs use, misbehave on vboxsf)
#   2. map each segment to its NIC by the fixed MAC the Vagrantfile set, give
#      it the .250 static address via netplan, and rewrite segments.conf's
#      iface column to the real kernel name
#   3. run setup.py (banner + progress bar): install-deps -> network-setup ->
#      gen-labs -> build AND start every lab. KAGE_START picks the final stage
#      (up=start all [default], build=build only, none=deps/net/gen only).
#   4. put the vagrant user in the docker group
#
set -euo pipefail

LAB_SRC=/vagrant
LAB_DIR=/opt/kage-man
START="${KAGE_START:-none}"
NETPLAN=/etc/netplan/60-kage-labs.yaml

# segment key -> fixed MAC (lowercase, colon-separated). Keep in sync with the
# SEGMENTS list in the Vagrantfile and the keys in segments.conf.
declare -A SEG_MAC=(
  [dmz]="08:00:27:1a:80:20"
  [internal]="08:00:27:1a:80:21"
  [wan]="08:00:27:1a:80:22"
)

log()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }

iface_for_mac() {
  local want="${1,,}" dev a
  for dev in /sys/class/net/*; do
    a="$(cat "$dev/address" 2>/dev/null || true)"
    [[ "${a,,}" == "$want" ]] && { basename "$dev"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. local working copy (off the vboxsf share)
# ---------------------------------------------------------------------------
if ! command -v rsync >/dev/null 2>&1; then
  log "installing rsync"
  env DEBIAN_FRONTEND=noninteractive apt-get update -q
  env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsync
fi

log "syncing repo -> $LAB_DIR"
mkdir -p "$LAB_DIR"
rsync -a --delete --exclude '.git' --exclude '.vagrant' "$LAB_SRC"/ "$LAB_DIR"/
cd "$LAB_DIR"

# ---------------------------------------------------------------------------
# 2. address the lab NICs (.250 per segment) + fix segments.conf iface names
#    NIC identity comes from the fixed MACs the Vagrantfile assigned, so the
#    opaque enp0s8/enp0s9/enp0s10 ordering does not matter.
# ---------------------------------------------------------------------------
log "mapping segment NICs by MAC and assigning static addresses"
{
  echo "# Managed by KAGE-MAN.DOJO vagrant-provision.sh -- do not edit by hand."
  echo "network:"
  echo "  version: 2"
  echo "  ethernets:"
} > "$NETPLAN.tmp"

declare -A KEY_IFACE=()
while read -r key iface net subnet gw hostip def; do
  [[ -z "${key:-}" || "$key" == \#* ]] && continue
  mac="${SEG_MAC[$key]:-}"
  if [[ -z "$mac" ]]; then warn "  no MAC known for segment '$key'; skipping"; continue; fi
  if realif="$(iface_for_mac "$mac")"; then
    KEY_IFACE[$key]="$realif"
    log "  $key: $realif  ($mac -> ${hostip})"
    {
      echo "    ${realif}:"
      echo "      dhcp4: no"
      echo "      dhcp6: no"
      echo "      optional: true"
      echo "      addresses: [${hostip}]"
    } >> "$NETPLAN.tmp"
  else
    warn "  $key: no NIC with MAC $mac found (check the VirtualBox adapters)"
  fi
done < segments.conf

install -m 0600 "$NETPLAN.tmp" "$NETPLAN"
rm -f "$NETPLAN.tmp"
log "applying netplan"
netplan generate
netplan apply
sleep 2

# rewrite segments.conf iface column to the resolved kernel names
tmp="$(mktemp)"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then printf '%s\n' "$line" >>"$tmp"; continue; fi
  read -r key iface net subnet gw hostip def <<<"$line"
  [[ -n "${KEY_IFACE[$key]:-}" ]] && iface="${KEY_IFACE[$key]}"
  printf '%s %s %s %s %s %s %s\n' "$key" "$iface" "$net" "$subnet" "$gw" "$hostip" "$def" >>"$tmp"
done < segments.conf
install -m 0644 "$tmp" segments.conf
rm -f "$tmp"
ok "segment NIC mapping:"
grep -vE '^[[:space:]]*(#|$)' segments.conf | awk '{printf "    %-9s %-10s %s\n", $1, $2, $6}'

# ---------------------------------------------------------------------------
# 3-6. install deps, configure networking, generate composes, then build and
#      start every lab -- all driven by the setup.py wrapper (banner + live
#      progress bar). KAGE_START selects the final stage:
#        up    (default) -> build AND start ALL labs (restart=unless-stopped)
#        build           -> build all images, do not start
#        none            -> deps/net/gen only
# ---------------------------------------------------------------------------
case "$START" in
  up)      SETUP_ARGS=() ;;
  build)   SETUP_ARGS=(--no-start) ;;
  none|"") SETUP_ARGS=(--skip-build) ;;
  *) warn "unknown KAGE_START='$START' (expected none|build|up); not starting labs"
     SETUP_ARGS=(--skip-build) ;;
esac
log "running setup.py ${SETUP_ARGS[*]:-(full install + build + start all)}"
python3 setup.py "${SETUP_ARGS[@]}"

# let the vagrant user drive docker without sudo
if id vagrant >/dev/null 2>&1 && ! id -nG vagrant | grep -qw docker; then
  usermod -aG docker vagrant && ok "added vagrant to the docker group"
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
cat <<BANNER

$(ok 'KAGE-MAN.DOJO range host is provisioned.')

  Repo (local copy):  $LAB_DIR
  Segments:           WAN 10.0.8.0/24 · DMZ 192.168.80.0/24 · INTERNAL 172.16.80.0/24
  Host addresses:     .250 on each segment

  Inside the VM (sudo docker ps to see what is running):
    vagrant ssh ; cd $LAB_DIR
    sudo python3 setup.py        # re-run the full install + build + start
    make ps | make health | make smoke
    make down LAB=<name>         # stop a lab   |   make up LAB=<name> to start

  Attacker: attach a Kali VM to the KAGE-DOJO-WAN NAT network with a static
            10.0.8.x address (DNS: 10.0.8.53).

BANNER
