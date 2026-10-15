#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: install.sh   (run this on your HOST, not in the VM)
#
# One command to build the whole range. It checks the host has Vagrant +
# VirtualBox, then runs `vagrant up`, which:
#   1. creates the three VirtualBox NAT networks (KAGE-DOJO-DMZ/INT/WAN)
#   2. boots the Ubuntu 20.04 VM "KAGE-MAN.DOJO"
#   3. installs Docker + builds the macvlan segments + generates composes
#   4. builds AND starts every lab + the WAN DNS (restart=unless-stopped)
#
# Usage:
#   ./install.sh                 # full build + start everything
#   ./install.sh --no-start      # provision only (don't start the ~27 labs)
#   ./install.sh --gui           # open the VM console window (shows the logo)
#   ./install.sh --provision     # re-run provisioning on an existing VM
#   ./install.sh --destroy       # tear the VM down
#
# Tunables pass straight through as environment variables, e.g.:
#   KAGE_MEMORY=12288 KAGE_CPUS=6 ./install.sh
#   (see the Vagrantfile header for KAGE_MEMORY/CPUS/BOX/DISK/START/GUI)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

GUI=0; START=""; ACTION="up"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '/^set -euo/d; s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gui)        GUI=1 ;;
    --no-start)   START="none" ;;
    --provision)  ACTION="provision" ;;
    --destroy)    ACTION="destroy" ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

red() { printf '\e[1;91m%s\e[0m\n' "$*"; }
die() { printf '\e[1;91m[x]\e[0m %s\n' "$*" >&2; exit 1; }

# ---- banner ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python3 setup.py --banner || true
elif [[ -f assets/banner.ans ]]; then
  printf '\n'; cat assets/banner.ans; printf '\n'
fi

# ---- destroy shortcut -----------------------------------------------------
if [[ "$ACTION" == "destroy" ]]; then
  command -v vagrant >/dev/null 2>&1 || die "vagrant not found"
  exec vagrant destroy -f
fi

# ---- host prerequisites ---------------------------------------------------
install_hint() {
  if   command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S virtualbox virtualbox-host-dkms vagrant"
  elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y virtualbox vagrant"
  elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y VirtualBox vagrant"
  elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y virtualbox vagrant"
  elif command -v brew    >/dev/null 2>&1; then echo "brew install --cask virtualbox vagrant"
  else echo "install VirtualBox and Vagrant from your distribution / https://www.vagrantup.com"
  fi
}

missing=0
command -v vagrant    >/dev/null 2>&1 || { printf '\e[1;91m[x]\e[0m %s\n' "Vagrant not found";               missing=1; }
command -v VBoxManage >/dev/null 2>&1 || { printf '\e[1;91m[x]\e[0m %s\n' "VirtualBox (VBoxManage) not found"; missing=1; }
if (( missing )); then
  echo
  echo "Install the host prerequisites, then re-run ./install.sh :"
  echo "    $(install_hint)"
  exit 1
fi

# ---- run ------------------------------------------------------------------
[[ -n "$START" ]] && export KAGE_START="$START"
(( GUI )) && export KAGE_GUI=1

red ">> vagrant ${ACTION} (KAGE_START=${KAGE_START:-up}${KAGE_GUI:+, GUI})"
if [[ "$ACTION" == "provision" ]]; then
  vagrant provision
else
  vagrant up
fi

# ---- next steps -----------------------------------------------------------
cat <<'EOF'

────────────────────────────────────────────────────────────────────────
KAGE-MAN.DOJO is up.

  Enter the VM:        vagrant ssh      (then: cd /opt/kage-man)
  What's running:      vagrant ssh -c 'sudo docker ps'
  Health / probes:     make health   |   make smoke   (inside the VM)
  Start/stop a lab:    make up LAB=<name>   |   make down LAB=<name>

  Attacker (Kali): attach it to the KAGE-DOJO-WAN NAT network, static
  10.0.8.x, DNS 10.0.8.53  ->  curl http://www.shopizer-online.com/
────────────────────────────────────────────────────────────────────────
EOF
