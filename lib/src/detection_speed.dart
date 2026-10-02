/// How often detections are delivered.
library;

/// How aggressively repeated detections are suppressed.
///
/// A camera delivers 30 frames a second, and a barcode held in front of it is
/// recognized in most of them. Without suppression `onDetect` would fire roughly
/// 30 times a second with the same value, which is almost never what an
/// application wants.
///
/// All three modes are implemented on the Dart side of the boundary, in one
/// place, so the behaviour is identical on both platforms and is unit tested.
/// The native recognizers always report what they see; the gate decides what
/// reaches `onDetect`.
enum DetectionSpeed {
  /// Emit every detection event the platform reports.
  ///
  /// No suppression at all. `onDetect` can fire at the frame rate. Use this only
  /// when you are tracking a barcode's movement or measuring the pipeline, and
  /// be aware your callback then runs on the same thread the UI does.
  unrestricted,

  /// Emit at most one capture per
  /// [MobileScannerController.detectionTimeout]. The default.
  ///
  /// Exact rule: when a capture is emitted, every capture arriving in the
  /// following [MobileScannerController.detectionTimeout] is dropped, whatever
  /// it contains. The default timeout is 250 ms, so a barcode held still
  /// produces about four events a second.
  ///
  /// This throttles by time, not by value: a *different* barcode entering the
  /// frame during the window is also dropped, and will be reported by the next
  /// frame after the window closes. That costs at most one timeout of latency
  /// and keeps the rule simple enough to reason about.
  normal,

  /// Emit a given barcode once, then not again while it stays visible.
  ///
  /// Exact rule: a detection is suppressed when a barcode with the same
  /// [Barcode.dedupKey] was last *seen* less than
  /// [MobileScannerController.duplicateCooldown] ago. "Seen" means observed in
  /// an incoming detection, whether or not that detection was emitted, so a
  /// barcode that stays in frame keeps renewing its own suppression and is never
  /// re-emitted. It becomes eligible again only once it has been absent for the
  /// full cooldown, which in practice means it left the frame and came back. The
  /// default cooldown is one second.
  ///
  /// A barcode with no [Barcode.dedupKey], meaning it carries neither text nor
  /// raw bytes, cannot be identified across frames and is never suppressed.
  ///
  /// Suppression is per barcode, not per capture: a frame holding one
  /// already-seen barcode and one new one emits a capture containing only the
  /// new one.
  noDuplicates,
}
