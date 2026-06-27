import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  final _pinController = TextEditingController();
  final _focusNode = FocusNode();
  bool _connecting = false;
  String _status = '';
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _pinController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _resolvePinAndConnect() async {
    final pin = _pinController.text.trim();
    if (pin.length != 6) {
      setState(() {
        _status = 'Invalid PIN format';
      });
      return;
    }

    setState(() {
      _connecting = true;
      _status = 'Locating DrawTab Server...';
    });

    // Implement Subnet Locator Ping / UDP Broadcast
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      
      final broadcastAddress = InternetAddress('255.255.255.255');
      final portToBroadcast = 8764;
      final payload = utf8.encode('Who is DrawTab?');
      
      socket.send(payload, broadcastAddress, portToBroadcast);
      
      bool found = false;
      String? targetHost;
      int? targetPort;
      
      final timer = Timer(const Duration(seconds: 5), () {
        if (!found && mounted) {
          socket?.close();
          setState(() {
            _status = 'Connection timed out. Server not found.';
            _connecting = false;
          });
        }
      });

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket?.receive();
          if (datagram != null) {
            try {
              final responseStr = utf8.decode(datagram.data);
              final jsonResponse = jsonDecode(responseStr);
              if (jsonResponse['pin'] == pin) {
                found = true;
                timer.cancel();
                targetHost = jsonResponse['ip'] ?? datagram.address.address;
                targetPort = jsonResponse['port'];
                socket?.close();
                
                _connectToServer(targetHost!, targetPort!);
              }
            } catch (e) {
              // Ignore parse errors from other packets
            }
          }
        }
      });
    } catch (e) {
      setState(() {
        _status = 'UDP Discovery failed: $e';
        _connecting = false;
      });
      socket?.close();
    }
  }

  void _connectToServer(String host, int port) async {
    final uri = Uri.parse('ws://$host:$port');
    try {
      final channel = IOWebSocketChannel.connect(uri, connectTimeout: const Duration(seconds: 5));
      await channel.ready;

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DrawingScreen(serverUri: uri, channel: channel),
        ),
      ).then((_) {
        setState(() {
          _connecting = false;
          _status = '';
          _pinController.clear();
        });
      });
    } catch (e) {
      setState(() {
        _status = 'Connection failed: $e';
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = DrawTabApp.of(context)?.isDark ?? true;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: const Color(0xFF121214), // Deep slate/charcoal workspace
      body: SafeArea(
        child: Stack(
          children: [
            // Title Context Header
            Positioned(
              top: 16,
              left: 24,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'DrawTab . Pipeline Hub',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.5,
                    ),
                  ),
                  IconButton(
                    icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode, size: 20),
                    color: Colors.white70,
                    onPressed: () => DrawTabApp.of(context)?.toggleTheme(),
                  ),
                ],
              ),
            ),
            
            // Connection Input Deck
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isLandscape ? 120.0 : 32.0),
                child: Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1E).withOpacity(0.85),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Enter 6-Digit Desktop Code',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 220,
                                child: TextField(
                                  controller: _pinController,
                                  focusNode: _focusNode,
                                  maxLength: 6,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontFamily: 'Courier',
                                    fontSize: 32,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 12,
                                    color: Colors.white,
                                  ),
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: InputDecoration(
                                    counterText: "", // Hide the character counter
                                    filled: true,
                                    fillColor: const Color(0xFF121214),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 20),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide(
                                        color: Colors.white.withOpacity(0.2),
                                        width: 1,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                        color: Color(0xFF00E5FF), // Neon Cyan
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                  onSubmitted: (_) => _resolvePinAndConnect(),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Container(
                                height: 72,
                                width: 72,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C4DFF), // Neon Purple Execution Button
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF7C4DFF).withOpacity(0.4),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    )
                                  ],
                                ),
                                child: _connecting
                                    ? const Padding(
                                        padding: EdgeInsets.all(24.0),
                                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                      )
                                    : IconButton(
                                        icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
                                        onPressed: _resolvePinAndConnect,
                                      ),
                              ),
                            ],
                          ),
                          if (_status.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            Text(
                              _status,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ]
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
        'source_width': sourceWidth,
        'source_height': sourceHeight,
        'pressure': pressure,
        'tilt_x': tiltX,
        'tilt_y': tiltY,
        'twist': twist,
        'is_pen': isPen,
        'buttons': buttons,
        'timestamp': timestamp,
      };
}

class DrawingScreen extends StatefulWidget {
  final Uri serverUri;
  final WebSocketChannel channel;

  const DrawingScreen({super.key, required this.serverUri, required this.channel});

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen> {
  late WebSocketChannel _channel;
  bool _connected = true;
  bool _reconnecting = false;
  String _status = 'Connected';

  final List<DrawEvent> _eventQueue = [];
  int _lastFlushTime = 0;
  Timer? _flushTimer;
  StreamSubscription? _channelSubscription;

  double _lastX = 0.0;
  double _lastY = 0.0;
  bool _isFirstStroke = true;

  double _pressureMultiplier = 1.0;
  bool _pressureOptimized = true;
  double _tiltSensitivity = 1.0;

  bool _regionModeEnabled = false;
  bool _regionLocked = false;
  Map<String, dynamic>? _serverRegion;

  Uint8List? _mirrorFrame;
  bool _keypadEnabled = false;

  bool _eraserMode = false;
  String _drawShortcut = 'b';
  String _eraserShortcut = 'e';

  Size? _canvasSize;

  bool _navbarExpanded = false;
  bool _showPressureSlider = false;

  final Set<int> _activePointerIds = {};
  
  Map<int, Offset> _pointerPositions = {};
  double _lastGestureScale = 1.0;
  
  final GlobalKey _pressureIconKey = GlobalKey();

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
                _regionLocked = data['regionLocked'] ?? _regionLocked;
                _serverRegion = data['region'];
              });
            } else if (data['cmd'] == 'mirror_frame') {
              setState(() {
                _mirrorFrame = base64Decode(data['image_b64']);
              });
            } else if (data['cmd'] == 'mirror_stopped') {
              setState(() {
                _mirrorFrame = null;
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

  void _requestRegionSelection() {
    _sendCommand({'cmd': 'select_region'});
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
    _channel.sink.add(jsonEncode({'batch': batch}));
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
    if (e.kind == PointerDeviceKind.invertedStylus || _eraserMode) buttons = 32;

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
    _activePointerIds.add(e.pointer);
    _pointerPositions[e.pointer] = e.localPosition;
    
    if (_navbarExpanded || _showPressureSlider) {
      setState(() {
        _navbarExpanded = false;
        _showPressureSlider = false;
      });
    }

    if (_activePointerIds.length == 1) {
      _isFirstStroke = true;
      final evt = _pointerToEvent(e, 'down');
      if (evt != null) _queueEvent(evt);
    } else {
      if (_activePointerIds.length == 2) {
        final evt = _pointerToEvent(e, 'up');
        if (evt != null) _queueEvent(evt);
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent e) {
    if (!_activePointerIds.contains(e.pointer)) return;
    _pointerPositions[e.pointer] = e.localPosition;

    if (_activePointerIds.length == 1) {
      final evt = _pointerToEvent(e, 'move');
      if (evt != null) _queueEvent(evt);
    }
  }

  void _handlePointerUp(PointerUpEvent e) {
    _activePointerIds.remove(e.pointer);
    _pointerPositions.remove(e.pointer);

    if (_activePointerIds.isEmpty) {
      final evt = _pointerToEvent(e, 'up');
      if (evt != null) {
        _queueEvent(evt);
        _flush();
      }
    }
  }

  void _handlePointerCancel(PointerCancelEvent e) {
    _activePointerIds.remove(e.pointer);
    _pointerPositions.remove(e.pointer);
  }

  Offset _getFocalPoint() {
    if (_pointerPositions.isEmpty) return Offset.zero;
    double x = 0;
    double y = 0;
    for (var pos in _pointerPositions.values) {
      x += pos.dx;
      y += pos.dy;
    }
    return Offset(x / _pointerPositions.length, y / _pointerPositions.length);
  }

  double _getSpan() {
    if (_pointerPositions.length < 2) return 0.0;
    final points = _pointerPositions.values.toList();
    return (points[0] - points[1]).distance;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _channelSubscription?.cancel();
    _channel.sink.close();
    super.dispose();
  }

  Widget _buildNavIcon(IconData icon, String tooltip, VoidCallback onTap, [Color? color, Key? key]) {
    return Tooltip(
      message: tooltip,
      child: Material(
        key: key,
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(icon, color: color ?? Theme.of(context).iconTheme.color, size: 24),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Stack(
        children: [
          // Canvas Layer
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (details) {
                _lastGestureScale = 1.0;
              },
              onScaleUpdate: (details) {
                if (_regionModeEnabled && !_regionLocked && details.pointerCount >= 2 && _canvasSize != null) {
                  final scaleDelta = details.scale / _lastGestureScale;
                  _lastGestureScale = details.scale;
                  
                  _sendCommand({
                    'cmd': 'adjust_region',
                    'dx_pixels': details.focalPointDelta.dx,
                    'dy_pixels': details.focalPointDelta.dy,
                    'scale': scaleDelta,
                    'sourceWidth': _canvasSize!.width,
                    'sourceHeight': _canvasSize!.height,
                  });
                }
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerCancel,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                    return Container(
                    width: double.infinity,
                    height: double.infinity,
                    color: Colors.transparent,
                    child: Stack(
                      children: [
                        if (_mirrorFrame != null)
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
                            child: CustomPaint(painter: _GridPainter(theme.dividerColor)),
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
          
          // Floating Navbar
          Positioned(
            top: 8,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        width: _navbarExpanded ? constraints.maxWidth : 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: _navbarExpanded ? theme.colorScheme.surface.withOpacity(0.85) : Colors.transparent,
                          borderRadius: BorderRadius.circular(25),
                          border: _navbarExpanded ? Border.all(color: theme.dividerColor.withOpacity(0.2)) : null,
                        ),
                      );
                    }
                  ),
                  
                  SizedBox(
                    height: 50,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: _navbarExpanded ? 1.0 : 0.5,
                          child: Container(
                            width: 50,
                            alignment: Alignment.center,
                            child: _buildNavIcon(
                              _navbarExpanded ? Icons.close : Icons.chevron_right,
                              'Menu',
                              () {
                                setState(() {
                                  _navbarExpanded = !_navbarExpanded;
                                  if (!_navbarExpanded) _showPressureSlider = false;
                                });
                              },
                              theme.colorScheme.primary
                            ),
                          ),
                        ),
                        
                        if (_navbarExpanded)
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _buildNavIcon(
                                  _regionLocked ? Icons.lock : Icons.lock_open,
                                  'Region Lock',
                                  () {
                                    setState(() => _regionLocked = !_regionLocked);
                                    _sendCommand({'cmd': 'set_region_lock', 'enabled': _regionLocked});
                                  },
                                  _regionLocked ? Colors.redAccent : theme.colorScheme.primary
                                ),
                                _buildNavIcon(
                                  Icons.keyboard,
                                  'Input Panel',
                                  () => setState(() => _keypadEnabled = !_keypadEnabled),
                                  _keypadEnabled ? theme.colorScheme.primary : null
                                ),
                                _buildNavIcon(
                                  Icons.line_weight,
                                  'Pressure',
                                  () => setState(() => _showPressureSlider = !_showPressureSlider),
                                  _showPressureSlider ? theme.colorScheme.primary : null,
                                  _pressureIconKey
                                ),
                                _buildNavIcon(
                                  _eraserMode ? Icons.auto_fix_high : Icons.edit,
                                  'Toggle Tool',
                                  () {
                                    setState(() => _eraserMode = !_eraserMode);
                                  },
                                  _eraserMode ? Colors.redAccent : null
                                ),
                                if (!_connected)
                                  _buildNavIcon(
                                    Icons.refresh,
                                    'Reconnect',
                                    _reconnect,
                                    Colors.orange
                                  ),
                                _buildNavIcon(
                                  Icons.power_settings_new,
                                  'Disconnect',
                                  () => Navigator.pop(context),
                                  Colors.red
                                ),
                                _buildNavIcon(
                                  Icons.undo,
                                  'Undo',
                                  () => _sendCommand({'cmd': 'key', 'keys': ['ctrl', 'z']}),
                                  theme.colorScheme.primary
                                ),
                              ],
                            ),
                          ),
                          
                        if (!_navbarExpanded)
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 300),
                            opacity: 0.5,
                            child: Container(
                              width: 50,
                              alignment: Alignment.center,
                              child: _buildNavIcon(
                                Icons.undo,
                                'Undo',
                                () => _sendCommand({'cmd': 'key', 'keys': ['ctrl', 'z']}),
                                theme.colorScheme.primary
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          if (_navbarExpanded && _showPressureSlider)
            Builder(
              builder: (context) {
                double leftOffset = 160;
                if (_pressureIconKey.currentContext != null) {
                  final RenderBox box = _pressureIconKey.currentContext!.findRenderObject() as RenderBox;
                  final position = box.localToGlobal(Offset.zero);
                  leftOffset = position.dx;
                }
                return Positioned(
                  top: 120, 
                  left: leftOffset, 
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      height: 150,
                      width: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: theme.dividerColor.withOpacity(0.2)),
                      ),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Slider(
                          value: _pressureMultiplier,
                          min: 0.1,
                          max: 3.0,
                          activeColor: theme.colorScheme.primary,
                          onChanged: (val) => setState(() => _pressureMultiplier = val),
                        ),
                      ),
                    ),
                  ),
                );
              }
            ),
            
          if (!_connected && !_reconnecting)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Disconnected', style: TextStyle(color: Colors.white)),
                ),
              ),
            ),
        ],
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
      ..strokeWidth = 1.0;
    const double spacing = 40.0;

    for (double i = 0; i < size.width; i += spacing) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i < size.height; i += spacing) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
