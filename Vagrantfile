# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# KAGE-MAN.DOJO :: Vagrantfile
#
# Stand up the entire 26-lab Metasploit range on one Ubuntu 20.04 VirtualBox
# VM, fully automatically:
#
#   vagrant up        # creates the 3 VirtualBox NAT networks, boots the VM,
#                     # installs Docker, builds the macvlan segments, generates
#                     # every lab compose, then BUILDS and STARTS all labs
#                     # (restart=unless-stopped, so they survive a reboot).
#
# Building + starting all ~27 containers needs plenty of RAM/disk and takes a
# while on the first run. To provision without starting everything, set
# KAGE_START (see below), e.g. `KAGE_START=none vagrant up`, and start labs a
# lesson at a time from inside the VM:
#
#   vagrant ssh ; cd /opt/kage-man
#   make up LAB=activemq      # or: make up   (everything)
#   make ps | make health | make smoke
#
# Tunables (environment overrides, all optional):
#   KAGE_CPUS=4            vCPUs                      (default 4)
#   KAGE_MEMORY=8192       RAM in MB                  (default 8192)
#   KAGE_BOX=ubuntu/focal64  base box (official 20.04, built from the ISO)
#   KAGE_DISK=80GB         root disk size (needs the vagrant-disksize plugin)
#   KAGE_START=up|build|none   final stage (default up = build AND start ALL
#                              labs with restart=unless-stopped; build = build
#                              only; none = deps/net/gen only)
#
#   e.g.  KAGE_MEMORY=12288 KAGE_START=build vagrant up
#
# ---------------------------------------------------------------------------
# Networking
#   Three VirtualBox NAT networks (named, L2 + outbound NAT at .1) carry the
#   segments; the creator scripts make them from segments.conf:
#       KAGE-DOJO-DMZ  192.168.80.0/24   -> adapter 2
#       KAGE-DOJO-INT  172.16.80.0/24    -> adapter 3
#       KAGE-DOJO-WAN  10.0.8.0/24       -> adapter 4
#   Adapter 1 stays Vagrant's management NAT (SSH + the VM's internet for
#   pulling images). The host VM takes .250 on every segment.
#
#   Each segment NIC gets a fixed MAC so the provisioner can map NIC -> segment
#   deterministically (VirtualBox/Vagrant NIC ordering is otherwise opaque:
#   the lab NICs come up as enp0s8/enp0s9/enp0s10, not enp0s3/8/9).
#
#   Attach a Kali box to the KAGE-DOJO-WAN NAT network (static 10.0.8.x) to
#   walk the campaign from the WAN inward.
# ---------------------------------------------------------------------------

Vagrant.require_version ">= 2.2.14"

CPUS   = (ENV["KAGE_CPUS"]   || "4").to_i
MEMORY = (ENV["KAGE_MEMORY"] || "8192").to_i
BOX    = ENV["KAGE_BOX"]     || "ubuntu/focal64"
START  = (ENV["KAGE_START"]  || "up").downcase

# Segment NAT-network name + fixed MAC (no separators, VirtualBox OUI 080027).
# Order = adapters 2, 3, 4. Keep in sync with segments.conf and the provisioner.
SEGMENTS = [
  { net: "KAGE-DOJO-DMZ", mac: "0800271A8020" }, # adapter 2
  { net: "KAGE-DOJO-INT", mac: "0800271A8021" }, # adapter 3
  { net: "KAGE-DOJO-WAN", mac: "0800271A8022" }, # adapter 4
]

GUI    = %w[1 true yes on].include?((ENV["KAGE_GUI"] || "").downcase)
LOGO   = File.expand_path("assets/images/logo.bmp", __dir__)

# The BIOS/firmware logo options were renamed in VirtualBox 7.1+
# (--bioslogo* -> --firmware-logo-*). Detect which this host supports so the
# logo works on both. NB: the logo only renders in the GUI console window
# (KAGE_GUI=1); a headless VM never shows it.
def logo_customizations(logo)
  return [] unless File.exist?(logo)
  help = begin; `VBoxManage help modifyvm 2>&1`; rescue StandardError; ""; end
  img, time, fin, fout =
    if help.include?("--firmware-logo-image-path")
      ["--firmware-logo-image-path", "--firmware-logo-display-time",
       "--firmware-logo-fade-in", "--firmware-logo-fade-out"]
    else
      ["--bioslogoimagepath", "--bioslogodisplaytime",
       "--bioslogofadein", "--bioslogofadeout"]
    end
  [[img, logo], [time, "5000"], [fin, "off"], [fout, "off"]]
end

Vagrant.configure("2") do |config|
  # Name the Vagrant machine to match the VirtualBox VM, so CLI commands can
  # address it by name, e.g. `vagrant up KAGE-MAN.DOJO`, `vagrant destroy
  # KAGE-MAN.DOJO`. (Plain `vagrant up` / `vagrant destroy` still work too.)
  config.vm.define "KAGE-MAN.DOJO"

  config.vm.box          = BOX
  config.vm.hostname     = "kage-man"
  config.vm.boot_timeout = 600

  # The vagrant-vbguest plugin (<= 0.32.0) crashes on Ruby 3.2+ with
  # "undefined method `exists?' for class File" when it tries to rebuild Guest
  # Additions (e.g. 6.1 additions on a 7.x host). The box's additions are fine
  # for this range, so disable the auto-rebuild. To actually match versions
  # instead, run: vagrant plugin update vagrant-vbguest
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  # Create the three VirtualBox NAT networks on the host before the VM boots.
  config.trigger.before :up do |t|
    t.name    = "KAGE-MAN.DOJO :: create VirtualBox NAT networks"
    t.warn    = "Creating VirtualBox NAT networks (KAGE-DOJO-DMZ/INT/WAN)"
    if Vagrant::Util::Platform.windows?
      t.run = { inline: 'powershell -NoProfile -ExecutionPolicy Bypass -File "scripts/vbox-networks.ps1" create' }
    else
      t.run = { path: "scripts/vbox-networks.sh", args: "create" }
    end
  end

  # Optional root-disk resize (26 lab images add up):
  #   vagrant plugin install vagrant-disksize
  if Vagrant.has_plugin?("vagrant-disksize")
    config.disksize.size = ENV["KAGE_DISK"] || "80GB"
  end

  config.vm.provider "virtualbox" do |vb|
    vb.name   = "KAGE-MAN.DOJO"
    vb.gui    = GUI            # KAGE_GUI=1 opens the VM window (needed to see the logo)
    vb.cpus   = CPUS
    vb.memory = MEMORY
    vb.customize ["modifyvm", :id, "--ioapic", "on"]

    # Lab segments on NAT networks (adapters 2..4), each with a fixed MAC and
    # promiscuous "allow-all" (required or macvlan traffic is silently dropped).
    SEGMENTS.each_with_index do |seg, i|
      n = i + 2
      vb.customize ["modifyvm", :id,
                    "--nic#{n}",           "natnetwork",
                    "--nat-network#{n}",   seg[:net],
                    "--macaddress#{n}",    seg[:mac],
                    "--nicpromisc#{n}",    "allow-all",
                    "--cableconnected#{n}", "on"]
    end

    # Boot splash = the dojo logo (VirtualBox BIOS logo; must be an
    # uncompressed BMP <= 640x480, which assets/images/logo.bmp already is).
    # Boot splash = the dojo logo (visible only with KAGE_GUI=1). Flag names
    # differ across VirtualBox versions; logo_customizations picks the right set.
    logo_customizations(LOGO).each do |flag, value|
      vb.customize ["modifyvm", :id, flag, value]
    end
  end

  config.vm.provision "shell",
    path: "scripts/vagrant-provision.sh",
    env:  { "KAGE_START" => START },
    privileged: true
end
