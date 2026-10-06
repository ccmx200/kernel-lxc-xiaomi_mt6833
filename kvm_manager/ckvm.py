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
import time
import unicodedata

VERSION = "2.0"

# --------------------------------------------------------------------------
# paths and defaults
# --------------------------------------------------------------------------
CKVM_ROOT = os.environ.get("CKVM_ROOT", "/var/lib/ckvm")
CACHE_DIR = os.path.join(CKVM_ROOT, ".cache")
FW_DIR = os.environ.get("CKVM_FWDIR", "/usr/local/share/ckvm/firmware")
BINDIR = "/usr/local/bin"

FW_CODE = "edk2_qemu_aarch64_nonvram.fd"
FW_VARS = "edk2_vars.fd"

DEF_CPUS = 8
DEF_MEM = 2048
DEF_DISK = 50
DEF_REL = "26.04"
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
GITHUB_ACCEL = [
    ("", "直连 GitHub（不加速）"),
    ("https://git.yylx.win/", "git.yylx.win"),
    ("https://ghproxy.net/", "ghproxy.net"),
    ("https://gh-proxy.com/", "gh-proxy.com"),
    ("https://mirror.ghproxy.com/", "mirror.ghproxy.com"),
]

REPO_RAW = "https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/refs/heads/resukisu"

# version | codename | lts | size
CATALOGUE = """\
22.04|jammy|LTS|673M
22.10|kinetic||716M
23.04|lunar||688M
23.10|mantic||684M
24.04|noble|LTS|592M
24.10|oracular||584M
25.04|plucky||680M
25.10|questing||843M
26.04|resolute|LTS|902M"""

CACHE_MODES = {
    "writeback": "宿主页缓存 + 尊重 flush（默认，等价于现状）",
    "none": "绕过宿主缓存（O_DIRECT），最保险但最慢",
    "unsafe": "忽略 flush，最快，断电可能损坏",
    "writethrough": "读走缓存，写直通",
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
         cancel: str = "取消", extra: str = "") -> int | None:
    """
    Numbered menu.  Returns the 0-based index, or None when cancelled.

    items: list of (label, description)
    """
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
    items.append(("自定义掩码", "例如 0-2,6-7 混搭大小核"))
    idx = menu("物理核心", items, default=1,
               extra="内核按 VM 快照了 ID 寄存器，任意掩码都可用")
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
    idx = menu("磁盘缓存", items, default=1,
               extra="qemu 打开磁盘时没有 O_DIRECT，所以 writeback 是现状，不是新增加速")
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
    out(f"{S.dim}先测速再选。按延迟排序曾经选中过最慢的那个，所以这里测的是吞吐。{S.rst}")
    out()

    results = []
    for host, name in APT_MIRRORS:
        url = f"https://{host}/debian"
        out(f"  {S.dim}测速 {name} ...{S.rst}", )
        speed = measure_url(f"{url}/dists/trixie/main/binary-arm64/Packages.gz")
        results.append((speed, url, name, host))
        print("\r\033[K", end="")

    results.sort(key=lambda r: -r[0])
    out(f"  {S.dim}{pad('源', 26)} {pad('吞吐', 10, 'right')}{S.rst}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    for speed, _url, name, host in results:
        bar = "" if speed <= 0 else f"{speed:5.2f} MB/s"
        mark = f"{S.g}★{S.rst}" if speed > 0 else f"{S.r}×{S.rst}"
        out(f"  {pad(name + '  (' + host + ')', 40)} {pad(bar, 10, 'right')} {mark}")
    out()

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
        "tune": cmd_tune,
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
    out(f"  ckvm create [名字]        交互式创建虚拟机")
    out(f"  ckvm list                 列出虚拟机")
    out(f"  ckvm start <名字> [-f]    启动（-f 前台）")
    out(f"  ckvm stop <名字>          停止")
    out(f"  ckvm rm <名字> [-f]       删除")
    out(f"  ckvm show <名字>          看配置")
    out(f"  ckvm tune <名字>          优化 guest 内部 apt（--status/--revert）")
    out(f"  ckvm mirror               换 apt 源（测速后你选）")
    out(f"  ckvm cache [--clear]      镜像缓存")
    out(f"  ckvm versions             可选 Ubuntu 版本")
    out()
    out(f"{S.dim}数据: {CKVM_ROOT}    固件: {FW_DIR}{S.rst}")
    out()


def cmd_versions(_rest: list[str]) -> int:
    header("可用的 Ubuntu 版本")
    out(f"  {S.dim}{pad('版本', 8)} {pad('代号', 14)} {pad('类型', 6)} 大小{S.rst}")
    for line in CATALOGUE.splitlines():
        ver, code, lts, size = line.split("|")
        tag = f"{S.g}LTS{S.rst}" if lts else "   "
        out(f"  {pad(ver, 8)} {pad(code, 14)} {pad(tag, 6)} {size}")
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
            p = os.path.join(CACHE_DIR, f"ubuntu-{target}-arm64.img")
            if os.path.isfile(p):
                os.remove(p)
                ok(f"已删除缓存: Ubuntu {target}")
            else:
                die(f"缓存里没有 Ubuntu {target}")
        else:
            shutil.rmtree(CACHE_DIR, ignore_errors=True)
            ok("已清空镜像缓存")
        return 0

    header("💾 镜像缓存", CACHE_DIR)
    entries = sorted(f for f in os.listdir(CACHE_DIR)
                     if f.startswith("ubuntu-") and f.endswith("-arm64.img"))
    if not entries:
        info("（空）— 下一次 ckvm create 会在这里缓存基础镜像")
        info("多个虚拟机共用同一份，只有第一次需要下载")
        out()
        return 0
    out(f"  {S.dim}{pad('版本', 10)} {pad('大小', 10, 'right')}  状态{S.rst}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    total = 0
    for f in entries:
        rel = f[len("ubuntu-"):-len("-arm64.img")]
        p = os.path.join(CACHE_DIR, f)
        sz = os.path.getsize(p)
        total += sz
        okmark = f"{S.g}✓{S.rst}" if cache_ready(rel) \
            else f"{S.y}不完整{S.rst}"
        out(f"  {pad(rel, 10)} {pad(human(sz), 10, 'right')}  {okmark}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    out(f"  {pad('合计', 10)} {pad(human(total), 10, 'right')}")
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
            cfg.get("CPUS", "?"),
            cfg.get("MEM", "?"),
            cfg.get("DISK_GB", "?"),
            cfg.get("PORT", "?"),
            cfg.get("CPUSET", "?"),
        ))
    w = max(width(r[0]) for r in rows)
    header("虚拟机")
    out(f"  {S.dim}{pad('名字', w)}  {pad('状态', 8)} {pad('vCPU', 4)} "
        f"{pad('内存', 6)} {pad('磁盘', 6)} {pad('端口', 6)} 物理核{S.rst}")
    for n, st, cpus, mem, disk, port, mask in rows:
        col = S.g if st == "running" else S.dim
        dot = "●" if st == "running" else "○"
        out(f"  {pad(n, w)}  {col}{dot} {pad(st, 6)}{S.rst} {pad(cpus, 4)} "
            f"{pad(mem, 6)} {pad(disk + 'G', 6)} {pad(port, 6)} {dim_mask(mask)}")
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
    keys = [
        ("Ubuntu", "UBUNTU_REL"), ("vCPU", "CPUS"), ("内存", "MEM"),
        ("磁盘", "DISK_GB"), ("端口", "PORT"), ("物理核", "CPUSET"),
        ("网络", "NET_MODE"), ("端口映射", "FORWARDS"),
        ("磁盘缓存", "CACHE_MODE"), ("用户", "VM_USER"),
        ("内部优化", "TUNE"),
    ]
    w = max(width(k) for k, _ in keys)
    for label, key in keys:
        v = cfg.get(key, "")
        if key == "CPUSET" and v:
            v = mask_label(v)
        out(f"  {pad(label, w)}  {v}")
    out()
    return 0



def ask_account() -> tuple[str, str]:
    """Login name and password.  Root is an explicit choice, not a default."""
    items = [
        ("ubuntu", "普通用户，可以 sudo"),
        ("root", "直接用 root 登录"),
    ]
    idx = menu("登录账号", items, default=1)
    user = "ubuntu" if idx is None or idx == 0 else "root"
    out()
    while True:
        p1 = ask_secret(f"{user} 的密码")
        p2 = ask_secret("再输一次")
        if p1 == p2:
            ok("密码已设置")
            return user, p1
        warn("两次不一致，重新输入")


def cmd_create(rest: list[str]) -> int:
    banner()
    header("创建 Ubuntu 虚拟机")

    # version
    items = []
    for line in CATALOGUE.splitlines():
        ver, code, lts, size = line.split("|")
        desc = f"{code}" + (f"  {S.g}LTS{S.rst}" if lts else "") + f"  {size}"
        items.append((ver, desc))
    idx = menu("Ubuntu 版本", items,
               default=[l.split("|")[0] for l in CATALOGUE.splitlines()].index(DEF_REL) + 1)
    if idx is None:
        info("已取消")
        return 1
    rel = CATALOGUE.splitlines()[idx].split("|")[0]
    ok(f"Ubuntu {rel}")
    out()

    name = ask("虚拟机名字", f"ubuntu{rel.replace('.', '')}")
    if not valid_name(name):
        die(f"名字只能用字母数字和 _ . - ：{name}")
    if os.path.isdir(vm_dir(name)):
        die(f"'{name}' 已经存在")
    cpus = ask("vCPU 数量", str(DEF_CPUS))
    if not cpus.isdigit() or int(cpus) < 1:
        die("vCPU 必须是正整数")
    out()
    cores = ask_cores()
    out()
    mem = ask("内存 (MiB)", str(DEF_MEM))
    disk = ask("磁盘 (GiB)", str(DEF_DISK))
    out()
    cache = ask_cache()
    out()
    idx = menu("guest 内部优化", [
        ("启用", "关掉拖慢 apt 的几个钩子（每次装包省几秒）"),
        ("不启用", "保持 Ubuntu 默认行为"),
    ], default=1, extra="可以随时用 ckvm tune <名字> 补上或撤销")
    do_tune = "yes" if idx == 0 else "no"
    out()
    forwards = edit_forwards([DEF_FORWARDS], next_free_port())
    out()
    user, pw = ask_account()
    out()

    # summary - includes the login, because it is chosen above
    out(f"{S.b}确认{S.rst}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    for k, v in (("名字", name), ("Ubuntu", rel), ("vCPU", cpus),
                 ("物理核", mask_label(cores)), ("内存", f"{mem} MiB"),
                 ("磁盘", f"{disk} GiB"), ("缓存", cache),
                 ("端口映射", ", ".join(forwards)),
                 ("登录", f"{user} / {'*' * len(pw)}"),
                 ("内部优化", "创建后启用" if do_tune == "yes" else "不启用")):
        out(f"  {pad(k, 8)} {v}")
    out(f"  {S.dim}{rule(40)}{S.rst}")
    out()
    if not confirm("开始创建"):
        info("已取消")
        return 1
    out()
    port = next_free_port()

    # ---- write the config ------------------------------------------
    d = vm_dir(name)
    os.makedirs(d, exist_ok=True)
    cfg = {
        "NAME": name, "UBUNTU_REL": rel, "CPUS": cpus, "MEM": mem,
        "DISK_GB": disk, "PORT": port, "CPUSET": cores,
        "NET_MODE": DEF_NET, "FORWARDS": ",".join(forwards),
        "CACHE_MODE": cache, "VM_USER": user, "VM_PASS": pw,
        "TUNE": do_tune,
        "VM_HOSTNAME": name,
    }
    with open(vm_conf(name), "w", encoding="utf-8") as fh:
        for k, v in cfg.items():
            fh.write(f"{k}={v}\n")
    ok(f"配置已写入 {vm_conf(name)}")

    # ---- firmware ---------------------------------------------------
    ok_src = os.path.join(FW_DIR, FW_CODE)
    if not os.path.isfile(ok_src):
        die(f"缺少固件 {ok_src}\n"
            f"     它应该在安装 ckvm 时放进 {FW_DIR}")
    shutil.copyfile(ok_src, os.path.join(d, "uefi-code.fd"))
    var_src = os.path.join(FW_DIR, FW_VARS)
    if os.path.isfile(var_src):
        shutil.copyfile(var_src, os.path.join(d, "uefi-vars.fd"))
    ok("UEFI 固件已就位")

    # ---- cloud-init seed -------------------------------------------
    if not have("cloud-localds"):
        die("缺少 cloud-localds（apt-get install cloud-image-utils）")
    write_seed(name, user, pw)
    ok("cloud-init 已生成")

    # ---- disk image ------------------------------------------------
    if not base_image(rel):
        warn("镜像没准备好，稍后可跑 ckvm image " + name)
    else:
        make_disk(name, rel, int(disk))
        ok(f"磁盘已就绪（{disk} GiB）")

    out()
    out(f"  {S.g}🎉{S.rst} {S.b}{name}{S.rst} 创建完成")
    out(f"  {S.dim}启动它：{S.rst} {S.b}ckvm start {name}{S.rst}")
    out()
    return 0


def key_paths(name: str) -> tuple[str, str]:
    d = vm_dir(name)
    return os.path.join(d, "id_ed25519"), os.path.join(d, "id_ed25519.pub")


def ensure_key(name: str) -> str:
    """Create a per-guest key pair if there is not one.  Returns the pubkey."""
    priv, pub = key_paths(name)
    if not os.path.isfile(pub):
        run(["ssh-keygen", "-t", "ed25519", "-N", "", "-C", f"ckvm@{name}",
             "-f", priv])
        os.chmod(priv, 0o600)
    try:
        return open(pub, encoding="utf-8").read().strip()
    except OSError:
        return ""


def write_seed(name: str, user: str, pw: str) -> None:
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
        user_block = (
            "users:\n"
            f"  - name: {user}\n"
            "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
            "    groups: sudo\n"
            "    shell: /bin/bash\n"
            "    lock_passwd: false\n"
            f'    hashed_passwd: "{hashed}"\n'
        )

    pub = ensure_key(name)
    # ssh_authorized_keys is a per-user field.  At the top level it only
    # applies to the *default* user, so a named user would never receive it.
    key_block = f"    ssh_authorized_keys:\n      - {pub}\n" if pub else ""

    user_data = (
        "#cloud-config\n"
        f"hostname: {name}\n"
        "manage_etc_hosts: true\n"
        "ssh_pwauth: true\n"
        "chpasswd:\n"
        "  expire: false\n"
        + user_block
        + key_block
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
def image_urls(rel: str) -> list[str]:
    f = f"ubuntu-{rel}-server-cloudimg-arm64.img"
    return [f"{m}/releases/{rel}/release/{f}" for m in MIRROR_IMAGES]


# A real cloud image is hundreds of MB.  Anything smaller is a partial
# download, so size is a sufficient test and needs no marker file.
MIN_IMAGE = 100 * 1024 * 1024


def cache_img(rel: str) -> str:
    return os.path.join(CACHE_DIR, f"ubuntu-{rel}-arm64.img")


def cache_ready(rel: str) -> bool:
    p = cache_img(rel)
    try:
        return os.path.isfile(p) and os.path.getsize(p) >= MIN_IMAGE
    except OSError:
        return False


def base_image(rel: str) -> bool:
    """Make sure the shared cache holds this release."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    dst = cache_img(rel)
    if cache_ready(rel):
        ok(f"使用缓存 Ubuntu {rel}（{human(os.path.getsize(dst))}，跳过下载）")
        return True
    if os.path.isfile(dst):
        warn("缓存里那份不完整，重新下载")
        os.remove(dst)
    for url in image_urls(rel):
        info(f"下载 {url}")
        rc = run(download_cmd(url, dst))
        if rc == 0 and cache_ready(rel):
            ok(f"已缓存 {human(os.path.getsize(dst))}")
            return True
        warn("这个源不行，换下一个")
    return False


def download_cmd(url: str, outfile: str) -> list[str]:
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
        return ["aria2c", "-x8", "-s8", "-k1M", "-c",
                "--file-allocation=none",
                "--console-log-level=warn", "--summary-interval=0",
                "--allow-overwrite=true", "--auto-file-renaming=false",
                "-d", os.path.dirname(outfile) or ".",
                "-o", os.path.basename(outfile), url]
    return ["curl", "-fL", "--progress-bar", "-C", "-", "-o", outfile, url]


def make_disk(name: str, rel: str, disk_gb: int) -> None:
    d = vm_dir(name)
    img = os.path.join(d, "disk.qcow2")
    if os.path.isfile(img) and os.path.getsize(img) > 1024 * 1024:
        info("磁盘已存在")
    else:
        info("从缓存复制基础镜像...")
        shutil.copyfile(cache_img(rel), img)
    run(["qemu-img", "resize", img, f"{disk_gb}G"])


def next_free_port() -> int:
    used = set()
    for n in list_guests():
        try:
            used.add(int(load_vm(n).get("PORT", "0")))
        except ValueError:
            pass
    p = DEF_PORT_BASE
    while p in used:
        p += 1
    return p


def cmd_start(rest: list[str]) -> int:
    if not rest:
        die("用法: ckvm start <名字>")
    name = rest[0]
    load_vm(name)
    if running(name):
        info(f"{name} 已经在运行")
        return 0
    pid = guest_pid(name)
    info(f"启动 {name} ...")
    die("启动流程尚未接上，下一步实现")
    return 0


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
SOFT_DEPS = ["aria2c", "sshpass", "numfmt"]


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
        accel = pick_accel()
        os.makedirs(FW_DIR, exist_ok=True)
        okall = True
        for fn in (FW_CODE, FW_VARS):
            url = f"{accel}{REPO_RAW}/kvm_manager/{fn}"
            info(f"下载 {fn}")
            rc = run(download_cmd(url, os.path.join(FW_DIR, fn)))
            if rc != 0 or not os.path.isfile(os.path.join(FW_DIR, fn)):
                warn(f"{fn} 下载失败")
                okall = False
                break
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
    wrapper = os.path.join(BINDIR, "ckvm")
    with open(wrapper, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\nexec python3 " + dst + ' "$@"\n')
    os.chmod(wrapper, 0o755)
    ok(f"已安装: {wrapper}")

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
    priv, _pub = key_paths(name)
    common = ["-o", "StrictHostKeyChecking=no",
              "-o", "UserKnownHostsFile=/dev/null",
              "-o", "LogLevel=ERROR",
              "-o", "ConnectTimeout=10"]

    if os.path.isfile(priv):
        argv = (["ssh"] + common
                + ["-i", priv, "-o", "IdentitiesOnly=yes",
                   "-p", str(port), f"{user}@127.0.0.1", command])
    elif have("sshpass"):
        argv = (["sshpass", "-p", pw, "ssh"] + common
                + ["-o", "PubkeyAuthentication=no",
                   "-p", str(port), f"{user}@127.0.0.1", command])
    else:
        return 1, ("没有该 guest 的 SSH 密钥，也没装 sshpass。"
                   "重建这台虚拟机即可获得密钥，或先 apt-get install sshpass")
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, ((p.stdout or "") + (p.stderr or "")).strip()
    except subprocess.TimeoutExpired:
        return 1, "超时"


def guest_root(name: str, command: str, timeout: int = 600) -> tuple[int, str]:
    """Same, but escalated with sudo when the login user is not root."""
    cfg = load_vm(name)
    if cfg.get("VM_USER", "ubuntu") == "root":
        return guest_ssh(name, command, timeout)
    priv, _ = key_paths(name)
    quoted = command.replace("'", "'\\''")
    if os.path.isfile(priv):
        # the key has no password, so a passwordless sudo is fine here
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

    args = [
        "qemu-system-aarch64", "-name", name,
        "-M", "virt,gic-version=3", "-cpu", "max", "-accel", "kvm",
        "-smp", cpus, "-m", mem,
        "-drive", f"if=pflash,format=raw,unit=0,file={d}/uefi-code.fd,readonly=on",
        "-drive", f"if=pflash,format=raw,unit=1,file={d}/uefi-vars.fd",
        "-drive", f"if=virtio,format=qcow2,cache={cache},file={d}/disk.qcow2",
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
    args += ["-device", "virtio-rng-pci",
             "-display", "none",
             "-serial", "file:" + os.path.join(d, "serial.log")]

    out(f"  {S.b}{name}{S.rst}  {S.dim}{cpus} vCPU · {mem} MiB · {mask_label(cpuset)}"
        f" · 缓存 {cache}{S.rst}")
    if net == "user":
        for f in forwards:
            h, g = parse_forward(f)
            h = int(port) if g == 22 else h
            out(f"  {S.dim}宿主机 {h} {S.arrow} guest {g}{S.rst}")
    out()

    env = dict(os.environ)
    taskset = have("taskset")
    if taskset and cpuset:
        args = ["taskset", "-c", cpuset] + args

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
            ok(f"SSH 已就绪  {S.b}ssh {cfg.get('VM_USER','ubuntu')}@127.0.0.1 -p {port}{S.rst}")
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
    priv, _ = key_paths(name)
    common = ["-o", "StrictHostKeyChecking=no",
              "-o", "UserKnownHostsFile=/dev/null",
              "-o", "LogLevel=ERROR",
              "-o", "ConnectTimeout=5",
              "-o", "BatchMode=yes"]
    if os.path.isfile(priv):
        argv = (["ssh"] + common
                + ["-i", priv, "-o", "IdentitiesOnly=yes",
                   "-p", str(port), f"{user}@127.0.0.1", "true"])
    elif have("sshpass"):
        argv = (["sshpass", "-p", cfg.get("VM_PASS", ""), "ssh"] + common
                + ["-o", "PubkeyAuthentication=no",
                   "-p", str(port), f"{user}@127.0.0.1", "true"])
    else:
        return False
    try:
        return subprocess.run(argv, capture_output=True, timeout=timeout).returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False


def wait_ssh(name: str, port: int, timeout: int = 420) -> bool:
    """
    Wait until SSH accepts a command.

    Testing the socket is not enough: the port is forwarded while sshd is still
    starting, so the first real connection can be reset.
    """
    import time as _t
    end = _t.time() + timeout
    while _t.time() < end:
        if ssh_probe(name, port):
            return True
        _t.sleep(4)
    return False


def tail_serial(name: str, n: int = 8) -> None:
    p = os.path.join(vm_dir(name), "serial.log")
    if not os.path.isfile(p):
        return
    lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    for l in lines[-n:]:
        out(f"  {S.dim}{l[:100]}{S.rst}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
