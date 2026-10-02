/// Validation for the normalized scan window.
library;

import 'package:dartnative/dartnative.dart' show Rect;

import 'exceptions.dart';

/// Checks that [window] is a usable scan window and throws when it is not.
///
/// A scan window is expressed in **normalized** coordinates: `left`, `top`,
/// `width` and `height` all run `0.0` to `1.0`, relative to the analyzed image
/// in its upright orientation, origin at the top left. Normalized coordinates
/// are used rather than pixels so the same value is correct on every device,
/// resolution and aspect ratio.
///
/// The constraints, all of which produce
/// [MobileScannerErrorCode.invalidScanWindow]:
///
/// * every edge is finite, so no `NaN` and no infinity;
/// * `width` and `height` are strictly greater than zero, since a zero-area
///   window would silently reject every barcode;
/// * the rectangle lies inside the unit square, so `left >= 0`, `top >= 0`,
///   `right <= 1` and `bottom <= 1`.
///
/// Validated eagerly, at the point the window is supplied, so a mistake surfaces
/// as a typed error at mount instead of as a scanner that mysteriously never
/// detects anything.
void validateScanWindow(Rect window) {
  if (!window.isFinite) {
    throw MobileScannerException(
      MobileScannerErrorCode.invalidScanWindow,
      'scanWindow must be finite, got $window.',
    );
  }
  if (window.width <= 0 || window.height <= 0) {
    throw MobileScannerException(
      MobileScannerErrorCode.invalidScanWindow,
      'scanWindow must have a positive width and height, got '
      '${window.width}x${window.height}.',
    );
  }
  if (window.left < 0 ||
      window.top < 0 ||
      window.right > 1 ||
      window.bottom > 1) {
    throw MobileScannerException(
      MobileScannerErrorCode.invalidScanWindow,
      'scanWindow must lie inside the unit square 0.0 to 1.0, got $window.',
    );
  }
}
