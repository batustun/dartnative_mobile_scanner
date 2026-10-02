// Mapping between the Dart BarcodeFormat set and AVFoundation's metadata types.
//
// The Dart side's format mask uses Google ML Kit's FORMAT_* bit values, because
// the Android side ORs them straight into BarcodeScannerOptions. iOS therefore
// translates, and this file is the only place that knows how.

import AVFoundation

/// The ML Kit FORMAT_* bits, mirrored from the Dart `BarcodeFormat.value`.
enum DNScannerFormatBit {
    static let code128: Int32 = 1
    static let code39: Int32 = 2
    static let code93: Int32 = 4
    static let codabar: Int32 = 8
    static let dataMatrix: Int32 = 16
    static let ean13: Int32 = 32
    static let ean8: Int32 = 64
    static let itf: Int32 = 128
    static let qrCode: Int32 = 256
    static let upcA: Int32 = 512
    static let upcE: Int32 = 1024
    static let pdf417: Int32 = 2048
    static let aztec: Int32 = 4096

    /// Matches `BarcodeFormat.allFormatsMask`.
    static let all: Int32 = 0xFFFF
}

/// The `BarcodeFormat.wireName` strings, mirrored from Dart.
enum DNScannerFormatName {
    static let code128 = "code128"
    static let code39 = "code39"
    static let code93 = "code93"
    static let codabar = "codabar"
    static let dataMatrix = "dataMatrix"
    static let ean13 = "ean13"
    static let ean8 = "ean8"
    static let itf = "itf"
    static let qrCode = "qrCode"
    static let upcA = "upcA"
    static let upcE = "upcE"
    static let pdf417 = "pdf417"
    static let aztec = "aztec"
}

enum DNScannerFormats {

    /// Whether `AVMetadataObject.ObjectType.codabar` exists on this OS.
    ///
    /// Added in iOS 15.4, while the pod's deployment target is 15.0, so a device
    /// between the two cannot scan Codabar at all.
    static var supportsCodabar: Bool {
        if #available(iOS 15.4, *) { return true }
        return false
    }

    /// Every symbology this build can recognize on the running OS, as Dart wire
    /// names. Backs `MobileScanner.supportedFormats`.
    static func supportedWireNames() -> [String] {
        var names = [
            DNScannerFormatName.code128,
            DNScannerFormatName.code39,
            DNScannerFormatName.code93,
            DNScannerFormatName.dataMatrix,
            DNScannerFormatName.ean13,
            DNScannerFormatName.ean8,
            DNScannerFormatName.itf,
            DNScannerFormatName.qrCode,
            DNScannerFormatName.upcA,
            DNScannerFormatName.upcE,
            DNScannerFormatName.pdf417,
            DNScannerFormatName.aztec,
        ]
        if supportsCodabar { names.append(DNScannerFormatName.codabar) }
        return names
    }

    /// The bits in `mask` that this OS cannot recognize.
    ///
    /// Returned as Dart wire names so the error message names what the caller
    /// asked for rather than a number.
    static func unsupportedWireNames(in mask: Int32) -> [String] {
        var missing: [String] = []
        if mask != DNScannerFormatBit.all,
           mask & DNScannerFormatBit.codabar != 0,
           !supportsCodabar {
            missing.append(DNScannerFormatName.codabar)
        }
        return missing
    }

    /// The metadata object types to ask the capture output for.
    ///
    /// Only the requested symbologies are listed, so AVFoundation does not spend
    /// effort looking for the rest. An empty result means the mask selected
    /// nothing this OS can do, which the caller treats as a configuration error
    /// rather than scanning for everything.
    static func metadataTypes(for mask: Int32) -> [AVMetadataObject.ObjectType] {
        var types: [AVMetadataObject.ObjectType] = []

        func include(_ bit: Int32) -> Bool { mask & bit != 0 }

        if include(DNScannerFormatBit.qrCode) { types.append(.qr) }
        if include(DNScannerFormatBit.aztec) { types.append(.aztec) }
        if include(DNScannerFormatBit.dataMatrix) { types.append(.dataMatrix) }
        if include(DNScannerFormatBit.pdf417) { types.append(.pdf417) }
        if include(DNScannerFormatBit.ean8) { types.append(.ean8) }
        if include(DNScannerFormatBit.upcE) { types.append(.upce) }
        if include(DNScannerFormatBit.code93) { types.append(.code93) }
        if include(DNScannerFormatBit.code128) { types.append(.code128) }

        // AVFoundation splits Code 39 into plain and mod-43 checksum variants,
        // while ML Kit reports one FORMAT_CODE_39. Request both and report both
        // as code39.
        if include(DNScannerFormatBit.code39) {
            types.append(.code39)
            types.append(.code39Mod43)
        }

        // Likewise ITF: AVFoundation has a strict 14 digit type and a general
        // interleaved 2 of 5 type; ML Kit has one FORMAT_ITF.
        if include(DNScannerFormatBit.itf) {
            types.append(.itf14)
            types.append(.interleaved2of5)
        }

        // There is no UPC-A metadata type. UPC-A is an EAN-13 payload with a
        // leading zero, so requesting either one asks for .ean13 and the reverse
        // mapping decides which name to report.
        if include(DNScannerFormatBit.ean13) || include(DNScannerFormatBit.upcA) {
            types.append(.ean13)
        }

        if include(DNScannerFormatBit.codabar), supportsCodabar {
            if #available(iOS 15.4, *) { types.append(.codabar) }
        }

        // Deduplicate while keeping order, since .ean13 can be appended once for
        // two different requested bits.
        var seen = Set<AVMetadataObject.ObjectType>()
        return types.filter { seen.insert($0).inserted }
    }

    /// The Dart wire name and payload to report for one recognized object.
    ///
    /// Returns nil for a symbology this plugin does not model, so an unexpected
    /// type is dropped rather than mislabelled.
    ///
    /// `mask` is needed to resolve the EAN-13 and UPC-A overlap: a 13 digit
    /// payload beginning with `0` is reported as UPC-A, with the leading zero
    /// stripped, only when UPC-A was actually requested.
    static func resolve(
        type: AVMetadataObject.ObjectType,
        value: String?,
        mask: Int32
    ) -> (name: String, value: String?)? {
        switch type {
        case .qr:
            return (DNScannerFormatName.qrCode, value)
        case .aztec:
            return (DNScannerFormatName.aztec, value)
        case .dataMatrix:
            return (DNScannerFormatName.dataMatrix, value)
        case .pdf417:
            return (DNScannerFormatName.pdf417, value)
        case .ean8:
            return (DNScannerFormatName.ean8, value)
        case .upce:
            return (DNScannerFormatName.upcE, value)
        case .code93:
            return (DNScannerFormatName.code93, value)
        case .code128:
            return (DNScannerFormatName.code128, value)
        case .code39, .code39Mod43:
            return (DNScannerFormatName.code39, value)
        case .itf14, .interleaved2of5:
            return (DNScannerFormatName.itf, value)
        case .ean13:
            let wantsUpcA = mask & DNScannerFormatBit.upcA != 0
            if wantsUpcA, let text = value, text.count == 13, text.hasPrefix("0") {
                return (DNScannerFormatName.upcA, String(text.dropFirst()))
            }
            return (DNScannerFormatName.ean13, value)
        default:
            if supportsCodabar, #available(iOS 15.4, *), type == .codabar {
                return (DNScannerFormatName.codabar, value)
            }
            return nil
        }
    }
}
