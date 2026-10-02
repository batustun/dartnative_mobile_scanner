/// The scanner widget and the native element that hosts the camera preview.
library;

import 'dart:typed_data';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative/plugin.dart';

import 'barcode_capture.dart';
import 'barcode_format.dart';
import 'exceptions.dart';
import 'mobile_scanner_controller.dart';
import 'native/scanner_codec.dart';
import 'native/scanner_ffi_bindings.dart';
import 'scan_window.dart';

/// The view type this plugin provides.
///
/// The index is assigned by the framework at runtime from the namespaced key,
/// and the Swift and Kotlin sides claim the same key, so the two always agree and
/// cannot collide with another plugin.
abstract final class MobileScannerViewType {
  /// The scanner's camera preview.
  static final int preview = ViewType.claim(
    'com.dartnative.mobile_scanner/preview',
  );
}

/// A live camera preview that recognizes barcodes natively.
///
/// Recognition never leaves the native side: iOS uses
/// `AVCaptureMetadataOutput` on an `AVCaptureSession`, Android uses CameraX
/// `ImageAnalysis` feeding Google ML Kit. Only the decoded result crosses into
/// Dart, so camera frames are never copied through the FFI boundary.
///
/// ```dart
/// MobileScanner(
///   onDetect: (capture) {
///     for (final barcode in capture.barcodes) {
///       print(barcode.rawValue);
///     }
///   },
/// )
/// ```
///
/// ## Give it definite bounds
///
/// The preview has no intrinsic size. Size it with explicit bounds, a
/// `SizedBox`, or `Positioned` edges plus a height. **Never size it with
/// `AspectRatio`**: it then measures zero at first attach, the camera surface
/// never appears, and CameraX gives up after about five seconds. To frame a
/// specific ratio, compute the height from the available width.
///
/// ```dart
/// SizedBox(
///   width: width,
///   height: width * 4 / 3,
///   child: MobileScanner(onDetect: _onDetect),
/// )
/// ```
///
/// ## Permissions
///
/// The host application declares the permission text; this plugin does not
/// invent it. iOS needs `NSCameraUsageDescription` in `Info.plist` or the system
/// terminates the app on first camera use. Android needs nothing in the app
/// manifest, because this plugin's own manifest declares `android.permission.CAMERA`.
/// A refusal is reported as [MobileScannerErrorCode.permissionDenied] or
/// [MobileScannerErrorCode.permissionPermanentlyDenied], never a crash.
class MobileScanner extends Widget {
  /// Creates a scanner.
  const MobileScanner({
    super.key,
    this.controller,
    this.onDetect,
    this.onError,
    this.scanWindow,
  });

  /// The controller driving this scanner.
  ///
  /// Optional. Without one the scanner creates and owns a controller with default
  /// settings, started automatically, and disposes it on unmount. Supply one when
  /// you need to start and stop the scanner, control the torch, switch cameras,
  /// filter formats, or observe [MobileScannerController.state].
  ///
  /// A supplied controller is **not** disposed by this widget; dispose it with
  /// whatever owns it.
  final MobileScannerController? controller;

  /// Called for each accepted detection event.
  ///
  /// One call carries every barcode recognized in one frame, so a frame holding
  /// three symbols produces one call with three [BarcodeCapture.barcodes]. How
  /// often this fires is governed by
  /// [MobileScannerController.detectionSpeed]; the default suppresses the flood
  /// a held barcode would otherwise cause.
  ///
  /// Runs on the platform main thread, which is also the UI thread, so keep it
  /// short and move real work off it. The camera's analyzer is not blocked by a
  /// slow callback, but the interface is. A throw is reported to the zone's error
  /// handler rather than unwinding into native code.
  final void Function(BarcodeCapture capture)? onDetect;

  /// Called when the scanner fails.
  ///
  /// Receives permission refusals, an unavailable or busy camera, an unsupported
  /// format, and native failures. The same value is available as
  /// [MobileScannerController.error].
  final void Function(MobileScannerException error)? onError;

  /// Restricts recognition to part of the frame.
  ///
  /// Expressed in **normalized preview coordinates**, the same space as
  /// [Barcode.boundingBox]: `left`, `top`, `width` and `height` each run `0.0`
  /// to `1.0` across the preview box as displayed, origin at the top left. So
  /// the window is the region of what the user sees, which is what you actually
  /// want to reason about, and one value is correct on every device and
  /// resolution.
  ///
  /// A centred band covering the middle 30 percent of the height:
  ///
  /// ```dart
  /// MobileScanner(
  ///   scanWindow: const Rect.fromLTWH(0.1, 0.35, 0.8, 0.3),
  ///   onDetect: _onDetect,
  /// )
  /// ```
  ///
  /// The rectangle must be finite, have a positive width and height, and lie
  /// inside the unit square. An invalid rectangle throws
  /// [MobileScannerException] with
  /// [MobileScannerErrorCode.invalidScanWindow] at mount, rather than producing a
  /// scanner that silently never detects anything. Passing device pixels by
  /// mistake fails this way too.
  ///
  /// A scan window is **a normalized preview-space region of interest used to
  /// limit which detections are reported.** The underlying native mechanism
  /// differs by platform:
  ///
  /// * **iOS** converts it with
  ///   `AVCaptureVideoPreviewLayer.metadataOutputRectConverted(fromLayerRect:)`
  ///   and sets `AVCaptureMetadataOutput.rectOfInterest`, so the native
  ///   recognition pipeline itself is constrained to the region.
  /// * **Android** performs native ML Kit decoding on the analyzed frame and then
  ///   filters the decoded geometry against the window, because CameraX exposes
  ///   no region-of-interest control on `ImageAnalysis`. So on Android the window
  ///   is primarily a **reported-detection region**, not a guarantee that ML Kit
  ///   avoided decoding pixels outside it. Do not read it as a native decode
  ///   crop; that distinction matters when reasoning about cost.
  ///
  /// Because the mechanisms differ, **behaviour at the window's boundary is
  /// platform-dependent**:
  ///
  /// * **iOS** constrains native decoding to the region, so a barcode only
  ///   partly inside it may not be decoded at all.
  /// * **Android** may report a decoded barcode whose bounds **intersect** the
  ///   window.
  ///
  /// This is a platform-mechanism difference, not a defect. Android deliberately
  /// does not discard a barcode ML Kit already decoded in order to imitate iOS.
  /// No full-containment guarantee is offered on either platform, and no
  /// pixel-identical cross-platform boundary semantics are claimed.
  ///
  /// An application that needs a stricter rule can apply it to
  /// [Barcode.boundingBox] or [Barcode.cornerPoints] itself: full containment,
  /// centre-point-inside, or any overlap threshold it prefers. This package
  /// intentionally exposes no option for that choice.
  ///
  /// `null`, the default, inspects the whole frame.
  final Rect? scanWindow;

  /// The symbologies **this package implements** on the running platform and OS
  /// version.
  ///
  /// It is not a promise about the camera in your hand. Read it as "the package
  /// knows how to ask for these here", not "this device will certainly recognize
  /// these".
  ///
  /// How it is derived:
  ///
  /// * **Android**: every [BarcodeFormat]. The ML Kit model is bundled, so what it
  ///   can read is fixed at build time and does not vary by device or OS version.
  /// * **iOS**: every [BarcodeFormat] except [BarcodeFormat.codabar] below
  ///   iOS 15.4, where `AVMetadataObject.ObjectType.codabar` does not exist. The
  ///   value is computed from the OS version alone, without opening a camera.
  ///
  /// **Actual runtime availability can be narrower than this set.** On iOS the
  /// authoritative list is `AVCaptureMetadataOutput.availableMetadataObjectTypes`,
  /// which depends on the capture device and is only known once a session has been
  /// configured. The requested formats are intersected against it when the scanner
  /// configures, and a request that resolves to nothing the device can recognize
  /// fails with [MobileScannerErrorCode.unsupportedBarcodeFormat] rather than
  /// quietly scanning for nothing.
  ///
  /// So this getter is the cheap pre-flight check, and the typed error at start is
  /// the authoritative one. Use the former to avoid offering a format you could
  /// never support, and handle the latter for the device that turns out not to.
  ///
  /// Empty when the native library is unavailable, which also means the scanner
  /// cannot run at all.
  static Set<BarcodeFormat> get supportedFormats =>
      decodeSupportedFormats(MobileScannerBindings.supportedFormatsJson());
}

/// Hosts the native camera preview for a [MobileScanner].
///
/// Not part of the public API.
class MobileScannerElement extends NativeElement {
  /// Creates the element.
  MobileScannerElement(MobileScanner super.widget);

  MobileScanner get _widget => widget as MobileScanner;

  /// The controller this element created itself, and must therefore dispose.
  MobileScannerController? _ownedController;

  MobileScannerController? _attached;

  @override
  int get viewType => MobileScannerViewType.preview;

  @override
  ViewProps buildProps() => const FlexProps(direction: 0, grow: 1);

  /// The preview has no intrinsic size, so inside a `Stack` it needs the full
  /// width to work from. See `NativeElement.stretchAsStackFlowChild`.
  @override
  bool get stretchAsStackFlowChild => true;

  @override
  void mount(Element? parent, UIKitReconciler reconciler) {
    super.mount(parent, reconciler);
    _inBuildPhase = true;
    try {
      _mount(reconciler);
    } finally {
      _inBuildPhase = false;
    }
  }

  void _mount(UIKitReconciler reconciler) {
    final Rect? window = _widget.scanWindow;
    if (window != null) validateScanWindow(window);

    final int id = viewId!;

    // Without this the preview collapses to width 0 inside a Column, whose
    // default cross-axis alignment is center, and the camera surface renders
    // black on Android while looking fine on iOS.
    emitMutation(SetAlignSelf(id, 1));

    final MobileScannerController controller = _resolveController();
    _attached = controller;
    _syncCallbacks(controller);
    controller.attach(id, _send, scanWindow: window);
  }

  @override
  void update(Widget newWidget) {
    _inBuildPhase = true;
    try {
      _update(newWidget);
    } finally {
      _inBuildPhase = false;
    }
  }

  void _update(Widget newWidget) {
    final MobileScanner old = _widget;
    super.update(newWidget);
    final MobileScanner next = _widget;

    // A different controller means a different session owner, so hand the view
    // over rather than leaving the old controller wired to it.
    if (next.controller != old.controller) {
      _attached?.detach();
      _clearCallbacks(_attached);
      _ownedController?.dispose();
      _ownedController = null;

      final MobileScannerController controller = _resolveController();
      _attached = controller;
      _syncCallbacks(controller);
      controller.attach(viewId!, _send, scanWindow: next.scanWindow);
      return;
    }

    // Re-point the callbacks at the latest build on every update, so a rebuilt
    // closure is the one that runs.
    _syncCallbacks(_attached);

    if (next.scanWindow != old.scanWindow) {
      final Rect? window = next.scanWindow;
      if (window != null) validateScanWindow(window);
      final MobileScannerController? controller = _attached;
      // A controller the application disposed while this scanner was still
      // mounted would reject the call; an unawaited rejected Future would then
      // surface as an unhandled async error rather than anything actionable.
      if (controller != null && !controller.isDisposed) {
        controller.setScanWindow(window);
      }
    }
  }

  @override
  void unmount() {
    _attached?.detach();
    _clearCallbacks(_attached);
    _attached = null;
    _ownedController?.dispose();
    _ownedController = null;
    super.unmount();
  }

  MobileScannerController _resolveController() {
    final MobileScannerController? supplied = _widget.controller;
    if (supplied != null) return supplied;
    final MobileScannerController owned = MobileScannerController();
    _ownedController = owned;
    return owned;
  }

  /// Reads the callbacks through the element, not through a captured closure, so
  /// the newest build's handlers always run.
  void _syncCallbacks(MobileScannerController? controller) {
    if (controller == null || controller.isDisposed) return;
    controller.onDetect = (BarcodeCapture capture) =>
        _widget.onDetect?.call(capture);
    controller.onError = (MobileScannerException error) =>
        _widget.onError?.call(error);
  }

  void _clearCallbacks(MobileScannerController? controller) {
    if (controller == null || controller.isDisposed) return;
    controller.onDetect = null;
    controller.onError = null;
  }

  /// True while `mount` or `update` is running.
  ///
  /// Commands emitted during a build are carried out by the framework's own
  /// mutation batch, so forcing a flush there would push this view's CreateView
  /// to native ahead of the parent mutations it depends on.
  bool _inBuildPhase = false;

  void _send(int tag, Uint8List payload) {
    final ViewId? id = viewId;
    if (id == null) return;
    emitMutation(PluginMutation(id, tag, payload));
    if (_inBuildPhase) return;

    // A controller command arrives from application code, not from a build, so
    // nothing schedules a frame and the mutation batch would otherwise sit
    // unflushed. On an idle app that means `stop()` leaves the camera running
    // until something unrelated happens to trigger a frame, which is both a
    // privacy problem and a battery one. Flushing here makes delivery depend on
    // the call rather than on whether the interface happens to be animating.
    reconciler.flushMutationsNow();
  }
}

/// Registers the scanner widget with the rendering pipeline.
///
/// Called from `MobileScannerBindings.loadSymbols()`, which the generated
/// `DartNativePluginRegistrant.registerAll()` runs. Applications do not call
/// this.
void registerMobileScannerElementFactory() {
  DartNativeReconciler.registerElementFactory<MobileScanner>(
    MobileScannerElement.new,
  );
}
