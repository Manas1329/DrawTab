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


# ─── WEBSOCKET SERVER (ASYNCIO ENGINE) ───────────────────────────────────────

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
        
        # State
        self.region_mode_enabled = False
        self.region_locked = False
        self.selected_region: Optional[dict] = None
        self.active_monitor_index = 0
        
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self.keyboard_controller = pynput_keyboard.Controller() if HAS_PYNPUT else None

        self.client_is_pro = False
        self.session_paused = False
        self.on_pipeline_status_changed = None

        self._evt_count = 0
        self._last_report = time.time()
        self._max_lag_ms = 0.0
        self._last_injected: Optional[dict] = None

    def broadcast_region_state(self):
        if not self._loop:
            return
        payload = json.dumps({
            'cmd': 'region_state',
            'regionModeEnabled': self.region_mode_enabled,
            'regionLocked': self.region_locked,
            'region': self.selected_region
        })
        async def _send():
            dead_clients = set()
            for ws in list(self.clients):
                try:
                    await ws.send(payload)
                except Exception:
                    dead_clients.add(ws)
            for ws in dead_clients:
                self.clients.discard(ws)
        asyncio.run_coroutine_threadsafe(_send(), self._loop)

    def _process_batch(self, batch: list):
        if self.session_paused:
            return
            
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

            if evt.ts > 0:
                lag_ms = (now_us - evt.ts) / 1000.0
                self._max_lag_ms = max(self._max_lag_ms, lag_ms)

            try:
                self._inject_with_interpolation(evt, active_region)
            except Exception as exc:
                log.exception(f"Injection error: {exc}")
            self._evt_count += 1

        now = time.time()
        if now - self._last_report >= 5.0:
            eps = self._evt_count / max(0.001, (now - self._last_report))
            if eps > 0:
                log.info(f"Throughput: {eps:.0f} events/s | Max lag: {self._max_lag_ms:.1f}ms")
            self._evt_count = 0
            self._max_lag_ms = 0.0
            self._last_report = now

    def _inject_with_interpolation(self, evt: DrawEvent, region: Optional[dict]):
        if not self.injector:
            return

        sx, sy = evt.to_screen(self.width, self.height, region)
        prev = self._last_injected

        if isinstance(prev, dict) and prev.get('pen_down', False) and evt.type in ('move', 'up'):
            px = prev['x']
            py = prev['y']
            dx = sx - px
            dy = sy - py
            distance = math.sqrt(dx * dx + dy * dy)

            if distance > 2:
                steps = max(1, int(distance / 1.5))
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
                        pressure=float(prev.get('pressure', evt.pressure)) + (evt.pressure - float(prev.get('pressure', evt.pressure))) * t,
                        tiltX=evt.tiltX,
                        tiltY=evt.tiltY,
                        isPen=evt.isPen,
                        buttons=evt.buttons,
                        ts=evt.ts
                    )
                    self.injector.inject(synthetic, region)

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

    def _handle_key_command(self, keys: list):
        if not self.keyboard_controller:
            return
        vk_map = {
            'ctrl': pynput_keyboard.Key.ctrl, 'shift': pynput_keyboard.Key.shift, 'alt': pynput_keyboard.Key.alt,
            'win': pynput_keyboard.Key.cmd, 'cmd': pynput_keyboard.Key.cmd, 'enter': pynput_keyboard.Key.enter,
            'backspace': pynput_keyboard.Key.backspace, 'tab': pynput_keyboard.Key.tab, 'space': pynput_keyboard.Key.space,
            'esc': pynput_keyboard.Key.esc, 'escape': pynput_keyboard.Key.esc, 'up': pynput_keyboard.Key.up,
            'down': pynput_keyboard.Key.down, 'left': pynput_keyboard.Key.left, 'right': pynput_keyboard.Key.right,
            'capslock': pynput_keyboard.Key.caps_lock,
        }
        for i in range(1, 13): vk_map[f'f{i}'] = getattr(pynput_keyboard.Key, f'f{i}')

        pressed = []
        try:
            for k in keys:
                key_obj = vk_map.get(str(k).lower(), str(k).lower())
                self.keyboard_controller.press(key_obj)
                pressed.append(key_obj)
            time.sleep(0.01)
        finally:
            for key_obj in reversed(pressed):
                try: self.keyboard_controller.release(key_obj)
                except Exception: pass

    async def handle_client(self, ws: Any):
        addr = ws.remote_address
        log.info(f"Client connected: {addr}")
        self.clients.add(ws)
        
        # Initial state payload
        await ws.send(json.dumps({
            'cmd': 'region_state',
            'regionModeEnabled': self.region_mode_enabled,
            'regionLocked': self.region_locked,
            'region': self.selected_region,
        }))

        try:
            async for message in ws:
                try:
                    data = json.loads(message)
                    cmd = data.get('cmd')
                    
                    if 'batch' in data:
                        self._process_batch(data['batch'])
                    elif 'type' in data:
                        self._process_batch([data])
                    elif cmd == 'ping':
                        await ws.send(json.dumps({'cmd': 'pong', 'ts': data.get('ts')}))
                    elif cmd == 'get_state':
                        pass # Triggered implicitly or ignored in new architecture
                    elif cmd == 'session_heartbeat':
                        time_remaining = data.get('time_remaining', 0)
                        self.session_paused = (time_remaining <= 0)
                    elif cmd == 'client_handshake':
                        self.client_is_pro = (data.get('tier') == 'pro')
                        if self.on_pipeline_status_changed:
                            self.on_pipeline_status_changed(self.client_is_pro)
                    elif cmd == 'initialize_stream':
                        self.client_is_pro = data.get('is_pro', False)
                        if self.on_pipeline_status_changed:
                            self.on_pipeline_status_changed(self.client_is_pro)
                    elif cmd == 'set_region_lock':
                        self.region_locked = bool(data.get('enabled', False))
                        if getattr(self, 'on_lock_changed_callback', None):
                            self.on_lock_changed_callback(self.region_locked)
                        self.broadcast_region_state()
                    elif cmd == 'adjust_region':
                        if self.selected_region:
                            dx, dy, scale = data.get('dx', 0), data.get('dy', 0), data.get('scale', 1.0)
                            cw, ch = self.selected_region['width'], self.selected_region['height']
                            cx, cy = self.selected_region['left'] + cw/2, self.selected_region['top'] + ch/2
                            new_w, new_h = cw / scale, ch / scale
                            new_w, new_h = min(new_w, self.width), min(new_h, self.height)
                            
                            if 'dx_pixels' in data and 'dy_pixels' in data:
                                sw, sh = max(1.0, float(data.get('sourceWidth', 1920))), max(1.0, float(data.get('sourceHeight', 1080)))
                                sx, sy = new_w / sw, new_h / sh
                                if self.enable_mirror:
                                    cx -= data['dx_pixels'] * sx
                                    cy -= data['dy_pixels'] * sy
                                else:
                                    cx += data['dx_pixels'] * sx
                                    cy += data['dy_pixels'] * sy
                            else:
                                if self.enable_mirror:
                                    cx -= dx * new_w
                                    cy -= dy * new_h
                                else:
                                    cx += dx * new_w
                                    cy += dy * new_h
                                    
                            new_left = max(0, min(self.width - new_w, cx - new_w / 2))
                            new_top = max(0, min(self.height - new_h, cy - new_h / 2))
                            
                            self.selected_region = {'left': new_left, 'top': new_top, 'width': new_w, 'height': new_h}
                            self.broadcast_region_state()
                    elif cmd == 'key':
                        self._handle_key_command(data.get('keys', []))
                except Exception as e:
                    log.error(f"Event processing error: {e}")
        except Exception:
            pass
        finally:
            self.clients.discard(ws)
            if len(self.clients) == 0 and getattr(self, 'on_pipeline_status_changed', None):
                self.on_pipeline_status_changed(None)
            log.info(f"Client disconnected: {addr}")

    async def _mirror_loop(self):
        if not HAS_MSS:
            return
        with mss.mss() as sct:
            while True:
                try:
                    if not self.enable_mirror or not self.clients or self.session_paused:
                        await asyncio.sleep(0.1)
                        continue
                    primary_mon = sct.monitors[1]
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
                        
                    sct_img = sct.grab(monitor)
                    if HAS_PILLOW:
                        from PIL import Image
                        img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
                        if img.width > 1280 or img.height > 1280:
                            img.thumbnail((1280, 1280), Image.Resampling.BILINEAR)
                        buf = io.BytesIO()
                        jpeg_quality = 80 if self.client_is_pro else 40
                        img.save(buf, format="JPEG", quality=jpeg_quality, optimize=False)
                        payload = json.dumps({'cmd': 'mirror_frame', 'image_b64': base64.b64encode(buf.getvalue()).decode('utf-8')})
                        
                        dead_clients = set()
                        for ws in list(self.clients):
                            try: await ws.send(payload)
                            except Exception: dead_clients.add(ws)
                        for ws in dead_clients: self.clients.discard(ws)
                    
                    sleep_delay = 1/60 if self.client_is_pro else 1/30
                    await asyncio.sleep(sleep_delay)
                except Exception as e:
                    await asyncio.sleep(1)

    async def start(self):
        self._loop = asyncio.get_running_loop()
        self.injector = create_injector(self.width, self.height)
        if self.enable_mirror:
            asyncio.create_task(self._mirror_loop())
            
        try:
            async with websockets.serve(self.handle_client, self.host, self.port, max_size=2**20, ping_interval=20, ping_timeout=10):
                await asyncio.Future()
        finally:
            if self.injector:
                self.injector.close()


# ─── GUI APPLICATION ─────────────────────────────────────────────────────────

import socket
import random
import threading
import customtkinter as ctk
import pystray
from PIL import Image, ImageDraw

def generate_pin(ip: str, port: int) -> str:
    # Hash IP and Port into a 6-digit numeric PIN
    seed = f"{ip}:{port}"
    hashed = hash(seed) % 1000000
    return f"{abs(hashed):06d}"

class DrawTabApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        
        self.title("DrawTab Pro")
        self.geometry("850x450")
        self.resizable(False, False)
        
        icon_path = os.path.join(os.path.dirname(__file__), 'icon.ico')
        if os.path.exists(icon_path):
            self.iconbitmap(icon_path)
        
        self.config_path = os.path.join(os.path.dirname(__file__), 'config.json')
        self.config_data = self._load_config()
        self.preset_slots = self.config_data.get('presets', {})
        self.is_pro = False
        
        # Theming
        ctk.set_appearance_mode(self.config_data.get('theme', 'Dark'))
        
        # Network Setup
        self.ip = socket.gethostbyname(socket.gethostname())
        self.port = random.randint(8000, 9000)
        self.pin = generate_pin(self.ip, self.port)
        
        self._build_ui()
        
        # System Tray Hook
        self.protocol('WM_DELETE_WINDOW', self.hide_window)
        self.tray_icon = None
        
        # Backend Server
        self.server = None
        self.server_thread = None
        self._start_server()
        
        # UDP Discovery
        self.udp_thread = threading.Thread(target=self._udp_listener, daemon=True)
        self.udp_thread.start()
    def _load_config(self):
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r') as f:
                    return json.load(f)
            except Exception:
                pass
        return {'theme': 'Dark', 'presets': {}}
        
    def _save_config(self):
        try:
            with open(self.config_path, 'w') as f:
                json.dump(self.config_data, f)
        except Exception as e:
            log.error(f"Failed to save config: {e}")

    def _build_ui(self):
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        # --- Left Sidebar ---
        self.sidebar_frame = ctk.CTkFrame(self, width=220, corner_radius=0, fg_color=("#E0E0E0", "#0B0C15"))
        self.sidebar_frame.grid(row=0, column=0, sticky="nsew")
        self.sidebar_frame.grid_rowconfigure(7, weight=1)
        
        self.logo_label = ctk.CTkLabel(self.sidebar_frame, text="DrawTab Pro", font=ctk.CTkFont(size=22, weight="bold"), text_color=("black", "white"))
        self.logo_label.grid(row=0, column=0, padx=20, pady=(20, 20))
        
        self.display_label = ctk.CTkLabel(self.sidebar_frame, text="Target Display:", anchor="w")
        self.display_label.grid(row=1, column=0, padx=20, pady=(10, 0), sticky="w")
        self.display_menu = ctk.CTkOptionMenu(self.sidebar_frame, values=["Monitor 1", "Monitor 2", "Monitor 3"], command=self._on_display_changed,
                                              fg_color=("#BA68C8", "#7B1FA2"), button_color=("#AB47BC", "#6A1B9A"), button_hover_color=("#9C27B0", "#4A148C"))
        self.display_menu.grid(row=2, column=0, padx=20, pady=(5, 10))
        
        self.region_label = ctk.CTkLabel(self.sidebar_frame, text="Capture Bounds:", anchor="w")
        self.region_label.grid(row=3, column=0, padx=20, pady=(10, 0), sticky="w")
        self.region_menu = ctk.CTkOptionMenu(self.sidebar_frame, values=["Full Screen", "Tablet Bounds (16:10)", "Mobile Bounds (9:16)", "Custom Box Selection..."], command=self._on_region_changed,
                                              fg_color=("#BA68C8", "#7B1FA2"), button_color=("#AB47BC", "#6A1B9A"), button_hover_color=("#9C27B0", "#4A148C"))
        self.region_menu.grid(row=4, column=0, padx=20, pady=(5, 15))
        
        self.lock_switch = ctk.CTkSwitch(self.sidebar_frame, text="Region Lock", command=self._on_lock_changed, progress_color=("#AB47BC", "#7B1FA2"))
        self.lock_switch.grid(row=5, column=0, padx=20, pady=(10, 10), sticky="nw")
        
        self.mirror_switch = ctk.CTkSwitch(self.sidebar_frame, text="Screen Mirroring", command=self._on_mirror_changed, progress_color=("#AB47BC", "#7B1FA2"))
        self.mirror_switch.deselect()
        self.mirror_switch.grid(row=6, column=0, padx=20, pady=(5, 15), sticky="nw")

        self.theme_btn = ctk.CTkButton(self.sidebar_frame, text="☀ ☾", width=50, height=30, corner_radius=15, 
                                       fg_color="transparent", border_width=1, border_color=("#AAA", "#555"),
                                       text_color=("black", "white"), command=self._toggle_theme)
        self.theme_btn.grid(row=7, column=0, padx=20, pady=(5, 20), sticky="nw")

        # --- Main Console ---
        self.main_frame = ctk.CTkFrame(self, fg_color=("#EDEDED", "#090912"), corner_radius=0)
        self.main_frame.grid(row=0, column=1, sticky="nsew")
        self.main_frame.grid_rowconfigure(1, weight=1)
        self.main_frame.grid_rowconfigure(3, weight=1)
        self.main_frame.grid_columnconfigure(0, weight=1)
        
        # --- Top Header (Presets & Theme) ---
        self.header_frame = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        self.header_frame.grid(row=0, column=0, sticky="ew", padx=20, pady=(20, 0))
        self.header_frame.grid_columnconfigure(11, weight=1)

        self.preset_label = ctk.CTkLabel(self.header_frame, text="Active Preset:", font=ctk.CTkFont(size=12, weight="bold"))
        self.preset_label.grid(row=0, column=0, padx=(0, 10))

        self.active_preset = 1
        self.preset_buttons = []
        for i in range(1, 11):
            text_val = str(i) if i <= 3 else "🔒"
            fg_col = ("#E1BEE7", "#6A1B9A") if i <= 3 else ("#E0E0E0", "#1A1B26")
            txt_col = ("black", "white") if i <= 3 else ("#AAA", "#555")
            btn = ctk.CTkButton(self.header_frame, text=text_val, width=32, height=32, corner_radius=16, 
                                font=ctk.CTkFont(weight="bold", size=13), fg_color=fg_col,
                                text_color=txt_col, hover_color=("#CE93D8", "#8E24AA"))
            btn.grid(row=0, column=i, padx=2)
            btn.bind("<Button-1>", lambda e, slot=i: self._load_preset(slot))
            self.preset_buttons.append(btn)

        self.save_btn = ctk.CTkButton(self.header_frame, text="Save", width=50, height=32, corner_radius=16,
                                      fg_color=("#BA68C8", "#9C27B0"), text_color="white", font=ctk.CTkFont(weight="bold"),
                                      hover_color=("#CE93D8", "#7B1FA2"), command=self._save_active_preset)
        self.save_btn.grid(row=0, column=12, padx=(10, 0))
        
        # Hide header frame initially until connection
        self.header_frame.grid_remove()
        
        # Center Card Container
        self.card_frame = ctk.CTkFrame(self.main_frame, fg_color=("#FAFAFA", "#12101C"), corner_radius=15, width=440, height=270, border_width=1, border_color=("#A0A0C0", "#3D4070"))
        self.card_frame.grid(row=2, column=0, padx=20, pady=20)
        self.card_frame.grid_propagate(False)
        self.card_frame.grid_rowconfigure(0, weight=1)
        self.card_frame.grid_rowconfigure(3, weight=1)
        self.card_frame.grid_columnconfigure(0, weight=1)
        
        self.instruction_label = ctk.CTkLabel(self.card_frame, text="INPUT PAIRING KEY ON TABLET PIPELINE", 
                                              font=ctk.CTkFont(size=11, weight="bold"), text_color=("#6A0DAD", "#8A2BE2"))
        self.instruction_label.grid(row=1, column=0, pady=(40, 10))
        
        self.pin_label = ctk.CTkLabel(self.card_frame, text=self.pin, 
                                      font=ctk.CTkFont(family="Consolas", size=56, weight="bold"), text_color=("black", "white"))
        self.pin_label.grid(row=2, column=0, pady=(0, 20))
        
        self.pipeline_status_label = ctk.CTkLabel(self.card_frame, text="PIPELINE: Waiting for connection...",
                                                  font=ctk.CTkFont(size=11, weight="bold"), text_color=("#555555", "#888888"))
        self.pipeline_status_label.grid(row=3, column=0, pady=(0, 20))
        
        # Debug Footer
        self.footnote_label = ctk.CTkLabel(self.main_frame, text=f"Host IP: {self.ip}  •  Active Port: {self.port}  •  UDP Discovery Active", 
                                           font=ctk.CTkFont(size=10), text_color="#444444")
        self.footnote_label.grid(row=3, column=0, pady=(0, 10), sticky="s")

    def _on_display_changed(self, choice: str):
        if not self.server: return
        idx = int(choice.split()[-1]) - 1
        self.server.active_monitor_index = max(0, idx)
        self.server.broadcast_region_state()

    def _on_region_changed(self, choice: str):
        if not self.server: return
        w, h = 1920, 1080 # Fallback bounds if MSS is not queried dynamically
        try:
            import mss
            with mss.mss() as sct:
                idx = self.server.active_monitor_index + 1
                if idx < len(sct.monitors):
                    mon = sct.monitors[idx]
                    w, h = mon['width'], mon['height']
        except Exception:
            pass

        if "Full Screen" in choice:
            self.server.region_mode_enabled = False
            self.server.selected_region = None
            self.server.broadcast_region_state()
        elif "16:10" in choice:
            self._launch_custom_region_selector(target_ratio=16/10)
        elif "9:16" in choice:
            self._launch_custom_region_selector(target_ratio=9/16)
        elif "Custom" in choice:
            self._launch_custom_region_selector(target_ratio=None)
        
    def _launch_custom_region_selector(self, target_ratio: float = None):
        self.iconify()
        import tkinter as tk
        selector = tk.Toplevel(self)
        selector.attributes('-fullscreen', True)
        selector.attributes('-alpha', 0.4)
        selector.configure(cursor="cross")
        selector.attributes("-topmost", True)
        
        canvas = tk.Canvas(selector, highlightthickness=0, bg='black')
        canvas.pack(fill='both', expand=True)
        
        screen_w = selector.winfo_screenwidth()
        screen_h = selector.winfo_screenheight()
        
        rect = None
        box_coords = [0, 0, 0, 0] # left, top, right, bottom
        state = "idle" # "idle", "drawing", "moving", "resizing"
        start_x = 0
        start_y = 0
        current_ratio = target_ratio
        resize_edge = None
        
        def draw_box():
            nonlocal rect
            if rect: canvas.delete(rect)
            canvas.delete("text")
            if box_coords[2] > box_coords[0] and box_coords[3] > box_coords[1]:
                rect = canvas.create_rectangle(*box_coords, outline='red', width=3, fill='gray')
                if current_ratio:
                    canvas.create_text(
                        (box_coords[0] + box_coords[2]) / 2, 
                        (box_coords[1] + box_coords[3]) / 2, 
                        text="Drag edges to resize\nPress SPACE to rotate\nPress ENTER to confirm", 
                        fill="white", font=("Arial", 14, "bold"), justify="center", tags="text"
                    )
                else:
                    canvas.create_text(
                        (box_coords[0] + box_coords[2]) / 2, 
                        (box_coords[1] + box_coords[3]) / 2, 
                        text="Drag edges to resize\nPress ENTER to confirm", 
                        fill="white", font=("Arial", 14, "bold"), justify="center", tags="text"
                    )
                
        # If preset, initialize a centered box
        if current_ratio:
            if abs(current_ratio - 16/10) < 0.01: # Tablet Landscape
                bw, bh = 1040, 680
            elif abs(current_ratio - 10/16) < 0.01: # Tablet Portrait
                bw, bh = 680, 1040
            elif abs(current_ratio - 9/16) < 0.01: # Mobile Portrait
                bw, bh = 500, 850
            elif abs(current_ratio - 16/9) < 0.01: # Mobile Landscape
                bw, bh = 850, 500
            else:
                bw, bh = screen_w * 0.5, screen_h * 0.5
                
            cx, cy = screen_w / 2, screen_h / 2
            box_coords = [cx - bw/2, cy - bh/2, cx + bw/2, cy + bh/2]
            draw_box()
            
        def on_rotate(event):
            nonlocal current_ratio
            if current_ratio and rect:
                current_ratio = 1 / current_ratio
                cx = (box_coords[0] + box_coords[2]) / 2
                cy = (box_coords[1] + box_coords[3]) / 2
                w = abs(box_coords[2] - box_coords[0])
                h = abs(box_coords[3] - box_coords[1])
                bw = h
                bh = w
                box_coords[0] = cx - bw/2
                box_coords[1] = cy - bh/2
                box_coords[2] = cx + bw/2
                box_coords[3] = cy + bh/2
                draw_box()
                
        selector.bind("<space>", on_rotate)
        selector.bind("r", on_rotate)
        selector.bind("R", on_rotate)
            
        def on_press(event):
            nonlocal start_x, start_y, state, resize_edge
            start_x, start_y = event.x, event.y
            
            if rect:
                margin = 40
                in_box = box_coords[0] - margin < start_x < box_coords[2] + margin and box_coords[1] - margin < start_y < box_coords[3] + margin
                if in_box:
                    on_left = abs(start_x - box_coords[0]) < margin
                    on_right = abs(start_x - box_coords[2]) < margin
                    on_top = abs(start_y - box_coords[1]) < margin
                    on_bottom = abs(start_y - box_coords[3]) < margin
                    
                    if on_right and on_bottom: resize_edge = "br"
                    elif on_right and on_top: resize_edge = "tr"
                    elif on_left and on_bottom: resize_edge = "bl"
                    elif on_left and on_top: resize_edge = "tl"
                    elif on_right: resize_edge = "r"
                    elif on_left: resize_edge = "l"
                    elif on_bottom: resize_edge = "b"
                    elif on_top: resize_edge = "t"
                    else: resize_edge = None
                    
                    if resize_edge:
                        state = "resizing"
                    else:
                        state = "moving"
                    return

            state = "drawing"
            box_coords[0] = start_x
            box_coords[1] = start_y
            box_coords[2] = start_x
            box_coords[3] = start_y
            draw_box()
                
        def on_drag(event):
            nonlocal state, start_x, start_y, resize_edge
            if state == "moving":
                dx = event.x - start_x
                dy = event.y - start_y
                box_coords[0] += dx
                box_coords[1] += dy
                box_coords[2] += dx
                box_coords[3] += dy
                start_x, start_y = event.x, event.y
                draw_box()
            elif state == "resizing":
                old_coords = list(box_coords)
                dx = event.x - start_x
                dy = event.y - start_y
                
                if "r" in resize_edge: box_coords[2] += dx
                if "l" in resize_edge: box_coords[0] += dx
                if "b" in resize_edge: box_coords[3] += dy
                if "t" in resize_edge: box_coords[1] += dy
                
                if current_ratio:
                    w = abs(box_coords[2] - box_coords[0])
                    h = abs(box_coords[3] - box_coords[1])
                    if h == 0: h = 1
                    
                    if w / h > current_ratio:
                        if "r" in resize_edge or "l" in resize_edge:
                            h = w / current_ratio
                            if "t" in resize_edge: box_coords[1] = box_coords[3] - h
                            else: box_coords[3] = box_coords[1] + h
                        else:
                            w = h * current_ratio
                            if "l" in resize_edge: box_coords[0] = box_coords[2] - w
                            else: box_coords[2] = box_coords[0] + w
                    else:
                        if "b" in resize_edge or "t" in resize_edge:
                            w = h * current_ratio
                            if "l" in resize_edge: box_coords[0] = box_coords[2] - w
                            else: box_coords[2] = box_coords[0] + w
                        else:
                            h = w / current_ratio
                            if "t" in resize_edge: box_coords[1] = box_coords[3] - h
                            else: box_coords[3] = box_coords[1] + h
                            
                    final_w = abs(box_coords[2] - box_coords[0])
                    final_h = abs(box_coords[3] - box_coords[1])
                    min_w, max_w = 0, screen_w
                    min_h, max_h = 0, screen_h
                    
                    if abs(current_ratio - 16/10) < 0.01 or abs(current_ratio - 10/16) < 0.01:
                        base_w = 1040 if current_ratio > 1 else 680
                        base_h = 680 if current_ratio > 1 else 1040
                        min_w, max_w = base_w - 50, base_w + 50
                        min_h, max_h = base_h - 50, base_h + 50
                    elif abs(current_ratio - 16/9) < 0.01 or abs(current_ratio - 9/16) < 0.01:
                        base_w = 850 if current_ratio > 1 else 500
                        base_h = 500 if current_ratio > 1 else 850
                        min_w, max_w = base_w - 50, base_w + 50
                        min_h, max_h = base_h - 50, base_h + 50
                        
                    if final_w < min_w or final_h < min_h or final_w > max_w or final_h > max_h:
                        for i in range(4): box_coords[i] = old_coords[i]
                        return
                        
                start_x, start_y = event.x, event.y
                draw_box()
            elif state == "drawing":
                end_x, end_y = event.x, event.y
                if current_ratio:
                    w = abs(end_x - box_coords[0])
                    h = abs(end_y - box_coords[1])
                    if h == 0: h = 1
                    if w / h > current_ratio:
                        end_x = box_coords[0] + (1 if end_x > box_coords[0] else -1) * (h * current_ratio)
                    else:
                        end_y = box_coords[1] + (1 if end_y > box_coords[1] else -1) * (w / current_ratio)
                box_coords[2] = end_x
                box_coords[3] = end_y
                draw_box()
                
        def on_release(event):
            nonlocal state
            # Normalize coords
            left = min(box_coords[0], box_coords[2])
            top = min(box_coords[1], box_coords[3])
            right = max(box_coords[0], box_coords[2])
            bottom = max(box_coords[1], box_coords[3])
            box_coords[:] = [left, top, right, bottom]
            draw_box()
            state = "idle"
            
        def on_confirm(event):
            width = box_coords[2] - box_coords[0]
            height = box_coords[3] - box_coords[1]
            if width > 10 and height > 10 and self.server:
                self.server.region_mode_enabled = True
                self.server.selected_region = {'left': box_coords[0], 'top': box_coords[1], 'width': width, 'height': height}
                self.server.broadcast_region_state()
            selector.destroy()
            self.deiconify()
            
        def on_flip(event):
            nonlocal current_ratio
            if current_ratio and box_coords[2] > box_coords[0]:
                current_ratio = 1 / current_ratio
                cx = (box_coords[0] + box_coords[2]) / 2
                cy = (box_coords[1] + box_coords[3]) / 2
                w = box_coords[2] - box_coords[0]
                h = box_coords[3] - box_coords[1]
                # swap w and h
                box_coords[:] = [cx - h/2, cy - w/2, cx + h/2, cy + w/2]
                draw_box()
            
        def on_escape(event):
            selector.destroy()
            self.deiconify()
            
        canvas.bind('<ButtonPress-1>', on_press)
        canvas.bind('<B1-Motion>', on_drag)
        canvas.bind('<ButtonRelease-1>', on_release)
        selector.bind('<Return>', on_confirm)
        selector.bind('<space>', on_flip)
        selector.bind('r', on_flip)
        selector.bind('<Escape>', on_escape)
        
    def _on_lock_changed(self):
        if not self.server: return
        self.server.region_locked = bool(self.lock_switch.get())
        self.server.broadcast_region_state()

    def _on_mirror_changed(self):
        if not self.server: return
        is_on = bool(self.mirror_switch.get())
        self.server.enable_mirror = is_on
        if not is_on:
            payload = json.dumps({'cmd': 'mirror_stopped'})
            for ws in list(self.server.clients):
                try: asyncio.run_coroutine_threadsafe(ws.send(payload), self.server._loop)
                except Exception: pass

    def _toggle_theme(self):
        current = ctk.get_appearance_mode()
        new_mode = "Light" if current == "Dark" else "Dark"
        ctk.set_appearance_mode(new_mode)
        self.config_data['theme'] = new_mode
        self._save_config()

    def _load_preset(self, slot: int):
        if not self.is_pro and slot > 3: return
        
        self.active_preset = slot
        self._update_preset_colors()
        
        preset = self.preset_slots.get(str(slot))
        if not preset or not self.server: 
            return # Default state, nothing to load
        
        self.server.active_monitor_index = preset.get("monitor_index", 0)
        self.server.region_locked = preset.get("region_locked", False)
        if preset.get("region_mode_enabled"):
            self.server.region_mode_enabled = True
            self.server.selected_region = preset.get("selected_region")
        else:
            self.server.region_mode_enabled = False
            self.server.selected_region = None
            
        self.server.broadcast_region_state()
        
        # update UI
        self.display_menu.set(f"Monitor {self.server.active_monitor_index + 1}")
        if self.server.region_locked:
            self.lock_switch.select()
        else:
            self.lock_switch.deselect()

    def _save_active_preset(self):
        slot = self.active_preset
        if not self.is_pro and slot > 3: return
        if not self.server: return
            
        self.preset_slots[str(slot)] = {
            "monitor_index": self.server.active_monitor_index,
            "region_locked": self.server.region_locked,
            "region_mode_enabled": self.server.region_mode_enabled,
            "selected_region": self.server.selected_region
        }
        self.config_data['presets'] = self.preset_slots
        self._save_config()
        
    def _update_preset_colors(self):
        for i, btn in enumerate(self.preset_buttons):
            slot = i + 1
            if not self.is_pro and slot > 3:
                btn.configure(fg_color=("#E0E0E0", "#1A1B26"), text_color=("#AAA", "#555"))
            else:
                if slot == self.active_preset:
                    btn.configure(fg_color=("#BA68C8", "#9C27B0"), text_color="white") # Active slot highlight
                else:
                    btn.configure(fg_color=("#E1BEE7", "#6A1B9A"), text_color=("black", "white"))

    def _update_preset_locks(self, is_pro):
        self.is_pro = is_pro
        for i, btn in enumerate(self.preset_buttons):
            slot = i + 1
            if not is_pro and slot > 3:
                btn.configure(state="disabled", text="🔒", fg_color=("#E0E0E0", "#1A1B26"), text_color=("#AAA", "#555"))
            else:
                btn.configure(state="normal", text=str(slot), fg_color=("#E1BEE7", "#6A1B9A"), text_color=("black", "white"))
        self._update_preset_colors()

    def _start_server(self):
        def _run_asyncio():
            self.server = DrawTabServer(host="0.0.0.0", port=self.port, width=1920, height=1080, enable_mirror=False)
            
            def update_lock_switch(locked):
                if locked:
                    self.lock_switch.select()
                else:
                    self.lock_switch.deselect()
            
            def update_pipeline_status(is_pro):
                if is_pro is None:
                    text = "PIPELINE: Waiting for connection..."
                elif is_pro:
                    text = "CONNECTED DEVICE: iPad Pro (PRO MEMBER - 60FPS Unlocked)"
                else:
                    text = "CONNECTED DEVICE: Tablet (FREE TIER - 30FPS Limit)"
                self.pipeline_status_label.configure(text=text)
                if is_pro is not None:
                    self.header_frame.grid()
                    self._update_preset_locks(is_pro)

            self.server.on_lock_changed_callback = lambda locked: self.after(0, lambda: update_lock_switch(locked))
            self.server.on_pipeline_status_changed = lambda is_pro: self.after(0, lambda: update_pipeline_status(is_pro))
            
            try:
                asyncio.run(self.server.start())
            except Exception as e:
                print(f"Asyncio Server Error: {e}")
            
        self.server_thread = threading.Thread(target=_run_asyncio, daemon=True)
        self.server_thread.start()
        
    def _udp_listener(self):
        import socket
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('0.0.0.0', 8764))
        while True:
            try:
                data, addr = sock.recvfrom(1024)
                if b'Who is DrawTab?' in data:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    try:
                        s.connect((addr[0], 1))
                        ip = s.getsockname()[0]
                    except Exception:
                        ip = self.ip
                    finally:
                        s.close()
                    resp = json.dumps({'pin': self.pin, 'port': self.port, 'ip': ip}).encode('utf-8')
                    sock.sendto(resp, addr)
            except Exception:
                time.sleep(1)

    def create_tray_image(self):
        image = Image.new('RGB', (64, 64), color=(26, 26, 30))
        d = ImageDraw.Draw(image)
        d.text((15, 25), "DT", fill=(138, 43, 226))
        return image

    def hide_window(self):
        self.withdraw()
        image = self.create_tray_image()
        menu = pystray.Menu(
            pystray.MenuItem('Restore DrawTab Pro', self.show_window, default=True),
            pystray.MenuItem('Quit', self.quit_window)
        )
        self.tray_icon = pystray.Icon("drawtab", image, "DrawTab Pro", menu)
        threading.Thread(target=self.tray_icon.run, daemon=True).start()

    def show_window(self, icon, item):
        icon.stop()
        self.after(0, self.deiconify)

    def quit_window(self, icon, item):
        icon.stop()
        self.quit()

if __name__ == '__main__':
    import ctypes
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        try: ctypes.windll.user32.SetProcessDPIAware()
        except Exception: pass
        
    app = DrawTabApp()
    app.mainloop()
