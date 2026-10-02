package com.dartnative.mobile_scanner

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * The plugin entry point, instantiated automatically by the generated registrant
 * because `pubspec.yaml` declares `pluginClass`.
 *
 * It does exactly two things: load the native library, which is the only call site
 * that fires `JNI_OnLoad`, and register the view provider. No method channels, no
 * services; this plugin talks to Dart over FFI alone.
 */
class DartNativeMobileScannerPlugin : FlutterPlugin {

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            System.loadLibrary("dartnative_mobile_scanner")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(
                "DNMobileScanner",
                "Failed to load libdartnative_mobile_scanner.so: ${e.message}",
            )
            // Without the library nothing can reach Dart, so do not advertise a
            // provider that could never report a result.
            return
        }
        DNMobileScannerBridge.register()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The framework disposes the views it created, which tears the cameras
        // down; nothing further is held here.
    }
}
