<p align="center">
  <img src="assets/images/logo.png" alt="KAGE-MAN.DOJO — Cybersecurity Lab" width="460">
</p>

# KAGE-MAN.DOJO

*A self-contained Metasploit practice range — three segments, **26 vulnerable
labs**, one continuous campaign.*

`KAGE-MAN.DOJO` is a complete, offline-capable training range for the
Metasploit Framework. A single Ubuntu VM hosts three macvlan segments — a WAN
"internet edge", a DMZ and an INTERNAL network — populated with 26 curated
vulnerable applications. A student Kali attached to the **WAN only** walks the
whole range: exploit internet-facing services, cross a dual-homed pivot into
the DMZ, cross a second seam into INTERNAL, and finish with a persistence
exam where `msfvenom` payloads survive restarts and a real reboot.

The course spans three belts in one campaign:

| Forms | Belt | What you practice |
|---|---|---|
| 1 | white | WAN attack surface + the door into the DMZ: ready-made modules (`use`/`set`/`run`) |
| 2 | brown | Configure, chain and auxiliary-driven access — including the DMZ→INTERNAL seam |
| 3 | black | Manual exploitation + full `msfvenom` → handler → post workflow (JNDI relay, staging via the seam) |
| 4 | — | Pivot masterclass: autoroute, socks, portfwd, reverse-through-pivot relays |
| 5 | **capstone** | **Persistence:** web payloads, backdoor accounts, SSH keys, systemd/cron beacons — verified across a reboot |

Everything needed is in this repository: the lab sources are vendored under
[`vulhub/`](vulhub/), the compose files are generated (and committed) with
**relative paths**, and the tooling is plain shell + `make`. A fresh clone
runs as-is.

| | |
|---|---|
| Host name | `KAGE-MAN` (fqdn `kage-man.dojo`) |
| Range type | 3 macvlan segments · 26 labs · vendored lab sources |
| OS / platform | Ubuntu 20.04 VirtualBox VM, Docker host (16.04 also supported by `make install-deps`) |
| NICs | `enp0s3` (DMZ), `enp0s8` (INTERNAL), `enp0s9` (WAN) |
| Host addresses | `.250` on every segment (`192.168.80.250`, `172.16.80.250`, `10.0.8.250`) |
| Segments | WAN `10.0.8.0/24`, DMZ `192.168.80.0/24`, INTERNAL `172.16.80.0/24` |
| Source of truth | [`labs.manifest`](labs.manifest) + [`segments.conf`](segments.conf) |
| Sizing | `polkit` needs ~2 GB and boots slowly (inner VM); `minio` runs three nodes; JVM labs — batch per lesson |

## Architecture

One VirtualBox VM with three NICs, one per segment. Each NIC is the **parent
interface** of a Docker macvlan network, so every lab container is a
first-class endpoint of its segment — its own MAC and IP, **no host port
mappings**. [`scripts/gen-labs.sh`](scripts/gen-labs.sh) reads
[`labs.manifest`](labs.manifest) and emits a self-contained macvlan compose per
lab into `<app>__<cve>/`; multi-service labs keep their datastore on a private
internal bridge (`labnet`) so only the front-end is exposed on the segment.

```text
          VirtualBox NAT networks (L2 + outbound NAT)
   KAGE-DOJO-WAN           KAGE-DOJO-DMZ            KAGE-DOJO-INT
     10.0.8.0/24           192.168.80.0/24          172.16.80.0/24
         │                       │                        │
         │ enp0s9                │ enp0s3                 │ enp0s8
    ┌────┴───────────────────────┴────────────────────────┴────┐
    │ KAGE-MAN — Ubuntu VM / Docker host                       │
    │ host .250 on each segment · default route via the DMZ    │
    │                                                          │
    │   macvlan KAGE-DOJO-WAN  ← internet edge (7 services)    │
    │   macvlan KAGE-DOJO-DMZ  ← 11 targets + the pivot seam   │
    │   macvlan KAGE-DOJO-INT  ← 8 targets + persistence host  │
    │   private bridge "labnet" ← datastores (multi-svc labs)  │
    └───────────────────────────────────────────────────────────┘
         ▲
   student Kali (WAN)  ──▶ foothold ──▶ seam ──▶ INTERNAL
   (never leaves the WAN seat: two autoroutes are the only road in)
```

### Segments and host NICs

| Segment | Docker network | Host NIC | Host IP | Subnet | Gateway | Default route |
|---|---|---|---|---|---|---|
| DMZ | `KAGE-DOJO-DMZ` | `enp0s3` | `192.168.80.250` | `192.168.80.0/24` | `192.168.80.1` | **yes** |
| INTERNAL | `KAGE-DOJO-INT` | `enp0s8` | `172.16.80.250` | `172.16.80.0/24` | `172.16.80.1` | no (segment-local) |
| WAN | `KAGE-DOJO-WAN` | `enp0s9` | `10.0.8.250` | `10.0.8.0/24` | `10.0.8.1` | no (segment-local) |

Only the DMZ NIC carries the default route; INTERNAL and WAN are
segment-local, which is exactly what forces the campaign to be pivoted rather
than routed. The macvlan design means **the host cannot reach its own
containers** — verify from inside a segment with `make health` / `make smoke`,
not with `curl` from the host.

### The pivot seams (dual-homed labs)

Two labs are dual-homed via the manifest's `extra-homes` column; they are the
seams the whole campaign walks through:

| Lab | Role | Home A | Home B (seam) |
|---|---|---|---|
| `activemq/CVE-2023-46604` | pivot **foothold** (the only WAN door) | WAN `10.0.8.20` | DMZ `192.168.80.20` |
| `tomcat/tomcat8` | pivot **seam** (DMZ→INTERNAL) | DMZ `192.168.80.23` | INTERNAL `172.16.80.20` |

Everything on INTERNAL is reachable **only** after the seam is crossed, via
Metasploit `autoroute` (or the socks/portfwd channels built in Form 4). The
other six WAN services are deliberate dead ends.

## Lab inventory

26 labs across three segments. Addresses are static; "Port" is the service
port on the segment (there are no host port mappings).

### WAN — the internet edge (7)

| # | Lab | IP | Port | Belt | MSF role |
|---|---|---|---|---|---|
| 1 | `activemq/CVE-2023-46604` | `10.0.8.20` (+dmz `.20`) | 61616 | white | `exploit/multi/misc/apache_activemq_rce_cve_2023_46604`: Spring-XML fetch → `cmd/unix/reverse_bash` → Meterpreter upgrade; **the only door** into the DMZ |
| 2 | `struts2/s2-045` | `10.0.8.21` | 8080 | white | `exploit/multi/http/struts2_content_type_ognl` — dead end |
| 3 | `spring/CVE-2022-22965` | `10.0.8.22` | 8080 | white | `exploit/multi/http/spring_framework_rce_spring4shell` — dead end |
| 4 | `cacti/CVE-2022-46169` | `10.0.8.23` | 80 | white | `exploit/linux/http/cacti_unauthenticated_cmd_injection` — dead end |
| 5 | `joomla/CVE-2015-8562` | `10.0.8.24` | 80 | white | `exploit/multi/http/joomla_http_header_rce` — dead end |
| 6 | `opensmtpd/CVE-2020-7247` | `10.0.8.25` | 25 | white | `exploit/unix/smtp/opensmtpd_mail_from_rce` — dead end |
| 7 | `erlang/CVE-2025-32433` | `10.0.8.26` | 2222 | white | `exploit/linux/ssh/ssh_erlangotp_rce` — dead end |

### DMZ — reachable only through the WAN door (11)

| # | Lab | IP | Port | Belt | MSF role |
|---|---|---|---|---|---|
| 8 | `couchdb/CVE-2017-12635` | `192.168.80.21` | 5984 | white | `exploit/linux/http/apache_couchdb_cmd_exec` |
| 9 | `redis/4-unacc` | `192.168.80.22` | 6379 | white | `exploit/linux/redis/redis_replication_cmd_exec` |
| 10 | `httpd/CVE-2021-41773` | `192.168.80.25` | 80 | white | `exploit/multi/http/apache_normalize_path_rce` (traversal → CGI RCE) |
| 11 | `samba/CVE-2017-7494` | `192.168.80.26` | 445 | white | `exploit/linux/samba/is_known_pipename` + `cmd/unix/interact` |
| 12 | `drupal/CVE-2018-7600` | `192.168.80.27` | 80 | white | `exploit/unix/webapp/drupal_drupalgeddon2`; web-root persistence host (Form 5) |
| 13 | `webmin/CVE-2019-15107` | `192.168.80.28` | 10000 | white | `exploit/linux/http/webmin_backdoor` (`set SSL true`) — root |
| 14 | `thinkphp/5-rce` | `192.168.80.29` | 80 | white | `exploit/unix/webapp/thinkphp_rce` |
| 15 | `tomcat/tomcat8` | `192.168.80.23` (+int `.20`) | 8080 | brown | `exploit/multi/http/tomcat_mgr_upload` (creds in lab README); the pivot **seam**, payload CDN and JSP persistence host |
| 16 | `php/8.1-backdoor` | `192.168.80.24` | 80 | brown/black | `User-Agentt` backdoor → `msfvenom` PHP bind payload; PHP persistence host |
| 17 | `libssh/CVE-2018-10933` | `192.168.80.30` | 22 | brown | aux `auxiliary/scanner/ssh/libssh_auth_bypass` (Action `Shell` → session, no password) |
| 18 | `supervisor/CVE-2017-11610` | `192.168.80.31` | 9001 | brown | `exploit/linux/http/supervisor_xmlrpc_exec` (lab XML-RPC runs without auth) |

### INTERNAL — reachable only through the seam (8)

| # | Lab | IP | Port | Belt | MSF role |
|---|---|---|---|---|---|
| 19 | `mysql/CVE-2012-2122` | `172.16.80.45` | 3306 | brown | aux `auxiliary/scanner/mysql/mysql_authbypass_hashdump` → hashes for offline crack |
| 20 | `uwsgi/unacc` | `172.16.80.46` | 8000 | black | manual uwsgi packet (`UWSGI_FILE` magic var) → staged ELF → bind session |
| 21 | `python/unpickle` | `172.16.80.41` | 8000 | black | malicious pickle (`user` cookie) → staged ELF → bind session |
| 22 | `flask/ssti` | `172.16.80.42` | 8000 | black | Jinja2 SSTI (`?name=`) → staged ELF → bind session |
| 23 | `fastjson/1.2.24-rce` | `172.16.80.47` | 8090 | black | `JdbcRowSetImpl` JNDI chain over the **seam relay** (marshalsec / java-chains) → staged ELF |
| 24 | `minio/CVE-2023-28432` | `172.16.80.48` | 9000 | black | aux `auxiliary/gather/minio_bootstrap_verify_info_disc` → leaked root creds → `mc` impact |
| 25 | `postgres/CVE-2019-9193` | `172.16.80.44` | 5432 | brown/black | `exploit/multi/postgres/postgres_copy_from_program_cmd_exec` (creds in lab README) |
| 26 | `polkit/CVE-2021-4034` | `172.16.80.43` | 2222 (ssh) | black | SSH in (`ubuntu`/`vulhub`) → `exploit/linux/local/cve_2021_4034_pwnkit_lpe_pkexec`; **the persistence host** (real Ubuntu VM inside) |

Per-lab credentials and target notes live in each vendored lab README at
`vulhub/<app>/<cve>/README.md`. The five-form campaign over these labs — every
command, in order, ending with the persistence exam — is in
[`SYLLABUS.md`](SYLLABUS.md).

## Student access

- **Continuous campaign (default):** attach Kali to the **WAN** segment
  (`10.0.8.0/24`, e.g. `10.0.8.100`) and never move it. Every form is designed
  around that single attachment.
- **Drill mode (optional):** to rehearse a single form in isolation, soft-attach
  Kali to the DMZ (`192.168.80.0/24`) or INTERNAL (`172.16.80.0/24`). Every
  graded run is WAN-only.
- Optionally add `kage-man.dojo` and the lab IPs to the Kali `/etc/hosts`.

## Repository layout

```text
.
├── Makefile                  # every operation below as a make target
├── README.md  SYLLABUS.md    # this file + the five-form campaign
├── labs.manifest             # the range as configuration (lab, IP, segment, options)
├── segments.conf             # the three macvlan segments + host NICs/IPs
├── smoke.tests               # generated endpoint list (make smoke)
├── scripts/
│   ├── gen-labs.sh           # labs.manifest -> <app>__<cve>/docker-compose.yml
│   ├── network-setup.sh      # static NICs + promisc + macvlan networks
│   ├── labs.sh               # build / up / down / reset / ps / logs
│   ├── healthcheck.sh        # containers, IPs, networks, mounts
│   ├── smoke-test.sh         # endpoint probes from inside each segment
│   ├── install-deps.sh       # docker + seccomp + compose + make
│   └── seccomp-lab.json      # daemon seccomp profile (clone3 / faccessat2 / rseq)
├── vulhub/                   # vendored lab sources (26 labs; do not edit)
└── <app>__<cve>/docker-compose.yml   # generated, committed, relative paths
```

The generated composes reference the vendored sources with **relative paths**
(`../vulhub/...`), so the checkout is portable and works without regenerating.
Edit `labs.manifest` (or `segments.conf`) and run `make gen` to re-emit them.

## One-command build with Vagrant

The whole range host builds itself from a stock Ubuntu 20.04 box. From a
machine with **VirtualBox + Vagrant**:

```bash
vagrant up        # boots ubuntu/focal64, installs Docker, builds the three
                  # macvlan segments, generates every lab compose — READY
vagrant ssh
cd /opt/kage-man
make up LAB=activemq     # start a lesson at a time (see batching below)
```

`vagrant up` provisions the host but leaves the 26 labs **stopped** (bringing
them all up at once is RAM/disk heavy). To also start or pre-pull them, set
`KAGE_START`:

```bash
KAGE_START=build vagrant up          # pre-build/pull all images (offline-ready)
KAGE_START=up    vagrant up          # build AND start all 26 labs
KAGE_MEMORY=12288 KAGE_CPUS=6 vagrant up   # bigger box (defaults: 8192 MB / 4 vCPU)
```

Other knobs: `KAGE_BOX`, `KAGE_DISK` (needs `vagrant plugin install
vagrant-disksize`). See the header comments in [`Vagrantfile`](Vagrantfile).
The VM is named **`KAGE-MAN.DOJO`** in VirtualBox. Log in at the console as
**`vagrant` / `vagrant`** (passwordless `sudo`); `vagrant ssh` uses the
generated key and needs no password.

By default the VM runs **headless** (no window). To open the VirtualBox console
window — and see the dojo logo
([`assets/images/logo.bmp`](assets/images/logo.bmp), derived from `logo.png`)
as the firmware boot splash — start it with a GUI:

```bash
KAGE_GUI=1 vagrant up        # or: vagrant reload, if already running
```

The logo shows only in the GUI window during early boot; a headless VM never
displays it.

### VirtualBox networks

The three segments are **named VirtualBox NAT networks** (L2 + outbound NAT at
`.1`), created with `VBoxManage` from `segments.conf`:

| NAT network | Subnet | Host VM | Adapter |
|---|---|---|---|
| `KAGE-DOJO-DMZ` | `192.168.80.0/24` | `.250` | 2 |
| `KAGE-DOJO-INT` | `172.16.80.0/24` | `.250` | 3 |
| `KAGE-DOJO-WAN` | `10.0.8.0/24` | `.250` | 4 |

`vagrant up` creates them automatically (a `before :up` trigger), but you can
run the creator yourself — it works identically on Linux/macOS and Windows:

```bash
./scripts/vbox-networks.sh create            # Linux / macOS
./scripts/vbox-networks.sh list | remove
```
```powershell
powershell -ExecutionPolicy Bypass -File scripts\vbox-networks.ps1 create   # Windows
powershell -ExecutionPolicy Bypass -File scripts\vbox-networks.ps1 list      # (or: remove)
```

**Attacker:** attach a Kali VM to the **`KAGE-DOJO-WAN`** NAT network with a
static `10.0.8.x` address and walk the campaign from the WAN inward.

### WAN DNS — fake internet ([`dns/`](dns/))

A CoreDNS resolver on the WAN (`10.0.8.53`) makes the seven WAN services look
like real internet sites: it answers the names in
[`dns/dojo.hosts`](dns/dojo.hosts) (e.g. `www.shopizer-online.com → 10.0.8.21`,
with auto-generated reverse PTR) and forwards everything else upstream, so
unknown names resolve on the real internet when the host VM is online.

```bash
make up LAB=dns          # or: make dns      (start the resolver)
make down LAB=dns        # or: make dns-down
```

On the attacker box (also on the WAN), point DNS at it and browse by name:

```bash
echo 'nameserver 10.0.8.53' | sudo tee /etc/resolv.conf     # Kali, on the WAN
curl http://www.shopizer-online.com/                        # -> struts2 @ 10.0.8.21
```

Edit `dns/dojo.hosts` to change the names — CoreDNS reloads it live (no
restart). The resolver sits on the WAN macvlan, so it is reachable from other
VMs on the segment, not from the Docker host itself (normal macvlan behaviour).

**NIC note:** Vagrant owns adapter 1 as its management NAT, so the three lab
NICs come up as `enp0s8/enp0s9/enp0s10`, not the `enp0s3/enp0s8/enp0s9` that
`segments.conf` ships with. The Vagrantfile pins a fixed MAC on each segment
NIC, and the provisioner
([`scripts/vagrant-provision.sh`](scripts/vagrant-provision.sh)) uses those
MACs to assign the `.250` addresses and rewrite the iface column — so the
opaque NIC ordering never matters.

## Tooling quick start

Prefer this path when you are **already on an Ubuntu host** (bare metal, or a VM
you built yourself). Run everything from the repository root — no environment
variables required:

```bash
sudo make install-deps                    # once per host: docker + seccomp + compose + make
sudo make net                             # static NICs + promisc + macvlan networks
make up                                   # start every lab (heavy — prefer LAB below)
make up LAB=activemq                      # start only matching lab(s)
make health                               # containers running, IPs/network/mounts correct
make smoke                                # endpoint probes from inside the segments
make down                                 # stop (keep data); make reset wipes volumes
```

Raw scripts work the same way, e.g. `./scripts/labs.sh up struts2` or
`./scripts/labs.sh up activemq couchdb redis`.

### Module batching (important on this host)

The `polkit` lab runs a **full Ubuntu 20.04 VM inside the container** (QEMU;
~2 GB RAM, cloud-init boot in the order of ~10 minutes), the `minio` lab runs
**three nodes**, and several labs are JVM-heavy. **Do not bring up all 26 labs
at once.** Start only the lab(s) for the current lesson:

```bash
./scripts/labs.sh up activemq struts2 spring cacti joomla opensmtpd erlang   # WAN lessons
./scripts/labs.sh up couchdb redis httpd samba drupal webmin thinkphp        # DMZ lessons
./scripts/labs.sh up tomcat libssh supervisor mysql                          # seam + brown belt
./scripts/labs.sh up uwsgi unpickle ssti fastjson minio postgres polkit php  # black belt
./scripts/labs.sh down                                                       # between lessons
```

## Operations

- **The repository is the single source of truth.** Nothing is edited on the
  host: change `labs.manifest` / `segments.conf`, run `make gen`, then
  `./scripts/labs.sh up <lab>`.
- **The vendored `vulhub/` tree is never edited**; generated composes under
  `<app>__<cve>/` are disposable and regenerated from the manifest.
- **Static addressing, no DHCP** inside the lab networks; keep the VirtualBox
  NAT pools away from the `.20`–`.48` / `.250` scheme.
- **Promiscuous mode** is required on every lab NIC (macvlan); set the
  VirtualBox adapters to *Promiscuous Mode: Allow All*.
- **Datastores on `labnet`**: multi-service labs keep their DB on a private
  internal bridge, unreachable from the segment — only the front-end is
  exposed at the IP in the inventory.
- **Restart semantics** (matters for the persistence forms):
  `docker restart <container>` keeps everything written to the container
  filesystem; `labs.sh down` + `up` **recreates** the container (files lost);
  `labs.sh reset` also wipes named volumes. Persistence taught here is about
  surviving a *reboot of the service/host*, and the syllabus documents exactly
  which cleanup action removes each artifact.

## Safety notes

- **Take a VirtualBox snapshot before each class and roll back afterwards.**
  These are deliberately vulnerable services on simulated segments.
- The **`polkit` lab is heavy**: ~2 GB RAM and a slow inner-VM boot. Start it
  first when a lesson needs it, and don't run it alongside the JVM labs if the
  host is small.
- Local privilege escalation (PwnKit) **lands root inside its VM** — that is
  the intended outcome; treat a rooted lab as spent for the session.
- The persistence forms deliberately leave artifacts (accounts, keys, units,
  cron files, web shells). `SYLLABUS.md` ends with a cleanup checklist, and
  `make reset` returns any lab to a clean state.
- Keep the range on an isolated VirtualBox NAT network only.
