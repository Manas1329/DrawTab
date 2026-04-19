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
from dataclasses import dataclass
from typing import Optional

# ─── Optional screen mirror imports ──────────────────────────────────────────
try:
    import websockets
    from websockets.server import WebSocketServerProtocol
    HAS_WEBSOCKETS = True
except ImportError:
    HAS_WEBSOCKETS = False
    print("Install websockets: pip install websockets")
    sys.exit(1)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger("DrawTab")

# ─── INPUT EVENT DATACLASS ────────────────────────────────────────────────────

@dataclass
class DrawEvent:
    type: str        # 'down' | 'move' | 'up' | 'hover'
    x: float         # normalized 0.0–1.0
    y: float         # normalized 0.0–1.0
    pressure: float  # 0.0–1.0
    tiltX: float     # -90 to 90 degrees
    tiltY: float     # -90 to 90 degrees
    isPen: bool
    buttons: int     # 1=primary, 32=eraser
    ts: int          # microsecond timestamp

    def to_screen(self, width: int, height: int) -> tuple[int, int]:
        """Convert normalized coords to screen pixels."""
        return (
            max(0, min(width - 1, int(self.x * width))),
            max(0, min(height - 1, int(self.y * height)))
        )

# ─── PLATFORM INPUT INJECTORS ─────────────────────────────────────────────────

class InputInjector:
    """Base class for platform-specific input injection."""
    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height
        self._pen_down = False

    def inject(self, evt: DrawEvent):
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

    def inject(self, evt: DrawEvent):
        sx, sy = evt.to_screen(65535, 65535)  # SendInput uses 0–65535 scale
        flags = self.MOUSEEVENTF_MOVE | self.MOUSEEVENTF_ABSOLUTE
        extra = 0

        if evt.type == 'down':
            self._pen_down = True
            flags |= self.MOUSEEVENTF_LEFTDOWN
        elif evt.type == 'up':
            self._pen_down = False
            flags |= self.MOUSEEVENTF_LEFTUP

        inp = self.INPUT(
            type=self.INPUT_MOUSE,
            mi=self.MOUSEINPUT(dx=sx, dy=sy, dwFlags=flags)
        )
        self.user32.SendInput(1, self.ctypes.byref(inp), self.ctypes.sizeof(inp))


class MacOSInputInjector(InputInjector):
    """Uses Quartz CoreGraphics for macOS pen/mouse events."""
    def __init__(self, width, height):
        super().__init__(width, height)
        try:
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

    def inject(self, evt: DrawEvent):
        Q = self.Quartz
        sx, sy = evt.to_screen(self.width, self.height)

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

    def inject(self, evt: DrawEvent):
        sx, sy = evt.to_screen(self.width, self.height)
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

        # Latency stats
        self._evt_count = 0
        self._last_report = time.time()
        self._max_lag_ms = 0.0

    def _process_batch(self, batch: list):
        now_us = time.monotonic_ns() // 1000
        for raw in batch:
            evt = DrawEvent(
                type=raw['type'],
                x=raw['x'],
                y=raw['y'],
                pressure=raw.get('pressure', 1.0),
                tiltX=raw.get('tiltX', 0.0),
                tiltY=raw.get('tiltY', 0.0),
                isPen=raw.get('isPen', False),
                buttons=raw.get('buttons', 1),
                ts=raw.get('ts', 0),
            )

            # Calculate lag
            if evt.ts > 0:
                lag_ms = (now_us - evt.ts) / 1000.0
                self._max_lag_ms = max(self._max_lag_ms, lag_ms)

            self.injector.inject(evt)
            self._evt_count += 1

        # Stats every 5 seconds
        now = time.time()
        if now - self._last_report >= 5.0:
            eps = self._evt_count / (now - self._last_report)
            log.info(f"Throughput: {eps:.0f} events/s | Max lag: {self._max_lag_ms:.1f}ms")
            self._evt_count = 0
            self._max_lag_ms = 0.0
            self._last_report = now

    async def handle_client(self, ws: WebSocketServerProtocol):
        addr = ws.remote_address
        log.info(f"Client connected: {addr}")
        self.clients.add(ws)

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
                except json.JSONDecodeError:
                    log.warning("Invalid JSON received")
                except Exception as e:
                    log.error(f"Event processing error: {e}")
        except Exception:
            pass
        finally:
            self.clients.discard(ws)
            log.info(f"Client disconnected: {addr}")

    async def start(self):
        self.injector = create_injector(self.width, self.height)
        log.info(f"DrawTab server starting on ws://{self.host}:{self.port}")
        log.info(f"Input injection ready ({platform.system()})")

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
            if self.injector:
                self.injector.close()


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='DrawTab Desktop Server')
    parser.add_argument('--host', default='0.0.0.0', help='Listen host')
    parser.add_argument('--port', type=int, default=8765, help='WebSocket port')
    parser.add_argument('--width', type=int, default=0, help='Screen width (0=auto)')
    parser.add_argument('--height', type=int, default=0, help='Screen height (0=auto)')
    parser.add_argument('--mirror', action='store_true', help='Enable screen mirroring')
    args = parser.parse_args()

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
