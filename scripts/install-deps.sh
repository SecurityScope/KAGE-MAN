#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/install-deps.sh
#
# Install the range-host dependencies on a fresh Ubuntu machine
# (20.04 focal recommended; 16.04 xenial kept working):
#
#   1. Docker CE + containerd (from the Docker apt repository; pinned on xenial)
#   2. custom seccomp profile + daemon.json (clone3 / faccessat2 / rseq)
#   3. Docker Compose v2 standalone binary
#   4. make (for the Makefile wrappers)
#
# Idempotent: anything already installed is skipped.
#
# Usage:
#   sudo ./scripts/install-deps.sh
#   sudo ./scripts/install-deps.sh --dry-run   # show actions, change nothing
#   COMPOSE_VERSION=v2.29.7 sudo ./scripts/install-deps.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# versions
# ---------------------------------------------------------------------------
DOCKER_CE_VERSION="5:20.10.7~3-0~ubuntu-xenial"
DOCKER_CLI_VERSION="5:20.10.7~3-0~ubuntu-xenial"
CONTAINERD_VERSION="1.4.6-1"
COMPOSE_VERSION="${COMPOSE_VERSION:-v5.6.0}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

log()  { printf '\e[1;34m[*]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[+]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[!]\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31m[x]\e[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then echo "DRY-RUN: $*"; else "$@"; fi; }

if (( EUID != 0 )) && (( ! DRY_RUN )); then
  die "must run as root: sudo $0"
fi

pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# 0. apt prerequisites
# ---------------------------------------------------------------------------
log "installing apt prerequisites (https transport, curl, gnupg)"
run env DEBIAN_FRONTEND=noninteractive apt-get update -q
run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  apt-transport-https ca-certificates curl gnupg lsb-release

# ---------------------------------------------------------------------------
# 1. Docker CE (apt removes conflicting docker.io / containerd packages)
#    - xenial: pinned to the last releases Ubuntu 16.04 supports
#    - focal and newer: current packages for this codename
# ---------------------------------------------------------------------------
codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo xenial)}")"
log "detected Ubuntu codename: $codename"

if [[ "$codename" == "xenial" ]]; then
  if [[ "$(pkg_version docker-ce)"     == "$DOCKER_CE_VERSION"  ]] \
  && [[ "$(pkg_version docker-ce-cli)" == "$DOCKER_CLI_VERSION" ]] \
  && [[ "$(pkg_version containerd.io)" == "$CONTAINERD_VERSION" ]]; then
    ok "docker-ce ${DOCKER_CE_VERSION%%~*} already installed"
  else
    install_docker=1
    DOCKER_PKGS=( "docker-ce=$DOCKER_CE_VERSION" "docker-ce-cli=$DOCKER_CLI_VERSION" "containerd.io=$CONTAINERD_VERSION" )
  fi
else
  if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
    ok "docker already installed: $(docker --version)"
  else
    install_docker=1
    DOCKER_PKGS=( docker-ce docker-ce-cli containerd.io )
  fi
fi

if [[ -n "${install_docker:-}" ]]; then
  log "adding the Docker apt repository"
  if ! apt-key list 2>/dev/null | grep -qi 'docker@docker.com'; then
    if (( DRY_RUN )); then
      echo "DRY-RUN: curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -"
    else
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    fi
  fi

  tmp=$(mktemp)
  printf 'deb [arch=amd64] https://download.docker.com/linux/ubuntu %s stable\n' "$codename" > "$tmp"
  run install -m 0644 "$tmp" /etc/apt/sources.list.d/docker.list
  rm -f "$tmp"

  run env DEBIAN_FRONTEND=noninteractive apt-get update -q
  log "installing docker packages"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "${DOCKER_PKGS[@]}"
  ok "docker installed"
fi

# ---------------------------------------------------------------------------
# 2. seccomp profile + daemon.json
# ---------------------------------------------------------------------------
SECCOMP_SRC="$ROOT/scripts/seccomp-lab.json"
SECCOMP_DST=/etc/docker/seccomp-lab.json
DAEMON_JSON=/etc/docker/daemon.json
restart_docker=0

[[ -f "$SECCOMP_SRC" ]] || die "missing $SECCOMP_SRC (run from a full checkout)"

if [[ ! -f "$SECCOMP_DST" ]] || ! cmp -s "$SECCOMP_SRC" "$SECCOMP_DST"; then
  log "installing seccomp profile to $SECCOMP_DST"
  run mkdir -p /etc/docker
  run install -m 0644 "$SECCOMP_SRC" "$SECCOMP_DST"
  restart_docker=1
else
  ok "seccomp profile up to date"
fi

if [[ ! -f "$DAEMON_JSON" ]]; then
  log "writing $DAEMON_JSON"
  tmp=$(mktemp)
  printf '{"seccomp-profile": "%s"}\n' "$SECCOMP_DST" > "$tmp"
  run install -m 0644 "$tmp" "$DAEMON_JSON"
  rm -f "$tmp"
  restart_docker=1
elif ! grep -q '"seccomp-profile"' "$DAEMON_JSON"; then
  # keep any existing daemon settings and add ours
  if command -v python3 >/dev/null 2>&1; then
    log "adding seccomp-profile to the existing $DAEMON_JSON"
    if (( DRY_RUN )); then
      echo "DRY-RUN: python3 merge seccomp-profile into $DAEMON_JSON"
    else
      python3 - "$DAEMON_JSON" "$SECCOMP_DST" <<'PY'
import json, sys
path, profile = sys.argv[1], sys.argv[2]
with open(path) as fh:
    cfg = json.load(fh)
cfg["seccomp-profile"] = profile
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
    fi
    restart_docker=1
  else
    warn "$DAEMON_JSON exists without seccomp-profile and python3 is missing"
    warn "add manually: {\"seccomp-profile\": \"$SECCOMP_DST\"}"
  fi
else
  ok "daemon.json already references the seccomp profile"
fi

if (( restart_docker )); then
  log "restarting docker to apply the profile"
  run systemctl restart docker
fi

# ---------------------------------------------------------------------------
# 3. Docker Compose v2 standalone binary
# ---------------------------------------------------------------------------
COMPOSE_BIN=/usr/local/bin/docker-compose
if [[ "$COMPOSE_VERSION" == "latest" ]]; then
  COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64"
else
  COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
fi

installed_compose=""
if [[ -x "$COMPOSE_BIN" ]]; then
  installed_compose="$(DOCKER_API_VERSION=1.39 "$COMPOSE_BIN" version 2>/dev/null | head -n1 || true)"
fi

if [[ "$installed_compose" == *"${COMPOSE_VERSION#v}"* ]]; then
  ok "docker-compose $COMPOSE_VERSION already installed"
else
  log "installing docker-compose $COMPOSE_VERSION to $COMPOSE_BIN"
  run curl -fsSL -o /tmp/docker-compose "$COMPOSE_URL"
  run install -m 0755 /tmp/docker-compose "$COMPOSE_BIN"
  run rm -f /tmp/docker-compose
  ok "docker-compose installed"
fi

# ---------------------------------------------------------------------------
# 4. make + docker service + docker group for the invoking user
# ---------------------------------------------------------------------------
log "installing make"
run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends make

run systemctl enable docker
if ! systemctl is-active --quiet docker; then
  log "starting the docker daemon"
  run systemctl start docker
fi

target_user="${SUDO_USER:-}"
if [[ -n "$target_user" && "$target_user" != "root" ]]; then
  if id -nG "$target_user" 2>/dev/null | grep -qw docker; then
    ok "$target_user is already in the docker group"
  else
    run usermod -aG docker "$target_user"
    warn "$target_user added to the docker group - re-login for it to apply"
  fi
fi

# ---------------------------------------------------------------------------
# 5. verify
# ---------------------------------------------------------------------------
if (( ! DRY_RUN )); then
  echo
  log "installed versions"
  docker --version
  docker info -f 'docker server: {{.ServerVersion}}' 2>/dev/null || warn "docker daemon not reachable"
  DOCKER_API_VERSION=1.39 DOCKER_BUILDKIT=0 "$COMPOSE_BIN" version
  echo
  ok "dependencies ready - next: sudo ./scripts/network-setup.sh && ./scripts/labs.sh up"
fi
