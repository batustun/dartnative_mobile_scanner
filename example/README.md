# mobile_scanner_example

The validation harness for
[`mobile_scanner`](https://github.com/batustun/dartnative_mobile_scanner).

Deliberately plain. It is not a design showcase; every control exists to exercise
one documented capability of the plugin on real hardware, which is why it sits
next to `doc/manual-test-matrix.md` in the parent repository.

## Run it

```sh
dn pub get
dn run -d <device-id>
```

DartNative apps require a licence, including this one. Subscribe at
[dartpub.dev/framework](https://dartpub.dev/framework), then configure the key
once:

```sh
dn config --license-key dnk_...
```

Or pass it per run, without storing it:

```sh
dn run --dart-define=DN_LICENSE_KEY=dnk_...
```

Without a licence the app builds but terminates at launch with
`License check failed`, because the free demo licence only runs official
DartNative demos. That is a framework behaviour, not a plugin failure.

Always use `dn` for run, build and pub commands, never the underlying SDK CLI.

## Use a real device

A camera is required, so:

- the **iOS simulator has no camera at all**, and the scanner correctly reports
  `cameraUnavailable` there;
- the **Android emulator** has a virtual scene that is usable for a first smoke
  test, but it is not a real sensor and proves little about focus, low light or
  rolling shutter.

## What each control does

| Control | Exercises |
|---|---|
| Format segments | format filtering pushed into the native recognizer, changed on a live session |
| Start / Stop | lifecycle, and the explicit-stop rule that survives backgrounding |
| Pause / Resume | releasing and reacquiring the camera without tearing the scanner down |
| Torch | torch control, and honest reporting when the camera has none |
| Flip camera | switching lenses with no overlapping sessions, and mirrored geometry |
| Window on / off | the scan window, in normalized preview coordinates |
| 1x / 2x | zoom, validated against the range the device reports |
| Status lines | `state`, `facingInUse`, `torchState`, `zoomScale` and the delivered count |
| Error panel | typed `MobileScannerErrorCode` plus the platform's own code |
| Result list | format, `rawValue` (possibly null), normalized geometry, `rawBytes` |

The scanner runs in `DetectionSpeed.noDuplicates`, so holding one barcode in frame
produces exactly one entry. The delivered count makes that visible: if it climbs
while a single barcode sits still, duplicate suppression is broken.

## Things worth watching

- Hold a barcode still for 30 seconds. The count should increment once.
- Move it out of frame and back after two seconds. It should be reported again.
- Toggle the window on and aim a barcode outside the band. It should stop
  scanning, in portrait **and** landscape, and on the front camera.
- Press capital `R` while scanning. The app must not abort.

The full checklist is `doc/manual-test-matrix.md` in the parent repository.
