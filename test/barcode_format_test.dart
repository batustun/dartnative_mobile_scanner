import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:test/test.dart';

void main() {
  group('BarcodeFormat wire values', () {
    test('match the ML Kit FORMAT_* bits', () {
      // These are the contract with the Android side, which ORs them straight
      // into BarcodeScannerOptions. A change here is a wire break.
      expect(BarcodeFormat.code128.value, 1);
      expect(BarcodeFormat.code39.value, 2);
      expect(BarcodeFormat.code93.value, 4);
      expect(BarcodeFormat.codabar.value, 8);
      expect(BarcodeFormat.dataMatrix.value, 16);
      expect(BarcodeFormat.ean13.value, 32);
      expect(BarcodeFormat.ean8.value, 64);
      expect(BarcodeFormat.itf.value, 128);
      expect(BarcodeFormat.qrCode.value, 256);
      expect(BarcodeFormat.upcA.value, 512);
      expect(BarcodeFormat.upcE.value, 1024);
      expect(BarcodeFormat.pdf417.value, 2048);
      expect(BarcodeFormat.aztec.value, 4096);
    });

    test('are distinct single bits', () {
      final seen = <int>{};
      for (final format in BarcodeFormat.values) {
        expect(
          format.value & (format.value - 1),
          0,
          reason: '${format.name} must be a single bit',
        );
        expect(
          seen.add(format.value),
          isTrue,
          reason: '${format.name} collides',
        );
      }
    });

    test('wireName is unique and round-trips', () {
      final seen = <String>{};
      for (final format in BarcodeFormat.values) {
        expect(seen.add(format.wireName), isTrue);
        expect(BarcodeFormat.fromWireName(format.wireName), format);
      }
    });

    test('fromValue round-trips and rejects non-formats', () {
      for (final format in BarcodeFormat.values) {
        expect(BarcodeFormat.fromValue(format.value), format);
      }
      expect(BarcodeFormat.fromValue(0), isNull);
      expect(BarcodeFormat.fromValue(3), isNull);
      expect(BarcodeFormat.fromValue(8192), isNull);
    });

    test('fromWireName returns null for an unknown symbology', () {
      // A newer native build reporting something this version predates must be
      // dropped, not guessed at.
      expect(BarcodeFormat.fromWireName('microQr'), isNull);
      expect(BarcodeFormat.fromWireName(''), isNull);
    });
  });

  group('formatMask', () {
    test('ORs the requested formats', () {
      expect(
        BarcodeFormat.formatMask([BarcodeFormat.qrCode, BarcodeFormat.ean13]),
        256 | 32,
      );
    });

    test('an empty request means every format', () {
      expect(BarcodeFormat.formatMask(const []), BarcodeFormat.allFormatsMask);
    });

    test('is idempotent for duplicates', () {
      expect(
        BarcodeFormat.formatMask([BarcodeFormat.qrCode, BarcodeFormat.qrCode]),
        BarcodeFormat.qrCode.value,
      );
    });

    test('every format together fits inside the all-formats mask', () {
      final mask = BarcodeFormat.formatMask(BarcodeFormat.values);
      expect(mask & BarcodeFormat.allFormatsMask, mask);
    });
  });
}
