/// The normalized barcode result both platforms are mapped onto.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart' show Offset, Rect;

import 'barcode_format.dart';

/// One recognized barcode.
///
/// Immutable, and deliberately narrow: it carries only what both platforms can
/// supply honestly. A field that the recognizing platform did not provide is
/// `null`, never an empty string or a zero rectangle standing in for missing
/// data.
///
/// Geometry uses the framework's own [Rect] and [Offset] from
/// `package:dartnative/dartnative.dart`, not Flutter's.
final class Barcode {
  /// Creates a barcode result.
  ///
  /// Only [format] is required. Every other field is optional because the two
  /// platform recognizers differ in what they expose.
  const Barcode({
    required this.format,
    this.rawValue,
    this.displayValue,
    this.rawBytes,
    this.boundingBox,
    this.cornerPoints,
  });

  /// The symbology that was recognized.
  final BarcodeFormat format;

  /// The decoded payload as text, or `null` when the platform could not produce
  /// one.
  ///
  /// A `null` value is legitimate and happens in practice: a binary-mode QR
  /// code, or a payload that is not valid UTF-8, has bytes but no text. Treat
  /// `null` as "no text available", not as an error, and read [rawBytes]
  /// instead.
  final String? rawValue;

  /// A value prepared for display, when the recognizer offers one.
  ///
  /// **Android only.** ML Kit derives this from the structured interpretation of
  /// the payload, so it can differ from [rawValue] (a phone number stripped of
  /// its `tel:` scheme, for example). AVFoundation has no equivalent, so this is
  /// always `null` on iOS.
  final String? displayValue;

  /// The raw payload bytes, before any text decoding.
  ///
  /// **Android only.** ML Kit exposes `Barcode.getRawBytes()`. AVFoundation's
  /// `AVMetadataMachineReadableCodeObject` does not expose the underlying bytes
  /// through public API, so this is always `null` on iOS. Never synthesized
  /// from [rawValue], because re-encoding text is not the same as the bytes the
  /// symbol carried.
  final Uint8List? rawBytes;

  /// The barcode's axis-aligned bounds, in **normalized preview coordinates**.
  ///
  /// `left`, `top`, `width` and `height` run `0.0` to `1.0` across the preview
  /// box as it is displayed, origin at the top left. That is the space an overlay
  /// is drawn in, so a highlight rectangle is `boundingBox` scaled by the
  /// widget's own size, with no sensor resolution, rotation or mirroring left for
  /// you to undo.
  ///
  /// Both platforms convert into this space with their own APIs rather than
  /// hand-rolled rotation math: iOS uses
  /// `AVCaptureVideoPreviewLayer.transformedMetadataObject(for:)`, and Android
  /// maps the upright image that ML Kit analyzed through the preview's
  /// centre-crop transform, mirroring for the front camera.
  ///
  /// **Values can fall slightly outside `0.0` to `1.0`.** The preview fills its
  /// box by cropping, so the recognizer sees a little more than is shown. A
  /// barcode in that cropped margin is still reported, with coordinates just
  /// outside the unit square. Clamp before drawing if that matters to you.
  ///
  /// `null` when the recognizer did not report bounds.
  final Rect? boundingBox;

  /// The barcode's corner points, in the same normalized preview space as
  /// [boundingBox].
  ///
  /// Unlike [boundingBox] these follow the symbol's actual rotation, so they
  /// describe a quadrilateral rather than an upright rectangle. Ordered as the
  /// recognizer reported them, which is clockwise from the top left **of the
  /// symbol as printed**; for a rotated symbol that is not the top left of the
  /// preview.
  ///
  /// `null` when the recognizer did not report corners, and never a partially
  /// filled list: if any point could not be read the whole list is dropped,
  /// because a partial outline would misstate the symbol's shape.
  final List<Offset>? cornerPoints;

  /// The identity used to decide whether two detections are "the same barcode"
  /// for duplicate suppression.
  ///
  /// Resolved in this order, so that a missing text value never collapses
  /// distinct symbols into one key:
  ///
  /// 1. [format] plus [rawValue], when [rawValue] is non-null.
  /// 2. [format] plus the base64 of [rawBytes], when [rawValue] is `null` and
  ///    [rawBytes] is non-null.
  /// 3. `null` when the detection carries neither. Such a detection cannot be
  ///    identified across frames, so duplicate suppression never withholds it.
  ///
  /// This is intentionally not [operator ==]: geometry changes on every frame
  /// while the barcode holds still, so including it would defeat suppression.
  String? get dedupKey {
    final value = rawValue;
    if (value != null) return '${format.wireName}\u0000t\u0000$value';
    final bytes = rawBytes;
    if (bytes != null) {
      return '${format.wireName}\u0000b\u0000${base64Encode(bytes)}';
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Barcode &&
        other.format == format &&
        other.rawValue == rawValue &&
        other.displayValue == displayValue &&
        other.boundingBox == boundingBox &&
        _bytesEqual(other.rawBytes, rawBytes) &&
        _cornersEqual(other.cornerPoints, cornerPoints);
  }

  @override
  int get hashCode => Object.hash(
    format,
    rawValue,
    displayValue,
    boundingBox,
    rawBytes == null ? null : Object.hashAll(rawBytes!),
    cornerPoints == null ? null : Object.hashAll(cornerPoints!),
  );

  @override
  String toString() =>
      'Barcode(${format.name}, rawValue: $rawValue, '
      'boundingBox: $boundingBox)';

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _cornersEqual(List<Offset>? a, List<Offset>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
