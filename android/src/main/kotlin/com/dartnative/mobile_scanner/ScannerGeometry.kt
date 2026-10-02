package com.dartnative.mobile_scanner

/**
 * Converts barcode geometry from the analyzed image into normalized preview
 * coordinates.
 *
 * ML Kit reports bounds in the coordinate space of the [android.media.Image] it
 * was handed, already rotated upright because the rotation degrees are passed to
 * `InputImage.fromMediaImage`. The preview, meanwhile, is an
 * `androidx.camera.view.PreviewView` in `FILL_CENTER` mode, which scales the
 * image to cover its box and centres it, cropping whatever does not fit. The
 * front camera's preview is additionally mirrored horizontally.
 *
 * So the whole transform is: scale by the larger of the two ratios, centre, and
 * mirror for the front camera. That is deliberately all it is. Rotation is
 * already handled upstream by ML Kit, which is why no rotation math appears here,
 * and why there is no handedness to get wrong.
 *
 * Kept free of Android types so it can be unit tested on the JVM.
 */
internal object ScannerGeometry {

    /**
     * A rectangle in normalized preview space, as four floats.
     *
     * Values can fall slightly outside 0..1 for a barcode in the margin the
     * preview crops away, which is reported honestly rather than clamped.
     */
    data class NormalizedRect(
        val left: Float,
        val top: Float,
        val width: Float,
        val height: Float,
    ) {
        val right: Float get() = left + width
        val bottom: Float get() = top + height

        /** Whether this rectangle overlaps [other] at all. */
        fun intersects(other: NormalizedRect): Boolean =
            left < other.right &&
                other.left < right &&
                top < other.bottom &&
                other.top < bottom

        fun isFinite(): Boolean =
            left.isFinite() && top.isFinite() &&
                width.isFinite() && height.isFinite()
    }

    /** The centre-crop mapping from image space to preview space. */
    data class Transform(
        val scale: Float,
        val offsetX: Float,
        val offsetY: Float,
        val viewWidth: Float,
        val viewHeight: Float,
        val mirrored: Boolean,
    )

    /**
     * Builds the transform for an [imageWidth] by [imageHeight] upright image
     * displayed in a [viewWidth] by [viewHeight] preview under FILL_CENTER.
     *
     * Returns null when any dimension is non-positive, which happens on the first
     * layout pass before the view has a size.
     */
    fun transformFor(
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Int,
        viewHeight: Int,
        mirrored: Boolean,
    ): Transform? {
        if (imageWidth <= 0 || imageHeight <= 0) return null
        if (viewWidth <= 0 || viewHeight <= 0) return null

        val vw = viewWidth.toFloat()
        val vh = viewHeight.toFloat()
        val iw = imageWidth.toFloat()
        val ih = imageHeight.toFloat()

        // FILL_CENTER covers the box, so the larger ratio wins and the smaller
        // dimension overflows and is cropped.
        val scale = maxOf(vw / iw, vh / ih)
        val offsetX = (vw - iw * scale) / 2f
        val offsetY = (vh - ih * scale) / 2f

        return Transform(scale, offsetX, offsetY, vw, vh, mirrored)
    }

    /**
     * Maps an image-space rectangle into normalized preview space.
     *
     * [left], [top], [right] and [bottom] are pixels in the upright image.
     */
    fun mapRect(
        transform: Transform,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
    ): NormalizedRect {
        var x0 = left * transform.scale + transform.offsetX
        var x1 = right * transform.scale + transform.offsetX
        val y0 = top * transform.scale + transform.offsetY
        val y1 = bottom * transform.scale + transform.offsetY

        if (transform.mirrored) {
            // Reflect around the preview's vertical centre line. The edges swap
            // roles, so re-order them to keep width positive.
            val mirroredX0 = transform.viewWidth - x1
            val mirroredX1 = transform.viewWidth - x0
            x0 = mirroredX0
            x1 = mirroredX1
        }

        return NormalizedRect(
            left = x0 / transform.viewWidth,
            top = y0 / transform.viewHeight,
            width = (x1 - x0) / transform.viewWidth,
            height = (y1 - y0) / transform.viewHeight,
        )
    }

    /**
     * Maps a single image-space point into normalized preview space.
     *
     * Used for corner points, which follow the symbol's rotation and so cannot go
     * through [mapRect].
     */
    fun mapPoint(transform: Transform, x: Int, y: Int): Pair<Float, Float> {
        val px = x * transform.scale + transform.offsetX
        val py = y * transform.scale + transform.offsetY
        val finalX = if (transform.mirrored) transform.viewWidth - px else px
        return Pair(finalX / transform.viewWidth, py / transform.viewHeight)
    }
}
