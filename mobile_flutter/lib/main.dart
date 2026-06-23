import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'input_panel_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('isDarkTheme') ?? true;
  runApp(DrawTabApp(initialDark: isDark));
}

class DrawTabApp extends StatefulWidget {
  final bool initialDark;
  const DrawTabApp({super.key, required this.initialDark});

  static _DrawTabAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_DrawTabAppState>();

  @override
  State<DrawTabApp> createState() => _DrawTabAppState();
}

class _DrawTabAppState extends State<DrawTabApp> {
  late bool isDark;

  @override
  void initState() {
    super.initState();
    isDark = widget.initialDark;
  }

  void toggleTheme() async {
    setState(() => isDark = !isDark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkTheme', isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DrawTab',
      theme: isDark
          ? ThemeData.dark().copyWith(
              colorScheme: ColorScheme.dark(
                primary: const Color(0xFF6C63FF),
                surface: const Color(0xFF1A1A2E),
              ),
              scaffoldBackgroundColor: const Color(0xFF0F0F1A),
            )
          : ThemeData.light().copyWith(
              colorScheme: ColorScheme.light(
                primary: const Color(0xFF6C63FF),
                surface: Colors.white,
              ),
              scaffoldBackgroundColor: const Color(0xFFF0F0F5),
            ),
      home: const MainMenuScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  final _ipController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '8765');
  bool _connecting = false;
  String _status = '';

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });

    final uri = Uri.parse('ws://${_ipController.text}:${_portController.text}');
    try {
      final channel = IOWebSocketChannel.connect(uri,
          connectTimeout: const Duration(seconds: 5));
      await channel.ready;

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DrawingScreen(serverUri: uri, channel: channel),
        ),
      ).then((_) {
        // Returned from drawing screen
        setState(() {
          _connecting = false;
          _status = '';
        });
      });
    } catch (e) {
      setState(() {
        _status = 'Connection failed: $e';
        _connecting = false;
      });
    }
  }

  void _showConnectionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text('Connect to Desktop', style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(labelText: 'IP Address'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(labelText: 'Port (8765)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _connect();
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = DrawTabApp.of(context)?.isDark ?? true;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
            color: Theme.of(context).iconTheme.color,
            onPressed: () => DrawTabApp.of(context)?.toggleTheme(),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.draw_outlined, size: 80, color: Color(0xFF6C63FF)),
            const SizedBox(height: 24),
            Text('DrawTab', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Theme.of(context).textTheme.bodyLarge?.color)),
            const SizedBox(height: 8),
            Text('Turn your device into a drawing tablet', style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 16)),
            const SizedBox(height: 48),
            if (_connecting)
              Column(
                children: [
                  const CircularProgressIndicator(color: Color(0xFF6C63FF)),
                  const SizedBox(height: 16),
                  Text(_status, style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color)),
                ],
              )
            else
              ElevatedButton.icon(
                icon: const Icon(Icons.link, size: 24),
                label: const Text('Connect to Server', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: _showConnectionDialog,
              ),
            if (!_connecting && _status.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(_status, style: const TextStyle(color: Colors.redAccent)),
            ]
          ],
        ),
      ),
    );
  }
}

class DrawEvent {
  final String type;
  final double x;
  final double y;
  final bool normalized;
  final double sourceWidth;
  final double sourceHeight;
  final double pressure;
  final double tiltX;
  final double tiltY;
  final double twist;
  final bool isPen;
  final int buttons;
  final int timestamp;

  DrawEvent({
    required this.type,
    required this.x,
    required this.y,
    required this.normalized,
    required this.sourceWidth,
    required this.sourceHeight,
    this.pressure = 1.0,
    this.tiltX = 0.0,
    this.tiltY = 0.0,
    this.twist = 0.0,
    this.isPen = false,
    this.buttons = 1,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'cmd': 'draw_event',
        'type': type,
        'x': x,
        'y': y,
        'normalized': normalized,
        'sourceWidth': sourceWidth,
        'sourceHeight': sourceHeight,
        'pressure': pressure,
        'tiltX': tiltX,
        'tiltY': tiltY,
        'twist': twist,
        'isPen': isPen,
        'buttons': buttons,
        'ts': timestamp,
      };
}

class DrawingScreen extends StatefulWidget {
  final Uri serverUri;
  final IOWebSocketChannel channel;

  const DrawingScreen({super.key, required this.serverUri, required this.channel});

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen> {
  late IOWebSocketChannel _channel;
  StreamSubscription? _channelSubscription;

  bool _connected = true;
  String _status = 'Connected';
  bool _reconnecting = false;

  final List<DrawEvent> _eventQueue = [];
  Timer? _flushTimer;

  bool _isFirstStroke = true;
  double _lastX = 0;
  double _lastY = 0;
  int _lastFlushTime = 0;

  bool _regionModeEnabled = false;
  Map<String, dynamic>? _serverRegion;
  bool _mirrorEnabled = false;
  Uint8List? _mirrorFrame;
  bool _keypadEnabled = false;

  double _pressureMultiplier = 1.0;
  bool _pressureOptimized = true;
  double _tiltSensitivity = 1.0;

  bool _eraserMode = false;
  String _drawShortcut = 'b';
  String _eraserShortcut = 'e';

  Size? _canvasSize;

  bool _navbarOpen = false;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _setupWebSocket();
    _flushTimer = Timer.periodic(const Duration(milliseconds: 1), (_) => _flush());
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _drawShortcut = prefs.getString('draw_shortcut') ?? 'b';
      _eraserShortcut = prefs.getString('eraser_shortcut') ?? 'e';
    });
  }

  void _setupWebSocket() {
    _channelSubscription = _channel.stream.listen(
      (message) {
        if (!mounted) return;
        try {
          if (message is String) {
            final data = jsonDecode(message);
            if (data['cmd'] == 'region_state') {
              setState(() {
                _regionModeEnabled = data['regionModeEnabled'] ?? false;
                _serverRegion = data['region'];
              });
            }
          } else if (message is List<int>) {
            setState(() {
              _mirrorFrame = Uint8List.fromList(message);
            });
          }
        } catch (e) {
          debugPrint('Error parsing message: $e');
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _connected = false;
            _status = 'Disconnected';
          });
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _connected = false;
            _status = 'Error: $error';
          });
        }
      },
    );
  }

  void _reconnect() async {
    setState(() {
      _reconnecting = true;
      _status = 'Reconnecting...';
    });

    try {
      _channelSubscription?.cancel();
      _channel = IOWebSocketChannel.connect(widget.serverUri, connectTimeout: const Duration(seconds: 5));
      await _channel.ready;
      _setupWebSocket();
      
      setState(() {
        _connected = true;
        _reconnecting = false;
        _status = 'Connected';
      });
      
      _sendCommand({'cmd': 'set_mirror_mode', 'enabled': _mirrorEnabled});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reconnecting = false;
        _status = 'Reconnect failed: $e';
      });
    }
  }

  void _sendCommand(Map<String, dynamic> cmd) {
    if (_connected) {
      _channel.sink.add(jsonEncode(cmd));
    }
  }

  void _requestRegionSelection(String preset) {
    _sendCommand({
      'cmd': 'select_region',
      'preset': preset,
    });
  }

  void _queueEvent(DrawEvent event) {
    _eventQueue.add(event);
    if (_eventQueue.length >= 10) _flush();
  }

  void _flush() {
    if (_eventQueue.isEmpty || !_connected) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now - _lastFlushTime < 1000 && _eventQueue.length < 5) return;

    final batch = _eventQueue.map((e) => e.toJson()).toList();
    _eventQueue.clear();
    _lastFlushTime = now;
    _channel.sink.add(jsonEncode({'cmd': 'batch_events', 'events': batch}));
  }

  DrawEvent? _pointerToEvent(PointerEvent e, String type) {
    if (_canvasSize == null) return null;
    final safeWidth = _canvasSize!.width <= 0 ? 1.0 : _canvasSize!.width;
    final safeHeight = _canvasSize!.height <= 0 ? 1.0 : _canvasSize!.height;

    final mappedX = (e.localPosition.dx / safeWidth).clamp(0.0, 1.0);
    final mappedY = (e.localPosition.dy / safeHeight).clamp(0.0, 1.0);

    double finalX = mappedX;
    double finalY = mappedY;

    if (_isFirstStroke && type == 'down') {
      _lastX = finalX;
      _lastY = finalY;
    } else if (type == 'move') {
      final alpha = 0.5;
      finalX = _lastX + alpha * (finalX - _lastX);
      finalY = _lastY + alpha * (finalY - _lastY);
      _lastX = finalX;
      _lastY = finalY;
    } else if (type == 'up') {
      finalX = _lastX;
      finalY = _lastY;
    }
    _isFirstStroke = false;

    double pressure = e.pressure.clamp(0.0, 1.0);
    if (pressure == 0.0 && type != 'up') pressure = 1.0;
    
    if (_pressureOptimized) {
      pressure = pow(pressure, 0.7).toDouble();
    }
    pressure = (pressure * _pressureMultiplier).clamp(0.0, 1.0);

    final tiltX = (e.tilt * _tiltSensitivity * (e.radiusMajor > 0 ? 1 : 0)).clamp(-90.0, 90.0);

    final isPen = e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;
    int buttons = 1;
    if (_eraserMode || e.kind == PointerDeviceKind.invertedStylus) buttons = 32;

    return DrawEvent(
      type: type,
      x: finalX,
      y: finalY,
      normalized: true,
      sourceWidth: safeWidth,
      sourceHeight: safeHeight,
      pressure: pressure,
      tiltX: tiltX,
      isPen: isPen,
      buttons: buttons,
      timestamp: DateTime.now().microsecondsSinceEpoch,
    );
  }

  void _handlePointerDown(PointerDownEvent e) {
    if (_navbarOpen) {
      setState(() => _navbarOpen = false);
      return;
    }
    final evt = _pointerToEvent(e, 'down');
    if (evt != null) _queueEvent(evt);
  }
  void _handlePointerMove(PointerMoveEvent e) {
    if (_navbarOpen) return;
    final evt = _pointerToEvent(e, 'move');
    if (evt != null) _queueEvent(evt);
  }
  void _handlePointerUp(PointerUpEvent e) {
    if (_navbarOpen) return;
    final evt = _pointerToEvent(e, 'up');
    if (evt != null) {
      _queueEvent(evt);
      _flush();
    }
  }

  // Multi-touch gestures
  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_navbarOpen) return;
    if (details.pointerCount >= 2 && _regionModeEnabled) {
      if (_canvasSize != null && _canvasSize!.width > 0) {
        final dx = details.focalPointDelta.dx / _canvasSize!.width;
        final dy = details.focalPointDelta.dy / _canvasSize!.height;
        
        _sendCommand({
          'cmd': 'adjust_region',
          'dx': dx,
          'dy': dy,
          'scale': details.scale,
        });
      }
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _channelSubscription?.cancel();
    _channel.sink.close();
    super.dispose();
  }

  void _showRegionOptions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Select Region Preset'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Mobile Size'),
              onTap: () { Navigator.pop(ctx); _requestRegionSelection('mobile'); },
            ),
            ListTile(
              leading: const Icon(Icons.tablet_mac),
              title: const Text('Tablet Size'),
              onTap: () { Navigator.pop(ctx); _requestRegionSelection('tablet'); },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Signature Area'),
              onTap: () { Navigator.pop(ctx); _requestRegionSelection('signature'); },
            ),
            ListTile(
              leading: const Icon(Icons.crop_free),
              title: const Text('Custom'),
              onTap: () { Navigator.pop(ctx); _requestRegionSelection('custom'); },
            ),
          ],
        ),
      ),
    );
  }

  void _showPressureSlider() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Pressure Multiplier'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => SizedBox(
            height: 200,
            child: RotatedBox(
              quarterTurns: -1,
              child: Slider(
                value: _pressureMultiplier,
                min: 0.5,
                max: 2.0,
                onChanged: (v) {
                  setDialogState(() => _pressureMultiplier = v);
                  setState(() {});
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavbar() {
    return Container(
      width: 70,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.9),
        borderRadius: const BorderRadius.only(topRight: Radius.circular(20), bottomRight: Radius.circular(20)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _NavBtn(
            icon: _regionModeEnabled ? Icons.crop_square : Icons.fullscreen,
            active: _regionModeEnabled,
            tooltip: 'Toggle Full/Region Mode',
            onTap: () {
              setState(() => _regionModeEnabled = !_regionModeEnabled);
              _sendCommand({'cmd': 'region_mode', 'enabled': _regionModeEnabled});
              if (_regionModeEnabled && _serverRegion == null) {
                _showRegionOptions();
              }
            },
            onLongPress: _regionModeEnabled ? _showRegionOptions : null,
          ),
          _NavBtn(
            icon: Icons.screen_share,
            active: _mirrorEnabled,
            tooltip: 'Toggle Mirror Mode',
            onTap: () {
              setState(() => _mirrorEnabled = !_mirrorEnabled);
              _sendCommand({'cmd': 'set_mirror_mode', 'enabled': _mirrorEnabled});
            },
          ),
          _NavBtn(
            icon: Icons.keyboard,
            active: _keypadEnabled,
            tooltip: 'Toggle Input Panel',
            onTap: () {
              setState(() => _keypadEnabled = !_keypadEnabled);
            },
          ),
          _NavBtn(
            icon: Icons.line_weight,
            active: false,
            tooltip: 'Pressure Sensitivity',
            onTap: _showPressureSlider,
          ),
          _NavBtn(
            icon: _eraserMode ? Icons.auto_fix_high : Icons.edit,
            active: _eraserMode,
            tooltip: 'Toggle Pen/Eraser',
            onTap: () {
              setState(() => _eraserMode = !_eraserMode);
              _sendCommand({'cmd': 'key', 'keys': [_eraserMode ? _eraserShortcut : _drawShortcut]});
            },
          ),
          _NavBtn(
            icon: Icons.undo,
            active: false,
            tooltip: 'Undo (Ctrl+Z)',
            onTap: () {
              _sendCommand({'cmd': 'key', 'keys': ['ctrl', 'z']});
            },
          ),
          const Spacer(),
          _NavBtn(
            icon: Icons.refresh,
            active: _connected,
            activeColor: Colors.greenAccent,
            inactiveColor: Colors.redAccent,
            tooltip: 'Status: $_status (Tap to reconnect)',
            onTap: _reconnect,
          ),
          _NavBtn(
            icon: Icons.power_settings_new,
            active: false,
            tooltip: 'Disconnect',
            onTap: () {
              Navigator.pop(context);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Canvas Layer
          Positioned.fill(
            child: GestureDetector(
              onScaleUpdate: _onScaleUpdate,
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                    return Container(
                      width: double.infinity,
                      height: double.infinity,
                      color: Colors.transparent,
                      child: Stack(
                        children: [
                          if (_mirrorEnabled && _mirrorFrame != null)
                            Positioned.fill(
                              child: Image.memory(
                                _mirrorFrame!,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.none,
                              ),
                            )
                          else
                            Positioned.fill(
                              child: CustomPaint(painter: _GridPainter(Theme.of(context).dividerColor)),
                            ),
                          if (_keypadEnabled)
                            Positioned.fill(
                              child: InputPanelScreen(sendCommand: _sendCommand),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          
          // Floating trigger button
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: _navbarOpen ? -50 : 0,
            top: MediaQuery.of(context).size.height / 2 - 25,
            child: GestureDetector(
              onTap: () => setState(() => _navbarOpen = true),
              child: Container(
                width: 40,
                height: 50,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.6),
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(25), bottomRight: Radius.circular(25)),
                ),
                child: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
              ),
            ),
          ),

          // Sliding Navbar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: _navbarOpen ? 0 : -70,
            top: 20, // Lowered slightly to avoid status bar
            bottom: 20,
            child: _buildNavbar(),
          ),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? activeColor;
  final Color? inactiveColor;

  const _NavBtn({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
    this.onLongPress,
    this.activeColor,
    this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final aColor = activeColor ?? theme.colorScheme.primary;
    final iColor = inactiveColor ?? theme.iconTheme.color?.withOpacity(0.5) ?? Colors.grey;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: Icon(icon, color: active ? aColor : iColor, size: 28),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color color;
  _GridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.05)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override
  bool shouldRepaint(_) => false;
}
