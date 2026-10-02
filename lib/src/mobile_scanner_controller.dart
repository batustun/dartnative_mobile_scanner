/// The scanner's imperative handle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart' show ChangeNotifier, Rect;

import 'barcode.dart';
import 'barcode_capture.dart';
import 'barcode_format.dart';
import 'camera_facing.dart';
import 'detection_speed.dart';
import 'exceptions.dart';
import 'mobile_scanner_state.dart';
import 'native/detection_gate.dart';
import 'native/scanner_codec.dart';
import 'native/scanner_ffi_bindings.dart';
import 'native/scanner_protocol.dart';
import 'scan_window.dart';
import 'torch_state.dart';

/// Sends one command to the native view this controller is attached to.
typedef ScannerCommandSink = void Function(int tag, Uint8List payload);

/// Controls one scanner: its camera, its lifecycle, and what it looks for.
///
/// A controller is a handle, not the scanner itself. The camera belongs to the
/// native view that `MobileScanner` hosts, so a controller does nothing until a
/// `MobileScanner` using it is mounted. Calls made before that are remembered as
/// intent and applied on mount, which is how [autoStart] and an initial
/// [torchEnabled] work.
///
/// It is a [ChangeNotifier], the framework's own observable model, so a widget
/// can rebuild on [state], [torchState], [facing] or [error] changing without
/// this package depending on a state-management library.
///
/// ```dart
/// final controller = MobileScannerController(
///   facing: CameraFacing.back,
///   formats: const [BarcodeFormat.qrCode, BarcodeFormat.ean13],
/// );
/// ```
///
/// Always [dispose] it when the owning widget is disposed.
///
/// ## One camera, one scanner
///
/// A device camera cannot be owned by two live sessions. Mounting a second
/// `MobileScanner` while one is running fails that second scanner with
/// [MobileScannerErrorCode.cameraInUse] rather than letting the two contend.
/// Do not run this alongside another package's camera session either.
class MobileScannerController with ChangeNotifier {
  /// Creates a controller.
  ///
  /// Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.invalidZoomScale] when [initialZoomScale] is not a
  /// finite, positive value, and with
  /// [MobileScannerErrorCode.invalidScanWindow] constraints unenforced here
  /// because the scan window belongs to the widget.
  MobileScannerController({
    this.facing = CameraFacing.back,
    this.autoStart = true,
    this.formats = const <BarcodeFormat>[],
    this.detectionSpeed = DetectionSpeed.normal,
    this.detectionTimeout = const Duration(milliseconds: 250),
    this.duplicateCooldown = const Duration(seconds: 1),
    bool torchEnabled = false,
    double initialZoomScale = 1.0,
  }) : _desiredFacing = facing,
       _desiredTorchOn = torchEnabled,
       _zoomScale = initialZoomScale {
    if (!initialZoomScale.isFinite || initialZoomScale <= 0) {
      throw MobileScannerException(
        MobileScannerErrorCode.invalidZoomScale,
        'initialZoomScale must be a finite, positive value, got '
        '$initialZoomScale.',
      );
    }
    _gate = DetectionGate(
      speed: detectionSpeed,
      detectionTimeout: detectionTimeout,
      duplicateCooldown: duplicateCooldown,
    );
  }

  /// The camera requested at construction.
  ///
  /// The camera actually in use is [facingInUse], which differs when the device
  /// lacks the requested lens.
  final CameraFacing facing;

  /// Whether the scanner starts as soon as it is mounted and permitted.
  ///
  /// With `false` the scanner stays in [MobileScannerState.stopped] until
  /// [start] is called.
  final bool autoStart;

  /// The symbologies to look for.
  ///
  /// Empty means every symbology the platform supports, which is the documented
  /// default. A non-empty list is pushed into the native recognizer, so unwanted
  /// symbologies are never decoded in the first place rather than being filtered
  /// afterwards.
  ///
  /// Requesting a format the running platform cannot recognize fails the scanner
  /// with [MobileScannerErrorCode.unsupportedBarcodeFormat]; check
  /// [MobileScanner.supportedFormats] first when you accept formats from
  /// configuration.
  final List<BarcodeFormat> formats;

  /// Which suppression rule applies to repeated detections.
  final DetectionSpeed detectionSpeed;

  /// The throttle window for [DetectionSpeed.normal]. Ignored by the other
  /// modes.
  final Duration detectionTimeout;

  /// The absence window for [DetectionSpeed.noDuplicates]. Ignored by the other
  /// modes.
  final Duration duplicateCooldown;

  late final DetectionGate _gate;

  int? _viewId;
  ScannerCommandSink? _send;
  bool _disposed = false;

  MobileScannerState _state = MobileScannerState.stopped;
  MobileScannerException? _error;
  TorchState _torchState = TorchState.unavailable;
  CameraFacing? _facingInUse;
  CameraFacing _desiredFacing;
  bool _desiredTorchOn;
  double _zoomScale;
  double _minZoomScale = 1.0;
  double _maxZoomScale = 1.0;

  /// Set by [stop] and cleared by [start].
  ///
  /// Tracked separately from [state] so that returning from the background does
  /// not restart a scanner the application deliberately stopped. The native side
  /// keeps the same distinction for the lifecycle transitions it handles itself.
  bool _explicitlyStopped = false;

  /// Where the scanner is in its lifecycle.
  ///
  /// Authoritative, and mirrored from the native side: the camera decides when it
  /// is really running, including transitions this Dart code did not ask for such
  /// as the app being backgrounded.
  MobileScannerState get state => _state;

  /// The most recent failure, or `null` when none has occurred since the last
  /// successful start.
  MobileScannerException? get error => _error;

  /// Whether the active camera has a torch, and whether it is lit.
  ///
  /// [TorchState.unavailable] until the camera is open, and on cameras with no
  /// torch at all.
  TorchState get torchState => _torchState;

  /// The camera actually in use, or `null` before one has opened.
  CameraFacing? get facingInUse => _facingInUse;

  /// The current zoom scale, where 1.0 is no zoom.
  ///
  /// Can be **below 1.0** on a device whose camera has an ultra-wide lens: a
  /// Galaxy S23 Ultra reports a range of 0.60 to 10.00, where 0.60 is the
  /// ultra-wide. Do not assume 1.0 is the floor; read [minZoomScale].
  double get zoomScale => _zoomScale;

  /// The smallest zoom scale this device accepts. 1.0 until the camera opens.
  ///
  /// Can be **below 1.0** where the camera has an ultra-wide lens, so this is a
  /// real lower bound to be read rather than assumed.
  double get minZoomScale => _minZoomScale;

  /// The largest zoom scale this device accepts. 1.0 until the camera opens,
  /// which also means "zoom range unknown", not "zoom unsupported".
  double get maxZoomScale => _maxZoomScale;

  /// Whether a `MobileScanner` using this controller is currently mounted.
  bool get isAttached => _viewId != null;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Called by the scanner element when its native view exists.
  ///
  /// Not part of the public API.
  void attach(int viewId, ScannerCommandSink send, {Rect? scanWindow}) {
    if (_disposed) return;
    _viewId = viewId;
    _send = send;
    MobileScannerBindings.registerHandler(viewId, _onNativeEvent);

    _sendJson(ScannerCommand.configure, <String, Object?>{
      'facing': _desiredFacing.wireName,
      'formats': BarcodeFormat.formatMask(formats),
      'scanWindow': scanWindow == null ? null : _rectToList(scanWindow),
      'torch': _desiredTorchOn,
      'zoom': _zoomScale,
      'autoStart': autoStart && !_explicitlyStopped,
    });
  }

  /// Called by the scanner element when its native view goes away.
  ///
  /// Not part of the public API.
  void detach() {
    final int? viewId = _viewId;
    if (viewId != null) MobileScannerBindings.unregisterHandler(viewId);
    _viewId = null;
    _send = null;
    _gate.reset();
    if (!_disposed && _state != MobileScannerState.stopped) {
      _state = MobileScannerState.stopped;
      notifyListeners();
    }
  }

  /// Opens the camera and begins analysis.
  ///
  /// Clears the "explicitly stopped" flag, so the scanner will also come back by
  /// itself after the app returns from the background.
  ///
  /// A no-op when the scanner is already [MobileScannerState.starting] or
  /// [MobileScannerState.running], so a duplicated lifecycle callback cannot
  /// restart a healthy session. Valid from [MobileScannerState.stopped],
  /// [MobileScannerState.paused] and [MobileScannerState.error].
  ///
  /// Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.controllerDisposed] after [dispose]. Failures to
  /// actually open the camera arrive asynchronously, as [error] and through
  /// `MobileScanner.onError`, because the camera is opened natively.
  Future<void> start() async {
    _assertUsable();
    _explicitlyStopped = false;
    if (_state == MobileScannerState.starting ||
        _state == MobileScannerState.running) {
      return;
    }
    _error = null;
    _gate.reset();
    _setState(MobileScannerState.starting);
    _sendEmpty(ScannerCommand.start);
  }

  /// Tears the session down and releases the camera.
  ///
  /// Marks the scanner as explicitly stopped, so returning from the background
  /// will not restart it. A no-op when already stopped or stopping.
  Future<void> stop() async {
    _assertUsable();
    _explicitlyStopped = true;
    if (_state == MobileScannerState.stopped ||
        _state == MobileScannerState.stopping) {
      return;
    }
    _setState(MobileScannerState.stopping);
    _sendEmpty(ScannerCommand.stop);
  }

  /// Suspends analysis and releases the camera, keeping the scanner mounted.
  ///
  /// Use this for a transient overlay, a sheet, or any moment the preview should
  /// go idle without being torn down. Unlike [stop] it does not mark the scanner
  /// explicitly stopped, so lifecycle-driven resumption still applies.
  ///
  /// Only valid from [MobileScannerState.running]; a no-op otherwise.
  Future<void> pause() async {
    _assertUsable();
    if (_state != MobileScannerState.running) return;
    _sendEmpty(ScannerCommand.pause);
  }

  /// Reacquires the camera after [pause].
  ///
  /// Only valid from [MobileScannerState.paused]; a no-op otherwise. Duplicate
  /// suppression history is cleared, so the barcode that was visible before the
  /// pause is reported again.
  Future<void> resume() async {
    _assertUsable();
    if (_state != MobileScannerState.paused) return;
    _gate.reset();
    _sendEmpty(ScannerCommand.resume);
  }

  /// Turns the torch on when it is off, and off when it is on.
  ///
  /// Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.torchUnavailable] when the active camera has no
  /// torch, rather than reporting a success that did not happen.
  Future<void> toggleTorch() => setTorchEnabled(_torchState != TorchState.on);

  /// Turns the torch on or off.
  ///
  /// Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.torchUnavailable] when the camera is open and has
  /// no torch. Before the camera opens the request is remembered and applied on
  /// start, because torch availability is not known until then.
  Future<void> setTorchEnabled(bool enabled) async {
    _assertUsable();
    if (isAttached &&
        _state.hasSession &&
        _torchState == TorchState.unavailable) {
      throw MobileScannerException(
        MobileScannerErrorCode.torchUnavailable,
        'The active camera has no torch.',
      );
    }
    _desiredTorchOn = enabled;
    _sendJson(ScannerCommand.setTorch, <String, Object?>{'on': enabled});
  }

  /// Switches between the front and back camera.
  ///
  /// The session is rebuilt around the new camera: the old input and use cases
  /// are released before the new ones are configured, so the two never overlap.
  /// Lifecycle state is preserved, so a running scanner keeps running, and
  /// duplicate suppression is cleared.
  ///
  /// A device that lacks the requested camera fails with
  /// [MobileScannerErrorCode.unsupportedCamera]. The previous session is released
  /// rather than left running with its results suppressed, so the scanner ends in
  /// [MobileScannerState.error]; call [start] to come back on the camera that does
  /// exist.
  Future<void> switchCamera() => setCameraFacing(
    (_facingInUse ?? _desiredFacing) == CameraFacing.back
        ? CameraFacing.front
        : CameraFacing.back,
  );

  /// Selects a specific camera.
  ///
  /// A no-op when that camera is already in use. See [switchCamera] for the
  /// transition's guarantees.
  Future<void> setCameraFacing(CameraFacing target) async {
    _assertUsable();
    if (_facingInUse == target) return;
    _desiredFacing = target;
    _gate.reset();
    _torchState = TorchState.unavailable;
    notifyListeners();
    _sendJson(ScannerCommand.setFacing, <String, Object?>{
      'facing': target.wireName,
    });
  }

  /// Sets the camera's zoom scale, where 1.0 is no zoom.
  ///
  /// Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.invalidZoomScale] when [scale] is not finite or not
  /// positive, or, once the camera is open and its range known, falls outside
  /// [minZoomScale] to [maxZoomScale].
  ///
  /// The range is device specific at **both** ends. A device with an ultra-wide
  /// lens reports a minimum below 1.0, so there is no 1.0 floor: query
  /// [minZoomScale] and [maxZoomScale] rather than assuming either bound.
  /// Measured examples: iPhone 15 Pro Max reports 1.00 to 123.75, Galaxy S23
  /// Ultra reports 0.60 to 10.00.
  ///
  /// **Pass the bounds themselves, not a literal you read off a UI.** Both
  /// platforms report zoom as a 32-bit float, so the bounds widen to values that
  /// are not round in Dart: that Galaxy minimum is actually
  /// `0.6000000238418579`, and `setZoomScale(0.6)` is therefore correctly
  /// rejected as below the minimum. `setZoomScale(controller.minZoomScale)`
  /// works.
  ///
  /// The native side reports the scale it actually applied, so [zoomScale]
  /// reflects reality rather than the request.
  Future<void> setZoomScale(double scale) async {
    _assertUsable();
    // A zoom ratio must be positive and finite. There is deliberately no 1.0
    // floor here: a device with an ultra-wide lens reports a minimum below 1.0,
    // and rejecting that would advertise a [minZoomScale] the setter refuses.
    if (!scale.isFinite || scale <= 0) {
      throw MobileScannerException(
        MobileScannerErrorCode.invalidZoomScale,
        'zoomScale must be a finite, positive value, got $scale.',
      );
    }
    // Enforced only once the camera has reported a real range; before that both
    // bounds are 1.0 and the native side clamps whatever it is given.
    if (_maxZoomScale > _minZoomScale &&
        (scale < _minZoomScale || scale > _maxZoomScale)) {
      throw MobileScannerException(
        MobileScannerErrorCode.invalidZoomScale,
        'zoomScale $scale is outside this device\'s range '
        '$_minZoomScale to $_maxZoomScale.',
      );
    }
    _sendJson(ScannerCommand.setZoomScale, <String, Object?>{'scale': scale});
  }

  /// Replaces the set of symbologies being looked for, on a live session.
  ///
  /// An empty [next] means every supported symbology. The native recognizer is
  /// reconfigured, so this changes what is decoded rather than filtering results.
  Future<void> setFormats(List<BarcodeFormat> next) async {
    _assertUsable();
    _sendJson(ScannerCommand.setFormats, <String, Object?>{
      'formats': BarcodeFormat.formatMask(next),
    });
  }

  /// Replaces the scan window on a live session, or clears it with `null`.
  ///
  /// See `MobileScanner.scanWindow` for the coordinate system and the
  /// constraints. Throws [MobileScannerException] with
  /// [MobileScannerErrorCode.invalidScanWindow] for an invalid rectangle.
  Future<void> setScanWindow(Rect? window) async {
    _assertUsable();
    if (window != null) validateScanWindow(window);
    _sendJson(ScannerCommand.setScanWindow, <String, Object?>{
      'scanWindow': window == null ? null : _rectToList(window),
    });
  }

  /// The callback the hosting widget wants detections delivered to.
  ///
  /// Set by the element on every rebuild so the latest build's callback is the
  /// one that runs. Not part of the public API.
  void Function(BarcodeCapture capture)? onDetect;

  /// The callback the hosting widget wants failures delivered to.
  ///
  /// Not part of the public API.
  void Function(MobileScannerException error)? onError;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final int? viewId = _viewId;
    if (viewId != null) MobileScannerBindings.unregisterHandler(viewId);
    _viewId = null;
    _send = null;
    onDetect = null;
    onError = null;
    _gate.reset();
    super.dispose();
  }

  /// Feeds one native event in, exactly as the dispatcher would.
  ///
  /// The seam the test suite drives the controller through, so the state machine,
  /// the suppression rules and the payload decoding are all exercised without a
  /// camera. Not part of the public API.
  void debugHandleNativeEvent(int type, String payload) =>
      _onNativeEvent(type, payload);

  // ── Native event routing ──────────────────────────────────────────────────

  void _onNativeEvent(int type, String payload) {
    // A disposed or detached controller never emits, even if native is still
    // mid-teardown. Routing already stops at the dispatcher when the handler is
    // unregistered; this is the same guarantee enforced a second time here, so it
    // holds however the event arrived.
    if (_disposed || _viewId == null) return;

    final Map<String, Object?>? json = decodeEnvelope(payload);
    if (json == null) return;

    switch (type) {
      case ScannerEvent.detection:
        _handleDetection(json);
      case ScannerEvent.stateChanged:
        final MobileScannerState? next = decodeState(json);
        if (next != null) _setState(next);
      case ScannerEvent.error:
        _handleError(decodeError(json));
      case ScannerEvent.torchStateChanged:
        final TorchState? next = decodeTorchState(json);
        if (next != null && next != _torchState) {
          _torchState = next;
          notifyListeners();
        }
      case ScannerEvent.ready:
        _handleReady(json);
      case ScannerEvent.zoomChanged:
        final double? scale = decodeZoomScale(json);
        if (scale != null && scale != _zoomScale) {
          _zoomScale = scale;
          notifyListeners();
        }
      default:
        // An event type from a newer native build. Ignored, not fatal.
        break;
    }
  }

  void _handleDetection(Map<String, Object?> json) {
    final decoded = decodeDetection(json);
    if (decoded == null) return;

    final BarcodeCapture? capture = _gate.admit(
      decoded.barcodes,
      decoded.timestamp,
      build: (List<Barcode> accepted) => BarcodeCapture(
        barcodes: List<Barcode>.unmodifiable(accepted),
        timestamp: decoded.timestamp,
        imageSize: decoded.imageSize,
      ),
    );
    if (capture == null) return;

    final void Function(BarcodeCapture)? callback = onDetect;
    if (callback == null) return;

    // User code runs on the platform main thread, inside the native call. The
    // camera's analyzer is not blocked by it: Android analyses on its own
    // executor and drops stale frames, and AVFoundation delivers metadata on its
    // own queue. A throw must not unwind into native code, so it is rethrown
    // asynchronously for the app's error handling to see.
    try {
      callback(capture);
    } on Object catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  void _handleReady(Map<String, Object?> json) {
    final ScannerReadyInfo? info = decodeReady(json);
    if (info == null) return;
    _facingInUse = info.facing;
    _torchState = info.torchState;
    _minZoomScale = info.minZoomScale;
    _maxZoomScale = info.maxZoomScale;
    notifyListeners();
  }

  void _handleError(MobileScannerException exception) {
    _error = exception;
    _setState(MobileScannerState.error);
    final void Function(MobileScannerException)? callback = onError;
    if (callback == null) return;
    try {
      callback(exception);
    } on Object catch (e, st) {
      Zone.current.handleUncaughtError(e, st);
    }
  }

  void _setState(MobileScannerState next) {
    if (_state == next) return;
    _state = next;
    if (next == MobileScannerState.stopped ||
        next == MobileScannerState.error) {
      _gate.reset();
    }
    notifyListeners();
  }

  // ── Command plumbing ──────────────────────────────────────────────────────

  void _assertUsable() {
    if (_disposed) {
      throw const MobileScannerException(
        MobileScannerErrorCode.controllerDisposed,
        'This MobileScannerController has been disposed.',
      );
    }
  }

  void _sendEmpty(int tag) => _send?.call(tag, Uint8List(0));

  void _sendJson(int tag, Map<String, Object?> body) {
    final sink = _send;
    if (sink == null) return;
    sink(tag, Uint8List.fromList(utf8.encode(jsonEncode(body))));
  }

  static List<double> _rectToList(Rect r) => <double>[
    r.left,
    r.top,
    r.width,
    r.height,
  ];
}
