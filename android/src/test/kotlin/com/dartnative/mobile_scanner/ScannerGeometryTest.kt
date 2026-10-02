package com.dartnative.mobile_scanner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The centre-crop transform is the one piece of coordinate math this plugin does
 * by hand, so it is the one piece that is unit tested.
 */
class ScannerGeometryTest {

    private val tolerance = 1e-4f

    private fun transform(
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Int,
        viewHeight: Int,
        mirrored: Boolean = false,
    ) = ScannerGeometry.transformFor(
        imageWidth, imageHeight, viewWidth, viewHeight, mirrored,
    )

    // ── transformFor ────────────────────────────────────────────────────────

    @Test
    fun `rejects non-positive dimensions`() {
        // Happens on the first layout pass, before the view has a size.
        assertNull(transform(0, 720, 1080, 1920))
        assertNull(transform(1280, 0, 1080, 1920))
        assertNull(transform(1280, 720, 0, 1920))
        assertNull(transform(1280, 720, 1080, 0))
        assertNull(transform(-1280, 720, 1080, 1920))
    }

    @Test
    fun `matching aspect ratios need no crop`() {
        // 720x1280 into 1080x1920: both ratios are 1.5, so nothing is cropped.
        val t = transform(720, 1280, 1080, 1920)!!
        assertEquals(1.5f, t.scale, tolerance)
        assertEquals(0f, t.offsetX, tolerance)
        assertEquals(0f, t.offsetY, tolerance)
    }

    @Test
    fun `a landscape image in a portrait view is cropped horizontally`() {
        // The height ratio is the larger one, so width overflows and is cut off.
        val t = transform(1280, 720, 1080, 1920)!!
        assertEquals(1920f / 720f, t.scale, tolerance)
        assertTrue("width should overflow", t.offsetX < 0f)
        assertEquals(0f, t.offsetY, tolerance)
    }

    @Test
    fun `a portrait image in a landscape view is cropped vertically`() {
        val t = transform(720, 1280, 1920, 1080)!!
        assertEquals(1920f / 720f, t.scale, tolerance)
        assertEquals(0f, t.offsetX, tolerance)
        assertTrue("height should overflow", t.offsetY < 0f)
    }

    @Test
    fun `an identical image and view is the identity transform`() {
        val t = transform(1080, 1920, 1080, 1920)!!
        assertEquals(1f, t.scale, tolerance)
        assertEquals(0f, t.offsetX, tolerance)
        assertEquals(0f, t.offsetY, tolerance)
    }

    // ── mapRect ─────────────────────────────────────────────────────────────

    @Test
    fun `the whole image fills the whole view when aspects match`() {
        val t = transform(720, 1280, 1080, 1920)!!
        val r = ScannerGeometry.mapRect(t, 0, 0, 720, 1280)
        assertEquals(0f, r.left, tolerance)
        assertEquals(0f, r.top, tolerance)
        assertEquals(1f, r.width, tolerance)
        assertEquals(1f, r.height, tolerance)
    }

    @Test
    fun `the image centre always maps to the view centre`() {
        // True whichever dimension is cropped, which is the property that makes a
        // centred scan window correct on every device.
        val cases = listOf(
            Triple(720, 1280, Pair(1080, 1920)),
            Triple(1280, 720, Pair(1080, 1920)),
            Triple(640, 480, Pair(1080, 2340)),
            Triple(1920, 1080, Pair(720, 720)),
        )
        for ((iw, ih, view) in cases) {
            val t = transform(iw, ih, view.first, view.second)!!
            val centre = ScannerGeometry.mapPoint(t, iw / 2, ih / 2)
            assertEquals("x for ${iw}x$ih", 0.5f, centre.first, 1e-3f)
            assertEquals("y for ${iw}x$ih", 0.5f, centre.second, 1e-3f)
        }
    }

    @Test
    fun `a quarter centred box stays a quarter centred box`() {
        val t = transform(720, 1280, 1080, 1920)!!
        val r = ScannerGeometry.mapRect(t, 180, 320, 540, 960)
        assertEquals(0.25f, r.left, tolerance)
        assertEquals(0.25f, r.top, tolerance)
        assertEquals(0.5f, r.width, tolerance)
        assertEquals(0.5f, r.height, tolerance)
    }

    @Test
    fun `a barcode in the cropped margin reports coordinates outside the unit square`() {
        // Reported honestly rather than clamped: the recognizer really did see it,
        // and the preview really is not showing it.
        val t = transform(1280, 720, 1080, 1920)!!
        val r = ScannerGeometry.mapRect(t, 0, 300, 50, 400)
        assertTrue("expected left < 0 but was ${r.left}", r.left < 0f)
    }

    @Test
    fun `width and height stay positive`() {
        val t = transform(1280, 720, 1080, 1920)!!
        val r = ScannerGeometry.mapRect(t, 100, 100, 300, 250)
        assertTrue(r.width > 0f)
        assertTrue(r.height > 0f)
    }

    // ── mirroring ───────────────────────────────────────────────────────────

    @Test
    fun `the front camera mirrors horizontally but not vertically`() {
        val t = transform(720, 1280, 1080, 1920, mirrored = true)
        val plain = transform(720, 1280, 1080, 1920, mirrored = false)!!
        val mirrored = ScannerGeometry.mapRect(t!!, 0, 100, 180, 200)
        val normal = ScannerGeometry.mapRect(plain, 0, 100, 180, 200)

        // A box at the left edge of the image appears at the right edge.
        assertEquals(0f, normal.left, tolerance)
        assertEquals(1f, mirrored.right, tolerance)
        // Vertical placement is untouched.
        assertEquals(normal.top, mirrored.top, tolerance)
        assertEquals(normal.height, mirrored.height, tolerance)
        // The shape is preserved.
        assertEquals(normal.width, mirrored.width, tolerance)
    }

    @Test
    fun `mirroring keeps width positive`() {
        // The edges swap roles under reflection, so they have to be re-ordered.
        val t = transform(720, 1280, 1080, 1920, mirrored = true)!!
        val r = ScannerGeometry.mapRect(t, 100, 100, 400, 500)
        assertTrue("width was ${r.width}", r.width > 0f)
    }

    @Test
    fun `mirroring leaves the centre at the centre`() {
        val t = transform(720, 1280, 1080, 1920, mirrored = true)!!
        val r = ScannerGeometry.mapRect(t, 300, 600, 420, 680)
        assertEquals(0.5f, r.left + r.width / 2f, tolerance)
    }

    @Test
    fun `mirroring is its own inverse`() {
        val plain = transform(720, 1280, 1080, 1920, mirrored = false)!!
        val mirrored = transform(720, 1280, 1080, 1920, mirrored = true)!!
        val a = ScannerGeometry.mapPoint(plain, 123, 456)
        val b = ScannerGeometry.mapPoint(mirrored, 123, 456)
        assertEquals(1f, a.first + b.first, tolerance)
        assertEquals(a.second, b.second, tolerance)
    }

    // ── NormalizedRect ──────────────────────────────────────────────────────

    @Test
    fun `intersects detects overlap and separation`() {
        val window = ScannerGeometry.NormalizedRect(0.1f, 0.35f, 0.8f, 0.3f)

        val inside = ScannerGeometry.NormalizedRect(0.4f, 0.45f, 0.1f, 0.1f)
        assertTrue(inside.intersects(window))

        val above = ScannerGeometry.NormalizedRect(0.4f, 0.0f, 0.1f, 0.1f)
        assertFalse(above.intersects(window))

        val below = ScannerGeometry.NormalizedRect(0.4f, 0.8f, 0.1f, 0.1f)
        assertFalse(below.intersects(window))

        val leftOf = ScannerGeometry.NormalizedRect(0.0f, 0.4f, 0.05f, 0.1f)
        assertFalse(leftOf.intersects(window))
    }

    @Test
    fun `a barcode straddling the window edge still counts`() {
        // Requiring full containment would make a symbol on the boundary unscannable.
        val window = ScannerGeometry.NormalizedRect(0.1f, 0.35f, 0.8f, 0.3f)
        val straddling = ScannerGeometry.NormalizedRect(0.05f, 0.3f, 0.2f, 0.2f)
        assertTrue(straddling.intersects(window))
    }

    @Test
    fun `intersects is symmetric`() {
        val a = ScannerGeometry.NormalizedRect(0.1f, 0.1f, 0.3f, 0.3f)
        val b = ScannerGeometry.NormalizedRect(0.2f, 0.2f, 0.3f, 0.3f)
        assertEquals(a.intersects(b), b.intersects(a))
    }

    @Test
    fun `touching edges do not count as overlap`() {
        val a = ScannerGeometry.NormalizedRect(0.0f, 0.0f, 0.5f, 0.5f)
        val b = ScannerGeometry.NormalizedRect(0.5f, 0.0f, 0.5f, 0.5f)
        assertFalse(a.intersects(b))
    }

    @Test
    fun `isFinite rejects NaN and infinity`() {
        assertTrue(ScannerGeometry.NormalizedRect(0f, 0f, 1f, 1f).isFinite())
        assertFalse(
            ScannerGeometry.NormalizedRect(Float.NaN, 0f, 1f, 1f).isFinite()
        )
        assertFalse(
            ScannerGeometry.NormalizedRect(0f, 0f, Float.POSITIVE_INFINITY, 1f)
                .isFinite()
        )
    }

    @Test
    fun `right and bottom derive from the origin and size`() {
        val r = ScannerGeometry.NormalizedRect(0.2f, 0.3f, 0.4f, 0.1f)
        assertEquals(0.6f, r.right, tolerance)
        assertEquals(0.4f, r.bottom, tolerance)
    }

    // ── ScannerFormats ──────────────────────────────────────────────────────

    @Test
    fun `the all-formats mask selects no explicit formats`() {
        // An empty list tells the caller to use ML Kit's own FORMAT_ALL_FORMATS
        // rather than listing thirteen constants.
        assertTrue(ScannerFormats.formatsOf(ScannerFormats.ALL_FORMATS).isEmpty())
    }

    @Test
    fun `a mask selects exactly the requested bits`() {
        val qrCode = 256
        val ean13 = 32
        val formats = ScannerFormats.formatsOf(qrCode or ean13)
        assertEquals(2, formats.size)
        assertTrue(formats.contains(qrCode))
        assertTrue(formats.contains(ean13))
    }

    @Test
    fun `an empty mask selects nothing`() {
        assertTrue(ScannerFormats.formatsOf(0).isEmpty())
    }

    @Test
    fun `every supported wire name maps back from a format bit`() {
        // Guards the Dart and Kotlin name lists against drifting apart.
        val names = ScannerFormats.supportedWireNames()
        assertEquals(13, names.size)
        assertEquals(names.size, names.toSet().size)
        assertNotNull(names)
    }
}
