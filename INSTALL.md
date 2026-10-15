<p align="center">
  <b>English</b> · <a href="INSTALL_AR.md">العربية</a>
  &nbsp;|&nbsp; <a href="README.md">README</a>
</p>

# Installing KAGE-MAN.DOJO

One command builds the whole range on a single Ubuntu 20.04 VirtualBox VM:
Vagrant creates the networks, boots the VM, installs Docker, builds the three
macvlan segments, and builds + starts all 26 labs plus the WAN DNS resolver
(`restart=unless-stopped`, so they survive a reboot).

> You run the installer **on your host** (Linux, macOS, or Windows). It drives
> Vagrant/VirtualBox; everything else happens inside the VM. You do **not** run
> `setup.py` or `make` on your host — those are for inside the VM.

---

## 1. Host requirements

| | |
|---|---|
| **VirtualBox** | 6.1 or 7.x (tested on 7.2) |
| **Vagrant** | ≥ 2.2.14 |
| **CPU** | VT-x/AMD-V enabled in BIOS/UEFI; 4+ cores recommended |
| **RAM** | 8 GB for the VM by default; **12–16 GB free** recommended if you start all labs at once |
| **Disk** | ~40–80 GB free (26 lab images + the base box) |
| **Internet** | needed on first build (pulls the box, Docker, and lab images) |

The default VM is **8192 MB / 4 vCPU**. Starting all ~27 containers at once is
heavy — give it more (`KAGE_MEMORY`/`KAGE_CPUS`) or provision without starting
(`KAGE_START=none`, see §5).

---

## 2. Install the prerequisites

### Linux

| Distro | Command |
|---|---|
| Arch / CachyOS / Manjaro | `sudo pacman -S virtualbox virtualbox-host-dkms vagrant` |
| Debian / Ubuntu | `sudo apt-get install -y virtualbox vagrant` |
| Fedora / RHEL | `sudo dnf install -y VirtualBox vagrant` |
| openSUSE | `sudo zypper install -y virtualbox vagrant` |

After installing VirtualBox, load its kernel module and add yourself to the
group (log out/in afterwards):

```bash
sudo modprobe vboxdrv
sudo usermod -aG vboxusers "$USER"
```

### Windows

Use a package manager (run the shell as Administrator):

```powershell
winget install HashiCorp.Vagrant Oracle.VirtualBox
# or:  choco install -y vagrant virtualbox
```

Then **reopen** PowerShell so `vagrant` and `VBoxManage` are on `PATH`.

> **Hyper-V / WSL2 conflict:** VirtualBox cannot run VMs while Hyper-V owns
> virtualization. If VMs fail to start, disable Hyper-V / the Windows
> Hypervisor Platform (or run `bcdedit /set hypervisorlaunchtype off` and
> reboot). Docker Desktop (WSL2) typically re-enables Hyper-V.

### macOS

```bash
brew install --cask virtualbox vagrant
```

---

## 3. Get the code

```bash
git clone <this-repo-url> KAGE-MAN.DOJO
cd KAGE-MAN.DOJO
```

---

## 4. Build it — one command

### Linux / macOS

```bash
./install.sh
```

### Windows (PowerShell)

```powershell
.\install.ps1
# if scripts are blocked:
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Either wrapper checks the host prerequisites, then runs `vagrant up`. Plain
`vagrant up` works too — the wrappers just add the banner, dependency checks,
and convenience flags.

**What it does, in order:**

1. creates three VirtualBox NAT networks — `KAGE-DOJO-DMZ/INT/WAN`
2. boots the Ubuntu 20.04 VM named **`KAGE-MAN.DOJO`**
3. installs Docker + a seccomp profile + docker-compose + make
4. assigns the host `.250` address on each segment and builds the macvlan nets
5. generates every lab's compose file
6. builds **and starts** all 26 labs + the WAN DNS resolver

The first run takes a while (downloads + image builds). Subsequent
`vagrant up`s are fast.

---

## 5. Options

Flags (bash `--flag` / PowerShell `-Flag`):

| Flag | Effect |
|---|---|
| `--no-start` / `-NoStart` | provision + build, but don't start the labs |
| `--gui` / `-Gui` | open the VirtualBox window (shows the boot logo) |
| `--provision` / `-Provision` | re-run provisioning on an existing VM |
| `--destroy` / `-Destroy` | delete the VM |

Environment tunables (pass straight through to `vagrant up`):

| Variable | Default | Meaning |
|---|---|---|
| `KAGE_MEMORY` | `8192` | VM RAM (MB) |
| `KAGE_CPUS` | `4` | vCPUs |
| `KAGE_START` | `up` | `up` = build+start all · `build` = build only · `none` = provision only |
| `KAGE_GUI` | *(off)* | `1` opens the console window |
| `KAGE_BOX` | `ubuntu/focal64` | base box |
| `KAGE_DISK` | `80GB` | root disk (needs `vagrant plugin install vagrant-disksize`) |

```bash
KAGE_MEMORY=12288 KAGE_CPUS=6 ./install.sh      # bigger box
KAGE_START=none ./install.sh                     # provision only, start labs by hand
```

```powershell
$env:KAGE_MEMORY=12288; .\install.ps1
```

---

## 6. Use the range

```bash
vagrant ssh                       # log into the VM
cd /opt/kage-man                  # the range lives here inside the VM
sudo docker ps                    # what's running
make ps | make health | make smoke
make up LAB=activemq              # start one lab     (make down LAB=... to stop)
make up                           # start everything  (heavy)
```

**Credentials:** console login is `vagrant` / `vagrant` (passwordless `sudo`);
`vagrant ssh` uses the generated key and needs no password.

### Attacker box (Kali)

Attach a Kali VM to the **`KAGE-DOJO-WAN`** NAT network, give it a static
`10.0.8.x` address, and use the lab DNS:

```bash
echo 'nameserver 10.0.8.53' | sudo tee /etc/resolv.conf
curl http://www.shopizer-online.com/          # -> struts2 @ 10.0.8.21
```

Walk the campaign from the WAN inward (the WAN is the only entry point).

---

## 7. Manage the VM

```bash
vagrant halt                      # stop the VM (containers resume on next boot)
vagrant up                        # start it again
vagrant provision                 # re-run the full install/build
./install.sh --destroy            # delete the VM   (or: vagrant destroy KAGE-MAN.DOJO -f)
```

To remove the VirtualBox networks too: `./scripts/vbox-networks.sh remove`
(Linux/macOS) or `scripts\vbox-networks.ps1 remove` (Windows).

---

## 8. Troubleshooting

**`env: 'apt-get': No such file or directory` when running `setup.py`.**
You ran `setup.py` on your host. It only runs inside the Ubuntu VM — use
`vagrant ssh`, then `cd /opt/kage-man && sudo python3 setup.py`. On the host,
run `./install.sh` (or `vagrant up`) instead.

**`vagrant up` aborts with `undefined method 'exists?' for class File`.**
An old `vagrant-vbguest` plugin on Ruby 3.2+. The Vagrantfile disables its
auto-rebuild, so this shouldn't occur; if it does, update it:
`vagrant plugin update vagrant-vbguest`, then `vagrant reload`.

**`vagrant destroy KAGE-MAN.DOJO` says "not found" / "not created".**
`KAGE-MAN.DOJO` is both the VirtualBox name and (now) the Vagrant machine name.
Use `vagrant destroy -f` or `./install.sh --destroy`. If a VM was created before
this naming, delete it directly:
`VBoxManage unregistervm KAGE-MAN.DOJO --delete` and `rm -rf .vagrant`.

**A container keeps restarting.** One-shot init containers are generated with
`restart: "no"`; long-running services use `unless-stopped`. If you edited a
compose, regenerate with `make gen` and recreate the lab (`make up LAB=<name>`).

**`curl` from the Docker host can't reach a lab IP.** That's expected: with
macvlan, the host can't talk to its own containers. Test from inside a segment
(`make smoke` / `make health`) or from the Kali box on that segment.

**The boot logo never appears.** The VM runs headless by default. Start it with
`--gui` (`KAGE_GUI=1`) to open the console window; the logo shows only there.

**VirtualBox VMs won't start on Windows.** See the Hyper-V/WSL2 note in §2.

**Not enough RAM / labs fail to start.** Raise `KAGE_MEMORY`, or provision with
`KAGE_START=none` and start labs a lesson at a time with `make up LAB=<name>`.
