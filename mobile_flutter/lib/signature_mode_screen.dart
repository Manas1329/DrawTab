import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SignatureModeScreen extends StatefulWidget {
  final void Function(Map<String, dynamic>) sendCommand;
  final Stream<dynamic> messageStream;

  const SignatureModeScreen({
    super.key,
    required this.sendCommand,
    required this.messageStream,
  });

  @override
  State<SignatureModeScreen> createState() => _SignatureModeScreenState();
}

class _SignatureModeScreenState extends State<SignatureModeScreen> {
  bool _palmRejection = false;
  bool _smoothing = true;
  bool _pressureOptimized = true;

  // Smoothing algorithm state
  double _lastX = 0;
  double _lastY = 0;
  bool _isFirstStroke = true;
  final double _smoothAlpha = 0.3; // Lower means smoother

  Uint8List? _previewImage;
  Map<String, dynamic>? _selectedRegion;
  List<Map<String, dynamic>> _savedRegions = [];
  bool _isDrawing = false;
  Size _canvasSize = Size.zero;

  List<Map<String, dynamic>> _eventBuffer = [];
  Timer? _flushTimer;

  @override
  void initState() {
    super.initState();
    _loadRegions();
    widget.messageStream.listen(_handleMessage);
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  void _handleMessage(dynamic message) {
    if (!mounted) return;
    try {
      final data = jsonDecode(message);
      if (data['cmd'] == 'region_preview' && data['image_b64'] != null) {
        setState(() {
          _previewImage = base64Decode(data['image_b64']);
        });
      } else if (data['cmd'] == 'region_selected' && data['region'] != null) {
        setState(() {
          _selectedRegion = data['region'];
        });
        _requestPreview();
        _promptSaveRegion();
      }
    } catch (e) {
      debugPrint("Error parsing message in signature screen: $e");
    }
  }

  Future<void> _loadRegions() async {
    final prefs = await SharedPreferences.getInstance();
    final regionsStr = prefs.getString('signature_regions');
    if (regionsStr != null) {
      try {
        final List<dynamic> decoded = jsonDecode(regionsStr);
        setState(() {
          _savedRegions = decoded.cast<Map<String, dynamic>>();
        });
      } catch (e) {
        debugPrint("Failed to load signature regions: $e");
      }
    }

    if (_savedRegions.isEmpty && _selectedRegion == null && mounted) {
      widget.sendCommand({'cmd': 'select_region'});
    }
  }

  Future<void> _saveRegions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('signature_regions', jsonEncode(_savedRegions));
  }

  void _requestPreview() {
    if (_selectedRegion != null) {
      widget.sendCommand({
        'cmd': 'get_region_preview',
        'region': _selectedRegion,
      });
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
          decoration: const InputDecoration(
            labelText: 'Region Name (e.g. Word Document)',
            labelStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
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

  Point<double> _applySmoothing(double x, double y) {
    if (!_smoothing || _isFirstStroke) {
      _lastX = x;
      _lastY = y;
      _isFirstStroke = false;
      return Point(x, y);
    }
    _lastX = _lastX + _smoothAlpha * (x - _lastX);
    _lastY = _lastY + _smoothAlpha * (y - _lastY);
    return Point(_lastX, _lastY);
  }

  double _optimizePressure(double rawPressure) {
    if (!_pressureOptimized) return rawPressure;
    return pow(rawPressure, 0.7).toDouble();
  }

  void _queueEvent(Map<String, dynamic> eventData) {
    _eventBuffer.add(eventData);
    _flushTimer ??= Timer(const Duration(milliseconds: 8), _flush);
  }

  void _flush() {
    if (_eventBuffer.isNotEmpty) {
      widget.sendCommand({'cmd': 'batch', 'batch': _eventBuffer});
      _eventBuffer.clear();
    }
    _flushTimer = null;
  }

  void _sendDrawEvent(String type, PointerEvent e) {
    if (_palmRejection && e.kind != PointerDeviceKind.stylus) {
      // Ignore finger/palm inputs if palm rejection is on
      return;
    }

    final safeWidth = _canvasSize.width <= 0 ? 1.0 : _canvasSize.width;
    final safeHeight = _canvasSize.height <= 0 ? 1.0 : _canvasSize.height;
    
    double rawX = (e.localPosition.dx / safeWidth).clamp(0.0, 1.0);
    double rawY = (e.localPosition.dy / safeHeight).clamp(0.0, 1.0);

    if (type == 'down') _isFirstStroke = true;

    final smoothed = _applySmoothing(rawX, rawY);
    final optPressure = _optimizePressure(e.pressure);

    final eventData = {
      'type': type,
      'x': smoothed.x,
      'y': smoothed.y,
      'pressure': optPressure,
      'normalized': true,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };

    _queueEvent(eventData);
    if (type == 'up') _flush();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top options bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFF1A1A2E),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
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
                        widget.sendCommand({
                          'cmd': 'region_mode',
                          'enabled': true,
                        });
                        _requestPreview();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.crop, color: Color(0xFF6C63FF)),
                tooltip: 'Select New Region',
                onPressed: () {
                  widget.sendCommand({'cmd': 'select_region'});
                },
              ),
            ],
          ),
        ),
        
        // Toggles
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: const Color(0xFF0F0F1A),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildToggle('Palm Rejection', _palmRejection, (v) => setState(() => _palmRejection = v)),
                _buildToggle('Smoothing', _smoothing, (v) => setState(() => _smoothing = v)),
                _buildToggle('Pressure Opt', _pressureOptimized, (v) => setState(() => _pressureOptimized = v)),
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white54, size: 18),
                  tooltip: 'Refresh Preview',
                  onPressed: _requestPreview,
                ),
              ],
            ),
          ),
        ),

        // Live Preview Panel
        if (_previewImage != null)
          Container(
            height: 120,
            width: double.infinity,
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                _previewImage!,
                fit: BoxFit.contain,
              ),
            ),
          ),

        // Signature Canvas
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                return Listener(
                  onPointerDown: (e) => _sendDrawEvent('down', e),
                  onPointerMove: (e) => _sendDrawEvent('move', e),
                  onPointerUp: (e) => _sendDrawEvent('up', e),
                  child: Container(
                    color: Colors.transparent,
                    child: Center(
                      child: Text(
                        'Sign Here',
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.05),
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilterChip(
        label: Text(label, style: TextStyle(color: value ? Colors.white : Colors.white54, fontSize: 12)),
        selected: value,
        onSelected: onChanged,
        backgroundColor: Colors.white.withValues(alpha: 0.05),
        selectedColor: const Color(0xFF6C63FF).withValues(alpha: 0.4),
        checkmarkColor: Colors.white,
      ),
    );
  }
}
