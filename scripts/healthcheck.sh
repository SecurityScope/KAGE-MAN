#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/healthcheck.sh
#
# Container-level healthcheck for every lab (fast; no network probing):
#   1. the compose file parses and interpolates cleanly
#   2. each service has a running container (plus Docker health status
#      when the service defines a healthcheck)
#   3. each container is attached to the networks - and IPv4 addresses -
#      declared in its compose file (catches stale containers / IP drift)
#   4. bind mounts resolve inside the lab directory or the vendored vulhub/
#      tree (catches containers left over from before a repository move)
#
# Usage:
#   ./scripts/healthcheck.sh               # every lab
#   ./scripts/healthcheck.sh struts2       # only labs whose path matches
#
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_API_VERSION="${DOCKER_API_VERSION:-1.39}"

command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

compose_bin() {
  local c
  for c in "${COMPOSE_BIN:-}" "${HOME}/.local/bin/docker-compose" /usr/local/bin/docker-compose; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v docker-compose
}
COMPOSE="$(compose_bin)" || { echo "error: docker-compose not found" >&2; exit 1; }

# Lab composes live at <repo>/<app>__<cve>/docker-compose.yml (depth 2);
# the vendored sources under vulhub/ (depth 3) are excluded by -maxdepth 2.
mapfile -t FILES < <(find "$ROOT" -mindepth 2 -maxdepth 2 -name 'docker-compose*.y*ml' -size +0c | sort)
filters=("$@")
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

pass=0; fail=0; failed=()

for f in "${FILES[@]}"; do
  lab="${f#$ROOT/}"; lab="${lab%%/docker-compose*}"

  tmpcfg=$(mktemp); tmperr=$(mktemp)
  if ! "$COMPOSE" -f "$f" config --format json >"$tmpcfg" 2>"$tmperr"; then
    printf '\033[1;31m[FAIL]\033[0m %-24s compose config invalid: %s\n' \
      "$lab" "$(tail -n1 "$tmperr")"
    rm -f "$tmpcfg" "$tmperr"
    fail=$((fail+1)); failed+=("$lab")
    continue
  fi

  out=$(python3 - "$tmpcfg" "$lab" "$f" "$ROOT" <<'PY'
import json, os, subprocess, sys

lab = sys.argv[2]
compose_file = os.path.abspath(sys.argv[3])
repo_root = os.path.abspath(sys.argv[4])
lab_dir = os.path.dirname(compose_file)
# generated labs bind-mount vendored lab content from vulhub/ on purpose
vulhub_dir = os.path.join(repo_root, "vulhub")

with open(sys.argv[1]) as fh:
    cfg = json.load(fh)

def run(*args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          universal_newlines=True).stdout

proj = cfg.get("name") or lab.lower()
nets = cfg.get("networks") or {}

def real_net(key):
    spec = nets.get(key) or {}
    name = spec.get("name")
    if name:
        return name
    return "{}_{}".format(proj, key) if key == "default" else key

expected = {}
for svc, spec in (cfg.get("services") or {}).items():
    wanted = []
    sn = spec.get("networks") or {}
    if isinstance(sn, list):
        for key in sn:
            wanted.append((real_net(key), None))
    elif isinstance(sn, dict):
        for key, nspec in sn.items():
            ip = nspec.get("ipv4_address") if isinstance(nspec, dict) else None
            wanted.append((real_net(key), ip))
    expected[svc] = wanted

ids = run("docker", "ps", "-aq",
          "--filter", "label=com.docker.compose.project=" + proj).split()
actual = {}
if ids:
    for line in run("docker", "inspect", "--format", "{{json .}}", *ids).splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        svc = ((obj.get("Config") or {}).get("Labels") or {}).get(
            "com.docker.compose.service")
        if svc:
            actual[svc] = obj

problems = []
for svc in sorted(expected):
    obj = actual.get(svc)
    if obj is None:
        problems.append("{}: container missing".format(svc))
        continue
    state = (obj.get("State") or {}).get("Status")
    if state != "running":
        problems.append("{}: state={}".format(svc, state))
        continue
    health = ((obj.get("State") or {}).get("Health") or {}).get("Status")
    if health == "unhealthy":
        problems.append("{}: docker health=unhealthy".format(svc))
    elif health == "starting":
        problems.append("{}: docker health=starting (still booting)".format(svc))
    have = (obj.get("NetworkSettings") or {}).get("Networks") or {}
    for net, ip in expected[svc]:
        if net not in have:
            problems.append("{}: not attached to network {}".format(svc, net))
        elif ip and (have[net].get("IPAddress") or "") != ip:
            problems.append("{}: {} has ip {}, compose says {}".format(
                svc, net, have[net].get("IPAddress") or "none", ip))
    for m in obj.get("Mounts") or []:
        if m.get("Type") != "bind":
            continue
        src = m.get("Source")
        if not src:
            continue
        src = os.path.abspath(src)
        in_lab = src == lab_dir or src.startswith(lab_dir + os.sep)
        in_vulhub = src == vulhub_dir or src.startswith(vulhub_dir + os.sep)
        if src.startswith(repo_root + os.sep) and not (in_lab or in_vulhub):
            problems.append(
                "{}: stale bind mount source {} (outside {} and vulhub/)".format(svc, src, lab_dir))

for svc in sorted(set(actual) - set(expected)):
    problems.append("{}: orphan container (not defined in compose)".format(svc))

if problems:
    print("\n".join(problems))
    sys.exit(1)

print("{} service(s) running, networks + mounts ok".format(len(expected)))
sys.exit(0)
PY
)
  rc=$?
  rm -f "$tmpcfg" "$tmperr"

  if (( rc == 0 )); then
    printf '\033[1;32m[PASS]\033[0m %-24s %s\n' "$lab" "$out"
    pass=$((pass+1))
  else
    printf '\033[1;31m[FAIL]\033[0m %-24s\n' "$lab"
    sed 's/^/         - /' <<<"$out"
    fail=$((fail+1)); failed+=("$lab")
  fi
done

printf '\n%d passed, %d failed' "$pass" "$fail"
(( fail )) && printf ' -> %s' "${failed[*]}"
printf '\n'
(( fail == 0 ))
