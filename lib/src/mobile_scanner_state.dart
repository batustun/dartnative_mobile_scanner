/// The scanner's lifecycle state.
library;

/// Where the scanner is in its lifecycle.
///
/// Transitions are deterministic and are the same on both platforms:
///
/// ```text
///                 start()
///   stopped  ──────────────▶  starting  ──▶  running
///      ▲                          │             │
///      │                          │ failure     │ pause()
///      │                          ▼             ▼
///      │                        error ◀──────  paused
///      │                                        │
///      │          stop()                        │ resume()
///      └──────── stopping ◀──────────────────────┘
/// ```
///
/// [MobileScannerController.start] is only valid from [stopped] or [error].
/// [MobileScannerController.pause] is only valid from [running]. Calling a
/// transition that is not valid from the current state is a no-op rather than an
/// error, so that duplicated lifecycle callbacks cannot break the scanner. See
/// each method for its exact contract.
enum MobileScannerState {
  /// No camera session exists. The initial state, and the state after
  /// [MobileScannerController.stop] completes.
  stopped(0, 'stopped'),

  /// A camera session is being opened. Permission may be being requested.
  starting(1, 'starting'),

  /// The camera is open and frames are being analyzed.
  running(2, 'running'),

  /// The session is open but analysis is suspended, so no detections are
  /// emitted.
  ///
  /// Reached by [MobileScannerController.pause] or by the app going to the
  /// background. The camera is released while paused, so another app can use it;
  /// [MobileScannerController.resume] reopens it.
  paused(3, 'paused'),

  /// The session is being torn down.
  stopping(4, 'stopping'),

  /// The scanner failed. [MobileScannerController.error] holds the reason.
  ///
  /// Recoverable: [MobileScannerController.start] may be called again, for
  /// instance after the user granted permission in Settings.
  error(5, 'error');

  const MobileScannerState(this.value, this.wireName);

  /// The wire value shared with the native side.
  final int value;

  /// The stable identifier used in native event payloads.
  final String wireName;

  /// Whether a camera session currently exists, in any form.
  bool get hasSession =>
      this == MobileScannerState.running ||
      this == MobileScannerState.paused ||
      this == MobileScannerState.starting;

  /// The state whose [wireName] is [name], or `null` when none matches.
  static MobileScannerState? fromWireName(String name) {
    for (final state in values) {
      if (state.wireName == name) return state;
    }
    return null;
  }
}
