// The FFI surface, the view provider registration, and the one dispatcher slot
// this plugin owns.
//
// Framework symbols are resolved with dlsym at runtime rather than by importing
// dartnative_ios, which would create a circular CocoaPods dependency.

import AVFoundation
import Foundation
import UIKit

/// Event type ids, mirrored from the Dart `ScannerEvent`.
enum DNScannerEventType {
    static let detection: Int32 = 1
    static let stateChanged: Int32 = 2
    static let error: Int32 = 3
    static let torchStateChanged: Int32 = 4
    static let ready: Int32 = 5
    static let zoomChanged: Int32 = 6
}

/// Command tags, mirrored from the Dart `ScannerCommand`.
private enum DNScannerCommand {
    static let configure: Int32 = 1
    static let start: Int32 = 2
    static let stop: Int32 = 3
    static let pause: Int32 = 4
    static let resume: Int32 = 5
    static let setTorch: Int32 = 6
    static let setZoomScale: Int32 = 7
    static let setFacing: Int32 = 8
    static let setFormats: Int32 = 9
    static let setScanWindow: Int32 = 10
}

enum DNScannerLog {
    static func write(_ message: String) {
        let tagged = "[DNMobileScanner] \(message)"
        print(tagged)
        // Opt-in: routes the line into the `dn run` terminal next to Dart output.
        tagged.withCString { _dnAppendLog?($0) }
    }

    private typealias AppendLogFn = @convention(c) (UnsafePointer<CChar>) -> Void
    private static let _dnAppendLog: AppendLogFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DNAppendLog")
        else { return nil }
        return unsafeBitCast(sym, to: AppendLogFn.self)
    }()
}

// MARK: - The dispatcher slot

/// THE SLOT. Heap-allocated so its address never moves: the framework keeps a
/// pointer to it and writes 0 into it when a hot restart begins, while the Dart
/// callback is still valid. Every fire re-reads it, so a dead pointer is never
/// called.
private let _dispatcherSlot: UnsafeMutablePointer<Int64> = {
    let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    p.pointee = 0
    return p
}()

private var _slotRegistered = false

private typealias DNDispatchFn =
    @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

enum DNScannerEmitter {

    /// Serializes `body` and calls Dart. Must be called on the main thread.
    ///
    /// The payload buffer is stack-scoped on purpose: the Dart side receives it
    /// through `Pointer.fromFunction`, which is synchronous and copies the string
    /// during the call, so no ownership is transferred and nothing is leaked.
    static func fire(token: Int64, type: Int32, body: [String: Any]) {
        assert(Thread.isMainThread, "Dart must be called from the main thread")

        guard JSONSerialization.isValidJSONObject(body) else {
            DNScannerLog.write("refusing to emit a non-serializable payload")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else {
            DNScannerLog.write("payload could not be encoded")
            return
        }

        let address = _dispatcherSlot.pointee  // read fresh, never cache
        guard address != 0 else { return }     // hot restart happened, drop quietly

        json.withCString { cString in
            unsafeBitCast(address, to: DNDispatchFn.self)(token, type, cString)
        }
    }
}

@_cdecl("DNMobileScannerSetDispatcher")
public func DNMobileScannerSetDispatcher(_ callbackPtr: Int64) {
    _dispatcherSlot.pointee = callbackPtr
    guard !_slotRegistered else { return }
    _slotRegistered = true
    typealias RegFn = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
    guard let sym = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "DNRegisterAsyncDispatcherSlot"
    ) else {
        DNScannerLog.write(
            "DNRegisterAsyncDispatcherSlot missing: hot restart will not be guarded"
        )
        return
    }
    unsafeBitCast(sym, to: RegFn.self)(_dispatcherSlot)
}

// MARK: - Supported formats

/// Cached for the app's lifetime, because the Dart side reads the pointer without
/// freeing it.
private var _supportedFormatsPtr: UnsafeMutablePointer<CChar>?

@_cdecl("DNMobileScannerSupportedFormats")
public func DNMobileScannerSupportedFormats() -> UnsafePointer<CChar> {
    if let cached = _supportedFormatsPtr { return UnsafePointer(cached) }
    let names = DNScannerFormats.supportedWireNames()
    let json = (try? JSONSerialization.data(withJSONObject: names))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    let allocated = strdup(json) ?? strdup("[]")!
    _supportedFormatsPtr = allocated
    return UnsafePointer(allocated)
}

// MARK: - Hot-restart cleanup

/// Tears down every live scanner.
///
/// Called from the Dart side's `loadSymbols()`, which runs again on each hot
/// restart. Without it the previous session's camera would stay open and its
/// metadata delegate would keep firing into a program that no longer exists.
@_cdecl("DNMobileScannerDisposeAll")
public func DNMobileScannerDisposeAll() {
    let tearDown = {
        for view in _liveScanners.allObjects {
            view.tearDown()
        }
        _liveScanners.removeAllObjects()
    }
    if Thread.isMainThread {
        tearDown()
    } else {
        DispatchQueue.main.sync(execute: tearDown)
    }
}

/// Weakly held, so a view that the framework already released is not resurrected
/// and nothing here extends a view's lifetime.
private let _liveScanners = NSHashTable<DNScannerPreviewView>.weakObjects()

// MARK: - View provider

private let DN_SCANNER_TYPE_KEY = "com.dartnative.mobile_scanner/preview"

/// Claimed lazily on first use. The Dart side claims the same key and the
/// framework hands back the same index, so the two always agree.
private let DN_SCANNER_TYPE_INDEX: Int32 = {
    typealias ClaimFn = @convention(c) (UnsafePointer<CChar>) -> Int32
    guard let sym = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewTypeClaim") else {
        DNScannerLog.write("dlsym DNViewTypeClaim failed")
        return -1
    }
    return DN_SCANNER_TYPE_KEY.withCString {
        unsafeBitCast(sym, to: ClaimFn.self)($0)
    }
}()

private let _createView: @convention(c) (Int32) -> Int64 = { typeIndex in
    // An unknown type index belongs to another plugin. Return 0, never crash.
    guard typeIndex == DN_SCANNER_TYPE_INDEX else { return 0 }

    var result: Int64 = 0
    let build = {
        let view = DNScannerPreviewView(frame: .zero)
        _liveScanners.add(view)
        // The framework takes ownership of this retain and balances it when the
        // view leaves the hierarchy.
        result = Int64(Int(bitPattern: Unmanaged.passRetained(view).toOpaque()))
    }
    if Thread.isMainThread {
        build()
    } else {
        DispatchQueue.main.sync(execute: build)
    }
    return result
}

private let _handleMutation: @convention(c)
    (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void =
{ viewId, eventTag, dataPtr, dataLen in
    let apply = {
        guard let view = _scannerView(for: viewId) else { return }
        // The framework assigns the id after createView, so this is where the view
        // learns its own routing token.
        view.token = viewId
        _dispatch(view, eventTag, dataPtr, dataLen)
    }
    if Thread.isMainThread {
        apply()
    } else {
        DispatchQueue.main.sync(execute: apply)
    }
}

private func _dispatch(
    _ view: DNScannerPreviewView,
    _ eventTag: Int32,
    _ dataPtr: UnsafePointer<UInt8>?,
    _ dataLen: Int32
) {
    switch eventTag {
    case DNScannerCommand.configure:
        guard let json = _json(dataPtr, dataLen) else { return }
        view.configure(json)

    case DNScannerCommand.start:
        view.start()

    case DNScannerCommand.stop:
        view.stop()

    case DNScannerCommand.pause:
        view.pause()

    case DNScannerCommand.resume:
        view.resume()

    case DNScannerCommand.setTorch:
        guard let json = _json(dataPtr, dataLen),
              let on = json["on"] as? Bool else { return }
        view.setTorch(on: on)

    case DNScannerCommand.setZoomScale:
        guard let json = _json(dataPtr, dataLen),
              let scale = json["scale"] as? NSNumber else { return }
        view.setZoom(CGFloat(scale.doubleValue))

    case DNScannerCommand.setFacing:
        guard let json = _json(dataPtr, dataLen),
              let facing = json["facing"] as? String else { return }
        view.setFacing(facing == "front" ? .front : .back)

    case DNScannerCommand.setFormats:
        guard let json = _json(dataPtr, dataLen),
              let mask = json["formats"] as? NSNumber else { return }
        view.setFormats(mask: mask.int32Value)

    case DNScannerCommand.setScanWindow:
        guard let json = _json(dataPtr, dataLen) else { return }
        // An explicit null clears the window, so a missing rect is not an error.
        view.setScanWindow(DNScannerPreviewView.rect(from: json["scanWindow"]))

    default:
        DNScannerLog.write("unknown eventTag=\(eventTag)")
    }
}

/// Decodes a mutation payload, validating the length before reading.
private func _json(
    _ dataPtr: UnsafePointer<UInt8>?,
    _ dataLen: Int32
) -> [String: Any]? {
    guard let dataPtr, dataLen > 0 else { return nil }
    let data = Data(bytes: dataPtr, count: Int(dataLen))
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let json = object as? [String: Any] else {
        DNScannerLog.write("malformed mutation payload")
        return nil
    }
    return json
}

// MARK: - Plumbing

private typealias DNGetViewFn = @convention(c) (Int64) -> Int64

private let _dnGetView: DNGetViewFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewRegistryGetView") else {
        return nil
    }
    return unsafeBitCast(sym, to: DNGetViewFn.self)
}()

private func _scannerView(for id: Int64) -> DNScannerPreviewView? {
    guard let fn = _dnGetView else { return nil }
    let pointer = fn(id)
    guard pointer != 0,
          let raw = UnsafeRawPointer(bitPattern: Int(pointer)) else { return nil }
    return Unmanaged<UIView>.fromOpaque(raw).takeUnretainedValue()
        as? DNScannerPreviewView
}

@_cdecl("DNMobileScannerRegisterProvider")
public func DNMobileScannerRegisterProvider() {
    guard let sym = dlsym(dlopen(nil, RTLD_NOLOAD), "DNRegisterPluginProvider") else {
        DNScannerLog.write(
            "dlsym DNRegisterPluginProvider failed: is dartnative_ios linked?"
        )
        return
    }
    typealias RegFn = @convention(c) (Int64, Int64) -> Void
    let register = unsafeBitCast(sym, to: RegFn.self)
    register(
        unsafeBitCast(_createView as @convention(c) (Int32) -> Int64, to: Int64.self),
        unsafeBitCast(
            _handleMutation as @convention(c)
                (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void,
            to: Int64.self
        )
    )
}
