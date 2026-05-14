// sos_service.dart
// ─────────────────────────────────────────────────────────────
// Handles all SOS alert sending: SMS, WhatsApp, Police call.
// Contacts are fetched from Supabase instead of being hardcoded.
// ─────────────────────────────────────────────────────────────

import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'supabase_service.dart';

class SOSService {
  static const String policeNumber = "112";

  // ── Fetch contacts from Supabase ───────────────────────────
  /// Returns phone numbers from the user's saved contacts.
  /// Falls back to an empty list if not logged in or no contacts saved.
  Future<List<String>> _getContacts() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return [];

      final data = await supabase
          .from('contacts')
          .select('phone')
          .eq('user_id', user.id);

      return (data as List)
          .map((e) => e['phone'] as String)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Step 1: Get location ───────────────────────────────────
  Future<String?> getLocationLink() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 8));

      return "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    } catch (_) {
      return null;
    }
  }

  // ── Step 2: Send SMS ───────────────────────────────────────
  Future<bool> sendSMS(String locationLink) async {
    final contacts = await _getContacts();
    if (contacts.isEmpty) return false;

    final body    = Uri.encodeComponent(_buildMessage(locationLink));
    final numbers = contacts.join(",");
    final uri     = Uri.parse("smsto:$numbers?body=$body");

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  // ── Step 3: Send WhatsApp ──────────────────────────────────
  Future<bool> sendWhatsApp(String locationLink) async {
    final encoded = Uri.encodeComponent(_buildMessage(locationLink));

    final waUri = Uri.parse("whatsapp://send?text=$encoded");
    if (await canLaunchUrl(waUri)) {
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
      return true;
    }

    final waFallback = Uri.parse("https://wa.me/?text=$encoded");
    if (await canLaunchUrl(waFallback)) {
      await launchUrl(waFallback, mode: LaunchMode.externalApplication);
      return true;
    }

    return false;
  }

  // ── Step 4: Call police ────────────────────────────────────
  Future<bool> callPolice() async {
    final uri = Uri.parse("tel:$policeNumber");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    return false;
  }

  // ── Helper ─────────────────────────────────────────────────
  String _buildMessage(String locationLink) =>
      "🚨 EMERGENCY! I need help immediately.\n"
          "📍 My location: $locationLink\n"
          "Please call emergency services or come to my location!";
}
