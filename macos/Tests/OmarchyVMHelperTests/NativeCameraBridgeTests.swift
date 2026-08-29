import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native camera bridge")
struct NativeCameraBridgeTests {
    @Test("wire messages use the fixed little-endian virtio framing")
    func wireFraming() throws {
        let payload = Data([0xaa, 0xbb, 0xcc])
        let message = NativeCameraWireFormat.message(
            kind: .frame,
            sequence: 0x0102_0304,
            payload: payload
        )
        #expect(message.count == NativeCameraWireFormat.headerBytes + payload.count)
        #expect(Array(message.prefix(4)) == [0x54, 0x4f, 0x43, 0x4d])
        #expect(message[4] == NativeCameraWireFormat.version)
        #expect(message[5] == NativeCameraWireFormat.MessageKind.frame.rawValue)
        #expect(Array(message[8..<12]) == [3, 0, 0, 0])
        #expect(Array(message[12..<16]) == [4, 3, 2, 1])
        #expect(message.suffix(payload.count) == payload)
    }

    @Test("camera format is 720p NV12")
    func fixedFormat() {
        #expect(NativeCameraWireFormat.width == 1280)
        #expect(NativeCameraWireFormat.height == 720)
        #expect(NativeCameraWireFormat.framesPerSecond == 30)
        #expect(NativeCameraWireFormat.pixelFormat == "NV12")
        #expect(NativeCameraWireFormat.frameBytes == 1_382_400)
        #expect(NativeCameraWireFormat.captureSessionPreset == .hd1280x720)
        let settings = NativeCameraWireFormat.videoSettings()
        #expect(
            settings[kCVPixelBufferPixelFormatTypeKey as String] as? Int
                == Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        )
        #expect(settings[kCVPixelBufferWidthKey as String] as? Int == 1280)
        #expect(settings[kCVPixelBufferHeightKey as String] as? Int == 720)
    }

    @Test("active session failures reconnect the bridge")
    func sessionFailureRecovery() {
        #expect(
            NativeCameraSessionLifecycle.failureNotifications
                == [
                    AVCaptureSession.runtimeErrorNotification,
                    AVCaptureSession.didStopRunningNotification,
                ]
        )
        #expect(
            NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: true,
                stopped: false
            )
        )
        #expect(
            !NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: false,
                stopped: false
            )
        )
        #expect(
            !NativeCameraSessionLifecycle.shouldTerminateBridge(
                streaming: true,
                stopped: true
            )
        )
    }
}

@Suite("Camera launch policy")
struct CameraLaunchDecisionTests {
    @Test("denial keeps Omarchy launchable and gives recovery instructions")
    func deniedStillLaunches() {
        let decision = CameraLaunchDecision.make(for: .denied)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("continue without the Mac camera") == true)
        #expect(decision.warning?.contains("Privacy & Security > Camera") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = CameraLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }

    @Test("an unrequested camera remains optional")
    func notDeterminedStillLaunches() {
        let decision = CameraLaunchDecision.make(for: .notDetermined)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("was not requested") == true)
    }
}
