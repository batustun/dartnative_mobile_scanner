import 'dart:convert';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart' show Rect;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/native/scanner_protocol.dart';
import 'package:test/test.dart';

/// One command the controller sent to its native view.
class SentCommand {
  SentCommand(this.tag, this.payload);
  final int tag;
  final Uint8List payload;

  Map<String, Object?> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
}

/// Drives a controller as a mounted scanner view would, without a camera.
class Harness {
  Harness(this.controller, {Rect? scanWindow}) {
    controller.attach(viewId, _sink, scanWindow: scanWindow);
  }

  static const int viewId = 42;
  final MobileScannerController controller;
  final List<SentCommand> sent = <SentCommand>[];

  void _sink(int tag, Uint8List payload) => sent.add(SentCommand(tag, payload));

  List<SentCommand> ofTag(int tag) => sent.where((c) => c.tag == tag).toList();

  bool hasTag(int tag) => sent.any((c) => c.tag == tag);

  void emitState(MobileScannerState state) => controller.debugHandleNativeEvent(
    ScannerEvent.stateChanged,
    jsonEncode({'state': state.wireName}),
  );

  void emitReady({
    CameraFacing facing = CameraFacing.back,
    TorchState torch = TorchState.off,
    double minZoom = 1.0,
    double maxZoom = 8.0,
  }) => controller.debugHandleNativeEvent(
    ScannerEvent.ready,
    jsonEncode({
      'facing': facing.wireName,
      'torch': torch.wireName,
      'minZoom': minZoom,
      'maxZoom': maxZoom,
    }),
  );

  void emitDetection(List<Map<String, Object?>> barcodes, {int? ts}) =>
      controller.debugHandleNativeEvent(
        ScannerEvent.detection,
        jsonEncode({'ts': ?ts, 'b': barcodes}),
      );

  void emitError(MobileScannerErrorCode code, {String message = 'boom'}) =>
      controller.debugHandleNativeEvent(
        ScannerEvent.error,
        jsonEncode({'code': code.wireName, 'message': message}),
      );

  /// Brings the scanner to a running state the way a real start does.
  Future<void> reachRunning() async {
    await controller.start();
    emitState(MobileScannerState.running);
    emitReady();
  }
}

void main() {
  group('construction', () {
    test('starts stopped with no error', () {
      final c = MobileScannerController();
      expect(c.state, MobileScannerState.stopped);
      expect(c.error, isNull);
      expect(c.torchState, TorchState.unavailable);
      expect(c.facingInUse, isNull);
      expect(c.isAttached, isFalse);
      expect(c.isDisposed, isFalse);
      c.dispose();
    });

    test('rejects an invalid initial zoom', () {
      for (final bad in <double>[0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => MobileScannerController(initialZoomScale: bad),
          throwsA(
            isA<MobileScannerException>().having(
              (e) => e.code,
              'code',
              MobileScannerErrorCode.invalidZoomScale,
            ),
          ),
          reason: '$bad',
        );
      }
    });
  });

  group('attach', () {
    test('sends one configure carrying the full intent', () {
      final c = MobileScannerController(
        facing: CameraFacing.front,
        formats: const [BarcodeFormat.qrCode, BarcodeFormat.ean13],
        torchEnabled: true,
      );
      final h = Harness(c, scanWindow: const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4));

      final configure = h.ofTag(ScannerCommand.configure).single;
      expect(configure.json['facing'], 'front');
      expect(
        configure.json['formats'],
        BarcodeFormat.qrCode.value | BarcodeFormat.ean13.value,
      );
      expect(configure.json['torch'], isTrue);
      expect(configure.json['autoStart'], isTrue);
      expect(configure.json['scanWindow'], [0.1, 0.2, 0.3, 0.4]);
      c.dispose();
    });

    test('an empty format list asks for every format', () {
      final c = MobileScannerController();
      final h = Harness(c);
      expect(
        h.ofTag(ScannerCommand.configure).single.json['formats'],
        BarcodeFormat.allFormatsMask,
      );
      c.dispose();
    });

    test('autoStart false is carried through', () {
      final c = MobileScannerController(autoStart: false);
      final h = Harness(c);
      expect(
        h.ofTag(ScannerCommand.configure).single.json['autoStart'],
        isFalse,
      );
      c.dispose();
    });

    test('a null scan window is explicit, not omitted', () {
      final c = MobileScannerController();
      final h = Harness(c);
      final json = h.ofTag(ScannerCommand.configure).single.json;
      expect(json.containsKey('scanWindow'), isTrue);
      expect(json['scanWindow'], isNull);
      c.dispose();
    });

    test('marks the controller attached', () {
      final c = MobileScannerController();
      Harness(c);
      expect(c.isAttached, isTrue);
      c.dispose();
    });
  });

  group('start and stop', () {
    test('start moves to starting and sends the command', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.start();
      expect(c.state, MobileScannerState.starting);
      expect(h.hasTag(ScannerCommand.start), isTrue);
      c.dispose();
    });

    test('native reports the authoritative running state', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      expect(c.state, MobileScannerState.running);
      c.dispose();
    });

    test('start is a no-op while starting or running', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.start();
      await c.start();
      expect(h.ofTag(ScannerCommand.start), hasLength(1));
      h.emitState(MobileScannerState.running);
      await c.start();
      expect(h.ofTag(ScannerCommand.start), hasLength(1));
      c.dispose();
    });

    test('stop moves to stopping and sends the command', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      await c.stop();
      expect(c.state, MobileScannerState.stopping);
      expect(h.hasTag(ScannerCommand.stop), isTrue);
      h.emitState(MobileScannerState.stopped);
      expect(c.state, MobileScannerState.stopped);
      c.dispose();
    });

    test('stop is a no-op when already stopped', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.stop();
      expect(h.ofTag(ScannerCommand.stop), isEmpty);
      c.dispose();
    });

    test('start after stop restarts and clears the error', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      await c.stop();
      h.emitState(MobileScannerState.stopped);
      h.emitError(MobileScannerErrorCode.cameraUnavailable);
      expect(c.error, isNotNull);

      await c.start();
      expect(c.state, MobileScannerState.starting);
      expect(c.error, isNull);
      expect(h.ofTag(ScannerCommand.start), hasLength(2));
      c.dispose();
    });

    test('start is valid from the error state', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      h.emitError(MobileScannerErrorCode.permissionDenied);
      expect(c.state, MobileScannerState.error);
      await c.start();
      expect(c.state, MobileScannerState.starting);
      c.dispose();
    });
  });

  group('explicit stop versus a lifecycle pause', () {
    test('an explicit stop before attach suppresses autoStart', () async {
      // The distinction the README promises: a scanner the application stopped
      // must not come back by itself.
      final c = MobileScannerController();
      await c.stop();
      final h = Harness(c);
      expect(
        h.ofTag(ScannerCommand.configure).single.json['autoStart'],
        isFalse,
      );
      c.dispose();
    });

    test(
      'start clears the explicit stop, so autoStart applies again',
      () async {
        final c = MobileScannerController();
        await c.stop();
        await c.start();
        final h = Harness(c);
        expect(
          h.ofTag(ScannerCommand.configure).single.json['autoStart'],
          isTrue,
        );
        c.dispose();
      },
    );

    test('pause does not count as an explicit stop', () async {
      final c = MobileScannerController();
      final h1 = Harness(c);
      await h1.reachRunning();
      await c.pause();
      expect(h1.hasTag(ScannerCommand.pause), isTrue);
      c.detach();

      final h2 = Harness(c);
      expect(
        h2.ofTag(ScannerCommand.configure).single.json['autoStart'],
        isTrue,
      );
      c.dispose();
    });

    test('pause only applies while running', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.pause();
      expect(h.hasTag(ScannerCommand.pause), isFalse);
      await c.start();
      await c.pause();
      expect(h.hasTag(ScannerCommand.pause), isFalse);
      c.dispose();
    });

    test('resume only applies while paused', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      await c.resume();
      expect(h.hasTag(ScannerCommand.resume), isFalse);
      h.emitState(MobileScannerState.paused);
      await c.resume();
      expect(h.hasTag(ScannerCommand.resume), isTrue);
      c.dispose();
    });
  });

  group('torch', () {
    test('reports availability from the ready report', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.start();
      h.emitState(MobileScannerState.running);
      h.emitReady(torch: TorchState.off);
      expect(c.torchState, TorchState.off);
      expect(c.torchState.isAvailable, isTrue);
      c.dispose();
    });

    test('toggling sends the opposite of the current state', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      await c.toggleTorch();
      expect(h.ofTag(ScannerCommand.setTorch).last.json['on'], isTrue);

      c.debugHandleNativeEvent(
        ScannerEvent.torchStateChanged,
        jsonEncode({'torch': 'on'}),
      );
      expect(c.torchState, TorchState.on);
      await c.toggleTorch();
      expect(h.ofTag(ScannerCommand.setTorch).last.json['on'], isFalse);
      c.dispose();
    });

    test('refuses when the open camera has no torch', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.start();
      h.emitState(MobileScannerState.running);
      h.emitReady(facing: CameraFacing.front, torch: TorchState.unavailable);

      expect(
        () => c.setTorchEnabled(true),
        throwsA(
          isA<MobileScannerException>().having(
            (e) => e.code,
            'code',
            MobileScannerErrorCode.torchUnavailable,
          ),
        ),
      );
      c.dispose();
    });

    test('a torch request before the camera opens is remembered', () async {
      // Availability is unknown until the camera opens, so refusing here would
      // be guessing.
      final c = MobileScannerController();
      final h = Harness(c);
      await c.setTorchEnabled(true);
      expect(h.ofTag(ScannerCommand.setTorch).single.json['on'], isTrue);
      c.dispose();
    });
  });

  group('camera switching', () {
    test('switchCamera flips away from the camera in use', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      expect(c.facingInUse, CameraFacing.back);
      await c.switchCamera();
      expect(h.ofTag(ScannerCommand.setFacing).single.json['facing'], 'front');
      c.dispose();
    });

    test(
      'switching resets torch state, since the new camera may lack one',
      () async {
        final c = MobileScannerController();
        final h = Harness(c);
        await h.reachRunning();
        h.emitReady(torch: TorchState.on);
        expect(c.torchState, TorchState.on);
        await c.switchCamera();
        expect(c.torchState, TorchState.unavailable);
        c.dispose();
      },
    );

    test('selecting the camera already in use is a no-op', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      await c.setCameraFacing(CameraFacing.back);
      expect(h.ofTag(ScannerCommand.setFacing), isEmpty);
      c.dispose();
    });

    test(
      'before any camera opens, switching uses the requested facing',
      () async {
        final c = MobileScannerController(facing: CameraFacing.front);
        final h = Harness(c);
        await c.switchCamera();
        expect(h.ofTag(ScannerCommand.setFacing).single.json['facing'], 'back');
        c.dispose();
      },
    );
  });

  group('zoom', () {
    test('rejects a non-finite or non-positive scale', () async {
      final c = MobileScannerController();
      Harness(c);
      for (final bad in <double>[0.0, -2.0, double.nan, double.infinity]) {
        expect(
          () => c.setZoomScale(bad),
          throwsA(
            isA<MobileScannerException>().having(
              (e) => e.code,
              'code',
              MobileScannerErrorCode.invalidZoomScale,
            ),
          ),
          reason: '$bad',
        );
      }
      c.dispose();
    });

    test('accepts the device minimum even when it is below 1.0', () async {
      // Regression: a hard 1.0 floor made an advertised minZoomScale
      // unreachable. A Galaxy S23 Ultra reports 0.60 (ultra-wide), so the
      // getter was offering a value the setter refused.
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      h.emitReady(minZoom: 0.6, maxZoom: 10.0);
      expect(c.minZoomScale, 0.6);

      await c.setZoomScale(0.6);
      expect(h.ofTag(ScannerCommand.setZoomScale).last.json['scale'], 0.6);
      await c.setZoomScale(0.8);
      expect(h.ofTag(ScannerCommand.setZoomScale).last.json['scale'], 0.8);
      c.dispose();
    });

    test('still rejects below the device minimum', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      h.emitReady(minZoom: 0.6, maxZoom: 10.0);
      expect(
        () => c.setZoomScale(0.5),
        throwsA(
          isA<MobileScannerException>().having(
            (e) => e.code,
            'code',
            MobileScannerErrorCode.invalidZoomScale,
          ),
        ),
      );
      c.dispose();
    });

    test('on a device whose minimum is 1.0, validation is unchanged', () async {
      // The zoom-floor fix was made for Android, where a Galaxy S23 Ultra reports
      // minZoomScale 0.60. This pins the behaviour on a device that reports 1.00,
      // the measured iPhone 15 Pro Max range, so the shared change is shown not to
      // alter iOS without needing another device run.
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      h.emitReady(minZoom: 1.0, maxZoom: 123.75);

      // Accepted, exactly as before.
      for (final good in <double>[1.0, 2.0, 60.0, 123.75]) {
        await c.setZoomScale(good);
        expect(
          h.ofTag(ScannerCommand.setZoomScale).last.json['scale'],
          good,
          reason: '$good should be accepted',
        );
      }
      // Rejected, exactly as before, and with the same code.
      for (final bad in <double>[0.99, 0.5, 123.76, 1000.0]) {
        expect(
          () => c.setZoomScale(bad),
          throwsA(
            isA<MobileScannerException>().having(
              (e) => e.code,
              'code',
              MobileScannerErrorCode.invalidZoomScale,
            ),
          ),
          reason: '$bad should be rejected',
        );
      }
      c.dispose();
    });

    test('an initial scale below 1.0 is allowed, zero and negative are not', () {
      // The constructor runs before any camera is open, so the device range is
      // unknown; only a non-positive or non-finite value is knowably wrong.
      expect(
        () => MobileScannerController(initialZoomScale: 0.6),
        returnsNormally,
      );
      for (final bad in <double>[0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => MobileScannerController(initialZoomScale: bad),
          throwsA(
            isA<MobileScannerException>().having(
              (e) => e.code,
              'code',
              MobileScannerErrorCode.invalidZoomScale,
            ),
          ),
          reason: '$bad',
        );
      }
    });

    test('rejects a scale beyond the reported device range', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      h.emitReady(minZoom: 1.0, maxZoom: 4.0);
      expect(() => c.setZoomScale(5.0), throwsA(isA<MobileScannerException>()));
      c.dispose();
    });

    test(
      'accepts a scale inside the range and mirrors what native applied',
      () async {
        final c = MobileScannerController();
        final h = Harness(c);
        await h.reachRunning();
        await c.setZoomScale(2.0);
        expect(h.ofTag(ScannerCommand.setZoomScale).single.json['scale'], 2.0);

        // Native clamped it; the controller must report reality, not the request.
        c.debugHandleNativeEvent(
          ScannerEvent.zoomChanged,
          jsonEncode({'scale': 1.75}),
        );
        expect(c.zoomScale, 1.75);
        c.dispose();
      },
    );

    test(
      'allows any scale at or above 1.0 before the range is known',
      () async {
        final c = MobileScannerController();
        final h = Harness(c);
        await c.setZoomScale(100.0);
        expect(
          h.ofTag(ScannerCommand.setZoomScale).single.json['scale'],
          100.0,
        );
        c.dispose();
      },
    );
  });

  group('runtime reconfiguration', () {
    test('setFormats sends a mask', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.setFormats(const [BarcodeFormat.aztec]);
      expect(
        h.ofTag(ScannerCommand.setFormats).single.json['formats'],
        BarcodeFormat.aztec.value,
      );
      c.dispose();
    });

    test('setScanWindow validates before sending', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      expect(
        () => c.setScanWindow(const Rect.fromLTWH(0, 0, 2, 2)),
        throwsA(
          isA<MobileScannerException>().having(
            (e) => e.code,
            'code',
            MobileScannerErrorCode.invalidScanWindow,
          ),
        ),
      );
      expect(h.ofTag(ScannerCommand.setScanWindow), isEmpty);

      await c.setScanWindow(const Rect.fromLTWH(0.1, 0.1, 0.5, 0.5));
      expect(h.ofTag(ScannerCommand.setScanWindow).single.json['scanWindow'], [
        0.1,
        0.1,
        0.5,
        0.5,
      ]);
      c.dispose();
    });

    test('setScanWindow accepts null to clear it', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await c.setScanWindow(null);
      expect(
        h.ofTag(ScannerCommand.setScanWindow).single.json['scanWindow'],
        isNull,
      );
      c.dispose();
    });
  });

  group('detections', () {
    test('reach onDetect', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      final captures = <BarcodeCapture>[];
      c.onDetect = captures.add;
      await h.reachRunning();

      h.emitDetection([
        {'f': 'qrCode', 'v': 'hello'},
      ]);
      expect(captures, hasLength(1));
      expect(captures.single.barcodes.single.rawValue, 'hello');
      c.dispose();
    });

    test('carry every barcode from one frame in one capture', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      final captures = <BarcodeCapture>[];
      c.onDetect = captures.add;
      await h.reachRunning();

      h.emitDetection([
        {'f': 'qrCode', 'v': 'a'},
        {'f': 'ean8', 'v': 'b'},
      ]);
      expect(captures, hasLength(1));
      expect(captures.single.barcodes, hasLength(2));
      c.dispose();
    });

    test('are suppressed according to detectionSpeed', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
      final h = Harness(c);
      var calls = 0;
      c.onDetect = (_) => calls++;
      await h.reachRunning();

      for (var i = 0; i < 5; i++) {
        h.emitDetection([
          {'f': 'qrCode', 'v': 'same'},
        ], ts: 1000 + i * 33);
      }
      expect(calls, 1);
      c.dispose();
    });

    test('the capture barcode list is unmodifiable', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      BarcodeCapture? got;
      c.onDetect = (capture) => got = capture;
      await h.reachRunning();
      h.emitDetection([
        {'f': 'qrCode', 'v': 'a'},
      ]);
      expect(
        () => got!.barcodes.add(const Barcode(format: BarcodeFormat.aztec)),
        throwsUnsupportedError,
      );
      c.dispose();
    });

    test('a malformed detection is dropped without calling onDetect', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      var calls = 0;
      c.onDetect = (_) => calls++;
      await h.reachRunning();

      c.debugHandleNativeEvent(ScannerEvent.detection, 'not json');
      c.debugHandleNativeEvent(ScannerEvent.detection, '{"b":[]}');
      c.debugHandleNativeEvent(ScannerEvent.detection, '{"b":[{"f":"nope"}]}');
      expect(calls, 0);
      c.dispose();
    });

    test('an unknown event type is ignored', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      await h.reachRunning();
      expect(
        () => c.debugHandleNativeEvent(9999, '{"anything":1}'),
        returnsNormally,
      );
      c.dispose();
    });
  });

  group('errors', () {
    test('reach onError, set error, and move to the error state', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      final errors = <MobileScannerException>[];
      c.onError = errors.add;
      await h.reachRunning();

      h.emitError(MobileScannerErrorCode.cameraInUse, message: 'busy');
      expect(errors, hasLength(1));
      expect(errors.single.code, MobileScannerErrorCode.cameraInUse);
      expect(c.error?.message, 'busy');
      expect(c.state, MobileScannerState.error);
      c.dispose();
    });

    test('notify listeners', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      var notifications = 0;
      c.addListener(() => notifications++);
      h.emitError(MobileScannerErrorCode.permissionDenied);
      expect(notifications, greaterThan(0));
      c.dispose();
    });
  });

  group('disposal', () {
    test('every method throws controllerDisposed afterwards', () async {
      final c = MobileScannerController();
      Harness(c);
      c.dispose();
      expect(c.isDisposed, isTrue);

      final matcher = throwsA(
        isA<MobileScannerException>().having(
          (e) => e.code,
          'code',
          MobileScannerErrorCode.controllerDisposed,
        ),
      );
      expect(c.start, matcher);
      expect(c.stop, matcher);
      expect(c.pause, matcher);
      expect(c.resume, matcher);
      expect(c.toggleTorch, matcher);
      expect(c.switchCamera, matcher);
      expect(() => c.setTorchEnabled(true), matcher);
      expect(() => c.setZoomScale(2), matcher);
      expect(() => c.setFormats(const []), matcher);
      expect(() => c.setScanWindow(null), matcher);
      expect(() => c.setCameraFacing(CameraFacing.front), matcher);
    });

    test('a late native event never reaches a disposed controller', () async {
      // The guarantee that matters for a camera that is still mid-teardown.
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      var calls = 0;
      c.onDetect = (_) => calls++;
      await h.reachRunning();
      c.dispose();

      h.emitDetection([
        {'f': 'qrCode', 'v': 'late'},
      ]);
      h.emitError(MobileScannerErrorCode.nativeFailure);
      h.emitState(MobileScannerState.running);
      expect(calls, 0);
    });

    test('dispose is idempotent', () {
      final c = MobileScannerController();
      c.dispose();
      expect(c.dispose, returnsNormally);
    });

    test('detach stops routing and returns to stopped', () async {
      final c = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      final h = Harness(c);
      var calls = 0;
      c.onDetect = (_) => calls++;
      await h.reachRunning();

      c.detach();
      expect(c.isAttached, isFalse);
      expect(c.state, MobileScannerState.stopped);
      h.emitDetection([
        {'f': 'qrCode', 'v': 'after detach'},
      ]);
      expect(calls, 0);
      c.dispose();
    });

    test('commands after detach are dropped rather than throwing', () async {
      final c = MobileScannerController();
      final h = Harness(c);
      c.detach();
      final before = h.sent.length;
      await c.start();
      expect(h.sent.length, before);
      c.dispose();
    });
  });
}
