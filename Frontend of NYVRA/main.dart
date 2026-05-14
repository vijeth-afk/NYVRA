// main.dart — Nyvra Safety Companion
// ✅ LoginPage is the entry point — app checks Supabase session on launch
// ✅ Named route /main defined so LoginPage's pushReplacementNamed works
// ✅ Logout signs out via Supabase then navigates back to LoginPage
// ✅ Live stats: Trips, Safe Checks, SOS Sent pulled from Supabase
// ✅ Travel History, Trusted Contacts, Notifications — real Supabase screens
// ✅ Profile loaded from Supabase profiles table
// ✅ withValues(alpha:) throughout (Flutter 3.27+)

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';
import 'login_page.dart';
import 'sos_screen.dart';
import 'chatbot_ui.dart';
import 'trip_planning_screen.dart';
import 'heatmap_screen.dart';
import 'edit_profile_page.dart';
import 'change_password_page.dart';

// ── Backend base URL ────────────────────────────────────────────────────────
const String kBaseUrl = "https://supriyachola-nyvra-api.hf.space";

// ── Design tokens ───────────────────────────────────────────────────────────
const Color kBg         = Color(0xFF080D18);
const Color kCard       = Color(0xFF111827);
const Color kCardBorder = Color(0xFF1F2A3C);
const Color kPurple     = Color(0xFF7B6EF6);
const Color kPurpleDim  = Color(0xFF5A52D5);
const Color kGreen      = Color(0xFF00D4AA);
const Color kAmber      = Color(0xFFFFA726);
const Color kRed        = Color(0xFFFF4757);
const Color kBlue       = Color(0xFF1E90FF);

// ── Supabase client shortcut ────────────────────────────────────────────────
SupabaseClient get _sb => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    anonKey: SupabaseConfig.supabaseAnonKey,
  );

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(const NyvraApp());
}

class NyvraApp extends StatelessWidget {
  const NyvraApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ── Decide start page based on existing session ──────────
    final session = Supabase.instance.client.auth.currentSession;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nyvra',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        fontFamily: 'SF Pro Display',
      ),
      // ── Start at LoginPage; if already logged in go to /main ──
      home: session != null ? const MainScreen() : const LoginPage(),
      // ── Named routes ─────────────────────────────────────────
      routes: {
        '/main':  (_) => const MainScreen(),
        '/login': (_) => const LoginPage(),
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// MAIN SCREEN — Bottom nav shell with GLOBAL floating SOS + Chatbot
// ════════════════════════════════════════════════════════════════════════════

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  final List<Widget> _pages = const [
    HomePage(),
    MapPage(),
    ProfilePage(),
  ];

  void _openChatbot() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ChatBotUI(),
    );
  }

  void _openSOS() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SOSScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          IndexedStack(index: _selectedIndex, children: _pages),

          // Global Floating Buttons
          Positioned(
            right: 16,
            bottom: 90,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _GlobalFAB(
                  onTap: _openSOS,
                  color: kRed,
                  icon: Icons.sos_rounded,
                  label: '',
                ),
                const SizedBox(height: 12),
                _GlobalFAB(
                  onTap: _openChatbot,
                  color: kPurple,
                  icon: Icons.chat_outlined,
                  label: null,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D1220),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.07),
              width: 0.5,
            ),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: kPurple,
          unselectedItemColor: Colors.white30,
          selectedLabelStyle:
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          onTap: (i) => setState(() => _selectedIndex = i),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.home_rounded), label: 'Home'),
            BottomNavigationBarItem(
                icon: Icon(Icons.map_rounded), label: 'Map'),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_rounded), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// GLOBAL FAB WIDGET
// ════════════════════════════════════════════════════════════════════════════

class _GlobalFAB extends StatelessWidget {
  final VoidCallback onTap;
  final Color color;
  final IconData icon;
  final String? label;

  const _GlobalFAB({
    required this.onTap,
    required this.color,
    required this.icon,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 14,
              spreadRadius: 1,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: label != null
            ? Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(
              label!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ],
        )
            : Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// HOME PAGE
// ════════════════════════════════════════════════════════════════════════════

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  Position? _position;
  StreamSubscription<Position>? _posStream;

  Map<String, dynamic>? _areaData;
  bool _loadingArea = true;

  Map<String, dynamic>? _insightsData;

  bool _liveTrackingOn = true;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _startLocationTracking();
  }

  Future<void> _startLocationTracking() async {
    bool svcEnabled = await Geolocator.isLocationServiceEnabled();
    if (!svcEnabled) return;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    if (mounted) setState(() => _position = pos);
    _fetchAreaData(pos.latitude, pos.longitude);
    _fetchInsights(pos.latitude, pos.longitude);

    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 50,
      ),
    ).listen((p) {
      if (mounted) setState(() => _position = p);
    });
  }

  Future<void> _fetchAreaData(double lat, double lng) async {
    if (mounted) setState(() => _loadingArea = true);
    try {
      final uri = Uri.parse('$kBaseUrl/predict_area').replace(
        queryParameters: {
          'latitude': lat.toString(),
          'longitude': lng.toString(),
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _areaData    = data;
          _loadingArea = false;
        });

        // ✅ Write safe_check to Supabase so stats counter increments
        _logSafeCheck(
          lat:        lat,
          lng:        lng,
          score:      data['safety_score'] as int? ?? 0,
          riskLevel:  data['danger_level'] as String? ?? 'Medium',
        );
      } else {
        if (mounted) setState(() => _loadingArea = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingArea = false);
    }
  }

  // ── Log safe check to Supabase ─────────────────────────────
  Future<void> _logSafeCheck({
    required double lat,
    required double lng,
    required int score,
    required String riskLevel,
  }) async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) return;
      await _sb.from('safe_checks').insert({
        'user_id':      user.id,
        'latitude':     lat,
        'longitude':    lng,
        'safety_score': score,
        'risk_level':   riskLevel,
      });
    } catch (_) {
      // Don't crash the UI if logging fails
    }
  }

  Future<void> _fetchInsights(double lat, double lng) async {
    try {
      final uri = Uri.parse('$kBaseUrl/heatmap_data').replace(
        queryParameters: {
          'latitude': lat.toString(),
          'longitude': lng.toString(),
          'radius_km': '3.0',
          'step_km': '0.5',
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final points = (data['points'] as List).cast<Map<String, dynamic>>();
        int safeZones  = points.where((p) => p['risk'] == 'Low').length;
        int riskAlerts = points.where((p) => p['risk'] == 'High').length;
        setState(() {
          _insightsData = {
            'safe_zones': safeZones,
            'risk_alerts': riskAlerts,
            'peak_risk_time': '10 PM – 1 AM',
          };
        });
      }
    } catch (_) {}
  }

  Future<void> _openWhatsAppSharing() async {
    final locationText = _position != null
        ? 'https://maps.google.com/?q=${_position!.latitude},${_position!.longitude}'
        : 'Location unavailable';
    final message = Uri.encodeComponent(
        'I am sharing my live location with you via Nyvra Safety App.\n$locationText');
    final waUri = Uri.parse('whatsapp://send?text=$message');
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
    } else {
      final waFallback = Uri.parse('https://wa.me/?text=$message');
      if (await canLaunchUrl(waFallback)) {
        await launchUrl(waFallback, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _posStream?.cancel();
    super.dispose();
  }

  Color _riskColor(String? risk) {
    switch (risk) {
      case 'Low':    return kGreen;
      case 'Medium': return kAmber;
      case 'High':   return kRed;
      default:       return Colors.white54;
    }
  }

  String _currentTime() {
    final now = DateTime.now();
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final m = now.minute.toString().padLeft(2, '0');
    final period = now.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $period';
  }

  String _crowdFromLabel(int? label) {
    if (label == null) return '—';
    if (label >= 2) return 'High';
    if (label == 1) return 'Medium';
    return 'Low';
  }

  Color _crowdColor(String crowd) {
    if (crowd == 'High') return kRed;
    if (crowd == 'Medium') return kAmber;
    return kGreen;
  }

  @override
  Widget build(BuildContext context) {
    final safetyScore   = _areaData?['safety_score'] as int?;
    final dangerLevel   = _areaData?['danger_level'] as String?;
    final factors       = (_areaData?['factors'] as List?)?.cast<String>() ?? [];
    final dangerLabel   = _areaData?['danger_label'] as int? ?? 1;
    final incidentCount = factors.isEmpty ? 0 : dangerLabel + 1;
    final crowdLevel    = _crowdFromLabel(dangerLabel);

    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _AmbientPainter())),
          SafeArea(
            child: RefreshIndicator(
              color: kPurple,
              backgroundColor: kCard,
              onRefresh: () async {
                if (_position != null) {
                  await _fetchAreaData(
                      _position!.latitude, _position!.longitude);
                  await _fetchInsights(
                      _position!.latitude, _position!.longitude);
                }
              },
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 12),
                    _buildStatusChips(),
                    const SizedBox(height: 14),
                    _buildAreaCard(
                        safetyScore, dangerLevel, incidentCount, crowdLevel),
                    const SizedBox(height: 20),
                    _sectionLabel('Quick Actions'),
                    const SizedBox(height: 10),
                    _buildQuickActions(),
                    const SizedBox(height: 20),
                    _buildMapPreviewSection(),
                    const SizedBox(height: 20),
                    _sectionLabel("Today's Safety Insights"),
                    const SizedBox(height: 10),
                    _buildInsights(),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: kPurple.withValues(alpha: 0.30),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/images/logo.png',
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kPurple, kPurpleDim],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shield_rounded,
                    color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nyvra',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3),
            ),
            Text(
              'Your safety companion',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusChips() {
    return Row(
      children: [
        GestureDetector(
          onTap: () => setState(() => _liveTrackingOn = !_liveTrackingOn),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kCardBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _liveTrackingOn ? kGreen : Colors.white30,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                const Text('Live Tracking',
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 36,
                  height: 20,
                  decoration: BoxDecoration(
                    color: _liveTrackingOn
                        ? kGreen.withValues(alpha: 0.85)
                        : Colors.white12,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    children: [
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 200),
                        left: _liveTrackingOn ? 17 : 2,
                        top: 3,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: const BoxDecoration(
                              color: Colors.white, shape: BoxShape.circle),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _liveTrackingOn ? 'ON' : 'OFF',
                  style: TextStyle(
                      color: _liveTrackingOn ? kGreen : Colors.white30,
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _openWhatsAppSharing,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kCardBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Color(0xFF25D366),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.chat_rounded,
                      color: Colors.white, size: 10),
                ),
                const SizedBox(width: 5),
                const Text('Trusted Contacts',
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(width: 4),
                const Text('>',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAreaCard(
      int? score, String? level, int incidents, String crowd) {
    final riskColor = _riskColor(level);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kCardBorder),
        boxShadow: [
          BoxShadow(
              color: riskColor.withValues(alpha: 0.07),
              blurRadius: 24,
              spreadRadius: 2),
        ],
      ),
      child: _loadingArea
          ? const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: CircularProgressIndicator(
                color: kPurple, strokeWidth: 2),
          ))
          : _areaData == null
          ? const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'Server unavailable — check connection',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ))
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.shield_outlined,
                color: kGreen, size: 14),
            const SizedBox(width: 5),
            const Text('Current Area',
                style:
                TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.location_on_rounded,
                color: kPurple, size: 13),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                _position != null
                    ? '${_position!.latitude.toStringAsFixed(4)}, ${_position!.longitude.toStringAsFixed(4)}'
                    : 'Fetching location...',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            const Text('Safety Level: ',
                style: TextStyle(
                    color: Colors.white54, fontSize: 13)),
            Text(
              level ?? '—',
              style: TextStyle(
                  color: riskColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _metaRow(Icons.access_time_rounded, 'Time',
                      _currentTime(), Colors.white60),
                  const SizedBox(height: 10),
                  _metaRow(Icons.people_rounded, 'Crowd', crowd,
                      _crowdColor(crowd)),
                  const SizedBox(height: 10),
                  _metaRow(Icons.warning_amber_rounded,
                      'Incidents Nearby', '$incidents', kRed),
                ],
              ),
            ),
            _scoreRing(score ?? 0, riskColor),
          ]),
        ],
      ),
    );
  }

  Widget _metaRow(
      IconData icon, String label, String value, Color valueColor) {
    return Row(children: [
      Icon(icon, color: Colors.white30, size: 13),
      const SizedBox(width: 6),
      Text('$label  ',
          style: const TextStyle(color: Colors.white38, fontSize: 11)),
      Text(value,
          style: TextStyle(
              color: valueColor,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _scoreRing(int score, Color color) {
    return SizedBox(
      width: 92,
      height: 92,
      child: CustomPaint(
        painter: _ScoreRingPainter(score: score, ringColor: color),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$score',
                style: TextStyle(
                  color: color,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  letterSpacing: -1,
                ),
              ),
              Text(
                '/100',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.30),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(text,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2));
  }

  Widget _buildQuickActions() {
    return Row(children: [
      _actionTile(
        icon: Icons.alt_route_rounded,
        label: 'Plan Safe\nRoute',
        sub: 'Find safest path',
        color: kPurple,
        onTap: () {
          if (_position != null) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TripPlanningScreen(
                  userLat: _position!.latitude,
                  userLng: _position!.longitude,
                ),
              ),
            );
          }
        },
      ),
      const SizedBox(width: 10),
      _actionTile(
        icon: Icons.local_hospital_rounded,
        label: 'Nearby\nHelp',
        sub: 'Police, Hospitals',
        color: kBlue,
        onTap: () async {
          final url = Uri.parse(
              'https://www.google.com/maps/search/police+station+near+me');
          await launchUrl(url, mode: LaunchMode.externalApplication);
        },
      ),
    ]);
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required String sub,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(height: 10),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.3)),
              const SizedBox(height: 3),
              Text(sub,
                  style:
                  const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapPreviewSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _sectionLabel('Live Safety Map (Preview)'),
          const Spacer(),
          GestureDetector(
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HeatmapScreen())),
            child: const Row(children: [
              Text('View Full Map',
                  style: TextStyle(color: kPurple, fontSize: 12)),
              SizedBox(width: 3),
              Icon(Icons.open_in_new_rounded, color: kPurple, size: 12),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const _FullMapPage())),
          child: Container(
            height: 220,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: kCardBorder),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(children: [
                if (_position != null)
                  FlutterMap(
                    options: MapOptions(
                      initialCenter:
                      LatLng(_position!.latitude, _position!.longitude),
                      initialZoom: 13.5,
                      interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.nyvra.safety',
                      ),
                      PolygonLayer(
                        polygons: _buildHeatmapBlobs(
                          _position!.latitude,
                          _position!.longitude,
                        ),
                      ),
                      MarkerLayer(markers: [
                        Marker(
                          point: LatLng(
                              _position!.latitude, _position!.longitude),
                          width: 44,
                          height: 44,
                          child: Container(
                            decoration: BoxDecoration(
                              color: kPurple,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                    color: kPurple.withValues(alpha: 0.5),
                                    blurRadius: 12,
                                    spreadRadius: 2)
                              ],
                              border: Border.all(
                                  color: Colors.white, width: 2.5),
                            ),
                            child: const Icon(Icons.navigation_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ),
                        Marker(
                          point: LatLng(_position!.latitude + 0.008,
                              _position!.longitude - 0.012),
                          width: 30,
                          height: 30,
                          child: Container(
                            decoration: BoxDecoration(
                              color: kAmber,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 1.5),
                            ),
                            child: const Icon(Icons.warning_rounded,
                                color: Colors.white, size: 14),
                          ),
                        ),
                        Marker(
                          point: LatLng(_position!.latitude - 0.005,
                              _position!.longitude + 0.015),
                          width: 30,
                          height: 30,
                          child: Container(
                            decoration: BoxDecoration(
                              color: kGreen,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Colors.white, width: 1.5),
                            ),
                            child: const Icon(Icons.shield_rounded,
                                color: Colors.white, size: 14),
                          ),
                        ),
                      ]),
                    ],
                  )
                else
                  Container(
                    color: kCard,
                    child: const Center(
                        child: CircularProgressIndicator(
                            color: kPurple, strokeWidth: 2)),
                  ),

                // Top gradient
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Container(
                    height: 60,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // Legend
                Positioned(
                  top: 10, right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _legendDot(kGreen, 'Safe'),
                        const SizedBox(height: 4),
                        _legendDot(kAmber, 'Moderate'),
                        const SizedBox(height: 4),
                        _legendDot(kRed, 'High Risk'),
                      ],
                    ),
                  ),
                ),

                // Locate FAB
                Positioned(
                  bottom: 12, right: 12,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: kPurple,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: kPurple.withValues(alpha: 0.5),
                            blurRadius: 8)
                      ],
                    ),
                    child: const Icon(Icons.my_location_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),

                // Bottom fade
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: Container(
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          kBg.withValues(alpha: 0.6),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  List<Polygon> _buildHeatmapBlobs(double lat, double lng) {
    final zones = [
      [kGreen.withValues(alpha: 0.30),  0.018, -0.010, 0.020],
      [kGreen.withValues(alpha: 0.25), -0.012,  0.020, 0.015],
      [kAmber.withValues(alpha: 0.30),  0.005, -0.020, 0.018],
      [kAmber.withValues(alpha: 0.25), -0.022,  0.005, 0.014],
      [kRed.withValues(alpha: 0.30),   -0.010, -0.015, 0.016],
      [kRed.withValues(alpha: 0.22),    0.025,  0.010, 0.012],
    ];
    return zones.map((z) {
      return _circlePolygon(
        lat + (z[1] as double),
        lng + (z[2] as double),
        z[3] as double,
        z[0] as Color,
      );
    }).toList();
  }

  Polygon _circlePolygon(
      double lat, double lng, double radius, Color color) {
    const int steps = 24;
    final List<LatLng> points = List.generate(steps, (i) {
      final angle = (2 * math.pi * i) / steps;
      return LatLng(
        lat + radius * math.cos(angle),
        lng + radius * math.sin(angle) / math.cos(lat * math.pi / 180),
      );
    });
    return Polygon(
      points: points,
      color: color,
      borderColor: Colors.transparent,
      borderStrokeWidth: 0,
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ],
    );
  }

  Widget _buildInsights() {
    if (_insightsData == null) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kCardBorder),
        ),
        child: const Center(
            child:
            CircularProgressIndicator(color: kPurple, strokeWidth: 2)),
      );
    }

    final safeZones  = _insightsData!['safe_zones']  as int? ?? 0;
    final riskAlerts = _insightsData!['risk_alerts'] as int? ?? 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kCardBorder),
      ),
      child: Row(children: [
        _insightTile(
          icon: Icons.shield_rounded,
          color: kGreen,
          value: '$safeZones',
          label: 'Safe Zones',
          sub: '+3 from yesterday',
        ),
        Container(
            width: 1,
            height: 55,
            color: Colors.white.withValues(alpha: 0.07)),
        _insightTile(
          icon: Icons.warning_amber_rounded,
          color: kAmber,
          value: '$riskAlerts',
          label: 'Risk Alerts',
          sub: riskAlerts > 0
              ? '+${riskAlerts > 1 ? riskAlerts - 1 : 1} from yesterday'
              : 'All clear',
        ),
        Container(
            width: 1,
            height: 55,
            color: Colors.white.withValues(alpha: 0.07)),
        _insightTile(
          icon: Icons.access_alarm_rounded,
          color: const Color(0xFFFF6B9D),
          value: '10 PM',
          label: 'Peak Risk Time',
          sub: '– 1 AM  Stay alert',
        ),
      ]),
    );
  }

  Widget _insightTile({
    required IconData icon,
    required Color color,
    required String value,
    required String label,
    required String sub,
  }) {
    return Expanded(
      child: Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
            textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(sub,
            style:
            TextStyle(color: color.withValues(alpha: 0.8), fontSize: 9),
            textAlign: TextAlign.center,
            maxLines: 2),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// AMBIENT BACKGROUND PAINTER
// ════════════════════════════════════════════════════════════════════════════

class _AmbientPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Paint()
      ..color = const Color(0xFF7B6EF6).withValues(alpha: 0.05)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 100);
    canvas.drawCircle(
        Offset(size.width * 0.12, size.height * 0.08), 180, p1);

    final p2 = Paint()
      ..color = const Color(0xFF1E90FF).withValues(alpha: 0.03)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 120);
    canvas.drawCircle(
        Offset(size.width * 0.9, size.height * 0.35), 200, p2);

    final p3 = Paint()
      ..color = const Color(0xFFFF4757).withValues(alpha: 0.02)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80);
    canvas.drawCircle(
        Offset(size.width * 0.5, size.height * 0.85), 150, p3);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ════════════════════════════════════════════════════════════════════════════
// MAP PAGE (tab)
// ════════════════════════════════════════════════════════════════════════════

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  LatLng _center = const LatLng(12.9716, 77.5946);
  StreamSubscription<Position>? _posStream;

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  Future<void> _startTracking() async {
    bool ok = await Geolocator.isLocationServiceEnabled();
    if (!ok) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    Position pos = await Geolocator.getCurrentPosition();
    if (mounted) setState(() => _center = LatLng(pos.latitude, pos.longitude));

    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen((p) {
      if (mounted) setState(() => _center = LatLng(p.latitude, p.longitude));
    });
  }

  @override
  void dispose() {
    _posStream?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(children: [
        FlutterMap(
          options: MapOptions(initialCenter: _center, initialZoom: 15),
          children: [
            TileLayer(
              urlTemplate:
              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.nyvra.safety',
            ),
            MarkerLayer(markers: [
              Marker(
                point: _center,
                width: 50,
                height: 50,
                child: Container(
                  decoration: BoxDecoration(
                    color: kPurple,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: kPurple.withValues(alpha: 0.5),
                          blurRadius: 12)
                    ],
                    border: Border.all(color: Colors.white, width: 2.5),
                  ),
                  child: const Icon(Icons.navigation_rounded,
                      color: Colors.white, size: 22),
                ),
              )
            ]),
          ],
        ),
        Positioned(
          bottom: 24,
          right: 16,
          child: FloatingActionButton.extended(
            backgroundColor: kPurple,
            icon: const Icon(Icons.layers_rounded),
            label: const Text('Safety Heatmap'),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HeatmapScreen())),
          ),
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// FULL MAP PAGE (pushed from home map preview tap)
// ════════════════════════════════════════════════════════════════════════════

class _FullMapPage extends StatefulWidget {
  const _FullMapPage();

  @override
  State<_FullMapPage> createState() => _FullMapPageState();
}

class _FullMapPageState extends State<_FullMapPage> {
  LatLng _center = const LatLng(12.9716, 77.5946);

  @override
  void initState() {
    super.initState();
    Geolocator.getCurrentPosition().then((p) {
      if (mounted) setState(() => _center = LatLng(p.latitude, p.longitude));
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        title: const Text('Live Safety Map',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          TextButton(
            onPressed: () => Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (_) => HeatmapScreen())),
            child: const Text('Heatmap',
                style: TextStyle(color: kPurple)),
          )
        ],
      ),
      body: FlutterMap(
        options: MapOptions(initialCenter: _center, initialZoom: 14),
        children: [
          TileLayer(
            urlTemplate:
            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.nyvra.safety',
          ),
          MarkerLayer(markers: [
            Marker(
              point: _center,
              width: 44,
              height: 44,
              child: Container(
                decoration: BoxDecoration(
                  color: kPurple,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: kPurple.withValues(alpha: 0.5),
                        blurRadius: 10)
                  ],
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.navigation_rounded,
                    color: Colors.white, size: 20),
              ),
            )
          ]),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// PROFILE PAGE  — Live stats + Travel History + Contacts + Notifications
// ════════════════════════════════════════════════════════════════════════════

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // ── Profile info ────────────────────────────────────────────
  String _name  = '';
  String _email = '';

  // ── Live stats ──────────────────────────────────────────────
  int _tripsCount      = 0;
  int _safeChecksCount = 0;
  int _sosCount        = 0;
  bool _loadingStats   = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadStats();
  }

  // ── Load profile from Supabase ──────────────────────────────
  Future<void> _loadProfile() async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) return;

      final data = await _sb
          .from('profiles')
          .select('name, email')
          .eq('id', user.id)
          .maybeSingle();

      if (data != null && mounted) {
        setState(() {
          _name  = data['name']  as String? ?? '';
          _email = data['email'] as String? ?? user.email ?? '';
        });
      } else {
        if (mounted) {
          setState(() {
            _name  = user.userMetadata?['full_name'] as String? ?? '';
            _email = user.email ?? '';
          });
        }
      }
    } catch (_) {
      final user = _sb.auth.currentUser;
      if (mounted && user != null) {
        setState(() {
          _name  = user.userMetadata?['full_name'] as String? ?? '';
          _email = user.email ?? '';
        });
      }
    }
  }

  // ── Load stats from Supabase ────────────────────────────────
  Future<void> _loadStats() async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loadingStats = false);
        return;
      }

      final results = await Future.wait([
        _sb
            .from('trips')
            .select('id')
            .eq('user_id', user.id)
            .count(CountOption.exact),
        _sb
            .from('safe_checks')
            .select('id')
            .eq('user_id', user.id)
            .count(CountOption.exact),
        _sb
            .from('sos_logs')
            .select('id')
            .eq('user_id', user.id)
            .count(CountOption.exact),
      ]);

      if (mounted) {
        setState(() {
          _tripsCount      = results[0].count ?? 0;
          _safeChecksCount = results[1].count ?? 0;
          _sosCount        = results[2].count ?? 0;
          _loadingStats    = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingStats = false);
    }
  }

  // ── Edit profile ────────────────────────────────────────────
  Future<void> _openEditProfile() async {
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfilePage(name: _name, email: _email),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _name  = result['name']  ?? _name;
        _email = result['email'] ?? _email;
      });
    }
  }

  void _openChangePassword() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
    );
  }

  // ── Logout ──────────────────────────────────────────────────
  // ✅ FIX: after signOut, navigate to LoginPage and clear the stack
  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout',
            style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // close dialog
              await _sb.auth.signOut();
              if (mounted) {
                // Remove entire stack and push LoginPage
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                      (route) => false,
                );
              }
            },
            child: const Text('Logout',
                style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName =
    _name.isNotEmpty ? _name : _email.split('@').first;
    final initials = displayName.isNotEmpty
        ? displayName[0].toUpperCase()
        : 'U';

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: kPurple,
          backgroundColor: kCard,
          onRefresh: () async {
            await _loadProfile();
            await _loadStats();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            child: Column(children: [

              // ── Profile header card ───────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kCardBorder),
                ),
                child: Row(children: [
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [kPurple, kPurpleDim],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: kPurple.withValues(alpha: 0.3),
                            blurRadius: 10)
                      ],
                    ),
                    child: Center(
                      child: Text(
                        initials,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName.isNotEmpty
                              ? '${displayName[0].toUpperCase()}${displayName.substring(1)}'
                              : 'Nyvra User',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(_email,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _openEditProfile,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: kPurple.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: kPurple.withValues(alpha: 0.3)),
                      ),
                      child: const Icon(Icons.edit_rounded,
                          color: kPurple, size: 16),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: kGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border:
                      Border.all(color: kGreen.withValues(alpha: 0.3)),
                    ),
                    child: const Text('Safe',
                        style: TextStyle(
                            color: kGreen,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),

              const SizedBox(height: 14),

              // ── Live stats row ────────────────────────────
              _loadingStats
                  ? Container(
                padding: const EdgeInsets.symmetric(vertical: 20),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kCardBorder),
                ),
                child: const Center(
                    child: CircularProgressIndicator(
                        color: kPurple, strokeWidth: 2)),
              )
                  : Row(children: [
                Expanded(
                    child: _statCard('Trips', '$_tripsCount')),
                const SizedBox(width: 10),
                Expanded(
                    child: _statCard(
                        'Safe Checks', '$_safeChecksCount')),
                const SizedBox(width: 10),
                Expanded(
                    child: _statCard('SOS Sent', '$_sosCount')),
              ]),

              const SizedBox(height: 18),

              // ── Account section ───────────────────────────
              _sectionHeader('Account'),

              _menuItem(
                icon: Icons.person_outline_rounded,
                text: 'Edit Profile',
                onTap: _openEditProfile,
              ),
              _menuItem(
                icon: Icons.lock_outline_rounded,
                text: 'Change Password',
                onTap: _openChangePassword,
              ),

              const SizedBox(height: 10),

              // ── App section ───────────────────────────────
              _sectionHeader('App'),

              _menuItem(
                icon: Icons.history_rounded,
                text: 'Travel History',
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(
                        builder: (_) => const TravelHistoryPage())),
              ),
              _menuItem(
                icon: Icons.group_rounded,
                text: 'Trusted Contacts',
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(
                        builder: (_) => const TrustedContactsPage())),
              ),
              _menuItem(
                icon: Icons.notifications_rounded,
                text: 'Notifications',
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(
                        builder: (_) => const NotificationsPage())),
              ),
              _menuItem(
                icon: Icons.location_on_rounded,
                text: 'Location Settings',
                onTap: () async {
                  await Geolocator.openLocationSettings();
                },
              ),

              const SizedBox(height: 10),

              // ── Logout ────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _confirmLogout,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Logout'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kRed,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String label) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1)),
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kCardBorder),
      ),
      child: Column(children: [
        Text(value,
            style: const TextStyle(
                color: kPurple, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ]),
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kCardBorder),
        ),
        child: Row(children: [
          Icon(icon, color: kPurple, size: 20),
          const SizedBox(width: 14),
          Text(text,
              style:
              const TextStyle(color: Colors.white, fontSize: 13)),
          const Spacer(),
          const Icon(Icons.arrow_forward_ios_rounded,
              size: 13, color: Colors.white24),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TRAVEL HISTORY PAGE
// ════════════════════════════════════════════════════════════════════════════

class TravelHistoryPage extends StatefulWidget {
  const TravelHistoryPage({super.key});

  @override
  State<TravelHistoryPage> createState() => _TravelHistoryPageState();
}

class _TravelHistoryPageState extends State<TravelHistoryPage> {
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final data = await _sb
          .from('trips')
          .select()
          .eq('user_id', user.id)
          .order('started_at', ascending: false);

      if (mounted) {
        setState(() {
          _trips   = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        title: const Text('Travel History',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(
          child: CircularProgressIndicator(color: kPurple))
          : _trips.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded,
                color: Colors.white12, size: 64),
            const SizedBox(height: 16),
            const Text('No trips yet',
                style: TextStyle(
                    color: Colors.white38, fontSize: 15)),
            const SizedBox(height: 6),
            const Text(
                'Your planned routes will appear here',
                style: TextStyle(
                    color: Colors.white24, fontSize: 12)),
          ],
        ),
      )
          : RefreshIndicator(
        color: kPurple,
        backgroundColor: kCard,
        onRefresh: _loadTrips,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _trips.length,
          itemBuilder: (context, index) {
            final trip = _trips[index];
            final score = trip['safety_score'] as int? ?? 0;
            final scoreColor = score >= 70
                ? kGreen
                : score >= 45
                ? kAmber
                : kRed;
            final dest =
                trip['destination'] as String? ?? 'Unknown';
            final origin =
                trip['origin'] as String? ?? 'Current Location';
            final dateStr =
                trip['started_at'] as String? ?? '';
            DateTime? date;
            try {
              date = DateTime.parse(dateStr).toLocal();
            } catch (_) {}

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kCardBorder),
              ),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scoreColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$score',
                      style: TextStyle(
                          color: scoreColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      Text(dest,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text('From: $origin',
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11)),
                      if (date != null)
                        Text(
                          '${date.day}/${date.month}/${date.year}  ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              color: Colors.white24,
                              fontSize: 10),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded,
                    size: 12, color: Colors.white24),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// TRUSTED CONTACTS PAGE
// ════════════════════════════════════════════════════════════════════════════

class TrustedContactsPage extends StatefulWidget {
  const TrustedContactsPage({super.key});

  @override
  State<TrustedContactsPage> createState() => _TrustedContactsPageState();
}

class _TrustedContactsPageState extends State<TrustedContactsPage> {
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;

  final _nameCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final data = await _sb
          .from('contacts')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _contacts = List<Map<String, dynamic>>.from(data as List);
          _loading  = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addContact() async {
    final name  = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;

    try {
      final user = _sb.auth.currentUser;
      if (user == null) return;

      await _sb.from('contacts').insert({
        'user_id': user.id,
        'name':    name.isNotEmpty ? name : null,
        'phone':   phone,
      });

      _nameCtrl.clear();
      _phoneCtrl.clear();
      Navigator.pop(context);
      await _loadContacts();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _deleteContact(String id) async {
    try {
      await _sb.from('contacts').delete().eq('id', id);
      await _loadContacts();
    } catch (_) {}
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add Trusted Contact',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDec('Name (optional)', Icons.person_rounded),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: Colors.white),
              decoration:
              _inputDec('Phone number *', Icons.phone_rounded),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _addContact,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPurple,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Save Contact',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDec(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      prefixIcon: Icon(icon, color: Colors.white38, size: 20),
      filled: true,
      fillColor: const Color(0xFF1A2332),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        title: const Text('Trusted Contacts',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, color: kPurple),
            onPressed: _showAddSheet,
          )
        ],
      ),
      body: _loading
          ? const Center(
          child: CircularProgressIndicator(color: kPurple))
          : _contacts.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_rounded,
                color: Colors.white12, size: 64),
            const SizedBox(height: 16),
            const Text('No contacts yet',
                style: TextStyle(
                    color: Colors.white38, fontSize: 15)),
            const SizedBox(height: 6),
            const Text(
                'Add contacts to alert during SOS',
                style: TextStyle(
                    color: Colors.white24, fontSize: 12)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Contact'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kPurple),
            ),
          ],
        ),
      )
          : RefreshIndicator(
        color: kPurple,
        backgroundColor: kCard,
        onRefresh: _loadContacts,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _contacts.length,
          itemBuilder: (context, index) {
            final c     = _contacts[index];
            final name  = c['name']  as String? ?? '';
            final phone = c['phone'] as String? ?? '';
            final id    = c['id']    as String;
            final initials = name.isNotEmpty
                ? name[0].toUpperCase()
                : phone.isNotEmpty
                ? phone[0]
                : '?';

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kCardBorder),
              ),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [kPurple, kPurpleDim]),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(initials,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      if (name.isNotEmpty)
                        Text(name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      Text(phone,
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      color: kRed, size: 20),
                  onPressed: () => _deleteContact(id),
                ),
              ]),
            );
          },
        ),
      ),
      floatingActionButton: _contacts.isNotEmpty
          ? FloatingActionButton(
        backgroundColor: kPurple,
        onPressed: _showAddSheet,
        child: const Icon(Icons.add_rounded),
      )
          : null,
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// NOTIFICATIONS PAGE
// ════════════════════════════════════════════════════════════════════════════

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final data = await _sb
          .from('notifications')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _notifications =
          List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
      _markAllRead(user.id);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead(String userId) async {
    try {
      await _sb
          .from('notifications')
          .update({'is_read': true})
          .eq('user_id', userId)
          .eq('is_read', false);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        title: const Text('Notifications',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _loading
          ? const Center(
          child: CircularProgressIndicator(color: kPurple))
          : _notifications.isEmpty
          ? Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_off_rounded,
                color: Colors.white12, size: 64),
            const SizedBox(height: 16),
            const Text('No notifications',
                style: TextStyle(
                    color: Colors.white38, fontSize: 15)),
            const SizedBox(height: 6),
            const Text(
                'Safety alerts will appear here',
                style: TextStyle(
                    color: Colors.white24, fontSize: 12)),
          ],
        ),
      )
          : RefreshIndicator(
        color: kPurple,
        backgroundColor: kCard,
        onRefresh: _loadNotifications,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _notifications.length,
          itemBuilder: (context, index) {
            final n       = _notifications[index];
            final title   = n['title']  as String? ?? '';
            final body    = n['body']   as String? ?? '';
            final isRead  = n['is_read'] as bool? ?? false;
            final dateStr = n['created_at'] as String? ?? '';
            DateTime? date;
            try {
              date = DateTime.parse(dateStr).toLocal();
            } catch (_) {}

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isRead
                    ? kCard
                    : kPurple.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: isRead
                        ? kCardBorder
                        : kPurple.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: kPurple.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                      Icons.notifications_rounded,
                      color: kPurple,
                      size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                    CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(title,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: isRead
                                      ? FontWeight.w400
                                      : FontWeight.w700)),
                        ),
                        if (!isRead)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                                color: kPurple,
                                shape: BoxShape.circle),
                          ),
                      ]),
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(body,
                            style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12)),
                      ],
                      if (date != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${date.day}/${date.month}/${date.year}  ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              color: Colors.white24,
                              fontSize: 10),
                        ),
                      ],
                    ],
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SCORE RING PAINTER
// ════════════════════════════════════════════════════════════════════════════

class _ScoreRingPainter extends CustomPainter {
  final int   score;
  final Color ringColor;

  const _ScoreRingPainter({required this.score, required this.ringColor});

  @override
  void paint(Canvas canvas, Size size) {
    final cx     = size.width  / 2;
    final cy     = size.height / 2;
    final radius = (size.width  / 2) - 7;
    final rect   = Rect.fromCircle(center: Offset(cx, cy), radius: radius);

    final trackPaint = Paint()
      ..color       = Colors.white.withValues(alpha: 0.07)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap   = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi, false, trackPaint);

    final fillPaint = Paint()
      ..color       = ringColor
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap   = StrokeCap.round;

    final sweep = 2 * math.pi * (score.clamp(0, 100) / 100);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, fillPaint);
  }

  @override
  bool shouldRepaint(_ScoreRingPainter old) =>
      old.score != score || old.ringColor != ringColor;
}