package com.dartnative.mobile_scanner

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

/**
 * One recognized barcode, already converted into the shape the wire expects.
 */
internal class AnalyzedBarcode(
    val wireName: String,
    val rawValue: String?,
    val displayValue: String?,
    val rawBytes: ByteArray?,
    val box: ScannerGeometry.NormalizedRect?,
    val corners: List<Pair<Float, Float>>?,
)

/**
 * The result of analyzing one frame.
 */
internal class AnalyzedFrame(
    val barcodes: List<AnalyzedBarcode>,
    val imageWidth: Int,
    val imageHeight: Int,
)

/**
 * Feeds CameraX frames to ML Kit and reports normalized results.
 *
 * ## Backpressure
 *
 * The `ImageAnalysis` use case is configured with `STRATEGY_KEEP_ONLY_LATEST`, so
 * CameraX delivers the next frame only after the current [ImageProxy] is closed,
 * and drops whatever arrived meanwhile. That alone bounds the pipeline to exactly
 * one analysis in flight, with no queue and no busy flag: the close **is** the
 * backpressure signal. The one obligation that follows is absolute, and a leak
 * here stalls the camera permanently rather than merely slowing it, so every path
 * out of [analyze] closes the proxy exactly once.
 */
internal class BarcodeAnalyzer(
    private val scanner: BarcodeScanner,
    /** Supplies the preview's current size, or null before it is laid out. */
    private val viewSize: () -> Pair<Int, Int>?,
    /** Whether the active camera's preview is mirrored, as the front one is. */
    private val isMirrored: () -> Boolean,
    /** The scan window in normalized preview space, or null for the whole frame. */
    private val scanWindow: () -> ScannerGeometry.NormalizedRect?,
    private val onFrame: (AnalyzedFrame) -> Unit,
    private val onFailure: (Exception) -> Unit,
) : ImageAnalysis.Analyzer {

    @Volatile
    private var closed = false

    /** Stops reporting. In-flight work still closes its proxy. */
    fun shutdown() {
        closed = true
    }

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        if (closed) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val rotation = imageProxy.imageInfo.rotationDegrees

        // Passing the rotation to ML Kit means the bounds come back in the upright
        // image's coordinate space, so no rotation math is needed downstream. The
        // media image is used directly: no bitmap, no JPEG round trip, no copy.
        val input = try {
            InputImage.fromMediaImage(mediaImage, rotation)
        } catch (e: IllegalArgumentException) {
            imageProxy.close()
            onFailure(e)
            return
        }

        // The upright dimensions are the proxy's own, swapped for a quarter turn.
        val uprightWidth = if (rotation == 90 || rotation == 270) {
            imageProxy.height
        } else {
            imageProxy.width
        }
        val uprightHeight = if (rotation == 90 || rotation == 270) {
            imageProxy.width
        } else {
            imageProxy.height
        }

        try {
            scanner.process(input)
                .addOnSuccessListener { barcodes ->
                    if (closed || barcodes.isEmpty()) return@addOnSuccessListener
                    val frame = convert(barcodes, uprightWidth, uprightHeight)
                    if (frame.barcodes.isNotEmpty()) onFrame(frame)
                }
                .addOnFailureListener { error ->
                    if (!closed) onFailure(error)
                }
                .addOnCompleteListener {
                    // The single close for the success and failure paths alike.
                    // Until it runs, CameraX delivers nothing further.
                    imageProxy.close()
                }
        } catch (e: RuntimeException) {
            // process() itself threw, so no completion listener will ever run and
            // the proxy would otherwise leak and stall the camera.
            imageProxy.close()
            onFailure(e)
        }
    }

    private fun convert(
        barcodes: List<Barcode>,
        imageWidth: Int,
        imageHeight: Int,
    ): AnalyzedFrame {
        val size = viewSize()
        val transform = if (size == null) {
            null
        } else {
            ScannerGeometry.transformFor(
                imageWidth = imageWidth,
                imageHeight = imageHeight,
                viewWidth = size.first,
                viewHeight = size.second,
                mirrored = isMirrored(),
            )
        }
        val window = scanWindow()

        val converted = ArrayList<AnalyzedBarcode>(barcodes.size)
        for (barcode in barcodes) {
            val name = ScannerFormats.wireName(barcode.format) ?: continue

            var box: ScannerGeometry.NormalizedRect? = null
            var corners: List<Pair<Float, Float>>? = null

            if (transform != null) {
                val rect = barcode.boundingBox
                if (rect != null) {
                    val mapped = ScannerGeometry.mapRect(
                        transform,
                        rect.left,
                        rect.top,
                        rect.right,
                        rect.bottom,
                    )
                    if (mapped.isFinite()) box = mapped
                }

                val points = barcode.cornerPoints
                if (points != null && points.isNotEmpty()) {
                    val mappedPoints = ArrayList<Pair<Float, Float>>(points.size)
                    var allFinite = true
                    for (point in points) {
                        val mapped = ScannerGeometry.mapPoint(transform, point.x, point.y)
                        if (!mapped.first.isFinite() || !mapped.second.isFinite()) {
                            allFinite = false
                            break
                        }
                        mappedPoints.add(mapped)
                    }
                    // All or nothing, matching the Dart contract: a partial outline
                    // would misstate the symbol's shape.
                    if (allFinite) corners = mappedPoints
                }
            }

            // CameraX has no region-of-interest control on ImageAnalysis, so the
            // window is applied here. A barcode is kept when it overlaps the
            // window at all, so a symbol on the boundary still scans. A detection
            // whose geometry could not be mapped is kept rather than dropped:
            // silently discarding it would be worse than ignoring the window for
            // that one frame.
            if (window != null && box != null && !box.intersects(window)) continue

            converted.add(
                AnalyzedBarcode(
                    wireName = name,
                    rawValue = barcode.rawValue,
                    displayValue = barcode.displayValue,
                    rawBytes = barcode.rawBytes,
                    box = box,
                    corners = corners,
                )
            )
        }

        return AnalyzedFrame(converted, imageWidth, imageHeight)
    }
}
