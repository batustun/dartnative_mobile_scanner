# mobile_scanner

Real-time barcode and QR scanning for [DartNative](https://dartnative.com), with
recognition kept on the native side.

- **iOS** runs an `AVCaptureSession` with `AVCaptureMetadataOutput`, AVFoundation's
  own metadata pipeline.
- **Android** runs CameraX `ImageAnalysis` feeding Google ML Kit barcode scanning,
  with the model bundled in the app.
- **No Flutter platform channels.** No `MethodChannel`, no `EventChannel`, no
  `package:flutter` import. Dart talks to both platforms over FFI.
- **Camera frames never cross into Dart.** Only the decoded result does: a format,
  a value, geometry, a timestamp. At 1080p a frame is several megabytes; a
  detection is a couple of hundred bytes.

```dart
MobileScanner(
  onDetect: (capture) {
    for (final barcode in capture.barcodes) {
      print(barcode.rawValue);
    }
  },
)
```

## Features

Everything listed here is implemented:

- live native camera preview
- real-time recognition of QR and twelve other symbologies
- format filtering pushed **into** the native recognizer, so unwanted symbologies
  are never decoded
- several barcodes from one frame in one callback
- three duplicate-suppression modes with defined semantics
- a scan window: a normalized preview-space region limiting which detections
  are reported, via `rectOfInterest` on iOS and result filtering on Android
- start, stop, pause and resume with deterministic state
- front and back camera selection, and switching on a live session
- torch control that reports honestly when the camera has no torch
- zoom, validated against the range the device actually reports
- typed errors for every failure, including permission refusals
- camera permission handled by the plugin, with no app manifest changes on Android
- background and foreground handled natively, without restarting a scanner the
  app deliberately stopped

## Installation

```yaml
dependencies:
  mobile_scanner:
    hosted: https://dartpub.dev
    version: ^0.1.0
```

```sh
dn pub get
```

The `hosted:` line is required, not optional. DartNative plugins live on
dartpub.dev, and an unrelated Flutter package also called `mobile_scanner` is
published on pub.dev. Without `hosted:`, `dn pub get` resolves that one instead
and pulls in the Flutter SDK with it.

That is all. `dn pub get` regenerates `lib/dartnative_plugin_registrant.dart`, and
`registerAll()` loads this plugin's symbols and registers its view:

```dart
void main() {
  DartNativePluginRegistrant.registerAll();
  runApp(const MyApp());
}
```

Do not edit `AppDelegate.swift` or `Application.kt`, and do not add a manual
`pod 'mobile_scanner'` line. Wiring is automatic on both platforms.

## Basic usage

```dart
import 'package:mobile_scanner/mobile_scanner.dart';

MobileScanner(
  onDetect: (capture) {
    for (final barcode in capture.barcodes) {
      print('${barcode.format.name}: ${barcode.rawValue}');
    }
  },
)
```

Without a controller the scanner creates one with default settings, starts
automatically, and disposes it when the widget unmounts.

### Give the preview definite bounds

The preview has no intrinsic size. Size it explicitly:

```dart
final width = MediaQuery.sizeOf(context).width;

SizedBox(
  width: width,
  height: width * 4 / 3,
  child: MobileScanner(onDetect: _onDetect),
)
```

**Never size it with `AspectRatio`.** It then measures zero on the first attach,
the camera surface never appears, and CameraX gives up after about five seconds.
To frame a ratio, compute the height from the available width as above.

## Controller usage

```dart
final controller = MobileScannerController(
  facing: CameraFacing.back,
  autoStart: true,
  torchEnabled: false,
  formats: const [BarcodeFormat.qrCode, BarcodeFormat.ean13],
  detectionSpeed: DetectionSpeed.noDuplicates,
);

MobileScanner(
  controller: controller,
  onDetect: _onDetect,
  onError: (error) => print(error.code),
)
```

```dart
await controller.start();
await controller.stop();
await controller.pause();
await controller.resume();

await controller.toggleTorch();
await controller.setTorchEnabled(true);

await controller.switchCamera();
await controller.setCameraFacing(CameraFacing.front);

await controller.setZoomScale(2.0);
await controller.setFormats(const [BarcodeFormat.qrCode]);
await controller.setScanWindow(const Rect.fromLTWH(0.1, 0.35, 0.8, 0.3));
```

A controller you create is yours to `dispose()`. One the widget created disposes
itself.

### Observing state

`MobileScannerController` is a `ChangeNotifier`, the framework's own observable
model, so there is no state-management dependency to adopt:

```dart
controller.addListener(() {
  print(controller.state);        // MobileScannerState
  print(controller.torchState);   // on / off / unavailable
  print(controller.facingInUse);  // the camera that actually opened
  print(controller.zoomScale);    // what native applied, not what you asked for
  print(controller.error);        // the last MobileScannerException, or null
});
```

## Barcode format filtering

An empty list, the default, asks for every symbology the platform supports.
A non-empty list is configured **into** the recognizer: `BarcodeScannerOptions`
on Android, `metadataObjectTypes` on iOS. Unwanted symbologies are never decoded,
rather than decoded and then filtered.

```dart
MobileScannerController(
  formats: const [BarcodeFormat.qrCode, BarcodeFormat.ean13],
)
```

Check support before accepting formats from configuration:

```dart
if (!MobileScanner.supportedFormats.contains(BarcodeFormat.codabar)) {
  // Codabar needs iOS 15.4 or newer.
}
```

`MobileScanner.supportedFormats` reports what **this package implements** on the
running platform and OS version: all thirteen on Android, where the ML Kit model is
bundled and so fixed at build time, and all but Codabar on iOS below 15.4. It is
computed without opening a camera, so it is a cheap pre-flight check and **not** a
guarantee about the device.

The authoritative list on iOS is
`AVCaptureMetadataOutput.availableMetadataObjectTypes`, which depends on the
capture device and is only known once a session is configured. The requested
formats are intersected against it at that point, and a request that resolves to
nothing the device can recognize fails with
`MobileScannerErrorCode.unsupportedBarcodeFormat`. A format is never silently
ignored, and an unsupported one never crashes the app.

## Duplicate handling

A camera delivers about 30 frames a second and a barcode held in front of it is
recognized in most of them. All three modes are implemented once, on the Dart
side, so the behaviour is identical on both platforms and is unit tested.

### `DetectionSpeed.normal` (default)

When a capture is emitted, every capture arriving in the next
`detectionTimeout` is dropped, whatever it contains. The default timeout is
**250 ms**, so a held barcode produces about four events a second.

This throttles by time, not by value: a different barcode entering the frame
during the window is also dropped and is reported by the next frame after the
window closes. That costs at most one timeout of latency and keeps the rule
simple to reason about.

### `DetectionSpeed.noDuplicates`

A detection is suppressed when a barcode with the same identity was last **seen**
less than `duplicateCooldown` ago. The default cooldown is **one second**.

"Seen" means observed in an incoming detection, whether or not it was emitted. So
a barcode that stays in frame keeps renewing its own suppression and is never
re-emitted; it becomes eligible again only after being absent for the full
cooldown, which in practice means it left the frame and came back.

Suppression is **per barcode**, not per capture: a frame holding one already-seen
barcode and one new one emits a capture containing only the new one.

Identity is the format plus `rawValue`; where there is no text value it falls back
to the format plus `rawBytes`. A barcode carrying neither cannot be identified
across frames and is never suppressed.

### `DetectionSpeed.unrestricted`

Every detection the platform reports is emitted, so `onDetect` can fire at the
frame rate. Use it to track a barcode's movement or to measure the pipeline, and
remember your callback runs on the thread that draws the interface.

```dart
MobileScannerController(
  detectionSpeed: DetectionSpeed.normal,
  detectionTimeout: const Duration(milliseconds: 500),
  duplicateCooldown: const Duration(seconds: 2),
)
```

## Scan window

A scan window is given in **normalized preview coordinates**: `left`, `top`,
`width` and `height` each run `0.0` to `1.0` across the preview box as displayed,
origin at the top left. It is the region of what the user sees, which is what you
want to reason about, and one value is correct on every device and resolution.

```dart
MobileScanner(
  scanWindow: const Rect.fromLTWH(0.1, 0.35, 0.8, 0.3), // a centred band
  onDetect: _onDetect,
)
```

The rectangle must be finite, have a positive width and height, and lie inside the
unit square. Anything else throws `MobileScannerException` with
`MobileScannerErrorCode.invalidScanWindow` at mount, which is also what happens if
you pass device pixels by mistake.

### What a scan window is, precisely

A scan window is **a normalized preview-space region of interest used to limit
which detections are reported.** The underlying native mechanism differs by
platform, so exact barcode behaviour at the scan-window boundary is
platform-dependent.

That is the whole contract. In particular this package does **not** promise that a
barcode must be fully contained in the window, and does not promise
pixel-identical boundary semantics across platforms.

**iOS** converts the rectangle with
`AVCaptureVideoPreviewLayer.metadataOutputRectConverted(fromLayerRect:)` and sets
`AVCaptureMetadataOutput.rectOfInterest`, so the native recognition pipeline
itself is constrained to the configured region.

**Android** performs native ML Kit decoding on the analyzed frame and then filters
the decoded barcode geometry against the window. CameraX exposes no
region-of-interest control on `ImageAnalysis`, and cropping every frame would cost
a copy per frame.

That difference has a consequence worth being explicit about, because it affects
how you reason about cost: **on Android the scan window is primarily a
reported-detection region, not a guarantee that ML Kit avoided decoding pixels
outside it.** Do not read it as a native decode crop. On iOS it genuinely does
narrow the native pipeline.

At the boundary, therefore:

| | Behaviour |
|---|---|
| **iOS** | the region constrains native decoding, so a barcode only partly inside it may not be decoded at all |
| **Android** | a decoded barcode whose bounds **intersect** the window may be reported |

Both are correct for their platform. Android deliberately does not discard a
barcode ML Kit already decoded merely to imitate iOS, since that would make
Android less capable without making anything more correct.

### If you need stricter semantics

`Barcode.boundingBox` and `Barcode.cornerPoints` are part of the public API, so an
application that wants a stricter rule can apply it to the returned bounds itself:
full containment, centre-point-inside, or any overlap threshold you prefer. This
package intentionally exposes no option or enum for that choice.

### Geometry

`Barcode.boundingBox` and `Barcode.cornerPoints` use the same normalized preview
space, so drawing a highlight is the rectangle scaled by the widget's own size,
with no rotation or mirroring left to undo. The conversion uses each platform's
own API rather than hand-rolled rotation math: `transformedMetadataObject(for:)`
on iOS, and the preview's centre-crop transform on Android, mirrored for the front
camera.

Values can fall slightly **outside** `0.0` to `1.0`. The preview fills its box by
cropping, so the recognizer sees a little more than is shown, and a barcode in
that margin is reported honestly rather than clamped.

`cornerPoints` follow the symbol's rotation, so they describe a quadrilateral, and
are ordered clockwise from the top left of the symbol as printed, which for a
rotated symbol is not the top left of the preview.

## Permissions

### iOS

The **host application** must declare `NSCameraUsageDescription` in `Info.plist`.
iOS terminates an app that requests camera access without it. This plugin does not
invent privacy copy for your app:

```xml
<key>NSCameraUsageDescription</key>
<string>Explain here why your app scans barcodes.</string>
```

### Android

Nothing to add. This plugin's own manifest declares
`android.permission.CAMERA`, and it requests the permission at runtime through a
headless fragment attached to the current activity.

It declares `android.hardware.camera` with `required="false"`, so your app stays
installable on a device with no camera and reports `cameraUnavailable` instead of
being filtered out of the store listing.

**No storage permission is requested.** Not `READ_EXTERNAL_STORAGE`, not
`WRITE_EXTERNAL_STORAGE`, not `MANAGE_EXTERNAL_STORAGE`. A scanner has no business
with them.

### Both

Refusals are typed, never crashes:

| Situation | Code |
|---|---|
| Refused, can be asked again | `permissionDenied` |
| Refused permanently, or restricted by policy | `permissionPermanentlyDenied` |

`permissionPermanentlyDenied` means only the app's settings page can change it. On
Android it is detected when a request comes back denied while the system also
reports that no rationale may be shown; on iOS it corresponds to
`AVAuthorizationStatus.denied` and `.restricted`, neither of which re-prompts.

## Lifecycle

| Event | Behaviour |
|---|---|
| mounted, `autoStart: true` | starts once the view exists and permission allows |
| mounted, `autoStart: false` | stays `stopped` until `start()` |
| `start()` | opens the camera, clears the explicit-stop flag |
| `stop()` | releases the camera, **marks the scanner explicitly stopped** |
| `pause()` | releases the camera, does **not** mark it explicitly stopped |
| `resume()` | reacquires the camera, clears suppression history |
| app backgrounded | analysis stops and the camera is released, natively |
| app foregrounded | resumes **only** if it was running and was not explicitly stopped |
| widget unmounted | the session is torn down and the camera released |
| another app takes the camera | `cameraInUse`, or a pause if the interruption is transient |

The distinction that matters: "stopped because the app asked" is tracked separately
from "stopped because the app went to the background". Returning to the foreground
never restarts a scanner the application deliberately stopped.

This is handled on the native side. Android drives its own `LifecycleRegistry`
rather than binding CameraX to the activity, because binding to the activity would
rebind the camera on every `ON_START` and resurrect a stopped scanner. iOS observes
`willResignActive` and `didBecomeActive`, plus the session interruption
notifications.

## Supported barcode formats

| Format | Android (ML Kit) | iOS (AVFoundation) | Notes |
|---|---|---|---|
| QR Code | yes | `.qr` | |
| Aztec | yes | `.aztec` | |
| Data Matrix | yes | `.dataMatrix` | |
| PDF417 | yes | `.pdf417` | |
| EAN-13 | yes | `.ean13` | |
| EAN-8 | yes | `.ean8` | |
| UPC-A | yes, native | `.ean13` + translation | see below |
| UPC-E | yes | `.upce` | |
| Code 39 | yes | `.code39`, `.code39Mod43` | mod-43 reported as Code 39 |
| Code 93 | yes | `.code93` | |
| Code 128 | yes | `.code128` | |
| ITF | yes | `.itf14`, `.interleaved2of5` | both reported as ITF |
| Codabar | yes | `.codabar` | **iOS 15.4 or newer only** |

Three differences are real and are not smoothed over:

**UPC-A.** AVFoundation has no UPC-A symbology, because a UPC-A code *is* an
EAN-13 payload with a leading zero. Requesting `upcA` adds `.ean13` to the native
type list, and a 13 digit payload beginning with `0` is reported as `upcA` with
the leading zero stripped, giving the 12 digit value. If `upcA` was not requested,
the same detection is reported as `ean13` with all 13 digits. If both were
requested, `upcA` wins for a payload beginning with `0`. Android reports
`FORMAT_UPC_A` natively and needs no translation.

**Codabar on iOS.** `AVMetadataObject.ObjectType.codabar` arrived in iOS 15.4,
while this plugin's deployment target is iOS 15.0. Between the two, Codabar is
absent from `MobileScanner.supportedFormats` and requesting it fails with
`unsupportedBarcodeFormat`. Raising the whole plugin's floor for one symbology
would have been the worse trade.

**`displayValue` and `rawBytes` are Android only.** ML Kit exposes both;
`AVMetadataMachineReadableCodeObject` exposes neither through public API, so they
are `null` on iOS. They are never synthesized from `rawValue`, because re-encoding
text is not the same as the bytes the symbol carried.

### Multiple barcodes

One `BarcodeCapture` carries every barcode accepted from one frame, so a frame
with three symbols produces one callback with three entries. Ordering is whatever
the platform recognizer reported: neither ML Kit nor AVFoundation documents an
order, and it is not stable across frames. Match on `rawValue` or geometry rather
than index.

## Performance

The architectural decision that matters is that recognition never leaves native
code:

```text
Android                              iOS
CameraX Preview   -> PreviewView     AVCaptureSession
CameraX ImageAnalysis                  + AVCaptureDeviceInput
  STRATEGY_KEEP_ONLY_LATEST            + AVCaptureVideoPreviewLayer
  InputImage.fromMediaImage            + AVCaptureMetadataOutput
  ML Kit BarcodeScanner                     rectOfInterest = scan window
  filter formats + scan window              metadataObjectTypes = formats
       |                                         |
       v                                         v
  normalized JSON                          normalized JSON
       |                                         |
       +----------------> Dart <-----------------+
```

- **No frame crosses the boundary.** A 1080p frame is megabytes; a detection is a
  couple of hundred bytes.
- **No unbounded frame queue.** `STRATEGY_KEEP_ONLY_LATEST` means CameraX delivers
  the next frame only after the current `ImageProxy` is closed and drops whatever
  arrived meanwhile. That bounds the pipeline to exactly one analysis in flight
  with no queue and no busy flag: the close **is** the backpressure signal. Every
  path out of the analyzer closes the proxy exactly once, including the path where
  `process()` itself throws, because a leaked `ImageProxy` stalls CameraX
  permanently rather than merely slowing it.
- **No bitmap or JPEG round trip.** The `android.media.Image` goes straight to
  `InputImage.fromMediaImage` with the rotation, which is also why no rotation math
  appears downstream.
- **Analysis runs at a scanning-appropriate resolution**, targeting 1280x720 with a
  fallback rule rather than a hardcoded device-specific size. High enough to read a
  dense symbol across the frame, low enough that nothing burns power producing
  pixels no one looks at.
- **Your callback cannot stall the camera.** Android analyses on its own executor
  and drops stale frames; AVFoundation delivers metadata on its own queue. A slow
  `onDetect` freezes the interface, which is your code's problem, but the capture
  pipeline keeps running.
- **No camera image is returned.** A `returnImage` style option is deliberately
  absent from 0.1.0: it would add a copy, memory pressure and latency to the common
  path for a feature most scanners never use.

## Privacy

Scope matters here, so this is split into what **this plugin** does and what the
**ML Kit SDK** it links on Android may do. Conflating the two would be a claim this
package is in no position to make.

This plugin:

- adds no analytics, telemetry or tracking of its own, and contains no advertising
  SDK;
- makes no network calls of its own;
- never writes a camera frame to disk, and never passes one into Dart;
- does not log barcode values in release builds.

Barcode recognition:

- runs **on the device**, through the platform recognizer;
- on Android uses a model **bundled into the application**, so there is no
  first-run model download and recognition works offline and without Google Play
  services.

Google's ML Kit SDK, on Android:

- is a Google SDK operating under Google's own terms. It may collect and transmit
  diagnostics, device and application information, and performance or utilisation
  metrics, and may contact Google services, as described in Google's current terms
  and privacy documentation.
- **Choosing the bundled model does not remove ML Kit's own telemetry.** Bundling
  governs where the *model* comes from, not what the SDK reports.

If you ship an Android app with this plugin, review Google's current data
disclosure requirements and reflect them in your own privacy policy and in your
**Google Play Data Safety** declaration. This plugin cannot make that declaration
on your behalf, and nothing here is legal advice.

On iOS there is no third-party SDK at all: recognition is AVFoundation, a system
framework.

Treat barcode contents as untrusted input. This plugin reports what it read and
does nothing else: it will not open a URL, join a Wi-Fi network, launch another
app, or navigate anywhere. What a scanned value means, and whether to act on it, is
your application's decision. Do not infer a payload's type from its text alone.

## Error handling

```dart
try {
  await controller.setZoomScale(8.0);
} on MobileScannerException catch (e) {
  switch (e.code) {
    case MobileScannerErrorCode.invalidZoomScale:
      // Outside the range this device reports.
    case MobileScannerErrorCode.torchUnavailable:
      // The front camera usually has no torch.
    default:
      print('${e.code.name}: ${e.message}');
  }
}
```

Failures that arise inside the camera pipeline have no call to throw from, so they
arrive through `onError` and stay readable as `controller.error`:

```dart
MobileScanner(
  controller: controller,
  onDetect: _onDetect,
  onError: (error) {
    if (error.code == MobileScannerErrorCode.permissionPermanentlyDenied) {
      // Send the user to the app's settings page.
    }
  },
)
```

Every code: `permissionDenied`, `permissionPermanentlyDenied`,
`cameraUnavailable`, `cameraInUse`, `unsupportedCamera`,
`unsupportedBarcodeFormat`, `torchUnavailable`, `invalidScanWindow`,
`invalidZoomScale`, `initializationFailed`, `startFailed`, `stopFailed`,
`analyzerFailed`, `controllerDisposed`, `nativeFailure`.
`MobileScannerException.nativeCode` carries the platform's own identifier when
there is one. A code from a newer native build degrades to `nativeFailure` rather
than being dropped, because something did fail.

## Multiple scanner instances

A device camera cannot be owned by two live sessions, so the behaviour is explicit
rather than a race: **one scanner owns the camera at a time.** Mounting a second
`MobileScanner` while one is running fails that second scanner with
`cameraInUse`. The claim is released when the first scanner stops, is paused, is
unmounted, or errors, after which the second can `start()` again.

Do not run this alongside another package's camera session, including
`dartnative_camera`. Nothing arbitrates between two plugins, so they would contend
for the device.

## Platform requirements

| | Minimum | Why |
|---|---|---|
| iOS | **15.0** | the minimum the DartNative tool declares for every app. Codabar additionally needs 15.4 at runtime |
| Android | **API 24** (7.0) | the floor the framework's own AAR declares. CameraX and ML Kit both support 21 |
| `compileSdk` | 35 | |
| NDK | r28+ | 16 KB page alignment, which Google Play requires for Android 15 and later |
| Dart SDK | `^3.9.0-0` | |

### Android application size

The bundled ML Kit barcode model is compiled into the app rather than downloaded
through Google Play services. The alternative,
`com.google.android.gms:play-services-mlkit-barcode-scanning`, keeps the model out
of the APK but requires Google Play services to be present and downloads the model
on first use.

Bundled was chosen because a scanner's primary feature has to work on the **first
scan, offline, on a device with no Google Play services**. A scanner that cannot
scan until it has been online once is not a scanner. The cost is a larger
application; `dn build apk --analyze-size` will show it for your app, since the
contribution depends on which ABIs you ship.

## Does this use `dartnative_camera`?

**No**, and the reason is architectural rather than a judgement about that package.

`dartnative_camera` is a camera plugin, and a good one: preview, capture,
recording, torch, zoom, and a frame stream. What it does not expose, on either
platform, is a hook for running recognition **natively**. Its complete FFI surface
has no analyzer registration, no access to the live `AVCaptureSession`, and no way
to bind a use case built inside another plugin's binary. Its only
scanner-shaped extension point is `startImageStream()`, which hands frames to
Dart.

Building on that would mean camera to Dart to native to ML Kit, with a full-frame
copy in each direction, on the thread that also draws the interface. So this plugin
owns one capture session of its own instead, which also keeps camera ownership
explicit and keeps the single-session rule enforceable.

The full investigation, including the exact symbols inspected, is in
[`doc/camera-architecture-decision.md`](doc/camera-architecture-decision.md).

## Limitations

Known and deliberate for 0.1.0:

- **Both platforms are hardware-validated**, on an iPhone 15 Pro Max (iOS 26.6)
  and a Galaxy S23 Ultra (Android 16, API 36): all thirteen formats, the
  controller and lifecycle matrix, camera controls, the scan window in portrait
  and landscape and on the front camera, duplicate suppression, multi-barcode
  frames, permission grant and both denial paths, background and foreground
  behaviour, a hot restart under load, and soaks of 295 and 311 operation cycles
  with no errors. Android additionally ran generation isolation across 16 camera
  switches and a sustained `ImageAnalysis` load of 15,403 analyzed frames with no
  image-pool exhaustion. Results per row are in
  [`doc/manual-test-matrix.md`](doc/manual-test-matrix.md).
- **One row is Android-only.** The one-scanner-at-a-time rule is enforced by the
  same process-wide claim on both platforms but was hardware-verified on Android
  alone.
- **Sustained throughput is thermally limited, not leak-limited.** Ten minutes of
  continuous recognition on the Galaxy heated the SoC enough for Android to report
  moderate throttling, and throughput fell from about 30 to about 14 detections a
  second. Heap stayed flat and no image-pool errors appeared, and cooling the
  device reversed the throttling. Expect the same on any phone: continuous
  scanning is a sustained load.
- `displayValue` and `rawBytes` are Android only.
- Codabar needs iOS 15.4.
- Scanning an existing image, `analyzeImage(path)`, is not implemented. The
  architecture leaves room for it: both platforms can recognize a still image.
- No camera frame or image is returned with a detection.
- Tap-to-focus is not exposed. Continuous autofocus is configured, with near-range
  restriction where the device supports it, which matters more for scanning.
- No structured barcode values (Wi-Fi, contact, calendar, geo). ML Kit models
  these; AVFoundation does not, so a cross-platform shape would be half empty.
  `rawValue` carries the payload and the parsing is yours.
- One scanner at a time, process-wide.
- iOS and Android only. No web, macOS, Windows or Linux.
- Barcode ordering within a capture is not stable.
- `BarcodeCapture.imageSize` reports the analyzed resolution and is informational;
  geometry is in preview space, not image space.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

### Third-party terms, including one that is not open source

AndroidX and CameraX are Apache 2.0. **Google ML Kit is not.** The POM for
`com.google.mlkit:barcode-scanning` declares its licence as the
[ML Kit Terms of Service](https://developers.google.com/ml-kit/terms), not an
open-source licence, and the barcode model is compiled into your application.

Android barcode recognition therefore uses Google's ML Kit Barcode Scanning SDK
and is subject to the applicable ML Kit and Google API terms. Application
developers and distributors are responsible for reviewing and complying with those
terms for their own use and distribution. This plugin's MIT licence covers this
plugin's own code only and conveys no rights to ML Kit. Nothing here is legal
advice.

Full notices are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). The iOS side links
only Apple system frameworks and has no third-party dependency.
