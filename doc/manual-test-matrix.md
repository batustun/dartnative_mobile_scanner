# Manual device test matrix

**Status: iOS EXECUTED and passing. Android EXECUTED and passing.**

Recorded 2026-10-02 and 2026-10-03 against:

| | |
|---|---|
| iOS | iPhone 15 Pro Max, iOS 26.6 |
| Android | Samsung SM-S918B (Galaxy S23 Ultra), Android 16, API 36, arm64 |

Evidence was produced from builds made out of hashed source trees, so results are
tied to specific binaries rather than inferred from chronology. Final clean-source
digest `62f0fa2f`.

### Results

| Area | iOS | Android |
|---|---|---|
| Environment, native init | pass | pass (CameraX bound, ML Kit TFLite + barhopper loaded) |
| Controller, lifecycle, B0 command delivery | 29/29 | 29/29 |
| Camera controls, torch, zoom | pass | pass |
| All 13 barcode formats | 13/13 | 13/13 |
| Multi-barcode in one capture | pass | pass |
| Duplicate suppression | pass | pass |
| Scan window, portrait rear | pass | pass |
| Scan window, portrait front | pass | pass |
| Scan window, landscape | pass | pass (front camera) |
| Permission grant / denial / permanent denial | 3/3 | 3/3 |
| Background and foreground invariants | 3/3 | 3/3 |
| Generation isolation | n/a, see note | pass, 16 switches, 0 stale frames |
| Sustained ImageAnalysis load | n/a | pass, 15403 frames, 0 pool errors |
| Hot restart with detections in flight | pass | pass, after a JNI fix |
| Repeated mount / dispose | pass | pass, 12 cycles, camera released each time |
| Second scanner, cameraInUse | not run, see note | pass, only 1 camera client ever active |
| Soak | 295 cycles, 0 errors | 311 cycles, 0 errors |

Notes. Generation isolation and sustained load are Android-specific: they exercise
the CameraX `ImageAnalysis` path, which has no iOS counterpart, since iOS receives
recognised metadata rather than frames. The second-scanner row was exercised on
Android only; the claim is enforced by the same process-wide token on both
platforms, but it is **hardware-verified on Android alone**.

### Defects found during physical validation

| # | Layer | Defect | Status |
|---|---|---|---|
| 1 | Dart element | Controller commands rode the reconciler's mutation batch, which only flushes on a frame. On an idle app `pause()` took over 8 seconds. | fixed, `flushMutationsNow` for application-issued commands; measured 26-32 ms after |
| 2 | JNI, Android only | `dlsym(RTLD_DEFAULT, "DN_IsolateGen")` silently fails under Android's linker namespaces, so hot-restart protection was absent and the app aborted with `Callback invoked after it has been deleted`. | fixed, explicit `dlopen` of `libdartnative_android.so` plus a loud warning if unresolvable |
| 3 | Shared Dart controller | A hard `< 1.0` zoom floor made the advertised `minZoomScale` unreachable; the Galaxy reports 0.60. | fixed, 4 regression tests including an iOS-equivalence test |
| 4 | Documentation | Claimed an edge-straddling barcode scans on both platforms. False on iOS. | corrected, asymmetry documented |
| 5 | Example, both platforms | Landscape preview height computed from screen width, pushing the scan band off screen. Made the landscape row unperformable and caused an iOS retraction. | fixed, box now fits both orientations |

Defect 2 is the one that justified Android validation on its own: a guaranteed
debug-session abort on every Android hot restart, originating in a documentation
snippet, and invisible to any amount of iOS testing because iOS uses a different
mechanism entirely.

Run it with `example/`, which exposes every control this matrix needs. A simulator
or emulator is not a substitute for the camera cases: the iOS simulator has no
camera at all, and the Android emulator's virtual scene is useful for a first
smoke test but is not a real sensor.

Record for each run: device, OS version, plugin version, and anything that failed.

## Printed samples you need

One sheet with all of these, each large enough to fill roughly a third of the
frame at 20 cm:

QR Code, EAN-13, EAN-8, UPC-A, UPC-E, Code 39, Code 93, Code 128, ITF, Codabar,
Data Matrix, PDF417, Aztec.

Plus: one sheet with **two different barcodes side by side**, one with a
**deliberately damaged** QR code (a corner torn or inked over), and one with a
**very small** QR code, about 8 mm across.

## A. Permissions

| # | Check | Expected |
|---|---|---|
| A1 | First launch, tap Allow | preview appears, state becomes `running` |
| A2 | Fresh install, tap Deny | no crash, error panel shows `permissionDenied` |
| A3 | After A2, press Start again | prompt appears again, or `permissionDenied` on iOS |
| A4 | Deny twice on Android | error becomes `permissionPermanentlyDenied` |
| A5 | iOS: Deny, then relaunch and Start | `permissionPermanentlyDenied`, no second prompt |
| A6 | Grant in Settings, return to the app, Start | scanner runs |
| A7 | Revoke in Settings while running | no crash; a typed error or a stopped scanner |
| A8 | iOS only: temporarily remove `NSCameraUsageDescription` | the OS terminates the app on camera use. This is the documented host-app requirement, not a plugin bug |

## B. Lifecycle

| # | Check | Expected |
|---|---|---|
| B1 | Start | `running`, preview live |
| B2 | Stop | preview stops, camera released (the torch goes out) |
| B3 | Start after Stop | runs again; the barcode still in frame is reported again |
| B4 | Pause | analysis stops, no detections |
| B5 | Resume after Pause | runs; the visible barcode is reported again |
| B6 | Pause, then background and foreground | **stays paused**, does not self-resume |
| B7 | Stop, then background and foreground | **stays stopped**. This is the explicit-stop rule |
| B8 | Running, then background | analysis stops, camera released, another app can use it |
| B9 | Running, background, foreground | resumes by itself |
| B10 | Background during an active detection | no crash, no late callback |
| B11 | Navigate away from the scanner screen | camera released |
| B12 | Navigate back | scanner works again |
| B13 | Mount, unmount and remount ten times | no leak, still works, no growing memory |
| B14 | Start twice in a row | one session, no error |
| B15 | Stop twice in a row | no error |
| B16 | Start while already `starting` | ignored, one session |
| B17 | Android: rotate with the activity recreated | scanner recovers |
| B18 | Press capital `R` (hot restart) mid-scan | **no abort**, scanner works afterwards. This is the dispatcher-slot guarantee |

### B0. Command delivery with the application idle (regression contract)

A controller command travels as a `PluginMutation` through the reconciler's
mutation batch. That batch is flushed when a frame is scheduled, so on an idle
application, with nothing animating and no rebuild pending, **nothing would flush
it**. A regression here is invisible in unit tests, because they inject a command
sink directly and never exercise `emitMutation`.

The contract is **not** a millisecond figure. It is:

> An application-issued controller command must reach the native side without
> waiting for an unrelated future UI frame.

Test it with the interface completely idle: no scrolling, no animation, no taps
other than the one under test, and ideally driven programmatically rather than by
a tap, since a tap itself causes a rebuild and would mask the fault.

| # | Check | Expected |
|---|---|---|
| B0a | `stop()` with the app idle | the camera is released, and the preview stops, **well inside 2 seconds** |
| B0b | `pause()` with the app idle | state reaches `paused` well inside 2 seconds |
| B0c | `resume()` with the app idle | state reaches `running` well inside 2 seconds |
| B0d | `toggleTorch()` with the app idle | the torch responds well inside 2 seconds |

The 2 second bound is deliberately generous: it exists to catch a multi-second or
never regression, not to pin down device performance. The original defect showed
as **more than 8 seconds, and in practice never**, until something unrelated
triggered a frame.

Recorded 2026-10-02, iPhone 15 Pro Max / iOS 26.6, driven programmatically with
the UI idle: pause 32 ms, resume 207 ms, stop 216 ms, start 216 ms, torch ~22 ms.
Pre-fix, the same measurement on the same device was **over 8000 ms**.

### B. The four lifecycle invariants, stated as assertions

These are the contract the private Android `LifecycleRegistry` and the iOS
notification observers exist to provide. Run each on both platforms and record a
pass or fail against the exact transition, not a general impression.

| # | Transition | Required end state |
|---|---|---|
| BI1 | `start()` → background → foreground | **running** |
| BI2 | `pause()` → background → foreground | **still paused**, never resumed |
| BI3 | `stop()` → background → foreground | **still stopped**, never resurrected |
| BI4 | dispose (unmount) → foreground lifecycle callback | **nothing resurrected**, no event emitted |
| BI5 | Android: background immediately after mount, before the first frame | camera released. Exercises the lifecycle observer attaching late, when no activity was resolvable at construction |

BI2 and BI3 are the ones a regression would break: both depend on the explicit-stop
flag surviving a host lifecycle callback.

## C. Camera selection

| # | Check | Expected |
|---|---|---|
| C1 | Back camera | scans |
| C2 | Flip to front | scans; geometry is mirrored correctly, not inverted |
| C3 | Flip back | scans |
| C4 | Flip ten times quickly | no crash, no overlapping sessions, still scans |
| C5 | Flip during an active detection | no crash, **and no result from the old camera appears after the flip** |
| C8 | Flip while a barcode is in frame, watch the first front-camera result | geometry mirrored correctly on the **first** frame, not only later ones |
| C6 | Device with no front camera, request front | `unsupportedCamera`; the previous session is **released**: preview stops and the torch goes out |
| C9 | iOS **debug** build, force a camera-open failure (request a camera the device lacks) | the typed error arrives with **no assertion crash** |
| C7 | Front camera, toggle torch | `torchUnavailable` thrown, or torch reported `unavailable` |

## D. Torch

| # | Check | Expected |
|---|---|---|
| D1 | Back camera, toggle on | light on, state `on` |
| D2 | Toggle off | light off, state `off` |
| D3 | Stop while the torch is on | light goes out |
| D4 | Torch on, flip to front | torch state becomes `unavailable` |
| D5 | Torch on, background and foreground | state matches reality, not a stale value |

## E. Zoom

| # | Check | Expected |
|---|---|---|
| E1 | `maxZoomScale` after the camera opens | a real device value, not 1.0 |
| E2 | Set 2x | preview zooms, `zoomScale` reports 2.0 |
| E3 | Set beyond max | `invalidZoomScale` thrown |
| E4 | Set below 1.0 | `invalidZoomScale` thrown |
| E5 | Zoom, then flip camera | no crash; the range is re-reported for the new camera |
| E6 | Scan a small barcode at 2x | easier than at 1x |

## F. Orientation

Run F1 to F4 in **both** camera facings.

| # | Check | Expected |
|---|---|---|
| F1 | Portrait | scans; `boundingBox` sits over the barcode when drawn |
| F2 | Landscape left | scans; geometry still correct |
| F3 | Landscape right | scans; geometry still correct |
| F4 | Rotate while scanning | no crash, preview reorients, geometry stays correct |
| F5 | Upside down, if the app allows it | scans |

The geometry check is the point of F1 to F4. Draw `boundingBox` scaled by the
widget's size and confirm it lands on the barcode rather than offset or rotated.

## G. Formats

For each of the thirteen symbologies: scan it with the preset `Everything`, and
confirm the reported `format` is correct.

| # | Check | Expected |
|---|---|---|
| G1 | Each of the thirteen, preset `Everything` | recognized, correct format |
| G2 | Preset `QR only`, scan a QR | recognized |
| G3 | Preset `QR only`, scan EAN-13 | **not** recognized |
| G4 | Preset `EAN 13 + EAN 8`, both | recognized |
| G5 | Preset `EAN 13 + EAN 8`, scan QR | **not** recognized |
| G6 | Switch presets on a live session | takes effect without restarting the app |
| G7 | Scan a UPC-A sheet | reported as `upcA` with **12** digits, not 13 |
| G8 | iOS below 15.4, request Codabar | absent from `supportedFormats`, `unsupportedBarcodeFormat` on start |
| G9 | iOS 15.4 or newer, Codabar | recognized |
| G10 | Compare one EAN-13 value across iOS and Android | identical string |
| G11 | A binary-payload QR code | `rawValue` may be null; no crash, no empty-string substitute |
| G12 | Android, any barcode | `rawBytes` present; on iOS it is null |

## H. Detection behaviour

| # | Check | Expected |
|---|---|---|
| H1 | Hold one QR still for 30 s, `noDuplicates` | **exactly one** callback |
| H2 | Move it out of frame, wait 2 s, return | reported again |
| H3 | Move it out and back within 0.5 s | **not** reported again |
| H4 | Two different barcodes in frame | one callback, two entries |
| H5 | Two barcodes, one already seen, `noDuplicates` | one callback containing only the new one |
| H6 | Two different symbologies at once | both reported with correct formats |
| H7 | `normal` mode, hold one barcode | about four callbacks a second |
| H8 | `unrestricted`, hold one barcode | many callbacks a second |
| H9 | Barcode at the extreme frame edge | recognized, or honestly not; geometry not nonsense |
| H10 | Very small barcode, about 8 mm | recognized when close |
| H11 | Large barcode filling the frame | recognized |
| H12 | Low light | recognized with the torch on |
| H13 | Barcode at 45 degrees | recognized; `cornerPoints` follow the rotation |
| H14 | Damaged barcode | recognized if the error correction allows, else nothing. No crash |
| H15 | Sweep the camera quickly past a barcode | no crash, no stuck preview |
| H16 | Nothing in frame for a minute | no callbacks, no error |

## I. Scan window

The contract being tested is: *a normalized preview-space region of interest used
to limit which detections are reported, whose boundary behaviour is
platform-dependent.* Record iOS and Android **separately**. A difference at the
boundary is a **PASS** when it matches the documented platform contract; it is not
a failure.

Draw the window while testing. The example renders the normalized rect as an
outline, so the outline and the region that actually scans can be compared
directly. Without it the test is not performable, because there is no way to know
where the band is.

| # | Position relative to the window | iOS expected | Android expected |
|---|---|---|---|
| I1 | **Fully inside** | recognized | recognized |
| I2 | **Fully outside** | **not** recognized | **not** recognized |
| I3 | **Touching the boundary** (edge-adjacent, not overlapping) | not recognized | not recognized |
| I4 | **Partially overlapping the boundary** | **may not be recognized**: `rectOfInterest` constrains native decoding, so a partly covered symbol may not decode at all | **may be recognized**: ML Kit decoded the frame and the result is kept when bounds intersect the window |

Record the observed result for each, per platform:

| # | iOS 26.6 (iPhone 15 Pro Max) | Android 16 (Galaxy S23 Ultra) |
|---|---|---|
| I1 | **PASS** recognized | **PASS** recognized |
| I2 | **PASS** not recognized | **PASS** not recognized |
| I3 | **PASS** not recognized | **PASS** not recognized |
| I4 | **PASS** not recognized, matching the documented iOS contract | **PASS** recognized, matching the documented Android contract |

Android I4 evidence: across portrait-rear, portrait-front and landscape-front, 12
reported detections were all partial overlaps of the band and **zero**
non-intersecting detections were ever reported. Three clipped an edge by under
0.02 normalized units and were still reported, which is the contract
`decoded + intersects -> must not be discarded`. No case arose where ML Kit failed
to decode a partially covered symbol, so that distinction was not needed.

Then the transform cases, which are where a coordinate bug actually hides:

| # | Check | Expected |
|---|---|---|
| I5 | Toggle the window on a live session | takes effect immediately |
| I6 | Repeat I1 and I2 in **landscape** | same results |
| I7 | Repeat I1 and I2 on the **front camera** | same results, mirroring accounted for |
| I8 | Window on, then flip camera | window still correct |
| I9 | Does the drawn outline still match the scanning region after rotating and after flipping? | yes; a drift means the Dart overlay and the native region disagree |

I6 and I7 are the cases most likely to expose a coordinate bug, because landscape
changes the preview transform and the front camera adds mirroring. Do not skip
them.

iOS results recorded 2026-10-02 on iPhone 15 Pro Max / iOS 26.6: I1, I2, I3, I4,
I6, I7 all matched the documented contract. Measured `rectOfInterest` for a band
of `(0.10, 0.35, 0.80, 0.30)` on a 430x573 preview was
`(0.3875, 0.1000, 0.2250, 0.8000)`, the expected axis swap for portrait, and every
accepted detection had bounds within `0.360`-`0.625`.

## J. Endurance

| # | Check | Expected |
|---|---|---|
| J1 | Scan continuously for 20 minutes | no freeze, no stall, no growing latency |
| J2 | Watch memory over J1 | stable, no upward trend |
| J3 | Device temperature over J1 | warm is fine; thermal throttling should not stall the scanner |
| J4 | Scan 200 different barcodes in a session, `noDuplicates` | memory stable; suppression history is pruned |
| J5 | Start and stop 50 times | still works |
| J6 | Background and foreground 20 times | still works |
| J7 | Flip camera 20 times | still works |

A stall during J1 on Android points at an `ImageProxy` that was not closed. It is
the failure mode to watch for, because it is permanent rather than gradual.

## K. Contention and edge cases

| # | Check | Expected |
|---|---|---|
| K1 | Two `MobileScanner` widgets mounted at once | the second fails with `cameraInUse`, no contention |
| K2 | After K1, unmount the first and Start the second | the second runs |
| K3 | Open the system camera app while scanning | typed `cameraInUse`, or a pause; no crash |
| K4 | Return from the system camera app | scanner recovers |
| K5 | A call arrives while scanning | no crash; session interruption handled |
| K6 | Use a disposed controller | `controllerDisposed` thrown |
| K7 | An invalid scan window | `invalidScanWindow` at mount |
| K8 | Airplane mode | scanning unaffected. Nothing here needs the network |
| K9 | Android device with no Google Play services | scanning works. This is why the model is bundled |

## Android devices to cover

At least two, differing in vendor and API level. Note the camera2 hardware level
if you can; a `LEGACY` device is the one most likely to behave differently.

| Device | API | Result |
|---|---|---|
| | | |
| | | |

## iOS devices to cover

At least one physical iPhone. Include one on iOS 15.x if you can reach it, for the
Codabar boundary at 15.4.

| Device | iOS | Result |
|---|---|---|
| | | |
