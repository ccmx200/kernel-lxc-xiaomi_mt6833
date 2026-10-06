#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Terminal feedback for ckvm: spinners, progress bars, transitions.

Kept in its own module because ckvm.py was already 2600 lines and mixing
animation code into the command logic makes both harder to follow.

Rules this module follows:

  * nothing animates unless stdout is a real terminal - a pipe gets plain lines,
    because escape codes in a log are worse than no animation
  * every glyph has an ASCII fallback chosen from the output encoding, so a GBK
    console does not raise UnicodeEncodeError mid-download
  * a context manager always clears its line, including when the body raises,
    so a failure never leaves half a progress bar on screen
  * elapsed time is shown for anything slow, since a still spinner with no
    numbers cannot be told from a hang
"""

from __future__ import annotations

import os
import shutil
import sys
import threading
import time

# --------------------------------------------------------------------------
# capability detection
# --------------------------------------------------------------------------
def is_tty() -> bool:
    try:
        return sys.stdout.isatty() and os.environ.get("TERM", "dumb") != "dumb"
    except Exception:
        return False


def _unicode_ok() -> bool:
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    return "utf" in enc


TTY = is_tty()
UNI = _unicode_ok()

_UTF_FRAMES = ("\u280b", "\u2819", "\u2839", "\u2838", "\u283c",
               "\u2834", "\u2826", "\u2827", "\u2807", "\u280f")
SPIN_FRAMES = _UTF_FRAMES if UNI else ("|", "/", "-", "\\")

# never emit a glyph the output encoding cannot represent
MARK_OK = "\u2713" if UNI else "OK"
MARK_DOT = "\u00b7" if UNI else "-"

_CODES = {
    "reset": "0", "bold": "1", "dim": "2", "italic": "3", "under": "4",
    "red": "31", "green": "32", "yellow": "33",
    "blue": "34", "magenta": "35", "cyan": "36", "grey": "90",
}


class Colours:
    """Colour codes, empty when colour would be wrong or unwanted."""

    def __init__(self) -> None:
        self.on = TTY and not os.environ.get("NO_COLOR")

    def __getattr__(self, name: str) -> str:
        code = _CODES.get(name)
        if code is None:
            raise AttributeError(name)
        return f"\033[{code}m" if self.on else ""


C = Colours()
R, D, B = C.reset, C.dim, C.bold


def term_width(default: int = 40) -> int:
    try:
        return max(20, min(shutil.get_terminal_size((80, 24)).columns - 6, 60))
    except Exception:
        return default


def human_time(secs: float) -> str:
    if secs < 60:
        return f"{secs:.0f}s"
    m, s = divmod(int(secs), 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m"


def human_bytes(n: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}B" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}T"


def clear_line() -> None:
    if TTY:
        sys.stdout.write("\r\033[K")
        sys.stdout.flush()


# --------------------------------------------------------------------------
# spinner
# --------------------------------------------------------------------------
class Spinner:
    """
    Animate a label while work runs on the calling thread.

        with Spinner("下载中") as sp:
            do_work()
            sp.note("310M/592M")
    """

    def __init__(self, label: str, enabled: bool = True) -> None:
        self.label = label
        self.enabled = enabled and TTY
        self.note_text = ""
        self._stop = threading.Event()
        self._thread = None
        self.t0 = time.time()
        self._lock = threading.Lock()

    def note(self, text: str) -> None:
        """Replace the trailing detail, e.g. a byte counter."""
        with self._lock:
            self.note_text = text

    def __enter__(self):
        if not self.enabled:
            sys.stdout.write(f"  {self.label}...\n")
            sys.stdout.flush()
            return self
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def _run(self) -> None:
        i = 0
        while not self._stop.is_set():
            frame = SPIN_FRAMES[i % len(SPIN_FRAMES)]
            with self._lock:
                note = self.note_text
            el = time.time() - self.t0
            tail = f"  {D}{note}{R}" if note else ""
            sys.stdout.write(
                f"\r\033[K  {C.cyan}{frame}{R} {self.label}"
                f"  {D}{human_time(el)}{R}{tail}")
            sys.stdout.flush()
            i += 1
            time.sleep(0.09)

    def __exit__(self, *exc) -> bool:
        if not self.enabled:
            return False
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=0.5)
        clear_line()
        return False


# --------------------------------------------------------------------------
# progress bar
# --------------------------------------------------------------------------
class Progress:
    """
    Known-length progress.

        with Progress("下载", total) as pr:
            pr.update(done)
    """

    FILL = "\u2588" if UNI else "#"
    EMPTY = "\u2591" if UNI else "-"

    def __init__(self, label: str, total: int, enabled: bool = True,
                 width=None) -> None:
        self.label = label
        self.total = max(1, int(total))
        self.enabled = enabled and TTY
        self.width = width or term_width()
        self.start = time.time()
        self.last = 0.0
        self.done = 0

    def __enter__(self):
        self.update(0)
        return self

    def update(self, done: int) -> None:
        self.done = done
        if not self.enabled:
            return
        now = time.time()
        # redraw at most ~12x a second; faster only burns cpu
        if now - self.last < 0.08 and done < self.total:
            return
        self.last = now
        frac = min(1.0, done / self.total)
        el = now - self.start
        speed = done / el if el > 0 else 0
        eta = (self.total - done) / speed if speed > 0 else 0
        f = int(frac * self.width)
        bar = self.FILL * f + self.EMPTY * (self.width - f)
        pct = f"{frac * 100:3.0f}%"
        tail = (f"{human_bytes(done)}/{human_bytes(self.total)}"
                f"  {D}{human_bytes(speed)}/s")
        if eta > 1:
            tail += f"  eta {human_time(eta)}"
        tail += R
        sys.stdout.write(f"\r\033[K  {C.cyan}{bar}{R} {pct} "
                         f"{self.label}  {tail}")
        sys.stdout.flush()

    def __exit__(self, *exc) -> bool:
        if self.enabled:
            clear_line()
        return False


# --------------------------------------------------------------------------
# one-shot effects
# --------------------------------------------------------------------------
def sweep(text: str, widths: int = 6, delay: float = 0.035) -> None:
    """
    A bright band travelling across the text, leaving it in green.

    For a result worth noticing.  Skipped entirely when not on a terminal.
    """
    if not TTY:
        sys.stdout.write(f"  {text}\n")
        return
    n = len(text)
    for pos in range(-widths, n + 1):
        buf = []
        for i, ch in enumerate(text):
            if pos <= i < pos + widths:
                buf.append(f"{C.bold}{C.cyan}{ch}{R}")
            elif i < pos:
                buf.append(ch)
            else:
                buf.append(f"{D}{ch}{R}")
        sys.stdout.write(f"\r\033[K  {''.join(buf)}")
        sys.stdout.flush()
        time.sleep(delay)
    sys.stdout.write(f"\r\033[K  {C.green}{text}{R}\n")
    sys.stdout.flush()


def bar_reveal(label: str, delay: float = 0.02) -> None:
    """Grow a short bar to full, for a step that just completed."""
    if not TTY:
        return
    W = 12
    for i in range(W + 1):
        bar = Progress.FILL * i + Progress.EMPTY * (W - i)
        mark = (f"{C.green}{MARK_OK}{R}" if i == W
                else f"{C.cyan}{MARK_DOT}{R}")
        sys.stdout.write(f"\r\033[K  {mark} {C.green}{bar}{R} {label}")
        sys.stdout.flush()
        time.sleep(delay)
    clear_line()


def steps(items, delay: float = 0.12) -> None:
    """
    Print a checklist, ticking each item in turn.

    Honest only if the work really happened.  Call it with the steps you
    actually performed, not as a decorative loading sequence.
    """
    for it in items:
        if TTY:
            sys.stdout.write(f"  {C.dim}...{R} {it}\r")
            sys.stdout.flush()
            time.sleep(delay)
            sys.stdout.write(f"\r\033[K  {C.green}{MARK_OK}{R} {it}\n")
        else:
            sys.stdout.write(f"  {MARK_OK} {it}\n")
        sys.stdout.flush()


def hint(text: str) -> str:
    """Consistent dim hint string, so menus read the same everywhere."""
    return f"{D}{text}{R}" if TTY else text
