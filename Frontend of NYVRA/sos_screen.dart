// sos_screen.dart
// ─────────────────────────────────────────────────────────────
// SOS UI — each row reflects a REAL action status from
// SOSController, not a fake timer.
// ─────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'sos_controller.dart';

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen> {
  final _controller = SOSController();

  @override
  void initState() {
    super.initState();
    _controller.startSOS();
  }

  @override
  void dispose() {
    _controller.disposeController();
    super.dispose();
  }

  // ── UI ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFFB71C1C),
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 24),

                // ── SOS title ──
                const Icon(Icons.sos_rounded, color: Colors.white, size: 52),
                const SizedBox(height: 8),
                const Text(
                  "Emergency Alert",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _stepLabel(_controller.currentStep),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 28),

                // ── Action list ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _actionRow(
                        icon: Icons.location_on_rounded,
                        label: "Getting your location",
                        status: _locationStatus(),
                      ),
                      const SizedBox(height: 10),
                      _actionRow(
                        icon: Icons.sms_rounded,
                        label: "SMS to trusted contacts",
                        status: _sentStatus(_controller.smsSent,
                            SOSStep.sms),
                      ),
                      const SizedBox(height: 10),
                      _actionRow(
                        icon: Icons.chat_rounded,
                        label: "WhatsApp alert",
                        status: _sentStatus(_controller.whatsAppSent,
                            SOSStep.whatsapp),
                      ),
                      const SizedBox(height: 10),
                      _actionRow(
                        icon: Icons.phone_rounded,
                        label: "Calling police (112)",
                        status: _sentStatus(_controller.policeCalled,
                            SOSStep.calling),
                      ),
                      const SizedBox(height: 10),
                      _actionRow(
                        icon: Icons.radar_rounded,
                        label: "Live location tracking",
                        status: _trackingStatus(),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ── Location display ──
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.location_searching_rounded,
                          color: Colors.white70, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _controller.locationText,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // ── Cancel button ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      label: const Text(
                        "Cancel SOS",
                        style: TextStyle(color: Colors.white70),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.3)),
                        padding:
                        const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Row widget ─────────────────────────────────────────────

  Widget _actionRow({
    required IconData icon,
    required String label,
    required _RowStatus status,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13)),
          ),
          _statusWidget(status),
        ],
      ),
    );
  }

  Widget _statusWidget(_RowStatus status) {
    switch (status) {
      case _RowStatus.pending:
        return Icon(Icons.radio_button_unchecked,
            color: Colors.white.withValues(alpha: 0.35), size: 20);
      case _RowStatus.loading:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              color: Colors.white, strokeWidth: 2),
        );
      case _RowStatus.done:
        return const Icon(Icons.check_circle_rounded,
            color: Colors.greenAccent, size: 20);
      case _RowStatus.failed:
        return const Icon(Icons.cancel_rounded,
            color: Colors.orange, size: 20);
    }
  }

  // ── Status helpers ─────────────────────────────────────────

  _RowStatus _locationStatus() {
    if (_controller.currentStep == SOSStep.locating) {
      return _RowStatus.loading;
    }
    if (_controller.currentStep == SOSStep.idle) {
      return _RowStatus.pending;
    }
    return _RowStatus.done;
  }

  _RowStatus _sentStatus(bool sent, SOSStep thisStep) {
    final idx = SOSStep.values.indexOf(_controller.currentStep);
    final myIdx = SOSStep.values.indexOf(thisStep);
    if (idx < myIdx) return _RowStatus.pending;
    if (idx == myIdx) return _RowStatus.loading;
    return sent ? _RowStatus.done : _RowStatus.failed;
  }

  _RowStatus _trackingStatus() {
    if (_controller.currentStep == SOSStep.tracking) {
      return _RowStatus.loading;
    }
    if (_controller.isTracking) return _RowStatus.done;
    return _RowStatus.pending;
  }

  String _stepLabel(SOSStep step) {
    switch (step) {
      case SOSStep.idle:      return "Initializing...";
      case SOSStep.locating:  return "Acquiring GPS location...";
      case SOSStep.sms:       return "Sending SMS alert...";
      case SOSStep.whatsapp:  return "Sending WhatsApp alert...";
      case SOSStep.calling:   return "Calling emergency services...";
      case SOSStep.tracking:  return "Starting live tracking...";
      case SOSStep.done:      return "All alerts sent ✓";
    }
  }
}

// ── Internal enum for row display state ────────────────────────
enum _RowStatus { pending, loading, done, failed }
