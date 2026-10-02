/// Barcode symbologies this plugin can recognize, and their platform mapping.
library;

/// A barcode symbology.
///
/// The [value] of each member is deliberately the Google ML Kit
/// `Barcode.FORMAT_*` bit, so a requested set can be combined with a bitwise OR
/// and handed straight to `BarcodeScannerOptions.setBarcodeFormats`. The iOS
/// side maps each member onto one or more `AVMetadataObject.ObjectType` values.
///
/// ## Platform support is not uniform
///
/// Every member below is supported on Android. On iOS, [codabar] needs iOS 15.4
/// or newer, and [upcA] is reported through a documented translation rather than
/// a native symbology (see [upcA]). Ask [MobileScanner.supportedFormats] at
/// runtime rather than assuming; requesting a format the running platform cannot
/// recognize fails with
/// [MobileScannerErrorCode.unsupportedBarcodeFormat] instead of silently
/// scanning nothing.
enum BarcodeFormat {
  /// Code 128, a variable-length linear symbology.
  ///
  /// iOS: `AVMetadataObject.ObjectType.code128`.
  code128(1, 'code128'),

  /// Code 39.
  ///
  /// iOS: `.code39` and `.code39Mod43`. The mod-43 checksum variant is reported
  /// as [code39] too, matching how ML Kit reports it.
  code39(2, 'code39'),

  /// Code 93.
  ///
  /// iOS: `.code93`.
  code93(4, 'code93'),

  /// Codabar.
  ///
  /// iOS: `.codabar`, which requires **iOS 15.4 or newer**. On an older iOS
  /// version this format is absent from [MobileScanner.supportedFormats] and
  /// requesting it throws
  /// [MobileScannerErrorCode.unsupportedBarcodeFormat].
  codabar(8, 'codabar'),

  /// Data Matrix, a 2D symbology.
  ///
  /// iOS: `.dataMatrix`.
  dataMatrix(16, 'dataMatrix'),

  /// EAN-13, the 13 digit retail symbology.
  ///
  /// iOS: `.ean13`.
  ///
  /// A 13 digit code whose first digit is `0` is, by definition, a UPC-A code
  /// carrying a leading zero. See [upcA] for how that overlap is resolved.
  ean13(32, 'ean13'),

  /// EAN-8.
  ///
  /// iOS: `.ean8`.
  ean8(64, 'ean8'),

  /// Interleaved 2 of 5, including ITF-14.
  ///
  /// iOS: `.itf14` and `.interleaved2of5`. AVFoundation splits the symbology in
  /// two, where ML Kit reports a single `FORMAT_ITF`; both platform types are
  /// requested together and both are reported as [itf].
  itf(128, 'itf'),

  /// QR Code.
  ///
  /// iOS: `.qr`.
  qrCode(256, 'qrCode'),

  /// UPC-A, the 12 digit retail symbology.
  ///
  /// **AVFoundation has no UPC-A symbology.** It reports UPC-A as an
  /// [ean13] object whose 13 digit payload carries a leading `0`, which is the
  /// correct relationship between the two symbologies rather than a defect.
  ///
  /// This plugin resolves the overlap deterministically:
  ///
  /// * Requesting [upcA] adds `.ean13` to the native type list on iOS.
  /// * A 13 digit `.ean13` payload beginning with `0` is reported as [upcA]
  ///   with the leading zero stripped, giving the 12 digit UPC-A value, **only
  ///   when [upcA] was requested**.
  /// * If [upcA] was not requested, the same detection is reported as [ean13]
  ///   with all 13 digits.
  /// * If both [upcA] and [ean13] were requested, [upcA] wins for a payload
  ///   beginning with `0`, and every other payload is [ean13].
  ///
  /// Android reports `FORMAT_UPC_A` natively and needs no translation, so the
  /// 12 digit value arrives directly.
  upcA(512, 'upcA'),

  /// UPC-E, the compressed 8 digit retail symbology.
  ///
  /// iOS: `.upce`.
  upcE(1024, 'upcE'),

  /// PDF417, a 2D stacked symbology.
  ///
  /// iOS: `.pdf417`.
  pdf417(2048, 'pdf417'),

  /// Aztec, a 2D symbology.
  ///
  /// iOS: `.aztec`.
  aztec(4096, 'aztec');

  const BarcodeFormat(this.value, this.wireName);

  /// The ML Kit `Barcode.FORMAT_*` bit for this symbology.
  ///
  /// Also this plugin's stable wire value for a single format. Bits combine with
  /// [formatMask].
  final int value;

  /// The stable identifier used in the native event payload.
  ///
  /// Kept separate from the enum member's own `name` so that renaming the Dart
  /// member cannot silently change the wire format.
  final String wireName;

  /// The format whose [value] is [bit], or `null` when no format matches.
  static BarcodeFormat? fromValue(int bit) {
    for (final format in values) {
      if (format.value == bit) return format;
    }
    return null;
  }

  /// The format whose [wireName] is [name], or `null` when none matches.
  ///
  /// A `null` return means the native side reported a symbology this Dart
  /// version does not know, which is treated as a malformed result and dropped
  /// rather than guessed at.
  static BarcodeFormat? fromWireName(String name) {
    for (final format in values) {
      if (format.wireName == name) return format;
    }
    return null;
  }

  /// The bitwise OR of every [value] in [formats].
  ///
  /// An empty [formats] yields [allFormatsMask], which asks the platform for
  /// every symbology it supports. That matches the documented default of
  /// scanning for everything when no filter is given.
  static int formatMask(Iterable<BarcodeFormat> formats) {
    if (formats.isEmpty) return allFormatsMask;
    var mask = 0;
    for (final format in formats) {
      mask |= format.value;
    }
    return mask;
  }

  /// The mask meaning "every supported symbology".
  ///
  /// Matches ML Kit's `Barcode.FORMAT_ALL_FORMATS`.
  static const int allFormatsMask = 0xFFFF;
}
