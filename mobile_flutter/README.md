# DrawTab — Mobile Drawing Tablet for Desktop

Turn any Android or iOS device into a pressure-sensitive drawing tablet for Krita, GIMP, Photoshop, or any drawing app on your desktop.

---

## Architecture Overview

```
┌─────────────────────────────┐         Wi-Fi / USB         ┌──────────────────────────────┐
│   Mobile App (Flutter)      │ ◄──── WebSocket ws:// ────► │  Desktop Server (Python)     │
│                             │                             │                              │
│  • Touch/Stylus capture     │   JSON batch events         │  • websockets server         │
│  • Pressure & tilt          │   ~120 events/sec           │  • Platform input injection  │
│  • Normalize to 0.0–1.0     │                             │  • Windows: SendInput API    │
│  • Batch & transmit         │   Optional: JPEG frames     │  • macOS: Quartz CGEvent     │
│  • Optional: mirror display │ ◄──── (mirror mode) ──────  │  • Linux: uinput tablet      │
└─────────────────────────────┘                             └──────────────────────────────┘
```

---

## Quick Start

### Desktop Server (Python)

**Prerequisites:** Python 3.10+

```bash
# 1. Clone or copy the desktop_python folder
cd desktop_python

# 2. Install dependencies
pip install -r requirements.txt

# 3. Start the server (auto-detects screen resolution)
python server.py

# With screen mirroring enabled:
python server.py --mirror

# Custom resolution and port:
python server.py --width 2560 --height 1440 --port 9000
```

The server prints your local IP on startup — you'll need it for the mobile app.

---

### Mobile App (Flutter)

**Prerequisites:** Flutter 3.13+, Android SDK or Xcode

```bash
# 1. Navigate to mobile folder
cd mobile_flutter

# 2. Install dependencies
flutter pub get

# 3. Run on your device (ensure device is on same Wi-Fi)
flutter run --release   # Release mode for best performance

# Build APK for Android:
flutter build apk --release

# Build IPA for iOS:
flutter build ipa --release
```

On the app's connection screen, enter your desktop's IP and port, then tap **Connect**.

---

## Platform-Specific Notes

### Windows
- Uses `SendInput` Win32 API — works with any app
- For full Wacom tablet emulation (pressure in Photoshop), install [VirtualTablet driver](https://www.veikk.com)
- Run server.py with administrator privileges for best compatibility

### macOS
- Install Quartz bindings: `pip install pyobjc-framework-Quartz`
- Grant Accessibility permissions to Terminal in System Preferences → Privacy & Security
- Works with Procreate-style apps receiving standard stylus events

### Linux (Best Tablet Support)
- Install uinput support: `sudo pip install python-uinput`
- Allow uinput access: `sudo usermod -a -G input $USER` (then re-login)
- Creates a virtual Wacom-compatible tablet device — full pressure/tilt in Krita
- Fallback to `xdotool` if uinput unavailable: `sudo apt install xdotool`

---

## USB Connection (Android)

For ultra-low latency via USB:

```bash
# 1. Enable USB Debugging on Android device
# 2. Connect USB cable
# 3. Forward port via ADB:
adb reverse tcp:8765 tcp:8765

# 4. In the mobile app, use IP: 127.0.0.1 (localhost)
```

iOS USB requires a paid Apple Developer account for local network entitlements.

---

## Protocol Specification

The mobile app sends batched JSON messages:

```json
{
  "batch": [
    {
      "type": "down",
      "x": 0.4523,
      "y": 0.3217,
      "pressure": 0.7812,
      "tiltX": -15.3,
      "tiltY": 8.1,
      "isPen": true,
      "buttons": 1,
      "ts": 1718000000000000
    }
  ]
}
```

| Field    | Type    | Description                                           |
|----------|---------|-------------------------------------------------------|
| type     | string  | `down`, `move`, `up`, or `hover`                     |
| x, y     | float   | Normalized 0.0–1.0 coordinates                        |
| pressure | float   | Pen pressure 0.0–1.0 (1.0 for finger touch)          |
| tiltX    | float   | Pen tilt in degrees (-90 to 90)                       |
| isPen    | bool    | True if input is from stylus/Apple Pencil             |
| buttons  | int     | 1=primary, 2=secondary, 32=eraser                     |
| ts       | int     | Microsecond timestamp for lag measurement             |

---

## Performance Tips

1. **Same Wi-Fi band**: Use 5GHz Wi-Fi for lowest latency (typically 2–8ms)
2. **USB preferred**: ADB forwarding gives sub-2ms latency
3. **Disable mobile data**: Prevents OS routing events over cellular
4. **Close background apps**: On mobile, for best touch sampling rate
5. **Battery optimization**: Disable battery saver on mobile device
6. **Server priority**: On Windows, set `server.py` to High priority in Task Manager

---

## Extending DrawTab

### Adding a custom pressure curve:

In `server.py`, modify `_process_batch()`:
```python
# Apply custom pressure curve (ease-in)
evt.pressure = evt.pressure ** 0.7  # softer feel
```

### Mapping tablet area to a sub-region:

```python
# In server.py DrawTabServer.__init__:
self.offset_x = 200   # start 200px from left
self.offset_y = 100   # start 100px from top
self.region_w = 1200  # map to 1200px wide
self.region_h = 800   # map to 800px tall

# In to_screen():
sx = int(self.x * self.region_w) + self.offset_x
```

### Keyboard shortcuts from mobile:

Add to `handle_client()` in `server.py`:
```python
elif data.get('cmd') == 'key':
    # Use pyautogui or pynput
    import pyautogui
    pyautogui.hotkey(*data['keys'])  # e.g. ['ctrl', 'z'] for undo
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't connect | Check firewall allows port 8765 inbound. Use `netstat -an` to verify server is listening |
| High latency | Switch to 5GHz Wi-Fi or use USB/ADB. Check no VPN is active |
| No pressure in Photoshop (Win) | Install WinTab-compatible driver or use Krita/GIMP instead |
| uinput permission denied | Run `sudo chmod 666 /dev/uinput` or add udev rule |
| iOS touch events missing | Ensure `NSLocalNetworkUsageDescription` in Info.plist |
| Flutter build fails | Run `flutter doctor` to check environment |
