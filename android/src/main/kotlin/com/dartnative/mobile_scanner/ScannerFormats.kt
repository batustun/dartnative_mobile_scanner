package com.dartnative.mobile_scanner

import com.google.mlkit.vision.barcode.common.Barcode

/**
 * Mapping between the Dart format mask and ML Kit's `Barcode.FORMAT_*` values.
 *
 * The Dart mask uses ML Kit's own bits, so this side mostly passes the number
 * through. The only real work is naming a recognized format for the wire, and
 * reporting which formats are supported.
 */
internal object ScannerFormats {

    /** Matches `BarcodeFormat.allFormatsMask` on the Dart side. */
    const val ALL_FORMATS = 0xFFFF

    /**
     * The `BarcodeFormat.wireName` for an ML Kit format, or null when ML Kit
     * reported something this plugin does not model.
     *
     * Returning null drops the detection rather than mislabelling it.
     */
    fun wireName(mlKitFormat: Int): String? = when (mlKitFormat) {
        Barcode.FORMAT_CODE_128 -> "code128"
        Barcode.FORMAT_CODE_39 -> "code39"
        Barcode.FORMAT_CODE_93 -> "code93"
        Barcode.FORMAT_CODABAR -> "codabar"
        Barcode.FORMAT_DATA_MATRIX -> "dataMatrix"
        Barcode.FORMAT_EAN_13 -> "ean13"
        Barcode.FORMAT_EAN_8 -> "ean8"
        Barcode.FORMAT_ITF -> "itf"
        Barcode.FORMAT_QR_CODE -> "qrCode"
        Barcode.FORMAT_UPC_A -> "upcA"
        Barcode.FORMAT_UPC_E -> "upcE"
        Barcode.FORMAT_PDF417 -> "pdf417"
        Barcode.FORMAT_AZTEC -> "aztec"
        else -> null
    }

    /**
     * Every symbology the bundled ML Kit recognizer supports, as Dart wire names.
     *
     * Unlike iOS this does not vary by OS version: the model is bundled in the
     * app, so what it can read is fixed at build time.
     */
    fun supportedWireNames(): List<String> = listOf(
        "code128", "code39", "code93", "codabar", "dataMatrix",
        "ean13", "ean8", "itf", "qrCode", "upcA", "upcE", "pdf417", "aztec",
    )

    /**
     * Splits [mask] into the individual ML Kit format bits it selects.
     *
     * [ALL_FORMATS] returns an empty list, which the caller turns into
     * `FORMAT_ALL_FORMATS` rather than a long explicit list.
     */
    fun formatsOf(mask: Int): List<Int> {
        if (mask == ALL_FORMATS) return emptyList()
        val bits = intArrayOf(
            Barcode.FORMAT_CODE_128,
            Barcode.FORMAT_CODE_39,
            Barcode.FORMAT_CODE_93,
            Barcode.FORMAT_CODABAR,
            Barcode.FORMAT_DATA_MATRIX,
            Barcode.FORMAT_EAN_13,
            Barcode.FORMAT_EAN_8,
            Barcode.FORMAT_ITF,
            Barcode.FORMAT_QR_CODE,
            Barcode.FORMAT_UPC_A,
            Barcode.FORMAT_UPC_E,
            Barcode.FORMAT_PDF417,
            Barcode.FORMAT_AZTEC,
        )
        return bits.filter { mask and it != 0 }
    }
}
