package com.dartnative.mobile_scanner

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The hosted native view: a CameraX preview plus the analysis that recognizes
 * barcodes.
 *
 * One of these owns exactly one camera binding. A second instance refuses to
 * start rather than contending for the device.
 *
 * The [PreviewView] is created once in the constructor and parented once.
 * Re-parenting a hardware-accelerated surface later makes it render black, which
 * is the single most expensive mistake to debug in this layer.
 */
@SuppressLint("ViewConstructor")
internal class ScannerView(context: Context) : FrameLayout(context) {

    companion object {
        /** The token of the scanner that currently holds the camera, or 0. */
        @Volatile
        private var activeToken: Long = 0L

        /**
         * The resolution analysis targets.
         *
         * 1280x720 is a target with a fallback rule, not a device-specific size:
         * high enough to read a dense symbol across the frame, low enough that ML
         * Kit keeps up comfortably and the camera does not burn power producing
         * pixels nothing will look at. The sensor's full output would cost far more
         * for no detection benefit.
         */
        private val ANALYSIS_TARGET = Size(1280, 720)
    }

    /** The framework's view id, which is also the dispatcher routing token. */
    var token: Long = 0L

    private val previewView = PreviewView(context).apply {
        layoutParams = LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT,
        )
        // FILL_CENTER is what ScannerGeometry's transform assumes. Changing it here
        // without changing that transform would silently misplace every overlay.
        scaleType = PreviewView.ScaleType.FILL_CENTER
        implementationMode = PreviewView.ImplementationMode.PERFORMANCE
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var analysisExecutor: ExecutorService? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var analyzer: BarcodeAnalyzer? = null
    private var barcodeScanner: BarcodeScanner? = null

    /**
     * The scanner drives its own lifecycle rather than binding to the Activity's.
     *
     * Binding to the Activity would rebind the camera on every ON_START, which
     * would resurrect a scanner the application deliberately stopped. Owning the
     * registry keeps "stopped because the app asked" and "stopped because the app
     * went to the background" distinguishable, which is the contract the Dart side
     * documents.
     */
    private val lifecycleOwner = ScannerLifecycleOwner()

    // Requested configuration.
    private var requestedFacing = CameraSelector.LENS_FACING_BACK
    private var formatMask = ScannerFormats.ALL_FORMATS
    private var requestedTorchOn = false
    private var requestedZoom = 1.0f
    private var scanWindow: ScannerGeometry.NormalizedRect? = null

    // Lifecycle intent.
    private var wantsRunning = false
    private var pausedByLifecycle = false
    private var currentState = "stopped"
    private var configured = false
    private var tornDown = false

    private var hostLifecycle: Lifecycle? = null

    /**
     * Incremented for every binding and every suspend.
     *
     * Frames carry the generation they were analyzed under, so a result that
     * completes after a camera switch, a stop, a pause or a dispose is discarded
     * instead of being attributed to whatever session is current.
     */
    private var sessionGeneration = 0L

    private val hostObserver = object : DefaultLifecycleObserver {
        override fun onStop(owner: LifecycleOwner) {
            if (currentState != "running") return
            pausedByLifecycle = true
            suspend("paused")
        }

        override fun onStart(owner: LifecycleOwner) {
            if (!pausedByLifecycle || !wantsRunning || tornDown) return
            pausedByLifecycle = false
            beginStart()
        }
    }

    init {
        layoutParams = LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT,
        )
        addView(previewView)
        attachHostLifecycle()
    }

    /**
     * Subscribes to the host activity's lifecycle.
     *
     * Retried from [beginStart] because `DNAppContext.activity()` is a weak
     * reference that can be null while no activity is resumed, and because the
     * framework types it as `android.app.Activity`, so being a `LifecycleOwner` is
     * a runtime fact rather than a guarantee. Failing silently here would leave the
     * private registry RESUMED when the app backgrounds and the camera held open,
     * which is the exact invariant owning the registry exists to provide.
     */
    private fun attachHostLifecycle() {
        if (hostLifecycle != null) return
        val owner = DNMobileScannerBridge.currentActivity() as? LifecycleOwner
            ?: return
        hostLifecycle = owner.lifecycle
        // LifecycleRegistry keys observers by instance, so re-adding the single
        // hostObserver is a no-op even if this runs more than once.
        owner.lifecycle.addObserver(hostObserver)
    }

    // ── Commands ────────────────────────────────────────────────────────────

    fun configure(
        facing: Int,
        mask: Int,
        torchOn: Boolean,
        zoom: Float,
        window: ScannerGeometry.NormalizedRect?,
        autoStart: Boolean,
    ) {
        requestedFacing = facing
        formatMask = mask
        requestedTorchOn = torchOn
        requestedZoom = zoom
        scanWindow = window
        configured = true
        if (autoStart) start()
    }

    fun start() {
        if (!configured || tornDown) return
        wantsRunning = true
        pausedByLifecycle = false
        if (currentState == "running" || currentState == "starting") return
        beginStart()
    }

    fun stop() {
        wantsRunning = false
        pausedByLifecycle = false
        if (currentState == "stopped") {
            setState("stopped")
            return
        }
        suspend("stopped")
    }

    fun pause() {
        if (currentState != "running") return
        // Not a lifecycle pause, so returning to the foreground must not undo it.
        pausedByLifecycle = false
        suspend("paused")
    }

    fun resume() {
        if (currentState != "paused") return
        beginStart()
    }

    fun setTorch(on: Boolean) {
        requestedTorchOn = on
        val control = camera?.cameraControl ?: return
        if (camera?.cameraInfo?.hasFlashUnit() != true) {
            emitTorch("unavailable")
            return
        }
        control.enableTorch(on)
        emitTorch(if (on) "on" else "off")
    }

    fun setZoom(scale: Float) {
        requestedZoom = scale
        val activeCamera = camera ?: return
        val state = activeCamera.cameraInfo.zoomState.value
        val clamped = if (state == null) {
            scale
        } else {
            scale.coerceIn(state.minZoomRatio, state.maxZoomRatio)
        }
        activeCamera.cameraControl.setZoomRatio(clamped)
        DNMobileScannerBridge.emit(token, ScannerEventType.ZOOM_CHANGED) { json ->
            json.put("scale", clamped.toDouble())
        }
    }

    fun setFacing(facing: Int) {
        if (facing == requestedFacing && camera != null) return
        requestedFacing = facing
        if (currentState != "running" && currentState != "starting") return
        // Rebinding unbinds the previous use cases first, so the two camera
        // bindings never overlap.
        beginStart()
    }

    fun setFormats(mask: Int) {
        if (mask == formatMask) return
        formatMask = mask
        if (currentState != "running") return
        // The recognizer's format set is fixed at construction, so a change means a
        // new client and a new analyzer.
        beginStart()
    }

    fun setScanWindow(window: ScannerGeometry.NormalizedRect?) {
        scanWindow = window
    }

    fun tearDown() {
        if (tornDown) return
        tornDown = true
        wantsRunning = false
        hostLifecycle?.removeObserver(hostObserver)
        hostLifecycle = null
        suspend("stopped")
        lifecycleOwner.destroy()
    }

    // ── Start and stop ──────────────────────────────────────────────────────

    private fun beginStart() {
        setState("starting")
        // The activity may not have been resolvable when the view was constructed.
        attachHostLifecycle()

        if (CameraPermission.isGranted(context)) {
            claimAndOpen()
            return
        }

        CameraPermission.request(DNMobileScannerBridge.currentActivity()) { outcome ->
            if (tornDown) return@request
            when (outcome) {
                PermissionOutcome.GRANTED -> claimAndOpen()
                PermissionOutcome.DENIED -> emitError(
                    "permissionDenied",
                    "The user refused camera access.",
                )
                PermissionOutcome.PERMANENTLY_DENIED -> emitError(
                    "permissionPermanentlyDenied",
                    "Camera access was refused and will not be requested again. " +
                        "Only the app's settings page can change it.",
                )
                PermissionOutcome.NO_ACTIVITY -> emitError(
                    "startFailed",
                    "No foreground Activity was available to request camera " +
                        "permission through.",
                )
            }
        }
    }

    private fun claimAndOpen() {
        if (tornDown) return

        val active = activeToken
        if (active != 0L && active != token) {
            emitError(
                "cameraInUse",
                "Another MobileScanner already owns the camera. " +
                    "Only one scanner can run at a time.",
            )
            return
        }
        activeToken = token

        val future = ProcessCameraProvider.getInstance(context.applicationContext)
        future.addListener({
            if (tornDown) return@addListener
            val provider = try {
                future.get()
            } catch (e: Exception) {
                emitError(
                    "initializationFailed",
                    "The camera provider could not be obtained: ${e.message}",
                    e.javaClass.simpleName,
                )
                return@addListener
            }
            cameraProvider = provider
            bind(provider)
        }, ContextCompat_getMainExecutor())
    }

    private fun bind(provider: ProcessCameraProvider) {
        val selector = CameraSelector.Builder()
            .requireLensFacing(requestedFacing)
            .build()

        if (!hasCamera(provider, selector)) {
            activeToken = 0L
            // Release whatever the previous binding still held. Without this a
            // failed switch leaves the old camera bound and its BarcodeScanner
            // open while emitError moves the state to "error", so the camera keeps
            // running and burning power with every detection suppressed.
            releaseUseCases(provider)
            lifecycleOwner.deactivate()
            camera = null
            val otherFacing = if (requestedFacing == CameraSelector.LENS_FACING_BACK) {
                CameraSelector.LENS_FACING_FRONT
            } else {
                CameraSelector.LENS_FACING_BACK
            }
            val hasOther = hasCamera(
                provider,
                CameraSelector.Builder().requireLensFacing(otherFacing).build(),
            )
            emitError(
                if (hasOther) "unsupportedCamera" else "cameraUnavailable",
                if (hasOther) {
                    "This device has no " +
                        (if (requestedFacing == CameraSelector.LENS_FACING_FRONT) "front" else "back") +
                        " camera."
                } else {
                    "This device has no usable camera."
                },
            )
            return
        }

        // Unbind before rebuilding so a camera switch or a format change never has
        // two bindings alive at once.
        releaseUseCases(provider)

        val scanner = buildScanner()
        barcodeScanner = scanner

        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(
                    ANALYSIS_TARGET,
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                )
            )
            .build()

        val newPreview = Preview.Builder().build().also {
            it.surfaceProvider = previewView.surfaceProvider
        }

        val newAnalysis = ImageAnalysis.Builder()
            .setResolutionSelector(resolutionSelector)
            // The next frame is delivered only after the current ImageProxy is
            // closed, and anything that arrived meanwhile is dropped. That bounds
            // the pipeline to one analysis in flight with no queue to grow.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()

        val executor = Executors.newSingleThreadExecutor()
        analysisExecutor = executor

        // This binding's identity. A frame converted by this analyzer carries it,
        // and emitDetection drops anything whose generation is no longer current.
        // analyzer.shutdown() alone is not enough: a frame already converted and
        // posted to the main looper cannot be recalled, and the next session also
        // reaches "running", so a state check cannot tell the two apart.
        val generation = ++sessionGeneration

        // Captured, not read live. convert() runs on the ML Kit callback, by which
        // time setFacing may already have changed requestedFacing, which would
        // mirror an in-flight rear-camera frame as if it were a front-camera one.
        val mirrored = requestedFacing == CameraSelector.LENS_FACING_FRONT

        val newAnalyzer = BarcodeAnalyzer(
            scanner = scanner,
            viewSize = {
                val w = previewView.width
                val h = previewView.height
                if (w > 0 && h > 0) Pair(w, h) else null
            },
            isMirrored = { mirrored },
            scanWindow = { scanWindow },
            onFrame = { frame ->
                mainHandler.post { emitDetection(frame, generation) }
            },
            onFailure = { error -> mainHandler.post { onAnalyzerFailure(error) } },
        )
        analyzer = newAnalyzer
        newAnalysis.setAnalyzer(executor, newAnalyzer)

        preview = newPreview
        imageAnalysis = newAnalysis

        val bound = try {
            lifecycleOwner.activate()
            provider.bindToLifecycle(lifecycleOwner, selector, newPreview, newAnalysis)
        } catch (e: Exception) {
            activeToken = 0L
            // The use cases, the analyzer, its executor and the new BarcodeScanner
            // were all created above and are now bound to nothing, so release them
            // here rather than leaving them for whenever the next call arrives.
            releaseUseCases(provider)
            lifecycleOwner.deactivate()
            camera = null
            emitError(
                "startFailed",
                "The camera could not be bound: ${e.message}",
                e.javaClass.simpleName,
            )
            return
        }

        camera = bound
        applyInitialDeviceState(bound)
        setState("running")
        emitReady(bound)
    }

    private fun hasCamera(
        provider: ProcessCameraProvider,
        selector: CameraSelector,
    ): Boolean = try {
        provider.hasCamera(selector)
    } catch (e: Exception) {
        false
    }

    private fun buildScanner(): BarcodeScanner {
        val formats = ScannerFormats.formatsOf(formatMask)
        if (formats.isEmpty()) {
            // The mask asked for everything, so let ML Kit use its own all-formats
            // path rather than listing thirteen constants.
            return BarcodeScanning.getClient(
                BarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
                    .build()
            )
        }
        // Only the requested symbologies are configured, so the recognizer never
        // spends effort decoding formats the caller does not want.
        val first = formats.first()
        val rest = formats.drop(1).toIntArray()
        return BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(first, *rest)
                .build()
        )
    }

    private fun applyInitialDeviceState(bound: Camera) {
        if (requestedZoom > 1.0f) setZoom(requestedZoom)
        if (requestedTorchOn && bound.cameraInfo.hasFlashUnit()) {
            bound.cameraControl.enableTorch(true)
        }
    }

    private fun suspend(reportedState: String) {
        if (activeToken == token) activeToken = 0L

        // Retire this binding's generation before anything else, so a frame still
        // in flight is already stale by the time it reaches the main looper.
        sessionGeneration++

        analyzer?.shutdown()
        imageAnalysis?.clearAnalyzer()
        cameraProvider?.let { releaseUseCases(it) }
        lifecycleOwner.deactivate()

        camera = null
        setState(reportedState)
        if (reportedState == "stopped") emitTorch("unavailable")
    }

    /**
     * Unbinds the use cases and releases everything attached to them.
     *
     * Ordering matters: the analyzer stops first so no further ML Kit work starts,
     * then the use cases are unbound so CameraX stops delivering, then the executor
     * and the recognizer are closed. Closing the recognizer while a frame is still
     * being processed would throw.
     */
    private fun releaseUseCases(provider: ProcessCameraProvider) {
        analyzer?.shutdown()
        imageAnalysis?.clearAnalyzer()

        val toUnbind = listOfNotNull(preview, imageAnalysis)
        if (toUnbind.isNotEmpty()) {
            try {
                provider.unbind(*toUnbind.toTypedArray())
            } catch (e: Exception) {
                DNMobileScannerBridge.log("unbind failed: ${e.message}")
            }
        }

        preview = null
        imageAnalysis = null
        analyzer = null

        analysisExecutor?.shutdown()
        analysisExecutor = null

        barcodeScanner?.let {
            try {
                it.close()
            } catch (e: Exception) {
                DNMobileScannerBridge.log("scanner close failed: ${e.message}")
            }
        }
        barcodeScanner = null
    }

    private fun onAnalyzerFailure(error: Exception) {
        // One failed frame is not worth tearing the session down; a camera that
        // momentarily produces an unusable buffer recovers by itself. Only report.
        DNMobileScannerBridge.log("analysis failed: ${error.message}")
    }

    // ── Events ──────────────────────────────────────────────────────────────

    private fun setState(next: String) {
        if (currentState == next) return
        currentState = next
        DNMobileScannerBridge.emit(token, ScannerEventType.STATE_CHANGED) { json ->
            json.put("state", next)
        }
    }

    private fun emitDetection(frame: AnalyzedFrame, generation: Long) {
        // Deterministic ownership rather than a timing assumption: a late frame
        // from a previous binding is identified by its generation, not by when it
        // happened to arrive.
        if (tornDown || generation != sessionGeneration) return
        if (currentState != "running") return
        DNMobileScannerBridge.emitDetection(token, frame)
    }

    private fun emitReady(bound: Camera) {
        val info = bound.cameraInfo
        val torch = if (!info.hasFlashUnit()) {
            "unavailable"
        } else if (info.torchState.value == androidx.camera.core.TorchState.ON) {
            "on"
        } else {
            "off"
        }
        val zoom = info.zoomState.value
        DNMobileScannerBridge.emit(token, ScannerEventType.READY) { json ->
            json.put(
                "facing",
                if (requestedFacing == CameraSelector.LENS_FACING_FRONT) "front" else "back",
            )
            json.put("torch", torch)
            json.put("minZoom", (zoom?.minZoomRatio ?: 1.0f).toDouble())
            json.put("maxZoom", (zoom?.maxZoomRatio ?: 1.0f).toDouble())
        }
        DNMobileScannerBridge.emit(token, ScannerEventType.ZOOM_CHANGED) { json ->
            json.put("scale", (zoom?.zoomRatio ?: 1.0f).toDouble())
        }
    }

    private fun emitTorch(state: String) {
        DNMobileScannerBridge.emit(token, ScannerEventType.TORCH_STATE_CHANGED) { json ->
            json.put("torch", state)
        }
    }

    private fun emitError(code: String, message: String, native: String? = null) {
        if (activeToken == token) activeToken = 0L
        currentState = "error"
        DNMobileScannerBridge.emit(token, ScannerEventType.ERROR) { json ->
            json.put("code", code)
            json.put("message", message)
            if (native != null) json.put("native", native)
        }
    }

    private fun ContextCompat_getMainExecutor() =
        androidx.core.content.ContextCompat.getMainExecutor(context)
}

/**
 * A lifecycle the scanner owns, so CameraX binds and unbinds exactly when this
 * plugin says so.
 */
private class ScannerLifecycleOwner : LifecycleOwner {

    private val registry = LifecycleRegistry(this)

    override val lifecycle: Lifecycle get() = registry

    init {
        registry.currentState = Lifecycle.State.INITIALIZED
        registry.currentState = Lifecycle.State.CREATED
    }

    fun activate() {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        registry.currentState = Lifecycle.State.RESUMED
    }

    fun deactivate() {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        registry.currentState = Lifecycle.State.CREATED
    }

    fun destroy() {
        registry.currentState = Lifecycle.State.DESTROYED
    }
}
