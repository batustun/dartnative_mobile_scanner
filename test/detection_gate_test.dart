import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/native/detection_gate.dart';
import 'package:test/test.dart';

/// A fixed origin, so every assertion is about elapsed time rather than wall
/// clock.
final DateTime t0 = DateTime.utc(2026, 1, 1);

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

Barcode qr(String value) =>
    Barcode(format: BarcodeFormat.qrCode, rawValue: value);

DetectionGate gate(
  DetectionSpeed speed, {
  Duration timeout = const Duration(milliseconds: 250),
  Duration cooldown = const Duration(seconds: 1),
}) => DetectionGate(
  speed: speed,
  detectionTimeout: timeout,
  duplicateCooldown: cooldown,
);

BarcodeCapture? feed(DetectionGate g, List<Barcode> barcodes, DateTime now) =>
    g.admit(
      barcodes,
      now,
      build: (accepted) => BarcodeCapture(barcodes: accepted, timestamp: now),
    );

void main() {
  test('an empty detection is never emitted, in any mode', () {
    for (final speed in DetectionSpeed.values) {
      expect(feed(gate(speed), const [], t0), isNull, reason: speed.name);
    }
  });

  group('unrestricted', () {
    test('emits every detection, including identical ones', () {
      final g = gate(DetectionSpeed.unrestricted);
      for (var i = 0; i < 30; i++) {
        expect(feed(g, [qr('same')], at(i * 33)), isNotNull);
      }
    });

    test('never filters barcodes out of a capture', () {
      final g = gate(DetectionSpeed.unrestricted);
      final capture = feed(g, [qr('a'), qr('b')], t0);
      expect(capture!.barcodes, hasLength(2));
    });
  });

  group('normal', () {
    test('emits the first detection immediately', () {
      expect(feed(gate(DetectionSpeed.normal), [qr('a')], t0), isNotNull);
    });

    test('drops everything inside the timeout window', () {
      final g = gate(DetectionSpeed.normal);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(1)), isNull);
      expect(feed(g, [qr('a')], at(249)), isNull);
    });

    test('emits again exactly at the timeout boundary', () {
      final g = gate(DetectionSpeed.normal);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(250)), isNotNull);
    });

    test('throttles by time, so a different barcode is also dropped', () {
      // Documented behaviour: the rule is a time window, not a value check.
      final g = gate(DetectionSpeed.normal);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('completely-different')], at(100)), isNull);
    });

    test('the window restarts from each emission, not from the first', () {
      final g = gate(DetectionSpeed.normal);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(250)), isNotNull);
      expect(feed(g, [qr('a')], at(499)), isNull);
      expect(feed(g, [qr('a')], at(500)), isNotNull);
    });

    test('honours a custom timeout', () {
      final g = gate(
        DetectionSpeed.normal,
        timeout: const Duration(milliseconds: 50),
      );
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(49)), isNull);
      expect(feed(g, [qr('a')], at(50)), isNotNull);
    });

    test('passes every barcode in an emitted frame through', () {
      final g = gate(DetectionSpeed.normal);
      final capture = feed(g, [qr('a'), qr('b'), qr('c')], t0);
      expect(capture!.barcodes.map((b) => b.rawValue), ['a', 'b', 'c']);
    });
  });

  group('noDuplicates', () {
    test('emits a barcode the first time it is seen', () {
      expect(feed(gate(DetectionSpeed.noDuplicates), [qr('a')], t0), isNotNull);
    });

    test('suppresses it while it stays continuously visible', () {
      // 30 fps for two seconds, well past the one second cooldown: the barcode
      // keeps renewing its own suppression, so it must never re-emit.
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      for (var ms = 33; ms <= 2000; ms += 33) {
        expect(feed(g, [qr('a')], at(ms)), isNull, reason: 'at ${ms}ms');
      }
    });

    test('re-emits once it has been absent for the full cooldown', () {
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      // Nothing is fed between 0 and 1000, which models the barcode leaving.
      expect(feed(g, [qr('a')], at(1000)), isNotNull);
    });

    test('still suppresses just before the cooldown elapses', () {
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(999)), isNull);
    });

    test('an interrupted absence restarts the cooldown', () {
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(900)), isNull); // seen again, renews
      expect(feed(g, [qr('a')], at(1800)), isNull); // only 900ms since renewal
      expect(feed(g, [qr('a')], at(2800)), isNotNull);
    });

    test('suppression is per barcode, not per capture', () {
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      final capture = feed(g, [qr('a'), qr('b')], at(100));
      expect(capture, isNotNull);
      expect(capture!.barcodes.map((b) => b.rawValue), ['b']);
    });

    test('a frame of only seen barcodes emits nothing', () {
      final g = gate(DetectionSpeed.noDuplicates);
      feed(g, [qr('a'), qr('b')], at(0));
      expect(feed(g, [qr('a'), qr('b')], at(100)), isNull);
    });

    test('tracks many distinct barcodes independently', () {
      final g = gate(DetectionSpeed.noDuplicates);
      for (var i = 0; i < 50; i++) {
        expect(feed(g, [qr('code-$i')], at(i)), isNotNull);
      }
      for (var i = 0; i < 50; i++) {
        expect(feed(g, [qr('code-$i')], at(100 + i)), isNull);
      }
    });

    test('never suppresses a barcode with no identity', () {
      // No text and no bytes, so it cannot be matched across frames.
      const anonymous = Barcode(format: BarcodeFormat.qrCode);
      final g = gate(DetectionSpeed.noDuplicates);
      for (var i = 0; i < 5; i++) {
        expect(feed(g, [anonymous], at(i * 33)), isNotNull);
      }
    });

    test('distinguishes the same text under different formats', () {
      final g = gate(DetectionSpeed.noDuplicates);
      expect(feed(g, [qr('12345678')], at(0)), isNotNull);
      final capture = feed(g, [
        const Barcode(format: BarcodeFormat.ean8, rawValue: '12345678'),
      ], at(10));
      expect(capture, isNotNull);
    });

    test('honours a custom cooldown', () {
      final g = gate(
        DetectionSpeed.noDuplicates,
        cooldown: const Duration(milliseconds: 100),
      );
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(99)), isNull); // renews lastSeen to 99
      // Nothing is fed between 99 and 199, so the barcode was absent for
      // exactly the cooldown. The boundary is inclusive, matching how the
      // normal mode's timeout boundary behaves.
      expect(feed(g, [qr('a')], at(199)), isNotNull);
    });

    test('every observation renews the window, even a suppressed one', () {
      // The rule is "absent for the cooldown", not "cooldown since emission".
      // Feeding just inside the window repeatedly keeps pushing eligibility out.
      final g = gate(
        DetectionSpeed.noDuplicates,
        cooldown: const Duration(milliseconds: 100),
      );
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      for (var ms = 90; ms <= 900; ms += 90) {
        expect(feed(g, [qr('a')], at(ms)), isNull, reason: 'at ${ms}ms');
      }
      // Last observation was 900, so 999 is still inside the window. Note that
      // this very probe counts as an observation and renews lastSeen to 999,
      // which pushes eligibility out to 1099 rather than 1000.
      expect(feed(g, [qr('a')], at(999)), isNull);
      // 1099 is exactly 100ms after that probe. Probing again in between would
      // renew lastSeen once more and push eligibility out again, so there is no
      // way to poll a barcode back into eligibility: it has to actually go away.
      expect(feed(g, [qr('a')], at(1099)), isNotNull);
    });

    test('prunes history so it does not grow for the session lifetime', () {
      final g = gate(DetectionSpeed.noDuplicates);
      for (var i = 0; i < 1000; i++) {
        feed(g, [qr('code-$i')], at(i));
      }
      // Long after every entry has aged out, the first code is emitted again,
      // which can only happen if its entry was dropped.
      expect(feed(g, [qr('code-0')], at(10000)), isNotNull);
    });
  });

  group('reset', () {
    test('clears the normal throttle', () {
      final g = gate(DetectionSpeed.normal);
      expect(feed(g, [qr('a')], at(0)), isNotNull);
      expect(feed(g, [qr('a')], at(10)), isNull);
      g.reset();
      expect(feed(g, [qr('a')], at(20)), isNotNull);
    });

    test(
      'clears noDuplicates history, so the visible barcode reports again',
      () {
        // This is what makes a barcode still in frame reappear after a stop or a
        // camera switch.
        final g = gate(DetectionSpeed.noDuplicates);
        expect(feed(g, [qr('a')], at(0)), isNotNull);
        expect(feed(g, [qr('a')], at(10)), isNull);
        g.reset();
        expect(feed(g, [qr('a')], at(20)), isNotNull);
      },
    );
  });
}
