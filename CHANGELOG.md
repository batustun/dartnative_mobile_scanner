## 0.1.0

First release.

Native barcode and QR scanning for DartNative. iOS uses `AVCaptureSession` with
`AVCaptureMetadataOutput`; Android uses CameraX `ImageAnalysis` with bundled
Google ML Kit barcode scanning. Camera frames never cross into Dart.

- `MobileScanner`, a hosted native camera preview that recognizes barcodes.
- `MobileScannerController` with `start`, `stop`, `pause`, `resume`,
  `toggleTorch`, `setTorchEnabled`, `switchCamera`, `setCameraFacing`,
  `setZoomScale`, `setFormats` and `setScanWindow`. It is a `ChangeNotifier`,
  exposing `state`, `error`, `torchState`, `facingInUse`, `zoomScale`,
  `minZoomScale` and `maxZoomScale`.
- Thirteen symbologies: QR Code, Aztec, Data Matrix, PDF417, EAN-13, EAN-8,
  UPC-A, UPC-E, Code 39, Code 93, Code 128, ITF and Codabar. Codabar needs
  iOS 15.4 or newer; `MobileScanner.supportedFormats` reports what the running
  platform can do.
- Format filtering configured into the native recognizer, so unwanted symbologies
  are never decoded.
- Several barcodes from one frame delivered in one `BarcodeCapture`.
- Three duplicate-suppression modes with defined semantics: `normal` throttles to
  one capture per 250 ms, `noDuplicates` suppresses a barcode until it has been
  absent for one second, `unrestricted` emits everything.
- A scan window in normalized preview coordinates, enforced through
  `AVCaptureMetadataOutput.rectOfInterest` on iOS and by filtering transformed
  detection bounds on Android.
- Barcode geometry, `boundingBox` and `cornerPoints`, in normalized preview
  coordinates, converted with each platform's own API.
- Camera permission handled by the plugin, including a distinct
  `permissionPermanentlyDenied`. No Android manifest change in the host app, and
  no storage permission requested.
- Background and foreground handled natively, keeping "stopped by the app"
  distinct from "stopped by the lifecycle".
- One camera session per scanner, process-wide, with a typed `cameraInUse` for a
  second instance.
- Typed failures throughout: `MobileScannerException` with a
  `MobileScannerErrorCode` and the platform's own `nativeCode` where there is one.
- Hot-restart safe: one dispatcher slot, re-checked before every delivery, and
  native sessions from a previous Dart session are reclaimed on load.

### Validation status

Hardware-validated on both platforms: iPhone 15 Pro Max (iOS 26.6) and Samsung
Galaxy S23 Ultra (Android 16, API 36). All thirteen formats, multiple barcodes in
one frame, duplicate suppression, permission grant and both denial paths, the full
controller and lifecycle matrix, torch, camera switching, zoom, the scan window in
portrait and landscape and on the front camera, a hot restart with detections in
flight, and soaks of 295 and 311 operation cycles with no errors. Android also ran
generation isolation across 16 camera switches with no stale deliveries, and a
sustained `ImageAnalysis` load of 15,403 analyzed frames with no image-pool
exhaustion and no memory trend.

Per-row results, the devices used, and the five defects found and fixed during
physical validation are recorded in `doc/manual-test-matrix.md`.
