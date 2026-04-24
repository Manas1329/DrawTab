import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'dart:ui';
import 'package:flutter/gestures.dart';



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
  bool _useRelativeCoordinates = true;
  String _status = 'Connected';
  int _flushIntervalMs = 16;

  @override
  void initState() {
    super.initState();
    _serverUri = widget.serverUri;
    _attachChannel(widget.channel);
  }

  void _attachChannel(WebSocketChannel channel) {
    _channel = channel;
    _channelSubscription?.cancel();
    _channelSubscription = _channel.stream.listen(
      (_) {},
      onError: (_) => _handleDisconnect(),
      onDone: () => _handleDisconnect(),
    );
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
        (_) {},
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

  DrawEvent _pointerToEvent(PointerEvent e, String type) {
    final size = _canvasSize ?? MediaQuery.of(context).size;
    final safeWidth = size.width <= 0 ? 1.0 : size.width;
    final safeHeight = size.height <= 0 ? 1.0 : size.height;
    final mappedX = _useRelativeCoordinates
      ? (e.localPosition.dx / safeWidth).clamp(0.0, 1.0)
      : e.localPosition.dx;
    final mappedY = _useRelativeCoordinates
      ? (e.localPosition.dy / safeHeight).clamp(0.0, 1.0)
      : e.localPosition.dy;

    double pressure = e.pressure.clamp(0.0, 1.0);
    if (pressure == 0.0 && type != 'up') pressure = 1.0;
    pressure = (pressure * _pressureMultiplier).clamp(0.0, 1.0);

    final tiltX = (e.tilt * _tiltSensitivity * (e.radiusMajor > 0 ? 1 : 0)).clamp(-90.0, 90.0);
    final tiltY = 0.0;

    final isPen = e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;
    int buttons = 1;
    if (_eraserMode || e.kind == PointerDeviceKind.invertedStylus) buttons = 32; // eraser flag

    return DrawEvent(
      type: type,
      x: mappedX,
      y: mappedY,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      isPen: isPen,
      buttons: buttons,
      timestamp: DateTime.now().microsecondsSinceEpoch,
    );
  }

  void _handlePointerDown(PointerDownEvent e) => _queueEvent(_pointerToEvent(e, 'down'));
  void _handlePointerMove(PointerMoveEvent e) => _queueEvent(_pointerToEvent(e, 'move'));
  void _handlePointerUp(PointerUpEvent e) {
    _queueEvent(_pointerToEvent(e, 'up'));
    _flush(); // force flush on up for responsiveness
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _channelSubscription?.cancel();
    _channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(),
            Expanded(
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
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1117),
                        border: Border.all(
                          color: _connected
                              ? const Color(0xFF6C63FF).withOpacity(0.4)
                              : Colors.red.withOpacity(0.4),
                          width: 1.5,
                        ),
                      ),
                      child: Stack(
                        children: [
                          CustomPaint(painter: _GridPainter(), size: Size.infinite),
                          Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.touch_app_outlined,
                                    size: 40,
                                    color: Colors.white.withOpacity(0.08)),
                                const SizedBox(height: 8),
                                Text('Draw here',
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.08),
                                        fontSize: 18)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final flushLabel = '${(1000 / _flushIntervalMs).round()}Hz';
    final mappingModeLabel = _useRelativeCoordinates ? 'Relative' : 'Absolute';

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.08))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.draw, color: Color(0xFF6C63FF), size: 20),
            const SizedBox(width: 8),
            const Text('DrawTab', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(width: 16),
            _ToolBtn(
              icon: _eraserMode ? Icons.auto_fix_high : Icons.brush,
              active: _eraserMode,
              tooltip: 'Eraser',
              onTap: () => setState(() => _eraserMode = !_eraserMode),
            ),
            const SizedBox(width: 4),
            _ToolBtn(
              icon: _useRelativeCoordinates ? Icons.percent : Icons.straighten,
              active: !_useRelativeCoordinates,
              tooltip: 'Mapping: $mappingModeLabel',
              onTap: () => setState(() => _useRelativeCoordinates = !_useRelativeCoordinates),
            ),
            const SizedBox(width: 4),
            Text(
              mappingModeLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(width: 8),
            _SliderTool(
              icon: Icons.compress,
              value: _pressureMultiplier,
              min: 0.5,
              max: 2.0,
              tooltip: 'Pressure: ${_pressureMultiplier.toStringAsFixed(1)}x',
              onChanged: (v) => setState(() => _pressureMultiplier = v),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<int>(
              tooltip: 'Flush rate: $flushLabel',
              onSelected: _setFlushInterval,
              itemBuilder: (context) => const [
                PopupMenuItem(value: 8, child: Text('120 Hz')),
                PopupMenuItem(value: 12, child: Text('83 Hz')),
                PopupMenuItem(value: 16, child: Text('60 Hz')),
                PopupMenuItem(value: 20, child: Text('50 Hz')),
                PopupMenuItem(value: 25, child: Text('40 Hz')),
              ],
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined, size: 16, color: Colors.white54),
                    const SizedBox(width: 6),
                    Text(flushLabel, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(width: 2),
                    const Icon(Icons.arrow_drop_down, size: 18, color: Colors.white54),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _connected
                    ? const Color(0xFF1DB954).withOpacity(0.15)
                    : Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _connected
                      ? const Color(0xFF1DB954).withOpacity(0.5)
                      : Colors.red.withOpacity(0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _connected ? const Color(0xFF1DB954) : Colors.red,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(_status,
                      style: TextStyle(
                          fontSize: 12,
                          color: _connected ? const Color(0xFF1DB954) : Colors.red)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: _reconnecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                    )
                  : const Icon(Icons.refresh, size: 20, color: Colors.white54),
              tooltip: 'Reconnect',
              onPressed: _reconnecting ? null : _reconnect,
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: Colors.white54),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  const _ToolBtn({required this.icon, required this.active, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
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
          Icon(icon, size: 16, color: Colors.white38),
          SizedBox(
            width: 80,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
