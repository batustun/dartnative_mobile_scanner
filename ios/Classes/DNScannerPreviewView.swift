// The hosted native view: an AVCaptureSession, its preview layer, and the
// metadata output that does the recognizing.
//
// One of these owns exactly one capture session. A second instance refuses to
// start rather than contending for the device, so there is never a moment where
// two sessions fight over the camera.

import AVFoundation
import UIKit

final class DNScannerPreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {

    // MARK: Single ownership

    /// The token of the scanner that currently holds the camera, or 0.
    ///
    /// A process-wide claim, because the device itself is process-wide. Checked on
    /// start and released on stop and teardown.
    private static var activeToken: Int64 = 0

    // MARK: Identity

    /// The framework's view id, which is also the dispatcher routing token.
    ///
    /// Zero until the first `configure` mutation arrives, because the framework
    /// assigns the id after `createView` returns. Nothing is emitted before then.
    var token: Int64 = 0

    // MARK: Capture

    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var captureDevice: AVCaptureDevice?

    /// Session mutation and start/stop run here, never on main: `startRunning()`
    /// blocks, often for several hundred milliseconds.
    private let sessionQueue = DispatchQueue(
        label: "com.dartnative.mobile_scanner.session"
    )

    /// Metadata delivery runs here so recognition results never land on main
    /// before they are needed there.
    private let metadataQueue = DispatchQueue(
        label: "com.dartnative.mobile_scanner.metadata"
    )

    private var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    // MARK: Requested configuration

    private var requestedFacing: AVCaptureDevice.Position = .back
    private var formatMask: Int32 = DNScannerFormatBit.all
    private var requestedTorchOn = false
    private var requestedZoom: CGFloat = 1.0

    /// The scan window in normalized preview space, or nil for the whole frame.
    private var scanWindow: CGRect?

    // MARK: Lifecycle intent

    /// What the application asked for, as opposed to what the camera is doing.
    ///
    /// Kept separate so returning from the background does not restart a scanner
    /// that was deliberately stopped.
    private var wantsRunning = false

    /// Set when the app backgrounded a running scanner, so foregrounding knows to
    /// bring it back.
    private var pausedByLifecycle = false

    private var currentState = "stopped"
    private var configured = false
    private var isTornDown = false

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        observeLifecycle()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The view is going away with its Dart element, so the camera must go too.
        // Capture what the closure needs: self is already being destroyed.
        let session = self.session
        let token = self.token
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        if DNScannerPreviewView.activeToken == token {
            DNScannerPreviewView.activeToken = 0
        }
    }

    // MARK: Layout and orientation

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        applyInterfaceOrientation()
        // The region of interest is defined against the layer, so it moves with it.
        applyScanWindow()
    }

    private func applyInterfaceOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported else { return }
        let orientation = (window?.windowScene?.interfaceOrientation)
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
                .first
            ?? .portrait
        connection.videoOrientation = Self.videoOrientation(for: orientation)
    }

    private static func videoOrientation(
        for interface: UIInterfaceOrientation
    ) -> AVCaptureVideoOrientation {
        switch interface {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    // MARK: App lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
    }

    @objc private func appWillResignActive() {
        // Analysis must not continue while backgrounded, and the camera should be
        // free for whatever the user switched to.
        guard currentState == "running" else { return }
        pausedByLifecycle = true
        suspendCapture(reportingState: "paused")
    }

    @objc private func appDidBecomeActive() {
        guard pausedByLifecycle, wantsRunning, !isTornDown else { return }
        pausedByLifecycle = false
        beginStart()
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        emitError(
            code: "nativeFailure",
            message: error?.localizedDescription
                ?? "The capture session stopped with a runtime error.",
            native: error.map { "AVError \($0.code)" }
        )
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        // Another app took the camera, or the app lost its multitasking slot.
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        if reason == .videoDeviceInUseByAnotherClient {
            emitError(
                code: "cameraInUse",
                message: "Another app is using the camera.",
                native: "videoDeviceInUseByAnotherClient"
            )
            return
        }
        if currentState == "running" {
            pausedByLifecycle = true
            setState("paused")
        }
    }

    @objc private func sessionInterruptionEnded() {
        guard pausedByLifecycle, wantsRunning, !isTornDown else { return }
        pausedByLifecycle = false
        beginStart()
    }

    // MARK: Mutation entry points

    func configure(_ json: [String: Any]) {
        if let facing = json["facing"] as? String {
            requestedFacing = facing == "front" ? .front : .back
        }
        if let mask = json["formats"] as? NSNumber {
            formatMask = mask.int32Value
        }
        requestedTorchOn = json["torch"] as? Bool ?? false
        if let zoom = json["zoom"] as? NSNumber {
            requestedZoom = CGFloat(zoom.doubleValue)
        }
        scanWindow = Self.rect(from: json["scanWindow"])
        configured = true

        if json["autoStart"] as? Bool ?? false {
            start()
        }
    }

    func start() {
        guard configured, !isTornDown else { return }
        wantsRunning = true
        pausedByLifecycle = false
        guard currentState != "running", currentState != "starting" else { return }
        beginStart()
    }

    func stop() {
        wantsRunning = false
        pausedByLifecycle = false
        guard currentState != "stopped" else {
            setState("stopped")
            return
        }
        suspendCapture(reportingState: "stopped")
    }

    func pause() {
        guard currentState == "running" else { return }
        // Not a lifecycle pause, so foregrounding must not undo it.
        pausedByLifecycle = false
        suspendCapture(reportingState: "paused")
    }

    func resume() {
        guard currentState == "paused", wantsRunning || configured else { return }
        beginStart()
    }

    func setTorch(on: Bool) {
        requestedTorchOn = on
        guard let device = captureDevice else { return }
        applyTorch(on: on, to: device)
        emitTorchState()
    }

    func setZoom(_ scale: CGFloat) {
        requestedZoom = scale
        guard let device = captureDevice else { return }
        let applied = applyZoom(scale, to: device)
        emit(type: DNScannerEventType.zoomChanged, body: ["scale": Double(applied)])
    }

    func setFacing(_ position: AVCaptureDevice.Position) {
        guard position != requestedFacing || deviceInput == nil else { return }
        requestedFacing = position
        guard currentState == "running" || currentState == "starting" else { return }
        // Rebuild the session around the new camera. The old input is removed
        // before the new one is added, inside one configuration transaction, so the
        // two never overlap.
        beginStart()
    }

    func setFormats(mask: Int32) {
        formatMask = mask
        guard session.outputs.contains(metadataOutput) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyMetadataTypes()
        }
    }

    func setScanWindow(_ window: CGRect?) {
        scanWindow = window
        applyScanWindow()
    }

    /// Releases the camera for good. Called when the framework disposes the view.
    func tearDown() {
        isTornDown = true
        wantsRunning = false
        NotificationCenter.default.removeObserver(self)
        suspendCapture(reportingState: "stopped")
    }

    // MARK: Start and stop

    private func beginStart() {
        setState("starting")

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            claimAndOpen()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.isTornDown else { return }
                    if granted {
                        self.claimAndOpen()
                    } else {
                        // A refusal at the prompt can be asked again later.
                        self.emitError(
                            code: "permissionDenied",
                            message: "The user refused camera access.",
                            native: nil
                        )
                    }
                }
            }
        case .denied, .restricted:
            // Neither re-prompts; only Settings can change this.
            emitError(
                code: "permissionPermanentlyDenied",
                message: status == .restricted
                    ? "Camera access is restricted on this device."
                    : "Camera access was refused and will not be requested again.",
                native: status == .restricted ? "restricted" : "denied"
            )
        @unknown default:
            emitError(
                code: "permissionDenied",
                message: "Camera authorization status could not be determined.",
                native: nil
            )
        }
    }

    private func claimAndOpen() {
        guard !isTornDown else { return }

        let unsupported = DNScannerFormats.unsupportedWireNames(in: formatMask)
        if !unsupported.isEmpty {
            emitError(
                code: "unsupportedBarcodeFormat",
                message: "This iOS version cannot recognize: "
                    + unsupported.joined(separator: ", ")
                    + ". Check MobileScanner.supportedFormats.",
                native: nil
            )
            return
        }

        let active = DNScannerPreviewView.activeToken
        if active != 0, active != token {
            emitError(
                code: "cameraInUse",
                message: "Another MobileScanner already owns the camera. "
                    + "Only one scanner can run at a time.",
                native: nil
            )
            return
        }
        DNScannerPreviewView.activeToken = token

        sessionQueue.async { [weak self] in
            self?.openSession()
        }
    }

    private func openSession() {
        guard let device = Self.device(for: requestedFacing) else {
            // Distinguish "this device has no such camera" from a real failure.
            let hasAny = Self.device(for: .back) != nil
                || Self.device(for: .front) != nil

            // Release whatever the previous session held. Without this a failed
            // switch leaves the old camera running while the state says "error"
            // and every detection is suppressed.
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            if let existing = deviceInput {
                session.removeInput(existing)
                deviceInput = nil
            }
            session.commitConfiguration()
            captureDevice = nil

            emitError(
                code: hasAny ? "unsupportedCamera" : "cameraUnavailable",
                message: hasAny
                    ? "This device has no \(requestedFacing == .front ? "front" : "back") camera."
                    : "This device has no usable camera.",
                native: nil
            )
            return
        }

        session.beginConfiguration()

        if let existing = deviceInput {
            session.removeInput(existing)
            deviceInput = nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                emitError(
                    code: "startFailed",
                    message: "The camera input could not be added to the session.",
                    native: nil
                )
                return
            }
            session.addInput(input)
            deviceInput = input
            captureDevice = device
        } catch let error as NSError {
            session.commitConfiguration()
            // A busy device surfaces here as well as through the interruption
            // notification, so classify it rather than reporting a generic failure.
            let busy = error.code == AVError.deviceAlreadyUsedByAnotherSession.rawValue
            emitError(
                code: busy ? "cameraInUse" : "cameraUnavailable",
                message: error.localizedDescription,
                native: "AVError \(error.code)"
            )
            return
        }

        if !session.outputs.contains(metadataOutput) {
            guard session.canAddOutput(metadataOutput) else {
                session.commitConfiguration()
                emitError(
                    code: "initializationFailed",
                    message: "The metadata output could not be added to the session.",
                    native: nil
                )
                return
            }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        }

        // metadataObjectTypes is only assignable once the output has a connection,
        // which is why it is set after addOutput and inside the transaction.
        applyMetadataTypes()

        session.commitConfiguration()

        if metadataOutput.metadataObjectTypes?.isEmpty ?? true {
            emitError(
                code: "unsupportedBarcodeFormat",
                message: "None of the requested barcode formats are supported here.",
                native: nil
            )
            return
        }

        configureDevice(device)

        if !session.isRunning { session.startRunning() }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.applyInterfaceOrientation()
            self.applyScanWindow()
            self.setState("running")
            self.emitReady(device: device)
        }
    }

    private func applyMetadataTypes() {
        let wanted = DNScannerFormats.metadataTypes(for: formatMask)
        // Asking for a type the output does not list throws, so intersect first.
        let available = Set(metadataOutput.availableMetadataObjectTypes)
        metadataOutput.metadataObjectTypes = wanted.filter { available.contains($0) }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Continuous autofocus is what makes a scanner feel instant. Barcodes
            // are usually close, so bias the ranging accordingly where supported.
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if requestedZoom > 1.0 {
                device.videoZoomFactor = Self.clampZoom(requestedZoom, for: device)
            }
            if requestedTorchOn, device.hasTorch, device.isTorchAvailable {
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            }
        } catch let error as NSError {
            // Not fatal: the session still runs with default focus and no torch.
            DNScannerLog.write(
                "device configuration failed: \(error.localizedDescription)"
            )
        }
    }

    private func suspendCapture(reportingState state: String) {
        if DNScannerPreviewView.activeToken == token {
            DNScannerPreviewView.activeToken = 0
        }
        setState(state == "stopped" ? "stopping" : state)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }

            // Drop the input so another app, or another scanner, can take the
            // camera. The output and its delegate stay, so restarting is cheap.
            self.session.beginConfiguration()
            if let input = self.deviceInput {
                self.session.removeInput(input)
                self.deviceInput = nil
            }
            self.session.commitConfiguration()
            self.captureDevice = nil

            DispatchQueue.main.async {
                guard !self.isTornDown else { return }
                self.setState(state)
                if state == "stopped" { self.emitTorchState(.unavailable) }
            }
        }
    }

    // MARK: Torch and zoom

    private func applyTorch(on: Bool, to device: AVCaptureDevice) {
        guard device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
        } catch let error as NSError {
            DNScannerLog.write("torch failed: \(error.localizedDescription)")
        }
    }

    private func applyZoom(_ scale: CGFloat, to device: AVCaptureDevice) -> CGFloat {
        let clamped = Self.clampZoom(scale, for: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = clamped
        } catch let error as NSError {
            DNScannerLog.write("zoom failed: \(error.localizedDescription)")
        }
        return clamped
    }

    private static func clampZoom(
        _ scale: CGFloat,
        for device: AVCaptureDevice
    ) -> CGFloat {
        min(max(scale, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor)
    }

    // MARK: Scan window

    private func applyScanWindow() {
        guard let window = scanWindow else {
            metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        // Normalized preview space to layer points, then to the metadata output's
        // own space. The second step is AVFoundation's conversion, which accounts
        // for the aspect-fill crop and the video orientation, so none of that is
        // hand-rolled here.
        let layerRect = CGRect(
            x: window.origin.x * size.width,
            y: window.origin.y * size.height,
            width: window.size.width * size.width,
            height: window.size.height * size.height
        )
        let converted = previewLayer.metadataOutputRectConverted(fromLayerRect: layerRect)
        guard converted.isFinite(), !converted.isEmpty else { return }
        metadataOutput.rectOfInterest = converted
    }

    // MARK: Metadata delegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !metadataObjects.isEmpty else { return }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let mask = formatMask

        // Which input produced this batch. AVFoundation tears down and rebuilds the
        // connection when the session's input is replaced, so comparing this against
        // the live deviceInput on main identifies a batch from a previous camera
        // deterministically, without a shared counter to race on. A state check
        // cannot do it: after a switch the new session also reports "running".
        let sourceInput = connection.inputPorts.first?.input

        // The preview layer's transform is CALayer state, so the conversion has to
        // happen on main. Dart has to be called from main anyway, so this is the
        // one hop either way, not an extra one. Analysis is unaffected: the capture
        // pipeline keeps running on its own queues.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTornDown, self.currentState == "running" else {
                return
            }
            // Dropped rather than transformed: transformedMetadataObject(for:) would
            // map an old camera's object through the new camera's preview layer, and
            // a rear-camera result must never be reported as a front-camera one.
            guard let sourceInput, sourceInput === self.deviceInput else { return }
            self.deliver(metadataObjects, timestamp: timestamp, mask: mask)
        }
    }

    private func deliver(
        _ objects: [AVMetadataObject],
        timestamp: Int64,
        mask: Int32
    ) {
        let size = bounds.size
        var payload: [[String: Any]] = []

        for object in objects {
            guard let code = object as? AVMetadataMachineReadableCodeObject else {
                continue
            }
            guard let resolved = DNScannerFormats.resolve(
                type: code.type,
                value: code.stringValue,
                mask: mask
            ) else { continue }

            var entry: [String: Any] = ["f": resolved.name]
            if let value = resolved.value { entry["v"] = value }

            // Transform into the preview's own coordinate space, which is what the
            // Dart side documents and what an overlay needs.
            if let transformed = previewLayer.transformedMetadataObject(for: code)
                as? AVMetadataMachineReadableCodeObject {
                if size.width > 0, size.height > 0 {
                    let box = transformed.bounds
                    if box.isFinite() {
                        entry["r"] = [
                            Double(box.origin.x / size.width),
                            Double(box.origin.y / size.height),
                            Double(box.size.width / size.width),
                            Double(box.size.height / size.height),
                        ]
                    }
                    let corners = transformed.corners
                    if !corners.isEmpty {
                        var points: [[Double]] = []
                        var ok = true
                        for point in corners {
                            guard point.x.isFinite, point.y.isFinite else {
                                ok = false
                                break
                            }
                            points.append([
                                Double(point.x / size.width),
                                Double(point.y / size.height),
                            ])
                        }
                        // All or nothing, matching the Dart contract.
                        if ok { entry["c"] = points }
                    }
                }
            }

            payload.append(entry)
        }

        guard !payload.isEmpty else { return }

        var body: [String: Any] = ["ts": timestamp, "b": payload]
        if let dimensions = currentFormatDimensions() {
            body["w"] = dimensions.width
            body["h"] = dimensions.height
        }
        emit(type: DNScannerEventType.detection, body: body)
    }

    private func currentFormatDimensions() -> (width: Int, height: Int)? {
        guard let device = captureDevice else { return nil }
        let description = device.activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return (Int(dimensions.width), Int(dimensions.height))
    }

    // MARK: Events

    private func setState(_ next: String) {
        guard currentState != next else { return }
        currentState = next
        emit(type: DNScannerEventType.stateChanged, body: ["state": next])
    }

    private func emitReady(device: AVCaptureDevice) {
        let torch: String
        if device.hasTorch, device.isTorchAvailable {
            torch = device.torchMode == .off ? "off" : "on"
        } else {
            torch = "unavailable"
        }
        emit(type: DNScannerEventType.ready, body: [
            "facing": device.position == .front ? "front" : "back",
            "torch": torch,
            "minZoom": Double(device.minAvailableVideoZoomFactor),
            "maxZoom": Double(device.maxAvailableVideoZoomFactor),
        ])
        emit(type: DNScannerEventType.zoomChanged, body: [
            "scale": Double(device.videoZoomFactor),
        ])
    }

    private func emitTorchState(_ forced: TorchReport? = nil) {
        let value: String
        if let forced {
            value = forced.rawValue
        } else if let device = captureDevice, device.hasTorch, device.isTorchAvailable {
            value = device.torchMode == .off ? "off" : "on"
        } else {
            value = "unavailable"
        }
        emit(type: DNScannerEventType.torchStateChanged, body: ["torch": value])
    }

    enum TorchReport: String {
        case unavailable
        case off
        case on
    }

    /// Reports a failure.
    ///
    /// Hops to main because most failures are raised from `openSession`, which runs
    /// on `sessionQueue`: Dart must be called from the main thread, and
    /// `currentState` and `activeToken` are read from main by the metadata
    /// delegate, so they are mutated there too rather than across threads.
    private func emitError(code: String, message: String, native: String?) {
        onMain { [weak self] in
            guard let self else { return }
            if DNScannerPreviewView.activeToken == self.token {
                DNScannerPreviewView.activeToken = 0
            }
            var body: [String: Any] = ["code": code, "message": message]
            if let native { body["native"] = native }
            self.currentState = "error"
            // Dart derives the error state from this event, so no separate state
            // change is sent: one event, one transition.
            self.emit(type: DNScannerEventType.error, body: body)
        }
    }

    private func emit(type: Int32, body: [String: Any]) {
        guard token != 0 else { return }
        let token = self.token
        onMain { DNScannerEmitter.fire(token: token, type: type, body: body) }
    }

    /// Runs `work` on the main thread, immediately when already there.
    ///
    /// Not `DispatchQueue.main.async` unconditionally: an event already raised on
    /// main must keep its ordering relative to the state changes around it, and
    /// deferring it would let a later event overtake it.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: Helpers

    private static func device(
        for position: AVCaptureDevice.Position
    ) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    static func rect(from value: Any?) -> CGRect? {
        guard let numbers = value as? [NSNumber], numbers.count == 4 else {
            return nil
        }
        let rect = CGRect(
            x: CGFloat(numbers[0].doubleValue),
            y: CGFloat(numbers[1].doubleValue),
            width: CGFloat(numbers[2].doubleValue),
            height: CGFloat(numbers[3].doubleValue)
        )
        guard rect.isFinite(), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}

extension CGRect {
    /// Whether every edge is finite, so the rectangle is safe to convert and to
    /// serialize. JSON has no representation for NaN or infinity.
    func isFinite() -> Bool {
        origin.x.isFinite && origin.y.isFinite
            && size.width.isFinite && size.height.isFinite
    }
}
