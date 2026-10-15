#!/usr/bin/env bash
#
# KAGE-MAN.DOJO :: scripts/gen-labs.sh
#
# Generate self-contained, macvlan-ready compose files for this range from the
# vendored lab sources in ./vulhub/.
#
# For every lab listed in labs.manifest it reads the vendored
#   vulhub/<app>/<cve>/docker-compose.yml
# and writes
#   <app>__<cve>/docker-compose.yml
# that:
#   * attaches the attacker-facing service to the range's macvlan segment with
#     the manifest's static ipv4_address, and drops all host port mappings
#   * puts dependency services (db/redis/init) on a private internal bridge
#     (<lab>_backend); the frontend joins that bridge too so it can reach them
#   * rewrites bind-mount sources and build contexts to paths RELATIVE to the
#     generated lab directory (../vulhub/...), so a fresh clone works without
#     regenerating
#   * adds restart: unless-stopped and a stable container_name
# It also (re)writes smoke.tests consumed by scripts/smoke-test.sh.
#
# Usage:
#   ./scripts/gen-labs.sh            # generate everything
#   ./scripts/gen-labs.sh --check    # parse only, write nothing
#
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

[[ -f "$ROOT/labs.manifest" ]] || { echo "error: labs.manifest missing" >&2; exit 1; }
[[ -f "$ROOT/segments.conf" ]] || { echo "error: segments.conf missing" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
python3 -c "import yaml" 2>/dev/null || { echo "error: python3 PyYAML (python3-yaml) not found" >&2; exit 1; }

python3 - "$ROOT" "$CHECK" <<'PY'
import os, re, sys, yaml

ROOT, CHECK = sys.argv[1], sys.argv[2] == "1"
VH    = os.path.join(ROOT, "vulhub")
PREFIX = re.sub(r'[^a-z0-9]+', '', os.path.basename(ROOT).lower()) or "lab"

# container ports ranked so the "primary" (the one the student attacks) wins over
# debug / wire / secondary ports that also happen to be exposed.
PORT_PRIORITY = [80, 8080, 8090, 8983, 3000, 10000, 5984, 9200, 7001, 8161, 9001,
                 6800, 8000, 445, 6379, 3306, 5432, 2222, 22, 1099, 61616, 443,
                 8009, 50000, 5005]
HTTP_PORTS = {80, 8080, 8090, 8983, 3000, 10000, 5984, 9200, 7001, 8161, 9001, 6800, 8000}

def die(msg):
    sys.stderr.write("error: %s\n" % msg); sys.exit(1)

# ---- segments.conf: key iface docker-network subnet gateway host-ip default ----
segs = {}
with open(os.path.join(ROOT, "segments.conf")) as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if len(f) < 4:
            continue
        key, iface, net, subnet = f[0], f[1], f[2], f[3]
        segs[key] = {"iface": iface, "net": net, "subnet": subnet}

def compose_path(lab):
    for n in ("docker-compose.yml", "docker-compose.yaml"):
        p = os.path.join(VH, lab, n)
        if os.path.isfile(p):
            return p
    return None

def container_ports(svc):
    out = []
    for p in (svc.get("ports") or []):
        if isinstance(p, dict):
            t = p.get("target")
            if t is not None:
                out.append(int(t))
        else:
            s = str(p).split("/")[0]
            try:
                out.append(int(s.split(":")[-1]))
            except ValueError:
                pass
    for e in (svc.get("expose") or []):
        try:
            out.append(int(str(e)))
        except ValueError:
            pass
    # de-dup preserving order
    seen, res = set(), []
    for p in out:
        if p not in seen:
            seen.add(p); res.append(p)
    return res

def rel(path, destdir):
    return os.path.relpath(path, destdir)

def fix_volumes(svc, labdir, destdir):
    vols = svc.get("volumes")
    if not vols:
        return
    fixed = []
    for v in vols:
        if isinstance(v, dict):
            if v.get("type") == "bind" and v.get("source"):
                src = v["source"]
                if not os.path.isabs(src):
                    v["source"] = rel(os.path.normpath(os.path.join(labdir, src)), destdir)
            fixed.append(v)
            continue
        parts = str(v).split(":")
        src = parts[0]
        if src.startswith(".") or src.startswith("/") or src.startswith("~"):
            abssrc = os.path.normpath(os.path.join(labdir, os.path.expanduser(src))) \
                     if not os.path.isabs(os.path.expanduser(src)) else os.path.expanduser(src)
            parts[0] = rel(abssrc, destdir)
            fixed.append(":".join(parts))
        else:
            fixed.append(v)  # named volume -> keep
    svc["volumes"] = fixed

def named_volumes(svc):
    out = set()
    for v in (svc.get("volumes") or []):
        if isinstance(v, dict):
            continue
        src = str(v).split(":")[0]
        if not (src.startswith(".") or src.startswith("/") or src.startswith("~")):
            out.add(src)
    return out

def fix_build(svc, labdir, destdir):
    b = svc.get("build")
    if b is None:
        return
    if isinstance(b, str):
        svc["build"] = {"context": rel(os.path.normpath(os.path.join(labdir, b)), destdir)}
    elif isinstance(b, dict):
        ctx = b.get("context", ".")
        if not os.path.isabs(ctx):
            b["context"] = rel(os.path.normpath(os.path.join(labdir, ctx)), destdir)

def fix_env_file(svc, labdir, destdir):
    ef = svc.get("env_file")
    if ef is None:
        return
    if isinstance(ef, str):
        ef = [ef]
    svc["env_file"] = [p if os.path.isabs(p) else rel(os.path.normpath(os.path.join(labdir, p)), destdir) for p in ef]

def pick_frontend(services, override):
    if override and override in services:
        return override
    withports = [n for n, s in services.items() if container_ports(s or {})]
    if len(withports) == 1:
        return withports[0]
    if withports:
        def rank(n):
            ps = container_ports(services[n] or {})
            best = min((PORT_PRIORITY.index(p) for p in ps if p in PORT_PRIORITY),
                       default=999)
            return best
        return sorted(withports, key=rank)[0]
    return next(iter(services))

def primary_port(svc, override):
    if override:
        return int(override)
    ps = container_ports(svc)
    if not ps:
        return None
    for p in PORT_PRIORITY:
        if p in ps:
            return p
    return ps[0]

# ---- manifest: lab_path  ip  seg_key  [frontend]  [primary_port]  [extra-homes] ----
rows = []
with open(os.path.join(ROOT, "labs.manifest")) as fh:
    for ln, line in enumerate(fh, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if len(f) < 3:
            die("labs.manifest:%d: need at least lab_path ip seg_key" % ln)
        rows.append({
            "lab": f[0][len("vulhub/"):] if f[0].startswith("vulhub/") else f[0],
            "ip": f[1], "seg": f[2],
            "frontend": f[3] if len(f) > 3 and f[3] != "-" else None,
            "pport": f[4] if len(f) > 4 and f[4] != "-" else None,
            # optional dual-homing for pivot seams: seg:ip[,seg:ip ...]
            "extra": f[5] if len(f) > 5 and f[5] != "-" else None,
        })

smoke = []
ndone = 0
for r in rows:
    lab, ip, seg = r["lab"], r["ip"], r["seg"]
    if seg not in segs:
        die("lab %s references unknown segment '%s' (not in segments.conf)" % (lab, seg))
    cp = compose_path(lab)
    if not cp:
        die("vendored compose not found for %s (expected under vulhub/)" % lab)
    labdir = os.path.dirname(cp)
    destdir = os.path.join(ROOT, lab.replace("/", "__"))
    with open(cp) as fh:
        up = yaml.safe_load(fh) or {}
    services = up.get("services") or {}
    if not services:
        die("%s has no services" % lab)

    frontend = pick_frontend(services, r["frontend"])
    multi = len(services) > 1
    segnet, backnet = "labseg", "labnet"
    slug = re.sub(r'[^a-z0-9]+', '-', lab.lower()).strip('-')

    # primary home + optional extra homes (dual-homed pivot seams)
    homes = [(segnet, segs[seg]["net"], ip)]
    if r["extra"]:
        for i, pair in enumerate(r["extra"].split(","), 1):
            k, _, xip = pair.partition(":")
            if k not in segs or not xip:
                die("lab %s has bad extra home '%s'" % (lab, pair))
            homes.append(("labseg%d" % i, segs[k]["net"], xip))

    out = {"version": "2.4", "services": {}, "networks": {}}
    for alias, netname, _xip in homes:
        out["networks"][alias] = {"external": True, "name": netname}
    if multi:
        out["networks"][backnet] = {"driver": "bridge", "internal": True}

    top_vols = set()
    for name, s in services.items():
        s = dict(s or {})
        # One-shot init/setup containers (run a command, depend on another
        # service, expose no ports) must NOT get restart:unless-stopped, or they
        # exit 0 and loop forever. Detect before we strip ports below.
        one_shot = (name != frontend and "command" in s
                    and "depends_on" in s and "ports" not in s)
        s.pop("ports", None)
        s.pop("network_mode", None)
        s.pop("networks", None)
        top_vols |= named_volumes(s)
        fix_volumes(s, labdir, destdir)
        fix_build(s, labdir, destdir)
        fix_env_file(s, labdir, destdir)
        s["restart"] = "no" if one_shot else "unless-stopped"
        s["container_name"] = re.sub(r'-+', '-', "%s-%s-%s" % (PREFIX, slug, name))[:60]
        if name == frontend:
            nets = {}
            for alias, _netname, xip in homes:
                nets[alias] = {"ipv4_address": xip}
            if multi:
                nets[backnet] = None
            s["networks"] = nets
        else:
            s["networks"] = [backnet]
        out["services"][name] = s

    keep_vols = (up.get("volumes") or {})
    vols_out = {v: (keep_vols.get(v) if isinstance(keep_vols, dict) else None) for v in top_vols}
    if vols_out:
        out["volumes"] = vols_out

    pport = primary_port(services[frontend] or {}, r["pport"])
    check = "tcp"
    if pport in HTTP_PORTS:
        check = "http"
    if pport:
        smoke.append("%-26s|%-16s|%-15s|%-5s|%s" %
                     (slug, segs[seg]["net"], ip, pport, check))

    dest = os.path.join(destdir, "docker-compose.yml")
    if CHECK:
        print("[check] %-42s frontend=%-10s port=%s %s" %
              (lab, frontend, pport, "(multi)" if multi else ""))
        continue
    os.makedirs(destdir, exist_ok=True)
    header = ("# GENERATED by scripts/gen-labs.sh from vulhub/%s -- do not edit by hand.\n"
              "# Upstream content (Dockerfiles, mounts) still lives in vulhub/%s.\n"
              % (lab, lab))
    with open(dest, "w") as fh:
        fh.write(header)
        yaml.safe_dump(out, fh, default_flow_style=False, sort_keys=False)
    print("[gen]   %-42s -> %s/" % (lab, lab.replace("/", "__")))
    ndone += 1

if not CHECK:
    with open(os.path.join(ROOT, "smoke.tests"), "w") as fh:
        fh.write("# GENERATED by scripts/gen-labs.sh -- lab|network|ip|port|check\n")
        fh.write("\n".join(smoke) + "\n")
    print("\n%d lab(s) generated; smoke.tests updated (%d endpoints)." % (ndone, len(smoke)))
PY
rc=$?
exit $rc
