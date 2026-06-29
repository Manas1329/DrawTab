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
      home: const AuthHubScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum UserTier { free, pro }

class MockAuthService {
  Future<UserTier?> signInWithGoogle(BuildContext context) async {
    return await showModalBottomSheet<UserTier>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Choose an Account',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.blue, child: Text('F', style: TextStyle(color: Colors.white))),
              title: const Text('Free User'),
              subtitle: const Text('free.user@gmail.com'),
              onTap: () => Navigator.pop(context, UserTier.free),
            ),
            ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.purple, child: Text('P', style: TextStyle(color: Colors.white))),
              title: const Text('Pro User'),
              subtitle: const Text('pro.user@gmail.com'),
              onTap: () => Navigator.pop(context, UserTier.pro),
            ),
          ],
        ),
      ),
    );
  }

  Future<UserTier?> signInWithEmail(String email, String password) async {
    await Future.delayed(const Duration(seconds: 1));
    if (email == 'free@drawtab.com' && password == 'password123') return UserTier.free;
    if (email == 'pro@drawtab.com' && password == 'password123') return UserTier.pro;
    return null;
  }
}

class MockInAppPurchaseService {
  Future<bool> buyPro() async {
    // Simulate native IAP checkout sheet delay
    await Future.delayed(const Duration(milliseconds: 1500));
    return true; // Simulate successful purchase
  }
}

class MockAdMobService {
  Future<void> showRewardedVideo(VoidCallback onEarnedReward) async {
    // Simulate loading and watching a rewarded video ad
    await Future.delayed(const Duration(seconds: 3));
    onEarnedReward();
  }
}

class AuthHubScreen extends StatefulWidget {
  const AuthHubScreen({super.key});

  @override
  State<AuthHubScreen> createState() => _AuthHubScreenState();
}

class _AuthHubScreenState extends State<AuthHubScreen> {
  final _authService = MockAuthService();
  bool _isLoading = false;
  bool _showEmailForm = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _handleAuth(Future<UserTier?> Function() authMethod) async {
    setState(() => _isLoading = true);
    final tier = await authMethod();
    if (tier != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isAuthenticated', true);
      await prefs.setBool('isSubscribed', tier == UserTier.pro);
      
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainMenuScreen()),
      );
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid credentials. Use free@drawtab.com or pro@drawtab.com with password123')),
        );
      }
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121214), // Deep slate background
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.draw, size: 80, color: Color(0xFF7C4DFF)),
              const SizedBox(height: 16),
              const Text(
                'DrawTab Authentication',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              if (_isLoading)
                const CircularProgressIndicator(color: Color(0xFF7C4DFF))
              else ...[
                _buildAuthButton(
                  'Continue with Google',
                  Icons.login,
                  () => _handleAuth(() => _authService.signInWithGoogle(context)),
                ),
                const SizedBox(height: 32),
                const Text(
                  'OR',
                  style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 32),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  height: _showEmailForm ? 220 : 56,
                  child: _showEmailForm
                      ? Column(
                          children: [
                            TextField(
                              controller: _emailController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Email',
                                hintStyle: const TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: const Color(0xFF1A1A1E),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Password',
                                hintStyle: const TextStyle(color: Colors.white54),
                                filled: true,
                                fillColor: const Color(0xFF1A1A1E),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildAuthButton(
                              'Sign In',
                              Icons.email,
                              () => _handleAuth(() => _authService.signInWithEmail(
                                _emailController.text,
                                _passwordController.text,
                              )),
                            ),
                          ],
                        )
                      : _buildAuthButton(
                          'Continue with Email',
                          Icons.mail_outline,
                          () => setState(() => _showEmailForm = true),
                          isOutlined: true,
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuthButton(String text, IconData icon, VoidCallback onPressed, {bool isOutlined = false}) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isOutlined ? Colors.transparent : const Color(0xFF7C4DFF),
          foregroundColor: Colors.white,
          elevation: isOutlined ? 0 : 4,
          side: isOutlined ? BorderSide(color: Colors.white.withOpacity(0.2)) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onPressed: onPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 12),
            Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
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

  bool _isAuthenticated = false;
  UserTier _userTier = UserTier.free;
  DateTime? _sessionExpiry;
  Timer? _sessionTimer;

  int get _sessionSecondsRemaining {
    if (_sessionExpiry == null) return 0;
    final diff = _sessionExpiry!.difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  // Hooks for state management (e.g. Riverpod/Bloc)
  void _refreshAuthToken() {
    // Implement token refresh logic here without disrupting the view
  }

  final _iapService = MockInAppPurchaseService();
  final _adMobService = MockAdMobService();

  @override
  void initState() {
    super.initState();
    _loadMonetizationState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  Future<void> _loadMonetizationState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isAuthenticated = prefs.getBool('isAuthenticated') ?? false;
      final isSubbed = prefs.getBool('isSubscribed') ?? false;
      _userTier = isSubbed ? UserTier.pro : UserTier.free;
      
      final expiryStr = prefs.getString('sessionExpiry');
      if (expiryStr != null) {
        _sessionExpiry = DateTime.parse(expiryStr);
      } else {
        _sessionExpiry = DateTime.now();
      }
    });
    _startSessionTimer();
  }

  void _startSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_userTier == UserTier.pro) {
        timer.cancel();
        return;
      }
      // Rebuild UI to reflect the calculated _sessionSecondsRemaining
      setState(() {});
    });
  }

  Future<void> _handleBuyPro() async {
    final bool? confirm = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const MockPaymentGatewayScreen()),
    );

    if (confirm != true) return;

    setState(() => _status = 'Initializing Purchase...');
    final success = await _iapService.buyPro();
    if (success && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isSubscribed', true);
      setState(() {
        _userTier = UserTier.pro;
        _status = '';
      });
    } else {
      if (mounted) setState(() => _status = 'Purchase Failed');
    }
  }

  Future<void> _handleWatchAd() async {
    setState(() => _status = 'Loading Ad...');
    await _adMobService.showRewardedVideo(() async {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        if (_sessionExpiry == null || _sessionExpiry!.isBefore(DateTime.now())) {
           _sessionExpiry = DateTime.now().add(const Duration(minutes: 30));
        } else {
           _sessionExpiry = _sessionExpiry!.add(const Duration(minutes: 30));
        }
        
        final maxExpiry = DateTime.now().add(const Duration(hours: 2));
        if (_sessionExpiry!.isAfter(maxExpiry)) {
           _sessionExpiry = maxExpiry;
        }
        
        _status = '';
      });
      await prefs.setString('sessionExpiry', _sessionExpiry!.toIso8601String());
      _startSessionTimer();
    });
  }
  
  Future<void> _resetTimer() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sessionExpiry = DateTime.now();
    });
    await prefs.setString('sessionExpiry', _sessionExpiry!.toIso8601String());
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
          builder: (_) => DrawingScreen(serverUri: uri, channel: channel, isPro: _userTier == UserTier.pro),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isPro = _userTier == UserTier.pro;

    return Scaffold(
      backgroundColor: const Color(0xFF1B1B22), // Matching the dark outer background in Figma
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Top Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'DrawTab',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      if (!isPro) ...[
                        _buildCircleIcon(Icons.undo, _resetTimer), // Reusing reset timer logic for the undo button
                        const SizedBox(width: 12),
                      ],
                      _buildCircleIcon(isDark ? Icons.light_mode : Icons.dark_mode, () => DrawTabApp.of(context)?.toggleTheme()),
                      const SizedBox(width: 12),
                      _buildCircleIcon(Icons.settings, () {}),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Main Card
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF23253A), // Dark navy card background
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF7C4DFF).withValues(alpha: 0.3)),
                  ),
                  child: Stack(
                    children: [
                      // Badge
                      Positioned(
                        top: 24,
                        left: 24,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            border: Border.all(color: isPro ? Colors.cyan : Colors.yellow),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            isPro ? 'Pro Tier' : 'FREE TIER',
                            style: TextStyle(
                              color: isPro ? Colors.cyan : Colors.yellow,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      
                      // Center Content
                      Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final isWide = constraints.maxWidth > 500;
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isPro) ...[
                                      Text(
                                        _sessionSecondsRemaining > 0 
                                            ? '${(_sessionSecondsRemaining ~/ 60).toString().padLeft(2, '0')}:${(_sessionSecondsRemaining % 60).toString().padLeft(2, '0')}'
                                            : '00:00',
                                        style: const TextStyle(
                                          fontSize: 48,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      Wrap(
                                        spacing: 16,
                                        runSpacing: 16,
                                        alignment: WrapAlignment.center,
                                        children: [
                                          ElevatedButton.icon(
                                            onPressed: _handleWatchAd,
                                            icon: const Icon(Icons.play_circle_outline),
                                            label: const Text('Watch an Ad\nto add 30 Mins', textAlign: TextAlign.center),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green.shade500,
                                              foregroundColor: Colors.white,
                                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            ),
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: _handleBuyPro,
                                            icon: const Icon(Icons.lock_outline),
                                            label: const Text('Upgrade to\nPro', textAlign: TextAlign.center),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.yellow.shade300,
                                              side: BorderSide(color: Colors.yellow.shade300),
                                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 32),
                                    ],
                                    
                                    // Decorative Line
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Transform.rotate(angle: 3.14/4, child: Container(width: 8, height: 8, color: const Color(0xFF7C4DFF))),
                                        Container(width: isWide ? 400 : 250, height: 2, color: const Color(0xFF7C4DFF)),
                                        Transform.rotate(angle: 3.14/4, child: Container(width: 8, height: 8, color: const Color(0xFF7C4DFF))),
                                      ],
                                    ),
                                    const SizedBox(height: 32),
                                    
                                    // Input & Connect Button
                                    Wrap(
                                      spacing: 16,
                                      runSpacing: 16,
                                      alignment: WrapAlignment.center,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 250,
                                          child: TextField(
                                            controller: _pinController,
                                            focusNode: _focusNode,
                                            enabled: isPro || _sessionSecondsRemaining > 0,
                                            maxLength: 6,
                                            style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 2),
                                            decoration: InputDecoration(
                                              counterText: "",
                                              hintText: 'Enter Code',
                                              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5), letterSpacing: 0),
                                              filled: true,
                                              fillColor: const Color(0xFF1B1B22),
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(12),
                                                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                                              ),
                                            ),
                                            onSubmitted: (_) {
                                              if (isPro || _sessionSecondsRemaining > 0) _resolvePinAndConnect();
                                            },
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () {
                                            if (isPro || _sessionSecondsRemaining > 0) _resolvePinAndConnect();
                                          },
                                          borderRadius: BorderRadius.circular(12),
                                          child: Container(
                                            height: 54,
                                            padding: const EdgeInsets.symmetric(horizontal: 32),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF7C4DFF),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Center(
                                              child: _connecting
                                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                                  : const Text(
                                                      'Connect',
                                                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    
                                    if (_status.isNotEmpty) ...[
                                      const SizedBox(height: 24),
                                      Text(
                                        _status,
                                        style: TextStyle(
                                          color: _status.contains('Failed') || _status.contains('Invalid') 
                                              ? Colors.redAccent 
                                              : Colors.white70,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ]
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCircleIcon(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF4A4A6A).withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white70, size: 20),
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
  final bool isPro;

  const DrawingScreen({super.key, required this.serverUri, required this.channel, required this.isPro});

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

  DateTime? _sessionExpiry;
  bool _isPaused = false;
  Timer? _heartbeatTimer;

  int get _sessionSecondsRemaining {
    if (_sessionExpiry == null) return 0;
    final diff = _sessionExpiry!.difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _sendCommand({
      'cmd': 'client_handshake',
      'tier': widget.isPro ? 'pro' : 'free',
    });
    _sendCommand({
      'cmd': 'initialize_stream',
      'is_pro': widget.isPro,
    });
    _setupWebSocket();
    _flushTimer = Timer.periodic(const Duration(milliseconds: 1), (_) => _flush());
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _drawShortcut = prefs.getString('draw_shortcut') ?? 'b';
      _eraserShortcut = prefs.getString('eraser_shortcut') ?? 'e';
      final expiryStr = prefs.getString('sessionExpiry');
      if (expiryStr != null) {
        _sessionExpiry = DateTime.parse(expiryStr);
      } else {
        _sessionExpiry = DateTime.now();
      }
      _isPaused = !widget.isPro && _sessionSecondsRemaining <= 0;
    });
    
    if (!widget.isPro) {
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _isPaused = _sessionSecondsRemaining <= 0;
        });
        
        if (timer.tick % 5 == 0) {
          _sendCommand({
            'cmd': 'session_heartbeat',
            'time_remaining': _sessionSecondsRemaining
          });
        }
      });
    }
  }

  final _adMobService = MockAdMobService();

  Future<void> _handleWatchAd() async {
    await _adMobService.showRewardedVideo(() async {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        if (_sessionExpiry == null || _sessionExpiry!.isBefore(DateTime.now())) {
           _sessionExpiry = DateTime.now().add(const Duration(minutes: 30));
        } else {
           _sessionExpiry = _sessionExpiry!.add(const Duration(minutes: 30));
        }
        
        final maxExpiry = DateTime.now().add(const Duration(hours: 2));
        if (_sessionExpiry!.isAfter(maxExpiry)) {
           _sessionExpiry = maxExpiry;
        }
        _isPaused = false;
      });
      await prefs.setString('sessionExpiry', _sessionExpiry!.toIso8601String());
      _sendCommand({
        'cmd': 'session_heartbeat',
        'time_remaining': _sessionSecondsRemaining
      });
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
    _heartbeatTimer?.cancel();
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
          
          if (_isPaused)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1E).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.2)),
                      ),
                      child: const Text(
                        'Session Paused.\nExtend canvas runtime via the navigation bar to resume work.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
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
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                      children: [
                                if (!widget.isPro)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _sessionSecondsRemaining < 300 
                                          ? Colors.redAccent.withOpacity(0.2) 
                                          : Colors.white.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: _sessionSecondsRemaining < 300 
                                            ? Colors.redAccent 
                                            : Colors.transparent
                                      ),
                                    ),
                                    child: Text(
                                      '${(_sessionSecondsRemaining ~/ 60).toString().padLeft(2, '0')}:${(_sessionSecondsRemaining % 60).toString().padLeft(2, '0')}',
                                      style: TextStyle(
                                        fontFamily: 'Courier',
                                        fontWeight: FontWeight.bold,
                                        color: _sessionSecondsRemaining < 300 
                                            ? Colors.redAccent 
                                            : theme.textTheme.bodyLarge?.color ?? Colors.white,
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 8),
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
                                if (!widget.isPro && _sessionSecondsRemaining <= 300)
                                  _buildNavIcon(
                                    Icons.play_circle_outline,
                                    'Watch Ad to Unpause',
                                    _handleWatchAd,
                                    Colors.greenAccent
                                  ),
                                if (!_connected)
                                  _buildNavIcon(
                                    Icons.refresh,
                                    'Reconnect',
                                    _reconnect,
                                    Colors.orangeAccent
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
                                );
                              }
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


class MockPaymentGatewayScreen extends StatefulWidget {
  const MockPaymentGatewayScreen({super.key});

  @override
  State<MockPaymentGatewayScreen> createState() => _MockPaymentGatewayScreenState();
}

class _MockPaymentGatewayScreenState extends State<MockPaymentGatewayScreen> {
  bool _isProcessing = false;

  void _processPayment() async {
    setState(() => _isProcessing = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Secure Checkout'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.workspace_premium, size: 64, color: Color(0xFF00E5FF)),
                const SizedBox(height: 24),
                const Text(
                  'DrawTab Pro Lifetime',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  '\.99 USD',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Credit Card', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      const TextField(
                        decoration: InputDecoration(
                          hintText: 'Card Number',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.credit_card),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: const [
                          Expanded(
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: 'MM/YY',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: 'CVC',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(20),
                    backgroundColor: const Color(0xFF7C4DFF),
                  ),
                  onPressed: _isProcessing ? null : _processPayment,
                  child: _isProcessing 
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Pay \.99', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
