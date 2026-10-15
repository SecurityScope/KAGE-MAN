#!/usr/bin/env python3
# KAGE-MAN.DOJO :: setup.py
#
# Install + build wrapper for the range. Runs the stages in order with a live
# progress bar and leaves every lab container running under `restart:
# unless-stopped` (so they survive a reboot):
#
#     deps   ->  scripts/install-deps.sh   (docker + seccomp + compose + make)
#     net    ->  scripts/network-setup.sh  (promisc + macvlan segments)
#     gen    ->  scripts/gen-labs.sh       (generate lab composes)
#     up     ->  scripts/labs.sh up        (build AND start ALL labs + the DNS)
#
# Usage (run as root, from the repo root):
#     sudo python3 setup.py                 # full install + build + start all
#     sudo python3 setup.py --no-start      # install + build, do not start
#     sudo python3 setup.py --skip-build    # install deps/net/gen only
#     python3 setup.py --banner             # just show the banner (no root)
#     python3 setup.py --help               # banner + full help (stages, examples)
#
# Pure standard library; no pip install required.

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from subprocess import Popen, PIPE, STDOUT

ROOT = Path(__file__).resolve().parent
BANNER_FILE = ROOT / "assets" / "banner.ans"   # pre-coloured ASCII art (ANSI)
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# --- colour (red theme), disabled when stdout is not a terminal -------------
_TTY = sys.stdout.isatty()
RED   = "\033[1;91m" if _TTY else ""   # bold bright red
DIM   = "\033[2m"    if _TTY else ""
RESET = "\033[0m"    if _TTY else ""


# ---------------------------------------------------------------------------
# ASCII-art banner (hand-built block font, no external deps)
# ---------------------------------------------------------------------------
_GLYPHS = {
    "K": ["█   █", "█  █ ", "███  ", "█  █ ", "█   █"],
    "A": [" ███ ", "█   █", "█████", "█   █", "█   █"],
    "G": [" ████", "█    ", "█  ██", "█   █", " ████"],
    "E": ["█████", "█    ", "███  ", "█    ", "█████"],
    "M": ["█   █", "██ ██", "█ █ █", "█   █", "█   █"],
    "N": ["█   █", "██  █", "█ █ █", "█  ██", "█   █"],
    "D": ["███  ", "█  █ ", "█   █", "█  █ ", "███  "],
    "O": [" ███ ", "█   █", "█   █", "█   █", " ███ "],
    "J": ["  ███", "   █ ", "   █ ", "█  █ ", " ██  "],
    "-": ["     ", "     ", " ███ ", "     ", "     "],
    ".": ["     ", "     ", "     ", "     ", "  █  "],
    " ": ["   ", "   ", "   ", "   ", "   "],
}
_SUBTITLE = "A self-contained Metasploit practice range"


def _render(word):
    """Return a word rendered in the block font as a list of 5 strings."""
    rows = [""] * 5
    for ch in word:
        glyph = _GLYPHS.get(ch.upper(), _GLYPHS[" "])
        for i in range(5):
            rows[i] += glyph[i] + " "
    return rows


def _fallback_art():
    """Block-font art, used only if assets/banner.ans is missing."""
    lines = _render("KAGE-MAN") + [""] + ["   " + r for r in _render("DOJO")]
    if RED:
        return "\n".join(RED + ln + RESET for ln in lines)
    return "\n".join(lines)


def _art():
    """The banner art: the pre-coloured ANSI file (colours stripped when the
    output is not a terminal), or the block-font fallback."""
    try:
        art = BANNER_FILE.read_text(encoding="utf-8").rstrip("\n")
    except OSError:
        return _fallback_art()
    return art if _TTY else _ANSI_RE.sub("", art)


def banner_str():
    """Full banner: the art, then the name + subtitle in the same red style."""
    tail = f"{RED}KAGE-MAN.DOJO{RESET}\n{RED}{_SUBTITLE}{RESET}"
    return _art() + "\n\n" + tail


def banner(save=True):
    """Print the banner and (optionally) save a plain-text copy to tempdir."""
    dst = None
    if save:
        try:
            dst = Path(tempfile.gettempdir()) / "kage-man.dojo.banner.txt"
            plain = _ANSI_RE.sub("", banner_str())
            dst.write_text(plain + "\n", encoding="utf-8")
        except OSError:
            dst = None
    print()
    print(banner_str())
    if dst:
        print(f"{DIM}(banner saved to {dst}){RESET}")
    print()


# ---------------------------------------------------------------------------
# argument parser that shows the ASCII banner at the top of --help
# ---------------------------------------------------------------------------
class BannerParser(argparse.ArgumentParser):
    def format_help(self):
        return "\n" + banner_str() + "\n\n" + super().format_help()


# ---------------------------------------------------------------------------
# progress bar
# ---------------------------------------------------------------------------
class Progress:
    WIDTH = 32

    def __init__(self):
        self.done = 0.0      # 0..100
        self.label = ""

    def set(self, done, label=None):
        self.done = max(0.0, min(100.0, done))
        if label is not None:
            self.label = label
        self._draw()

    def add(self, delta):
        self.set(self.done + delta)

    def _draw(self):
        frac = self.done / 100.0
        if _TTY:
            filled = int(self.WIDTH * frac)
            bar = "█" * filled + "─" * (self.WIDTH - filled)
            sys.stdout.write(f"\r{RED}[{bar}]{RESET} {int(frac*100):3d}%  {self.label}\033[K")
            sys.stdout.flush()
        # on a non-tty the per-stage banners (printed elsewhere) carry progress

    def finish(self):
        if _TTY:
            sys.stdout.write("\n")
            sys.stdout.flush()


def preflight():
    """Return an error message if this is not the Ubuntu range host (the VM)."""
    if shutil.which("apt-get") is None:
        return (
            "this is not the Ubuntu range host (no apt-get found).\n"
            "    setup.py installs apt/docker and must run INSIDE the VM, not on\n"
            "    your workstation. From the project directory on the host:\n"
            "\n"
            "        vagrant up                 # provisions the VM for you, or\n"
            "        vagrant ssh                # then, inside the VM:\n"
            "        cd /opt/kage-man && sudo python3 setup.py"
        )
    return None


def count_labs():
    """Number of lab/compose projects (depth-2 docker-compose files, incl. dns)."""
    return sum(1 for _ in ROOT.glob("*/docker-compose*.y*ml"))


def run_stage(cmd, on_line=None, logf=None):
    """Stream a subprocess; call on_line(line) per line; return exit code."""
    proc = Popen(cmd, cwd=str(ROOT), stdout=PIPE, stderr=STDOUT,
                 text=True, bufsize=1)
    for line in proc.stdout:
        if logf:
            logf.write(line)
            logf.flush()
        if on_line:
            on_line(line)
    proc.wait()
    return proc.returncode


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    tmp = Path(tempfile.gettempdir())
    description = (
        "Install + build wrapper for the KAGE-MAN.DOJO range.\n"
        "\n"
        "Drives the repo's scripts in order (with a live progress bar) and\n"
        "leaves every lab container under restart=unless-stopped, so the range\n"
        "survives a reboot. Stages, in order:\n"
        "\n"
        "  stage  script                  what it does\n"
        "  deps   scripts/install-deps.sh  Docker CE + seccomp + compose + make\n"
        "  net    scripts/network-setup.sh promiscuous mode + the 3 macvlan nets\n"
        "  gen    scripts/gen-labs.sh      (re)generate every lab compose file\n"
        "  up     scripts/labs.sh up       build AND start ALL labs + the WAN DNS\n"
        "\n"
        "With no options it runs every stage (deps -> net -> gen -> up) and\n"
        "starts all ~27 containers. That needs plenty of RAM/disk and is slow\n"
        "on the first run; use --no-start or --skip-build to do less."
    )
    epilog = (
        "examples:\n"
        "  sudo python3 setup.py                install, build, and start the whole range\n"
        "  sudo python3 setup.py --no-start     install + build every image, start nothing\n"
        "  sudo python3 setup.py --skip-build   only deps + networking + lab composes\n"
        "  python3 setup.py --banner            print the banner and exit (no root needed)\n"
        "\n"
        "afterwards, drive individual labs with make (from the repo root):\n"
        "  make up LAB=activemq      start one lab        make ps      what is running\n"
        "  make down LAB=activemq    stop one lab         make health  sanity check\n"
        "  make up                   start everything     make smoke   probe endpoints\n"
        "\n"
        "files written:\n"
        f"  {tmp / 'kage-man.dojo.setup.log'}    full output of every stage\n"
        f"  {tmp / 'kage-man.dojo.banner.txt'}   the banner art\n"
        "\n"
        "Run as root (sudo) for every mode except --banner."
    )

    ap = BannerParser(
        prog="setup.py",
        description=description,
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--no-start", action="store_true",
        help="run deps/net/gen, then BUILD all lab images but do NOT start them",
    )
    mode.add_argument(
        "--skip-build", action="store_true",
        help="run deps/net/gen only — no image build, no containers started",
    )
    ap.add_argument(
        "--banner", action="store_true",
        help="just print the ASCII banner and exit (does not need root)",
    )
    args = ap.parse_args()

    banner()
    if args.banner:
        return 0

    if os.geteuid() != 0:
        print(f"{RED}[x]{RESET} run as root:  sudo python3 setup.py", file=sys.stderr)
        return 1

    problem = preflight()
    if problem:
        print(f"{RED}[x]{RESET} {problem}", file=sys.stderr)
        return 2

    # the last stage: start-all (build+up), build-only, or nothing
    if args.skip_build:
        last = None
    elif args.no_start:
        last = ("build", ["./scripts/labs.sh", "build"], "==> build :")
    else:
        last = ("up", ["./scripts/labs.sh", "up"], "==> up :")

    # (name, command, weight, fatal, marker-for-per-lab-progress)
    stages = [
        ("Installing dependencies", ["./scripts/install-deps.sh"], 25, True, None),
        ("Configuring networking",  ["./scripts/network-setup.sh"], 5,  True, None),
        ("Generating lab composes", ["./scripts/gen-labs.sh"],      5,  True, None),
    ]
    if last:
        verb = "Building labs" if last[0] == "build" else "Building & starting labs"
        stages.append((verb, last[1], 65, False, last[2]))

    total_labs = count_labs() or 1
    log_path = Path(tempfile.gettempdir()) / "kage-man.dojo.setup.log"
    bar = Progress()
    base = 0.0  # progress accumulated before the current stage

    with open(log_path, "w", encoding="utf-8") as logf:
        for name, cmd, weight, fatal, marker in stages:
            bar.set(base, f"{name} ...")
            if not _TTY:
                print(f"[*] {name} ...")

            if marker:
                done_labs = [0]

                def on_line(line, _m=marker, _w=weight, _d=done_labs):
                    if _m in line:
                        _d[0] += 1
                        lab = line.split(_m, 1)[1].strip()
                        bar.set(base + _w * min(_d[0], total_labs) / total_labs,
                                f"{name} ({_d[0]}/{total_labs}) {lab}")
            else:
                on_line = None

            rc = run_stage(cmd, on_line=on_line, logf=logf)
            base += weight
            bar.set(base, f"{name} — done" if rc == 0 else f"{name} — rc={rc}")

            if rc != 0:
                if fatal:
                    bar.finish()
                    print(f"{RED}[x]{RESET} {name} failed (exit {rc}). "
                          f"Last lines of {log_path}:", file=sys.stderr)
                    _tail(log_path)
                    return rc
                else:
                    if not _TTY:
                        print(f"[!] {name}: some items failed (exit {rc}) — see {log_path}")

        bar.set(100, "Done")
        bar.finish()

    print(f"{RED}[+]{RESET} KAGE-MAN.DOJO ready.  Full log: {DIM}{log_path}{RESET}")
    if last and last[0] == "up":
        print("    Containers are running with restart=unless-stopped "
              "(they survive a reboot).")
        print("    Check:  sudo docker ps   |   make ps   |   make health")
    return 0


def _tail(path, n=25):
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
        for ln in lines[-n:]:
            print("    " + ln, file=sys.stderr)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
