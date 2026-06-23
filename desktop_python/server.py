#!/usr/bin/env python3
"""
DrawTab Desktop Server
Receives touch/pen input from mobile app via WebSocket and injects
as system-level mouse/pen events using platform-specific APIs.

Supports: Windows (ctypes WinAPI), macOS (Quartz), Linux (uinput/xdotool)

Usage:
    python server.py [--host 0.0.0.0] [--port 8765] [--width 1920] [--height 1080]
    python server.py --mirror          # Enable screen mirroring to mobile
"""

import asyncio
import json
import sys
import argparse
import logging
import platform
import time
import os
import subprocess
import threading
from dataclasses import dataclass
from typing import Optional, Any
import math
import base64
import io

try:
    from PIL import ImageGrab
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False

try:
    import mss
    import mss.tools
    HAS_MSS = True
except ImportError:
    HAS_MSS = False

# ─── Optional screen mirror imports ──────────────────────────────────────────
try:
    import websockets
    HAS_WEBSOCKETS = True
except ImportError:
    HAS_WEBSOCKETS = False
    print("Install websockets: pip install websockets")
    sys.exit(1)

try:
    from pynput import keyboard as pynput_keyboard
    HAS_PYNPUT = True
except ImportError:
    HAS_PYNPUT = False
    pynput_keyboard = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("DrawTab")
BUILD_TAG = "mapping-fix-2026-04-25-3"

# ─── INPUT EVENT DATACLASS ────────────────────────────────────────────────────

@dataclass
class DrawEvent:
    type: str        # 'down' | 'move' | 'up' | 'hover'
    x: float         # normalized 0.0–1.0
    y: float         # normalized 0.0–1.0
    normalized: bool # True when x/y are normalized, False when absolute pixels
    sourceWidth: float  # source input surface width in pixels
    sourceHeight: float # source input surface height in pixels
    pressure: float  # 0.0–1.0
    tiltX: float     # -90 to 90 degrees
    tiltY: float     # -90 to 90 degrees
    isPen: bool
    buttons: int     # 1=primary, 32=eraser
    ts: int          # microsecond timestamp

    def to_screen(self, width: int, height: int, region: Optional[dict] = None) -> tuple[int, int]:
        """Convert event coords to screen pixels."""
        target_left = 0
        target_top = 0
        target_width = width
        target_height = height

        if region:
            target_left = int(region.get('left', 0))
            target_top = int(region.get('top', 0))
            target_width = max(1, int(region.get('width', width)))
            target_height = max(1, int(region.get('height', height)))

        if self.normalized:
            sx = int(target_left + (self.x * target_width))
            sy = int(target_top + (self.y * target_height))
        else:
            if self.sourceWidth > 0 and self.sourceHeight > 0:
                sx = int(target_left + ((self.x / self.sourceWidth) * target_width))
                sy = int(target_top + ((self.y / self.sourceHeight) * target_height))
            else:
                sx = int(target_left + self.x)
                sy = int(target_top + self.y)

        max_x = target_left + max(1, target_width) - 1
        max_y = target_top + max(1, target_height) - 1
        return (
            max(target_left, min(max_x, sx)),
            max(target_top, min(max_y, sy))
        )


@dataclass
class ScreenRegion:
    left: int
    top: int
    width: int
    height: int

    def to_dict(self) -> dict:
        return {
            'left': int(self.left),
            'top': int(self.top),
            'width': int(self.width),
            'height': int(self.height),
        }


# Region selector presets.
# Change these values if you want different default sizes.
PORTRAIT_PRESET_SIZE = (360, 640)
LANDSCAPE_PRESET_SIZE = (640, 360)
PORTRAIT_MIN_SIZE = (320, 480)
LANDSCAPE_MIN_SIZE = (480, 320)

# Interpolation: maximum pixels per injected step. Lower = smoother curves.
INTERPOLATION_MAX_PIXEL_STEP = 2
# Minimum time (ms) between events to trigger interpolation; if events are frequent
# we skip adding intermediates to avoid overload/lag.
INTERPOLATION_MIN_TIME_MS = 2


def run_region_selector_app() -> Optional[dict]:
    try:
        import tkinter as tk
    except ImportError:
        log.error("tkinter is required for region selection")
        return None

    selected: dict[str, int] = {}
    done = False

    root = tk.Tk()
    root.title('DrawTab Region Selector')
    root.attributes('-topmost', True)
    try:
        root.attributes('-alpha', 1.0)
    except Exception:
        pass
    root.deiconify()
    root.update_idletasks()
    root.lift()
    root.focus_force()

    screen_w = root.winfo_screenwidth()
    screen_h = root.winfo_screenheight()
    max_width = screen_w
    max_height = screen_h

    def orientation_profile(mode: str) -> tuple[tuple[int, int], tuple[int, int]]:
        if mode == 'landscape':
            return LANDSCAPE_PRESET_SIZE, LANDSCAPE_MIN_SIZE
        return PORTRAIT_PRESET_SIZE, PORTRAIT_MIN_SIZE

    base_size, min_size = orientation_profile('portrait')
    scale = min(screen_w / base_size[0], screen_h / base_size[1], 1.0)
    width = max(min_size[0], int(base_size[0] * scale))
    height = max(min_size[1], int(base_size[1] * scale))
    width = min(width, max_width)
    height = min(height, max_height)

    x = max(0, (screen_w - width) // 2)
    y = max(0, (screen_h - height) // 2)
    root.geometry(f'{width}x{height}+{x}+{y}')
    root.minsize(min_size[0], min_size[1])
    root.maxsize(max_width, max_height)
    root.resizable(True, True)
    orientation = 'portrait' if height >= width else 'landscape'
    orientation_var = tk.StringVar(value=orientation)

    frame = tk.Frame(root, bg='#111827', highlightbackground='#6C63FF', highlightthickness=3)
    frame.pack(fill='both', expand=True)

    header = tk.Frame(frame, bg='#6C63FF', height=40)
    header.pack(fill='x', side='top')
    header.pack_propagate(False)

    title = tk.Label(
        header,
        text='DrawTab Region Selector',
        fg='white',
        bg='#6C63FF',
        font=('Segoe UI', 11, 'bold')
    )
    title.pack(side='left', padx=12)

    hint = tk.Label(
        frame,
        text='Move and resize this window with the mouse. Use Portrait/Landscape to switch size. Press Enter to confirm or Esc to cancel.',
        fg='white',
        bg='#111827',
        justify='left',
        anchor='w',
        wraplength=max(220, width - 24),
        font=('Segoe UI', 11)
    )
    hint.pack(fill='x', padx=12, pady=(10, 6))

    control_bar = tk.Frame(frame, bg='#111827')
    control_bar.pack(fill='x', padx=12, pady=(0, 8))

    orientation_label = tk.Label(
        control_bar,
        text='Orientation:',
        fg='white',
        bg='#111827',
        font=('Segoe UI', 10, 'bold')
    )
    orientation_label.pack(side='left', padx=(0, 8))

    body = tk.Frame(frame, bg='#111827')
    body.pack(fill='both', expand=True, padx=12, pady=(116, 12))

    info = tk.Label(
        body,
        text='Region will map only within this window area.\nDefault size is mobile-like and can be resized up to the monitor bounds.',
        fg='white',
        bg='#111827',
        justify='left',
        anchor='nw',
        wraplength=max(220, width - 48),
        font=('Segoe UI', 12)
    )
    info.pack(anchor='nw', fill='x')

    def apply_orientation(next_orientation: str):
        nonlocal orientation
        orientation = next_orientation
        orientation_var.set(next_orientation)
        base_size, next_min_size = orientation_profile(next_orientation)
        scale = min(screen_w / base_size[0], screen_h / base_size[1], 1.0)
        next_width = max(next_min_size[0], int(base_size[0] * scale))
        next_height = max(next_min_size[1], int(base_size[1] * scale))
        next_width = min(next_width, max_width)
        next_height = min(next_height, max_height)
        next_x = max(0, (screen_w - next_width) // 2)
        next_y = max(0, (screen_h - next_height) // 2)
        root.geometry(f'{next_width}x{next_height}+{next_x}+{next_y}')
        root.minsize(next_min_size[0], next_min_size[1])
        root.maxsize(max_width, max_height)
        hint.configure(wraplength=max(220, next_width - 24))
        info.configure(wraplength=max(220, next_width - 48))
        sync_orientation_buttons()

    portrait_btn = tk.Button(
        control_bar,
        text='Portrait',
        command=lambda: apply_orientation('portrait'),
        relief='flat',
        bg='#374151',
        fg='white',
        activebackground='#6C63FF',
        activeforeground='white',
        padx=10,
        pady=4,
    )
    portrait_btn.pack(side='left', padx=(0, 8))

    landscape_btn = tk.Button(
        control_bar,
        text='Landscape',
        command=lambda: apply_orientation('landscape'),
        relief='flat',
        bg='#374151',
        fg='white',
        activebackground='#6C63FF',
        activeforeground='white',
        padx=10,
        pady=4,
    )
    landscape_btn.pack(side='left')

    def sync_orientation_buttons():
        active_bg = '#6C63FF'
        inactive_bg = '#374151'
        portrait_btn.configure(bg=active_bg if orientation_var.get() == 'portrait' else inactive_bg)
        landscape_btn.configure(bg=active_bg if orientation_var.get() == 'landscape' else inactive_bg)

    def on_resize(_event=None):
        current_width = root.winfo_width()
        hint.configure(wraplength=max(220, current_width - 24))
        info.configure(wraplength=max(220, current_width - 48))

    root.bind('<Configure>', on_resize)
    sync_orientation_buttons()

    def finish(region: Optional[dict] = None):
        nonlocal done
        if done:
            return
        done = True
        if region:
            selected.update(region)
        try:
            root.destroy()
        except Exception:
            pass

    def capture_region():
        root.update_idletasks()
        left = int(root.winfo_rootx())
        top = int(root.winfo_rooty())
        width = int(root.winfo_width())
        height = int(root.winfo_height())
        _, min_size = orientation_profile(orientation)
        width = max(min_size[0], min(max_width, width))
        height = max(min_size[1], min(max_height, height))
        left = max(0, min(screen_w - width, left))
        top = max(0, min(screen_h - height, top))
        return {
            'left': left,
            'top': top,
            'width': width,
            'height': height,
        }

    def on_confirm(_event=None):
        finish(capture_region())

    def on_cancel(_event=None):
        finish(None)

    root.bind('<Return>', on_confirm)
    root.bind('<KP_Enter>', on_confirm)
    root.bind('<Escape>', on_cancel)
    root.protocol('WM_DELETE_WINDOW', on_cancel)

    root.mainloop()
    return selected or None

# ─── PLATFORM INPUT INJECTORS ─────────────────────────────────────────────────

class InputInjector:
    """Base class for platform-specific input injection."""
    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height
        self._pen_down = False

    def inject(self, evt: DrawEvent, region: Optional[dict] = None):
        raise NotImplementedError

    def close(self):
        pass


class WindowsInputInjector(InputInjector):
    """Uses Win32 SendInput API for Wintab-compatible pen events."""
    def __init__(self, width, height):
        super().__init__(width, height)
        import ctypes
        import ctypes.wintypes as wt
        self.ctypes = ctypes
        self.wt = wt
        self.user32 = ctypes.windll.user32
        self._setup_structs()
        self._setup_screen_size()

    def _setup_screen_size(self):
        # Prefer actual current primary screen metrics for pixel mapping.
        self.SM_CXSCREEN = 0
        self.SM_CYSCREEN = 1
        w = self.user32.GetSystemMetrics(self.SM_CXSCREEN)
        h = self.user32.GetSystemMetrics(self.SM_CYSCREEN)
        if w > 0:
            self.width = w
        if h > 0:
            self.height = h

    def _setup_structs(self):
        c = self.ctypes
        wt = self.wt

        class MOUSEINPUT(c.Structure):
            _fields_ = [
                ("dx", wt.LONG), ("dy", wt.LONG),
                ("mouseData", wt.DWORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", c.POINTER(wt.ULONG))
            ]

        class INPUT(c.Structure):
            class _INPUT(c.Union):
                _fields_ = [("mi", MOUSEINPUT)]
            _anonymous_ = ("_input",)
            _fields_ = [("type", wt.DWORD), ("_input", _INPUT)]

        self.MOUSEINPUT = MOUSEINPUT
        self.INPUT = INPUT

        # Flags
        self.MOUSEEVENTF_MOVE = 0x0001
        self.MOUSEEVENTF_LEFTDOWN = 0x0002
        self.MOUSEEVENTF_LEFTUP = 0x0004
        self.MOUSEEVENTF_RIGHTDOWN = 0x0008
        self.MOUSEEVENTF_RIGHTUP = 0x0010
        self.MOUSEEVENTF_ABSOLUTE = 0x8000
        self.INPUT_MOUSE = 0

    def inject(self, evt: DrawEvent, region: Optional[dict] = None):
        px, py = evt.to_screen(self.width, self.height, region)
        
        # Use MOUSEEVENTF_ABSOLUTE for precise mapping to the virtual desktop, avoiding DPI/acceleration issues
        nx = int((px / max(1, self.width)) * 65535)
        ny = int((py / max(1, self.height)) * 65535)
        
        flags = self.MOUSEEVENTF_ABSOLUTE | self.MOUSEEVENTF_MOVE
        
        if evt.type == 'down':
            self._pen_down = True
            flags |= self.MOUSEEVENTF_LEFTDOWN
        elif evt.type == 'up':
            self._pen_down = False
            flags |= self.MOUSEEVENTF_LEFTUP

        self.user32.mouse_event(flags, nx, ny, 0, 0)


class MacOSInputInjector(InputInjector):
    """Uses Quartz CoreGraphics for macOS pen/mouse events."""
    def __init__(self, width, height):
        super().__init__(width, height)
        try:
            # pyrefly: ignore [missing-import]
            import Quartz
            self.Quartz = Quartz
        except ImportError:
            raise ImportError("Install pyobjc-framework-Quartz: pip install pyobjc-framework-Quartz")

    def _cg_event(self, event_type, x: int, y: int, pressure: float = 1.0):
        Q = self.Quartz
        event = Q.CGEventCreateMouseEvent(None, event_type, (x, y), Q.kCGMouseButtonLeft)
        if pressure > 0:
            Q.CGEventSetDoubleValueField(event, Q.kCGMouseEventPressure, pressure)
        Q.CGEventPost(Q.kCGHIDEventTap, event)

    def inject(self, evt: DrawEvent, region: Optional[dict] = None):
        Q = self.Quartz
        sx, sy = evt.to_screen(self.width, self.height, region)

        if evt.type == 'down':
            self._pen_down = True
            self._cg_event(Q.kCGEventLeftMouseDown, sx, sy, evt.pressure)
        elif evt.type == 'move':
            if self._pen_down:
                self._cg_event(Q.kCGEventLeftMouseDragged, sx, sy, evt.pressure)
            else:
                self._cg_event(Q.kCGEventMouseMoved, sx, sy, 0)
        elif evt.type == 'up':
            self._pen_down = False
            self._cg_event(Q.kCGEventLeftMouseUp, sx, sy, 0)


class LinuxInputInjector(InputInjector):
    """
    Uses python-uinput to create a virtual tablet device on Linux.
    Provides proper pressure and tilt support for apps like Krita/GIMP.
    Falls back to xdotool if uinput unavailable.
    """
    def __init__(self, width, height):
        super().__init__(width, height)
        self._setup_uinput()

    def _setup_uinput(self):
        try:
            # pyrefly: ignore [missing-import]
            import uinput
            self.uinput = uinput
            # Define virtual tablet device capabilities
            events = (
                uinput.ABS_X + (0, 65535, 0, 0),        # X axis
                uinput.ABS_Y + (0, 65535, 0, 0),        # Y axis
                uinput.ABS_PRESSURE + (0, 8191, 0, 0),  # Pressure (Wacom-compatible)
                uinput.ABS_TILT_X + (-64, 63, 0, 0),    # Tilt X
                uinput.ABS_TILT_Y + (-64, 63, 0, 0),    # Tilt Y
                uinput.BTN_TOUCH,
                uinput.BTN_TOOL_PEN,
                uinput.BTN_STYLUS,
                uinput.BTN_STYLUS2,
            )
            self.device = uinput.Device(events, name="DrawTab Virtual Tablet",
                                         bustype=0x03)
            self.use_uinput = True
            log.info("uinput tablet device created successfully")
        except Exception as e:
            log.warning(f"uinput not available ({e}), falling back to xdotool")
            self.use_uinput = False
            import subprocess
            self._subprocess = subprocess

    def inject(self, evt: DrawEvent, region: Optional[dict] = None):
        sx, sy = evt.to_screen(self.width, self.height, region)
        if self.use_uinput:
            self._inject_uinput(evt, sx, sy)
        else:
            self._inject_xdotool(evt, sx, sy)

    def _inject_uinput(self, evt: DrawEvent, sx: int, sy: int):
        u = self.uinput
        d = self.device
        pressure = int(evt.pressure * 8191)
        tilt_x = int(evt.tiltX)
        tilt_y = int(evt.tiltY)

        # Normalize to 0–65535
        nx = int(sx / self.width * 65535)
        ny = int(sy / self.height * 65535)

        d.emit(u.ABS_X, nx, syn=False)
        d.emit(u.ABS_Y, ny, syn=False)
        d.emit(u.ABS_PRESSURE, pressure, syn=False)
        d.emit(u.ABS_TILT_X, tilt_x, syn=False)
        d.emit(u.ABS_TILT_Y, tilt_y, syn=False)

        if evt.type == 'down':
            d.emit(u.BTN_TOOL_PEN, 1, syn=False)
            d.emit(u.BTN_TOUCH, 1, syn=True)
        elif evt.type == 'up':
            d.emit(u.BTN_TOUCH, 0, syn=False)
            d.emit(u.BTN_TOOL_PEN, 0, syn=True)
        else:
            d.syn()

    def _inject_xdotool(self, evt: DrawEvent, sx: int, sy: int):
        cmd = ['xdotool']
        if evt.type == 'down':
            cmd += ['mousemove', str(sx), str(sy), 'mousedown', '1']
        elif evt.type == 'move':
            cmd += ['mousemove', str(sx), str(sy)]
        elif evt.type == 'up':
            cmd += ['mousemove', str(sx), str(sy), 'mouseup', '1']
        else:
            return
        self._subprocess.Popen(cmd, stdout=self._subprocess.DEVNULL,
                               stderr=self._subprocess.DEVNULL)

    def close(self):
        if self.use_uinput and hasattr(self, 'device'):
            self.device.destroy()


def create_injector(width: int, height: int) -> InputInjector:
    """Factory: create the right injector for the current platform."""
    os = platform.system()
    log.info(f"Platform: {os} — Screen: {width}×{height}")
    if os == 'Windows':
        return WindowsInputInjector(width, height)
    elif os == 'Darwin':
        return MacOSInputInjector(width, height)
    elif os == 'Linux':
        return LinuxInputInjector(width, height)
    else:
        raise RuntimeError(f"Unsupported platform: {os}")


# ─── WEBSOCKET SERVER ─────────────────────────────────────────────────────────

class DrawTabServer:
    def __init__(self, host: str, port: int, width: int, height: int,
                 enable_mirror: bool = False):
        self.host = host
        self.port = port
        self.width = width
        self.height = height
        self.enable_mirror = enable_mirror
        self.injector: Optional[InputInjector] = None
        self.clients: set = set()
        self.region_mode_enabled = False
        self.selected_region: Optional[dict] = None
        self._region_selection_lock = asyncio.Lock()
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._hotkey_listener = None
        self.keyboard_controller = pynput_keyboard.Controller() if HAS_PYNPUT else None

        # Latency stats
        self._evt_count = 0
        self._last_report = time.time()
        self._max_lag_ms = 0.0
        self._debug_logged_events = 0
        # Track last injected screen point for interpolation smoothing
        self._last_injected: Optional[dict] = None
        self._stroke_points = []

    def quadratic_bezier(self, p0, p1, p2, t):
        x = ((1 - t) ** 2) * p0[0] + \
            2 * (1 - t) * t * p1[0] + \
            (t ** 2) * p2[0]

        y = ((1 - t) ** 2) * p0[1] + \
            2 * (1 - t) * t * p1[1] + \
            (t ** 2) * p2[1]

        return int(x), int(y)

    def _process_batch(self, batch: list):
        now_us = time.monotonic_ns() // 1000
        active_region = self.selected_region if self.region_mode_enabled else None
        for raw in batch:
            evt = DrawEvent(
                type=raw['type'],
                x=raw['x'],
                y=raw['y'],
                normalized=raw.get('normalized', raw.get('relative', True)),
                sourceWidth=raw.get('sourceWidth', 0.0),
                sourceHeight=raw.get('sourceHeight', 0.0),
                pressure=raw.get('pressure', 1.0),
                tiltX=raw.get('tiltX', 0.0),
                tiltY=raw.get('tiltY', 0.0),
                isPen=raw.get('isPen', False),
                buttons=raw.get('buttons', 1),
                ts=raw.get('ts', 0),
            )

            if self._debug_logged_events < 8:
                sx, sy = evt.to_screen(self.width, self.height, active_region)
                log.info(
                    "DBG evt=%s raw=(%.4f, %.4f) normalized=%s src=(%.2f, %.2f) mapped=(%d, %d)",
                    evt.type,
                    evt.x,
                    evt.y,
                    evt.normalized,
                    evt.sourceWidth,
                    evt.sourceHeight,
                    sx,
                    sy,
                )
                self._debug_logged_events += 1

            # Calculate lag
            if evt.ts > 0:
                lag_ms = (now_us - evt.ts) / 1000.0
                self._max_lag_ms = max(self._max_lag_ms, lag_ms)

            # Inject with smoothing interpolation to produce curved strokes
            try:
                self._inject_with_interpolation(evt, active_region)
            except Exception as exc:
                log.exception(f"Injection error: {exc}")
            self._evt_count += 1

        # Stats every 5 seconds
        now = time.time()
        if now - self._last_report >= 5.0:
            eps = self._evt_count / (now - self._last_report)
            log.info(f"Throughput: {eps:.0f} events/s | Max lag: {self._max_lag_ms:.1f}ms")
            self._evt_count = 0
            self._max_lag_ms = 0.0
            self._last_report = now

    # def _inject_with_interpolation(self, evt: DrawEvent, region: Optional[dict]):
    #     """Inject an event, inserting interpolated move events between the
    #     previously injected point and this event to smooth strokes.
    #     """
    #     # Guard: injector must be ready
    #     if not self.injector:
    #         log.warning("Injector not ready, dropping event")
    #         return

    #     # Compute target screen coordinates for this event
    #     sx, sy = evt.to_screen(self.width, self.height, region)

    #     prev = self._last_injected
    #     if evt.type == 'down':
    #         self._stroke_points = [(sx, sy)]

    #     # elif evt.type == 'move':
    #     #     self._stroke_points.append((sx, sy))
    #     elif evt.type == 'move':
    #         self._stroke_points.append((sx, sy))

    #         if len(self._stroke_points) > 10:
    #             self._stroke_points.pop(0)

    #     # Decide whether to interpolate: only when previous point exists and pen was down
    #     #if isinstance(prev, dict) and prev.get('pen_down', False) and evt.type in ('move', 'up'):
    #     if len(self._stroke_points) >= 3:
    #         p0 = self._stroke_points[-3]
    #         p1 = self._stroke_points[-2]
    #         p2 = self._stroke_points[-1]

    #         for i in range(1, 17):

    #             t = i / 16

    #             bx, by = self.quadratic_bezier(
    #                 p0,
    #                 p1,
    #                 p2,
    #                 t
    #             )
    #             region_left = region.get('left', 0) if region else 0
    #             region_top = region.get('top', 0) if region else 0

    #             synthetic = DrawEvent(
    #                 type='move',
    #                 x=bx - region_left,
    #                 y=by - region_top,
    #                 normalized=False,
    #                 sourceWidth=0,
    #                 sourceHeight=0,
    #                 pressure=evt.pressure,
    #                 tiltX=evt.tiltX,
    #                 tiltY=evt.tiltY,
    #                 isPen=evt.isPen,
    #                 buttons=evt.buttons,
    #                 ts=evt.ts
    #             )

    #             self.injector.inject(
    #                 synthetic,
    #                 region
    #             )

    #     # Finally inject the real event
    #     self.injector.inject(evt, region)

    #     # Update last injected point state
    #     pen_down = True if evt.type in ('down', 'move') else False
    #     if evt.type == 'up':
    #         pen_down = False
    #         self._stroke_points.clear()
    #     self._last_injected = {
    #         'x': sx,
    #         'y': sy,
    #         'pressure': float(evt.pressure),
    #         'pen_down': pen_down,
    #         'ts': evt.ts,
    #     }

    def _inject_with_interpolation(self, evt: DrawEvent, region: Optional[dict]):
        """
        Inject event with smooth interpolation.
        Uses the original interpolation system but generates
        more points for smoother strokes.
        """

        if not self.injector:
            log.warning("Injector not ready, dropping event")
            return

        sx, sy = evt.to_screen(self.width, self.height, region)

        prev = self._last_injected

        if (
            isinstance(prev, dict)
            and prev.get('pen_down', False)
            and evt.type in ('move', 'up')
        ):

            px = prev['x']
            py = prev['y']

            dx = sx - px
            dy = sy - py

            distance = math.sqrt(dx * dx + dy * dy)

            # Skip interpolation for tiny movements
            if distance > 2:

                # More interpolation points = smoother lines
                steps = max(
                    1,
                    int(distance / 1.5)
                )

                region_left = region.get('left', 0) if region else 0
                region_top = region.get('top', 0) if region else 0

                for step in range(1, steps):

                    t = step / steps

                    ix = px + dx * t
                    iy = py + dy * t

                    synthetic = DrawEvent(
                        type='move',
                        x=ix - region_left,
                        y=iy - region_top,
                        normalized=False,
                        sourceWidth=0,
                        sourceHeight=0,
                        pressure=float(prev.get('pressure', evt.pressure))
                        + (evt.pressure - float(prev.get('pressure', evt.pressure))) * t,
                        tiltX=evt.tiltX,
                        tiltY=evt.tiltY,
                        isPen=evt.isPen,
                        buttons=evt.buttons,
                        ts=evt.ts
                    )

                    self.injector.inject(
                        synthetic,
                        region
                    )

        # Inject actual event
        self.injector.inject(evt, region)

        pen_down = evt.type in ('down', 'move')

        self._last_injected = {
            'x': sx,
            'y': sy,
            'pressure': float(evt.pressure),
            'pen_down': pen_down,
            'ts': evt.ts,
        }

        if evt.type == 'up':
            self._last_injected['pen_down'] = False

    async def handle_client(self, ws: Any):
        addr = ws.remote_address
        log.info(f"Client connected: {addr}")
        self.clients.add(ws)
        await self._send_region_state(ws)

        try:
            async for message in ws:
                try:
                    data = json.loads(message)
                    if 'batch' in data:
                        self._process_batch(data['batch'])
                    elif 'type' in data:
                        # Single event fallback
                        self._process_batch([data])
                    elif data.get('cmd') == 'ping':
                        await ws.send(json.dumps({'cmd': 'pong', 'ts': data.get('ts')}))
                    elif data.get('cmd') == 'get_state':
                        await self._send_region_state(ws)
                    elif data.get('cmd') == 'region_mode':
                        self.region_mode_enabled = bool(data.get('enabled', False))
                        await self._broadcast_region_state()
                    elif data.get('cmd') == 'select_region':
                        await self._select_region_from_overlay()
                        await self._broadcast_region_state()
                    elif data.get('cmd') == 'key':
                        self._handle_key_command(data.get('keys', []))
                    elif data.get('cmd') == 'get_region_preview':
                        await self._handle_get_region_preview(ws, data.get('region'))
                    elif data.get('cmd') == 'set_mirror_mode':
                        enabled = bool(data.get('enabled', False))
                        self.enable_mirror = enabled
                        if enabled and not hasattr(self, '_mirror_task'):
                            self._mirror_task = asyncio.create_task(self._mirror_loop())
                except json.JSONDecodeError:
                    log.warning("Invalid JSON received")
                except Exception as e:
                    log.error(f"Event processing error: {e}")
        except Exception:
            pass
        finally:
            self.clients.discard(ws)
            log.info(f"Client disconnected: {addr}")

    async def _handle_get_region_preview(self, ws: Any, region: dict):
        if not HAS_PILLOW:
            log.warning("Pillow not installed, cannot generate preview.")
            return
        if not region:
            return
        try:
            x, y = int(region.get('x', 0)), int(region.get('y', 0))
            w, h = int(region.get('width', 0)), int(region.get('height', 0))
            if w <= 0 or h <= 0:
                return

            def _grab():
                return ImageGrab.grab(bbox=(x, y, x + w, y + h))

            img = await self._loop.run_in_executor(None, _grab)
            
            max_dim = 800
            if img.width > max_dim or img.height > max_dim:
                img.thumbnail((max_dim, max_dim))
            
            buf = io.BytesIO()
            img.save(buf, format='JPEG', quality=70)
            b64 = base64.b64encode(buf.getvalue()).decode('utf-8')
            
            await ws.send(json.dumps({
                'cmd': 'region_preview',
                'image_b64': b64
            }))
        except Exception as e:
            log.error(f"Error generating preview: {e}")

    def _handle_key_command(self, keys: list):
        if not self.keyboard_controller:
            log.warning("Keyboard injection requested but pynput not available")
            return
            
        vk_map = {
            'ctrl': pynput_keyboard.Key.ctrl,
            'shift': pynput_keyboard.Key.shift,
            'alt': pynput_keyboard.Key.alt,
            'win': pynput_keyboard.Key.cmd,
            'cmd': pynput_keyboard.Key.cmd,
            'enter': pynput_keyboard.Key.enter,
            'backspace': pynput_keyboard.Key.backspace,
            'tab': pynput_keyboard.Key.tab,
            'space': pynput_keyboard.Key.space,
            'esc': pynput_keyboard.Key.esc,
            'escape': pynput_keyboard.Key.esc,
            'up': pynput_keyboard.Key.up,
            'down': pynput_keyboard.Key.down,
            'left': pynput_keyboard.Key.left,
            'right': pynput_keyboard.Key.right,
            'capslock': pynput_keyboard.Key.caps_lock,
        }
        for i in range(1, 13):
            vk_map[f'f{i}'] = getattr(pynput_keyboard.Key, f'f{i}')

        pressed = []
        try:
            for k in keys:
                k = str(k).lower()
                key_obj = vk_map.get(k, k)
                self.keyboard_controller.press(key_obj)
                pressed.append(key_obj)
            
            time.sleep(0.01)
        except Exception as e:
            log.error(f"Error pressing keys {keys}: {e}")
        finally:
            for key_obj in reversed(pressed):
                try:
                    self.keyboard_controller.release(key_obj)
                except Exception:
                    pass

    async def _send_region_state(self, ws: Any):
        await ws.send(json.dumps({
            'cmd': 'region_state',
            'regionModeEnabled': self.region_mode_enabled,
            'region': self.selected_region,
        }))

    async def _broadcast_region_state(self):
        if not self.clients:
            return

        payload = json.dumps({
            'cmd': 'region_state',
            'regionModeEnabled': self.region_mode_enabled,
            'region': self.selected_region,
        })
        dead_clients = set()
        for ws in list(self.clients):
            try:
                await ws.send(payload)
            except Exception:
                dead_clients.add(ws)

        for ws in dead_clients:
            self.clients.discard(ws)

    async def _select_region_from_overlay(self):
        async with self._region_selection_lock:
            region = await asyncio.to_thread(self._select_region_blocking)
            if region:
                self.selected_region = region
                log.info(
                    "Region selected: left=%d top=%d width=%d height=%d",
                    region['left'], region['top'], region['width'], region['height']
                )
            else:
                log.info("Region selection cancelled")

    def _select_region_blocking(self) -> Optional[dict]:
        cmd = [sys.executable, os.path.abspath(__file__), '--select-region']
        try:
            completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except Exception as exc:
            log.error(f"Failed to launch region selector: {exc}")
            return None

        output = (completed.stdout or '').strip()
        if not output:
            return None

        try:
            data = json.loads(output)
        except json.JSONDecodeError:
            log.error(f"Region selector returned invalid output: {output}")
            return None

        if not isinstance(data, dict):
            return None
        return data

    async def _mirror_loop(self):
        if not HAS_MSS:
            log.warning("mss not installed, low-latency mirroring unavailable.")
            return

        with mss.mss() as sct:
            while self.enable_mirror and self.clients:
                try:
                    primary_mon = sct.monitors[1]  # Primary monitor (physical pixels)
                    # Calculate display scaling factor (physical / logical)
                    scale_x = primary_mon['width'] / max(1, self.width)
                    scale_y = primary_mon['height'] / max(1, self.height)

                    region = self.selected_region if self.region_mode_enabled and self.selected_region else None
                    if region:
                        monitor = {
                            "top": int(region.get('top', 0) * scale_y) + primary_mon['top'],
                            "left": int(region.get('left', 0) * scale_x) + primary_mon['left'],
                            "width": int(region.get('width', self.width) * scale_x),
                            "height": int(region.get('height', self.height) * scale_y),
                        }
                    else:
                        monitor = primary_mon
                    
                    # Capture screen
                    sct_img = sct.grab(monitor)
                    
                    # Convert to JPEG using Pillow
                    if HAS_PILLOW:
                        from PIL import Image
                        img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
                        
                        # Downscale to reduce latency and bandwidth if it's large
                        MAX_DIM = 1280
                        if img.width > MAX_DIM or img.height > MAX_DIM:
                            img.thumbnail((MAX_DIM, MAX_DIM), Image.Resampling.BILINEAR)
                        
                        # Compress with lower quality for maximum speed
                        buf = io.BytesIO()
                        img.save(buf, format="JPEG", quality=40, optimize=False)
                        img_b64 = base64.b64encode(buf.getvalue()).decode('utf-8')
                        
                        payload = json.dumps({
                            'cmd': 'mirror_frame',
                            'image_b64': img_b64
                        })
                        
                        # Broadcast to all clients
                        dead_clients = set()
                        for ws in list(self.clients):
                            try:
                                await ws.send(payload)
                            except Exception:
                                dead_clients.add(ws)
                        for ws in dead_clients:
                            self.clients.discard(ws)
                            
                    await asyncio.sleep(1/30)  # ~30 FPS limit
                except Exception as e:
                    log.error(f"Mirror loop error: {e}")
                    await asyncio.sleep(1)
        
        if hasattr(self, '_mirror_task'):
            delattr(self, '_mirror_task')

    async def start(self):
        self._loop = asyncio.get_running_loop()
        self.injector = create_injector(self.width, self.height)
        self._start_hotkey_listener()
        log.info(f"Build: {BUILD_TAG}")
        log.info(f"DrawTab server starting on ws://{self.host}:{self.port}")
        log.info(f"Input injection ready ({platform.system()})")
        if HAS_MSS:
            log.info("mss found: High-performance mirroring ready.")

        # Print connection instructions
        import socket
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
        print("\n" + "═" * 50)
        print(f"  DrawTab Server Ready!")
        print(f"  Connect your mobile app to:")
        print(f"  IP:   {local_ip}")
        print(f"  Port: {self.port}")
        print("═" * 50 + "\n")

        try:
            async with websockets.serve(self.handle_client, self.host, self.port,
                                         max_size=2 ** 20,
                                         ping_interval=20,
                                         ping_timeout=10):
                await asyncio.Future()  # run forever
        finally:
            self._stop_hotkey_listener()
            if self.injector:
                self.injector.close()

    def _start_hotkey_listener(self):
        if not HAS_PYNPUT:
            log.info("Hotkey listener unavailable (install pynput to enable Ctrl+Shift+R)")
            return

        if pynput_keyboard is None:
            log.info("pynput module not available, hotkey disabled")
            return

        def open_selector():
            if not self._loop:
                return
            asyncio.run_coroutine_threadsafe(self._select_region_from_overlay(), self._loop)

        try:
            self._hotkey_listener = pynput_keyboard.GlobalHotKeys({
                '<ctrl>+<shift>+r': open_selector,
            })
            self._hotkey_listener.start()
            log.info("Hotkey ready: Ctrl+Shift+R opens region selector")
        except Exception as exc:
            log.warning(f"Hotkey listener unavailable: {exc}")

    def _stop_hotkey_listener(self):
        listener = self._hotkey_listener
        self._hotkey_listener = None
        if listener is not None:
            try:
                listener.stop()
            except Exception:
                pass


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='DrawTab Desktop Server')
    parser.add_argument('--host', default='0.0.0.0', help='Listen host')
    parser.add_argument('--port', type=int, default=8765, help='WebSocket port')
    parser.add_argument('--width', type=int, default=0, help='Screen width (0=auto)')
    parser.add_argument('--height', type=int, default=0, help='Screen height (0=auto)')
    parser.add_argument('--mirror', action='store_true', help='Enable screen mirroring')
    parser.add_argument('--select-region', action='store_true', help='Launch the region selector window and print the selected region as JSON')
    args = parser.parse_args()

    if args.select_region:
        region = run_region_selector_app()
        if region:
            print(json.dumps(region))
            return
        return

    # Auto-detect screen resolution
    if args.width == 0 or args.height == 0:
        try:
            import tkinter as tk
            root = tk.Tk()
            root.withdraw()
            w, h = root.winfo_screenwidth(), root.winfo_screenheight()
            root.destroy()
            args.width = args.width or w
            args.height = args.height or h
            log.info(f"Auto-detected screen: {args.width}×{args.height}")
        except Exception:
            args.width = args.width or 1920
            args.height = args.height or 1080
            log.info(f"Using default screen: {args.width}×{args.height}")

    server = DrawTabServer(
        host=args.host,
        port=args.port,
        width=args.width,
        height=args.height,
        enable_mirror=args.mirror
    )

    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        log.info("Server stopped.")


if __name__ == '__main__':
    main()