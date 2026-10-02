/// Real-time barcode and QR scanning for DartNative, with recognition kept
/// native.
///
/// iOS runs an `AVCaptureSession` with `AVCaptureMetadataOutput`; Android runs
/// CameraX `ImageAnalysis` feeding Google ML Kit. Camera frames never cross into
/// Dart, so only decoded results travel over the FFI boundary.
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
library;

export 'src/barcode.dart';
export 'src/barcode_capture.dart';
export 'src/barcode_format.dart';
export 'src/camera_facing.dart';
export 'src/detection_speed.dart';
export 'src/exceptions.dart';
export 'src/mobile_scanner.dart'
    show
        MobileScanner,
        MobileScannerViewType,
        registerMobileScannerElementFactory;
export 'src/mobile_scanner_controller.dart'
    show MobileScannerController, ScannerCommandSink;
export 'src/mobile_scanner_state.dart';
export 'src/native/scanner_ffi_bindings.dart' show MobileScannerBindings;
export 'src/torch_state.dart';
