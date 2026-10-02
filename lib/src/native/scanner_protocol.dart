/// The wire contract between Dart and the two native scanner implementations.
///
/// Both directions carry UTF-8 JSON. JSON rather than packed binary because
/// every message here is a control command or a small detection result, never a
/// camera frame, so the cost is irrelevant next to having one decode path per
/// platform that is easy to validate and forward compatible. Keys are short to
/// keep detection payloads small, since those are the only ones that can arrive
/// at frame rate.
///
/// Not part of the public API. Changing anything here means changing the Swift
/// and Kotlin sides in the same commit.
library;

/// Tags for `PluginMutation`, the Dart to native direction.
///
/// These travel through the framework's own mutation batch, which keeps them
/// correctly ordered with respect to the view's creation. The payload of each is
/// UTF-8 JSON.
abstract final class ScannerCommand {
  /// Full configuration, sent once in `mount` before anything else.
  ///
  /// `{"facing":"back","formats":256,"scanWindow":[l,t,w,h]|null,
  ///   "torch":bool,"autoStart":bool}`
  static const int configure = 1;

  /// Open the camera and begin analysis. No payload.
  static const int start = 2;

  /// Tear the session down. No payload.
  static const int stop = 3;

  /// Release the camera but keep the scanner mounted. No payload.
  static const int pause = 4;

  /// Reacquire the camera after [pause]. No payload.
  static const int resume = 5;

  /// `{"on":bool}`
  static const int setTorch = 6;

  /// `{"scale":double}`
  static const int setZoomScale = 7;

  /// `{"facing":"front"|"back"}`
  static const int setFacing = 8;

  /// `{"formats":int}`, an ML Kit style format mask.
  static const int setFormats = 9;

  /// `{"scanWindow":[l,t,w,h]}` or `{"scanWindow":null}` to clear it.
  static const int setScanWindow = 10;
}

/// Types for the native to Dart dispatcher, the second argument of the slot
/// callback.
abstract final class ScannerEvent {
  /// One or more barcodes were recognized.
  ///
  /// ```json
  /// {"ts": 1730000000123,
  ///  "w": 1280, "h": 720,
  ///  "b": [{"f":"qrCode","v":"text","d":"display",
  ///         "bytes":"<base64>","r":[l,t,w,h],"c":[[x,y],[x,y],[x,y],[x,y]]}]}
  /// ```
  ///
  /// `ts` is epoch milliseconds taken natively when the recognizer returned.
  /// `w` and `h` are the analyzed image size after rotation, and may be absent.
  /// Inside each barcode, `f` is a [BarcodeFormat.wireName] and is required;
  /// `v`, `d`, `bytes`, `r` and `c` are all optional. `r` and `c` are normalized
  /// to the unit square by the native side.
  static const int detection = 1;

  /// The lifecycle state changed.
  ///
  /// `{"state":"running"}`, using [MobileScannerState.wireName].
  static const int stateChanged = 2;

  /// The scanner failed.
  ///
  /// `{"code":"permissionDenied","message":"...","native":"..."|null}`, using
  /// [MobileScannerErrorCode.wireName]. A code this Dart version does not know
  /// degrades to [MobileScannerErrorCode.nativeFailure] rather than being
  /// dropped.
  static const int error = 3;

  /// The torch's availability or state changed.
  ///
  /// `{"torch":"on"|"off"|"unavailable"}`, using [TorchState.wireName].
  static const int torchStateChanged = 4;

  /// The camera is open and its capabilities are now known.
  ///
  /// `{"facing":"back","torch":"off","minZoom":1.0,"maxZoom":8.0}`
  ///
  /// Sent once per successful start, after [stateChanged] reports `running`.
  static const int ready = 5;

  /// The zoom scale changed, including when the native side clamped a request.
  ///
  /// `{"scale":2.5}`
  static const int zoomChanged = 6;
}
