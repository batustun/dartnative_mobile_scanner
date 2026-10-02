import 'package:dartnative/dartnative.dart' show Rect;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/scan_window.dart';
import 'package:test/test.dart';

Matcher throwsScanWindowError = throwsA(
  isA<MobileScannerException>().having(
    (e) => e.code,
    'code',
    MobileScannerErrorCode.invalidScanWindow,
  ),
);

void main() {
  group('accepts', () {
    test('the full unit square', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0, 0, 1, 1)),
        returnsNormally,
      );
    });

    test('a centred band, the common scanner shape', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.1, 0.35, 0.8, 0.3)),
        returnsNormally,
      );
    });

    test('a rectangle touching the far edges exactly', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.5, 0.5, 0.5, 0.5)),
        returnsNormally,
      );
    });

    test('a very small but non-empty rectangle', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.5, 0.5, 1e-6, 1e-6)),
        returnsNormally,
      );
    });
  });

  group('rejects a degenerate rectangle', () {
    test('zero width', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.1, 0.1, 0, 0.5)),
        throwsScanWindowError,
      );
    });

    test('zero height', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.1, 0.1, 0.5, 0)),
        throwsScanWindowError,
      );
    });

    test('negative width', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.5, 0.1, -0.2, 0.5)),
        throwsScanWindowError,
      );
    });

    test('negative height', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.1, 0.5, 0.5, -0.2)),
        throwsScanWindowError,
      );
    });
  });

  group('rejects out of bounds', () {
    test('negative left', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(-0.1, 0, 0.5, 0.5)),
        throwsScanWindowError,
      );
    });

    test('negative top', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0, -0.1, 0.5, 0.5)),
        throwsScanWindowError,
      );
    });

    test('right past 1.0', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0.6, 0, 0.5, 0.5)),
        throwsScanWindowError,
      );
    });

    test('bottom past 1.0', () {
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0, 0.6, 0.5, 0.5)),
        throwsScanWindowError,
      );
    });

    test('a pixel rectangle, the most likely mistake', () {
      // Passing device pixels instead of normalized coordinates must fail loudly
      // rather than produce a scanner that never detects anything.
      expect(
        () => validateScanWindow(const Rect.fromLTWH(0, 0, 1080, 1920)),
        throwsScanWindowError,
      );
    });
  });

  group('rejects non-finite values', () {
    test('NaN origin', () {
      expect(
        () => validateScanWindow(Rect.fromLTWH(double.nan, 0, 0.5, 0.5)),
        throwsScanWindowError,
      );
    });

    test('infinite width', () {
      expect(
        () => validateScanWindow(Rect.fromLTWH(0, 0, double.infinity, 0.5)),
        throwsScanWindowError,
      );
    });

    test('NaN height', () {
      expect(
        () => validateScanWindow(Rect.fromLTWH(0, 0, 0.5, double.nan)),
        throwsScanWindowError,
      );
    });
  });
}
