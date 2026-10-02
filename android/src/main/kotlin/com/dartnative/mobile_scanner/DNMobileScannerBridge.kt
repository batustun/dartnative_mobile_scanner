package com.dartnative.mobile_scanner

import android.app.Activity
import android.util.Base64
import android.util.Log
import android.view.View
import com.dartnative.DNAndroidPluginProvider
import com.dartnative.DNAppContext
import com.dartnative.DNPluginRegistry
import com.dartnative.DNViewRegistry
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Event type ids, mirrored from the Dart `ScannerEvent`. */
internal object ScannerEventType {
    const val DETECTION = 1
    const val STATE_CHANGED = 2
    const val ERROR = 3
    const val TORCH_STATE_CHANGED = 4
    const val READY = 5
    const val ZOOM_CHANGED = 6
}

/** Command tags, mirrored from the Dart `ScannerCommand`. */
private object ScannerCommand {
    const val CONFIGURE = 1
    const val START = 2
    const val STOP = 3
    const val PAUSE = 4
    const val RESUME = 5
    const val SET_TORCH = 6
    const val SET_ZOOM_SCALE = 7
    const val SET_FACING = 8
    const val SET_FORMATS = 9
    const val SET_SCAN_WINDOW = 10
}

/**
 * The plugin's view provider, and the single path from Kotlin into Dart.
 *
 * Registered from [DartNativeMobileScannerPlugin] on engine attach, which is also
 * where the `.so` is loaded.
 */
internal object DNMobileScannerBridge : DNAndroidPluginProvider {

    private const val TAG = "DNMobileScanner"
    private const val TYPE_KEY = "com.dartnative.mobile_scanner/preview"

    /**
     * Claimed lazily. The Dart and Swift sides claim the same key and the framework
     * hands back the same index, so the three always agree.
     */
    private val typeIndex: Int by lazy { DNPluginRegistry.claimViewType(TYPE_KEY) }

    /** Live scanner views, keyed by the framework's view id. */
    private val views = HashMap<Long, ScannerView>()

    fun register() {
        // Caches this class in the JNI layer so DisposeAll can call back into
        // Kotlin. Done from Kotlin because FindClass in JNI_OnLoad would run under
        // a class loader that cannot see app classes.
        nativeRegisterBridge()
        DNPluginRegistry.register(this)
        // Runs when a NEW Dart session starts, which is the right moment to reclaim
        // a camera the previous session left open. It is cleanup, never the
        // dangling-callback guard; that lives in the JNI layer's generation check.
        DNViewRegistry.registerResetHook {
            disposeAll()
            null
        }
        Log.i(TAG, "mobile scanner provider registered")
    }

    fun currentActivity(): Activity? = try {
        DNAppContext.activity()
    } catch (e: Throwable) {
        // An app on a framework built before this accessor degrades instead of
        // crashing; permission requests then report that no Activity was available.
        null
    }

    fun log(message: String) {
        Log.w(TAG, message)
    }

    // ── DNAndroidPluginProvider ─────────────────────────────────────────────

    override fun createView(typeIndex: Int): View? {
        // An unknown index belongs to another plugin. Return null, never crash.
        if (typeIndex != this.typeIndex) return null
        val context = DNAppContext.get() ?: return null
        return ScannerView(context)
    }

    override fun handleMutation(viewId: Long, eventTag: Int, data: ByteArray) {
        val view = DNViewRegistry.view(viewId) as? ScannerView ?: return
        // The framework assigns the id after createView, so this is where the view
        // learns its own routing token.
        view.token = viewId
        views[viewId] = view

        try {
            dispatch(view, eventTag, data)
        } catch (e: JSONException) {
            log("malformed mutation payload for tag $eventTag: ${e.message}")
        }
    }

    override fun disposeView(viewId: Long, view: View) {
        views.remove(viewId)
        (view as? ScannerView)?.tearDown()
    }

    private fun disposeAll() {
        val snapshot = views.values.toList()
        views.clear()
        for (view in snapshot) view.tearDown()
    }

    /** Invoked from JNI when the Dart side calls `DNMobileScannerDisposeAll`. */
    @JvmStatic
    fun disposeAllFromNative() {
        disposeAll()
    }

    private fun dispatch(view: ScannerView, eventTag: Int, data: ByteArray) {
        when (eventTag) {
            ScannerCommand.CONFIGURE -> {
                val json = parse(data) ?: return
                view.configure(
                    facing = facingOf(json.optString("facing", "back")),
                    mask = json.optInt("formats", ScannerFormats.ALL_FORMATS),
                    torchOn = json.optBoolean("torch", false),
                    zoom = json.optDouble("zoom", 1.0).toFloat(),
                    window = windowOf(json),
                    autoStart = json.optBoolean("autoStart", false),
                )
            }

            ScannerCommand.START -> view.start()
            ScannerCommand.STOP -> view.stop()
            ScannerCommand.PAUSE -> view.pause()
            ScannerCommand.RESUME -> view.resume()

            ScannerCommand.SET_TORCH -> {
                val json = parse(data) ?: return
                view.setTorch(json.optBoolean("on", false))
            }

            ScannerCommand.SET_ZOOM_SCALE -> {
                val json = parse(data) ?: return
                view.setZoom(json.optDouble("scale", 1.0).toFloat())
            }

            ScannerCommand.SET_FACING -> {
                val json = parse(data) ?: return
                view.setFacing(facingOf(json.optString("facing", "back")))
            }

            ScannerCommand.SET_FORMATS -> {
                val json = parse(data) ?: return
                view.setFormats(json.optInt("formats", ScannerFormats.ALL_FORMATS))
            }

            ScannerCommand.SET_SCAN_WINDOW -> {
                val json = parse(data) ?: return
                // An explicit null clears the window, so a missing rect is not an
                // error.
                view.setScanWindow(windowOf(json))
            }

            else -> log("unknown eventTag=$eventTag")
        }
    }

    /** Decodes a mutation payload, validating the length before reading. */
    private fun parse(data: ByteArray): JSONObject? {
        if (data.isEmpty()) return null
        return JSONObject(String(data, Charsets.UTF_8))
    }

    private fun facingOf(name: String): Int =
        if (name == "front") {
            androidx.camera.core.CameraSelector.LENS_FACING_FRONT
        } else {
            androidx.camera.core.CameraSelector.LENS_FACING_BACK
        }

    private fun windowOf(json: JSONObject): ScannerGeometry.NormalizedRect? {
        val array = json.optJSONArray("scanWindow") ?: return null
        if (array.length() != 4) return null
        val rect = ScannerGeometry.NormalizedRect(
            left = array.optDouble(0, Double.NaN).toFloat(),
            top = array.optDouble(1, Double.NaN).toFloat(),
            width = array.optDouble(2, Double.NaN).toFloat(),
            height = array.optDouble(3, Double.NaN).toFloat(),
        )
        if (!rect.isFinite() || rect.width <= 0f || rect.height <= 0f) return null
        return rect
    }

    // ── Emitting to Dart ────────────────────────────────────────────────────

    /**
     * Builds a payload and fires it at Dart.
     *
     * Must be called on the main thread, which is where Dart lives. The JNI layer
     * re-checks the dispatcher slot and the isolate generation before every call,
     * so a hot restart drops the event instead of calling a dead pointer.
     */
    fun emit(token: Long, type: Int, build: (JSONObject) -> Unit) {
        if (token == 0L) return
        val json = JSONObject()
        try {
            build(json)
        } catch (e: JSONException) {
            log("could not build event $type: ${e.message}")
            return
        }
        nativeEmit(token, type, json.toString())
    }

    fun emitDetection(token: Long, frame: AnalyzedFrame) {
        if (token == 0L) return
        val barcodes = JSONArray()
        try {
            for (barcode in frame.barcodes) {
                val entry = JSONObject()
                entry.put("f", barcode.wireName)
                barcode.rawValue?.let { entry.put("v", it) }
                barcode.displayValue?.let { entry.put("d", it) }
                barcode.rawBytes?.let {
                    entry.put("bytes", Base64.encodeToString(it, Base64.NO_WRAP))
                }
                barcode.box?.let { box ->
                    entry.put(
                        "r",
                        JSONArray().apply {
                            put(box.left.toDouble())
                            put(box.top.toDouble())
                            put(box.width.toDouble())
                            put(box.height.toDouble())
                        },
                    )
                }
                barcode.corners?.let { corners ->
                    entry.put(
                        "c",
                        JSONArray().apply {
                            for (point in corners) {
                                put(
                                    JSONArray().apply {
                                        put(point.first.toDouble())
                                        put(point.second.toDouble())
                                    },
                                )
                            }
                        },
                    )
                }
                barcodes.put(entry)
            }

            if (barcodes.length() == 0) return

            val json = JSONObject()
            json.put("ts", System.currentTimeMillis())
            json.put("w", frame.imageWidth)
            json.put("h", frame.imageHeight)
            json.put("b", barcodes)
            nativeEmit(token, ScannerEventType.DETECTION, json.toString())
        } catch (e: JSONException) {
            log("could not build detection payload: ${e.message}")
        }
    }

    /**
     * Delivers one event to the Dart dispatcher.
     *
     * Implemented in `dn_scanner_bridge.cpp`, which owns the dispatcher slot and
     * performs the hot-restart generation check.
     */
    @JvmStatic
    private external fun nativeEmit(token: Long, type: Int, payload: String)

    /**
     * Hands this class to the JNI layer so it can invoke [disposeAllFromNative].
     *
     * Implemented in `dn_scanner_bridge.cpp`.
     */
    @JvmStatic
    private external fun nativeRegisterBridge()
}
