/// The suppression rules that decide which detections reach `onDetect`.
library;

import '../barcode.dart';
import '../barcode_capture.dart';
import '../detection_speed.dart';

/// Applies [DetectionSpeed] to the stream of raw detections.
///
/// Kept free of FFI, timers and platform calls so the rules can be unit tested
/// exactly: time is supplied by the caller rather than read from the clock. The
/// controller owns one gate and feeds every native detection through
/// [admit].
///
/// Not part of the public API.
class DetectionGate {
  /// Creates a gate.
  DetectionGate({
    required this.speed,
    required this.detectionTimeout,
    required this.duplicateCooldown,
  });

  /// Which rule to apply. See [DetectionSpeed] for the exact semantics of each.
  final DetectionSpeed speed;

  /// The throttle window used by [DetectionSpeed.normal].
  final Duration detectionTimeout;

  /// The absence window used by [DetectionSpeed.noDuplicates].
  final Duration duplicateCooldown;

  /// When the last capture was emitted, for [DetectionSpeed.normal].
  DateTime? _lastEmittedAt;

  /// Last time each identity was observed, for [DetectionSpeed.noDuplicates].
  ///
  /// Pruned on every call, so it stays proportional to the number of distinct
  /// barcodes seen within one cooldown rather than growing for the session's
  /// lifetime.
  final Map<String, DateTime> _lastSeenAt = <String, DateTime>{};

  /// Decides what to deliver for a detection observed at [now].
  ///
  /// Returns the capture to hand to `onDetect`, or `null` when the detection is
  /// entirely suppressed. The returned capture may contain fewer barcodes than
  /// [barcodes] under [DetectionSpeed.noDuplicates], because suppression there is
  /// per barcode.
  ///
  /// [barcodes] is expected to be non-empty; an empty detection is treated as
  /// nothing to report and yields `null`.
  BarcodeCapture? admit(
    List<Barcode> barcodes,
    DateTime now, {
    required BarcodeCapture Function(List<Barcode> accepted) build,
  }) {
    if (barcodes.isEmpty) return null;

    switch (speed) {
      case DetectionSpeed.unrestricted:
        return build(barcodes);

      case DetectionSpeed.normal:
        final last = _lastEmittedAt;
        if (last != null && now.difference(last) < detectionTimeout) {
          return null;
        }
        _lastEmittedAt = now;
        return build(barcodes);

      case DetectionSpeed.noDuplicates:
        _pruneSeen(now);

        final accepted = <Barcode>[];
        for (final barcode in barcodes) {
          final key = barcode.dedupKey;
          if (key == null) {
            // Unidentifiable across frames, so suppression cannot apply.
            accepted.add(barcode);
            continue;
          }
          final lastSeen = _lastSeenAt[key];
          if (lastSeen == null ||
              now.difference(lastSeen) >= duplicateCooldown) {
            accepted.add(barcode);
          }
          // Renew on every observation, emitted or not, so a barcode held in
          // frame keeps extending its own suppression.
          _lastSeenAt[key] = now;
        }

        if (accepted.isEmpty) return null;
        return build(accepted);
    }
  }

  /// Forgets all suppression history.
  ///
  /// Called when the session stops or the camera is switched, so that the first
  /// barcode seen after restarting is always reported rather than being
  /// suppressed by what was visible before.
  void reset() {
    _lastEmittedAt = null;
    _lastSeenAt.clear();
  }

  void _pruneSeen(DateTime now) {
    if (_lastSeenAt.isEmpty) return;
    _lastSeenAt.removeWhere(
      (_, seenAt) => now.difference(seenAt) >= duplicateCooldown,
    );
  }
}
