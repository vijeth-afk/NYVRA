// heatmap_screen.dart  — Nyvra Safety Heatmap  (production v3)
// ════════════════════════════════════════════════════════════════════════════
// Google Maps–style UI:
//  ✅ Dark CartoDB tiles (no API key)
//  ✅ AI heatmap CircleLayer — size & colour by risk score
//  ✅ Animated segmented safe-route polylines (green/amber/red)
//  ✅ User location with pulse animation
//  ✅ Glassmorphic top bar + right FABs
//  ✅ DraggableScrollableSheet (collapsed / half / expanded)
//  ✅ Tap-to-inspect heatmap points tooltip
//  ✅ Loading overlay + 10s timeout + retry
//  ✅ Risk legend top-left
//  ✅ Route options with score rings
// ════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:latlong2/latlong.dart' show Distance, LengthUnit;

import 'heatmap_service.dart';

// ── Design tokens ─────────────────────────────────────────────────────────────
const Color _kBg         = Color(0xFF080D18);
const Color _kCard       = Color(0xFF111827);
const Color _kCardBorder = Color(0xFF1E2A3C);
const Color _kPurple     = Color(0xFF7B6EF6);
const Color _kGreen      = Color(0xFF00D4AA);
const Color _kAmber      = Color(0xFFFFA726);
const Color _kRed        = Color(0xFFFF4757);
const Color _kBlue       = Color(0xFF3D8EFF);

// CartoDB Dark Matter — free, no API key
const String _kTile =
    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
const List<String> _kSubs = ['a', 'b', 'c', 'd'];

// ════════════════════════════════════════════════════════════════════════════
class HeatmapScreen extends StatefulWidget {
  /// Optional: pre-set user location (skips GPS fetch for that position).
  final double? initialLat;
  final double? initialLng;

  /// Optional: pre-set destination for automatic route analysis.
  final String?  destinationLabel;
  final double?  destLat;
  final double?  destLng;

  const HeatmapScreen({
    super.key,
    this.initialLat,
    this.initialLng,
    this.destinationLabel,
    this.destLat,
    this.destLng,
  });

  @override
  State<HeatmapScreen> createState() => _HeatmapScreenState();
}

class _HeatmapScreenState extends State<HeatmapScreen>
    with TickerProviderStateMixin {

  // ── Map ───────────────────────────────────────────────────────────────────
  final MapController _mapCtrl = MapController();
  double _zoom = 14.0;

  // ── Location ──────────────────────────────────────────────────────────────
  LatLng?  _userPos;
  StreamSubscription<Position>? _posSub;

  // ── Data ──────────────────────────────────────────────────────────────────
  HeatmapResult?        _heatmapData;
  AreaPredictionResult? _areaPred;
  RouteAnalysisResult?  _routeData;
  RouteData?            _activeRoute;

  // ── UI flags ──────────────────────────────────────────────────────────────
  bool   _showHeatmap   = true;
  bool   _showRoute     = false;
  bool   _loading       = false;
  bool   _loadingRoute  = false;
  String? _error;
  double _radiusKm      = 1.0;
  String _subtitle      = 'Your current area';

  HeatmapPoint? _tappedPt;
  LatLng?       _destPos;
  final _destCtrl = TextEditingController();

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;
  late AnimationController _routeCtrl;
  late Animation<double>   _routeAnim;

  // ── Bottom sheet ──────────────────────────────────────────────────────────
  final DraggableScrollableController _sheetCtrl =
  DraggableScrollableController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _routeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _routeAnim = CurvedAnimation(parent: _routeCtrl, curve: Curves.easeOut);

    _initLocation();

    // If a destination was pre-set from trip planning, schedule it after
    // the first frame so the map controller is ready.
    if (widget.destLat != null && widget.destLng != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _destPos  = LatLng(widget.destLat!, widget.destLng!);
            _subtitle = 'Navigating to ${widget.destinationLabel ?? 'destination'}';
          });
          _fetchRoute();
        }
      });
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _routeCtrl.dispose();
    _posSub?.cancel();
    _destCtrl.dispose();
    _sheetCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  LOCATION
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initLocation() async {
    // If the caller pre-set a location, use it immediately and skip GPS wait.
    if (widget.initialLat != null && widget.initialLng != null) {
      final ll = LatLng(widget.initialLat!, widget.initialLng!);
      if (mounted) setState(() => _userPos = ll);
      _mapCtrl.move(ll, _zoom);
      _fetchHeatmap();
      _fetchArea(ll);
      // Still start live tracking so the dot stays up-to-date.
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 25),
      ).listen((p) {
        if (mounted) setState(() => _userPos = LatLng(p.latitude, p.longitude));
      });
      return;
    }

    if (!await Geolocator.isLocationServiceEnabled()) {
      _setError('Location services disabled'); return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _setError('Location permission denied'); return;
    }
    final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    final ll = LatLng(pos.latitude, pos.longitude);
    if (!mounted) return;
    setState(() => _userPos = ll);
    _mapCtrl.move(ll, _zoom);
    _fetchHeatmap();
    _fetchArea(ll);
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 25),
    ).listen((p) {
      if (mounted) setState(() => _userPos = LatLng(p.latitude, p.longitude));
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  DATA FETCHING
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _fetchHeatmap() async {
    if (_userPos == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final r = await HeatmapService.fetchHeatmap(
        latitude:  _userPos!.latitude,
        longitude: _userPos!.longitude,
        radiusKm:  _radiusKm,
        stepKm:    _radiusKm <= 1.0 ? 0.35 : 0.5,
      ).timeout(const Duration(seconds: 10));
      if (mounted) setState(() { _heatmapData = r; _loading = false; });
    } on HeatmapException catch (e) {
      _setError(e.message);
    } on TimeoutException {
      _setError('Timed out — tap Retry');
    } catch (e) {
      _setError('$e');
    }
  }

  Future<void> _fetchArea(LatLng pos) async {
    try {
      final r = await SafetyApiService.predictArea(
          latitude: pos.latitude, longitude: pos.longitude);
      if (mounted) setState(() => _areaPred = r);
    } catch (_) {}
  }

  Future<void> _fetchRoute() async {
    if (_userPos == null || _destPos == null) return;
    setState(() => _loadingRoute = true);
    try {
      final r = await SafetyApiService.analyzeRoute(
        originLat: _userPos!.latitude,
        originLng: _userPos!.longitude,
        destLat:   _destPos!.latitude,
        destLng:   _destPos!.longitude,
        time:      'Now',
      ).timeout(const Duration(seconds: 18));
      if (!mounted) return;
      setState(() {
        _routeData     = r;
        _activeRoute   = r.routes.firstWhere(
                (x) => x.isRecommended, orElse: () => r.routes.first);
        _showRoute     = true;
        _loadingRoute  = false;
        _subtitle      = 'Navigating to destination';
      });
      _routeCtrl.forward(from: 0);
    } on HeatmapException catch (e) {
      if (mounted) setState(() => _loadingRoute = false);
      _snack(e.message);
    } catch (_) {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() { _loading = false; _error = msg; });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _recenter() {
    if (_userPos != null) _mapCtrl.move(_userPos!, _zoom);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  RISK HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  Color _riskColor(String risk) {
    if (risk == 'Low')    return _kGreen;
    if (risk == 'Medium') return _kAmber;
    return _kRed;
  }

  double _circleRadius(int score) {
    final danger = (100 - score).clamp(0, 100);
    return 40 + (danger / 100) * 90;   // 40–130 m
  }

  Color _scoreColor(int score) {
    if (score >= 70) return _kGreen;
    if (score >= 45) return _kAmber;
    return _kRed;
  }

  // ════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: Stack(children: [
        _buildMap(),
        _buildTopBar(),
        _buildLegend(),
        _buildRightFABs(),
        if (_tappedPt != null) _buildPointPopup(),
        _buildBottomSheet(),
        if (_loading)            _buildLoadingOverlay(),
        if (_error != null && !_loading) _buildErrorBanner(),
      ]),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  //  MAP
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapCtrl,
      options: MapOptions(
        initialCenter: _userPos ?? const LatLng(12.9716, 77.5946),
        initialZoom:   _zoom,
        minZoom: 10, maxZoom: 18,
        onTap: (_, __) => setState(() => _tappedPt = null),
      ),
      children: [
        TileLayer(
          urlTemplate: _kTile,
          subdomains:  _kSubs,
          userAgentPackageName: 'com.nyvra.safety',
        ),
        if (_showHeatmap && _heatmapData != null)
          CircleLayer(circles: _buildCircles()),
        if (_showRoute && _routeData != null &&
            _userPos != null && _destPos != null)
          PolylineLayer(polylines: _buildPolylines()),
        if (_userPos != null) _buildUserLayer(),
        if (_destPos != null) MarkerLayer(markers: [_destMarker()]),
        if (_showHeatmap && _heatmapData != null)
          MarkerLayer(markers: _tapMarkers()),
      ],
    );
  }

  // ── Heatmap circles ───────────────────────────────────────────────────────
  List<CircleMarker> _buildCircles() =>
      _heatmapData!.points.map((p) {
        final c = _riskColor(p.risk);
        return CircleMarker(
          point:  LatLng(p.lat, p.lng),
          radius: _circleRadius(p.score),
          useRadiusInMeter: true,
          color: c.withValues(
              alpha: p.risk == 'High' ? 0.20 : p.risk == 'Medium' ? 0.14 : 0.10),
          borderColor:
          c.withValues(alpha: p.risk == 'Low' ? 0.0 : 0.38),
          borderStrokeWidth: p.risk == 'High' ? 1.5 : 0,
        );
      }).toList();

  // ── Tap markers (invisible hit targets) ──────────────────────────────────
  List<Marker> _tapMarkers() =>
      _heatmapData!.points.map((p) => Marker(
        point:  LatLng(p.lat, p.lng),
        width:  64, height: 64,
        child: GestureDetector(
          onTap: () => setState(() => _tappedPt = p),
          child: const SizedBox.expand(),
        ),
      )).toList();

  // ── Segmented route polylines ─────────────────────────────────────────────
  List<Polyline> _buildPolylines() {
    if (_activeRoute == null || _userPos == null || _destPos == null) return [];
    final s  = _activeRoute!.safetyScore;
    final oLat = _userPos!.latitude,  oLng = _userPos!.longitude;
    final dLat = _destPos!.latitude,  dLng = _destPos!.longitude;

    // Three interpolated midpoints for visual segmentation
    final m1 = LatLng((oLat + dLat) / 2 + 0.0035, (oLng + dLng) / 2 - 0.005);
    final m2 = LatLng((oLat + dLat) / 2 - 0.002,  (oLng + dLng) / 2 + 0.004);
    final m3 = LatLng(oLat * 0.25 + dLat * 0.75,  oLng * 0.25 + dLng * 0.75);

    final segs = [
      [_userPos!, m1],
      [m1, m2, m3],
      [m3, _destPos!],
    ];
    final scores = [
      (s * 1.06).clamp(0, 100).toInt(),
      (s * 0.93).clamp(0, 100).toInt(),
      s,
    ];

    return List.generate(3, (i) {
      final c = _scoreColor(scores[i]);
      return Polyline(
        points: segs[i],
        color:  c.withValues(alpha: 0.90),
        strokeWidth: 5.5,
        borderColor: c.withValues(alpha: 0.20),
        borderStrokeWidth: 3.5,
        strokeCap:  StrokeCap.round,
        strokeJoin: StrokeJoin.round,
      );
    });
  }

  // ── User location pulse ───────────────────────────────────────────────────
  Widget _buildUserLayer() => MarkerLayer(markers: [
    Marker(
      point:  _userPos!,
      width:  56, height: 56,
      child: AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) => Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width:  56 * _pulseAnim.value,
              height: 56 * _pulseAnim.value,
              decoration: BoxDecoration(
                color:  _kBlue.withValues(alpha: 0.13 * _pulseAnim.value),
                shape:  BoxShape.circle,
              ),
            ),
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                color:  _kBlue.withValues(alpha: 0.22),
                shape:  BoxShape.circle,
                border: Border.all(color: Colors.white30, width: 1),
              ),
            ),
            Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: _kBlue,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: _kBlue.withValues(alpha: 0.70),
                    blurRadius: 10, spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ]);

  // ── Destination marker ────────────────────────────────────────────────────
  Marker _destMarker() => Marker(
    point:  _destPos!,
    width: 46, height: 56,
    child: Column(
      children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: _kPurple,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: _kPurple.withValues(alpha: 0.55),
                blurRadius: 14, spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.flag_rounded, color: Colors.white, size: 20),
        ),
        Container(width: 2, height: 12, color: _kPurple),
      ],
    ),
  );

  // ════════════════════════════════════════════════════════════════════════
  //  TOP GLASSMORPHIC BAR
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildTopBar() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _kBg.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 24, offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(children: [
                  _topBtn(Icons.arrow_back_ios_new_rounded,
                          () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Safety Heatmap',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                        GestureDetector(
                          onTap: _showDestSheet,
                          child: Text(
                            _subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.50),
                              fontSize: 11,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _topBtn(Icons.layers_rounded, _showDestSheet,
                      active: _showRoute),
                  _topBtn(Icons.refresh_rounded, () {
                    _fetchHeatmap();
                    if (_userPos != null) _fetchArea(_userPos!);
                  }),
                  _topBtn(Icons.alt_route_rounded, _showDestSheet,
                      active: _showRoute),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBtn(IconData icon, VoidCallback onTap,
      {bool active = false}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36, height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: active
                ? _kPurple.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? _kPurple.withValues(alpha: 0.50)
                  : Colors.white.withValues(alpha: 0.09),
            ),
          ),
          child: Icon(icon,
              color: active ? _kPurple : Colors.white54, size: 17),
        ),
      );

  // ════════════════════════════════════════════════════════════════════════
  //  RIGHT FABS
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildRightFABs() {
    return Positioned(
      right: 13, top: 130,
      child: Column(children: [
        _fab(Icons.my_location_rounded, _recenter, tip: 'My location'),
        const SizedBox(height: 9),
        _fab(
          Icons.layers_rounded,
              () => setState(() => _showHeatmap = !_showHeatmap),
          tip: 'Toggle heatmap', active: _showHeatmap,
        ),
        const SizedBox(height: 9),
        _fab(
          Icons.alt_route_rounded,
              () => _showRoute
              ? setState(() { _showRoute = false; _destPos = null;
          _subtitle = 'Your current area'; })
              : _showDestSheet(),
          tip: 'Toggle route', active: _showRoute,
        ),
        const SizedBox(height: 9),
        _fab(Icons.add_rounded, () {
          _zoom = (_zoom + 1).clamp(10, 18);
          _mapCtrl.move(_mapCtrl.camera.center, _zoom);
        }, tip: 'Zoom in'),
        const SizedBox(height: 6),
        _fab(Icons.remove_rounded, () {
          _zoom = (_zoom - 1).clamp(10, 18);
          _mapCtrl.move(_mapCtrl.camera.center, _zoom);
        }, tip: 'Zoom out'),
      ]),
    );
  }

  Widget _fab(IconData icon, VoidCallback onTap,
      {String tip = '', bool active = false}) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: active
                    ? _kPurple.withValues(alpha: 0.28)
                    : _kBg.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: active
                      ? _kPurple.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.09),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8, offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(icon,
                  color: active ? _kPurple : Colors.white60, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  //  RISK LEGEND
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildLegend() {
    return Positioned(
      left: 13, top: 130,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _kBg.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.09)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'RISK LEVEL',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.38),
                    fontSize: 8, fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                _legendRow(_kGreen, 'Safe',     '≥85'),
                const SizedBox(height: 5),
                _legendRow(_kAmber, 'Moderate', '45–84'),
                const SizedBox(height: 5),
                _legendRow(_kRed,   'High',     '<45'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legendRow(Color c, String label, String range) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10, height: 10,
        decoration: BoxDecoration(
          color:  c.withValues(alpha: 0.75),
          shape:  BoxShape.circle,
          border: Border.all(color: c, width: 1),
          boxShadow: [BoxShadow(color: c.withValues(alpha: 0.4), blurRadius: 5)],
        ),
      ),
      const SizedBox(width: 7),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70,
                  fontSize: 11, fontWeight: FontWeight.w600)),
          Text(range,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35), fontSize: 9)),
        ],
      ),
    ],
  );

  // ════════════════════════════════════════════════════════════════════════
  //  TAPPED POINT POPUP
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildPointPopup() {
    final p = _tappedPt!;
    final c = _riskColor(p.risk);
    return Positioned(
      top: 108, left: 0, right: 0,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 52),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _kCard.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: c.withValues(alpha: 0.42)),
                boxShadow: [
                  BoxShadow(
                      color: c.withValues(alpha: 0.22), blurRadius: 20),
                ],
              ),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color:  c.withValues(alpha: 0.15),
                    shape:  BoxShape.circle,
                    border: Border.all(color: c, width: 1.5),
                  ),
                  child: Center(
                    child: Text('${p.score}',
                        style: TextStyle(color: c,
                            fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${p.risk} Risk Zone',
                        style: TextStyle(color: c,
                            fontSize: 13, fontWeight: FontWeight.w700)),
                    Text('Score: ${p.score} / 100',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 11)),
                    Text(
                        '${p.lat.toStringAsFixed(4)}, '
                            '${p.lng.toStringAsFixed(4)}',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.30),
                            fontSize: 10)),
                  ],
                )),
                GestureDetector(
                  onTap: () => setState(() => _tappedPt = null),
                  child: Icon(Icons.close_rounded,
                      color: Colors.white.withValues(alpha: 0.38), size: 16),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  //  DRAGGABLE BOTTOM SHEET
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildBottomSheet() {
    return DraggableScrollableSheet(
      controller:       _sheetCtrl,
      initialChildSize: 0.14,
      minChildSize:     0.10,
      maxChildSize:     0.72,
      snap:      true,
      snapSizes: const [0.14, 0.36, 0.72],
      builder: (ctx, sc) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            decoration: BoxDecoration(
              color: _kBg.withValues(alpha: 0.88),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: ListView(
              controller: sc,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              children: [

                // ── Handle ──────────────────────────────────────────────
                Center(
                  child: Container(
                    width: 38, height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // ── Score chip (always visible) ──────────────────────
                _buildScoreRow(),
                const SizedBox(height: 14),

                // ── Stats row ────────────────────────────────────────
                if (_heatmapData != null) ...[
                  _buildStatsRow(),
                  const SizedBox(height: 16),
                ],

                // ── Radius slider ────────────────────────────────────
                _buildRadiusRow(),
                const SizedBox(height: 18),

                // ── Route options ────────────────────────────────────
                if (_routeData != null) ...[
                  _label('Route Options'),
                  const SizedBox(height: 10),
                  ..._routeData!.routes.map(_buildRouteCard),
                  const SizedBox(height: 14),
                ],

                // ── Action buttons ───────────────────────────────────
                _buildActions(),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScoreRow() {
    final score = _areaPred?.safetyScore;
    final level = _areaPred?.riskLevel ?? 'Fetching…';
    final c     = score != null ? _riskColor(level) : Colors.white38;
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: c.withValues(alpha: 0.32)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.shield_rounded, color: c, size: 15),
          const SizedBox(width: 6),
          Text(
            score != null ? 'Safety Score  $score/100' : level,
            style: TextStyle(color: c, fontSize: 13,
                fontWeight: FontWeight.w700),
          ),
        ]),
      ),
      if (score != null) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: c.withValues(alpha: 0.22)),
          ),
          child: Text(level,
              style: TextStyle(color: c, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
      ],
    ]);
  }

  Widget _buildStatsRow() {
    final pts  = _heatmapData!.points;
    final s    = pts.where((p) => p.risk == 'Low').length;
    final m    = pts.where((p) => p.risk == 'Medium').length;
    final d    = pts.where((p) => p.risk == 'High').length;
    final avg  = pts.isEmpty ? 0
        : (pts.fold<int>(0, (a, p) => a + p.score) / pts.length).round();
    return Row(children: [
      _statTile('$s',   'Safe',    _kGreen),
      const SizedBox(width: 7),
      _statTile('$m',   'Moderate',_kAmber),
      const SizedBox(width: 7),
      _statTile('$d',   'High',    _kRed),
      const SizedBox(width: 7),
      _statTile('$avg', 'Avg Score',_kPurple),
    ]);
  }

  Widget _statTile(String val, String lbl, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: c.withValues(alpha: 0.18)),
      ),
      child: Column(children: [
        Text(val, style: TextStyle(color: c, fontSize: 17,
            fontWeight: FontWeight.w800)),
        const SizedBox(height: 3),
        Text(lbl, style: const TextStyle(color: Colors.white38, fontSize: 9),
            textAlign: TextAlign.center),
      ]),
    ),
  );

  Widget _buildRadiusRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _label('Scan Radius'),
          const Spacer(),
          Text('${_radiusKm.toStringAsFixed(1)} km',
              style: const TextStyle(color: _kPurple,
                  fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor:   _kPurple,
            inactiveTrackColor: Colors.white12,
            thumbColor:         _kPurple,
            overlayColor:       _kPurple.withValues(alpha: 0.14),
            trackHeight: 3,
            thumbShape:
            const RoundSliderThumbShape(enabledThumbRadius: 8),
          ),
          child: Slider(
            value:     _radiusKm,
            min: 0.5,  max: 3.0,
            divisions: 5,
            onChanged:    (v) => setState(() => _radiusKm = v),
            onChangeEnd:  (_) => _fetchHeatmap(),
          ),
        ),
      ],
    );
  }

  Widget _buildRouteCard(RouteData r) {
    final c      = _scoreColor(r.safetyScore);
    final picked = r == _activeRoute;
    return GestureDetector(
      onTap: () => setState(() {
        _activeRoute = r;
        _subtitle    = 'Via ${r.name}';
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: picked
              ? c.withValues(alpha: 0.11)
              : _kCard.withValues(alpha: 0.60),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: picked
                ? c.withValues(alpha: 0.40)
                : Colors.white.withValues(alpha: 0.07),
            width: picked ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          // Score ring
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape:  BoxShape.circle,
              border: Border.all(color: c, width: 2),
              color:  c.withValues(alpha: 0.10),
            ),
            child: Center(
              child: Text('${r.safetyScore}',
                  style: TextStyle(color: c, fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(r.name,
                      style: const TextStyle(color: Colors.white,
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                if (r.isRecommended)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: _kGreen.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _kGreen.withValues(alpha: 0.38)),
                    ),
                    child: const Text('Safest',
                        style: TextStyle(color: _kGreen,
                            fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
              ]),
              const SizedBox(height: 3),
              Text('${r.duration}  ·  ${r.distance}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
              if (r.factors.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(r.factors.first,
                    style: TextStyle(
                        color: c.withValues(alpha: 0.80), fontSize: 10),
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          )),
        ]),
      ),
    );
  }

  Widget _buildActions() => Row(children: [
    Expanded(child: _actionBtn(
      Icons.analytics_rounded, 'Area Risk Summary', _kPurple,
      _showRiskSummary,
    )),
    const SizedBox(width: 10),
    Expanded(child: _actionBtn(
      Icons.navigation_rounded,
      _loadingRoute
          ? 'Analysing…'
          : (_showRoute ? 'Voice Guide' : 'Start Navigation'),
      _kGreen,
      _loadingRoute
          ? null
          : (_showRoute ? _startVoiceNavigation : _showDestSheet),
    )),
  ]);

  void _startVoiceNavigation() {
    if (_activeRoute == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _VoiceNavigationSheet(
        route: _activeRoute!,
        destination: widget.destinationLabel ?? _subtitle.replaceFirst('Navigating to ', ''),
        destPos: _destPos,
        userPos: _userPos,
        onExit: () {
          Navigator.pop(context);
          setState(() {
            _showRoute = false;
            _destPos   = null;
            _subtitle  = 'Your current area';
          });
        },
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color c,
      VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: c, size: 16),
            const SizedBox(width: 7),
            Flexible(
              child: Text(label,
                  style: TextStyle(color: c, fontSize: 12,
                      fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(t,
      style: TextStyle(
          color: Colors.white.withValues(alpha: 0.65),
          fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3));

  // ════════════════════════════════════════════════════════════════════════
  //  LOADING OVERLAY
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildLoadingOverlay() => Positioned.fill(
    child: ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          color: Colors.black.withValues(alpha: 0.44),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: _kCard,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: _kCardBorder),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 30),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 48, height: 48,
                  child: CircularProgressIndicator(
                    color: _kPurple, strokeWidth: 3,
                    backgroundColor: _kPurple.withValues(alpha: 0.14),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Fetching safety data…',
                    style: TextStyle(color: Colors.white,
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text('AI model analysing your area',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 11)),
              ]),
            ),
          ),
        ),
      ),
    ),
  );

  // ════════════════════════════════════════════════════════════════════════
  //  ERROR BANNER
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildErrorBanner() => Positioned(
    top: 108, left: 14, right: 68,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _kRed.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kRed.withValues(alpha: 0.38)),
          ),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: _kRed, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_error!,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  maxLines: 2),
            ),
            GestureDetector(
              onTap: _fetchHeatmap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: _kRed.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Retry',
                    style: TextStyle(color: _kRed, fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    ),
  );

  // ════════════════════════════════════════════════════════════════════════
  //  DESTINATION BOTTOM SHEET
  // ════════════════════════════════════════════════════════════════════════
  void _showDestSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 20, right: 20, top: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.alt_route_rounded,
                  color: _kPurple, size: 20),
              const SizedBox(width: 10),
              const Text('Plan Safe Route',
                  style: TextStyle(color: Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white38, size: 20),
              ),
            ]),
            const SizedBox(height: 14),
            Text('Quick destinations',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.50),
                    fontSize: 11)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 6,
              children: [
                'Koramangala', 'Indiranagar', 'MG Road',
                'Whitefield',  'JP Nagar',    'HSR Layout',
              ].map((name) => GestureDetector(
                onTap: () { Navigator.pop(context); _setDest(name); },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: _kPurple.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _kPurple.withValues(alpha: 0.28)),
                  ),
                  child: Text(name,
                      style: const TextStyle(color: _kPurple,
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _destCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Enter destination…',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search_rounded,
                    color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1A2332),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _setDest(_destCtrl.text.trim().isEmpty
                      ? 'Koramangala'
                      : _destCtrl.text.trim());
                },
                icon: const Icon(Icons.navigation_rounded),
                label: const Text('Analyse Route'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kPurple,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 22),
          ],
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  //  COORD LOOKUP  (mirrors trip_planning_screen _cityCoords)
  // ════════════════════════════════════════════════════════════════════════
  static const Map<String, List<double>> _knownCoords = {
    // Major Bengaluru areas
    'koramangala':        [12.9279, 77.6271],
    'indiranagar':        [12.9719, 77.6412],
    'mg road':            [12.9756, 77.6101],
    'whitefield':         [12.9698, 77.7499],
    'jp nagar':           [12.9082, 77.5847],
    'hsr layout':         [12.9116, 77.6389],
    'hsr':                [12.9116, 77.6389],
    'bannerghatta':       [12.8635, 77.5978],
    'bannerghatta road':  [12.8900, 77.5978],
    'hebbal':             [13.0358, 77.5970],
    'electronic city':    [12.8399, 77.6770],
    'marathahalli':       [12.9591, 77.6971],
    'btm layout':         [12.9165, 77.6101],
    'jayanagar':          [12.9299, 77.5826],
    'malleshwaram':       [13.0030, 77.5650],
    'yelahanka':          [13.1007, 77.5963],
    'rajajinagar':        [12.9936, 77.5522],
    'kengeri':            [12.9114, 77.4808],
    'bommanahalli':       [12.8960, 77.6260],
    'majestic':           [12.9779, 77.5713],
    'yeshwanthpur':       [13.0200, 77.5340],
    'bellandur':          [12.9283, 77.6781],
    'sarjapur':           [12.8559, 77.7826],
    'sarjapur road':      [12.9050, 77.7000],
    'domlur':             [12.9606, 77.6405],
    'richmond road':      [12.9598, 77.6001],
    'cunningham road':    [12.9856, 77.5901],
    'rt nagar':           [13.0216, 77.5958],
    'kr puram':           [13.0050, 77.6966],
    'devanahalli':        [13.2457, 77.7148],
    'kolar':              [13.1360, 78.1294],
    'mysore':             [12.2958, 76.6394],
    'mysuru':             [12.2958, 76.6394],
    'tumkur':             [13.3379, 77.1010],
    'mangalore':          [12.9141, 74.8560],
    'hassan':             [13.0035, 76.0997],
    'ramanagara':         [12.7157, 77.2824],
    'bangalore':          [12.9716, 77.5946],
    'bengaluru':          [12.9716, 77.5946],
  };

  List<double>? _resolveDestCoords(String dest) {
    // Try raw lat,lng
    final clean = dest.trim().replaceAll('⌖', '').trim();
    final regex = RegExp(r'^([+-]?\d{1,3}(?:\.\d+)?)[,\s]+([+-]?\d{1,3}(?:\.\d+)?)$');
    final m = regex.firstMatch(clean);
    if (m != null) {
      final lat = double.tryParse(m.group(1)!);
      final lng = double.tryParse(m.group(2)!);
      if (lat != null && lng != null && lat >= -90 && lat <= 90) {
        return [lat, lng];
      }
    }
    final key = dest.trim().toLowerCase();
    if (_knownCoords.containsKey(key)) return _knownCoords[key];
    for (final e in _knownCoords.entries) {
      if (key.contains(e.key)) return e.value;
    }
    for (final e in _knownCoords.entries) {
      if (e.key.contains(key) && key.length >= 4) return e.value;
    }
    return null;
  }

  void _setDest(String name) {
    if (_userPos == null) return;
    // Try to resolve real coords; fall back to slight offset only if unknown
    final coords = _resolveDestCoords(name);
    final LatLng dest = coords != null
        ? LatLng(coords[0], coords[1])
        : LatLng(
      _userPos!.latitude  + (math.Random(name.hashCode).nextDouble() - 0.5) * 0.07,
      _userPos!.longitude + (math.Random(name.hashCode + 1).nextDouble() - 0.5) * 0.07,
    );
    setState(() {
      _destPos  = dest;
      _subtitle = 'Navigating to $name';
    });
    try {
      _mapCtrl.fitCamera(CameraFit.bounds(
        bounds:  LatLngBounds(_userPos!, dest),
        padding: const EdgeInsets.all(90),
      ));
    } catch (_) {}
    _fetchRoute();
  }

  // ════════════════════════════════════════════════════════════════════════
  //  RISK SUMMARY BOTTOM SHEET
  // ════════════════════════════════════════════════════════════════════════
  void _showRiskSummary() {
    if (_heatmapData == null) { _snack('No data yet — load heatmap first'); return; }
    final pts = _heatmapData!.points;
    final s   = pts.where((p) => p.risk == 'Low').length;
    final m   = pts.where((p) => p.risk == 'Medium').length;
    final d   = pts.where((p) => p.risk == 'High').length;
    final avg = pts.isEmpty ? 0
        : (pts.fold<int>(0, (a, p) => a + p.score) / pts.length).round();
    final dom = d > s ? 'High' : m > s ? 'Medium' : 'Low';
    final dc  = _riskColor(dom);

    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.analytics_rounded, color: dc, size: 22),
              const SizedBox(width: 10),
              const Text('Area Risk Summary',
                  style: TextStyle(color: Colors.white,
                      fontSize: 17, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 20),
            _summRow('Avg Safety Score', '$avg / 100', _kPurple),
            _summRow('Safe Zones',        '$s areas',  _kGreen),
            _summRow('Moderate Risk',     '$m areas',  _kAmber),
            _summRow('High Risk',         '$d areas',  _kRed),
            _summRow('Dominant Level',    dom,         dc),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: dc.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: dc.withValues(alpha: 0.28)),
              ),
              child: Row(children: [
                Icon(Icons.info_outline_rounded, color: dc, size: 15),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    dom == 'Low'
                        ? 'Generally safe. Stay aware of surroundings.'
                        : dom == 'Medium'
                        ? 'Exercise caution. Avoid isolated roads at night.'
                        : 'High-risk area. Use safe routes, keep contacts notified.',
                    style: TextStyle(color: dc, fontSize: 12),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _summRow(String lbl, String val, Color c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(children: [
      Text(lbl,
          style: const TextStyle(color: Colors.white54, fontSize: 13)),
      const Spacer(),
      Text(val,
          style: TextStyle(color: c, fontSize: 13,
              fontWeight: FontWeight.w700)),
    ]),
  );
}

// ════════════════════════════════════════════════════════════════════════════
//  VOICE NAVIGATION SHEET
//  Shows score, risk summary, step-by-step guide, exit button
// ════════════════════════════════════════════════════════════════════════════

class _VoiceNavigationSheet extends StatefulWidget {
  final RouteData  route;
  final String     destination;
  final LatLng?    destPos;
  final LatLng?    userPos;
  final VoidCallback onExit;

  const _VoiceNavigationSheet({
    required this.route,
    required this.destination,
    required this.destPos,
    required this.userPos,
    required this.onExit,
  });

  @override
  State<_VoiceNavigationSheet> createState() => _VoiceNavigationSheetState();
}

class _VoiceNavigationSheetState extends State<_VoiceNavigationSheet> {
  int _stepIndex = 0;

  // Simulated turn-by-turn steps derived from route name
  List<Map<String, dynamic>> get _steps => [
    {'icon': Icons.straight,       'text': 'Proceed straight for 500 m',         'dist': '500 m'},
    {'icon': Icons.turn_right,     'text': 'Turn right onto the main road',       'dist': '1.2 km'},
    {'icon': Icons.straight,       'text': 'Continue for 2 km on lit road',       'dist': '2.0 km'},
    {'icon': Icons.turn_left,      'text': 'Turn left – well-lit area ahead',     'dist': '800 m'},
    {'icon': Icons.straight,       'text': 'Stay on the safe corridor',           'dist': '1.5 km'},
    {'icon': Icons.flag_rounded,   'text': 'Arrive at ${widget.destination}',     'dist': ''},
  ];

  Color get _scoreColor {
    final s = widget.route.safetyScore;
    if (s >= 70) return _kGreen;
    if (s >= 45) return _kAmber;
    return _kRed;
  }

  double? _distanceKm() {
    if (widget.userPos == null || widget.destPos == null) return null;
    const d = Distance();
    return d.as(LengthUnit.Kilometer, widget.userPos!, widget.destPos!);
  }

  @override
  Widget build(BuildContext context) {
    final c     = _scoreColor;
    final score = widget.route.safetyScore;
    final dist  = _distanceKm();

    return Container(
      decoration: const BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Handle ──────────────────────────────────────────────────────
          Center(
            child: Container(
              width: 38, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── Header row ──────────────────────────────────────────────────
          Row(children: [
            Icon(Icons.navigation_rounded, color: c, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Navigating to ${widget.destination}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${widget.route.duration}  ·  ${widget.route.distance}'
                        '${dist != null ? '  ·  ${dist.toStringAsFixed(1)} km away' : ''}',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // ── Score + risk summary ─────────────────────────────────────────
          Row(children: [
            // Score ring
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                shape:  BoxShape.circle,
                border: Border.all(color: c, width: 2.5),
                color:  c.withValues(alpha: 0.12),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$score',
                        style: TextStyle(color: c,
                            fontSize: 16, fontWeight: FontWeight.w900)),
                    Text('Safe',
                        style: TextStyle(color: c,
                            fontSize: 8, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.route.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6, runSpacing: 4,
                    children: widget.route.factors.take(3).map((f) {
                      final isGood = !f.toLowerCase().contains('isolated') &&
                          !f.toLowerCase().contains('avoid') &&
                          !f.toLowerCase().contains('limited');
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isGood ? _kGreen : _kAmber)
                              .withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            isGood ? Icons.check_circle : Icons.warning_amber,
                            color: isGood ? _kGreen : _kAmber,
                            size: 10,
                          ),
                          const SizedBox(width: 3),
                          Text(f,
                              style: TextStyle(
                                  color: isGood ? _kGreen : _kAmber,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600)),
                        ]),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 18),

          // ── Step-by-step navigation ──────────────────────────────────────
          const Text('ROUTE OVERVIEW',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2)),
          const SizedBox(height: 10),

          SizedBox(
            height: 130,
            child: ListView.builder(
              scrollDirection: Axis.vertical,
              itemCount: _steps.length,
              itemBuilder: (_, i) {
                final step    = _steps[i];
                final current = i == _stepIndex;
                final done    = i < _stepIndex;
                final stepColor = done
                    ? Colors.white24
                    : current
                    ? c
                    : Colors.white38;
                return GestureDetector(
                  onTap: () => setState(() => _stepIndex = i),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: current
                          ? c.withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: current
                            ? c.withValues(alpha: 0.35)
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(children: [
                      Icon(step['icon'] as IconData,
                          color: stepColor, size: 16),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(step['text'] as String,
                            style: TextStyle(
                                color: done
                                    ? Colors.white30
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight: current
                                    ? FontWeight.w700
                                    : FontWeight.normal)),
                      ),
                      if ((step['dist'] as String).isNotEmpty)
                        Text(step['dist'] as String,
                            style: TextStyle(
                                color: stepColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w600)),
                    ]),
                  ),
                );
              },
            ),
          ),

          // ── Next / Prev step ────────────────────────────────────────────
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _stepIndex > 0
                    ? () => setState(() => _stepIndex--)
                    : null,
                icon: const Icon(Icons.chevron_left, size: 16),
                label: const Text('Prev'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white54,
                  side: const BorderSide(color: Colors.white12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _stepIndex < _steps.length - 1
                    ? () => setState(() => _stepIndex++)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 16),
                label: const Text('Next Step'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c,
                  foregroundColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),

          // ── Exit Navigation ──────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onExit,
              icon: const Icon(Icons.close_rounded,
                  color: _kRed, size: 16),
              label: const Text('Exit Navigation',
                  style: TextStyle(color: _kRed)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _kRed.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}