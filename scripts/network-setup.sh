#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/network-setup.sh
#
# Host-side provisioning for the range:
#   1. static IPv4 on the three lab NICs (single default route via the DMZ)
#   2. promiscuous mode on the lab NICs (immediate + persistent across reboot)
#   3. Docker macvlan networks for the three lab segments (idempotent)
#
# The segment table is read from ./segments.conf:
#   key iface net subnet gateway host-ip default(yes|no)
#
# Safe by default: running interfaces (once the lab is live) are never
# re-addressed. The static config applies on the next reboot or when you run
# with --restart-all from the VirtualBox console.
#
# Usage:
#   sudo ./scripts/network-setup.sh                 # apply safely (no restarts)
#   sudo ./scripts/network-setup.sh --no-live       # write config only
#   sudo ./scripts/network-setup.sh --restart-all   # full networking restart (console!)
#   ./scripts/network-setup.sh --dry-run            # show actions, change nothing
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "$ROOT/segments.conf" ]]; then
  echo "error: segments.conf not found next to this repository" >&2
  exit 1
fi

SEGMENTS=()
while read -r key iface net subnet gw hostip def; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  SEGMENTS+=("$iface $net $subnet $gw $hostip ${def:-no}")
done < "$ROOT/segments.conf"
(( ${#SEGMENTS[@]} )) || { echo "error: no segments parsed from segments.conf" >&2; exit 1; }

IFACES_FILE=/etc/network/interfaces.d/kage-labs
PROMISC_UNIT=/etc/systemd/system/promisc-mode.service
DNS="8.8.8.8 8.8.4.4"

DRY_RUN=0
NO_LIVE=0
RESTART_ALL=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --no-live)     NO_LIVE=1 ;;
    --restart-all) RESTART_ALL=1 ;;
    -h|--help)     sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then echo "DRY-RUN: $*"; else "$@"; fi; }

if (( EUID != 0 )) && (( ! DRY_RUN )); then
  die "must run as root (or use --dry-run)"
fi
# Under --dry-run (e.g. validating a segments.conf off the target host) missing
# docker / NICs are warnings, not fatal.
if (( DRY_RUN )); then
  command -v docker >/dev/null || warn "docker is not installed (dry-run)"
  docker info >/dev/null 2>&1  || warn "docker daemon not reachable (dry-run)"
else
  command -v docker >/dev/null || die "docker is not installed"
  docker info >/dev/null 2>&1  || die "docker daemon is not reachable"
fi

for seg in "${SEGMENTS[@]}"; do
  read -r iface _ _ _ _ _ <<< "$seg"
  ip link show "$iface" >/dev/null 2>&1 && continue
  if (( DRY_RUN )); then
    warn "NIC $iface not found (dry-run; expected on the target VM)"
  else
    die "NIC $iface not found - check the VirtualBox adapter settings"
  fi
done

# ---------------------------------------------------------------------------
# 1. static addressing (dedicated ifupdown fragment, main file already
#    sources /etc/network/interfaces.d/*)
# ---------------------------------------------------------------------------
log "writing $IFACES_FILE"
tmp=$(mktemp)
{
  echo "# Managed by KAGE-MAN.DOJO scripts/network-setup.sh -- do not edit by hand."
  for seg in "${SEGMENTS[@]}"; do
    read -r iface _ _ gw hostip def <<< "$seg"
    cat <<EOF

auto $iface
iface $iface inet static
    address ${hostip%/*}
    netmask 255.255.255.0
    post-up /sbin/ip link set dev $iface promisc on
    dns-nameservers $DNS
EOF
    if [[ "$def" == "yes" ]]; then
      echo "    gateway $gw"
    fi
  done
} > "$tmp"
if (( DRY_RUN )); then
  cat "$tmp"
else
  install -m 0644 "$tmp" "$IFACES_FILE"
fi
rm -f "$tmp"

# ---------------------------------------------------------------------------
# 2. promiscuous-mode systemd unit (post-up covers ifup, this covers boot)
# ---------------------------------------------------------------------------
log "installing $PROMISC_UNIT"
if (( DRY_RUN )); then
  echo "[DRY-RUN] write unit + docker ordering drop-in + systemctl daemon-reload + enable"
elif (( NO_LIVE )); then
  echo "[--no-live] skipped unit installation"
else
  {
    cat <<'EOF'
[Unit]
Description=Enable promiscuous mode on KAGE-MAN lab NICs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EOF
    for seg in "${SEGMENTS[@]}"; do
      read -r iface _ <<< "$seg"
      echo "ExecStart=/sbin/ip link set $iface promisc on"
    done
    cat <<'EOF'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
  } > "$PROMISC_UNIT"

  # make sure containers (restart policies) only start once the lab NICs and
  # promiscuous mode are ready - macvlan children inherit the parent link state
  DOCKER_DROPIN=/etc/systemd/system/docker.service.d/after-network.conf
  mkdir -p "$(dirname "$DOCKER_DROPIN")"
  cat > "$DOCKER_DROPIN" <<'EOF'
[Unit]
After=network-online.target promisc-mode.service
Wants=network-online.target
EOF

  systemctl daemon-reload
  systemctl enable promisc-mode.service
fi

# ---------------------------------------------------------------------------
# 3. bring up the lab NICs (never re-address a running interface)
# ---------------------------------------------------------------------------
if (( RESTART_ALL )); then
  warn "full networking restart requested - SSH sessions WILL drop"
  run systemctl restart networking
  run systemctl start promisc-mode.service
elif (( ! NO_LIVE )); then
  for seg in "${SEGMENTS[@]}"; do
    read -r iface _ _ _ _ _ <<< "$seg"
    if ip link show "$iface" | grep -qE 'state (UP|UNKNOWN)'; then
      ok "$iface is already up - leaving its live address alone"
    else
      run ifup "$iface"
    fi
    run ip link set dev "$iface" promisc on
  done
else
  warn "--no-live: interfaces and promisc mode untouched"
fi

# ---------------------------------------------------------------------------
# 4. docker macvlan networks (idempotent)
# ---------------------------------------------------------------------------
for seg in "${SEGMENTS[@]}"; do
  read -r iface net subnet gw _ _ <<< "$seg"
  if docker network inspect "$net" >/dev/null 2>&1; then
    ok "docker network '$net' already exists"
  else
    run docker network create -d macvlan \
        --subnet "$subnet" \
        --gateway "$gw" \
        -o parent="$iface" \
        -o macvlan_mode=bridge \
        "$net"
    ok "docker network '$net' created (parent $iface, gw $gw)"
  fi
done

# ---------------------------------------------------------------------------
# 5. verify
# ---------------------------------------------------------------------------
echo
log "host addresses:"
for seg in "${SEGMENTS[@]}"; do
  read -r iface _ _ _ _ _ <<< "$seg"
  ip -br -4 addr show "$iface" || true
done

log "promisc flags:"
for seg in "${SEGMENTS[@]}"; do
  read -r iface _ _ _ _ _ <<< "$seg"
  if ip link show "$iface" 2>/dev/null | grep -q PROMISC; then
    ok "$iface promisc ON"
  else
    warn "$iface promisc OFF"
  fi
done

log "macvlan networks:"
docker network ls --filter driver=macvlan --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
