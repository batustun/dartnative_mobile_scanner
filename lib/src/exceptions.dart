/// Typed scanner failures.
library;

/// Why a scanner operation failed.
///
/// Every failure this plugin reports carries one of these. Nothing throws a bare
/// `Exception`, so callers can branch on the cause instead of matching strings.
enum MobileScannerErrorCode {
  /// The user refused camera access, and may be asked again.
  permissionDenied('permissionDenied'),

  /// The user refused camera access in a way the system will not prompt for
  /// again.
  ///
  /// The only route back is the app's own Settings page. On Android this is
  /// detected after a request that was denied while the system also reports that
  /// no rationale may be shown. On iOS it corresponds to
  /// `AVAuthorizationStatus.denied` or `.restricted`, which never re-prompts.
  permissionPermanentlyDenied('permissionPermanentlyDenied'),

  /// The camera could not be opened, for a reason other than permission.
  ///
  /// A hardware failure, or a device with no usable camera at all.
  cameraUnavailable('cameraUnavailable'),

  /// The camera is already held by something else.
  ///
  /// Another app, or another `MobileScanner` in this app. One scanner owns the
  /// camera at a time; see the README section on multiple scanner instances.
  cameraInUse('cameraInUse'),

  /// The requested [CameraFacing] does not exist on this device.
  ///
  /// A tablet with no front camera, for instance.
  unsupportedCamera('unsupportedCamera'),

  /// A requested [BarcodeFormat] cannot be recognized on this platform or OS
  /// version.
  ///
  /// Check [MobileScanner.supportedFormats] to avoid it.
  unsupportedBarcodeFormat('unsupportedBarcodeFormat'),

  /// The active camera has no torch, so torch control is meaningless.
  ///
  /// Typical of front cameras.
  torchUnavailable('torchUnavailable'),

  /// The scan window was not a valid normalized rectangle.
  ///
  /// See [MobileScanner.scanWindow] for the exact constraints.
  invalidScanWindow('invalidScanWindow'),

  /// The requested zoom was outside the range the device reports.
  invalidZoomScale('invalidZoomScale'),

  /// The native scanner could not be created.
  ///
  /// Includes failure to construct the platform recognizer.
  initializationFailed('initializationFailed'),

  /// Starting the session failed after the camera itself had been acquired.
  startFailed('startFailed'),

  /// Stopping the session failed. The scanner is forced to
  /// [MobileScannerState.stopped] regardless, so this is reported rather than
  /// left pending.
  stopFailed('stopFailed'),

  /// Frame analysis failed repeatedly and analysis was abandoned.
  analyzerFailed('analyzerFailed'),

  /// The controller was used after [MobileScannerController.dispose].
  controllerDisposed('controllerDisposed'),

  /// A native failure that does not fit any other code.
  ///
  /// [MobileScannerException.nativeCode] carries the platform's own identifier
  /// when there is one.
  nativeFailure('nativeFailure');

  const MobileScannerErrorCode(this.wireName);

  /// The stable identifier used in native event payloads.
  final String wireName;

  /// The code whose [wireName] is [name], or [nativeFailure] when the native
  /// side reported a code this Dart version does not know.
  ///
  /// Falling back rather than returning `null` keeps a newer native build from
  /// turning an ordinary error into a dropped event.
  static MobileScannerErrorCode fromWireName(String name) {
    for (final code in values) {
      if (code.wireName == name) return code;
    }
    return MobileScannerErrorCode.nativeFailure;
  }
}

/// A scanner failure.
///
/// Thrown by [MobileScannerController] methods, and also delivered to
/// [MobileScanner.onError] and exposed as [MobileScannerController.error] for
/// failures that arise asynchronously inside the camera pipeline, where there is
/// no call to throw from.
final class MobileScannerException implements Exception {
  /// Creates a scanner exception.
  const MobileScannerException(this.code, this.message, {this.nativeCode});

  /// What went wrong, as a value you can branch on.
  final MobileScannerErrorCode code;

  /// A human-readable explanation, for logs and developer-facing surfaces.
  ///
  /// Not localized, and not intended to be shown to end users as-is.
  final String message;

  /// The platform's own error identifier, when it supplied one.
  ///
  /// An `AVFoundation` error code, or a CameraX or ML Kit exception class name.
  /// `null` for failures raised on the Dart side.
  final String? nativeCode;

  @override
  String toString() {
    final native = nativeCode;
    final suffix = native == null ? '' : ' (native: $native)';
    return 'MobileScannerException(${code.name}): $message$suffix';
  }
}
