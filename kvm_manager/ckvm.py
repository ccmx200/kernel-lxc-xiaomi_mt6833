#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ckvm - KVM guest manager for the MT6833 / evergo device.

Rewritten in Python after the shell version kept getting in the way: the
interactive flow could not express a free-form CPU mask, the port prompt
contradicted its own help text, and the styling drifted between three
different separator styles.

Design rules kept deliberately simple so this stays maintainable:
  * one style object, one separator, one set of markers - see Style
  * width is measured with unicodedata.east_asian_width so CJK columns line up
  * every menu is a numbered list with a default and a cancel option
  * nothing is hidden: external commands print their own output
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata

# Animations live in ckvm_ui.py.  Look beside this file first so a checkout
# works without installing, then fall back to the install directory.
try:
    _here = os.path.dirname(os.path.abspath(__file__))
    for _p in (_here, "/usr/local/bin"):
        if _p and _p not in sys.path:
            sys.path.insert(0, _p)
    from ckvm_ui import (Spinner, Progress, sweep, bar_reveal, steps,  # noqa
                         human_bytes, human_time, TTY as UI_TTY,
                         pick, can_pick)
    HAVE_UI = True
except Exception:                                    # pragma: no cover
    HAVE_UI = False

    class Spinner:                                   # type: ignore
        def __init__(self, label, enabled=True):
            self.label = label

        def note(self, _t):
            pass

        def __enter__(self):
            print(f"  {self.label}...")
            return self

        def __exit__(self, *a):
            return False

    class Progress:                                  # type: ignore
        def __init__(self, label, total, enabled=True, width=None):
            self.total = max(1, int(total))
            self.done = 0

        def __enter__(self):
            return self

        def update(self, done):
            self.done = done

        def __exit__(self, *a):
            return False

    def sweep(text, **k):
        print(f"  {text}")

    def bar_reveal(label, **k):
        pass

    def steps(items, **k):
        for i in items:
            print(f"  - {i}")

    def human_bytes(n):
        return f"{n / 1048576:.1f}M"

    def human_time(s):
        return f"{s:.0f}s"

VERSION = "2.0"

# --------------------------------------------------------------------------
# paths and defaults
# --------------------------------------------------------------------------
BINDIR = "/usr/local/bin"
CKVM_ROOT = os.environ.get("CKVM_ROOT", "/var/lib/ckvm")
CACHE_DIR = os.path.join(CKVM_ROOT, ".cache")
FW_DIR = os.environ.get("CKVM_FWDIR", "/usr/local/share/ckvm/firmware")
BINDIR = "/usr/local/bin"

FW_CODE = "edk2_qemu_aarch64_nonvram.fd"
FW_VARS = "edk2_vars.fd"

DEF_CPUS = 8
DEF_MEM = 2048
DEF_DISK = 50
DEF_REL = "26.04"   # only a menu default now; never used to fill a missing value
DEF_PORT_BASE = 8023
DEF_CORES = "0-7"
DEF_CACHE = "writeback"
DEF_FORWARDS = "22"
DEF_NET = "user"

MIRROR_IMAGES = [
    "https://mirror.nju.edu.cn/ubuntu-cloud-images",
    "https://cloud-images.ubuntu.com",
]

# Ubuntu mirror list, offered interactively.  Measure before choosing.
APT_MIRRORS = [
    ("mirrors.tuna.tsinghua.edu.cn", "清华 TUNA"),
    ("mirrors.aliyun.com", "阿里云"),
    ("mirrors.ustc.edu.cn", "中科大"),
    ("mirror.nju.edu.cn", "南京大学"),
    ("mirrors.bfsu.edu.cn", "北外"),
]

# The repo lives behind several accelerators; the user picks, we do not.
# Only these two served raw files from the device when tested; git.yylx.win
# proxies git clone only and returns 404 for raw content.
GITHUB_ACCEL = [
    ("https://ghproxy.net/", "ghproxy.net（实测可用）"),
    ("https://gh-proxy.com/", "gh-proxy.com（实测可用）"),
    ("", "直连 GitHub（国内通常不通）"),
]

# NOTE: the short /<branch>/ form.  /refs/heads/<branch>/ returned HTTP 500.
REPO_RAW = "https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu"

class Distro:
    """
    One distribution family.

    Each owns its release list and its download URLs, so adding a family does
    not mean touching the create flow.
    """

    def __init__(self, key, name, default_user, releases, url_tmpls,
                 cache_name, note=""):
        self.build = False        # True when ckvm must assemble the disk
        self.key = key
        self.name = name
        self.default_user = default_user
        # release: (version, codename, tag, size)
        self.releases = releases
        self.url_tmpls = url_tmpls
        self.cache_name = cache_name
        self.note = note

    def rel(self, version):
        for r in self.releases:
            if r[0] == version:
                return r
        return None

    def urls(self, version):
        """Every mirror to try, in order."""
        r = self.rel(version)
        if not r:
            return []
        code = r[1]
        out = []
        for t in self.url_tmpls:
            out.append(t.format(ver=version, code=code))
        return out

    def cache_file(self, version):
        return self.cache_name.format(ver=version)


UBUNTU = Distro(
    "ubuntu", "Ubuntu", "ubuntu",
    [("22.04", "jammy", "LTS", "673M"),
     ("22.10", "kinetic", "", "716M"),
     ("23.04", "lunar", "", "688M"),
     ("23.10", "mantic", "", "684M"),
     ("24.04", "noble", "LTS", "592M"),
     ("24.10", "oracular", "", "584M"),
     ("25.04", "plucky", "", "680M"),
     ("25.10", "questing", "", "843M"),
     ("26.04", "resolute", "LTS", "902M")],
    ["https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/{ver}/release/"
     "ubuntu-{ver}-server-cloudimg-arm64.img",
     "https://cloud-images.ubuntu.com/releases/{ver}/release/"
     "ubuntu-{ver}-server-cloudimg-arm64.img"],
    "ubuntu-{ver}-arm64.img",
    note="Ubuntu 官方 cloud image",
)

DEBIAN = Distro(
    "debian", "Debian", "debian",
    [("13", "trixie", "stable", "322M"),
     ("12", "bookworm", "oldstable", "326M")],
    ["https://mirror.nju.edu.cn/debian-cdimage/cloud/{code}/latest/"
     "debian-{ver}-genericcloud-arm64.qcow2",
     "https://cloud.debian.org/images/cloud/{code}/latest/"
     "debian-{ver}-genericcloud-arm64.qcow2"],
    "debian-{ver}-arm64.qcow2",
    note="genericcloud，带 cloud-init",
)

FEDORA = Distro(
    "fedora", "Fedora", "fedora",
    [("42", "42", "", "600M")],
    ["https://download.fedoraproject.org/pub/fedora/linux/releases/{ver}/"
     "Cloud/aarch64/images/Fedora-Cloud-Base-Generic-{ver}-1.1.aarch64.qcow2"],
    "fedora-{ver}-arm64.qcow2",
    note="官方 Cloud Base Generic",
)

# Arch is a different animal: no cloud image, so `build` says ckvm must
# assemble the disk from the Arch Linux ARM rootfs tarball.
ARCH = Distro(
    "arch", "Arch Linux ARM", "alarm",
    [("latest", "aarch64", "rolling", "831M")],
    ["https://mirrors.ustc.edu.cn/archlinuxarm/os/"
     "ArchLinuxARM-aarch64-latest.tar.gz",
     "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/"
     "ArchLinuxARM-aarch64-latest.tar.gz",
     "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"],
    "arch-latest-arm64-rootfs.tar.gz",
    note="从 rootfs tarball 建盘（约 3GB 可用内存）",
)
ARCH.build = True

DISTROS = [UBUNTU, DEBIAN, FEDORA, ARCH]
DISTRO_BY_KEY = {d.key: d for d in DISTROS}

# kept for the code that still refers to it; the Ubuntu list
CATALOGUE = "\n".join("|".join(r) for r in UBUNTU.releases)

CACHE_MODES = {
    "writeback": "速度最快，断电时可能丢失最近写入（推荐）",
    "none": "每次写入都落盘，最安全但最慢",
    "unsafe": "比 writeback 更快，断电容易损坏磁盘",
    "writethrough": "读走缓存，写直接落盘",
}

# CPU mask presets.  Arbitrary masks are accepted too - the kernel snapshots
# the ID registers per VM, so crossing clusters is fine.
CORE_PRESETS = [
    ("0-7", 8, "全部 8 核（6×A55 + 2×A76）", "吞吐优先"),
    ("6-7", 2, "仅 2 个大核（A76）", "单核延迟优先"),
    ("0-5", 6, "仅 6 个小核（A55）", "省电／低发热"),
]

# port presets: (label, port, description)
PORT_PRESETS = [
    (22, "SSH"),
    (80, "HTTP"),
    (443, "HTTPS"),
    (3306, "MySQL"),
    (5432, "PostgreSQL"),
    (6379, "Redis"),
    (3000, "Node / 前端"),
    (8080, "备用 HTTP"),
]


# --------------------------------------------------------------------------
# terminal
# --------------------------------------------------------------------------
def _tty() -> bool:
    return sys.stdout.isatty() and os.environ.get("TERM", "dumb") != "dumb"


class Style:
    """One place for every colour and marker, so nothing drifts."""

    def __init__(self) -> None:
        on = _tty() and not os.environ.get("NO_COLOR")
        self.on = on

    def _c(self, code: str) -> str:
        return f"\033[{code}m" if self.on else ""

    @property
    def b(self) -> str: return self._c("1")          # bold
    @property
    def dim(self) -> str: return self._c("2")
    @property
    def g(self) -> str: return self._c("32")         # green
    @property
    def y(self) -> str: return self._c("33")         # yellow
    @property
    def r(self) -> str: return self._c("31")         # red
    @property
    def c(self) -> str: return self._c("36")         # cyan
    @property
    def m(self) -> str: return self._c("35")         # magenta
    @property
    def rst(self) -> str: return self._c("0")

    # markers: one glyph per meaning, used everywhere
    ok, no, warn, info, dot = "✅", "❌", "⚠️ ", "·", "·"
    arrow, bullet = "→", "•"


S = Style()


def width(s: str) -> int:
    """Display columns, treating East Asian wide/fullwidth and emoji as 2."""
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        ea = unicodedata.east_asian_width(ch)
        if ea in ("W", "F") or ord(ch) >= 0x1F300:
            w += 2
        else:
            w += 1
    return w


def pad(s: str, n: int, align: str = "left") -> str:
    d = max(0, n - width(s))
    if align == "right":
        return " " * d + s
    return s + " " * d


def rule(n: int | None = None) -> str:
    """The one separator.  Used by every section in this program."""
    return "─" * (n or min(shutil.get_terminal_size((72, 24)).columns - 4, 68))


def out(s: str = "") -> None:
    print(f"  {s}")


def info(s: str) -> None:
    out(f"{S.dim}{s}{S.rst}")


def ok(s: str) -> None:
    out(f"{S.g}{S.ok}{S.rst} {s}")


def warn(s: str) -> None:
    print(f"  {S.y}{S.warn}{S.rst} {s}", file=sys.stderr)


def die(s: str, code: int = 1) -> "None":
    print(f"  {S.r}{S.no} {s}{S.rst}", file=sys.stderr)
    sys.exit(code)


def header(title: str, sub: str = "") -> None:
    out()
    out(f"{S.b}{title}{S.rst}" + (f"  {S.dim}{sub}{S.rst}" if sub else ""))
    out(f"{S.dim}{rule()}{S.rst}")
    out()


def banner() -> None:
    if not _tty():
        return
    print()
    print(f"  {S.c}🚀{S.rst} {S.b}ckvm{S.rst} {S.dim}·{S.rst} KVM 虚拟机管理器 "
          f"{S.dim}{VERSION}{S.rst}")
    print(f"     {S.dim}作者  {S.m}璀璨梦星 · cuicanmx{S.rst}   "
          f"{S.dim}github.com/ccmx200{S.rst}")
    print()


# --------------------------------------------------------------------------
# prompting
# --------------------------------------------------------------------------
def ask(prompt: str, default: str = "") -> str:
    """A plain prompt.  Empty input returns the default."""
    tail = f" {S.dim}[{default}]{S.rst}" if default else ""
    while True:
        try:
            ans = input(f"  {prompt}{tail}: ").strip()
        except EOFError:
            return default
        except KeyboardInterrupt:
            print()
            sys.exit(130)
        if ans:
            return ans
        if default != "":
            return default
        print(f"  {S.y}不能为空{S.rst}")


def ask_secret(prompt: str) -> str:
    """
    Read a password.

    stdin, not /dev/tty like getpass: that also works when the input is piped
    or driven by a test harness.  Echo is turned off when stdin is a terminal.
    """
    while True:
        sys.stdout.write(f"  {prompt}: ")
        sys.stdout.flush()
        fd = sys.stdin.fileno()
        old = None
        try:
            import termios
            if sys.stdin.isatty():
                old = termios.tcgetattr(fd)
                new = termios.tcgetattr(fd)
                new[3] &= ~termios.ECHO
                termios.tcsetattr(fd, termios.TCSADRAIN, new)
        except Exception:
            old = None
        try:
            raw = sys.stdin.readline()
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(130)
        finally:
            if old is not None:
                try:
                    termios.tcsetattr(fd, termios.TCSADRAIN, old)
                except Exception:
                    pass
            print()
        a = raw.rstrip("\n")
        if a:
            return a
        print(f"  {S.y}不能为空{S.rst}")


def menu(title: str, items: list[tuple[str, str]], default: int = 1,
         cancel: str = "取消", extra: str = "") -> "int | None":
    """
    Let the user choose.  Returns the 0-based index, or None when cancelled.

    On a terminal this is an arrow-key menu; otherwise it stays the numbered
    prompt, so piping still works and scripts do not change behaviour.

    items: list of (label, description)
    """
    if HAVE_UI and can_pick():
        # pick() takes a 0-based default; callers here pass 1-based
        return pick(title, items, default=default - 1, cancel=cancel,
                    extra=extra)

    out(f"{S.b}{title}{S.rst}")
    if extra:
        out(f"{S.dim}{extra}{S.rst}")
    out()
    w = max((width(l) for l, _ in items), default=0)
    for i, (label, desc) in enumerate(items, 1):
        mark = f"{S.c}{i:2}){S.rst}"
        d = f"  {S.dim}{desc}{S.rst}" if desc else ""
        out(f"  {mark} {pad(label, w)}{d}")
    out(f"  {S.c} 0){S.rst} {S.dim}{cancel}{S.rst}")
    out()
    while True:
        try:
            raw = input(f"  {S.b}选择{S.rst} [{default}]: ").strip()
        except EOFError:
            return None
        except KeyboardInterrupt:
            print()
            return None
        if not raw:
            raw = str(default)
        if raw == "0":
            return None
        if raw.isdigit() and 1 <= int(raw) <= len(items):
            return int(raw) - 1
        print(f"  {S.y}请输入 1-{len(items)}，或 0 {cancel}{S.rst}")


def confirm(prompt: str, default: bool = True) -> bool:
    d = "Y/n" if default else "y/N"
    try:
        raw = input(f"  {prompt} [{d}]: ").strip().lower()
    except EOFError:
        print()
        return default
    except KeyboardInterrupt:
        print()
        return False
    if not raw:
        return default
    return raw in ("y", "yes", "是")


def is_interactive() -> bool:
    return _tty() and sys.stdin.isatty()


# --------------------------------------------------------------------------
# CPU mask
# --------------------------------------------------------------------------
def mask_cores(mask: str) -> list[int]:
    """Parse '0-7', '0-2,6-7', '6' into a sorted list of ints."""
    cores: set[int] = set()
    for part in mask.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            if not (a.isdigit() and b.isdigit()):
                raise ValueError(f"无法解析: {part}")
            lo, hi = int(a), int(b)
            if lo > hi:
                raise ValueError(f"范围反了: {part}")
            cores.update(range(lo, hi + 1))
        else:
            if not part.isdigit():
                raise ValueError(f"无法解析: {part}")
            cores.add(int(part))
    if not cores:
        raise ValueError("空的 CPU 掩码")
    return sorted(cores)


def mask_label(mask: str) -> str:
    """Human description of a mask, using this SoC's real topology."""
    try:
        cores = mask_cores(mask)
    except ValueError:
        return mask
    a55 = [c for c in cores if c <= 5]
    a76 = [c for c in cores if c >= 6]
    bits = []
    if a55:
        bits.append(f"{len(a55)}×A55")
    if a76:
        bits.append(f"{len(a76)}×A76")
    return f"{mask}  ({' + '.join(bits)})" if bits else mask


def ask_cores() -> str:
    """Pick a CPU mask.  Presets plus an option for an arbitrary mask."""
    items = [(mask_label(m), f"{desc}，{note}") for m, _n, desc, note in CORE_PRESETS]
    items.append(("自定义", "想自己指定就用这个，例如 0-2,6-7"))
    idx = menu("物理核心", items, default=1)
    if idx is None:
        return DEF_CORES
    if idx < len(CORE_PRESETS):
        return CORE_PRESETS[idx][0]
    while True:
        raw = ask("掩码（如 0-2,6-7）", DEF_CORES)
        try:
            cores = mask_cores(raw)
        except ValueError as e:
            warn(str(e))
            continue
        bad = [c for c in cores if c > 7]
        if bad:
            warn(f"这台机器只有核 0-7，越界: {bad}")
            continue
        norm = ",".join(str(c) for c in cores)
        ok(f"{mask_label(norm)}  —  共 {len(cores)} 核")
        return norm


# --------------------------------------------------------------------------
# port forwards
# --------------------------------------------------------------------------
def parse_forward(item: str) -> tuple[int, int]:
    """'80' -> (80,80);  '8080:80' -> (8080,80)."""
    item = item.strip()
    if not item:
        raise ValueError("空")
    if ":" in item:
        h, _, g = item.partition(":")
    else:
        h = g = item
    if not (h.isdigit() and g.isdigit()):
        raise ValueError(f"不是端口: {item}")
    hi, gi = int(h), int(g)
    for p in (hi, gi):
        if not (1 <= p <= 65535):
            raise ValueError(f"端口超出范围: {p}")
    return hi, gi


def forward_text(item: str) -> str:
    h, g = parse_forward(item)
    return f"{g}" if h == g else f"{h}:{g}"


def render_forwards(forwards: list[str], port: int) -> None:
    """Show the table, resolving guest 22 to this guest's PORT."""
    if not forwards:
        info("（没有端口映射）")
        return
    w = max((width(f) for f in forwards), default=4)
    for i, f in enumerate(forwards, 1):
        h, g = parse_forward(f)
        shown = f"<本机 {port}>" if g == 22 and h == 22 else str(h)
        out(f"  {S.c}{i:2}){S.rst} 宿主机 {pad(shown, 12)} "
            f"{S.dim}{S.arrow}{S.rst} guest {pad(str(g), 6)} "
            f"{S.dim}{pad(f, w)}{S.rst}")


def edit_forwards(default: list[str] | None = None, port: int = DEF_PORT_BASE) -> list[str]:
    """
    A real editor: add by preset, add by number, and delete individual entries.
    This is the part the shell version got wrong - it showed old help text and
    then accepted a format the new code did not expect.
    """
    forwards = list(default if default is not None else [DEF_FORWARDS])

    while True:
        out()
        out(f"{S.b}端口映射{S.rst}  {S.dim}guest 22 会映射到本机 {port}{S.rst}")
        out()
        render_forwards(forwards, port)
        out()
        choices = [
            ("添加常用端口", "SSH / HTTP / HTTPS / 数据库 …"),
            ("添加自定义映射", "例如 8080:80"),
            ("删除某一项", ""),
            ("完成", ""),
        ]
        idx = menu("", choices, default=4, cancel="放弃修改")
        if idx is None:
            return default if default is not None else [DEF_FORWARDS]
        if idx == 0:
            add = _add_preset(forwards, port)
            forwards = add
        elif idx == 1:
            add = _add_custom(forwards, port)
            forwards = add
        elif idx == 2:
            forwards = _del_forward(forwards, port)
        else:
            if not forwards:
                warn("至少留一个映射（一般保留 22）")
                continue
            return forwards


def _add_preset(forwards: list[str], port: int) -> list[str]:
    items = [(str(p), f"{name}") for p, name in PORT_PRESETS]
    idx = menu("添加哪个端口", items, default=1)
    if idx is None:
        return forwards
    p = PORT_PRESETS[idx][0]
    item = str(p)
    if item in forwards:
        info(f"{p} 已经在列表里了")
        return forwards
    forwards.append(item)
    ok(f"已添加 {p}")
    return forwards


def _add_custom(forwards: list[str], port: int) -> list[str]:
    while True:
        raw = ask("映射（如 8080:80，直接回车取消）", "")
        if not raw:
            return forwards
        try:
            item = forward_text(raw)
        except ValueError as e:
            warn(str(e))
            continue
        if item in forwards:
            info(f"{item} 已经在列表里了")
            return forwards
        forwards.append(item)
        ok(f"已添加 {item}")
        return forwards


def _del_forward(forwards: list[str], port: int) -> list[str]:
    if not forwards:
        info("没有可删的")
        return forwards
    items = []
    for f in forwards:
        h, g = parse_forward(f)
        items.append((f, f"guest {g}" + (f" → 宿主机 {h}" if h != g else "")))
    idx = menu("删除哪一项", items, default=1, cancel="不删了")
    if idx is None:
        return forwards
    removed = forwards.pop(idx)
    ok(f"已删除 {removed}")
    return forwards


# --------------------------------------------------------------------------
# cache mode
# --------------------------------------------------------------------------
def ask_cache() -> str:
    items = [(m, d) for m, d in CACHE_MODES.items()]
    idx = menu("磁盘缓存", items, default=1)
    if idx is None:
        return DEF_CACHE
    return list(CACHE_MODES)[idx]


# --------------------------------------------------------------------------
# guests
# --------------------------------------------------------------------------
def vm_dir(name: str) -> str:
    return os.path.join(CKVM_ROOT, name)


def vm_conf(name: str) -> str:
    return os.path.join(vm_dir(name), "vm.conf")


def valid_name(name: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9_.\-]+", name or ""))


def load_vm(name: str) -> dict[str, str]:
    path = vm_conf(name)
    if not os.path.isfile(path):
        die(f"没有这个虚拟机: {name}（用 ckvm list 看看）")
    cfg: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()
    return cfg


def list_guests() -> list[str]:
    if not os.path.isdir(CKVM_ROOT):
        return []
    return sorted(
        d for d in os.listdir(CKVM_ROOT)
        if not d.startswith(".") and os.path.isfile(vm_conf(d))
    )


def guest_pid(name: str) -> int | None:
    f = os.path.join(vm_dir(name), "qemu.pid")
    try:
        pid = int(open(f).read().strip())
    except Exception:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid


def running(name: str) -> bool:
    return guest_pid(name) is not None


# --------------------------------------------------------------------------
# external commands
# --------------------------------------------------------------------------
def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def run(cmd: list[str], **kw) -> int:
    """Run with output going straight to the terminal - never swallowed."""
    try:
        return subprocess.call(cmd, **kw)
    except FileNotFoundError:
        die(f"找不到命令: {cmd[0]}")
        return 127


def capture(cmd: list[str]) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return 127, ""



# --------------------------------------------------------------------------
# measuring mirrors and accelerators
# --------------------------------------------------------------------------
def measure_url(url: str, timeout: int = 25, maxbytes: int = 6_000_000) -> float:
    """Download a bit of url and return MB/s, or 0.0 on failure."""
    import time as _t
    import urllib.request
    t0 = _t.time()
    got = 0
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ckvm"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            while got < maxbytes:
                chunk = r.read(65536)
                if not chunk:
                    break
                got += len(chunk)
    except Exception:
        return 0.0
    dt = max(_t.time() - t0, 0.001)
    if got < 200_000:
        return 0.0
    return got / 1048576.0 / dt


def pick_apt_mirror(current: str = "") -> str | None:
    """
    Interactive apt mirror choice, with measured throughput.
    Returns the base URL, or None to keep the current one.
    """
    out()
    out(f"{S.b}apt 软件源{S.rst}")
    out(f"{S.dim}正在测速，稍等一下…{S.rst}")
    out()

    # print each result as it arrives; trying to rewind the line left stray
    # escape fragments in piped output, and the columns never lined up anyway
    results = []
    for host, name in APT_MIRRORS:
        url = f"https://{host}/debian"
        speed = measure_url(f"{url}/dists/trixie/main/binary-arm64/Packages.gz")
        results.append((speed, url, name, host))
        shown = f"{speed:.2f} MB/s" if speed > 0 else "不可达"
        mark = f"{S.g}★{S.rst}" if speed > 0 else f"{S.r}×{S.rst}"
        out(f"  {mark} {pad(name, 12)} {pad(host, 30)} {pad(shown, 10, 'right')}")
    out()

    results.sort(key=lambda r: -r[0])

    items = [(name, f"{speed:.2f} MB/s" if speed > 0 else "不可达") 
             for speed, _u, name, _h in results]
    items.append(("保持当前源", current or "不动"))
    idx = menu("用哪个源", items, default=1)
    if idx is None or idx == len(items) - 1:
        return None
    return results[idx][1]


def apt_current_mirror() -> str:
    """Best-effort read of the active Debian mirror base URL."""
    for path in ("/etc/apt/sources.list",
                 "/etc/apt/sources.list.d/debian.sources"):
        if not os.path.isfile(path):
            continue
        try:
            txt = open(path, encoding="utf-8").read()
        except Exception:
            continue
        m = re.search(r"https?://([^/\s]+)/debian", txt)
        if m:
            return f"https://{m.group(1)}/debian"
    return ""


def apt_mirror_speed(base: str, timeout: int = 25) -> float:
    """
    Measure a Debian mirror in MB/s by downloading part of a real index.

    Deliberately a bandwidth test, not a latency test: ranking mirrors by ping
    picked the slowest one once already, because a nearby host with a saturated
    uplink answers quickly and then crawls.
    """
    import time as _t
    import urllib.request
    url = f"{base.rstrip('/')}/dists/trixie/main/binary-arm64/Packages.gz"
    t0 = _t.time()
    got = 0
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ckvm"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            while got < 6_000_000:
                chunk = r.read(65536)
                if not chunk:
                    break
                got += len(chunk)
    except Exception:
        return 0.0
    if got < 200_000:
        return 0.0
    return got / 1048576.0 / max(_t.time() - t0, 0.001)


def apt_pick_fastest_mirror() -> str:
    """
    The apt mirror with the best measured throughput, or "" if none answered.

    Was lost in the multi-distro rewrite while cmd_install kept calling it, so
    installing on a container with a stock mirror crashed with a NameError
    before it could switch the source.
    """
    best, best_speed = "", 0.0
    for host, _name in APT_MIRRORS:
        speed = apt_mirror_speed(f"https://{host}/debian")
        if speed > best_speed:
            best, best_speed = f"https://{host}/debian", speed
    return best


def apply_apt_mirror(base: str) -> bool:
    """Rewrite sources to use base, keeping a backup."""
    import glob
    files = ["/etc/apt/sources.list.d/debian.sources", "/etc/apt/sources.list"]
    done = False
    for path in files:
        if not os.path.isfile(path):
            continue
        txt = open(path, encoding="utf-8").read()
        if "/debian" not in txt:
            continue
        bak = path + ".ckvm.bak"
        if not os.path.exists(bak):
            shutil.copyfile(path, bak)
        new = re.sub(r"https?://[^/\s]+/debian-security",
                     base.replace("/debian", "/debian-security"), txt)
        new = re.sub(r"https?://[^/\s]+/debian", base, new)
        open(path, "w", encoding="utf-8").write(new)
        done = True
    return done


def pick_accel() -> str:
    """Interactive GitHub accelerator choice.  Returns a URL prefix."""
    out()
    out(f"{S.b}GitHub 加速{S.rst}")
    out(f"{S.dim}国内直连 GitHub 通常不通。选一个，或先用直连试试。{S.rst}")
    out()
    items = [(name, url or "raw.githubusercontent.com") for url, name in GITHUB_ACCEL]
    items.append(("手动输入", "你自己的反代地址"))
    idx = menu("下载源", items, default=1)
    if idx is None:
        return ""
    if idx == len(items) - 1:
        return ask("加速地址（如 https://your.proxy）", "")
    return GITHUB_ACCEL[idx][0]


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        usage()
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd in ("-V", "--version", "version"):
        print(f"ckvm {VERSION}")
        return 0

    table = {
        "create": cmd_create, "list": cmd_list, "ls": cmd_list,
        "start": cmd_start, "stop": cmd_stop, "rm": cmd_rm, "remove": cmd_rm,
        "cache": cmd_cache, "versions": cmd_versions,
        "show": cmd_show, "config": cmd_show,
        "install": cmd_install, "mirror": cmd_mirror,
        "tune": cmd_tune, "selftest": cmd_selftest,
        "console": cmd_console, "net": cmd_net, "ssh": cmd_ssh,
        "status": cmd_status, "restart": cmd_restart, "edit": cmd_edit,
        "ports": cmd_ports, "image": cmd_image,
        "enable": cmd_enable, "disable": cmd_disable,
        "uninstall": cmd_uninstall,
    }
    fn = table.get(cmd)
    if fn is None:
        warn(f"未知命令: {cmd}")
        usage()
        return 1
    return fn(rest)


def usage() -> None:
    banner()
    out(f"{S.b}用法{S.rst}")
    out()
    out(f"  ckvm create               交互式创建（一步一步问）")
    out(f"  ckvm create <名字> [选项]  命令式创建，见 ckvm create --help")
    out(f"  ckvm list                 列出虚拟机")
    out(f"  ckvm start <名字> [-f]    启动（-f 前台）")
    out(f"  ckvm stop <名字>          停止")
    out(f"  ckvm rm <名字> [-f]       删除")
    out(f"  ckvm show <名字>          看配置")
    out(f"  ckvm tune <名字>          优化 guest 内部 apt（--status/--revert）")
    out(f"  ckvm console <名字> [-a]  看串口（默认实时，-a 全部，-n N 最后 N 行）")
    out(f"  ckvm ssh <名字>           直接登进 guest（-p 只打印命令）")
    out(f"  ckvm net [名字]           网络情况")
    out(f"  ckvm status <名字>        运行状态、CPU 亲和、串口摘要")
    out(f"  ckvm ports <名字> [add/rm] 看或改端口映射")
    out(f"  ckvm edit <名字>          编辑 vm.conf")
    out(f"  ckvm image [版本]         只下载/缓存基础镜像")
    out(f"  ckvm enable|disable <名字> 开机自启")
    out(f"  ckvm selftest             只检查配置，不启动虚拟机")
    out(f"  ckvm uninstall            卸载（保留虚拟机数据）")
    out(f"  ckvm mirror               换 apt 源（测速后你选）")
    out(f"  ckvm cache [--clear]      镜像缓存")
    out(f"  ckvm versions [发行版]     可选版本（ubuntu/debian/fedora/arch）")
    out()
    out(f"{S.dim}数据: {CKVM_ROOT}    固件: {FW_DIR}{S.rst}")
    out()


def cmd_versions(rest: list[str]) -> int:
    """List releases, for one distro or for all of them."""
    want = rest[0] if rest else ""
    if want and want not in DISTRO_BY_KEY:
        die(f"不支持的发行版: {want}；可选: {', '.join(DISTRO_BY_KEY)}")

    for d in DISTROS:
        if want and d.key != want:
            continue
        header(f"可用的 {d.name} 版本", d.note)
        out(f"  {S.dim}{pad('版本', 8)} {pad('代号', 14)} "
            f"{pad('标记', 10)} 大小{S.rst}")
        for ver, code, tag, size in d.releases:
            mark = f"{S.g}{tag}{S.rst}" if tag else " " * len(tag)
            cached = f"  {S.g}✓ 已缓存{S.rst}" if cache_ready(ver, d) else ""
            out(f"  {pad(ver, 8)} {pad(code, 14)} {pad(mark, 10)} {size}{cached}")
        out()
    return 0


def cmd_cache(rest: list[str]) -> int:
    os.makedirs(CACHE_DIR, exist_ok=True)
    if rest and rest[0] == "--path":
        print(CACHE_DIR)
        return 0
    if rest and rest[0] == "--clear":
        target = rest[1] if len(rest) > 1 else None
        if target:
            hits = [p for d in DISTROS
                    if os.path.isfile(p := cache_img(target, d))]
            if not hits:
                die(f"缓存里没有 {target}")
            for p in hits:
                os.remove(p)
                ok(f"已删除缓存: {os.path.basename(p)}")
        else:
            shutil.rmtree(CACHE_DIR, ignore_errors=True)
            ok("已清空镜像缓存")
        return 0

    header("💾 镜像缓存", CACHE_DIR)
    rows = []
    for d in DISTROS:
        for ver, _code, _tag, _size in d.releases:
            p = cache_img(ver, d)
            if os.path.isfile(p):
                rows.append((d, ver, p))
    if not rows:
        info("（空）— 下一次 ckvm create 会在这里缓存基础镜像")
        info("多个虚拟机共用同一份，只有第一次需要下载")
        out()
        return 0
    out(f"  {S.dim}{pad('发行版', 12)} {pad('版本', 8)} "
        f"{pad('大小', 10, 'right')}  状态{S.rst}")
    out(f"  {S.dim}{rule(48)}{S.rst}")
    total = 0
    for d, ver, p in rows:
        sz = os.path.getsize(p)
        total += sz
        mark = f"{S.g}✓{S.rst}" if cache_ready_path(p) else f"{S.y}不完整{S.rst}"
        out(f"  {pad(d.name, 12)} {pad(ver, 8)} {pad(human(sz), 10, 'right')}  {mark}")
    out(f"  {S.dim}{rule(48)}{S.rst}")
    out(f"  {pad('合计', 12)} {pad('', 8)} {pad(human(total), 10, 'right')}")
    out()
    return 0


def human(n: int) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}T"


def cmd_list(_rest: list[str]) -> int:
    names = list_guests()
    if not names:
        header("虚拟机")
        info("还没有虚拟机。跑 ckvm create 建一个")
        out()
        return 0
    rows = []
    for n in names:
        cfg = load_vm(n)
        rows.append((
            n,
            "running" if running(n) else "stopped",
            distro_of(cfg).name,
            cfg.get("UBUNTU_REL", "?"),
            cfg.get("CPUS", "?"),
            cfg.get("MEM", "?"),
            cfg.get("DISK_GB", "?"),
            cfg.get("PORT", "?"),
            cfg.get("CPUSET", "?"),
        ))
    w = max(width(r[0]) for r in rows)
    dw = max(width(r[2]) for r in rows)
    header("虚拟机")
    out(f"  {S.dim}{pad('名字', w)}  {pad('状态', 9)} {pad('发行版', dw)} "
        f"{pad('版本', 7)} {pad('vCPU', 4)} {pad('内存', 6)} {pad('磁盘', 6)} "
        f"{pad('物理核', 9)} 连接{S.rst}")
    for n, st, dname, rel, cpus, mem, disk, port, mask in rows:
        col = S.g if st == "running" else S.dim
        dot = "●" if st == "running" else "○"
        how = f"ssh {load_vm(n).get('VM_USER', distro_of(load_vm(n)).default_user)}" \
              f"@127.0.0.1 -p {port}"
        out(f"  {pad(n, w)}  {col}{dot} {pad(st, 7)}{S.rst} {pad(dname, dw)} "
            f"{pad(rel, 7)} {pad(cpus, 4)} {pad(mem, 6)} {pad(disk + 'G', 6)} "
            f"{pad(dim_mask(mask), 9)} {S.dim}{how}{S.rst}")
    out()
    return 0


def dim_mask(mask: str) -> str:
    return f"{S.dim}{mask}{S.rst}"


def cmd_show(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm show <名字>")
    name = rest[0]
    cfg = load_vm(name)
    header(f"🔧 {name}")
    d = distro_of(cfg)
    keys = [
        ("发行版", None), ("版本", "UBUNTU_REL"), ("vCPU", "CPUS"),
        ("内存", "MEM"), ("磁盘", "DISK_GB"), ("端口", "PORT"),
        ("物理核", "CPUSET"), ("网络", "NET_MODE"),
        ("端口映射", "FORWARDS"), ("磁盘缓存", "CACHE_MODE"),
        ("用户", "VM_USER"), ("内部优化", "TUNE"),
    ]
    w = max(width(k) for k, _ in keys)
    for label, key in keys:
        if key is None:
            v = d.name
        else:
            v = cfg.get(key, "")
        if key == "CPUSET" and v:
            v = mask_label(v)
        if key == "TUNE":
            v = "启用" if v == "yes" else "不启用"
        out(f"  {pad(label, w)}  {v}")
    out()
    return 0



def ask_account(default_user: str = "ubuntu") -> tuple[str, str]:
    """Login name and password, including a name of the user's choosing."""
    items = [
        (default_user, "推荐，可以 sudo"),
        ("root", "直接用 root 登录"),
        ("自定义", "自己指定用户名"),
    ]
    idx = menu("登录账号", items, default=1)
    if idx == 1:
        user = "root"
    elif idx == 2:
        while True:
            raw = ask("用户名", "")
            if re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", raw or ""):
                user = raw
                break
            warn("用户名只能用 a-z 0-9 _ -，且不能以数字开头")
    else:
        user = default_user

    out()
    env_pw = os.environ.get("CKVM_PW", "")
    if env_pw:
        info("密码取自 CKVM_PW")
        return user, env_pw
    while True:
        p1 = ask_secret(f"{user} 的密码")
        p2 = ask_secret("再输一次")
        if p1 == p2:
            ok("密码已设置")
            return user, p1
        warn("两次不一致，重新输入")


def cmd_create(rest: list[str]) -> int:
    """
    Interactive when it needs to be, command-driven when given flags.

    Any option supplied here is used as-is and not asked again; anything left
    out is asked.  So `ckvm create` is the full wizard and
    `ckvm create web --rel 24.04 --cpus 4 --pass x` runs straight through.
    """
    banner()

    # ---- parse options -------------------------------------------------
    # switches take no value; everything else does
    SWITCHES = {"yes", "y", "interactive", "i", "on", "off",
                "dry-run", "dry", "help", "h"}
    o: dict[str, str] = {}
    name = ""
    i = 0
    while i < len(rest):
        a = rest[i]
        if a.startswith("--"):
            key = a[2:]
            if key in SWITCHES:
                o[key] = "1"
                i += 1
                continue
            if i + 1 >= len(rest):
                die(f"{a} 后面要跟一个值")
            o[key] = rest[i + 1]
            i += 2
        elif a == "-i":
            o["interactive"] = "1"
            i += 1
        elif not name:
            name = a
            i += 1
        else:
            i += 1

    unknown = sorted(set(o) - {"distro", "rel", "cpus", "cores", "mem", "disk",
                               "port", "net", "fwd", "user", "pass", "cache",
                               "tune", "hostname", "yes", "interactive",
                               "dry-run", "dry"})
    if unknown:
        die(f"不认识的选项: {' '.join('--' + u for u in unknown)}\n"
            f"     可用: --distro --rel --cpus --cores --mem --disk --port "
            f"--net --fwd --user --pass --cache --tune --yes --dry-run")

    # --dry-run and --yes both mean "do not ask me anything": use defaults for
    # whatever the command line did not specify.
    DRY = bool(o.get("dry-run") or o.get("dry"))
    QUIET = bool(o.get("yes")) or DRY
    if DRY:
        o.setdefault("yes", "1")

    # ---- validate everything given on the command line, before asking ----
    # otherwise a bad value is only reported after the interactive questions
    def bad(msg: str) -> None:
        die(msg)

    if o.get("distro") and o["distro"] not in DISTRO_BY_KEY:
        bad(f"不支持的发行版: {o['distro']}；可选: {', '.join(DISTRO_BY_KEY)}")
    if o.get("rel"):
        # without --distro the release could belong to any family, so only
        # complain when we know which one was meant
        if o.get("distro"):
            pre = DISTRO_BY_KEY[o["distro"]]
            if o["rel"] not in [r[0] for r in pre.releases]:
                bad(f"{pre.name} 没有 {o['rel']}；"
                    f"可选: {', '.join(r[0] for r in pre.releases)}")
        elif not any(o["rel"] in [r[0] for r in d.releases] for d in DISTROS):
            allr = ", ".join(f"{d.key}:{r[0]}"
                             for d in DISTROS for r in d.releases)
            bad(f"没有版本 {o['rel']}；可选: {allr}")
    if name and not valid_name(name):
        bad(f"名字只能用字母数字和 _ . - ：{name}")
    if name and os.path.isdir(vm_dir(name)):
        bad(f"'{name}' 已经存在")
    if o.get("cpus") and not (o["cpus"].isdigit() and int(o["cpus"]) >= 1):
        bad(f"--cpus 必须是正整数，收到: {o['cpus']}")
    if o.get("cores"):
        c = o["cores"]
        c = DEF_CORES if c == "all" else ("6-7" if c == "big" else c)
        try:
            cs = mask_cores(c)
        except ValueError as e:
            bad(f"--cores {o['cores']}: {e}")
        if any(x > 7 for x in cs):
            bad(f"--cores {o['cores']}: 这台机器只有核 0-7")
    for key, label, lo in (("mem", "内存 (MiB)", 256), ("disk", "磁盘 (GiB)", 2)):
        v = o.get(key, "")
        if v and not (v.isdigit() and int(v) >= lo):
            bad(f"--{key} 至少 {lo}，收到: {v}")
        if v and key == "mem" and int(v) > 8192:
            warn(f"--mem {v} 超过本机可用内存，可能起不来")
    if o.get("cache") and o["cache"] not in CACHE_MODES:
        bad(f"--cache 只能是: {', '.join(CACHE_MODES)}")
    if o.get("fwd"):
        for part in o["fwd"].split(","):
            part = part.strip()
            if part:
                try:
                    forward_text(part)
                except ValueError as e:
                    bad(f"--fwd {part}: {e}")
    if o.get("user") and not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", o["user"]):
        bad(f"--user 不合法: {o['user']}")
    if o.get("port"):
        p = o["port"]
        if not p.isdigit() or not (1 <= int(p) <= 65535):
            bad(f"--port 必须是 1-65535，收到: {p}")
        if port_busy(int(p)):
            bad(f"--port {p} 已被占用")
    if o.get("net") and o["net"] not in ("user", "host"):
        bad(f"--net 只能是 user 或 host，收到: {o['net']}")

    header("创建虚拟机")

    # ---- distro ---------------------------------------------------------
    # Never assumed.  Two earlier versions of this got it wrong: passing a
    # default into o.get() made the key always truthy so the menu was dead code
    # and every create was Ubuntu; then --rel alone still fell through to
    # Ubuntu, so --rel 13 made an Ubuntu guest.  Now the family is chosen
    # explicitly, or inferred from a release that only one family has.
    dkey = o.get("distro", "")
    candidates = DISTROS
    if not dkey and o.get("rel"):
        matches = [d for d in DISTROS if o["rel"] in [r[0] for r in d.releases]]
        if len(matches) == 1:
            # unambiguous: only one family publishes that release number
            dkey = matches[0].key
        elif len(matches) > 1:
            candidates = matches
            if QUIET:
                die(f"{o['rel']} 在多个发行版里都有: "
                    f"{', '.join(d.key for d in matches)}；请加 --distro")
    elif not dkey and QUIET:
        # no menu is possible, and guessing is what caused the bug
        die("需要指定发行版。\n"
            f"     --distro {' | '.join(DISTRO_BY_KEY)}\n"
            f"     例如： ckvm create web --distro debian --rel 13 --yes")

    picked = False
    if dkey:
        if dkey not in DISTRO_BY_KEY:
            die(f"不支持的发行版: {dkey}；可选: {', '.join(DISTRO_BY_KEY)}")
        distro = DISTRO_BY_KEY[dkey]
    else:
        items = [(d.name, d.note or "") for d in candidates]
        idx = menu("发行版", items, default=1)
        if idx is None:
            info("已取消")
            return 1
        distro = candidates[idx]
        picked = True
    rels = [r[0] for r in distro.releases]
    if not picked:
        # say which one, but not twice: the arrow-key menu already echoed it
        ok(f"{distro.name}")

    # ---- release --------------------------------------------------------
    # Same rule as the family: never assumed.  With no menu available, an
    # implicit "latest" is a silent decision, so ask for --rel instead.
    rel = o.get("rel", "")
    if rel:
        if rel not in rels:
            die(f"{distro.name} 没有 {rel}；可选: {', '.join(rels)}")
    elif QUIET:
        die(f"需要指定版本。\n"
            f"     --rel {' | '.join(rels)}\n"
            f"     例如： ckvm create web --distro {distro.key} "
            f"--rel {rels[-1]} --yes")
    else:
        items = []
        for ver, code, tag, size in distro.releases:
            desc = code + (f"  {S.g}{tag}{S.rst}" if tag else "") + f"  {size}"
            items.append((ver, desc))
        default = rels.index(DEF_REL) + 1 if DEF_REL in rels else 1
        idx = menu(f"{distro.name} 版本", items, default=default)
        if idx is None:
            info("已取消")
            return 1
        rel = rels[idx]
    ok(f"{distro.name} {rel}")
    out()

    # ---- name -----------------------------------------------------------
    if not name:
        default_name = f"{distro.key}{rel.replace('.', '')}"
        name = default_name if QUIET else ask("虚拟机名字", default_name)
    if not valid_name(name):
        die(f"名字只能用字母数字和 _ . - ：{name}")
    if os.path.isdir(vm_dir(name)):
        die(f"'{name}' 已经存在")

    # ---- cpu ------------------------------------------------------------
    cpus = o.get("cpus", "")
    if not cpus:
        cpus = str(DEF_CPUS) if QUIET else ask("vCPU 数量", str(DEF_CPUS))
    if not cpus.isdigit() or int(cpus) < 1:
        die("vCPU 必须是正整数")
    out()

    # ---- physical cores -------------------------------------------------
    cores = o.get("cores", "")
    if cores:
        if cores == "all":
            cores = DEF_CORES
        elif cores == "big":
            cores = "6-7"
        try:
            cs = mask_cores(cores)
        except ValueError as e:
            die(f"--cores {cores}: {e}")
        bad = [c for c in cs if c > 7]
        if bad:
            die(f"这台机器只有核 0-7，越界: {bad}")
        ok(f"{mask_label(cores)}")
    elif QUIET:
        cores = DEF_CORES
    else:
        cores = ask_cores()
    out()

    # ---- memory / disk --------------------------------------------------
    mem = o.get("mem", "") or (str(DEF_MEM) if QUIET
                               else ask("内存 (MiB)", str(DEF_MEM)))
    disk = o.get("disk", "") or (str(DEF_DISK) if QUIET
                                 else ask("磁盘 (GiB)", str(DEF_DISK)))
    for label, v, lo in (("内存", mem, 256), ("磁盘", disk, 2)):
        if not v.isdigit() or int(v) < lo:
            die(f"{label} 至少 {lo}，收到: {v}")
    out()

    # ---- cache ----------------------------------------------------------
    cache = o.get("cache", "")
    if cache:
        if cache not in CACHE_MODES:
            die(f"--cache 只能是: {', '.join(CACHE_MODES)}")
    elif QUIET:
        cache = DEF_CACHE
    else:
        cache = ask_cache()
        out()

    # ---- tune -----------------------------------------------------------
    tune = o.get("tune", "")
    if tune:
        do_tune = "yes" if tune.lower() in ("yes", "y", "1", "on", "true") else "no"
    elif QUIET:
        do_tune = "yes"
    else:
        idx = menu("安装后自动优化", [
            ("启用", "装软件包会快一些"),
            ("不启用", "保持系统默认"),
        ], default=1, extra="之后随时可以改： ckvm tune <名字> / --revert")
        do_tune = "yes" if idx != 1 else "no"
    out()

    # ---- forwards -------------------------------------------------------
    fwd = o.get("fwd", "")
    if fwd:
        forwards = []
        for part in fwd.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                forwards.append(forward_text(part))
            except ValueError as e:
                die(f"--fwd {part}: {e}")
        if not forwards:
            die("--fwd 是空的")
    elif QUIET:
        forwards = [DEF_FORWARDS]
    else:
        forwards = edit_forwards([DEF_FORWARDS], next_free_port())
    out()

    # ---- account --------------------------------------------------------
    user = o.get("user", "")
    pw = o.get("pass", "") or os.environ.get("CKVM_PW", "")
    if user and pw:
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
            die(f"用户名不合法: {user}")
        ok(f"登录 {user}")
    elif QUIET and not pw:
        if not user:
            user = distro.default_user
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
            die(f"用户名不合法: {user}")
        ok(f"登录 {user}")
    else:
        if user:
            if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
                die(f"用户名不合法: {user}")
            out()
            got = ask_account(distro.default_user)
            user, pw = user, got[1]
        else:
            user, pw = ask_account(distro.default_user)
    out()

    # ---- summary --------------------------------------------------------
    out(f"{S.b}确认{S.rst}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    for k, v in (("名字", name), ("发行版", f"{distro.name} {rel}"), ("vCPU", cpus),
                 ("物理核", mask_label(cores)), ("内存", f"{mem} MiB"),
                 ("磁盘", f"{disk} GiB"), ("缓存", cache),
                 ("端口映射", ", ".join(forwards)),
                 ("登录", f"{user} / {'*' * len(pw)}"),
                 ("内部优化", "启用" if do_tune == "yes" else "不启用")):
        out(f"  {pad(k, 8)} {v}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    out()
    if not DRY and not o.get("yes") and not confirm("开始创建"):
        info("已取消")
        return 1
    out()

    # ---- dry run: describe everything, touch nothing --------------------
    if DRY:
        port = o.get("port", "") or str(next_free_port())
        planned_urls = distro.urls(rel)
        cached = find_cached(rel, distro)
        d = vm_dir(name)
        out(f"{S.b}试运行{S.rst}  {S.dim}不会下载、不会写入{S.rst}")
        out(f"  {S.dim}{rule(52)}{S.rst}")
        plan = [
            ("配置目录", d),
            ("vm.conf", vm_conf(name)),
            ("基础镜像", cached or planned_urls[0] if planned_urls else "?"),
            ("镜像状态", f"已缓存 {human(os.path.getsize(cached))}" if cached
                        else "需要下载"),
            ("磁盘", os.path.join(d, "disk.qcow2") + f"  {disk} GiB"),
            ("启动方式", "直接内核启动（-kernel）" if getattr(distro, "build", False)
                        else "UEFI 固件"),
            ("固件" if not getattr(distro, "build", False) else "内核",
             os.path.join(FW_DIR, FW_CODE) if not getattr(distro, "build", False)
             else "从 disk.qcow2 的 /boot/Image 取出"),
            ("cloud-init", os.path.join(d, "seed.img")),
            ("宿主机端口", f"{port} → guest 22"),
        ]
        w = max(width(k) for k, _ in plan)
        for k, v in plan:
            out(f"  {pad(k, w)}  {S.dim}{v}{S.rst}")
        out(f"  {S.dim}{rule(52)}{S.rst}")
        out()
        out(f"  {S.dim}备用镜像源:{S.rst}")
        for u in planned_urls:
            mark = f"{S.g}首选{S.rst}" if u == planned_urls[0] else f"{S.dim}备用{S.rst}"
            out(f"    {mark}  {S.dim}{u[:88]}{S.rst}")
        out()
        out(f"  {S.dim}QEMU 会以这些参数启动:{S.rst}")
        for line in group_args(prepare_qemu_args(
                name, load_vm_like(name, rel, cpus, mem, disk, port, cores,
                                   cache, forwards, o.get("net", DEF_NET),
                                   distro.key),
                materialize=False)):
            out(f"    {S.dim}{line}{S.rst}")
        out()
        ok("试运行结束，什么都没改")
        return 0

    # ---- write config ---------------------------------------------------
    port = o.get("port", "") or str(next_free_port())
    d = vm_dir(name)
    os.makedirs(d, exist_ok=True)
    cfg = {
        "NAME": name, "DISTRO": distro.key, "UBUNTU_REL": rel,
        "CPUS": cpus, "MEM": mem,
        "DISK_GB": disk, "PORT": port, "CPUSET": cores,
        "NET_MODE": o.get("net", DEF_NET), "FORWARDS": ",".join(forwards),
        "CACHE_MODE": cache, "VM_USER": user, "VM_PASS": pw,
        "TUNE": do_tune, "VM_HOSTNAME": o.get("hostname", name),
    }
    with open(vm_conf(name), "w", encoding="utf-8") as fh:
        for k, v in cfg.items():
            fh.write(f"{k}={v}\n")
    ok(f"配置已写入 {vm_conf(name)}")

    # ---- firmware -------------------------------------------------------
    code_src = os.path.join(FW_DIR, FW_CODE)
    if not os.path.isfile(code_src):
        die(f"缺少固件 {code_src}\n"
            f"     跑 ckvm install 会装好")
    shutil.copyfile(code_src, os.path.join(d, "uefi-code.fd"))
    var_src = os.path.join(FW_DIR, FW_VARS)
    if os.path.isfile(var_src):
        shutil.copyfile(var_src, os.path.join(d, "uefi-vars.fd"))
    ok("UEFI 固件已就位")

    # ---- cloud-init -----------------------------------------------------
    if not have("cloud-localds"):
        die("缺少 cloud-localds（apt-get install cloud-image-utils）")
    write_seed(name, user, pw, distro)
    ok("cloud-init 已生成")

    # ---- disk -----------------------------------------------------------
    if not base_image(rel, distro):
        warn(f"镜像没拿到；稍后跑 ckvm image {rel} 再 ckvm rm {name} 重建")
    else:
        make_disk(name, rel, int(disk), distro)
        ok(f"磁盘已就绪（{disk} GiB）")
        # Arch has no cloud-init, so the seed is ignored and the login has to be
        # written into the image itself
        if getattr(distro, "build", False):
            img = os.path.join(d, "disk.qcow2")
            if inject_arch_credentials(img, user, pw):
                ok("账号已写入镜像（Arch 没有 cloud-init）")
            else:
                warn("账号注入失败；guest 起来后只能用镜像自带的密码登录")

    out()
    out(f"  {S.g}🎉{S.rst} {S.b}{name}{S.rst} 创建完成")
    out(f"  {S.dim}启动它：{S.rst} {S.b}ckvm start {name}{S.rst}")
    out()
    return 0

def write_seed(name: str, user: str, pw: str, distro: "Distro" = None) -> None:
    """Build user-data / meta-data, then let cloud-localds package them."""
    d = vm_dir(name)
    hashed = hash_pw(pw)

    if user == "root":
        user_block = (
            "users:\n"
            "  - name: root\n"
            "    lock_passwd: false\n"
            f'    hashed_passwd: "{hashed}"\n'
        )
    else:
        # Debian's default group for sudo rights is "sudo"; Fedora and Arch use
        # "wheel".  The explicit sudo rule works either way, but naming the
        # right group avoids a guest where sudo silently is not configured.
        groups = "wheel" if (distro and distro.key in ("fedora", "arch")) \
            else "sudo"
        user_block = (
            "users:\n"
            f"  - name: {user}\n"
            "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
            f"    groups: {groups}\n"
            "    shell: /bin/bash\n"
            "    lock_passwd: false\n"
            f'    hashed_passwd: "{hashed}"\n'
        )

    user_data = (
        "#cloud-config\n"
        f"hostname: {name}\n"
        "manage_etc_hosts: true\n"
        "ssh_pwauth: true\n"
        "chpasswd:\n"
        "  expire: false\n"
        + user_block
    )

    with open(os.path.join(d, "user-data"), "w", encoding="utf-8") as fh:
        fh.write(user_data)
    with open(os.path.join(d, "meta-data"), "w", encoding="utf-8") as fh:
        fh.write(f"instance-id: {name}\nlocal-hostname: {name}\n")

    run(["cloud-localds",
         os.path.join(d, "seed.img"),
         os.path.join(d, "user-data"),
         os.path.join(d, "meta-data")])

def hash_pw(pw: str) -> str:
    """
    SHA-512 crypt, the $6$... form shadow and cloud-init expect.

    Python 3.13 removed the crypt module, and a plain sha512 hexdigest is NOT a
    valid crypt string - using one silently produced a guest whose password
    never worked.  openssl is present on any Debian/Ubuntu host.
    """
    for argv in (["openssl", "passwd", "-6", pw],
                 ["mkpasswd", "-m", "sha-512", pw]):
        rc, out_ = capture(argv)
        if rc == 0 and out_.strip().startswith("$6$"):
            return out_.strip()
    # last resort: let chpasswd set it in plain text
    return pw
def distro_of(cfg: dict) -> "Distro":
    """The distro a guest uses.  Guests from before multi-distro are Ubuntu."""
    return DISTRO_BY_KEY.get(cfg.get("DISTRO", "ubuntu"), UBUNTU)


# A real cloud image is hundreds of MB.  Anything smaller is a partial
# download, so size is a sufficient test and needs no marker file.
MIN_IMAGE = 100 * 1024 * 1024


def cache_ready_path(p: str) -> bool:
    try:
        return os.path.isfile(p) and os.path.getsize(p) >= MIN_IMAGE
    except OSError:
        return False


def cache_img(rel: str, distro: "Distro" = None) -> str:
    d = distro or UBUNTU
    return os.path.join(CACHE_DIR, d.cache_file(rel))


def find_cached(rel: str, distro: "Distro" = None) -> "str | None":
    """
    The cached image for a release, if any.

    With no distro given it also checks the other families, so a release whose
    number is unique (13, 42) is found regardless of who cached it.
    """
    d = distro or UBUNTU
    p = cache_img(rel, d)
    if cache_ready_path(p):
        return p
    if distro is None:
        for other in DISTROS:
            p2 = cache_img(rel, other)
            if cache_ready_path(p2):
                return p2
    return None


def cache_ready(rel: str, distro: "Distro" = None) -> bool:
    return find_cached(rel, distro) is not None


def base_image(rel: str, distro: "Distro" = None) -> bool:
    """Make sure the shared cache holds this release."""
    d = distro or UBUNTU
    os.makedirs(CACHE_DIR, exist_ok=True)
    found = find_cached(rel, d)
    if found:
        ok(f"使用缓存 {d.name} {rel}（{human(os.path.getsize(found))}，跳过下载）")
        return True
    if getattr(d, "build", False):
        return base_image_arch(rel, d)
    dst = cache_img(rel, d)
    if os.path.isfile(dst):
        warn("缓存里那份不完整，重新下载")
        os.remove(dst)
    for url in d.urls(rel):
        info(f"下载 {d.name} {rel}")
        if HAVE_UI:
            rc = watch_download(url, dst, f"{d.name} {rel}")
        else:
            rc = run(download_cmd(url, dst))
        if rc == 0 and cache_ready_path(dst):
            if HAVE_UI:
                bar_reveal(f"已缓存 {human(os.path.getsize(dst))}")
            ok(f"已缓存 {human(os.path.getsize(dst))}")
            return True
        warn("这个源不行，换下一个")
    return False


# --------------------------------------------------------------------------
# Arch: build a disk from the rootfs tarball
# --------------------------------------------------------------------------
BUILD_MIN_FREE = 3 * 1024 ** 3      # tarball + tree + image, with headroom


def free_mem() -> int:
    """MemAvailable in bytes, or 0 when it cannot be read."""
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) * 1024
    except Exception:
        pass
    return 0


def build_rootfs_image(tar_path: str, out_path: str, size_gb: int = 5) -> bool:
    """
    Turn the Arch Linux ARM rootfs tarball into a bootable ext4 image.

    Two routes, tried in order:

      mke2fs -d <tarball>        needs e2fsprogs built with libarchive.  The
                                 device's is not, WSL's is.
      extract, then -d <dir>     works anywhere, but needs the tree on disk.

    Refuses when there is not enough free memory, because running out mid-build
    does not fail cleanly - it makes the machine unresponsive.
    """
    avail = free_mem()
    if avail and avail < BUILD_MIN_FREE:
        die(f"可用内存只有 {human(avail)}，建 Arch 镜像需要约 "
            f"{human(BUILD_MIN_FREE)}。\n"
            f"     先停掉运行中的虚拟机腾出内存，再试：\n"
            f"       ckvm list && ckvm stop <名字>\n"
            f"     或者在内存更大的机器上建好，把镜像拷到 {CACHE_DIR}")

    if os.path.isfile(out_path):
        os.remove(out_path)

    with Spinner("建 ext4 镜像"):
        rc, out_ = capture(["mke2fs", "-t", "ext4", "-d", tar_path,
                            "-F", out_path, f"{size_gb}G"])
    if rc == 0 and cache_ready_path(out_path):
        return True

    if "libarchive" in out_:
        info("本机 mke2fs 不支持 tarball，改为解包后建盘")
    else:
        warn(f"直接从 tarball 建盘失败：{out_[-160:]}")

    root = tempfile.mkdtemp(prefix="ckvm-arch-")
    try:
        with Spinner("解包 rootfs"):
            rc = run(["tar", "xzf", tar_path, "-C", root])
        if rc != 0:
            return False
        with Spinner("建 ext4 镜像"):
            rc, out_ = capture(["mke2fs", "-t", "ext4", "-d", root,
                                "-F", out_path, f"{size_gb}G"])
        if rc != 0:
            warn(f"建盘失败：{out_[-200:]}")
            return False
        return cache_ready_path(out_path)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def inject_arch_credentials(img: str, user: str, pw: str) -> bool:
    """
    Set the login for an Arch guest by editing the image directly.

    Arch Linux ARM has no cloud-init, so the seed.img ckvm builds for Ubuntu and
    Debian is simply ignored - the guest boots to a login prompt that only the
    image's default password would satisfy.  This was found by booting one and
    watching it reach "alarm login:" while SSH kept timing out.

    debugfs edits /etc/shadow and /etc/group inside the image, which needs no
    mounting and no loop device.
    """
    if not have("debugfs"):
        return False

    hashed = hash_pw(pw)
    if not hashed.startswith("$"):
        return False

    tmpd = tempfile.mkdtemp(prefix="ckvm-arch-cred-")
    try:
        # ---- shadow: give the user and root a known password ----------
        sh = os.path.join(tmpd, "shadow")
        rc, _ = capture(["debugfs", "-R", f"dump /etc/shadow {sh}", img])
        if rc != 0 or not os.path.isfile(sh):
            return False
        lines = open(sh, encoding="utf-8").read().splitlines()
        found = False
        new = []
        for l in lines:
            f = l.split(":")
            if len(f) > 2 and f[0] == user:
                f[1] = hashed
                l = ":".join(f)
                found = True
            elif len(f) > 2 and f[0] == "root":
                f[1] = hashed
                l = ":".join(f)
            new.append(l)
        if not found:
            return False
        with open(sh, "w", encoding="utf-8") as fh:
            fh.write("\n".join(new) + "\n")

        # ---- passwd: make sure the shell is usable --------------------
        pwf = os.path.join(tmpd, "passwd")
        capture(["debugfs", "-R", f"dump /etc/passwd {pwf}", img])
        if os.path.isfile(pwf):
            plines = []
            for l in open(pwf, encoding="utf-8").read().splitlines():
                f = l.split(":")
                if len(f) > 6 and f[0] == user and ("nologin" in f[6] or not f[6]):
                    f[6] = "/bin/bash"
                    l = ":".join(f)
                plines.append(l)
            with open(pwf, "w", encoding="utf-8") as fh:
                fh.write("\n".join(plines) + "\n")

        # ---- group: wheel for sudo ------------------------------------
        grp = os.path.join(tmpd, "group")
        capture(["debugfs", "-R", f"dump /etc/group {grp}", img])
        if os.path.isfile(grp):
            glines = []
            for l in open(grp, encoding="utf-8").read().splitlines():
                f = l.split(":")
                if len(f) > 3 and f[0] == "wheel" and user not in f[3].split(","):
                    f[3] = (f[3] + "," + user).lstrip(",")
                    l = ":".join(f)
                glines.append(l)
            with open(grp, "w", encoding="utf-8") as fh:
                fh.write("\n".join(glines) + "\n")

        # ---- write them back ------------------------------------------
        # Three things had to be established by testing, all of which broke
        # this the first time:
        #   * `debugfs write` refuses an existing path with "Ext2 file already
        #     exists" and changes nothing, so the file must be removed first.
        #   * after rm+write the mode becomes 0644, and sshd will not use a
        #     world-readable /etc/shadow.
        #   * `set_inode_field mode 600` is read as OCTAL-ish and produced
        #     mode 01200 with a "bad type" inode, which then broke D-Bus and
        #     the SSH handshake.  The mode must be given as an octal string.
        modes = {"shadow": "0100600", "passwd": "0100644", "group": "0100644"}
        ok_all = True
        for name, dest in (("shadow", "/etc/shadow"),
                           ("passwd", "/etc/passwd"),
                           ("group", "/etc/group")):
            src = os.path.join(tmpd, name)
            if not os.path.isfile(src):
                continue
            capture(["debugfs", "-w", "-R", f"rm {dest}", img])
            rc, wout = capture(["debugfs", "-w", "-R",
                                f"write {src} {dest}", img])
            if "Allocated inode" not in wout and rc != 0:
                warn(f"写 {dest} 失败：{wout.strip()[-80:]}")
                ok_all = False
                continue
            capture(["debugfs", "-w", "-R",
                     f"set_inode_field {dest} mode {modes[name]}", img])
        return ok_all
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def arch_kernel_from_image(img: str, dest_dir: str) -> str:
    """
    Copy the kernel out of the rootfs image so QEMU can boot it directly.

    Arch on this device uses -kernel/-append instead of UEFI, because building
    an EFI system partition would need mkfs.vfat or mtools, which are not
    present.  debugfs reads the image without mounting it.
    """
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "Image")
    rc, _ = capture(["debugfs", "-R", f"dump /boot/Image {dest}", img])
    if rc == 0 and os.path.isfile(dest) and os.path.getsize(dest) > 1024 * 1024:
        return dest
    return ""


def base_image_arch(rel: str, distro: "Distro") -> bool:
    """Fetch the tarball and build the disk image from it."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    img = cache_img(rel, distro)
    if cache_ready_path(img):
        ok(f"使用缓存 {distro.name}（{human(os.path.getsize(img))}，跳过构建）")
        return True

    tar = img + ".tar.gz"
    # the tarball is a different size class from a finished image, so test it
    # directly rather than with cache_ready_path, which expects a >100MB image
    tar_ok = os.path.isfile(tar) and os.path.getsize(tar) > 600 * 1024 * 1024
    if not tar_ok:
        got = False
        for url in distro.urls(rel):
            info(f"下载 {distro.name} rootfs")
            rc = watch_download(url, tar, f"{distro.name} rootfs")
            if rc == 0 and os.path.isfile(tar) \
                    and os.path.getsize(tar) > 600 * 1024 * 1024:
                ok(f"已下载 {human(os.path.getsize(tar))}")
                got = True
                break
            warn("这个源不行，换下一个")
        if not got:
            return False

    info("从 rootfs 建盘（这一步吃内存和磁盘，几分钟）")
    if not build_rootfs_image(tar, img):
        return False
    ok(f"已建成 {human(os.path.getsize(img))}")

    # the tarball is no longer needed once the image exists
    try:
        os.remove(tar)
    except OSError:
        pass
    return True


def remote_size(url: str, timeout: int = 15) -> int:
    """Content-Length, or 0 when the server will not say."""
    import urllib.request
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "ckvm"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return int(r.headers.get("Content-Length") or 0)
    except Exception:
        return 0


def watch_download(url: str, outfile: str, label: str = "下载") -> int:
    """
    Run the downloader while showing progress.

    The total comes from a HEAD request; without it the spinner shows the byte
    count and no percentage, because a bar against a guessed total would be
    wrong rather than merely approximate.

    aria2c and curl are told to be quiet - their own progress output and ours
    would fight over the same line.
    """
    total = remote_size(url) or 0
    quiet_cmd = download_cmd(url, outfile, quiet=True)

    if not HAVE_UI or not UI_TTY:
        return run(quiet_cmd)

    proc = subprocess.Popen(quiet_cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    if total > 0:
        with Progress(label, total) as pr:
            while proc.poll() is None:
                try:
                    pr.update(os.path.getsize(outfile))
                except OSError:
                    pass
                time.sleep(0.25)
            try:
                pr.update(os.path.getsize(outfile))
            except OSError:
                pass
    else:
        with Spinner(label) as sp:
            while proc.poll() is None:
                try:
                    sp.note(human_bytes(os.path.getsize(outfile)))
                except OSError:
                    pass
                time.sleep(0.3)
    return proc.returncode


def download_cmd(url: str, outfile: str, quiet: bool = False) -> list[str]:
    """
    aria2c when available: several connections and real resume.

    It writes <outfile> itself rather than a .part, because aria2c keeps its
    control data in <outfile>.aria2 - pointing it at a different name while a
    stale control file exists makes it stall with no output.
    """
    if have("aria2c"):
        # a stale control file with no data makes aria2c sit and do nothing
        ctrl = outfile + ".aria2"
        try:
            if os.path.isfile(ctrl) and not os.path.isfile(outfile):
                os.remove(ctrl)
        except OSError:
            pass
        cmd = ["aria2c", "-x8", "-s8", "-k1M", "-c",
               "--file-allocation=none",
               "--console-log-level=warn", "--summary-interval=0",
               "--allow-overwrite=true", "--auto-file-renaming=false",
               "-d", os.path.dirname(outfile) or ".",
               "-o", os.path.basename(outfile), url]
        if quiet:
            cmd.insert(1, "--quiet=true")
        return cmd
    cmd = ["curl", "-fL", "-C", "-", "-o", outfile, url]
    if quiet:
        cmd.insert(1, "-sS")           # silent, but still report real errors
    else:
        cmd.insert(1, "--progress-bar")
    return cmd


def copy_with_progress(src: str, dst: str, label: str = "复制镜像") -> None:
    """
    Copy a file, showing how far along it is.

    shutil.copyfile has no callback and the source is a few hundred MB, so the
    copy is done in chunks and the byte count reported as it goes.
    """
    total = os.path.getsize(src)
    chunk = 4 * 1024 * 1024
    done = 0
    pr = Progress(label, total) if HAVE_UI else None
    if pr:
        pr.__enter__()
    try:
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            while True:
                buf = fi.read(chunk)
                if not buf:
                    break
                fo.write(buf)
                done += len(buf)
                if pr:
                    pr.update(done)
    finally:
        if pr:
            pr.__exit__()
    shutil.copystat(src, dst)


def make_disk(name: str, rel: str, disk_gb: int,
              distro: "Distro" = None) -> None:
    """
    Give the guest its own copy of the base image, resized.

    Arch keeps a raw disk.  Its boot needs the kernel extracted from the image
    with debugfs, which reads filesystems, not qcow2 containers - converting
    made the kernel unreachable.  The format is recorded in DISK_FMT so start
    passes the right -drive format.
    """
    d = vm_dir(name)
    img = os.path.join(d, "disk.qcow2")
    fmt = "qcow2"
    if os.path.isfile(img) and os.path.getsize(img) > 1024 * 1024:
        info("磁盘已存在")
    else:
        src = find_cached(rel, distro)
        if not src:
            raise RuntimeError(f"缓存里没有 {rel} 的镜像")
        copy_with_progress(src, img,
                           f"复制 {distro.name if distro else ''} 镜像".strip())
        _rc, info_txt = capture(["qemu-img", "info", img])
        if re.search(r"^file format:\s*raw\b", info_txt, re.M):
            fmt = "raw"
            if getattr(distro, "build", False):
                # leave it raw: debugfs has to read the kernel back out later
                info("基础镜像是 raw，Arch 直接使用 raw 磁盘")
            else:
                info("基础镜像是 raw，转成 qcow2")
                tmp = img + ".qc"
                if run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2",
                        img, tmp]) == 0 and os.path.getsize(tmp) > 1024 * 1024:
                    os.replace(tmp, img)
                    fmt = "qcow2"
                    ok("已转为 qcow2")
                else:
                    warn("转换失败，继续用 raw（磁盘仍可用）")
                    try:
                        os.remove(tmp)
                    except OSError:
                        pass
    run(["qemu-img", "resize", img, f"{disk_gb}G"])
    set_conf(name, "DISK_FMT", fmt)


def load_vm_like(name: str, rel: str, cpus: str, mem: str, disk: str,
                 port: str, cores: str, cache: str, forwards: list,
                 net: str, distro: str = "ubuntu") -> dict:
    """
    A cfg dict shaped like vm.conf, for planning without writing one.

    DISTRO must be present: distro_of() keys off it, and without it a dry run
    for Arch reported the Ubuntu boot path.
    """
    return {
        "NAME": name, "DISTRO": distro, "UBUNTU_REL": rel, "CPUS": cpus,
        "MEM": mem, "DISK_GB": disk, "PORT": port, "CPUSET": cores,
        "CACHE_MODE": cache, "FORWARDS": ",".join(forwards), "NET_MODE": net,
    }


def build_qemu_args(name: str, cfg: dict) -> list[str]:
    """
    The QEMU command line for a guest.

    Shared by `start` and by `--dry-run`, so the plan a dry run prints is the
    command that would actually run - they cannot drift apart.
    """
    d = vm_dir(name)
    port = cfg.get("PORT", str(DEF_PORT_BASE))
    cpus = cfg.get("CPUS", str(DEF_CPUS))
    mem = cfg.get("MEM", str(DEF_MEM))
    cpuset = cfg.get("CPUSET", DEF_CORES)
    cache = cfg.get("CACHE_MODE", DEF_CACHE)
    # Arch keeps a raw disk so debugfs can read the kernel back out of it
    disk_fmt = cfg.get("DISK_FMT", "qcow2")
    forwards = [f for f in cfg.get("FORWARDS", DEF_FORWARDS).split(",") if f]
    net = cfg.get("NET_MODE", DEF_NET)

    args = [
        "qemu-system-aarch64", "-name", name,
        "-M", "virt,gic-version=3", "-cpu", "max", "-accel", "kvm",
        "-smp", cpus, "-m", mem,
        "-drive", f"if=pflash,format=raw,unit=0,file={d}/uefi-code.fd,readonly=on",
        "-drive", f"if=pflash,format=raw,unit=1,file={d}/uefi-vars.fd",
        "-drive", f"if=virtio,format={disk_fmt},cache={cache},file={d}/disk.qcow2",
        "-drive", f"if=virtio,format=raw,readonly=on,file={d}/seed.img",
    ]
    if net == "user":
        hf = []
        for f in forwards:
            h, g = parse_forward(f)
            if g == 22:
                h = int(port)
            hf.append(f"hostfwd=tcp:0.0.0.0:{h}-:{g}")
        args += ["-netdev", "user,id=n0," + ",".join(hf),
                 "-device", "virtio-net-pci,netdev=n0"]
    args += ["-device", "virtio-rng-pci", "-display", "none",
             "-serial", "file:" + os.path.join(d, "serial.log")]

    if have("taskset") and cpuset:
        args = ["taskset", "-c", cpuset] + args
    return args


def group_args(argv: list[str], per_line: int = 2,
               width: int = 96) -> list[str]:
    """
    Group a QEMU argv into readable lines.

    Printing one element per line is unreadable; printing it all on one line
    wraps badly.  Options come in flag/value pairs, so group in pairs and split
    when a line would get too long.
    """
    lines: list[str] = []
    cur = ""
    i = 0
    while i < len(argv):
        n = per_line
        piece = " ".join(argv[i:i + n])
        i += n
        if cur and len(cur) + 1 + len(piece) > width:
            lines.append(cur)
            cur = piece
        else:
            cur = f"{cur} {piece}".strip()
    if cur:
        lines.append(cur)
    return lines


def prepare_qemu_args(name: str, cfg: dict, materialize: bool = True) -> list[str]:
    """
    The final QEMU command line, including the Arch special case.

    Arch guests boot by direct kernel boot: -kernel plus -append, with the
    pflash drives removed, because the disk is a bare ext4 rootfs with no ESP
    and no bootloader.  Verified under QEMU -M virt: the Arch kernel reaches
    systemd.

    materialize=False is for --dry-run: it reports that the kernel would be
    extracted from the image rather than extracting it, so a preview stays
    free of side effects.
    """
    args = build_qemu_args(name, cfg)
    if not getattr(distro_of(cfg), "build", False):
        return args

    d = vm_dir(name)
    # Drop the two pflash drives as flag/value pairs.  Filtering element by
    # element removed only the value - "if=pflash..." matched but "-drive" did
    # not - which left a stray -drive and made QEMU exit immediately.
    args = drop_drive(args, "if=pflash")
    if materialize:
        kern = arch_kernel_from_image(os.path.join(d, "disk.qcow2"), d)
        if not kern:
            die(f"从 {d}/disk.qcow2 里取不到 /boot/Image；"
                f"重建一次： ckvm rm {name} -f && ckvm create {name}")
    else:
        kern = os.path.join(d, "boot/Image") + "  (启动时从镜像里取)"
    return args + ["-kernel", kern, "-append",
                   "console=ttyAMA0 root=/dev/vda rw"]


def set_conf(name: str, key: str, value: str) -> None:
    """Set one key in vm.conf, adding it if absent."""
    path = vm_conf(name)
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return
    out_lines, seen = [], False
    for l in lines:
        if l.startswith(key + "="):
            out_lines.append(f"{key}={value}")
            seen = True
        else:
            out_lines.append(l)
    if not seen:
        out_lines.append(f"{key}={value}")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out_lines) + "\n")
    except OSError:
        pass


def drop_drive(argv: list[str], match: str) -> list[str]:
    """
    Remove every `-drive <value>` pair whose value contains match.

    Written after a plain element filter broke the argv: it removed the value
    ("if=pflash,...") but kept the preceding "-drive", so QEMU saw two -drive
    flags in a row and refused to start.
    """
    out: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "-drive" and i + 1 < len(argv) and match in argv[i + 1]:
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return out


def port_busy(port: int) -> bool:
    """True when something already listens on this host port."""
    import socket
    for host in ("0.0.0.0", "127.0.0.1"):
        s_ = socket.socket()
        try:
            s_.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s_.bind((host, port))
        except OSError:
            return True
        finally:
            s_.close()
    return False


def next_free_port() -> int:
    """
    A port that is neither claimed by a guest config nor actually in use.

    Checking only the configs was not enough: an old guest (or anything else)
    can hold the port, and QEMU then refuses to start with a hostfwd error.
    """
    used = set()
    for n in list_guests():
        try:
            used.add(int(load_vm(n).get("PORT", "0")))
        except ValueError:
            pass
    p = DEF_PORT_BASE
    while p in used or port_busy(p):
        p += 1
    return p


def cmd_stop(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm stop <名字>")
    name = rest[0]
    load_vm(name)
    pid = guest_pid(name)
    if pid is None:
        info(f"{name} 没在运行")
        return 0
    os.kill(pid, signal.SIGTERM)
    ok(f"{name} 已停止")
    return 0


def cmd_rm(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm rm <名字> [-f]")
    name = rest[0]
    load_vm(name)
    if running(name) and "-f" not in rest:
        die(f"{name} 在运行；先 ckvm stop，或加 -f")
    if running(name):
        cmd_stop([name])
    if is_interactive() and "-f" not in rest:
        if not confirm(f"删除 {name}（数据不可恢复）", default=False):
            info("已取消")
            return 1
    shutil.rmtree(vm_dir(name), ignore_errors=True)
    ok(f"{name} 已删除")
    return 0



# --------------------------------------------------------------------------
# install / mirror
# --------------------------------------------------------------------------
APT_DEPS = ["qemu-system-arm", "qemu-utils", "cloud-image-utils", "aria2", "sshpass"]
BIN_DEPS = ["qemu-system-aarch64", "qemu-img", "cloud-localds"]
SOFT_DEPS = ["aria2c", "numfmt"]


def missing_deps() -> list[str]:
    return [b for b in BIN_DEPS if not have(b)]


def cmd_mirror(rest: list[str]) -> int:
    banner()
    if rest and rest[0] == "--restore":
        n = 0
        for path in ("/etc/apt/sources.list.d/debian.sources", "/etc/apt/sources.list"):
            bak = path + ".ckvm.bak"
            if os.path.exists(bak):
                shutil.copyfile(bak, path)
                n += 1
        ok(f"已恢复 {n} 个源文件") if n else info("没有备份可恢复")
        return 0

    cur = apt_current_mirror()
    info(f"当前源: {cur or '未知'}")
    base = pick_apt_mirror(cur)
    if base is None:
        info("保持当前源")
        return 0
    if apply_apt_mirror(base):
        ok(f"已切换到 {base}")
        info("立刻更新索引...")
        run(["apt-get", "update"])
    else:
        warn("没找到可改写的源文件")
    return 0


def cmd_install(rest: list[str]) -> int:
    banner()
    if os.geteuid() != 0:
        die("需要 root（用 sudo）")

    # -cn <url> pins the GitHub accelerator instead of asking
    accel_hint = os.environ.get("CKVM_ACCEL", "")
    i = 0
    while i < len(rest):
        if rest[i] in ("-cn", "--cn", "--accel") and i + 1 < len(rest):
            accel_hint = rest[i + 1]
            i += 2
            continue
        if rest[i].startswith("http"):
            accel_hint = rest[i]
        i += 1

    header("安装 ckvm")

    # ---- 1. dependencies -------------------------------------------
    miss = missing_deps()
    if miss:
        out(f"  {S.b}缺少依赖{S.rst}  {S.dim}{' '.join(miss)}{S.rst}")
        out()
        cur = apt_current_mirror()
        if "deb.debian.org" in cur or not cur:
            info("当前源是官方默认源，在国内通常很慢，先挑一个快的")
            base = pick_apt_mirror(cur)
            if base and apply_apt_mirror(base):
                ok(f"已切换到 {base}")
        out()
        info("——— apt-get update ———")
        run(["apt-get", "update"])
        out()
        info(f"——— apt-get install {' '.join(APT_DEPS)} ———")
        info("qemu 约 200 MB，慢的话几分钟；Ctrl-C 可中断")
        out()
        rc = run(["apt-get", "install", "-y"] + APT_DEPS)
        if rc != 0:
            warn(f"apt-get install 返回 {rc}")
    else:
        ok("依赖齐全")

    miss = missing_deps()
    if miss:
        warn(f"仍缺少: {' '.join(miss)}")
        return 1

    # ---- 2. firmware -----------------------------------------------
    out()
    already = (os.path.isfile(os.path.join(FW_DIR, FW_CODE))
               and os.path.isfile(os.path.join(FW_DIR, FW_VARS)))
    if already:
        ok(f"固件已在 {FW_DIR}")
    else:
        out(f"  {S.b}需要 UEFI 固件{S.rst}  {S.dim}（约 134 MB，不写 NVRAM 的 EDK2）{S.rst}")
        out()
        if accel_hint:
            accel = accel_hint
            info(f"使用指定的加速地址: {accel}")
        else:
            accel = pick_accel()
        os.makedirs(FW_DIR, exist_ok=True)

        # try the chosen accelerator, then the rest of the list, so a dead
        # mirror does not end the install
        order = [accel] + [a for a, _ in GITHUB_ACCEL if a != accel]
        okall = False
        for pref in order:
            good = True
            for fn in (FW_CODE, FW_VARS):
                url = f"{pref}{REPO_RAW}/kvm_manager/{fn}"
                dest = os.path.join(FW_DIR, fn)
                info(f"下载 {fn}  ({pref or '直连'})")
                rc = run(download_cmd(url, dest))
                if rc != 0 or not os.path.isfile(dest)                         or os.path.getsize(dest) < 1024 * 1024:
                    good = False
                    break
            if good:
                okall = True
                break
            warn(f"{(pref or '直连')} 不行，换下一个")
        if okall:
            ok(f"固件已安装到 {FW_DIR}")
        else:
            warn("固件没拿到；可以手动从设备拷：")
            info("su -c 'cp /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'")
            return 1

    # ---- 3. install the program itself ------------------------------
    out()
    me = os.path.abspath(__file__)
    dst = os.path.join(BINDIR, "ckvm.py")
    if me != dst:
        shutil.copyfile(me, dst)
        os.chmod(dst, 0o755)
    # The animations live in a second file.  Look for it beside this script; if
    # it is not there (a piped install that only fetched ckvm.py, say) fetch it,
    # because installing without it silently loses every spinner and bar.
    ui_dst = os.path.join(BINDIR, "ckvm_ui.py")
    ui = os.path.join(os.path.dirname(me), "ckvm_ui.py")
    if os.path.isfile(ui):
        shutil.copyfile(ui, ui_dst)
        ok("动画模块已安装")
    else:
        info("动画模块不在手边，取一份")
        got = False
        for pref in [accel] + [a for a, _ in GITHUB_ACCEL if a != accel]:
            url = f"{pref}{REPO_RAW}/kvm_manager/ckvm_ui.py"
            tmp = ui_dst + ".part"
            if run(download_cmd(url, tmp, quiet=True)) == 0 \
                    and os.path.isfile(tmp) \
                    and os.path.getsize(tmp) > 1024:
                os.replace(tmp, ui_dst)
                got = True
                break
        if got:
            ok("动画模块已安装")
        else:
            warn("动画模块没取到；ckvm 可用，只是没有动画")
    wrapper = os.path.join(BINDIR, "ckvm")
    with open(wrapper, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\nexec python3 " + dst + ' "$@"\n')
    os.chmod(wrapper, 0o755)
    ok(f"已安装: {wrapper}")

    # Leave the apt source pointing at something usable.  A fresh Debian
    # container comes with deb.debian.org, which is slow from China, and the
    # selftest reports it as a failure - so a just-installed ckvm would greet
    # the user with a red line.  Pick the fastest measured mirror when the
    # current one is a stock host.
    cur = apt_current_mirror()
    if "deb.debian.org" in cur or "archive.ubuntu.com" in cur or not cur:
        out()
        info(f"当前 apt 源 {cur or '未知'} 在国内很慢，测速换一个")
        fast = apt_pick_fastest_mirror()
        if fast and apply_apt_mirror(fast):
            ok(f"已换用 {fast}")
            info("更新索引...")
            run(["apt-get", "update", "-qq"])

    out()
    out(f"  {S.g}🎉{S.rst} {S.b}安装完成{S.rst}")
    out(f"  {S.dim}下一步：{S.rst} {S.b}ckvm create{S.rst}")
    out()
    return 0



# --------------------------------------------------------------------------
# tune - guest-side apt speed-ups
# --------------------------------------------------------------------------
TUNE_STEP_HOOK = "disable 99update-notifier hook"
TUNE_STEP_I18N = "drop translation indexes"
TUNE_STEP_MANDB = "disable man-db trigger"
TUNE_STEP_NR = "purge needrestart"


def guest_ssh(name: str, command: str, timeout: int = 600) -> tuple[int, str]:
    """
    Run a command inside the guest as its login user.

    Uses ssh over the published port.  sshpass supplies the password because the
    guest is a throwaway VM; a key would be nicer but the point here is to work
    on a freshly created machine with no setup.
    """
    cfg = load_vm(name)
    user = cfg.get("VM_USER", "ubuntu")
    pw = cfg.get("VM_PASS", "")
    port = cfg.get("PORT", str(DEF_PORT_BASE))
    if not pw:
        return 1, "guest 没记录密码"
    common = ["-o", "StrictHostKeyChecking=no",
              "-o", "UserKnownHostsFile=/dev/null",
              "-o", "LogLevel=ERROR",
              "-o", "ConnectTimeout=10"]

    if not have("sshpass"):
        return 1, "需要 sshpass（apt-get install sshpass）"
    argv = (["sshpass", "-e", "ssh"] + common
            + ["-o", "PubkeyAuthentication=no",
               "-o", "PreferredAuthentications=password",
               "-p", str(port), f"{user}@127.0.0.1", command])
    env = dict(os.environ, SSHPASS=pw)
    try:
        p = subprocess.run(argv, capture_output=True, text=True, env=env,
                           timeout=timeout)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except subprocess.TimeoutExpired:
        return 1, "超时"


def guest_root(name: str, command: str, timeout: int = 600) -> tuple[int, str]:
    """Same, but escalated with sudo when the login user is not root."""
    cfg = load_vm(name)
    if cfg.get("VM_USER", "ubuntu") == "root":
        return guest_ssh(name, command, timeout)
    quoted = command.replace("'", "'\\''")
    # try passwordless sudo first (works for root and for NOPASSWD users),
    # then fall back to feeding the password
    rc, out_ = guest_ssh(name, f"sudo -n true 2>/dev/null && echo __SUDO_OK__ || true",
                         timeout=120)
    if "__SUDO_OK__" in out_:
        return guest_ssh(name, f"sudo -n bash -c '{quoted}'", timeout)
    pw = cfg.get("VM_PASS", "")
    return guest_ssh(name, f"echo '{pw}' | sudo -S bash -c '{quoted}'", timeout)


def tune_status(name: str) -> None:
    header(f"🔧 {name} 的 guest 内部优化")
    rows = [
        ("99update-notifier hook", "test -f /etc/apt/apt.conf.d/99update-notifier "
                                   "&& echo 开 || echo 关"),
        ("翻译索引", "ls /var/lib/apt/lists/*Translation* 2>/dev/null | wc -l"),
        ("apt lists", "du -sh /var/lib/apt/lists 2>/dev/null | cut -f1"),
        ("man-db trigger", "test -f /var/lib/dpkg/info/man-db.triggers "
                           "&& echo 在 || echo 已移除"),
        ("needrestart", "dpkg -s needrestart >/dev/null 2>&1 && echo 装了 || echo 没装"),
    ]
    w = max(width(k) for k, _ in rows)
    for label, cmd in rows:
        _rc, out_ = guest_root(name, cmd, timeout=120)
        out_ = out_.strip().splitlines()[-1] if out_.strip() else "?"
        out(f"  {pad(label, w)}  {out_}")
    out()


def tune_apply(name: str, quiet: bool = False) -> bool:
    """Run every step.  Returns True when the guest is reachable."""
    steps = [
        (TUNE_STEP_HOOK,
         "test -f /etc/apt/apt.conf.d/99update-notifier && "
         "mv -f /etc/apt/apt.conf.d/99update-notifier "
         "/etc/apt/apt.conf.d/99update-notifier.disabled; true"),
        (TUNE_STEP_I18N,
         "rm -f /var/lib/apt/lists/*Translation* 2>/dev/null; true"),
        (TUNE_STEP_MANDB,
         "test -f /var/lib/dpkg/info/man-db.triggers && "
         "mv -f /var/lib/dpkg/info/man-db.triggers "
         "/var/lib/dpkg/info/man-db.triggers.ckvmbak; true"),
    ]
    reachable = False
    for label, cmd in steps:
        rc, out_ = guest_root(name, cmd, timeout=180)
        if rc == 0:
            reachable = True
        if not quiet:
            ok(label) if rc == 0 else warn(f"{label}: {out_[:80]}")
    # needrestart is only present on some images
    rc, out_ = guest_root(name, "dpkg -s needrestart >/dev/null 2>&1 && echo yes || echo no",
                          timeout=120)
    if "yes" in out_:
        rc2, _ = guest_root(
            name,
            "DEBIAN_FRONTEND=noninteractive apt-get purge -y needrestart "
            ">/dev/null 2>&1; true", timeout=600)
        if not quiet:
            ok(TUNE_STEP_NR) if rc2 == 0 else warn(TUNE_STEP_NR)
    elif not quiet:
        info("needrestart 未安装，跳过")
    return reachable


def tune_revert(name: str) -> None:
    guest_root(
        name,
        "mv -f /etc/apt/apt.conf.d/99update-notifier.disabled "
        "/etc/apt/apt.conf.d/99update-notifier 2>/dev/null; "
        "test -f /var/lib/dpkg/info/man-db.triggers.ckvmbak && "
        "mv -f /var/lib/dpkg/info/man-db.triggers.ckvmbak "
        "/var/lib/dpkg/info/man-db.triggers; true", timeout=180)
    ok("已恢复 hook 与 man-db trigger")
    info("needrestart 没有被装回来（它本来就是个可选的通知工具）")


def cmd_tune(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm tune <名字> [--status|--revert]")
    name, mode = rest[0], (rest[1] if len(rest) > 1 else "")
    load_vm(name)
    if not running(name):
        die(f"{name} 没在运行；tune 需要在 guest 内部执行")
    if mode == "--status":
        tune_status(name)
        return 0
    if mode == "--revert":
        tune_revert(name)
        return 0
    banner()
    header(f"🔧 guest 内部优化  {S.dim}{name}{S.rst}")
    if tune_apply(name):
        out()
        ok("完成")
        info(f"查看: ckvm tune {name} --status   恢复: ckvm tune {name} --revert")
    else:
        warn("guest 不可达；确认它已经启动到 SSH 就绪")
        return 1
    out()
    return 0


# --------------------------------------------------------------------------
# start
# --------------------------------------------------------------------------
def cmd_start(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm start <名字> [-f]")
    name = rest[0]
    fg = "-f" in rest
    cfg = load_vm(name)
    if running(name):
        info(f"{name} 已经在运行（pid {guest_pid(name)}）")
        return 0
    d = vm_dir(name)
    for f in ("uefi-code.fd", "disk.qcow2", "seed.img"):
        if not os.path.isfile(os.path.join(d, f)):
            die(f"缺少 {f}；先跑 ckvm create {name}")

    # vars must be refreshed from the template each start: a polluted NVRAM
    # makes GRUB hang.
    var_tpl = os.path.join(FW_DIR, FW_VARS)
    if os.path.isfile(var_tpl):
        shutil.copyfile(var_tpl, os.path.join(d, "uefi-vars.fd"))

    port = cfg.get("PORT", str(DEF_PORT_BASE))
    cpus = cfg.get("CPUS", str(DEF_CPUS))
    mem = cfg.get("MEM", str(DEF_MEM))
    cpuset = cfg.get("CPUSET", DEF_CORES)
    cache = cfg.get("CACHE_MODE", DEF_CACHE)
    forwards = [f for f in cfg.get("FORWARDS", DEF_FORWARDS).split(",") if f]
    net = cfg.get("NET_MODE", DEF_NET)

    # build_qemu_args already wraps the command in taskset when a mask is set
    args = prepare_qemu_args(name, cfg)

    out(f"  {S.b}{name}{S.rst}  {S.dim}{cpus} vCPU · {mem} MiB · {mask_label(cpuset)}"
        f" · 缓存 {cache}{S.rst}")
    if net == "user":
        for f in forwards:
            h, g = parse_forward(f)
            h = int(port) if g == 22 else h
            out(f"  {S.dim}宿主机 {h} {S.arrow} guest {g}{S.rst}")
    out()

    env = dict(os.environ)

    if fg:
        return run(args, env=env)

    info("启动 QEMU ...")
    log = open(os.path.join(d, "qemu.err"), "wb")
    p = subprocess.Popen(args, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         env=env, start_new_session=True)
    with open(os.path.join(d, "qemu.pid"), "w") as fh:
        fh.write(str(p.pid))
    time.sleep(3)
    if p.poll() is not None:
        err = ""
        try:
            err = open(os.path.join(d, "qemu.err"), encoding="utf-8",
                       errors="replace").read().strip().splitlines()
            err = err[0] if err else ""
        except Exception:
            pass
        die(f"QEMU 立刻退出: {err}")
    ok(f"QEMU 已启动（pid {p.pid}）")

    if net == "user":
        info("等 guest 启动到 SSH 就绪（最多 300 秒）...")
        if wait_ssh(name, int(port)):
            ok(f"SSH 已就绪  {S.b}{ssh_target(name)}{S.rst}")
            info(f"密码 {cfg.get('VM_PASS','')}   直连: ckvm ssh {name}")
            if cfg.get("TUNE", "no") == "yes":
                out()
                info("应用 guest 内部优化（TUNE=yes）...")
                done = tune_apply(name, quiet=True)
                if not done:
                    time.sleep(10)
                    done = tune_apply(name, quiet=True)
                if done:
                    ok("内部优化已应用")
                else:
                    warn("优化没应用上；可稍后跑 ckvm tune " + name)
        else:
            warn("等 SSH 超时；串口日志最后几行：")
            tail_serial(name, 8)
    return 0


def ssh_probe(name: str, port: int, timeout: int = 15) -> bool:
    """True when a real SSH command completes, not merely when the port is up."""
    cfg = load_vm(name)
    user = cfg.get("VM_USER", "ubuntu")
    # NOTE: no BatchMode here.  It disables interactive auth, which is exactly
    # what sshpass provides, so the probe could never succeed.
    common = ["-o", "StrictHostKeyChecking=no",
              "-o", "UserKnownHostsFile=/dev/null",
              "-o", "LogLevel=ERROR",
              "-o", "ConnectTimeout=5"]
    pw = cfg.get("VM_PASS", "")
    if not pw or not have("sshpass"):
        return False
    argv = (["sshpass", "-e", "ssh"] + common
            + ["-o", "PubkeyAuthentication=no",
               "-o", "PreferredAuthentications=password",
               "-p", str(port), f"{user}@127.0.0.1", "true"])
    env = dict(os.environ, SSHPASS=pw)
    try:
        return subprocess.run(argv, capture_output=True, env=env,
                              timeout=timeout).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def serial_last(name: str, width: int = 58) -> str:
    """
    The last meaningful serial line, for a progress note.

    Boot output is very noisy (kernel timestamps, systemd colour codes, the
    cloud-init fingerprint art), so pick the last line that says something:
    strip the escapes, drop the fingerprint block, and keep the tail.
    """
    p = os.path.join(vm_dir(name), "serial.log")
    try:
        with open(p, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 8192))
            raw = fh.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = [strip_ansi(x).strip() for x in raw.splitlines()]
    skip = ("+--", "|", "\\", "/", "=")
    for l in reversed(lines):
        if not l or l.startswith(skip):
            continue
        # kernel timestamp noise is not useful to a person waiting
        l = re.sub(r"^\[\s*[\d.]+\]\s*", "", l)
        l = re.sub(r"^cloud-init\[\d+\]:\s*", "", l)
        if len(l) < 4:
            continue
        return l[:width]
    return ""


def wait_ssh(name: str, port: int, timeout: int = 420) -> bool:
    """
    Wait until SSH accepts a command.

    Testing the socket is not enough: the port is forwarded while sshd is still
    starting, so the first real connection can be reset.

    Boot takes up to a few minutes, so while waiting this shows the last
    meaningful line from the serial console.  Waiting silently with a fixed
    message is indistinguishable from a hang.
    """
    import time as _t
    end = _t.time() + timeout
    sp = Spinner("等 guest 启动")
    with sp:
        while _t.time() < end:
            if ssh_probe(name, port):
                return True
            note = serial_last(name)
            if note:
                sp.note(note)
            _t.sleep(4)
    return False


def tail_serial(name: str, n: int = 8) -> None:
    p = os.path.join(vm_dir(name), "serial.log")
    if not os.path.isfile(p):
        return
    lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    for l in lines[-n:]:
        out(f"  {S.dim}{l[:100]}{S.rst}")




def ssh_target(name: str) -> str:
    """The exact ssh command for this guest, for display and for use."""
    cfg = load_vm(name)
    user = cfg.get("VM_USER", "ubuntu")
    port = cfg.get("PORT", str(DEF_PORT_BASE))
    return f"ssh {user}@127.0.0.1 -p {port}"


def cmd_ssh(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm ssh <名字>")
    name = rest[0]
    cfg = load_vm(name)
    if not running(name):
        die(f"{name} 没在运行")
    cmd = ssh_target(name)

    if "-p" in rest or "--print" in rest:
        print(cmd)
        print(f"# 密码 {cfg.get('VM_PASS','')}")
        return 0

    out(f"  {S.dim}密码 {cfg.get('VM_PASS','')}{S.rst}")
    out(f"  {S.b}{cmd}{S.rst}")
    out()
    if not have("sshpass"):
        # hand over a plain ssh the user can type, with the password shown
        info("（装了 sshpass 就能免密直连： apt-get install sshpass）")
        return run(["ssh", "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-p", str(cfg.get("PORT", DEF_PORT_BASE)),
                    f"{cfg.get('VM_USER','ubuntu')}@127.0.0.1"])
    user = cfg.get("VM_USER", "ubuntu")
    port = cfg.get("PORT", str(DEF_PORT_BASE))
    return run(["sshpass", "-p", cfg.get("VM_PASS", ""), "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password",
                "-p", str(port), f"{user}@127.0.0.1"])



# --------------------------------------------------------------------------
# status / restart / edit
# --------------------------------------------------------------------------
def cmd_status(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm status <名字>")
    name = rest[0]
    cfg = load_vm(name)
    header(f"📊 {name}")

    pid = guest_pid(name)
    if pid:
        rc, aff = capture(["taskset", "-pc", str(pid)])
        aff = aff.strip().split(":")[-1].strip() if rc == 0 else "?"
        out(f"  {pad('状态', 8)} {S.g}● running{S.rst}  {S.dim}pid {pid}{S.rst}")
        out(f"  {pad('CPU 亲和', 8)} {aff}")
    else:
        out(f"  {pad('状态', 8)} {S.dim}○ stopped{S.rst}")

    out(f"  {pad('配置', 8)} {cfg.get('CPUS','?')} vCPU, {cfg.get('MEM','?')} MiB, "
        f"磁盘 {cfg.get('DISK_GB','?')}G, 端口 {cfg.get('PORT','?')}")
    out(f"  {pad('物理核', 8)} {mask_label(cfg.get('CPUSET', DEF_CORES))}")
    pw = cfg.get("VM_PASS", "")
    out(f"  {pad('登录', 8)} {cfg.get('VM_USER','ubuntu')} / {'*' * len(pw)}"
        f"  {S.dim}要看密码： ckvm ssh {name} -p{S.rst}")
    if cfg.get("NET_MODE", DEF_NET) == "user":
        out(f"  {pad('连接', 8)} {ssh_target(name)}")

    log = os.path.join(vm_dir(name), "serial.log")
    if os.path.isfile(log):
        sz = os.path.getsize(log)
        out(f"  {pad('串口日志', 8)} {human(sz)}")
        txt = open(log, encoding="utf-8", errors="replace").read()
        if "login:" in txt:
            out(f"  {pad('登录提示', 8)} {S.g}已出现{S.rst}")
        out()
        out(f"  {S.dim}--- 串口最后 8 行 ---{S.rst}")
        for l in txt.splitlines()[-8:]:
            out(f"  {S.dim}{strip_ansi(l)[:100]}{S.rst}")
    else:
        out(f"  {pad('串口日志', 8)} {S.dim}（还没有）{S.rst}")
    out()
    return 0


def cmd_restart(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm restart <名字>")
    name = rest[0]
    load_vm(name)
    cmd_stop([name])
    time.sleep(2)
    return cmd_start([name] + [a for a in rest[1:]])


def cmd_edit(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm edit <名字>")
    name = rest[0]
    load_vm(name)
    ed = os.environ.get("EDITOR", "")
    if not ed:
        for cand in ("nano", "micro", "vim", "vi"):
            if have(cand):
                ed = cand
                break
    if not ed:
        die("找不到编辑器；设置 EDITOR=<你的编辑器>")
    info(f"用 {ed} 编辑 {vm_conf(name)}")
    rc = run([ed, vm_conf(name)])
    if rc == 0:
        info(f"已保存。改动要生效： ckvm restart {name}")
    return rc


# --------------------------------------------------------------------------
# ports - the forward table, editable
# --------------------------------------------------------------------------
def cmd_ports(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm ports <名字> [add <映射> | rm <映射>]")
    name = rest[0]
    cfg = load_vm(name)
    port = int(cfg.get("PORT", DEF_PORT_BASE))
    cur = [f for f in cfg.get("FORWARDS", DEF_FORWARDS).split(",") if f]

    action = rest[1] if len(rest) > 1 else ""

    if action == "add":
        if len(rest) < 3:
            die("用法: ckvm ports <名字> add 8080:80")
        try:
            item = forward_text(rest[2])
        except ValueError as e:
            die(str(e))
        if item in cur:
            info(f"{item} 已经在列表里")
        else:
            cur.append(item)
            save_forwards(name, cur)
            ok(f"已添加 {item}")
    elif action in ("rm", "remove", "del"):
        if len(rest) < 3:
            die("用法: ckvm ports <名字> rm 8080:80")
        target = rest[2]
        if target not in cur:
            die(f"列表里没有 {target}")
        cur.remove(target)
        save_forwards(name, cur)
        ok(f"已删除 {target}")
    elif action:
        die(f"不认识的动作: {action}（add / rm）")

    header(f"🌐 {name} 的端口映射")
    render_forwards(cur, port)
    out()
    if running(name) and action:
        info(f"改动要生效： ckvm restart {name}")
    return 0


def save_forwards(name: str, forwards: list[str]) -> None:
    """Rewrite FORWARDS in vm.conf, leaving other keys alone."""
    path = vm_conf(name)
    lines = open(path, encoding="utf-8").read().splitlines()
    out_lines, seen = [], False
    for l in lines:
        if l.startswith("FORWARDS="):
            out_lines.append("FORWARDS=" + ",".join(forwards))
            seen = True
        else:
            out_lines.append(l)
    if not seen:
        out_lines.append("FORWARDS=" + ",".join(forwards))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines) + "\n")


# --------------------------------------------------------------------------
# image - fetch/cache a base image without creating a guest
# --------------------------------------------------------------------------
def cmd_image(rest: list[str]) -> int:
    banner()
    # --distro selects the family; the release may also be given as
    # "debian:13" or "13" (searched across families)
    want_distro = ""
    args = []
    i = 0
    while i < len(rest):
        if rest[i] == "--distro" and i + 1 < len(rest):
            want_distro = rest[i + 1]
            i += 2
            continue
        args.append(rest[i])
        i += 1

    if not args:
        for d in DISTROS:
            if want_distro and d.key != want_distro:
                continue
            header(f"🖼  {d.name}", d.note)
            for ver, code, tag, size in d.releases:
                have_it = cache_ready(ver, d)
                mark = f"{S.g}✓ 已缓存{S.rst}" if have_it else f"{S.dim}未下载{S.rst}"
                out(f"  {pad(ver, 8)} {pad(code, 12)} {pad(size, 6)} {mark}")
            out()
        info("下载： ckvm image <版本>        例如 ckvm image 26.04")
        info("      ckvm image 13 --distro debian")
        out()
        return 0

    target = args[0]
    distro = None
    rel = ""
    if ":" in target:
        dk, _, rv = target.partition(":")
        if dk not in DISTRO_BY_KEY:
            die(f"不支持的发行版: {dk}；可选: {', '.join(DISTRO_BY_KEY)}")
        distro, rel = DISTRO_BY_KEY[dk], rv
        if rel not in [r[0] for r in distro.releases]:
            die(f"{distro.name} 没有 {rel}")
    else:
        if want_distro:
            if want_distro not in DISTRO_BY_KEY:
                die(f"不支持的发行版: {want_distro}")
            distro = DISTRO_BY_KEY[want_distro]
        for d in ([distro] if distro else DISTROS):
            if target in [r[0] for r in d.releases]:
                distro, rel = d, target
                break
        if not distro:
            if os.path.isfile(vm_conf(target)):
                cfg = load_vm(target)
                distro = distro_of(cfg)
                rel = cfg.get("UBUNTU_REL", DEF_REL)
                info(f"{target} 用的是 {distro.name} {rel}")
            else:
                allr = ", ".join(f"{d.key}:{r[0]}"
                                 for d in DISTROS for r in d.releases)
                die(f"不是已知版本也不是虚拟机: {target}\n     可选: {allr}")

    header(f"🖼  {distro.name} {rel}")
    found = find_cached(rel, distro)
    if found:
        ok(f"已在缓存里（{human(os.path.getsize(found))}）")
        out()
        return 0
    if base_image(rel, distro):
        out()
        ok("可以创建虚拟机了： ckvm create")
        out()
        return 0
    warn("所有镜像源都失败了")
    return 1


# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------
SYSTEMD_DIR = "/etc/systemd/system"
UNIT = "ckvm@.service"


def write_unit() -> str:
    """The template unit; %i is the guest name."""
    path = os.path.join(SYSTEMD_DIR, UNIT)
    os.makedirs(SYSTEMD_DIR, exist_ok=True)
    body = f"""[Unit]
Description=ckvm KVM guest %i
After=network.target

[Service]
Type=forking
ExecStart={BINDIR}/ckvm start %i
ExecStop={BINDIR}/ckvm stop %i
PIDFile={CKVM_ROOT}/%i/qemu.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return path


def have_systemd() -> bool:
    return os.path.isdir("/run/systemd/system") and have("systemctl")


def cmd_enable(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm enable <名字>")
    name = rest[0]
    if not valid_name(name):
        die(f"名字不合法: {name}")
    load_vm(name)
    if os.geteuid() != 0:
        die("需要 root（用 sudo）")
    if not have_systemd():
        warn("这个环境没有 systemd（容器里可能没跑 init）")
        return 1
    with open(vm_conf(name), "a", encoding="utf-8") as fh:
        fh.write("")   # ensure the file is there
    path = write_unit()
    info(f"写入 {path}")
    run(["systemctl", "daemon-reload"])
    rc = run(["systemctl", "enable", "--now", f"ckvm@{name}.service"])
    if rc == 0:
        ok(f"{name} 已设为开机自启并启动")
        info(f"管理： systemctl {{status,stop,restart}} ckvm@{name}")
    return rc


def cmd_disable(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm disable <名字>")
    name = rest[0]
    load_vm(name)
    if os.geteuid() != 0:
        die("需要 root（用 sudo）")
    if not have_systemd():
        warn("这个环境没有 systemd")
        return 1
    run(["systemctl", "disable", "--now", f"ckvm@{name}.service"])
    ok(f"{name} 已取消开机自启")
    return 0


def cmd_uninstall(rest: list[str]) -> int:
    banner()
    header("卸载 ckvm")
    if os.geteuid() != 0:
        die("需要 root（用 sudo）")

    guests = list_guests()
    if guests and is_interactive():
        out(f"  {S.y}注意{S.rst} 卸载只删程序，{S.b}{CKVM_ROOT} 里的虚拟机数据会保留")
        for g in guests:
            out(f"    {S.dim}{g}{S.rst}")
        out()
        if not confirm("继续卸载", default=False):
            info("已取消")
            return 1

    if have_systemd():
        rc, lst = capture(["systemctl", "list-units", "--all", "--no-legend",
                           "ckvm@*"])
        for line in lst.splitlines():
            unit = line.split()[0] if line.split() else ""
            if unit.startswith("ckvm@"):
                run(["systemctl", "disable", "--now", unit])
        unitp = os.path.join(SYSTEMD_DIR, UNIT)
        if os.path.isfile(unitp):
            os.remove(unitp)
            info(f"已删除 {unitp}")
        run(["systemctl", "daemon-reload"])

    for f in (os.path.join(BINDIR, "ckvm"), os.path.join(BINDIR, "ckvm.py")):
        if os.path.isfile(f):
            os.remove(f)
            info(f"已删除 {f}")

    out()
    ok("ckvm 已卸载")
    info(f"虚拟机数据仍在 {CKVM_ROOT}，要删就 rm -rf {CKVM_ROOT}")
    out()
    return 0


# --------------------------------------------------------------------------
# selftest - inspect only, never boots anything
# --------------------------------------------------------------------------
def cmd_selftest(rest: list[str]) -> int:
    banner()
    header("自检", "只检查配置，不启动虚拟机")

    checks: list[tuple[str, bool, str]] = []

    def add(label: str, good: bool, detail: str = ""):
        checks.append((label, good, detail))

    # ---- privileges and virtualisation --------------------------------
    add("root 权限", os.geteuid() == 0,
        "" if os.geteuid() == 0 else "需要 sudo")
    add("/dev/kvm", os.path.exists("/dev/kvm"),
        "" if os.path.exists("/dev/kvm") else "内核没启用 KVM，或没释放 EL2")

    # ---- tools ---------------------------------------------------------
    for b in BIN_DEPS:
        add(b, have(b), "" if have(b) else "缺少；跑 ckvm install")

    # ---- firmware ------------------------------------------------------
    code = os.path.join(FW_DIR, FW_CODE)
    varsf = os.path.join(FW_DIR, FW_VARS)
    add("UEFI 固件", os.path.isfile(code) and os.path.isfile(varsf),
        "" if os.path.isfile(code) else f"缺少 {FW_DIR}/edk2_*.fd")
    if os.path.isfile(code):
        sz = os.path.getsize(code)
        add("固件大小", sz > 1024 * 1024, human(sz))

    # ---- CPU topology --------------------------------------------------
    try:
        caps = []
        for i in range(8):
            p = f"/sys/devices/system/cpu/cpu{i}/cpu_capacity"
            if os.path.isfile(p):
                caps.append(int(open(p).read().strip()))
        if caps:
            add("CPU 拓扑", True,
                f"8 核，小核 {min(caps)} / 大核 {max(caps)}")
        else:
            add("CPU 拓扑", True, "读不到 cpu_capacity（非致命）")
    except Exception as e:
        add("CPU 拓扑", True, f"跳过: {e}")

    # ---- memory and disk ----------------------------------------------
    try:
        info_mem = {}
        for line in open("/proc/meminfo"):
            k, _, v = line.partition(":")
            info_mem[k.strip()] = v.strip()
        total = int(info_mem.get("MemTotal", "0 kB").split()[0]) * 1024
        avail = int(info_mem.get("MemAvailable", "0 kB").split()[0]) * 1024
        add("内存", avail > 512 * 1024 * 1024,
            f"总 {human(total)}，可用 {human(avail)}")
    except Exception:
        add("内存", True, "读不到 /proc/meminfo")

    try:
        st = os.statvfs(CKVM_ROOT if os.path.isdir(CKVM_ROOT) else "/")
        free = st.f_bavail * st.f_frsize
        add("磁盘", free > 5 * 1024 ** 3, f"{CKVM_ROOT} 可用 {human(free)}")
    except Exception:
        add("磁盘", True, "读不到 statvfs")

    # ---- state ---------------------------------------------------------
    n = len(list_guests())
    add("虚拟机", True, f"{n} 台" if n else "还没有")
    cached = [f for f in os.listdir(CACHE_DIR)] if os.path.isdir(CACHE_DIR) else []
    imgs = [f for f in cached if f.endswith("-arm64.img")]
    total_cache = sum(os.path.getsize(os.path.join(CACHE_DIR, f)) for f in imgs)
    add("镜像缓存", True, f"{len(imgs)} 个，{human(total_cache)}" if imgs else "空")

    # A stock mirror is slow, not broken: apt still works, so this is a warning
    # rather than a failure.  Counting it as a failure meant a just-installed
    # ckvm exited non-zero on its own selftest, and something the user can fix
    # with one command should not look like a broken install.
    cur = apt_current_mirror()
    slow = "deb.debian.org" in cur or "archive.ubuntu.com" in cur
    add("apt 源", True,
        (cur or "未知") + ("    慢，跑 ckvm mirror 换一个" if slow else ""))

    # ---- print ---------------------------------------------------------
    w = max(width(c[0]) for c in checks)
    bad = 0
    for label, good, detail in checks:
        mark = f"{S.g}{S.ok}{S.rst}" if good else f"{S.r}{S.no}{S.rst}"
        if not good:
            bad += 1
        out(f"  {mark} {pad(label, w)}  {S.dim}{detail}{S.rst}")
    out()

    if bad:
        warn(f"{bad} 项不满足；跑 ckvm install 一般能补齐")
        return 1
    ok("全部通过")
    out()
    info("下一步： ckvm create")
    out()
    return 0


# --------------------------------------------------------------------------
# console
# --------------------------------------------------------------------------
def cmd_console(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm console <名字> [-n N|-a]")
    name = rest[0]
    load_vm(name)
    log = os.path.join(vm_dir(name), "serial.log")
    if not os.path.isfile(log):
        die(f"还没有串口日志（{name} 从未启动过？）")

    lines: list[str] = []
    if "-a" in rest:
        lines = open(log, encoding="utf-8", errors="replace").read().splitlines()
    else:
        n = 30
        if "-n" in rest:
            try:
                n = int(rest[rest.index("-n") + 1])
            except (IndexError, ValueError):
                pass
        lines = open(log, encoding="utf-8", errors="replace").read().splitlines()[-n:]

    for l in lines:
        print(strip_ansi(l))
    if "-a" in rest or "-n" in rest:
        return 0

    info("（后面是实时输出，Ctrl-C 退出）")
    try:
        with open(log, encoding="utf-8", errors="replace") as fh:
            fh.seek(0, os.SEEK_END)
            while True:
                chunk = fh.readline()
                if chunk:
                    print(strip_ansi(chunk), end="")
                else:
                    time.sleep(0.5)
    except KeyboardInterrupt:
        print()
    return 0


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][AB0]")


def strip_ansi(s: str) -> str:
    """Drop terminal control sequences; the serial log is full of them."""
    return ANSI_RE.sub("", s).replace("\r", "")


# --------------------------------------------------------------------------
# net
# --------------------------------------------------------------------------
def cmd_net(rest: list[str]) -> int:
    banner()
    if rest:
        name = rest[0]
        cfg = load_vm(name)
        header(f"🌐 {name} 的网络")
        mode = cfg.get("NET_MODE", DEF_NET)
        port = cfg.get("PORT", "?")
        if mode == "user":
            out(f"  模式     QEMU user NAT（容器外要经宿主转发）")
            out(f"  SSH      ssh {cfg.get('VM_USER','ubuntu')}@127.0.0.1 -p {port}")
            out()
            out(f"  {S.b}端口映射{S.rst}")
            for f in [x for x in cfg.get("FORWARDS", "").split(",") if x]:
                h, g = parse_forward(f)
                h = int(port) if g == 22 else h
                out(f"    宿主机 {pad(str(h), 6)} {S.arrow} guest {g}")
        else:
            out(f"  模式     tap，guest 有自己的 IP")
            out(f"  guest    {TAP_GUEST}")
        out()
        return 0

    header("🌐 容器网络")
    rc, out_ = capture(["ip", "-brief", "addr"])
    for l in out_.splitlines():
        out(f"  {S.dim}{l.strip()}{S.rst}")
    out()
    guests = list_guests()
    if guests:
        out(f"  {S.b}虚拟机{S.rst}")
        for n in guests:
            cfg = load_vm(n)
            state = "running" if running(n) else "stopped"
            out(f"    {pad(n, 14)} {pad(state, 9)} "
                f"{cfg.get('NET_MODE','user')}  端口 {cfg.get('PORT','?')}")
        out()
    return 0


TAP_GUEST = "172.28.100.2/24"


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
