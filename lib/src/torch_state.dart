/// Torch availability and state.
library;

/// The state of the camera's torch.
///
/// Distinguishes "off" from "this camera has no torch", because a scanner UI
/// that shows an enabled torch button on a front camera that cannot light up is
/// lying to the user.
enum TorchState {
  /// The active camera has no torch, so it can be neither on nor off.
  ///
  /// Typical for front cameras. Calls to
  /// [MobileScannerController.setTorchEnabled] throw
  /// [MobileScannerErrorCode.torchUnavailable] in this state.
  unavailable(0, 'unavailable'),

  /// The torch is available and currently off.
  off(1, 'off'),

  /// The torch is available and currently on.
  on(2, 'on');

  const TorchState(this.value, this.wireName);

  /// The wire value shared with the native side.
  final int value;

  /// The stable identifier used in native event payloads.
  final String wireName;

  /// Whether the active camera has a torch at all.
  bool get isAvailable => this != TorchState.unavailable;

  /// The state whose [wireName] is [name], or `null` when none matches.
  static TorchState? fromWireName(String name) {
    for (final state in values) {
      if (state.wireName == name) return state;
    }
    return null;
  }
}
