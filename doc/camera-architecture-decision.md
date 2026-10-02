# Camera Architecture Decision

Engineering traceability note for `mobile_scanner`. Everything below
was read from the installed SDK and the current public repository, not from
articles or memory.

Verified 2026-10-02 against:

- SDK: `dn` 1.0.0 stable, framework edition `7ae291321d3045cd`, framework
  revision `113c27aacb2` (2026-09-28), engine `868544bccad64b70d0c00cfc5010440dae673b94`,
  Tools Dart 3.12.0
- Repo: `github.com/DartNative/dartnative` @ `main` (shallow clone), docs
  `plugin_development.md`, `plugin_async_callbacks.md`
- Registry: `dartpub.dev` (`/api/plugins`)
- Toolchain: Xcode 26.2, Android SDK 36.0.0, NDK 25.1–28.2, CMake 3.22.1/3.31.4

---

## 1. Package inspected

| | |
|---|---|
| Package | `dartnative_camera` |
| Version | **1.0.0** |
| Path | `~/zero/bin/cache/pkg/dartnative_camera` |
| Distribution | Declaration-only Dart (`lib/**.dart`, every body `throw UnimplementedError()`) plus compiled `dart/{debug,product}/dartnative_camera.dill`. No Swift, Kotlin, C++, podspec, gradle or CMake is distributed. |
| Registry page | `dartpub.dev/api/plugins/dartnative_camera`, owner `DartNative`, publisher `iosephmagno` |

Files read in full:

```
lib/dartnative_camera.dart          lib/src/camera_controller.dart
lib/src/camera_types.dart           lib/src/camera_ffi_bindings.dart
lib/src/camera_preview.dart         lib/src/dartnative_camera.dart
pubspec.yaml   manifest.json   NOTICES   LICENSE
plugins/dartnative_camera/README.md (public repo)
```

No binary was decompiled. The `.dill` files were not inspected; the public Dart
declarations are the package's documented API surface and were sufficient.

---

## 2. Public API found

**Entry point** — `DartNativeCamera.availableCameras()`,
`requestGalleryAddPermission()`, `requestMicrophonePermission()`.

**Controller** — `CameraController(CameraDescription, ResolutionPreset, {enableAudio, videoQuality, videoAspectRatio, videoBitRateBps})` with
`initialize()`, `takePicture()`, `startVideoRecording()`, `stopVideoRecording()`,
`pauseVideoRecording()`, `resumeVideoRecording()`, `setFlashMode()`,
`setZoomLevel()`, `setFocusPoint()`, `setExposurePoint()`,
`setCaptureOrientation()`, `setResolutionPreset()`, `setVideoAspectRatio()`,
`saveToGallery()`, `openGallery()`, `startImageStream()`, `stopImageStream()`,
`previewHandle`, `isInitialized`, `recordingEvents`, `dispose()`.

**Preview** — `CameraPreview({controller, enablePinchToZoom, enableTapToFocus})`,
a `StatefulWidget` whose leaf `NativeElement` hosts
`AVCaptureVideoPreviewLayer` (iOS) / `androidx.camera.view.PreviewView` (Android).

**Facing** — `CameraLensDirection { front(0), back(1), external(2) }`.

**Torch** — only through `FlashMode`, whose `torch(3)` member is documented
"**(iOS only)** Torch, continuous on, used for video / barcode scan. **Ignored
on Android.**"

**Zoom** — `setZoomLevel(double)`, device-specific range, clamped natively.

**Frames** — `startImageStream() -> Future<Stream<CameraImage>>`.
`CameraImage` carries `format`, `width`, `height`, `timestampNs` and
`bytes`, documented as "**First plane's bytes**, Y for YUV, BGRA for iOS"
(`format` 1 = BGRA8888 iOS, 35 = YUV_420_888 Android, *first plane only*).

**Permission** — `CameraFfiBindings.requestCameraPermissions({enableAudio})`;
`initialize()` surfaces `CameraAccessDenied` on Android and a
platform-derived message on iOS.

---

## 3. Native extension points searched for, and what exists

`lib/src/camera_ffi_bindings.dart` is the complete FFI surface, so the absence
of a symbol there is conclusive for the public API.

### Android — what exists

The Android side is a handle-based wrapper over CameraX: native objects live in
the plugin's own instance manager and Dart holds opaque `Int64` handles.

```
providerGetInstance()                      -> ProcessCameraProvider handle
providerGetAvailableCameraInfos(provider)   -> [CameraInfo handles]
selectorCreate(lensFacing)                  -> CameraSelector handle
previewCreate()                             -> Preview use-case handle
imageAnalysisCreate(quality, aspectRatio)   -> ImageAnalysis use-case handle
imageCaptureCreate(flashMode)               -> ImageCapture use-case handle
recorderCreate(...) / videoCaptureWithOutput(recorder)
providerBindToLifecycle(provider, selector, [useCaseIds])
providerUnbindAll(provider)
imageStreamSetEnabled(bool)
set imageFrameListener(ImageFrameListener?)  // process-wide
androidSetZoomRatio / androidSetFocusPoint / androidSetExposurePoint
```

So `ImageAnalysis` **is** exposed, and `providerBindToLifecycle` accepts an
arbitrary list of use-case handles. Three facts stop that being usable:

1. `imageAnalysisCreate` returns an `ImageAnalysis` that already has the
   plugin's **own** analyzer attached, and that analyzer's only destination is
   Dart via `imageFrameListener`. There is no
   `imageAnalysisSetNativeAnalyzer(...)`, no analyzer-registration symbol, and
   no callback that stays native-side.
2. Handles are minted by `dartnative_camera`'s native instance manager, which
   is private to its own binary. A scanner cannot obtain a handle for an
   `ImageAnalysis` it constructs inside its own `.so`, so it cannot hand one to
   `providerBindToLifecycle`.
3. `imageFrameListener` is a **single process-wide** slot. `CameraController`
   documents the consequence: "The controller installs process-wide native
   listeners for recording events and streamed frames, so a second controller
   would take them over from the first."

### iOS — what exists

```
iosCreate() / iosDispose(id) / iosInitialize(id, name, preset, enableAudio)
iosTakePicture / iosStartVideoRecording / iosStopVideoRecording
iosPause|ResumeVideoRecording / iosPause|ResumePreview
iosSetFlashMode / iosSetZoomLevel / iosSetFocusPoint / iosSetExposurePoint
iosLock|UnlockOrientation / iosSetSessionPreset
iosGetPreviewView(id)   -> UIView pointer
iosImageStreamSetEnabled(id, enabled)
iosAvailableCamerasJson
```

No `AVCaptureSession` handle is exposed. There is no symbol that adds an
output to the session, nothing resembling
`iosAddMetadataOutput` / `iosAddVideoDataOutput` /
`iosRegisterSessionOutput` / `iosGetCaptureSession`, and no native delegate
registration. `iosGetPreviewView` hands back the preview `UIView` only.

### Both platforms, summarised

| Capability sought | Android | iOS |
|---|---|---|
| Register a **native** analyzer / session output | **No** | **No** |
| Access the live `AVCaptureSession` | n/a | **No** |
| Attach `AVCaptureMetadataOutput` | n/a | **No** |
| Bind a use case the scanner constructed | **No** (foreign instance manager) | n/a |
| Share `ProcessCameraProvider` / lifecycle | Provider handle yes, but no native analyzer hook | n/a |
| Per-frame bytes **into Dart** | Yes (`imageFrameListener`, Y plane) | Yes (BGRA8888) |
| Reusable preview, torch, zoom, facing, permission | Yes, at the Dart level only | Yes, at the Dart level only |

The only scanner-shaped extension point on either platform is
`startImageStream()`. The public README names that use explicitly: frames are
handed over "for ML, scanning, or your own processing".

---

## 4. Decision

### `dartnative_camera` is **NOT USED**.

Reusing it would force exactly the pipeline the architecture forbids:

```
camera session (dartnative_camera)
        -> native frame
        -> copy into Dart Uint8List
        -> back across FFI into our .so
        -> ML Kit / Vision
        -> result -> Dart
```

Reasons, in order of weight:

1. **No native recognition path exists.** Neither platform exposes an analyzer
   or session-output hook, so recognition could only run after the frame had
   already crossed into Dart. That is a double full-frame copy per frame on the
   UI thread, which is also the Dart thread (`architecture.md`: "Every layer
   runs on the same thread").
2. **The payload is wrong, not merely large.** iOS delivers BGRA8888, roughly
   8 MB per frame at 1080p. Android delivers the **Y plane only**, which is
   neither NV21 nor YV12, so `InputImage.fromByteArray` cannot accept it
   without fabricating a chroma plane. Barcode reading from luminance is
   possible, but only after inventing a buffer layout the upstream API never
   promised to keep stable.
3. **Single-session ownership could not be honoured.** `CameraController`
   supports one live session and installs process-wide listeners. A scanner
   session alongside it would contend for both the device and that listener
   slot, violating the one-session-per-scanner rule.
4. **Torch would be unreachable on Android.** The only torch control is
   `FlashMode.torch`, documented as iOS-only and ignored on Android.
5. **No scan-window path.** `rectOfInterest` is not reachable on iOS, and no
   native ROI or geometry hook exists on Android, so the region of interest
   could only ever be a Dart-side filter over frames that already crossed the
   boundary.

None of this is a defect in `dartnative_camera`. It is a camera plugin, and its
frame stream is a reasonable general-purpose escape hatch. It simply is not a
recognition-pipeline extension point, and a scanner needs one.

### Camera ownership model

`mobile_scanner` owns **exactly one** native capture session per
scanner view, created and destroyed by its own native code.

- One active session process-wide. A second `MobileScanner` mounted while one
  is running fails with a typed `MobileScannerErrorCode.cameraInUse` rather
  than contending for the device.
- The session is created when the scanner view is created and torn down when
  the view is disposed, on the platform main thread.
- Applications must not run a `dartnative_camera` `CameraController` and a
  `MobileScanner` at the same time. This is documented in the README as a
  consumer-visible constraint, since no framework arbitration exists.

### Final pipeline

Android:

```
CameraX ProcessCameraProvider
  ├── Preview            -> androidx.camera.view.PreviewView (hosted native view)
  └── ImageAnalysis      -> STRATEGY_KEEP_ONLY_LATEST
          -> InputImage.fromMediaImage(image, rotationDegrees)
          -> ML Kit BarcodeScanner (bundled, com.google.mlkit:barcode-scanning)
          -> format filter + scan-window filter, native side
          -> normalized JSON  -> dispatcher slot -> Dart
```

iOS:

```
AVCaptureSession
  ├── AVCaptureDeviceInput
  ├── AVCaptureVideoPreviewLayer (hosted native view)
  └── AVCaptureMetadataOutput
          metadataObjectTypes = requested formats only
          rectOfInterest      = scan window
          -> AVMetadataMachineReadableCodeObject
          -> normalized JSON  -> dispatcher slot -> Dart
```

Only normalized detection data crosses into Dart: format, raw value, raw bytes
where the platform supplies them, geometry, timestamp, plus state and error
events. No camera frame is transferred by default.

---

## 5. Dependencies this decision implies

| Dependency | Used | Why |
|---|---|---|
| `dartnative` | yes | Framework. `NativeElement`, `ViewType`, `PluginMutation`, widgets. |
| `ffi` | yes | `Pointer<Utf8>` for the dispatcher payload. |
| `dartnative_camera` | **no** | Section 4. |
| `com.google.mlkit:barcode-scanning` | yes (Android) | Native recognition. Bundled rather than Play-Services-delivered; see README "Platform requirements". |
| `androidx.camera:camera-*` | yes (Android) | `1.6.2`, the current stable line (`1.7.0` is alpha). |
| AVFoundation | yes (iOS) | System framework, no third party. |

---

## 6. Publication constraint, checked rather than assumed

A view plugin compiles against the framework's Android classes
(`DNPluginRegistry`, `DNViewRegistry`, `DNAppContext`) and therefore declares
`compileOnly project(':dartnative_android')`, as `plugin_development.md` §4
Step 1 requires. That document also states:

> `dn plugin build` finds it only inside the DartNative source tree for now, so
> a plugin with this dependency builds and runs inside an app but cannot yet
> produce its own Android archive for publishing.

**That is stale for `dn` 1.0.0 stable.** Verified by building a throwaway plugin
with the same dependency from a directory outside the SDK tree, then by building
this one:

```
dn plugin build
  android : gradle assembleRelease (mobile_scanner, min SDK 24)
  android : mobile_scanner.aar (364970 bytes,
            abis: arm64-v8a, armeabi-v7a, x86, x86_64)
  native  : 3 source file(s), min iOS 15.0
  lipo 2 slices, create-xcframework
  tarball : dist/mobile_scanner-0.1.0.tar.gz
```

The generated harness resolves the module from the package cache explicitly
(`dist/_build_android/settings.gradle`):

```groovy
include(':dartnative_android')
project(':dartnative_android').projectDir =
    new File('<sdk>/bin/cache/pkg/dartnative_android/android')
```

and injects `compileOnly 'io.flutter:flutter_embedding_release:1.0.0-<engine>'`
into every `com.android.library` subproject, which is also how
`FlutterPlugin` resolves without the plugin declaring it.

So the dependency is not a publication blocker. Corroborating datapoint: the
first-party `dartnative_share`, which has no view at all, declares the same
`compileOnly project(':dartnative_android')`.

---

## 7. Validation status

The licence blocker recorded here during development has since been resolved by
the repository owner configuring a DartNative licence locally, and iOS physical
validation was then carried out.

**iOS: validated** on an iPhone 15 Pro Max running iOS 26.6. All thirteen formats,
the controller and lifecycle matrix, camera switching, torch, zoom, the scan window
including landscape and the front camera, duplicate suppression, multi-barcode
frames, a hot restart with detections in flight, and a ten-minute soak. Evidence
was produced from a build made out of a hashed source tree, so it is tied to a
specific binary rather than inferred from chronology.

Two defects were found during that validation, both invisible to the unit tests:

1. Application-issued controller commands rode the reconciler's mutation batch,
   which only flushes on a frame, so on an idle application a command could be
   delayed indefinitely. Measured at over 8 seconds before the fix and 26 to 32 ms
   after it.
2. The documentation claimed that a barcode straddling the scan-window edge is
   reported on both platforms. That is false on iOS, where `rectOfInterest`
   constrains native decoding. The scan-window contract has been reworded, and the
   platform asymmetry is documented rather than removed.

**Android: not validated.** It compiles, its unit tests pass and the example APK
builds, but it has not been run on a physical device. That is the remaining
blocker for a stable release, and `doc/manual-test-matrix.md` carries the
unexecuted rows.
