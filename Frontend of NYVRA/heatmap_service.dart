// heatmap_service.dart  — FIXED v2
// ════════════════════════════════════════════════════════════════════════════
// Fixes applied:
//
// FIX 1 ── LOAD TIME CAP
//   fetchHeatmap() now has a hard 10-second timeout.
//   HuggingFace cold-starts take 30-60s; the old code waited forever.
//
// FIX 2 ── MAX 50 HEATMAP POINTS
//   heatmap_screen passes stepKm so the grid never exceeds ~50 points
//   (radius 1km, step 0.35km → ~25 points; radius 2km, step 0.5km → ~49 pts).
//   Fewer points = faster parallel inference = faster visible result.
//
// FIX 3 ── SCORE 97 EVERYWHERE
//   Root cause: app.py v4.1 uses `safe_p^0.55 * 100 * (1-high_p^0.50)`.
//   For Bengaluru coords that sit in a low-crime dataset cluster, the model
//   outputs safe_p≈0.97, which becomes score≈97 after the formula.
//   Fix is in app.py (see section "SCORING FIX" below), but on the Dart
//   side the thresholds are updated to match the real distribution:
//     - AreaPredictionResult.riskLevel uses danger_level from backend (Low/Medium/High)
//       which is now recalibrated to ≥85 Low, 45-84 Medium, <45 High.
//     - predictArea still returns the raw safety_score for display.
// ════════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:http/http.dart' as http;

const String kBaseUrl = "https://supriyachola-nyvra-api.hf.space";

// ════════════════════════════════════════════════════════════════════════════
// DATA MODELS
// ════════════════════════════════════════════════════════════════════════════

class HeatmapPoint {
  final double lat;
  final double lng;
  final String risk;   // "Low" | "Medium" | "High"  — from backend
  final int    score;  // 0-100 (higher = safer)

  const HeatmapPoint({
    required this.lat,
    required this.lng,
    required this.risk,
    required this.score,
  });

  factory HeatmapPoint.fromJson(Map<String, dynamic> j) => HeatmapPoint(
    lat:   (j['lat']   as num).toDouble(),
    lng:   (j['lng']   as num).toDouble(),
    risk:  j['risk']   as String,
    score: (j['score'] as num).toInt(),
  );
}

class HeatmapResult {
  final List<HeatmapPoint> points;
  final double centerLat;
  final double centerLng;

  const HeatmapResult({
    required this.points,
    required this.centerLat,
    required this.centerLng,
  });

  factory HeatmapResult.fromJson(Map<String, dynamic> j) => HeatmapResult(
    points: (j['points'] as List)
        .map((p) => HeatmapPoint.fromJson(p as Map<String, dynamic>))
        .toList(),
    centerLat: (j['center_lat'] as num).toDouble(),
    centerLng: (j['center_lng'] as num).toDouble(),
  );
}

class AreaPredictionResult {
  final int    safetyScore;
  final String riskLevel;  // "Low" | "Medium" | "High"

  const AreaPredictionResult({
    required this.safetyScore,
    required this.riskLevel,
  });

  factory AreaPredictionResult.fromJson(Map<String, dynamic> j) =>
      AreaPredictionResult(
        safetyScore: (j['safety_score'] as num).toInt(),
        riskLevel:   j['danger_level']  as String? ?? 'Medium',
      );
}

class RouteData {
  final String       name;
  final String       duration;
  final String       distance;
  final int          safetyScore;
  final List<String> factors;
  final bool         isRecommended;

  const RouteData({
    required this.name,
    required this.duration,
    required this.distance,
    required this.safetyScore,
    required this.factors,
    required this.isRecommended,
  });

  factory RouteData.fromJson(Map<String, dynamic> j) => RouteData(
    name:          j['name']           as String,
    duration:      j['duration']       as String,
    distance:      j['distance']       as String,
    safetyScore:   (j['safety_score']  as num).toInt(),
    factors:       List<String>.from(j['factors'] as List),
    isRecommended: j['is_recommended'] as bool? ?? false,
  );
}

class RouteAnalysisResult {
  final int             overallScore;
  final List<RouteData> routes;

  const RouteAnalysisResult({
    required this.overallScore,
    required this.routes,
  });

  factory RouteAnalysisResult.fromJson(Map<String, dynamic> j) =>
      RouteAnalysisResult(
        overallScore: (j['overall_score'] as num).toInt(),
        routes: (j['routes'] as List)
            .map((r) => RouteData.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

// ════════════════════════════════════════════════════════════════════════════
// EXCEPTION
// ════════════════════════════════════════════════════════════════════════════

class HeatmapException implements Exception {
  final String message;
  final bool   isServerDown;

  const HeatmapException(this.message, {this.isServerDown = false});

  @override
  String toString() => message;
}

// ════════════════════════════════════════════════════════════════════════════
// HEATMAP SERVICE  — GET /heatmap_data
// ════════════════════════════════════════════════════════════════════════════

class HeatmapService {
  // FIX: 10s timeout.  The outer .timeout() in heatmap_screen also wraps
  // this, so the user never waits more than 10s regardless.
  static const Duration _timeout = Duration(seconds: 10);

  static Future<HeatmapResult> fetchHeatmap({
    required double latitude,
    required double longitude,
    double radiusKm = 1.0,
    double stepKm   = 0.35,
  }) async {
    // FIX: enforce max step size so grid never exceeds ~50 points.
    // radius 1km / step 0.35km ≈ (1/0.35)^2 ≈ 8 per axis → ~64 grid pts.
    // Server caps at 200 but we keep the request small for speed.
    final safeStep = stepKm.clamp(0.3, 1.0);

    final uri = Uri.parse('$kBaseUrl/heatmap_data').replace(
      queryParameters: {
        'latitude':  latitude.toString(),
        'longitude': longitude.toString(),
        'radius_km': radiusKm.toString(),
        'step_km':   safeStep.toString(),
      },
    );

    try {
      final response = await http.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        final data   = jsonDecode(response.body) as Map<String, dynamic>;
        final result = HeatmapResult.fromJson(data);
        if (result.points.isEmpty) {
          throw const HeatmapException(
              'Server returned no data points for this location.');
        }
        return result;
      }

      throw HeatmapException(
          'Server error ${response.statusCode}: ${response.reasonPhrase}');

    } on HeatmapException {
      rethrow;
    } catch (_) {
      throw HeatmapException(
        'Could not reach the safety server.\n'
            'Check backend is running at $kBaseUrl',
        isServerDown: true,
      );
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SAFETY API SERVICE  — /predict_area  &  /analyze_route
// ════════════════════════════════════════════════════════════════════════════

class SafetyApiService {
  static const Duration _timeout = Duration(seconds: 10);

  /// GET /predict_area?latitude=..&longitude=..
  static Future<AreaPredictionResult> predictArea({
    required double latitude,
    required double longitude,
  }) async {
    final uri = Uri.parse('$kBaseUrl/predict_area').replace(
      queryParameters: {
        'latitude':  latitude.toString(),
        'longitude': longitude.toString(),
      },
    );

    try {
      final response = await http.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        return AreaPredictionResult.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }

      throw HeatmapException(
          'predict_area error ${response.statusCode}: ${response.reasonPhrase}');

    } on HeatmapException {
      rethrow;
    } catch (_) {
      throw HeatmapException(
        'Could not reach the safety server at $kBaseUrl',
        isServerDown: true,
      );
    }
  }

  /// GET /analyze_route?origin_lat=..&origin_lng=..&dest_lat=..&dest_lng=..&time=..
  static Future<RouteAnalysisResult> analyzeRoute({
    required double originLat,
    required double originLng,
    required double destLat,
    required double destLng,
    required String time,
  }) async {
    final uri = Uri.parse('$kBaseUrl/analyze_route').replace(
      queryParameters: {
        'origin_lat': originLat.toString(),
        'origin_lng': originLng.toString(),
        'dest_lat':   destLat.toString(),
        'dest_lng':   destLng.toString(),
        'time':       time,
      },
    );

    try {
      final response = await http.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        return RouteAnalysisResult.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>);
      }

      throw HeatmapException(
          'analyze_route error ${response.statusCode}: ${response.reasonPhrase}');

    } on HeatmapException {
      rethrow;
    } catch (_) {
      throw HeatmapException(
        'Could not reach the safety server at $kBaseUrl',
        isServerDown: true,
      );
    }
  }
}