/// Decoding of native event payloads into the public value types.
///
/// Every function here is defensive: a malformed or partially unknown payload
/// yields `null` or is skipped, never an exception and never a fabricated value.
/// A native build newer than this Dart code must degrade, not crash.
///
/// Not part of the public API.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart' show Offset, Rect, Size;

import '../barcode.dart';
import '../barcode_format.dart';
import '../camera_facing.dart';
import '../exceptions.dart';
import '../mobile_scanner_state.dart';
import '../torch_state.dart';

/// The capabilities reported once the camera is open.
final class ScannerReadyInfo {
  /// Creates a ready report.
  const ScannerReadyInfo({
    required this.facing,
    required this.torchState,
    required this.minZoomScale,
    required this.maxZoomScale,
  });

  /// Which camera actually opened, which can differ from the one requested when
  /// the device lacks it.
  final CameraFacing facing;

  /// Whether the opened camera has a torch, and its current state.
  final TorchState torchState;

  /// The smallest zoom scale the device accepts.
  final double minZoomScale;

  /// The largest zoom scale the device accepts.
  final double maxZoomScale;
}

/// Decodes a payload into a JSON map, or `null` when it is not one.
Map<String, Object?>? decodeEnvelope(String payload) {
  if (payload.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(payload);
    if (decoded is Map<String, Object?>) return decoded;
    return null;
  } on FormatException {
    return null;
  }
}

/// Decodes a [ScannerEvent.detection] payload.
///
/// Returns `null` when the payload carries no usable barcode, which includes the
/// case where every entry named a symbology this version does not know.
({List<Barcode> barcodes, DateTime timestamp, Size? imageSize})?
decodeDetection(Map<String, Object?> json) {
  final Object? rawList = json['b'];
  if (rawList is! List) return null;

  final barcodes = <Barcode>[];
  for (final Object? entry in rawList) {
    if (entry is! Map<String, Object?>) continue;
    final Barcode? barcode = _decodeBarcode(entry);
    if (barcode != null) barcodes.add(barcode);
  }
  if (barcodes.isEmpty) return null;

  final int? millis = _asInt(json['ts']);
  final DateTime timestamp = millis == null
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(millis);

  final double? width = _asDouble(json['w']);
  final double? height = _asDouble(json['h']);
  final Size? imageSize =
      (width != null && height != null && width > 0 && height > 0)
      ? Size(width, height)
      : null;

  return (barcodes: barcodes, timestamp: timestamp, imageSize: imageSize);
}

Barcode? _decodeBarcode(Map<String, Object?> json) {
  final Object? formatName = json['f'];
  if (formatName is! String) return null;
  final BarcodeFormat? format = BarcodeFormat.fromWireName(formatName);
  // An unknown symbology is dropped rather than guessed at: reporting the wrong
  // format would be worse than reporting nothing.
  if (format == null) return null;

  return Barcode(
    format: format,
    rawValue: json['v'] is String ? json['v'] as String : null,
    displayValue: json['d'] is String ? json['d'] as String : null,
    rawBytes: _decodeBytes(json['bytes']),
    boundingBox: _decodeRect(json['r']),
    cornerPoints: _decodeCorners(json['c']),
  );
}

Uint8List? _decodeBytes(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

Rect? _decodeRect(Object? value) {
  if (value is! List || value.length != 4) return null;
  final double? left = _asDouble(value[0]);
  final double? top = _asDouble(value[1]);
  final double? width = _asDouble(value[2]);
  final double? height = _asDouble(value[3]);
  if (left == null || top == null || width == null || height == null) {
    return null;
  }
  final rect = Rect.fromLTWH(left, top, width, height);
  // A non-finite rectangle is malformed, not merely odd.
  if (!rect.isFinite) return null;
  return rect;
}

List<Offset>? _decodeCorners(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final corners = <Offset>[];
  for (final Object? point in value) {
    if (point is! List || point.length != 2) return null;
    final double? x = _asDouble(point[0]);
    final double? y = _asDouble(point[1]);
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    corners.add(Offset(x, y));
  }
  // All or nothing: a partially decoded corner list would misrepresent the
  // symbol's shape.
  return corners;
}

/// Decodes a [ScannerEvent.stateChanged] payload.
MobileScannerState? decodeState(Map<String, Object?> json) {
  final Object? name = json['state'];
  if (name is! String) return null;
  return MobileScannerState.fromWireName(name);
}

/// Decodes a [ScannerEvent.error] payload.
///
/// Always yields an exception: an unparseable error payload still means
/// something failed, so it degrades to
/// [MobileScannerErrorCode.nativeFailure] rather than being swallowed.
MobileScannerException decodeError(Map<String, Object?> json) {
  final Object? code = json['code'];
  final Object? message = json['message'];
  final Object? native = json['native'];
  return MobileScannerException(
    code is String
        ? MobileScannerErrorCode.fromWireName(code)
        : MobileScannerErrorCode.nativeFailure,
    message is String && message.isNotEmpty
        ? message
        : 'The native scanner reported a failure with no description.',
    nativeCode: native is String ? native : null,
  );
}

/// Decodes a [ScannerEvent.torchStateChanged] payload.
TorchState? decodeTorchState(Map<String, Object?> json) {
  final Object? name = json['torch'];
  if (name is! String) return null;
  return TorchState.fromWireName(name);
}

/// Decodes a [ScannerEvent.zoomChanged] payload.
double? decodeZoomScale(Map<String, Object?> json) => _asDouble(json['scale']);

/// Decodes a [ScannerEvent.ready] payload.
ScannerReadyInfo? decodeReady(Map<String, Object?> json) {
  final Object? facingName = json['facing'];
  if (facingName is! String) return null;
  final CameraFacing? facing = CameraFacing.fromWireName(facingName);
  if (facing == null) return null;

  final Object? torchName = json['torch'];
  final TorchState torchState = torchName is String
      ? (TorchState.fromWireName(torchName) ?? TorchState.unavailable)
      : TorchState.unavailable;

  return ScannerReadyInfo(
    facing: facing,
    torchState: torchState,
    minZoomScale: _asDouble(json['minZoom']) ?? 1.0,
    maxZoomScale: _asDouble(json['maxZoom']) ?? 1.0,
  );
}

/// Decodes the JSON array returned by the supported-formats symbol.
///
/// Unknown names are skipped, so a native build that gains a symbology this Dart
/// version predates simply reports fewer formats here.
Set<BarcodeFormat> decodeSupportedFormats(String payload) {
  if (payload.isEmpty) return const <BarcodeFormat>{};
  Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return const <BarcodeFormat>{};
  }
  if (decoded is! List) return const <BarcodeFormat>{};
  final formats = <BarcodeFormat>{};
  for (final Object? name in decoded) {
    if (name is! String) continue;
    final BarcodeFormat? format = BarcodeFormat.fromWireName(name);
    if (format != null) formats.add(format);
  }
  return formats;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite) return value.toInt();
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return null;
}
