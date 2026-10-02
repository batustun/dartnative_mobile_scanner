/// One detection event delivered to `onDetect`.
library;

import 'package:dartnative/dartnative.dart' show Size;

import 'barcode.dart';

/// The barcodes recognized in a single analyzed frame.
///
/// One capture corresponds to one logical detection event, not to one barcode:
/// a frame containing three symbols produces one [BarcodeCapture] whose
/// [barcodes] has three entries.
final class BarcodeCapture {
  /// Creates a capture.
  const BarcodeCapture({
    required this.barcodes,
    required this.timestamp,
    this.imageSize,
  });

  /// Every barcode accepted from this frame, after format and scan-window
  /// filtering.
  ///
  /// Never empty: a frame that yielded nothing, or whose detections were all
  /// filtered out, produces no capture at all rather than an empty one.
  ///
  /// Ordering is whatever the platform recognizer reported, which differs
  /// between them and is not stable across frames. ML Kit does not document an
  /// order, and AVFoundation's array order likewise carries no guarantee. Do
  /// not rely on index; match on [Barcode.rawValue] or geometry when you need a
  /// specific symbol.
  final List<Barcode> barcodes;

  /// When the frame that produced this capture was recognized.
  ///
  /// Taken on the native side at the moment the recognizer returned, so it is
  /// not delayed by the hop into Dart or by work your `onDetect` performs.
  final DateTime timestamp;

  /// The size in pixels of the frame that was analyzed, after rotation.
  ///
  /// Informational: the resolution the recognizer actually worked at, which is
  /// lower than the sensor's full output because analysis is deliberately run at
  /// a scanning-appropriate size. It is **not** the space
  /// [Barcode.boundingBox] is expressed in; that is normalized preview space.
  ///
  /// `null` when the platform did not report it.
  final Size? imageSize;

  @override
  String toString() =>
      'BarcodeCapture(${barcodes.length} barcode(s) at '
      '${timestamp.toIso8601String()})';
}
