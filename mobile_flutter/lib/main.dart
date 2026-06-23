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


// void main() {
//   SystemChrome.setPreferredOrientations([
//     DeviceOrientation.landscapeLeft,
//     DeviceOrientation.landscapeRight,
//   ]);
//   runApp(const DrawTabApp());
// }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(DrawTabApp());
}

class DrawTabApp extends StatelessWidget {
  const DrawTabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DrawTab',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6C63FF),
          surface: const Color(0xFF1A1A2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
      ),
      home: const ConnectionScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─── CONNECTION SCREEN ───────────────────────────────────────────────────────

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
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
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => DrawingScreen(serverUri: uri, channel: channel),
        ),
      );
    } catch (e) {
      setState(() {
        _status = 'Connection failed: $e';
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.draw_outlined, size: 48, color: Color(0xFF6C63FF)),
              const SizedBox(height: 12),
              const Text('DrawTab', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const Text('Connect to Desktop', style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 28),
              _buildTextField(_ipController, 'Desktop IP Address', Icons.computer),
              const SizedBox(height: 12),
              _buildTextField(_portController, 'Port (default 8765)', Icons.wifi),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _connecting ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _connecting
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Connect', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(_status, style: TextStyle(
                  color: _status.startsWith('Connection failed') ? Colors.redAccent : Colors.white54,
                  fontSize: 13,
                )),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        prefixIcon: Icon(icon, color: const Color(0xFF6C63FF), size: 20),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF6C63FF)),
        ),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
      ),
    );
  }
}

// ─── INPUT EVENT MODEL ────────────────────────────────────────────────────────

class DrawEvent {
  final String type;   // 'down' | 'move' | 'up' | 'hover'
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
  final int buttons;   // bitmask: 1=primary, 2=secondary, 4=middle
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
    'type': type,
    'x': double.parse(x.toStringAsFixed(4)),
    'y': double.parse(y.toStringAsFixed(4)),
    'normalized': normalized,
    'sourceWidth': double.parse(sourceWidth.toStringAsFixed(2)),
    'sourceHeight': double.parse(sourceHeight.toStringAsFixed(2)),
    'pressure': double.parse(pressure.toStringAsFixed(4)),
    'tiltX': double.parse(tiltX.toStringAsFixed(2)),
    'tiltY': double.parse(tiltY.toStringAsFixed(2)),
    'twist': double.parse(twist.toStringAsFixed(2)),
    'isPen': isPen,
    'buttons': buttons,
    'ts': timestamp,
  };
}

// ─── DRAWING SCREEN ───────────────────────────────────────────────────────────

class DrawingScreen extends StatefulWidget {
  final Uri serverUri;
  final WebSocketChannel channel;
  const DrawingScreen({super.key, required this.serverUri, required this.channel});

  @override
  State<DrawingScreen> createState() => _DrawingScreenState();
}

class _DrawingScreenState extends State<DrawingScreen> {
  final List<DrawEvent> _eventBuffer = [];
  Timer? _flushTimer;
  StreamSubscription? _channelSubscription;
  late WebSocketChannel _channel;
  late Uri _serverUri;
  bool _connected = true;
  bool _reconnecting = false;
  Size? _canvasSize;
  bool _showMirror = false;
  double _pressureMultiplier = 1.0;
  double _tiltSensitivity = 1.0;
  bool _eraserMode = false;
  bool _regionModeEnabled = false;
  bool _regionSelectionPending = false;
  Map<String, dynamic>? _selectedRegion;
  String _status = 'Connected';
  int _flushIntervalMs = 8;
  int _currentIndex = 0;
  String _eraserShortcut = 'e';
  String _drawShortcut = 'b';
  final StreamController<dynamic> _messageBus = StreamController<dynamic>.broadcast();

  // Smoothing and global options
  bool _palmRejection = false;
  bool _smoothing = true;
  bool _pressureOptimized = true;
  double _lastX = 0;
  double _lastY = 0;
  bool _isFirstStroke = true;
  final double _smoothAlpha = 0.3;

  Uint8List? _previewImage;
  Uint8List? _mirrorFrame;
  List<Map<String, dynamic>> _savedRegions = [];

  @override
  void initState() {
    super.initState();
    _loadShortcuts();
    _serverUri = widget.serverUri;
    _attachChannel(widget.channel);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendCommand({'cmd': 'get_state'});
    });
  }

  Future<void> _loadShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _eraserShortcut = prefs.getString('eraser_shortcut') ?? 'e';
      _drawShortcut = prefs.getString('draw_shortcut') ?? 'b';
    });

    final regionsStr = prefs.getString('signature_regions');
    if (regionsStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(regionsStr);
        setState(() {
          _savedRegions = decoded.cast<Map<String, dynamic>>();
        });
      } catch (e) {
        debugPrint("Failed to load regions: $e");
      }
    }
  }

  Future<void> _saveRegions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('signature_regions', jsonEncode(_savedRegions));
  }

  void _attachChannel(WebSocketChannel channel) {
    _channel = channel;
    _channelSubscription?.cancel();
    _channelSubscription = _channel.stream.listen(
      _handleServerMessage,
      onError: (_) => _handleDisconnect(),
      onDone: () => _handleDisconnect(),
    );
  }

  void _sendCommand(Map<String, dynamic> command) {
    if (!_connected) {
      return;
    }

    try {
      _channel.sink.add(jsonEncode(command));
    } catch (_) {
      setState(() {
        _connected = false;
        _status = 'Disconnected';
      });
    }
  }

  void _handleServerMessage(dynamic message) {
    _messageBus.add(message);
    if (!mounted) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      if (decoded['cmd'] == 'mirror_frame' && decoded['image_b64'] != null) {
        setState(() {
          _mirrorFrame = base64Decode(decoded['image_b64']);
        });
      } else if (decoded['cmd'] == 'region_preview' && decoded['image_b64'] != null) {
        setState(() {
          _previewImage = base64Decode(decoded['image_b64']);
        });
      } else if (decoded['cmd'] == 'region_selected' && decoded['region'] != null) {
        setState(() {
          _selectedRegion = decoded['region'];
        });
        _requestPreview();
        _promptSaveRegion();
      } else if (decoded['cmd'] == 'region_state') {
        final region = decoded['region'];
        setState(() {
          _regionModeEnabled = decoded['regionModeEnabled'] == true;
          _selectedRegion = region is Map ? Map<String, dynamic>.from(region) : null;
          _regionSelectionPending = false;
          _status = _regionModeEnabled
              ? (_selectedRegion == null ? 'Region mode on' : 'Region selected')
              : 'Connected';
        });
      }
    } catch (_) {
      // Ignore non-JSON server messages.
    }
  }

  void _requestPreview() {
    if (_selectedRegion != null) {
      _sendCommand({'cmd': 'get_region_preview', 'region': _selectedRegion});
    }
  }

  Future<void> _promptSaveRegion() async {
    if (_selectedRegion == null) return;
    final nameCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Save Signature Region', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: nameCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(labelText: 'Region Name', labelStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () {
              setState(() {
                _savedRegions.add({
                  'name': nameCtrl.text.isNotEmpty ? nameCtrl.text : 'Untitled Region',
                  'region': _selectedRegion,
                });
              });
              _saveRegions();
              Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: Color(0xFF6C63FF))),
          ),
        ],
      ),
    );
  }

  String _regionSummary() {
    final region = _selectedRegion;
    if (region == null) {
      return 'Full screen';
    }

    final left = region['left'] ?? 0;
    final top = region['top'] ?? 0;
    final width = region['width'] ?? 0;
    final height = region['height'] ?? 0;
    return 'Region ${width}x${height} @ ${left},${top}';
  }

  void _setRegionMode(bool enabled) {
    setState(() {
      _regionModeEnabled = enabled;
      _status = enabled ? 'Region mode on' : 'Connected';
    });
    _sendCommand({'cmd': 'region_mode', 'enabled': enabled});

    if (enabled) {
      _requestRegionSelection();
    }
  }

  void _requestRegionSelection() {
    if (!_connected || _regionSelectionPending) {
      return;
    }

    setState(() {
      _regionSelectionPending = true;
      _status = 'Selecting region...';
    });
    _sendCommand({'cmd': 'select_region'});
  }

  void _handleDisconnect() {
    if (!mounted || !_connected) {
      return;
    }

    _flushTimer?.cancel();
    _flushTimer = null;
    _eventBuffer.clear();
    setState(() {
      _connected = false;
      _regionSelectionPending = false;
      _status = 'Disconnected';
    });
  }

  Future<void> _reconnect() async {
    if (_reconnecting) {
      return;
    }

    setState(() {
      _reconnecting = true;
      _status = 'Reconnecting...';
    });

    _flushTimer?.cancel();
    _flushTimer = null;
    _eventBuffer.clear();

    final previousChannel = _channel;
    final previousSubscription = _channelSubscription;
    final nextChannel = IOWebSocketChannel.connect(
      _serverUri,
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      await nextChannel.ready;
      if (!mounted) {
        await nextChannel.sink.close();
        return;
      }

      _channel = nextChannel;
      _channelSubscription = _channel.stream.listen(
        _handleServerMessage,
        onError: (_) => _handleDisconnect(),
        onDone: () => _handleDisconnect(),
      );

      await previousSubscription?.cancel();
      await previousChannel.sink.close();

      setState(() {
        _connected = true;
        _reconnecting = false;
        _status = 'Connected';
      });
      _sendCommand({'cmd': 'get_state'});
    } catch (e) {
      await nextChannel.sink.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _connected = false;
        _reconnecting = false;
        _status = 'Reconnect failed: $e';
      });
    }
  }

  void _setFlushInterval(int intervalMs) {
    setState(() {
      _flushIntervalMs = intervalMs;
    });

    if (_eventBuffer.isEmpty || !_connected) {
      return;
    }

    _flushTimer?.cancel();
    _flushTimer = Timer(Duration(milliseconds: _flushIntervalMs), _flush);
  }

  // Batch events and flush at a configurable cadence.
  void _queueEvent(DrawEvent evt) {
    _eventBuffer.add(evt);
    _flushTimer ??= Timer(Duration(milliseconds: _flushIntervalMs), _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (_eventBuffer.isEmpty || !_connected) return;

    final batch = {
      'batch': _eventBuffer.map((e) => e.toJson()).toList(),
    };
    try {
      _channel.sink.add(jsonEncode(batch));
    } catch (_) {
      setState(() {
        _connected = false;
        _status = 'Disconnected';
      });
    }
    _eventBuffer.clear();
  }

  DrawEvent? _pointerToEvent(PointerEvent e, String type) {
    if (_palmRejection && e.kind != PointerDeviceKind.stylus) {
      return null;
    }

    final size = _canvasSize ?? MediaQuery.of(context).size;
    final safeWidth = size.width <= 0 ? 1.0 : size.width;
    final safeHeight = size.height <= 0 ? 1.0 : size.height;
    final mappedX = (e.localPosition.dx / safeWidth).clamp(0.0, 1.0);
    final mappedY = (e.localPosition.dy / safeHeight).clamp(0.0, 1.0);

    if (type == 'down') _isFirstStroke = true;

    double finalX = mappedX;
    double finalY = mappedY;

    if (_smoothing) {
      if (_isFirstStroke) {
        _lastX = mappedX;
        _lastY = mappedY;
      } else {
        _lastX = _lastX + _smoothAlpha * (mappedX - _lastX);
        _lastY = _lastY + _smoothAlpha * (mappedY - _lastY);
      }
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
    final tiltY = 0.0;

    final isPen = e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;
    int buttons = 1;
    if (_eraserMode || e.kind == PointerDeviceKind.invertedStylus) buttons = 32; // eraser flag

    return DrawEvent(
      type: type,
      x: finalX,
      y: finalY,
      normalized: true,
      sourceWidth: safeWidth,
      sourceHeight: safeHeight,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      isPen: isPen,
      buttons: buttons,
      timestamp: DateTime.now().microsecondsSinceEpoch,
    );
  }

  void _handlePointerDown(PointerDownEvent e) {
    final evt = _pointerToEvent(e, 'down');
    if (evt != null) _queueEvent(evt);
  }
  void _handlePointerMove(PointerMoveEvent e) {
    final evt = _pointerToEvent(e, 'move');
    if (evt != null) _queueEvent(evt);
  }
  void _handlePointerUp(PointerUpEvent e) {
    final evt = _pointerToEvent(e, 'up');
    if (evt != null) {
      _queueEvent(evt);
      _flush(); // force flush on up for responsiveness
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _channelSubscription?.cancel();
    _channel.sink.close();
    _messageBus.close();
    super.dispose();
  }
  void _setMode(int mode) {
    setState(() {
      _currentIndex = mode;
      if (mode != 3) {
        _mirrorFrame = null;
      }
    });
    _sendCommand({
      'cmd': 'set_mirror_mode',
      'enabled': mode == 3,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
            Positioned.fill(
              child: _buildCurrentMode(),
            ),
            Positioned(
              top: 16,
              left: 16,
              child: Builder(
                builder: (context) {
                  return Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2E).withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.menu, color: Colors.white),
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      tooltip: 'Menu',
                    ),
                  );
                }
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E).withValues(alpha: 0.8),
                  shape: BoxShape.circle,
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                ),
                child: IconButton(
                  icon: const Icon(Icons.undo, color: Colors.white),
                  onPressed: () {
                    _sendCommand({
                      'cmd': 'key',
                      'keys': ['ctrl', 'z']
                    });
                  },
                  tooltip: 'Undo (Ctrl+Z)',
                ),
              ),
            ),
          ],
        ),
      );
  }

  Widget _buildCurrentMode() {
    if (_currentIndex == 1) {
      return InputPanelScreen(sendCommand: _sendCommand);
    } else {
      return Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
            return Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                border: Border.all(
                  color: _connected
                      ? const Color(0xFF6C63FF).withValues(alpha: 0.4)
                      : Colors.red.withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Stack(
                children: [
                  if (_currentIndex == 3 && _mirrorFrame != null)
                    Positioned.fill(
                      child: Image.memory(
                        _mirrorFrame!,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  if (_currentIndex != 3) ...[
                    CustomPaint(painter: _GridPainter(), size: Size.infinite),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _currentIndex == 2 ? Icons.edit_document : Icons.touch_app_outlined,
                            size: 40,
                            color: Colors.white.withValues(alpha: 0.08)
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _currentIndex == 2 ? 'Sign Here' : 'Draw here',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.08),
                                fontSize: 18)
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      );
    }
  }

  void _showSettingsDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Drawing Settings', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Palm Rejection', style: TextStyle(color: Colors.white)),
                  value: _palmRejection,
                  onChanged: (v) { setState(() => _palmRejection = v); setModalState((){}); },
                ),
                SwitchListTile(
                  title: const Text('Stroke Smoothing', style: TextStyle(color: Colors.white)),
                  value: _smoothing,
                  onChanged: (v) { setState(() => _smoothing = v); setModalState((){}); },
                ),
                SwitchListTile(
                  title: const Text('Pressure Optimization', style: TextStyle(color: Colors.white)),
                  value: _pressureOptimized,
                  onChanged: (v) { setState(() => _pressureOptimized = v); setModalState((){}); },
                ),
                const Divider(color: Colors.white24),
                const Text('Active Region', style: TextStyle(color: Colors.white, fontSize: 16)),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<Map<String, dynamic>>(
                        dropdownColor: const Color(0xFF1A1A2E),
                        isExpanded: true,
                        hint: const Text('Select a saved region', style: TextStyle(color: Colors.white54)),
                        value: _savedRegions.where((e) => e['region'] == _selectedRegion).firstOrNull,
                        items: _savedRegions.map((item) {
                          return DropdownMenuItem<Map<String, dynamic>>(
                            value: item,
                            child: Text(item['name'], style: const TextStyle(color: Colors.white)),
                          );
                        }).toList(),
                        onChanged: (item) {
                          if (item != null) {
                            setState(() {
                              _selectedRegion = item['region'];
                            });
                            setModalState((){});
                            _sendCommand({'cmd': 'region_mode', 'enabled': true});
                            _requestPreview();
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.crop, color: Color(0xFF6C63FF)),
                      onPressed: () {
                        Navigator.pop(context);
                        _sendCommand({'cmd': 'select_region'});
                      },
                    ),
                  ],
                ),
                if (_previewImage != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    height: 120,
                    width: double.infinity,
                    decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                    child: Image.memory(_previewImage!, fit: BoxFit.contain),
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          );
        });
      },
    );
  }
  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF1A1A2E),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              alignment: Alignment.centerLeft,
              child: const Text(
                'DrawTab Options',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: Icon(Icons.draw, color: _currentIndex == 0 ? const Color(0xFF6C63FF) : Colors.white54),
                    title: const Text('Draw Mode', style: TextStyle(color: Colors.white)),
                    selected: _currentIndex == 0,
                    onTap: () {
                      _setMode(0);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.keyboard, color: _currentIndex == 1 ? const Color(0xFF6C63FF) : Colors.white54),
                    title: const Text('Keypad Mode', style: TextStyle(color: Colors.white)),
                    selected: _currentIndex == 1,
                    onTap: () {
                      _setMode(1);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.edit_document, color: _currentIndex == 2 ? const Color(0xFF6C63FF) : Colors.white54),
                    title: const Text('Sign Mode', style: TextStyle(color: Colors.white)),
                    selected: _currentIndex == 2,
                    onTap: () {
                      _setMode(2);
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.connected_tv, color: _currentIndex == 3 ? const Color(0xFF6C63FF) : Colors.white54),
                    title: const Text('Mirror Mode', style: TextStyle(color: Colors.white)),
                    selected: _currentIndex == 3,
                    onTap: () {
                      _setMode(3);
                      Navigator.pop(context);
                    },
                  ),
                  const Divider(color: Colors.white24),
                  ListTile(
                    leading: const Icon(Icons.settings, color: Colors.white54),
                    title: const Text('Settings', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showSettingsDialog();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.undo, color: Colors.white54),
                    title: const Text('Undo (Ctrl+Z)', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      _sendCommand({
                        'cmd': 'key',
                        'keys': ['ctrl', 'z']
                      });
                      Navigator.pop(context);
                    },
                  ),
                  ListTile(
                    leading: Icon(_eraserMode ? Icons.auto_fix_high : Icons.brush, color: _eraserMode ? const Color(0xFF6C63FF) : Colors.white54),
                    title: Text('Toggle Tool [$_eraserShortcut/$_drawShortcut]', style: const TextStyle(color: Colors.white)),
                    subtitle: const Text('Long press to configure', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    onTap: () {
                      setState(() {
                        _eraserMode = !_eraserMode;
                      });
                      _sendCommand({
                        'cmd': 'key',
                        'keys': [_eraserMode ? _eraserShortcut : _drawShortcut]
                      });
                    },
                    onLongPress: _showShortcutConfigDialog,
                  ),
                  ListTile(
                    leading: Icon(_regionModeEnabled ? Icons.crop_square : Icons.open_with, color: _regionModeEnabled ? const Color(0xFF6C63FF) : Colors.white54),
                    title: Text('Region mode: ${_regionModeEnabled ? _regionSummary() : 'Full screen'}', style: const TextStyle(color: Colors.white)),
                    onTap: () => _setRegionMode(!_regionModeEnabled),
                  ),
                  ListTile(
                    leading: const Icon(Icons.select_all, color: Colors.white54),
                    title: const Text('Select desktop region', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _requestRegionSelection();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pressure: ${_pressureMultiplier.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white)),
                        Slider(
                          value: _pressureMultiplier,
                          min: 0.5,
                          max: 2.0,
                          activeColor: const Color(0xFF6C63FF),
                          inactiveColor: Colors.white24,
                          onChanged: (v) => setState(() => _pressureMultiplier = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white24),
            ListTile(
              leading: const Icon(Icons.exit_to_app, color: Colors.redAccent),
              title: const Text('Disconnect', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(context);
                Navigator.pop(context); // Go back to connect screen
              },
            ),
            ListTile(
              leading: Icon(_connected ? Icons.cloud_done : Icons.cloud_off, color: _connected ? const Color(0xFF1DB954) : Colors.red),
              title: Text('Status: $_status', style: const TextStyle(color: Colors.white)),
              trailing: _reconnecting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                  : IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white54),
                      onPressed: _reconnecting ? null : _reconnect,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showShortcutConfigDialog() {
    final eraserCtrl = TextEditingController(text: _eraserShortcut);
    final drawCtrl = TextEditingController(text: _drawShortcut);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Configure Tool Shortcuts', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: drawCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Draw Tool Shortcut (e.g. p, b)',
                labelStyle: TextStyle(color: Colors.white54),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: eraserCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Eraser Tool Shortcut (e.g. e)',
                labelStyle: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              final newDraw = drawCtrl.text.trim();
              final newEraser = eraserCtrl.text.trim();
              if (newDraw.isNotEmpty && newEraser.isNotEmpty) {
                await prefs.setString('draw_shortcut', newDraw);
                await prefs.setString('eraser_shortcut', newEraser);
                setState(() {
                  _drawShortcut = newDraw;
                  _eraserShortcut = newEraser;
                });
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: Color(0xFF6C63FF))),
          ),
        ],
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ToolBtn({required this.icon, required this.active, required this.tooltip, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF6C63FF).withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 18,
              color: active ? const Color(0xFF6C63FF) : Colors.white54),
        ),
      ),
    );
  }
}

class _SliderTool extends StatelessWidget {
  final IconData icon;
  final double value, min, max;
  final String tooltip;
  final ValueChanged<double> onChanged;
  const _SliderTool({required this.icon, required this.value, required this.min, required this.max, required this.tooltip, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.white38),
          SizedBox(
            width: 60,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                activeTrackColor: const Color(0xFF6C63FF),
                thumbColor: const Color(0xFF6C63FF),
                inactiveTrackColor: Colors.white12,
                overlayColor: const Color(0xFF6C63FF).withOpacity(0.2),
              ),
              child: Slider(value: value, min: min, max: max, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.03)
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
