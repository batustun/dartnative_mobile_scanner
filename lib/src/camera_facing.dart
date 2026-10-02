/// Which physical camera the scanner opens.
library;

/// The camera to scan with.
///
/// Deliberately limited to the two lenses every phone exposes. Richer lens
/// selection (ultra wide, telephoto) is not modelled here, because the
/// framework has no camera-device abstraction to align with yet and inventing
/// one in a 0.1.0 would commit the API to a shape that may not match the
/// eventual canonical one.
enum CameraFacing {
  /// The user-facing camera.
  ///
  /// Usually has no torch. [MobileScannerController.toggleTorch] reports that
  /// honestly rather than pretending to succeed.
  front(0, 'front'),

  /// The world-facing camera. The default, and the right one for scanning.
  back(1, 'back');

  const CameraFacing(this.value, this.wireName);

  /// The wire value shared with the native side.
  ///
  /// Matches CameraX `CameraSelector.LENS_FACING_FRONT` (0) and
  /// `LENS_FACING_BACK` (1), so Android needs no translation table.
  final int value;

  /// The stable identifier used in native event payloads.
  final String wireName;

  /// The facing whose [wireName] is [name], or `null` when none matches.
  static CameraFacing? fromWireName(String name) {
    for (final facing in values) {
      if (facing.wireName == name) return facing;
    }
    return null;
  }
}
