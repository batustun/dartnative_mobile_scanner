import 'dart:convert';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart' show Offset, Rect;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:test/test.dart';

void main() {
  group('dedupKey', () {
    test('uses format and rawValue when text is present', () {
      const a = Barcode(format: BarcodeFormat.qrCode, rawValue: 'hello');
      const b = Barcode(format: BarcodeFormat.qrCode, rawValue: 'hello');
      expect(a.dedupKey, isNotNull);
      expect(a.dedupKey, b.dedupKey);
    });

    test('ignores geometry, so a held barcode keeps one identity', () {
      // The whole point: bounds move every frame while the symbol holds still.
      const still = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'hello',
        boundingBox: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
      );
      const drifted = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'hello',
        boundingBox: Rect.fromLTWH(0.11, 0.12, 0.2, 0.2),
      );
      expect(still.dedupKey, drifted.dedupKey);
    });

    test('ignores displayValue, which is Android-only', () {
      // Otherwise the same symbol would dedupe differently per platform.
      const withDisplay = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'tel:123',
        displayValue: '123',
      );
      const withoutDisplay = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'tel:123',
      );
      expect(withDisplay.dedupKey, withoutDisplay.dedupKey);
    });

    test('separates the same text under different formats', () {
      const qr = Barcode(format: BarcodeFormat.qrCode, rawValue: '12345678');
      const ean = Barcode(format: BarcodeFormat.ean8, rawValue: '12345678');
      expect(qr.dedupKey, isNot(ean.dedupKey));
    });

    test('falls back to rawBytes when there is no text', () {
      final a = Barcode(
        format: BarcodeFormat.qrCode,
        rawBytes: Uint8List.fromList([1, 2, 3]),
      );
      final b = Barcode(
        format: BarcodeFormat.qrCode,
        rawBytes: Uint8List.fromList([1, 2, 3]),
      );
      final c = Barcode(
        format: BarcodeFormat.qrCode,
        rawBytes: Uint8List.fromList([1, 2, 4]),
      );
      expect(a.dedupKey, isNotNull);
      expect(a.dedupKey, b.dedupKey);
      expect(a.dedupKey, isNot(c.dedupKey));
    });

    test('prefers rawValue over rawBytes when both exist', () {
      final withBoth = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'hi',
        rawBytes: Uint8List.fromList([9, 9]),
      );
      const textOnly = Barcode(format: BarcodeFormat.qrCode, rawValue: 'hi');
      expect(withBoth.dedupKey, textOnly.dedupKey);
    });

    test('is null when the barcode carries neither text nor bytes', () {
      // Such a detection cannot be identified across frames, so suppression
      // must never withhold it.
      const nothing = Barcode(format: BarcodeFormat.qrCode);
      expect(nothing.dedupKey, isNull);
    });

    test('a text value cannot collide with a base64 bytes value', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final fromBytes = Barcode(format: BarcodeFormat.qrCode, rawBytes: bytes);
      final fromText = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: base64Encode(bytes),
      );
      expect(fromBytes.dedupKey, isNot(fromText.dedupKey));
    });

    test('a value containing the separator cannot forge another identity', () {
      const tricky = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: '\u0000t\u0000spoofed',
      );
      const plain = Barcode(format: BarcodeFormat.qrCode, rawValue: 'spoofed');
      expect(tricky.dedupKey, isNot(plain.dedupKey));
    });
  });

  group('equality', () {
    test('is full value equality, including geometry', () {
      const a = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'x',
        boundingBox: Rect.fromLTWH(0, 0, 1, 1),
      );
      const b = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'x',
        boundingBox: Rect.fromLTWH(0, 0, 1, 1),
      );
      const differentBox = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'x',
        boundingBox: Rect.fromLTWH(0, 0, 0.5, 1),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(differentBox));
    });

    test('compares rawBytes by content, not identity', () {
      final a = Barcode(
        format: BarcodeFormat.pdf417,
        rawBytes: Uint8List.fromList([1, 2, 3]),
      );
      final b = Barcode(
        format: BarcodeFormat.pdf417,
        rawBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('distinguishes a null field from a present one', () {
      const withBytes = Barcode(format: BarcodeFormat.qrCode, rawValue: 'x');
      final withEmptyBytes = Barcode(
        format: BarcodeFormat.qrCode,
        rawValue: 'x',
        rawBytes: Uint8List(0),
      );
      expect(withBytes, isNot(withEmptyBytes));
    });

    test('compares cornerPoints by content and order', () {
      const a = Barcode(
        format: BarcodeFormat.qrCode,
        cornerPoints: [Offset(0, 0), Offset(1, 0)],
      );
      const b = Barcode(
        format: BarcodeFormat.qrCode,
        cornerPoints: [Offset(0, 0), Offset(1, 0)],
      );
      const reversed = Barcode(
        format: BarcodeFormat.qrCode,
        cornerPoints: [Offset(1, 0), Offset(0, 0)],
      );
      expect(a, b);
      expect(a, isNot(reversed));
    });
  });
}
