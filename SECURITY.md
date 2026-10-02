# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

Use GitHub's private vulnerability reporting on this repository:
**Security > Report a vulnerability**.

Private vulnerability reporting is enabled on this repository. No private
security contact address is published here on purpose: inventing one would be
worse than naming none. If the GitHub form is not available to you, open a
public issue asking for a private channel, without including any details of the
vulnerability itself.

Please include the plugin version, the platform and OS version, and the smallest
reproduction you can manage. You can expect an acknowledgement; this is a
community plugin maintained in spare time, so please do not expect a same-day fix.

## Scope

In scope: anything in this repository, including the Dart API, the Swift and
Kotlin implementations, the JNI layer, and the build configuration.

Out of scope, and better reported upstream:

- Google ML Kit barcode scanning
- AndroidX CameraX
- AVFoundation and iOS
- the DartNative framework itself (report at `DartNative/dartnative`)

## What this plugin does and does not do

Relevant when assessing impact:

- **This plugin** makes no network calls of its own and adds no analytics,
  telemetry or upload path of its own.
- Camera frames are processed on the device by the platform recognizer. This plugin
  writes no frame to disk and passes no frame into Dart.
- On Android, recognition is performed by Google's ML Kit SDK, which operates under
  Google's own terms and may report diagnostics and device or application
  information to Google. That behaviour is Google's, not this plugin's, and is not
  something this plugin can assert about or suppress. See the README's Privacy
  section.
- It **never acts on a scanned value**. It will not open a URL, join a Wi-Fi
  network, launch another app or navigate anywhere. It reports what it read.
- Barcode values are not written to the log in release builds.

## A note on barcode contents

A barcode is untrusted input from whoever printed it. A QR code can carry a URL, a
payment string, a Wi-Fi credential, a deep link or a shell-shaped string, and the
symbology tells you nothing about which. Validate `rawValue` before using it, and
do not infer the payload's type from its text.

This boundary is intentional: the plugin reports, your application decides.
