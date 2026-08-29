import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum NativeCameraWireFormat {
    static let magic = Data([0x54, 0x4f, 0x43, 0x4d]) // "TOCM"
    static let version: UInt8 = 1
    static let headerBytes = 16
    static let width = 1280
    static let height = 720
    static let framesPerSecond = 30
    static let pixelFormat = "NV12"
    static let frameBytes = width * height * 3 / 2
    static let captureSessionPreset = AVCaptureSession.Preset.hd1280x720

    static func videoSettings() -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    }

    enum MessageKind: UInt8 {
        case status = 1
        case frame = 2
    }

    static func message(kind: MessageKind, sequence: UInt32, payload: Data) -> Data {
        var result = Data(capacity: headerBytes + payload.count)
        result.append(magic)
        result.append(version)
        result.append(kind.rawValue)
        result.append(contentsOf: [0, 0])
        append(UInt32(payload.count), to: &result)
        append(sequence, to: &result)
        result.append(payload)
        return result
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

enum NativeCameraSessionLifecycle {
    static let failureNotifications = [
        AVCaptureSession.runtimeErrorNotification,
        AVCaptureSession.didStopRunningNotification,
    ]

    static func shouldTerminateBridge(streaming: Bool, stopped: Bool) -> Bool {
        streaming && !stopped
    }
}

final class NativeCameraBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let descriptor: Int32
    private let sessionQueue = DispatchQueue(label: "dev.tryomarchy.native.camera-session")
    private let videoQueue = DispatchQueue(
        label: "dev.tryomarchy.native.camera-frames",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var session: AVCaptureSession?
    private var sessionObservers: [NSObjectProtocol] = []
    private var streaming = false
    private var stopped = false
    private var sequence: UInt32 = 0

    init(targetPID: pid_t, socketPath: String) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native camera bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "camera bridge")
        super.init()
    }

    deinit {
        stop()
    }

    func run() throws {
        try sendStatus(["status": "idle"])
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0x0D {
                    guard line.count < 4096 else {
                        throw HelperError.io("guest camera request exceeds 4 KiB")
                    }
                    line.append(byte)
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest camera channel")
            }
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        streaming = false
        stateLock.unlock()

        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            removeSessionObservers()
            self.session?.stopRunning()
            self.session = nil
        }
    }

    private func handle(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted() == ["type"],
              let type = object["type"] as? String else {
            throw HelperError.io("guest sent an invalid camera request")
        }
        switch type {
        case "start":
            try startCapture()
        case "stop":
            stopCapture()
        default:
            throw HelperError.io("guest sent an unsupported camera request")
        }
    }

    private func startCapture() throws {
        stateLock.lock()
        let alreadyStreaming = streaming
        let isStopped = stopped
        stateLock.unlock()
        guard !alreadyStreaming, !isStopped else { return }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            try sendStatus(["reason": "permission", "status": "unavailable"])
            return
        }

        try sessionQueue.sync {
            let captureSession: AVCaptureSession
            let cameraName: String
            if let existing = session,
               let input = existing.inputs.first as? AVCaptureDeviceInput {
                captureSession = existing
                cameraName = input.device.localizedName
            } else {
                let configured = try makeCaptureSession()
                captureSession = configured.session
                cameraName = configured.cameraName
                session = captureSession
                observeSessionFailures(captureSession)
            }
            captureSession.startRunning()
            guard captureSession.isRunning else {
                throw HelperError.io("the Mac camera capture session did not start")
            }
            stateLock.lock()
            streaming = true
            stateLock.unlock()
            try sendStatus([
                "fps": NativeCameraWireFormat.framesPerSecond,
                "height": NativeCameraWireFormat.height,
                "name": cameraName,
                "pixelFormat": NativeCameraWireFormat.pixelFormat,
                "status": "streaming",
                "width": NativeCameraWireFormat.width,
            ])
        }
    }

    private func stopCapture() {
        stateLock.lock()
        let wasStreaming = streaming
        streaming = false
        stateLock.unlock()
        guard wasStreaming else { return }
        sessionQueue.sync {
            session?.stopRunning()
        }
        try? sendStatus(["status": "idle"])
    }

    private func makeCaptureSession() throws -> (session: AVCaptureSession, cameraName: String) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("FaceTime")
        }) ?? AVCaptureDevice.default(for: .video) else {
            throw HelperError.io("this Mac has no available camera")
        }

        let targetFormat = device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == NativeCameraWireFormat.width,
                  dimensions.height == NativeCameraWireFormat.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(NativeCameraWireFormat.framesPerSecond)
                    && range.maxFrameRate >= Double(NativeCameraWireFormat.framesPerSecond)
            }
        }
        guard let targetFormat else {
            throw HelperError.io("the Mac camera does not support 1280×720 at 30 fps")
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = NativeCameraWireFormat.videoSettings()
        output.setSampleBufferDelegate(self, queue: videoQueue)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // The default `.high` preset produces 1080p output on FaceTime HD
        // cameras even when their active input format is 720p.
        captureSession.sessionPreset = NativeCameraWireFormat.captureSessionPreset
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw HelperError.io("the Mac camera cannot be attached to the native bridge")
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)

        // Configure the device while it belongs to the session's configuration
        // transaction, as required by AVFoundation's active-format contract.
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = targetFormat
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(NativeCameraWireFormat.framesPerSecond)
        )
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return (captureSession, device.localizedName)
    }

    private func observeSessionFailures(_ captureSession: AVCaptureSession) {
        removeSessionObservers()
        let center = NotificationCenter.default
        sessionObservers = NativeCameraSessionLifecycle.failureNotifications.map { name in
            center.addObserver(
                forName: name,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                self?.captureSessionFailed(notification)
            }
        }
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        for observer in sessionObservers {
            center.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func captureSessionFailed(_ notification: Notification) {
        stateLock.lock()
        let shouldTerminate = NativeCameraSessionLifecycle.shouldTerminateBridge(
            streaming: streaming,
            stopped: stopped
        )
        if shouldTerminate {
            streaming = false
        }
        stateLock.unlock()
        guard shouldTerminate else { return }

        let reason = notification.name == AVCaptureSession.runtimeErrorNotification
            ? "reported a runtime error"
            : "stopped unexpectedly"
        fputs("[camera-bridge] The Mac camera session \(reason); reconnecting.\n", stderr)
        // Closing the channel ends run(); the launcher then restarts this helper,
        // while the guest service reopens its side of the virtio port.
        stop()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let shouldStream = streaming && !stopped
        stateLock.unlock()
        guard shouldStream,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        do {
            let payload = try copyNV12Payload(from: pixelBuffer)
            writeLock.lock()
            sequence &+= 1
            let message = NativeCameraWireFormat.message(
                kind: .frame,
                sequence: sequence,
                payload: payload
            )
            defer { writeLock.unlock() }
            try NativeBridgeSocket.writeAll(message, to: descriptor, label: "camera")
        } catch {
            stateLock.lock()
            let shouldReport = streaming && !stopped
            streaming = false
            stateLock.unlock()
            if shouldReport {
                fputs("[camera-bridge] \(error.localizedDescription)\n", stderr)
                stop()
            }
        }
    }

    private func copyNV12Payload(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              width == NativeCameraWireFormat.width,
              height == NativeCameraWireFormat.height,
              planeCount == 2 else {
            throw HelperError.io(
                String(
                    format: "the Mac camera produced format 0x%08x at %dx%d with %d planes",
                    pixelFormat,
                    width,
                    height,
                    planeCount
                )
            )
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var payload = Data(count: NativeCameraWireFormat.frameBytes)
        try payload.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                throw HelperError.io("cannot allocate a camera frame")
            }
            var destinationOffset = 0
            for plane in 0..<2 {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    throw HelperError.io("the Mac camera frame has no plane storage")
                }
                // NV12's chroma plane reports half the luma width in two-byte
                // samples, but both planes contain `width` packed bytes per row.
                let rowBytes = NativeCameraWireFormat.width
                let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let expectedRows = plane == 0
                    ? NativeCameraWireFormat.height
                    : NativeCameraWireFormat.height / 2
                guard rows == expectedRows,
                      sourceStride >= rowBytes,
                      destinationOffset + rowBytes * rows <= destination.count else {
                    throw HelperError.io("the Mac camera frame has an unexpected plane layout")
                }
                for row in 0..<rows {
                    memcpy(
                        destinationBase.advanced(by: destinationOffset),
                        sourceBase.advanced(by: row * sourceStride),
                        rowBytes
                    )
                    destinationOffset += rowBytes
                }
            }
            guard destinationOffset == destination.count else {
                throw HelperError.io("the Mac camera frame is incomplete")
            }
        }
        return payload
    }

    private func sendStatus(_ fields: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let message = NativeCameraWireFormat.message(kind: .status, sequence: 0, payload: payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try NativeBridgeSocket.writeAll(message, to: descriptor, label: "camera")
    }
}
