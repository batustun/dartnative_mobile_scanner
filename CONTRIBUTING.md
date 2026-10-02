# Contributing

Thanks for considering a contribution. This is a native plugin on three language
boundaries, so the setup matters more than usual.

## What you need

| | |
|---|---|
| DartNative SDK | `dn` 1.0.0 stable or newer, on your `PATH` |
| Dart | the SDK's own, at `<sdk>/bin/dart`. There is no `dn format` |
| Android | SDK 35, NDK r28 or newer, CMake 3.22.1 or newer, JDK 17 |
| iOS | macOS with Xcode 16 or newer, CocoaPods |
| Devices | a real iPhone and a real Android phone. A simulator has no camera |

Use `dn pub get`, `dn analyze` and `dn test`, never the plain `dart` or `flutter`
equivalents: DartNative packages resolve from the installed SDK, not from pub.dev,
so `dart pub get` fails on this package by design.

## Running the checks

```sh
tool/check.sh          # format, analyze, Dart tests, Kotlin tests, both native builds
tool/prepublish.sh     # the above, plus example builds and the release audit
```

Both stop at the first failure. `dn analyze` treats infos and warnings as fatal,
which is deliberate: a lint that an IDE shows in grey still fails the gate here.

Anything that cannot be automated is labelled `MANUAL CHECK` in the script output
rather than quietly skipped.

## Running the example

```sh
cd example
dn pub get
dn run
```

Note that the framework's licence check only runs official DartNative demos, so
running this example needs a DartNative subscription. The build itself works
without one.

## Tests

- **Dart**, in `test/`, run with `dn test`. This is where the logic that can be
  tested without a camera lives: format mapping, duplicate suppression and
  throttling, scan-window validation, payload decoding, controller state
  transitions and disposal.
- **Kotlin**, in `android/src/test/kotlin/`, run by `tool/check.sh`. This covers
  the centre-crop geometry transform, which is the only coordinate math done by
  hand, and the format mask.

New behaviour needs a test when it can have one. Please do not add tests that only
raise a coverage number.

Two rules that have earned their place:

- A test asserting duplicate-suppression timing must account for **every probe
  being an observation**. Feeding the gate inside the cooldown renews it, so you
  cannot poll a barcode back into eligibility.
- Geometry assertions should state a property (the image centre maps to the view
  centre, mirroring is its own inverse) rather than a magic number.

## Code style

- `dart format` with the default line length, via the SDK's own Dart.
- Every public member carries a doc comment; `public_member_api_docs` is on.
- Document platform differences where they exist. A field that only one platform
  can fill should say so in its own doc comment, not only in the README.
- Comments explain **why**. The surrounding code already says what.

## Touching the native sides

The wire protocol is defined in `lib/src/native/scanner_protocol.dart` and
mirrored in `ios/Classes/DNScannerBridge.swift` and
`android/.../DNMobileScannerBridge.kt`. Changing a tag, an event id or a payload
key means changing all three in the same commit.

Three native rules not to rediscover the hard way:

- **Every path out of the Android analyzer must close its `ImageProxy` exactly
  once**, including the path where `process()` throws. A leak stalls CameraX
  permanently.
- **The `PreviewView` is parented once, in the constructor.** Re-parenting a
  hardware-accelerated surface later makes it render black on Android while iOS
  looks fine.
- **Never cache the dispatcher address.** Read the slot fresh before every fire
  and check the isolate generation, or a hot restart aborts the app.

After any native change, verify a hot restart: start a scan, press capital `R`
mid-scan, and confirm the app survives and the scanner works again.

## Pull requests

- One topic per pull request.
- `tool/check.sh` passes.
- The CHANGELOG has an entry under the unreleased version.
- Say which devices and OS versions you tested on, and which parts of
  `doc/manual-test-matrix.md` you ran. "Not tested on hardware" is an acceptable
  answer; an untested claim is not.
