"""
DrawTab Screen Mirror
Captures a region of the desktop and streams JPEG frames to the mobile device
over WebSocket. Optimized for low bandwidth using adaptive quality.

Integration: imported by server.py when --mirror flag is set.

Install: pip install mss pillow websockets
"""

import asyncio
import io
import time
import threading
import logging
from typing import Optional

log = logging.getLogger("DrawTab.Mirror")


class ScreenMirror:
    """
    Captures desktop frames and pushes them to connected WebSocket clients.
    
    Target: 15–30 fps at 720p with adaptive JPEG quality.
    Uses a background thread for capture to avoid blocking the event loop.
    """
    
    def __init__(self, region: Optional[dict] = None, fps: int = 20, quality: int = 60):
        """
        Args:
            region: {'left': x, 'top': y, 'width': w, 'height': h}
                    None = full primary monitor
            fps:    Target frames per second (10–30 recommended)
            quality: JPEG quality 1–95 (lower = faster, smaller)
        """
        self.region = region
        self.fps = fps
        self.quality = quality
        self.clients: set = set()
        self._running = False
        self._frame: Optional[bytes] = None
        self._frame_lock = threading.Lock()
        self._loop: Optional[asyncio.AbstractEventLoop] = None

    def start(self, loop: asyncio.AbstractEventLoop):
        """Start capture in a background thread."""
        self._loop = loop
        self._running = True
        thread = threading.Thread(target=self._capture_loop, daemon=True)
        thread.start()
        log.info(f"Screen mirror started at {self.fps}fps quality={self.quality}")

    def stop(self):
        self._running = False

    def add_client(self, ws):
        self.clients.add(ws)
        log.info(f"Mirror client added, total: {len(self.clients)}")

    def remove_client(self, ws):
        self.clients.discard(ws)

    def _capture_loop(self):
        """Background thread: capture frames and schedule broadcasts."""
        try:
            import mss
            from PIL import Image
        except ImportError:
            log.error("Install: pip install mss pillow")
            return

        interval = 1.0 / self.fps
        
        with mss.mss() as sct:
            # Select monitor region
            if self.region:
                monitor = self.region
            else:
                monitor = sct.monitors[1]  # Primary monitor

            while self._running:
                t_start = time.monotonic()
                
                try:
                    # Capture screen
                    sct_img = sct.grab(monitor)
                    img = Image.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
                    
                    # Downscale to max 1280px wide for bandwidth
                    max_w = 1280
                    if img.width > max_w:
                        ratio = max_w / img.width
                        new_size = (max_w, int(img.height * ratio))
                        img = img.resize(new_size, Image.LANCZOS)
                    
                    # Encode to JPEG
                    buf = io.BytesIO()
                    img.save(buf, format='JPEG', quality=self.quality, optimize=False)
                    frame = buf.getvalue()
                    
                    with self._frame_lock:
                        self._frame = frame
                    
                    # Broadcast to clients on the event loop
                    if self.clients and self._loop:
                        asyncio.run_coroutine_threadsafe(
                            self._broadcast(frame), self._loop
                        )
                
                except Exception as e:
                    log.debug(f"Capture error: {e}")
                
                # Sleep to maintain target fps
                elapsed = time.monotonic() - t_start
                sleep_time = interval - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)

    async def _broadcast(self, frame: bytes):
        """Send frame to all connected mirror clients."""
        if not self.clients:
            return
        
        # Wrap in a simple protocol: 4-byte length header + JPEG
        msg = len(frame).to_bytes(4, 'big') + frame
        
        dead = set()
        for ws in list(self.clients):
            try:
                await ws.send(msg, text=False)
            except Exception:
                dead.add(ws)
        
        for ws in dead:
            self.clients.discard(ws)


# ─── Flutter-side mirror receiver snippet ────────────────────────────────────
#
# Add to pubspec.yaml:
#   flutter_image: ^4.2.0
#
# In your DrawingScreen widget:
#
# import 'dart:typed_data';
# import 'package:flutter/material.dart';
#
# class MirrorOverlay extends StatefulWidget { ... }
#
# class _MirrorOverlayState extends State<MirrorOverlay> {
#   Uint8List? _frame;
#   
#   void _onMessage(dynamic msg) {
#     if (msg is List<int>) {
#       final bytes = Uint8List.fromList(msg);
#       final length = ByteData.sublistView(bytes, 0, 4)
#                        .getUint32(0, Endian.big);
#       setState(() => _frame = bytes.sublist(4, 4 + length));
#     }
#   }
#   
#   @override
#   Widget build(BuildContext context) {
#     if (_frame == null) return const SizedBox.shrink();
#     return Opacity(
#       opacity: 0.4,
#       child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.cover),
#     );
#   }
# }
