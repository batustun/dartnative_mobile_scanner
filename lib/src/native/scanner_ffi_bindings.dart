/// The FFI surface, and the one dispatcher the whole plugin shares.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import '../mobile_scanner.dart' show registerMobileScannerElementFactory;

/// Receives one decoded native event for one scanner instance.
typedef ScannerEventHandler = void Function(int type, String payload);

/// The single dispatcher pointer for this plugin, and the token routing table.
///
/// One `Pointer.fromFunction` serves every scanner instance; the `token` is the
/// framework's view id, so routing is per instance without any global state in
/// native code. A token from before a hot restart finds no handler and is
/// dropped.
///
/// `Pointer.fromFunction` is **synchronous**: Dart copies the payload string
/// during the call, so the native side transfers no ownership and nothing needs
/// freeing on either side. That is also why the native code may hand over a
/// stack-scoped buffer rather than a `strdup`.
final Map<int, ScannerEventHandler> _handlers = <int, ScannerEventHandler>{};

void _dispatch(int token, int type, Pointer<Utf8> payload) {
  // Copy first, synchronously, before any routing can fail.
  final String json = payload == nullptr ? '' : payload.toDartString();
  _handlers[token]?.call(type, json);
}

final Pointer<NativeFunction<_DispatchC>> _dispatchPtr =
    Pointer.fromFunction<_DispatchC>(_dispatch);

typedef _DispatchC = Void Function(Int64, Int32, Pointer<Utf8>);

typedef _SetDispatcherC = Void Function(Int64);
typedef _SetDispatcherDart = void Function(int);

typedef _VoidC = Void Function();
typedef _VoidDart = void Function();

typedef _SupportedFormatsC = Pointer<Utf8> Function();
typedef _SupportedFormatsDart = Pointer<Utf8> Function();

/// Loads the plugin's native symbols and owns the dispatcher registration.
///
/// `MobileScannerBindings.loadSymbols()` is named in this package's
/// `dartnative.registrant` block, so the generated
/// `DartNativePluginRegistrant.registerAll()` calls it once at startup. Apps do
/// not call it themselves.
abstract final class MobileScannerBindings {
  static bool _loaded = false;

  static late final _SetDispatcherDart _setDispatcher;
  static late final _SupportedFormatsDart _supportedFormats;
  static late final _VoidDart _disposeAll;

  /// Whether the native library loaded and the symbols resolved.
  ///
  /// `false` on an unsupported platform, and on a platform where the native
  /// build is missing or stale. Every public entry point checks this and reports
  /// a typed error rather than throwing a `LateInitializationError`.
  static bool get isAvailable => _loaded;

  /// Resolves the native symbols, registers the dispatcher, and clears any
  /// native state left by a previous Dart session.
  ///
  /// Safe to call more than once. Starts with a platform guard because
  /// `registerAll()` runs on every platform.
  static void loadSymbols() {
    if (_loaded) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    final DynamicLibrary lib = Platform.isAndroid
        ? DynamicLibrary.open('libdartnative_mobile_scanner.so')
        : DynamicLibrary.process();

    _setDispatcher = lib.lookupFunction<_SetDispatcherC, _SetDispatcherDart>(
      'DNMobileScannerSetDispatcher',
    );
    _supportedFormats = lib
        .lookupFunction<_SupportedFormatsC, _SupportedFormatsDart>(
          'DNMobileScannerSupportedFormats',
        );
    _disposeAll = lib.lookupFunction<_VoidC, _VoidDart>(
      'DNMobileScannerDisposeAll',
    );

    if (Platform.isIOS) {
      // iOS has no FlutterPlugin hook, so the view provider registers here.
      // Android registers from DartNativeMobileScannerPlugin.onAttachedToEngine.
      lib.lookupFunction<_VoidC, _VoidDart>(
        'DNMobileScannerRegisterProvider',
      )();
    }

    _loaded = true;

    // Teach the reconciler how to inflate MobileScanner into a native view. Done
    // here so the app needs no init call of its own beyond registerAll().
    registerMobileScannerElementFactory();

    // Tear down sessions a previous Dart session left running. On a hot restart
    // the camera is still open and the old analyzer is still delivering; this is
    // the new session's first chance to reclaim it.
    _disposeAll();

    // Hand native the dispatcher address. Native stores it in one slot and, on
    // iOS, registers that slot with the framework so a hot restart zeroes it
    // before the pointer dies.
    _setDispatcher(_dispatchPtr.address);
  }

  /// Routes events carrying [token] to [handler].
  ///
  /// [token] is the framework's view id for the scanner instance.
  static void registerHandler(int token, ScannerEventHandler handler) {
    _handlers[token] = handler;
  }

  /// Stops routing events for [token].
  ///
  /// Called on disposal. A native event that arrives afterwards finds no handler
  /// and is discarded, which is what guarantees a disposed scanner never emits.
  static void unregisterHandler(int token) {
    _handlers.remove(token);
  }

  /// The raw JSON array of symbologies the running platform can recognize.
  ///
  /// Returns `'[]'` when the native library is unavailable. The returned
  /// `Pointer<Utf8>` is a cached native allocation valid for the app's lifetime,
  /// so it is read but never freed.
  static String supportedFormatsJson() {
    if (!_loaded) return '[]';
    final Pointer<Utf8> ptr = _supportedFormats();
    if (ptr == nullptr) return '[]';
    return ptr.toDartString();
  }
}
