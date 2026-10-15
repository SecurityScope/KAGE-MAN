#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/labs.sh
#
# Build / start / stop every lab compose project in this repository.
#
# Usage:
#   ./scripts/labs.sh build             # build all lab images
#   ./scripts/labs.sh up                # build + start all labs
#   ./scripts/labs.sh up activemq       # only lab dirs matching "activemq"
#   ./scripts/labs.sh down              # stop containers (keep volumes)
#   ./scripts/labs.sh reset             # stop containers AND delete lab volumes
#   ./scripts/labs.sh ps                # list running lab containers
#   ./scripts/labs.sh logs struts2
#
# EXCLUDE=struts2 ./scripts/labs.sh build   # skip labs whose path matches
#
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_API_VERSION="${DOCKER_API_VERSION:-1.39}"
# classic builder is the reliable path on old hosts (Docker CE on kernel 4.4)
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"

compose_bin() {
  local c
  for c in "${COMPOSE_BIN:-}" "${HOME}/.local/bin/docker-compose" /usr/local/bin/docker-compose; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v docker-compose
}
COMPOSE="$(compose_bin)" || { echo "error: docker-compose not found" >&2; exit 1; }

action="${1:-}"
[[ $# -gt 0 ]] && shift
filters=("$@")

# Lab composes live at <repo>/<app>__<cve>/docker-compose.yml (depth 2);
# the vendored sources under vulhub/ (depth 3) are excluded by -maxdepth 2.
mapfile -t FILES < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name 'docker-compose*.y*ml' -size +0c | sort)
if [[ -n "${EXCLUDE:-}" ]]; then
  keep=()
  for f in "${FILES[@]}"; do
    [[ "$f" == *"$EXCLUDE"* ]] || keep+=("$f")
  done
  FILES=("${keep[@]}")
fi
if (( ${#filters[@]} )); then
  keep=()
  for f in "${FILES[@]}"; do
    for flt in "${filters[@]}"; do
      [[ "$f" == *"$flt"* ]] && { keep+=("$f"); break; }
    done
  done
  FILES=("${keep[@]}")
  (( ${#FILES[@]} )) || { echo "no lab matched: ${filters[*]}" >&2; exit 1; }
fi

lab_name() { local rel="${1#$ROOT/}"; printf '%s\n' "${rel%%/docker-compose*}"; }

case "$action" in
  build|up|down|reset)
    rc=0
    for f in "${FILES[@]}"; do
      printf '\n\033[1;34m==> %s : %s\033[0m\n' "$action" "$(lab_name "$f")"
      case "$action" in
        build) "$COMPOSE" -f "$f" build                     || rc=1 ;;
        up)    "$COMPOSE" -f "$f" up -d --build             || rc=1 ;;
        down)  "$COMPOSE" -f "$f" down                      || rc=1 ;;
        reset) "$COMPOSE" -f "$f" down -v --remove-orphans  || rc=1 ;;
      esac
    done
    if (( rc == 0 )); then
      printf '\n\033[1;32m[all done]\033[0m\n'
    else
      printf '\n\033[1;31m[some labs failed - see output above]\033[0m\n'
    fi
    exit $rc
    ;;
  ps)
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
    ;;
  logs)
    for f in "${FILES[@]}"; do
      printf '\n\033[1;34m==> logs: %s\033[0m\n' "$(lab_name "$f")"
      "$COMPOSE" -f "$f" logs --tail=50
    done
    ;;
  *)
    sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
