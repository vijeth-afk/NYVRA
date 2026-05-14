// sos_controller.dart
// ─────────────────────────────────────────────────────────────
// ✅ Logs every SOS to Supabase sos_logs table
// ✅ Also inserts a notification row so Notifications page shows it
// ─────────────────────────────────────────────────────────────

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'sos_service.dart';

enum SOSStep { idle, locating, sms, whatsapp, calling, tracking, done }

class SOSController extends ChangeNotifier {
  final SOSService _service = SOSService();

  SOSStep  currentStep  = SOSStep.idle;
  String   locationText = "Fetching location...";
  String?  locationLink;
  bool     smsSent      = false;
  bool     whatsAppSent = false;
  bool     policeCalled = false;
  bool     isTracking   = false;
  String?  errorMessage;

  StreamSubscription<Position>? _posStream;

  // ── Supabase client ────────────────────────────────────────
  final _sb = Supabase.instance.client;

  // ── Public: kick off the full SOS flow ────────────────────
  Future<void> startSOS() async {
    errorMessage = null;

    // Step 1 — Get location
    _setStep(SOSStep.locating);
    locationLink = await _service.getLocationLink();
    final link = locationLink ?? "Location unavailable";
    locationText = locationLink != null
        ? "Location acquired"
        : "Location unavailable — sending alert anyway";
    notifyListeners();

    // Step 2 — Send SMS
    _setStep(SOSStep.sms);
    smsSent = await _service.sendSMS(link);
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 800));

    // Step 3 — Send WhatsApp
    _setStep(SOSStep.whatsapp);
    whatsAppSent = await _service.sendWhatsApp(link);
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 800));

    // Step 4 — Call police
    _setStep(SOSStep.calling);
    policeCalled = await _service.callPolice();
    notifyListeners();

    // Step 5 — Log to Supabase
    await _logSOSToSupabase(link);

    // Step 6 — Start live location tracking
    _setStep(SOSStep.tracking);
    _startLiveTracking();

    _setStep(SOSStep.done);
  }

  // ── Log SOS to Supabase ────────────────────────────────────
  Future<void> _logSOSToSupabase(String locationUrl) async {
    try {
      final user = _sb.auth.currentUser;
      if (user == null) return;

      // Parse lat/lng from the Google Maps URL if available
      double? lat;
      double? lng;
      if (locationLink != null) {
        final parts = locationLink!
            .replaceAll('https://maps.google.com/?q=', '')
            .split(',');
        if (parts.length == 2) {
          lat = double.tryParse(parts[0]);
          lng = double.tryParse(parts[1]);
        }
      }

      // ✅ Insert into sos_logs
      await _sb.from('sos_logs').insert({
        'user_id':       user.id,
        'latitude':      lat,
        'longitude':     lng,
        'location_url':  locationUrl,
        'sms_sent':      smsSent,
        'whatsapp_sent': whatsAppSent,
        'police_called': policeCalled,
      });

      // ✅ Insert a notification so it shows in Notifications page
      await _sb.from('notifications').insert({
        'user_id': user.id,
        'title':   '🚨 SOS Alert Sent',
        'body':    'Emergency alert sent to your trusted contacts'
            '${policeCalled ? ' and police called (112)' : ''}.',
        'is_read': false,
      });

    } catch (e) {
      // Don't crash the SOS flow if logging fails
      debugPrint('SOS log error: $e');
    }
  }

  // ── Live GPS stream ────────────────────────────────────────
  void _startLiveTracking() {
    isTracking = true;
    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(
          (pos) {
        locationText =
        "📍 ${pos.latitude.toStringAsFixed(5)}, "
            "${pos.longitude.toStringAsFixed(5)}";
        notifyListeners();
      },
      onError: (_) {
        locationText = "Lost GPS signal";
        notifyListeners();
      },
    );
  }

  // ── Helpers ────────────────────────────────────────────────
  void _setStep(SOSStep step) {
    currentStep = step;
    notifyListeners();
  }

  void disposeController() {
    _posStream?.cancel();
  }
}
